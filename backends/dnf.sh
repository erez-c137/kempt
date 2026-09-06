#!/usr/bin/env bash
# dnf5 backend. Pure parsers take stdin/files; impure funcs go through priv_* / overridable cmds.
# Requires lib/common.sh sourced first.

KEMPT_DNF_INSTALLED_CMD="${KEMPT_DNF_INSTALLED_CMD:-}"
KEMPT_DNF_CMD="${KEMPT_DNF_CMD:-dnf5}"
# Its own seam rather than a reuse of KEMPT_DNF_CMD: four test files point that one at a
# needs-restarting stub, and this query has nothing to do with restarts.
KEMPT_DNF_SIZES_CMD="${KEMPT_DNF_SIZES_CMD:-}"
# Which dnf5 metadata cache the size query reads. The shipped value is the one `kempt-refresh
# refresh` keeps current as root, and the only cache Kempt maintains; the seam is how a hermetic
# test drives both branches of dnf_sizes' readability guard.
KEMPT_DNF_SYSTEM_CACHE="${KEMPT_DNF_SYSTEM_CACHE:-/var/cache/libdnf5}"

dnf_installed_lookup() {  # → sorted TSV, ONE row per name, EVRs comma-joined ASCENDING (installonly pkgs - kernel*, gpg-pubkey - install multiple versions; without collapse_versions, join cross-products them into phantom updates)
  # Both branches share the SAME sort tail: a stub's rows must reach collapse_versions in the
  # ordering the real rpm path produces, or no test can see a version-ordering bug.
  { if [[ -n "$KEMPT_DNF_INSTALLED_CMD" ]]; then $KEMPT_DNF_INSTALLED_CMD
    else rpm -qa --queryformat '%{NAME}\t%{EVR}\n'; fi; } | sort_name_version | collapse_versions
}

dnf_parse_check_update() {  # $1=installed TSV; stdin=dnf5 check-update lines → JSON [{name,from,to}]
  # Three filters, each load-bearing (see tests/fixtures/MANIFEST.md):
  #   /^[^[:space:]]/  column-0 anchor - dnf5's "Obsoleting Packages" section is INDENTED and
  #                    otherwise column-identical. An obsoleted package is being REMOVED, so
  #                    reporting it invents a phantom self-update for something the user is losing.
  #   $1 ~ arch        real update rows always carry a .arch suffix.
  #   $2 ~ EVR-shape   diagnostic/notice lines ("Last metadata expiration check: ...") reach
  #                    stdin on some paths and otherwise satisfy NF>=3.
  # collapse_versions on the PENDING side too: multilib twins routinely lag each other
  # (bash.x86_64 5.3.10-1 vs bash.i686 5.3.9-4) and -u only drops rows matching on both keys, so
  # divergent twins would double-count as two updates of one package. sort_name_version rather than
  # a plain sort, for the reason its own comment in lib/common.sh gives.
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
  # Capture BEFORE the cleanup: rm's exit 0 would otherwise mask a parser failure, and an empty
  # item list looks exactly like a successful "nothing pending" check.
  dnf_parse_check_update "$lookup" <<<"$out" || prc=$?
  rm -f "$lookup"
  return $prc
}

