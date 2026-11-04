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
# The write a run makes once its stage is armed, with no check behind it yet.
jq -c '.restart_holder = "none"' "$KEMPT_STATE_DIR/state.json" > "$TESTTMP/s.json" && cp "$TESTTMP/s.json" "$KEMPT_STATE_DIR/state.json"
bash -c 'source "$1/lib/common.sh"; publish_staged_state_write "" ""' _ "$REPO_ROOT"
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
# The widget's consent is to a live run, so it does not turn a stage asked for into one.
gate_refuses "a stage asked for with the flag and auto_accept off" "$KEMPT" update --surface=offline --risky-ok </dev/null
# ...where a terminal must not turn the stage asked for into a live run.
: > "$WORLD/calls"; rc=0
python3 -c 'import pty, sys; sys.exit(pty.spawn(sys.argv[1:]) >> 8)' "$KEMPT" update --surface=offline >/dev/null 2>&1 </dev/null || rc=$?
assert_eq "$rc" "5" "a stage asked for at a terminal with auto_accept off is refused"
assert_eq "$(cat "$WORLD/calls")" "" "...and changes nothing"
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

# Live with nobody asked: the widget's last read may have said Flatpak alone, and this check found more.
gate_refuses "a live run nobody was asked about" "$KEMPT" update --surface=popup
gate_refuses "...and one with no terminal" "$KEMPT" update --surface=terminal </dev/null
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
  assert_not_contains "$_err" "--surface=terminal" "$_args: offers no run the helper would refuse"
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
python3 -c 'import pty, sys; sys.exit(pty.spawn(sys.argv[1:]) >> 8)' "$KEMPT" update --surface=terminal >/dev/null 2>&1 </dev/null || rc=$?
assert_eq "$rc" "0" "a terminal is not refused"
assert_contains "$(cat "$WORLD/calls")" "APPLY dnf-upgrade" "...and upgrades"
# A terminal on one side only cannot show and ask.
: > "$WORLD/calls"; rc=0
python3 -c 'import pty, sys; sys.exit(pty.spawn(sys.argv[1:]) >> 8)' bash -c '"$0" update --surface=terminal </dev/null' "$KEMPT" >/dev/null 2>&1 </dev/null || rc=$?
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
assert_contains "$drep" "what is left of a staged update that was only partly installed" "doctor explains the leftover"
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
assert_not_contains "$drep" "only partly installed" "...and a later stage retires the row"
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

# A package below where it was installed nothing of the stage, however close to the staged version.
staged_marker "$NAMES"
moved $'librepo\t1.10.0-1.fc44'
qa_from_after; harvest
assert_contains "$(cat "$WORLD/notifications")" "can no longer install" "a pure downgrade is not an install"
assert_eq "$(entries)" "0" "...with no history"
rm -f "$marker" "$pre"
# An epoch counts as newer whatever the version, and a row with none has epoch 0.
staged_marker "$NAMES"
moved $'librepo\t1:1.10.0-1.fc44'
qa_from_after; harvest
assert_eq "$(cat "$WORLD/notifications")" "NOTIFY Kempt 1 of your staged updates was installed outside Kempt." "a newer epoch counts"
rm -f "$KEMPT_STATE_DIR/offline-partial"
# A name the stage would only remove says nothing about the stage if it moved...
staged_marker "$NAMES"
moved $'bash-color-prompt\t0.9-1.fc44'
qa_from_after; harvest
assert_contains "$(cat "$WORLD/notifications")" "can no longer install" "upgrading a package the stage would remove is not an install"
rm -f "$marker" "$pre"
# ...but a name it also installs does, as a kernel does.
cp "$tx" "$tx.keep"
jq '.rpms += [{"nevra":"librepo-1.19.0-1.fc44.x86_64","action":"Remove","reason":"User","repo_id":"@System"}]' "$tx.keep" > "$tx"
staged_marker "$NAMES"
moved $'librepo\t1.21.0-1.fc44'
qa_from_after; harvest
assert_eq "$(cat "$WORLD/notifications")" "NOTIFY Kempt 1 of your staged updates was installed outside Kempt." "a name removed and installed counts"
mv "$tx.keep" "$tx"; rm -f "$KEMPT_STATE_DIR/offline-partial"

