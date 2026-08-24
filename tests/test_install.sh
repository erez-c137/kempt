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

# The panel widget. kpackagetool6 COPIES a package into the user's plasmoids directory, so
# --destdir stages a copy of the same tree in the same place - that is what makes the widget arm
# testable at all on a box where running kpackagetool6 is off limits.
P="$D$HOME/.local/share/plasma/plasmoids/org.erez.upkeep"
[[ -f "$P/metadata.json" ]] && echo "ok: widget metadata staged" || { echo "FAIL: widget metadata"; _fail=1; }
[[ -f "$P/contents/ui/main.qml" ]] && echo "ok: widget main.qml staged" || { echo "FAIL: widget main.qml"; _fail=1; }
[[ -f "$P/contents/ui/logic.js" ]] && echo "ok: widget logic.js staged" || { echo "FAIL: widget logic.js"; _fail=1; }
[[ -f "$P/contents/config/config.qml" ]] && echo "ok: widget config page staged" || { echo "FAIL: widget config"; _fail=1; }
assert_eq "$(jq -r .KPlugin.Id "$P/metadata.json")" "org.erez.upkeep" "the staged package carries the id install.sh removes by"
# A symlinked package would break the moment the repo moved, and it is not what kpackagetool6
# does either: the widget is the one part of the install that is genuinely a copy.
assert_exit 0 "the staged widget is a copy, not a symlink into the checkout" -- test ! -L "$P"

# The helpers are the only COPIES: they must be byte-identical to what the repo reviewed, and
# the policy has to be world-readable or polkit ignores the action.
assert_exit 0 "staged refresh helper matches the repo" -- cmp -s "$REPO_ROOT/libexec/upkeep-refresh" "$D/usr/local/libexec/upkeep-refresh"
assert_exit 0 "staged apply helper matches the repo" -- cmp -s "$REPO_ROOT/libexec/upkeep-apply" "$D/usr/local/libexec/upkeep-apply"
assert_eq "$(stat -c %a "$D/usr/share/polkit-1/actions/org.erez.upkeep.policy")" "644" "policy is world-readable"

# The symlink is the whole "the checkout is load-bearing" contract: it must resolve INTO the
# repo, not into a copy. A copy would silently freeze the CLI at install time.
assert_eq "$(readlink "$D$HOME/.local/bin/upkeep")" "$REPO_ROOT/bin/upkeep" "the CLI symlink points into the checkout"
# Same contract for the man page: `man upkeep` must show the checkout's page, not a copy frozen
# at install time. It goes to the USER man hierarchy, so it needs no root.
assert_eq "$(readlink "$D$HOME/.local/share/man/man1/upkeep.1")" "$REPO_ROOT/docs/man/upkeep.1" "man page symlinked into the checkout"

# Staging is for packaging and tests: it must not reach outside DESTDIR and install for real.
assert_exit 0 "staging never touches the live HOME" -- test ! -e "$HOME/.local/bin/upkeep"

# Re-running the installer is the normal way to pick up a repo update.
# The stray file proves re-staging REPLACES the widget package: a copy that merged instead would
# keep serving a QML file the repo deleted, and the widget would drift from the source it came from.
printf 'stale\n' > "$P/contents/ui/GoneInTheNextRelease.qml"
bash "$INSTALL" --destdir "$D" >/dev/null
assert_eq "$(ls -1 "$D$HOME/.local/bin/" | wc -l)" "1" "re-staging leaves exactly one CLI entry"
assert_eq "$(readlink "$D$HOME/.local/bin/upkeep")" "$REPO_ROOT/bin/upkeep" "re-staging keeps the symlink pointing into the checkout"
assert_exit 0 "re-staging the widget drops a file the repo no longer has" -- test ! -e "$P/contents/ui/GoneInTheNextRelease.qml"
assert_exit 0 "...and still stages the real ones" -- test -f "$P/contents/ui/logic.js"

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
assert_exit 0 "uninstall removes the staged man page symlink" -- test ! -e "$D$HOME/.local/share/man/man1/upkeep.1"
assert_exit 0 "uninstall removes the staged widget package" -- test ! -e "$P"
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
# The widget arm names the checkout too, and this assertion is about the ROOT script's three
# arguments - so the (single-line, unprivileged) kpackagetool command is excluded from the count.
assert_eq "$(grep -v 'Plasma/Applet' <<<"$out" | grep -oF "$REPO_ROOT" | wc -l)" "3" "each path appears exactly once, as an argument"
grep -q 'mkdir -p /usr/local/libexec' <<<"$out" \
  && echo "ok: creates /usr/local/libexec (a fresh Fedora box has none)" || { echo "FAIL: mkdir -p missing"; _fail=1; }
assert_eq "$(grep -c '^pkexec' <<<"$out")" "1" "one pkexec prompt for the whole root install"

