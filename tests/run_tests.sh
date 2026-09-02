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
for t in "${files[@]}"; do
  echo "== $t"
  bash "$t" || rc=1
done
[[ $rc -eq 0 ]] && echo "ALL PASS" || echo "FAILURES"
echo "ran ${#files[@]} test file(s)"
exit $rc
