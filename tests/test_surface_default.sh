#!/usr/bin/env bash
# The popup default for `surface`, and the one-time migration that keeps an existing install on the
# terminal it had. Each case is a fresh state and config dir, because the migration runs once.
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
KEMPT="$REPO_ROOT/bin/kempt"

fresh() {  # → empty state and config dirs, as on a box that has never run this version
  rm -rf "$KEMPT_STATE_DIR" "$KEMPT_CONFIG_DIR"
}
used_before() {  # → a state dir an earlier version left: state.json and a history entry
  mkdir -p "$KEMPT_STATE_DIR/history"
  printf '{"schema":1,"status":"ok","actionable":0}\n' > "$KEMPT_STATE_DIR/state.json"
  printf '{"timestamp":"2026-09-01T10:00:00+03:00","surface":"terminal","status":"ok"}\n' \
    > "$KEMPT_STATE_DIR/history/20260901T100000.json"
}

assert_eq "$(kempt_default surface)" "popup" "a new install runs updates in the popup by default"
assert_eq "$(grep -o 'DEFAULT_SURFACE = "[a-z]*"' "$REPO_ROOT/plasmoid/contents/ui/logic.js")" \
  'DEFAULT_SURFACE = "popup"' "...and the widget's twin of that default agrees"

# --- a new install: no state, so no key and the new default -----------------------------------------
fresh
assert_eq "$("$KEMPT" config get surface)" "popup" "a new install reads the popup default"
assert_eq "$(grep -qs '^surface=' "$KEMPT_CONFIG_DIR/config" && echo yes || echo no)" "no" \
  "...with no surface key written"
assert_eq "$([[ -e "$KEMPT_STATE_DIR/surface-migrated" ]] && echo yes || echo no)" "yes" \
  "...and the migration recorded as done"
assert_eq "$([[ -e "$KEMPT_STATE_DIR/surface-offer" ]] && echo yes || echo no)" "no" \
  "...with nothing to offer"
# A new install that then runs updates has state.json from now on. It was never pinned, and it is
# not pinned later either.
used_before
assert_eq "$("$KEMPT" config get surface)" "popup" "...and a later run does not move it to the terminal"

# --- an install that has run Kempt before, with no surface key --------------------------------------
fresh; used_before
mkdir -p "$KEMPT_CONFIG_DIR"; printf 'include_flatpak=false\n' > "$KEMPT_CONFIG_DIR/config"
assert_eq "$("$KEMPT" config get surface)" "terminal" "an existing install keeps the terminal"
assert_eq "$(grep -c '^surface=terminal$' "$KEMPT_CONFIG_DIR/config")" "1" "...written into its config"
assert_eq "$(grep -c '^include_flatpak=false$' "$KEMPT_CONFIG_DIR/config")" "1" \
  "...beside the settings it already had"
assert_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "config set surface=terminal (was unset)" \
  "...through the normal config write, which logs it"
assert_eq "$([[ -e "$KEMPT_STATE_DIR/surface-offer" ]] && echo yes || echo no)" "yes" \
  "...and the popup owes it the offer"
assert_eq "$(surface_offer_pending && echo yes || echo no)" "yes" "...which is pending"

# Only a history entry, no state.json: still an install that has run Kempt.
fresh; mkdir -p "$KEMPT_STATE_DIR/history"
printf '{}\n' > "$KEMPT_STATE_DIR/history/20260901T100000.json"
assert_eq "$("$KEMPT" config get surface)" "terminal" "a history entry alone is enough to keep the terminal"
# Only a config file with a setting in it, as an install that never ran an update leaves.
fresh; mkdir -p "$KEMPT_CONFIG_DIR"; printf 'auto_accept=false\n' > "$KEMPT_CONFIG_DIR/config"
assert_eq "$("$KEMPT" config get surface)" "terminal" "a config file alone is enough to keep the terminal"
# ...but an empty one is what a first `config set` creates, and says nothing about an earlier version.
fresh; mkdir -p "$KEMPT_CONFIG_DIR"; : > "$KEMPT_CONFIG_DIR/config"
assert_eq "$("$KEMPT" config get surface)" "popup" "an empty config file is a new install"
# A new install's first command is a setting: the migration runs before it writes, so it stays new.
fresh
"$KEMPT" config set auto_accept false >/dev/null
assert_eq "$("$KEMPT" config get surface)" "popup" "a new install whose first command sets something keeps the popup"

# Every command runs it first, discover-notifier included.
fresh; used_before
KEMPT_XDG_AUTOSTART_DIR="$TESTTMP/no-autostart" "$KEMPT" discover-notifier status >/dev/null 2>&1 || true
assert_eq "$([[ -e "$KEMPT_STATE_DIR/surface-migrated" ]] && echo yes || echo no)|$(grep -c '^surface=terminal$' "$KEMPT_CONFIG_DIR/config" 2>/dev/null)" \
  "yes|1" "discover-notifier runs the migration like every other command"

# --- it runs once -----------------------------------------------------------------------------------
fresh; used_before
"$KEMPT" config get surface >/dev/null
sed -i '/^surface=/d' "$KEMPT_CONFIG_DIR/config"
assert_eq "$("$KEMPT" config get surface)" "popup" "the migration runs once: a key removed afterwards stays removed"
assert_eq "$(grep -c 'config set surface=' "$KEMPT_STATE_DIR/events.log")" "1" "...and it wrote once"

