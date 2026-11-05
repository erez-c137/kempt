#!/usr/bin/env bash
# Another updater holds the next restart: who holds it, what each command does about it, and what is
# said after a restart that installed some, all or none of a stage.
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"

export WORLD="$TESTTMP/world"; mkdir -p "$WORLD"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
cp "$FIXTURES/flatpak-list.tsv" "$WORLD/fp.tsv"
: > "$WORLD/calls"; : > "$WORLD/notifications"

cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$*" >> "$WORLD/calls"
exit 0
STUB
cat > "$TESTTMP/fp-update-stub" <<STUB
#!/usr/bin/env bash
echo "FLATPAK \$*" >> "$WORLD/calls"
exit 0
STUB
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
cat > "$TESTTMP/refresh-nothing" <<STUB
#!/usr/bin/env bash
exit 0
STUB
cat > "$TESTTMP/refresh-fails" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { echo "Failed to download metadata" >&2; exit 1; }
exit 0
STUB
cat > "$TESTTMP/notify-stub" <<STUB
#!/usr/bin/env bash
printf 'NOTIFY %s\n' "\$*" >> "$WORLD/notifications"
STUB
chmod +x "$TESTTMP/apply-stub" "$TESTTMP/fp-update-stub" "$TESTTMP/refresh-stub" "$TESTTMP/refresh-nothing" \
  "$TESTTMP/refresh-fails" "$TESTTMP/notify-stub"
export KEMPT_APPLY_HELPER="$TESTTMP/apply-stub" KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_FLATPAK_UPDATE_CMD="$TESTTMP/fp-update-stub" KEMPT_NOTIFY="$TESTTMP/notify-stub"
export KEMPT_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export KEMPT_FLATPAK_LIST_CMD="cat $WORLD/fp.tsv" KEMPT_FLATPAK_SNAP_CMD="cat $WORLD/fp.tsv"
export KEMPT_SKIP_REFRESH=1
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-no-reboot"; chmod +x "$TESTTMP/dnf-no-reboot"
export KEMPT_DNF_CMD="$TESTTMP/dnf-no-reboot"

LINK="$TESTTMP/system-update"
export KEMPT_OFFLINE_LINK="$LINK"
holder() { bash -c 'source "$1/lib/common.sh"; restart_holder' _ "$REPO_ROOT"; }
foreign_link() { rm -f "$LINK"; ln -s /var/lib/PackageKit/prepared-update "$LINK"; }
no_link() { rm -f "$LINK"; }
state() { jq -r "$1" "$KEMPT_STATE_DIR/state.json"; }

# --- restart_holder ----------------------------------------------------------------------------
no_link
assert_eq "$(holder)" "none" "nothing there: nobody holds the restart"
offline_dir="$TESTTMP/offline-data"; mkdir -p "$offline_dir"
export KEMPT_OFFLINE_DATADIR="$offline_dir"
ln -s "$offline_dir" "$LINK"
assert_eq "$(holder)" "kempt" "dnf5's own link: Kempt's side holds it"
foreign_link
assert_eq "$(holder)" "other" "a link to somewhere else: another updater"
rm -f "$LINK"; ln -s "$TESTTMP/no/such/target" "$LINK"
assert_eq "$(holder)" "other" "a dangling link still diverts the boot"
rm -f "$LINK"; : > "$LINK"
assert_eq "$(holder)" "other" "a plain file diverts the boot too"
if [[ "$(id -u)" != 0 ]]; then
  chmod 000 "$LINK"
  assert_eq "$(holder)" "other" "a file nobody may read is still there"
  rm -f "$LINK"
  sealed="$TESTTMP/sealed"; mkdir -p "$sealed"; ln -s /x "$sealed/system-update"
  chmod 000 "$sealed"
  assert_eq "$(KEMPT_OFFLINE_LINK="$sealed/system-update" holder)" "none" \
    "a folder nobody may enter hides what is in it, and hiding is not holding"
  chmod 755 "$sealed"
fi
no_link
assert_exit 0 "the small test readers share says yes behind a foreign link" -- bash -c \
  'source "$1/lib/common.sh"; ln -s /x "$KEMPT_OFFLINE_LINK"; restart_held_by_other; r=$?; rm -f "$KEMPT_OFFLINE_LINK"; exit $r' _ "$REPO_ROOT"
assert_exit 1 "...and no with nothing there" -- bash -c 'source "$1/lib/common.sh"; restart_held_by_other' _ "$REPO_ROOT"

