#!/usr/bin/env bash
# install.sh is NEVER run privileged from a test. Two safe modes are exercised here:
#   --destdir  stages everything into the sandbox (no pkexec at all), and
#   KEMPT_INSTALL_ECHO=1  runs the real-mode path but PRINTS the pkexec/pkill commands
#                          instead of running them (same seam shape as KEMPT_APPLY_ECHO).
# sandbox() gives this file its own $HOME, so even the real-mode path only ever writes there.
source "$(dirname "$0")/lib.sh"; sandbox
INSTALL="$REPO_ROOT/install.sh"
D="$TESTTMP/stage"

bash "$INSTALL" --destdir "$D" >/dev/null
[[ -x "$D/usr/local/libexec/kempt-refresh" ]] && echo "ok: refresh helper staged" || { echo "FAIL: refresh helper"; _fail=1; }
[[ -x "$D/usr/local/libexec/kempt-apply" ]] && echo "ok: apply helper staged" || { echo "FAIL: apply helper"; _fail=1; }
[[ -f "$D/usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy" ]] && echo "ok: policy staged" || { echo "FAIL: policy"; _fail=1; }
[[ -L "$D$HOME/.local/bin/kempt" ]] && echo "ok: CLI symlinked" || { echo "FAIL: symlink"; _fail=1; }

# The panel widget. kpackagetool6 COPIES a package into the user's plasmoids directory, so
# --destdir stages a copy of the same tree in the same place - that is what makes the widget arm
# testable at all on a box where running kpackagetool6 is off limits.
P="$D$HOME/.local/share/plasma/plasmoids/io.github.erez_c137.kempt"
[[ -f "$P/metadata.json" ]] && echo "ok: widget metadata staged" || { echo "FAIL: widget metadata"; _fail=1; }
[[ -f "$P/contents/ui/main.qml" ]] && echo "ok: widget main.qml staged" || { echo "FAIL: widget main.qml"; _fail=1; }
[[ -f "$P/contents/ui/logic.js" ]] && echo "ok: widget logic.js staged" || { echo "FAIL: widget logic.js"; _fail=1; }
[[ -f "$P/contents/config/config.qml" ]] && echo "ok: widget config page staged" || { echo "FAIL: widget config"; _fail=1; }
assert_eq "$(jq -r .KPlugin.Id "$P/metadata.json")" "io.github.erez_c137.kempt" "the staged package carries the id install.sh removes by"
# A symlinked package would break the moment the repo moved, and it is not what kpackagetool6
# does either: the widget is the one part of the install that is genuinely a copy.
assert_exit 0 "the staged widget is a copy, not a symlink into the checkout" -- test ! -L "$P"

# The application icon, in the USER'S ICON THEME rather than only inside the package.
# metadata.json asks for it by name ("kempt"), and a name is resolved by the XDG icon theme, not
# by KPackage: measured on Plasma 6.7 with Breeze loaded, an icon that lives only in the installed
# package's contents/icons/ does not resolve from its name at all. Without this file the widget
# shows a generic placeholder in Add Widgets, which looks like nothing being wrong.
# It goes in as a SIZE LADDER (2026-08-26), the way Breeze ships one: five drawings of the same
# comb, each hinted for the sizes it serves, because a comb fine enough to read as a comb at
# 256 px is grey mush at 32 and a flat bar at 16. Every rung is asserted, and asserted by
# CONTENT: a size directory that is merely present, or present with the wrong drawing in it,
# fails nowhere at runtime. It just quietly serves the wrong artwork at that size, which is the
# exact bug the ladder exists to fix.
ICONS="$D$HOME/.local/share/icons/hicolor"
ICON="$ICONS/scalable/apps/kempt.svg"
LADDER="scalable:kempt.svg 64x64:kempt-48.svg 48x48:kempt-48.svg 32x32:kempt-32.svg 22x22:kempt-22.svg 16x16:kempt-16.svg"
for _rung in $LADDER; do
  _dir="${_rung%%:*}"; _src="${_rung#*:}"
  assert_exit 0 "the app icon is staged into hicolor/$_dir/apps, where a name resolves" \
    -- test -f "$ICONS/$_dir/apps/kempt.svg"
  assert_exit 0 "...and hicolor/$_dir/apps got the $_src drawing" \
    -- cmp -s "$REPO_ROOT/plasmoid/contents/icons/$_src" "$ICONS/$_dir/apps/kempt.svg"
  [[ -f "$P/contents/icons/$_src" ]] && echo "ok: ...and $_src still ships inside the package too" \
    || { echo "FAIL: the package lost its copy of $_src"; _fail=1; }
