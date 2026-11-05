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
stage_real() {  # a real armed stage from this world, so there is something to protect
  stored offline-ready.toml; cp "$TESTTMP/staged.tsv" "$WORLD/rpm.tsv"
  KEMPT_APPLY_HELPER="$TESTTMP/apply-ok" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
}

# --- the arm is refused: a release upgrade replaced the stage between the stage and the arm --------
apply_stub arm-relup 'dnf-offline-arm) cp "'"$RELUP"'" "'"$TOML"'"
  echo "kempt-apply: refusing dnf-offline-arm: a Fedora release upgrade (44 -> 45) is stored" >&2; exit 3 ;;'
stored offline-ready.toml; reset_run
rc=0
KEMPT_APPLY_HELPER="$TESTTMP/apply-arm-relup" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>"$TESTTMP/err" || rc=$?
assert_eq "$rc" "1" "a refused arm fails the run"
assert_eq "$(calls dnf-offline-clean)" "0" "...and is not unwound with a clean, which the helper would refuse too"
assert_eq "$(last_error)" "the updates were downloaded, but not set to install on the next restart, because a Fedora release upgrade (44 -> 45) is stored. See: kempt doctor" \
  "...and the reason names what is stored"
no_clean_advice "...and nothing advises the command that would delete the release upgrade"

# --- the stage is refused -------------------------------------------------------------------------
apply_stub stage-refused 'dnf-offline-stage) echo "kempt-apply: refusing dnf-offline-stage: the stored offline transaction cannot be read, so it may be a Fedora release upgrade" >&2; exit 3 ;;'
printf 'not a transaction-state file\n' > "$TOML"; reset_run
rc=0
KEMPT_APPLY_HELPER="$TESTTMP/apply-stage-refused" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>"$TESTTMP/err" || rc=$?
assert_eq "$rc" "1" "a refused stage fails the run"
assert_eq "$(calls dnf-offline-arm)" "0" "...arms nothing"
assert_eq "$(calls dnf-offline-clean)" "0" "...and cleans nothing"
assert_eq "$(last_error)" \
  "nothing was prepared, because the stored offline transaction could not be read and preparing updates would replace it. See: kempt doctor" \
  "...and says nothing was staged, and why"
grep -q "Staging was refused by Kempt's system helper" "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...and the event log records the refusal" || { echo "FAIL: no refusal event"; _fail=1; }
no_clean_advice "...and does not advise a clean"

# The same, over an EXISTING stage whose state file already reads as `ready`: the rebuild unwind
# (which cleans when the old stage looks gone) must not run for a refusal either.
stage_real
reset_run
KEMPT_APPLY_HELPER="$TESTTMP/apply-stage-refused" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>"$TESTTMP/err" || true
assert_eq "$(calls dnf-offline-clean)" "0" "a refused re-stage never cleans the previous stage"

# --- the arm fails for an ordinary reason, and the unwind clean is refused ------------------------
# The pre-flight refuses a stored release upgrade outright, so the world starts ordinary and the
# stage "stores" one, which is the race the root-side check exists for.
stored offline-ready.toml; reset_run
apply_stub arm-fail-clean-refused 'dnf-offline-stage) cp "'"$RELUP"'" "'"$TOML"'" ;;
dnf-offline-arm) echo "Failed to prepare the system-update symlink" >&2; exit 1 ;;
dnf-offline-clean) echo "kempt-apply: refusing dnf-offline-clean: a Fedora release upgrade (44 -> 45) is stored" >&2; exit 3 ;;'
rc=0
KEMPT_APPLY_HELPER="$TESTTMP/apply-arm-fail-clean-refused" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>"$TESTTMP/err" || rc=$?
assert_eq "$rc" "1" "an arm failure whose unwind is refused still fails the run"
assert_eq "$(last_error)" "the updates were downloaded, but could not be set to install on the next restart" "...and the reason stays the arm"
grep -q 'left in place because a Fedora release upgrade (44 -> 45) is stored' "$TESTTMP/err" \
  && echo "ok: ...and the warning says the stored transaction was left in place, and why" \
  || { echo "FAIL: no left-in-place warning"; _fail=1; cat "$TESTTMP/err"; }
