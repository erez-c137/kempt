#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"

# EVERY assertion in this file is --print-command: `kempt run` for real spawns a Konsole window (or a
# detached update), and a test suite must never launch either.

# The terminal emulator is a seam like every other one, so it is stubbed like every other one:
# cmd_run checks `command -v "$KEMPT_TERMINAL"` BEFORE printing the launch plan, so with the
# default (konsole) these assertions passed or failed according to what the box running the suite
# happened to have installed. A CI runner with a stripped PATH failed three of them.
export KEMPT_TERMINAL="$TESTTMP/stub-terminal"
printf '#!/usr/bin/env bash\nexit 0\n' > "$KEMPT_TERMINAL"; chmod +x "$KEMPT_TERMINAL"

# --print-command prints the launch plan instead of spawning anything
"$KEMPT" config set surface terminal
assert_eq "$("$KEMPT" run --print-command)" "terminal: $KEMPT_TERMINAL -e kempt update" "terminal plan"
"$KEMPT" config set surface background
assert_eq "$("$KEMPT" run --print-command)" "detached: kempt update (surface=background)" "background plan"
"$KEMPT" config set surface popup
assert_eq "$("$KEMPT" run --print-command)" "detached: kempt update (surface=popup)" "popup plan"
"$KEMPT" config set surface offline
assert_eq "$("$KEMPT" run --print-command)" "detached: kempt update (surface=offline)" "offline plan"
# auto_accept=false forces terminal regardless of surface
"$KEMPT" config set auto_accept false
assert_eq "$("$KEMPT" run --print-command)" "terminal: $KEMPT_TERMINAL -e kempt update" "no-auto-accept forces terminal"

# A mistyped flag must never be read as "go ahead and launch": this command's normal outcome is a
# real update, so an unrecognised argument has to stop before anything spawns.
assert_exit 2 "run: mistyped dry-run flag rejected" "$KEMPT" run --dryrun
assert_exit 2 "run: extra arguments rejected" "$KEMPT" run --print-command extra

# --- --dry-run: the old spelling, accepted for one release and advertised nowhere ----------------
# The flag printed the LAUNCHER, never a transaction, so "dry run" promised a preview of an update
# that was never coming - the one thing a person would reach for it to get. It is --print-command
# now, which says what it actually does.
# The old spelling still works, because scripts and muscle memory have it, and it is deliberately
# absent from the usage text and the man page: accepted, not offered. Both halves are asserted,
# because an alias nobody removes and nobody documents is just a second name to keep working.
"$KEMPT" config set auto_accept true
"$KEMPT" config set surface terminal
assert_eq "$("$KEMPT" run --dry-run)" "terminal: $KEMPT_TERMINAL -e kempt update" \
  "--dry-run still does what it always did"
assert_eq "$("$KEMPT" run --dry-run)" "$("$KEMPT" run --print-command)" \
  "...and exactly what the new spelling does"
assert_eq "$("$KEMPT" help | grep -c -- '--print-command')" "1" \
  "the usage text offers the new spelling"
assert_eq "$("$KEMPT" help | grep -ci dry)" "0" \
  "...and does not offer the old one"
assert_eq "$(grep -ci dry "$REPO_ROOT/docs/man/kempt.1")" "0" \
  "...and neither does the man page"

# An unknown surface (config typo, stale value from an older widget) falls back to the one surface
# that can always show a human what happened. auto_accept goes back to TRUE first, or the
# auto-accept guard would force terminal on its own and this would prove nothing.
"$KEMPT" config set auto_accept true
"$KEMPT" config set surface bogus
surferr="$("$KEMPT" run --print-command 2>&1 >/dev/null)"
assert_eq "$("$KEMPT" run --print-command 2>/dev/null)" "terminal: $KEMPT_TERMINAL -e kempt update" "unknown surface falls back to terminal"
grep -q "unknown surface 'bogus'" <<<"$surferr" && echo "ok: unknown surface warns on stderr" || { echo "FAIL: surface warning"; _fail=1; }

