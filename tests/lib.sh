#!/usr/bin/env bash
# Test helpers. Source me. Each test file runs in its own sandboxed HOME (a throwaway
# $TESTTMP/home — the real $HOME is never touched; see sandbox()).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO_ROOT/tests/fixtures"
_fail=0

sandbox() {  # fresh dirs per test file; call first
  TESTTMP="$(mktemp -d "${TMPDIR:-/tmp}/kempt-test.XXXXXX")"
  export HOME="$TESTTMP/home"; mkdir -p "$HOME"
  export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
  export KEMPT_CONFIG_DIR="$TESTTMP/config"
  export KEMPT_STATE_DIR="$TESTTMP/state"
  export KEMPT_PKEXEC=""
  export KEMPT_NOTIFY="true"   # /usr/bin/true — notifications are no-ops in tests
  export KEMPT_REFRESH_HELPER="$TESTTMP/UNSTUBBED-refresh"
  export KEMPT_APPLY_HELPER="$TESTTMP/UNSTUBBED-apply"
  unset KEMPT_DNF_INSTALLED_CMD KEMPT_DNF_CMD KEMPT_FLATPAK_REMOTE_CMD KEMPT_FLATPAK_LIST_CMD \
        KEMPT_SKIP_REFRESH KEMPT_RISKY_RE KEMPT_TERMINAL KEMPT_ASSUME_TTY KEMPT_RETRY_DELAY \
        KEMPT_AUTOSTART_SRC KEMPT_INSTALL_ECHO KEMPT_APPLY_ECHO KEMPT_REFRESH_ECHO \
        KEMPT_BOOT_ID KEMPT_POLICY_FILE \
        KEMPT_REFRESH_HELPER_PATH KEMPT_APPLY_HELPER_PATH
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
