#!/usr/bin/env bash
# The three writers that touch the user's own two files, run against each other.
#
# What this is for. `config_set`, `hold_add` and `hold_remove` each read the whole file into a
# variable and then write the whole file back through `atomic_write`. Atomic means a reader never
# sees a half-written file; it does NOT mean two writers cannot lose each other's work, and they
# did. Every writer that read before the other one's rename saw the OLD file and wrote it back
# with only its own change on top - last rename wins, everything in between is gone.
#
# Measured on the unmodified code, 4 batches of 10 concurrent commands with `wait` between them:
# 40 `config set` left 4 of 40 keys (one per batch), and 40 `unhold` removed 4 of 40 holds. The
# widget queues its commands one at a time, so the reachable cases are two terminals, a script,
# or the CLI racing a widget write - and a lost hold is still a user's own decision going quiet.
#
# The batch size is the machine envelope, not a detail: 10 concurrent processes with `wait`
# between batches, so a suite run never fans out further than that.
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
KEMPT="$REPO_ROOT/bin/kempt"

# Where the writers' lock lives. Asserted rather than read from the library on purpose: it is a
# promise about WHERE Kempt writes (the state dir, never the user's config dir - docs/architecture.md
# "Where Kempt writes"), and a test that took the path from the code it is testing could not tell
# the difference between the two directories.
LOCK="$KEMPT_STATE_DIR/writer.lock"

# 40 commands, 10 at a time. `wait` with no arguments returns 0 whatever the children did, which
# is what this file wants: the claim is about the FILE the writers left behind, and a child that
# failed shows up there as a missing key rather than as an exit status.
batches_of_ten() {  # cmd... ; each invocation gets the counter 1..40 appended
  local batch i n
  for batch in 0 1 2 3; do
    for i in 1 2 3 4 5 6 7 8 9 10; do
      n=$(( batch * 10 + i ))
      "$@" "$n" &
    done
    wait
  done
}

# --- config set: every key survives ---------------------------------------------------------------
set_key() { "$KEMPT" config set "key$1" "v$1"; }
batches_of_ten set_key

assert_eq "$(wc -l < "$CONFIG_FILE")" "40" "40 concurrent config writes leave 40 lines"
assert_eq "$(cut -d= -f1 "$CONFIG_FILE" | sort -u | wc -l)" "40" "...40 distinct keys, none lost"
missing=""
for n in $(seq 1 40); do
  [[ "$(config_get "key$n")" == "v$n" ]] || missing="$missing key$n"
done
assert_eq "${missing# }" "" "...and every key carries the value its own writer wrote"

# The lock is a file in the STATE directory. The config directory is the user's - a `key=value`
# file they may edit by hand - and Kempt puts nothing else in it.
assert_exit 0 "the writers' lock file lives in the state directory" -- test -e "$LOCK"
assert_exit 1 "...and nothing new appears in the user's config directory" \
  -- test -e "$KEMPT_CONFIG_DIR/writer.lock"

# --- hold: an append is safe, a check-then-append is not ------------------------------------------
# `hold_add` greps before it appends, so two writers can both read "not there" and both append.
# The append itself never tore - a short `>>` write is one syscall - which is why the count alone
# would pass here and the DUPLICATE assertion is the one that binds.
add_hold() { "$KEMPT" hold "dnf:pkg$1"; }
batches_of_ten add_hold

assert_eq "$(wc -l < "$HOLDS_FILE")" "40" "40 concurrent holds leave 40 lines"
assert_eq "$(sort -u "$HOLDS_FILE" | wc -l)" "40" "...all 40 distinct, so nothing was held twice"

# A name the validation refuses is still refused under contention, and still with exit 2 - the
# status `kempt hold` promises and the widget reads. Nine writers are in flight while it runs, so
# the rejection happens with the lock contended rather than on a quiet file.
for i in 1 2 3 4 5 6 7 8 9; do "$KEMPT" hold "dnf:extra$i" & done
assert_exit 2 "a rejected hold name still exits 2 while other writers hold the lock" \
  -- "$KEMPT" hold 'dnf:*'
wait
grep -q '^dnf:\*$' "$HOLDS_FILE" \
  && { echo "FAIL: a refused name reached the holds file"; _fail=1; } \
  || echo "ok: ...and never reached the file"

# --- unhold: the removal that was losing 36 of 40 -------------------------------------------------
# The read-modify-write with the worst odds: every writer removes ONE line from the copy it read,
# so a writer that read before its neighbour's rename puts that neighbour's line back.
rm_hold() { "$KEMPT" unhold "dnf:pkg$1"; }
batches_of_ten rm_hold
for i in 1 2 3 4 5 6 7 8 9; do "$KEMPT" unhold "dnf:extra$i"; done

assert_eq "$(wc -c < "$HOLDS_FILE")" "0" "40 concurrent unholds leave the holds file empty"

# --- readers are not locked out -------------------------------------------------------------------
# The lock is for writers only. A reader takes no lock at all, so `kempt config get` answers while
# a writer is mid-write - which is what keeps the widget's 30-second poll and the settings page
# from blocking on each other. The write it might catch is atomic either way: `atomic_write`
# renames, so a reader sees the whole old file or the whole new one.
"$KEMPT" config set reader_probe held
exec 6>>"$LOCK"
flock 6
got="$(timeout 1 "$KEMPT" config get reader_probe)" || got="BLOCKED"
flock -u 6; exec 6>&-
assert_eq "$got" "held" "a reader answers within a second while a writer holds the lock"

