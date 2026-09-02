#!/usr/bin/env bash
# Kempt installer. `--destdir <dir>` stages everything unprivileged (for tests and packaging);
# real mode symlinks the CLI into ~/.local/bin and installs the root helpers + polkit action with
# ONE pkexec prompt. `--uninstall` reverses either mode.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# LIBEXEC_DIR must match the polkit action's exec.path annotation (polkit/io.github.erez_c137.kempt.policy)
# and lib/common.sh's KEMPT_{REFRESH,APPLY}_HELPER defaults, and RULES_FILE must match bin/kempt's
# RULES_DST. The root install script below repeats these as LITERALS on purpose (it must not
# interpolate anything) - change one, change the other.
LIBEXEC_DIR=/usr/local/libexec
ACTIONS_DIR=/usr/share/polkit-1/actions
RULES_FILE=/etc/polkit-1/rules.d/49-kempt.rules
POLICY=io.github.erez_c137.kempt.policy
# Must match plasmoid/metadata.json's KPlugin.Id - kpackagetool6 addresses the installed package
# by that id, and a mismatch would install one widget and remove a different one.
PLASMOID_ID=io.github.erez_c137.kempt
# Test seam, same shape as the others: point it at a stub to exercise the widget arm without a
# desktop, or at a missing path to exercise the "not installed" branch.
KEMPT_KPACKAGETOOL="${KEMPT_KPACKAGETOOL:-kpackagetool6}"
# metadata.json asks for the icon by NAME ("kempt"), and a name is resolved through the XDG icon
# theme - NOT through the package. Measured on Plasma 6.7 with Breeze loaded: an icon sitting in
# the installed package's contents/icons/ does not resolve from its name at all; it only resolves
# if something has added that directory to QIcon's fallback search paths, and nothing does. So the
# same SVG is also installed into the user's hicolor theme, which is the standard route and the
# one that actually makes the icon appear in Add Widgets. User-level, no authentication.
ICON_THEME_BASE="$HOME/.local/share/icons/hicolor"
# ...and it is installed as a SIZE LADDER, the way Breeze ships one (breeze/apps/16, /22, /32,
# /48, /64 are five different drawings, not one file scaled five ways). A comb fine enough to
# read as a comb at 256 px is grey mush at 32, so each band gets the drawing that survives it:
#   scalable  the 17-element fine comb, a measured redraw of the founder's reference photo
#   64 + 48   the same comb at 7 teeth, the most that hold 2 solid device pixels at 48 px
#   32        the six-tooth drawing, exact on the 32 px grid
#   22 + 16   hand-hinted five-tooth drawings authored on the 22 and 16 px grids themselves
#             (viewBox 22 and 16, not 256), because no arrangement of a 256-unit grid lands on
#             whole device pixels at those sizes - the same reason the symbolic glyphs are
#             hand-hinted per size, and they share those glyphs' 2 px tooth / 1 px gap grid.
# One name, "kempt", resolves to all of them: an XDG icon theme picks the directory whose size
# matches the request, and hicolor's index.theme lists every fixed-size dir before scalable/apps,
# so an exact-size dir wins. Verified on this box with kiconfinder6 - see
# docs/research/brand/README.md for the queries and their output.
# "<hicolor size dir>:<drawing under plasmoid/contents/icons/>"
ICON_LADDER=(
  "scalable:kempt.svg"
  "64x64:kempt-48.svg"
  "48x48:kempt-48.svg"
  "32x32:kempt-32.svg"
  "22x22:kempt-22.svg"
  "16x16:kempt-16.svg"
)
# ...and the signal that makes a RUNNING desktop notice it. Measured on this box: after the SVG
# above was installed, `kiconfinder6 kempt` resolved it immediately in a fresh process, while
# plasmashell - started days earlier, before ~/.local/share/icons/hicolor existed - went on
# drawing the unknown-icon placeholder in Add Widgets. It computes its icon theme's directory
# list once at startup. org.kde.KIconLoader.iconChanged is the standard broadcast that tells
# every KIconLoader in the session to rebuild that list; KDE's own installers emit it for the
# same reason. Best-effort and never fatal: a box with no session bus still installs fine, it
# just needs a log-out to see the icon. A seam so the suite never signals the real desktop.
KEMPT_DBUS_SEND="${KEMPT_DBUS_SEND:-dbus-send}"
# The system autostart entry the opt-out overrides. A seam so the copy source can be a fixture:
# with the real path hardcoded, every call re-copied the live system file over the test's own,
# and the "an existing Hidden= is replaced" case could never actually run.
KEMPT_AUTOSTART_SRC="${KEMPT_AUTOSTART_SRC:-/etc/xdg/autostart/org.kde.discover.notifier.desktop}"