# --- a config that names a surface is never touched -------------------------------------------------
for s in terminal background popup offline; do
  fresh; used_before
  mkdir -p "$KEMPT_CONFIG_DIR"; printf 'surface=%s\nauto_accept=true\n' "$s" > "$KEMPT_CONFIG_DIR/config"
  before="$(cat "$KEMPT_CONFIG_DIR/config")"
  assert_eq "$("$KEMPT" config get surface)" "$s" "an existing install with surface=$s keeps it"
  assert_eq "$(cat "$KEMPT_CONFIG_DIR/config")" "$before" "...and its config file is unchanged"
  assert_eq "$([[ -e "$KEMPT_STATE_DIR/surface-offer" ]] && echo yes || echo no)" "no" \
    "...and nothing is offered to it"
done

# --- the offer is answered by choosing a surface ----------------------------------------------------
fresh; used_before
"$KEMPT" config get surface >/dev/null
"$KEMPT" config set auto_accept true
assert_eq "$([[ -e "$KEMPT_STATE_DIR/surface-offer" ]] && echo yes || echo no)" "yes" \
  "another setting leaves the offer pending"
"$KEMPT" config set surface terminal
assert_eq "$([[ -e "$KEMPT_STATE_DIR/surface-offer" ]] && echo yes || echo no)" "no" \
  "Keep the Terminal (config set surface terminal) answers it"
fresh; used_before
"$KEMPT" config get surface >/dev/null
"$KEMPT" config set surface popup
assert_eq "$([[ -e "$KEMPT_STATE_DIR/surface-offer" ]] && echo yes || echo no)" "no" \
  "Use the Popup (config set surface popup) answers it"
assert_eq "$("$KEMPT" config get surface)" "popup" "...and updates then run in the popup"
# A config edited by hand to another surface has answered it too, without a word to Kempt.
fresh; used_before
"$KEMPT" config get surface >/dev/null
sed -i 's/^surface=.*/surface=background/' "$KEMPT_CONFIG_DIR/config"
assert_eq "$(surface_offer_pending && echo yes || echo no)" "no" "a surface set by hand is not offered the popup"
assert_eq "$([[ -e "$KEMPT_STATE_DIR/surface-offer" ]] && echo yes || echo no)" "no" \
  "...and the marker goes with it"
sed -i 's/^surface=.*/surface=terminal/' "$KEMPT_CONFIG_DIR/config"
assert_eq "$(surface_offer_pending && echo yes || echo no)" "no" \
  "...so editing back to the terminal does not bring the offer back"

# --- a concurrent config set surface wins ------------------------------------------------------------
# The check for a surface line and the write are one step under the writers' lock. Here the lock is
# held while another writer puts surface=popup in, and the migration, waiting on the lock, must
# find that line rather than write over it.
fresh; used_before
mkdir -p "$KEMPT_CONFIG_DIR"; : > "$KEMPT_CONFIG_DIR/config"
kempt_init_dirs
exec 6>>"$WRITER_LOCK_FILE"; flock 6
"$KEMPT" config get surface > "$TESTTMP/race.out" 2>&1 &
race_pid=$!
sleep 0.5
printf 'surface=popup\n' >> "$KEMPT_CONFIG_DIR/config"
flock -u 6; exec 6>&-
wait "$race_pid"
assert_eq "$(cat "$KEMPT_CONFIG_DIR/config")" "surface=popup" \
  "a surface written while the migration waits for the lock is kept"
assert_eq "$([[ -e "$KEMPT_STATE_DIR/surface-offer" ]] && echo yes || echo no)" "no" \
  "...and nothing is offered"
assert_eq "$(config_set surface terminal if-absent; echo "rc=$?")" "rc=3" \
  "the if-absent write reports a key that is already there"

# --- what does not run it ---------------------------------------------------------------------------
fresh; used_before
"$KEMPT" --version >/dev/null
"$KEMPT" help >/dev/null
assert_eq "$([[ -e "$KEMPT_STATE_DIR/surface-migrated" ]] && echo yes || echo no)" "no" \
  "help and the version change nothing"
assert_eq "$([[ -e "$KEMPT_CONFIG_DIR/config" ]] && echo yes || echo no)" "no" "...not even the config"
"$KEMPT" nonsense >/dev/null 2>&1 || true
assert_eq "$([[ -e "$KEMPT_STATE_DIR/surface-migrated" ]] && echo yes || echo no)" "no" \
  "a mistyped command changes nothing either"

# An unreadable config cannot say whether it names a surface, so the migration waits for a run that
# can read it. Root reads everything, so this case means nothing there.
if [[ $EUID -ne 0 ]]; then
  fresh; used_before
  mkdir -p "$KEMPT_CONFIG_DIR"; printf 'surface=background\n' > "$KEMPT_CONFIG_DIR/config"
  chmod 000 "$KEMPT_CONFIG_DIR/config"
  "$KEMPT" config get surface >/dev/null 2>&1 || true
  chmod 644 "$KEMPT_CONFIG_DIR/config"
  assert_eq "$(cat "$KEMPT_CONFIG_DIR/config")" "surface=background" "an unreadable config is not written"
  assert_eq "$([[ -e "$KEMPT_STATE_DIR/surface-migrated" ]] && echo yes || echo no)" "no" \
    "...and the migration tries again next run"
  assert_eq "$("$KEMPT" config get surface)" "background" "...where it finds the surface and keeps it"
fi

finish
