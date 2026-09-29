#!/usr/bin/env bash
# Reclaiming disk space: the Flatpak refs nothing installed uses. The listing helper, the size
# estimate, the stability rule, the reclaim block in state.json and `kempt reclaim` itself.
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
KEMPT="$REPO_ROOT/bin/kempt"
HELPER="$REPO_ROOT/libexec/kempt-flatpak-unused"
UNUSED_FX="$FIXTURES/flatpak-unused.json"

# --- the listing helper ---------------------------------------------------------------------------
# Run against a stand-in for PyGObject (tests/fixtures/fake-gi) that serves the fixture's refs, so
# this needs python3 and nothing else: no libflatpak, no system installation, no network.
if command -v python3 >/dev/null 2>&1; then
  export FAKE_FLATPAK_JSON="$UNUSED_FX" FAKE_FLATPAK_CALLS="$TESTTMP/fake-calls"
  hout="$(PYTHONPATH="$FIXTURES/fake-gi" PYTHONDONTWRITEBYTECODE=1 "$HELPER")" || hout="rc=$?"
  assert_json_eq "$hout" "$(cat "$UNUSED_FX")" \
    "the helper prints the installation, the unused refs with their end-of-life reason, and the rest as used"
  assert_eq "$(jq -r '.unused[4].eol' <<<"$hout" 2>/dev/null)" \
    "We strongly recommend moving to the latest stable version of the Platform and SDK" \
    "...an end-of-life runtime carries flatpak's reason"
  assert_eq "$(jq -r '.unused[0].eol' <<<"$hout" 2>/dev/null)" "null" "...and a supported one carries null"
  # new_user() creates ~/.local/share/flatpak/repo as a side effect, so the helper must never call it.
  assert_eq "$(cat "$TESTTMP/fake-calls")" "new_system" "the helper opens the system installation and nothing else"
  rc=0; FAKE_FLATPAK_FAIL="boom" PYTHONPATH="$FIXTURES/fake-gi" PYTHONDONTWRITEBYTECODE=1 \
    "$HELPER" >"$TESTTMP/hout" 2>"$TESTTMP/herr" || rc=$?
  assert_eq "$rc" "1" "a library that fails is a non-zero exit"
  assert_eq "$(wc -c < "$TESTTMP/hout")" "0" "...with nothing on stdout for the CLI to parse"
  assert_contains "$(cat "$TESTTMP/herr")" "flatpak did not answer: boom" "...and the reason on stderr"
  rc=0; PYTHONPATH="$TESTTMP/no-such-dir" PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 python3 -S "$HELPER" \
    >/dev/null 2>"$TESTTMP/herr" || rc=$?
  assert_eq "$rc" "3" "no PyGObject at all is exit 3"
  assert_exit 2 "the helper takes no arguments" -- env PYTHONPATH="$FIXTURES/fake-gi" "$HELPER" --user
  unset FAKE_FLATPAK_JSON FAKE_FLATPAK_CALLS
else
  skip "python3 not installed: the listing helper was not run"
fi
# Not under lib/ or backends/: the package strips the shebang from every file there, and this one
# is executed rather than sourced.
assert_eq "$(head -1 "$HELPER")" "#!/usr/bin/python3" "the helper names its interpreter absolutely"
assert_exit 0 "...and is executable in the tree" -- test -x "$HELPER"

finish
