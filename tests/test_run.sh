#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"

# EVERY assertion in this file is --dry-run: `kempt run` for real spawns a Konsole window (or a
# detached update), and a test suite must never launch either.

# The terminal emulator is a seam like every other one, so it is stubbed like every other one:
# cmd_run checks `command -v "$KEMPT_TERMINAL"` BEFORE printing the launch plan, so with the
# default (konsole) these assertions passed or failed according to what the box running the suite
# happened to have installed. A CI runner with a stripped PATH failed three of them.
export KEMPT_TERMINAL="$TESTTMP/stub-terminal"
printf '#!/usr/bin/env bash\nexit 0\n' > "$KEMPT_TERMINAL"; chmod +x "$KEMPT_TERMINAL"

# --dry-run prints the launch plan instead of spawning anything
"$KEMPT" config set surface terminal
assert_eq "$("$KEMPT" run --dry-run)" "terminal: $KEMPT_TERMINAL -e kempt update" "terminal plan"
"$KEMPT" config set surface background
assert_eq "$("$KEMPT" run --dry-run)" "detached: kempt update (surface=background)" "background plan"
"$KEMPT" config set surface popup
assert_eq "$("$KEMPT" run --dry-run)" "detached: kempt update (surface=popup)" "popup plan"
"$KEMPT" config set surface offline
assert_eq "$("$KEMPT" run --dry-run)" "detached: kempt update (surface=offline)" "offline plan"
# auto_accept=false forces terminal regardless of surface
"$KEMPT" config set auto_accept false
assert_eq "$("$KEMPT" run --dry-run)" "terminal: $KEMPT_TERMINAL -e kempt update" "no-auto-accept forces terminal"

# A mistyped flag must never be read as "go ahead and launch": this command's normal outcome is a
# real update, so an unrecognised argument has to stop before anything spawns.
assert_exit 2 "run: mistyped dry-run flag rejected" "$KEMPT" run --dryrun
assert_exit 2 "run: extra arguments rejected" "$KEMPT" run --dry-run extra

# An unknown surface (config typo, stale value from an older widget) falls back to the one surface
# that can always show a human what happened. auto_accept goes back to TRUE first, or the
# auto-accept guard would force terminal on its own and this would prove nothing.
"$KEMPT" config set auto_accept true
"$KEMPT" config set surface bogus
surferr="$("$KEMPT" run --dry-run 2>&1 >/dev/null)"
assert_eq "$("$KEMPT" run --dry-run 2>/dev/null)" "terminal: $KEMPT_TERMINAL -e kempt update" "unknown surface falls back to terminal"
grep -q "unknown surface 'bogus'" <<<"$surferr" && echo "ok: unknown surface warns on stderr" || { echo "FAIL: surface warning"; _fail=1; }

# No terminal emulator = the button does nothing, forever, silently. Fail loudly instead, and say
# how to fix it. Checked in --dry-run too: "what would happen" has to include "nothing".
#
# Pinned whole, not by substring, because this message is read almost entirely INSIDE THE WIDGET:
# a failed launch is reported in the popup in the CLI's own words. So it has to be a sentence
# first and a shell incantation second, and it has to name the two places the setting lives - the
# command, for someone in a terminal, and the control, for the person who has never opened one.
# The UX panel of 2026-09-05 rated the old wording ("konsole not found - install it or run: ...")
# a dead end for a first-timer, and a substring pin is what let it stay one.
"$KEMPT" config set surface terminal
assert_exit 4 "missing terminal emulator is a loud failure" \
  env KEMPT_TERMINAL=kempt-no-such-terminal "$KEMPT" run --dry-run
termerr="$(KEMPT_TERMINAL=kempt-no-such-terminal "$KEMPT" run --dry-run 2>&1 >/dev/null || true)"
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
# Everything above this line is --dry-run, which can only ever assert what a launch would look
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
ps -o pgid= -p \$\$ | tr -d ' ' > "$TESTTMP/term-pgid"
shift                                       # drop -e; what is left is: bash -c <script>
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
KEMPT_TERMINAL="$TESTTMP/stub-terminal-capture" "$KEMPT" run
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
at_prompt() { grep -q '^  curl$' "$TESTTMP/term-out" 2>/dev/null; }
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

# (d) the status the window leaves with is the UPDATE's. A check that fails must never turn a good
# run into a bad one, and a check that succeeds must never launder a failed one. The update lock is
# the cheapest deterministic non-zero: this test process holds it, so `kempt update` exits 3.
echo /dev/null > "$STDIN_PATH"
exec 7>"$KEMPT_STATE_DIR/lock"
flock -n 7 || { echo "FAIL: the test could not take the update lock"; _fail=1; }
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
exec 7>&-

# Nothing this file started may outlive it: a wrapper still sitting at a prompt would keep the
# sandbox open and show up in `ps` long after the suite said ALL PASS.
if [[ -e "$TESTTMP/term-pgid" ]]; then kill -TERM -"$(cat "$TESTTMP/term-pgid")" 2>/dev/null || true; fi

finish
