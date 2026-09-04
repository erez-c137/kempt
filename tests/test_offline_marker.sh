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
source "$REPO_ROOT/lib/common.sh"
{ printf '{"staged_at":"2026-09-05T01:00:00+03:00","pre_snapshot":"/x.tsv","boot_id":"b",'
  touch "$TESTTMP/writing"
  sleep 2
  printf '"staged":2,"armed":true}\n'; } | write_offline_marker
EOF
chmod +x "$TESTTMP/slow-writer"
"$TESTTMP/slow-writer" & wpid=$!
# Wait for the EVENT, never a fixed interval: the touch is the writer saying it has started and
# has not finished, which is the only moment this assertion means anything.
for _ in $(seq 1 200); do [[ -e "$TESTTMP/writing" ]] && break; sleep 0.02; done
assert_exit 0 "the slow writer really got going" -- test -e "$TESTTMP/writing"
assert_eq "$(cat "$marker")" "$old" \
  "a marker being rewritten is never observable half-written"
{ kill -9 "$wpid"; wait "$wpid" || true; } 2>/dev/null
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

finish
