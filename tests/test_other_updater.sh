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
cat > "$TESTTMP/refresh-busy" <<STUB
#!/usr/bin/env bash
echo "kempt-refresh: dnf5 was not started, because a Kempt update is running. Nothing changed." >&2
exit 5
STUB
chmod +x "$TESTTMP/refresh-busy"
: > "$WORLD/calls"; busy_rc=0
busy_err="$(KEMPT_REFRESH_HELPER="$TESTTMP/refresh-busy" "$KEMPT" update --surface=offline 2>&1 >/dev/null)" || busy_rc=$?
assert_eq "$busy_rc" "3" "another Kempt update running: the code for that, not a refusal"
assert_eq "$busy_err" "another kempt update is running" "...saying only that"
assert_eq "$(cat "$WORLD/calls")" "" "...and nothing ran"
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

# --- after the restart -------------------------------------------------------------------------
# The stage named three packages. Across the restart some of them moved; dnf5's copy stayed at
# `ready` and no link of dnf5's is left.
export KEMPT_DNF_INSTALLED_CMD="cat $FIXTURES/rpm-installed.tsv"
export KEMPT_DNF_HISTORY_CMD="false"
export KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml"
marker="$KEMPT_STATE_DIR/offline_staged.json"
pre="$KEMPT_STATE_DIR/snapshots/offline-pre-test.tsv"
tx="$TESTTMP/tx.json"
cat > "$tx" <<'JSON'
{"version":"1.0","rpms":[
 {"nevra":"librepo-1.21.0-1.fc44.x86_64","action":"Upgrade","reason":"Dependency","repo_id":"updates"},
 {"nevra":"aardvark-dns-2:1.18.0-1.fc44.x86_64","action":"Upgrade","reason":"User","repo_id":"updates"},
 {"nevra":"7zip-26.03-1.fc44.x86_64","action":"Upgrade","reason":"User","repo_id":"updates"},
 {"nevra":"bash-color-prompt-0.7.1-3.fc44.noarch","action":"Remove","reason":"User","repo_id":"@System"}]}
