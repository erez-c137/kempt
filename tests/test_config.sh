#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
KEMPT="$REPO_ROOT/bin/kempt"
kempt_init_dirs

assert_eq "$(config_get surface terminal)" "terminal" "default when unset"
config_set surface background
assert_eq "$(config_get surface terminal)" "background" "reads set value"
config_set surface offline
assert_eq "$(config_get surface terminal)" "offline" "overwrite same key"
assert_eq "$(grep -c '^surface=' "$KEMPT_CONFIG_DIR/config")" "1" "no duplicate keys"
config_set include_flatpak false
assert_eq "$(config_get include_flatpak true)" "false" "second key independent"
assert_eq "$(config_get surface terminal)" "offline" "setting a second key preserves the first"
assert_eq "$(config_get refresh_interval_min 60)" "60" "default numeric"

# Input validation: a key that could smuggle syntax, and a multi-line value that could inject
# a second key=value line into the config file, are both refused.
assert_exit 2 "config key validated" config_set 'auto.accept' x
assert_exit 2 "newline value rejected" config_set multi $'a\nb=c'
# The same key rule on the read side. The key is matched against the file, so a key that is not a
# key - `s.*` - used to match whatever line came first and print another setting's value.
assert_exit 2 "config get refuses a key that is not a key" config_get 's.*'
assert_eq "$(config_get 's.*' 2>/dev/null)" "" "...and prints no other setting's value"
assert_exit 2 "...and kempt config get says so with a usage error" "$REPO_ROOT/bin/kempt" config get 's.*'
# A rejected write must not have disturbed what was already stored.
assert_eq "$(config_get surface terminal)" "offline" "rejected writes leave surface intact"
assert_eq "$(config_get include_flatpak true)" "false" "rejected writes leave include_flatpak intact"
assert_eq "$(grep -c '' "$KEMPT_CONFIG_DIR/config")" "2" "rejected writes added no lines"

# --- restart_reminder: a default that must exist, or the reminder is silently off --------------
# The widget asks the CLI for this key and reads the answer with is_true(). A key with no entry in
# kempt_default answers with the EMPTY STRING, is_true reads that as false, and the restart
# reminder is off on every box whose config file has never named it - which is every box, since
# nothing writes a key until somebody changes it. That is the same silent-off bug the wiring table
# in docs/architecture.md describes for include_<backend>, so the default is asserted from BOTH
# ends: the table itself, and the config_get fallback a reader actually goes through.
assert_eq "$(kempt_default restart_reminder)" "true" "the defaults table knows restart_reminder"
assert_eq "$(config_get restart_reminder)" "true" \
  "an untouched restart_reminder reads as true, not as an empty string"
assert_eq "$(is_true "$(config_get restart_reminder)" && echo on || echo off)" "on" \
  "...and a reader that runs it through is_true gets the reminder ON"
config_set restart_reminder false
assert_eq "$(config_get restart_reminder)" "false" "turning the reminder off round-trips"
assert_eq "$(grep -c '^restart_reminder=' "$KEMPT_CONFIG_DIR/config")" "1" \
  "...as exactly one line, like every other key"
config_set restart_reminder true
assert_eq "$(config_get restart_reminder)" "true" "and back on again"

# --- config set says when it did not recognise what you wrote ------------------------------------
# A typo used to be stored in silence: `kempt config set surfce terminal` wrote a key nothing
# reads, and `kempt config set surface bogus` wrote a value nothing accepts, both under exit 0 with
# no output at all. The person then waited for behaviour that was never going to arrive.
#
# WARN, never refuse. An unknown key may be one a newer widget or a later Kempt knows, so the write
# still goes through and the status stays 0 - what changes is that it is no longer silent. These
# assertions are at the CLI, because that is the surface the warning belongs to: config_set itself
# stays quiet for the internal callers that go through it.
ERR="$TESTTMP/cfg-err"

rc=0; "$KEMPT" config set surfce terminal 2>"$ERR" >/dev/null || rc=$?
assert_eq "$rc" "0" "an unknown key is still stored, and is still a success"
assert_eq "$(config_get surfce)" "terminal" "...the value really is written"
grep -q "unknown setting 'surfce'" "$ERR" \
  && echo "ok: ...and the warning names the key that was not recognised" \
  || { echo "FAIL: no unknown-key warning"; _fail=1; sed 's/^/    /' "$ERR"; }
grep -q 'surface' "$ERR" \
  && echo "ok: ...and lists the settings Kempt does know, which is where the typo shows up" \
  || { echo "FAIL: the warning does not list the known settings"; _fail=1; sed 's/^/    /' "$ERR"; }

