#!/usr/bin/env bash
# `kempt startup --all`: what did not start this boot and why, what the last update changed about
# startup, what starts with the computer, what runs on a schedule, and how long startup took. Every
# outside command is a stub that records its calls.
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
KEMPT="$REPO_ROOT/bin/kempt"
export TZ=UTC

# systemctl, driven by files: failed-, enabled-, autostart- and timers-<scope>.json answer the
# list queries, props-<scope>/<unit> holds key=value lines a `show` prints over its defaults, and
# down-<scope> makes that scope fail.
SD="$TESTTMP/sd"; mkdir -p "$SD/props-system" "$SD/props-user"
export SD_DIR="$SD"
cat > "$TESTTMP/systemctl" <<'STUB'
#!/usr/bin/env bash
d="$SD_DIR"; scope=system
if [[ "$1" == --user ]]; then scope=user; shift; fi
echo "$scope $*" >> "$d/calls-systemctl"
[[ -e "$d/down-$scope" ]] && exit 1
[[ -e "$d/slow-$scope" ]] && exit 124
case "$1" in
  --failed) cat "$d/failed-$scope.json" 2>/dev/null || echo '[]' ;;
  --version) echo "systemd 259" ;;
  list-unit-files) cat "$d/enabled-$scope.json" 2>/dev/null || echo '[]' ;;
  list-units) cat "$d/autostart-$scope.json" 2>/dev/null || echo '[]' ;;
  list-timers) cat "$d/timers-$scope.json" 2>/dev/null || echo '[]' ;;
  show)
    shift
    while [[ "$1" == -p ]]; do shift 2; done
    [[ "$1" == -- ]] && shift
    for u in "$@"; do
      dir=system; [[ "$scope" == user ]] && dir=user
      printf 'Id=%s\nDescription=%s\nTransient=no\nActiveState=active\nLoadState=loaded\nResult=success\nConditionResult=yes\nConditionTimestampMonotonic=0\nFragmentPath=%s/files/%s/%s\nSourcePath=\n' "$u" "$u" "$d" "$dir" "$u" \
        | F="$d/props-$scope/$u" awk -F= '
            BEGIN { f = ENVIRON["F"]; while ((getline l < f) > 0) { i = index(l, "="); o[substr(l, 1, i - 1)] = substr(l, i + 1) } }
            { if ($1 in o) print $1 "=" o[$1]; else print }'
      echo
    done ;;
  *) exit 1 ;;
esac
STUB
# journalctl: the access check prints a line unless journal-denied exists; a json query prints
# journal-<scope>.json.
cat > "$TESTTMP/journalctl" <<'STUB'
#!/usr/bin/env bash
d="$SD_DIR"; echo "$*" >> "$d/calls-journalctl"
scope=system; [[ " $* " == *" --user "* ]] && scope=user
if [[ " $* " == *" -o cat "* ]]; then
  [[ -e "$d/journal-denied" ]] && { echo "Hint: You are currently not seeing messages from other users and the system." >&2; exit 0; }
  echo "Starting up"; exit 0
fi
echo "$scope" >> "$d/journal-scopes"
cat "$d/journal-$scope.json" 2>/dev/null; exit 0
STUB
cat > "$TESTTMP/crontab" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$SD_DIR/calls-crontab"
[[ -f "$SD_DIR/crontab" ]] || { echo "no crontab for $USER" >&2; exit 1; }
cat "$SD_DIR/crontab"
STUB
# rpm -qf: owners holds path<TAB>package lines.
cat > "$TESTTMP/rpm" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$SD_DIR/calls-rpm"
shift 3
rc=0
for p in "$@"; do
  n="$(awk -F'\t' -v p="$p" '$1 == p { print $2 }' "$SD_DIR/owners" 2>/dev/null)"
  if [[ -n "$n" ]]; then echo "$n"; else echo "file $p is not owned by any package"; rc=1; fi
done
exit $rc
STUB
cat > "$TESTTMP/systemd-analyze" <<'STUB'
#!/usr/bin/env bash
echo "${*:-time}" >> "$SD_DIR/calls-analyze"
case "${1:-time}" in
  time) [[ -f "$SD_DIR/analyze" ]] || { echo "Bootup is not yet finished." >&2; exit 1; }; cat "$SD_DIR/analyze" ;;
  blame) cat "$SD_DIR/blame" 2>/dev/null ;;
esac
STUB
cat > "$TESTTMP/atq" <<'STUB'
#!/usr/bin/env bash
cat "$SD_DIR/atq" 2>/dev/null; exit 0
STUB
chmod +x "$TESTTMP"/{systemctl,journalctl,crontab,rpm,systemd-analyze,atq}
echo "me wheel" > "$SD/groups"
export KEMPT_SYSTEMCTL_CMD="$TESTTMP/systemctl" KEMPT_JOURNALCTL_CMD="$TESTTMP/journalctl" \
       KEMPT_CRONTAB_CMD="$TESTTMP/crontab" KEMPT_RPM_QF_CMD="$TESTTMP/rpm" \
       KEMPT_SYSTEMD_ANALYZE_CMD="$TESTTMP/systemd-analyze" KEMPT_ATQ_CMD="$TESTTMP/atq" \
       KEMPT_GROUPS_CMD="cat $SD/groups"
ETC="$TESTTMP/etc"; SPOOL="$TESTTMP/spool"; LINGER="$TESTTMP/linger"
mkdir -p "$ETC" "$SPOOL" "$LINGER"
export KEMPT_STARTUP_ETC="$ETC" KEMPT_ANACRON_SPOOL="$SPOOL" KEMPT_LINGER_DIR="$LINGER" USER=tester
touch "$LINGER/tester"
export KEMPT_BOOT_ID=boot-now

page() { "$KEMPT" startup --all --json 2>/dev/null; }
text() { "$KEMPT" startup --all 2>/dev/null; }
calls() { cat "$SD/calls-$1" 2>/dev/null || true; }
reset_calls() { rm -f "$SD"/calls-*; }