# Told it can no longer install, then a later boot finds some of it there: no second story.
staged_marker "$NAMES"
cp "$pre" "$after_tsv"; qa_from_after; : > "$WORLD/notifications"
KEMPT_RPM_QA_CMD="cat $qa" KEMPT_DNF_INSTALLED_CMD="cat $after_tsv" KEMPT_BOOT_ID=boot-before "$KEMPT" check >/dev/null 2>&1 || true
assert_contains "$(cat "$WORLD/notifications")" "can no longer install" "lost in the same boot: said once"
assert_eq "$(jq -r .lost_announced "$marker")" "true" "...and recorded as said"
moved $'aardvark-dns\t2:1.18.0-1.fc44'; qa_from_after; harvest
assert_eq "$(cat "$WORLD/notifications")" "" "the next boot's partial install says nothing more"
assert_eq "$(entries)" "0" "...with no history"
assert_exit 0 "...and the marker goes" -- test ! -f "$marker"
assert_exit 0 "...with its snapshot" -- test ! -f "$pre"
assert_exit 0 "...and doctor can still explain what dnf5 keeps" -- test -s "$KEMPT_STATE_DIR/offline-partial"
assert_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "after it was announced as lost" "...and the log keeps what happened"
rm -f "$KEMPT_STATE_DIR/offline-partial"
# A demotion nobody was told about still reports.
staged_marker "$NAMES"
jq -c '. + {armed: false}' "$marker" > "$marker.t"; mv "$marker.t" "$marker"
moved $'aardvark-dns\t2:1.18.0-1.fc44'; qa_from_after; harvest
assert_eq "$(cat "$WORLD/notifications")" "NOTIFY Kempt 1 of your staged updates was installed outside Kempt." "a quiet demotion still reports what arrived"
rm -f "$KEMPT_STATE_DIR/offline-partial"

# None with the next restart held: the advice cannot be a stage, which would be refused.
staged_marker "$NAMES"
moved $'zzz-unrelated\t1.0-1.fc44'
qa_from_after; foreign_link; harvest
assert_contains "$(cat "$WORLD/notifications")" "The next restart belongs to another updater" "held: says whose restart it is"
assert_not_contains "$(cat "$WORLD/notifications")" "--surface=offline" "...and does not advise a stage"
assert_not_contains "$(cat "$WORLD/notifications")" "dnf5 offline clean" "...nor a clean that would cancel that updater's"
no_link; rm -f "$marker" "$pre"

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

# The count said to the person is never more than the count Kempt gave when it staged, and new
# dependencies are not part of that count.
newdep_marker() { jq -c --arg n zz-new-dep '.staged_names += [$n]' "$marker" > "$marker.t"; mv "$marker.t" "$marker"; }
staged_marker "$NAMES"; newdep_marker
moved $'aardvark-dns\t2:1.18.0-1.fc44' $'zz-new-dep\t1.0-1.fc44'; qa_from_after; harvest
assert_eq "$(cat "$WORLD/notifications")" "NOTIFY Kempt 1 of your staged updates was installed outside Kempt." "a new dependency does not raise the count"
assert_eq "$(entry '.backends.dnf.added | length')" "1" "...and history still records it"
rm -f "$marker" "$pre"
staged_marker "$NAMES"; jq -c '.staged = 1' "$marker" > "$marker.t"; mv "$marker.t" "$marker"
moved $'librepo\t1.20.9-1.fc44' $'aardvark-dns\t2:1.18.0-1.fc44'; qa_from_after; harvest
assert_eq "$(cat "$WORLD/notifications")" "NOTIFY Kempt 1 of your staged updates was installed outside Kempt." "the count stops at what was staged"
rm -f "$marker" "$pre"
staged_marker "$NAMES"; jq -c 'del(.staged)' "$marker" > "$marker.t"; mv "$marker.t" "$marker"
moved $'librepo\t1.20.9-1.fc44' $'aardvark-dns\t2:1.18.0-1.fc44'; qa_from_after; harvest
assert_eq "$(cat "$WORLD/notifications")" "NOTIFY Kempt 2 of your staged updates were installed outside Kempt." "...and a marker with no count still gives one"
rm -f "$marker" "$pre"
staged_marker "$NAMES"; newdep_marker
moved $'zz-new-dep\t1.0-1.fc44'; qa_from_after; harvest
assert_eq "$(cat "$WORLD/notifications")" "NOTIFY Kempt Part of your staged update was installed outside Kempt." "only a new dependency: no count of zero"
rm -f "$marker" "$pre"

