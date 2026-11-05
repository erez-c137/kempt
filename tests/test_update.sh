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
# A fresh check that finds nothing to update.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/refresh-stub.nothing-pending"
chmod +x "$TESTTMP/refresh-stub.nothing-pending"
cat > "$TESTTMP/notify-stub" <<STUB
#!/usr/bin/env bash
echo "NOTIFY \$@" >> "$WORLD/notifications"
STUB
chmod +x "$TESTTMP/notify-stub"
# The same stand-in that also writes down what state.json says is staged at the moment the
# notification goes out: the order of the two is what the widget sees, not just the end result.
cat > "$TESTTMP/notify-stub.state" <<STUB
#!/usr/bin/env bash
echo "NOTIFY \$@" >> "$WORLD/notifications"
jq -c '.offline_staged.armed // "absent"' "$KEMPT_STATE_DIR/state.json" >> "$WORLD/notify-state" 2>/dev/null \
  || echo unreadable >> "$WORLD/notify-state"
STUB
chmod +x "$TESTTMP/notify-stub.state"
export KEMPT_APPLY_HELPER="$TESTTMP/apply-stub"
export KEMPT_FLATPAK_UPDATE_CMD="$TESTTMP/fp-update-stub"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_NOTIFY="$TESTTMP/notify-stub"
export KEMPT_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export KEMPT_FLATPAK_LIST_CMD="cat $WORLD/fp.tsv"
# The SNAPSHOT seam reads the same world file. It is a separate command because the real one asks
# flatpak for the deployed commit as well, and apply_flatpak_updates uses the snapshot as its
# installed-set filter, so a run whose snapshot is empty hands flatpak no ids at all.
export KEMPT_FLATPAK_SNAP_CMD="cat $WORLD/fp.tsv"
export KEMPT_SKIP_REFRESH=1
# The reboot check is the backend's (dnf_reboot_needed), so it is stubbed through the backend's
# own seam: KEMPT_DNF_CMD. "Reboot needed" is rc 1 PLUS the package list on stdout - rc 1 with an
# empty stdout is how the real command reports that it could not answer, and answers false.
write_reboot_stub "$TESTTMP/dnf-reboot-yes"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"
chmod +x "$TESTTMP/dnf-reboot-no"
export KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-yes"

# Applying an offline transaction REMOVES dnf5's state toml, transaction.json and /system-update.
# Verified against dnf5 5.4.3 in a container (`dnf5 offline _execute`, all three gone afterwards).
simulate_reboot() {
  export KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml"
  export KEMPT_OFFLINE_LINK="$TESTTMP/no-system-update"
}
# What the newest run recorded as staged: the count every surface repeats.
last_staged() { jq -r .staged "$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"; }
# ...and back to a box carrying an armed transaction, for the blocks that stage again afterwards.
# Both halves, lib.sh's default pair: the `ready` toml and the /system-update symlink.
transaction_armed() { export KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml"
                      export KEMPT_OFFLINE_LINK="$TESTTMP/system-update"; }
# A Fedora RELEASE upgrade, stored in the same file and armed the same way. The fixture's keys are
# dnf5's own output, captured from `dnf5 system-upgrade download --releasever=45` on Fedora 44.
release_upgrade_staged() { export KEMPT_OFFLINE_TOML="$FIXTURES/offline-release-upgrade.toml"; }
# ARMED is two things. Nothing else in this file creates the boot symlink, so without this every
# release-upgrade case ran in the STRANDED state and the armed branch was never executed at all -
# proved by replacing it with a marker string and watching the file stay green.
relup_link_on()  { ln -sfn "$TESTTMP" "$TESTTMP/relup-system-update"
                   export KEMPT_OFFLINE_LINK="$TESTTMP/relup-system-update"; }
relup_link_off() { export KEMPT_OFFLINE_LINK="$TESTTMP/no-system-update"; }
# The same two halves for an ordinary stage. A `ready` toml alone is not armed: any live dnf5
# transaction removes /system-update and leaves the status as it was.
stage_link_on()  { ln -sfn "$TESTTMP" "$TESTTMP/stage-system-update"
                   export KEMPT_OFFLINE_LINK="$TESTTMP/stage-system-update"; }
stage_link_off() { export KEMPT_OFFLINE_LINK="$TESTTMP/no-system-update"; }
transaction_gone()  { export KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml"; }

# History filenames are per-second, and $ts comes from `date` INSIDE cmd_update -
# so a test can never choose the name the NEXT run will write. The `sleep 1`s that used to sit at
# every call site below were only ever buying the other half of that: no entry ALREADY ON DISK
# sitting on the second the next run is about to use. Moving the written entries is free, so this
# does that instead, and the suite stops paying a second per collision.
# Renames rather than `touch -d`: the collision is on the FILENAME. mtime only drives the
# 50-entry prune in kempt_init_dirs, which nothing here is near.
# Five minutes back, one distinct second per entry, and the -offline suffix the restart report's
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

"$KEMPT" config set surface widget
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

# ...but a pending RUNTIME is still updated, even with every app held. Runtimes cannot be held, so
# "every app is held" says nothing about them - and `flatpak update` would have updated them anyway,
# which is the disagreement between the count and the transaction this whole area exists to end.
# The runtime seams are pinned at `true` for the rest of this file (sandbox), so this is the one
# block where a runtime is pending at all.
: > "$WORLD/apply-calls"
KEMPT_FLATPAK_REMOTE_RUNTIME_CMD="cat $FIXTURES/flatpak-remote-ls-runtime.tsv" \
KEMPT_FLATPAK_LIST_RUNTIME_CMD="cat $FIXTURES/flatpak-list-runtime.tsv" \
  "$KEMPT" update >/dev/null
assert_eq "$(grep '^FLATPAK' "$WORLD/apply-calls")" "FLATPAK --noninteractive -y --runtime" \
  "every app held but a runtime pending → the runtimes are still updated, as one command"
# Guards the pair: the apps really are all held, so that single line is the runtime arm and not an
# app slipping through it.
assert_eq "$(grep -c '^FLATPAK' "$WORLD/apply-calls")" "1" \
  "...and no app is named, because every one of them is held"

# ...and the lookup that builds that per-app list FAILING is not "nothing pending". It used to be
# swallowed to an empty list, so a run with a flatpak hold and a broken remote updated no app and
# reported flatpak "ok". It is the error it is, the way the installed lookup beside it already was.
"$KEMPT" unhold flatpak:net.mkiol.SpeechNote
: > "$WORLD/apply-calls"
fl_rc=0
fl_err="$(KEMPT_FLATPAK_REMOTE_CMD=false "$KEMPT" update --surface=widget 2>&1 >/dev/null)" || fl_rc=$?
fl_hist="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .backends.flatpak.status "$fl_hist")" "failed" \
  "a flatpak hold with a failed update lookup reports flatpak failed, not ok"
assert_eq "$fl_rc" "1" "...and fails the run, as a failed dnf lookup does"
assert_contains "$fl_err" "flatpak update lookup failed" "...saying which lookup failed"
assert_eq "$(grep -c '^FLATPAK' "$WORLD/apply-calls" || true)" "0" "...and runs flatpak on nothing it could not list"
assert_eq "$(grep -c '^APPLY dnf-upgrade' "$WORLD/apply-calls" || true)" "1" "...on a run that did reach it"

"$KEMPT" unhold flatpak:org.gimp.GIMP

# No flatpak command on the box and include_flatpak never set: the run skips Flatpak, as it does
# with include_flatpak=false, rather than reporting a Flatpak half that could never run.
: > "$WORLD/apply-calls"
nofp_rc=0
KEMPT_FLATPAK_LIST_CMD="kempt-no-such-flatpak list" KEMPT_FLATPAK_SNAP_CMD="kempt-no-such-flatpak list" \
  "$KEMPT" update --surface=widget >/dev/null 2>&1 || nofp_rc=$?
nofp_hist="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$nofp_rc" "0" "no flatpak at the default: the run succeeds"
assert_eq "$(jq -r .backends.flatpak.status "$nofp_hist")" "skipped" "...with Flatpak skipped, not failed"
assert_eq "$(grep -c '^FLATPAK' "$WORLD/apply-calls" || true)" "0" "...and never run"
assert_eq "$(grep -c '^APPLY dnf-upgrade' "$WORLD/apply-calls" || true)" "1" "...on a run that updated dnf"

# A typo'd flag must never be treated as "run with the configured defaults".
assert_exit 2 "unknown update option rejected" "$KEMPT" update --bogus

# auto_accept=false asks a person, and only a person at a terminal can answer. With nobody there
# the command refuses and changes nothing, unless a press in the widget already answered.
: > "$WORLD/apply-calls"
"$KEMPT" config set auto_accept false
rc=0; norun_err="$("$KEMPT" update 2>&1 >/dev/null </dev/null)" || rc=$?
assert_eq "$rc" "5" "auto_accept=false with stdin closed: refused"
assert_contains "$norun_err" "nothing was changed" "...and says so"
assert_eq "$(grep -cE '^(APPLY|FLATPAK)' "$WORLD/apply-calls" || true)" "0" "...and neither dnf nor Flatpak ran"
rc=0; python3 -c 'import pty, sys; sys.exit(pty.spawn(sys.argv[1:]) >> 8)' bash -c '"$0" update | tee /dev/null; exit "${PIPESTATUS[0]}"' "$KEMPT" >/dev/null 2>&1 </dev/null || rc=$?
assert_eq "$rc" "5" "auto_accept=false on a pty piped through tee: refused"
assert_eq "$(grep -cE '^(APPLY|FLATPAK)' "$WORLD/apply-calls" || true)" "0" "...and neither dnf nor Flatpak ran"
# dnf-reboot-no → rc 0 → no reboot needed: the everyday case, and the one the reboot-needed
# stub above can never prove.
KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no" "$KEMPT" update --answered >/dev/null
h2="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .reboot_needed "$h2")" "false" "no-reboot-needed run completes and records false"
assert_eq "$(jq -r .surface "$h2")" "popup" "auto_accept=false leaves the surface alone"
assert_eq "$(grep -c '^APPLY dnf-upgrade.* -y' "$WORLD/apply-calls")" "1" "...and a press in the widget sends -y"
: > "$WORLD/apply-calls"
# At a terminal: dnf5 cannot ask from a service, so without -y it shows what it would do and stops,
# and only a yes given here runs it with -y.
cat > "$TESTTMP/apply-asks" <<EOF
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
if [[ " \$* " == *" -y "* ]]; then echo "the update runs"; exit 0; fi
if [[ -e "$TESTTMP/preview-fails" ]]; then echo "Failed to download metadata"; exit 1; fi
if [[ -e "$TESTTMP/preview-empty" ]]; then echo "Nothing to do."; exit 0; fi
echo "Upgrading: vim"; echo "Is this ok [y/N]: Operation aborted by the user."; exit 1
EOF
chmod +x "$TESTTMP/apply-asks"
asked() {  # answer-or-nothing surface → the helper calls, one a line; rc in asked_rc, output in asked_out
  : > "$WORLD/apply-calls"; asked_rc=0
  asked_out="$(KEMPT_ASSUME_TTY=1 KEMPT_APPLY_HELPER="$TESTTMP/apply-asks" KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no" \
    "$KEMPT" update --no-flatpak --surface="$2" <<<"$1" 2>&1)" || asked_rc=$?
  "$KEMPT" unstage >/dev/null 2>&1 || true
}
calls() { grep -E "^APPLY $1" "$WORLD/apply-calls" | sed 's/^APPLY //; s/ --exclude=[^ ]*//g' | tr '\n' ';'; }
asked y popup
assert_eq "$(calls dnf-upgrade)" "dnf-upgrade;dnf-upgrade -y;" "auto_accept=false at a terminal: first what it would do, then with -y on a yes"
assert_contains "$asked_out" "Upgrading: vim" "...the person sees what it would do"
assert_contains "$asked_out" "the update runs" "...and the update"
assert_eq "$asked_rc" "0" "...and a yes ends well"
asked n popup
assert_eq "$(calls dnf-upgrade)" "dnf-upgrade;" "a no: nothing with -y"
assert_contains "$asked_out" "Answered no, so nothing was changed." "...and it says so"
asked "" popup
assert_eq "$(calls dnf-upgrade)" "dnf-upgrade;" "no answer at all is a no"
touch "$TESTTMP/preview-fails"; asked y popup; rm -f "$TESTTMP/preview-fails"
assert_eq "$(calls dnf-upgrade)" "dnf-upgrade;" "a first run that failed asks nothing and goes no further"
assert_contains "$asked_out" "Failed to download metadata" "...and shows why"
touch "$TESTTMP/preview-empty"; asked y popup; rm -f "$TESTTMP/preview-empty"
assert_eq "$(calls dnf-upgrade)" "dnf-upgrade;" "nothing to do asks nothing"
assert_eq "$asked_rc" "0" "...and is no failure"
asked y offline
assert_eq "$(calls dnf-offline-stage)" "dnf-offline-stage;dnf-offline-stage -y;" "a stage asks the same way"
asked n offline
assert_eq "$(calls dnf-offline-stage)" "dnf-offline-stage;" "...and a no stores nothing"
assert_eq "$(calls dnf-offline-arm)" "" "...and arms nothing"
"$KEMPT" config set auto_accept true
asked "" popup
assert_eq "$(calls dnf-upgrade)" "dnf-upgrade -y;" "auto_accept on: straight to -y, with nothing asked"

# Ctrl-C: dnf5 runs on, so there is no result to report and no failure to record.
cat > "$TESTTMP/apply-watch-stopped" <<EOF
#!/usr/bin/env bash
echo "kempt-apply: stopped watching. An update that has started carries on to the end, and dnf5 history list shows how it ended." >&2
exit 130
EOF
chmod +x "$TESTTMP/apply-watch-stopped"
hist_before="$(ls "$KEMPT_STATE_DIR/history/" | wc -l)"
: > "$WORLD/notifications"
for tty in "" 1; do
  rc=0; ctrlc_out="$(KEMPT_ASSUME_TTY=$tty KEMPT_APPLY_HELPER="$TESTTMP/apply-watch-stopped" "$KEMPT" update --no-flatpak --surface=popup 2>&1 </dev/null)" || rc=$?
  assert_eq "$rc" "130" "the watching stopped (terminal='$tty'): kempt update ends with 130"
