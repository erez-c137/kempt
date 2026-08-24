#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
UPKEEP="$REPO_ROOT/bin/upkeep"

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
  flatpak-update)  : ;;   # no flatpak changes in this fake world
esac
exit 0
STUB
chmod +x "$TESTTMP/apply-stub"
cp "$TESTTMP/apply-stub" "$TESTTMP/apply-stub.orig"   # probes that swap it restore from here
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub"
cat > "$TESTTMP/notify-stub" <<STUB
#!/usr/bin/env bash
echo "NOTIFY \$@" >> "$WORLD/notifications"
STUB
chmod +x "$TESTTMP/notify-stub"
export UPKEEP_APPLY_HELPER="$TESTTMP/apply-stub"
export UPKEEP_REFRESH_HELPER="$TESTTMP/refresh-stub"
export UPKEEP_NOTIFY="$TESTTMP/notify-stub"
export UPKEEP_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
export UPKEEP_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export UPKEEP_FLATPAK_LIST_CMD="cat $WORLD/fp.tsv"
export UPKEEP_SKIP_REFRESH=1
# The reboot check is the backend's (dnf_reboot_needed), so it is stubbed through the backend's
# own seam: UPKEEP_DNF_CMD, exit 1 = reboot needed, exit 0 = not needed.
printf '#!/usr/bin/env bash\nexit 1\n' > "$TESTTMP/dnf-reboot-yes"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"
chmod +x "$TESTTMP/dnf-reboot-yes" "$TESTTMP/dnf-reboot-no"
export UPKEEP_DNF_CMD="$TESTTMP/dnf-reboot-yes"

# A staged transaction can only be applied by a REBOOT, and the marker records the boot session
# it was staged in. Nothing else in a test can change /proc, so "the machine rebooted" is
# simulated by rewriting that field - which is exactly what the harvest gates on.
simulate_reboot() {
  local m="$UPKEEP_STATE_DIR/offline_staged.json"
  [[ -f "$m" ]] || return 0
  jq '.boot_id = "00000000-0000-0000-0000-000000000000"' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
}

"$UPKEEP" config set surface background
"$UPKEEP" hold dnf:vim-common

out="$("$UPKEEP" update)"
hist="$(ls "$UPKEEP_STATE_DIR/history/" | tail -1)"
h="$UPKEEP_STATE_DIR/history/$hist"
assert_eq "$(jq -r .status "$h")" "ok" "history status ok"
assert_eq "$(jq '.backends.dnf.updated | length' "$h")" "2" "dnf updated from snapshot diff"
assert_eq "$(jq -r '.backends.dnf.skipped_held[0]' "$h")" "vim-common" "held pkg recorded as skipped"
assert_eq "$(jq -r .reboot_needed "$h")" "true" "reboot flag captured"
grep -q -- '--exclude=vim-common' "$WORLD/apply-calls" && echo "ok: hold became --exclude" || { echo "FAIL: exclude"; _fail=1; }
grep -q 'flatpak-update' "$WORLD/apply-calls" && echo "ok: flatpak ran" || { echo "FAIL: flatpak"; _fail=1; }
grep -q NOTIFY "$WORLD/notifications" && echo "ok: non-terminal surface notified" || { echo "FAIL: notify"; _fail=1; }

# A CLI-only user must not be left staring at a pending list the run already emptied: the run
# refreshes the state itself instead of waiting for the widget to come along and do it.
assert_exit 0 "update self-refreshes the state" -- test -f "$UPKEEP_STATE_DIR/state.json"
assert_eq "$(jq '.backends.dnf.items | length' "$UPKEEP_STATE_DIR/state.json")" "7" \
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
arout="$("$UPKEEP" update --no-flatpak)"
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
# absent from the installed list, and the root helper's installed-set check is only a BACKSTOP —
# it must never be what stops it, or a normal run would die on "not installed".
: > "$WORLD/apply-calls"
"$UPKEEP" hold flatpak:org.gimp.GIMP
"$UPKEEP" update >/dev/null
assert_eq "$(grep 'flatpak-update' "$WORLD/apply-calls")" "APPLY flatpak-update -y net.mkiol.SpeechNote" \
  "flatpak hold → per-app update of the pending, non-held, installed app only"
grep -q 'com.example.NotInstalled' "$WORLD/apply-calls" && { echo "FAIL: uninstalled app reached the helper"; _fail=1; } \
  || echo "ok: pending-but-not-installed app never reaches the privileged helper"
