#!/usr/bin/env bash
# Upkeep shared library. Pure helpers + path setup. Sourced by bin/upkeep, backends, tests.
set -euo pipefail
# C.UTF-8, not C: byte-identical collation for sort/join (verified) while leaving UTF-8 bytes
# intact in logs and package summaries instead of mangling them.
export LC_ALL=C.UTF-8

# Package/app name shape. Mirrors the root helper's validation on purpose: a hold must be
# rejected HERE, at hold time, so a bad name can never reach the privileged apply path.
UPKEEP_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._+-]*$'

# session-critical prefixes: a LIVE upgrade of these can break the running desktop mid-transaction
# (spec §Run surfaces), so Upkeep recommends the offline path before proceeding. Overridable.
UPKEEP_RISKY_RE="${UPKEEP_RISKY_RE:-^(kernel|systemd|glibc|dbus|mesa|qt6|kf6|plasma-workspace)}"

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

upkeep_init_dirs() {
  mkdir -p "$UPKEEP_CONFIG_DIR" "$HIST_DIR" "$LOG_DIR" "$SNAP_DIR"
  # Sweep aged orphan tmps: a crash between mktemp and mv leaks .atomic.XXXXXX forever.
  # +60min so a tmp belonging to a live concurrent writer is never eligible.
  [[ -d "$UPKEEP_STATE_DIR" ]] && find "$UPKEEP_STATE_DIR" -maxdepth 1 -name '.atomic.*' -mmin +60 -delete 2>/dev/null || true
}

atomic_write() {  # dest; stdin → dest atomically (same-dir tmp so mv stays atomic)
  local dest="$1" tmp
  tmp="$(mktemp -p "$(dirname "$dest")" .atomic.XXXXXX)"
  # sync before the rename: an atomic rename only guarantees you see the OLD or NEW name, not
  # that the new name's CONTENT reached disk. After an unclean shutdown that gap shows up as a
  # zero-length holds file - which silently un-holds every package the user pinned.
  if cat > "$tmp"; then sync "$tmp" 2>/dev/null || true; mv "$tmp" "$dest"; else rm -f "$tmp"; return 1; fi
}

collapse_versions() {  # stdin: name-sorted TSV name\tver (names may repeat) → one row per name, versions comma-joined in input order
  awk -F'\t' '
    $1 != prev { if (prev != "") print prev "\t" vals; prev = $1; vals = $2; next }
    { vals = vals "," $2 }
    END { if (prev != "") print prev "\t" vals }'
}

upkeep_default() {  # key → default ("" if unknown)
  case "$1" in
    include_flatpak|auto_accept) echo true ;;
    surface) echo terminal ;;
    refresh_interval_min) echo 60 ;;
    *) echo "" ;;
  esac
}
is_true() { local v="${1,,}"; [[ "$v" == true || "$v" == 1 || "$v" == yes ]]; }