done
assert_eq "$(head -c 5 "$ICON" 2>/dev/null)" "<?xml" "...and what was staged is the SVG, not a stub"
# Three DIFFERENT drawings is the whole point. If a future edit ever copies one file over the
# others, the ladder still installs six files and every assertion above still passes.
assert_exit 1 "the scalable and the 48 drawing are genuinely different artwork" \
  -- cmp -s "$REPO_ROOT/plasmoid/contents/icons/kempt.svg" "$REPO_ROOT/plasmoid/contents/icons/kempt-48.svg"
assert_exit 1 "...and so are the 48 and the 32 drawing" \
  -- cmp -s "$REPO_ROOT/plasmoid/contents/icons/kempt-48.svg" "$REPO_ROOT/plasmoid/contents/icons/kempt-32.svg"
assert_exit 1 "...and so are the 32 and the 22 drawing" \
  -- cmp -s "$REPO_ROOT/plasmoid/contents/icons/kempt-32.svg" "$REPO_ROOT/plasmoid/contents/icons/kempt-22.svg"
assert_exit 1 "...and so are the 22 and the 16 drawing" \
  -- cmp -s "$REPO_ROOT/plasmoid/contents/icons/kempt-22.svg" "$REPO_ROOT/plasmoid/contents/icons/kempt-16.svg"
# The two smallest rungs are hand-hinted on their OWN pixel grid, and that is the entire point of
# them: a viewBox of 256 cannot put a tooth edge on a whole device pixel at 22 or 16 px. If one
# of these ever gets "tidied up" onto the 256 grid the teeth silently blur back into a flat bar,
# and nothing else in the suite would notice.
assert_exit 0 "the 22 px rung is authored on the 22 px grid, not the 256 one" \
  -- grep -q 'viewBox="0 0 22 22"' "$REPO_ROOT/plasmoid/contents/icons/kempt-22.svg"
assert_exit 0 "the 16 px rung is authored on the 16 px grid, not the 256 one" \
  -- grep -q 'viewBox="0 0 16 16"' "$REPO_ROOT/plasmoid/contents/icons/kempt-16.svg"
# The symbolic panel glyphs are NOT part of this ladder and must not be dragged into it: they are
# monochrome currentColor drawings for the system tray, resolved by their own names.
assert_exit 1 "the ladder does not install a symbolic glyph under the 'kempt' name" \
  -- test -e "$ICONS/22x22/apps/kempt-symbolic.svg"

# The helpers are the only COPIES: they must be byte-identical to what the repo reviewed, and
# the policy has to be world-readable or polkit ignores the action.
assert_exit 0 "staged refresh helper matches the repo" -- cmp -s "$REPO_ROOT/libexec/kempt-refresh" "$D/usr/local/libexec/kempt-refresh"
assert_exit 0 "staged apply helper matches the repo" -- cmp -s "$REPO_ROOT/libexec/kempt-apply" "$D/usr/local/libexec/kempt-apply"
assert_eq "$(stat -c %a "$D/usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy")" "644" "policy is world-readable"

# The symlink is the whole "the checkout is load-bearing" contract: it must resolve INTO the
# repo, not into a copy. A copy would silently freeze the CLI at install time.
assert_eq "$(readlink "$D$HOME/.local/bin/kempt")" "$REPO_ROOT/bin/kempt" "the CLI symlink points into the checkout"
# Same contract for the man page: `man kempt` must show the checkout's page, not a copy frozen
# at install time. It goes to the USER man hierarchy, so it needs no root.
assert_eq "$(readlink "$D$HOME/.local/share/man/man1/kempt.1")" "$REPO_ROOT/docs/man/kempt.1" "man page symlinked into the checkout"