JSON
export KEMPT_OFFLINE_TXJSON="$tx"
staged_marker() {  # names-json
  mkdir -p "$KEMPT_STATE_DIR/snapshots"
  { cat "$FIXTURES/rpm-installed.tsv"; printf 'librepo\t1.20.0-1.fc44\n'; } | LC_ALL=C sort > "$pre"
  jq -n --arg snap "$pre" --argjson names "$1" \
    '{staged_at:"2026-11-02T10:00:00+02:00", pre_snapshot:$snap, boot_id:"boot-before", staged:($names|length),
      armed:true, staged_names:$names, staged_names_source:"transaction"}' > "$marker"
}
NAMES='["7zip","aardvark-dns","librepo","bash-color-prompt"]'
after_tsv="$TESTTMP/after.tsv"
qa="$TESTTMP/qa"
moved() {  # tsv lines of what is installed now, on top of the snapshot
  local name
  { cat "$pre"; } > "$after_tsv.tmp"
  while (( $# )); do
    name="${1%%$'\t'*}"
    grep -v "^$name"$'\t' "$after_tsv.tmp" > "$after_tsv.t2" || true
    printf '%s\n' "$1" >> "$after_tsv.t2"
    mv "$after_tsv.t2" "$after_tsv.tmp"; shift
  done
  LC_ALL=C sort "$after_tsv.tmp" > "$after_tsv"; rm -f "$after_tsv.tmp"
}
qa_from_after() { awk -F'\t' '{ v=$2; if (v !~ /:/) v="0:" v; print $1 "-" v ".x86_64" }' "$after_tsv" > "$qa"; }
harvest() { : > "$WORLD/notifications"; rm -rf "$KEMPT_STATE_DIR/history"
  KEMPT_RPM_QA_CMD="${QA_CMD:-cat $qa}" KEMPT_DNF_INSTALLED_CMD="cat $after_tsv" KEMPT_BOOT_ID=boot-after \
    "$KEMPT" check >/dev/null 2>&1 || true; }
entries() { ls -1 "$KEMPT_STATE_DIR"/history/*.json 2>/dev/null | wc -l; }
entry() { jq -r "$1" "$(ls -1 "$KEMPT_STATE_DIR"/history/*.json | tail -1)"; }
no_link

# All: every staged package at its staged version or newer.
staged_marker "$NAMES"
moved $'librepo\t1.21.0-1.fc44' $'aardvark-dns\t2:1.18.0-1.fc44' $'7zip\t26.03-1.fc44'
grep -v '^bash-color-prompt'$'\t' "$after_tsv" > "$after_tsv.x"; mv "$after_tsv.x" "$after_tsv"
qa_from_after; harvest
assert_eq "$(cat "$WORLD/notifications")" "NOTIFY Kempt Your staged updates are installed." "all of it: as before"
assert_eq "$(entry .surface)" "offline (installed by another updater)" "...with its history entry"
assert_exit 0 "...and the marker goes" -- test ! -f "$marker"

# Some, plural, one of them at a version lower than the one staged, and a Remove entry that went.
staged_marker "$NAMES"
moved $'librepo\t1.20.9-1.fc44' $'aardvark-dns\t2:1.18.0-1.fc44' $'zzz-unrelated\t1.0-1.fc44' $'vim-minimal\t2:9.3.0-1.fc44'
grep -v '^bash-color-prompt'$'\t' "$after_tsv" > "$after_tsv.x"; mv "$after_tsv.x" "$after_tsv"
qa_from_after; harvest
assert_eq "$(cat "$WORLD/notifications")" "NOTIFY Kempt 2 of your staged updates were installed outside Kempt." \
  "some of it: counted, a lower version included, a removal and unrelated packages not"
assert_eq "$(entries)" "1" "...with a history entry"
assert_eq "$(entry .surface)" "offline (partly installed outside Kempt)" "...saying how it arrived"
assert_eq "$(entry '[.backends.dnf.updated[] | "\(.name) \(.to)"] | join(", ")')" "aardvark-dns 2:1.18.0-1.fc44, librepo 1.20.9-1.fc44" \
  "...with the real versions, not the staged ones"
assert_eq "$(entry '.backends.dnf.removed | length')" "0" "...and no removal"
assert_exit 0 "...and the marker goes" -- test ! -f "$marker"
assert_exit 0 "...with its snapshot" -- test ! -f "$pre"
assert_eq "$(jq -r '.offline_staged // "absent"' "$KEMPT_STATE_DIR/state.json")" "absent" "...and nothing is published as staged"
assert_contains "$("$KEMPT" history | awk 'NR==1')" "staged update (partly installed outside Kempt)" "...and history reads in words"
assert_contains "$(grep -c 'offline stage partly installed outside Kempt' "$KEMPT_STATE_DIR/events.log")" "1" "...and one event records it"

# Doctor over what is left. Reads with the same dnf5 files, so the row is about this copy.
drep="$(KEMPT_RPM_QA_CMD="cat $qa" "$KEMPT" doctor 2>&1 || true)"
assert_contains "$drep" "partly installed outside Kempt" "doctor explains the leftover"
assert_contains "$drep" "To remove it, run: kempt unstage" "...naming unstage"
assert_contains "$drep" "A later stage replaces it" "...and that a later stage replaces it"
assert_not_contains "$drep" "staged outside Kempt" "...and not as somebody else's"
assert_not_contains "$drep" "sudo dnf5 offline clean" "...and not with dnf5's own command"
assert_not_contains "$drep" "can never install" "...and with no failure beside it"
ln -s /x "$LINK"
drep="$(KEMPT_RPM_QA_CMD="cat $qa" "$KEMPT" doctor 2>&1 || true)"
assert_contains "$drep" "restart first, then run: kempt unstage" "...and with the restart held, unstage has to wait, so it says so"
no_link
cp "$FIXTURES/offline-ready.toml" "$TESTTMP/later.toml"; echo '# later' >> "$TESTTMP/later.toml"
drep="$(KEMPT_OFFLINE_TOML="$TESTTMP/later.toml" KEMPT_RPM_QA_CMD="cat $qa" "$KEMPT" doctor 2>&1 || true)"
assert_not_contains "$drep" "partly installed outside Kempt" "...and a later stage retires the row"
KEMPT_OFFLINE_TOML="$TESTTMP/later.toml" KEMPT_RPM_QA_CMD="cat $qa" KEMPT_DNF_INSTALLED_CMD="cat $after_tsv" "$KEMPT" check >/dev/null 2>&1 || true
staged_marker "$NAMES"
: > "$WORLD/notifications"
KEMPT_OFFLINE_TOML="$TESTTMP/later.toml" KEMPT_RPM_QA_CMD="cat $qa" KEMPT_DNF_INSTALLED_CMD="cat $pre" KEMPT_BOOT_ID=boot-before "$KEMPT" check >/dev/null 2>&1 || true
assert_exit 0 "...and the next harvest clears its note" -- test ! -e "$KEMPT_STATE_DIR/offline-partial"
rm -f "$marker" "$pre"

# Some, singular.
staged_marker "$NAMES"
moved $'aardvark-dns\t2:1.18.0-1.fc44'
qa_from_after; harvest
assert_eq "$(cat "$WORLD/notifications")" "NOTIFY Kempt 1 of your staged updates was installed outside Kempt." "one of them reads in the singular"
rm -f "$KEMPT_STATE_DIR/offline-partial"

# A staged Remove still installed: every upgrade arrived, and that is still not all of it.
staged_marker "$NAMES"
moved $'librepo\t1.21.0-1.fc44' $'aardvark-dns\t2:1.18.0-1.fc44' $'7zip\t26.03-1.fc44'
qa_from_after; echo 'bash-color-prompt-0:0.7.1-3.fc44.noarch' >> "$qa"; harvest
assert_eq "$(cat "$WORLD/notifications")" "NOTIFY Kempt 3 of your staged updates were installed outside Kempt." \
  "a staged removal still there: not all of it, and the removal not counted"
rm -f "$KEMPT_STATE_DIR/offline-partial"

# None: the set moved, none of it Kempt's.
staged_marker "$NAMES"
moved $'zzz-unrelated\t1.0-1.fc44'
grep -v '^bash-color-prompt'$'\t' "$after_tsv" > "$after_tsv.x"; mv "$after_tsv.x" "$after_tsv"
qa_from_after; harvest
assert_contains "$(cat "$WORLD/notifications")" "can no longer install" "none of it: as before, a removal not counting"
assert_eq "$(entries)" "0" "...with no history"
assert_eq "$(jq -r .armed "$marker")" "false" "...and the marker demoted"
rm -f "$marker" "$pre"

# Cannot tell: nothing false, and the normal list takes over.
cannot_tell() {  # label
  assert_eq "$(cat "$WORLD/notifications")" "" "$1: nothing is said"
  assert_eq "$(entries)" "0" "$1: no history"
  assert_eq "$(jq -r .armed "$marker")" "false" "$1: the promise is withdrawn"
  assert_eq "$(jq -r '.offline_staged // "absent"' "$KEMPT_STATE_DIR/state.json")" "absent" "$1: nothing is published as staged"
  assert_eq "$(jq -r '.actionable > 0' "$KEMPT_STATE_DIR/state.json")" "true" "$1: the normal list is there"
  assert_contains "$(tail -n 8 "$KEMPT_STATE_DIR/events.log")" "offline stage result unknown" "$1: the log says it is unknown"
  rm -f "$marker" "$pre"
}
export KEMPT_SKIP_REFRESH=1
staged_marker "$NAMES"; moved $'aardvark-dns\t2:1.18.0-1.fc44'; qa_from_after
KEMPT_OFFLINE_TXJSON="$TESTTMP/no-such.json" harvest
cannot_tell "dnf5's copy unreadable"
staged_marker "$NAMES"; moved $'aardvark-dns\t2:1.18.0-1.fc44'
QA_CMD=true harvest
cannot_tell "an rpm that lists nothing"
staged_marker "$NAMES"; moved $'aardvark-dns\t2:1.18.0-1.fc44'
QA_CMD=false harvest
cannot_tell "rpm failing"
staged_marker "$NAMES"; moved $'aardvark-dns\t2:1.18.0-1.fc44'; qa_from_after
jq -c '. + {replaced: true}' "$marker" > "$marker.t"; mv "$marker.t" "$marker"
harvest
cannot_tell "a stage replaced outside Kempt"
staged_marker "$NAMES"; moved $'aardvark-dns\t2:1.18.0-1.fc44'; qa_from_after
jq -c 'del(.staged_names)' "$marker" > "$marker.t"; mv "$marker.t" "$marker"
harvest
cannot_tell "a marker that names nothing"

# transaction-incomplete stays the detour, whatever moved.
sed 's/^status *=.*/status = "transaction-incomplete"/' "$FIXTURES/offline-ready.toml" > "$TESTTMP/incomplete.toml"
staged_marker "$NAMES"; moved $'aardvark-dns\t2:1.18.0-1.fc44'; qa_from_after
KEMPT_OFFLINE_TOML="$TESTTMP/incomplete.toml" harvest
assert_contains "$(cat "$WORLD/notifications")" "can no longer install" "a transaction dnf5 left incomplete keeps its own path"
assert_eq "$(entries)" "0" "...with no history"
rm -f "$marker" "$pre"

# --- doctor while another updater holds it -------------------------------------------------------
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

finish
