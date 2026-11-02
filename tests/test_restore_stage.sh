#!/usr/bin/env bash
# `kempt restore-stage` - setting a staged update to install again after another program removed
# its restart step.
#
# PackageKit removes /system-update after a refresh and after any rpm change, and leaves dnf5's
# state at `ready`. After a refresh the transaction is still good. After an rpm change dnf5 refuses
# it, so that case must never reach the root helper, and must never be offered.
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"

export WORLD="$TESTTMP/world"; mkdir -p "$WORLD"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"

cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$WORLD/notified" > "$TESTTMP/notify-stub"
chmod +x "$TESTTMP/refresh-stub" "$TESTTMP/dnf-reboot-no" "$TESTTMP/notify-stub"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no"
export KEMPT_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
export KEMPT_SKIP_REFRESH=1
export KEMPT_NOTIFY="$TESTTMP/notify-stub"
"$KEMPT" config set include_flatpak false >/dev/null

TOML="$TESTTMP/offline-transaction-state.toml"
export KEMPT_OFFLINE_TOML="$TOML"
mkdir -p "$KEMPT_OFFLINE_DATADIR"
marker="$KEMPT_STATE_DIR/offline_staged.json"
st="$KEMPT_STATE_DIR/state.json"

apply_stub() {  # name 'case arms' → an apply helper recording every call
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
ARM='dnf-offline-arm) ln -sfn "'"$KEMPT_OFFLINE_DATADIR"'" "'"$KEMPT_OFFLINE_LINK"'" ;;'
apply_stub arms "$ARM"
apply_stub no-link ''
apply_stub cancelled 'dnf-offline-arm) exit 126 ;;'
apply_stub refused 'dnf-offline-arm) exit 3 ;;'
apply_stub dnf-says-no 'dnf-offline-arm) echo "dnf5 said why" >&2; exit 1 ;;'
calls() { grep -c "APPLY $1" "$WORLD/apply-calls" 2>/dev/null || true; }
restore() {  # helper-stub → sets rc and out
  rc=0; : > "$WORLD/apply-calls"
  out="$(KEMPT_APPLY_HELPER="$TESTTMP/apply-$1" "$KEMPT" restore-stage 2>"$TESTTMP/err")" || rc=$?
}
staged_armed() {  # a real armed stage from this world
  cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
  cp "$FIXTURES/offline-ready.toml" "$TOML"
  rm -f "$marker" "$KEMPT_OFFLINE_LINK" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
  KEMPT_APPLY_HELPER="$TESTTMP/apply-arms" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
  : > "$WORLD/notified"
}
staged_lost() {  # ...and what PackageKit's refresh leaves of it, seen by a check
  staged_armed
  rm -f "$KEMPT_OFFLINE_LINK"
  "$KEMPT" check >/dev/null 2>&1
}

# --- what a refresh leaves behind is offered ------------------------------------------------------
staged_lost
assert_eq "$(jq -r '.offline_staged // "absent"' "$st")" "absent" \
  "a stage with no restart step is not published as staged"
assert_eq "$(jq -r '.offline_stage_restorable.staged_at == ($m[0].staged_at)' --slurpfile m "$marker" "$st")" "true" \
  "...and is published as one that can be put back"
assert_contains "$(cat "$WORLD/notified")" "another program removed its restart step" \
  "the notification says what happened"
assert_contains "$(cat "$WORLD/notified")" "Put It Back" "...and how to fix it"
assert_not_contains "$(cat "$WORLD/notified")" "dnf5 offline clean" \
  "...and not the command that would throw the download away"

# --- putting it back -----------------------------------------------------------------------------
count="$(jq -r '.staged' "$marker")"
restore arms
assert_eq "$rc" "0" "restore-stage over a stage that lost its restart step succeeds"
assert_eq "$(calls dnf-offline-arm)" "1" "...through the verb that armed it the first time"
assert_eq "$(grep -c APPLY "$WORLD/apply-calls")" "1" "...and no other root helper call"
assert_eq "$out" "Put back. The next restart installs your $count staged updates." "...and says so"
assert_eq "$(jq -r '.armed' "$marker")" "true" "...and the record says it will install"
assert_eq "$(jq -r '.offline_staged.count' "$st")" "$count" "...and so does state.json"
assert_eq "$(jq -r '.offline_stage_restorable // "absent"' "$st")" "absent" "...and it stops being offered"
: > "$WORLD/notified"
"$KEMPT" check >/dev/null 2>&1
assert_eq "$(cat "$WORLD/notified")" "" "the next check has nothing to say about it"
grep -q 'restore-stage put the staged update back' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...and it is in the event log" || { echo "FAIL: no restore line in the log"; _fail=1; }
# Losing it a second time is news again: the next day's refresh does exactly this.
rm -f "$KEMPT_OFFLINE_LINK"; : > "$WORLD/notified"
"$KEMPT" check >/dev/null 2>&1
assert_contains "$(cat "$WORLD/notified")" "another program removed its restart step" \
  "a second loss is announced too"

# --- already set ---------------------------------------------------------------------------------
staged_armed
restore arms
assert_eq "$rc" "0" "restore-stage over an armed stage is not a failure"
assert_eq "$(calls dnf-offline-arm)" "0" "...and asks root for nothing"
assert_contains "$out" "already set to install" "...and says so"

# --- the package set moved: the stage is dead, and dnf5 would refuse it ---------------------------
staged_lost
restore_offered="$(jq -r '.offline_stage_restorable // "absent"' "$st")"
assert_eq "$([[ "$restore_offered" != absent ]] && echo offered)" "offered" "the fixture starts from an offered stage"
printf 'someother\t1-1.fc44\n' >> "$WORLD/rpm.tsv"
"$KEMPT" check >/dev/null 2>&1
assert_eq "$(jq -r '.offline_stage_restorable // "absent"' "$st")" "absent" \
  "a package change takes the offer away at the next check"
restore arms
assert_eq "$rc" "5" "restore-stage refuses once packages have changed"
assert_eq "$(calls dnf-offline-arm)" "0" "...before asking for a password"
assert_contains "$(cat "$TESTTMP/err")" "cannot be put back" "...and says why"
staged_armed; rm -f "$KEMPT_OFFLINE_LINK"; printf 'someother\t1-1.fc44\n' >> "$WORLD/rpm.tsv"
"$KEMPT" check >/dev/null 2>&1
assert_not_contains "$(cat "$WORLD/notified")" "Put It Back" \
  "a stage lost to a package change never mentions Put It Back"
assert_contains "$(cat "$WORLD/notified")" "To stage your updates again" "...and gives the remedy that works"

# --- a press that does not work leaves the stage reported as lost ---------------------------------
staged_lost
restore cancelled
assert_eq "$rc" "1" "a cancelled password prompt is a failed run"
assert_contains "$(cat "$TESTTMP/err")" "not put back" "...and says nothing changed"
assert_eq "$(jq -r '.armed' "$marker")" "false" "...and the record still says it will not install"
assert_contains "$(cat "$TESTTMP/err")" "press Put It Back again" "...and pressing again is worth it"
"$KEMPT" check >/dev/null 2>&1
assert_eq "$(jq -r '.offline_stage_restorable != null' "$st")" "true" "...so it is still offered"
restore no-link
assert_eq "$rc" "1" "a helper that exits 0 without the restart step is a failure too"
assert_eq "$(jq -r '.armed' "$marker")" "false" "...and is not recorded as restored"
staged_lost
restore dnf-says-no
assert_eq "$rc" "1" "dnf5 turning the stage down is a failure"
assert_contains "$(cat "$TESTTMP/err")" "dnf5 said why" "...which keeps dnf5's own words"
assert_eq "$(jq -r '.offline_stage_restorable // "absent"' "$st")" "absent" \
  "...and stops offering a button that would ask for a password to hear the same answer"
restore arms
assert_eq "$(calls dnf-offline-arm)" "0" "...and a second try does not ask either"
staged_lost
restore refused
assert_eq "$rc" "5" "the root helper's refusal is a refusal"
assert_contains "$(cat "$TESTTMP/err")" "See: kempt doctor" "...with somewhere to look"

# --- not Kempt's to put back ----------------------------------------------------------------------
staged_lost
jq -c '. + {replaced: true}' "$marker" > "$marker.new" && mv "$marker.new" "$marker"
restore arms
assert_eq "$rc" "5" "a stage replaced outside Kempt is refused"
assert_eq "$(calls dnf-offline-arm)" "0" "...without arming somebody else's transaction"

staged_lost
cp "$FIXTURES/offline-release-upgrade.toml" "$TOML"
restore arms
assert_eq "$rc" "5" "a stored release upgrade is refused"
assert_eq "$(calls dnf-offline-arm)" "0" "...without arming it"

# Armed, under a marker a check already demoted: "Put back" is only true if the transaction is this one.
demoted_armed() {
  staged_lost
  ln -sfn "$KEMPT_OFFLINE_DATADIR" "$KEMPT_OFFLINE_LINK"
}
demoted_armed
restore arms
assert_eq "$rc" "0" "the restart step back on its own under a demoted marker is recorded"
assert_eq "$(calls dnf-offline-arm)" "0" "...asking root for nothing"
assert_eq "$(jq -r '.armed' "$marker")" "true" "...and the record is right again"
demoted_armed
cp "$FIXTURES/offline-release-upgrade.toml" "$TOML"
restore arms
assert_eq "$rc" "5" "...but a release upgrade behind that link is not reported as put back"
assert_not_contains "$out" "Put back" "...in any words"
demoted_armed
printf 'someother\t1-1.fc44\n' >> "$WORLD/rpm.tsv"
restore arms
assert_eq "$rc" "5" "...nor is a stage whose packages have moved"
staged_armed
cp "$FIXTURES/offline-release-upgrade.toml" "$TOML"
restore arms
assert_not_contains "$out" "already set" "a release upgrade behind an armed link is not called already set"

# A marker with no cookie cannot say the transaction is this stage, so nothing is armed on its word.
staged_lost
jq -c 'del(.rpmdb_cookie)' "$marker" > "$marker.new" && mv "$marker.new" "$marker"
restore arms
assert_eq "$rc" "5" "a marker with no cookie is refused"
assert_eq "$(calls dnf-offline-arm)" "0" "...before asking root for anything"

# Another updater's restart: not "the system changed", and not advice to clean it away.
staged_lost
ln -sfn "$TESTTMP/someone-elses" "$KEMPT_OFFLINE_LINK"
restore arms
assert_eq "$rc" "5" "another updater's restart is refused"
assert_contains "$(cat "$TESTTMP/err")" "Another updater has prepared the next restart" "...saying so"
assert_not_contains "$(cat "$TESTTMP/err")" "dnf5 offline clean" "...and not advising what would cancel it"
rm -f "$KEMPT_OFFLINE_LINK"

# A check announcing the loss while a restore puts it back must not write the old answer over it.
staged_armed
rm -f "$KEMPT_OFFLINE_LINK"
cat > "$TESTTMP/notify-restores" <<STUB
#!/usr/bin/env bash
ln -sfn "$KEMPT_OFFLINE_DATADIR" "$KEMPT_OFFLINE_LINK"
STUB
chmod +x "$TESTTMP/notify-restores"
KEMPT_NOTIFY="$TESTTMP/notify-restores" "$KEMPT" check >/dev/null 2>&1
assert_eq "$(jq -r '.armed' "$marker")" "true" "a restart step back during the announcement keeps the record armed"

rm -f "$marker" "$KEMPT_OFFLINE_LINK"; cp "$FIXTURES/offline-ready.toml" "$TOML"
restore arms
assert_eq "$rc" "5" "with no stage of Kempt's there is nothing to put back"
assert_eq "$(calls dnf-offline-arm)" "0" "...and nothing is armed"

assert_exit 2 "restore-stage takes no arguments" "$KEMPT" restore-stage --all

finish
