#!/usr/bin/env bash
# Did everything come back after the update? The baseline every run records, the comparison a
# check makes after a restart or a live run, what it announces, and `kempt startup`.
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
KEMPT="$REPO_ROOT/bin/kempt"

# A systemctl stand-in driven by files: failed-<scope>.json is what `--failed` lists,
# transient-<scope> names the units `show` calls transient, active-<scope> the ones running and
# gone-<scope> the ones systemd no longer knows, success-<scope> the inactive ones whose last run
# succeeded, alias-<scope> holds name=canonical lines, enabled-<scope>.json is the list-unit-files
# answer, down-<scope> makes that scope fail and garbage-<scope> makes it answer nonsense. Every
# call is recorded.
SD="$TESTTMP/sd"; mkdir -p "$SD"
export SD_DIR="$SD"
cat > "$TESTTMP/systemctl-stub" <<'STUB'
#!/usr/bin/env bash
d="$SD_DIR"; scope=system
if [[ "$1" == --user ]]; then scope=user; shift; fi
echo "$scope $*" >> "$d/calls"
[[ -e "$d/down-$scope" ]] && exit 1
[[ -e "$d/garbage-$scope" ]] && { echo 'Id=?? {not json'; exit 0; }
case "$1" in
  --failed) cat "$d/failed-$scope.json" 2>/dev/null || echo '[]' ;;
  --version) echo "systemd 259" ;;
  list-unit-files) cat "$d/enabled-$scope.json" 2>/dev/null || echo '[]' ;;
  show)
    shift
    while [[ "$1" == -p ]]; do shift 2; done
    [[ "$1" == -- ]] && shift
    for u in "$@"; do
      id="$(sed -n "s/^$u=//p" "$d/alias-$scope" 2>/dev/null)"
      desc="$(jq -r --arg u "$u" '.[] | select(.unit == $u) | .description' "$d/failed-$scope.json" 2>/dev/null)"
      t=no; grep -qxF "$u" "$d/transient-$scope" 2>/dev/null && t=yes
      a=inactive l=loaded r=exit-code
      [[ -n "$desc" ]] && a=failed
      grep -qxF "$u" "$d/active-$scope" 2>/dev/null && { a=active; r=success; }
      grep -qxF "$u" "$d/success-$scope" 2>/dev/null && r=success
      grep -qxF "$u" "$d/gone-$scope" 2>/dev/null && l=not-found
      printf 'Id=%s\nDescription=%s\nTransient=%s\nActiveState=%s\nLoadState=%s\nResult=%s\n\n' \
        "${id:-$u}" "${desc:-$u}" "$t" "$a" "$l" "$r"
    done ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TESTTMP/systemctl-stub"
export KEMPT_SYSTEMCTL_CMD="$TESTTMP/systemctl-stub"

# failing <scope> [unit=description ...]: what systemd lists as failed in that scope right now.
failing() {
  local scope="$1" pair out='[]'; shift
  for pair in "$@"; do
    out="$(jq -c --arg u "${pair%%=*}" --arg d "${pair#*=}" \
             '. + [{unit: $u, load: "loaded", active: "failed", sub: "failed", description: $d}]' <<<"$out")"
  done
  printf '%s\n' "$out" > "$SD/failed-$scope.json"
}
failing system; failing user
printf '[{"unit_file":"sshd.service","state":"enabled","preset":"disabled"}]\n' > "$SD/enabled-system.json"
printf '[{"unit_file":"pipewire.socket","state":"enabled","preset":"enabled"}]\n' > "$SD/enabled-user.json"

cat > "$TESTTMP/notify-stub" <<STUB
#!/usr/bin/env bash
printf 'NOTIFY %s | %s\n' "\$1" "\${2:-}" >> "$TESTTMP/notifications"
STUB
chmod +x "$TESTTMP/notify-stub"
export KEMPT_NOTIFY="$TESTTMP/notify-stub"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$TESTTMP/no-bus-needed"
notes() { cat "$TESTTMP/notifications" 2>/dev/null || true; }
note_count() { grep -c . "$TESTTMP/notifications" 2>/dev/null || echo 0; }

# dnf5's history list, for the attribution: its highest id is the newest transaction.
dnf_max() { printf '#!/usr/bin/env bash\necho %s\n' "'[{\"id\":$1,\"command_line\":\"x\"}]'" > "$TESTTMP/dnf-history"
            chmod +x "$TESTTMP/dnf-history"; export KEMPT_DNF_HISTORY_CMD="$TESTTMP/dnf-history"; }