# Staging is for packaging and tests: it must not reach outside DESTDIR and install for real.
assert_exit 0 "staging never touches the live HOME" -- test ! -e "$HOME/.local/bin/kempt"

# Re-running the installer is the normal way to pick up a repo update.
# The stray file proves re-staging REPLACES the widget package: a copy that merged instead would
# keep serving a QML file the repo deleted, and the widget would drift from the source it came from.
printf 'stale\n' > "$P/contents/ui/GoneInTheNextRelease.qml"
bash "$INSTALL" --destdir "$D" >/dev/null
assert_eq "$(ls -1 "$D$HOME/.local/bin/" | wc -l)" "1" "re-staging leaves exactly one CLI entry"
assert_eq "$(readlink "$D$HOME/.local/bin/kempt")" "$REPO_ROOT/bin/kempt" "re-staging keeps the symlink pointing into the checkout"
assert_exit 0 "re-staging the widget drops a file the repo no longer has" -- test ! -e "$P/contents/ui/GoneInTheNextRelease.qml"
assert_exit 0 "...and still stages the real ones" -- test -f "$P/contents/ui/logic.js"

# --uninstall against a DESTDIR removes exactly what --destdir staged, with no pkexec anywhere.
# Holds and history are the user's own data: uninstalling the tool must not throw them away.
mkdir -p "$KEMPT_CONFIG_DIR" "$KEMPT_STATE_DIR"
printf 'surface=terminal\n' > "$KEMPT_CONFIG_DIR/config"
printf 'dnf:vim-common\n' > "$KEMPT_CONFIG_DIR/holds"
bash "$INSTALL" --uninstall --destdir "$D" >/dev/null
assert_exit 0 "uninstall removes the staged refresh helper" -- test ! -e "$D/usr/local/libexec/kempt-refresh"
assert_exit 0 "uninstall removes the staged apply helper" -- test ! -e "$D/usr/local/libexec/kempt-apply"
assert_exit 0 "uninstall removes the staged policy" -- test ! -e "$D/usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy"
assert_exit 0 "uninstall removes the staged CLI symlink" -- test ! -e "$D$HOME/.local/bin/kempt"
assert_exit 0 "uninstall removes the staged man page symlink" -- test ! -e "$D$HOME/.local/share/man/man1/kempt.1"
assert_exit 0 "uninstall removes the staged widget package" -- test ! -e "$P"
# ...and EVERY rung of the icon ladder, not just the scalable one. An uninstall that left five
# stale drawings behind in the size dirs would keep serving a "kempt" icon for a program that is
# no longer installed - and the next install would silently inherit them.
for _rung in $LADDER; do
  assert_exit 0 "uninstall removes the staged icon from hicolor/${_rung%%:*}/apps" \
    -- test ! -e "$ICONS/${_rung%%:*}/apps/kempt.svg"
done
assert_exit 0 "uninstall leaves the config alone" -- test -s "$KEMPT_CONFIG_DIR/config"
assert_exit 0 "uninstall leaves the holds alone" -- test -s "$KEMPT_CONFIG_DIR/holds"

# Usage errors: a typo must never be read as "install with the defaults".
assert_exit 2 "unknown option refused" bash "$INSTALL" --bogus
assert_exit 2 "--destdir without a value refused" bash "$INSTALL" --destdir
assert_exit 2 "a bare positional argument refused" bash "$INSTALL" /some/where

# --- real-mode command construction (printed, never run) ---
# The paths must be PASSED to the root shell as positional args, never interpolated into its
# script: a checkout path containing a quote would otherwise break the command or inject into it.
out="$(KEMPT_INSTALL_ECHO=1 bash "$INSTALL" <<<"n")"
grep -q 'install -m 755 -o root -g root "\$1" "\$2" /usr/local/libexec/' <<<"$out" \
  && echo "ok: the root script reads its paths from \$1/\$2, not from interpolation" \
  || { echo "FAIL: pkexec script does not use positional args - got: $out"; _fail=1; }
