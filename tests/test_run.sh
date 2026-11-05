#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"

# Nearly every assertion in this file is --print-command, since `kempt run` for real starts a
# detached update. The lock cases below refuse before anything is started.

# --print-command prints the launch plan instead of spawning anything
# Configs from when `background` and `terminal` were surfaces of their own run in the widget.
mkdir -p "$KEMPT_CONFIG_DIR"
for old in background terminal; do
  printf 'surface=%s\n' "$old" > "$KEMPT_CONFIG_DIR/config"
  assert_eq "$("$KEMPT" run --print-command)" "detached: kempt update --answered (surface=widget)" "a saved $old runs in the widget"
  assert_eq "$("$KEMPT" config get surface)" "popup" "...and reads as such"
  assert_eq "$("$KEMPT" run --print-command --surface=$old)" "detached: kempt update --answered (surface=widget)" \
    "...and so does a script that names it"
  "$KEMPT" config set surface "$old" 2>"$TESTTMP/old.err"
  assert_eq "$(grep '^surface=' "$KEMPT_CONFIG_DIR/config")|$(cat "$TESTTMP/old.err")" "surface=popup|" \
    "...and setting it stores the widget, with no warning"
done
"$KEMPT" config set surface popup
assert_eq "$("$KEMPT" run --print-command)" "detached: kempt update --answered (surface=widget)" "popup plan"
# --risky-ok, after Install Now in the popup, reaches the detached update and nothing else.
assert_eq "$("$KEMPT" run --print-command --risky-ok)" "detached: kempt update --answered --risky-ok (surface=widget)" \
  "Install Now passes --risky-ok on to a detached update"
"$KEMPT" config set surface offline
assert_eq "$("$KEMPT" run --print-command)" "detached: kempt update --answered (surface=offline)" "offline plan"
# With nobody at a terminal, auto_accept=false has nobody to ask, and the press was the answer.
"$KEMPT" config set auto_accept false
assert_eq "$("$KEMPT" run --print-command)" "detached: kempt update --answered (surface=offline)" "auto_accept=false starts the same run"
"$KEMPT" config set auto_accept true

# A mistyped flag must never be read as "go ahead and launch": this command's normal outcome is a
# real update, so an unrecognised argument has to stop before anything spawns.
assert_exit 2 "run: mistyped dry-run flag rejected" "$KEMPT" run --dryrun
assert_exit 2 "run: extra arguments rejected" "$KEMPT" run --print-command extra

# --- --print-command, and only that spelling --------------------------------------------------
assert_exit 2 "--dry-run is not an option" "$KEMPT" run --dry-run
assert_eq "$("$KEMPT" help | grep -c -- '--print-command' | awk '{print ($1 >= 1)}')" "1" \
  "the usage text offers it"
assert_eq "$("$KEMPT" help | grep -ci dry)" "0" \
  "...and does not offer the old one"

# An unknown surface (config typo, stale value from an older widget) falls back to the widget and
# never to a stage.
"$KEMPT" config set surface bogus
surferr="$("$KEMPT" run --print-command 2>&1 >/dev/null)"
assert_eq "$("$KEMPT" run --print-command 2>/dev/null)" "detached: kempt update --answered (surface=widget)" "unknown surface falls back to the widget"
assert_contains "$surferr" "surface='bogus' is not a known value, so updates run in the widget" "unknown surface warns on stderr"

# `widget` is the other name for the stored `popup`: a hand-written surface=widget, and
# --surface=widget, both run detached in the widget.
sed -i 's/^surface=.*/surface=widget/' "$KEMPT_CONFIG_DIR/config"
assert_eq "$("$KEMPT" run --print-command 2>&1)" "detached: kempt update --answered (surface=widget)" \
  "a hand-written surface=widget runs in the widget, with no warning"
assert_eq "$("$KEMPT" run --print-command --surface=Widget 2>&1)" "detached: kempt update --answered (surface=widget)" \
  "--surface=widget is accepted as the widget"

# --- --surface=<s>: one run on a named surface, whatever the setting says -----------------------
# The widget stages through this (`kempt run --surface=offline`) so that a stage gets the same
# up-front refusals Update Now does - the lock above all - instead of a detached `kempt update`
# whose exit status nobody reads.
"$KEMPT" config set surface widget
assert_eq "$("$KEMPT" run --print-command --surface=offline)" "detached: kempt update --answered (surface=offline)" \
  "--surface=offline stages detached on a box configured for the widget"
assert_eq "$("$KEMPT" run --surface=offline --print-command)" "detached: kempt update --answered (surface=offline)" \
  "...with the flags in either order"
"$KEMPT" config set surface offline
assert_eq "$("$KEMPT" run --print-command --surface=' Popup ')" "detached: kempt update --answered (surface=widget)" \
  "...a surface is read the way the setting is, trimmed and case-folded"
# A surface named on the command line is a request, not a stored value, so a typo is refused
# rather than quietly turned into the widget the way a mistyped setting is.
rc=0; surferr="$("$KEMPT" run --print-command --surface=bogus 2>&1 >/dev/null)" || rc=$?
assert_eq "$rc" "2" "run: an unknown --surface is refused (exit 2)"
assert_eq "$surferr" "unknown --surface value: bogus (use widget or offline)" \
  "...naming the surfaces there are"
assert_exit 2 "run: an empty --surface is refused" "$KEMPT" run --print-command --surface=
assert_exit 2 "run: --surface given twice is refused" \
  "$KEMPT" run --print-command --surface=offline --surface=widget

# --- a run while another update holds the lock ---------------------------------------------------
#
# The refusal used to happen inside the detached shell, where nobody reads the status, so
# `kempt run` returned 0 and the widget that lost the race entered its updating pane for a run that
# was never going to happen. Refused before anything is launched, the widget gets the exit 3 it
# already knows how to show.
"$KEMPT" config set surface widget
exec 7>"$KEMPT_STATE_DIR/lock"
flock -n 7 || { echo "FAIL: the test could not take the update lock"; _fail=1; }
rc=0; lockerr="$("$KEMPT" run 2>&1 >/dev/null)" || rc=$?
assert_eq "$rc" "3" "with an update holding the lock, a run is refused (exit 3)"
assert_eq "$lockerr" "An update is already running." "...in a sentence the widget can show as it is"
# ...and so is a stage asked for by name, which is how the widget's Install on Next Restart reaches
# the CLI.
rc=0; lockerr="$("$KEMPT" run --surface=offline 2>&1 >/dev/null)" || rc=$?
assert_eq "$rc" "3" "a stage asked for with --surface=offline is refused the same way"
assert_eq "$lockerr" "An update is already running." "...in the same sentence"
exec 7>&-

# The line that says what the pause is prints only to a terminal, so it is read from the source: it
# must come before the update's closing check, not after it.
assert_eq "$(grep -A1 -F "&& printf" "$REPO_ROOT/bin/kempt" | grep -A1 -F "left to update" | tail -1 | tr -d ' ')" \
  "cmd_check>/dev/null2>&1||true" "the update says it is checking, right before it checks"

finish