# The rest of the world a check reads, as test_check.sh stubs it.
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export WORLD="$TESTTMP/world"; mkdir -p "$WORLD"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
export KEMPT_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export KEMPT_FLATPAK_LIST_CMD="cat $FIXTURES/flatpak-list.tsv"
export KEMPT_FLATPAK_SNAP_CMD="cat $FIXTURES/flatpak-list.tsv"
export KEMPT_SKIP_REFRESH=1
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"; chmod +x "$TESTTMP/dnf-reboot-no"
export KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no"
# No stage in this world unless a test makes one.
export KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml" KEMPT_OFFLINE_LINK="$TESTTMP/no-system-update"
export KEMPT_BOOT_ID=boot-A

check() { "$KEMPT" check 2>/dev/null; }
startup_state() { jq -c "$1" "$KEMPT_STATE_DIR/startup.json" 2>/dev/null; }
block() { jq -c "${1:-.startup}" "$KEMPT_STATE_DIR/state.json" 2>/dev/null; }
HD="$KEMPT_STATE_DIR/history"

# A history entry as a run writes one: $1 the file stamp, $2 the baseline's boot, $3 the failed
# units at the baseline (records with scope), $4 the transaction id or "", $5 the surface.
entry() {
  mkdir -p "$HD"
  jq -n --arg boot "$2" --argjson failed "$3" --arg tx "$4" --arg surface "${5:-background}" '
    {timestamp: "2026-10-20T10:00:00+03:00", surface: $surface, status: "ok", duration_sec: 3,
     reboot_needed: true, log: "", error: "",
     backends: {dnf: {updated: [{name: "bluez", from: "5.1", to: "5.2"}], added: [], removed: [],
                      status: "ok", skipped_held: []},
                flatpak: {updated: [], added: [], removed: [], status: "skipped", skipped_held: []}},
     failed_before: {boot_id: $boot, at: "2026-10-20T10:00:00+03:00",
                     system: [$failed[] | select(.scope == "system") | {unit, description}],
                     user:   [$failed[] | select(.scope == "user") | {unit, description}]}}
    + (if $tx == "" then {} else {transaction_id: ($tx | tonumber)} end)' > "$HD/$1.json"
}
reset_world() {
  rm -rf "$HD" "$KEMPT_STATE_DIR/startup.json" "$KEMPT_STATE_DIR/startup-mutes" "$TESTTMP/notifications" "$SD/calls"
  rm -f "$SD"/active-* "$SD"/gone-* "$SD"/garbage-* "$SD"/success-* "$SD"/alias-*
  failing system; failing user
  export KEMPT_BOOT_ID=boot-A
}

# --- the query: transient units and run-* leftovers are not services anyone set up ---------------
failing system 'bluetooth.service=Bluetooth service' 'run-u42.service=/usr/bin/true' 'tmp-x.scope=tmp-x.scope'
echo 'tmp-x.scope' > "$SD/transient-system"
assert_json_eq "$(startup_failed system)" '[{"unit":"bluetooth.service","description":"Bluetooth service"}]' \
  "the failed list skips transient units and run-* leftovers, and keeps the description"
jq -c '. + [{unit: "gone.service", load: "not-found", active: "failed", sub: "failed", description: "gone.service"}]' \
  "$SD/failed-system.json" > "$SD/f.json" && mv "$SD/f.json" "$SD/failed-system.json"
assert_eq "$(startup_failed system | jq -r '[.[].unit] | join(",")')" "bluetooth.service" \
  "...and units whose file is gone (not-found), which systemd keeps listing until the next restart"
rm -f "$SD/transient-system"
touch "$SD/down-user"
assert_exit 1 "a scope systemd does not answer for is a failure, not an empty list" -- startup_failed user
rm -f "$SD/down-user"
assert_contains "$(cat "$SD/calls")" "system --failed --output=json" "premise: the stub records the query"

# --- the baseline at run start, on every surface -------------------------------------------------
reset_world
failing system 'cups.service=CUPS Scheduler'
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
case "\$1" in
  dnf-upgrade) [[ -e "$WORLD/no-dnf-change" ]] || cp "$FIXTURES/snap-after.tsv" "$WORLD/rpm.tsv"
               [[ -e "$WORLD/breaks" ]] && cp "$WORLD/breaks" "$SD/failed-system.json" ;;