grep -qF -- "_ $REPO_ROOT/libexec/kempt-refresh $REPO_ROOT/libexec/kempt-apply $REPO_ROOT/polkit/io.github.erez_c137.kempt.policy" <<<"$out" \
  && echo "ok: the three paths are trailing positional args" || { echo "FAIL: positional args - got: $out"; _fail=1; }
# The widget arm names the checkout too, and this assertion is about the ROOT script's three
# arguments - so the (single-line, unprivileged) kpackagetool command is excluded from the count.
assert_eq "$(grep -v 'Plasma/Applet' <<<"$out" | grep -oF "$REPO_ROOT" | wc -l)" "3" "each path appears exactly once, as an argument"
# The MODE is the assertion, not just the mkdir: pkexec sets no umask, so root inherits the
# caller's, and a bare `mkdir -p` under `umask 000` leaves the directory that holds a root-exec'd
# helper world-writable.
grep -q 'mkdir -p -m 0755 /usr/local/libexec' <<<"$out" \
  && echo "ok: creates /usr/local/libexec with an explicit mode (a fresh Fedora box has none)" \
  || { echo "FAIL: mkdir -p -m 0755 missing"; _fail=1; }
assert_eq "$(grep -c '^pkexec' <<<"$out")" "1" "one pkexec prompt for the whole root install"
# ...and pkexec is handed bash by its ABSOLUTE path, on both the install and the uninstall step.
# pkexec resolves a bare name through the caller's PATH, where ~/.local/bin comes first on Fedora.
# (The commands inside the root script need no such care: pkexec runs them with its own safe PATH.)
assert_eq "$(grep '^pkexec' <<<"$out" | grep -vc '^pkexec /usr/bin/bash -c ')" "0" \
  "the root install runs /usr/bin/bash, never a bash found on the caller's PATH"
uninst_out="$(KEMPT_INSTALL_ECHO=1 bash "$INSTALL" --uninstall 2>&1)"
assert_eq "$(grep -c '^pkexec /usr/bin/bash -c ' <<<"$uninst_out")" "1" \
  "the root uninstall runs /usr/bin/bash too"
# The uninstall above removed the CLI symlink the next block checks, so put it back the same way.
KEMPT_INSTALL_ECHO=1 bash "$INSTALL" <<<"n" >/dev/null 2>&1 || true

# Real mode is also what a user runs to UPDATE an install, and it must say that the checkout
# stays load-bearing (only the root helpers are copies).
assert_exit 0 "real mode symlinks the CLI into ~/.local/bin" -- test -L "$HOME/.local/bin/kempt"
assert_eq "$(readlink "$HOME/.local/bin/kempt")" "$REPO_ROOT/bin/kempt" "real mode symlink points into the checkout"
grep -q "don't move/delete the repo" <<<"$out" \
  && echo "ok: says the checkout is load-bearing" || { echo "FAIL: no checkout warning - got: $out"; _fail=1; }

# --- wrong outcomes: what the installer SAYS when the auth dialog is dismissed. KEMPT_INSTALL_ECHO=fail
# makes the printed pkexec report failure, which is the only way to reach these paths unprivileged.
irc=0
iout="$(KEMPT_INSTALL_ECHO=fail bash "$INSTALL" </dev/null 2>&1)" || irc=$?
assert_eq "$irc" "1" "a declined install exits 1, not a bare pkexec rc"
grep -q 'root helpers are NOT installed' <<<"$iout" \
  && echo "ok: a declined install says the helpers are missing" || { echo "FAIL: install failure message - got: $iout"; _fail=1; }
# The widget arm sits after the root step, so a declined dialog skips it too. Skipping is right (a
# widget with no root helpers can only ever show a failed check), but it must be SAID, not silent.
grep -q 'panel widget was not installed either' <<<"$iout" \
  && echo "ok: ...and that the widget was skipped along with them" || { echo "FAIL: declined install does not mention the widget - got: $iout"; _fail=1; }
urc=0
uout="$(KEMPT_INSTALL_ECHO=fail bash "$INSTALL" --uninstall 2>&1)" || urc=$?
assert_eq "$urc" "1" "a declined uninstall exits 1, not a bare pkexec rc"
grep -q 'the CLI symlink is gone, but' <<<"$uout" \
  && echo "ok: a declined uninstall names the half-removed state" || { echo "FAIL: uninstall failure message - got: $uout"; _fail=1; }