# No terminal emulator = the button does nothing, forever, silently. Fail loudly instead, and say
# how to fix it. Checked in --print-command too: "what would happen" has to include "nothing".
#
# Pinned whole, not by substring, because this message is read almost entirely INSIDE THE WIDGET:
# a failed launch is reported in the popup in the CLI's own words. So it has to be a sentence
# first and a shell incantation second, and it has to name the two places the setting lives - the
# command, for someone in a terminal, and the control, for the person who has never opened one.
# The old wording ("konsole not found - install it or run: ...") was a dead end for a first-timer,
# and a substring pin is what let it stay one.
"$KEMPT" config set surface terminal
assert_exit 4 "missing terminal emulator is a loud failure" \
  env KEMPT_TERMINAL=kempt-no-such-terminal "$KEMPT" run --print-command
termerr="$(KEMPT_TERMINAL=kempt-no-such-terminal "$KEMPT" run --print-command 2>&1 >/dev/null || true)"
assert_eq "$termerr" \
  "Kempt could not find kempt-no-such-terminal. Install it, or run updates another way: kempt config set surface background (Settings > Run updates in > In the background)" \
  "the error names the emulator, the command and the control that change it"

# --- the terminal run ends the widget's updating state, however that window exits ---------------
#
# The widget leaves its updating state on exactly ONE event: state.json changing under its watcher
# (plasmoid/contents/ui/main.qml, pollWatch). Its own periodic checks re-baseline that watcher
# rather than ending a run, and the only other way out is a three-hour guard. So a terminal run
# that exits without rewriting state.json parks the popup on an empty "Updating…" pane - no list,
# no Update Now, no Refresh - for up to three hours. Two everyday exits used to do exactly that:
# answering the risky-transaction prompt with its default (abort exits 0 BEFORE cmd_update's own
# post-run check) and closing the window mid-run. Hence the wrapper re-checks on every exit path,
# and the four assertions below are that promise, one exit path each.
#
# Everything above this line is --print-command, which can only ever assert what a launch would look
# like. These run the wrapper for real, so they need the same offline stubs a check needs.
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
case "\$1" in
  check) cat "$FIXTURES/dnf-check-update.txt"; exit 100 ;;
  refresh) exit 0 ;;
esac
STUB
chmod +x "$TESTTMP/refresh-stub"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_DNF_INSTALLED_CMD="cat $FIXTURES/rpm-installed.tsv"
export KEMPT_SKIP_REFRESH=1
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"; chmod +x "$TESTTMP/dnf-reboot-no"
export KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no"
"$KEMPT" config set include_flatpak false   # no flatpak stubs needed: the check under test is dnf's

EVENTS="$KEMPT_STATE_DIR/events.log"
STATE="$KEMPT_STATE_DIR/state.json"
STDIN_PATH="$TESTTMP/term-stdin"            # where the launched window's stdin comes from, per case
echo /dev/null > "$STDIN_PATH"

