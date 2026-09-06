#!/usr/bin/env bash
# flatpak backend. Same contract as dnf.sh. Requires lib/common.sh sourced first.

# v1 is SYSTEM-scope flatpaks only, and --system is a contract all four commands below keep, so the
# apps the badge counts are exactly the apps the run acts on. Nothing outside this file enforces it:
# the update no longer crosses the privilege boundary (see KEMPT_FLATPAK_UPDATE_CMD).
#
# --cached is the network boundary, and the whole reason there are two commands below. Without it
# this query fetches flathub's summary index on EVERY check, so with the network away it fails
# ("Unable to load summary from remote flathub") and takes the entire flatpak backend down with it,
# leaving the widget a stale badge on battery, on a metered link and behind every captive portal.
# With it the query answers from the local summary, which leaves the check where dnf's already is:
# read-only against a local cache, filled by a separate step under one policy.
KEMPT_FLATPAK_REMOTE_CMD="${KEMPT_FLATPAK_REMOTE_CMD:-flatpak remote-ls --updates --system --app --cached --columns=application,version,download-size}"
# The separate step: the check command minus --cached, so what it fetches is exactly what the check
# reads back. It has to exist rather than letting the check heal itself, because --cached never
# falls back to the network - even with flathub reachable an empty cache is still "No cached summary
# for remote 'flathub'", rc 1, forever. Run as an ordinary user, this line rewrites
# ~/.cache/flatpak/system-cache/summaries/, which is the tree --cached reads.
# `flatpak update --appstream` is NOT the alternative it looks like: it fills the root-owned
# /var/lib/flatpak/appstream tree, which --cached does not read, and needs a polkit action
# (org.freedesktop.Flatpak.appstream-update) to write there at all. So this stays UNPRIVILEGED -
# the cache lives in the user's own home, and root would only widen the privileged surface.
KEMPT_FLATPAK_REFRESH_CMD="${KEMPT_FLATPAK_REFRESH_CMD:-flatpak remote-ls --updates --system --app --columns=application,version,download-size}"
KEMPT_FLATPAK_LIST_CMD="${KEMPT_FLATPAK_LIST_CMD:-flatpak list --system --app --columns=application,version}"
# The apply arm, and like the refresh above it runs AS THE USER: no pkexec, no Kempt polkit action,
# no root helper. flatpak asks for no password of its own here - the policy it ships sets
# allow_active=yes on org.freedesktop.Flatpak.app-update, runtime-update and metadata-update, so an
# active local session updates system apps with no dialog. Routed through libexec/kempt-apply
# instead, it would sit behind Kempt's auth_admin_keep action, and a run containing nothing but
# flatpak updates would ask for a password plain `flatpak update` never asks for.
#
# What this removes is the GUARANTEED prompt, not every possible one. Two cases still authenticate,
# and both are honest limits rather than bugs:
#   - An update pulling in a NEW runtime is an install, and runtime-install is auth_admin_keep.
#     Fedora's rules file answers YES for a wheel member in an active local session; without that
#     file, or for a user outside wheel, it can raise one dialog.
#   - allow_active means an ACTIVE LOCAL session. Over SSH the check falls to allow_inactive /
#     allow_any, which are auth_admin, so the flatpak half authenticates against flatpak's own
#     action instead of Kempt's - a prompt wherever there is a terminal to prompt on, a refusal
#     headless. Untested; SSH was never a supported surface.
KEMPT_FLATPAK_UPDATE_CMD="${KEMPT_FLATPAK_UPDATE_CMD:-flatpak update --system}"

# remote-ls with --columns=application,version may emit an empty version column, and a pending app
# can be missing from the installed lookup entirely. GNU join's `-a1 -e '?' -o` flags fill both
# gaps - and they are not redundant with jq's `//`, which does NOT catch empty strings.
flatpak_parse_remote_ls() {  # $1=installed TSV (sorted); stdin=remote-ls lines → JSON [{name,from,to}]
  # awk, not `grep -vE '^(#|$)'`: same filtering, but grep exits 1 when it selects nothing, and
  # under pipefail that makes the COMMON "no pending updates" case a check failure.
  # -F'\t' and an explicit two-field cut, because the row is THREE fields wide: the download-size
  # column rides along for flatpak_parse_sizes and must not reach the join, whose -o list is
  # written for a two-field row.
  awk -F'\t' 'NF && $1 !~ /^#/ { print $1 "\t" $2 }' \
  | sort -u \
  | join -t "$(printf '\t')" -a1 -e '?' -o '1.1,2.2,1.2' - "$1" \
  | jq -Rn '[inputs | split("\t") | {name:.[0], from:.[1], to:(.[2] // "?")}]'
}

