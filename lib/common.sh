#!/usr/bin/env bash
# Upkeep shared library. Pure helpers + path setup. Sourced by bin/upkeep, backends, tests.
set -euo pipefail
# C.UTF-8, not C: byte-identical collation for sort/join (verified) while leaving UTF-8 bytes
# intact in logs and package summaries instead of mangling them.
export LC_ALL=C.UTF-8

# Package/app name shape. Mirrors the root helper's validation on purpose: a hold must be
# rejected HERE, at hold time, so a bad name can never reach the privileged apply path.
UPKEEP_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._+-]*$'

UPKEEP_CONFIG_DIR="${UPKEEP_CONFIG_DIR:-$HOME/.config/upkeep}"
UPKEEP_STATE_DIR="${UPKEEP_STATE_DIR:-$HOME/.local/state/upkeep}"
UPKEEP_PKEXEC="${UPKEEP_PKEXEC-pkexec}"
UPKEEP_REFRESH_HELPER="${UPKEEP_REFRESH_HELPER:-/usr/local/libexec/upkeep-refresh}"
UPKEEP_APPLY_HELPER="${UPKEEP_APPLY_HELPER:-/usr/local/libexec/upkeep-apply}"
UPKEEP_NOTIFY="${UPKEEP_NOTIFY:-notify-send}"

CONFIG_FILE="$UPKEEP_CONFIG_DIR/config"
HOLDS_FILE="$UPKEEP_CONFIG_DIR/holds"
STATE_FILE="$UPKEEP_STATE_DIR/state.json"
HIST_DIR="$UPKEEP_STATE_DIR/history"
LOG_DIR="$UPKEEP_STATE_DIR/logs"
SNAP_DIR="$UPKEEP_STATE_DIR/snapshots"
LAST_REFRESH_FILE="$UPKEEP_STATE_DIR/last_refresh"
OFFLINE_MARKER="$UPKEEP_STATE_DIR/offline_staged.json"
LOCK_FILE="$UPKEEP_STATE_DIR/lock"

upkeep_init_dirs() { mkdir -p "$UPKEEP_CONFIG_DIR" "$HIST_DIR" "$LOG_DIR" "$SNAP_DIR"; }

atomic_write() {  # dest; stdin → dest atomically (same-dir tmp so mv stays atomic)
  local dest="$1" tmp
  tmp="$(mktemp -p "$(dirname "$dest")" .atomic.XXXXXX)"
  if cat > "$tmp"; then mv "$tmp" "$dest"; else rm -f "$tmp"; return 1; fi
}

collapse_versions() {  # stdin: name-sorted TSV name\tver (names may repeat) → one row per name, versions comma-joined in input order
  awk -F'\t' '
    $1 != prev { if (prev != "") print prev "\t" vals; prev = $1; vals = $2; next }
    { vals = vals "," $2 }
    END { if (prev != "") print prev "\t" vals }'
}

config_get() {  # key default
  if [[ -e "$CONFIG_FILE" && ! -r "$CONFIG_FILE" ]]; then
    echo "warning: $CONFIG_FILE exists but is unreadable - using default for $1" >&2
  fi
  local v
  v="$(grep -s "^$1=" "$CONFIG_FILE" | tail -1 | cut -d= -f2- || true)"
  printf '%s\n' "${v:-$2}"
}

config_set() {  # key value
  [[ "$1" =~ ^[a-z][a-z0-9_]+$ ]] || { echo "invalid config key: $1" >&2; return 2; }
  [[ "$2" == *$'\n'* ]] && { echo "config value must be single-line" >&2; return 2; }
  upkeep_init_dirs
  touch "$CONFIG_FILE"
  # Read-then-write: grep completes into a variable BEFORE any write begins, so a failure
  # mid-pipeline can never leave a truncated config behind. rc 1 = "no other lines", allowed.
  local out rc=0
  out="$(grep -v "^$1=" "$CONFIG_FILE")" || rc=$?
  [[ $rc -le 1 ]] || return $rc
  printf '%s%s=%s\n' "${out:+$out$'\n'}" "$1" "$2" | atomic_write "$CONFIG_FILE"
}

priv_refresh() { ${UPKEEP_PKEXEC:+$UPKEEP_PKEXEC} "$UPKEEP_REFRESH_HELPER" "$@"; }
priv_apply()   { ${UPKEEP_PKEXEC:+$UPKEEP_PKEXEC} "$UPKEEP_APPLY_HELPER" "$@"; }
notify()       { "$UPKEEP_NOTIFY" "$@" >/dev/null 2>&1 || true; }
now_iso()      { date -Is; }

