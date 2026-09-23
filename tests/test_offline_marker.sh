#!/usr/bin/env bash
# The offline marker as a FILE: how it is written, and what every reader does with a damaged one.
#
# The marker is the one state file two commands write and read on different locks - `kempt update`
# stages it, `kempt check` harvests it - and it names the packages a restart is about to install.
# Two consequences, and this file pins both:
#
#   the write. It used to be a bare `>` redirect at default umask: world-readable, and truncated
#   from the first instant of the write, so any check that read it in that window saw an empty
#   file where a promise used to be.
#
#   the read. An empty or unparsable marker used to reach the harvest's stale-pointer branch,
#   which DELETES the marker - so one torn read made Kempt disown an armed transaction that was
#   sitting there perfectly staged, and the popup stopped mentioning the restart that was still
#   going to install 83 packages.
#
# The rule the readers follow now: a marker that cannot be trusted is skipped. Not cleared, not
# guessed at, not announced. Clearing stays what it always was - a marker that PARSES, over a
# transaction dnf5 says is gone.
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"

export WORLD="$TESTTMP/world"; mkdir -p "$WORLD"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
exit 0
STUB
chmod +x "$TESTTMP/apply-stub"
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"
chmod +x "$TESTTMP/dnf-reboot-no"
export KEMPT_APPLY_HELPER="$TESTTMP/apply-stub"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
export KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no"
export KEMPT_SKIP_REFRESH=1
"$KEMPT" config set include_flatpak false >/dev/null

marker="$KEMPT_STATE_DIR/offline_staged.json"

# --- the write --------------------------------------------------------------------------------
# 0600 asserted on the marker a REAL stage wrote, not on a helper called in isolation: the mode is
# a property of the write site, and a helper that lands 0600 while cmd_update keeps its own
# redirect would leave the box exactly as exposed as before.
"$KEMPT" update --surface=offline --no-flatpak >/dev/null
assert_exit 0 "the offline stage wrote a marker" -- test -f "$marker"
assert_eq "$(stat -c %a "$marker")" "600" \
  "the marker a stage writes is 0600 - it is a per-box list of what is pending, like state.json and events.log"
# The temp atomic_write renames from lives NEXT TO the destination, so a write that completed
# leaves nothing behind. A leftover here is either a crash or a write that never went through it.
assert_eq "$(find "$KEMPT_STATE_DIR" -maxdepth 1 -name '.atomic.*' | wc -l)" "0" \
  "...and the write left no temp behind"

# The writer on its own, which is also what stops the mid-write assertion below from passing for
# the wrong reason: a helper that is not there writes nothing, and a marker nobody touched is
# trivially not half-written.
old='{"staged_at":"2026-09-05T00:00:00+03:00","pre_snapshot":"/x.tsv","boot_id":"b","staged":1,"armed":true}'
new='{"staged_at":"2026-09-05T01:00:00+03:00","pre_snapshot":"/x.tsv","boot_id":"b","staged":2,"armed":true}'
write_marker() { bash -c 'source "$1/lib/common.sh"; write_offline_marker' _ "$REPO_ROOT"; }
printf '%s\n' "$old" > "$marker"
printf '%s\n' "$new" | write_marker
assert_eq "$(cat "$marker")" "$new" "the writer replaces the marker whole"
assert_eq "$(stat -c %a "$marker")" "600" "...and lands 0600 over a marker that was not"

