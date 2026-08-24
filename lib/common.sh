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
