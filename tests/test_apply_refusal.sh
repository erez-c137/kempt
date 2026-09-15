#!/usr/bin/env bash
# What `kempt update` does when the root helper refuses an offline verb (exit 3) because of what
# dnf5 has stored. The helper side is in test_helpers.sh; this file is about the CLI telling the
# truth afterwards. A refusal changed nothing, so it must never be unwound with another offline
# verb, and never answered with "run: sudo dnf5 offline clean", which deletes what it protected.
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"

export WORLD="$TESTTMP/world"; mkdir -p "$WORLD"
printf 'bash\t5.2.37-1.fc44\nkernel-core\t6.15.3-200.fc44\nzsh\t5.9-11.fc44\n' > "$TESTTMP/staged.tsv"
printf 'bash\t5.2.38-1.fc44\nkernel-core\t6.15.3-200.fc44\nzsh\t5.9-11.fc44\n' > "$TESTTMP/live.tsv"
cp "$TESTTMP/staged.tsv" "$WORLD/rpm.tsv"

cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
cat > "$TESTTMP/notify-stub" <<STUB
#!/usr/bin/env bash
echo "NOTIFY \$@" >> "$WORLD/notifications"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"
chmod +x "$TESTTMP/refresh-stub" "$TESTTMP/notify-stub" "$TESTTMP/dnf-reboot-no"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_NOTIFY="$TESTTMP/notify-stub"
export KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no"
export KEMPT_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export KEMPT_FLATPAK_LIST_CMD="cat $FIXTURES/flatpak-list.tsv"
export KEMPT_FLATPAK_UPDATE_CMD="$TESTTMP/UNSTUBBED-flatpak-update"
export KEMPT_SKIP_REFRESH=1

# dnf5's state file for this world is a COPY, so a stub can replace it mid-run the way
# `dnf5 system-upgrade download` would.
TOML="$TESTTMP/offline-transaction-state.toml"
export KEMPT_OFFLINE_TOML="$TOML"
stored() { cp "$FIXTURES/$1" "$TOML"; }
RELUP="$FIXTURES/offline-release-upgrade.toml"
marker="$KEMPT_STATE_DIR/offline_staged.json"