"$UPKEEP" unhold flatpak:org.gimp.GIMP

# A typo'd flag must never be treated as "run with the configured defaults".
assert_exit 2 "unknown update option rejected" "$UPKEEP" update --bogus

# auto_accept=false is enforced in cmd_update ITSELF, not only in cmd_run: `upkeep update` is a
# real entry point (widget/cron/user), and only a terminal can answer dnf5's prompt. So the run
# is forced to the terminal surface and -y must NOT reach the privileged helper.
: > "$WORLD/apply-calls"
"$UPKEEP" config set auto_accept false
# dnf-reboot-no → rc 0 → no reboot needed: the everyday case, and the one the reboot-needed
# stub above can never prove.
UPKEEP_DNF_CMD="$TESTTMP/dnf-reboot-no" "$UPKEEP" update >/dev/null
h2="$UPKEEP_STATE_DIR/history/$(ls "$UPKEEP_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .reboot_needed "$h2")" "false" "no-reboot-needed run completes and records false"
assert_eq "$(jq -r .surface "$h2")" "terminal" "auto_accept=false forces the terminal surface"
assert_eq "$(grep -c -- ' -y' "$WORLD/apply-calls")" "0" "auto_accept=false never sends -y to the helper"
"$UPKEEP" config set auto_accept true

# An unknown surface must not silently mean "detached, and definitely not offline". auto_accept is
# true again here, so terminal can ONLY have come from the surface guard.
surferr="$("$UPKEEP" update --surface=bogus 2>&1 >/dev/null)"
grep -q "unknown surface 'bogus'" <<<"$surferr" && echo "ok: unknown surface warns" || { echo "FAIL: surface warning"; _fail=1; }
hs="$UPKEEP_STATE_DIR/history/$(ls "$UPKEEP_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .surface "$hs")" "terminal" "unknown surface falls back to terminal in update"

# offline surface: stage instead of upgrading live, and leave a marker owning its OWN copy of the
# pre-snapshot (a later update overwrites dnf-before.tsv, and the harvest still has to diff
# against the state as it was when the transaction was staged).
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
"$UPKEEP" update --surface=offline >/dev/null
grep -q 'dnf-offline-stage' "$WORLD/apply-calls" && echo "ok: offline stages the transaction" || { echo "FAIL: offline stage"; _fail=1; }
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && { echo "FAIL: offline also upgraded live"; _fail=1; } || echo "ok: offline did not upgrade live"
marker="$UPKEEP_STATE_DIR/offline_staged.json"
assert_exit 0 "offline marker written" -- test -f "$marker"
pre="$(jq -r .pre_snapshot "$marker")"
assert_exit 0 "marker owns its own pre-snapshot copy" -- test -f "$pre"
[[ "$pre" != "$UPKEEP_STATE_DIR/snapshots/dnf-before.tsv" ]] && echo "ok: copy is not the shared before-snapshot" \
  || { echo "FAIL: marker points at the reusable dnf-before.tsv"; _fail=1; }
grep -q 'staged' "$WORLD/notifications" && echo "ok: offline notification says staged" || { echo "FAIL: offline notify"; _fail=1; }

# The run is over the moment the helper returns: a report step that dies afterwards would take the
# HISTORY ENTRY and the notification down with it, leaving a system that changed and a CLI that
# says nothing happened. Fail the AFTER-snapshot only (2nd call in a run) and demand a clean,
# honest, empty report instead of a crash — and never a report claiming everything was removed.
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
snaperr="$(UPKEEP_DNF_INSTALLED_CMD="$TESTTMP/flaky-installed" "$UPKEEP" update --no-flatpak 2>&1 >/dev/null)" || snaprc=$?
assert_eq "$snaprc" "0" "a broken after-snapshot never crashes the run"
h3="$UPKEEP_STATE_DIR/history/$(ls "$UPKEEP_STATE_DIR/history/" | tail -1)"
grep -q 'snapshot after the run failed' <<<"$snaperr" && echo "ok: broken after-snapshot warns" || { echo "FAIL: snapshot warning"; _fail=1; }
assert_eq "$(jq -r .status "$h3")" "ok" "a broken report does not turn a good run into a failure"
assert_eq "$(jq '.backends.dnf.updated + .backends.dnf.removed | length' "$h3")" "0" \
  "broken after-snapshot degrades to an empty report, never phantom removals"

# every run since the staging rewrote dnf-before.tsv, and the marker's own copy is still there
assert_exit 0 "marker snapshot survives later runs" -- test -f "$pre"

