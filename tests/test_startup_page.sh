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
      printf 'Id=%s\nDescription=%s\nTransient=no\nActiveState=active\nLoadState=loaded\nResult=success\nFragmentPath=%s/files/%s/%s\nSourcePath=\n' "$u" "$u" "$d" "$dir" "$u" \
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
assert_eq "$(jq -c '[keys[] | select(IN("failed", "changed", "starts", "schedule", "boot_time"))]' <<<"$out")" "[]" \
  "with nothing to show, no section is in the answer"
assert_eq "$(calls journalctl)" "" "nothing failed, so the journal is never read"
assert_eq "$(calls rpm)" "" "nothing to group, so rpm is never asked"
assert_contains "$(text)" "Kempt found nothing to list." "the text says so in one line"
assert_eq "$(config_get startup_page)" "false" "the setting is off by default, and --all works anyway"
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
assert_eq "$(jq -r '.failed.journal_denied' <<<"$out")" "false" "the journal was readable"
assert_eq "$(calls journalctl | grep -c -- '-o json')" "2" "one journal query per scope, not one per unit"
t="$(text)"
assert_contains "$t" "Didn't start this boot:" "the text names the section"
assert_contains "$t" "  Bluetooth service (bluetooth.service)" "...lists the unit"
assert_contains "$t" "    No Bluetooth adapter found" "...with its log line"
assert_contains "$t" "    systemctl status bluetooth.service" "...and the command"
assert_contains "$t" "  IMSettings ($AUTOSTART), when you log in" "...and says which units are your session's"

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
rm -f "$SD/journal-denied" "$SD"/failed-*.json "$SD"/journal-*.json

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
  {"unit_file":"multi-user.target","state":"enabled"},{"unit_file":"backup.timer","state":"enabled"}]' > "$SD/enabled-system.json"
printf '%s\n' '[{"unit_file":"pipewire.service","state":"enabled"},{"unit_file":"pipewire.socket","state":"enabled"}]' > "$SD/enabled-user.json"
GEO="app-geoclue\\x2ddemo\\x2dagent$AT"
jq -cn --arg g "$GEO" --arg at "$AT" '[{unit: $g, load: "loaded", active: "active", description: "Geoclue Demo agent"},
                        {unit: ("app-hidden" + $at), load: "not-found", active: "inactive", description: "hidden"}]' > "$SD/autostart-user.json"
printf 'Description=OpenSSH server daemon\n' > "$SD/props-system/sshd.service"
printf 'Description=My own thing\nFragmentPath=%s/files/etc/mine.service\n' "$SD" > "$SD/props-system/mine.service"
printf 'Description=PipeWire Multimedia Service\n' > "$SD/props-user/pipewire.service"
printf 'SourcePath=%s/files/xdg/geoclue-demo-agent.desktop\nFragmentPath=/run/user/1000/systemd/generator.late/%s\n' "$SD" "$GEO" > "$SD/props-user/$GEO"
# rpm -qf prints nothing on stdout for a path that does not exist, so every path here is a file.
mkdir -p "$SD/files/system" "$SD/files/user" "$SD/files/etc" "$SD/files/xdg" "$TESTTMP/units"
touch "$SD/files/system/sshd.service" "$SD/files/etc/mine.service" "$SD/files/user/pipewire.service" \
      "$SD/files/xdg/geoclue-demo-agent.desktop" "$TESTTMP/units/getty@.service"
printf '%s\topenssh-server\n%s\tpipewire\n%s\tgeoclue2-demos\n%s\tsystemd\n' "$SD/files/system/sshd.service" \
  "$SD/files/user/pipewire.service" "$SD/files/xdg/geoclue-demo-agent.desktop" "$TESTTMP/units/getty@.service" > "$SD/owners"
export KEMPT_SYSTEM_UNIT_DIRS="$TESTTMP/units"
out="$(page)"
assert_json_eq "$(jq -c '[.starts[] | [.scope, .kind, .unit, .package]]' <<<"$out")" \
  "$(jq -cn --arg g "$GEO" '[["system","service","getty@.service","systemd"],["system","service","mine.service",null],
     ["system","service","sshd.service","openssh-server"],["user","autostart",$g,"geoclue2-demos"],
     ["user","service","pipewire.service","pipewire"]]')" \
  "services and autostart entries, each with the package that owns it; sockets, targets and timers are left out"