# The one property a rename buys and a redirect cannot: there is no instant at which a reader sees
# the destination half-written. A `>` redirect truncates at OPEN, before the first byte of the new
# content exists, so the whole of the producer's runtime is a window where the marker is empty.
printf '%s\n' "$old" > "$marker"
cat > "$TESTTMP/slow-writer" <<EOF
#!/usr/bin/env bash
# set -m puts the pipeline in a process group of its own so the test can kill BOTH halves of it.
# Killing this script alone left the pipeline running: it finished its write about two seconds
# later, either into a sandbox the assertions below had already moved past (the marker came back
# underneath them - the intermittent failure that never reproduced) or into one the EXIT trap had
# already removed (the stray "mv: cannot stat .../.atomic.*" that surfaced in the NEXT file's
# output and looked like it came from somewhere else).
set -m
source "$REPO_ROOT/lib/common.sh"
{ printf '{"staged_at":"2026-09-05T01:00:00+03:00","pre_snapshot":"/x.tsv","boot_id":"b",'
  touch "$TESTTMP/writing"
  sleep 2
  printf '"staged":2,"armed":true}\n'; } | write_offline_marker &
jobs -p > "$TESTTMP/writer-pgid"
wait
EOF
chmod +x "$TESTTMP/slow-writer"
"$TESTTMP/slow-writer" & wpid=$!
# Wait for the EVENT, never a fixed interval: the touch is the writer saying it has started and
# has not finished, which is the only moment this assertion means anything.
# Both files: the pgid is what the kill below needs, and it is written by a different process
# than the one that touches "writing".
for _ in $(seq 1 200); do
  [[ -e "$TESTTMP/writing" && -s "$TESTTMP/writer-pgid" ]] && break; sleep 0.02
done
assert_exit 0 "the slow writer really got going" -- test -e "$TESTTMP/writing"
assert_eq "$(cat "$marker")" "$old" \
  "a marker being rewritten is never observable half-written"
{ kill -9 -- -"$(cat "$TESTTMP/writer-pgid")" || true
  kill -9 "$wpid"; wait "$wpid" || true; } 2>/dev/null
after="$(cat "$marker")"
if [[ "$after" == "$old" ]]; then
  echo "ok: a writer killed mid-write leaves the marker it found, never a truncated one"
elif jq -e 'type == "object" and has("armed")' <<<"$after" >/dev/null 2>&1; then
  echo "ok: a writer killed mid-write leaves the whole new marker, never a truncated one"
else
  echo "FAIL: the marker was left truncated: $after"; _fail=1
fi

# --- the read ---------------------------------------------------------------------------------
# Three ways a marker arrives unreadable, and one rule for all three: skip it. The check must go on
# saying exactly what it says with no marker at all - no key in the state, no event, and above all
# no deletion.
export KEMPT_BOOT_ID="boot-marker"
export KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml"
st="$KEMPT_STATE_DIR/state.json"
events_cleared() {  # → how many times a check has said it threw a marker away
  grep -cE 'offline marker cleared|harvest cleared stale marker' "$KEMPT_STATE_DIR/events.log" 2>/dev/null || true
}
# The state as a comparison subject: the two timestamps move on every run and nothing else may.
state_shape() { jq -Sc 'del(.last_check, .last_success)' "$st"; }

rm -f "$marker"
"$KEMPT" check >/dev/null
baseline="$(state_shape)"
cleared_before="$(events_cleared)"

# EMPTY. A zero-length marker is what an interrupted `>` redirect leaves, which is the bug this
# whole file is about: the reader that finds one is looking at a write in progress, not at a stage
# that has gone.
: > "$marker"
"$KEMPT" check >/dev/null
assert_exit 0 "an empty marker is left alone, not deleted" -- test -f "$marker"
assert_eq "$(events_cleared)" "$cleared_before" "...and nothing is recorded about clearing it"
assert_eq "$(jq -r '.offline_staged // "absent"' "$st")" "absent" "...and nothing is published about it"
assert_eq "$(state_shape)" "$baseline" "...and the check answers exactly as it does with no marker"

# GARBAGE. A truncated JSON object, a half-flushed page, anything at all: it parses as nothing, so
# it says nothing.
printf '{"staged_at":"2026-09-05T00:00:00+03:0' > "$marker"
"$KEMPT" check >/dev/null
assert_exit 0 "an unparsable marker is left alone, not deleted" -- test -f "$marker"
assert_eq "$(events_cleared)" "$cleared_before" "...and nothing is recorded about clearing it"
assert_eq "$(jq -r '.offline_staged // "absent"' "$st")" "absent" "...and nothing is published about it"
assert_eq "$(state_shape)" "$baseline" "...and the check answers exactly as it does with no marker"

