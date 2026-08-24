#!/usr/bin/env bash
# Upkeep shared library. Pure helpers + path setup. Sourced by bin/upkeep, backends, tests.
set -euo pipefail
export LC_ALL=C

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

config_get() {  # key default
  local v
  v="$(grep -s "^$1=" "$CONFIG_FILE" | tail -1 | cut -d= -f2- || true)"
  printf '%s\n' "${v:-$2}"
}

config_set() {  # key value
  upkeep_init_dirs
  touch "$CONFIG_FILE"
  grep -v "^$1=" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

priv_refresh() { ${UPKEEP_PKEXEC:+$UPKEEP_PKEXEC} "$UPKEEP_REFRESH_HELPER" "$@"; }
priv_apply()   { ${UPKEEP_PKEXEC:+$UPKEEP_PKEXEC} "$UPKEEP_APPLY_HELPER" "$@"; }
notify()       { "$UPKEEP_NOTIFY" "$@" >/dev/null 2>&1 || true; }
now_iso()      { date -Is; }

# --- holds: one "backend:name" per line ---
holds_all() { cat "$HOLDS_FILE" 2>/dev/null || true; }
holds_for() { holds_all | grep "^$1:" | cut -d: -f2- || true; }
hold_add() {  # backend name
  upkeep_init_dirs; touch "$HOLDS_FILE"
  grep -qxF "$1:$2" "$HOLDS_FILE" || printf '%s:%s\n' "$1" "$2" >> "$HOLDS_FILE"
}
hold_remove() {  # backend name
  [[ -f "$HOLDS_FILE" ]] || return 0
  grep -vxF "$1:$2" "$HOLDS_FILE" > "$HOLDS_FILE.tmp" || true
  mv "$HOLDS_FILE.tmp" "$HOLDS_FILE"
}
mark_held() {  # backend; stdin: JSON [{name,from,to}] → adds held:bool
  local holds_json
  holds_json="$(holds_for "$1" | jq -Rn '[inputs]')"
  # `.name as $n` is load-bearing: jq evaluates the argument of index() against index()'s own
  # input ($holds, an array), so an inline `index(.name)` dies with "Cannot index array".
  jq --argjson holds "$holds_json" '[.[] | .name as $n | . + {held: (($holds | index($n)) != null)}]'
}

# --- snapshot diff: before/after TSV (name\tversion, sorted by name) → report JSON ---
tsv_diff_updates() {  # before_file after_file
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
