#!/usr/bin/env bash
# Test helpers. Source me. Each test file runs in its own sandboxed HOME (a throwaway
# $TESTTMP/home - the real $HOME is never touched; see sandbox()).
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
  export KEMPT_NOTIFY="true"   # /usr/bin/true - notifications are no-ops in tests
  # Same shape: the installer's icon-cache signal must never reach the real session bus from a
  # test run. The suite asserts the SHAPE of the command install.sh builds, not its delivery.
  export KEMPT_DBUS_SEND="true"
  export KEMPT_REFRESH_HELPER="$TESTTMP/UNSTUBBED-refresh"
  export KEMPT_APPLY_HELPER="$TESTTMP/UNSTUBBED-apply"
  # The PATH `kempt doctor` resolves the widget's own lookup through. Pinned at a directory that
  # does not exist, and this is the one seam where leaving it unset would break the suite on the
  # developer's box rather than on a stranger's: unset it reads $HOME/.local/bin:$PATH, where a
  # checkout install leaves a `kempt` symlink pointing at the MAIN checkout - a different file from
  # the tree under test, so every doctor case would report a split install that only exists because
  # the developer has Kempt installed. Nothing on this PATH means "no kempt for the widget", which
  # doctor reports as info; the cases that need the ok and FAIL branches build their own directory.
  export KEMPT_WIDGET_PATH="$TESTTMP/no-widget-path"
  # Poisoned, not merely unset like the *_CMD seams below, and the difference matters: unset, this
  # one falls back to the REAL `flatpak remote-ls` WITHOUT --cached, which fetches flathub's
  # summary over the network. Any test file that leaves KEMPT_SKIP_REFRESH unset reaches
  # maybe_refresh_metadata, so "unset" would mean a suite that talks to flathub - slow, and
  # answering differently on a box with no flatpak installed at all. A path that does not exist
  # fails the arm loudly (rc 127) and touches nothing.
  export KEMPT_FLATPAK_REFRESH_CMD="$TESTTMP/UNSTUBBED-flatpak-refresh"
  # Poisoned for a quieter reason than the two above, but the same one at bottom: unset, dnf_sizes
  # falls back to a REAL `dnf5 -C repoquery` on every check the suite runs - about 1.4s each,
  # measured on this box, and a different answer depending on what the developer happens to have
  # pending. A path that does not exist makes every size query fail, which is also the contract
  # worth exercising by default: a failed size query yields no number and never a failed check.
  export KEMPT_DNF_SIZES_CMD="$TESTTMP/UNSTUBBED-dnf-sizes"
  # PINNED rather than poisoned, and it is the one seam where "a path that does not exist" would be
  # the wrong default. Unset, this reads the REAL
  # /usr/lib/sysimage/libdnf5/offline/offline-transaction-state.toml, so whether the box running
  # the suite happens to have a staged transaction would decide which reconciliation branch every
  # offline test takes. Pointed at nothing, "no transaction" is the answer - and a marker with no
  # transaction under it is exactly the case the check CLEARS, which would delete the marker out
  # from under every staging test in test_update.sh before it could be harvested. The fixture says
  # `ready`: if a stage exists in a test's world, it is armed. Files that need another status (or
  # none) point the seam somewhere else themselves.
  export KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml"
  # PINNED for the same reason as the toml above, and at the matching half of the same recorded
  # stage: unset, this reads the REAL /usr/lib/sysimage/libdnf5/offline/transaction.json, so whether
  # a hold conflicts with a staged transaction would be decided by what the box running the suite
  # happens to have staged. Pointed at nothing, "no list" is the answer - which is the DEGRADED
  # branch, so the primary path (a transaction that parses) would never run in the suite by default
  # and every conflict test would have to opt into it. So the fixture is the default, exactly like
  # the `ready` toml: if a stage exists in a test's world, it is armed, and its contents are the
  # three packages this fixture records.
  # Consequence, by design: any test that writes a marker and then holds ca-certificates, librepo or
  # openldap sees a conflict warning. Files that need a different transaction (or none) point the
  # seam somewhere else themselves.
  export KEMPT_OFFLINE_TXJSON="$FIXTURES/offline-transaction-full.json"
  # Pointed at a path that does not exist, which is the opposite pin to the toml above and the right
  # one: `kempt doctor` lstats this, so unset it would read the REAL /system-update and a developer
  # box with a stage armed would grow a doctor FAIL that no test asked for. "No symlink" is also the
  # state of every box that has not just staged something. Files that need one make their own.
  export KEMPT_OFFLINE_LINK="$TESTTMP/no-system-update"
  # Poisoned for the same reason, and a louder one: unset, this falls back to the REAL
  # `flatpak update --system`, which no longer goes through a stubbable root helper. A test file
  # that forgets to name its own stub would update the machine running the suite.
  export KEMPT_FLATPAK_UPDATE_CMD="$TESTTMP/UNSTUBBED-flatpak-update"
  # KEMPT_DNF_SYSTEM_CACHE joins the plain unsets rather than the poisoned ones above: its default
  # is only ever READ from, never run, and a test that cares drives both branches of its guard by
  # setting it itself. Unset here so a value exported in a developer's shell cannot decide which
  # branch the rest of the suite takes.
  unset KEMPT_DNF_INSTALLED_CMD KEMPT_DNF_CMD KEMPT_DNF_SYSTEM_CACHE \
        KEMPT_FLATPAK_REMOTE_CMD KEMPT_FLATPAK_LIST_CMD \
        KEMPT_SKIP_REFRESH KEMPT_RISKY_RE KEMPT_TERMINAL KEMPT_ASSUME_TTY KEMPT_RETRY_DELAY \
        KEMPT_AUTOSTART_SRC KEMPT_INSTALL_ECHO KEMPT_APPLY_ECHO KEMPT_REFRESH_ECHO \
        KEMPT_BOOT_ID KEMPT_POLICY_FILE KEMPT_VIA KEMPT_ROOT \
        KEMPT_REFRESH_HELPER_PATH KEMPT_APPLY_HELPER_PATH KEMPT_PLASMOID_DIR
  trap '_rc=$?; rm -rf "$TESTTMP"; [[ $_rc -ne 0 ]] && exit $_rc; exit $_fail' EXIT
}

# A dnf5 stand-in that reports a restart IS owed. Four test files drive that verdict, and each
# used to carry its own copy of this heredoc - which had already drifted (one grew a second
# kernel line). The drift matters here in a way it would not for most stubs: dnf_reboot_needed
# reads rc 1 as "yes" ONLY when a package list is actually on stdout, because rc 1 with an empty
# stdout is how the real command reports that it could not work the answer out at all (the
# cold-cache case). The stub's shape is therefore half the verdict every one of those files
# asserts, so it gets one definition. The rc-0 "no restart owed" stub stays inline where it is
# used: it is a bare `exit 0` with no output to get wrong.
write_reboot_stub() {  # path → an executable dnf5 stand-in printing the real command's "yes"
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
Core libraries or services have been updated since boot-up:
  * kernel
  * kernel-core

Reboot is required to fully utilize these updates.
OUT
exit 1
STUB
  chmod +x "$1"
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