# --- what the check publishes ------------------------------------------------------------------
no_link
"$KEMPT" check >/dev/null
assert_eq "$(state .restart_holder)" "none" "the state says nobody holds it"
assert_eq "$(state .discover_unattended)" "false" "...and Discover is not set to take it"
assert_not_contains "$("$KEMPT" status 2>&1 || true)" "belongs to another updater" "...and status is silent"
foreign_link
"$KEMPT" check >/dev/null
assert_eq "$(state .restart_holder)" "other" "the state names another updater"
assert_contains "$("$KEMPT" status 2>&1 || true)" "Another updater has prepared the next restart" "...and status has a line saying so"
# The write a run makes once its stage is armed, with no check behind it yet.
jq -c '.restart_holder = "none"' "$KEMPT_STATE_DIR/state.json" > "$TESTTMP/s.json" && cp "$TESTTMP/s.json" "$KEMPT_STATE_DIR/state.json"
bash -c 'source "$1/lib/common.sh"; publish_staged_state_write "" "" ""' _ "$REPO_ROOT"
assert_eq "$(state .restart_holder)" "other" "...and a run's own write says so before the next check"
no_link

# --- kempt update to a restart -----------------------------------------------------------------
gate_refuses() {  # label, then the environment and arguments
  local label="$1" rc=0 err; shift
  : > "$WORLD/calls"; : > "$WORLD/notifications"
  local hist_before; hist_before="$(ls "$KEMPT_STATE_DIR/history" 2>/dev/null | wc -l)"
  err="$(env "$@" 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "5" "$label: refused with the code for this condition"
  assert_eq "$(cat "$WORLD/calls")" "" "$label: no download and no Flatpak"
  assert_contains "$err" "another updater has prepared the next restart" "$label: says why"
  assert_eq "$(ls "$KEMPT_STATE_DIR/history" 2>/dev/null | wc -l)" "$hist_before" "$label: nothing recorded as a run"
}
foreign_link
gate_refuses "a foreign link" "$KEMPT" update --surface=offline
assert_contains "$(cat "$WORLD/notifications")" "another updater has prepared the next restart" "...and the notification says so"
assert_not_contains "$(cat "$WORLD/notifications")" "install on" "...and promises nothing"
rm -f "$LINK"; ln -s "$TESTTMP/no/such/target" "$LINK"
gate_refuses "a dangling link" "$KEMPT" update --surface=offline
rm -f "$LINK"; : > "$LINK"
gate_refuses "a plain file" "$KEMPT" update --surface=offline

foreign_link
"$KEMPT" config set surface offline
gate_refuses "the configured surface" "$KEMPT" update
"$KEMPT" config set auto_accept false
gate_refuses "a press with auto_accept off" "$KEMPT" update --answered --surface=offline </dev/null
gate_refuses "...and the same from the configured surface" "$KEMPT" update --answered </dev/null
# The widget's consent is to a live run, so it does not turn a stage asked for into one.
gate_refuses "a stage asked for with the flag and auto_accept off" "$KEMPT" update --answered --surface=offline --risky-ok </dev/null
# ...where a terminal must not turn the stage asked for into a live run.
: > "$WORLD/calls"; rc=0
python3 -c 'import pty, sys; sys.exit(pty.spawn(sys.argv[1:]) >> 8)' "$KEMPT" update --surface=offline >/dev/null 2>&1 </dev/null || rc=$?
assert_eq "$rc" "5" "a stage asked for at a terminal with auto_accept off is refused"
assert_eq "$(cat "$WORLD/calls")" "" "...and changes nothing"
"$KEMPT" config set auto_accept true
"$KEMPT" config set surface popup 2>/dev/null || true
gate_refuses "a check that cannot answer" KEMPT_REFRESH_HELPER="$TESTTMP/refresh-fails" "$KEMPT" update --surface=offline

# Nothing to stage: the run carries on, so whatever else it does still happens.
: > "$WORLD/calls"; rc=0
KEMPT_REFRESH_HELPER="$TESTTMP/refresh-nothing" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "an empty check behind a foreign link carries on"
for n in $(sed -n 's/^\([a-zA-Z0-9-]*\)\.[a-z0-9_]* .*/\1/p' "$FIXTURES/dnf-check-update.txt" | sort -u); do
  "$KEMPT" hold "dnf:$n" >/dev/null 2>&1
done
: > "$WORLD/calls"; rc=0
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "every update held behind a foreign link carries on"
for n in $(sed -n 's/^\([a-zA-Z0-9-]*\)\.[a-z0-9_]* .*/\1/p' "$FIXTURES/dnf-check-update.txt" | sort -u); do
  "$KEMPT" unhold "dnf:$n" >/dev/null 2>&1