# A pre-run snapshot that cannot be read means we could never say what changed, so the run stops
# BEFORE touching anything - loudly, with its own exit code, and the detached user is told.
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
prc=0
perr="$(UPKEEP_DNF_INSTALLED_CMD=false "$UPKEEP" update --surface=background 2>&1 >/dev/null)" || prc=$?
assert_eq "$prc" "5" "unreadable package set aborts pre-flight with exit 5"
grep -q 'cannot read the installed package set' <<<"$perr" \
  && echo "ok: pre-flight failure says what went wrong" || { echo "FAIL: preflight message - got: $perr"; _fail=1; }
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "pre-flight abort changes nothing"
grep -q 'did not start' "$WORLD/notifications" \
  && echo "ok: a detached user is told the run never started" || { echo "FAIL: preflight notify"; _fail=1; }
# same for the optional backend: it must not die silently through errexit either
frc=0
ferr="$(UPKEEP_FLATPAK_LIST_CMD=false "$UPKEEP" update 2>&1 >/dev/null)" || frc=$?
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
export UPKEEP_REFRESH_HELPER="$TESTTMP/risky-stub"

# [a]bort: nothing runs, nothing is recorded, rc 0 - the user declined, that is not a failure
: > "$WORLD/apply-calls"
hist_n="$(ls "$UPKEEP_STATE_DIR"/history/*.json | wc -l)"
arc=0
aout="$(UPKEEP_ASSUME_TTY=1 "$UPKEEP" update --surface=terminal <<<"a" 2>/dev/null)" || arc=$?
assert_eq "$arc" "0" "declining a risky update is not an error"
grep -q 'session-critical' <<<"$aout" && echo "ok: recommendation explains the risk" || { echo "FAIL: recommendation text"; _fail=1; }
grep -q 'kernel-core' <<<"$aout" && echo "ok: recommendation names the package" || { echo "FAIL: risky list"; _fail=1; }
grep -q 'bash' <<<"$aout" && { echo "FAIL: ordinary package listed as risky"; _fail=1; } || echo "ok: ordinary packages stay out of the list"
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "abort runs no privileged command"
assert_eq "$(ls "$UPKEEP_STATE_DIR"/history/*.json | wc -l)" "$hist_n" "abort records no run"
# "no residue" now means NOT LOCKED (flock leaves the file in place; only the lock matters)
assert_exit 0 "abort leaves the lock free" -- flock -n "$UPKEEP_STATE_DIR/lock" true

# [s]tage offline instead: the recommendation is actionable, not just advice
: > "$WORLD/apply-calls"
UPKEEP_ASSUME_TTY=1 "$UPKEEP" update --surface=terminal <<<"s" >/dev/null 2>&1
grep -q 'dnf-offline-stage' "$WORLD/apply-calls" && echo "ok: [s] switches the run to offline staging" || { echo "FAIL: stage offline"; _fail=1; }
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && { echo "FAIL: [s] upgraded live anyway"; _fail=1; } || echo "ok: [s] never upgrades live"
# only the newest staging can ever be harvested, so older copies are swept, not accumulated
assert_eq "$(ls "$UPKEEP_STATE_DIR"/snapshots/offline-pre-*.tsv | wc -l)" "1" "staging sweeps orphaned pre-snapshots"
assert_exit 0 "the surviving copy is the one the marker points at" \
  -- test -f "$(jq -r .pre_snapshot "$UPKEEP_STATE_DIR/offline_staged.json")"

# [u]pdate live: the user always decides
: > "$WORLD/apply-calls"
UPKEEP_ASSUME_TTY=1 "$UPKEEP" update --surface=terminal <<<"u" >/dev/null 2>&1
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && echo "ok: [u] proceeds with the live upgrade" || { echo "FAIL: update live"; _fail=1; }

# Saying NO to a risk warning must never proceed - the answer people actually type is "n".
# The trailing "u" is the point: if "n" were ever treated as an unrecognised answer, the
# re-prompt would swallow it and the run would proceed on an answer meant to stop it.
: > "$WORLD/apply-calls"
nrc=0
printf 'n\nu\n' | UPKEEP_ASSUME_TTY=1 "$UPKEEP" update --surface=terminal >/dev/null 2>&1 || nrc=$?
assert_eq "$nrc" "0" "declining with n exits 0"
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "n means no: nothing is applied"