# A transaction dnf5 left incomplete. A package's script failed part way through a restart, and the
# packages before it are installed.
sed 's/^status *=.*/status = "transaction-incomplete"/' "$FIXTURES/offline-ready.toml" > "$TESTTMP/incomplete.toml"
staged_marker "$NAMES"; moved $'aardvark-dns\t2:1.18.0-1.fc44' $'librepo\t1.20.9-1.fc44'; qa_from_after
KEMPT_OFFLINE_TOML="$TESTTMP/incomplete.toml" harvest
assert_eq "$(cat "$WORLD/notifications")" "NOTIFY Kempt 2 of your staged updates were installed, but the install did not finish on the restart. Kempt's update list shows what is still waiting." \
  "some of an unfinished restart: says how many, and where the rest is"
assert_eq "$(entries)" "1" "...with one history entry"
assert_eq "$(entry .surface)" "offline (restart did not finish)" "...which says what happened"
assert_eq "$(entry .status)" "failed" "...as a failed run"
assert_eq "$(entry .backends.dnf.status)" "failed" "...on the system half"
assert_eq "$(entry .error)" "the install did not finish on the restart" "...with the reason"
assert_eq "$(entry '[.backends.dnf.updated[] | "\(.name) \(.to)"] | join(", ")')" "aardvark-dns 2:1.18.0-1.fc44, librepo 1.20.9-1.fc44" \
  "...and the real versions"
assert_contains "$("$KEMPT" history | awk 'NR==1')" "staged update (restart did not finish)" "...and history reads in words"
assert_contains "$(cat "$(entry .log)")" "dnf5 stopped before the end of the install during the restart" "...and so does its log"
assert_contains "$(grep -c 'offline stage partly installed on a restart that did not finish' "$KEMPT_STATE_DIR/events.log")" "1" "...and one event records it"
assert_exit 0 "...and the marker goes" -- test ! -f "$marker"
drep="$(KEMPT_OFFLINE_TOML="$TESTTMP/incomplete.toml" KEMPT_RPM_QA_CMD="cat $qa" "$KEMPT" doctor 2>&1 || true)"
assert_contains "$drep" "only partly installed" "...and doctor explains the leftover"
assert_not_contains "$drep" "partly installed outside Kempt" "...without saying it happened outside Kempt"
assert_not_contains "$drep" "never set to install" "...nor that it was never set to install"
rm -f "$KEMPT_STATE_DIR/offline-partial"

# Told about, once, and the next check is quiet.
staged_marker "$NAMES"; moved $'aardvark-dns\t2:1.18.0-1.fc44'; qa_from_after
KEMPT_OFFLINE_TOML="$TESTTMP/incomplete.toml" harvest
assert_eq "$(cat "$WORLD/notifications")" "NOTIFY Kempt 1 of your staged updates was installed, but the install did not finish on the restart. Kempt's update list shows what is still waiting." \
  "one of an unfinished restart: in the singular"
KEMPT_OFFLINE_TOML="$TESTTMP/incomplete.toml" harvest
assert_eq "$(cat "$WORLD/notifications")" "" "...and only once"
rm -f "$KEMPT_STATE_DIR/offline-partial"

# ...and the count holds here too.
staged_marker "$NAMES"; newdep_marker
moved $'aardvark-dns\t2:1.18.0-1.fc44' $'zz-new-dep\t1.0-1.fc44'; qa_from_after
KEMPT_OFFLINE_TOML="$TESTTMP/incomplete.toml" harvest
assert_contains "$(cat "$WORLD/notifications")" "1 of your staged updates was installed, but" "an unfinished restart does not count a new dependency either"
rm -f "$KEMPT_STATE_DIR/offline-partial"

