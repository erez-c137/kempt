#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"

# Fake world: apply-stub "upgrades" by swapping which snapshot the installed-cmd serves.
export WORLD="$TESTTMP/world"; mkdir -p "$WORLD"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
cp "$FIXTURES/flatpak-list.tsv" "$WORLD/fp.tsv"
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
case "\$1" in
  dnf-upgrade)     cp "$FIXTURES/snap-after.tsv" "$WORLD/rpm.tsv" ;;
  dnf-offline-stage) touch "$WORLD/staged" ;;
esac
exit 0
STUB
chmod +x "$TESTTMP/apply-stub"
cp "$TESTTMP/apply-stub" "$TESTTMP/apply-stub.orig"   # probes that swap it restore from here
# The flatpak half of a run no longer goes through the root helper, so it gets its own stand-in on
# its own seam (there are no flatpak changes in this fake world; it only records). It writes to the
# SAME apply-calls file under a prefix of its own, so every "nothing was applied" assertion below
# still covers both backends while no assertion can confuse the two paths: an APPLY line proves
# the privileged helper ran, a FLATPAK line proves the unprivileged seam did.
cat > "$TESTTMP/fp-update-stub" <<STUB
#!/usr/bin/env bash
echo "FLATPAK \$@" >> "$WORLD/apply-calls"
exit 0
STUB
chmod +x "$TESTTMP/fp-update-stub"
cp "$TESTTMP/fp-update-stub" "$TESTTMP/fp-update-stub.orig"
# Records what WOULD have been escalated and then runs it anyway (sandbox() leaves KEMPT_PKEXEC
# empty). It is what lets the privilege-boundary assertion below be a real negative instead of a
# reading of the source.
cat > "$TESTTMP/pkexec-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TESTTMP/pkexec-calls"
exec "\$@"
STUB
chmod +x "$TESTTMP/pkexec-stub"
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub"
# Both halves of a run recorded into ONE file, which is the only way to assert their ORDER: the
# offline surface has to ask what is pending BEFORE it stages, and two separate recorders can never
# say which came first. Used for that one probe and nowhere else - the apply-calls file the rest of
# this file reads is a proxy for "the apply has run", and a refresh line in it would break every
# assertion that leans on that.
cat > "$TESTTMP/refresh-timeline" <<STUB
#!/usr/bin/env bash
echo "REFRESH \$@" >> "$WORLD/timeline"
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-timeline"
cat > "$TESTTMP/apply-timeline" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/timeline"
exit 0
STUB
chmod +x "$TESTTMP/apply-timeline"
# The same refresh helper with its check verb broken and nothing else changed: the count an offline
# stage asks for has to be losable without the stage itself becoming unavailable.
cat > "$TESTTMP/refresh-stub.checkfails" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { echo "Failed to download metadata for repo 'fedora'" >&2; exit 1; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub.checkfails"
cat > "$TESTTMP/notify-stub" <<STUB
#!/usr/bin/env bash
echo "NOTIFY \$@" >> "$WORLD/notifications"
STUB
chmod +x "$TESTTMP/notify-stub"
export KEMPT_APPLY_HELPER="$TESTTMP/apply-stub"
export KEMPT_FLATPAK_UPDATE_CMD="$TESTTMP/fp-update-stub"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_NOTIFY="$TESTTMP/notify-stub"
export KEMPT_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export KEMPT_FLATPAK_LIST_CMD="cat $WORLD/fp.tsv"
export KEMPT_SKIP_REFRESH=1
# The reboot check is the backend's (dnf_reboot_needed), so it is stubbed through the backend's
# own seam: KEMPT_DNF_CMD. "Reboot needed" is rc 1 PLUS the package list on stdout - rc 1 with an
# empty stdout is how the real command reports that it could not answer, and answers false.
write_reboot_stub "$TESTTMP/dnf-reboot-yes"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"
chmod +x "$TESTTMP/dnf-reboot-no"
export KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-yes"

# A staged transaction can only be applied by a REBOOT, and the marker records the boot session
# it was staged in. Nothing else in a test can change /proc, so "the machine rebooted" is
# simulated by rewriting that field - which is exactly what the harvest gates on.
simulate_reboot() {
  local m="$KEMPT_STATE_DIR/offline_staged.json"
  [[ -f "$m" ]] || return 0
  jq '.boot_id = "00000000-0000-0000-0000-000000000000"' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
}

# History filenames are per-second, and $ts comes from `date` INSIDE cmd_update/harvest_offline -
# so a test can never choose the name the NEXT run will write. The `sleep 1`s that used to sit at
# every call site below were only ever buying the other half of that: no entry ALREADY ON DISK
# sitting on the second the next run is about to use. Moving the written entries is free, so this
# does that instead, and the suite stops paying a second per collision.
# Renames rather than `touch -d`: the collision is on the FILENAME. mtime only drives the
# 50-entry prune in kempt_init_dirs, which nothing here is near.
# Five minutes back, one distinct second per entry, and the -offline suffix the harvest's
# collision guard appends is preserved. Nothing in this file writes an entry that old, so the new
# names cannot collide with a surviving one either.
# The one case this CANNOT cover is two consecutive cmd_update runs that must land on different
# seconds themselves - see the surviving sleep at the double-staging probe.
push_history_back() {
  local f base cutoff now n=0
  now="$(date +%s)"
  cutoff="$(date -d "@$(( now - 1 ))" +%Y%m%dT%H%M%S)"
  for f in "$KEMPT_STATE_DIR"/history/*.json; do
    [[ -e "$f" ]] || continue        # no nullglob here: an empty history dir yields the pattern itself
    base="$(basename "$f")"
    if [[ "${base:0:15}" < "$cutoff" ]]; then continue; fi
    mv -f "$f" "$KEMPT_STATE_DIR/history/$(date -d "@$(( now - 300 - n ))" +%Y%m%dT%H%M%S)${base:15}"
    n=$(( n + 1 ))
  done
}

"$KEMPT" config set surface background
"$KEMPT" hold dnf:vim-common

out="$("$KEMPT" update)"
hist="$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
h="$KEMPT_STATE_DIR/history/$hist"
assert_eq "$(jq -r .status "$h")" "ok" "history status ok"
assert_eq "$(jq '.backends.dnf.updated | length' "$h")" "2" "dnf updated from snapshot diff"
assert_eq "$(jq -r '.backends.dnf.skipped_held[0]' "$h")" "vim-common" "held pkg recorded as skipped"
assert_eq "$(jq -r .reboot_needed "$h")" "true" "reboot flag captured"
grep -q -- '--exclude=vim-common' "$WORLD/apply-calls" && echo "ok: hold became --exclude" || { echo "FAIL: exclude"; _fail=1; }
grep -q '^FLATPAK' "$WORLD/apply-calls" && echo "ok: flatpak ran" || { echo "FAIL: flatpak"; _fail=1; }
grep -q NOTIFY "$WORLD/notifications" && echo "ok: non-terminal surface notified" || { echo "FAIL: notify"; _fail=1; }

# --- the privilege boundary of a run, asserted rather than read off the source. `flatpak update`
# asks for no password of its own in an active local session (app-update and runtime-update are
# allow_active=yes in the policy flatpak ships), so routing it through kempt-apply put it behind
# auth_admin_keep and made a flatpak-only run prompt where plain `flatpak update` would not. dnf
# still escalates, because dnf5 genuinely needs root.
: > "$WORLD/apply-calls"; : > "$TESTTMP/pkexec-calls"
KEMPT_PKEXEC="$TESTTMP/pkexec-stub" "$KEMPT" update >/dev/null
# Both guards against a vacuous pass: an empty recorder would satisfy the count below while
# proving nothing, and a flatpak half that never ran would too.
assert_exit 0 "the pkexec recorder really was in the path" -- test -s "$TESTTMP/pkexec-calls"
grep -q '^FLATPAK' "$WORLD/apply-calls" && echo "ok: ...on a run whose flatpak half really ran" \
  || { echo "FAIL: flatpak half never ran"; _fail=1; }
assert_eq "$(grep -c flatpak "$TESTTMP/pkexec-calls" || true)" "0" \
  "applying flatpak updates never goes through pkexec"
assert_eq "$(grep -c 'dnf-upgrade' "$TESTTMP/pkexec-calls" || true)" "1" \
  "...while the dnf upgrade still does"

# A CLI-only user must not be left staring at a pending list the run already emptied: the run
# refreshes the state itself instead of waiting for the widget to come along and do it.
assert_exit 0 "update self-refreshes the state" -- test -f "$KEMPT_STATE_DIR/state.json"
assert_eq "$(jq '.backends.dnf.items | length' "$KEMPT_STATE_DIR/state.json")" "7" \
  "the state written after the run comes from a fresh check"

# --- truthful counts: a transaction that only installs and removes changed the system just as
# much as one that upgrades. "0 packages updated" would be a lie the user can act wrongly on.
printf 'bash\t5.2.37-1.fc44\nzsh\t5.9-11.fc44\n'    > "$TESTTMP/ar-before.tsv"
printf 'bash\t5.2.37-1.fc44\nnewpkg\t1.0-1.fc44\n'  > "$TESTTMP/ar-after.tsv"
cp "$TESTTMP/ar-before.tsv" "$WORLD/rpm.tsv"
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
cp "$TESTTMP/ar-after.tsv" "$WORLD/rpm.tsv"
exit 0
STUB
: > "$WORLD/notifications"
arout="$("$KEMPT" update --no-flatpak)"
grep -q 'System (dnf): 0 updated, +1 installed, -1 removed' <<<"$arout" \
  && echo "ok: summary counts installs and removals" || { echo "FAIL: summary counts - got: $arout"; _fail=1; }
grep -qE '0 (packages )?updated|no package changes' "$WORLD/notifications" \
  && { echo "FAIL: notification claimed nothing happened"; _fail=1; } || echo "ok: notification never claims nothing happened"
grep -q '+1 installed' "$WORLD/notifications" && echo "ok: notification counts installs" || { echo "FAIL: notify installs"; _fail=1; }
grep -q '\-1 removed' "$WORLD/notifications" && echo "ok: notification counts removals" || { echo "FAIL: notify removals"; _fail=1; }
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"   # back to the main fake world
cp "$FIXTURES/snap-after.tsv" "$WORLD/rpm.tsv"

# A flatpak hold switches the whole backend to PER-APP updates, and that list is pre-filtered to
# apps that are actually installed: com.example.NotInstalled is pending in the remote fixture but
# absent from the installed list. That pre-filter is the ONLY installed check a run makes now: the
# root helper's backstop went with the privilege boundary, so an id that got past it would reach
# flatpak itself and fail the run with "not installed".
: > "$WORLD/apply-calls"
"$KEMPT" hold flatpak:org.gimp.GIMP
"$KEMPT" update >/dev/null
assert_eq "$(grep '^FLATPAK' "$WORLD/apply-calls")" "FLATPAK --noninteractive -y net.mkiol.SpeechNote" \
  "flatpak hold → per-app update of the pending, non-held, installed app only"
grep -q 'com.example.NotInstalled' "$WORLD/apply-calls" && { echo "FAIL: uninstalled app reached flatpak"; _fail=1; } \
  || echo "ok: pending-but-not-installed app is never handed to flatpak"

# EVERY pending app held, which is the case the per-app form can get catastrophically wrong.
# flatpak_apply overloads "no ids" to mean "update EVERYTHING", so the only thing standing between
# a fully-held backend and updating every single app the user pinned is the `${#ids[@]} -gt 0`
# guard in cmd_update. Until this case existed, no test ever emptied that list - the fixtures held
# one of the two installed apps and left the other to be updated - so deleting that guard left the
# suite green while turning every hold on this backend into a no-op.
: > "$WORLD/apply-calls"
"$KEMPT" hold flatpak:net.mkiol.SpeechNote
"$KEMPT" update >/dev/null
assert_eq "$(grep -c '^FLATPAK' "$WORLD/apply-calls")" "0" \
  "every pending app held → flatpak is not run at all, rather than run on all of them"
# Guards the vacuous pass: a run that never reached the flatpak half also writes no FLATPAK line.
assert_eq "$(grep -c '^APPLY dnf-upgrade' "$WORLD/apply-calls")" "1" "...on a run that did reach it"
"$KEMPT" unhold flatpak:net.mkiol.SpeechNote
"$KEMPT" unhold flatpak:org.gimp.GIMP

# A typo'd flag must never be treated as "run with the configured defaults".
assert_exit 2 "unknown update option rejected" "$KEMPT" update --bogus

# auto_accept=false is enforced in cmd_update ITSELF, not only in cmd_run: `kempt update` is a
# real entry point (widget/cron/user), and only a terminal can answer dnf5's prompt. So the run
# is forced to the terminal surface and -y must NOT reach the privileged helper.
: > "$WORLD/apply-calls"
"$KEMPT" config set auto_accept false
# dnf-reboot-no → rc 0 → no reboot needed: the everyday case, and the one the reboot-needed
# stub above can never prove.
KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no" "$KEMPT" update >/dev/null
h2="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .reboot_needed "$h2")" "false" "no-reboot-needed run completes and records false"
assert_eq "$(jq -r .surface "$h2")" "terminal" "auto_accept=false forces the terminal surface"
assert_eq "$(grep -c -- ' -y' "$WORLD/apply-calls")" "0" "auto_accept=false never sends -y to the helper"
"$KEMPT" config set auto_accept true

# An unknown surface must not silently mean "detached, and definitely not offline". auto_accept is
# true again here, so terminal can ONLY have come from the surface guard.
surferr="$("$KEMPT" update --surface=bogus 2>&1 >/dev/null)"
grep -q "unknown surface 'bogus'" <<<"$surferr" && echo "ok: unknown surface warns" || { echo "FAIL: surface warning"; _fail=1; }
hs="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .surface "$hs")" "terminal" "unknown surface falls back to terminal in update"

# offline surface: stage instead of upgrading live, and leave a marker owning its OWN copy of the
# pre-snapshot (a later update overwrites dnf-before.tsv, and the harvest still has to diff
# against the state as it was when the transaction was staged).
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
"$KEMPT" update --surface=offline >/dev/null
grep -q 'dnf-offline-stage' "$WORLD/apply-calls" && echo "ok: offline stages the transaction" || { echo "FAIL: offline stage"; _fail=1; }
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && { echo "FAIL: offline also upgraded live"; _fail=1; } || echo "ok: offline did not upgrade live"
marker="$KEMPT_STATE_DIR/offline_staged.json"
assert_exit 0 "offline marker written" -- test -f "$marker"
pre="$(jq -r .pre_snapshot "$marker")"
assert_exit 0 "marker owns its own pre-snapshot copy" -- test -f "$pre"
[[ "$pre" != "$KEMPT_STATE_DIR/snapshots/dnf-before.tsv" ]] && echo "ok: copy is not the shared before-snapshot" \
  || { echo "FAIL: marker points at the reusable dnf-before.tsv"; _fail=1; }
grep -q 'staged' "$WORLD/notifications" && echo "ok: offline notification says staged" || { echo "FAIL: offline notify"; _fail=1; }

# ARMING, which is the whole difference between a staged transaction and one that installs. dnf5
# leaves a staged transaction at status="download-complete" and NO boot applies that; `dnf5 offline
# reboot` is what flips it to "ready" and creates /system-update. Staging without arming is what
# shipped first, and it meant "Install on Next Restart" quietly never installed anything, on any
# number of restarts. The ORDER is asserted, not just the presence: arming before the transaction
# exists arms nothing.
stage_ln="$(grep -n 'APPLY dnf-offline-stage' "$WORLD/apply-calls" | head -1 | cut -d: -f1 || true)"
arm_ln="$(grep -n 'APPLY dnf-offline-arm' "$WORLD/apply-calls" | head -1 | cut -d: -f1 || true)"
[[ -n "$stage_ln" && -n "$arm_ln" && "$arm_ln" -gt "$stage_ln" ]] \
  && echo "ok: the run stages the transaction and then arms it" \
  || { echo "FAIL: stage-then-arm (stage=${stage_ln:-none} arm=${arm_ln:-none})"; _fail=1; }
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "0" \
  "an armed stage is not immediately thrown away again"
# armed is recorded in the marker, because the marker is what every later reader (harvest, doctor,
# the popup) works from - and an unarmed stage must never be described to anyone as pending.
assert_eq "$(jq -r '.armed' "$marker")" "true" "the marker records that the stage was armed"
# The SAME count the event line carries: both answer "how many updates is the person waiting for",
# and two different numbers on two surfaces for one transaction is a bug report waiting to happen.
staged_ev="$(grep ' offline staged ' "$KEMPT_STATE_DIR/events.log" | tail -1 | sed 's/.* offline staged //')"
assert_eq "$(jq -r '.staged' "$marker")" "$staged_ev" \
  "the marker carries the same staged count the event line reports"


# An arm that fails leaves a transaction that would sit in the offline directory forever, telling
# every later check and the doctor that an install is pending when nothing will ever apply it. So
# the run FAILS and unwinds: discard the stage, write no marker, and say why.
cat > "$TESTTMP/apply-stub.armfail" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
[[ "\$1" == dnf-offline-arm ]] && { echo "Failed to prepare the system-update symlink" >&2; exit 1; }
exit 0
STUB
chmod +x "$TESTTMP/apply-stub.armfail"
rm -f "$marker"
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
armrc=0
KEMPT_APPLY_HELPER="$TESTTMP/apply-stub.armfail" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || armrc=$?
assert_eq "$armrc" "1" "a run that could not arm its stage fails"
grep -q 'APPLY dnf-offline-clean' "$WORLD/apply-calls" \
  && echo "ok: the stage it could not arm is discarded" || { echo "FAIL: no unwind after a failed arm"; _fail=1; }
assert_exit 0 "a stage that was never armed leaves no marker" -- test ! -f "$marker"
armhist="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .status "$armhist")" "failed" "...and the history entry says the run failed"
assert_eq "$(jq -r .error "$armhist")" "staged but could not arm the restart install" \
  "...naming the step that failed, not the first error-shaped line in the log"
grep -q 'run failed rc=1: staged but could not arm the restart install' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: the event log carries the same reason" || { echo "FAIL: arm failure event line"; _fail=1; }
grep -q 'FAILED' "$WORLD/notifications" \
  && echo "ok: a detached user is told the staging did not take" || { echo "FAIL: arm failure notification"; _fail=1; }

# The unwind is best-effort by design: `dnf5 offline clean` failing on top of an arm that already
# failed changes nothing about the verdict (the run failed either way) and must not replace the
# reason with its own. A run that reported "could not clean up" would send the reader after the
# wrong problem.
cat > "$TESTTMP/apply-stub.bothfail" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
case "\$1" in dnf-offline-arm|dnf-offline-clean) exit 1 ;; esac
exit 0
STUB
chmod +x "$TESTTMP/apply-stub.bothfail"
: > "$WORLD/apply-calls"
bothrc=0
botherr="$(KEMPT_APPLY_HELPER="$TESTTMP/apply-stub.bothfail" "$KEMPT" update --surface=offline --no-flatpak 2>&1 >/dev/null)" || bothrc=$?
assert_eq "$bothrc" "1" "a failed unwind does not change the verdict"
grep -q 'could not discard' <<<"$botherr" \
  && echo "ok: a failed unwind warns" || { echo "FAIL: no warning for a failed unwind - got: $botherr"; _fail=1; }
bothhist="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .error "$bothhist")" "staged but could not arm the restart install" \
  "...and the reason stays the arm, not the cleanup that failed after it"

# The run is over the moment the helper returns: a report step that dies afterwards would take the
# HISTORY ENTRY and the notification down with it, leaving a system that changed and a CLI that
# says nothing happened. Fail the AFTER-snapshot only (2nd call in a run) and demand a clean,
# honest, empty report instead of a crash - and never a report claiming everything was removed.
# Fails only AFTER the apply has run - i.e. the after-snapshot, whatever else a run happens to
# look up first. Binding to the MEANING and not to a call index: a new lookup elsewhere in
# cmd_update (the risky-transaction check added one) must not silently re-point this probe at
# the pre-run snapshot, where crashing is correct behaviour.
cat > "$TESTTMP/flaky-installed" <<STUB
#!/usr/bin/env bash
[[ -s "$WORLD/apply-calls" ]] && exit 7
cat "$WORLD/rpm.tsv"
STUB
chmod +x "$TESTTMP/flaky-installed"
: > "$WORLD/apply-calls"
snaprc=0
snaperr="$(KEMPT_DNF_INSTALLED_CMD="$TESTTMP/flaky-installed" "$KEMPT" update --no-flatpak 2>&1 >/dev/null)" || snaprc=$?
assert_eq "$snaprc" "0" "a broken after-snapshot never crashes the run"
h3="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
grep -q 'snapshot after the run failed' <<<"$snaperr" && echo "ok: broken after-snapshot warns" || { echo "FAIL: snapshot warning"; _fail=1; }
assert_eq "$(jq -r .status "$h3")" "ok" "a broken report does not turn a good run into a failure"
assert_eq "$(jq '.backends.dnf.updated + .backends.dnf.removed | length' "$h3")" "0" \
  "broken after-snapshot degrades to an empty report, never phantom removals"

# every run since the staging rewrote dnf-before.tsv, and the marker's own copy is still there
assert_exit 0 "marker snapshot survives later runs" -- test -f "$pre"

# --- and the same escalation the other way round: nobody reads stderr in a panel ------------------
# A cleanup that failed leaves the box in the one state a person has to act on by hand, and the run
# that produced it is usually a click in the widget. The warning above goes to stderr and to a log
# file; the notification is the only surface that reaches the person who pressed the button, so it
# carries the command verbatim. The reason stays the ARM: the step that failed is what a reader
# has to chase, and the cleanup rides alongside it rather than replacing it.
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
KEMPT_APPLY_HELPER="$TESTTMP/apply-stub.bothfail" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || true
grep -qF 'sudo dnf5 offline clean' "$WORLD/notifications" \
  && echo "ok: the failure notification carries the command that clears what is left" \
  || { echo "FAIL: no clean command in the notification - got: $(cat "$WORLD/notifications")"; _fail=1; }
armdbl="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .error "$armdbl")" "staged but could not arm the restart install" \
  "...while the recorded reason still names the step that failed"

# --- a REBUILD whose STAGE fails, which is the state nothing used to unwind -----------------------
# Ground truth, container-verified: staging over an armed transaction is cancel-then-stage. The old
# transaction is destroyed the moment the re-stage begins, not swapped for the new one at the end.
# So a stage that fails leaves no transaction, a toml that is not `ready`, and the /system-update
# symlink still standing - and the next restart detours into the offline updater and installs
# nothing at all. Only a failed ARM used to unwind; a failed stage left exactly that behind, with a
# marker still promising the install.
cat > "$TESTTMP/apply-stub.stagefail" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
[[ "\$1" == dnf-offline-stage ]] && { echo "No space left on device" >&2; exit 1; }
exit 0
STUB
chmod +x "$TESTTMP/apply-stub.stagefail"
cat > "$TESTTMP/apply-stub.stage-clean-fail" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
case "\$1" in dnf-offline-stage|dnf-offline-clean) exit 1 ;; esac
exit 0
STUB
chmod +x "$TESTTMP/apply-stub.stage-clean-fail"

# The fixture is a REAL armed stage - the marker a `kempt update --surface=offline` writes, over
# the `ready` toml this file runs against - because what the unwind has to get right is the
# lifecycle of the file that command produces, not of a hand-built stand-in.
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
assert_exit 0 "the rebuild fixture starts from a real armed stage" -- test -f "$marker"
old_pre="$(jq -r .pre_snapshot "$marker")"
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
strc=0
KEMPT_APPLY_HELPER="$TESTTMP/apply-stub.stagefail" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || strc=$?
assert_eq "$strc" "1" "a rebuild whose stage fails fails the run"
grep -q 'APPLY dnf-offline-clean' "$WORLD/apply-calls" \
  && echo "ok: ...and discards what the re-stage destroyed" \
  || { echo "FAIL: no unwind after a failed stage"; _fail=1; }
assert_exit 0 "a rebuild that discarded the old stage leaves no marker" -- test ! -f "$marker"
assert_exit 0 "...and no snapshot copy either" -- test ! -f "$old_pre"
grep -q 'offline marker cleared (rebuild failed, stage discarded)' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...and the event log says which of the two it was" \
  || { echo "FAIL: no rebuild-failed clearing event"; _fail=1; }
sthist="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .status "$sthist")" "failed" "...the history entry says the run failed"
assert_eq "$(jq -r .error "$sthist")" "the previous staged update was discarded and could not be rebuilt" \
  "...naming what the user lost, not the first error-shaped line in the log"

# The double failure - state (d). The clean failed too, so the toml and the boot symlink disagree
# and only a person with root can fix it. The marker STAYS: `kempt doctor` reads it against the
# toml and fails on that row, the symlink row fails beside it, and both name the same command.
# Clearing it here would turn the first of those into the benign "staged outside Kempt" info.
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
KEMPT_APPLY_HELPER="$TESTTMP/apply-stub.stage-clean-fail" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || true
assert_exit 0 "a rebuild whose cleanup failed too keeps the marker for the doctor" -- test -f "$marker"
grep -qF 'sudo dnf5 offline clean' "$WORLD/notifications" \
  && echo "ok: ...and the notification carries the command that clears it" \
  || { echo "FAIL: no clean command in the notification - got: $(cat "$WORLD/notifications")"; _fail=1; }
dblhist="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .error "$dblhist")" \
  "the previous staged update was discarded and could not be rebuilt, and could not be cleaned up - run: sudo dnf5 offline clean" \
  "...and the reason carries it too, because there is nothing left to chase in the log"

# Nothing staged before the attempt: there is nothing to unwind, and a clean fired anyway would be
# a privileged call made for no reason. The reason comes from the log, as it always did.
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
: > "$WORLD/apply-calls"
KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml" KEMPT_APPLY_HELPER="$TESTTMP/apply-stub.stagefail" \
  "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || true
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "0" \
  "a first stage that fails unwinds nothing - there was nothing there"
nsthist="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
[[ "$(jq -r .error "$nsthist")" == "the previous staged update was discarded and could not be rebuilt" ]] \
  && { echo "FAIL: a first stage reported a previous one being lost"; _fail=1; } \
  || echo "ok: ...and says nothing about a previous stage that never existed"

# A rebuild that WORKED, which is the whole point of the failure paths above: the run is what a
# hold-behind-a-stage tells the user to do, and the event log is the only record of why it ran.
# The conflicting holds are read BEFORE the stage, because afterwards the question cannot be asked
# again - the transaction that contained the held package is gone.
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
first_at="$(jq -r .staged_at "$marker")"
"$KEMPT" hold dnf:librepo >/dev/null 2>&1
# The one sleep this case needs, and for the same reason the double-staging probe below keeps one:
# staged_at has second resolution and the assertion is that the rebuild wrote a NEW marker.
sleep 1
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
grep -q 'offline restage (holds: librepo)' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: a rebuild over a conflicting hold records the hold it was for" \
  || { echo "FAIL: no restage event - got: $(grep -c 'offline restage' "$KEMPT_STATE_DIR/events.log" || true) restage lines"; _fail=1; }
[[ "$(jq -r .staged_at "$marker")" != "$first_at" ]] \
  && echo "ok: ...and the marker is the new stage's, not the one it replaced" \
  || { echo "FAIL: the marker still describes the replaced stage"; _fail=1; }
assert_eq "$(jq -c '.staged_names' "$marker")" '["ca-certificates","librepo","openldap"]' \
  "...read from the transaction that is there now"
assert_eq "$(jq -r '.armed' "$marker")" "true" "...and armed, like any other stage"
"$KEMPT" unhold dnf:librepo >/dev/null 2>&1
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
"$KEMPT" check >/dev/null

# --- and that count is asked for NOW. It is the only thing the user is ever told about a
# transaction they cannot open, it is what the popup and `kempt doctor` repeat back for as long as
# the stage is armed, and it used to be copied out of the last check's state.json - a number written
# by whatever check ran last, against different metadata, possibly days ago.
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
"$KEMPT" check >/dev/null
fresh="$(jq -r '.backends.dnf.actionable' "$KEMPT_STATE_DIR/state.json")"
# A state.json that says something else entirely, which is all "stale" ever means. 999 rather than
# a plausible number so a marker that came from the wrong place cannot be mistaken for one that did
# not: only the stale path can produce it.
jq '.backends.dnf.actionable = 999' "$KEMPT_STATE_DIR/state.json" > "$TESTTMP/stale-state.json" \
  && mv "$TESTTMP/stale-state.json" "$KEMPT_STATE_DIR/state.json"
: > "$WORLD/timeline"
KEMPT_REFRESH_HELPER="$TESTTMP/refresh-timeline" KEMPT_APPLY_HELPER="$TESTTMP/apply-timeline" \
  "$KEMPT" update --surface=offline --no-flatpak >/dev/null
check_ln="$(grep -n 'REFRESH check' "$WORLD/timeline" | head -1 | cut -d: -f1 || true)"
stage_ln="$(grep -n 'APPLY dnf-offline-stage' "$WORLD/timeline" | head -1 | cut -d: -f1 || true)"
[[ -n "$check_ln" && -n "$stage_ln" && "$check_ln" -lt "$stage_ln" ]] \
  && echo "ok: the offline surface asks what is pending before it stages" \
  || { echo "FAIL: check-before-stage (check=${check_ln:-none} stage=${stage_ln:-none})"; _fail=1; }
assert_eq "$(jq -r '.staged' "$marker")" "$fresh" \
  "the marker's count comes from that check, not from the state file it found"
staged_ev="$(grep ' offline staged ' "$KEMPT_STATE_DIR/events.log" | tail -1 | sed 's/.* offline staged //')"
assert_eq "$staged_ev" "$fresh" "...and so does the count on the event line"

# A check that cannot answer must not stop the stage. Losing a number is not worth refusing to
# update the machine, so it degrades to the stale count with a warning - the same shape the
# risky-transaction pre-check degrades in.
: > "$WORLD/apply-calls"
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
jq '.backends.dnf.actionable = 999' "$KEMPT_STATE_DIR/state.json" > "$TESTTMP/stale-state.json" \
  && mv "$TESTTMP/stale-state.json" "$KEMPT_STATE_DIR/state.json"
degraded="$(KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub.checkfails" \
  "$KEMPT" update --surface=offline --no-flatpak 2>&1 >/dev/null)" || true
grep -q 'APPLY dnf-offline-stage' "$WORLD/apply-calls" \
  && echo "ok: a check that could not answer still stages" || { echo "FAIL: degraded stage"; _fail=1; }
assert_exit 0 "...and still writes a marker" -- test -f "$marker"
assert_eq "$(jq -r '.staged' "$marker")" "999" "...carrying the only count left, the stale one"
grep -q '^warning: ' <<<"$degraded" \
  && echo "ok: ...and says on stderr that the number is not fresh" \
  || { echo "FAIL: no warning - got: $degraded"; _fail=1; }
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
"$KEMPT" check >/dev/null

# --- and the stage records WHICH packages, not only how many ------------------------------------
# A hold added after a stage cannot change the transaction dnf5 has already built, so the only
# honest thing Kempt can do is say whether the held package is in it. That answer needs names, and
# the marker is where they are kept for the moment the live record cannot be read.
#
# Two lists, from two different places, because they answer two different questions:
#   staged_names     what the transaction INSTALLS - read from dnf5's own stored transaction, which
#                    is the only source that sees resolver-added packages and a transaction someone
#                    else replaced. The marker's copy is the fallback, never the primary.
#   staged_excluded  what was held AND pending when the stage was made - which the transaction can
#                    never say, because a package absent from it is indistinguishable from a
#                    package that simply had no update. It is what lets `kempt unhold` know whether
#                    this stage was built without the package the user just released.
: > "$WORLD/apply-calls"
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
"$KEMPT" hold dnf:curl >/dev/null 2>&1
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
assert_eq "$(jq -r '.staged_names_source' "$marker")" "transaction" \
  "the staged set is recorded from dnf5's own transaction, and the marker says so"
assert_eq "$(jq -c '.staged_names' "$marker")" '["ca-certificates","librepo","openldap"]' \
  "...as the names that transaction installs, not the names the check happened to list"
assert_eq "$(jq -c '.staged_excluded' "$marker")" '["curl"]' \
  "a package held and pending at stage time is recorded as excluded from it"
assert_eq "$(jq -r '.staged' "$marker")" "6" \
  "the count stays what it was: pending, minus the held one"
assert_eq "$(stat -c %a "$marker")" "600" "...and the marker is still private"

# The live record unreadable, the check fine: the names degrade to the check's answer and the
# marker SAYS they did. A check-derived list may confirm a conflict and may never deny one, so the
# source field is not bookkeeping - it is what stops a later reader from taking silence for proof.
: > "$WORLD/apply-calls"
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
printf 'not a transaction\n' > "$TESTTMP/tx-garbage.json"
KEMPT_OFFLINE_TXJSON="$TESTTMP/tx-garbage.json" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
assert_eq "$(jq -r '.staged_names_source' "$marker")" "check" \
  "a transaction record that will not parse falls back to the check, and is labelled as such"
assert_eq "$(jq -c '.staged_names' "$marker")" \
  '["aajohan-comfortaa-fonts","bash","brandnew","git-core","tar","vim-minimal"]' \
  "...carrying what the check said was pending and not held"
assert_eq "$(jq -c '.staged_excluded' "$marker")" '["curl"]' \
  "...and the excluded list is unaffected: it never came from the transaction"

# Both sources gone - an unparsable record AND a check that could not answer. There is no list, so
# the marker carries none at all rather than an empty array that a reader could mistake for "the
# transaction installs nothing". The stage still goes ahead: losing a list is not worth refusing to
# update the machine, exactly like losing the count.
: > "$WORLD/apply-calls"
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
KEMPT_OFFLINE_TXJSON="$TESTTMP/tx-garbage.json" KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub.checkfails" \
  "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
grep -q 'APPLY dnf-offline-stage' "$WORLD/apply-calls" \
  && echo "ok: a stage with no names available still stages" || { echo "FAIL: nameless stage"; _fail=1; }
assert_eq "$(jq -r '.staged_names_source' "$marker")" "none" "...and says it knows no names"
assert_eq "$(jq -r 'has("staged_names")' "$marker")" "false" \
  "...with no staged_names key at all, so an empty list can never be read as an empty transaction"
assert_eq "$(jq -c '.staged_excluded' "$marker")" '[]' \
  "...and an empty excluded list, which sends unhold to its pending fallback"

# ONE name that fails the name gate drops the WHOLE list. The gate is KEMPT_NAME_RE, the same shape
# a hold is validated against, and it covers jq, the shell, QML and a terminal in one place. Partial
# filtering would be worse than nothing: a list with a name quietly removed is a list that can still
# be used to say "your package is not in the transaction".
# The check is the path that needs the gate - the transaction reader applies it before it answers -
# so the live record is pointed at garbage to reach it.
cat > "$TESTTMP/badname-check.txt" <<'EOF'
bash.x86_64   5.3.10-1.fc44   updates
--exclude=evil.x86_64   1.0-1.fc44   updates
EOF
cat > "$TESTTMP/refresh-stub.badname" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$TESTTMP/badname-check.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub.badname"
: > "$WORLD/apply-calls"
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
KEMPT_OFFLINE_TXJSON="$TESTTMP/tx-garbage.json" KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub.badname" \
  "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
assert_eq "$(jq -r '.staged_names_source' "$marker")" "none" \
  "one name that fails the gate drops the whole list to no source at all"
assert_eq "$(jq -r 'has("staged_names")' "$marker")" "false" \
  "...and nothing of that list is written down"
"$KEMPT" unhold dnf:curl >/dev/null 2>&1
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
"$KEMPT" check >/dev/null

# A pre-run snapshot that cannot be read means we could never say what changed, so the run stops
# BEFORE touching anything - loudly, with its own exit code, and the detached user is told.
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
prc=0
perr="$(KEMPT_DNF_INSTALLED_CMD=false "$KEMPT" update --surface=background 2>&1 >/dev/null)" || prc=$?
assert_eq "$prc" "5" "unreadable package set aborts pre-flight with exit 5"
grep -q 'cannot read the installed package set' <<<"$perr" \
  && echo "ok: pre-flight failure says what went wrong" || { echo "FAIL: preflight message - got: $perr"; _fail=1; }
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "pre-flight abort changes nothing"
grep -q 'did not start' "$WORLD/notifications" \
  && echo "ok: a detached user is told the run never started" || { echo "FAIL: preflight notify"; _fail=1; }
# same for the optional backend: it must not die silently through errexit either
frc=0
ferr="$(KEMPT_FLATPAK_LIST_CMD=false "$KEMPT" update 2>&1 >/dev/null)" || frc=$?
assert_eq "$frc" "5" "unreadable flatpak set aborts pre-flight too"
grep -q 'cannot read the installed flatpak set' <<<"$ferr" \
  && echo "ok: flatpak pre-flight failure is named" || { echo "FAIL: flatpak preflight message"; _fail=1; }

# --- risky-transaction detection: recommend offline staging before a LIVE upgrade of packages
# that can break the running desktop. The fixture used everywhere else has none, so this section
# swaps in a check stub that does, and restores it afterwards.
printf 'kernel-core.x86_64   6.15.4-200.fc44   updates\nbash.x86_64   5.3.10-1.fc44   updates\n' > "$TESTTMP/risky-check.txt"
cat > "$TESTTMP/risky-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$TESTTMP/risky-check.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/risky-stub"
export KEMPT_REFRESH_HELPER="$TESTTMP/risky-stub"

# [a]bort: nothing runs, nothing is recorded, rc 0 - the user declined, that is not a failure
: > "$WORLD/apply-calls"
hist_n="$(ls "$KEMPT_STATE_DIR"/history/*.json | wc -l)"
arc=0
aout="$(KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=terminal <<<"a" 2>/dev/null)" || arc=$?
assert_eq "$arc" "0" "declining a risky update is not an error"
grep -q 'session-critical' <<<"$aout" && echo "ok: recommendation explains the risk" || { echo "FAIL: recommendation text"; _fail=1; }
grep -q 'kernel-core' <<<"$aout" && echo "ok: recommendation names the package" || { echo "FAIL: risky list"; _fail=1; }
grep -q 'bash' <<<"$aout" && { echo "FAIL: ordinary package listed as risky"; _fail=1; } || echo "ok: ordinary packages stay out of the list"
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "abort runs no privileged command"
assert_eq "$(ls "$KEMPT_STATE_DIR"/history/*.json | wc -l)" "$hist_n" "abort records no run"
# "no residue" now means NOT LOCKED (flock leaves the file in place; only the lock matters)
assert_exit 0 "abort leaves the lock free" -- flock -n "$KEMPT_STATE_DIR/lock" true

# [s]tage offline instead: the recommendation is actionable, not just advice
: > "$WORLD/apply-calls"
KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=terminal <<<"s" >/dev/null 2>&1
grep -q 'dnf-offline-stage' "$WORLD/apply-calls" && echo "ok: [s] switches the run to offline staging" || { echo "FAIL: stage offline"; _fail=1; }
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && { echo "FAIL: [s] upgraded live anyway"; _fail=1; } || echo "ok: [s] never upgrades live"
# only the newest staging can ever be harvested, so older copies are swept, not accumulated
assert_eq "$(ls "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv | wc -l)" "1" "staging sweeps orphaned pre-snapshots"
assert_exit 0 "the surviving copy is the one the marker points at" \
  -- test -f "$(jq -r .pre_snapshot "$KEMPT_STATE_DIR/offline_staged.json")"

# [u]pdate live: the user always decides
: > "$WORLD/apply-calls"
KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=terminal <<<"u" >/dev/null 2>&1
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && echo "ok: [u] proceeds with the live upgrade" || { echo "FAIL: update live"; _fail=1; }

# Saying NO to a risk warning must never proceed - the answer people actually type is "n".
# The trailing "u" is the point: if "n" were ever treated as an unrecognised answer, the
# re-prompt would swallow it and the run would proceed on an answer meant to stop it.
: > "$WORLD/apply-calls"
nrc=0
printf 'n\nu\n' | KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=terminal >/dev/null 2>&1 || nrc=$?
assert_eq "$nrc" "0" "declining with n exits 0"
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "n means no: nothing is applied"

# no answer at all (Enter, or EOF from a closed stdin) is NOT consent
: > "$WORLD/apply-calls"
KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=terminal </dev/null >/dev/null 2>&1
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "an unanswered risk warning defaults to abort"
: > "$WORLD/apply-calls"
printf '\nu\n' | KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=terminal >/dev/null 2>&1
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "pressing Enter defaults to abort"

# gibberish gets one more chance, then aborts rather than guessing
: > "$WORLD/apply-calls"
printf 'x\nx\n' | KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=terminal >/dev/null 2>&1
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "two unparseable answers abort"
: > "$WORLD/apply-calls"
printf 'x\nu\n' | KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=terminal >/dev/null 2>&1
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && echo "ok: the re-prompt accepts a valid second answer" || { echo "FAIL: re-prompt"; _fail=1; }

# --- bounded output: a real Qt or KDE bump matches by the hundred (168 on this box), and a wall
# of names is not a recommendation anyone can act on.
{ for i in 01 02 03 04 05 06 07 08 09 10 11 12; do printf 'qt6-qtmod%s.x86_64   6.9.1-1.fc44   updates\n' "$i"; done
  for i in 01 02 03 04 05; do printf 'kf6-kmod%s.x86_64   6.18.0-1.fc44   updates\n' "$i"; done
  printf 'kernel-core.x86_64   6.15.4-200.fc44   updates\n'
  printf 'mesa-libGL.x86_64   25.2.1-1.fc44   updates\n'
  printf 'kwin-x11.x86_64   6.5.1-1.fc44   updates\n'
  printf 'kernel-devel.x86_64   6.15.4-200.fc44   updates\n'; } > "$TESTTMP/risky-check.txt"
big="$(KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=terminal <<<"a" 2>/dev/null)"
grep -q 'touches 20 session-critical packages' <<<"$big" \
  && echo "ok: the count is the headline (kernel-devel excluded)" || { echo "FAIL: risky count - got: $(head -1 <<<"$big")"; _fail=1; }
# One representative per FAMILY, like the notification: eight alphabetical names off the top of
# a 12-package qt6 bump told the user nothing about the kernel further down the list. Five
# families here (kernel, kf6, kwin, mesa, qt6), so five names and the rest counted in the tail.
assert_eq "$(grep -cE '^  [a-z]' <<<"$big")" "5" "terminal listing shows one name per family"
assert_eq "$(grep -c 'qt6-qtmod' <<<"$big")" "1" "a single family never fills the whole listing"
grep -q '  mesa-libGL' <<<"$big" && echo "ok: a one-package family is still named" || { echo "FAIL: small family missing"; _fail=1; }
grep -q '  kernel-core' <<<"$big" && echo "ok: the kernel is named, not buried by alphabetical qt6 rows" || { echo "FAIL: kernel missing from the listing"; _fail=1; }
grep -q '\.\.\. and 15 more' <<<"$big" && echo "ok: the rest are counted, not printed" || { echo "FAIL: overflow line"; _fail=1; }
: > "$WORLD/notifications"
"$KEMPT" update --surface=background >/dev/null 2>&1
grep -q '20 session-critical packages pending (kernel, kf6, kwin, mesa, ...)' "$WORLD/notifications" \
  && echo "ok: notification summarises by family, capped at 4" || { echo "FAIL: family summary - got: $(cat "$WORLD/notifications")"; _fail=1; }
grep -q 'qtmod' "$WORLD/notifications" && { echo "FAIL: individual names leaked into the notification"; _fail=1; } \
  || echo "ok: no wall of package names in a notification"
printf 'kernel-core.x86_64   6.15.4-200.fc44   updates\nbash.x86_64   5.3.10-1.fc44   updates\n' > "$TESTTMP/risky-check.txt"

# The lock is NOT held while a human deliberates: the recommendation runs before acquire_lock, so
# a prompt left open over lunch never blocks the timer's next run, and an abort leaves no residue.
{ sleep 1; echo a; } | KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=terminal >/dev/null 2>&1 &
bgpid=$!
sleep 0.4
if kill -0 "$bgpid" 2>/dev/null && flock -n "$KEMPT_STATE_DIR/lock" true; then
  echo "ok: no lock is held while the recommendation waits for an answer"
else echo "FAIL: lock held (or run already over) during the prompt"; _fail=1; fi
wait "$bgpid" || true

# A detached surface must not prompt even when it happens to have a terminal on stdin: the surface
# itself says nobody is watching, and a background run must never block waiting on a human.
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=background <<<"a" >/dev/null 2>&1
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && echo "ok: background surface proceeds instead of prompting" \
  || { echo "FAIL: background surface prompted and was aborted"; _fail=1; }

# detached surface: nobody is there to answer a prompt, so it warns and proceeds
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
"$KEMPT" update --surface=background >/dev/null 2>&1
grep -q 'session-critical' "$WORLD/notifications" && echo "ok: detached surface gets a heads-up" || { echo "FAIL: detached heads-up"; _fail=1; }
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && echo "ok: detached surface proceeds anyway" || { echo "FAIL: detached proceed"; _fail=1; }

# an offline run is already the recommendation - it must not nag about taking its own advice
: > "$WORLD/notifications"
"$KEMPT" update --surface=offline >/dev/null 2>&1
grep -q 'session-critical' "$WORLD/notifications" && { echo "FAIL: offline run still recommended offline"; _fail=1; } \
  || echo "ok: offline surface skips the recommendation"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"

# second update while the lock is REALLY held → refuses. A background holder takes the same
# flock the CLI takes, so this exercises the kernel's answer, not a heuristic about a pid file.
hold_lock() {  # → sets $holder; returns once the lock is genuinely held
  rm -f "$TESTTMP/held-flag"
  ( exec 8>"$KEMPT_STATE_DIR/lock"; flock 8; touch "$TESTTMP/held-flag"; sleep 30 ) &
  holder=$!
  local w=0
  until [[ -f "$TESTTMP/held-flag" ]] || (( w > 100 )); do sleep 0.05; w=$(( w + 1 )); done
  [[ -f "$TESTTMP/held-flag" ]] || { echo "FAIL: background lock holder never started"; _fail=1; }
}
mkdir -p "$KEMPT_STATE_DIR"
hold_lock
assert_exit 3 "concurrent update refused" "$KEMPT" update
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true

# ...and a lock whose holder was SIGKILLed must not freeze updates forever (the restic lock that
# silently froze retention for 8 days). With flock there is nothing to clear: the kernel drops it
# when the fd closes, however the process died.
hold_lock
kill -9 "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
assert_exit 0 "a killed holder's lock is gone by construction" "$KEMPT" update --no-flatpak

# A failure that is NOT a busy package lock must fail at once: retrying a full disk three times
# just makes the user wait three times as long for the same bad news.
cat > "$TESTTMP/apply-stub" <<'STUB'
#!/usr/bin/env bash
echo "Error: No space left on device" >&2; exit 1
STUB
export KEMPT_RETRY_DELAY=0
# Log filenames are per-second too ($LOG_DIR/$ts.log, same $ts as the history entry) and the run
# APPENDS, so a run sharing a second with an earlier one reads both runs' lines. Clearing the dir
# makes "the newest log" unambiguously this run's, whatever second it lands on.
rm -f "$KEMPT_STATE_DIR"/logs/*.log
assert_exit 1 "a non-lock failure fails immediately" "$KEMPT" update --no-flatpak
assert_eq "$(grep -c 'retrying' "$(ls -t "$KEMPT_STATE_DIR"/logs/* | head -1)")" "0" "only package-lock errors are retried"

# helper failure with lock-ish stderr → retried then fails cleanly.
# --no-flatpak keeps the retry count scoped to ONE apply call (both backends would retry).
cat > "$TESTTMP/apply-stub" <<'STUB'
#!/usr/bin/env bash
echo "cannot open lock file: held by another process" >&2; exit 1
STUB
export KEMPT_RETRY_DELAY=0
rm -f "$KEMPT_STATE_DIR"/logs/*.log   # per-second log names: this run's retries only
assert_exit 1 "busy rpm lock eventually fails" "$KEMPT" update --no-flatpak
assert_eq "$(grep -c 'retrying' "$(ls -t "$KEMPT_STATE_DIR"/logs/* | head -1)")" "2" "two retries logged"
# 3 attempts = 2 retries: the last failure must not promise a retry that never comes.
assert_eq "$(grep -c 'giving up' "$(ls -t "$KEMPT_STATE_DIR"/logs/* | head -1)")" "1" "gives up loudly after the last attempt"

# --- offline harvest: the staged transaction applies during a reboot, and the next check has to
# notice and turn it into a normal history entry + notification.
# The marker OWNS its pre-snapshot copy and harvest deletes it, so a marker must never point at a
# shared file - pointing this one at tests/fixtures/ would delete a repo fixture.
pre_copy="$KEMPT_STATE_DIR/snapshots/offline-pre-harvest.tsv"
cp "$FIXTURES/snap-before.tsv" "$pre_copy"
jq -n --arg snap "$pre_copy" '{staged_at:"x", pre_snapshot:$snap}' > "$KEMPT_STATE_DIR/offline_staged.json"
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub"

# not applied yet (reboot hasn't happened): the installed set still matches the pre-snapshot
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
before_n="$(ls "$KEMPT_STATE_DIR"/history/*.json | wc -l)"
"$KEMPT" check >/dev/null
assert_exit 0 "unapplied stage keeps its marker" -- test -f "$KEMPT_STATE_DIR/offline_staged.json"
assert_eq "$(ls "$KEMPT_STATE_DIR"/history/*.json | wc -l)" "$before_n" "unapplied stage records nothing"

# applied on reboot: the installed set moved
cp "$FIXTURES/snap-after.tsv" "$WORLD/rpm.tsv"
: > "$WORLD/notifications"
push_history_back   # per-second names: keep the harvested entry from landing on an older one
"$KEMPT" check >/dev/null
[[ ! -f "$KEMPT_STATE_DIR/offline_staged.json" ]] && echo "ok: marker consumed" || { echo "FAIL: marker"; _fail=1; }
ls "$KEMPT_STATE_DIR"/history/*.json >/dev/null 2>&1 && echo "ok: harvest wrote history" || { echo "FAIL: harvest"; _fail=1; }
assert_eq "$(ls "$KEMPT_STATE_DIR"/history/*.json | wc -l)" "$((before_n + 1))" "exactly one history entry harvested"
hh="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .surface "$hh")" "offline (applied on reboot)" "harvested entry names the surface"
assert_eq "$(jq '.backends.dnf.updated | length' "$hh")" "2" "harvest diffs against the marker's own snapshot"
assert_exit 0 "harvest removes the snapshot copy it owned" -- test ! -f "$pre_copy"
grep -q NOTIFY "$WORLD/notifications" && echo "ok: harvest notifies" || { echo "FAIL: harvest notify"; _fail=1; }

# a consumed marker must not be harvested twice (a second entry would double-count the run)
"$KEMPT" check >/dev/null
assert_eq "$(ls "$KEMPT_STATE_DIR"/history/*.json | wc -l)" "$((before_n + 1))" "harvest does not repeat"

# cmd_update prints the rendered summary on stdout - that is the terminal surface's whole point
# ($out was captured from the very first run, before the stub renderer was replaced)
grep -q 'kernel-core 6.15.3-200.fc44 → 6.15.4-200.fc44' <<<"$out" && echo "ok: update printed a rendered summary" \
  || { echo "FAIL: update printed no summary - got: $out"; _fail=1; }

# --- a LIVE update SUPERSEDES a pending stage, and a flatpak-only one does not.
# A staged transaction records the rpmdb cookie it was built against, and dnf5 refuses a
# transaction whose cookie has moved. So once a live run installs anything, the armed stage is no
# longer a pending update - it is a failed offline boot waiting to happen - and the honest thing
# is to discard it. A run that touched no rpm (flatpak only) leaves the cookie intact, and the
# stage stays pending.
# Three worlds: staged (baseline) → live (a live run bumped bash) → reboot (the staged kernel).
printf 'bash\t5.2.37-1.fc44\nkernel-core\t6.15.3-200.fc44\nzsh\t5.9-11.fc44\n' > "$TESTTMP/rb-staged.tsv"
printf 'bash\t5.2.38-1.fc44\nkernel-core\t6.15.3-200.fc44\nzsh\t5.9-11.fc44\n' > "$TESTTMP/rb-live.tsv"
printf 'bash\t5.2.37-1.fc44\nkernel-core\t6.15.4-200.fc44\nzsh\t5.9-11.fc44\n' > "$TESTTMP/rb-reboot.tsv"
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
[[ "\$1" == dnf-upgrade ]] && cp "$TESTTMP/rb-live.tsv" "$WORLD/rpm.tsv"
exit 0
STUB
marker="$KEMPT_STATE_DIR/offline_staged.json"
cp "$TESTTMP/rb-staged.tsv" "$WORLD/rpm.tsv"
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
assert_exit 0 "offline stage left a marker" -- test -f "$marker"
sup_pre="$(jq -r .pre_snapshot "$marker")"
push_history_back   # per-second names: move the staging entry off the second the live run will use
ls -1 "$KEMPT_STATE_DIR"/history/*.json | sort > "$TESTTMP/hist-before.txt"
: > "$WORLD/apply-calls"
# Without cmp on PATH (nocmp_dir): "the stage is still pending" and "the set moved" are decided
# from content, not from a diffutils binary a minimal box may not have.
PATH="$(nocmp_dir):$PATH" "$KEMPT" update --surface=background --no-flatpak >/dev/null 2>&1
grep -q 'APPLY dnf-offline-clean' "$WORLD/apply-calls" \
  && echo "ok: a live rpm change discards the stage it invalidated" \
  || { echo "FAIL: the superseded stage was left armed and doomed"; _fail=1; }
assert_exit 0 "...and the marker goes with it" -- test ! -f "$marker"
assert_exit 0 "...along with the snapshot copy the marker owned" -- test ! -f "$sup_pre"
grep -q 'offline stage dropped (superseded by live update)' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: the drop is recorded - it is the only trace the stage ever left" \
  || { echo "FAIL: no event for the dropped stage"; _fail=1; }
ls -1 "$KEMPT_STATE_DIR"/history/*.json | sort > "$TESTTMP/hist-after.txt"
comm -13 "$TESTTMP/hist-before.txt" "$TESTTMP/hist-after.txt" > "$TESTTMP/hist-new.txt"
assert_eq "$(wc -l < "$TESTTMP/hist-new.txt")" "1" "the live run records ONE entry, not one plus a phantom harvest"
assert_eq "$(jq -r .surface "$(head -1 "$TESTTMP/hist-new.txt")")" "background" "the entry is the live run, not a mislabelled harvest"

# A run that installed no rpm cannot have invalidated anything: the stage stays, and the reboot
# that applies it is still reported. This is the flatpak-only run, and it is the reason the
# supersede is gated on a real rpm delta rather than on "a live run happened".
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
exit 0
STUB
cp "$TESTTMP/rb-staged.tsv" "$WORLD/rpm.tsv"
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
push_history_back
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=background --no-flatpak >/dev/null 2>&1
assert_exit 0 "a run that changed no rpm leaves the pending stage alone" -- test -f "$marker"
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "0" \
  "...and never discards it"

# ...and after the reboot that actually applies it, the harvest reports the STAGED delta
cp "$TESTTMP/rb-reboot.tsv" "$WORLD/rpm.tsv"
simulate_reboot
push_history_back   # `ls | tail -1` below must find the harvest, not the live run it collided with
"$KEMPT" check >/dev/null 2>&1
[[ ! -f "$marker" ]] && echo "ok: the post-reboot check consumes the marker" || { echo "FAIL: marker survived the reboot"; _fail=1; }
hr="$KEMPT_STATE_DIR/history/$(ls -1 "$KEMPT_STATE_DIR/history" | tail -1)"
assert_eq "$(jq -r .surface "$hr")" "offline (applied on reboot)" "the reboot result is harvested as an offline run"
assert_eq "$(jq -c '[.backends.dnf.updated[].name]' "$hr")" '["kernel-core"]' \
  "the harvest reports the staged package and nothing else"

# --- history filenames are per-second, and a harvest fires from a check a live run may have
# triggered in the same second. An existing entry must never be overwritten.
pre2="$KEMPT_STATE_DIR/snapshots/offline-pre-collide.tsv"
cp "$TESTTMP/rb-live.tsv" "$pre2"
jq -n --arg snap "$pre2" '{staged_at:"x", pre_snapshot:$snap}' > "$marker"
cp "$TESTTMP/rb-reboot.tsv" "$WORLD/rpm.tsv"
decoys=()
for off in 0 1 2 3; do
  d="$KEMPT_STATE_DIR/history/$(date -d "+$off seconds" +%Y%m%dT%H%M%S).json"
  printf 'DECOY\n' > "$d"; decoys+=("$d")
done
"$KEMPT" check >/dev/null 2>&1
assert_eq "$(ls -1 "$KEMPT_STATE_DIR"/history/*-offline.json 2>/dev/null | wc -l)" "1" \
  "a same-second harvest takes its own filename"
assert_eq "$(cat "${decoys[@]}" | grep -c DECOY)" "4" "no existing history entry was overwritten"
rm -f "${decoys[@]}"

# --- the lock-retry window is PER ATTEMPT. dnf fails three times on a busy package lock, then
# flatpak fails on a full disk in the SAME log: a fixed `tail -n 20` re-reads dnf's lock errors,
# calls the disk failure a lock too, and retries a run that was never going to succeed.
cat > "$TESTTMP/apply-stub" <<'STUB'
#!/usr/bin/env bash
echo "APPLY $@" >> "$WORLD/apply-calls"
[[ "$1" == dnf-upgrade ]] && echo "cannot open lock file: held by another process" >&2
exit 1
STUB
cat > "$TESTTMP/fp-update-stub" <<'STUB'
#!/usr/bin/env bash
echo "FLATPAK $@" >> "$WORLD/apply-calls"
echo "Error: No space left on device" >&2
exit 1
STUB
: > "$WORLD/apply-calls"
export KEMPT_RETRY_DELAY=0
rm -f "$KEMPT_STATE_DIR"/logs/*.log   # per-second log names: the mixed log must be this run's alone
assert_exit 1 "a lock-then-disk run fails" "$KEMPT" update --surface=background
mixed_log="$(ls -t "$KEMPT_STATE_DIR"/logs/*.log | head -1)"
assert_eq "$(grep -c '^APPLY' "$WORLD/apply-calls")" "3" "the dnf lock error is retried three times"
assert_eq "$(grep -c '^FLATPAK' "$WORLD/apply-calls")" "1" "...and the flatpak disk error is tried exactly once"
assert_eq "$(grep -c 'retrying' "$mixed_log")" "2" "the disk failure is never retried as a lock error"

# ...and the other half of that: flatpak's OWN lock wordings must be retried too. There are three
# of them across two libraries, and in two the PATH SITS IN THE MIDDLE - which is the detail a
# literal pattern gets wrong, and the reason all four lines below are driven rather than one:
#     Unable to lock %s                  flatpak CLI and libflatpak
#     Locking repo %s failed             libostree  (the CLI also carries `Locking repo failed (%s)`)
#     Opening lock file %s/.lock failed  libostree and the CLI
# (Read 2026-08-27 with `strings` on /usr/bin/flatpak, /usr/lib64/libflatpak.so.0 and
# /usr/lib64/libostree-1.so.1, flatpak 1.18.1.) Not one of them says rpm, package, transaction or
# held, so the dnf-shaped half of apply_with_retry's predicate never matched them: a run that lost
# a race with GNOME Software failed on attempt 1 while the log above it promised three.
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"     # dnf succeeds; flatpak is the one retrying
while IFS='|' read -r label msg; do
  [[ -n "$label" ]] || continue
  cat > "$TESTTMP/fp-update-stub" <<STUB
#!/usr/bin/env bash
echo "FLATPAK \$@" >> "$WORLD/apply-calls"
echo "$msg" >&2
exit 1
STUB
  chmod +x "$TESTTMP/fp-update-stub"
  : > "$WORLD/apply-calls"
  rm -f "$KEMPT_STATE_DIR"/logs/*.log
  "$KEMPT" update --surface=background >/dev/null 2>&1 || true
  assert_eq "$(grep -c '^FLATPAK' "$WORLD/apply-calls")" "3" "flatpak lock wording retried: $label"
done <<'CASES'
libflatpak, path at the end|error: Unable to lock /var/lib/flatpak/repo/.lock: Resource temporarily unavailable
libostree, path in the MIDDLE|error: Locking repo /var/lib/flatpak/repo failed: Resource temporarily unavailable
the CLI's own parenthesised form|error: Locking repo failed (Resource temporarily unavailable)
the lock file could not be opened|error: Opening lock file /var/lib/flatpak/repo/.lock failed: Permission denied
CASES
# The near-miss that must NOT be retried. `Unlocking repo failed` contains `locking repo failed`
# as a substring, so the pattern is word-anchored; unlocking is a different error and not a lock
# anyone should wait on.
cat > "$TESTTMP/fp-update-stub" <<STUB
#!/usr/bin/env bash
echo "FLATPAK \$@" >> "$WORLD/apply-calls"
echo "error: Unlocking repo failed" >&2
exit 1
STUB
chmod +x "$TESTTMP/fp-update-stub"
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=background >/dev/null 2>&1 || true
assert_eq "$(grep -c '^FLATPAK' "$WORLD/apply-calls")" "1" \
  "an UNlock failure is not a lock to wait on, and is tried once"
cp "$TESTTMP/fp-update-stub.orig" "$TESTTMP/fp-update-stub"

# --- double staging leaves ONE pre-snapshot: only the newest can ever be harvested, so an
# un-swept copy is dead weight that accumulates one file per staged run, forever.
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"
cp "$TESTTMP/fp-update-stub.orig" "$TESTTMP/fp-update-stub"
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
first_pre="$(jq -r .pre_snapshot "$marker")"
# The one sleep that has to stay. Everywhere else the collision is with a file already on disk,
# which push_history_back moves for free - here it is between the $ts of two CONSECUTIVE
# cmd_update runs, generated inside each run, and the assertion below is precisely that the two
# stagings produced DIFFERENT offline-pre-$ts.tsv names. Faking that would delete the guard: with
# both stagings on one filename the sweep is never exercised and this probe proves nothing.
sleep 1
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
second_pre="$(jq -r .pre_snapshot "$marker")"
[[ "$first_pre" != "$second_pre" ]] && echo "ok: the second staging really wrote a new copy" \
  || { echo "FAIL: both stagings used one filename - the sweep was never exercised"; _fail=1; }
assert_eq "$(ls -1 "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv | wc -l)" "1" \
  "double staging leaves exactly one pre-snapshot"
assert_exit 0 "and the survivor is the one the live marker points at" -- test -f "$second_pre"

# --- the OTHER ordering: the reboot ALREADY applied the staged transaction, and no check has run
# since, so the marker is still sitting there unharvested. Rebasing here would fold the staged
# delta into the baseline - the transaction would never be reported at all, and the marker would
# linger to mislabel whatever changed next. The rebase therefore only fires while the stage is
# still PENDING, which is exactly "the marker's baseline still matches the world this run started
# from" (staging writes no rpm changes of its own).
printf 'bash\t5.2.37-1.fc44\nkernel-core\t6.15.4-200.fc44\nzsh\t5.9-11.fc44\n' > "$TESTTMP/rb-applied.tsv"
printf 'bash\t5.2.38-1.fc44\nkernel-core\t6.15.4-200.fc44\nzsh\t5.9-11.fc44\n' > "$TESTTMP/rb-live2.tsv"
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
[[ "\$1" == dnf-upgrade ]] && cp "$TESTTMP/rb-live2.tsv" "$WORLD/rpm.tsv"
exit 0
STUB
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
cp "$TESTTMP/rb-staged.tsv" "$WORLD/rpm.tsv"
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
cp "$TESTTMP/rb-applied.tsv" "$WORLD/rpm.tsv"   # the reboot applied it; no check has run yet
simulate_reboot
push_history_back   # per-second names: move the staging entry off the second the live run will use
ls -1 "$KEMPT_STATE_DIR"/history/*.json | sort > "$TESTTMP/hist-before.txt"
"$KEMPT" update --surface=background --no-flatpak >/dev/null 2>&1
[[ ! -f "$marker" ]] && echo "ok: an already-applied stage is harvested, never swallowed by a rebase" \
  || { echo "FAIL: the staged transaction was folded into the baseline and lost"; _fail=1; }
ls -1 "$KEMPT_STATE_DIR"/history/*.json | sort > "$TESTTMP/hist-after.txt"
comm -13 "$TESTTMP/hist-before.txt" "$TESTTMP/hist-after.txt" > "$TESTTMP/hist-new.txt"
assert_eq "$(wc -l < "$TESTTMP/hist-new.txt")" "2" "two entries: the live run AND the harvested stage"
off_entry=/dev/null; live_entry=/dev/null
while IFS= read -r f; do
  case "$(jq -r '.surface // ""' "$f" 2>/dev/null)" in
    "offline (applied on reboot)") off_entry="$f" ;;
    background) live_entry="$f" ;;
  esac
done < "$TESTTMP/hist-new.txt"
[[ "$off_entry" != /dev/null ]] && echo "ok: the staged transaction gets its own history entry" \
  || { echo "FAIL: no harvested entry - the staged transaction was never reported"; _fail=1; }
[[ "$live_entry" != /dev/null ]] && echo "ok: the live run keeps its own entry" \
  || { echo "FAIL: the live run's entry was lost or mislabelled"; _fail=1; }
assert_eq "$(jq -r '[.backends.dnf.updated[].name] | index("kernel-core") != null' "$off_entry")" "true" \
  "the harvested entry reports the staged package"
assert_eq "$(jq -r '[.backends.dnf.updated[].name] | index("bash") != null' "$live_entry")" "true" \
  "the live entry reports the live package, under its own surface"
assert_eq "$(ls -1 "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv 2>/dev/null | wc -l)" "0" \
  "the harvest cleans up the snapshot copy the marker owned"

# --- a TRUNCATED after-snapshot must never become the harvest baseline. The redirection creates
# the file before the snapshot runs, so a snapshot that dies mid-stream leaves a short but
# non-empty file: every package missing from it would come back as newly installed at the next
# harvest. The report degrades to empty (the run is over either way) and the marker keeps the
# baseline it was staged with.
cat > "$TESTTMP/partial-installed" <<STUB
#!/usr/bin/env bash
[[ -s "$WORLD/apply-calls" ]] && { printf 'bash\t5.2.37-1.fc44\n'; exit 7; }
cat "$WORLD/rpm.tsv"
STUB
chmod +x "$TESTTMP/partial-installed"
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
cp "$TESTTMP/rb-staged.tsv" "$WORLD/rpm.tsv"
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
pre_c="$(jq -r .pre_snapshot "$marker")"
cp "$pre_c" "$TESTTMP/baseline-copy.tsv"
: > "$WORLD/apply-calls"
push_history_back   # per-second names: the live run must not overwrite the staging run's entry
KEMPT_DNF_INSTALLED_CMD="$TESTTMP/partial-installed" "$KEMPT" update --surface=background --no-flatpak >/dev/null 2>&1
assert_exit 0 "a truncated after-snapshot leaves the marker in place" -- test -f "$marker"
assert_exit 0 "...and never overwrites its baseline with the truncation" -- cmp -s "$pre_c" "$TESTTMP/baseline-copy.tsv"
assert_eq "$(ls -1a "$KEMPT_STATE_DIR"/snapshots/.atomic.* 2>/dev/null | wc -l)" "0" "the rebase leaves no temp files behind"

# --- BOOT SESSION GATE: only a reboot can apply a staged transaction. "The installed set moved"
# never was evidence of that - a manual `dnf install cowsay` between staging and the reboot used
# to consume the marker and report someone else's package as "offline (applied on reboot)", and
# the real staged transaction was then never reported at all.
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
cp "$TESTTMP/rb-staged.tsv" "$WORLD/rpm.tsv"
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
pre_boot="$(jq -r .pre_snapshot "$marker")"
assert_eq "$(jq -r '.boot_id | length > 0' "$marker")" "true" "staging records the boot session"
# Not just speed here - this makes the probe BIND. The "no new entry" assertion below counts
# files, so a buggy same-second harvest that OVERWROTE the staging entry would leave the count
# unchanged and pass. With the staging entry moved out of the way, a harvest that fires has
# nowhere to hide: it writes a new name and the count goes up.
push_history_back
ls -1 "$KEMPT_STATE_DIR"/history/*.json | sort > "$TESTTMP/hist-before.txt"
# somebody installs a package by hand before rebooting
printf 'bash\t5.2.37-1.fc44\ncowsay\t3.04-1.fc44\nkernel-core\t6.15.3-200.fc44\nzsh\t5.9-11.fc44\n' > "$WORLD/rpm.tsv"
: > "$WORLD/notifications"
"$KEMPT" check >/dev/null 2>&1
assert_exit 0 "a manual install before the reboot leaves the stage pending" -- test -f "$marker"
assert_exit 0 "...and the marker's snapshot copy with it" -- test -f "$pre_boot"
ls -1 "$KEMPT_STATE_DIR"/history/*.json | sort > "$TESTTMP/hist-after.txt"
assert_eq "$(comm -13 "$TESTTMP/hist-before.txt" "$TESTTMP/hist-after.txt" | wc -l)" "0" \
  "...and records no history entry for a transaction that has not happened"
assert_eq "$(wc -c < "$WORLD/notifications")" "0" "...and tells the user nothing was applied"

# the reboot itself: same package set, different boot session → NOW it is harvested
simulate_reboot
push_history_back   # `ls | tail -1` below must find the harvest, not an entry it collided with
"$KEMPT" check >/dev/null 2>&1
[[ ! -f "$marker" ]] && echo "ok: the reboot consumes the marker" || { echo "FAIL: marker survived a real reboot"; _fail=1; }
hb2="$KEMPT_STATE_DIR/history/$(ls -1 "$KEMPT_STATE_DIR/history" | tail -1)"
assert_eq "$(jq -r .surface "$hb2")" "offline (applied on reboot)" "the staged transaction is reported after the reboot"
assert_eq "$(jq -r '[.backends.dnf.added[].name] | index("cowsay") != null' "$hb2")" "true" \
  "the post-reboot diff reports what actually changed since staging"
grep -q NOTIFY "$WORLD/notifications" && echo "ok: and the user is told" || { echo "FAIL: no harvest notification"; _fail=1; }

# The harvest notification uses the same counts phrase as a live run: a staged transaction that
# only installed or removed packages must never be announced as "0 packages".
grep -qE '0 (packages )?updated|no package changes' "$WORLD/notifications" \
  && { echo "FAIL: harvest notification claimed nothing happened"; _fail=1; } \
  || echo "ok: the harvest notification counts installs, not just upgrades"
grep -q '+1 installed' "$WORLD/notifications" && echo "ok: it names the install" || { echo "FAIL: harvest notify installs - got: $(cat "$WORLD/notifications")"; _fail=1; }

# ...but a box with no readable /proc/sys/kernel/random/boot_id records "unknown", and an unknown
# session must NOT gate the harvest forever - it falls back to the old snapshot comparison.
# Both sides read "unknown" here, which is exactly the case a bare equality test would swallow.
export KEMPT_BOOT_ID=unknown
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
cp "$TESTTMP/rb-staged.tsv" "$WORLD/rpm.tsv"
: > "$WORLD/notifications"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
assert_eq "$(jq -r .boot_id "$marker")" "unknown" "a box without a readable boot id stages an unknown session"
cp "$TESTTMP/rb-reboot.tsv" "$WORLD/rpm.tsv"
push_history_back   # `ls | tail -1` below must find the harvest, not the staging entry
"$KEMPT" check >/dev/null 2>&1
[[ ! -f "$marker" ]] && echo "ok: an unknown boot session falls back to the snapshot comparison" \
  || { echo "FAIL: an unknown boot session gated the harvest forever"; _fail=1; }
hu="$KEMPT_STATE_DIR/history/$(ls -1 "$KEMPT_STATE_DIR/history" | tail -1)"
assert_eq "$(jq -r .surface "$hu")" "offline (applied on reboot)" "...and still reports the staged transaction"
unset KEMPT_BOOT_ID

finish