# --- an empty world draws no section, and asks the journal nothing --------------------------------
out="$(page)"
assert_eq "$(jq -r '.schema' <<<"$out")" "1" "the page is schema 1"
assert_eq "$(jq -r '.generated_at | test("^[0-9-]{10}T[0-9:]{8}Z$")' <<<"$out")" "true" "its times are UTC"
assert_eq "$(jq -c '.notes' <<<"$out")" "[]" "no notes when everything answered"
assert_eq "$(jq -c '[keys[] | select(IN("failed", "changed", "starts", "schedule", "boot_time"))]' <<<"$out")" "[]" \
  "with nothing to show, no section is in the answer"
assert_eq "$(calls journalctl)" "" "nothing failed, so the journal is never read"
assert_eq "$(calls rpm)" "" "nothing to group, so rpm is never asked"
assert_contains "$(text)" "Kempt found nothing to list." "the text says so in one line"
assert_exit 2 "an unknown option is refused" -- "$KEMPT" startup --all --bogus

# --- didn't start this boot, with the line that explains it --------------------------------------
reset_calls
printf '%s\n' '[{"unit":"bluetooth.service","load":"loaded","active":"failed","sub":"failed","description":"Bluetooth service"},
                {"unit":"cups.service","load":"loaded","active":"failed","sub":"failed","description":"CUPS Scheduler"}]' > "$SD/failed-system.json"
printf 'Result=exit-code\nActiveState=failed\nDescription=Bluetooth service\n' > "$SD/props-system/bluetooth.service"
printf 'Result=core-dump\nActiveState=failed\nDescription=CUPS Scheduler\n' > "$SD/props-system/cups.service"
# The unit's own last line explains; systemd's "Failed with result" line only repeats the state.
{
  echo '{"_SYSTEMD_UNIT":"bluetooth.service","PRIORITY":"6","MESSAGE":"Starting"}'
  echo '{"_SYSTEMD_UNIT":"bluetooth.service","PRIORITY":"6","MESSAGE":"No Bluetooth adapter found"}'
  echo '{"_SYSTEMD_UNIT":"init.scope","UNIT":"bluetooth.service","PRIORITY":"4","MESSAGE":"bluetooth.service: Failed with result '"'"'exit-code'"'"'."}'
  echo '{"_SYSTEMD_UNIT":"init.scope","UNIT":"cups.service","PRIORITY":"4","MESSAGE":"cups.service: Main process exited, code=dumped"}'
} > "$SD/journal-system.json"
# Split so the name does not read as an email address to test_docs.sh.
AT='@autostart.service'
AUTOSTART="app-imsettings\\x2dstart$AT"
jq -cn --arg u "$AUTOSTART" '[{unit: $u, load: "loaded", active: "failed", sub: "failed", description: "IMSettings"}]' > "$SD/failed-user.json"
jq -cn --arg u "$AUTOSTART" '{_SYSTEMD_USER_UNIT: $u, PRIORITY: "6", MESSAGE: "Current desktop is not supported"}' > "$SD/journal-user.json"
printf 'Result=exit-code\nActiveState=failed\nDescription=IMSettings\n' > "$SD/props-user/$AUTOSTART"
out="$(page)"
assert_json_eq "$(jq -c '.failed.units[0]' <<<"$out")" \
  '{"scope":"system","unit":"bluetooth.service","description":"Bluetooth service","state":"failed","result":"exit-code","log":"No Bluetooth adapter found","status_command":"systemctl status bluetooth.service"}' \
  "a failed unit carries its state, its result, its own last log line and the command that shows why"
assert_eq "$(jq -r '.failed.units[1].log' <<<"$out")" "cups.service: Main process exited, code=dumped" \
  "with no line of its own, systemd's line about the unit stands"
assert_eq "$(jq -r '.failed.units[2] | .log, .status_command' <<<"$out")" \
  "Current desktop is not supported"$'\n'"systemctl --user status '$AUTOSTART'" \
  "a session unit reads the user's own journal, and its command is quoted"
assert_eq "$(jq -r '.failed | [.journal_denied, .journal_available] | join(",")' <<<"$out")" "false,true" "the journal was readable"
assert_contains "$(calls journalctl | grep -- '-o json' | head -n 1)" "--output-fields=MESSAGE,PRIORITY," \
  "the journal is asked only for the fields the page reads"
assert_eq "$(calls journalctl | grep -c -- '-o json')" "2" "one journal query per scope, not one per unit"
t="$(text)"
assert_contains "$t" "Didn't start this boot:" "the text names the section"
assert_contains "$t" "Didn't start this boot:"$'\n'"  Bluetooth service"$'\n'"    Its log says: No Bluetooth adapter found"$'\n'"    To see why: systemctl status bluetooth.service" \
  "...names the unit by its description, then its log line, then the command on a line of its own"
assert_contains "$t" "  IMSettings (when you log in)" "...and says which units are your session's"

# --- an autostart unit systemd names only by its unit: the entry's Name=, else its decoded name ---
mkdir -p "$TESTTMP/xdg/autostart"
printf '[Desktop Entry]\nName = IM Settings\nName[de]=IM-Einstellungen\n[Desktop Action x]\nName=Other\n' > "$TESTTMP/xdg/autostart/imsettings-start.desktop"
export XDG_CONFIG_DIRS="$TESTTMP/xdg"
FOO="app-foo\\x2dbar$AT"
jq -cn --arg a "$AUTOSTART" --arg f "$FOO" '[{unit: $a, description: $a}, {unit: $f, description: $f}]' > "$SD/failed-user.json"
mv "$SD/props-user/$AUTOSTART" "$TESTTMP/props-keep"
assert_eq "$(startup_failed user | jq -r '[.[].description] | join(",")')" "foo-bar,IM Settings" \
  "the list of services that stopped starting names an autostart unit by its entry, else its decoded name"
t="$(text)"
assert_contains "$t" "  IM Settings (when you log in)" "the page names it the same way"
assert_contains "$t" "  foo-bar (when you log in)" "...decoding systemd's escapes when there is no entry"
mv "$TESTTMP/props-keep" "$SD/props-user/$AUTOSTART"
jq -cn --arg u "$AUTOSTART" '[{unit: $u, load: "loaded", active: "failed", sub: "failed", description: "IMSettings"}]' > "$SD/failed-user.json"