# A restart that installed nothing is a failed run. `kempt status` read the staging run as the last
# update, and said "staged" after the restart had shown that it was not.
staging_entry() {  # the run that made this stage, as the last thing history knows
  mkdir -p "$KEMPT_STATE_DIR/history"
  jq -n --arg ts "$(date -Iseconds -d '-1 hour')" \
    '{timestamp:$ts, surface:"offline", status:"ok", reboot_needed:false, log:"",
      backends:{dnf:{updated:[],added:[],removed:[],status:"ok",skipped_held:[]},
                flatpak:{updated:[],added:[],removed:[],status:"skipped",skipped_held:[]}}}' \
    > "$KEMPT_STATE_DIR/history/20200101T000000.json"
}
harvest_keeping_history() {
  : > "$WORLD/notifications"
  KEMPT_RPM_QA_CMD="${QA_CMD:-cat $qa}" KEMPT_DNF_INSTALLED_CMD="cat $after_tsv" KEMPT_BOOT_ID=boot-after \
    "$KEMPT" check >/dev/null 2>&1 || true
}
last_run_line() { "$KEMPT" status 2>&1 | grep '^Last update' || true; }
rm -rf "$KEMPT_STATE_DIR/history"
staging_entry
assert_contains "$(last_run_line)" "staged" "premise: before the restart, status says the update is staged"

staged_marker "$NAMES"; cp "$pre" "$after_tsv"; qa_from_after
export KEMPT_OFFLINE_TOML="$TESTTMP/incomplete.toml"
harvest_keeping_history
assert_eq "$(entries)" "2" "a restart that stopped and installed nothing: a history entry"
assert_eq "$(entry .status)" "failed" "...a failed one"
assert_eq "$(entry .error)" "the restart installed none of the staged update" "...saying so"
assert_eq "$(entry .surface)" "offline (restart did not finish)" "...and how"
assert_eq "$(entry '.backends.dnf.updated | length')" "0" "...with nothing listed as installed"
assert_contains "$(last_run_line)" "failed" "status reads it as failed"
assert_not_contains "$(last_run_line)" "staged" "...and stops saying staged"
harvest_keeping_history
harvest_keeping_history
assert_eq "$(entries)" "2" "...and it is one entry, however many checks follow"
rm -f "$marker"; export KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml"

# The same with the restart marker gone: dnf5 still says ready, and no restart ran it.
rm -rf "$KEMPT_STATE_DIR/history"; staging_entry
staged_marker "$NAMES"; cp "$pre" "$after_tsv"; qa_from_after
harvest_keeping_history
assert_eq "$(entry .status)" "failed" "a restart that walked past the stage: failed too"
assert_eq "$(entry .surface)" "restart (staged update did not run)" "...in its own words"
assert_not_contains "$(last_run_line)" "staged for" "...and status stops promising it"

# ...and when other packages moved and none of the stage's did.
rm -f "$marker"; rm -rf "$KEMPT_STATE_DIR/history"; staging_entry
staged_marker "$NAMES"
moved $'zzz-unrelated\t1.0-1.fc44'
qa_from_after
harvest_keeping_history
assert_eq "$(entry .status)" "failed" "other packages moved and none of the stage's: failed as well"
assert_eq "$(entry .surface)" "restart (staged update did not run)" "...in the same words"

# A marker already told it cannot install still gets the row, on the box that upgraded to this.
rm -rf "$KEMPT_STATE_DIR/history"; staging_entry
jq -c '. + {armed:false, lost_announced:true}' "$marker" > "$marker.t"; mv "$marker.t" "$marker"
harvest_keeping_history
assert_eq "$(entry .status)" "failed" "an already announced stage: the failed entry still lands"
assert_eq "$(cat "$WORLD/notifications")" "" "...with no second notification"

# Some other run came after the stage: it is the last update, and it is not rewritten as failed.
rm -f "$marker"; rm -rf "$KEMPT_STATE_DIR/history"; staging_entry
jq '.surface = "terminal" | .timestamp = "2026-11-03T10:00:00+02:00"' "$KEMPT_STATE_DIR/history/20200101T000000.json" \
  > "$KEMPT_STATE_DIR/history/20200101T000001.json"
