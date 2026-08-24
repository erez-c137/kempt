#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/backends/flatpak.sh"

# Fixture contract (MANIFEST.md): 3 pending apps; com.example.NotInstalled is absent from flatpak-list.tsv.
out="$(flatpak_parse_remote_ls "$FIXTURES/flatpak-list.tsv" < "$FIXTURES/flatpak-remote-ls.txt")"
assert_eq "$(jq 'length' <<<"$out")" "3" "three pending flatpaks"
assert_eq "$(jq -r '.[0] | has("name") and has("from") and has("to")' <<<"$out")" "true" "item shape"
assert_eq "$(jq -r '.[] | select(.name == "com.example.NotInstalled") | .from' <<<"$out")" "?" "not-installed app falls back to ?"

export UPKEEP_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export UPKEEP_FLATPAK_LIST_CMD="cat $FIXTURES/flatpak-list.tsv"
got="$(flatpak_check)"
assert_eq "$(jq 'length' <<<"$got")" "3" "flatpak_check wires cmds→parser"

export UPKEEP_FLATPAK_REMOTE_CMD="false"
assert_exit 1 "flatpak_check propagates failure" flatpak_check
finish