# --- every notification is text: Plasma would read & < > as markup ------------------------------
cat > "$TESTTMP/notify" <<'STUB'
#!/usr/bin/env bash
printf '%s|' "$@" >> "$SD_DIR/notes"; echo >> "$SD_DIR/notes"
STUB
chmod +x "$TESTTMP/notify"
( KEMPT_NOTIFY="$TESTTMP/notify"; DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent
  notify "Kempt" "a < b & c > d"; notify_delivered "Kempt" "<i>x</i> & y" || true )
assert_eq "$(cat "$SD/notes")" "Kempt|a &lt; b &amp; c &gt; d|"$'\n'"Kempt|&lt;i&gt;x&lt;/i&gt; &amp; y|" \
  "notify and notify_delivered escape markup for every caller"
rm -f "$SD/notes"

# --- the journal denied: membership first, then a line, never the exit status -------------------
reset_calls
echo "tester" > "$SD/groups"
out="$(page)"
assert_eq "$(jq -r '.failed.journal_denied, .failed.units[0].log' <<<"$out")" "true"$'\n'"null" \
  "outside wheel, adm and systemd-journal, the system journal is not read"
assert_eq "$(calls journalctl | grep -c -- '--user')" "$(calls journalctl | grep -c -- '-o json')" \
  "...and only the user's own journal is asked"
assert_contains "$(text)" "No log lines for system services: you are not allowed to read the system journal." \
  "the text says why the lines are missing"
assert_contains "$(text)" "    Stopped with an error (exit-code)" "...and shows the state instead"
echo "tester wheel" > "$SD/groups"; touch "$SD/journal-denied"
assert_eq "$(page | jq -r '.failed.journal_denied')" "true" \
  "in wheel but the journal prints nothing: denied, though journalctl exits 0"
rm -f "$SD/journal-denied"

# --- without journalctl, the log text is simply missing ---------------------------------------
out="$(KEMPT_JOURNALCTL_CMD="$TESTTMP/no-such-journalctl" page)"
assert_eq "$(jq -r '.failed | [.journal_denied, .journal_available, .units[0].log] | join(",")' <<<"$out")" "false,false," \
  "journalctl missing is not a refusal: denied false, available false, no log"
assert_not_contains "$(KEMPT_JOURNALCTL_CMD="$TESTTMP/no-such-journalctl" text)" "not allowed" "...and the text does not say you are not allowed"
rm -f "$SD"/failed-*.json "$SD"/journal-*.json

# --- a long journal: more than one argument can hold reaches jq whole ---------------------------
big="$(head -c 1500 /dev/zero | tr '\0' 'x')"
jq -cn '[{unit: "a.service", description: "A"}, {unit: "b.service", description: "B"}, {unit: "c.service", description: "C"}]' > "$SD/failed-system.json"
for u in a b c; do
  for i in $(seq 60); do jq -cn --arg u "$u.service" --arg m "$big" '{_SYSTEMD_UNIT: $u, PRIORITY: "6", MESSAGE: $m}'; done
  jq -cn --arg u "$u.service" '{_SYSTEMD_UNIT: $u, PRIORITY: "3", MESSAGE: ("reason " + $u)}'
done > "$SD/journal-system.json"
assert_eq "$([[ $(stat -c %s "$SD/journal-system.json") -gt 200000 ]] && echo big)" "big" "premise: the journal is over 200 KB"
assert_eq "$(page | jq -r '[.failed.units[].log] | join(",")')" "reason a.service,reason b.service,reason c.service" \
  "three failed units and a long journal: every unit keeps its line"
rm -f "$SD"/failed-*.json "$SD"/journal-*.json

# --- control characters from outside never reach the terminal -----------------------------------
ESC=$'\e'; BEL=$'\a'
jq -cn --arg d "Evil${ESC}]52;c;aGk=${BEL} service" '[{unit: "evil.service", description: $d}]' > "$SD/failed-system.json"
printf 'Description=Evil\033]52;c;aGk=\007 service\nResult=exit-code\n' > "$SD/props-system/evil.service"
# A MESSAGE journald could not store as text arrives as an array of bytes.
jq -cn '{_SYSTEMD_UNIT: "evil.service", PRIORITY: "3", MESSAGE: ([27, 93, 50, 59, 104, 105, 7, 155] + ("bad" | explode))}' > "$SD/journal-system.json"
out="$(page)"
assert_contains "$(jq -r '.failed.units[0].description' <<<"$out")" "$ESC" "the JSON keeps the description as systemd gave it"
t="$(text)"
assert_eq "$(LC_ALL=C grep -c $'[\x01-\x08\x0b-\x1f\x7f]' <<<"$t")" "0" "the text has no control characters"
assert_eq "$(grep -c $'\u009b' <<<"$t")" "0" "...not even the eight-bit ones"
assert_contains "$t" "  Evil ]52;c;aGk=  service" "...they are spaces"
assert_contains "$t" "Its log says:  ]2;hi  bad" "...in the log line too"
rm -f "$SD"/failed-*.json "$SD"/journal-*.json "$SD/props-system/evil.service"
jq -n --arg d "Odd${ESC}]52;c;aGk=${BEL}" '{schema: 1, announced: [{unit: "odd.service", scope: "system", description: $d, since: "2026-10-20T00:00:00Z"}]}' \
  > "$KEMPT_STATE_DIR/startup.json"
t="$("$KEMPT" startup 2>/dev/null)"
assert_contains "$t" "  Odd ]52;c;aGk=  (odd.service)" "the list of services that stopped starting cleans them too"
assert_eq "$(LC_ALL=C grep -c $'[\x01-\x08\x0b-\x1f\x7f]' <<<"$t")" "0" "...and prints no control character"
rm -f "$KEMPT_STATE_DIR/startup.json"