rc=0; "$KEMPT" config set surface bogus 2>"$ERR" >/dev/null || rc=$?
assert_eq "$rc" "0" "an invalid value for a known key is still stored, and still a success"
assert_eq "$(config_get surface)" "bogus" "...the value really is written"
grep -q "not a value surface accepts" "$ERR" \
  && echo "ok: ...and the warning names the key" \
  || { echo "FAIL: no invalid-value warning"; _fail=1; sed 's/^/    /' "$ERR"; }
for v in terminal popup background offline; do
  grep -q "$v" "$ERR" || { echo "FAIL: the warning does not offer $v"; _fail=1; }
done
echo "ok: ...and lists every value it does accept"

# The quiet cases. A warning on a correct write would train people to ignore the channel the two
# warnings above depend on.
assert_eq "$("$KEMPT" config set surface offline 2>&1 >/dev/null)" "" \
  "a value the key accepts says nothing"
assert_eq "$("$KEMPT" config set risky_regex '^foo' 2>&1 >/dev/null)" "" \
  "...and so does a known key with no fixed set of values"
# Booleans are deliberately not an enum: configuration.md says anything that is not true/1/yes is
# false, in as many words, and `auto_accept on` is the documented example of it.
assert_eq "$("$KEMPT" config set auto_accept on 2>&1 >/dev/null)" "" \
  "a boolean takes anything, as documented, so it is not warned about"
assert_eq "$("$KEMPT" config set widget_icon_size enormous 2>&1 >/dev/null)" "" \
  "...and widget_icon_size is validated by the widget, which is the half that can see the panel"

# hold and unhold stay silent, which is their own contract: they print nothing on success today and
# nothing here changes that.
assert_eq "$("$KEMPT" hold dnf:zsh 2>&1 >/dev/null)" "" "hold stays silent"
assert_eq "$("$KEMPT" unhold dnf:zsh 2>&1 >/dev/null)" "" "unhold stays silent"

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
kempt_init_dirs
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
# into every command that calls kempt_init_dirs).
rm -f "$HIST_DIR"/*.json
assert_exit 0 "pruning an empty history dir is not an error" -- kempt_init_dirs

# Orphan temp sweep: a crash between mktemp and mv leaks a .atomic.XXXXXX forever. atomic_write
# puts its temp NEXT TO the destination, so it is not only the state root that collects them -
# the offline-baseline rebase writes through snapshots/, one level down.
printf 'x' > "$KEMPT_STATE_DIR/.atomic.old"; touch -d '2 hours ago' "$KEMPT_STATE_DIR/.atomic.old"
printf 'x' > "$SNAP_DIR/.atomic.old";         touch -d '2 hours ago' "$SNAP_DIR/.atomic.old"
printf 'x' > "$SNAP_DIR/.atomic.fresh"
printf 'x' > "$SNAP_DIR/keep.tsv";            touch -d '2 hours ago' "$SNAP_DIR/keep.tsv"
kempt_init_dirs
assert_exit 0 "an aged orphan temp in the state dir is swept" -- test ! -e "$KEMPT_STATE_DIR/.atomic.old"
assert_exit 0 "...and one in snapshots/, where the rebase leaves them" -- test ! -e "$SNAP_DIR/.atomic.old"
assert_exit 0 "a fresh temp (a live concurrent writer's) is left alone" -- test -f "$SNAP_DIR/.atomic.fresh"
assert_exit 0 "the sweep only ever takes .atomic. files" -- test -f "$SNAP_DIR/keep.tsv"
rm -f "$SNAP_DIR/.atomic.fresh" "$SNAP_DIR/keep.tsv"
# The config directory collects them too: `hold`, `unhold` and `config set` all write through
# atomic_write there, so one killed mid-write leaves its temp next to the holds or config file.
printf 'x' > "$KEMPT_CONFIG_DIR/.atomic.old"; touch -d '2 hours ago' "$KEMPT_CONFIG_DIR/.atomic.old"
printf 'x' > "$KEMPT_CONFIG_DIR/.atomic.fresh"
kempt_init_dirs
assert_exit 0 "an aged orphan temp in the config dir is swept" -- test ! -e "$KEMPT_CONFIG_DIR/.atomic.old"
assert_exit 0 "...while a fresh one there is left alone" -- test -f "$KEMPT_CONFIG_DIR/.atomic.fresh"
assert_exit 0 "...and the config file itself is untouched" -- test -f "$KEMPT_CONFIG_DIR/config"
rm -f "$KEMPT_CONFIG_DIR/.atomic.fresh"
finish