done

# Live with nobody asked: the widget's last read may have said Flatpak alone, and this check found more.
gate_refuses "a live run nobody was asked about" "$KEMPT" update --surface=popup
_live_err="$("$KEMPT" update --surface=popup 2>&1 >/dev/null || true)"
assert_contains "$_live_err" "updating now may stop what it prepared" "...saying what a live update risks"
assert_not_contains "$_live_err" "nothing was staged" "...not that a stage was refused"
# Held, and other users can change a dnf folder: the helper would refuse a terminal run too, so the
# refusal names both and does not offer one.
_unsafe="$TESTTMP/unsafe-cache"; mkdir -p "$_unsafe"; chmod 777 "$_unsafe"
gate_refuses "held with an unsafe folder" KEMPT_DNF_CACHE_DIR="$_unsafe" "$KEMPT" update --surface=popup
for _args in "--surface=popup" "--surface=offline"; do
  _err="$(KEMPT_DNF_CACHE_DIR="$_unsafe" "$KEMPT" update $_args 2>&1 >/dev/null || true)"
  assert_contains "$_err" "other users can change files in $_unsafe" "$_args: names the folder"
  assert_contains "$_err" "See: kempt doctor" "$_args: sends the reader to the fix"
  assert_not_contains "$_err" "in a terminal" "$_args: offers no run the helper would refuse"
done
# Flatpak alone is not held up by the restart, so this refusal is not the one that speaks for it.
: > "$WORLD/calls"; rc=0
KEMPT_DNF_CACHE_DIR="$_unsafe" KEMPT_REFRESH_HELPER="$TESTTMP/refresh-nothing" "$KEMPT" update --surface=popup >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "held with an unsafe folder and no system updates: Flatpak still runs"
assert_contains "$(cat "$WORLD/calls")" "FLATPAK" "...and updates the apps"
chmod 755 "$_unsafe"
# The widget asked: the flag says so, and that is the choice it offers.
: > "$WORLD/calls"; rc=0
"$KEMPT" update --surface=popup --risky-ok >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "a live run the widget asked about is not refused"
assert_contains "$(cat "$WORLD/calls")" "APPLY dnf-upgrade" "...and upgrades"
# A terminal: dnf5 asks there, and it is the way the refusal names.
: > "$WORLD/calls"; rc=0
python3 -c 'import pty, sys; sys.exit(pty.spawn(sys.argv[1:]) >> 8)' "$KEMPT" update --surface=widget >/dev/null 2>&1 </dev/null || rc=$?
assert_eq "$rc" "0" "a terminal is not refused"
assert_contains "$(cat "$WORLD/calls")" "APPLY dnf-upgrade" "...and upgrades"
# A terminal on one side only cannot show and ask.
: > "$WORLD/calls"; rc=0
python3 -c 'import pty, sys; sys.exit(pty.spawn(sys.argv[1:]) >> 8)' bash -c '"$0" update --surface=widget </dev/null' "$KEMPT" >/dev/null 2>&1 </dev/null || rc=$?
assert_eq "$rc" "5" "output to a terminal with no input from one is refused"
assert_eq "$(grep -c APPLY "$WORLD/calls" || true)" "0" "...and installs nothing"
# Flatpak alone: nothing that updater prepared is touched.
: > "$WORLD/calls"; rc=0
KEMPT_REFRESH_HELPER="$TESTTMP/refresh-nothing" "$KEMPT" update --surface=popup >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "Flatpak with no system updates still runs, unasked"
assert_contains "$(cat "$WORLD/calls")" "FLATPAK" "...and updates the apps"
gate_refuses "a live check that cannot answer" KEMPT_REFRESH_HELPER="$TESTTMP/refresh-fails" "$KEMPT" update --surface=popup

# No foreign link: the gate does not get in the way.
no_link
: > "$WORLD/calls"; rc=0
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "with nobody holding the restart the stage goes ahead"
assert_contains "$(cat "$WORLD/calls")" "APPLY dnf-offline-stage" "...and reaches dnf5"

