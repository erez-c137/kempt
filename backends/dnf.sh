#!/usr/bin/env bash
# dnf5 backend. Pure parsers take stdin/files; impure funcs go through priv_* / overridable cmds.
# Requires lib/common.sh sourced first.

KEMPT_DNF_INSTALLED_CMD="${KEMPT_DNF_INSTALLED_CMD:-}"
KEMPT_DNF_CMD="${KEMPT_DNF_CMD:-dnf5}"

dnf_installed_lookup() {  # → sorted TSV, ONE row per name, EVRs comma-joined ASCENDING (installonly pkgs - kernel*, gpg-pubkey - install multiple versions; without collapse_versions, join cross-products them into phantom updates)
  # Both branches flow through the SAME sort tail. The seam branch used to bypass sorting
  # entirely, so a stub's row order reached collapse_versions untouched: no test could see the
  # ordering the real rpm path produces, and the version-order bug was invisible to the suite.
  { if [[ -n "$KEMPT_DNF_INSTALLED_CMD" ]]; then $KEMPT_DNF_INSTALLED_CMD
    else rpm -qa --queryformat '%{NAME}\t%{EVR}\n'; fi; } | sort_name_version | collapse_versions
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
  # (bash.x86_64 5.3.10-1 vs bash.i686 5.3.9-4), and -u only drops rows that match on both keys,
  # so divergent twins would otherwise double-count as two separate updates of one package.
  # sort_name_version, not a plain sort: that same pair is the one where lexical order puts the
  # OLDER build last, and last is what every consumer calls newest.
  awk '/^[^[:space:]]/ && NF>=3 && $1 ~ /\.[A-Za-z0-9_]+$/ \
       && $2 ~ /^([0-9]+:)?[^[:space:]]*[0-9][^[:space:]]*-[^[:space:]]+$/ \
       { n=$1; sub(/\.[^.]+$/,"",n); print n "\t" $2 }' \
  | sort_name_version -u | collapse_versions \
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

dnf_reboot_needed() {  # → prints true|false, from purely LOCAL facts (rpm install times vs boot time)
  # -C keeps it offline: an uncached needs-restarting does NETWORK I/O and can prompt on stdin,
  # and this runs from detached surfaces where nobody is there to answer.
  #
  # --disablerepo='*' is what makes -C honest. Kempt never fills the USER's ~/.cache/libdnf5 -
  # kempt-refresh runs `dnf5 makecache --refresh` as root, into /var/cache/libdnf5 - so a cold
  # user cache is the DEFAULT on a fresh install, not an edge case. In that state plain
  # `dnf5 -C needs-restarting` prints `Cache-only enabled but no cache for repository "fedora"`
  # on stderr, nothing at all on stdout, and exits 1. Mapped by exit code alone that reads as
  # "a restart is owed", on every box that has never checked as this user - a permanent false
  # positive, and the first thing a reader of the state key would show a human. Disabling every
  # repo is not a workaround for it: this question needs no repo metadata whatsoever, so the
  # verdict is the same verdict, and it is available on a completely cold cache in about half a
  # second (measured on this box, Fedora 44 / dnf5, six runs against six fresh empty HOMEs:
  # 0.48-0.54s). A warm plain -C takes about three times that, and answers no better.
  #
  # rc 1 therefore requires POSITIVE evidence - the package list on stdout. rc 1 with an empty
  # stdout is the command saying it could not work the answer out, and `false` here means
  # "nothing to say", never "no restart needed". The evidence for that reading is the case
  # described two paragraphs up: this command can exit non-zero having computed no verdict at
  # all, so a reader who treats its `false` as an affirmative "no restart is owed" is reading a
  # failure as an answer. The two therefore collapse safely onto the same answer plus a warning.
  local out rc=0
  out="$($KEMPT_DNF_CMD -C --disablerepo='*' needs-restarting </dev/null 2>/dev/null)" || rc=$?
  case $rc in
    1) if [[ -n "$out" ]]; then echo true
       else echo "warning: reboot check could not answer (rc=1, no output)" >&2; echo false; fi ;;
    0) echo false ;;
    *) echo "warning: reboot check failed (rc=$rc)" >&2; echo false ;;
  esac
}
