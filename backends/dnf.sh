#!/usr/bin/env bash
# dnf5 backend. Pure parsers take stdin/files; impure funcs go through priv_* / overridable cmds.
# Requires lib/common.sh sourced first.

UPKEEP_DNF_INSTALLED_CMD="${UPKEEP_DNF_INSTALLED_CMD:-}"
UPKEEP_DNF_CMD="${UPKEEP_DNF_CMD:-dnf5}"

dnf_installed_lookup() {  # → sorted TSV, ONE row per name, EVRs comma-joined (installonly pkgs - kernel*, gpg-pubkey - install multiple versions; without collapse_versions, join cross-products them into phantom updates)
  { if [[ -n "$UPKEEP_DNF_INSTALLED_CMD" ]]; then $UPKEEP_DNF_INSTALLED_CMD
    else rpm -qa --queryformat '%{NAME}\t%{EVR}\n' | sort; fi; } | collapse_versions
}

dnf_parse_check_update() {  # $1=installed TSV; stdin=dnf5 check-update lines → JSON [{name,from,to}]
  # Three filters, each load-bearing (see tests/fixtures/MANIFEST.md):
  #   /^[^[:space:]]/  column-0 anchor - dnf5 appends an "Obsoleting Packages" section whose rows
  #                    are INDENTED and otherwise column-identical to real updates. An obsoleted
  #                    package is being removed, not upgraded; reporting it invents a phantom
  #                    self-update for something the user is losing.
  #   $1 ~ arch        real update rows always carry a .arch suffix.
  #   $2 ~ EVR-shape   diagnostic/notice lines ("Last metadata expiration check: ...") reach
  #                    stdin on some paths and otherwise satisfy NF>=3.
  # collapse_versions on the PENDING side too: multilib twins routinely lag each other
  # (bash.x86_64 5.3.10-1 vs bash.i686 5.3.9-4), and sort -u only dedupes byte-identical rows,
  # so divergent twins would otherwise double-count as two separate updates of one package.
  awk '/^[^[:space:]]/ && NF>=3 && $1 ~ /\.[A-Za-z0-9_]+$/ \
       && $2 ~ /^([0-9]+:)?[^[:space:]]*[0-9][^[:space:]]*-[^[:space:]]+$/ \
       { n=$1; sub(/\.[^.]+$/,"",n); print n "\t" $2 }' \
  | sort -u | collapse_versions \
  | join -t "$(printf '\t')" -a1 -e '?' -o '1.1,2.2,1.2' - "$1" \
  | jq -Rn '[inputs | split("\t") | {name:.[0], from:.[1], to:.[2]}]'
}

dnf_check() {  # → items JSON on stdout; non-zero on helper OR parser failure
  local out rc=0 lookup prc=0
  out="$(priv_refresh check)" || rc=$?
  if [[ $rc -ne 0 && $rc -ne 100 ]]; then return 1; fi
  # A failed lookup must be loud: without this guard the join still succeeds against an empty
  # file and every package reports from="?" - a plausible-looking, entirely fabricated report.
  lookup="$(mktemp)"; dnf_installed_lookup > "$lookup" || { rm -f "$lookup"; return 1; }
  # Capture BEFORE the cleanup: rm's exit 0 would otherwise mask a parser failure and hand
  # Task 8 an empty item list that looks like a successful "nothing pending" check.
  dnf_parse_check_update "$lookup" <<<"$out" || prc=$?
  rm -f "$lookup"
  return $prc
}

dnf_snapshot() { dnf_installed_lookup; }   # → TSV to stdout

dnf_reboot_needed() {  # → prints true|false; -C = cache-only (needs-restarting otherwise does NETWORK I/O and can prompt on stdin)
  local rc=0
  $UPKEEP_DNF_CMD -C needs-restarting </dev/null >/dev/null 2>&1 || rc=$?
  case $rc in
    1) echo true ;;
    0) echo false ;;
    *) echo "warning: reboot check failed (rc=$rc)" >&2; echo false ;;
  esac
}
