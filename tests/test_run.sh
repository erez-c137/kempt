#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
UPKEEP="$REPO_ROOT/bin/upkeep"

# EVERY assertion in this file is --dry-run: `upkeep run` for real spawns a Konsole window (or a
# detached update), and a test suite must never launch either.

# --dry-run prints the launch plan instead of spawning anything
"$UPKEEP" config set surface terminal
assert_eq "$("$UPKEEP" run --dry-run)" "terminal: konsole -e upkeep update" "terminal plan"
"$UPKEEP" config set surface background
assert_eq "$("$UPKEEP" run --dry-run)" "detached: upkeep update (surface=background)" "background plan"
"$UPKEEP" config set surface popup
assert_eq "$("$UPKEEP" run --dry-run)" "detached: upkeep update (surface=popup)" "popup plan"
"$UPKEEP" config set surface offline
assert_eq "$("$UPKEEP" run --dry-run)" "detached: upkeep update (surface=offline)" "offline plan"
# auto_accept=false forces terminal regardless of surface
"$UPKEEP" config set auto_accept false
assert_eq "$("$UPKEEP" run --dry-run)" "terminal: konsole -e upkeep update" "no-auto-accept forces terminal"

# A mistyped flag must never be read as "go ahead and launch": this command's normal outcome is a
# real update, so an unrecognised argument has to stop before anything spawns.
assert_exit 2 "run: mistyped dry-run flag rejected" "$UPKEEP" run --dryrun
assert_exit 2 "run: extra arguments rejected" "$UPKEEP" run --dry-run extra
finish