# --- a session that does not answer: one wait, then the page goes on without it -----------------
reset_calls
jq -cn '[{unit: "a.service", description: "A"}]' > "$SD/failed-system.json"
printf '%s\n' '[{"next":1792540800000000,"last":null,"unit":"sync.timer","activates":"sync.service"}]' > "$SD/timers-user.json"
touch "$SD/slow-user"; rm -f "$SD/journal-scopes"
out="$(page)"
assert_eq "$(jq -c '.notes' <<<"$out")" '["session_slow"]' "a session call that timed out is noted"
assert_not_contains "$(calls systemctl)" "user list-timers" "...and the session is asked nothing more"
assert_not_contains "$(cat "$SD/journal-scopes" 2>/dev/null)" "user" "...not even its journal"
assert_contains "$(text)" "Your session did not answer in time; its part is missing." "the text says what is missing"
rm -f "$SD/slow-user" "$SD/timers-user.json" "$SD/journal-scopes"
# No session bus at all (`su - user -c`): the session fails at once, which is not slow.
touch "$SD/down-user"
out="$(page)"
assert_eq "$(jq -c '.notes' <<<"$out")" '["session_missing"]' "a session that could not be reached is noted"
assert_contains "$(text)" "Your session could not be reached, so its part is missing." "...and the text says what is missing"
touch "$SD/down-system"
assert_eq "$(page | jq -c '.notes')" '[]' "with no systemd at all, the session is not singled out"
rm -f "$SD/down-user" "$SD/down-system" "$SD/failed-system.json"
reset_calls
STARTUP_DEADLINE=$SECONDS
assert_exit 1 "with the page's time used up, no call is made" -- startup_systemctl system --failed
assert_eq "$(calls systemctl)" "" "...and systemctl is never started"
unset STARTUP_DEADLINE
# A session cut short by the page's time is slow too: session_missing is for one that failed at once.
STARTUP_TMP="$TESTTMP/st"; mkdir -p "$STARTUP_TMP"
STARTUP_DEADLINE=$SECONDS
startup_systemctl user list-timers >/dev/null || true
assert_eq "$([[ -e "$STARTUP_TMP/user-slow" ]] && echo slow || echo not)" "slow" "a session call with no time left marks the session slow"
rm -f "$STARTUP_TMP/user-slow"; touch "$SD/slow-user"
STARTUP_DEADLINE=$(( SECONDS + 3 ))
startup_systemctl user list-timers >/dev/null || true
assert_eq "$([[ -e "$STARTUP_TMP/user-slow" ]] && echo slow || echo not)" "slow" "...as does one that timed out on a shorter wait"
rm -f "$SD/slow-user"; rm -rf "$STARTUP_TMP"; unset STARTUP_DEADLINE STARTUP_TMP
mkdir -p "$TESTTMP/tmpd"
TMPDIR="$TESTTMP/tmpd" page >/dev/null
assert_eq "$(ls -A "$TESTTMP/tmpd")" "" "the page's temporary folder is gone when it ends"

# --- a unit name is shown, never run ------------------------------------------------------------
reset_calls
jq -cn --arg u "x\$(touch $TESTTMP/pwned).service" '[{unit: $u, description: "odd"}]' > "$SD/failed-system.json"
out="$(page)"
assert_eq "$([[ -e "$TESTTMP/pwned" ]] && echo ran || echo shown)" "shown" "a strange unit name runs nothing"
assert_contains "$(jq -r '.failed.units[0].status_command' <<<"$out")" "status 'x\$(touch" "...and its command is single quoted"
rm -f "$SD/failed-system.json"

# --- starts with the computer, grouped by package ------------------------------------------------
reset_calls
printf '%s\n' '[{"unit_file":"sshd.service","state":"enabled"},{"unit_file":"cups.socket","state":"enabled"},
  {"unit_file":"mine.service","state":"enabled"},{"unit_file":"getty@.service","state":"enabled"},
  {"unit_file":"multi-user.target","state":"enabled"},{"unit_file":"backup.timer","state":"enabled"},
  {"unit_file":"sshd-keygen.service","state":"enabled"},{"unit_file":"vboxservice.service","state":"enabled"}]' > "$SD/enabled-system.json"
printf '%s\n' '[{"unit_file":"pipewire.service","state":"enabled"},{"unit_file":"pipewire.socket","state":"enabled"}]' > "$SD/enabled-user.json"
GEO="app-geoclue\\x2ddemo\\x2dagent$AT"
jq -cn --arg g "$GEO" --arg at "$AT" '[{unit: $g, load: "loaded", active: "active", description: "Geoclue Demo agent"},
                        {unit: ("app-hidden" + $at), load: "not-found", active: "inactive", description: "hidden"}]' > "$SD/autostart-user.json"
printf 'Description=OpenSSH server daemon\n' > "$SD/props-system/sshd.service"
# systemd says ConditionResult=no for a unit it never tried; only a checked condition skips one.
printf 'Description=OpenSSH key generation\nConditionResult=no\nActiveState=inactive\n' > "$SD/props-system/sshd-keygen.service"
printf 'Description=VirtualBox guest services\nConditionResult=no\nConditionTimestampMonotonic=4873018\nActiveState=inactive\n' > "$SD/props-system/vboxservice.service"
printf 'Description=My own thing\nFragmentPath=%s/files/etc/mine.service\n' "$SD" > "$SD/props-system/mine.service"
printf 'Description=PipeWire Multimedia Service\n' > "$SD/props-user/pipewire.service"
printf 'SourcePath=%s/files/xdg/geoclue-demo-agent.desktop\nFragmentPath=/run/user/1000/systemd/generator.late/%s\n' "$SD" "$GEO" > "$SD/props-user/$GEO"
# rpm -qf prints nothing on stdout for a path that does not exist, so every path here is a file.
mkdir -p "$SD/files/system" "$SD/files/user" "$SD/files/etc" "$SD/files/xdg" "$TESTTMP/units"
touch "$SD/files/system/sshd.service" "$SD/files/system/sshd-keygen.service" "$SD/files/etc/mine.service" "$SD/files/user/pipewire.service" \
      "$SD/files/xdg/geoclue-demo-agent.desktop" "$TESTTMP/units/getty@.service"
printf '%s\topenssh-server\n%s\topenssh-server\n%s\tpipewire\n%s\tgeoclue2-demos\n%s\tsystemd\n' "$SD/files/system/sshd.service" "$SD/files/system/sshd-keygen.service" \
  "$SD/files/user/pipewire.service" "$SD/files/xdg/geoclue-demo-agent.desktop" "$TESTTMP/units/getty@.service" > "$SD/owners"