# OVERSIZED, and otherwise perfect: valid JSON, this boot, an armed transaction under it. Size
# alone is the refusal, because a marker that has grown past a megabyte is not a marker any version
# of Kempt wrote, and a reader that parses it anyway is a reader that can be handed anything.
{ printf '{"staged_at":"2026-09-05T00:00:00+03:00","pre_snapshot":"/x.tsv","boot_id":"boot-marker","staged":61,"armed":true,"pad":"'
  head -c 1100000 /dev/zero | tr '\0' 'a'
  printf '"}\n'; } > "$marker"
assert_exit 0 "the oversized fixture really is valid JSON" -- jq -e . "$marker"
"$KEMPT" check >/dev/null
assert_exit 0 "a marker over 1 MB is left alone, not deleted" -- test -f "$marker"
assert_eq "$(events_cleared)" "$cleared_before" "...and nothing is recorded about clearing it"
assert_eq "$(jq -r '.offline_staged // "absent"' "$st")" "absent" \
  "...and a marker too big to trust publishes no pending install"
assert_eq "$(state_shape)" "$baseline" "...and the check answers exactly as it does with no marker"

# The control, and the reason none of the above passes by accident: a marker that IS readable still
# publishes, and a marker over a transaction that is gone is still cleared. The tolerance is a
# tolerance, not a new refusal to ever act.
jq -n --arg boot boot-marker '{staged_at:"2026-09-05T00:00:00+03:00", pre_snapshot:"/x.tsv",
                               boot_id:$boot, staged:61, armed:true}' > "$marker"
"$KEMPT" check >/dev/null
assert_eq "$(jq -r '.offline_staged.count' "$st")" "61" "a readable marker is published as it always was"
KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml" "$KEMPT" check >/dev/null
assert_exit 0 "...and a readable marker whose transaction is gone is still cleared" -- test ! -f "$marker"
assert_eq "$(events_cleared)" "$(( cleared_before + 1 ))" "...and the clearing is still recorded"

# --- the marker's version -------------------------------------------------------------------------
# One integer saying which shape this marker is, in place of working it out from which of several
# fields happen to be present. It is written where a marker is BORN and nowhere else: the additive
# updates (armed, replaced, set_moved) carry forward whatever was already there, so a marker from an
# older build is never stamped with a version whose fields it does not actually have.
export KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml"
rm -f "$marker"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
assert_exit 0 "the version fixture starts from a real stage" -- test -f "$marker"
assert_eq "$(jq -r '.version' "$marker")" "1" "a stage stamps the marker with its version"
assert_eq "$(jq -r '.version | type' "$marker")" "number" "...as an integer, not a string"
# The fields it vouches for are still all there: a version is an addition, not a replacement.
assert_eq "$(jq -r 'has("staged_at") and has("boot_id") and has("armed")' "$marker")" "true" \
  "...beside everything the marker already recorded"

# A marker written before the field existed must behave EXACTLY as it did. Read, published, and
# never quietly stamped with a version whose shape it cannot vouch for - the per-field fallbacks
# are what read it, and a version would tell them not to.
jq -n --arg boot boot-marker '{staged_at:"2026-09-05T00:00:00+03:00", pre_snapshot:"/x.tsv",
                               boot_id:$boot, staged:61, armed:true}' > "$marker"
"$KEMPT" check >/dev/null
assert_eq "$(jq -r '.offline_staged.count' "$st")" "61" \
  "a marker with no version is published exactly as before"
assert_eq "$(jq -r 'has("version")' "$marker")" "false" \
  "...and is not stamped with a version it cannot vouch for"