# --- the risky prompt --------------------------------------------------------------------------
export KEMPT_RISKY_RE='^bash$'
foreign_link
: > "$WORLD/calls"; : > "$WORLD/notifications"
sout="$(KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget <<<"s" 2>&1)" || true
assert_contains "$sout" "Staging is not available: another updater has prepared the next restart" "the risky prompt drops staging"
assert_not_contains "$sout" "[s]" "...and does not offer the key"
assert_eq "$(grep -c 'APPLY dnf-offline-stage' "$WORLD/calls" || true)" "0" "...and answering s anyway never stages"
assert_contains "$sout" "Staging is not available, because another updater has prepared the next restart. Answer u or a." "...and is turned down in words"
assert_contains "$sout" "aborted" "...and the end of input ends the run"
: > "$WORLD/notifications"
"$KEMPT" update --surface=popup </dev/null >/dev/null 2>&1 || true
assert_not_contains "$(cat "$WORLD/notifications")" "--surface=offline" "...and the notification gives no advice to stage"
no_link
: > "$WORLD/calls"
sout="$(KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=widget <<<"s" 2>&1)" || true
assert_contains "$(cat "$WORLD/calls")" "APPLY dnf-offline-stage" "with nobody holding the restart the same answer stages"
unset KEMPT_RISKY_RE

# --- what doctor and status say about a folder other users can change ------------------------------
_mfolder="$TESTTMP/unsafe-folder"; mkdir -p "$_mfolder/repo"; chmod 777 "$_mfolder/repo"
drep="$(KEMPT_DNF_OFFLINE_PKG_DIR="$_mfolder" "$KEMPT" doctor 2>&1 || true)"
assert_contains "$drep" "A changed package there installs as root at the next restart" "the staged folder's row says what is at stake"
for _row in KEMPT_DNF_CACHE_DIR KEMPT_DNF_SYSIMAGE_DIR KEMPT_DNF_OFFLINE_PKG_DIR; do
  drep="$(env "$_row=$_mfolder" "$KEMPT" doctor 2>&1 || true)"
  assert_contains "$drep" "Kempt 0.1.7 or earlier may have left them that way" "$_row: it can be true, so it is said"
done
KEMPT_DNF_CACHE_DIR="$_mfolder" "$KEMPT" check >/dev/null 2>&1 || true
srep="$(KEMPT_DNF_CACHE_DIR="$_mfolder" "$KEMPT" status 2>&1 || true)"
assert_contains "$srep" "Updates paused for safety: other users can change files in $_mfolder. Run kempt doctor for the fix." "status says updates are paused and names the folder"
rm -rf "$_mfolder"; "$KEMPT" check >/dev/null 2>&1 || true

# --- the last run, while another updater holds the restart ------------------------------------------
_hd="$KEMPT_STATE_DIR/history"; rm -rf "$_hd"; mkdir -p "$_hd"
jq -n '{timestamp:"2026-11-04T10:00:00+02:00", surface:"offline", status:"ok", staged:256, reboot_needed:false, log:"",
        backends:{dnf:{updated:[],added:[],removed:[],status:"ok"},flatpak:{updated:[],added:[],removed:[],status:"skipped"}}}' > "$_hd/20261104T100000.json"
rm -f "$LINK"; ln -s "$KEMPT_OFFLINE_DATADIR" "$LINK"
srep="$("$KEMPT" status 2>&1 || true)"
assert_contains "$srep" "staged 256 updates for a restart" "an armed stage reads as itself"
foreign_link
srep="$("$KEMPT" status 2>&1 || true)"
assert_contains "$srep" "staged 256 updates, but another updater has since prepared the next restart" "...and held, it says what became of the restart"
assert_not_contains "$srep" "for a restart" "...and not that it is for one"
no_link; rm -rf "$_hd"

# --- doctor while another updater holds it -------------------------------------------------------
qa="$TESTTMP/qa"; printf 'bash-0:5.3.9-1.fc44.x86_64\n' > "$qa"
foreign_link
drep="$(KEMPT_RPM_QA_CMD="cat $qa" "$KEMPT" doctor 2>&1 || true)"
assert_contains "$drep" "WARN  another updater has prepared the next restart" "doctor warns about a foreign link"
assert_not_contains "$drep" "info  another updater has prepared the next restart" "...and no longer as a note"
drep="$(KEMPT_OFFLINE_TOML="$TESTTMP/no-such.toml" KEMPT_RPM_QA_CMD="cat $qa" "$KEMPT" doctor 2>&1 || true)"
assert_contains "$drep" "WARN  another updater has prepared the next restart: " "...with nothing of dnf5's stored as well"
rm -f "$LINK"; : > "$LINK"
drep="$(KEMPT_RPM_QA_CMD="cat $qa" "$KEMPT" doctor 2>&1 || true)"
assert_contains "$drep" "WARN  another updater has prepared the next restart" "...and about a plain file"
assert_contains "$drep" "is not dnf5's" "...which points nowhere, and it says so"
assert_not_contains "$drep" "is gone" "...and is not called gone"
no_link