# Test seam, same shape as libexec/kempt-apply's KEMPT_APPLY_ECHO: with KEMPT_INSTALL_ECHO=1
# the privileged (and process-killing) commands are PRINTED instead of run, so the real-mode
# path can be tested without ever touching /usr, /etc or somebody's running desktop.
# KEMPT_INSTALL_ECHO=fail additionally makes them REPORT failure - the only way to test what the
# installer says when someone dismisses the auth dialog.
run() {
  [[ -n "${KEMPT_INSTALL_ECHO:-}" ]] || { "$@"; return; }
  printf '%s\n' "$*"
  [[ "$KEMPT_INSTALL_ECHO" == fail ]] && return 1
  return 0
}

# Recommended opt-out: plasma-discover-notifier duplicates Kempt's notifications AND its
# background PackageKit activity takes the dnf5 lock at random, which makes Kempt runs fail
# spuriously (spec, survey C2). A user-level autostart entry with Hidden=true overrides the
# system one. Idempotent by construction: re-running the installer must never accumulate lines,
# and a system entry that already carries `Hidden=false` must be REPLACED, not joined - two
# Hidden= keys make an invalid desktop entry that parsers disagree about.
notifier_optout() {  # autostart_dir
  local dir="$1" src="$KEMPT_AUTOSTART_SRC" body
  local f="$dir/org.kde.discover.notifier.desktop"
  mkdir -p "$dir"
  # Seed from the system entry ONLY when there is nothing there yet: re-running the installer
  # must not overwrite an override the user has since edited by hand.
  [[ -f "$f" ]] || { [[ -f "$src" ]] && cp "$src" "$f"; } || true
  [[ -f "$f" ]] || printf '[Desktop Entry]\nType=Application\nName=Discover Notifier\n' > "$f"
  body="$(grep -v '^Hidden=' "$f")" || true
  printf '%sHidden=true\n' "${body:+$body$'\n'}" > "$f"
}