export KEMPT_SYSTEM_UNIT_DIRS="$TESTTMP/units"
out="$(page)"
assert_json_eq "$(jq -c '[.starts[] | [.scope, .kind, .unit, .package]]' <<<"$out")" \
  "$(jq -cn --arg g "$GEO" '[["system","service","getty@.service","systemd"],["system","service","mine.service",null],
     ["system","service","sshd-keygen.service","openssh-server"],["system","service","sshd.service","openssh-server"],
     ["system","service","vboxservice.service",null],["user","autostart",$g,"geoclue2-demos"],
     ["user","service","pipewire.service","pipewire"]]')" \
  "services and autostart entries, each with the package that owns it; sockets, targets and timers are left out"
assert_eq "$(jq -r '[.starts[] | select(.skipped) | .unit] | join(",")' <<<"$out")" "vboxservice.service" \
  "a unit whose condition failed this boot is marked skipped, one never tried is not"
assert_eq "$(calls rpm | wc -l | tr -d ' ')" "1" "rpm is asked once for every unit"
assert_not_contains "$(calls systemctl)" "getty@.service" "a template is never handed to show, which refuses the whole call"
t="$(text)"
assert_contains "$t" "Starts with the computer:"$'\n'"  Not from a package"$'\n'"    My own thing"$'\n'"  openssh-server"$'\n'"    OpenSSH key generation"$'\n'"    OpenSSH server daemon"$'\n'"  getty instances (systemd)"$'\n'"  1 more is set to start but is skipped on this computer." \
  "the text puts what no package owns first, one line per unit, and a package heading only over two"
assert_not_contains "$t" "VirtualBox" "...and leaves out the skipped unit"
assert_eq "$(jq -r '.starts[] | select(.unit == "getty@.service") | .description' <<<"$out")" "getty instances" \
  "a template, which systemd describes per instance, is described by its name"
assert_contains "$t" "Starts when you log in:"$'\n'"  Geoclue Demo agent (geoclue2-demos)"$'\n'"  PipeWire Multimedia Service (pipewire)" \
  "...and session services under their own heading"

# --- also when present: rc.local and autostart scripts --------------------------------------------
printf '#!/bin/sh\n' > "$ETC/rc.local"; chmod +x "$ETC/rc.local"
mkdir -p "$HOME/.config/autostart-scripts"; touch "$HOME/.config/autostart-scripts/start-vpn.sh"
out="$(page)"
assert_eq "$(jq -r '[.starts[] | select(.kind == "rc-local" or .kind == "script") | .unit] | join(",")' <<<"$out")" \
  "$ETC/rc.local,start-vpn.sh" "an executable rc.local and the session's autostart scripts are listed"
rm -f "$ETC/rc.local"; rm -rf "$HOME/.config/autostart-scripts"

# --- changed since the last update ----------------------------------------------------------------
mkdir -p "$KEMPT_STATE_DIR/history"
jq -n '{timestamp: "2026-10-18T10:00:00+03:00", surface: "background", status: "ok",
        failed_before: {boot_id: "b0", at: "2026-10-18T10:00:00+03:00", system: [], user: [],
          enabled: {system: ["sshd.service", "getty@.service", "old.service", "old.socket"], user: ["pipewire.service", "pipewire.socket"]}}}' \
  > "$KEMPT_STATE_DIR/history/2026-10-18T10-00-00.json"
out="$(page)"
assert_json_eq "$(jq -c '.changed' <<<"$out")" \
  '{"since":"2026-10-18T07:00:00Z","added":[{"scope":"system","unit":"backup.timer","description":"backup.timer"},{"scope":"system","unit":"mine.service","description":"My own thing"},{"scope":"system","unit":"sshd-keygen.service","description":"OpenSSH key generation"},{"scope":"system","unit":"vboxservice.service","description":"VirtualBox guest services"}],"removed":[{"scope":"system","unit":"old.service","description":"old.service"}]}' \
  "units enabled or no longer enabled since the last run's baseline, described as the page describes them elsewhere, else by name; plumbing is left out"
assert_contains "$(text)" "Changed since the last update (18 Oct 07:00):"$'\n'"  Now starts: backup.timer"$'\n'"  Now starts: My own thing (mine.service)" \
  "the text names what changed, by its description"
touch "$SD/down-user"
assert_eq "$(page | jq -c '[.changed.added[].scope] | unique')" '["system"]' "a scope that did not answer is not compared"
rm -f "$SD/down-user"

# --- runs on a schedule ---------------------------------------------------------------------------
reset_calls
TODAY="$(date -u -d 'today 00:00' +%s)"; TOMORROW=$(( TODAY + 86400 ))
jq -cn --argjson l "${TODAY}000000" --argjson n "${TOMORROW}000000" '[{next: $n, last: $l, unit: "backup.timer", activates: "backup.service"},
  {next: $n, last: null, unit: "fstrim.timer", activates: "fstrim.service"},
  {next: null, last: null, unit: "never.timer", activates: "never.service"}]' > "$SD/timers-system.json"