staged_marker "$NAMES"; cp "$pre" "$after_tsv"; qa_from_after
harvest_keeping_history
assert_eq "$(entries)" "2" "a newer run stands as the last update: no entry on top of it"
rm -f "$marker"; rm -rf "$KEMPT_STATE_DIR/history"

# None of it changed, with the set as it was.
staged_marker "$NAMES"; cp "$pre" "$after_tsv"; qa_from_after
KEMPT_OFFLINE_TOML="$TESTTMP/incomplete.toml" harvest
assert_contains "$(cat "$WORLD/notifications")" "Your staged update did not finish installing on the restart, and none of it was installed." "none of an unfinished restart: says so"
assert_not_contains "$(cat "$WORLD/notifications")" "can no longer install" "...and not that it can no longer install"
assert_eq "$(entries)" "0" "...with no history"
assert_contains "$(tail -n 4 "$KEMPT_STATE_DIR/events.log")" "offline stage did not finish on the restart (status transaction-incomplete) - announced" "...and the log agrees"
assert_eq "$(jq -r .lost_announced "$marker")" "true" "...and it is said once"
drep="$(KEMPT_OFFLINE_TOML="$TESTTMP/incomplete.toml" KEMPT_RPM_QA_CMD="cat $qa" "$KEMPT" doctor 2>&1 || true)"
assert_contains "$drep" "FAIL  staged update did not finish: dnf5 started it on a restart and stopped before the end" "...and doctor tells it the same way"
assert_contains "$drep" "sudo dnf5 offline clean" "...with the way to clear it"
assert_not_contains "$drep" "never set to install" "...and not as never set to install"
assert_not_contains "$drep" "can never install" "...nor as unable to"
rm -f "$marker" "$pre"

# None of it, with other things moved.
staged_marker "$NAMES"; moved $'zzz-unrelated\t1.0-1.fc44'
grep -v '^bash-color-prompt'$'\t' "$after_tsv" > "$after_tsv.x"; mv "$after_tsv.x" "$after_tsv"; qa_from_after
KEMPT_OFFLINE_TOML="$TESTTMP/incomplete.toml" harvest
assert_contains "$(cat "$WORLD/notifications")" "did not finish installing on the restart, and none of it was installed" "none of it, whatever else moved"
assert_eq "$(entries)" "0" "...with no history"
rm -f "$marker" "$pre"

# Cannot tell: says it did not finish, with nothing about how much.
staged_marker "$NAMES"; moved $'aardvark-dns\t2:1.18.0-1.fc44'; qa_from_after
jq -c 'del(.staged_names)' "$marker" > "$marker.t"; mv "$marker.t" "$marker"
KEMPT_OFFLINE_TOML="$TESTTMP/incomplete.toml" harvest
assert_contains "$(cat "$WORLD/notifications")" "Your staged update did not finish installing on the restart." "cannot tell how much: says it did not finish"
assert_not_contains "$(cat "$WORLD/notifications")" "none of it" "...and nothing about how much"
assert_not_contains "$(cat "$WORLD/notifications")" "of your staged updates" "...either way"
assert_eq "$(entries)" "0" "...with no history"
rm -f "$marker" "$pre"

# All of it, with dnf5 still calling it incomplete: there is nothing left to say but that.
staged_marker "$NAMES"
moved $'librepo\t1.21.0-1.fc44' $'aardvark-dns\t2:1.18.0-1.fc44' $'7zip\t26.03-1.fc44'
grep -v '^bash-color-prompt'$'\t' "$after_tsv" > "$after_tsv.x"; mv "$after_tsv.x" "$after_tsv"; qa_from_after
KEMPT_OFFLINE_TOML="$TESTTMP/incomplete.toml" harvest
assert_eq "$(cat "$WORLD/notifications")" "NOTIFY Kempt Your staged updates are installed." "all of an unfinished restart: installed, with no count to get wrong"
rm -f "$marker" "$pre"


