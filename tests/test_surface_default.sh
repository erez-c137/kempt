#!/usr/bin/env bash
# The default for `surface`, and that the file decides whenever it names one.
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
KEMPT="$REPO_ROOT/bin/kempt"

assert_eq "$(kempt_default surface)" "popup" "updates run in the widget by default"
assert_eq "$(grep -o 'DEFAULT_SURFACE = "[a-z]*"' "$REPO_ROOT/plasmoid/contents/ui/logic.js")" \
  'DEFAULT_SURFACE = "popup"' "...and the widget's twin of that default agrees"

# A config with no surface line reads the default, and reading writes nothing.
mkdir -p "$KEMPT_CONFIG_DIR"; printf 'include_flatpak=false\n' > "$KEMPT_CONFIG_DIR/config"
assert_eq "$("$KEMPT" config get surface)" "popup" "a config that names no surface reads the default"
assert_eq "$(cat "$KEMPT_CONFIG_DIR/config")" "include_flatpak=false" "...and the file is unchanged"

for s in terminal popup offline; do
  printf 'surface=%s\nauto_accept=true\n' "$s" > "$KEMPT_CONFIG_DIR/config"
  before="$(cat "$KEMPT_CONFIG_DIR/config")"
  assert_eq "$("$KEMPT" config get surface)" "$s" "a config with surface=$s keeps it"
  assert_eq "$(cat "$KEMPT_CONFIG_DIR/config")" "$before" "...and the file is unchanged"
done

finish