done
assert_contains "$ctrlc_out" "carries on to the end" "...and the person reads what happens to the update"
assert_not_contains "$ctrlc_out" "Update failed" "...and is not told it failed"
assert_eq "$(ls "$KEMPT_STATE_DIR/history/" | wc -l)" "$hist_before" "...and no run is recorded as ended"
assert_eq "$(tail -n 1 "$KEMPT_STATE_DIR/events.log" | grep -c 'Stopped watching')" "1" "...and the event log says the watching stopped"
assert_eq "$(wc -l < "$WORLD/notifications")" "0" "...and no notification says it did"
if flock -n "$KEMPT_STATE_DIR/lock" true 2>/dev/null; then echo "ok: ...and the lock is free for the next run"; else echo "FAIL: lock still held"; _fail=1; fi
# Ctrl-C reaches every process of the terminal's group, tee too. Its line must still get through.
cat > "$TESTTMP/apply-wait-for-int" <<EOF
#!/usr/bin/env bash
trap 'sleep 0.3; echo "the words after Ctrl-C" >&2; exit 130' INT
: > "$TESTTMP/apply-waiting"
for _ in {1..100}; do sleep 0.1; done
exit 1
EOF
chmod +x "$TESTTMP/apply-wait-for-int"
ctrlc_group="$(KEMPT_ASSUME_TTY=1 KEMPT_APPLY_HELPER="$TESTTMP/apply-wait-for-int" python3 - "$KEMPT" "$TESTTMP/apply-waiting" <<'PY'
import os, signal, subprocess, sys, time
def fresh():
    for s in (signal.SIGINT, signal.SIGQUIT, signal.SIGHUP, signal.SIGTERM):
        signal.signal(s, signal.SIG_DFL)
p = subprocess.Popen([sys.argv[1], "update", "--no-flatpak", "--surface=popup"], stdin=subprocess.DEVNULL,
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True, preexec_fn=fresh)
for _ in range(300):
    if os.path.exists(sys.argv[2]):
        break
    time.sleep(0.1)
time.sleep(0.3)
os.killpg(p.pid, signal.SIGINT)
print(p.communicate(timeout=30)[0].decode(errors="replace"))
print("rc=%d" % p.returncode)
PY
)"
assert_contains "$ctrlc_group" "the words after Ctrl-C" "Ctrl-C to the whole terminal group: the helper's last words still reach the person"
assert_contains "$ctrlc_group" "rc=130" "...and kempt update ends with 130"

# A next run while dnf5 goes on: the fixed unit name refuses, in words a person can use.
cat > "$TESTTMP/apply-busy" <<EOF
#!/usr/bin/env bash
echo "Failed to start transient service unit: Unit kempt-apply-dnf-upgrade.service was already loaded or has a fragment file." >&2
exit 1
EOF
chmod +x "$TESTTMP/apply-busy"
busy_out="$(KEMPT_APPLY_HELPER="$TESTTMP/apply-busy" "$KEMPT" update --no-flatpak --surface=popup 2>&1 </dev/null)" || true
assert_contains "$busy_out" "the update started earlier is still running, so nothing new was started" "a run over one still going says so"

# An unknown surface must not silently mean offline.
surferr="$("$KEMPT" update --surface=bogus 2>&1 >/dev/null)"
grep -q "surface='bogus' is not a known value" <<<"$surferr" && echo "ok: unknown surface warns" || { echo "FAIL: surface warning"; _fail=1; }
hs="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .surface "$hs")" "popup" "unknown surface falls back to the widget in update"

# offline surface: stage instead of upgrading live.
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
"$KEMPT" update --surface=offline >/dev/null
grep -q 'dnf-offline-stage' "$WORLD/apply-calls" && echo "ok: offline stages the transaction" || { echo "FAIL: offline stage"; _fail=1; }
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && { echo "FAIL: offline also upgraded live"; _fail=1; } || echo "ok: offline did not upgrade live"
# auto_accept off: a stage asked for at a terminal stays a stage, without -y first, so the person is asked.
# Without a terminal the stage still runs, with -y, because nobody can answer.
pty_run() { python3 -c 'import pty, sys; sys.exit(pty.spawn(sys.argv[1:]) >> 8)' "$@"; }
"$KEMPT" config set auto_accept false
: > "$WORLD/apply-calls"
pty_run "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 </dev/null || true
assert_eq "$(grep -c '^APPLY dnf-offline-stage' "$WORLD/apply-calls")" "1" \
  "auto_accept=false at a terminal: --surface=offline stages"
assert_eq "$(grep -c '^APPLY dnf-upgrade' "$WORLD/apply-calls")" "0" "...and never upgrades live"
assert_eq "$(grep -c -- ' -y' "$WORLD/apply-calls")" "0" "...and has gone no further than showing it, with no yes given"
: > "$WORLD/apply-calls"
rc=0; "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 </dev/null || rc=$?
assert_eq "$rc" "5" "auto_accept=false with no terminal: no stage either"
assert_eq "$(grep -cE '^(APPLY|FLATPAK)' "$WORLD/apply-calls" || true)" "0" "...and nothing ran"
"$KEMPT" update --answered --surface=offline --no-flatpak >/dev/null 2>&1 </dev/null || true
assert_eq "$(grep -c '^APPLY dnf-offline-stage.* -y' "$WORLD/apply-calls")" "1" \
  "...while a press stages, with -y"
assert_eq "$(grep -c '^APPLY dnf-upgrade' "$WORLD/apply-calls")" "0" "...and it never upgrades live"
"$KEMPT" config set auto_accept true
"$KEMPT" unstage >/dev/null 2>&1 || true
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=offline >/dev/null

grep -q 'are ready' "$WORLD/notifications" && echo "ok: offline notification says the updates are ready" || { echo "FAIL: offline notify"; _fail=1; }
# A run that DID stage carries no staged_nothing key. The key exists so the popup can tell this run
# apart from one that staged nothing, and absence is how a real stage says so - which also keeps
# every entry written before the key existed reading as what it is.
stgd_hist="$KEMPT_STATE_DIR/history/$(ls -1 "$KEMPT_STATE_DIR/history" | tail -1)"
assert_eq "$(jq -r 'has("staged_nothing")' "$stgd_hist")" "false" \
  "...and its history entry does not claim nothing was staged"
# ...and records how many it staged, so history and summary can say it.
assert_eq "$(jq -r '.staged | type' "$stgd_hist")" "number" "...and its history entry records the staged count"
assert_eq "$(jq -r .staged "$stgd_hist")" "3" "...the count in dnf5's stored list"
assert_eq "$(jq -r 'has("stage_blocked")' "$stgd_hist")" "false" "...and no blocked flag with no other updater"
assert_eq "$("$KEMPT" history | awk 'NR==1' | grep -c " offline  ok  staged $(jq -r .staged "$stgd_hist") update[s]* for a restart")" "1" \
  "...and kempt history says what was staged, not \"no package changes\""

# ARMING, which is the whole difference between a staged transaction and one that installs. dnf5
# leaves a staged transaction at status="download-complete" and NO boot applies that; `dnf5 offline
# reboot` is what flips it to "ready" and creates /system-update. Staging without arming is what
# shipped first, and it meant "Install on Next Restart" quietly never installed anything, on any
# number of restarts. The ORDER is asserted, not just the presence: arming before the transaction
# exists arms nothing.
stage_ln="$(grep -n 'APPLY dnf-offline-stage' "$WORLD/apply-calls" | awk 'NR==1' | cut -d: -f1 || true)"
arm_ln="$(grep -n 'APPLY dnf-offline-arm' "$WORLD/apply-calls" | awk 'NR==1' | cut -d: -f1 || true)"
[[ -n "$stage_ln" && -n "$arm_ln" && "$arm_ln" -gt "$stage_ln" ]] \
  && echo "ok: the run stages the transaction and then arms it" \
  || { echo "FAIL: stage-then-arm (stage=${stage_ln:-none} arm=${arm_ln:-none})"; _fail=1; }
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "0" \
  "an armed stage is not immediately thrown away again"
# The SAME count the event line carries: both answer "how many updates is the person waiting for",
# and two different numbers on two surfaces for one transaction is a bug report waiting to happen.
staged_ev="$(grep ' Staged [0-9?]' "$KEMPT_STATE_DIR/events.log" | tail -1 | sed 's/.* Staged \([^ ]*\) .*/\1/')"
assert_eq "$(last_staged)" "$staged_ev" \
  "the history entry carries the same staged count the event line reports"

# --- the RUN publishes the stage, rather than leaving it to the check behind it ------------------
# THE PROBLEM: cmd_update ends with a best-effort check, and that check is where offline_staged is
# normally computed. Its dnf half takes tens of seconds on a real box, and for that whole window
# the popup carried the finished run's report - "Updates are staged" - beside the pre-run banner
# still offering Install on Next Restart, under a header still counting those updates as available,
# with Update Now live underneath. Both buttons rebuild a transaction that is already downloaded
# and armed; measured on a real 19-package stage, that is 618 MB thrown away by the obvious press.
#
# PROVED BY TAKING THE CHECK LOCK AWAY. A check that cannot have the lock serves the previous state
# and writes nothing (cmd_check's flock branch), so whatever is in state.json when the run returns
# was put there by the RUN. `kempt update` works under the update lock and never touches this one,
# so holding it cannot stall the stage - test_check.sh pins that independence from the other side.
# Everything this borrows goes back afterwards: the sections below run against the world THIS
# section found, and a stage of its own would leave them a different baseline.
cp "$KEMPT_STATE_DIR/state.json" "$TESTTMP/state.before-publish" 2>/dev/null || true
transaction_armed
: > "$WORLD/apply-calls"
# A state file with no staged key, which is what one written before the stage looks like.
jq -n '{schema: 1, last_check: "2026-01-01T00:00:00+00:00", actionable: 19}' \
  > "$KEMPT_STATE_DIR/state.json"
( flock 9; sleep 10 ) 9>"$KEMPT_STATE_DIR/check.lock" &
lockpid=$!
# Wait for the holder to actually have it: starting the run first would race the background shell.
for _i in $(seq 1 100); do
  flock -w 0 -n "$KEMPT_STATE_DIR/check.lock" true 2>/dev/null || break
  sleep 0.02
done
rm -f "$TESTTMP/closing-mark" "$WORLD/notify-state"
KEMPT_CLOSING_CHECK_MARK="$TESTTMP/closing-mark" KEMPT_CHECK_LOCK_WAIT=0 \
  KEMPT_NOTIFY="$TESTTMP/notify-stub.state" \
  "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
kill "$lockpid" 2>/dev/null || true
wait "$lockpid" 2>/dev/null || true
# The closing check lost the lock and served the previous state. The mark would make the update
# window skip its own check, which is now the only one left to run.
assert_exit 1 "a closing check that lost the lock does not claim to have checked" -- \
  test -e "$TESTTMP/closing-mark"
assert_eq "$(jq -r '.offline_staged.armed // "absent"' "$KEMPT_STATE_DIR/state.json")" "true" \
  "the run records the staged transaction itself, without waiting for a check"
assert_eq "$(jq -r '.offline_staged.count // "absent"' "$KEMPT_STATE_DIR/state.json")" \
  "$(last_staged)" "...carrying the run's count, so no surface has to guess"
# ...and it is there BEFORE the notification. The widget leaves its busy state on a state.json
# change, so a stage published after "Updates are staged" kept the popup busy beside that message.
assert_eq "$(cat "$WORLD/notify-state" 2>/dev/null)" "true" \
  "the state already holds the stage when the notification goes out"
# The rest of the state is LEFT ALONE. This is not a check and must not date itself as one: a fresh
# last_check over counts nobody re-read is a worse lie than the one being fixed.
assert_eq "$(jq -r '.last_check' "$KEMPT_STATE_DIR/state.json")" "2026-01-01T00:00:00+00:00" \
  "...and does not stamp the state with a check that never ran"
assert_eq "$(jq -r '.actionable' "$KEMPT_STATE_DIR/state.json")" "19" \
  "...nor rewrite counts it did not re-read"
cp "$TESTTMP/state.before-publish" "$KEMPT_STATE_DIR/state.json" 2>/dev/null || true

# Another updater's symlink that appears while the stage downloads, past the gate that refuses one
# already there. Prints the stand-in helper to use; the real work goes on to the helper it is given.
link_appears_mid_stage() {  # next-helper → helper
  local mid="$1.link-mid"
  rm -f "$TESTTMP/foreign-system-update"
  cat > "$mid" <<STUB
#!/usr/bin/env bash
[[ "\$1" == dnf-offline-stage ]] && ln -sfn /var/lib/PackageKit/prepared-update "$TESTTMP/foreign-system-update"
exec "$1" "\$@"
STUB
  chmod +x "$mid"
  printf '%s\n' "$mid"
}

# A stage made as another updater's symlink arrives. dnf5 creates /system-update only when it is
# absent, so the arm succeeds and the next restart installs the other updater's update. The run
# must not promise the restart. Borrowed and given back like the section above.
mid_helper="$(link_appears_mid_stage "$TESTTMP/apply-stub")"
: > "$WORLD/notifications"
KEMPT_OFFLINE_LINK="$TESTTMP/foreign-system-update" KEMPT_APPLY_HELPER="$mid_helper" \
  "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>"$TESTTMP/foreign.err" || true
assert_contains "$(cat "$WORLD/notifications")" "another updater has prepared the next restart, so they will not install then" \
  "a stage behind another updater's symlink is not promised for the restart"
assert_not_contains "$(cat "$WORLD/notifications")" "install on the next restart" "...in any words"
assert_contains "$(cat "$TESTTMP/foreign.err")" "the updates staged here will not install then" "...and the terminal says so too"
assert_eq "$(jq -r '.offline_stage_blocked.count // "absent"' "$KEMPT_STATE_DIR/state.json")" \
  "3" "...and the state carries the blocked stage for the widget"
assert_eq "$(jq -r '.offline_staged // "absent"' "$KEMPT_STATE_DIR/state.json")" "absent" "...not a pending one"
assert_eq "$(jq -r '.restart_holder' "$KEMPT_STATE_DIR/state.json")" "other" "...and it names who holds the restart now"
fghist="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r '[.status, .stage_blocked] | @tsv' "$fghist")" "ok	true" \
  "...and its history entry marks the stage as blocked"
assert_contains "$("$KEMPT" history | awk 'NR==1')" ", but another updater had already prepared a restart" \
  "...so history does not promise the restart either"
cp "$TESTTMP/state.before-publish" "$KEMPT_STATE_DIR/state.json" 2>/dev/null || true


# An arm that fails leaves a transaction that would sit in the offline directory forever, telling
# every later check and the doctor that an install is pending when nothing will ever apply it. So
# the run FAILS and unwinds: discard the stage and say why.
cat > "$TESTTMP/apply-stub.armfail" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
[[ "\$1" == dnf-offline-arm ]] && { echo "Failed to prepare the system-update symlink" >&2; exit 1; }
exit 0
STUB
chmod +x "$TESTTMP/apply-stub.armfail"
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
armrc=0
KEMPT_APPLY_HELPER="$TESTTMP/apply-stub.armfail" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || armrc=$?
assert_eq "$armrc" "1" "a run that could not arm its stage fails"
grep -q 'APPLY dnf-offline-clean' "$WORLD/apply-calls" \
  && echo "ok: the stage it could not arm is discarded" || { echo "FAIL: no unwind after a failed arm"; _fail=1; }
