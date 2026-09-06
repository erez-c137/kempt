#!/usr/bin/env bash
set -uo pipefail
shopt -s nullglob
cd "$(dirname "$0")" || exit 1
rc=0
files=(test_*.sh)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "NO TEST FILES MATCHED test_*.sh"
  exit 1
fi
# Where the test files record what they could not run. A green suite that skipped the widget's
# whole QML half used to print ALL PASS and nothing else, which is how a CI badge comes to mean
# less than the person reading it thinks.
KEMPT_TEST_SKIPS="$(mktemp)"; export KEMPT_TEST_SKIPS
trap 'rm -f "$KEMPT_TEST_SKIPS"' EXIT

for t in "${files[@]}"; do
  echo "== $t"
  bash "$t" || rc=1
done

skipped=$(grep -c . "$KEMPT_TEST_SKIPS" 2>/dev/null || true); skipped=${skipped:-0}
if [[ $rc -ne 0 ]]; then
  echo "FAILURES"
elif [[ $skipped -gt 0 ]]; then
  echo "ALL PASS - with $skipped skipped, so this run did not cover everything:"
  sed 's/^/    /' "$KEMPT_TEST_SKIPS"
else
  echo "ALL PASS"
fi
echo "ran ${#files[@]} test file(s)"
exit $rc