grep -q 'See: kempt doctor' "$WORLD/notifications" \
  && echo "ok: ...and the notification points at the doctor" || { echo "FAIL: notification"; _fail=1; cat "$WORLD/notifications"; }
no_clean_advice "...and nothing advises a clean"

# --- a failed re-stage whose clean is refused leaves it for the doctor --------------------
stage_real
apply_stub stage-fail-clean-refused 'dnf-offline-stage) echo "No space left on device" >&2; exit 1 ;;
dnf-offline-clean) cp "'"$RELUP"'" "'"$TOML"'"
  echo "kempt-apply: refusing dnf-offline-clean: a Fedora release upgrade (44 -> 45) is stored" >&2; exit 3 ;;'
stored offline-download-complete.toml; reset_run
KEMPT_APPLY_HELPER="$TESTTMP/apply-stage-fail-clean-refused" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>"$TESTTMP/err" || true
assert_eq "$(calls dnf-offline-clean)" "1" "a failed re-stage still tries its unwind"
assert_eq "$(last_error)" \
  "could not replace the prepared updates, and what is stored was left in place because a Fedora release upgrade (44 -> 45) is stored. See: kempt doctor" \
  "...and the reason says what was left and why"
no_clean_advice "...and nothing advises a clean"

# --- a live run supersedes the stage, and the clean is refused -----------------------------------
# A release upgrade stored between the CLI's own check and the clean: the helper refuses.
apply_stub live-clean-relup 'dnf-upgrade) cp "'"$TESTTMP/live.tsv"'" "'"$WORLD/rpm.tsv"'" ;;
dnf-offline-clean) cp "'"$RELUP"'" "'"$TOML"'"
  echo "kempt-apply: refusing dnf-offline-clean: a Fedora release upgrade (44 -> 45) is stored" >&2; exit 3 ;;'
stage_real
reset_run
KEMPT_APPLY_HELPER="$TESTTMP/apply-live-clean-relup" "$KEMPT" update --surface=widget --no-flatpak >/dev/null 2>"$TESTTMP/err" || true
assert_eq "$(calls dnf-offline-clean)" "1" "a superseding live run asks for the clean"

# Refused without a release upgrade the CLI can see: the warning says why.
apply_stub live-clean-refused 'dnf-upgrade) cp "'"$TESTTMP/live.tsv"'" "'"$WORLD/rpm.tsv"'" ;;
dnf-offline-clean) echo "kempt-apply: refusing dnf-offline-clean: the stored offline transaction cannot be read, so it may be a Fedora release upgrade" >&2; exit 3 ;;'
stage_real
reset_run
KEMPT_APPLY_HELPER="$TESTTMP/apply-live-clean-refused" "$KEMPT" update --surface=widget --no-flatpak >/dev/null 2>"$TESTTMP/err" || true
grep -q 'superseded the staged transaction, but it could not be discarded. See: kempt doctor' "$TESTTMP/err" \
  && echo "ok: ...and warns that it was left in place" || { echo "FAIL: no warning"; _fail=1; cat "$TESTTMP/err"; }
no_clean_advice "...and does not advise a clean"

