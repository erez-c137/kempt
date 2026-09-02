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
"$KEMPT" config set surface terminal
assert_exit 4 "missing terminal emulator is a loud failure" \
  env KEMPT_TERMINAL=kempt-no-such-terminal "$KEMPT" run --dry-run
termerr="$(KEMPT_TERMINAL=kempt-no-such-terminal "$KEMPT" run --dry-run 2>&1 >/dev/null || true)"
grep -q 'config set surface background' <<<"$termerr" \
  && echo "ok: the error tells the user how to fix it" || { echo "FAIL: no remedy in the message"; _fail=1; }
finish