grep -q 're-run ./install.sh --uninstall' <<<"$uout" \
  && echo "ok: ...and says how to finish" || { echo "FAIL: no recovery instruction - got: $uout"; _fail=1; }

# --- the notifier question. "no" must mean no: `!= "n"` used to read the word "no" as consent.
# Yes runs `kempt discover-notifier off`, the command the widget runs (tests/test_discover_notifier.sh
# covers the command itself). The sandbox's pgrep and pkill seams find and stop nothing.
export KEMPT_XDG_AUTOSTART_DIR="$TESTTMP/xdg-autostart"; mkdir -p "$KEMPT_XDG_AUTOSTART_DIR"
printf '[Desktop Entry]\nType=Application\nName=Discover Notifier\nExec=/usr/bin/DiscoverNotifier\nHidden=false\nX-KDE-autostart-phase=2\n' \
  > "$KEMPT_XDG_AUTOSTART_DIR/org.kde.discover.notifier.desktop"
USER_AUTOSTART="$HOME/.config/autostart/org.kde.discover.notifier.desktop"
# Test mode on a real desktop: without a directory named for it, yes prints the command and writes
# nothing, wherever XDG_CONFIG_HOME points.
yout="$(KEMPT_INSTALL_ECHO=1 bash "$INSTALL" <<<"y")"
assert_contains "$yout" "$REPO_ROOT/bin/kempt discover-notifier off" "test mode with no directory named prints the command"
assert_exit 0 "...and writes no autostart entry" -- test ! -e "$USER_AUTOSTART"
assert_exit 0 "...and records no answer" -- test ! -e "$KEMPT_STATE_DIR/discover-offer-answered"
export KEMPT_INSTALL_CONFIG_HOME="$XDG_CONFIG_HOME"
assert_exit 0 "declining with n writes nothing" -- test ! -e "$USER_AUTOSTART"
nout_no="$(KEMPT_INSTALL_ECHO=1 bash "$INSTALL" <<<"no")"
assert_exit 0 "declining with the word 'no' writes nothing either" -- test ! -e "$USER_AUTOSTART"
grep -q 'is left on' <<<"$nout_no" && echo "ok: and it says the notifier is still on" || { echo "FAIL: no-answer message - got: $nout_no"; _fail=1; }
grep -q 'kempt discover-notifier off' <<<"$nout_no" && echo "ok: ...and how to turn it off later" || { echo "FAIL: no command named - got: $nout_no"; _fail=1; }
grep -q 'notifier is off' <<<"$nout_no" && { echo "FAIL: 'no' turned the notifier off anyway"; _fail=1; } \
  || echo "ok: 'no' never claims it turned anything off"
yout="$(KEMPT_INSTALL_ECHO=1 bash "$INSTALL" <<<"y")"
assert_exit 0 "accepting writes the override" -- test -f "$USER_AUTOSTART"
assert_exit 0 "...records the answer inside the named directory" -- test -e "$KEMPT_INSTALL_CONFIG_HOME/kempt-state/discover-offer-answered"
assert_exit 0 "...and nothing in the usual state directory" -- test ! -e "$KEMPT_STATE_DIR/discover-offer-answered"
assert_eq "$(grep -c '^Hidden=' "$USER_AUTOSTART")" "1" "the override has one Hidden= line"
assert_eq "$(grep -c '^Hidden=true' "$USER_AUTOSTART")" "1" "...and it hides the notifier"
assert_eq "$(grep -c '^X-Kempt-Override=true' "$USER_AUTOSTART")" "1" \
  "...marked as Kempt's, so kempt discover-notifier on can remove it"