# Real mode is also what a user runs to UPDATE an install, and it must say that the checkout
# stays load-bearing (only the root helpers are copies).
assert_exit 0 "real mode symlinks the CLI into ~/.local/bin" -- test -L "$HOME/.local/bin/upkeep"
assert_eq "$(readlink "$HOME/.local/bin/upkeep")" "$REPO_ROOT/bin/upkeep" "real mode symlink points into the checkout"
grep -q "don't move/delete the repo" <<<"$out" \
  && echo "ok: says the checkout is load-bearing" || { echo "FAIL: no checkout warning - got: $out"; _fail=1; }

# --- wrong outcomes: what the installer SAYS when the auth dialog is dismissed. UPKEEP_INSTALL_ECHO=fail
# makes the printed pkexec report failure, which is the only way to reach these paths unprivileged.
irc=0
iout="$(UPKEEP_INSTALL_ECHO=fail bash "$INSTALL" </dev/null 2>&1)" || irc=$?
assert_eq "$irc" "1" "a declined install exits 1, not a bare pkexec rc"
grep -q 'root helpers are NOT installed' <<<"$iout" \
  && echo "ok: a declined install says the helpers are missing" || { echo "FAIL: install failure message - got: $iout"; _fail=1; }
# The widget arm sits after the root step, so a declined dialog skips it too. Skipping is right (a
# widget with no root helpers can only ever show a failed check), but it must be SAID, not silent.
grep -q 'panel widget was not installed either' <<<"$iout" \
  && echo "ok: ...and that the widget was skipped along with them" || { echo "FAIL: declined install does not mention the widget - got: $iout"; _fail=1; }
urc=0
uout="$(UPKEEP_INSTALL_ECHO=fail bash "$INSTALL" --uninstall 2>&1)" || urc=$?
assert_eq "$urc" "1" "a declined uninstall exits 1, not a bare pkexec rc"
grep -q 'the CLI symlink is gone, but' <<<"$uout" \
  && echo "ok: a declined uninstall names the half-removed state" || { echo "FAIL: uninstall failure message - got: $uout"; _fail=1; }
grep -q 're-run ./install.sh --uninstall' <<<"$uout" \
  && echo "ok: ...and says how to finish" || { echo "FAIL: no recovery instruction - got: $uout"; _fail=1; }

# --- the notifier question. "no" must mean no: `!= "n"` used to read the word "no" as consent.
export UPKEEP_AUTOSTART_SRC="$TESTTMP/system-notifier.desktop"
printf '[Desktop Entry]\nType=Application\nName=Discover Notifier\nExec=/usr/bin/DiscoverNotifier\nHidden=false\nX-KDE-autostart-phase=2\n' \
  > "$UPKEEP_AUTOSTART_SRC"
USER_AUTOSTART="$HOME/.config/autostart/org.kde.discover.notifier.desktop"
assert_exit 0 "declining with n writes nothing" -- test ! -e "$USER_AUTOSTART"
nout_no="$(UPKEEP_INSTALL_ECHO=1 bash "$INSTALL" <<<"no")"
assert_exit 0 "declining with the word 'no' writes nothing either" -- test ! -e "$USER_AUTOSTART"
grep -q 'left enabled' <<<"$nout_no" && echo "ok: and it says the notifier is still enabled" || { echo "FAIL: no-answer message - got: $nout_no"; _fail=1; }
grep -q 'DiscoverNotifier disabled' <<<"$nout_no" && { echo "FAIL: 'no' disabled the notifier anyway"; _fail=1; } \
  || echo "ok: 'no' never claims it disabled anything"
yout="$(UPKEEP_INSTALL_ECHO=1 bash "$INSTALL" <<<"y")"
assert_exit 0 "accepting writes the override" -- test -f "$USER_AUTOSTART"
assert_eq "$(grep -c '^Hidden=true' "$USER_AUTOSTART")" "1" "the override hides the notifier"
grep -q 'pkill -f DiscoverNotifier' <<<"$yout" && echo "ok: accepting also stops the running notifier" || { echo "FAIL: pkill not attempted - got: $yout"; _fail=1; }
rm -f "$USER_AUTOSTART"

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

# An override the user has since edited by hand must survive a re-install: the system entry is
# only ever a SEED, copied when there is nothing there yet.
printf '[Desktop Entry]\nType=Application\nName=Discover Notifier\nX-Erez-Custom=1\nHidden=true\n' > "$f"
notifier_optout "$AUTOSTART"
grep -q '^X-Erez-Custom=1' "$f" && echo "ok: re-installing preserves the user's own autostart edits" \
  || { echo "FAIL: the system entry overwrote the user's file"; _fail=1; }
assert_eq "$(grep -c '^Hidden=' "$f")" "1" "and still exactly one Hidden= line"