# --- the helper refuses because other users can change dnf5's folders ----------------------------
# The helper refuses the upgrade, the stage and the arm then, and its sentence is what the run reports.
# These folders turn unsafe after the run has started, the one case that still reaches the helper.
UNSAFE="$TESTTMP/unsafe-state"
UNSAFE_SAYS="Updates paused for safety: users other than root can change $UNSAFE. Run kempt doctor for the fix."
unsafe_refusal() { printf 'mkdir -m 0777 "%s"; echo "kempt-apply: %s" >&2; exit 3' "$UNSAFE" "$UNSAFE_SAYS"; }
apply_stub stage-unsafe "dnf-offline-stage) $(unsafe_refusal dnf-offline-stage) ;;"
stored offline-ready.toml; reset_run
rc=0
KEMPT_DNF_SYSIMAGE_DIR="$UNSAFE" KEMPT_APPLY_HELPER="$TESTTMP/apply-stage-unsafe" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>"$TESTTMP/err" || rc=$?
assert_eq "$rc" "1" "a stage refused over an unsafe dnf folder fails the run"
assert_eq "$(calls dnf-offline-arm)" "0" "...arms nothing"
assert_eq "$(calls dnf-offline-clean)" "0" "...and cleans nothing"
assert_eq "$(last_error)" "nothing was prepared. $UNSAFE_SAYS" \
  "...and the reason is the helper's sentence"

apply_stub arm-unsafe "dnf-offline-arm) $(unsafe_refusal dnf-offline-arm) ;;"
stored offline-ready.toml; reset_run; rm -rf "$UNSAFE"
KEMPT_DNF_OFFLINE_PKG_DIR="$UNSAFE" KEMPT_APPLY_HELPER="$TESTTMP/apply-arm-unsafe" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>"$TESTTMP/err" || true
assert_eq "$(calls dnf-offline-clean)" "0" "an arm refused over an unsafe dnf folder is not unwound"
assert_eq "$(last_error)" "the updates were downloaded, but not set to install on the next restart. $UNSAFE_SAYS" \
  "...and the reason is the helper's sentence"

apply_stub live-unsafe "dnf-upgrade) $(unsafe_refusal dnf-upgrade) ;;"
stored offline-ready.toml; reset_run; rm -rf "$UNSAFE"
rc=0
KEMPT_DNF_SYSIMAGE_DIR="$UNSAFE" KEMPT_APPLY_HELPER="$TESTTMP/apply-live-unsafe" "$KEMPT" update --surface=widget --no-flatpak >/dev/null 2>"$TESTTMP/err" || rc=$?
assert_eq "$rc" "1" "a live update refused over an unsafe dnf folder fails the run"
assert_eq "$(last_error)" "nothing was installed. $UNSAFE_SAYS" \
  "...and the reason is the helper's sentence"
grep -q "The update was refused by Kempt's system helper" "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...and the event log records the refusal" || { echo "FAIL: no live refusal event"; _fail=1; }
grep -q 'Run kempt doctor' "$WORLD/notifications" \
  && echo "ok: ...and the notification points at the doctor" || { echo "FAIL: notification"; _fail=1; cat "$WORLD/notifications"; }
# A refusal with no sentence of the helper's still says what kind of problem it is.
apply_stub live-silent 'dnf-upgrade) exit 3 ;;'
reset_run
KEMPT_APPLY_HELPER="$TESTTMP/apply-live-silent" "$KEMPT" update --surface=widget --no-flatpak >/dev/null 2>"$TESTTMP/err" || true
assert_eq "$(last_error)" "nothing was installed, because other users can change files in dnf's folders. See: kempt doctor" \
  "...and without a folder to name, it says dnf's folders"
rm -rf "$UNSAFE"

