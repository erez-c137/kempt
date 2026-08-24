#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
upkeep_init_dirs

hold_add dnf vim-common
hold_add flatpak org.gimp.GIMP
hold_add dnf vim-common                      # idempotent
assert_eq "$(holds_all | wc -l)" "2" "no duplicate holds"
assert_eq "$(holds_for dnf)" "vim-common" "dnf holds listed"
assert_eq "$(holds_for flatpak)" "org.gimp.GIMP" "flatpak holds listed"
hold_remove dnf vim-common
assert_eq "$(holds_for dnf | wc -l)" "0" "unhold removes"
assert_eq "$(holds_for flatpak)" "org.gimp.GIMP" "unhold is scoped to backend"
hold_remove dnf never-held                   # removing absent = ok, exit 0
assert_exit 0 "unhold absent is not an error" -- true

# mark_held: annotate items with held:bool. Regression guard — jq evaluates the argument of
# index() against index()'s OWN input ($holds, an array), so .name must be bound to a $var
# first or the filter dies with "Cannot index array with string name".
# State here: flatpak holds org.gimp.GIMP; dnf holds nothing.
marked="$(mark_held flatpak <<<'[{"name":"org.gimp.GIMP"},{"name":"net.mkiol.SpeechNote"}]')"
assert_eq "$(jq -c '[.[] | {(.name): .held}]' <<<"$marked")" \
  '[{"org.gimp.GIMP":true},{"net.mkiol.SpeechNote":false}]' "mark_held flags only held items"
assert_eq "$(mark_held dnf <<<'[{"name":"vim-common"}]' | jq -c '.[0].held')" "false" \
  "mark_held with no holds for that backend"
finish