# --- the event log: two writers against the trim --------------------------------------------------
# Two writers race the first line, then append 600 numbered lines each over a log one line short of
# its 2500 cap. A line appended between the trim's read and its rename would leave a gap.
EV="$KEMPT_STATE_DIR/events.log"
rm -f "$EV"
( for i in $(seq 1 50); do log_event "first A $i"; done ) &
( for i in $(seq 1 50); do log_event "first B $i"; done ) &
wait
assert_eq "$(grep -c ' first [AB] ' "$EV")" "100" "two writers creating the event log keep all 100 lines"
assert_eq "$(stat -c %a "$EV")" "600" "...and the log is 0600"
seq 1 2499 | sed 's/^/2026-01-01T00:00:00+00:00 cli filler /' > "$EV"
( for i in $(seq 1 600); do log_event "seq A $i"; done ) &
( for i in $(seq 1 600); do log_event "seq B $i"; done ) &
wait
suffix_ok() {  # writer → "ok" when its lines are 1..600 with only a prefix trimmed away
  grep -oE " seq $1 [0-9]+\$" "$EV" | awk '{ print $3 }' \
    | awk 'NR == 1 { p = $1; next } $1 != p + 1 { bad = 1 } { p = $1 } END { print (!bad && p == 600) ? "ok" : "gap" }'
}
assert_eq "$(suffix_ok A)|$(suffix_ok B)" "ok|ok" "two writers across the trim lose no line of either"
assert_eq "$(( $(wc -l < "$EV") <= 2500 ))" "1" "...and the log stays within its cap"
# The loop above rarely lands inside the trim's window, so this pins the mechanism: while
# events.lock is held, a line waits, and it lands once the lock is released.
before="$(wc -l < "$EV")"
exec 3>>"$KEMPT_STATE_DIR/events.lock"; flock 3
log_event "waited" &
sleep 1
held="$(wc -l < "$EV")"
flock -u 3; exec 3>&-
wait
assert_eq "$held|$(grep -c ' waited$' "$EV")" "$before|1" "a line waits for events.lock, then lands"

# --- the state file: a run's publish against write_state ------------------------------------------
# Writer A owns .seq and writes 1..300. Writer B republishes the stage the whole time. A stale
# write from B would put an older .seq back, which A sees before its next write.
offline_staged_state() { echo '{"count":1}'; }
offline_stage_blocked_state() { :; }
echo '{"seq":0}' > "$STATE_FILE"
( for i in $(seq 1 300); do
    [[ "$(jq -r .seq "$STATE_FILE")" == "$(( i - 1 ))" ]] || echo "stale before $i" >> "$TESTTMP/stale"
    jq -c -n --argjson i "$i" '{seq: $i, offline_staged: {count: 1}}' | write_state
  done; touch "$TESTTMP/a-done" ) &
( until [[ -e "$TESTTMP/a-done" ]]; do publish_staged_state; done ) &
wait
assert_eq "$(cat "$TESTTMP/stale" 2>/dev/null)" "" "a publish racing write_state never puts back an older state"
assert_eq "$(jq -c . "$STATE_FILE")" '{"seq":300,"offline_staged":{"count":1}}' "...and the last write stands"


# --- a lock that cannot be opened skips the lock, never the write ---------------------------------
# A directory stands in for a lock file that is mode 000, root-owned or otherwise unopenable.
rm -f "$KEMPT_STATE_DIR/state.lock" "$KEMPT_STATE_DIR/events.lock"
mkdir "$KEMPT_STATE_DIR/state.lock" "$KEMPT_STATE_DIR/events.lock"
rc=0; echo '{"seq":1}' | write_state || rc=$?
assert_eq "$rc|$(jq -c . "$STATE_FILE")" '0|{"seq":1}' "write_state writes when state.lock cannot be opened"
publish_staged_state
assert_eq "$(jq -c . "$STATE_FILE")" '{"seq":1,"offline_staged":{"count":1}}' "...and so does publish_staged_state"
log_event unopenable
assert_eq "$(tail -n 1 "$EV" | sed 's/^[^ ]* //')" "cli unopenable" "log_event appends when events.lock cannot be opened"
rc=0; echo '[1]' | write_state 2>/dev/null || rc=$?
assert_eq "$rc" "1" "write_state still returns the write's failure"
# With no lock to share, the trim runs anyway, so the log stays bounded.
for i in $(seq 1 2600); do echo "old $i"; done > "$EV"
log_event bounded
assert_eq "$(wc -l < "$EV")|$(tail -n 1 "$EV" | sed 's/^[^ ]* //')" "2000|cli bounded" \
  "a log whose lock cannot be opened is still trimmed"
rmdir "$KEMPT_STATE_DIR/state.lock" "$KEMPT_STATE_DIR/events.lock"

# Only publish_staged_state may tell write_state the lock is held. A value from the environment,
# under the old name or the new one, still waits for the lock.
exec 3>>"$KEMPT_STATE_DIR/state.lock"; flock 3
( sleep 2; flock -u 3 ) &
t0=$(date +%s%N)
echo '{"seq":2}' | STATE_LOCK_HELD=1 _KEMPT_STATE_LOCK_HELD=1 \
  bash -c 'source "$1/lib/common.sh"; write_state' _ "$REPO_ROOT"
t1=$(date +%s%N); wait; exec 3>&-
assert_eq "$(( (t1 - t0) / 1000000 >= 1500 ))|$(jq -c . "$STATE_FILE")" '1|{"seq":2}' \
  "an inherited lock-held flag does not skip state.lock"

finish