esac
exit 0
STUB
chmod +x "$TESTTMP/apply-stub"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/fp-update-stub"; chmod +x "$TESTTMP/fp-update-stub"
export KEMPT_APPLY_HELPER="$TESTTMP/apply-stub" KEMPT_FLATPAK_UPDATE_CMD="$TESTTMP/fp-update-stub"
"$KEMPT" update --surface=widget >/dev/null 2>&1 || true
live="$(ls "$HD"/*.json | tail -n 1)"
assert_json_eq "$(jq -c '.failed_before | {boot_id, system, user}' "$live")" \
  '{"boot_id":"boot-A","system":[{"unit":"cups.service","description":"CUPS Scheduler"}],"user":[]}' \
  "a live run records the failed units of both scopes at its start, with the boot"
assert_json_eq "$(jq -c '.failed_before.enabled' "$live")" '{"system":["sshd.service"],"user":["pipewire.socket"]}' \
  "...and the enabled units of both scopes"

# A run whose baseline cannot be read records none, and the entry looks as it did before.
reset_world
touch "$SD/down-system" "$SD/down-user"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
"$KEMPT" update --surface=widget >/dev/null 2>&1 || true
assert_eq "$(jq -c 'has("failed_before")' "$(ls "$HD"/*.json | tail -n 1)")" "false" \
  "with systemctl not answering, the entry has no failed_before"
rm -f "$SD/down-system" "$SD/down-user"

# The stage records it in the marker, the harvest carries it into its entry, and a live run that
# rebases a pending stage hands it its own baseline, as it does the package snapshot.
reset_world
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
export KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" KEMPT_OFFLINE_LINK="$TESTTMP/system-update"
failing system 'cups.service=CUPS Scheduler'
"$KEMPT" update --surface=offline >/dev/null 2>&1 || true
M="$KEMPT_STATE_DIR/offline_staged.json"
assert_json_eq "$(jq -c '.failed_before.system' "$M" 2>/dev/null)" '[{"unit":"cups.service","description":"CUPS Scheduler"}]' \
  "a stage records the baseline in its marker"
failing system 'cups.service=CUPS Scheduler' 'avahi-daemon.service=Avahi mDNS/DNS-SD Stack'
touch "$WORLD/no-dnf-change"
"$KEMPT" update --surface=widget >/dev/null 2>&1 || true
rm -f "$WORLD/no-dnf-change"
assert_eq "$(jq -c '[.failed_before.system[].unit]' "$M" 2>/dev/null)" '["avahi-daemon.service","cups.service"]' \
  "a live run that rebases the pending stage gives it its own baseline"
# The restart installs it: a new boot, the package set moved, dnf5's transaction gone.
cp "$FIXTURES/snap-after.tsv" "$WORLD/rpm.tsv"
export KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml" KEMPT_OFFLINE_LINK="$TESTTMP/no-system-update"
export KEMPT_BOOT_ID=boot-B
check >/dev/null
harvested="$(grep -l '"offline (applied on reboot)"' "$HD"/*.json | tail -n 1)"
assert_eq "$(jq -c '[.failed_before.boot_id, (.failed_before.system | length)]' "$harvested" 2>/dev/null)" '["boot-A",2]' \
  "the harvest carries the marker's baseline into its history entry"

# --- the first check of a new boot -------------------------------------------------------------
reset_world
dnf_max 142
check >/dev/null    # boot-A seen
entry 20261020T100000 boot-A '[{"unit":"cups.service","scope":"system","description":"CUPS Scheduler"}]' 142
export KEMPT_BOOT_ID=boot-B
failing system 'cups.service=CUPS Scheduler' 'bluetooth.service=Bluetooth service' 'run-u7.service=x'
failing user 'plasma-foo.service=Foo helper'
check >/dev/null
assert_json_eq "$(startup_state '[.announced[] | {unit, scope, description}]')" \
  '[{"unit":"bluetooth.service","scope":"system","description":"Bluetooth service"},{"unit":"plasma-foo.service","scope":"user","description":"Foo helper"}]' \
  "after a restart, a unit failing now that was not failing at the run's start is announced"
assert_json_eq "$(startup_state '[.already[].unit]')" '["cups.service"]' "...one failing before the update is already failing, and quiet"
assert_eq "$(note_count)" "1" "...in one notification for the set"
assert_eq "$(notes)" "NOTIFY Kempt | 2 services didn't start after the update: Bluetooth service and Foo helper. To see why, run: kempt startup" \
  "...which counts them, names them and ties them to the update"
assert_eq "$(startup_state '[.boot_id, .baseline.transaction_id, .attribution]')" '["boot-B",142,"update"]' \
  "startup.json records the boot, the baseline's transaction and the attribution"
assert_json_eq "$(block '.startup | {notify, attribution, already, recovered, muted, recovered_digest}')" \
  '{"notify":true,"attribution":"update","already":[{"unit":"cups.service","scope":"system","description":"CUPS Scheduler"}],"recovered":[],"muted":[],"recovered_digest":""}' \
  "state.json carries the startup block"
assert_eq "$(block '[.startup.announced[] | keys] | unique')" '[["description","scope","since","unit"]]' \
  "...each announced entry with unit, scope, description and since"

check >/dev/null
assert_eq "$(note_count)" "1" "a later check in the same boot does not announce the same set again"
assert_eq "$(startup_state '.announced | length')" "2" "...and keeps it announced while it fails"

# One unit: its name in the title, the kind in the body.
reset_world
dnf_max 150
check >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service'
check >/dev/null
assert_eq "$(notes)" "NOTIFY Kempt | Bluetooth service didn't start after the update. It stopped with an error. A system service (bluetooth.service). To see why, run: kempt startup" \
  "one new failure is named, with what kind of service it is"
assert_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "startup failed after the update: bluetooth.service" "...and logged"

# A session unit says so.
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing user 'foo.service=Foo'
check >/dev/null
assert_eq "$(notes)" "NOTIFY Kempt | Foo didn't start after the update. It stopped with an error. A service in your session (foo.service). To see why, run: kempt startup" \
  "a session unit says it is a service in your session"

# A description is outside text: a tab in it must not split the line the note is read from, and
# Plasma reads a notification body as markup.
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing system "odd.service=Odd"$'\t'"<b>tab</b> & co"
check >/dev/null
assert_eq "$(notes)" "NOTIFY Kempt | Odd &lt;b&gt;tab&lt;/b&gt; &amp; co didn't start after the update. It stopped with an error. A system service (odd.service). To see why, run: kempt startup" \
  "a tab becomes a space and markup is escaped, so the whole note arrives as text"
assert_eq "$(startup_state '[.announced[] | select(.unsent)] | length')" "0" "...and nothing is marked unsent"

# Attribution: dnf's history moved on since the run, so Kempt cannot tie it to the update.
reset_world; dnf_max 151; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service'
check >/dev/null
assert_contains "$(notes)" "NOTIFY Kempt | Bluetooth service didn't start after the last restart." \
  "when another transaction ran since Kempt's, it says after the last restart and names no update"
assert_eq "$(block '.startup.attribution')" '"restart"' "...and the block says restart"

# The earliest run since the previous boot is the baseline: a failure the first run caused sits in
# the second run's baseline as already failing.
reset_world; dnf_max 161; check >/dev/null
entry 20261020T110000 boot-A '[]' 160
entry 20261020T120000 boot-A '[{"unit":"bluetooth.service","scope":"system","description":"Bluetooth service"}]' 161
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service'
check >/dev/null
assert_contains "$(notes)" "Bluetooth service didn't start after the update." "the earliest run since the last boot is the baseline"

# No Kempt run since the last boot: nothing compared, nothing said.
reset_world; dnf_max 150; check >/dev/null
entry 20261019T110000 boot-0 '[]' 150
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service'
check >/dev/null
assert_eq "$(note_count)" "0" "with no Kempt run since the last boot, nothing is said"
assert_eq "$(startup_state '.announced | length')" "0" "...and nothing is announced"
assert_eq "$(startup_state '.boot_id')" '"boot-B"' "...but the boot is recorded"

# --- recovery and mutes --------------------------------------------------------------------------
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service' 'cups.service=CUPS Scheduler'
check >/dev/null
assert_exit 0 "kempt startup mute takes a unit" "$KEMPT" startup mute cups.service
assert_eq "$(cat "$KEMPT_STATE_DIR/startup-mutes")" "system:cups.service" "...and records it in the state directory"
assert_eq "$(block '[.startup.announced[].unit]')" '["bluetooth.service"]' "...the state no longer announces it"
assert_eq "$(block '[.startup.muted[] | [.unit, .scope, .description]]')" '[["cups.service","system","CUPS Scheduler"]]' \
  "...and lists it as muted, with its description"
check >/dev/null
assert_eq "$(cat "$KEMPT_STATE_DIR/startup-mutes")" "system:cups.service" "a mute survives later checks"
rm -f "$TESTTMP/notifications"
failing system
printf '%s\n' bluetooth.service cups.service > "$SD/active-system"
check >/dev/null
assert_eq "$(notes)" "NOTIFY Kempt | Bluetooth service is running again. A system service (bluetooth.service)." \
  "a unit Kempt announced that runs again is announced once, and a muted one recovers in silence"
assert_eq "$(block '[.startup.recovered[].unit] | sort')" '["bluetooth.service"]' "...only the unmuted one is listed as recovered"
assert_eq "$([[ -s "$KEMPT_STATE_DIR/startup-mutes" ]] && echo kept || echo cleared)" "cleared" "...and recovery clears its mute"
assert_eq "$(startup_state '.announced | length')" "0" "...and the muted one leaves the announced list"
assert_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "startup recovered: bluetooth.service"$'\n' "...and it is logged"
check >/dev/null
assert_eq "$(note_count)" "1" "...once, not at every check"
digest="$(block '.startup.recovered_digest' | tr -d '"')"
assert_eq "${#digest}" "16" "the recovered set has a 16-character digest"
assert_exit 6 "ack with a digest that is not the current set changes nothing" "$KEMPT" startup ack --expect=0000000000000000
assert_exit 0 "ack with the current digest" "$KEMPT" startup ack --expect="$digest"
assert_eq "$(block '[(.startup.recovered | length), .startup.recovered_digest]')" '[0,""]' "...clears recovered in state.json"
assert_eq "$(startup_state '.recovered | length')" "0" "...and in startup.json"

# A unit muted before it fails is never announced.
reset_world; dnf_max 150; check >/dev/null
"$KEMPT" startup mute foo.service --user >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing user 'foo.service=Foo'
check >/dev/null
assert_eq "$(note_count)" "0" "a muted unit that fails is not announced"
assert_exit 0 "unmute" "$KEMPT" startup unmute foo.service --user
assert_eq "$([[ -s "$KEMPT_STATE_DIR/startup-mutes" ]] && echo kept || echo gone)" "gone" "...removes the mute"
assert_exit 2 "a unit name with a slash is refused" "$KEMPT" startup mute ../etc/passwd
# Muting a unit systemd does not know, or one that is running, would be undone by the next check.
echo nosuch.service > "$SD/gone-system"; echo nosuch.service > "$SD/gone-user"
rc=0; out="$("$KEMPT" startup mute nosuch.service 2>&1)" || rc=$?
assert_eq "$rc" "2" "a unit systemd does not know is refused"
assert_eq "$out" "Kempt does not know a service called nosuch.service." "...with a plain message"
echo mine.service > "$SD/gone-system"
rc=0; out="$("$KEMPT" startup mute mine.service 2>&1)" || rc=$?
assert_eq "$rc" "2" "a unit only your session knows is refused without --user"
assert_eq "$out" "mine.service is a service in your session. To mute it, run: kempt startup mute mine.service --user" \
  "...and the message says how to mute it"
echo running.service > "$SD/active-system"
rc=0; out="$("$KEMPT" startup mute running.service 2>&1)" || rc=$?
assert_eq "$rc" "6" "a running unit is refused as having changed since it was shown"
assert_eq "$out" "running.service is running, so there is nothing to mute." "...with a plain message"
assert_eq "$([[ -s "$KEMPT_STATE_DIR/startup-mutes" ]] && echo kept || echo none)" "none" "...and neither is recorded"
touch "$SD/down-system"
assert_exit 0 "when systemctl does not answer, the mute is kept as typed" "$KEMPT" startup mute running.service
rm -f "$SD/down-system" "$SD/gone-system" "$SD/gone-user" "$SD/active-system"
assert_exit 2 "an unknown startup subcommand is a usage error" "$KEMPT" startup frob

# --- the first good description is kept after the package is removed -----------------------------
# Autostart units are template instances; the suffix is kept apart so no line reads as an address.
AUTOSTART='@autostart.service'
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing user "app-imsettings\\x2dstart$AUTOSTART=Input Method starter"
check >/dev/null
failing user "app-imsettings\\x2dstart$AUTOSTART=app-imsettings\\x2dstart$AUTOSTART"
check >/dev/null
assert_eq "$(block '.startup.announced[0].description')" '"Input Method starter"' \
  "a description seen while the unit was installed is kept once systemd forgets it"

# --- the end of a live run compares too --------------------------------------------------------
reset_world
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
check >/dev/null
jq -n '[{unit: "bluetooth.service", load: "loaded", active: "failed", sub: "failed", description: "Bluetooth service"}]' > "$WORLD/breaks"
"$KEMPT" update --surface=widget >/dev/null 2>&1 || true
rm -f "$WORLD/breaks"
assert_contains "$(notes)" "Bluetooth service didn't start after the" "a live run's closing check announces a unit the run broke"
assert_eq "$(startup_state '[.announced[].unit]')" '["bluetooth.service"]' "...and records it"

# --- the setting, and systemd not being there ------------------------------------------------------
reset_world
"$KEMPT" config set notify_startup false >/dev/null
check >/dev/null
assert_eq "$([[ -e "$SD/calls" ]] && echo asked || echo never)" "never" "with notify_startup off, systemd is never asked"
assert_eq "$(block 'has("startup")')" "false" "...and state.json has no startup block"
"$KEMPT" update --surface=widget >/dev/null 2>&1 || true
assert_eq "$(jq -c 'has("failed_before")' "$(ls "$HD"/*.json | tail -n 1)")" "false" "...and a run records no baseline"
"$KEMPT" config set notify_startup true >/dev/null

reset_world
KEMPT_SYSTEMCTL_CMD="$TESTTMP/UNSTUBBED-systemctl" "$KEMPT" check >/dev/null 2>&1
assert_eq "$(block 'has("startup")')" "false" "with systemctl missing, state.json has no startup block"
out="$(KEMPT_SYSTEMCTL_CMD="$TESTTMP/UNSTUBBED-systemctl" "$KEMPT" doctor 2>&1)" || true
assert_contains "$out" "info  startup: " "...and doctor's startup row is info, not a warning"

# --- a scope that did not answer is compared when it does -------------------------------------
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service'
failing user 'foo.service=Foo'
touch "$SD/down-user"
check >/dev/null
assert_eq "$(startup_state '[.announced[].unit]')" '["bluetooth.service"]' "the first check of a boot compares the scope that answered"
rm -f "$SD/down-user"
check >/dev/null
assert_eq "$(startup_state '[.announced[].unit] | sort')" '["bluetooth.service","foo.service"]' \
  "...and a later check of the same boot compares the one that did not"
assert_contains "$(notes)" "Foo didn't start after the update." "...and announces what it finds"
check >/dev/null
assert_eq "$(note_count)" "2" "...once"

# --- a state that cannot be written announces nothing, and so repeats nothing --------------------
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service'
chmod 555 "$KEMPT_STATE_DIR"
check >/dev/null 2>&1 || true; check >/dev/null 2>&1 || true
chmod 755 "$KEMPT_STATE_DIR"
assert_eq "$(note_count)" "0" "with startup.json unwritable, nothing is announced, check after check"
check >/dev/null
assert_eq "$(note_count)" "1" "...and once it can be written, the set is announced once"

# --- no session bus: the announcement waits for a check that has one ----------------------------
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service'
env -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="$TESTTMP/no-runtime" "$KEMPT" check >/dev/null 2>&1
assert_eq "$(note_count)" "0" "a check with no session bus announces nothing"
check >/dev/null
assert_eq "$(note_count)" "1" "...and the next check with one announces it"
check >/dev/null
assert_eq "$(note_count)" "1" "...once"

# --- running again means running ----------------------------------------------------------------
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service'
check >/dev/null
"$KEMPT" startup mute bluetooth.service >/dev/null
failing system
check >/dev/null
assert_eq "$(note_count)" "1" "a unit that is no longer failing but not running is not announced as running again"
assert_eq "$(startup_state '[.announced[].unit]')" '["bluetooth.service"]' "...stays announced"
assert_eq "$(cat "$KEMPT_STATE_DIR/startup-mutes")" "system:bluetooth.service" "...and keeps its mute"
echo bluetooth.service > "$SD/gone-system"
check >/dev/null
assert_eq "$(note_count)" "1" "a unit systemd no longer knows is dropped without a word"
assert_eq "$(startup_state '.announced | length')" "0" "...from the announced list"
assert_eq "$(startup_state '.recovered | length')" "0" "...and is not listed as running again"
# Removed with its package after it failed: systemd still lists it as failed, but not-found, until
# the next restart. Nothing is left to fix, so it is dropped the same way.
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service'
check >/dev/null
assert_eq "$(startup_state '[.announced[].unit]')" '["bluetooth.service"]' "premise: the failure is announced"
jq -c '.[0].load = "not-found"' "$SD/failed-system.json" > "$SD/f.json" && mv "$SD/f.json" "$SD/failed-system.json"
echo bluetooth.service > "$SD/gone-system"
check >/dev/null
assert_eq "$(startup_state '.announced | length')" "0" "a failed unit whose file is gone leaves the announced list"
assert_eq "$(startup_state '.recovered | length')" "0" "...without being called running again"
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service'
check >/dev/null
failing system
echo bluetooth.service > "$SD/active-system"
check >/dev/null
assert_contains "$(notes)" "NOTIFY Kempt | Bluetooth service is running again. A system service (bluetooth.service)." \
  "a unit that runs again is announced once"

# A mute ends when the unit is seen running, whether or not Kempt ever announced it.
reset_world; check >/dev/null
"$KEMPT" startup mute foo.service --user >/dev/null
check >/dev/null
assert_eq "$(cat "$KEMPT_STATE_DIR/startup-mutes")" "user:foo.service" "a mute holds while the unit is not running"
echo foo.service > "$SD/active-user"
check >/dev/null
assert_eq "$([[ -s "$KEMPT_STATE_DIR/startup-mutes" ]] && echo kept || echo cleared)" "cleared" \
  "...and ends once it is seen running"

# A unit with a backslash is hidden by its mute like any other.
reset_world; dnf_max 150; check >/dev/null
"$KEMPT" startup mute "app-x\\x2dy$AUTOSTART" --user >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing user "app-x\\x2dy$AUTOSTART=X"
check >/dev/null
assert_eq "$(note_count)" "0" "a muted unit with a backslash in its name is not announced"
assert_eq "$(block '[(.startup.announced | length), (.startup.muted | length)]')" '[0,1]' "...and is listed as muted only"
assert_exit 2 "a unit name with a newline is refused" "$KEMPT" startup mute $'a\nb.service'
assert_exit 0 "a colon after the first character is allowed" "$KEMPT" startup mute 'a:b.service'

# --- nonsense from systemctl is not an answer -----------------------------------------------------
reset_world
touch "$SD/garbage-system" "$SD/garbage-user"
assert_exit 0 "a check survives systemctl answering nonsense" "$KEMPT" check
assert_eq "$(block 'has("startup")')" "false" "...and publishes no startup block"
rm -f "$SD/garbage-system" "$SD/garbage-user"

# --- the check closing a live run compares against that run, not the boot's first ---------------
reset_world; dnf_max 150; check >/dev/null
entry 20261020T090000 boot-A '[]' 150
check >/dev/null
failing system 'bluetooth.service=Bluetooth service'
check >/dev/null
assert_eq "$(note_count)" "0" "premise: a unit that fails with no run since is not announced"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
"$KEMPT" update --surface=widget >/dev/null 2>&1 || true
assert_eq "$(notes | grep -c "didn't start" || true)" "0" "a unit already failing when a live run started is not blamed on it"
assert_eq "$(startup_state '[.already[].unit]')" '["bluetooth.service"]' "...and is listed as already failing"

# --- a run that changed no package compares nothing ----------------------------------------------
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
jq '.backends.dnf.updated = []' "$HD/20261020T110000.json" > "$TESTTMP/e.json" && mv "$TESTTMP/e.json" "$HD/20261020T110000.json"
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service'
check >/dev/null
assert_eq "$(note_count)" "0" "after a run that changed no package, the next boot says nothing"

# --- a scope still waiting for its comparison keeps its own baseline -----------------------------
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing user 'foo.service=Foo'
touch "$SD/down-user"
check >/dev/null
rm -f "$SD/down-user"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
"$KEMPT" update --surface=widget >/dev/null 2>&1 || true
assert_contains "$(notes)" "Foo didn't start after the update." \
  "a run before the waiting scope answered does not make its failure look older than it is"

# --- a unit that ends cleanly without staying active ---------------------------------------------
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service'
check >/dev/null
"$KEMPT" startup mute bluetooth.service >/dev/null
failing system
echo bluetooth.service > "$SD/success-system"
check >/dev/null
assert_eq "$(note_count)" "1" "a unit that last ran cleanly and stopped is not announced as running again"
assert_eq "$(startup_state '[(.announced | length), (.recovered | length)]')" '[0,0]' "...and is dropped from the announced list"
assert_eq "$([[ -s "$KEMPT_STATE_DIR/startup-mutes" ]] && echo kept || echo cleared)" "cleared" "...and its mute ends"

# --- a failure never told that recovers is never told either -------------------------------------
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service'
env -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="$TESTTMP/no-runtime" "$KEMPT" check >/dev/null 2>&1
failing system
echo bluetooth.service > "$SD/active-system"
check >/dev/null
assert_eq "$(note_count)" "0" "an unsent failure that recovers is dropped, with no running-again notice"
assert_eq "$(startup_state '[(.announced | length), (.recovered | length)]')" '[0,0]' "...from both lists"

# --- mutes of units systemd no longer knows, and aliases -----------------------------------------
reset_world; check >/dev/null
"$KEMPT" startup mute foo.service --user >/dev/null
echo foo.service > "$SD/gone-user"
check >/dev/null
assert_eq "$([[ -s "$KEMPT_STATE_DIR/startup-mutes" ]] && echo kept || echo cleared)" "cleared" \
  "a mute of a unit systemd no longer knows ends"
echo 'dbus.service=dbus-broker.service' > "$SD/alias-system"
"$KEMPT" startup mute dbus.service >/dev/null
assert_eq "$(cat "$KEMPT_STATE_DIR/startup-mutes")" "system:dbus-broker.service" "a mute of an alias records the unit's own name"

# --- the history window ----------------------------------------------------------------------------
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
for i in $(seq 10 69); do
  jq 'del(.failed_before) | .backends.dnf.updated = []' "$HD/20261020T110000.json" > "$HD/20261020T12${i}00.json"
done
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service'
# Retention keeps history to 50 entries; a directory it cannot prune is how more are left.
chmod 555 "$HD"
check >/dev/null || true
chmod 755 "$HD"
assert_contains "$(notes)" "Bluetooth service didn't start" "a run with a baseline is found behind 60 entries without one"
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
jq '.backends.dnf.updated = 5' "$HD/20261020T110000.json" > "$TESTTMP/e.json" && mv "$TESTTMP/e.json" "$HD/20261020T110000.json"
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service'
check >/dev/null
assert_eq "$(note_count)" "0" "a package list that is not a list does not count as a change"

# --- kempt doctor and kempt startup ------------------------------------------------------------
reset_world; dnf_max 150; check >/dev/null
assert_contains "$("$KEMPT" doctor 2>&1)" "info  startup: no Kempt update compared yet" \
  "doctor says nothing was compared yet, rather than all clear, before any comparison"
assert_eq "$("$KEMPT" startup)" "Nothing to report." "...and so does kempt startup"
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
check >/dev/null
assert_contains "$("$KEMPT" doctor 2>&1)" "ok    startup: no service has stopped starting since a Kempt update" \
  "doctor gives the all-clear once a comparison found nothing"
assert_eq "$("$KEMPT" startup)" "No service has stopped starting since a Kempt update." "...and so does kempt startup"
reset_world; dnf_max 150; check >/dev/null
entry 20261020T110000 boot-A '[]' 150
export KEMPT_BOOT_ID=boot-B
failing system 'bluetooth.service=Bluetooth service'
check >/dev/null
day="$(LC_ALL=C date '+%-d %b')"
assert_contains "$("$KEMPT" doctor 2>&1)" "WARN  startup: Bluetooth service has not started since an update on $day. See: kempt startup" \
  "doctor warns about a unit that stopped starting, dated, without tying it to the newest update"
out="$("$KEMPT" startup)"
assert_contains "$out" "Not starting since an update:" "kempt startup groups what did not start"
assert_contains "$out" "Bluetooth service (bluetooth.service), since $day" "...each with the day it stopped"
assert_contains "$out" "systemctl status bluetooth.service" "...with the command that shows why"
assert_json_eq "$("$KEMPT" startup --json)" "$(block)" "kempt startup --json prints the block state.json carries"
failing user "app-x\\x2dy$AUTOSTART=X"
"$KEMPT" startup mute "app-x\\x2dy$AUTOSTART" --user >/dev/null
assert_contains "$("$KEMPT" startup)" "systemctl --user status 'app-x\\x2dy$AUTOSTART'" \
  "a unit with a backslash is quoted in its command"

finish
