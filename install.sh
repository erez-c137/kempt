#!/usr/bin/env bash
# Upkeep installer. `--destdir <dir>` stages everything unprivileged (for tests and packaging);
# real mode symlinks the CLI into ~/.local/bin and installs the root helpers + polkit action with
# ONE pkexec prompt. `--uninstall` reverses either mode.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# LIBEXEC_DIR must match the polkit action's exec.path annotation (polkit/org.erez.upkeep.policy)
# and lib/common.sh's UPKEEP_{REFRESH,APPLY}_HELPER defaults, and RULES_FILE must match bin/upkeep's
# RULES_DST. The root install script below repeats these as LITERALS on purpose (it must not
# interpolate anything) - change one, change the other.
LIBEXEC_DIR=/usr/local/libexec
ACTIONS_DIR=/usr/share/polkit-1/actions
RULES_FILE=/etc/polkit-1/rules.d/49-upkeep.rules
POLICY=org.erez.upkeep.policy
# The system autostart entry the opt-out overrides. A seam so the copy source can be a fixture:
# with the real path hardcoded, every call re-copied the live system file over the test's own,
# and the "an existing Hidden= is replaced" case could never actually run.
UPKEEP_AUTOSTART_SRC="${UPKEEP_AUTOSTART_SRC:-/etc/xdg/autostart/org.kde.discover.notifier.desktop}"

# Test seam, same shape as libexec/upkeep-apply's UPKEEP_APPLY_ECHO: with UPKEEP_INSTALL_ECHO=1
# the privileged (and process-killing) commands are PRINTED instead of run, so the real-mode
# path can be tested without ever touching /usr, /etc or somebody's running desktop.
# UPKEEP_INSTALL_ECHO=fail additionally makes them REPORT failure - the only way to test what the
# installer says when someone dismisses the auth dialog.
run() {
  [[ -n "${UPKEEP_INSTALL_ECHO:-}" ]] || { "$@"; return; }
  printf '%s\n' "$*"
  [[ "$UPKEEP_INSTALL_ECHO" == fail ]] && return 1
  return 0
}

# Recommended opt-out: plasma-discover-notifier duplicates Upkeep's notifications AND its
# background PackageKit activity takes the dnf5 lock at random, which makes Upkeep runs fail
# spuriously (spec, survey C2). A user-level autostart entry with Hidden=true overrides the
# system one. Idempotent by construction: re-running the installer must never accumulate lines,
# and a system entry that already carries `Hidden=false` must be REPLACED, not joined - two
# Hidden= keys make an invalid desktop entry that parsers disagree about.
notifier_optout() {  # autostart_dir
  local dir="$1" src="$UPKEEP_AUTOSTART_SRC" body
  local f="$dir/org.kde.discover.notifier.desktop"
  mkdir -p "$dir"
  # Seed from the system entry ONLY when there is nothing there yet: re-running the installer
  # must not overwrite an override the user has since edited by hand.
  [[ -f "$f" ]] || { [[ -f "$src" ]] && cp "$src" "$f"; } || true
  [[ -f "$f" ]] || printf '[Desktop Entry]\nType=Application\nName=Discover Notifier\n' > "$f"
  body="$(grep -v '^Hidden=' "$f")" || true
  printf '%sHidden=true\n' "${body:+$body$'\n'}" > "$f"
}

main() {
  # Man page goes to the USER man hierarchy: `man upkeep` finds it there, it needs no root, and
  # a symlink keeps it in step with the checkout the CLI already runs from. The one pkexec below
  # stays exactly as it was - a man page is not worth widening the privileged step.
  local DESTDIR="" UNINSTALL="" MAN1_DIR="$HOME/.local/share/man/man1"
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
      rm -f "$DESTDIR$LIBEXEC_DIR/upkeep-refresh" "$DESTDIR$LIBEXEC_DIR/upkeep-apply" \
            "$DESTDIR$ACTIONS_DIR/$POLICY" "$DESTDIR$RULES_FILE" "$DESTDIR$HOME/.local/bin/upkeep" \
            "$DESTDIR$MAN1_DIR/upkeep.1"
      echo "removed the staged install under $DESTDIR"
      exit 0
    fi
    rm -f "$HOME/.local/bin/upkeep" "$MAN1_DIR/upkeep.1"
    # A declined auth prompt leaves a HALF-uninstalled system, and pkexec's own rc 126 says
    # nothing about that. Name the exact state and the exact way out.
    run pkexec bash -c 'rm -f "$1" "$2" "$3" "$4"' _ \
      "$LIBEXEC_DIR/upkeep-refresh" "$LIBEXEC_DIR/upkeep-apply" "$ACTIONS_DIR/$POLICY" "$RULES_FILE" \
      || { echo "root uninstall failed (authentication declined?) - the CLI symlink is gone, but $LIBEXEC_DIR/upkeep-* and the polkit action are still installed; re-run ./install.sh --uninstall" >&2; exit 1; }
    echo "Upkeep uninstalled (config/state in ~/.config/upkeep, ~/.local/state/upkeep left in place;"
    echo "  ~/.config/autostart/org.kde.discover.notifier.desktop also stays - delete it to let Discover's notifier run again)"
    exit 0
  fi

  if [[ -n "$DESTDIR" ]]; then
    install -D -m 755 "$ROOT/libexec/upkeep-refresh" "$DESTDIR$LIBEXEC_DIR/upkeep-refresh"
    install -D -m 755 "$ROOT/libexec/upkeep-apply"   "$DESTDIR$LIBEXEC_DIR/upkeep-apply"
    install -D -m 644 "$ROOT/polkit/$POLICY"         "$DESTDIR$ACTIONS_DIR/$POLICY"
    mkdir -p "$DESTDIR$HOME/.local/bin" "$DESTDIR$MAN1_DIR"
    ln -sfn "$ROOT/bin/upkeep" "$DESTDIR$HOME/.local/bin/upkeep"
    ln -sfn "$ROOT/docs/man/upkeep.1" "$DESTDIR$MAN1_DIR/upkeep.1"
    echo "staged into $DESTDIR"
    exit 0
  fi

  mkdir -p "$HOME/.local/bin" "$MAN1_DIR"
  ln -sfn "$ROOT/bin/upkeep" "$HOME/.local/bin/upkeep"
  ln -sfn "$ROOT/docs/man/upkeep.1" "$MAN1_DIR/upkeep.1"
  # Paths passed as POSITIONAL ARGS, never interpolated into the root shell's script: a checkout
  # path containing a quote would otherwise break the command - or inject into it, as root.
  # mkdir -p first: a fresh Fedora box has no /usr/local/libexec at all.
  run pkexec bash -c 'mkdir -p /usr/local/libexec \
  && install -m 755 -o root -g root "$1" "$2" /usr/local/libexec/ \
  && install -m 644 -o root -g root "$3" /usr/share/polkit-1/actions/' _ \
    "$ROOT/libexec/upkeep-refresh" "$ROOT/libexec/upkeep-apply" "$ROOT/polkit/$POLICY" \
    || { echo "root install failed (authentication declined?) - the CLI symlink is in place, but the root helpers are NOT installed and 'upkeep check' will not work yet" >&2; exit 1; }
  echo "Installed. Try: upkeep check   (reference: man upkeep)"
  echo "note: the CLI runs from this checkout (symlink install) - don't move/delete the repo. Only the root helpers + policy are copies."

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