armhist="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .status "$armhist")" "failed" "...and the history entry says the run failed"
assert_eq "$(jq -r .error "$armhist")" "the updates were downloaded, but could not be set to install on the next restart" \
  "...naming the step that failed, not the first error-shaped line in the log"
grep -q 'Update failed (exit code 1): the updates were downloaded, but could not be set to install on the next restart' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: the event log carries the same reason" || { echo "FAIL: arm failure event line"; _fail=1; }
grep -q 'Update failed: ' "$WORLD/notifications" \
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
assert_eq "$(jq -r .error "$bothhist")" "the updates were downloaded, but could not be set to install on the next restart" \
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

# A failed arm is not unwound behind another updater's /system-update. dnf5's clean removes that
# symlink whoever made it, which would cancel the other updater's restart install. The clean is
# skipped.
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
mid_helper="$(link_appears_mid_stage "$TESTTMP/apply-stub.armfail")"
: > "$WORLD/apply-calls"
armrc=0
KEMPT_OFFLINE_LINK="$TESTTMP/foreign-system-update" KEMPT_APPLY_HELPER="$mid_helper" \
  "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || armrc=$?
assert_eq "$armrc" "1" "an arm that fails behind another updater's symlink still fails the run"
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "0" \
  "...and the clean that would remove that symlink is never run"
assert_eq "$(tail -n 4 "$KEMPT_STATE_DIR/events.log" | grep -c 'Staged update left in place (another updater has prepared the next restart)')" "1" \
  "...and the log says why the stored one stayed"
afhist="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .error "$afhist")" \
  "the updates were downloaded, but another updater has prepared the next restart, so they will not install then. Try again after the restart" \
  "...and the reason says the download will not install at the restart"

# --- and the same escalation the other way round: nobody reads stderr in a panel ------------------
# A cleanup that failed leaves the box in the one state a person has to act on by hand, and the run
# that produced it is usually a click in the widget. The warning above goes to stderr and to a log
# file; the notification is the only surface that reaches the person who pressed the button, so it
# carries the command verbatim. The reason stays the ARM: the step that failed is what a reader
# has to chase, and the cleanup rides alongside it rather than replacing it.
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
KEMPT_APPLY_HELPER="$TESTTMP/apply-stub.bothfail" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || true
grep -qF 'See: kempt doctor' "$WORLD/notifications" \
  && echo "ok: the failure notification says where the fix for what is left is" \
  || { echo "FAIL: no clean command in the notification - got: $(cat "$WORLD/notifications")"; _fail=1; }
armdbl="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .error "$armdbl")" "the updates were downloaded, but could not be set to install on the next restart" \
  "...while the recorded reason still names the step that failed"

# --- a REBUILD whose STAGE fails, which is the state nothing used to unwind -----------------------
# Ground truth, container-verified: staging over an armed transaction is cancel-then-stage. The old
# transaction is destroyed the moment the re-stage begins, not swapped for the new one at the end.
# So a stage that fails leaves no transaction, a toml that is not `ready`, and the /system-update
# symlink still standing - and the next restart detours into the offline updater and installs
# nothing at all. Only a failed ARM used to unwind; a failed stage left exactly that behind.
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

: > "$WORLD/apply-calls"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
strc=0
# The toml this file pins is `ready`: dnf5 failed BEFORE replacing the previous transaction, which
# is what a download that cannot complete does (live container gate, 2026-09-05: toml ready,
# symlink present, old set untouched). There is nothing to unwind, and a clean here would throw
# away a perfectly good armed stage the user is still counting on.
stage_link_on   # armed is both halves: the toml says `ready` AND /system-update is there
KEMPT_APPLY_HELPER="$TESTTMP/apply-stub.stagefail" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || strc=$?
stage_link_off
assert_eq "$strc" "1" "a rebuild whose stage fails fails the run"
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "0" \
  "...and does NOT clean away the previous transaction dnf5 left armed"
grep -q 'Rebuilding the staged update failed (previous stage intact)' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...and the event log says the previous stage is intact" \
  || { echo "FAIL: no restage-failed event"; _fail=1; }
sthist="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .status "$sthist")" "failed" "...the history entry says the run failed"
assert_eq "$(jq -r .error "$sthist")" \
  "could not replace the prepared updates. The earlier ones are unchanged and still install on the next restart" \
  "...and the reason says the previous stage still installs, not that it was lost"

# ...but `ready` WITHOUT /system-update is not intact. Measured on Fedora 44: a live dnf5
# transaction deletes the symlink by itself and leaves the toml at `ready`, and `dnf5 offline
# status` then calls the transaction invalid. Calling that "unchanged and still installs" promised
# an install no restart would do; it is a leftover, and it takes the clean.
: > "$WORLD/apply-calls"
strc=0
KEMPT_APPLY_HELPER="$TESTTMP/apply-stub.stagefail" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || strc=$?
assert_eq "$strc" "1" "a rebuild whose stage fails over a stage not set to install fails the run"
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "1" \
  "...and cleans the stale stage, which no restart would install"
sthist="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
[[ "$(jq -r .error "$sthist")" == *"still installs on the next restart"* ]] \
  && { echo "FAIL: a stage not set to install was reported as still installing"; _fail=1; } \
  || echo "ok: ...and the reason does not claim it still installs"

# ...and a rebuild that failed after dnf5 replaced the old transaction (the toml is no longer
# `ready`), behind another updater's /system-update. The clean would remove that symlink and
# cancel the other updater's restart install, so it is skipped.
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
mid_helper="$(link_appears_mid_stage "$TESTTMP/apply-stub.stagefail")"
: > "$WORLD/apply-calls"
strc=0
KEMPT_OFFLINE_LINK="$TESTTMP/foreign-system-update" KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml" \
  KEMPT_APPLY_HELPER="$mid_helper" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || strc=$?
assert_eq "$strc" "1" "a rebuild that fails behind another updater's symlink fails the run"
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "0" \
  "...and never runs the clean that would remove that symlink"
sthist="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .error "$sthist")" \
  "could not replace the prepared updates, and the earlier ones are gone. Another updater has prepared the next restart. Try again after that restart" \
  "...and the reason says the old stage is gone and the restart installs the other update"
grep -q 'Rebuilding the staged update failed (stage left in place, another updater has prepared the next restart)' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...and the log says why nothing was cleaned" || { echo "FAIL: no event for the skipped clean"; _fail=1; }

# --- a stage with nothing in it is not a failed stage --------------------------------------------
# Hold your only pending update, then stage: `dnf5 upgrade --offline` prints "Nothing to do", exits
# 0 and stores no transaction, so arming fails with "No offline transaction is stored". Reported as
# "staged but could not arm the restart install", rc 1, with a FAILED notification - blaming the arm
# for a transaction that was never built, over the user's own holds doing exactly what they asked.
# Found by running it on a real machine with one pending update held.
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
before_hist_n="$(ls -1 "$KEMPT_STATE_DIR"/history/*.json 2>/dev/null | grep -c . || true)"
transaction_gone   # dnf5 stored nothing, which is what an empty transaction leaves behind
nrc=0
"$KEMPT" hold dnf:bash >/dev/null 2>&1
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || nrc=$?
assert_eq "$nrc" "0" "staging with nothing to stage is not a failure"
assert_eq "$(grep -c 'APPLY dnf-offline-arm' "$WORLD/apply-calls" || true)" "0" \
  "...and nothing is armed, because there is nothing to arm"
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "0" \
  "...and nothing is cleaned up, because nothing was made"
grep -q 'Staged ? updates' "$KEMPT_STATE_DIR/events.log" \
  && { echo "FAIL: the log says 'Staged ? updates' for a run that staged nothing"; _fail=1; } \
  || echo "ok: ...and no staged-count line contradicts it in the same second"
grep -q 'Nothing to stage (every pending update is held)' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: the event names the reason, so the log does not read as a fault" \
  || { echo "FAIL: no nothing-to-stage event"; _fail=1; grep 'Nothing\|Staged' "$KEMPT_STATE_DIR/events.log" | tail -3; }
grep -q 'Every waiting update is held, so the next restart has nothing to install' "$WORLD/notifications" \
  && echo "ok: ...and the user is told their holds did it, not that Kempt failed" \
  || { echo "FAIL: wrong notification"; _fail=1; cat "$WORLD/notifications"; }
grep -q 'could not be set to install' "$WORLD/notifications" \
  && { echo "FAIL: an empty transaction was blamed on the arm"; _fail=1; } \
  || echo "ok: ...and the arm is not blamed for a transaction that was never built"
nhist="$KEMPT_STATE_DIR/history/$(ls -1 "$KEMPT_STATE_DIR/history" | tail -1)"
assert_eq "$(jq -r .status "$nhist")" "ok" "...and the history entry records a run that succeeded"
# ...and records WHY nothing was staged, which is the only place a later reader can learn it. The
# event line and the notification above say it too, but they are spoken once; the popup's post-run
# line and its last-update row are rendered from this entry, and with only `surface` and `status`
# to go on both announced "Updates are staged - they install on the next restart" over a restart
# that installs nothing. `held` and not just "nothing", because "Kempt did nothing" reads as a
# fault where "every pending update is held" is the user's own holds working.
assert_eq "$(jq -r .staged_nothing "$nhist")" "held" \
  "...and says nothing was staged because every pending update is held"
assert_eq "$(jq -r 'has("staged")' "$nhist")" "false" "...and carries no staged count"
"$KEMPT" unhold dnf:bash >/dev/null 2>&1
transaction_armed

# --- the same empty stage over a transaction that is ALREADY stored ------------------------------
# Measured on Fedora 44, dnf5 5.4.1: with a transaction stored, `dnf5 upgrade --offline -y
# --exclude=<every pending package>` prints "Nothing to do.", exits 0 and leaves the stored
# transaction byte-identical, /system-update included. The next restart installs ALL of it,
# the package just held among them. Kempt used to see status `ready`, arm the old transaction
# again, log "offline restage" and report success: a hold that did nothing.
# The stub models exactly that: it prints dnf5's line and touches neither file this world reads.
cat > "$TESTTMP/apply-stub.nothing" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
[[ "\$1" == dnf-offline-stage ]] && echo "Nothing to do."
exit 0
STUB
chmod +x "$TESTTMP/apply-stub.nothing"
cat > "$TESTTMP/apply-stub.nothing-clean-fail" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
[[ "\$1" == dnf-offline-stage ]] && echo "Nothing to do."
[[ "\$1" == dnf-offline-clean ]] && exit 1
exit 0
STUB
chmod +x "$TESTTMP/apply-stub.nothing-clean-fail"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
"$KEMPT" hold dnf:bash >/dev/null 2>&1
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
nd_ev="$(wc -l < "$KEMPT_STATE_DIR/events.log")"
ndrc=0
KEMPT_APPLY_HELPER="$TESTTMP/apply-stub.nothing" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || ndrc=$?
assert_eq "$ndrc" "0" "an empty stage over a stored transaction is not a failure"
assert_eq "$(grep -c 'APPLY dnf-offline-arm' "$WORLD/apply-calls" || true)" "0" \
  "...and the old transaction is NOT armed again"
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "1" \
  "...it is cleaned away, so the held package does not install on the next restart"
tail -n +$(( nd_ev + 1 )) "$KEMPT_STATE_DIR/events.log" | grep -q 'Staged update rebuilt' \
  && { echo "FAIL: an empty stage over a stored one was logged as a restage"; _fail=1; } \
  || echo "ok: ...and the log does not call it a restage"
grep -q 'Staged update discarded' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...the log says the stored one was discarded" \
  || { echo "FAIL: no discarded event"; _fail=1; }
grep -q 'Every waiting update is held, so the next restart has nothing to install. The updates prepared earlier were removed' "$WORLD/notifications" \
  && echo "ok: ...and the user is told the earlier stage is gone" \
  || { echo "FAIL: wrong notification - got: $(cat "$WORLD/notifications")"; _fail=1; }
ndhist="$KEMPT_STATE_DIR/history/$(ls -1 "$KEMPT_STATE_DIR/history" | tail -1)"
assert_eq "$(jq -r .staged_nothing "$ndhist")" "held" "...and the history entry records nothing staged, because of holds"

# ...but not behind another updater's /system-update. dnf5's clean removes that symlink whoever
# made it, so it would cancel the other updater's restart install; the old transaction cannot
# install behind it anyway. The clean is skipped.
"$KEMPT" unhold dnf:bash >/dev/null 2>&1
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
"$KEMPT" hold dnf:bash >/dev/null 2>&1
ln -sfn /var/lib/PackageKit/prepared-update "$TESTTMP/foreign-system-update"
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
ndrc=0
KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub.nothing-pending" KEMPT_OFFLINE_LINK="$TESTTMP/foreign-system-update" \
  KEMPT_APPLY_HELPER="$TESTTMP/apply-stub.nothing" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || ndrc=$?
assert_eq "$ndrc" "0" "an empty stage behind another updater's symlink is not a failure"
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "0" \
  "...and the clean that would remove that symlink is never run"
assert_eq "$(grep -c 'APPLY dnf-offline-arm' "$WORLD/apply-calls" || true)" "0" "...nor the arm"
grep -q 'Staged update left in place (another updater has prepared the next restart)' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...and the log says why the stored one stayed" \
  || { echo "FAIL: no event for the stage left in place"; _fail=1; }
assert_eq "$(cat "$WORLD/notifications")" "NOTIFY Kempt Every waiting update is held, so the next restart has nothing to install" \
  "...and the notification claims no removal"

# ...and when the clean fails, the old transaction still installs, held package included: that is
# a failed run that names the command, never a success.
"$KEMPT" unhold dnf:bash >/dev/null 2>&1
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
"$KEMPT" hold dnf:bash >/dev/null 2>&1
: > "$WORLD/apply-calls"
ndrc=0
KEMPT_APPLY_HELPER="$TESTTMP/apply-stub.nothing-clean-fail" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || ndrc=$?
assert_eq "$ndrc" "1" "an empty stage whose clean fails fails the run"
assert_eq "$(grep -c 'APPLY dnf-offline-arm' "$WORLD/apply-calls" || true)" "0" "...without arming the old transaction"
ndhist="$KEMPT_STATE_DIR/history/$(ls -1 "$KEMPT_STATE_DIR/history" | tail -1)"
assert_eq "$(jq -r .error "$ndhist")" \
  "nothing new was prepared, and the earlier updates could not be removed, so they still install on the next restart, held packages included. See: kempt doctor" \
  "...and the reason says the old one still installs and how to clear it"
"$KEMPT" unhold dnf:bash >/dev/null 2>&1

# The other outcome: dnf5 got as far as replacing the previous transaction and then failed, so the
# toml is a partial stage nothing arms (download-complete) with the old boot symlink standing over
# it. That is the strand, and it is what the unwind is for.
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml" KEMPT_APPLY_HELPER="$TESTTMP/apply-stub.stagefail" \
  "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || true
