#!/usr/bin/env bash
# install.sh is NEVER run privileged from a test. Two safe modes are exercised here:
#   --destdir  stages everything into the sandbox (no pkexec at all), and
#   UPKEEP_INSTALL_ECHO=1  runs the real-mode path but PRINTS the pkexec/pkill commands
#                          instead of running them (same seam shape as UPKEEP_APPLY_ECHO).
# sandbox() gives this file its own $HOME, so even the real-mode path only ever writes there.
source "$(dirname "$0")/lib.sh"; sandbox
INSTALL="$REPO_ROOT/install.sh"
D="$TESTTMP/stage"

bash "$INSTALL" --destdir "$D" >/dev/null
[[ -x "$D/usr/local/libexec/upkeep-refresh" ]] && echo "ok: refresh helper staged" || { echo "FAIL: refresh helper"; _fail=1; }
[[ -x "$D/usr/local/libexec/upkeep-apply" ]] && echo "ok: apply helper staged" || { echo "FAIL: apply helper"; _fail=1; }
[[ -f "$D/usr/share/polkit-1/actions/org.erez.upkeep.policy" ]] && echo "ok: policy staged" || { echo "FAIL: policy"; _fail=1; }
[[ -L "$D$HOME/.local/bin/upkeep" ]] && echo "ok: CLI symlinked" || { echo "FAIL: symlink"; _fail=1; }

# The helpers are the only COPIES: they must be byte-identical to what the repo reviewed, and
# the policy has to be world-readable or polkit ignores the action.
assert_exit 0 "staged refresh helper matches the repo" -- cmp -s "$REPO_ROOT/libexec/upkeep-refresh" "$D/usr/local/libexec/upkeep-refresh"
assert_exit 0 "staged apply helper matches the repo" -- cmp -s "$REPO_ROOT/libexec/upkeep-apply" "$D/usr/local/libexec/upkeep-apply"
assert_eq "$(stat -c %a "$D/usr/share/polkit-1/actions/org.erez.upkeep.policy")" "644" "policy is world-readable"

# The symlink is the whole "the checkout is load-bearing" contract: it must resolve INTO the
# repo, not into a copy. A copy would silently freeze the CLI at install time.
assert_eq "$(readlink "$D$HOME/.local/bin/upkeep")" "$REPO_ROOT/bin/upkeep" "the CLI symlink points into the checkout"

# Staging is for packaging and tests: it must not reach outside DESTDIR and install for real.
assert_exit 0 "staging never touches the live HOME" -- test ! -e "$HOME/.local/bin/upkeep"

# Re-running the installer is the normal way to pick up a repo update.
bash "$INSTALL" --destdir "$D" >/dev/null
assert_eq "$(ls -1 "$D$HOME/.local/bin/" | wc -l)" "1" "re-staging leaves exactly one CLI entry"
assert_eq "$(readlink "$D$HOME/.local/bin/upkeep")" "$REPO_ROOT/bin/upkeep" "re-staging keeps the symlink pointing into the checkout"

# --uninstall against a DESTDIR removes exactly what --destdir staged, with no pkexec anywhere.
# Holds and history are the user's own data: uninstalling the tool must not throw them away.
mkdir -p "$UPKEEP_CONFIG_DIR" "$UPKEEP_STATE_DIR"
printf 'surface=terminal\n' > "$UPKEEP_CONFIG_DIR/config"
printf 'dnf:vim-common\n' > "$UPKEEP_CONFIG_DIR/holds"
bash "$INSTALL" --uninstall --destdir "$D" >/dev/null
assert_exit 0 "uninstall removes the staged refresh helper" -- test ! -e "$D/usr/local/libexec/upkeep-refresh"
assert_exit 0 "uninstall removes the staged apply helper" -- test ! -e "$D/usr/local/libexec/upkeep-apply"
assert_exit 0 "uninstall removes the staged policy" -- test ! -e "$D/usr/share/polkit-1/actions/org.erez.upkeep.policy"
assert_exit 0 "uninstall removes the staged CLI symlink" -- test ! -e "$D$HOME/.local/bin/upkeep"
assert_exit 0 "uninstall leaves the config alone" -- test -s "$UPKEEP_CONFIG_DIR/config"
assert_exit 0 "uninstall leaves the holds alone" -- test -s "$UPKEEP_CONFIG_DIR/holds"

# Usage errors: a typo must never be read as "install with the defaults".
assert_exit 2 "unknown option refused" bash "$INSTALL" --bogus
assert_exit 2 "--destdir without a value refused" bash "$INSTALL" --destdir
assert_exit 2 "a bare positional argument refused" bash "$INSTALL" /some/where

# --- real-mode command construction (printed, never run) ---
# The paths must be PASSED to the root shell as positional args, never interpolated into its
# script: a checkout path containing a quote would otherwise break the command or inject into it.
out="$(UPKEEP_INSTALL_ECHO=1 bash "$INSTALL" <<<"n")"
grep -q 'install -m 755 -o root -g root "\$1" "\$2" /usr/local/libexec/' <<<"$out" \
  && echo "ok: the root script reads its paths from \$1/\$2, not from interpolation" \
  || { echo "FAIL: pkexec script does not use positional args - got: $out"; _fail=1; }