# no answer at all (Enter, or EOF from a closed stdin) is NOT consent
: > "$WORLD/apply-calls"
UPKEEP_ASSUME_TTY=1 "$UPKEEP" update --surface=terminal </dev/null >/dev/null 2>&1
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "an unanswered risk warning defaults to abort"
: > "$WORLD/apply-calls"
printf '\nu\n' | UPKEEP_ASSUME_TTY=1 "$UPKEEP" update --surface=terminal >/dev/null 2>&1
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "pressing Enter defaults to abort"

# gibberish gets one more chance, then aborts rather than guessing
: > "$WORLD/apply-calls"
printf 'x\nx\n' | UPKEEP_ASSUME_TTY=1 "$UPKEEP" update --surface=terminal >/dev/null 2>&1
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "two unparseable answers abort"
: > "$WORLD/apply-calls"
printf 'x\nu\n' | UPKEEP_ASSUME_TTY=1 "$UPKEEP" update --surface=terminal >/dev/null 2>&1
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && echo "ok: the re-prompt accepts a valid second answer" || { echo "FAIL: re-prompt"; _fail=1; }

# --- bounded output: a real Qt or KDE bump matches by the hundred (168 on this box), and a wall
# of names is not a recommendation anyone can act on.
{ for i in 01 02 03 04 05 06 07 08 09 10 11 12; do printf 'qt6-qtmod%s.x86_64   6.9.1-1.fc44   updates\n' "$i"; done
  for i in 01 02 03 04 05; do printf 'kf6-kmod%s.x86_64   6.18.0-1.fc44   updates\n' "$i"; done
  printf 'kernel-core.x86_64   6.15.4-200.fc44   updates\n'
  printf 'mesa-libGL.x86_64   25.2.1-1.fc44   updates\n'
  printf 'kwin-x11.x86_64   6.5.1-1.fc44   updates\n'
  printf 'kernel-devel.x86_64   6.15.4-200.fc44   updates\n'; } > "$TESTTMP/risky-check.txt"
big="$(UPKEEP_ASSUME_TTY=1 "$UPKEEP" update --surface=terminal <<<"a" 2>/dev/null)"
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
"$UPKEEP" update --surface=background >/dev/null 2>&1
grep -q '20 session-critical packages pending (kernel, kf6, kwin, mesa, ...)' "$WORLD/notifications" \
  && echo "ok: notification summarises by family, capped at 4" || { echo "FAIL: family summary - got: $(cat "$WORLD/notifications")"; _fail=1; }
grep -q 'qtmod' "$WORLD/notifications" && { echo "FAIL: individual names leaked into the notification"; _fail=1; } \
  || echo "ok: no wall of package names in a notification"
printf 'kernel-core.x86_64   6.15.4-200.fc44   updates\nbash.x86_64   5.3.10-1.fc44   updates\n' > "$TESTTMP/risky-check.txt"

# The lock is NOT held while a human deliberates: the recommendation runs before acquire_lock, so
# a prompt left open over lunch never blocks the timer's next run, and an abort leaves no residue.
{ sleep 1; echo a; } | UPKEEP_ASSUME_TTY=1 "$UPKEEP" update --surface=terminal >/dev/null 2>&1 &
bgpid=$!
sleep 0.4
if kill -0 "$bgpid" 2>/dev/null && flock -n "$UPKEEP_STATE_DIR/lock" true; then
  echo "ok: no lock is held while the recommendation waits for an answer"
else echo "FAIL: lock held (or run already over) during the prompt"; _fail=1; fi
wait "$bgpid" || true

# A detached surface must not prompt even when it happens to have a terminal on stdin: the surface
# itself says nobody is watching, and a background run must never block waiting on a human.
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
UPKEEP_ASSUME_TTY=1 "$UPKEEP" update --surface=background <<<"a" >/dev/null 2>&1
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && echo "ok: background surface proceeds instead of prompting" \
  || { echo "FAIL: background surface prompted and was aborted"; _fail=1; }

# detached surface: nobody is there to answer a prompt, so it warns and proceeds
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
"$UPKEEP" update --surface=background >/dev/null 2>&1
grep -q 'session-critical' "$WORLD/notifications" && echo "ok: detached surface gets a heads-up" || { echo "FAIL: detached heads-up"; _fail=1; }
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && echo "ok: detached surface proceeds anyway" || { echo "FAIL: detached proceed"; _fail=1; }

# an offline run is already the recommendation - it must not nag about taking its own advice
: > "$WORLD/notifications"
"$UPKEEP" update --surface=offline >/dev/null 2>&1
grep -q 'session-critical' "$WORLD/notifications" && { echo "FAIL: offline run still recommended offline"; _fail=1; } \
  || echo "ok: offline surface skips the recommendation"