assert_eq "$(calls rpm | wc -l | tr -d ' ')" "1" "rpm is asked once for every unit"
assert_not_contains "$(calls systemctl)" "getty@.service" "a template is never handed to show, which refuses the whole call"
t="$(text)"
assert_contains "$t" "Starts with the computer:"$'\n'"  openssh-server"$'\n'"    OpenSSH server daemon (sshd.service)" \
  "the text groups by package"
assert_contains "$t" "  Not from a package"$'\n'"    My own thing (mine.service)" "...with units no package owns in their own group"
assert_contains "$t" "Starts when you log in:" "...and session services under their own heading"
assert_contains "$t" "    Geoclue Demo agent (autostart)" "...autostart entries named as such"

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
  '{"since":"2026-10-18T10:00:00+03:00","added":[{"scope":"system","unit":"backup.timer"},{"scope":"system","unit":"mine.service"}],"removed":[{"scope":"system","unit":"old.service"}]}' \
  "units enabled or no longer enabled since the last run's baseline; plumbing is left out"
assert_contains "$(text)" "Changed since the last update (18 Oct):"$'\n'"  Now starts: backup.timer"$'\n'"  Now starts: mine.service"$'\n'"  No longer starts: old.service" \
  "the text names what changed"
touch "$SD/down-user"
assert_eq "$(page | jq -c '[.changed.added[].scope] | unique')" '["system"]' "a scope that did not answer is not compared"
rm -f "$SD/down-user"

# --- runs on a schedule ---------------------------------------------------------------------------
reset_calls
printf '%s\n' '[{"next":1792540800000000,"last":1792454400000000,"unit":"backup.timer","activates":"backup.service"},
  {"next":1792540800000000,"last":null,"unit":"fstrim.timer","activates":"fstrim.service"},
  {"next":null,"last":null,"unit":"never.timer","activates":"never.service"}]' > "$SD/timers-system.json"
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
echo 20261020 > "$SPOOL/cron.daily"; touch -d '2026-10-20 03:12' "$SPOOL/cron.daily"
printf '5\tTue Oct 21 10:00:00 2026 a tester\n' > "$SD/atq"
out="$(page)"
assert_json_eq "$(jq -c '.schedule.timers[0]' <<<"$out")" \
  '{"scope":"system","unit":"backup.timer","activates":"backup.service","description":"Nightly backup","last":"2026-10-20T00:00:00Z","next":"2026-10-21T00:00:00Z","result":"exit-code"}' \
  "a timer carries its last and next run and the result of the service it starts"
assert_eq "$(jq -r '[.schedule.timers[].unit] | join(",")' <<<"$out")" "backup.timer,fstrim.timer,sync.timer" \
  "a timer that has never run and is not scheduled is left out"
assert_json_eq "$(jq -c '[.schedule.cron[] | [.source, .schedule, .user, .command]]' <<<"$out")" \
  '[["crontab","0 3 * * *",null,"/home/tester/bin/backup.sh >/dev/null"],["crontab","@reboot",null,"/home/tester/bin/hello"],
    ["/etc/crontab","*/5 * * * *","root","/usr/local/bin/poll"],["/etc/cron.d/raid-check","30 2 * * 0","root","/usr/sbin/raid-check"],
    ["cron.daily","daily",null,"logrotate"],["anacron","3",null,"/usr/local/bin/tidy"]]' \
  "cron jobs from every source; run-parts lines, 0anacron, comments, settings and package leftovers are not jobs"
assert_eq "$(jq -r '.schedule.cron[] | select(.source == "cron.daily") | .last' <<<"$out")" "2026-10-20T03:12:00Z" \
  "anacron's own record gives the last run of the daily scripts"