printf 'Description=Nightly backup\nResult=exit-code\n' > "$SD/props-system/backup.service"
printf 'Description=Discard unused blocks\n' > "$SD/props-system/fstrim.service"
printf '%s\n' '[{"next":1792540800000000,"last":1792454400000000,"unit":"sync.timer","activates":"sync.service"}]' > "$SD/timers-user.json"
printf '# a comment\nMAILTO=me\n0 3 * * * /home/tester/bin/backup.sh >/dev/null\n@reboot /home/tester/bin/hello\n' > "$SD/crontab"
printf 'SHELL=/bin/bash\n*/5 * * * * root /usr/local/bin/poll\n' > "$ETC/crontab"
mkdir -p "$ETC/cron.d" "$ETC/cron.hourly" "$ETC/cron.daily" "$ETC/cron.weekly" "$ETC/cron.monthly"
printf '01 * * * * root run-parts /etc/cron.hourly\n' > "$ETC/cron.d/0hourly"
printf '30 2 * * 0 root /usr/sbin/raid-check\n' > "$ETC/cron.d/raid-check"
printf 'ignored\n' > "$ETC/cron.d/raid-check.rpmsave"
printf '#!/bin/sh\n' > "$ETC/cron.hourly/0anacron"; printf '#!/bin/sh\n' > "$ETC/cron.daily/logrotate"
chmod +x "$ETC/cron.hourly/0anacron" "$ETC/cron.daily/logrotate"
printf 'SHELL=/bin/sh\n1\t5\tcron.daily\t\tnice run-parts /etc/cron.daily\n3\t10\tbackup.tidy\t/usr/local/bin/tidy\n' > "$ETC/anacrontab"
date +%Y%m%d > "$SPOOL/cron.daily"; touch -d 'today 03:12' "$SPOOL/cron.daily"
printf '5\tThu Oct 21 10:00:00 2027 a tester\n' > "$SD/atq"
out="$(page)"
assert_json_eq "$(jq -c '.schedule.timers[0]' <<<"$out")" \
  "$(jq -cn --arg l "$(date -u -d @"$TODAY" +%FT%TZ)" --arg n "$(date -u -d @"$TOMORROW" +%FT%TZ)" \
     '{scope: "system", unit: "backup.timer", activates: "backup.service", description: "Nightly backup", last: $l, next: $n, result: "exit-code"}')" \
  "a timer carries its last and next run and the result of the service it starts"
assert_eq "$(jq -c '.schedule.timers[1].result' <<<"$out")" "null" \
  "a timer that never ran has no result, though its service says success"
assert_eq "$(jq -r '[.schedule.timers[].unit] | join(",")' <<<"$out")" "backup.timer,fstrim.timer,sync.timer" \
  "a timer that has never run and is not scheduled is left out"
assert_json_eq "$(jq -c '[.schedule.cron[] | [.source, .schedule, .user, .command]]' <<<"$out")" \
  '[["crontab","0 3 * * *",null,"/home/tester/bin/backup.sh >/dev/null"],["crontab","@reboot",null,"/home/tester/bin/hello"],
    ["/etc/crontab","*/5 * * * *","root","/usr/local/bin/poll"],["/etc/cron.d/raid-check","30 2 * * 0","root","/usr/sbin/raid-check"],
    ["cron.daily","daily",null,"logrotate"],["anacron","3",null,"/usr/local/bin/tidy"]]' \
  "cron jobs from every source; run-parts lines, 0anacron, comments, settings and package leftovers are not jobs"
assert_eq "$(jq -r '.schedule.cron[] | select(.source == "cron.daily") | .last' <<<"$out")" "$(date -u -d 'today 03:12' +%FT%TZ)" \
  "anacron's own record gives the last run of the daily scripts"
assert_eq "$(jq -c '.schedule.at' <<<"$out")" '[{"id":"5","when":"2027-10-21T10:00:00Z"}]' "at jobs are listed, their time in UTC"
assert_eq "$(jq -c '.schedule.notes' <<<"$out")" '[]' "crond running and lingering on: no notes"
t="$(text)"
assert_contains "$t" "Runs on a schedule:" "the text names the section"
assert_contains "$t" "    Nightly backup (backup.timer): last run today 00:00, next tomorrow 00:00, the last run failed" \
  "...says when a timer ran, when it runs next, and that its last run failed"
assert_contains "$t" "    Discard unused blocks (fstrim.timer): next tomorrow 00:00" "...and leaves out what is unknown"
assert_contains "$t" "    backup.sh: every day at 03:00 (your crontab)" "...cron jobs by program, their schedule in words"
assert_contains "$t" "    hello: at startup (your crontab)" "...@reboot too"
assert_contains "$t" "    poll: every 5 minutes (/etc/crontab, as root)" "...steps of minutes"
assert_contains "$t" "    raid-check: every Sunday at 02:30 (/etc/cron.d/raid-check, as root)" "...days of the week"
assert_contains "$t" "    logrotate: every day, last run today" "...the daily scripts in words"
assert_contains "$t" "    21 Oct 10:00 (job 5)" "...and an at job's time"
printf 'ActiveState=inactive\n' > "$SD/props-system/crond.service"
rm -f "$LINGER/tester"
out="$(page)"
assert_eq "$(jq -c '.schedule.notes' <<<"$out")" '["crond_down","linger_off"]' "crond stopped and lingering off are both noted"
t="$(text)"
assert_contains "$t" "These jobs do not run while crond is stopped." "the crond note is in the text"
assert_contains "$t" "Your timers stop when you log out." "...and so is the lingering note"
rm -f "$SD/crontab" "$ETC/crontab" "$ETC/anacrontab"; rm -rf "$ETC"/cron.*; rm -f "$SD/timers-user.json"
assert_eq "$(page | jq -c '.schedule.notes')" '[]' "with no cron jobs and no session timers, neither note applies"
rm -f "$SD/props-system/crond.service"; touch "$LINGER/tester"

# --- startup time against the usual --------------------------------------------------------------
reset_calls
rm -f "$SD"/enabled-*.json "$SD"/autostart-*.json "$SD"/timers-*.json "$SD/atq"
rm -rf "$KEMPT_STATE_DIR/history"
assert_eq "$(page | jq 'has("boot_time")')" "false" "while startup is still running, there is no time to show"
assert_eq "$([[ -e "$KEMPT_STATE_DIR/boot-times.json" ]] && echo yes || echo no)" "no" "...and nothing is recorded"
printf 'Startup finished in 13.153s (firmware) + 2.670s (loader) + 856ms (kernel) + 1.919s (initrd) + 3min 996ms (userspace) = 3min 19.596s\ngraphical.target reached after 6.117s in userspace.\n' > "$SD/analyze"
printf '1min 32.362s systemd-fsck@dev-disk-by\\x2duuid-655f.service\n     17.721s plocate-updatedb.service\n' > "$SD/blame"
printf 'Description=File System Check on /dev/disk/by-uuid/655f\n' > "$SD/props-system/systemd-fsck@dev-disk-by\x2duuid-655f.service"
t="$(text)"
assert_contains "$t" "Startup time:"$'\n'"  Ready in 6 s; all services by 3 min 1 s."$'\n'"  From power on: 3 min 20 s." \
  "the first boot Kempt sees still shows its time"