# --- a user's mount, in the words the helper and doctor use ------------------------------------------
_mfolder="$TESTTMP/users-mount"; mkdir -p "$_mfolder/repo"; chmod 777 "$_mfolder/repo"
_mi="$TESTTMP/mountinfo-users"
{ cat "$KEMPT_MOUNTINFO"; printf '90 1 0:50 / %s rw - fuse.sshfs u@h:/d rw,user_id=1000,group_id=1000\n' "$_mfolder"; } > "$_mi"
KEMPT_MOUNTINFO="$_mi" KEMPT_DNF_CACHE_DIR="$_mfolder" "$KEMPT" check >/dev/null 2>&1 || true
srep="$(KEMPT_MOUNTINFO="$_mi" KEMPT_DNF_CACHE_DIR="$_mfolder" "$KEMPT" status 2>&1 || true)"
assert_contains "$srep" "Updates paused for safety: $_mfolder is on a mount made by a user other than root. Run kempt doctor for the fix." "status names a user's mount"
assert_not_contains "$srep" "other users can change files in $_mfolder" "...and does not call it something else"
drep="$(KEMPT_MOUNTINFO="$_mi" KEMPT_DNF_CACHE_DIR="$_mfolder" "$KEMPT" doctor 2>&1 || true)"
assert_contains "$drep" "is a mount made by" "doctor names it too"
assert_contains "$drep" "FAIL  dnf cache: other users can change files in $_mfolder" "...and still has the cache row"
assert_not_contains "$drep" "Kempt 0.1.7 or earlier" "...which does not blame an old Kempt for a mount"
for _row in KEMPT_DNF_SYSIMAGE_DIR KEMPT_DNF_OFFLINE_PKG_DIR; do
  drep="$(env KEMPT_MOUNTINFO="$_mi" "$_row=$_mfolder" "$KEMPT" doctor 2>&1 || true)"
  assert_not_contains "$drep" "Kempt 0.1.7 or earlier" "...nor does $_row's row"
done
drep="$(KEMPT_DNF_OFFLINE_PKG_DIR="$_mfolder" KEMPT_MOUNTINFO="$_mi" "$KEMPT" doctor 2>&1 || true)"
assert_contains "$drep" "A changed package there installs as root at the next restart" "...and the staged row still says what is at stake"
for _row in KEMPT_DNF_CACHE_DIR KEMPT_DNF_SYSIMAGE_DIR KEMPT_DNF_OFFLINE_PKG_DIR; do
  drep="$(env "$_row=$_mfolder" "$KEMPT" doctor 2>&1 || true)"
  assert_contains "$drep" "Kempt 0.1.7 or earlier may have left them that way" "$_row with no mount: it can be true, so it is said"
done
KEMPT_DNF_CACHE_DIR="$_mfolder" "$KEMPT" check >/dev/null 2>&1 || true
srep="$(KEMPT_DNF_CACHE_DIR="$_mfolder" "$KEMPT" status 2>&1 || true)"
assert_contains "$srep" "Updates paused for safety: other users can change files in $_mfolder. Run kempt doctor for the fix." "...and without one, status says what it always did"
rm -rf "$_mfolder"; "$KEMPT" check >/dev/null 2>&1 || true

# --- the last run, while another updater holds the restart ------------------------------------------
_hd="$KEMPT_STATE_DIR/history"; rm -rf "$_hd"; mkdir -p "$_hd"
jq -n '{timestamp:"2026-11-04T10:00:00+02:00", surface:"offline", status:"ok", staged:256, reboot_needed:false, log:"",
        backends:{dnf:{updated:[],added:[],removed:[],status:"ok"},flatpak:{updated:[],added:[],removed:[],status:"skipped"}}}' > "$_hd/20261104T100000.json"
srep="$("$KEMPT" status 2>&1 || true)"
assert_contains "$srep" "staged 256 updates for a restart" "a stage reads as itself"
foreign_link
srep="$("$KEMPT" status 2>&1 || true)"
assert_contains "$srep" "staged 256 updates, but another updater has since prepared the next restart" "...and held, it says what became of the restart"
assert_not_contains "$srep" "for a restart" "...and not that it is for one"
no_link; rm -rf "$_hd"

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