assert_eq "$(jq -c '.schedule.at' <<<"$out")" '[{"id":"5","when":"Tue Oct 21 10:00:00 2026"}]' "at jobs are listed"
assert_eq "$(jq -c '.schedule.notes' <<<"$out")" '[]' "crond running and lingering on: no notes"
t="$(text)"
assert_contains "$t" "Runs on a schedule:" "the text names the section"
assert_contains "$t" "    Nightly backup (backup.timer): last 20 Oct 00:00, next 21 Oct 00:00, the last run failed" \
  "...says when a timer ran, when it runs next, and that its last run failed"
assert_contains "$t" "    Discard unused blocks (fstrim.timer): next 21 Oct 00:00" "...and leaves out what is unknown"
assert_contains "$t" "    0 3 * * * /home/tester/bin/backup.sh >/dev/null (your crontab)" "...cron lines as written"
assert_contains "$t" "    logrotate: every day, last 20 Oct" "...the daily scripts in words"
printf 'ActiveState=inactive\n' > "$SD/props-system/crond.service"
rm -f "$LINGER/tester"
out="$(page)"
assert_eq "$(jq -c '.schedule.notes' <<<"$out")" '["crond_down","linger_off"]' "crond stopped and lingering off are both noted"
t="$(text)"
assert_contains "$t" "These jobs never run: crond is not running." "the crond note is in the text"
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
jq -cn '[{boot_id: "b1", at: "2026-10-15T08:00:00Z", ready_sec: 5, total_sec: 170},
         {boot_id: "b2", at: "2026-10-16T08:00:00Z", ready_sec: 7, total_sec: 175},
         {boot_id: "b3", at: "2026-10-17T08:00:00Z", ready_sec: 9, total_sec: 400}]' > "$KEMPT_STATE_DIR/boot-times.json"
out="$(page)"
assert_json_eq "$(jq -c '.boot_time | del(.recent)' <<<"$out")" \
  '{"ready_sec":6.117,"total_sec":180.996,"usual":{"ready_sec":7,"total_sec":175,"boots":3},"slowest":{"unit":"systemd-fsck@dev-disk-by\\x2duuid-655f.service","sec":92.362}}' \
  "this boot's times, the median of the boots Kempt recorded before it, and the slowest unit"
assert_eq "$(jq -r '[.boot_time.recent[].boot_id] | join(",")' <<<"$out")" "b3,b2,b1" "the recent boots, newest first"
assert_eq "$(jq -r '.[-1].boot_id' "$KEMPT_STATE_DIR/boot-times.json")" "boot-now" "this boot is recorded"
t="$(text)"
assert_contains "$t" "Startup time:"$'\n'"  Ready in 6 s; everything started in 3 min 1 s." "the text gives this boot's times"
assert_contains "$t" "  Usually ready in 7 s; everything in 2 min 55 s." "...and the usual"
assert_contains "$t" "  Slowest to start: systemd-fsck@dev-disk-by\\x2duuid-655f.service, 1 min 32 s." "...and names the slowest unit"
reset_calls
page >/dev/null
assert_eq "$(calls analyze)" "" "a boot already recorded is not asked again"
assert_eq "$(jq '[.[] | select(.boot_id == "boot-now")] | length' "$KEMPT_STATE_DIR/boot-times.json")" "1" "...and recorded once"

# The check records the time once per boot, without the slow blame, when the page is on.
reset_calls
rm -f "$KEMPT_STATE_DIR/boot-times.json"
startup_boot_record_if_on
assert_eq "$([[ -e "$KEMPT_STATE_DIR/boot-times.json" ]] && echo yes || echo no)" "no" "the check records nothing with the page off"
config_set startup_page true
startup_boot_record_if_on
assert_eq "$(jq -c '.[0] | [.boot_id, .ready_sec, has("slowest")]' "$KEMPT_STATE_DIR/boot-times.json")" '["boot-now",6.117,false]' \
  "with the page on, the check records this boot's times"
assert_not_contains "$(calls analyze)" "blame" "...and leaves the slowest unit to the page"
assert_contains "$(sed -n '/^cmd_check()/,/^}/p' "$KEMPT")" "startup_boot_record_if_on" "cmd_check calls it"
assert_eq "$(page | jq -r '.boot_time.slowest.unit')" 'systemd-fsck@dev-disk-by\x2duuid-655f.service' \
  "the page fills in the slowest unit later"

finish