# Bytes, out of the same rows flatpak_check already fetched. The value flatpak prints is a HUMAN
# string, not a number - "1.2 GB", rounded to one decimal by g_format_size, and `remote-info`
# returns the same rounded string - so exact bytes are not available from the CLI at all, and the
# conversion happens here so that string never escapes the backend.
#
# The separator between number and unit is U+00A0 NO-BREAK SPACE for kB, MB and GB and a PLAIN
# space for `bytes`, so a whitespace-splitting parser fails silently on all but the very smallest
# apps - the worst possible way to be wrong. The gsub normalises the NBSP to a space FIRST so one
# split handles both. Units are SI decimal with a lowercase k, matching g_format_size; anything
# else - an empty column, a literal "?", a unit nobody has seen - yields NO ROW rather than a zero,
# because a missing size must read as "not known" and suppress the figure, never as "free".
flatpak_parse_sizes() {  # stdin: remote-ls rows → TSV appid<TAB>bytes; unparseable rows omitted
  awk -F'\t' '
    function tobytes(s,   n,u,a) {
      gsub(/\xc2\xa0/, " ", s)
      if (s ~ /^[[:space:]]*$/) return -1
      n = s; sub(/[[:space:]].*$/, "", n)
      u = s; sub(/^[^[:space:]]*[[:space:]]*/, "", u); gsub(/[[:space:]]/, "", u)
      if (n !~ /^[0-9]+(\.[0-9]+)?$/) return -1
      a["bytes"]=1; a["B"]=1; a["kB"]=1000; a["KB"]=1000
      a["MB"]=1000000; a["GB"]=1000000000; a["TB"]=1000000000000
      if (!(u in a)) return -1
      return int(n * a[u] + 0.5)
    }
    NF >= 3 && $1 !~ /^#/ { b = tobytes($3); if (b >= 0) print $1 "\t" b }' \
  | sort -t "$(printf '\t')" -k1,1
}

flatpak_check() {  # [sizes_out_path] → items JSON; non-zero on command OR parser failure
  local out lookup prc=0
  out="$($KEMPT_FLATPAK_REMOTE_CMD)" || return 1
  # Sizes come out of the rows already in hand: a second remote-ls would re-fetch bytes that
  # arrived with the first copy, and the cached query is not free (~1.6s here).
  # An `if`, not `[[ ... ]] && ...`: the && form evaluates to rc 1 whenever no path was passed,
  # and this function's status is read by cmd_check to decide whether the backend answered.
  if [[ -n "${1:-}" ]]; then flatpak_parse_sizes <<<"$out" > "$1" || : > "$1"; fi
  # The lookup guard and the capture-before-cleanup below are dnf_check's, for its reasons: an
  # unguarded lookup failure joins against an empty file and reports every app as from="?", and
  # rm's exit 0 masks a parser failure as a successful "nothing pending" check.
  lookup="$(mktemp)"; $KEMPT_FLATPAK_LIST_CMD | sort_name_version | collapse_versions > "$lookup" \
    || { rm -f "$lookup"; return 1; }
  flatpak_parse_remote_ls "$lookup" <<<"$out" || prc=$?
  rm -f "$lookup"
  return $prc
}

# Same one-row-per-name, ascending-version contract as dnf - see sort_name_version.
flatpak_snapshot() { $KEMPT_FLATPAK_LIST_CMD | sort_name_version | collapse_versions; }

# The backend's network step, called only from maybe_refresh_metadata so that one gate - interval,
# mains power, unmetered link - governs every fetch Kempt makes. Both streams go nowhere: the point
# of the call is its side effect (it rewrites the local summary), and the pending list it also
# prints is flatpak_check's job, so letting it out would contaminate the caller's capture.
# 9>&- for the reason priv_refresh gives: this runs inside the check lock and talks to the network,
# and anything it leaves behind would hold that lock open after it is gone.
flatpak_refresh() { $KEMPT_FLATPAK_REFRESH_CMD >/dev/null 2>&1 9>&-; }

# The backend's apply step, called from cmd_update through apply_with_retry. Argument shape is the
# one the hold logic produces: an optional -y, then the app ids left standing after the held ones
# are removed - no ids at all meaning "every pending app".
# There is deliberately no installed-set re-check here. Distrusting your caller's argv is the ROOT
# helper's whole job; on this side of the boundary the ids were built a few lines from the call out
# of the same `flatpak list --system` any re-check would consult, and cmd_update's pre-filter keeps
# an id flatpak does not have off the command line.
# Returns status explicitly, like every other backend function: `if fn` and `fn ||` both disable
# errexit inside the body, so nothing here may lean on set -e. Non-zero is the whole contract, so
# the two branches deliberately do not agree: the single-command form passes flatpak's own status
# through, where it is worth something in a log, while the loop flattens to 1 because "which of
# these three apps failed" is not a thing one number can say.
flatpak_apply() {  # [-y] [app-id...] → 0, or non-zero (per-app when ids are given, all apps when none)
  local a id rc=0
  local assume=() ids=()
  for a in "$@"; do
    case "$a" in
      # Auto-accept, mapped rather than hardcoded: a user who turned auto_accept off must still
      # get flatpak's own prompt on the terminal surface instead of a silent unattended upgrade.
      -y) assume=(--noninteractive -y) ;;
      # App ids come from a REMOTE's summary, so they stay validated even though nothing here runs
      # as root: KEMPT_NAME_RE's anchor on the first character is what stops a name such as
      # `--installation=other` arriving at flatpak as an OPTION. The whole call is rejected rather
      # than one argument quietly dropped, and nothing has run yet when it is. The message names
      # both possibilities because everything option-shaped lands here too, and calling someone's
      # `--installroot=/` an invalid app id sends them looking in the wrong place.
      *) [[ "$a" =~ $KEMPT_NAME_RE ]] || { echo "invalid app id or option: $a" >&2; return 2; }
         ids+=("$a") ;;
    esac
  done
  if [[ ${#ids[@]} -eq 0 ]]; then
    $KEMPT_FLATPAK_UPDATE_CMD "${assume[@]}" || rc=$?
  else
    # Per-app is what makes holds possible: a held app is simply not in the list. One failure
    # fails the call, and the loop still finishes - the other apps have no reason to be skipped.
    for id in "${ids[@]}"; do
      $KEMPT_FLATPAK_UPDATE_CMD "${assume[@]}" "$id" || rc=1
    done
  fi
  return $rc
}