# --- the panel widget arm (sourced, with a stub kpackagetool6) ---------------------------------
# The real kpackagetool6 is never run here: it writes into the user's plasmoids directory and
# talks to the running plasmashell. UPKEEP_KPACKAGETOOL points at a stub that records its
# arguments, which is what makes the install-or-upgrade fallback provable rather than asserted.
cat > "$TESTTMP/kp-ok" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TESTTMP/kp-calls"
exit 0
STUB
# The real tool refuses -i when the package is already installed. That refusal is the ONLY signal
# install.sh has that this is an update, so the stub reproduces it exactly.
cat > "$TESTTMP/kp-already" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TESTTMP/kp-calls"
case " \$* " in *" -i "*) echo "org.erez.upkeep already exists" >&2; exit 1 ;; esac
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$TESTTMP/kp-broken"
chmod +x "$TESTTMP/kp-ok" "$TESTTMP/kp-already" "$TESTTMP/kp-broken"

: > "$TESTTMP/kp-calls"
UPKEEP_KPACKAGETOOL="$TESTTMP/kp-ok" widget_install > "$TESTTMP/wout" 2>&1
assert_eq "$(grep -c '' "$TESTTMP/kp-calls")" "1" "a first install calls kpackagetool6 exactly once"
assert_eq "$(cat "$TESTTMP/kp-calls")" "-t Plasma/Applet -i $REPO_ROOT/plasmoid" \
  "...as an Applet install of the repo's own plasmoid tree"
grep -q 'Add Widgets' "$TESTTMP/wout" && echo "ok: and it says how to actually put the widget on the panel" \
  || { echo "FAIL: no instruction after install - got: $(cat "$TESTTMP/wout")"; _fail=1; }
grep -q 'COPY' "$TESTTMP/wout" && echo "ok: ...and that the widget, unlike the CLI, is a copy" \
  || { echo "FAIL: does not say the widget is a copy - got: $(cat "$TESTTMP/wout")"; _fail=1; }

# Re-running the installer is how a user updates: -i refuses, -u has to pick it up.
: > "$TESTTMP/kp-calls"
UPKEEP_KPACKAGETOOL="$TESTTMP/kp-already" widget_install >/dev/null 2>&1
assert_eq "$(grep -c '' "$TESTTMP/kp-calls")" "2" "an already-installed widget falls back to the upgrade path"
assert_eq "$(sed -n 2p "$TESTTMP/kp-calls")" "-t Plasma/Applet -u $REPO_ROOT/plasmoid" \
  "...and the fallback is -u against the same tree"

# The CLI is the product. A box with no kpackagetool6 (no Plasma at all, or a KDE-less server)
# must still finish the install, and must SAY the widget was skipped rather than imply it worked.
rc=0
out="$(UPKEEP_KPACKAGETOOL="$TESTTMP/no-such-kpackagetool" widget_install 2>&1)" || rc=$?
assert_eq "$rc" "0" "a missing kpackagetool6 never fails the install"
grep -q 'NOT installed' <<<"$out" && echo "ok: and it says the widget was skipped" \
  || { echo "FAIL: silent widget skip - got: $out"; _fail=1; }
rc=0
out="$(UPKEEP_KPACKAGETOOL="$TESTTMP/kp-broken" widget_install 2>&1)" || rc=$?
assert_eq "$rc" "0" "a kpackagetool6 that fails both ways never fails the install either"
grep -q 'CLI is installed and working' <<<"$out" && echo "ok: and it says what still works" \
  || { echo "FAIL: unhelpful widget failure - got: $out"; _fail=1; }

# Uninstall addresses the package by id, and a widget that was never installed is not an error.
: > "$TESTTMP/kp-calls"
UPKEEP_KPACKAGETOOL="$TESTTMP/kp-ok" widget_uninstall >/dev/null 2>&1
assert_eq "$(cat "$TESTTMP/kp-calls")" "-t Plasma/Applet -r org.erez.upkeep" \
  "uninstall removes the widget by the id in metadata.json"
assert_eq "$(jq -r .KPlugin.Id "$REPO_ROOT/plasmoid/metadata.json")" "org.erez.upkeep" \
  "...and that id is the one the package actually declares"
rc=0
UPKEEP_KPACKAGETOOL="$TESTTMP/kp-broken" widget_uninstall >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "removing a widget that was never installed is not a failure"

# ...and the whole arm is covered by the echo seam, so no test anywhere in this suite can reach
# a real kpackagetool6 and write into somebody's plasmoids directory.
: > "$TESTTMP/kp-calls"
wout="$(UPKEEP_KPACKAGETOOL="$TESTTMP/kp-ok" UPKEEP_INSTALL_ECHO=1 bash "$INSTALL" </dev/null)"
grep -qF -- "$TESTTMP/kp-ok -t Plasma/Applet -i $REPO_ROOT/plasmoid" <<<"$wout" \
  && echo "ok: echo mode prints the kpackagetool command" || { echo "FAIL: widget arm missing from echo mode - got: $wout"; _fail=1; }
assert_eq "$(grep -c '' "$TESTTMP/kp-calls" || true)" "0" "echo mode PRINTS the widget install without running it"
finish