# A terminal stub that RUNS what it was handed instead of pretending to, and records enough for the
# assertions to be about behaviour: the script itself, the exit status the window left with, and
# the process GROUP - because that is what closing a terminal window signals, konsole's child shell
# and everything it started, not one pid. setsid put this stub at the head of its own group.
cat > "$TESTTMP/stub-terminal-run" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$TESTTMP/term-argv"
# The process GROUP without ps: procps-ng is not in Fedora's minimal buildroot and %check runs
# there, so a suite that needs ps makes every package build fail. Field 5 of /proc/self/stat is
# the pgrp; the comm field before it is parenthesised and can contain spaces, so the prefix is
# dropped up to the closing paren rather than counted through.
{ read -r st < /proc/self/stat; st=\${st#*") "}; st=\${st#* }; st=\${st#* }
  printf '%s\n' "\${st%% *}"; } > "$TESTTMP/term-pgid"
shift                                       # drop -e; what is left is: bash -c <script>
# The update lock, taken INSIDE the window when asked for. \`kempt run\` refuses before it launches
# anything while the lock is held, so a case that needs the update itself to meet the lock has to
# take it after the launch. fd 5 is inherited by the script, so the lock lasts the whole window.
if [[ -e "$TESTTMP/term-lock" ]]; then exec 5>"$KEMPT_STATE_DIR/lock"; flock -n 5; fi
rc=0
"\$@" <"\$(cat "$STDIN_PATH")" >"$TESTTMP/term-out" 2>&1 || rc=\$?
printf '%s\n' "\$rc" > "$TESTTMP/term-rc"
STUB
chmod +x "$TESTTMP/stub-terminal-run"

# The same stub without the running: (a) is about the string handed over, and a capture that
# executes nothing keeps a failure there unambiguous.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s"\n' "$TESTTMP/term-argv" \
  > "$TESTTMP/stub-terminal-capture"
chmod +x "$TESTTMP/stub-terminal-capture"

# `kempt run` detaches and returns, so every assertion here has to wait for the window it launched.
# Polling with a ceiling rather than a fixed sleep: fast where it can be, a failure rather than a
# hang where it cannot.
wait_until() {  # predicate... - true within ~15s
  local i
  for ((i = 0; i < 150; i++)); do "$@" && return 0; sleep 0.1; done
  return 1
}
launched()  { [[ -e "$TESTTMP/term-argv" ]]; }
finished()  { [[ -e "$TESTTMP/term-rc" ]]; }
# The inode, not the mtime: write_state goes through atomic_write, so a rewrite REPLACES the file.
# mtime has one-second granularity on some filesystems and these runs finish inside one second.
state_inode() { stat -c %i "$STATE" 2>/dev/null || echo none; }
check_events() { grep -c ' check ' "$EVENTS" 2>/dev/null || true; }
reset_capture() { rm -f "$TESTTMP/term-argv" "$TESTTMP/term-rc" "$TESTTMP/term-out" "$TESTTMP/term-pgid"; }

"$KEMPT" config set surface terminal
"$KEMPT" config set auto_accept true

# (a) the string the terminal is handed carries the check, on the exit path rather than only after
# a clean update.
reset_capture
# This stub never runs the script, so `kempt run` rightly reports that the window never started
# (see "a launch that did not happen" below). Its status is not what (a) is about.
KEMPT_TERMINAL="$TESTTMP/stub-terminal-capture" KEMPT_RUN_START_WAIT=1 "$KEMPT" run 2>/dev/null || true
wait_until launched && echo "ok: the terminal was launched" \
  || { echo "FAIL: the terminal stub was never launched"; _fail=1; }
argv="$(cat "$TESTTMP/term-argv" 2>/dev/null || true)"
grep -q "check" <<<"$argv" \
  && echo "ok: the launched script re-checks" || { echo "FAIL: no check in the launched script"; echo "  got: $argv"; _fail=1; }
grep -qE "trap .*EXIT" <<<"$argv" \
  && echo "ok: the check is on an EXIT trap" || { echo "FAIL: no EXIT trap in the launched script"; echo "  got: $argv"; _fail=1; }
grep -qE "trap .*HUP INT TERM" <<<"$argv" \
  && echo "ok: HUP, INT and TERM are trapped too" || { echo "FAIL: no signal traps in the launched script"; echo "  got: $argv"; _fail=1; }

export KEMPT_TERMINAL="$TESTTMP/stub-terminal-run"

# (b) the abort. Not a simulation of one: KEMPT_RISKY_RE makes curl session-critical, so the REAL
# risky prompt is asked, and stdin at /dev/null answers it the way Enter and Ctrl-D do - with the
# default. cmd_update exits 0 there, before its own post-run check, having written nothing at all.
export KEMPT_RISKY_RE='^curl'
export KEMPT_ASSUME_TTY=1
"$KEMPT" check >/dev/null            # a state.json and an events.log to compare against
before_inode="$(state_inode)"; before_events="$(check_events)"
reset_capture
echo /dev/null > "$STDIN_PATH"
"$KEMPT" run
wait_until finished && echo "ok: the aborted window closed" \
  || { echo "FAIL: the aborted window never finished"; _fail=1; }
grep -q "aborted" "$TESTTMP/term-out" 2>/dev/null \
  && echo "ok: it really was the risky prompt's abort" \
  || { echo "FAIL: the run under test did not abort at the prompt"; sed 's/^/    /' "$TESTTMP/term-out" 2>/dev/null; _fail=1; }
assert_eq "$(cat "$TESTTMP/term-rc")" "0" "an aborted run leaves the window with the update's 0"
assert_eq "$([[ "$(state_inode)" != "$before_inode" ]] && echo rewritten || echo untouched)" \
  "rewritten" "an abort still rewrites state.json, so the widget's updating state ends"
assert_eq "$([[ "$(check_events)" -gt "$before_events" ]] && echo logged || echo silent)" \
  "logged" "and the check it ran is in the events log"

# (c) the window closed while the question is still on screen. The prompt reads from a FIFO nothing
# ever writes to, so `kempt update` sits at it exactly as it does while a person reads the
# recommendation; then the process group is SIGHUPed, which is what closing the window does.
# Read-write on the FIFO deliberately: opening one for writing ALONE blocks until a reader arrives,
# which is a deadlock against a window that has not started yet.
mkfifo "$TESTTMP/prompt-fifo"
exec 6<>"$TESTTMP/prompt-fifo"
echo "$TESTTMP/prompt-fifo" > "$STDIN_PATH"
before_inode="$(state_inode)"; before_events="$(check_events)"
reset_capture
"$KEMPT" run
# The question itself never reaches this file: bash prints a `read -p` prompt only when stdin is
# a terminal, and here it is a FIFO. The one-name package listing printed immediately before the
# read is the last thing that does, so it is what "the window is waiting" looks like from out here.
# Losing the last microseconds of that race would not weaken the assertion either - SIGHUP to the
# group kills whatever `kempt update` is doing, and the trap under test fires either way.
at_prompt() { grep -q '^      curl$' "$TESTTMP/term-out" 2>/dev/null; }
wait_until at_prompt && echo "ok: the window is waiting at the risky question" \
  || { echo "FAIL: the window never reached the risky question"; sed 's/^/    /' "$TESTTMP/term-out" 2>/dev/null; _fail=1; }
kill -HUP -"$(cat "$TESTTMP/term-pgid")" 2>/dev/null || true
# The check writes state.json and THEN appends its event line, and SIGHUP took the stub with the
# window, so there is no term-rc to wait for here: waiting on the inode alone read the events log
# in the gap between the two writes on a slow runner (CI, 2026-09-05). Wait for the line, which is
# the later of the two, then the inode is a plain assertion.
logged_check() { [[ "$(check_events)" -gt "$before_events" ]]; }
wait_until logged_check && echo "ok: the check after a closed window is in the events log too" \
  || { echo "FAIL: SIGHUP left no check in the events log - the widget would spin for three hours"; _fail=1; }
assert_eq "$([[ "$(state_inode)" != "$before_inode" ]] && echo rewritten || echo untouched)" \
  "rewritten" "a closed window still rewrites state.json"
exec 6>&-

# (c2) the same close, with a check that takes TIME - which is the only kind a real box has.
# Case (c) passes with the recovery check in the terminal's own process group, because the check
# here answers instantly. A real one talks to dnf and takes seconds, and closing a window SIGHUPs
# the group and then SIGKILLs whatever is still in it moments later: the check is killed
# mid-flight, state.json is never rewritten, and the popup sits on an empty updating pane for the
# three hours until its watchdog gives up. Measured on a real machine, and this is the case that
# was missing - so the check is detached into a session of its own, where the teardown cannot
# reach it.
slow_installed="$TESTTMP/slow-installed"
printf '#!/usr/bin/env bash\nsleep 3\nprintf "curl\\t8.9.1-1.fc44\\n"\n' > "$slow_installed"
chmod +x "$slow_installed"
echo /dev/null > "$STDIN_PATH"
before_inode="$(state_inode)"; before_events="$(check_events)"
reset_capture
KEMPT_DNF_INSTALLED_CMD="$slow_installed" "$KEMPT" run
for _ in $(seq 1 200); do [[ -s "$TESTTMP/term-pgid" ]] && break; sleep 0.05; done
sleep 0.5
pg="$(cat "$TESTTMP/term-pgid" 2>/dev/null)"
if [[ -n "$pg" ]]; then
  kill -HUP -"$pg" 2>/dev/null || true
  sleep 0.2
  kill -KILL -"$pg" 2>/dev/null || true      # what a terminal emulator does to a lingering group
  logged_check() { [[ "$(check_events)" -gt "$before_events" ]]; }
  wait_until logged_check \
    && echo "ok: a check that takes time still lands after the window is killed" \
    || { echo "FAIL: the recovery check died with the window - the popup would spin for three hours"; _fail=1; }
  assert_eq "$([[ "$(state_inode)" != "$before_inode" ]] && echo rewritten || echo untouched)" \
    "rewritten" "...and state.json is rewritten, which is what ends the popup's updating state"
else
  echo "FAIL: the terminal stub never recorded its process group"; _fail=1
fi

# (d) the status the window leaves with is the UPDATE's. A check that fails must never turn a good
# run into a bad one, and a check that succeeds must never launder a failed one. The update lock is
# the cheapest deterministic non-zero: the window takes it before the script starts, so
# `kempt update` exits 3. Inside the window rather than in this process, because `kempt run` itself
# refuses to launch anything while the lock is already held.
echo /dev/null > "$STDIN_PATH"
touch "$TESTTMP/term-lock"
before_inode="$(state_inode)"; before_events="$(check_events)"
reset_capture
env -u KEMPT_ASSUME_TTY "$KEMPT" run    # no tty, no prompt: this run reaches the lock
wait_until finished && echo "ok: the locked-out window closed" \
  || { echo "FAIL: the locked-out window never finished"; _fail=1; }
assert_eq "$(cat "$TESTTMP/term-rc")" "3" "the wrapper exits with the update's status, not the check's"
assert_eq "$([[ "$(state_inode)" != "$before_inode" ]] && echo rewritten || echo untouched)" \
  "rewritten" "a failed run rewrites state.json too"
assert_eq "$([[ "$(check_events)" -gt "$before_events" ]] && echo logged || echo silent)" \
  "logged" "and logs its check"
rm -f "$TESTTMP/term-lock"

# --- a launch that did not happen is not a run --------------------------------------------------
#
# `kempt run` hands the update to a terminal window and returns. When the emulator cannot open that
# window (an SSH session with no display, a broken or half-upgraded install), the update inside it
# never begins, and nothing used to record that: `kempt run` said 0, no event was written, and the
# widget sat on its updating pane until the three-hour guard. The window now claims a start token
# as its very first action, and `kempt run` waits for that claim.
history_count() { find "$KEMPT_STATE_DIR/history" -type f 2>/dev/null | wc -l; }
run_starts() { grep -c ' run start ' "$EVENTS" 2>/dev/null || true; }

# (e) the emulator exits with an error straight away.
printf '#!/usr/bin/env bash\necho "could not connect to display" >&2\nexit 1\n' > "$TESTTMP/stub-terminal-fail"
chmod +x "$TESTTMP/stub-terminal-fail"
reset_capture
rc=0; t0=$SECONDS
launcherr="$(KEMPT_TERMINAL="$TESTTMP/stub-terminal-fail" KEMPT_RUN_START_WAIT=10 "$KEMPT" run 2>&1 >/dev/null)" || rc=$?
assert_eq "$rc" "5" "a terminal that fails to open is a run that did not start (exit 5)"
assert_eq "$(( SECONDS - t0 < 5 ))" "1" "...reported as soon as the emulator exits, not after the whole wait"
grep -q "stub-terminal-fail" <<<"$launcherr" && echo "ok: ...and the message names the emulator" \
  || { echo "FAIL: the launch failure does not name the emulator"; echo "  got: $launcherr"; _fail=1; }
grep -q "run did not start: .*stub-terminal-fail" "$EVENTS" && echo "ok: ...and the event log records it" \
  || { echo "FAIL: no event for a window that never opened"; tail -3 "$EVENTS" | sed 's/^/    /'; _fail=1; }
assert_eq "$(find "$KEMPT_STATE_DIR" -maxdepth 1 -name 'run-start.*' | wc -l)" "0" "...and no start token is left behind"

# (f) the emulator hands the window to another process and exits 0, and the window turns up after
# `kempt run` has already said it did not start. That late window must not start an update behind
# the report: the claim on the token is atomic, so exactly one side wins it.
cat > "$TESTTMP/stub-terminal-late" <<STUB
#!/usr/bin/env bash
shift
( sleep 2; rc=0; "\$@" </dev/null >"$TESTTMP/term-out" 2>&1 || rc=\$?; printf '%s\n' "\$rc" > "$TESTTMP/term-rc" ) >/dev/null 2>&1 &
exit 0
STUB
chmod +x "$TESTTMP/stub-terminal-late"
reset_capture
before_events="$(check_events)"; before_hist="$(history_count)"; before_starts="$(run_starts)"
rc=0; KEMPT_TERMINAL="$TESTTMP/stub-terminal-late" KEMPT_RUN_START_WAIT=1 "$KEMPT" run 2>/dev/null || rc=$?
assert_eq "$rc" "5" "a window that never arrives within the wait is a run that did not start"
wait_until finished && echo "ok: the late window did open, after the report" \
  || { echo "FAIL: the late window never finished"; _fail=1; }
grep -q "not started" "$TESTTMP/term-out" 2>/dev/null && echo "ok: ...and says the update was not started" \
  || { echo "FAIL: the late window did not say it stood down"; sed 's/^/    /' "$TESTTMP/term-out" 2>/dev/null; _fail=1; }
assert_eq "$(run_starts)|$(history_count)|$(check_events)" "$before_starts|$before_hist|$before_events" \
  "...and ran nothing: no update, no history entry, no check"

# (g) the same hand-off, arriving inside the wait, is an ordinary run.
sed -i 's/sleep 2;/sleep 0.3;/' "$TESTTMP/stub-terminal-late"
reset_capture
rc=0; KEMPT_TERMINAL="$TESTTMP/stub-terminal-late" KEMPT_RUN_START_WAIT=10 "$KEMPT" run || rc=$?
assert_eq "$rc" "0" "a handed-off window that arrives in time is a run that started"
wait_until finished && grep -q "aborted" "$TESTTMP/term-out" 2>/dev/null \
  && echo "ok: ...and the update inside it really ran (to the risky prompt)" \
  || { echo "FAIL: the handed-off window did not run the update"; sed 's/^/    /' "$TESTTMP/term-out" 2>/dev/null; _fail=1; }

# --- a run while another update holds the lock ---------------------------------------------------
#
# The refusal used to happen inside the launched window or the detached shell, where nobody reads
# the status, so `kempt run` returned 0 and the widget that lost the race entered its updating pane
# for a run that was never going to happen. Refused before anything is launched, the widget gets
# the exit 3 it already knows how to show.
exec 7>"$KEMPT_STATE_DIR/lock"
flock -n 7 || { echo "FAIL: the test could not take the update lock"; _fail=1; }
reset_capture
rc=0; lockerr="$("$KEMPT" run 2>&1 >/dev/null)" || rc=$?
assert_eq "$rc" "3" "with an update holding the lock, a terminal run is refused (exit 3)"
assert_eq "$lockerr" "An update is already running." "...in a sentence the widget can show as it is"
sleep 0.5
assert_eq "$([[ -e "$TESTTMP/term-argv" ]] && echo launched || echo nothing)" "nothing" "...and no window is opened"
"$KEMPT" config set surface background
rc=0; "$KEMPT" run 2>/dev/null || rc=$?
assert_eq "$rc" "3" "a background run is refused the same way"
exec 7>&-
"$KEMPT" config set surface terminal

# Nothing this file started may outlive it: a wrapper still sitting at a prompt would keep the
# sandbox open and show up in `ps` long after the suite said ALL PASS.
if [[ -e "$TESTTMP/term-pgid" ]]; then kill -TERM -"$(cat "$TESTTMP/term-pgid")" 2>/dev/null || true; fi

finish
