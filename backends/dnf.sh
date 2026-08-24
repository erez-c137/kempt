#!/usr/bin/env bash
# dnf5 backend. Pure parsers take stdin/files; impure funcs go through priv_* / overridable cmds.
# Requires lib/common.sh sourced first.

UPKEEP_DNF_INSTALLED_CMD="${UPKEEP_DNF_INSTALLED_CMD:-}"

dnf_installed_lookup() {  # → sorted TSV, ONE row per name, EVRs comma-joined (installonly pkgs — kernel*, gpg-pubkey — install multiple versions; without collapse_versions, join cross-products them into phantom updates)
  { if [[ -n "$UPKEEP_DNF_INSTALLED_CMD" ]]; then $UPKEEP_DNF_INSTALLED_CMD
    else rpm -qa --queryformat '%{NAME}\t%{EVR}\n' | sort; fi; } | collapse_versions
}

dnf_parse_check_update() {  # $1=installed TSV; stdin=dnf5 check-update lines → JSON [{name,from,to}]
  awk 'NF>=3 && $1 ~ /\.[A-Za-z0-9_]+$/ && $1 !~ /^#/ { n=$1; sub(/\.[^.]+$/, "", n); print n "\t" $2 }' \
  | sort -u \
  | join -t "$(printf '\t')" -a1 -e '?' -o '1.1,2.2,1.2' - "$1" \
  | jq -Rn '[inputs | split("\t") | {name:.[0], from:.[1], to:.[2]}]'
}

dnf_check() {  # → items JSON on stdout; non-zero on helper OR parser failure
  local out rc=0 lookup prc=0
  out="$(priv_refresh check)" || rc=$?
  if [[ $rc -ne 0 && $rc -ne 100 ]]; then return 1; fi
  lookup="$(mktemp)"; dnf_installed_lookup > "$lookup"
  # Capture BEFORE the cleanup: rm's exit 0 would otherwise mask a parser failure and hand
  # Task 8 an empty item list that looks like a successful "nothing pending" check.
  dnf_parse_check_update "$lookup" <<<"$out" || prc=$?
  rm -f "$lookup"
  return $prc
}

dnf_snapshot() { dnf_installed_lookup; }   # → TSV to stdout

dnf_reboot_needed() {  # → prints true|false
  local rc=0
  dnf5 needs-restarting -r >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 1 ]] && echo true || echo false
}