assert_not_contains "$t" "Usually" "...with nothing usual to compare against"
assert_not_contains "$t" "Longest step" "...and no step singled out"
rm -f "$KEMPT_STATE_DIR/boot-times.json"
jq -cn '[{boot_id: "b1", at: "2026-10-15T11:00:00+03:00", ready_sec: 5, userspace_sec: 170},
         {boot_id: "b2", at: "2026-10-16T08:00:00Z", ready_sec: 7, userspace_sec: 175},
         {boot_id: "b3", at: "2026-10-17T08:00:00Z", ready_sec: 9, userspace_sec: 400}]' > "$KEMPT_STATE_DIR/boot-times.json"
out="$(page)"
assert_json_eq "$(jq -c '.boot_time | del(.recent)' <<<"$out")" \
  '{"ready_sec":6.117,"userspace_sec":180.996,"total_sec":199.596,"usual":{"ready_sec":7,"userspace_sec":175,"boots":3},"slowest":{"unit":"systemd-fsck@dev-disk-by\\x2duuid-655f.service","description":"File System Check on /dev/disk/by-uuid/655f","sec":92.362}}' \
  "this boot's times, the median of the boots Kempt recorded before it, and the slowest unit"
assert_eq "$(jq -r '.boot_time.recent[-1].at' <<<"$out")" "2026-10-15T08:00:00Z" "an earlier boot's time is given in UTC"
assert_eq "$(jq -r '[.boot_time.recent[].boot_id] | join(",")' <<<"$out")" "b3,b2,b1" "the recent boots, newest first"
assert_eq "$(jq -r '.[-1].boot_id' "$KEMPT_STATE_DIR/boot-times.json")" "boot-now" "this boot is recorded"
t="$(text)"
assert_contains "$t" "Startup time:"$'\n'"  Ready in 6 s; all services by 3 min 1 s." "the text gives this boot's times"
assert_contains "$t" "  Usually ready in 7 s; all services by 2 min 55 s." "...and the usual"
assert_not_contains "$t" "Longest step" "close to the usual, no step is singled out"
jq '[.[] | if .boot_id == "boot-now" then . else .userspace_sec = 110 end]' "$KEMPT_STATE_DIR/boot-times.json" > "$TESTTMP/bt" \
  && mv "$TESTTMP/bt" "$KEMPT_STATE_DIR/boot-times.json"
assert_contains "$(text)" "  Longest step: the disk check, 1 min 32 s." "well above the usual, the longest step is named in words"
reset_calls
page >/dev/null
assert_eq "$(calls analyze)" "" "a boot already recorded is not asked again"
assert_eq "$(jq '[.[] | select(.boot_id == "boot-now")] | length' "$KEMPT_STATE_DIR/boot-times.json")" "1" "...and recorded once"

# The check records the time once per boot, without the slow blame, for everyone: the page opens
# from the widget's menu whenever someone wants it, and "usual" needs the boots before that.
reset_calls
rm -f "$KEMPT_STATE_DIR/boot-times.json"
mv "$SD/analyze" "$SD/analyze.later"
startup_boot_record_quietly; rc=$?
assert_eq "$rc:$([[ -e "$KEMPT_STATE_DIR/boot-times.json" ]] && echo yes || echo no)" "0:no" \
  "a check while startup is still running records nothing, and does not fail"
mv "$SD/analyze.later" "$SD/analyze"
reset_calls
startup_boot_record_quietly
assert_eq "$(jq -c '.[0] | [.boot_id, .ready_sec, has("slowest")]' "$KEMPT_STATE_DIR/boot-times.json")" '["boot-now",6.117,false]' \
  "a check records this boot's times, with no setting to turn on"
assert_eq "$(calls analyze)" "time" "...with one systemd-analyze call, leaving the slowest unit to the page"
startup_boot_record_quietly
startup_boot_record_quietly
assert_eq "$(calls analyze)" "time" "later checks in the same boot ask systemd-analyze nothing"
assert_eq "$(jq '[.[] | select(.boot_id == "boot-now")] | length' "$KEMPT_STATE_DIR/boot-times.json")" "1" "...and add nothing"
KEMPT_BOOT_ID=boot-next startup_boot_record_quietly
assert_eq "$(calls analyze | wc -l | tr -d ' '):$(jq -r '.[-1].boot_id' "$KEMPT_STATE_DIR/boot-times.json")" "2:boot-next" \
  "the next boot is asked once and recorded"
jq '[.[] | select(.boot_id != "boot-next")]' "$KEMPT_STATE_DIR/boot-times.json" > "$TESTTMP/bt" \
  && mv "$TESTTMP/bt" "$KEMPT_STATE_DIR/boot-times.json"

# Until startup has finished, systemd-analyze says "Bootup is not yet finished." and exits 1. Each
# check asks again (a few milliseconds), records nothing, and still succeeds.
reset_calls
mv "$SD/analyze" "$SD/analyze.later"
KEMPT_BOOT_ID=boot-early startup_boot_record_quietly; rc1=$?
KEMPT_BOOT_ID=boot-early startup_boot_record_quietly; rc2=$?
mv "$SD/analyze.later" "$SD/analyze"
assert_eq "$rc1:$rc2:$(jq '[.[] | select(.boot_id == "boot-early")] | length' "$KEMPT_STATE_DIR/boot-times.json")" "0:0:0" \
  "while startup is not yet finished, a check records nothing and succeeds"
assert_eq "$(calls analyze | tr '\n' ' ')" "time time " "...and each check asks systemd-analyze once more"

# A systemd-analyze that hangs costs the check no more than its deadline.
cat > "$TESTTMP/analyze-hang" <<'STUB'
#!/usr/bin/env bash
sleep 30
STUB
chmod +x "$TESTTMP/analyze-hang"
t0=$SECONDS
STARTUP_DEADLINE=$(( SECONDS + 1 )) KEMPT_SYSTEMD_ANALYZE_CMD="$TESTTMP/analyze-hang" KEMPT_BOOT_ID=boot-hang \
  startup_boot_record_quietly; rc=$?