# --- folders this user can already see are unsafe: no helper, so no password prompt -------------------
mkdir -m 0777 "$UNSAFE"
apply_stub ok ""
for _sf in widget offline; do
  stored offline-ready.toml; reset_run
  rc=0
  KEMPT_DNF_SYSIMAGE_DIR="$UNSAFE" KEMPT_APPLY_HELPER="$TESTTMP/apply-ok" "$KEMPT" update --surface=$_sf --no-flatpak >/dev/null 2>"$TESTTMP/err" </dev/null || rc=$?
  assert_eq "$rc" "5" "$_sf over a folder other users can change: exit 5, nothing changed"
  assert_eq "$(calls dnf)" "0" "...and the helper, with its password prompt, is never asked"
  assert_contains "$(cat "$TESTTMP/err")" "nothing was changed, because other users can change files in $UNSAFE. See: kempt doctor" "...and the reason is the folder"
  assert_eq "$(compgen -G "$KEMPT_STATE_DIR/history/*.json" | wc -l)" "0" "...and no run is recorded, since none started"
done
# Apps still update when no system update is waiting, without a word to the helper.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/refresh-none"; chmod +x "$TESTTMP/refresh-none"
reset_run; rc=0
KEMPT_DNF_SYSIMAGE_DIR="$UNSAFE" KEMPT_APPLY_HELPER="$TESTTMP/apply-ok" KEMPT_REFRESH_HELPER="$TESTTMP/refresh-none" "$KEMPT" update --surface=widget --no-flatpak >/dev/null 2>"$TESTTMP/err" </dev/null || rc=$?
assert_eq "$rc" "0" "no system updates waiting: the run goes on"
assert_eq "$(calls dnf)" "0" "...and leaves the helper out"
# A stage has nothing else to do, so it refuses either way.
reset_run; rc=0
KEMPT_DNF_SYSIMAGE_DIR="$UNSAFE" KEMPT_APPLY_HELPER="$TESTTMP/apply-ok" KEMPT_REFRESH_HELPER="$TESTTMP/refresh-none" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>"$TESTTMP/err" </dev/null || rc=$?
assert_eq "$rc" "5" "...but a stage with nothing waiting still refuses"
# A check that cannot answer refuses too.
printf '#!/usr/bin/env bash\nexit 1\n' > "$TESTTMP/refresh-broken"; chmod +x "$TESTTMP/refresh-broken"
reset_run; rc=0
KEMPT_DNF_SYSIMAGE_DIR="$UNSAFE" KEMPT_APPLY_HELPER="$TESTTMP/apply-ok" KEMPT_REFRESH_HELPER="$TESTTMP/refresh-broken" "$KEMPT" update --surface=widget --no-flatpak >/dev/null 2>"$TESTTMP/err" </dev/null || rc=$?
assert_eq "$rc" "5" "a check that cannot answer refuses too"
rm -rf "$UNSAFE"

# --- the helper's own sentence, because only it knows ------------------------------------------------
# A user's reading cannot see what root was denied, and what is stored may be a second problem the helper never reached. So its last line is what the run reports.
S_CHECK="Kempt could not check /var/lib/secret (Permission denied). Run kempt doctor."
S_UNSAFE="Updates paused for safety: users other than root can change /var/cache/libdnf5. Run kempt doctor for the fix."
says() { printf 'echo "kempt-apply: %s" >&2; exit 3' "$1"; }
i=0
for sentence in "$S_CHECK" "$S_UNSAFE"; do
  i=$(( i + 1 ))
  apply_stub "w-stage-$i" "dnf-offline-stage) $(says "$sentence") ;;"
  stored offline-ready.toml; reset_run
  KEMPT_APPLY_HELPER="$TESTTMP/apply-w-stage-$i" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || true
  assert_eq "$(last_error)" "nothing was prepared. $sentence" "a refused stage reports the helper's sentence: ${sentence:0:40}"
  apply_stub "w-arm-$i" "dnf-offline-arm) $(says "$sentence") ;;"
  stored offline-ready.toml; reset_run
  KEMPT_APPLY_HELPER="$TESTTMP/apply-w-arm-$i" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || true
  assert_eq "$(last_error)" "the updates were downloaded, but not set to install on the next restart. $sentence" "...and a refused arm"
  assert_eq "$(calls dnf-offline-clean)" "0" "...which is not unwound"
  apply_stub "w-live-$i" "dnf-upgrade) $(says "$sentence") ;;"
  stored offline-ready.toml; reset_run
  KEMPT_APPLY_HELPER="$TESTTMP/apply-w-live-$i" "$KEMPT" update --surface=widget --no-flatpak >/dev/null 2>&1 || true
  assert_eq "$(last_error)" "nothing was installed. $sentence" "...and a refused live update"
done
# A problem this account cannot see gets past the CLI to root. That refusal is exit 1, and Flatpak still updates.
printf '#!/usr/bin/env bash\ntouch "%s/flatpak-ran"\n' "$WORLD" > "$TESTTMP/flatpak-update-log"; chmod +x "$TESTTMP/flatpak-update-log"
apply_stub w-seen-live "dnf-upgrade) $(says "$S_UNSAFE") ;;"
apply_stub w-seen-stage "dnf-offline-stage) $(says "$S_UNSAFE") ;;"
for _sf in widget offline; do
  rm -f "$WORLD/flatpak-ran"; stored offline-ready.toml; reset_run
  rc=0; _stub="$TESTTMP/apply-w-seen-live"; [[ "$_sf" == offline ]] && _stub="$TESTTMP/apply-w-seen-stage"
  KEMPT_FLATPAK_UPDATE_CMD="$TESTTMP/flatpak-update-log" KEMPT_APPLY_HELPER="$_stub" "$KEMPT" update --surface=$_sf >/dev/null 2>&1 </dev/null || rc=$?
  assert_eq "$rc" "1" "root's refusal of a $_sf run the CLI could not foresee is exit 1"
  assert_eq "$([[ -e "$WORLD/flatpak-ran" ]] && echo yes)" "yes" "...and Flatpak still updates"
done
# Folders caused it, and a release upgrade is stored as well: the helper's word stands.
apply_stub w-stage-relup "dnf-offline-stage) cp '$RELUP' '$TOML'; $(says "$S_CHECK") ;;"
stored offline-ready.toml; reset_run
KEMPT_APPLY_HELPER="$TESTTMP/apply-w-stage-relup" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || true
assert_eq "$(last_error)" "nothing was prepared. $S_CHECK" "a stored release upgrade is not blamed when the helper named the folders"
apply_stub w-arm-relup "dnf-offline-arm) cp '$RELUP' '$TOML'; $(says "$S_UNSAFE") ;;"
stored offline-ready.toml; reset_run
KEMPT_APPLY_HELPER="$TESTTMP/apply-w-arm-relup" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || true
assert_eq "$(last_error)" "the updates were downloaded, but not set to install on the next restart. $S_UNSAFE" "...nor at the arm"
# And when the helper did refuse over what is stored, the CLI's reason still says so.
apply_stub w-stage-stored 'dnf-offline-stage) cp "'"$RELUP"'" "'"$TOML"'"; echo "kempt-apply: refusing dnf-offline-stage: a Fedora release upgrade (44 -> 45) is stored" >&2; exit 3 ;;'
stored offline-ready.toml; reset_run
KEMPT_APPLY_HELPER="$TESTTMP/apply-w-stage-stored" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || true
assert_contains "$(last_error)" "a Fedora release upgrade (44 -> 45) is stored" "a refusal over a stored release upgrade keeps its reason"
# An earlier line in the log says nothing about this refusal: only the last line counts.
apply_stub w-stale "dnf-upgrade) echo 'kempt-apply: $S_CHECK' >&2; echo 'something else' >&2; exit 3 ;;"
stored offline-ready.toml; reset_run
KEMPT_APPLY_HELPER="$TESTTMP/apply-w-stale" "$KEMPT" update --surface=widget --no-flatpak >/dev/null 2>&1 || true
assert_not_contains "$(last_error)" "could not check" "a sentence that is not the helper's last line is not its reason"

# dnf_status starts unknown and every path names it. A run that reached history says ok or failed.
assert_eq "$(cat "$KEMPT_STATE_DIR"/history/*.json 2>/dev/null | jq -r 'select(.dnf != null) | .dnf.status' | grep -vxE 'ok|failed' | sort -u)" "" \
  "every run in history recorded dnf as ok or failed"

finish