# --- the panel widget -------------------------------------------------------------------------
# kpackagetool6 is a USER-level tool: it copies the package into ~/.local/share/plasma/plasmoids
# and never asks for authentication, and installing a widget does NOT put it on anybody's panel -
# the user still has to add it. It does talk to the running desktop, though, so it goes through
# the same `run` seam as the privileged commands: a test prints the command instead of running it
# and no live plasmashell is ever touched by the suite.
# Neither function is ever fatal. The CLI is the product; a desktop without kpackagetool6 (or
# without Plasma at all) must still end up with a working `kempt`.
widget_install() {
  command -v "$KEMPT_KPACKAGETOOL" >/dev/null 2>&1 || {
    echo "note: $KEMPT_KPACKAGETOOL not found - the panel widget was NOT installed (the CLI works without it)"
    return 0
  }
  # -i refuses when the package is already installed and -u is the upgrade path, so trying -i
  # first and falling back to -u makes one command cover both a first install and an update.
  # WHICH of the two ran is worth remembering: only the upgrade needs the restart note below.
  local upgraded=0
  if run "$KEMPT_KPACKAGETOOL" -t Plasma/Applet -i "$ROOT/plasmoid" 2>/dev/null; then
    :
  elif run "$KEMPT_KPACKAGETOOL" -t Plasma/Applet -u "$ROOT/plasmoid"; then
    upgraded=1
  else
    echo "warning: could not install the panel widget - the CLI is installed and working; re-run ./install.sh to try the widget again" >&2
    return 0
  fi
  icon_install
  echo "Panel widget installed. Add it: right-click the panel > Add Widgets > search for Kempt."
  echo "note: the widget is a COPY (the CLI is a symlink) - re-run ./install.sh after changing plasmoid/."
  # An upgrade replaces the files under a plasmashell that already has the OLD ones loaded, and
  # nothing makes it re-read them: the applet keeps running the QML it started with, and a tray
  # entry can end up half-reloaded. Deliberately NOT solved by removing and re-installing the
  # package - kpackagetool6 -r takes every instance of the applet off the user's panels with it,
  # so a re-install would silently cost them the widget they had placed. Telling them how to
  # reload the session is the honest version of that trade.
  [[ $upgraded -eq 1 ]] && echo "note: the widget was upgraded in a running session - run 'plasmashell --replace' (or log out) so the tray entry reloads cleanly."
  return 0
}

widget_uninstall() {
  icon_uninstall
  command -v "$KEMPT_KPACKAGETOOL" >/dev/null 2>&1 || return 0
  # A widget that was never installed must not stop the rest of the uninstall.
  run "$KEMPT_KPACKAGETOOL" -t Plasma/Applet -r "$PLASMOID_ID" 2>/dev/null || true
}

# The application icon in the user's own hicolor theme - see ICON_THEME_BASE above for why the
# copy inside the package is not enough, and ICON_LADDER for why there are six of them. A plain
# file install, so it needs no seam and no `run`. The optional argument is a DESTDIR prefix: with
# one, this is staging a tree for a test or a package and must not touch the running session, so
# the reload signal and the log-out note are skipped.
icon_install() {  # [destdir prefix]
  local prefix="${1:-}" entry dir src installed=0
  for entry in "${ICON_LADDER[@]}"; do
    dir="${entry%%:*}"; src="${entry#*:}"
    [[ -f "$ROOT/plasmoid/contents/icons/$src" ]] || continue
    install -D -m 644 "$ROOT/plasmoid/contents/icons/$src" \
      "$prefix$ICON_THEME_BASE/$dir/apps/kempt.svg"
    installed=1
  done
  # Staging a DESTDIR tree must not touch the running session: no signal, no advice about it.
  # `if` rather than `[[ ... ]] && return`, which under `set -e` is a foot-gun the moment somebody
  # adds a line after it.
  if [[ -n "$prefix" || $installed -eq 0 ]]; then return 0; fi
  icon_reload
  echo "note: if the widget picker still shows a placeholder icon, log out and back in."
  return 0
}

icon_uninstall() {  # [destdir prefix]
  local prefix="${1:-}" entry dir
  for entry in "${ICON_LADDER[@]}"; do
    dir="${entry%%:*}"
    rm -f "$prefix$ICON_THEME_BASE/$dir/apps/kempt.svg"
  done
  if [[ -n "$prefix" ]]; then return 0; fi
  icon_reload
  return 0
}

# Tell every running KIconLoader in the session to re-scan the icon theme - see KEMPT_DBUS_SEND
# above for what this is really fixing. Deliberately NOT `hicolor/index.theme`: hicolor is merged
# into whatever theme is loaded, so the directory needs no theme file of its own and adding one
# would be a second, competing description of a theme this project does not own.
icon_reload() {
  command -v "$KEMPT_DBUS_SEND" >/dev/null 2>&1 || return 0
  run "$KEMPT_DBUS_SEND" --session --type=signal /KIconLoader org.kde.KIconLoader.iconChanged int32:0 \
    || true
}