took=$(( SECONDS - t0 ))
assert_eq "$rc:$(( took <= 3 )):$(jq '[.[] | select(.boot_id == "boot-hang")] | length' "$KEMPT_STATE_DIR/boot-times.json")" "0:1:0" \
  "a hanging systemd-analyze is cut off at the deadline, records nothing, and the check succeeds"

# The page and a check can record the same boot at once. Whichever writes last, the page's slowest
# unit stays: a check that read no entry for this boot, then finds the page's entry under the lock,
# merges into it.
cat > "$TESTTMP/analyze-race" <<'STUB'
#!/usr/bin/env bash
jq -c '. + [{boot_id: "boot-race", at: "2026-10-21T08:00:00Z", ready_sec: 6.117, userspace_sec: 180.996,
             total_sec: 199.596, slowest: {unit: "x.service", description: "X", sec: 9}}]' \
  "$KEMPT_STATE_DIR/boot-times.json" > "$KEMPT_STATE_DIR/bt.race" && mv "$KEMPT_STATE_DIR/bt.race" "$KEMPT_STATE_DIR/boot-times.json"
cat "$SD_DIR/analyze"
STUB
chmod +x "$TESTTMP/analyze-race"
KEMPT_SYSTEMD_ANALYZE_CMD="$TESTTMP/analyze-race" KEMPT_BOOT_ID=boot-race startup_boot_record_quietly
assert_json_eq "$(jq -c '[.[] | select(.boot_id == "boot-race") | [.ready_sec, .slowest.unit]]' "$KEMPT_STATE_DIR/boot-times.json")" \
  '[[6.117,"x.service"]]' "a check recording a boot the page has just recorded keeps its slowest unit, once"
assert_eq "$(jq -r '.[-1].boot_id' "$KEMPT_STATE_DIR/boot-times.json")" "boot-race" "...as the newest entry"
jq '[.[] | select(.boot_id != "boot-race")]' "$KEMPT_STATE_DIR/boot-times.json" > "$TESTTMP/bt" \
  && mv "$TESTTMP/bt" "$KEMPT_STATE_DIR/boot-times.json"
assert_contains "$(sed -n '/^cmd_check()/,/^}/p' "$KEMPT")" "startup_boot_record_quietly" "cmd_check calls it"
assert_eq "$(page | jq -r '.boot_time.slowest.unit')" 'systemd-fsck@dev-disk-by\x2duuid-655f.service' \
  "the page fills in the slowest unit later"

# A device's description is its /sys path; the page names it by its kernel name instead.
rm -f "$KEMPT_STATE_DIR/boot-times.json"
printf '4.007s sys-devices-pci0000:00-0000:00:03.0-virtio1-block-vda-vda3.device\n' > "$SD/blame"
printf 'Description=/sys/devices/pci0000:00/0000:00:03.0/virtio1/block/vda/vda3\n' \
  > "$SD/props-system/sys-devices-pci0000:00-0000:00:03.0-virtio1-block-vda-vda3.device"
assert_eq "$(page | jq -r '.boot_time.slowest.description')" "waiting for vda3" "a device is named by its kernel name"
jq '[.[] | .slowest.description = "/sys/devices/x/vda3"]' "$KEMPT_STATE_DIR/boot-times.json" > "$TESTTMP/bt" \
  && mv "$TESTTMP/bt" "$KEMPT_STATE_DIR/boot-times.json"
assert_eq "$(page | jq -r '.boot_time.slowest.description')" "waiting for vda3" "...in a boot recorded before too"

# The usual is a median, rounded to a tenth of a second.
jq -cn --arg y "$(date -u -d 'yesterday 23:40' +%FT%TZ)" --arg d "$(date -u -d 'today 00:10' +%FT%TZ)" '
  [{boot_id: "c1", at: "2026-10-15T08:00:00Z", ready_sec: 3.506, userspace_sec: 3.617},
   {boot_id: "c2", at: "2026-10-16T08:00:00Z", ready_sec: 3.505, userspace_sec: 3.656},
   {boot_id: "c3", at: $y, ready_sec: 3.505, userspace_sec: 3.617},
   {boot_id: "c4", at: $d, ready_sec: 3.506, userspace_sec: 3.656}]' > "$KEMPT_STATE_DIR/boot-times.json"
out="$(page)"
assert_json_eq "$(jq -c '.boot_time.usual' <<<"$out")" '{"ready_sec":3.5,"userspace_sec":3.6,"boots":4}' \
  "the usual times carry no float noise"
t="$(text)"
assert_contains "$t" "  Earlier starts:"$'\n'"    today 00:10: " "an earlier start today says today and its time"
assert_contains "$t" $'\n'"    yesterday 23:40: " "...one yesterday says yesterday"
assert_contains "$t" $'\n'"    16 Oct 08:00: " "...and an older one its date"

# Today, tomorrow and yesterday are calendar days, as in the widget: the days the clocks change
# are 23 and 25 hours long. America/New_York changes on 8 Mar and 1 Nov 2026.
rm -f "$SD/analyze" "$SD/blame" "$KEMPT_STATE_DIR/boot-times.json"
us() { echo "$(date -u -d "$1" +%s)000000"; }
jq -cn --argjson n "$(us 2026-03-08T15:00:00Z)" --argjson l "$(us 2026-11-01T00:00:00Z)" \
  '[{next: $n, last: null, unit: "a.timer", activates: "a.service"}, {next: null, last: $l, unit: "b.timer", activates: "b.service"}]' \
  > "$SD/timers-system.json"
t="$(TZ=America/New_York KEMPT_NOW="$(date -u -d 2026-03-08T04:30:00Z +%s)" text)"
assert_contains "$t" "(a.timer): next tomorrow 11:00" "late on the day before a 23-hour day, that morning is tomorrow"
t="$(TZ=America/New_York KEMPT_NOW="$(date -u -d 2026-11-02T04:30:00Z +%s)" text)"
assert_contains "$t" "(b.timer): last run yesterday 20:00" "late on a 25-hour day, the evening before is yesterday"
rm -f "$SD/timers-system.json"

finish