grep -q 'notifier is off' <<<"$yout" && echo "ok: accepting says the notifier is off" || { echo "FAIL: no confirmation - got: $yout"; _fail=1; }
# Already off: nothing to ask, and an answer of n is never read as "left on".
before="$(cat "$USER_AUTOSTART")"
aout="$(KEMPT_INSTALL_ECHO=1 bash "$INSTALL" <<<"n" 2>&1)"
assert_contains "$aout" "Discover's update notifier is already off." "with the notifier already off, the installer says so"
assert_not_contains "$aout" "left on" "...and never says it was left on"
assert_eq "$(cat "$USER_AUTOSTART")" "$before" "...and leaves the entry alone"
uout="$(KEMPT_INSTALL_ECHO=1 bash "$INSTALL" --uninstall 2>&1)"
assert_contains "$uout" "stays off. To turn it back on: $REPO_ROOT/bin/kempt discover-notifier on" \
  "uninstall says how to turn the notifier back on while Kempt's file keeps it off"
assert_eq "$(KEMPT_INSTALL_ECHO=1 "$REPO_ROOT/bin/kempt" discover-notifier on >/dev/null; echo "$?")" "0" \
  "...and the command turns it back on"
assert_exit 0 "...removing the installer's file" -- test ! -e "$USER_AUTOSTART"
uout="$(KEMPT_INSTALL_ECHO=1 bash "$INSTALL" --uninstall 2>&1)"
assert_not_contains "$uout" "Discover" "with the notifier on, uninstall says nothing about it"
# The file install.sh 0.1.7 wrote: uninstall's advice works on it too.
{ grep -v '^Hidden=' "$KEMPT_XDG_AUTOSTART_DIR/org.kde.discover.notifier.desktop"; echo Hidden=true; } > "$USER_AUTOSTART"
uout="$(KEMPT_INSTALL_ECHO=1 bash "$INSTALL" --uninstall 2>&1)"
assert_contains "$uout" "To turn it back on" "uninstall names on for the file install.sh 0.1.7 wrote"
"$REPO_ROOT/bin/kempt" discover-notifier on >/dev/null
assert_exit 0 "...and on removes that file" -- test ! -e "$USER_AUTOSTART"
KEMPT_INSTALL_ECHO=1 bash "$INSTALL" <<<"n" >/dev/null 2>&1 || true

# A person's own entry, there before the installer: kept, and put back by on.
mkdir -p "$(dirname "$USER_AUTOSTART")"
printf '[Desktop Entry]\nType=Application\nX-Own=1\n' > "$USER_AUTOSTART"
KEMPT_INSTALL_ECHO=1 bash "$INSTALL" <<<"" >/dev/null
assert_eq "$(grep -c '^Hidden=true' "$USER_AUTOSTART")" "1" "an empty answer is yes, over the person's own entry too"
assert_eq "$(cat "$USER_AUTOSTART.before-kempt")" $'[Desktop Entry]\nType=Application\nX-Own=1' \
  "...which is kept beside it"
"$REPO_ROOT/bin/kempt" discover-notifier on >/dev/null
assert_eq "$(cat "$USER_AUTOSTART")" $'[Desktop Entry]\nType=Application\nX-Own=1' "...and put back by on"
rm -f "$USER_AUTOSTART"

# ...and neither does having nobody to ask. The notifier is never turned off silently, so a
# piped or redirected stdin must leave it as it was.
nout="$(KEMPT_INSTALL_ECHO=1 bash "$INSTALL" </dev/null)"
assert_exit 0 "a non-interactive install never turns the notifier off" -- test ! -e "$USER_AUTOSTART"
grep -q 'left on' <<<"$nout" && echo "ok: and it says so" || { echo "FAIL: silent skip - got: $nout"; _fail=1; }
grep -q 'notifier is off' <<<"$nout" && { echo "FAIL: the notifier was turned off without an answer"; _fail=1; } \
  || echo "ok: nothing was turned off"

# Without Discover installed, yes changes nothing and says so.
rm -f "$KEMPT_XDG_AUTOSTART_DIR/org.kde.discover.notifier.desktop"
yout="$(KEMPT_INSTALL_ECHO=1 bash "$INSTALL" <<<"y")"
assert_exit 0 "with no notifier installed, yes writes nothing" -- test ! -e "$USER_AUTOSTART"
grep -q 'not installed' <<<"$yout" && echo "ok: ...and says it is not installed" || { echo "FAIL: got: $yout"; _fail=1; }
export KEMPT_XDG_AUTOSTART_DIR="$TESTTMP/no-system-autostart"

