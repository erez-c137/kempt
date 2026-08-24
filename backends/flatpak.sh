#!/usr/bin/env bash
# flatpak backend. Same contract as dnf.sh. Requires lib/common.sh sourced first.

UPKEEP_FLATPAK_REMOTE_CMD="${UPKEEP_FLATPAK_REMOTE_CMD:-flatpak remote-ls --updates --app --columns=application,version}"
UPKEEP_FLATPAK_LIST_CMD="${UPKEEP_FLATPAK_LIST_CMD:-flatpak list --app --columns=application,version}"

# remote-ls with --columns=application,version may emit an empty version column, and a pending
# app can be missing from the installed lookup entirely. GNU join's `-a1 -e '?' -o` flags are the
# guard that fills both gaps — jq's `//` does NOT catch empty strings, so they are not redundant.
flatpak_parse_remote_ls() {  # $1=installed TSV (sorted); stdin=remote-ls lines → JSON [{name,from,to}]
  grep -vE '^(#|$)' \
  | sort -u \
  | join -t "$(printf '\t')" -a1 -e '?' -o '1.1,2.2,1.2' - "$1" \
  | jq -Rn '[inputs | split("\t") | {name:.[0], from:.[1], to:(.[2] // "?")}]'
}

flatpak_check() {  # → items JSON; exit 1 on failure
  local out lookup
  out="$($UPKEEP_FLATPAK_REMOTE_CMD)" || return 1
  lookup="$(mktemp)"; $UPKEEP_FLATPAK_LIST_CMD | sort | collapse_versions > "$lookup"
  flatpak_parse_remote_ls "$lookup" <<<"$out"
  rm -f "$lookup"
}

flatpak_snapshot() { $UPKEEP_FLATPAK_LIST_CMD | sort | collapse_versions; }   # same one-row-per-name contract as dnf