export UPKEEP_REFRESH_HELPER="$TESTTMP/refresh-stub"

# second update while the lock is REALLY held → refuses. A background holder takes the same
# flock the CLI takes, so this exercises the kernel's answer, not a heuristic about a pid file.
hold_lock() {  # → sets $holder; returns once the lock is genuinely held
  rm -f "$TESTTMP/held-flag"
  ( exec 8>"$UPKEEP_STATE_DIR/lock"; flock 8; touch "$TESTTMP/held-flag"; sleep 30 ) &
  holder=$!
  local w=0
  until [[ -f "$TESTTMP/held-flag" ]] || (( w > 100 )); do sleep 0.05; w=$(( w + 1 )); done
  [[ -f "$TESTTMP/held-flag" ]] || { echo "FAIL: background lock holder never started"; _fail=1; }
}
mkdir -p "$UPKEEP_STATE_DIR"
hold_lock
assert_exit 3 "concurrent update refused" "$UPKEEP" update
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true

# ...and a lock whose holder was SIGKILLed must not freeze updates forever (the restic lock that
# silently froze retention for 8 days). With flock there is nothing to clear: the kernel drops it
# when the fd closes, however the process died.
hold_lock
kill -9 "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
assert_exit 0 "a killed holder's lock is gone by construction" "$UPKEEP" update --no-flatpak