grep -q 'APPLY dnf-offline-clean' "$WORLD/apply-calls" \
  && echo "ok: a re-stage that replaced the old transaction and then failed is cleaned up" \
  || { echo "FAIL: no unwind after a failed stage that replaced the old transaction"; _fail=1; }
sthist="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .status "$sthist")" "failed" "...the history entry says the run failed"
assert_eq "$(jq -r .error "$sthist")" "the earlier updates were removed and could not be prepared again" \
  "...naming what the user lost, not the first error-shaped line in the log"

# The double failure. The clean failed too, so the toml and the boot symlink disagree and only a
# person with root can fix it. `kempt doctor` fails on the symlink row and names the command.
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml" KEMPT_APPLY_HELPER="$TESTTMP/apply-stub.stage-clean-fail" \
  "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || true
grep -qF 'See: kempt doctor' "$WORLD/notifications" \
  && echo "ok: ...and the notification says where the fix is" \
  || { echo "FAIL: no clean command in the notification - got: $(cat "$WORLD/notifications")"; _fail=1; }
dblhist="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .error "$dblhist")" \
  "the earlier updates were removed and could not be prepared again or cleaned up. See: kempt doctor" \
  "...and the reason says so too, because there is nothing left to chase in the log"

# Nothing staged before the attempt: there is nothing to unwind, and a clean fired anyway would be
# a privileged call made for no reason. The reason comes from the log, as it always did.
: > "$WORLD/apply-calls"
KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml" KEMPT_APPLY_HELPER="$TESTTMP/apply-stub.stagefail" \
  "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || true
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "0" \
  "a first stage that fails unwinds nothing - there was nothing there"
nsthist="$KEMPT_STATE_DIR/history/$(ls "$KEMPT_STATE_DIR/history/" | tail -1)"
[[ "$(jq -r .error "$nsthist")" == "the earlier updates were removed and could not be prepared again" ]] \
  && { echo "FAIL: a first stage reported a previous one being lost"; _fail=1; } \
  || echo "ok: ...and says nothing about a previous stage that never existed"

# A stage that lost its restart step is staged again. dnf5 reuses the download it still holds, and a
# clean first would delete it, so the free route depends on this path never asking for one.
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
link_was="$KEMPT_OFFLINE_LINK"
stage_link_off
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "0" \
  "staging again after a lost stage cleans nothing, so the download is kept"
export KEMPT_OFFLINE_LINK="$link_was"

# A rebuild that WORKED, which is the whole point of the failure paths above: the run is what a
# hold-behind-a-stage tells the user to do, and the event log is the only record of why it ran.
# The conflicting holds are read BEFORE the stage, because afterwards the question cannot be asked
# again - the transaction that contained the held package is gone.
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
"$KEMPT" hold dnf:librepo >/dev/null 2>&1
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
grep -q 'Staged update rebuilt (holds: librepo)' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: a rebuild over a conflicting hold records the hold it was for" \
  || { echo "FAIL: no restage event - got: $(grep -c 'Staged update rebuilt' "$KEMPT_STATE_DIR/events.log" || true) restage lines"; _fail=1; }
"$KEMPT" unhold dnf:librepo >/dev/null 2>&1
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"
"$KEMPT" check >/dev/null

# --- and that count is asked for NOW. It is the only thing the user is ever told about a
# transaction they cannot open, it is what the popup and `kempt doctor` repeat back for as long as
# the stage is armed, and it used to be copied out of the last check's state.json - a number written
# by whatever check ran last, against different metadata, possibly days ago. dnf5's list decides.
"$KEMPT" check >/dev/null
fresh="$(jq -r '.backends.dnf.actionable' "$KEMPT_STATE_DIR/state.json")"
jq '.backends.dnf.actionable = 999' "$KEMPT_STATE_DIR/state.json" > "$TESTTMP/stale-state.json" \
  && mv "$TESTTMP/stale-state.json" "$KEMPT_STATE_DIR/state.json"
: > "$WORLD/timeline"
KEMPT_REFRESH_HELPER="$TESTTMP/refresh-timeline" KEMPT_APPLY_HELPER="$TESTTMP/apply-timeline" \
  "$KEMPT" update --surface=offline --no-flatpak >/dev/null
check_ln="$(grep -n 'REFRESH check' "$WORLD/timeline" | awk 'NR==1' | cut -d: -f1 || true)"
stage_ln="$(grep -n 'APPLY dnf-offline-stage' "$WORLD/timeline" | awk 'NR==1' | cut -d: -f1 || true)"
[[ -n "$check_ln" && -n "$stage_ln" && "$check_ln" -lt "$stage_ln" ]] \
  && echo "ok: the offline surface asks what is pending before it stages" \
  || { echo "FAIL: check-before-stage (check=${check_ln:-none} stage=${stage_ln:-none})"; _fail=1; }
assert_eq "$(last_staged)" "3" \
  "the count comes from what dnf5 stored, not from the state file it found"
staged_ev="$(grep ' Staged [0-9?]' "$KEMPT_STATE_DIR/events.log" | tail -1 | sed 's/.* Staged \([^ ]*\) .*/\1/')"
assert_eq "$staged_ev" "3" "...and so does the count on the event line"

# A check that cannot answer must not stop the stage. Losing a number is not worth refusing to
# update the machine, so it warns - the same shape the risky-transaction pre-check degrades in.
: > "$WORLD/apply-calls"
jq '.backends.dnf.actionable = 999' "$KEMPT_STATE_DIR/state.json" > "$TESTTMP/stale-state.json" \
  && mv "$TESTTMP/stale-state.json" "$KEMPT_STATE_DIR/state.json"
degraded="$(KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub.checkfails" \
  "$KEMPT" update --surface=offline --no-flatpak 2>&1 >/dev/null)" || true
grep -q 'APPLY dnf-offline-stage' "$WORLD/apply-calls" \
  && echo "ok: a check that could not answer still stages" || { echo "FAIL: degraded stage"; _fail=1; }
grep -q '^warning: ' <<<"$degraded" \
  && echo "ok: ...and says on stderr that the number is not fresh" \
  || { echo "FAIL: no warning - got: $degraded"; _fail=1; }
"$KEMPT" check >/dev/null

# A check on stale metadata finds nothing, and the stage, which fetches its own, stores updates.
# The count is then what the transaction holds: "Staged 0 updates" over a stage of three is wrong
# on every surface that repeats it.
"$KEMPT" hold dnf:curl >/dev/null 2>&1
cat > "$TESTTMP/refresh-stub.checknothing" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub.checknothing"
: > "$WORLD/apply-calls"
stale_out="$(KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub.checknothing" \
  "$KEMPT" update --surface=offline --no-flatpak 2>/dev/null)" || true
assert_eq "$(last_staged)" "3" "a check that found nothing gives way to the transaction's count"
staged_ev="$(grep ' Staged [0-9?]' "$KEMPT_STATE_DIR/events.log" | tail -1 | sed 's/.* Staged \([^ ]*\) .*/\1/')"
assert_eq "$staged_ev" "3" "...on the event line too"
assert_contains "$stale_out" "staged 3 updates for a restart" "...and in the run's summary"

"$KEMPT" unhold dnf:curl >/dev/null 2>&1
"$KEMPT" check >/dev/null

# A pre-run snapshot that cannot be read means we could never say what changed, so the run stops
# BEFORE touching anything - loudly, with its own exit code, and the detached user is told.
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
prc=0
perr="$(KEMPT_DNF_INSTALLED_CMD=false "$KEMPT" update --surface=widget 2>&1 >/dev/null)" || prc=$?
assert_eq "$prc" "5" "unreadable package set aborts pre-flight with exit 5"
grep -q 'cannot read the installed package set' <<<"$perr" \
  && echo "ok: pre-flight failure says what went wrong" || { echo "FAIL: preflight message - got: $perr"; _fail=1; }
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "pre-flight abort changes nothing"
grep -q 'did not start' "$WORLD/notifications" \
  && echo "ok: a detached user is told the run never started" || { echo "FAIL: preflight notify"; _fail=1; }
# same for the optional backend: it must not die silently through errexit either
frc=0
ferr="$(KEMPT_FLATPAK_SNAP_CMD=false "$KEMPT" update 2>&1 >/dev/null)" || frc=$?
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
aout="$(KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget <<<"a" 2>/dev/null)" || arc=$?
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
KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget <<<"s" >/dev/null 2>&1
grep -q 'dnf-offline-stage' "$WORLD/apply-calls" && echo "ok: [s] switches the run to offline staging" || { echo "FAIL: stage offline"; _fail=1; }
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && { echo "FAIL: [s] upgraded live anyway"; _fail=1; } || echo "ok: [s] never upgrades live"
# ...and the route the recommendation offers must be one that EXISTS. `[s]tage offline` sets the
# surface from inside this prompt, so a refusal placed before the recommendation is bypassed by
# Kempt's own advice: answering `s` with a Fedora release upgrade stored reached dnf5, cancelled
# gigabytes of downloaded upgrade, recorded it in the event log as an ordinary rebuilt stage,
# and told the user their updates would install on the next restart. The identical run started with
# --surface=offline was refused. Two things close it: the option is not offered, and the gate now
# runs after the prompt that can change the surface.
: > "$WORLD/apply-calls"
: > "$WORLD/notifications"
relup_ev_before="$(grep -c 'Staged update rebuilt' "$KEMPT_STATE_DIR/events.log" 2>/dev/null || true)"
release_upgrade_staged
sout="$(KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget <<<"s" 2>&1)" || true
assert_eq "$(grep -c 'APPLY dnf-offline-stage' "$WORLD/apply-calls" || true)" "0" \
  "answering [s] with a release upgrade stored never reaches dnf5"
assert_eq "$(grep -c 'Staged update rebuilt' "$KEMPT_STATE_DIR/events.log" 2>/dev/null || true)" \
  "$relup_ev_before" "...and Kempt does not record the destruction as its own restage"
case "$sout" in
  *"Staging is not available"*) echo "ok: ...because the prompt does not offer a route that is refused" ;;
  *) echo "FAIL: the prompt still offered staging"; echo "  got: $(head -6 <<<"$sout")"; _fail=1 ;;
esac
# `read -p` prints nothing when stdin is not a terminal, so the prompt string itself is not
# assertable here - but the refusal to act on `s` is, and that is the behaviour that matters.
case "$sout" in
  *"would cancel the stored Fedora release upgrade"*) echo "ok: ...and answering it anyway is turned down, in words" ;;
  *) echo "FAIL: answering s was accepted silently"; echo "  got: $(head -8 <<<"$sout")"; _fail=1 ;;
esac
case "$sout" in
  *aborted*) echo "ok: ...and the run ends without staging anything" ;;
  *) echo "FAIL: the run did not abort"; _fail=1 ;;
esac
grep -q 'install on the next restart' "$WORLD/notifications" \
  && { echo "FAIL: it promised an install it did not stage"; _fail=1; } \
  || echo "ok: ...and nothing promises an install that was never staged"
transaction_armed

# [u]pdate live: the user always decides
: > "$WORLD/apply-calls"
KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget <<<"u" >/dev/null 2>&1
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && echo "ok: [u] proceeds with the live upgrade" || { echo "FAIL: update live"; _fail=1; }

# Saying NO to a risk warning must never proceed - the answer people actually type is "n".
# The trailing "u" is the point: if "n" were ever treated as an unrecognised answer, the
# re-prompt would swallow it and the run would proceed on an answer meant to stop it.
: > "$WORLD/apply-calls"
nrc=0
printf 'n\nu\n' | KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget >/dev/null 2>&1 || nrc=$?
assert_eq "$nrc" "0" "declining with n exits 0"
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "n means no: nothing is applied"

# no answer at all (Enter, or EOF from a closed stdin) is NOT consent
: > "$WORLD/apply-calls"
KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget </dev/null >/dev/null 2>&1
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "an unanswered risk warning defaults to abort"
: > "$WORLD/apply-calls"
printf '\nu\n' | KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget >/dev/null 2>&1
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "pressing Enter defaults to abort"

# gibberish gets one more chance, then aborts rather than guessing
: > "$WORLD/apply-calls"
printf 'x\nx\n' | KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget >/dev/null 2>&1
assert_eq "$(wc -c < "$WORLD/apply-calls")" "0" "two unparseable answers abort"
: > "$WORLD/apply-calls"
printf 'x\nu\n' | KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget >/dev/null 2>&1
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && echo "ok: the re-prompt accepts a valid second answer" || { echo "FAIL: re-prompt"; _fail=1; }

# --- bounded output: a real Qt or KDE bump matches by the hundred (168 on this box), and a wall
# of names is not a recommendation anyone can act on.
{ for i in 01 02 03 04 05 06 07 08 09 10 11 12; do printf 'qt6-qtmod%s.x86_64   6.9.1-1.fc44   updates\n' "$i"; done
  for i in 01 02 03 04 05; do printf 'kf6-kmod%s.x86_64   6.18.0-1.fc44   updates\n' "$i"; done
  printf 'kernel-core.x86_64   6.15.4-200.fc44   updates\n'
  printf 'mesa-libGL.x86_64   25.2.1-1.fc44   updates\n'
  printf 'kwin-x11.x86_64   6.5.1-1.fc44   updates\n'
  printf 'kernel-devel.x86_64   6.15.4-200.fc44   updates\n'; } > "$TESTTMP/risky-check.txt"
big="$(KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget <<<"a" 2>/dev/null)"
grep -q '20 session-critical packages are pending' <<<"$big" \
  && echo "ok: the count is the headline (kernel-devel excluded)" || { echo "FAIL: risky count - got: $(head -3 <<<"$big")"; _fail=1; }
# One representative per FAMILY, like the notification: eight alphabetical names off the top of
# a 12-package qt6 bump told the user nothing about the kernel further down the list. Five
# families here (kernel, kf6, kwin, mesa, qt6), so five names and the rest counted in the tail.
assert_eq "$(grep -cE '^      [A-Za-z]' <<<"$big")" "5" "terminal listing shows one row per family"
assert_eq "$(grep -c 'qtmod' <<<"$big")" "0" "a 12-package family is one row, not twelve names"
grep -qE '^      the desktop toolkit \(qt6\) +12 packages' <<<"$big" \
  && echo "ok: ...and that row carries the family's own count" || { echo "FAIL: family count row - got: $(grep -E '^      ' <<<"$big")"; _fail=1; }
