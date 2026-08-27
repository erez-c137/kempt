#!/usr/bin/env bash
# dnf5 backend. Pure parsers take stdin/files; impure funcs go through priv_* / overridable cmds.
# Requires lib/common.sh sourced first.

KEMPT_DNF_INSTALLED_CMD="${KEMPT_DNF_INSTALLED_CMD:-}"
KEMPT_DNF_CMD="${KEMPT_DNF_CMD:-dnf5}"
# Its own seam rather than a reuse of KEMPT_DNF_CMD, because four test files already point that one
# at a needs-restarting stub and this query has nothing to do with restarts.
KEMPT_DNF_SIZES_CMD="${KEMPT_DNF_SIZES_CMD:-}"

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

# How many bytes the pending dnf updates would pull down, from metadata already on disk. No
# depsolve, no transaction, no network - the numbers are in the solv cache repoquery already loads.
#
# Four details, each of which was wrong in the obvious version of this command:
#   --latest-limit 1   MANDATORY, not an optimisation. `--upgrades` lists every newer candidate,
#                      one row PER VERSION, so a box three nodesource releases behind contributes
#                      nodejs three times to a naive sum (measured: 27 rows for nodejs without it,
#                      1 with).
#   downloadsize       the real tag name. `%{download_size}` is not a tag and is echoed back
#                      literally, so the obvious spelling silently produces the string
#                      "%{download_size}" in every row.
#   $4 > 0             installed packages report 0 (the rpmdb does not keep the figure), so any
#                      row that resolved to @System is worthless and must not count as "known".
#   per name+arch sum  `--latest-limit 1` is per name.arch, and multilib twins are BOTH
#                      downloaded: glibc x86_64 2483277 plus i686 2282613 is 4765890 bytes of
#                      actual transfer. The item pipeline strips the arch and collapses the pair,
#                      so a size joined onto the collapsed item would lose the i686 half. Summing
#                      here, before anything joins, is what keeps it.
# -C keeps it offline, exactly like every other question a check asks. NEVER remove it.
# `timeout` and the empty-on-failure contract are the non-blocking half: this is a nicety on top
# of a check, and it must degrade to "no number" rather than to a failed or stale check.
# ALWAYS returns 0, and that is the contract rather than sloppiness: `set -o pipefail` is on, so a
# size command that fails - a missing dnf5, a timeout, a repoquery that cannot read its cache -
# would otherwise propagate out of the pipeline and become the caller's exit status. The caller is
# a CHECK, and a check must answer whether or not the nicety on top of it worked. Failure is
# expressed as an empty table, which the coverage rule downstream already reads as "not known".
dnf_sizes() {  # → TSV name<TAB>bytes, one row per name, arches summed. EMPTY on any failure. rc 0.
  { if [[ -n "$KEMPT_DNF_SIZES_CMD" ]]; then $KEMPT_DNF_SIZES_CMD
    else timeout 60 $KEMPT_DNF_CMD -C repoquery --upgrades --latest-limit 1 \
           --qf "%{name}\t%{arch}\t%{evr}\t%{downloadsize}\n" 2>/dev/null; fi; } \
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
  #
  # "Evidence" means the thing itself, and this used to test for "any non-whitespace on stdout"
  # instead - which is not the same promise. Every sentence dnf5 might print satisfied it: one
  # release that moves a line from stderr to stdout, one plugin printing a deprecation notice, and
  # rc 1 plus that line reads as "a restart is owed" on every check the box ever runs, which is
  # the same permanent false positive --disablerepo='*' was added to stop.
  #
  # So the two shapes the real command actually uses for YES are what count, measured against
  # dnf5 5.4.3 on Fedora 44 (2026-08-27), whose stdout for a box owing a restart is:
  #
  #     Core libraries or services have been updated since boot-up:
  #       * kernel
  #       * kernel-core
  #
  #     Reboot is required to fully utilize these updates.
  #     More information: https://access.redhat.com/solutions/27943
  #
  # (the "Updating and loading repositories:" chatter goes to stderr, which is already discarded).
  # Either half is accepted on its own: the indented package list, and dnf5's own verdict
  # sentence. Two tests rather than one because each covers the other's drift - a release that
  # restyles the list keeps the sentence, and a release that drops the sentence keeps the list.
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