# Sourced from here on: install.sh only runs main when executed.
source "$INSTALL"

# --- the panel widget arm (sourced, with a stub kpackagetool6) ---------------------------------
# The real kpackagetool6 is never run here: it writes into the user's plasmoids directory and
# talks to the running plasmashell. KEMPT_KPACKAGETOOL points at a stub that records its
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
case " \$* " in *" -i "*) echo "io.github.erez_c137.kempt already exists" >&2; exit 1 ;; esac
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$TESTTMP/kp-broken"
chmod +x "$TESTTMP/kp-ok" "$TESTTMP/kp-already" "$TESTTMP/kp-broken"

: > "$TESTTMP/kp-calls"
KEMPT_KPACKAGETOOL="$TESTTMP/kp-ok" widget_install > "$TESTTMP/wout" 2>&1
assert_eq "$(grep -c '' "$TESTTMP/kp-calls")" "1" "a first install calls kpackagetool6 exactly once"
assert_eq "$(cat "$TESTTMP/kp-calls")" "-t Plasma/Applet -i $REPO_ROOT/plasmoid" \
  "...as an Applet install of the repo's own plasmoid tree"
grep -q 'Add Widgets' "$TESTTMP/wout" && echo "ok: and it says how to actually put the widget on the panel" \
  || { echo "FAIL: no instruction after install - got: $(cat "$TESTTMP/wout")"; _fail=1; }
grep -q 'COPY' "$TESTTMP/wout" && echo "ok: ...and that the widget, unlike the CLI, is a copy" \
  || { echo "FAIL: does not say the widget is a copy - got: $(cat "$TESTTMP/wout")"; _fail=1; }
# The icon is installed into a theme directory that a plasmashell started before it existed will
# not have in its search list. The signal below fixes that for a running session; the way out when
# it does not (no session bus, a shell that ignores it) is a log-out, and the user has to be told.
grep -qi 'log out' "$TESTTMP/wout" && echo "ok: ...and how to get the icon to appear if the session missed the reload" \
  || { echo "FAIL: no log-out fallback after installing the icon - got: $(cat "$TESTTMP/wout")"; _fail=1; }

# A first install must NOT tell anybody to restart their shell: there is nothing loaded yet.
grep -qF -- 'plasmashell --replace' "$TESTTMP/wout" \
  && { echo "FAIL: a first install tells the user to restart plasmashell - got: $(cat "$TESTTMP/wout")"; _fail=1; } \
  || echo "ok: ...and a FIRST install says nothing about restarting the shell"

# Re-running the installer is how a user updates: -i refuses, -u has to pick it up.
: > "$TESTTMP/kp-calls"
KEMPT_KPACKAGETOOL="$TESTTMP/kp-already" widget_install > "$TESTTMP/uout" 2>&1
assert_eq "$(grep -c '' "$TESTTMP/kp-calls")" "2" "an already-installed widget falls back to the upgrade path"
assert_eq "$(sed -n 2p "$TESTTMP/kp-calls")" "-t Plasma/Applet -u $REPO_ROOT/plasmoid" \
  "...and the fallback is -u against the same tree"
# An upgrade swaps the files under a plasmashell that already has the old ones loaded, and nothing
# makes it re-read them - the applet keeps running the QML it started with. The alternative (remove
# then install) would take every placed instance of the widget off the user's panels, so the fix is
# to say so. Only on the upgrade path: the assertion above pins that a first install stays quiet.
grep -qF -- "plasmashell --replace" "$TESTTMP/uout" \
  && echo "ok: ...and an upgrade says how to reload the running session" \
  || { echo "FAIL: an upgrade gives no restart hint - got: $(cat "$TESTTMP/uout")"; _fail=1; }
grep -qF -- "the widget was upgraded in a running session" "$TESTTMP/uout" \
  && echo "ok: ...saying plainly that this was an upgrade, not a fresh install" \
  || { echo "FAIL: the upgrade hint does not say what happened - got: $(cat "$TESTTMP/uout")"; _fail=1; }