grep -q '      graphics drivers (mesa-libGL)' <<<"$big" && echo "ok: a one-package family is named outright" || { echo "FAIL: small family missing"; _fail=1; }
grep -q '      the Linux kernel (kernel-core)' <<<"$big" && echo "ok: the kernel is named, not buried by alphabetical qt6 rows" || { echo "FAIL: kernel missing from the listing"; _fail=1; }
# FIVE families, cap of eight: nothing is hidden, so nothing may claim to be. The old tail compared
# the PACKAGE count against the rows it had printed and announced "... and 15 more" here, and
# "... and 5 more" for a six-package mesa bump that was one row and one decision.
grep -q '\.\.\. and' <<<"$big" && { echo "FAIL: overflow line claims hidden families that fit"; _fail=1; } \
  || echo "ok: no overflow line when every family is shown"
# The shape a real box actually produced: SIX mesa packages, one family, nothing hidden. The old
# listing printed the first name and "... and 5 more", so one graphics driver read as six risks,
# five of them unnamed. One row, one count, no tail.
{ printf 'mesa-dri-drivers.x86_64   25.2.1-1.fc44   updates\n'
  printf 'mesa-filesystem.x86_64   25.2.1-1.fc44   updates\n'
  printf 'mesa-libEGL.x86_64   25.2.1-1.fc44   updates\n'
  printf 'mesa-libgbm.x86_64   25.2.1-1.fc44   updates\n'
  printf 'mesa-libGL.x86_64   25.2.1-1.fc44   updates\n'
  printf 'mesa-vulkan-drivers.x86_64   25.2.1-1.fc44   updates\n'; } > "$TESTTMP/risky-check.txt"
one="$(KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget <<<"a" 2>/dev/null)"
grep -q '6 session-critical packages are pending' <<<"$one" \
  && echo "ok: one family, six packages, counted honestly" || { echo "FAIL: single-family count - got: $(head -3 <<<"$one")"; _fail=1; }
grep -qE '^      graphics drivers \(mesa\) +6 packages' <<<"$one" \
  && echo "ok: ...named once, in words, with its count on its own row" || { echo "FAIL: mesa row - got: $(grep -E '^      ' <<<"$one")"; _fail=1; }
assert_eq "$(grep -cE '^      [A-Za-z]' <<<"$one")" "1" "...and it really is one row"
grep -q '\.\.\. and 5 more' <<<"$one" && { echo "FAIL: six packages in one family still read as five hidden risks"; _fail=1; } \
  || echo "ok: nothing is hidden, so nothing claims to be"

# A family Kempt ships NO label for prints BARE. risky_regex is the user's to extend, so the moment
# a label is derived from a name rather than looked up, Kempt starts describing packages it knows
# nothing about - to someone deciding whether they are safe to install. `curl` here stands for
# every package a widened regex can pull in.
{ printf 'curl.x86_64   8.9.1-1.fc44   updates\n'
  printf 'mesa-libGL.x86_64   25.2.1-1.fc44   updates\n'
  printf 'mesa-libEGL.x86_64   25.2.1-1.fc44   updates\n'; } > "$TESTTMP/risky-check.txt"
unl="$(KEMPT_RISKY_RE='^(curl|mesa)' KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget <<<"a" 2>/dev/null)"
grep -qE '^      curl$' <<<"$unl" \
  && echo "ok: an unlabelled family prints bare, with nothing invented for it" \
  || { echo "FAIL: unlabelled family - got: $(grep -E '^      ' <<<"$unl")"; _fail=1; }
grep -qE '^      graphics drivers \(mesa\) +2 packages' <<<"$unl" \
  && echo "ok: ...while a family Kempt does ship a label for still gets one" \
  || { echo "FAIL: labelled family alongside an unlabelled one"; _fail=1; }
{ for i in 01 02 03 04 05 06 07 08 09 10 11 12; do printf 'qt6-qtmod%s.x86_64   6.9.1-1.fc44   updates\n' "$i"; done
  for i in 01 02 03 04 05; do printf 'kf6-kmod%s.x86_64   6.18.0-1.fc44   updates\n' "$i"; done
  printf 'kernel-core.x86_64   6.15.4-200.fc44   updates\n'
  printf 'mesa-libGL.x86_64   25.2.1-1.fc44   updates\n'
  printf 'kwin-x11.x86_64   6.5.1-1.fc44   updates\n'
  printf 'kernel-devel.x86_64   6.15.4-200.fc44   updates\n'; } > "$TESTTMP/risky-check.txt"
: > "$WORLD/notifications"
"$KEMPT" update --surface=widget >/dev/null 2>&1
grep -qF 'This update includes 20 packages your running session depends on (the Linux kernel, KDE framework libraries, the window manager, graphics drivers, ...). Restart after it finishes.' "$WORLD/notifications" \
  && echo "ok: notification summarises by family, capped at 4" || { echo "FAIL: family summary - got: $(cat "$WORLD/notifications")"; _fail=1; }
grep -q 'qtmod' "$WORLD/notifications" && { echo "FAIL: individual names leaked into the notification"; _fail=1; } \
  || echo "ok: no wall of package names in a notification"
# --risky-ok: the popup asked first and the person chose Install Now, so the advice is not sent
# again. The run itself goes ahead exactly as before.
: > "$WORLD/notifications"; : > "$WORLD/apply-calls"
"$KEMPT" update --surface=popup --risky-ok >/dev/null 2>&1
assert_eq "$(grep -c 'running session depends on' "$WORLD/notifications")" "0" \
  "after Install Now in the popup, no session-critical notification"
assert_eq "$(grep -c 'APPLY dnf-upgrade' "$WORLD/apply-calls")" "1" "...and the update still runs, live"
# A terminal still asks, whatever the popup heard.
ask="$(KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget --risky-ok <<<"a" 2>/dev/null)"
assert_contains "$ask" "Heads up:" "--risky-ok does not skip the terminal's own question"
printf 'kernel-core.x86_64   6.15.4-200.fc44   updates\nbash.x86_64   5.3.10-1.fc44   updates\n' > "$TESTTMP/risky-check.txt"

# The lock is NOT held while a human deliberates: the recommendation runs before acquire_lock, so
# a prompt left open over lunch never blocks the timer's next run, and an abort leaves no residue.
{ sleep 1; echo a; } | KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget >/dev/null 2>&1 &
bgpid=$!
sleep 0.4
if kill -0 "$bgpid" 2>/dev/null && flock -n "$KEMPT_STATE_DIR/lock" true; then
  echo "ok: no lock is held while the recommendation waits for an answer"
else echo "FAIL: lock held (or run already over) during the prompt"; _fail=1; fi
wait "$bgpid" || true

# Input from somewhere but no terminal on the output side is not a person who can read the question,
# and a background run must never block waiting on a human.
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
"$KEMPT" update --surface=widget <<<"a" >/dev/null 2>&1
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && echo "ok: detached surface proceeds instead of prompting" \
  || { echo "FAIL: detached surface prompted and was aborted"; _fail=1; }

# detached surface: nobody is there to answer a prompt, so it warns and proceeds
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
"$KEMPT" update --surface=widget >/dev/null 2>&1
grep -q 'running session depends on' "$WORLD/notifications" && echo "ok: detached surface gets a heads-up" || { echo "FAIL: detached heads-up"; _fail=1; }
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && echo "ok: detached surface proceeds anyway" || { echo "FAIL: detached proceed"; _fail=1; }

# The heads-up says the install is happening, so it waits for the run to really start. Another
# run holding the lock stops this one before anything is installed, and nothing may be announced.
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
( flock -n 9 && sleep 3 ) 9>"$KEMPT_STATE_DIR/lock" &
lockpid=$!
sleep 0.4
lockrc=0; "$KEMPT" update --surface=widget >/dev/null 2>&1 || lockrc=$?
assert_eq "$lockrc" "3" "premise: the run is stopped by the held lock"
assert_eq "$(grep -c 'running session depends on' "$WORLD/notifications")" "0" \
  "a run stopped by the lock sends no session-critical heads-up"
