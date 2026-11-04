#!/usr/bin/env bash
# The promises in tests/PROMISES.md that no other file stood behind. Two of them are not kept yet, and
# each says so with a skip, which the suite's summary lists: a skip is not a pass.
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"

export WORLD="$TESTTMP/world"; mkdir -p "$WORLD" "$TESTTMP/stubbin"
for b in dnf5 dnf systemctl pkexec sudo flatpak; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/path-calls"\nexit 1\n' "$b" "$WORLD" > "$TESTTMP/stubbin/$b"
  chmod +x "$TESTTMP/stubbin/$b"
done
export PATH="$TESTTMP/stubbin:$PATH"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"; cp "$FIXTURES/flatpak-list.tsv" "$WORLD/fp.tsv"
: > "$WORLD/notifications"; : > "$WORLD/path-calls"
mk() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$TESTTMP/$1"; chmod +x "$TESTTMP/$1"; }
mk fp-update-stub 'exit 0'
mk refresh-stub "[[ \"\$1\" == check ]] && { cat \"$FIXTURES/dnf-check-update.txt\"; exit 100; }; exit 0"
mk notify-stub "printf 'NOTIFY %s\n' \"\$*\" >> \"$WORLD/notifications\""
mk dnf-no-reboot 'exit 0'
# The root helper's stand-in: says which session it is in, then waits to be let go.
mk apply-stub "ps -o sid= -p \$\$ | tr -d ' ' > \"$WORLD/update-session\"
for _ in {1..200}; do [[ -e \"$WORLD/release\" ]] && break; sleep 0.1; done
touch \"$WORLD/finished\"
exit 0"
export KEMPT_APPLY_HELPER="$TESTTMP/apply-stub" KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_FLATPAK_UPDATE_CMD="$TESTTMP/fp-update-stub" KEMPT_NOTIFY="$TESTTMP/notify-stub"
export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export KEMPT_FLATPAK_LIST_CMD="cat $WORLD/fp.tsv" KEMPT_FLATPAK_SNAP_CMD="cat $WORLD/fp.tsv"
export KEMPT_SKIP_REFRESH=1 KEMPT_DNF_CMD="$TESTTMP/dnf-no-reboot" KEMPT_DNF_HISTORY_CMD=false
export KEMPT_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
LINK="$TESTTMP/system-update"; export KEMPT_OFFLINE_LINK="$LINK"; rm -f "$LINK"
export KEMPT_OFFLINE_DATADIR="$TESTTMP/offline"; mkdir -p "$KEMPT_OFFLINE_DATADIR"
TOML="$KEMPT_OFFLINE_DATADIR/offline-transaction-state.toml"; export KEMPT_OFFLINE_TOML="$TOML"
TX="$KEMPT_OFFLINE_DATADIR/transaction.json"; export KEMPT_OFFLINE_TXJSON="$TX"
STATE_FILE="$KEMPT_STATE_DIR/state.json"

wait_for() {  # file-test-args... : up to 20 seconds
  local _
  for _ in {1..200}; do
    test "$@" && return 0
    sleep 0.1
  done
  return 1
}

# --- an update outlives whatever started it ---------------------------------------------------------
# The widget starts an update and may then die, with plasmashell or on its own. Its whole session is
# killed here, the moment the update reaches the root helper.
"$KEMPT" config set surface background >/dev/null
setsid bash -c 'echo "$$" > "$WORLD/caller-session"; "$0" run; exec sleep 60' "$KEMPT" >/dev/null 2>&1 &
assert_exit 0 "premise: the started update reached the root helper" -- wait_for -s "$WORLD/update-session"
caller="$(cat "$WORLD/caller-session")"
assert_exit 0 "premise: the caller is still there to be killed" -- kill -0 "$caller"
assert_exit 1 "the update is not in the session that started it" -- test "$(cat "$WORLD/update-session")" = "$caller"
kill -KILL -- "-$caller" 2>/dev/null || true
touch "$WORLD/release"
assert_exit 0 "...so killing that session leaves it running to the end" -- wait_for -e "$WORLD/finished"
hist_entry() { find "$KEMPT_STATE_DIR/history" -name '*.json' 2>/dev/null | awk 'NR==1'; }
for _ in {1..200}; do [[ -n "$(hist_entry)" ]] && break; sleep 0.1; done
assert_eq "$(jq -r .status "$(hist_entry)" 2>/dev/null)" "ok" "...and it records its own result"
for _ in {1..100}; do flock -n "$KEMPT_STATE_DIR/lock" true && break; sleep 0.1; done

# --- deleting the state folder ----------------------------------------------------------------------
armed() {
  cp "$FIXTURES/offline-ready.toml" "$TOML"; rm -f "$LINK"; ln -s "$KEMPT_OFFLINE_DATADIR" "$LINK"
  cat > "$TX" <<'JSON'
{"version":"1.0","rpms":[{"nevra":"librepo-1.21.0-1.fc44.x86_64","action":"Upgrade","reason":"Dependency","repo_id":"updates"}]}
JSON
  mkdir -p "$KEMPT_STATE_DIR/snapshots"
  cp "$FIXTURES/rpm-installed.tsv" "$KEMPT_STATE_DIR/snapshots/offline-pre-test.tsv"
  jq -n --arg snap "$KEMPT_STATE_DIR/snapshots/offline-pre-test.tsv" \
    '{version:1, staged_at:"2026-11-02T10:00:00+02:00", pre_snapshot:$snap, boot_id:"boot-before", staged:1,
      armed:true, staged_names:["librepo"], staged_names_source:"transaction"}' > "$KEMPT_STATE_DIR/offline_staged.json"
}
check() { KEMPT_BOOT_ID="$1" KEMPT_RPM_QA_CMD="false" "$KEMPT" check >/dev/null 2>&1 || true; }

armed
check boot-before
assert_eq "$(jq -r .offline_staged.count "$STATE_FILE")" "1" "premise: a stage is armed and published"
: > "$WORLD/notifications"
rm -rf "$KEMPT_STATE_DIR"
check boot-before
assert_eq "$(( $(wc -l < "$WORLD/notifications") <= 1 ))" "1" "deleting the state folder costs at most one notification"
check boot-before
assert_eq "$(( $(wc -l < "$WORLD/notifications") <= 1 ))" "1" "...and the next check adds none"
if [[ "$(jq -r '.offline_staged.count // empty' "$STATE_FILE")" == 1 ]]; then
  echo "ok: ...and the armed stage is still shown"
else
  skip "pending: the armed stage is not shown once the state folder is gone, because it is read from Kempt's own note and not from dnf5"
fi

# --- "cannot tell" ------------------------------------------------------------------------------------
# test_stage_unknown.sh holds that nothing false is said when the stored state cannot be read. Nothing
# says "cannot tell" either, and saying it needs a message this project has not added yet.
skip "pending: no surface answers \"cannot tell\" when the stored offline state cannot be read"

assert_eq "$(cat "$WORLD/path-calls")" "" "nothing here reached a real dnf, pkexec or systemctl"
finish
