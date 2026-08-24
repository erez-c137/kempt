#!/usr/bin/env bash
set -uo pipefail
shopt -s nullglob
cd "$(dirname "$0")"
rc=0
for t in test_*.sh; do
  echo "== $t"
  bash "$t" || rc=1
done
[[ $rc -eq 0 ]] && echo "ALL PASS" || echo "FAILURES"
exit $rc