# apply_stub name 'case arms' → an apply helper that records each call and runs the arms given.
# The refusal arms print the real helper's line and exit 3.
apply_stub() {
  cat > "$TESTTMP/apply-$1" <<STUB
#!/usr/bin/env bash
echo "APPLY \$*" >> "$WORLD/apply-calls"
case "\$1" in
$2
esac
exit 0
STUB
  chmod +x "$TESTTMP/apply-$1"
}
apply_stub ok 'dnf-upgrade) cp "'"$TESTTMP/live.tsv"'" "'"$WORLD/rpm.tsv"'" ;;'
reset_run() { : > "$WORLD/apply-calls"; : > "$WORLD/notifications"; rm -f "$KEMPT_STATE_DIR"/history/*.json; }
last_error() { jq -r .error "$(ls -1 "$KEMPT_STATE_DIR"/history/*.json | tail -1)"; }
calls() { grep -c "APPLY $1" "$WORLD/apply-calls" || true; }
no_clean_advice() {  # label
  if grep -qF 'dnf5 offline clean' "$WORLD/notifications" "$TESTTMP/err" 2>/dev/null; then
    echo "FAIL: $1"; _fail=1; cat "$WORLD/notifications" "$TESTTMP/err"
  else
    echo "ok: $1"
  fi
}
stage_real() {  # a real armed stage from this world, so a marker exists to be protected
  stored offline-ready.toml; cp "$TESTTMP/staged.tsv" "$WORLD/rpm.tsv"
  rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
  KEMPT_APPLY_HELPER="$TESTTMP/apply-ok" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
}

# --- the arm is refused: a release upgrade replaced the stage between the stage and the arm --------
apply_stub arm-relup 'dnf-offline-arm) cp "'"$RELUP"'" "'"$TOML"'"
  echo "kempt-apply: refusing dnf-offline-arm: a Fedora release upgrade (44 -> 45) is stored" >&2; exit 3 ;;'
stored offline-ready.toml; rm -f "$marker"; reset_run
rc=0
KEMPT_APPLY_HELPER="$TESTTMP/apply-arm-relup" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>"$TESTTMP/err" || rc=$?
assert_eq "$rc" "1" "a refused arm fails the run"
assert_eq "$(calls dnf-offline-clean)" "0" "...and is not unwound with a clean, which the helper would refuse too"
assert_exit 1 "...and writes no marker" -- test -f "$marker"
assert_eq "$(last_error)" "staged but not armed, because a Fedora release upgrade (44 -> 45) is stored - see: kempt doctor" \
  "...and the reason names what is stored"
no_clean_advice "...and nothing advises the command that would delete the release upgrade"

# --- the stage is refused -------------------------------------------------------------------------
apply_stub stage-refused 'dnf-offline-stage) echo "kempt-apply: refusing dnf-offline-stage: the stored offline transaction cannot be read, so it may be a Fedora release upgrade" >&2; exit 3 ;;'
printf 'not a transaction-state file\n' > "$TOML"; rm -f "$marker"; reset_run
rc=0
KEMPT_APPLY_HELPER="$TESTTMP/apply-stage-refused" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>"$TESTTMP/err" || rc=$?
assert_eq "$rc" "1" "a refused stage fails the run"
assert_eq "$(calls dnf-offline-arm)" "0" "...arms nothing"
assert_eq "$(calls dnf-offline-clean)" "0" "...and cleans nothing"
assert_eq "$(last_error)" \
  "nothing was staged, because the stored offline transaction could not be read and staging would replace it - see: kempt doctor" \
  "...and says nothing was staged, and why"
grep -q 'offline stage refused by the root helper' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...and the event log records the refusal" || { echo "FAIL: no refusal event"; _fail=1; }
no_clean_advice "...and does not advise a clean"

# The same, over an EXISTING stage whose state file already reads as `ready`: the rebuild unwind
# (which cleans when the old stage looks gone) must not run for a refusal either.
stage_real
assert_exit 0 "the rebuild fixture starts from a real armed stage" -- test -f "$marker"
reset_run
KEMPT_APPLY_HELPER="$TESTTMP/apply-stage-refused" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>"$TESTTMP/err" || true
assert_eq "$(calls dnf-offline-clean)" "0" "a refused re-stage never cleans the previous stage"
assert_exit 0 "...and its marker stays, because nothing changed" -- test -f "$marker"

# --- the arm fails for an ordinary reason, and the unwind clean is refused ------------------------
# The pre-flight refuses a stored release upgrade outright, so the world starts ordinary and the
# stage "stores" one, which is the race the root-side check exists for.
stored offline-ready.toml; rm -f "$marker"; reset_run
apply_stub arm-fail-clean-refused 'dnf-offline-stage) cp "'"$RELUP"'" "'"$TOML"'" ;;
dnf-offline-arm) echo "Failed to prepare the system-update symlink" >&2; exit 1 ;;
dnf-offline-clean) echo "kempt-apply: refusing dnf-offline-clean: a Fedora release upgrade (44 -> 45) is stored" >&2; exit 3 ;;'
rc=0
KEMPT_APPLY_HELPER="$TESTTMP/apply-arm-fail-clean-refused" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>"$TESTTMP/err" || rc=$?
assert_eq "$rc" "1" "an arm failure whose unwind is refused still fails the run"
assert_eq "$(last_error)" "staged but could not arm the restart install" "...and the reason stays the arm"
grep -q 'left in place because a Fedora release upgrade (44 -> 45) is stored' "$TESTTMP/err" \
  && echo "ok: ...and the warning says the stored transaction was left in place, and why" \
  || { echo "FAIL: no left-in-place warning"; _fail=1; cat "$TESTTMP/err"; }
grep -q 'see: kempt doctor' "$WORLD/notifications" \
  && echo "ok: ...and the notification points at the doctor" || { echo "FAIL: notification"; _fail=1; cat "$WORLD/notifications"; }
no_clean_advice "...and nothing advises a clean"

# --- a failed re-stage whose clean is refused keeps the marker for the doctor --------------------
stage_real
assert_exit 0 "the second rebuild fixture starts from a real armed stage" -- test -f "$marker"
apply_stub stage-fail-clean-refused 'dnf-offline-stage) echo "No space left on device" >&2; exit 1 ;;
dnf-offline-clean) cp "'"$RELUP"'" "'"$TOML"'"
  echo "kempt-apply: refusing dnf-offline-clean: a Fedora release upgrade (44 -> 45) is stored" >&2; exit 3 ;;'
stored offline-download-complete.toml; reset_run
KEMPT_APPLY_HELPER="$TESTTMP/apply-stage-fail-clean-refused" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>"$TESTTMP/err" || true
assert_eq "$(calls dnf-offline-clean)" "1" "a failed re-stage still tries its unwind"
assert_exit 0 "...and when the helper refuses it, the marker stays" -- test -f "$marker"
assert_eq "$(last_error)" \
  "could not rebuild the staged update, and what is stored was left in place because a Fedora release upgrade (44 -> 45) is stored - see: kempt doctor" \
  "...and the reason says what was left and why"
no_clean_advice "...and nothing advises a clean"

# --- a live run supersedes the stage, and the clean is refused -----------------------------------
# A release upgrade stored between the CLI's own check and the clean: the helper refuses, and the
# marker is dropped exactly as when the CLI sees the release upgrade first.
apply_stub live-clean-relup 'dnf-upgrade) cp "'"$TESTTMP/live.tsv"'" "'"$WORLD/rpm.tsv"'" ;;
dnf-offline-clean) cp "'"$RELUP"'" "'"$TOML"'"
  echo "kempt-apply: refusing dnf-offline-clean: a Fedora release upgrade (44 -> 45) is stored" >&2; exit 3 ;;'
stage_real
assert_exit 0 "the supersede fixture starts from a real armed stage" -- test -f "$marker"
reset_run
KEMPT_APPLY_HELPER="$TESTTMP/apply-live-clean-relup" "$KEMPT" update --surface=background --no-flatpak >/dev/null 2>"$TESTTMP/err" || true
assert_eq "$(calls dnf-offline-clean)" "1" "a superseding live run asks for the clean"
assert_exit 1 "...and when a release upgrade is what refused it, our marker is dropped" -- test -f "$marker"
grep -q 'offline marker dropped (a release upgrade (44 -> 45) replaced our stage)' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...with the same event as when the CLI saw it first" || { echo "FAIL: no marker-dropped event"; _fail=1; }

# Refused without a release upgrade the CLI can see: the marker stays and the warning says why.
apply_stub live-clean-refused 'dnf-upgrade) cp "'"$TESTTMP/live.tsv"'" "'"$WORLD/rpm.tsv"'" ;;
dnf-offline-clean) echo "kempt-apply: refusing dnf-offline-clean: the stored offline transaction cannot be read, so it may be a Fedora release upgrade" >&2; exit 3 ;;'
stage_real
reset_run
KEMPT_APPLY_HELPER="$TESTTMP/apply-live-clean-refused" "$KEMPT" update --surface=background --no-flatpak >/dev/null 2>"$TESTTMP/err" || true
assert_exit 0 "a refused supersede clean keeps the marker for the doctor" -- test -f "$marker"
grep -q 'left in place because the stored offline transaction could not be read - see: kempt doctor' "$TESTTMP/err" \
  && echo "ok: ...and warns that it was left in place" || { echo "FAIL: no warning"; _fail=1; cat "$TESTTMP/err"; }
no_clean_advice "...and does not advise a clean"

finish
