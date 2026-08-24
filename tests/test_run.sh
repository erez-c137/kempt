#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
UPKEEP="$REPO_ROOT/bin/upkeep"

# EVERY assertion in this file is --dry-run: `upkeep run` for real spawns a Konsole window (or a
# detached update), and a test suite must never launch either.

# The terminal emulator is a seam like every other one, so it is stubbed like every other one:
# cmd_run checks `command -v "$UPKEEP_TERMINAL"` BEFORE printing the launch plan, so with the
# default (konsole) these assertions passed or failed according to what the box running the suite
# happened to have installed. A CI runner with a stripped PATH failed three of them.
export UPKEEP_TERMINAL="$TESTTMP/stub-terminal"
printf '#!/usr/bin/env bash\nexit 0\n' > "$UPKEEP_TERMINAL"; chmod +x "$UPKEEP_TERMINAL"

# --dry-run prints the launch plan instead of spawning anything
"$UPKEEP" config set surface terminal
assert_eq "$("$UPKEEP" run --dry-run)" "terminal: $UPKEEP_TERMINAL -e upkeep update" "terminal plan"
"$UPKEEP" config set surface background
assert_eq "$("$UPKEEP" run --dry-run)" "detached: upkeep update (surface=background)" "background plan"
"$UPKEEP" config set surface popup
assert_eq "$("$UPKEEP" run --dry-run)" "detached: upkeep update (surface=popup)" "popup plan"
"$UPKEEP" config set surface offline
assert_eq "$("$UPKEEP" run --dry-run)" "detached: upkeep update (surface=offline)" "offline plan"
# auto_accept=false forces terminal regardless of surface
"$UPKEEP" config set auto_accept false
assert_eq "$("$UPKEEP" run --dry-run)" "terminal: $UPKEEP_TERMINAL -e upkeep update" "no-auto-accept forces terminal"

# A mistyped flag must never be read as "go ahead and launch": this command's normal outcome is a
# real update, so an unrecognised argument has to stop before anything spawns.
assert_exit 2 "run: mistyped dry-run flag rejected" "$UPKEEP" run --dryrun
assert_exit 2 "run: extra arguments rejected" "$UPKEEP" run --dry-run extra

# An unknown surface (config typo, stale value from an older widget) falls back to the one surface
# that can always show a human what happened. auto_accept goes back to TRUE first, or the
# auto-accept guard would force terminal on its own and this would prove nothing.
"$UPKEEP" config set auto_accept true
"$UPKEEP" config set surface bogus
surferr="$("$UPKEEP" run --dry-run 2>&1 >/dev/null)"
assert_eq "$("$UPKEEP" run --dry-run 2>/dev/null)" "terminal: $UPKEEP_TERMINAL -e upkeep update" "unknown surface falls back to terminal"
grep -q "unknown surface 'bogus'" <<<"$surferr" && echo "ok: unknown surface warns on stderr" || { echo "FAIL: surface warning"; _fail=1; }

# No terminal emulator = the button does nothing, forever, silently. Fail loudly instead, and say
# how to fix it. Checked in --dry-run too: "what would happen" has to include "nothing".
"$UPKEEP" config set surface terminal
assert_exit 4 "missing terminal emulator is a loud failure" \
  env UPKEEP_TERMINAL=upkeep-no-such-terminal "$UPKEEP" run --dry-run
termerr="$(UPKEEP_TERMINAL=upkeep-no-such-terminal "$UPKEEP" run --dry-run 2>&1 >/dev/null || true)"
grep -q 'config set surface background' <<<"$termerr" \
  && echo "ok: the error tells the user how to fix it" || { echo "FAIL: no remedy in the message"; _fail=1; }
finish