main() {
  # Man page goes to the USER man hierarchy: `man kempt` finds it there, it needs no root, and
  # a symlink keeps it in step with the checkout the CLI already runs from. The one pkexec below
  # stays exactly as it was - a man page is not worth widening the privileged step.
  local DESTDIR="" UNINSTALL="" MAN1_DIR="$HOME/.local/share/man/man1"
  # Where kpackagetool6 puts a Plasma/Applet package for the current user. --destdir stages a
  # copy of the same tree there so packaging and tests can see the result without a desktop.
  local PLASMOID_DIR="$HOME/.local/share/plasma/plasmoids/$PLASMOID_ID"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --destdir) [[ -n "${2:-}" ]] || { echo "--destdir needs a value" >&2; exit 2; }; DESTDIR="$2"; shift 2 ;;
      --uninstall) UNINSTALL=1; shift ;;
      *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
  done

  if [[ -n "$UNINSTALL" ]]; then
    # A staged tree is unprivileged: tear it down with plain rm and no auth prompt. Only a REAL
    # install needs root, and only for the three root-owned files it created.
    if [[ -n "$DESTDIR" ]]; then
      rm -f "$DESTDIR$LIBEXEC_DIR/kempt-refresh" "$DESTDIR$LIBEXEC_DIR/kempt-apply" \
            "$DESTDIR$ACTIONS_DIR/$POLICY" "$DESTDIR$RULES_FILE" "$DESTDIR$HOME/.local/bin/kempt" \
            "$DESTDIR$MAN1_DIR/kempt.1"
      rm -rf "$DESTDIR$PLASMOID_DIR"
      icon_uninstall "$DESTDIR"
      echo "removed the staged install under $DESTDIR"
      exit 0
    fi
    rm -f "$HOME/.local/bin/kempt" "$MAN1_DIR/kempt.1"
    # Before the root step on purpose: a declined auth dialog exits below, and the widget removal
    # needs no authentication at all - there is no reason to make it a casualty of that.
    widget_uninstall
    # A declined auth prompt leaves a HALF-uninstalled system, and pkexec's own rc 126 says
    # nothing about that. Name the exact state and the exact way out.
    # The $1..$4 are the ROOT shell's positional parameters, filled from the arguments below. They
    # must NOT expand here: interpolating a checkout path into a script that runs as root is the
    # injection this form exists to prevent.
    # shellcheck disable=SC2016
    run pkexec bash -c 'rm -f "$1" "$2" "$3" "$4"' _ \
      "$LIBEXEC_DIR/kempt-refresh" "$LIBEXEC_DIR/kempt-apply" "$ACTIONS_DIR/$POLICY" "$RULES_FILE" \
      || { echo "root uninstall failed (authentication declined?) - the CLI symlink is gone, but $LIBEXEC_DIR/kempt-* and the polkit action are still installed; re-run ./install.sh --uninstall" >&2; exit 1; }
    echo "Kempt uninstalled (config/state in ~/.config/kempt, ~/.local/state/kempt left in place;"
    echo "  ~/.config/autostart/org.kde.discover.notifier.desktop also stays - delete it to let Discover's notifier run again)"
    exit 0
  fi

  if [[ -n "$DESTDIR" ]]; then
    install -D -m 755 "$ROOT/libexec/kempt-refresh" "$DESTDIR$LIBEXEC_DIR/kempt-refresh"
    install -D -m 755 "$ROOT/libexec/kempt-apply"   "$DESTDIR$LIBEXEC_DIR/kempt-apply"
    install -D -m 644 "$ROOT/polkit/$POLICY"         "$DESTDIR$ACTIONS_DIR/$POLICY"
    mkdir -p "$DESTDIR$HOME/.local/bin" "$DESTDIR$MAN1_DIR"
    ln -sfn "$ROOT/bin/kempt" "$DESTDIR$HOME/.local/bin/kempt"
    ln -sfn "$ROOT/docs/man/kempt.1" "$DESTDIR$MAN1_DIR/kempt.1"
    # The widget is a COPY of the tree, which is what kpackagetool6 does in real mode. Removing
    # first is what makes re-staging an update rather than a merge: a file deleted from the repo
    # must not survive in the staged package.
    rm -rf "$DESTDIR$PLASMOID_DIR"
    mkdir -p "$(dirname "$DESTDIR$PLASMOID_DIR")"
    cp -a "$ROOT/plasmoid" "$DESTDIR$PLASMOID_DIR"
    # ...and the icon ladder in the hicolor theme, which is what makes metadata.json's "kempt"
    # resolve - at every size, not just the scalable one.
    icon_install "$DESTDIR"
    echo "staged into $DESTDIR"
    exit 0
  fi

  mkdir -p "$HOME/.local/bin" "$MAN1_DIR"
  ln -sfn "$ROOT/bin/kempt" "$HOME/.local/bin/kempt"
  ln -sfn "$ROOT/docs/man/kempt.1" "$MAN1_DIR/kempt.1"
  # Paths passed as POSITIONAL ARGS, never interpolated into the root shell's script: a checkout
  # path containing a quote would otherwise break the command - or inject into it, as root.
  # mkdir -p first: a fresh Fedora box has no /usr/local/libexec at all.
  # $1..$3 belong to the ROOT shell and must survive this file unexpanded; see the uninstall
  # branch above for why interpolating them instead would be the bug.
  # shellcheck disable=SC2016
  run pkexec bash -c 'mkdir -p /usr/local/libexec \
  && install -m 755 -o root -g root "$1" "$2" /usr/local/libexec/ \
  && install -m 644 -o root -g root "$3" /usr/share/polkit-1/actions/' _ \
    "$ROOT/libexec/kempt-refresh" "$ROOT/libexec/kempt-apply" "$ROOT/polkit/$POLICY" \
    || { echo "root install failed (authentication declined?) - the CLI symlink is in place, but the root helpers are NOT installed and 'kempt check' will not work yet; the panel widget was not installed either. Re-run ./install.sh to finish both" >&2; exit 1; }
  echo "Installed. Try: kempt check   (reference: man kempt)"
  echo "note: the CLI runs from this checkout (symlink install) - don't move/delete the repo. Only the root helpers + policy are copies."

  # After the root step, deliberately. The widget needs no authentication, so it COULD go first
  # like widget_uninstall does - but a widget installed against missing root helpers is worse than
  # no widget: every check fails, and it sits in the panel showing a warning emblem forever. So a
  # declined auth dialog skips it, and the failure message above says so.
  widget_install

  # Recommended: stop Discover's notifier (duplicate nags + it holds the dnf5 lock at random).
  # An OFFER, never silent (spec), default yes. A failed read means there is nobody to ask
  # (piped or redirected stdin), and "nobody answered" must leave the notifier exactly as it was.
  local ans=""
  if ! read -rp "Disable plasma-discover-notifier for this user? [Y/n] " ans; then
    echo "note: nothing to read an answer from - plasma-discover-notifier left ENABLED. Re-run install.sh in a terminal to turn it off (recommended: it duplicates notifications and holds the dnf5 lock)."
    return 0
  fi
  # "no" must mean no: the old `!= "n"` test read the word "no" as consent.
  case "${ans,,}" in
    n|no)
      echo "plasma-discover-notifier left enabled (run ./install.sh again to change your mind)" ;;
    *)
      notifier_optout "$HOME/.config/autostart"
      run pkill -f DiscoverNotifier 2>/dev/null || true
      echo "DiscoverNotifier disabled for $(id -un) (delete $HOME/.config/autostart/org.kde.discover.notifier.desktop to undo)" ;;
  esac
}

# Sourced (by the tests) it defines functions only; executed it installs.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
