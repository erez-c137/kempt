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
assert_contains "$("$KEMPT" status 2>&1 || true)" "The next restart belongs to another updater" "...and status has a line saying so"
no_link

# --- kempt update to a restart -----------------------------------------------------------------
gate_refuses() {  # label, then the environment and arguments
  local label="$1" rc=0 err; shift
  : > "$WORLD/calls"; : > "$WORLD/notifications"
  local hist_before; hist_before="$(ls "$KEMPT_STATE_DIR/history" 2>/dev/null | wc -l)"
  err="$(env "$@" 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "5" "$label: refused with the code for this condition"
  assert_eq "$(cat "$WORLD/calls")" "" "$label: no download and no Flatpak"
  assert_contains "$err" "the next restart belongs to another updater" "$label: says why"
  assert_eq "$(ls "$KEMPT_STATE_DIR/history" 2>/dev/null | wc -l)" "$hist_before" "$label: nothing recorded as a run"
}
foreign_link
gate_refuses "a foreign link" "$KEMPT" update --surface=offline
assert_contains "$(cat "$WORLD/notifications")" "the next restart belongs to another updater" "...and the notification says so"
assert_not_contains "$(cat "$WORLD/notifications")" "install on" "...and promises nothing"
rm -f "$LINK"; ln -s "$TESTTMP/no/such/target" "$LINK"
gate_refuses "a dangling link" "$KEMPT" update --surface=offline
rm -f "$LINK"; : > "$LINK"
gate_refuses "a plain file" "$KEMPT" update --surface=offline

foreign_link
"$KEMPT" config set surface offline
gate_refuses "the configured surface" "$KEMPT" update
"$KEMPT" config set auto_accept false
gate_refuses "a run with no terminal and auto_accept off" "$KEMPT" update --surface=offline </dev/null
gate_refuses "...and the same from the configured surface" "$KEMPT" update </dev/null
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

# Live stays open: that is the choice the widget offers, and the way the refusal names.
: > "$WORLD/calls"; rc=0
"$KEMPT" update --surface=popup >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "a live run behind a foreign link is not refused"
assert_contains "$(cat "$WORLD/calls")" "APPLY dnf-upgrade" "...and upgrades"

# No foreign link: the gate does not get in the way.
no_link
: > "$WORLD/calls"; rc=0
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "with nobody holding the restart the stage goes ahead"
assert_contains "$(cat "$WORLD/calls")" "APPLY dnf-offline-stage" "...and reaches dnf5"
rm -f "$KEMPT_STATE_DIR/offline_staged.json" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv

# --- the risky prompt --------------------------------------------------------------------------
export KEMPT_RISKY_RE='^bash$'
foreign_link
: > "$WORLD/calls"; : > "$WORLD/notifications"
sout="$(KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=terminal <<<"s" 2>&1)" || true
assert_contains "$sout" "Staging is not available: the next restart belongs to another updater" "the risky prompt drops staging"
assert_not_contains "$sout" "[s]" "...and does not offer the key"
assert_eq "$(grep -c 'APPLY dnf-offline-stage' "$WORLD/calls" || true)" "0" "...and answering s anyway never stages"
assert_contains "$sout" "Staging is not available, because the next restart belongs to another updater. Answer u or a." "...and is turned down in words"
assert_contains "$sout" "aborted" "...and the end of input ends the run"
: > "$WORLD/notifications"
KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=popup </dev/null >/dev/null 2>&1 || true
assert_not_contains "$(cat "$WORLD/notifications")" "--surface=offline" "...and the notification gives no advice to stage"
no_link
: > "$WORLD/calls"
sout="$(KEMPT_ASSUME_TTY=1 "$KEMPT" update --surface=terminal <<<"s" 2>&1)" || true
assert_contains "$(cat "$WORLD/calls")" "APPLY dnf-offline-stage" "with nobody holding the restart the same answer stages"
rm -f "$KEMPT_STATE_DIR/offline_staged.json" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
unset KEMPT_RISKY_RE

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

finish