# The CLI is the product. A box with no kpackagetool6 (no Plasma at all, or a KDE-less server)
# must still finish the install, and must SAY the widget was skipped rather than imply it worked.
rc=0
out="$(KEMPT_KPACKAGETOOL="$TESTTMP/no-such-kpackagetool" widget_install 2>&1)" || rc=$?
assert_eq "$rc" "0" "a missing kpackagetool6 never fails the install"
grep -q 'NOT installed' <<<"$out" && echo "ok: and it says the widget was skipped" \
  || { echo "FAIL: silent widget skip - got: $out"; _fail=1; }
rc=0
out="$(KEMPT_KPACKAGETOOL="$TESTTMP/kp-broken" widget_install 2>&1)" || rc=$?
assert_eq "$rc" "0" "a kpackagetool6 that fails both ways never fails the install either"
grep -q 'CLI is installed and working' <<<"$out" && echo "ok: and it says what still works" \
  || { echo "FAIL: unhelpful widget failure - got: $out"; _fail=1; }

# Uninstall addresses the package by id, and a widget that was never installed is not an error.
: > "$TESTTMP/kp-calls"
KEMPT_KPACKAGETOOL="$TESTTMP/kp-ok" widget_uninstall >/dev/null 2>&1
assert_eq "$(cat "$TESTTMP/kp-calls")" "-t Plasma/Applet -r io.github.erez_c137.kempt" \
  "uninstall removes the widget by the id in metadata.json"
assert_eq "$(jq -r .KPlugin.Id "$REPO_ROOT/plasmoid/metadata.json")" "io.github.erez_c137.kempt" \
  "...and that id is the one the package actually declares"
rc=0
KEMPT_KPACKAGETOOL="$TESTTMP/kp-broken" widget_uninstall >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "removing a widget that was never installed is not a failure"

# ...and the whole arm is covered by the echo seam, so no test anywhere in this suite can reach
# a real kpackagetool6 and write into somebody's plasmoids directory.
: > "$TESTTMP/kp-calls"
wout="$(KEMPT_KPACKAGETOOL="$TESTTMP/kp-ok" KEMPT_INSTALL_ECHO=1 bash "$INSTALL" </dev/null)"
grep -qF -- "$TESTTMP/kp-ok -t Plasma/Applet -i $REPO_ROOT/plasmoid" <<<"$wout" \
  && echo "ok: echo mode prints the kpackagetool command" || { echo "FAIL: widget arm missing from echo mode - got: $wout"; _fail=1; }
assert_eq "$(grep -c '' "$TESTTMP/kp-calls" || true)" "0" "echo mode PRINTS the widget install without running it"

# The icon-cache reload. plasmashell computes its icon theme's directory list once, at startup, so
# a session that was already running when ~/.local/share/icons/hicolor first appeared goes on
# drawing the unknown-icon placeholder in Add Widgets even though `kiconfinder6 kempt` resolves
# perfectly in a fresh process. This signal is the standard way to tell it to look again.
grep -qF -- "--session --type=signal /KIconLoader org.kde.KIconLoader.iconChanged int32:0" <<<"$wout" \
  && echo "ok: installing the icon signals running KIconLoaders to re-scan the theme" \
  || { echo "FAIL: no icon-cache reload signal in echo mode - got: $wout"; _fail=1; }
# ...through dbus-send by default. The suite points KEMPT_DBUS_SEND at /usr/bin/true (lib.sh), so
# the line above proves the SHAPE of the command and this proves what really sends it.
grep -q 'KEMPT_DBUS_SEND:-dbus-send' "$INSTALL" \
  && echo "ok: ...and the default sender is dbus-send" \
  || { echo "FAIL: install.sh no longer defaults KEMPT_DBUS_SEND to dbus-send"; _fail=1; }
# hicolor is MERGED into whatever icon theme is loaded, so it needs no index.theme of its own -
# and shipping one would be this project describing a theme it does not own.
assert_exit 1 "the installer adds no index.theme to hicolor, which merges without one" \
  -- test -e "$D$HOME/.local/share/icons/hicolor/index.theme"
finish