# --- holds: one "backend:name" per line ---
holds_all() { cat "$HOLDS_FILE" 2>/dev/null || true; }
holds_for() { holds_all | grep "^$1:" | cut -d: -f2- || true; }
hold_add() {  # backend name
  [[ "$2" =~ $UPKEEP_NAME_RE ]] || { echo "invalid hold name: $2" >&2; return 2; }
  upkeep_init_dirs; touch "$HOLDS_FILE"
  grep -qxF "$1:$2" "$HOLDS_FILE" || printf '%s:%s\n' "$1" "$2" >> "$HOLDS_FILE"
}
hold_remove() {  # backend name
  [[ -f "$HOLDS_FILE" ]] || return 0
  # Read-then-write, same reasoning as config_set: never truncate before the read succeeds.
  local out rc=0
  out="$(grep -vxF "$1:$2" "$HOLDS_FILE")" || rc=$?
  [[ $rc -le 1 ]] || return $rc
  printf '%s' "${out:+$out$'\n'}" | atomic_write "$HOLDS_FILE"
}
mark_held() {  # backend; stdin: JSON [{name,from,to}] → adds held:bool
  local holds_json
  holds_json="$(holds_for "$1" | jq -Rn '[inputs]')"
  # `.name as $n` is load-bearing: jq evaluates the argument of index() against index()'s own
  # input ($holds, an array), so an inline `index(.name)` dies with "Cannot index array".
  jq --argjson holds "$holds_json" '[.[] | .name as $n | . + {held: (($holds | index($n)) != null)}]'
}

# --- snapshot diff: before/after TSV, sorted by name with ONE row per name → report JSON ---
# Producers MUST pipe through collapse_versions first. Fedora keeps several versions of
# installonly packages (kernel* families, gpg-pubkey), so a raw rpm listing repeats names and
# join emits a CROSS PRODUCT — a self-diff of this box's real package list produced 192 phantom
# "updated" rows. The guard below refuses that input loudly instead of reporting fiction.
tsv_diff_updates() {  # before_file after_file
  local f
  for f in "$1" "$2"; do
    awk -F'\t' 'prev == $1 { exit 65 } { prev = $1 }' "$f" \
      || { echo "tsv_diff_updates: duplicate names in $f (run through collapse_versions)" >&2; return 65; }
  done
  {
    # `$2"" != $3""` forces STRING comparison: awk compares two numeric-looking fields
    # numerically, which makes a real 1.1 → 1.10 bump compare equal and vanish from the report.
    join -t "$(printf '\t')" "$1" "$2" | awk -F'\t' '$2"" != $3"" {print "U\t"$1"\t"$2"\t"$3}'
    join -t "$(printf '\t')" -v2 "$1" "$2" | awk -F'\t' '{print "A\t"$1"\t\t"$2}'
    join -t "$(printf '\t')" -v1 "$1" "$2" | awk -F'\t' '{print "R\t"$1"\t"$2"\t"}'
  } | jq -Rn '
    [inputs | split("\t")] |
    { updated: [.[] | select(.[0]=="U") | {name:.[1], from:.[2], to:.[3]}],
      added:   [.[] | select(.[0]=="A") | {name:.[1], to:.[3]}],
      removed: [.[] | select(.[0]=="R") | {name:.[1], from:.[2]}] }'
}

# --- state assembly ---
assemble_state() {  # $1 dnf items JSON (held-marked), $2 flatpak items JSON, $3 status, $4 error
  jq -n --argjson dnf "$1" --argjson fp "$2" --arg status "$3" --arg error "$4" --arg now "$(now_iso)" '
    def wrap: {count: ([.[] | select(.held|not)] | length),
               held:  ([.[] | select(.held)] | length),
               items: .};
    {last_check: $now, status: $status, error: $error,
     backends: {dnf: ($dnf | wrap), flatpak: ($fp | wrap)},
     actionable: (($dnf + $fp) | [.[] | select(.held|not)] | length),
     held_total: (($dnf + $fp) | [.[] | select(.held)] | length)}'
}

state_prev_items() {  # backend → previous items JSON or []
  jq ".backends.$1.items // []" "$STATE_FILE" 2>/dev/null || echo '[]'
}

write_state() { atomic_write "$STATE_FILE"; }   # per-process mktemp: overlapping checks (timer + event watch + post-run) must never collide

maybe_refresh_metadata() {  # ≤ every 3h, AC power, unmetered; never blocks check on failure
  [[ -n "${UPKEEP_SKIP_REFRESH:-}" ]] && return 0
  local last=0 now; now="$(date +%s)"
  [[ -f "$LAST_REFRESH_FILE" ]] && last="$(stat -c %Y "$LAST_REFRESH_FILE")"
  (( now - last < 10800 )) && return 0
  on_battery && return 0
  metered_connection && return 0
  priv_refresh refresh >/dev/null 2>&1 && touch "$LAST_REFRESH_FILE" || true
}

on_battery() {
  local ps
  for ps in /sys/class/power_supply/BAT*/status; do
    [[ -e "$ps" ]] && grep -q Discharging "$ps" && return 0
  done
  return 1
}

metered_connection() {
  busctl get-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager \
    org.freedesktop.NetworkManager Metered 2>/dev/null | grep -qE ' (1|3)$'
}