# --- publish_staged_state: the staged fact, without a check -------------------------------------
# A check is where offline_staged is normally computed, and on a real box its dnf half takes tens
# of seconds. A run that has just staged a transaction knows the answer already, and until it says
# so every surface is still offering to stage what is downloaded and armed. These call the function
# DIRECTLY: what it does to a state file is the whole of its contract, and test_update.sh proves
# separately that a run reaches it before the check behind it.
publish() { bash -c 'source "$1/lib/common.sh"; publish_staged_state' _ "$REPO_ROOT"; }

# Sets. The marker is the armed one written just above, and the count comes from it rather than
# from anything this function decides for itself.
jq -n --arg boot boot-marker '{staged_at:"2026-09-05T00:00:00+03:00", pre_snapshot:"/x.tsv",
                               boot_id:$boot, staged:61, armed:true}' > "$marker"
jq -n '{schema:1, last_check:"2026-01-01T00:00:00+00:00", actionable:19}' > "$st"
publish
assert_eq "$(jq -r '.offline_staged.count' "$st")" "61" \
  "the staged transaction reaches the state file without a check"
assert_eq "$(jq -r '.offline_staged.armed' "$st")" "true" "...described as armed, which it is"
# The other keys are somebody else's answers. Re-dating them here would put a fresh timestamp on
# counts nobody re-read, which is a worse lie than the silence being fixed.
assert_eq "$(jq -r '.last_check' "$st")" "2026-01-01T00:00:00+00:00" \
  "...and nothing else in the state is touched"
assert_eq "$(jq -r '.actionable' "$st")" "19" "...including the counts it did not re-read"
assert_eq "$(stat -c %a "$st")" "600" "...landing 0600 like every other state write"

# Clears. This is the half a live run needs: reconcile_stage_after_live_run discards a stage its
# own install superseded, and a state file still promising one leaves the popup offering a restart
# that would install nothing.
rm -f "$marker"
publish
assert_eq "$(jq -r 'has("offline_staged")' "$st")" "false" \
  "with no stage left, the promise of one is taken back out of the state"
assert_eq "$(jq -r '.actionable' "$st")" "19" "...without disturbing the rest of it"

# A state file that is not there is a box that has never checked: there is nothing to keep
# consistent, and nothing is created. A run must never be the thing that invents a state file.
rm -f "$st"
publish
assert_exit 0 "no state file means nothing to publish into, not a state file to invent" -- test ! -f "$st"

# Corrupt, and the house guard for it - `[inputs][0] | select(type == "object")`, the same two
# steps every other reader of this file takes. A state file holding TWO documents is valid input to
# jq, so the plain form would write both back and the widget's JSON.parse would keep throwing on
# the second; this takes the first document, which is the one every reader already answers from,
# and writes it back alone. Repairing the file is a side effect worth having rather than a loss.
jq -n --arg boot b '{staged_at:"2026-09-05T00:00:00+03:00", boot_id:$boot, staged:2, armed:true}' > "$marker"
printf '%s\n%s\n' '{"schema":1,"actionable":5}' '{"schema":1,"actionable":9}' > "$st"
publish
assert_eq "$(jq -s 'length' "$st")" "1" "a two-document state file comes back as one document"
assert_eq "$(jq -r '.actionable' "$st")" "5" \
  "...the first, which is the one every other reader answers from"
assert_eq "$(jq -r '.offline_staged.count' "$st")" "2" "...carrying the stage that was published"
# ...and what has no first document to take is left exactly as it was, for the check behind this
# one to rewrite properly. Nothing here may turn a corrupt state file into a plausible-looking one.
printf 'not json at all\n' > "$st"
publish
assert_eq "$(cat "$st")" "not json at all" "a state file that is not JSON is left untouched"
printf '%s\n' '["not","an","object"]' > "$st"
publish
assert_eq "$(cat "$st")" '["not","an","object"]' "...and so is one whose document is not an object"

finish