# --- Discover's setting ---------------------------------------------------------------------------
ENTRY=org.kde.discover.notifier.desktop
SYS="$TESTTMP/xdg-autostart"; mkdir -p "$SYS"; export KEMPT_XDG_AUTOSTART_DIR="$SYS"
printf '[Desktop Entry]\nType=Application\nName=Discover Notifier\nExec=/usr/bin/DiscoverNotifier\n' > "$SYS/$ENTRY"
CONF="$TESTTMP/discover-updates"; export KEMPT_DISCOVER_UPDATES_CONF="$CONF"
printf '[Global]\nUseUnattendedUpdates=true\n' > "$CONF"
KEY="$KEMPT_STATE_DIR/discover-unattended-answered"
check_state() { "$KEMPT" check >/dev/null 2>&1; }
check_state
assert_eq "$(state .discover_unattended)" "true" "the setting on, the state says so"
assert_eq "$(state .discover_unattended_warn)" "true" "...and the warning is owed"
"$KEMPT" config set surface offline
check_state
assert_eq "$(state .discover_unattended_warn)" "true" "...whatever mode Kempt runs in"
"$KEMPT" config set surface popup 2>/dev/null || true
"$KEMPT" discover-notifier keep >/dev/null
check_state
assert_eq "$(state .discover_unattended_warn)" "true" "...and whether or not the earlier offer was answered"
"$KEMPT" discover-notifier seen
assert_exit 0 "seen marks the warning drawn" -- test -e "$KEY"
assert_eq "$(state '.discover_unattended_warn // "absent"')" "absent" "...and takes it out of the state at once, before the next check"
check_state
assert_eq "$(state '.discover_unattended_warn // "absent"')" "absent" "...so it is owed no longer"
assert_eq "$(state .discover_unattended)" "true" "...while the setting is still reported"
printf '[Global]\nUseUnattendedUpdates=false\n' > "$CONF"
check_state
assert_exit 0 "a setting read as false forgets the warning" -- test ! -e "$KEY"
assert_eq "$(state .discover_unattended)" "false" "...and the state says it is off"
printf '[Global]\nUseUnattendedUpdates=true\n' > "$CONF"
check_state
assert_eq "$(state .discover_unattended_warn)" "true" "...so turning it on warns again"
"$KEMPT" discover-notifier seen
out="$("$KEMPT" discover-notifier off)"
assert_exit 0 "off leaves KDE's setting alone" -- grep -q 'UseUnattendedUpdates=true' "$CONF"
assert_not_contains "$out" "automatic updates" "...and says nothing about it"
check_state
assert_eq "$(state .discover_unattended)" "false" "with the notifier off, nothing acts on the setting"
assert_eq "$("$KEMPT" discover-notifier status --json | jq -r .unattended)" "true" "...and status still shows the setting"
assert_contains "$("$KEMPT" discover-notifier status)" "automatic updates: on" "...in words too"
out="$("$KEMPT" discover-notifier on)"
assert_contains "$out" "automatic updates resume" "on says they resume with the setting still on"
assert_exit 0 "...and on forgets the warning was drawn" -- test ! -e "$KEY"
printf '[Global]\nUseUnattendedUpdates=false\n' > "$CONF"
"$KEMPT" discover-notifier off >/dev/null
out="$("$KEMPT" discover-notifier on)"
assert_not_contains "$out" "automatic updates" "...and says nothing with the setting off"
# An image-based Fedora: Kempt tells people to use Discover there, so neither is offered.
printf '[Global]\nUseUnattendedUpdates=true\n' > "$CONF"
rm -f "$KEY" "$KEMPT_STATE_DIR/discover-offer-answered"
check_state
assert_eq "$(state .discover_unattended_warn)" "true" "(with the setting on, the warning is owed)"
KEMPT_OSTREE_MARKER="$TESTTMP/ostree-booted"; export KEMPT_OSTREE_MARKER; : > "$KEMPT_OSTREE_MARKER"
check_state
assert_eq "$(state '.discover_unattended_warn // "absent"')" "absent" "an image-based Fedora is not warned"
assert_eq "$(state '.discover_offer // "absent"')" "absent" "...nor offered the notifier's off"
rm -f "$KEMPT_OSTREE_MARKER"; unset KEMPT_OSTREE_MARKER

finish