assert_eq "$(grep -c 'APPLY dnf-upgrade' "$WORLD/apply-calls")" "0" "...because it installed nothing"
kill "$lockpid" 2>/dev/null; wait "$lockpid" 2>/dev/null || true

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
# ...at once, before the pre-flight check: that check goes through the root helper, which waits on
# dnf5's lock until the other update's transaction ends, so the refusal used to come only then.
cat > "$TESTTMP/refresh-recorder" <<STUB
#!/usr/bin/env bash
echo "REFRESH \$*" >> "$TESTTMP/refresh-calls"
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-recorder"
rm -f "$TESTTMP/refresh-calls"
busy_rc=0; busy_err="$(KEMPT_REFRESH_HELPER="$TESTTMP/refresh-recorder" "$KEMPT" update 2>&1 >/dev/null)" || busy_rc=$?
assert_eq "$busy_rc" 3 "a second update while one runs exits 3"
assert_eq "$busy_err" "another kempt update is running" "...saying only that another update is running"
assert_exit 1 "...without asking the root helper anything first" -- test -e "$TESTTMP/refresh-calls"
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
assert_eq "$(grep -c 'Retrying' "$(ls -t "$KEMPT_STATE_DIR"/logs/* | awk 'NR==1')")" "0" "only package-lock errors are retried"

# helper failure with lock-ish stderr → retried then fails cleanly.
# --no-flatpak keeps the retry count scoped to ONE apply call (both backends would retry).
cat > "$TESTTMP/apply-stub" <<'STUB'
#!/usr/bin/env bash
echo "Failed to obtain rpm transaction lock. Another transaction is in progress." >&2; exit 1
STUB
export KEMPT_RETRY_DELAY=0
rm -f "$KEMPT_STATE_DIR"/logs/*.log   # per-second log names: this run's retries only
# Exit 7, not 1: a script can tell "something else has the lock, try later" from a broken run.
assert_exit 7 "a busy rpm lock exits 7 after the retries" "$KEMPT" update --no-flatpak
grep -q 'Update failed (exit code 7): another program is using the package system' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...and the event log names the same rc and reason" \
  || { echo "FAIL: the event log does not say rc=7 with the busy reason"; _fail=1; }
assert_eq "$(grep -c 'Retrying' "$(ls -t "$KEMPT_STATE_DIR"/logs/* | awk 'NR==1')")" "2" "two retries logged"
assert_eq "$(jq -r .error "$KEMPT_STATE_DIR/history/$(ls -1 "$KEMPT_STATE_DIR/history" | tail -1)")" \
  "another program is using the package system (PackageKit, Discover or dnf-automatic) and was still busy after three tries. Nothing was installed. Try again in a few minutes." \
  "...and the reason is Kempt's busy sentence for dnf, in short sentences"
# 3 attempts = 2 retries: the last failure must not promise a retry that never comes.
assert_eq "$(grep -c 'Giving up' "$(ls -t "$KEMPT_STATE_DIR"/logs/* | awk 'NR==1')")" "1" "gives up loudly after the last attempt"

# ...and WHAT THE PERSON IS TOLD, which is the whole point of retrying at all. This is the most
# likely failure Kempt has - Discover, PackageKit and dnf-automatic all take the same lock - and
# until Kempt owned the sentence, the reason in the summary, the notification and the history entry
# was whichever of dnf's lines run_failure_reason's keyword list matched first: raw text about a
# lock file, which reads as a broken installation rather than as "something else is using this
# right now".
lk_hist="$KEMPT_STATE_DIR/history/$(ls -1 "$KEMPT_STATE_DIR/history" | tail -1)"
assert_eq "$(jq -r .status "$lk_hist")" "failed" "the run that lost the lock is recorded as failed"
case "$(jq -r .error "$lk_hist")" in
  *"using the package system"*) echo "ok: ...and the reason is Kempt's own sentence, in words about what happened" ;;
  *) echo "FAIL: the history entry carries dnf's raw text"; echo "  got: $(jq -r .error "$lk_hist")"; _fail=1 ;;
esac
case "$(jq -r .error "$lk_hist")" in
  *"lock file"*) echo "FAIL: the reason is still dnf's lock-file line"; _fail=1 ;;
  *) echo "ok: ...not the lock-file line, which reads as a broken installation" ;;
esac
case "$(jq -r .error "$lk_hist")" in
  *"Try again"*) echo "ok: ...and it says what to do, because there is something to do" ;;
  *) echo "FAIL: the reason does not say to try again"; _fail=1 ;;
esac
grep -q 'using the package system' "$WORLD/notifications" \
  && echo "ok: ...and the notification says the same thing, in the same words" \
  || { echo "FAIL: the notification carries something else"; _fail=1; }
# The one thing that would be WORSE than dnf's raw text: labelling something else as a busy lock.
# The evidence is the lock-specific grep against this attempt's own output, and nothing wider - so
# a full disk keeps its own reason.
cat > "$TESTTMP/apply-stub" <<'STUB'
#!/usr/bin/env bash
echo "Error: No space left on device" >&2; exit 1
STUB
rm -f "$KEMPT_STATE_DIR"/logs/*.log
# No push_history_back here: the lock entry has already been read above, so a per-second collision
# would only overwrite it with this one, which is the entry being asked about anyway. Moving the
# history instead risks landing on a second an earlier push already used.
"$KEMPT" update --no-flatpak >/dev/null 2>&1 || true
lk2="$KEMPT_STATE_DIR/history/$(ls -1 "$KEMPT_STATE_DIR/history" | tail -1)"
case "$(jq -r .error "$lk2")" in
  *"using the package system"*) echo "FAIL: a full disk was reported as a busy package system"; _fail=1 ;;
  *) echo "ok: a failure that is not a lock keeps its own reason" ;;
esac
case "$(jq -r .error "$lk2")" in
  *"No space left"*) echo "ok: ...which is dnf's line, because for this one dnf's line is the answer" ;;
  *) echo "FAIL: the disk failure lost its reason: $(jq -r .error "$lk2")"; _fail=1 ;;
esac
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"

# --- state.json only ever holds a state. The closing check runs as `cmd_check || true`, with errexit off inside it, so
# a failed assemble_state carries on to write_state with an empty string.
# assemble_state's jq is the one call that fails here (a full tmpfs does exactly this), picked out
# by how its arguments START - the history entry's jq also reads a --slurpfile dnfa. Every other
# jq runs as usual, so the run itself still succeeds and reaches the closing check.
mkdir -p "$TESTTMP/jq-fails"
real_jq="$(command -v jq)"
cat > "$TESTTMP/jq-fails/jq" <<STUB
#!/usr/bin/env bash
[[ "\$*" == "-n --slurpfile dnfa "* ]] && exit 1
exec "$real_jq" "\$@"
STUB
chmod +x "$TESTTMP/jq-fails/jq"
jq -n '{schema: 1, last_check: "2026-01-01T00:00:00+00:00", actionable: 7}' > "$KEMPT_STATE_DIR/state.json"
PATH="$TESTTMP/jq-fails:$PATH" "$KEMPT" update --no-flatpak >/dev/null 2>&1 || true
assert_eq "$(jq -r '.actionable' "$KEMPT_STATE_DIR/state.json" 2>/dev/null)" "7" \
  "a closing check whose state could not be built leaves the previous state.json in place"

cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub"

cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"

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
cp "$TESTTMP/rb-staged.tsv" "$WORLD/rpm.tsv"
: > "$WORLD/apply-calls"
transaction_armed   # staging needs a box that can arm one
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
push_history_back   # per-second names: move the staging entry off the second the live run will use
ls -1 "$KEMPT_STATE_DIR"/history/*.json | sort > "$TESTTMP/hist-before.txt"
: > "$WORLD/apply-calls"
# Without cmp on PATH (nocmp_dir): "the stage is still pending" and "the set moved" are decided
# from content, not from a diffutils binary a minimal box may not have.
PATH="$(nocmp_dir):$PATH" "$KEMPT" update --surface=widget --no-flatpak >/dev/null 2>&1
grep -q 'APPLY dnf-offline-clean' "$WORLD/apply-calls" \
  && echo "ok: a live rpm change discards the stage it invalidated" \
  || { echo "FAIL: the superseded stage was left armed and doomed"; _fail=1; }
grep -q 'Staged update dropped (a live update replaced it)' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: the drop is recorded - it is the only trace the stage ever left" \
  || { echo "FAIL: no event for the dropped stage"; _fail=1; }
ls -1 "$KEMPT_STATE_DIR"/history/*.json | sort > "$TESTTMP/hist-after.txt"
comm -13 "$TESTTMP/hist-before.txt" "$TESTTMP/hist-after.txt" > "$TESTTMP/hist-new.txt"
assert_eq "$(wc -l < "$TESTTMP/hist-new.txt")" "1" "the live run records ONE entry, not one plus a phantom restart report"
assert_eq "$(jq -r .surface "$(head -1 "$TESTTMP/hist-new.txt")")" "popup" "the entry is the live run, not a mislabelled restart report"

# The same supersede behind another updater's /system-update: dnf5's clean would remove that
# symlink too, and with it the other updater's restart install. Kempt's stage cannot install
# behind it anyway, and the clean is never run.
cp "$TESTTMP/rb-staged.tsv" "$WORLD/rpm.tsv"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
push_history_back
ln -sfn /var/lib/PackageKit/prepared-update "$TESTTMP/foreign-system-update"
: > "$WORLD/apply-calls"
KEMPT_OFFLINE_LINK="$TESTTMP/foreign-system-update" \
  "$KEMPT" update --surface=widget --no-flatpak --risky-ok >/dev/null 2>&1
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "0" \
  "a live run behind another updater's symlink never runs the clean that would remove it"
# A run that installed no rpm cannot have invalidated anything: the stage stays, and the reboot
# that applies it is still reported. This is the flatpak-only run, and it is the reason the
# supersede is gated on a real rpm delta rather than on "a live run happened".
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
exit 0
STUB
cp "$TESTTMP/rb-staged.tsv" "$WORLD/rpm.tsv"
transaction_armed   # staging needs a box that can arm one
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
push_history_back
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=widget --no-flatpak >/dev/null 2>&1
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "0" \
  "...and never discards it"

# A live run that FAILED but still moved the rpm database supersedes the stage all the same: the
# cookie has moved and dnf5 has already removed /system-update. It used to rebase the baseline
# instead and go on advertising a stage no restart would install.
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
[[ "\$1" == dnf-upgrade ]] && { cp "$TESTTMP/rb-live.tsv" "$WORLD/rpm.tsv"; echo "error: scriptlet failed" >&2; exit 1; }
exit 0
STUB
cp "$TESTTMP/rb-staged.tsv" "$WORLD/rpm.tsv"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
push_history_back
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=widget --no-flatpak >/dev/null 2>&1 || true
grep -q 'APPLY dnf-offline-clean' "$WORLD/apply-calls" \
  && echo "ok: a failed live run that moved rpms discards the stage it invalidated" \
  || { echo "FAIL: a failed live run left the superseded stage advertised"; _fail=1; }

# --- a staged Fedora release upgrade is not ours to destroy --------------------------------------
# dnf5 keeps ONE stored transaction for offline updates and release upgrades alike, and staging
# over one cancels it. Measured against real dnf5 on Fedora 44: the 44 -> 45 transaction is
# replaced by the ordinary one, dnf5 prints "Continuing will cancel the old offline transaction"
# and then does it anyway under -y - which is how Kempt runs it - and /system-update is LEFT
# STANDING, so the machine still restarts into an update, just not the one that was asked for.
# Re-downloading a Fedora release upgrade is gigabytes, so there is no recovering from it either.
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"
: > "$WORLD/apply-calls"
release_upgrade_staged
relup_link_on          # ...and armed, which is the state the sentences below are about
rc=0
# Deliberately WITHOUT --no-flatpak: the refusal happens before the run begins, so the flatpak half
# never runs either. It used to, and the run then reported FAILED with a reason about dnf while
# every flatpak on the box had just been updated.
relout="$("$KEMPT" update --surface=offline 2>&1)" || rc=$?
# Exit 5, the documented "aborted during pre-flight, nothing was changed" - which is exactly what
# this is. Reported as a failed RUN it left a status:"failed" history entry and a notification
# pointing at a zero-byte log, over a run that correctly did nothing.
assert_eq "$rc" "5" "staging over a staged release upgrade aborts in pre-flight, changing nothing"
assert_eq "$(grep -c 'APPLY dnf-offline-stage' "$WORLD/apply-calls" || true)" "0"   "...and dnf5 is never asked to stage, so there is nothing to undo"
assert_eq "$(grep -c '^FLATPAK' "$WORLD/apply-calls" || true)" "0" \
  "...and nothing else is run either, because the run never starts"
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "0"   "...nor to clean: the transaction is somebody else's and it is left exactly where it is"
# The refusal has to NAME what is there, or it is one more tool saying no without saying why.
case "$relout" in
  *"installs on the next restart"*) echo "ok: ...and the reason describes an armed upgrade as one that installs" ;;
  *) echo "FAIL: the armed state was not described as armed"; echo "  got: $relout"; _fail=1 ;;
esac
case "$relout" in
  *"44 -> 45"*) echo "ok: ...naming the upgrade that is waiting" ;;
  *) echo "FAIL: the refusal does not say what is staged"; echo "  got: $relout"; _fail=1 ;;
esac
case "$relout" in
  *"dnf5 offline clean"*) echo "ok: ...and how to get rid of it if that is what the person wants" ;;
  *) echo "FAIL: no remedy offered"; _fail=1 ;;
esac
grep -q 'Update did not start' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...and the refusal is in the event log, not only on a terminal nobody saw" \
  || { echo "FAIL: no event for the refusal"; _fail=1; }
# ...and a state write DOES happen. It is the only thing that takes the widget out of its updating
# state: without it, pressing Update Now on a machine that refuses spins the popup until its
# three-hour guard fires, every press, for ever.
assert_exit 0 "...while the state file is refreshed, which is what releases the widget's spinner" \
  -- test -s "$KEMPT_STATE_DIR/state.json"

# ...and the same refusal, in the state a release upgrade is usually in: DOWNLOADED and not armed.
# Staging over it cancels it just as thoroughly, so the refusal is deliberately status-agnostic -
# but the sentence is not, because "restart to install it" would send somebody to restart a machine
# that comes back exactly as it was.
: > "$WORLD/apply-calls"
rc=0
dlout="$(KEMPT_OFFLINE_TOML="$FIXTURES/offline-release-upgrade-downloaded.toml" \
         "$KEMPT" update --surface=offline 2>&1)" || rc=$?
assert_eq "$rc" "5" "a downloaded release upgrade is protected exactly as an armed one is"
assert_eq "$(grep -c 'APPLY dnf-offline-stage' "$WORLD/apply-calls" || true)" "0" "...nothing staged over it"
case "$dlout" in
  *"downloaded but not started"*) echo "ok: ...and the refusal says which of the two states it is in" ;;
  *) echo "FAIL: the refusal describes it as armed"; echo "  got: $dlout"; _fail=1 ;;
esac
case "$dlout" in
  *"system-upgrade reboot"*) echo "ok: ...and how to start it, which is what the person still has to do" ;;
  *) echo "FAIL: no pointer at what arms it"; _fail=1 ;;
esac
release_upgrade_staged

# ...and the third state: stored, `ready`, and the boot symlink gone. A restart has already been
# past it, so neither of the other two sentences is true - and staging is refused all the same,
# because staging cancels a stored transaction whatever state it is in.
: > "$WORLD/apply-calls"
rc=0
relup_link_off         # `ready`, and the boot marker gone: a restart has already been past it
stout="$("$KEMPT" update --surface=offline 2>&1)" || rc=$?
assert_eq "$rc" "5" "a stranded release upgrade is protected exactly as the other two are"
assert_eq "$(grep -c 'APPLY dnf-offline-stage' "$WORLD/apply-calls" || true)" "0" "...nothing staged over it"
case "$stout" in
  *"no longer set to install"*) echo "ok: ...and the refusal says a restart will not install it as things stand" ;;
  *) echo "FAIL: the refusal describes the wrong state"; echo "  got: $stout"; _fail=1 ;;
esac
case "$stout" in
  *"installs on the next restart"*) echo "FAIL: it promises a restart that will not happen"; _fail=1 ;;
  *) echo "ok: ...and promises nothing a restart will not do" ;;
esac

# ...and the fourth state: dnf5 recorded that the transaction did not finish. "Downloaded" would
# say the opposite of the word dnf5 wrote, and `system-upgrade reboot` is advice dnf5 declines.
: > "$WORLD/apply-calls"
rc=0
icout="$(KEMPT_OFFLINE_TOML="$FIXTURES/offline-release-upgrade-incomplete.toml" \
         "$KEMPT" update --surface=offline 2>&1)" || rc=$?
assert_eq "$rc" "5" "an unfinished release upgrade is protected too"
case "$icout" in
  *"did not finish"*) echo "ok: ...and the refusal says it did not finish, which is what dnf5 recorded" ;;
  *) echo "FAIL: the unfinished state was mis-described"; echo "  got: $icout"; _fail=1 ;;
esac
case "$icout" in
  *"has been downloaded"*) echo "FAIL: it calls download-incomplete downloaded"; _fail=1 ;;
  *) echo "ok: ...and never calls download-incomplete downloaded" ;;
esac
case "$icout" in
  *"offline log"*) echo "ok: ...and points at the command that says what happened" ;;
  *) echo "FAIL: no pointer at dnf5 offline log"; _fail=1 ;;
esac
relup_link_off

# The predicate is a COMPARISON, never "does this file mention a releasever". Both keys are in
# every state_version 2 file and an ordinary offline upgrade carries the SAME value in both - which
# is what tests/fixtures/offline-ready.toml records - so a presence test would refuse every
# rebuild, and holds would stop working.
cp "$TESTTMP/rb-staged.tsv" "$WORLD/rpm.tsv"
: > "$WORLD/apply-calls"
transaction_armed
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
grep -q 'APPLY dnf-offline-stage' "$WORLD/apply-calls" \
  && echo "ok: an ordinary staged transaction is still restaged, because the two releasevers match" \
  || { echo "FAIL: the refusal fired on an ordinary offline transaction"; _fail=1; }

# ...and the same rule on the way out: the user staged a release upgrade after Kempt staged a stage,
# and dnf5 cancelled Kempt's as it stored theirs. A clean would destroy a release upgrade.
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
[[ "\$1" == dnf-upgrade ]] && cp "$TESTTMP/rb-live.tsv" "$WORLD/rpm.tsv"
exit 0
STUB
cp "$TESTTMP/rb-staged.tsv" "$WORLD/rpm.tsv"
transaction_armed
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
push_history_back
: > "$WORLD/apply-calls"
release_upgrade_staged   # ...and now theirs is the one that is stored
PATH="$(nocmp_dir):$PATH" "$KEMPT" update --surface=widget --no-flatpak >/dev/null 2>&1
assert_eq "$(grep -c 'APPLY dnf-offline-clean' "$WORLD/apply-calls" || true)" "0" \
  "a live run never cleans a transaction Kempt did not stage"
transaction_armed
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"

# --- the history entry is worth losing; the run and the check are not ----------------------------
# Both of these sites carry a comment saying what happens if they fail, and both were left as bare
# redirects under errexit, so a full home reproduced exactly the outcome the comment described.
#
# (a) the LIVE run's entry, written on the far side of the update. dnf5 has already installed
# everything; a failure here used to end the run before the summary, the notification, the run-done
# event and the post-run check - and the post-run check is the only thing that takes the widget out
# of its updating state. A successful update presented as a spinner that never stops.
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
transaction_armed
: > "$WORLD/notifications"
rm -f "$KEMPT_STATE_DIR"/logs/*.log
# Emptied first, and this is what makes the test mean anything: history filenames are per-second, so
# an entry left over from a run in the SAME second is a file that already exists - and writing to an
# existing file succeeds in a directory with no write permission of its own. The test would then
# pass without exercising the failure at all, depending only on how fast the machine is. Nothing
# below counts entries absolutely; the restart report further down takes its own baseline after this.
rm -f "$KEMPT_STATE_DIR"/history/*.json
chmod 500 "$KEMPT_STATE_DIR/history"
rc=0
"$KEMPT" update --no-flatpak >/dev/null 2>&1 || rc=$?
chmod 700 "$KEMPT_STATE_DIR/history"
assert_eq "$rc" "0" "a run whose history entry cannot be written is still a successful run"
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" \
  && echo "ok: ...because the update itself had already happened" \
  || { echo "FAIL: the update did not run"; _fail=1; }
# The entry is BUILT beside the run and installed into the history, so what a failure costs is the
# durable record and nothing else: the person in front of the machine still gets the real counts.
grep -qE 'NOTIFY Kempt .*(updated|no package changes)' "$WORLD/notifications" \
  && echo "ok: ...and the notification still carries what actually changed" \
  || { echo "FAIL: no counts in the notification - got: $(cat "$WORLD/notifications")"; _fail=1; }
grep -q 'Update history not saved' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...and the loss is recorded rather than passed over in silence" \
  || { echo "FAIL: nothing says the entry was lost"; _fail=1; }
grep -q ' Update finished: ' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...and the run reaches its own end, which it used to die before" \
  || { echo "FAIL: no run-done event"; _fail=1; }
# The post-run check is what releases the widget. Nothing else does.
assert_exit 0 "...while the state file is rewritten, which is what stops the popup spinning" \
  -- test -s "$KEMPT_STATE_DIR/state.json"

# (c) the same far side, reached by a write that is not the entry at all: the run log, and the temp
# files the entry is built from. Once the package set has moved, a full home or a full /tmp must
# cost at most those niceties - never the history entry, the run-done event and the closing check.
# The stub fills the gap at exactly that moment: the dnf apply moves the package set and then takes
# away the write. The flatpak half runs, because its section heading is a write into that log.
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
if [[ "\$1" == dnf-upgrade ]]; then
  cp "$FIXTURES/snap-after.tsv" "$WORLD/rpm.tsv"
  chmod 444 "$KEMPT_STATE_DIR"/logs/*.log
fi
exit 0
STUB
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
rm -f "$KEMPT_STATE_DIR"/logs/*.log "$KEMPT_STATE_DIR/state.json"
push_history_back
{ ls -1 "$KEMPT_STATE_DIR"/history/*.json 2>/dev/null || true; } | sort > "$TESTTMP/hist-logro-before.txt"
logro_end="$(grep -cE ' Update finished: |Update failed \(exit code 1\)' "$KEMPT_STATE_DIR/events.log" || true)"
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=widget >/dev/null 2>&1 || true
chmod 644 "$KEMPT_STATE_DIR"/logs/*.log 2>/dev/null || true
{ ls -1 "$KEMPT_STATE_DIR"/history/*.json 2>/dev/null || true; } | sort > "$TESTTMP/hist-logro-after.txt"
logro_hist="$(comm -13 "$TESTTMP/hist-logro-before.txt" "$TESTTMP/hist-logro-after.txt" | head -1)"
assert_eq "$(jq -r '.backends.dnf.status' "$logro_hist" 2>/dev/null)" "ok" \
  "a run whose log stops taking writes after the update still records the update in the history"
assert_eq "$(jq -r '.backends.dnf.updated | length > 0' "$logro_hist" 2>/dev/null)" "true" \
  "...with the packages that moved"
# flatpak's output has nowhere to go, so apply_with_retry never starts it and the entry says it
# failed - which is true, and is not the same as the run dying.
assert_eq "$(grep -cE ' Update finished: |Update failed \(exit code 1\)' "$KEMPT_STATE_DIR/events.log" || true)" "$(( logro_end + 1 ))" \
  "...and the run reaches its own end"
assert_exit 0 "...and the closing check still rewrites the state the widget waits on" \
  -- test -s "$KEMPT_STATE_DIR/state.json"

# ...and /tmp filling up at the same moment. The two reports reach jq through temp files; a mktemp
# that fails there used to end the run under errexit. The entry itself is built in /tmp too, so
# what this may cost is the durable record - which the run says it lost - and nothing else.
RUN_TMP="$TESTTMP/run-tmp"; mkdir -p "$RUN_TMP"
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
if [[ "\$1" == dnf-upgrade ]]; then
  cp "$FIXTURES/snap-after.tsv" "$WORLD/rpm.tsv"
  chmod 500 "$RUN_TMP"
fi
exit 0
STUB
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
before_done="$(grep -c ' Update finished: ' "$KEMPT_STATE_DIR/events.log" || true)"
before_lost="$(grep -c 'Update history not saved' "$KEMPT_STATE_DIR/events.log" || true)"
rc=0
TMPDIR="$RUN_TMP" "$KEMPT" update --surface=widget --no-flatpak >/dev/null 2>&1 || rc=$?
chmod 700 "$RUN_TMP"
assert_eq "$rc" "0" "a run whose temp directory fills after the update is still a successful run"
assert_eq "$(grep -c ' Update finished: ' "$KEMPT_STATE_DIR/events.log")" "$(( before_done + 1 ))" \
  "...and reaches its own end instead of dying on a temp file"
assert_eq "$(grep -c 'Update history not saved' "$KEMPT_STATE_DIR/events.log" || true)" "$(( before_lost + 1 ))" \
  "...saying what it could not keep"
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"

# --- the lock-retry window is PER ATTEMPT. dnf fails three times on a busy package lock, then
# flatpak fails on a full disk in the SAME log: a fixed `tail -n 20` re-reads dnf's lock errors,
# calls the disk failure a lock too, and retries a run that was never going to succeed.
cat > "$TESTTMP/apply-stub" <<'STUB'
#!/usr/bin/env bash
echo "APPLY $@" >> "$WORLD/apply-calls"
[[ "$1" == dnf-upgrade ]] && echo "Failed to obtain rpm transaction lock. Another transaction is in progress." >&2
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
assert_exit 1 "a lock-then-disk run fails" "$KEMPT" update --surface=widget
mixed_log="$(ls -t "$KEMPT_STATE_DIR"/logs/*.log | awk 'NR==1')"
assert_eq "$(grep -c '^APPLY' "$WORLD/apply-calls")" "3" "the dnf lock error is retried three times"
assert_eq "$(grep -c '^FLATPAK' "$WORLD/apply-calls")" "1" "...and the flatpak disk error is tried exactly once"
assert_eq "$(grep -c 'Retrying' "$mixed_log")" "2" "the disk failure is never retried as a lock error"

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
  "$KEMPT" update --surface=widget >/dev/null 2>&1 || true
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
"$KEMPT" update --surface=widget >/dev/null 2>&1 || true
assert_eq "$(grep -c '^FLATPAK' "$WORLD/apply-calls")" "1" \
  "an UNlock failure is not a lock to wait on, and is tried once"

# A Flatpak lock that outlasts the retries gets Kempt's own sentence and exit 7, as dnf's does.
# The sentence is about Flatpak only: dnf ran first and may have installed everything.
cat > "$TESTTMP/fp-update-stub" <<STUB
#!/usr/bin/env bash
echo "FLATPAK \$@" >> "$WORLD/apply-calls"
echo "error: Locking repo /var/lib/flatpak/repo failed: Resource temporarily unavailable" >&2
exit 1
STUB
chmod +x "$TESTTMP/fp-update-stub"
: > "$WORLD/notifications"
push_history_back; rm -f "$KEMPT_STATE_DIR"/logs/*.log   # per-second log names: this run's lines only
rc=0; "$KEMPT" update --surface=widget >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "7" "a busy Flatpak lock exits 7 after the retries"
fpb_hist="$KEMPT_STATE_DIR/history/$(ls -1 "$KEMPT_STATE_DIR/history" | tail -1)"
assert_eq "$(jq -r .status "$fpb_hist")" "failed" "...and the run is recorded as failed"
assert_eq "$(jq -r .backends.dnf.status "$fpb_hist")" "ok" "...with dnf still ok"
assert_eq "$(jq -r .error "$fpb_hist")" \
  "another program is using Flatpak (Discover, PackageKit or another flatpak command) and was still busy after three tries. The Flatpak update did not finish. Try again in a few minutes." \
  "...and the reason is Kempt's busy sentence for Flatpak"
grep -q 'another program is using Flatpak' "$WORLD/notifications" \
  && echo "ok: ...and the notification says the same" \
  || { echo "FAIL: the notification does not carry the Flatpak busy sentence"; _fail=1; }
grep -q 'Update failed (exit code 7): another program is using Flatpak' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...and so does the event log, with rc=7" \
  || { echo "FAIL: the event log does not say rc=7 with the Flatpak busy reason"; _fail=1; }

# ...but a dnf failure before it keeps its own reason and exit 1. A busy Flatpak lock must not
# relabel a run whose dnf half failed for another reason.
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
[[ "\$1" == dnf-upgrade ]] && { echo "Error: No space left on device" >&2; exit 1; }
exit 0
STUB
chmod +x "$TESTTMP/apply-stub"
push_history_back; rm -f "$KEMPT_STATE_DIR"/logs/*.log
rc=0; "$KEMPT" update --surface=widget >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "a dnf failure followed by a busy Flatpak lock exits 1"
fpb2="$KEMPT_STATE_DIR/history/$(ls -1 "$KEMPT_STATE_DIR/history" | tail -1)"
case "$(jq -r .error "$fpb2")" in
  *"using Flatpak"*) echo "FAIL: the Flatpak lock relabelled a dnf failure"; _fail=1 ;;
  *"No space left"*) echo "ok: ...and the reason is still dnf's" ;;
  *) echo "FAIL: unexpected reason: $(jq -r .error "$fpb2")"; _fail=1 ;;
esac
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"
cp "$TESTTMP/fp-update-stub.orig" "$TESTTMP/fp-update-stub"

# dnf busy, but Flatpak updated an app in the same run: the reason no longer says nothing was
# installed, and the run still exits 7.
cat > "$TESTTMP/apply-stub" <<'STUB'
#!/usr/bin/env bash
echo "Failed to obtain rpm transaction lock. Another transaction is in progress." >&2; exit 1
STUB
cat > "$TESTTMP/fp-update-stub" <<STUB
#!/usr/bin/env bash
sed -i 's/^org\.gimp\.GIMP\t.*/org.gimp.GIMP\t3.0.4/' "$WORLD/fp.tsv"
STUB
push_history_back; rm -f "$KEMPT_STATE_DIR"/logs/*.log
rc=0; "$KEMPT" update --surface=widget >/dev/null 2>&1 || rc=$?
bf_hist="$KEMPT_STATE_DIR/history/$(ls -1 "$KEMPT_STATE_DIR/history" | tail -1)"
assert_eq "$rc" "7" "dnf busy while Flatpak updated an app still exits 7"
assert_eq "$(jq -r '.backends.flatpak.updated | length' "$bf_hist")" "1" "...with the Flatpak update in the history entry"
assert_eq "$(jq -r .error "$bf_hist")" \
  "another program is using the package system (PackageKit, Discover or dnf-automatic) and was still busy after three tries. Try again in a few minutes." \
  "...and the reason no longer says nothing was installed"
cp "$FIXTURES/flatpak-list.tsv" "$WORLD/fp.tsv"
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"
cp "$TESTTMP/fp-update-stub.orig" "$TESTTMP/fp-update-stub"

# --- dnf's side of the same predicate, driven from the tools' own wordings (sources in
# tests/fixtures/MANIFEST.md). A busy line is retried. A line that only names a lock, such as a
# dependency error about kscreenlocker, is tried once and never reported as a busy package system.
dnf_lock_case() {  # line expected_attempts label
  printf '%s\n' "$1" > "$TESTTMP/dnf-lock-line"
  cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
cat "$TESTTMP/dnf-lock-line" >&2
exit 1
STUB
  chmod +x "$TESTTMP/apply-stub"
  : > "$WORLD/apply-calls"
  rm -f "$KEMPT_STATE_DIR"/logs/*.log
  # </dev/null: the loops below feed this function from the fixture on stdin.
  "$KEMPT" update --surface=widget --no-flatpak </dev/null >/dev/null 2>&1 || true
  assert_eq "$(grep -c '^APPLY' "$WORLD/apply-calls")" "$2" "$3: $1"
}
while IFS= read -r line; do
  dnf_lock_case "$line" 3 "a real lock-held wording is retried"
done < "$FIXTURES/dnf-lock-busy.txt"
while IFS= read -r line; do
  dnf_lock_case "$line" 1 "a failure that only NAMES a lock is tried once"
done < "$FIXTURES/dnf-lock-not-busy.txt"
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"

cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"
cp "$TESTTMP/fp-update-stub.orig" "$TESTTMP/fp-update-stub"

# --- a clock that steps backwards during a run ---------------------------------------------------
# NTP correcting a fast clock, or a suspend and resume across a time change, can put the end of a
# run before its start. The duration is then not a measurement, and "Updated 1 package in -287s"
# is what a person would read. A `date` stand-in answers the run's first `date +%s` with a time
# 287 seconds AFTER every later one; every other format goes to the real date.
REAL_DATE="$(command -v date)"
mkdir -p "$TESTTMP/backwards-clock"
cat > "$TESTTMP/backwards-clock/date" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "+%s" ]]; then
  if [[ -e "$TESTTMP/backwards-clock/started" ]]; then echo 2000000000
  else touch "$TESTTMP/backwards-clock/started"; echo 2000000287; fi
  exit 0
fi
exec "$REAL_DATE" "\$@"
STUB
chmod +x "$TESTTMP/backwards-clock/date"
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
PATH="$TESTTMP/backwards-clock:$PATH" "$KEMPT" update --surface=widget --no-flatpak >/dev/null 2>&1 || true
assert_exit 0 "...the fake clock really was consulted" -- test -e "$TESTTMP/backwards-clock/started"
hb="$(ls -1t "$KEMPT_STATE_DIR"/history/*.json | awk 'NR==1')"
assert_eq "$(jq -r .duration_sec "$hb")" "0" "a run whose clock stepped backwards records a duration of 0, never a negative one"

# --- each backend's output under its own heading. flatpak's own notices stay in the log.
cp "$TESTTMP/apply-stub.orig" "$TESTTMP/apply-stub"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
cat > "$TESTTMP/fp-update-stub" <<STUB
#!/usr/bin/env bash
echo "FLATPAK \$@" >> "$WORLD/apply-calls"
echo "Info: org.kde.Platform is end-of-life, with reason: We strongly recommend moving to the latest stable version of the Platform and SDK"
echo "Info: org.kde.Platform.Locale is end-of-life, with reason: We strongly recommend moving to the latest stable version of the Platform and SDK"
echo "Nothing to update."
exit 0
STUB
chmod +x "$TESTTMP/fp-update-stub"
push_history_back
rm -f "$KEMPT_STATE_DIR"/logs/*.log   # per-second log names: the heading count must be this run's alone
eout="$(KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget </dev/null 2>/dev/null)" || true
he="$(ls -1t "$KEMPT_STATE_DIR"/history/*.json | awk 'NR==1')"
assert_contains "$eout" "== System (dnf) ==" "a terminal run heads the dnf output"
assert_contains "$eout" "== Apps (flatpak) ==" "...and the flatpak output"
assert_eq "$(grep -n '^== ' "$(jq -r .log "$he")" | cut -d: -f2- | paste -sd'|')" \
  "== System (dnf) ==|== Apps (flatpak) ==" "the log carries both headings, dnf first"
assert_contains "$(cat "$(jq -r .log "$he")")" "org.kde.Platform is end-of-life" "flatpak's notice stays in the log"
assert_not_contains "$eout" "has reached end-of-life" "...and the summary adds nothing about it"
assert_eq "$(jq -r '.backends.flatpak | has("eol")' "$he")|$(jq -r .status "$he")" "false|ok" \
  "the history records no notes, and a notice does not fail the run"
export KEMPT_FLATPAK_LIST_RUNTIME_CMD=true
cp "$TESTTMP/fp-update-stub.orig" "$TESTTMP/fp-update-stub"

# --- per-user Flatpak apps ---------------------------------------------------------------------------
# Apps installed with --user are outside the system installation, so a run that updated only that
# left them behind while saying all was well. The per-user installation is updated after the system
# one, as the person, with the same holds, retries and reporting. Its stand-in writes a line of its
# own and moves its own snapshot, the way a real update changes the next listing.
mkdir -p "$TESTTMP/ufp/repo"; : > "$TESTTMP/ufp/repo/config"
printf 'com.brave.Browser\t1.79\nnet.mkiol.SpeechNote\t4.8.0\n' > "$TESTTMP/u-before.tsv"
printf 'com.brave.Browser\t1.80\nnet.mkiol.SpeechNote\t4.9.0\n' > "$TESTTMP/u-after.tsv"
printf 'com.brave.Browser\t1.80\t219.2\xc2\xa0MB\nnet.mkiol.SpeechNote\t4.9.0\t1.1\xc2\xa0GB\n' > "$TESTTMP/u-remote.tsv"
cat > "$TESTTMP/fp-user-stub" <<STUB
#!/usr/bin/env bash
echo "FLATPAK-USER \$@" >> "$WORLD/apply-calls"
[[ -n "\${USER_FP_RC:-}" ]] && exit "\$USER_FP_RC"
cp "$TESTTMP/u-after.tsv" "$WORLD/u-fp.tsv"
exit 0
STUB
chmod +x "$TESTTMP/fp-user-stub"
export KEMPT_FLATPAK_USER_DIR="$TESTTMP/ufp" KEMPT_FLATPAK_USER_UPDATE_CMD="$TESTTMP/fp-user-stub" \
       KEMPT_FLATPAK_USER_REMOTE_CMD="cat $TESTTMP/u-remote.tsv" \
       KEMPT_FLATPAK_USER_LIST_CMD="cat $WORLD/u-fp.tsv" KEMPT_FLATPAK_USER_SNAP_CMD="cat $WORLD/u-fp.tsv"
for h in $(grep '^flatpak:' "$KEMPT_CONFIG_DIR/holds" 2>/dev/null || true); do "$KEMPT" unhold "$h" >/dev/null; done
uf_update() { cp "$TESTTMP/u-before.tsv" "$WORLD/u-fp.tsv"; : > "$WORLD/apply-calls"; push_history_back
              UF_OUT="$("$KEMPT" update --surface=widget 2>/dev/null)" || true
              UH="$(ls -1t "$KEMPT_STATE_DIR"/history/*.json | awk 'NR==1')"; }

uf_update
assert_eq "$(grep '^FLATPAK' "$WORLD/apply-calls")" "FLATPAK --noninteractive -y
FLATPAK-USER --noninteractive -y" "the per-user installation is updated after the system one, with the same flags"
assert_eq "$(jq -r .status "$UH")" "ok" "...in a run that succeeded"
assert_eq "$(jq -c .backends.flatpak.scopes "$UH")" '{"system":"ok","user":"ok"}' "...recording each installation's outcome"
assert_eq "$(jq -c '[.backends.flatpak.updated[] | select(.scope == "user") | .name] | sort' "$UH")" \
  '["com.brave.Browser","net.mkiol.SpeechNote"]' "the per-user apps it updated are in the history, marked scope user"
assert_contains "$(grep 'com.brave.Browser' <<<"$UF_OUT")" "(for you only)" "...and the summary says they are for you only"
assert_contains "$(cat "$(jq -r .log "$UH")")" "== Apps for you only (flatpak) ==" "the log has them under their own heading"

# A per-user failure does not undo or hide the system update, and is named as the per-user one.
USER_FP_RC=1 uf_update
assert_eq "$(grep -c '^FLATPAK ' "$WORLD/apply-calls")|$(grep -c '^FLATPAK-USER' "$WORLD/apply-calls")" "1|1" \
  "a per-user update that fails still follows a system update that ran"
assert_eq "$(jq -r .status "$UH")|$(jq -c .backends.flatpak.scopes "$UH")" 'failed|{"system":"ok","user":"failed"}' \
  "...and the run is failed, with the system installation recorded ok"
assert_contains "$(cat "$(jq -r .log "$UH")")" "warning: updating apps for you only failed" "...said in the log"
assert_contains "$UF_OUT" "[failed: apps for you only]" "...and the summary names which half failed"

# ...and the other way round: a system failure does not stop the per-user update.
printf '#!/usr/bin/env bash\necho "FLATPAK $@" >> "%s/apply-calls"\nexit 1\n' "$WORLD" > "$TESTTMP/fp-update-stub"
uf_update
assert_eq "$(grep -c '^FLATPAK-USER' "$WORLD/apply-calls")" "1" "a system update that fails does not stop the per-user one"
assert_eq "$(jq -c .backends.flatpak.scopes "$UH")" '{"system":"failed","user":"ok"}' "...and each outcome is recorded"
assert_contains "$UF_OUT" "[failed: system apps]" "...and the summary names the system half"
cp "$TESTTMP/fp-update-stub.orig" "$TESTTMP/fp-update-stub"

# Holds are by id: a hold on a per-user app skips it, and the rest of that installation still moves.
"$KEMPT" hold flatpak:com.brave.Browser >/dev/null
uf_update
assert_eq "$(grep '^FLATPAK-USER' "$WORLD/apply-calls")" "FLATPAK-USER --noninteractive -y net.mkiol.SpeechNote" \
  "a hold on a per-user app → per-app update of the rest of the per-user installation"
assert_contains "$(jq -c '.backends.flatpak.skipped_held' "$UH")" "com.brave.Browser" "...recorded as skipped"
"$KEMPT" unhold flatpak:com.brave.Browser >/dev/null
# ...and a hold on an id installed both ways holds both copies.
"$KEMPT" hold flatpak:net.mkiol.SpeechNote >/dev/null
uf_update
assert_eq "$(grep '^FLATPAK-USER' "$WORLD/apply-calls")" "FLATPAK-USER --noninteractive -y com.brave.Browser" \
  "a hold on an id installed both ways skips the per-user copy"
assert_not_contains "$(grep '^FLATPAK ' "$WORLD/apply-calls")" "net.mkiol.SpeechNote" "...and the system copy"
"$KEMPT" unhold flatpak:net.mkiol.SpeechNote >/dev/null

# With holds, a lookup that fails names the installation it failed in.
"$KEMPT" hold flatpak:org.gimp.GIMP >/dev/null
KEMPT_FLATPAK_USER_REMOTE_CMD=false uf_update
assert_contains "$(cat "$(jq -r .log "$UH")")" "flatpak update lookup failed for the apps for you only" \
  "a failed per-user lookup is named as the per-user one"
assert_eq "$(grep -c '^FLATPAK ' "$WORLD/apply-calls")" "1" "...and the system apps are still updated"
"$KEMPT" unhold flatpak:org.gimp.GIMP >/dev/null

# A per-user installation that cannot be listed drops only itself: dnf and the system apps update,
# and the run says the per-user side failed. It used to stop the whole run before dnf.
KEMPT_FLATPAK_USER_SNAP_CMD=false uf_update
assert_eq "$(grep -c '^APPLY dnf-upgrade' "$WORLD/apply-calls")|$(grep -c '^FLATPAK ' "$WORLD/apply-calls")|$(grep -c '^FLATPAK-USER' "$WORLD/apply-calls")" \
  "1|1|0" "an unreadable per-user installation: dnf and the system apps update, the per-user apps do not"
assert_eq "$(jq -r .status "$UH")|$(jq -c .backends.flatpak.scopes "$UH")" 'failed|{"system":"ok","user":"failed"}' \
  "...and the run records the per-user side as failed"
assert_contains "$(cat "$(jq -r .log "$UH")")" "the apps for you only could not be listed" "...said in the log"
assert_eq "$(jq -c '[.backends.flatpak.removed[] | select(.scope == "user")] | length' "$UH")" "0" \
  "...and no per-user app is reported removed"
# The skip covers the run only. The check after it asks the per-user installation again, so its
# pending apps stay listed rather than the state saying everything is up to date.
assert_eq "$(jq -c '[.backends.flatpak.items[] | select(.scope == "user") | .name] | sort' "$KEMPT_STATE_DIR/state.json")" \
  '["com.brave.Browser","net.mkiol.SpeechNote"]' "the check after a run that skipped the per-user apps still lists them"
assert_eq "$(jq -c .backends.flatpak.scopes "$KEMPT_STATE_DIR/state.json")" '{"system":"ok","user":"ok"}' \
  "...and records that it asked both installations"

# A per-user set that can be listed before the run and not after it: the per-user apps that did
# update are missing from the summary, so the run is failed and names the per-user side.
printf '#!/usr/bin/env bash\ncmp -s "%s/u-fp.tsv" "%s/u-after.tsv" && exit 1\ncat "%s/u-fp.tsv"\n' \
  "$WORLD" "$TESTTMP" "$WORLD" > "$TESTTMP/u-snap-after-fails"
chmod +x "$TESTTMP/u-snap-after-fails"
KEMPT_FLATPAK_USER_SNAP_CMD="$TESTTMP/u-snap-after-fails" uf_update
assert_eq "$(grep -c '^FLATPAK-USER' "$WORLD/apply-calls")" "1" "a per-user set unreadable after the run: the per-user apps were still updated"
assert_eq "$(jq -r .status "$UH")|$(jq -r .backends.flatpak.status "$UH")|$(jq -c .backends.flatpak.scopes "$UH")" \
  'failed|failed|{"system":"ok","user":"failed"}' "...and the run is failed on the per-user side"
assert_contains "$(jq -r .error "$UH")" "apps for you only could not be listed after the run" "...with that as the reason"
assert_contains "$UF_OUT" "[failed: apps for you only]" "...and the summary names the per-user half"
# A run that had already failed keeps its own reason: the per-user listing must not mask it.
KEMPT_FLATPAK_UPDATE_CMD=false KEMPT_FLATPAK_USER_SNAP_CMD="$TESTTMP/u-snap-after-fails" uf_update
assert_eq "$(jq -r .status "$UH")" "failed" "a failed system Flatpak update with an unreadable per-user set after it fails the run"
assert_not_contains "$(jq -r .error "$UH")" "apps for you only could not be listed" \
  "...and the reason is the earlier failure, not the per-user listing"
assert_eq "$(jq -c '[.backends.flatpak.removed[] | select(.scope == "user")] | length' "$UH")" "0" \
  "...and no per-user app is reported removed"

# A busy system installation beside a per-user failure that is not a lock: exit 1, not 7, and the
# reason does not end on "Try again", which alone would not fix the run.
printf '#!/usr/bin/env bash\necho "FLATPAK $@" >> "%s/apply-calls"\necho "error: Locking repo /var/lib/flatpak/repo failed: Resource temporarily unavailable" >&2\nexit 1\n' \
  "$WORLD" > "$TESTTMP/fp-busy-stub"
chmod +x "$TESTTMP/fp-busy-stub"
uf_busy_update() { cp "$TESTTMP/u-before.tsv" "$WORLD/u-fp.tsv"; : > "$WORLD/apply-calls"; push_history_back
                   UF_RC=0; KEMPT_RETRY_DELAY=0 KEMPT_FLATPAK_UPDATE_CMD="$TESTTMP/fp-busy-stub" \
                     "$KEMPT" update --surface=widget >/dev/null 2>&1 || UF_RC=$?
                   UH="$(ls -1t "$KEMPT_STATE_DIR"/history/*.json | awk 'NR==1')"; }
uf_busy_update
assert_eq "$UF_RC" "7" "a busy system installation with the per-user one fine still exits 7"
USER_FP_RC=1 uf_busy_update
assert_eq "$UF_RC" "1" "a busy system installation and a failed per-user update exit 1"
assert_contains "$(jq -r .error "$UH")" "another program is using Flatpak" "...the reason still names the busy lock"
assert_contains "$(jq -r .error "$UH")" "Another part of the update failed too" "...and says something else failed"
assert_not_contains "$(jq -r .error "$UH")" "Try again" "...in place of telling the person to try again"
grep -q 'Update failed (exit code 1): another program is using Flatpak.*Another part of the update failed too' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...and the event log says rc=1 with the same reason" \
  || { echo "FAIL: the event log does not say rc=1 with the combined reason"; _fail=1; }
# ...and the same when the per-user apps cannot be listed after the run.
KEMPT_FLATPAK_USER_SNAP_CMD="$TESTTMP/u-snap-after-fails" uf_busy_update
assert_eq "$UF_RC|$(jq -c .backends.flatpak.scopes "$UH")" '1|{"system":"failed","user":"failed"}' \
  "a busy system installation and a per-user set unreadable after the run exit 1"

# A busy dnf lock with the per-user apps unreadable before the run: two failures, so exit 1, and
# the reason is still the busy sentence with the "failed too" ending, not dnf's raw lock line.
printf '#!/usr/bin/env bash\necho "APPLY $@" >> "%s/apply-calls"\necho "Failed to obtain rpm transaction lock. Another transaction is in progress." >&2\nexit 1\n' \
  "$WORLD" > "$TESTTMP/apply-busy-stub"
chmod +x "$TESTTMP/apply-busy-stub"
cp "$TESTTMP/u-before.tsv" "$WORLD/u-fp.tsv"; : > "$WORLD/apply-calls"; push_history_back
UF_RC=0; KEMPT_RETRY_DELAY=0 KEMPT_APPLY_HELPER="$TESTTMP/apply-busy-stub" KEMPT_FLATPAK_USER_SNAP_CMD=false \
  "$KEMPT" update --surface=widget >/dev/null 2>&1 || UF_RC=$?
UH="$(ls -1t "$KEMPT_STATE_DIR"/history/*.json | awk 'NR==1')"
assert_eq "$UF_RC" "1" "a busy dnf lock and per-user apps unreadable before the run exit 1"
assert_contains "$(jq -r .error "$UH")" "another program is using the package system" "...the reason names the busy lock"
assert_contains "$(jq -r .error "$UH")" "Another part of the update failed too" "...and says something else failed"
assert_not_contains "$(jq -r .error "$UH")" "rpm transaction lock" "...not dnf's raw lock line"

# A bare repo directory, which flatpak fails on, is no installation: the run is the system one.
rm "$TESTTMP/ufp/repo/config"
KEMPT_FLATPAK_USER_SNAP_CMD=false KEMPT_FLATPAK_USER_LIST_CMD=false uf_update
assert_eq "$(jq -r .status "$UH")|$(grep -c '^FLATPAK-USER' "$WORLD/apply-calls")|$(jq -c .backends.flatpak.scopes "$UH")" \
  "ok|0|null" "an empty per-user repo directory changes nothing about the run"
: > "$TESTTMP/ufp/repo/config"

# Never as root with the person's HOME: flatpak would leave root-owned files in their installation.
SUDO_UID=1000 uf_update
assert_eq "$(grep -c '^FLATPAK ' "$WORLD/apply-calls")|$(grep -c '^FLATPAK-USER' "$WORLD/apply-calls")" "1|0" \
  "a run under sudo updates the system apps and leaves the per-user installation alone"
PKEXEC_UID=1000 uf_update
assert_eq "$(grep -c '^FLATPAK-USER' "$WORLD/apply-calls")" "0" "...and so does one under pkexec"

export KEMPT_FLATPAK_USER_DIR="$TESTTMP/no-user-flatpak"

# dnf_status starts unknown and every path names it. A run that reached history says ok or failed.
assert_eq "$(cat "$KEMPT_STATE_DIR"/history/*.json 2>/dev/null | jq -r 'select(.dnf != null) | .dnf.status' | grep -vxE 'ok|failed' | sort -u)" "" \
  "every run in history recorded dnf as ok or failed"

finish
