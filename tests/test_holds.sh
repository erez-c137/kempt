#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
kempt_init_dirs

hold_add dnf vim-common
hold_add flatpak org.gimp.GIMP
hold_add dnf vim-common                      # idempotent
assert_eq "$(holds_all | wc -l)" "2" "no duplicate holds"
assert_eq "$(holds_for dnf)" "vim-common" "dnf holds listed"
assert_eq "$(holds_for flatpak)" "org.gimp.GIMP" "flatpak holds listed"
hold_remove dnf vim-common
assert_eq "$(holds_for dnf | wc -l)" "0" "unhold removes"
assert_eq "$(holds_for flatpak)" "org.gimp.GIMP" "unhold is scoped to backend"
assert_exit 0 "unhold absent is not an error" -- hold_remove dnf never-held
assert_eq "$(holds_all | wc -l)" "1" "removing an absent hold preserves other holds"
assert_exit 2 "hold name validated" hold_add dnf '*'
assert_eq "$(holds_all | wc -l)" "1" "rejected hold was not written"

# mark_held: annotate items with held:bool. Regression guard - jq evaluates the argument of
# index() against index()'s OWN input ($holds, an array), so .name must be bound to a $var
# first or the filter dies with "Cannot index array with string name".
# State here: flatpak holds org.gimp.GIMP; dnf holds nothing.
marked="$(mark_held flatpak <<<'[{"name":"org.gimp.GIMP"},{"name":"net.mkiol.SpeechNote"}]')"
assert_eq "$(jq -c '[.[] | {(.name): .held}]' <<<"$marked")" \
  '[{"org.gimp.GIMP":true},{"net.mkiol.SpeechNote":false}]' "mark_held flags only held items"
assert_eq "$(mark_held dnf <<<'[{"name":"vim-common"}]' | jq -c '.[0].held')" "false" \
  "mark_held with no holds for that backend"

# The writers' lock is released with `exec 7>&-`, and an `exec` with no command applies its
# redirections to the SHELL and KEEPS them. Written flat as `exec 7>&- 2>/dev/null`, every write
# through this lock also pointed the process's own stderr at /dev/null for the rest of its life -
# so the first `kempt hold`, `kempt unhold` or `kempt config set` in a run silently deafened
# everything after it. Nothing failed and nothing was logged; warnings simply stopped existing.
# A subshell, because the assertion is about what a whole process can still say after a write.
speaks_after() {  # code → whatever it manages to put on stderr afterwards
  bash -c 'set -euo pipefail; source "$1/lib/common.sh"; kempt_init_dirs
           eval "$2"
           echo "still speaking" >&2' _ "$REPO_ROOT" "$1" 2>&1 >/dev/null
}
assert_eq "$(speaks_after 'hold_add dnf lock-probe >/dev/null')" "still speaking" \
  "a process can still warn after taking and releasing the writers' lock"
assert_eq "$(speaks_after 'acquire_lock; release_lock')" "still speaking" \
  "...and after the update lock, which closes its descriptor the same way"
hold_remove dnf lock-probe
finish