# How many bytes the pending dnf updates would pull down, from metadata already on disk. No
# depsolve, no transaction, no network - the numbers are in the solv cache repoquery already loads.
#
# Four details, each of which is wrong in the obvious version of this command:
#   --latest-limit 1   MANDATORY, not an optimisation: `--upgrades` lists one row PER VERSION, so
#                      a package several releases behind counts many times over (27 rows for
#                      nodejs here, 1 with the limit).
#   downloadsize       the real tag name; `%{download_size}` is not a tag and is echoed back
#                      literally into every row.
#   $4 > 0             installed packages report 0 (the rpmdb does not keep the figure), so a row
#                      that resolved to @System must not count as "known".
#   per name+arch sum  the limit is per name.arch and multilib twins are BOTH downloaded, while the
#                      item pipeline strips the arch and collapses the pair - so summing here,
#                      before anything joins, is what keeps the second half.
# -C keeps it offline, exactly like every other question a check asks. NEVER remove it, and keep
# --setopt=cachedir with it: the size must come from the SAME metadata the check was answered from.
# `kempt check` lists updates through the ROOT helper against /var/cache/libdnf5 while this runs as
# the USER, whose ~/.cache/libdnf5 Kempt never fills, so a stale user cache returns no row for a
# name the check is reporting and the coverage rule then suppresses the figure altogether.
# (dnf_reboot_needed meets the same root-vs-user cache split from the other side.)
#
# ALWAYS returns 0, and that is the contract: under `set -o pipefail` a failing size command would
# become the CALLER's exit status, and the caller is a check that must answer whether or not this
# nicety worked. `timeout` is the other half of that. Failure is an empty table, which the coverage
# rule downstream reads as "not known".
# The format string MUST be a $'...' literal: dnf5 does not unescape \t itself, so "...\t..." hands
# it a backslash and a t, the output has ONE field, awk below finds no $4, and every size vanishes
# behind that same "unknown". test_dnf.sh pins the literal's spelling; the seam tests feed real
# tabs and cannot see it.
dnf_sizes() {  # → TSV name<TAB>bytes, one row per name, arches summed. EMPTY on any failure. rc 0.
  # An ARRAY, so an empty one contributes no argument at all and a path with a space in it stays
  # one. Guarded on readability rather than assumed: the directory is root-owned and a container or
  # a differently-packaged box may have no system cache. Unreadable falls back to the plain query
  # against whatever the user cache holds, and the coverage rule keeps hiding the partial answer.
  local cache=()
  [[ -r "$KEMPT_DNF_SYSTEM_CACHE" ]] && cache=(--setopt=cachedir="$KEMPT_DNF_SYSTEM_CACHE")
  # Both seams hold a COMMAND WITH ARGUMENTS, not a path, so the word-splitting is the point: tests
  # set KEMPT_DNF_CMD="<stub> --setopt=keepcache=1", and `kempt doctor` reads the executable back
  # out with ${KEMPT_DNF_CMD%% *}. Quoted, bash would look for one file whose name has a space in it.
  # shellcheck disable=SC2086
  { if [[ -n "$KEMPT_DNF_SIZES_CMD" ]]; then $KEMPT_DNF_SIZES_CMD
    else timeout 60 $KEMPT_DNF_CMD "${cache[@]}" -C repoquery --upgrades --latest-limit 1 \
           --qf $'%{name}\t%{arch}\t%{evr}\t%{downloadsize}\n' 2>/dev/null; fi; } \
  | awk -F'\t' '$4 ~ /^[0-9]+$/ && $4 > 0 { s[$1] += $4 }
                END { for (n in s) print n "\t" s[n] }' \
  | sort -t "$(printf '\t')" -k1,1 || true
  return 0
}

dnf_snapshot() { dnf_installed_lookup; }   # → TSV to stdout

dnf_reboot_needed() {  # → prints true|false, from purely LOCAL facts (rpm install times vs boot time)
  # -C keeps it offline: an uncached needs-restarting does NETWORK I/O and can prompt on stdin,
  # and this runs from detached surfaces where nobody is there to answer.
  #
  # --disablerepo='*' is what makes -C honest. Kempt fills only the ROOT cache (kempt-refresh
  # makecaches into /var/cache/libdnf5), so a cold ~/.cache/libdnf5 is the DEFAULT here. In that
  # state plain `dnf5 -C needs-restarting` prints nothing on stdout and exits 1 - which by exit
  # code alone reads as "a restart is owed" on every box that has never checked as this user. The
  # question needs no repo metadata at all, so disabling every repo gives the same verdict, and
  # gives it on a completely cold cache in about half a second.
  #
  # rc 1 therefore requires POSITIVE evidence on stdout: the command can exit non-zero having
  # computed no verdict at all, so `false` here means "nothing to say", never "no restart needed",
  # and the two collapse safely onto the same answer plus a warning.
  # Evidence means the thing itself, not "any non-whitespace on stdout" - every sentence dnf5 might
  # print satisfies that, and one line moved from stderr to stdout would restore the same permanent
  # false positive. So: the indented `  * <package>` list, or dnf5's own "Reboot is required"
  # sentence, either accepted alone, because each covers the other's drift.
  local out rc=0
  out="$($KEMPT_DNF_CMD -C --disablerepo='*' needs-restarting </dev/null 2>/dev/null)" || rc=$?
  case $rc in
    1) if grep -qE '^[[:space:]]+\* [^[:space:]]' <<<"$out" \
          || grep -qF 'Reboot is required' <<<"$out"; then echo true
       else echo "warning: reboot check could not answer (rc=1, no restart evidence)" >&2; echo false; fi ;;
    0) echo false ;;
    *) echo "warning: reboot check failed (rc=$rc)" >&2; echo false ;;
  esac
}
