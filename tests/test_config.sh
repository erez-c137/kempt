#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
upkeep_init_dirs

assert_eq "$(config_get surface terminal)" "terminal" "default when unset"
config_set surface background
assert_eq "$(config_get surface terminal)" "background" "reads set value"
config_set surface offline
assert_eq "$(config_get surface terminal)" "offline" "overwrite same key"
assert_eq "$(grep -c '^surface=' "$UPKEEP_CONFIG_DIR/config")" "1" "no duplicate keys"
config_set include_flatpak false
assert_eq "$(config_get include_flatpak true)" "false" "second key independent"
assert_eq "$(config_get surface terminal)" "offline" "setting a second key preserves the first"
assert_eq "$(config_get refresh_interval_min 60)" "60" "default numeric"

# Input validation: a key that could smuggle syntax, and a multi-line value that could inject
# a second key=value line into the config file, are both refused.
assert_exit 2 "config key validated" config_set 'auto.accept' x
assert_exit 2 "newline value rejected" config_set multi $'a\nb=c'
# A rejected write must not have disturbed what was already stored.
assert_eq "$(config_get surface terminal)" "offline" "rejected writes leave surface intact"
assert_eq "$(config_get include_flatpak true)" "false" "rejected writes leave include_flatpak intact"
assert_eq "$(grep -c '' "$UPKEEP_CONFIG_DIR/config")" "2" "rejected writes added no lines"

# --- retention. History and logs grow forever otherwise, and the widget triggers a run on a
# timer: one entry plus one log per run, on a box that never gets tidied by hand.
# 55 entries with distinct mtimes, oldest first, so "newest 50" is a claim the test can check.
now="$(date +%s)"
for i in $(seq 1 55); do
  f="$HIST_DIR/$(printf '20260101T0000%02d' "$i").json"
  printf '{}' > "$f"
  touch -d "@$(( now - 10000 + i * 60 ))" "$f"
done
printf 'x' > "$LOG_DIR/old.log";    touch -d '61 days ago' "$LOG_DIR/old.log"
printf 'x' > "$LOG_DIR/recent.log"; touch -d '59 days ago' "$LOG_DIR/recent.log"
printf 'x' > "$LOG_DIR/keep.txt";   touch -d '400 days ago' "$LOG_DIR/keep.txt"
upkeep_init_dirs
assert_eq "$(ls -1 "$HIST_DIR"/*.json | wc -l)" "50" "retention keeps the newest 50 history entries"
assert_exit 0 "the newest entry survives" -- test -f "$HIST_DIR/20260101T000055.json"
assert_exit 0 "the 50th-newest survives" -- test -f "$HIST_DIR/20260101T000006.json"
assert_exit 0 "the 51st-newest is dropped" -- test ! -f "$HIST_DIR/20260101T000005.json"
assert_exit 0 "the oldest is dropped" -- test ! -f "$HIST_DIR/20260101T000001.json"
assert_exit 0 "a 61-day-old log is dropped" -- test ! -f "$LOG_DIR/old.log"
assert_exit 0 "a 59-day-old log is kept" -- test -f "$LOG_DIR/recent.log"
assert_exit 0 "retention only ever deletes its own file types" -- test -f "$LOG_DIR/keep.txt"
# An empty history dir is the normal state on a fresh install: the sweep must not turn "nothing
# to prune" into a failure (ls exits 2 on no match, and pipefail would carry that all the way up
# into every command that calls upkeep_init_dirs).
rm -f "$HIST_DIR"/*.json
assert_exit 0 "pruning an empty history dir is not an error" -- upkeep_init_dirs
finish
