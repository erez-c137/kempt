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
# The security advisory query (dnf_security_query). Unset means KEMPT_DNF_CMD. Its own seam for the
# reason the size query has one: the files that point KEMPT_DNF_CMD at a needs-restarting stub must
# not have that stub answer an advisory question too.
KEMPT_DNF_ADVISORY_CMD="${KEMPT_DNF_ADVISORY_CMD:-}"

dnf_installed_lookup() {  # → sorted TSV, ONE row per name, EVRs comma-joined ASCENDING (installonly pkgs - kernel*, gpg-pubkey - install multiple versions; without collapse_versions, join cross-products them into phantom updates)
  # Both branches share the SAME sort tail: a stub's rows must reach collapse_versions in the
  # ordering the real rpm path produces, or no test can see a version-ordering bug.
  { if [[ -n "$KEMPT_DNF_INSTALLED_CMD" ]]; then $KEMPT_DNF_INSTALLED_CMD
    else rpm -qa --queryformat '%{NAME}\t%{EVR}\n'; fi; } | sort_name_version | collapse_versions
}

# dnf5 5.4.0 and later print check-update as JSON, and the root helper asks for it there. The
# JSON's "upgrades" list is the whole answer: an obsoleted package appears only under
# "obsoleting_packages", which is not read. dnf5 prints {} when nothing is pending.
dnf_check_update_json_rows() {  # stdin=dnf5 check-update --json → name<TAB>evr rows; rc≠0 on any other shape
  jq -r 'if type != "object" then error("not an object") else . end
         | (.upgrades // []) | if type != "array" then error("upgrades is not a list") else .[] end
         | if (.name | type) == "string" and (.evr | type) == "string" then [.name, .evr] | @tsv
           else error("an upgrade without a name and evr") end'
}

dnf_parse_check_update() {  # $1=installed TSV; stdin=dnf5 check-update, text or JSON → JSON [{name,from,to}]
  # JSON starts with "{" (or "[" when it is the wrong shape) and the text never starts with either,
  # so the content decides and the helper's choice of format never has to match this file's.
  local in; in="$(cat)"
  # Three filters on the text, each load-bearing (see tests/fixtures/MANIFEST.md):
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
  if [[ "$in" =~ ^[[:space:]]*[{[] ]]; then dnf_check_update_json_rows <<<"$in"
  else
    awk '/^[^[:space:]]/ && NF>=3 && $1 ~ /\.[A-Za-z0-9_]+$/ \
         && $2 ~ /^([0-9]+:)?[^[:space:]]*[0-9][^[:space:]]*-[^[:space:]]+$/ \
         { n=$1; sub(/\.[^.]+$/,"",n); print n "\t" $2 }' <<<"$in"
  fi \
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

# Which pending system updates fix a security advisory, from the updateinfo already in the cache.
# Asked only for a person who turned notify_security on, and only after the dnf check answered.
# Cache-only (-C) and against the system cache, for the reasons dnf_sizes gives: no network, and
# the same metadata the check was answered from. dnf5 prints `[]` under exit 0 when nothing is due.
# The rows (dnf5 5.2.18 on Fedora 43 and 5.4 on Fedora 44 alike) are
#   {"name": "FEDORA-2026-...", "type": "security", "severity": "...", "nevra": "...", "buildtime": ...}
# where `name` is the ADVISORY id, not the package. Unlike dnf_sizes this one reports failure: a
# question nobody answered must not read as "no security updates".
dnf_security_query() {  # → dnf5's advisory list JSON; rc≠0 when dnf5 did not answer
  local cache=()
  [[ -r "$KEMPT_DNF_SYSTEM_CACHE" ]] && cache=(--setopt=cachedir="$KEMPT_DNF_SYSTEM_CACHE")
  # Unquoted on purpose: a seam holds a command with arguments (see dnf_sizes).
  # shellcheck disable=SC2086
  timeout "$SECURITY_QUERY_TIMEOUT" ${KEMPT_DNF_ADVISORY_CMD:-$KEMPT_DNF_CMD} "${cache[@]}" -C -q \
    advisory list --security --updates --json </dev/null 2>/dev/null
}

# The advisory rows, read against the pending dnf items (after mark_held). By content, never by
# position: the top level must be a list and every row an object with a string `name` and `nevra`,
# or the whole answer is refused (rc≠0), because a partly read answer would under-report. Ids that
# do not look like an advisory id are dropped. The package name is the NEVRA without its `.arch`
# and its `-[epoch:]version-release`. Output:
#   known       ids whose package is pending at all, held or not (what the seen file may keep)
#   open        ids whose package is pending and not held, all of them (what is announced)
#   advisories  the first 200 of those, sorted (what the state publishes and the widget acknowledges)
#   packages    those packages, as the pending items name them and in their order
# The names come from the items, never from the NEVRA, so they are the names the widget lists and
# have already passed KEMPT_NAME_RE.
dnf_security_parse() {  # $1=file holding the dnf items JSON; stdin=advisory JSON → JSON object
  jq -c --slurpfile items "$1" '
    def pkgname: sub("\\.[^.]*$"; "") | sub("-[^-]*-[^-]*$"; "");
    (reduce ($items[0] // [])[] as $i ({}; .[$i.name | tostring] = ($i.held == true))) as $pend
    | if type != "array" then error("not a list") else . end
    | map(if type == "object" and (.name | type) == "string" and (.nevra | type) == "string"
          then {id: .name, pkg: (.nevra | pkgname)} else error("a row without a name and nevra") end)
    | map(select(.id | test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$")))
    | unique
    | [.[] | select($pend[.pkg] != null)] as $known
    | [$known[] | select($pend[.pkg] == false)] as $open
    | ($open | map(.pkg) | unique) as $pkgs
    | { known: ($known | map(.id) | unique),
        open: ($open | map(.id) | unique),
        advisories: ($open | map(.id) | unique | .[:200]),
        packages: [($items[0] // [])[] | select(.held != true) | .name | tostring
                   | select(. as $n | $pkgs | index([$n]) != null)] }'
}

dnf_snapshot() { dnf_installed_lookup; }   # → TSV to stdout

# Is the installed dnf5 at least this version? KEMPT_DNF5_VERSION stands in for rpm in tests.
dnf5_at_least() {  # version → rc 0 when the installed dnf5 is that version or newer
  local v="${KEMPT_DNF5_VERSION:-$(rpm -q --qf '%{VERSION}' dnf5 2>/dev/null || true)}"
  [[ "$v" =~ ^[0-9][0-9.]*$ ]] && [[ "$(printf '%s\n' "$1" "$v" | sort -V | head -n1)" == "$1" ]]
}

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
  # dnf5 5.4.1 and later print the verdict as JSON, so nothing has to be read out of a sentence.
  # The exit code must agree with it: rc 1 with true, rc 0 with false. Anything else could not
  # answer, exactly as on the text path.
  if dnf5_at_least 5.4.1; then
    out="$($KEMPT_DNF_CMD -C --disablerepo='*' needs-restarting --json </dev/null 2>/dev/null)" || rc=$?
    local verdict
    verdict="$(jq -r 'if type == "array" then [.[] | select(.type == "reboot") | .reboot_required]
                      else [] end | if length == 1 and (.[0] | type) == "boolean" then .[0]
                      else error("no verdict") end' <<<"$out" 2>/dev/null)" || verdict=""
    case "$rc:$verdict" in
      1:true)  echo true ;;
      0:false) echo false ;;
      *) echo "warning: restart check could not answer (rc=$rc, no verdict in dnf5's JSON)" >&2; echo false ;;
    esac
    return 0
  fi
  out="$($KEMPT_DNF_CMD -C --disablerepo='*' needs-restarting </dev/null 2>/dev/null)" || rc=$?
  case $rc in
    1) if grep -qE '^[[:space:]]+\* [^[:space:]]' <<<"$out" \
          || grep -qF 'Reboot is required' <<<"$out"; then echo true
       else echo "warning: restart check could not answer (rc=1, no restart evidence)" >&2; echo false; fi ;;
    0) echo false ;;
    *) echo "warning: restart check failed (rc=$rc)" >&2; echo false ;;
  esac
}