# A failure that is NOT a busy package lock must fail at once: retrying a full disk three times
# just makes the user wait three times as long for the same bad news.
cat > "$TESTTMP/apply-stub" <<'STUB'
#!/usr/bin/env bash
echo "Error: No space left on device" >&2; exit 1
STUB
export UPKEEP_RETRY_DELAY=0
assert_exit 1 "a non-lock failure fails immediately" "$UPKEEP" update --no-flatpak
assert_eq "$(grep -c 'retrying' "$(ls -t "$UPKEEP_STATE_DIR"/logs/* | head -1)")" "0" "only package-lock errors are retried"

# helper failure with lock-ish stderr → retried then fails cleanly.
# --no-flatpak keeps the retry count scoped to ONE apply call (both backends would retry).
cat > "$TESTTMP/apply-stub" <<'STUB'
#!/usr/bin/env bash
echo "cannot open lock file: held by another process" >&2; exit 1
STUB
export UPKEEP_RETRY_DELAY=0
assert_exit 1 "busy rpm lock eventually fails" "$UPKEEP" update --no-flatpak
assert_eq "$(grep -c 'retrying' "$(ls -t "$UPKEEP_STATE_DIR"/logs/* | head -1)")" "2" "two retries logged"
# 3 attempts = 2 retries: the last failure must not promise a retry that never comes.
assert_eq "$(grep -c 'giving up' "$(ls -t "$UPKEEP_STATE_DIR"/logs/* | head -1)")" "1" "gives up loudly after the last attempt"

# --- offline harvest: the staged transaction applies during a reboot, and the next check has to
# notice and turn it into a normal history entry + notification.
# The marker OWNS its pre-snapshot copy and harvest deletes it, so a marker must never point at a
# shared file — pointing this one at tests/fixtures/ would delete a repo fixture.
pre_copy="$UPKEEP_STATE_DIR/snapshots/offline-pre-harvest.tsv"
cp "$FIXTURES/snap-before.tsv" "$pre_copy"
jq -n --arg snap "$pre_copy" '{staged_at:"x", pre_snapshot:$snap}' > "$UPKEEP_STATE_DIR/offline_staged.json"
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub"

# not applied yet (reboot hasn't happened): the installed set still matches the pre-snapshot
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
before_n="$(ls "$UPKEEP_STATE_DIR"/history/*.json | wc -l)"
"$UPKEEP" check >/dev/null
assert_exit 0 "unapplied stage keeps its marker" -- test -f "$UPKEEP_STATE_DIR/offline_staged.json"
assert_eq "$(ls "$UPKEEP_STATE_DIR"/history/*.json | wc -l)" "$before_n" "unapplied stage records nothing"

# applied on reboot: the installed set moved
cp "$FIXTURES/snap-after.tsv" "$WORLD/rpm.tsv"
: > "$WORLD/notifications"
sleep 1   # history filenames are per-second; keep the harvested entry from landing on an older one
"$UPKEEP" check >/dev/null
[[ ! -f "$UPKEEP_STATE_DIR/offline_staged.json" ]] && echo "ok: marker consumed" || { echo "FAIL: marker"; _fail=1; }
ls "$UPKEEP_STATE_DIR"/history/*.json >/dev/null 2>&1 && echo "ok: harvest wrote history" || { echo "FAIL: harvest"; _fail=1; }
assert_eq "$(ls "$UPKEEP_STATE_DIR"/history/*.json | wc -l)" "$((before_n + 1))" "exactly one history entry harvested"
hh="$UPKEEP_STATE_DIR/history/$(ls "$UPKEEP_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .surface "$hh")" "offline (applied on reboot)" "harvested entry names the surface"
assert_eq "$(jq '.backends.dnf.updated | length' "$hh")" "2" "harvest diffs against the marker's own snapshot"
assert_exit 0 "harvest removes the snapshot copy it owned" -- test ! -f "$pre_copy"
grep -q NOTIFY "$WORLD/notifications" && echo "ok: harvest notifies" || { echo "FAIL: harvest notify"; _fail=1; }

# a consumed marker must not be harvested twice (a second entry would double-count the run)
"$UPKEEP" check >/dev/null
assert_eq "$(ls "$UPKEEP_STATE_DIR"/history/*.json | wc -l)" "$((before_n + 1))" "harvest does not repeat"

# cmd_update prints the rendered summary on stdout — that is the terminal surface's whole point
# ($out was captured from the very first run, before the stub renderer was replaced)
grep -q 'kernel-core 6.15.3-200.fc44 → 6.15.4-200.fc44' <<<"$out" && echo "ok: update printed a rendered summary" \
  || { echo "FAIL: update printed no summary — got: $out"; _fail=1; }

# --- a LIVE run must not let its own closing self-refresh mis-harvest a PENDING offline stage.
# The staged transaction applies only on reboot, but a live run moves the rpm snapshot too — so
# the self-refresh saw "the installed set changed", harvested immediately, labelled the LIVE
# delta "offline (applied on reboot)" and consumed the marker. The staged transaction then
# applied at the next reboot and was never reported at all. Three distinct worlds below:
# staged (baseline) → live (a live run bumped bash) → reboot (the staged kernel landed).
printf 'bash\t5.2.37-1.fc44\nkernel-core\t6.15.3-200.fc44\nzsh\t5.9-11.fc44\n' > "$TESTTMP/rb-staged.tsv"
printf 'bash\t5.2.38-1.fc44\nkernel-core\t6.15.3-200.fc44\nzsh\t5.9-11.fc44\n' > "$TESTTMP/rb-live.tsv"
printf 'bash\t5.2.38-1.fc44\nkernel-core\t6.15.4-200.fc44\nzsh\t5.9-11.fc44\n' > "$TESTTMP/rb-reboot.tsv"
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
[[ "\$1" == dnf-upgrade ]] && cp "$TESTTMP/rb-live.tsv" "$WORLD/rpm.tsv"
exit 0
STUB
marker="$UPKEEP_STATE_DIR/offline_staged.json"
cp "$TESTTMP/rb-staged.tsv" "$WORLD/rpm.tsv"
rm -f "$marker" "$UPKEEP_STATE_DIR"/snapshots/offline-pre-*.tsv
: > "$WORLD/apply-calls"
"$UPKEEP" update --surface=offline --no-flatpak >/dev/null 2>&1
assert_exit 0 "offline stage left a marker to rebase" -- test -f "$marker"
ls -1 "$UPKEEP_STATE_DIR"/history/*.json | sort > "$TESTTMP/hist-before.txt"
sleep 1   # per-second history filenames: keep the live run off the staging run's name
"$UPKEEP" update --surface=background --no-flatpak >/dev/null 2>&1
assert_exit 0 "a live run leaves a pending offline marker in place" -- test -f "$marker"
ls -1 "$UPKEEP_STATE_DIR"/history/*.json | sort > "$TESTTMP/hist-after.txt"
comm -13 "$TESTTMP/hist-before.txt" "$TESTTMP/hist-after.txt" > "$TESTTMP/hist-new.txt"
assert_eq "$(wc -l < "$TESTTMP/hist-new.txt")" "1" "the live run records ONE entry, not one plus a phantom harvest"
assert_eq "$(jq -r .surface "$(head -1 "$TESTTMP/hist-new.txt")")" "background" "the entry is the live run, not a mislabelled harvest"

# ...and after the reboot that actually applies it, the harvest reports the STAGED delta only
cp "$TESTTMP/rb-reboot.tsv" "$WORLD/rpm.tsv"
simulate_reboot
sleep 1
"$UPKEEP" check >/dev/null 2>&1
[[ ! -f "$marker" ]] && echo "ok: the post-reboot check consumes the marker" || { echo "FAIL: marker survived the reboot"; _fail=1; }
hr="$UPKEEP_STATE_DIR/history/$(ls -1 "$UPKEEP_STATE_DIR/history" | tail -1)"
assert_eq "$(jq -r .surface "$hr")" "offline (applied on reboot)" "the reboot result is harvested as an offline run"
assert_eq "$(jq -c '[.backends.dnf.updated[].name]' "$hr")" '["kernel-core"]' \
  "the harvest diffs the rebased baseline: only the staged package, not the live run's bash"

# --- history filenames are per-second, and a harvest fires from a check a live run may have
# triggered in the same second. An existing entry must never be overwritten.
pre2="$UPKEEP_STATE_DIR/snapshots/offline-pre-collide.tsv"
cp "$TESTTMP/rb-live.tsv" "$pre2"
jq -n --arg snap "$pre2" '{staged_at:"x", pre_snapshot:$snap}' > "$marker"
cp "$TESTTMP/rb-reboot.tsv" "$WORLD/rpm.tsv"
decoys=()
for off in 0 1 2 3; do
  d="$UPKEEP_STATE_DIR/history/$(date -d "+$off seconds" +%Y%m%dT%H%M%S).json"
  printf 'DECOY\n' > "$d"; decoys+=("$d")
done
"$UPKEEP" check >/dev/null 2>&1
assert_eq "$(ls -1 "$UPKEEP_STATE_DIR"/history/*-offline.json 2>/dev/null | wc -l)" "1" \
  "a same-second harvest takes its own filename"
assert_eq "$(cat "${decoys[@]}" | grep -c DECOY)" "4" "no existing history entry was overwritten"
rm -f "${decoys[@]}"

# --- the lock-retry window is PER ATTEMPT. dnf fails three times on a busy package lock, then
# flatpak fails on a full disk in the SAME log: a fixed `tail -n 20` re-reads dnf's lock errors,
# calls the disk failure a lock too, and retries a run that was never going to succeed.
cat > "$TESTTMP/apply-stub" <<'STUB'
#!/usr/bin/env bash
echo "APPLY $@" >> "$WORLD/apply-calls"
case "$1" in
  dnf-upgrade)    echo "cannot open lock file: held by another process" >&2 ;;
  flatpak-update) echo "Error: No space left on device" >&2 ;;
esac
exit 1
STUB
: > "$WORLD/apply-calls"
export UPKEEP_RETRY_DELAY=0
assert_exit 1 "a lock-then-disk run fails" "$UPKEEP" update --surface=background
mixed_log="$(ls -t "$UPKEEP_STATE_DIR"/logs/*.log | head -1)"
assert_eq "$(grep -c '^APPLY' "$WORLD/apply-calls")" "4" "3 dnf attempts + exactly ONE flatpak attempt"
assert_eq "$(grep -c 'retrying' "$mixed_log")" "2" "the disk failure is never retried as a lock error"

# --- double staging leaves ONE pre-snapshot: only the newest can ever be harvested, so an
# un-swept copy is dead weight that accumulates one file per staged run, forever.
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"
rm -f "$marker" "$UPKEEP_STATE_DIR"/snapshots/offline-pre-*.tsv
"$UPKEEP" update --surface=offline --no-flatpak >/dev/null 2>&1
first_pre="$(jq -r .pre_snapshot "$marker")"
sleep 1   # per-second names: without this the second staging would reuse the first one's file
"$UPKEEP" update --surface=offline --no-flatpak >/dev/null 2>&1
second_pre="$(jq -r .pre_snapshot "$marker")"
[[ "$first_pre" != "$second_pre" ]] && echo "ok: the second staging really wrote a new copy" \
  || { echo "FAIL: both stagings used one filename - the sweep was never exercised"; _fail=1; }
assert_eq "$(ls -1 "$UPKEEP_STATE_DIR"/snapshots/offline-pre-*.tsv | wc -l)" "1" \
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
rm -f "$marker" "$UPKEEP_STATE_DIR"/snapshots/offline-pre-*.tsv
cp "$TESTTMP/rb-staged.tsv" "$WORLD/rpm.tsv"
: > "$WORLD/apply-calls"
"$UPKEEP" update --surface=offline --no-flatpak >/dev/null 2>&1
cp "$TESTTMP/rb-applied.tsv" "$WORLD/rpm.tsv"   # the reboot applied it; no check has run yet
simulate_reboot
ls -1 "$UPKEEP_STATE_DIR"/history/*.json | sort > "$TESTTMP/hist-before.txt"
sleep 1
"$UPKEEP" update --surface=background --no-flatpak >/dev/null 2>&1
[[ ! -f "$marker" ]] && echo "ok: an already-applied stage is harvested, never swallowed by a rebase" \
  || { echo "FAIL: the staged transaction was folded into the baseline and lost"; _fail=1; }
ls -1 "$UPKEEP_STATE_DIR"/history/*.json | sort > "$TESTTMP/hist-after.txt"
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
assert_eq "$(ls -1 "$UPKEEP_STATE_DIR"/snapshots/offline-pre-*.tsv 2>/dev/null | wc -l)" "0" \
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
rm -f "$marker" "$UPKEEP_STATE_DIR"/snapshots/offline-pre-*.tsv
cp "$TESTTMP/rb-staged.tsv" "$WORLD/rpm.tsv"
: > "$WORLD/apply-calls"
"$UPKEEP" update --surface=offline --no-flatpak >/dev/null 2>&1
pre_c="$(jq -r .pre_snapshot "$marker")"
cp "$pre_c" "$TESTTMP/baseline-copy.tsv"
: > "$WORLD/apply-calls"
sleep 1
UPKEEP_DNF_INSTALLED_CMD="$TESTTMP/partial-installed" "$UPKEEP" update --surface=background --no-flatpak >/dev/null 2>&1
assert_exit 0 "a truncated after-snapshot leaves the marker in place" -- test -f "$marker"
assert_exit 0 "...and never overwrites its baseline with the truncation" -- cmp -s "$pre_c" "$TESTTMP/baseline-copy.tsv"
assert_eq "$(ls -1a "$UPKEEP_STATE_DIR"/snapshots/.atomic.* 2>/dev/null | wc -l)" "0" "the rebase leaves no temp files behind"

# --- BOOT SESSION GATE: only a reboot can apply a staged transaction. "The installed set moved"
# never was evidence of that - a manual `dnf install cowsay` between staging and the reboot used
# to consume the marker and report someone else's package as "offline (applied on reboot)", and
# the real staged transaction was then never reported at all.
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"
rm -f "$marker" "$UPKEEP_STATE_DIR"/snapshots/offline-pre-*.tsv
cp "$TESTTMP/rb-staged.tsv" "$WORLD/rpm.tsv"
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
"$UPKEEP" update --surface=offline --no-flatpak >/dev/null 2>&1
pre_boot="$(jq -r .pre_snapshot "$marker")"
assert_eq "$(jq -r '.boot_id | length > 0' "$marker")" "true" "staging records the boot session"
ls -1 "$UPKEEP_STATE_DIR"/history/*.json | sort > "$TESTTMP/hist-before.txt"
# somebody installs a package by hand before rebooting
printf 'bash\t5.2.37-1.fc44\ncowsay\t3.04-1.fc44\nkernel-core\t6.15.3-200.fc44\nzsh\t5.9-11.fc44\n' > "$WORLD/rpm.tsv"
: > "$WORLD/notifications"
sleep 1
"$UPKEEP" check >/dev/null 2>&1
assert_exit 0 "a manual install before the reboot leaves the stage pending" -- test -f "$marker"
assert_exit 0 "...and the marker's snapshot copy with it" -- test -f "$pre_boot"
ls -1 "$UPKEEP_STATE_DIR"/history/*.json | sort > "$TESTTMP/hist-after.txt"
assert_eq "$(comm -13 "$TESTTMP/hist-before.txt" "$TESTTMP/hist-after.txt" | wc -l)" "0" \
  "...and records no history entry for a transaction that has not happened"
assert_eq "$(wc -c < "$WORLD/notifications")" "0" "...and tells the user nothing was applied"

# the reboot itself: same package set, different boot session → NOW it is harvested
simulate_reboot
sleep 1
"$UPKEEP" check >/dev/null 2>&1
[[ ! -f "$marker" ]] && echo "ok: the reboot consumes the marker" || { echo "FAIL: marker survived a real reboot"; _fail=1; }
hb2="$UPKEEP_STATE_DIR/history/$(ls -1 "$UPKEEP_STATE_DIR/history" | tail -1)"
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

finish
