#!/usr/bin/env bash
# The sandbox starts from a clean KEMPT_ environment: a value in the developer's shell must not
# reach a test, because an unset seam falls back to the real command or path. KEMPT_TEST_* is the
# suite's own control channel and survives.
source "$(dirname "$0")/lib.sh"

probe() {  # probe VAR → what the variable reads inside a fresh sandbox, with junk set in the caller
  env KEMPT_NOW=1 KEMPT_CRONTAB_CMD=/bin/false KEMPT_JOURNALCTL_CMD=/bin/false KEMPT_TEST_KEEP=kept \
    bash -c 'source "$1/tests/lib.sh"; sandbox; printf "%s" "${!2-UNSET}"' _ "$REPO_ROOT" "$1"
}
assert_eq "$(probe KEMPT_NOW)" "UNSET" "an inherited seam with no sandbox default is dropped"
assert_eq "$(probe KEMPT_CRONTAB_CMD)" "UNSET" "...whichever seam it is"
assert_eq "$(probe KEMPT_TEST_KEEP)" "kept" "the suite's own KEMPT_TEST_ controls are kept"
assert_contains "$(env KEMPT_NOTIFY=/bin/false bash -c 'source "$1/tests/lib.sh"; sandbox; printf "%s" "$KEMPT_NOTIFY"' _ "$REPO_ROOT")" "true" \
  "a value the sandbox sets itself wins over the caller's"
finish
