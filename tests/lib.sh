#!/usr/bin/env bash
# Test helpers. Source me. Each test file runs in its own sandbox HOME.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO_ROOT/tests/fixtures"
_fail=0

sandbox() {  # fresh dirs per test file; call first
  TESTTMP="$(mktemp -d "${TMPDIR:-/tmp}/upkeep-test.XXXXXX")"
  export UPKEEP_CONFIG_DIR="$TESTTMP/config"
  export UPKEEP_STATE_DIR="$TESTTMP/state"
  export UPKEEP_PKEXEC=""
  export UPKEEP_NOTIFY="true"   # /usr/bin/true — notifications are no-ops in tests
  trap 'rm -rf "$TESTTMP"' EXIT
}

assert_eq() {  # got expected label
  if [[ "$1" != "$2" ]]; then echo "FAIL: $3"; echo "  expected: $2"; echo "  got:      $1"; _fail=1
  else echo "ok: $3"; fi
}

assert_json_eq() {  # got expected label (order-insensitive keys)
  assert_eq "$(jq -Sc . <<<"$1")" "$(jq -Sc . <<<"$2")" "$3"
}

assert_exit() {  # expected_rc label -- cmd...
  local want="$1" label="$2"; shift 2; local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "$want" "$label"
}

finish() { exit $_fail; }
