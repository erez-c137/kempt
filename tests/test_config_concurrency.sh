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
# surfaces that reach these are the settings page (a tick per key, dispatched together) and the
# widget's hold buttons, so the loss is a user's own clicks going quiet.
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

finish
