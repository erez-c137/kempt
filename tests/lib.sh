#!/usr/bin/env bash
# Test helpers. Source me. Each test file runs in its own sandboxed HOME (a throwaway
# $TESTTMP/home — the real $HOME is never touched; see sandbox()).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO_ROOT/tests/fixtures"
_fail=0

sandbox() {  # fresh dirs per test file; call first
  TESTTMP="$(mktemp -d "${TMPDIR:-/tmp}/upkeep-test.XXXXXX")"
  export HOME="$TESTTMP/home"; mkdir -p "$HOME"
  export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
  export UPKEEP_CONFIG_DIR="$TESTTMP/config"
  export UPKEEP_STATE_DIR="$TESTTMP/state"
  export UPKEEP_PKEXEC=""
  export UPKEEP_NOTIFY="true"   # /usr/bin/true — notifications are no-ops in tests
  export UPKEEP_REFRESH_HELPER="$TESTTMP/UNSTUBBED-refresh"
  export UPKEEP_APPLY_HELPER="$TESTTMP/UNSTUBBED-apply"
  unset UPKEEP_DNF_INSTALLED_CMD UPKEEP_DNF_CMD UPKEEP_FLATPAK_REMOTE_CMD UPKEEP_FLATPAK_LIST_CMD \
        UPKEEP_SKIP_REFRESH UPKEEP_RISKY_RE UPKEEP_TERMINAL UPKEEP_ASSUME_TTY UPKEEP_RETRY_DELAY \
        UPKEEP_AUTOSTART_SRC UPKEEP_INSTALL_ECHO UPKEEP_APPLY_ECHO UPKEEP_REFRESH_ECHO \
        UPKEEP_BOOT_ID UPKEEP_POLICY_FILE \
        UPKEEP_REFRESH_HELPER_PATH UPKEEP_APPLY_HELPER_PATH
  trap '_rc=$?; rm -rf "$TESTTMP"; [[ $_rc -ne 0 ]] && exit $_rc; exit $_fail' EXIT
}

assert_eq() {  # got expected label
  if [[ "$1" != "$2" ]]; then echo "FAIL: $3"; echo "  expected: $2"; echo "  got:      $1"; _fail=1
  else echo "ok: $3"; fi
}

assert_json_eq() {  # got expected label (order-insensitive keys)
  assert_eq "$(jq -Sc . <<<"$1")" "$(jq -Sc . <<<"$2")" "$3"
}

assert_exit() {  # expected_rc label [--] cmd...
  local want="$1" label="$2"; shift 2
  [[ "${1:-}" == "--" ]] && shift
  local rc=0
  "$@" >"$TESTTMP/last_output" 2>&1 || rc=$?
  assert_eq "$rc" "$want" "$label"
  [[ "$rc" != "$want" ]] && { echo "  output:"; sed 's/^/    /' "$TESTTMP/last_output"; }
  return 0
}

finish() { exit $_fail; }