config_get() {  # key [default]; explicit default wins, else the upkeep_default table
  if [[ -e "$CONFIG_FILE" && ! -r "$CONFIG_FILE" ]]; then
    echo "warning: $CONFIG_FILE exists but is unreadable - using default for $1" >&2
  fi
  local v
  v="$(grep -s "^$1=" "$CONFIG_FILE" | tail -1 | cut -d= -f2- || true)"
  printf '%s\n' "${v:-${2:-$(upkeep_default "$1")}}"
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

# timeout: metadata refresh runs from background checks. Once polkit exists but before the
# action file is installed, pkexec falls back to an auth DIALOG - a background check would hang
# forever waiting on a password nobody is there to type. priv_apply stays untimed on purpose:
# there, interactive auth is the legitimate flow.
priv_refresh() { timeout 120 ${UPKEEP_PKEXEC:+$UPKEEP_PKEXEC} "$UPKEEP_REFRESH_HELPER" "$@"; }
priv_apply()   { ${UPKEEP_PKEXEC:+$UPKEEP_PKEXEC} "$UPKEEP_APPLY_HELPER" "$@"; }
notify()       { "$UPKEEP_NOTIFY" "$@" >/dev/null 2>&1 || true; }
now_iso()      { date -Is; }

# --- passwordless polkit rule rendering ---
# Split out of bin/upkeep so the render and its self-check are unit-testable without touching
# /etc: the ONLY thing this file's caller then does is hand the result to install(1).
render_passwordless_rule() {  # template_file out_file → 0, or 2 with nothing written
  local tmpl="$1" out="$2" u n
  # $(id -un), never $USER: a crafted USER env var used to be sed-injected into the render and
  # could drop the scope clause. id -un is kernel truth, awk -v never interprets it, and the
  # guard below also keeps the name clear of gsub's replacement metachars (& and backslash).
  u="$(id -un)"
  [[ "$u" =~ ^[a-z_][a-z0-9._-]*$ ]] || {
    echo "unexpected username: $u - install the rules file manually; see polkit/49-upkeep.rules.in" >&2
    return 2; }
  awk -v u="$u" '{gsub(/@USER@/, u); print}' "$tmpl" > "$out" || { rm -f "$out"; return 2; }
  # Self-check BOTH halves plus the rule count. A template that lost the scope clause grants to
  # inactive/remote sessions; one that lost the action id grants EVERY polkit action; a second
  # addRule block could carry anything at all. Nothing unverified reaches install(1).
  # Comment lines are stripped first: a grep that reads them would accept a rule whose scope
  # survives only in a `//` comment while the code that runs has none.
  local code
  code="$(grep -v '^[[:space:]]*//' "$out" || true)"
  n="$(grep -c 'polkit.addRule' <<<"$code" || true)"
  if ! grep -q 'subject.active && subject.local' <<<"$code" \
     || ! grep -q 'action.id == "org.erez.upkeep.apply"' <<<"$code" \
     || [[ "$n" != 1 ]]; then
    echo "rendered rule failed scope check" >&2; rm -f "$out"; return 2
  fi
}

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

# stdin: items JSON (AFTER mark_held) → one session-critical name per line.
# Held packages are excluded on purpose: the user already declined that one, so recommending a
# whole different update strategy because of it would be nagging about a decision already made.
# `|| true`: grep exits 1 when it selects nothing, and "nothing risky" is the common, happy case.
risky_names() { jq -r '.[] | select(.held|not) | .name' | grep -E "$UPKEEP_RISKY_RE" || true; }

# --- snapshot diff: before/after TSV, sorted by name with ONE row per name → report JSON ---
# Producers MUST pipe through collapse_versions first. Fedora keeps several versions of
# installonly packages (kernel* families, gpg-pubkey), so a raw rpm listing repeats names and
# join emits a CROSS PRODUCT - a self-diff of this box's real package list produced 192 phantom
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
# State schema v1 - FROZEN. This JSON is a public interface (the widget and any scripted reader
# consume it), so additive changes only; anything else bumps `schema`.
assemble_state() {  # $1 dnf items, $2 fp items, $3 status, $4 error, $5 fp_enabled(true|false), $6 prev last_success ISO or "", $7 risky_pending JSON array (optional)
  jq -n --argjson dnf "$1" --argjson fp "$2" --arg status "$3" --arg error "$4" \
        --argjson fpe "$5" --arg pls "$6" --argjson risky "${7:-[]}" --arg now "$(now_iso)" '
    def wrap(e): {enabled: e,
                  actionable: ([.[] | select(.held|not)] | length),
                  held:       ([.[] | select(.held)] | length),
                  items: .};
    {schema: 1, last_check: $now,
     last_success: (if $status == "ok" then $now elif $pls == "" then null else $pls end),
     status: $status, error: $error,
     backends: {dnf: ($dnf | wrap(true)), flatpak: ($fp | wrap($fpe))},
     actionable: (($dnf + $fp) | [.[] | select(.held|not)] | length),
     held_total: (($dnf + $fp) | [.[] | select(.held)] | length),
     risky_pending: $risky}'
}

# Must survive a corrupt state file: a truncated/garbage/wrong-shaped state.json used to reach
# --argjson as invalid JSON (or a string), killing the whole check with jq rc 2/5 - the one
# moment the fallback exists for. Every bad shape degrades to [].
state_prev_items() {  # backend → previous items array; [] for missing/corrupt/wrong-shaped state
  local out
  out="$(jq -c -n --arg b "$1" '[inputs][0].backends[$b].items? // []
                                 | if type=="array" then . else [] end' "$STATE_FILE" 2>/dev/null)"
  [[ "$out" == \[* ]] && printf '%s\n' "$out" || echo '[]'
}

write_state() { atomic_write "$STATE_FILE"; }   # per-process mktemp: overlapping checks (timer + event watch + post-run) must never collide

maybe_refresh_metadata() {  # ≤ every 3h, AC power, unmetered; never blocks check on failure
  [[ -n "${UPKEEP_SKIP_REFRESH:-}" ]] && return 0
  local last=0 now; now="$(date +%s)"
  # `|| echo 0` covers the TOCTOU gap: the file can vanish between the -f test and the stat
  # (state dir cleanup, another process), and a bare failing stat escapes errexit here.
  [[ -f "$LAST_REFRESH_FILE" ]] && last="$(stat -c %Y "$LAST_REFRESH_FILE" || echo 0)"
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

# --- update lock (our own concurrency; foreign rpm lock handled by retry in cmd_update) ---
# A lockfile whose PID is dead is stale and gets cleared: a lock nobody owns froze restic's
# retention for 8 days while the backups still reported healthy. Never inherit that failure.
acquire_lock() {
  upkeep_init_dirs
  if [[ -f "$LOCK_FILE" ]] && kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then return 1; fi
  [[ -f "$LOCK_FILE" ]] && echo "note: clearing stale upkeep lock" >&2
  echo $$ > "$LOCK_FILE"
}
release_lock() { rm -f "$LOCK_FILE"; }

# --- human summary of one history entry (same renderer for the terminal, the popup and the
# notification body: one truth, rendered once) ---
render_summary() {  # history-json-file → human text
  jq -r '
    def newest(v): v | split(",") | last;   # installonly sets stay truthful in JSON; humans see newest → newest
    def lines(b): b.updated | map("  " + .name + " " + newest(.from) + " → " + newest(.to)) | join("\n");
    def heldline: [.backends[].skipped_held[]] | if length == 0 then empty
                  else "Held (skipped): " + join(", ") end;
    "Upkeep - " + .timestamp + " (" + .surface + ", " + (.duration_sec|tostring) + "s) "
      + (if .status == "ok" then "✓" else "FAILED - see " + .log end),
    "System (dnf): " + (.backends.dnf.updated|length|tostring) + " updated"
      + (if .backends.dnf.status != "ok" then " [" + .backends.dnf.status + "]" else "" end),
    (if (.backends.dnf.updated|length) > 0 then lines(.backends.dnf) else empty end),
    "Apps (flatpak): " + (.backends.flatpak.updated|length|tostring) + " updated"
      + (if .backends.flatpak.status != "ok" then " [" + .backends.flatpak.status + "]" else "" end),
    (if (.backends.flatpak.updated|length) > 0 then lines(.backends.flatpak) else empty end),
    heldline,
    "Reboot: " + (if .reboot_needed then "needed" else "not needed" end)
  ' "$1"
}
