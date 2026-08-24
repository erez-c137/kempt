#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/backends/flatpak.sh"

# Fixture contract (MANIFEST.md): 3 pending apps; com.example.NotInstalled is absent from flatpak-list.tsv.
out="$(flatpak_parse_remote_ls "$FIXTURES/flatpak-list.tsv" < "$FIXTURES/flatpak-remote-ls.txt")"
assert_eq "$(jq 'length' <<<"$out")" "3" "three pending flatpaks"
assert_eq "$(jq -r '.[0] | has("name") and has("from") and has("to")' <<<"$out")" "true" "item shape"
assert_eq "$(jq -r '.[] | select(.name == "com.example.NotInstalled") | .from' <<<"$out")" "?" "not-installed app falls back to ?"

# Nothing pending is the COMMON case, not an error: the parser must yield [] and exit 0.
prc=0
empty_out="$(flatpak_parse_remote_ls "$FIXTURES/flatpak-list.tsv" </dev/null)" || prc=$?
assert_eq "$prc" "0" "parser on empty stdin exits 0"
assert_json_eq "$empty_out" "[]" "parser on empty stdin → []"

export UPKEEP_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export UPKEEP_FLATPAK_LIST_CMD="cat $FIXTURES/flatpak-list.tsv"
got="$(flatpak_check)"
assert_eq "$(jq 'length' <<<"$got")" "3" "flatpak_check wires cmds→parser"

# Same ascending-set contract as the dnf side: consumers read the LAST element of a comma set as
# the newest version, and a plain sort puts 1.10 before 1.9.
printf 'org.x.App\t1.10\norg.x.App\t1.9\ncom.a.B\t2.0\n' > "$TESTTMP/fp-unsorted.tsv"
snap="$(UPKEEP_FLATPAK_LIST_CMD="cat $TESTTMP/fp-unsorted.tsv" flatpak_snapshot)"
assert_eq "$(awk -F'\t' '$1=="org.x.App"{print $2}' <<<"$snap")" "1.9,1.10" \
  "a flatpak version set collapses in version order too"
assert_eq "$(cut -f1 <<<"$snap" | paste -sd, -)" "com.a.B,org.x.App" \
  "app ids stay in byte order for join"

# Fully up-to-date box: remote-ls prints nothing, exits 0. Must NOT look like a failed check
# (Task 8 would misread a non-zero rc as "stale" on the most common state there is).
export UPKEEP_FLATPAK_REMOTE_CMD="true"
crc=0
none="$(flatpak_check)" || crc=$?
assert_eq "$crc" "0" "zero pending flatpak is success, not stale"
assert_json_eq "$none" "[]" "zero pending flatpak → empty items"

# A parser failure must survive the cleanup rm instead of being masked by its exit 0.
_real_parse="$(declare -f flatpak_parse_remote_ls)"
flatpak_parse_remote_ls() { return 3; }
assert_exit 3 "parser failure propagates past cleanup rm" flatpak_check
eval "$_real_parse"

# A broken installed-lookup must FAIL, not report every app as from="?".
export UPKEEP_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export UPKEEP_FLATPAK_LIST_CMD="false"
assert_exit 1 "failing installed-lookup is loud" flatpak_check
export UPKEEP_FLATPAK_LIST_CMD="cat $FIXTURES/flatpak-list.tsv"

export UPKEEP_FLATPAK_REMOTE_CMD="false"
assert_exit 1 "flatpak_check propagates failure" flatpak_check
finish
