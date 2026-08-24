#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"

got="$(tsv_diff_updates "$FIXTURES/snap-before.tsv" "$FIXTURES/snap-after.tsv")"
expected='{
  "updated":[{"name":"kernel-core","from":"6.15.3-200.fc44","to":"6.15.4-200.fc44"},
             {"name":"vim-common","from":"2:9.1.900-1.fc44","to":"2:9.1.1000-1.fc44"}],
  "added":[{"name":"newpkg","to":"1.0-1.fc44"}],
  "removed":[{"name":"zsh","from":"5.9-11.fc44"}]
}'
assert_json_eq "$got" "$expected" "diff finds updated/added/removed, skips unchanged"

got2="$(tsv_diff_updates "$FIXTURES/snap-before.tsv" "$FIXTURES/snap-before.tsv")"
assert_json_eq "$got2" '{"updated":[],"added":[],"removed":[]}' "identical snapshots → empty"

# Regression guard: awk compares two "numeric string" fields NUMERICALLY, so a genuine
# 1.1 → 1.10 bump (plausible for flatpak --columns=version) reads as UNCHANGED and vanishes
# from the report unless string comparison is forced. RPM EVRs dodge this only because they
# always carry a release suffix; flatpak versions do not.
printf 'org.example.App\t1.1\n' > "$TESTTMP/numeric-before.tsv"
printf 'org.example.App\t1.10\n' > "$TESTTMP/numeric-after.tsv"
assert_json_eq "$(tsv_diff_updates "$TESTTMP/numeric-before.tsv" "$TESTTMP/numeric-after.tsv")" \
  '{"updated":[{"name":"org.example.App","from":"1.1","to":"1.10"}],"added":[],"removed":[]}' \
  "numeric-looking version bump (1.1 → 1.10) is not swallowed"

# --- installonly duplication (kernel*, gpg-pubkey): raw snapshots repeat names, and join on
# duplicate names emits a CROSS PRODUCT. Measured on this box: a self-diff of the real package
# list produced 192 phantom "updated" rows. Raw input must be REJECTED, not silently diffed.
RAW="$FIXTURES/snap-multiver-raw.tsv"
assert_exit 65 "raw multiver input rejected (as before-file)" tsv_diff_updates "$RAW" "$FIXTURES/snap-before.tsv"
assert_exit 65 "raw multiver input rejected (as after-file)"  tsv_diff_updates "$FIXTURES/snap-before.tsv" "$RAW"
assert_exit 65 "raw multiver input rejected (both files)"     tsv_diff_updates "$RAW" "$RAW"

# collapse_versions: one row per name, versions comma-joined in the order they arrive. Producers
# feed it through sort_name_version, so that order is ascending by version and the last element
# is the newest (see tests/test_dnf.sh for the pair where lexical order gets that backwards).
# This fixture's sets read the same either way, which is why they are not the ordering test.
collapse_versions < "$RAW" > "$TESTTMP/collapsed.tsv"
assert_eq "$(wc -l < "$TESTTMP/collapsed.tsv")" "3" "collapse_versions yields one row per name"
assert_eq "$(awk -F'\t' '$1=="gpg-pubkey"{print $2}' "$TESTTMP/collapsed.tsv")" \
  "11aa22bb-1111,33cc44dd-2222" "gpg-pubkey versions comma-joined"
assert_eq "$(awk -F'\t' '$1=="kernel-core"{print $2}' "$TESTTMP/collapsed.tsv")" \
  "6.15.3-200.fc44,6.15.4-200.fc44,6.15.5-200.fc44" "kernel-core versions comma-joined"
assert_eq "$(awk -F'\t' '$1=="zsh"{print $2}' "$TESTTMP/collapsed.tsv")" \
  "5.9-11.fc44" "single-version row survives collapsing unchanged"

# The bug this whole contract exists to kill: nothing changed → the report must be EMPTY.
assert_json_eq "$(tsv_diff_updates "$TESTTMP/collapsed.tsv" "$TESTTMP/collapsed.tsv")" \
  '{"updated":[],"added":[],"removed":[]}' "collapsed self-diff reports no phantom updates"

# Truth test: a real kernel rotation (6.15.3/4/5 → 6.15.4/5/6) is ONE updated row, and the
# untouched gpg-pubkey/zsh rows generate nothing.
printf 'gpg-pubkey\t11aa22bb-1111\ngpg-pubkey\t33cc44dd-2222\nkernel-core\t6.15.4-200.fc44\nkernel-core\t6.15.5-200.fc44\nkernel-core\t6.15.6-200.fc44\nzsh\t5.9-11.fc44\n' \
  > "$TESTTMP/multiver-after-raw.tsv"
collapse_versions < "$TESTTMP/multiver-after-raw.tsv" > "$TESTTMP/collapsed-after.tsv"
got3="$(tsv_diff_updates "$TESTTMP/collapsed.tsv" "$TESTTMP/collapsed-after.tsv")"
assert_json_eq "$got3" '{
  "updated":[{"name":"kernel-core",
              "from":"6.15.3-200.fc44,6.15.4-200.fc44,6.15.5-200.fc44",
              "to":"6.15.4-200.fc44,6.15.5-200.fc44,6.15.6-200.fc44"}],
  "added":[],"removed":[]
}' "kernel rotation = exactly one updated row, no phantoms"
finish