grep -qF -- "_ $REPO_ROOT/libexec/upkeep-refresh $REPO_ROOT/libexec/upkeep-apply $REPO_ROOT/polkit/org.erez.upkeep.policy" <<<"$out" \
  && echo "ok: the three paths are trailing positional args" || { echo "FAIL: positional args - got: $out"; _fail=1; }
assert_eq "$(grep -oF "$REPO_ROOT" <<<"$out" | wc -l)" "3" "each path appears exactly once, as an argument"
grep -q 'mkdir -p /usr/local/libexec' <<<"$out" \
  && echo "ok: creates /usr/local/libexec (a fresh Fedora box has none)" || { echo "FAIL: mkdir -p missing"; _fail=1; }
assert_eq "$(grep -c '^pkexec' <<<"$out")" "1" "one pkexec prompt for the whole root install"

# Real mode is also what a user runs to UPDATE an install, and it must say that the checkout
# stays load-bearing (only the root helpers are copies).
assert_exit 0 "real mode symlinks the CLI into ~/.local/bin" -- test -L "$HOME/.local/bin/upkeep"
assert_eq "$(readlink "$HOME/.local/bin/upkeep")" "$REPO_ROOT/bin/upkeep" "real mode symlink points into the checkout"
grep -q "don't move/delete the repo" <<<"$out" \
  && echo "ok: says the checkout is load-bearing" || { echo "FAIL: no checkout warning - got: $out"; _fail=1; }

# Answering no to the notifier question must leave the user's autostart alone.
assert_exit 0 "declining the notifier opt-out writes nothing" -- test ! -e "$HOME/.config/autostart/org.kde.discover.notifier.desktop"

# ...and neither does having nobody to ask. The spec is explicit that the notifier is never
# disabled silently, so a piped/redirected stdin must leave it exactly as it was.
nout="$(UPKEEP_INSTALL_ECHO=1 bash "$INSTALL" </dev/null)"
assert_exit 0 "a non-interactive install never disables the notifier" -- test ! -e "$HOME/.config/autostart/org.kde.discover.notifier.desktop"
grep -q 'left ENABLED' <<<"$nout" && echo "ok: and it says so" || { echo "FAIL: silent skip - got: $nout"; _fail=1; }
grep -q 'DiscoverNotifier' <<<"$nout" && { echo "FAIL: pkill reached a non-interactive install"; _fail=1; } \
  || echo "ok: nothing was killed on the user's desktop"

# --- the notifier opt-out itself (sourced: install.sh only runs main when executed) ---
# UPKEEP_AUTOSTART_SRC is the copy source. Seeding the RESULT would prove nothing: the next call
# re-copies the source over it, so only a fixture SOURCE actually exercises the replace logic.
source "$INSTALL"
AUTOSTART="$TESTTMP/autostart"
f="$AUTOSTART/org.kde.discover.notifier.desktop"

# No system entry to copy (a box without Discover installed): still a valid, hiding entry.
UPKEEP_AUTOSTART_SRC="$TESTTMP/no-such-autostart.desktop"
notifier_optout "$AUTOSTART"
assert_exit 0 "opt-out writes an autostart override" -- test -f "$f"
assert_eq "$(grep -c '^Hidden=true' "$f")" "1" "the override hides the notifier"
grep -q '^\[Desktop Entry\]' "$f" && echo "ok: the fallback is a valid desktop entry" || { echo "FAIL: fallback has no desktop entry header"; _fail=1; }
grep -q '^Type=Application' "$f" && echo "ok: the fallback carries the required Type key" || { echo "FAIL: fallback missing Type"; _fail=1; }
notifier_optout "$AUTOSTART"
notifier_optout "$AUTOSTART"
assert_eq "$(grep -c '^Hidden=' "$f")" "1" "re-running the installer never accumulates Hidden= lines"
assert_eq "$(grep -c '^Hidden=true' "$f")" "1" "and the one line still hides it"

# A system entry that ships Hidden=false must not survive alongside ours: two Hidden= keys is an
# invalid desktop entry and parsers disagree about which one wins.
UPKEEP_AUTOSTART_SRC="$TESTTMP/system-notifier.desktop"
printf '[Desktop Entry]\nType=Application\nName=Discover Notifier\nExec=/usr/bin/DiscoverNotifier\nHidden=false\nX-KDE-autostart-phase=2\n' \
  > "$UPKEEP_AUTOSTART_SRC"
rm -rf "$AUTOSTART"
notifier_optout "$AUTOSTART"
assert_eq "$(grep -c '^Hidden=' "$f")" "1" "an existing Hidden= key is replaced, not duplicated"
assert_eq "$(grep -c '^Hidden=true' "$f")" "1" "and what remains is Hidden=true"
grep -q '^\[Desktop Entry\]' "$f" && echo "ok: the file stays a valid desktop entry" || { echo "FAIL: desktop entry header lost"; _fail=1; }
grep -q '^Exec=/usr/bin/DiscoverNotifier' "$f" && echo "ok: the system entry's own keys survive" || { echo "FAIL: Exec key lost"; _fail=1; }
grep -q '^X-KDE-autostart-phase=2' "$f" && echo "ok: even the trailing keys survive" || { echo "FAIL: trailing key lost"; _fail=1; }
notifier_optout "$AUTOSTART"
notifier_optout "$AUTOSTART"
assert_eq "$(grep -c '^Hidden=' "$f")" "1" "re-running against a Hidden=false system entry still leaves one"
assert_eq "$(grep -c '^Hidden=true' "$f")" "1" "and it is still the hiding one"
finish
