#!/usr/bin/env bash
# flatpak backend. Same contract as dnf.sh. Requires lib/common.sh sourced first.

# v1 is SYSTEM-scope flatpaks only, and --system is a contract every command in this file keeps -
# check, installed lookup, refresh and update all name the same scope, so the apps the badge
# counts are exactly the apps the run acts on. It used to be a CROSS-BOUNDARY contract, checked a
# second time inside libexec/kempt-apply; the update no longer crosses that boundary at all (see
# KEMPT_FLATPAK_UPDATE_CMD below), so the scope now has to agree within this one file.
#
# --cached is the network boundary, and it is the whole reason there are two commands below.
# Without it this query fetches flathub's summary index on EVERY check: with the network away it
# returned rc 1 in 48ms ("Unable to load summary from remote flathub"), which failed the entire
# flatpak backend and showed the widget a stale badge on battery, on a metered link and behind
# every captive portal. With it, the same query answered from the local summary, rc 0, network
# blackholed (measured 2026-08-27, flatpak 1.18.1). That leaves the check where dnf's already is:
# read-only against a local cache, filled by a separate step under one policy.
KEMPT_FLATPAK_REMOTE_CMD="${KEMPT_FLATPAK_REMOTE_CMD:-flatpak remote-ls --updates --system --app --cached --columns=application,version,download-size}"
# The separate step. It is the check command minus --cached, so what it fetches is exactly what the
# check reads back afterwards. It has to exist rather than letting the check heal itself, because
# --cached never falls back to the network - not even when the network is right there. Measured on
# this box with the cache emptied and flathub reachable, it still exits 1 in 40ms with "No cached
# summary for remote 'flathub'", so a cache nothing has filled stays a hard failure forever.
#
# Which command refreshes it was the question worth answering, and it was answered by watching the
# files rather than by reading the help text: running this line as an ordinary user rewrites
# ~/.cache/flatpak/system-cache/summaries/ (flathub.idx, its .sig and a fresh .sub subsummary) in
# 2.0-2.4s, and the --cached query then answers from it, rc 0, with the network blackholed.
# `flatpak update --appstream` is NOT the alternative it looks like: it fills the root-owned
# /var/lib/flatpak/appstream tree, which is not what --cached reads, and it needs a polkit action
# (org.freedesktop.Flatpak.appstream-update) to write there at all.
# Deliberately UNPRIVILEGED - no pkexec, no polkit action, no root helper. The cache it fills lives
# in the user's own home, so root would buy nothing here and would only widen the privileged
# surface. (All measurements 2026-08-27, flatpak 1.18.1, Fedora 44.)
KEMPT_FLATPAK_REFRESH_CMD="${KEMPT_FLATPAK_REFRESH_CMD:-flatpak remote-ls --updates --system --app --columns=application,version,download-size}"
KEMPT_FLATPAK_LIST_CMD="${KEMPT_FLATPAK_LIST_CMD:-flatpak list --system --app --columns=application,version}"
# The apply arm, and like the refresh above it runs AS THE USER: no pkexec, no Kempt polkit
# action, no root helper. flatpak asks for no password of its own here - the policy flatpak ships
# sets allow_active=yes on org.freedesktop.Flatpak.app-update, runtime-update and metadata-update,
# so an active local session updates system apps with no dialog at all. Routing this through
# libexec/kempt-apply put it behind Kempt's auth_admin_keep action instead, which meant a run with
# nothing but flatpak updates in it asked for a password that plain `flatpak update` never asks
# for. (Read from /usr/share/polkit-1/actions/org.freedesktop.Flatpak.policy, flatpak 1.18.1,
# Fedora 44, 2026-08-27.)
#
# What this removes is the GUARANTEED prompt, not every possible one. Two cases still authenticate,
# and both are honest limits rather than bugs:
#   - An update that pulls in a NEW runtime is an install, and runtime-install is auth_admin_keep.
#     Fedora ships a rules file that answers YES for a wheel member in an active local session, so
#     it is silent here; on a distribution without that file, or for a user outside wheel, that
#     case can still raise one dialog.
#   - allow_active means an ACTIVE LOCAL session. Over SSH the check falls to allow_inactive /
#     allow_any, which are auth_admin, so the flatpak half now authenticates against flatpak's own
#     action instead of Kempt's. It is a prompt rather than a refusal wherever there is a terminal
#     to prompt on: flatpak links libpolkit-agent-1 and registers its own text listener, exactly
#     as pkexec does. Headless, neither has anywhere to ask, and the call is refused. Untested;
#     SSH was never the supported surface.
KEMPT_FLATPAK_UPDATE_CMD="${KEMPT_FLATPAK_UPDATE_CMD:-flatpak update --system}"

# remote-ls with --columns=application,version may emit an empty version column, and a pending
# app can be missing from the installed lookup entirely. GNU join's `-a1 -e '?' -o` flags are the
# guard that fills both gaps - jq's `//` does NOT catch empty strings, so they are not redundant.
flatpak_parse_remote_ls() {  # $1=installed TSV (sorted); stdin=remote-ls lines → JSON [{name,from,to}]
  # awk, not `grep -vE '^(#|$)'`: same filtering, but grep exits 1 when it selects nothing, and
  # under pipefail that turned the COMMON "no pending updates" case into a check failure.
  # -F'\t' and an explicit two-field cut, because the row is now THREE fields wide: the
  # download-size column rides along for flatpak_parse_sizes, and it must not reach the join, whose
  # -o list would otherwise be picking fields out of a row shape it was not written for.
  awk -F'\t' 'NF && $1 !~ /^#/ { print $1 "\t" $2 }' \
  | sort -u \
  | join -t "$(printf '\t')" -a1 -e '?' -o '1.1,2.2,1.2' - "$1" \
  | jq -Rn '[inputs | split("\t") | {name:.[0], from:.[1], to:(.[2] // "?")}]'
}

# Bytes, out of the same rows flatpak_check already fetched. The value flatpak prints is a HUMAN
# string, not a number - "1.2 GB", rounded to one decimal by g_format_size - and `remote-info`
# returns the same rounded string, so exact bytes are not available from the CLI at all. The
# conversion happens here so that the human string never escapes the backend.
#
# The separator between number and unit is U+00A0 NO-BREAK SPACE for kB, MB and GB, and a PLAIN
# space for `bytes` (verified with cat -A on this box: `1.2M-BM- GB` against `847 bytes`). A
# whitespace-splitting parser therefore fails silently on 3471 of the 3474 apps flathub publishes
# and works on the three smallest, which is the worst possible way for it to be wrong. The gsub
# normalises the NBSP to a space FIRST so one split handles both.
# Units are SI decimal with a lowercase k, matching g_format_size. Anything else - an empty
# column, a literal "?", a unit nobody has seen - yields NO ROW rather than a zero, because a
# missing size must read as "not known" and suppress the figure, never as "free".
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
  # Sizes come out of the rows already in hand rather than from a second remote-ls. The cached
  # query costs about 1.6s on this box, and paying that twice per check to re-read bytes that
  # arrived with the first copy would be the whole cost of the feature, spent for nothing.
  # An `if`, not `[[ ... ]] && ...`: the && form evaluates to rc 1 whenever no path was passed,
  # and this function's status is read by cmd_check to decide whether the backend answered.
  if [[ -n "${1:-}" ]]; then flatpak_parse_sizes <<<"$out" > "$1" || : > "$1"; fi
  # A failed lookup must be loud: without this guard the join still succeeds against an empty
  # file and every app reports from="?" - a plausible-looking, entirely fabricated report.
  lookup="$(mktemp)"; $KEMPT_FLATPAK_LIST_CMD | sort_name_version | collapse_versions > "$lookup" \
    || { rm -f "$lookup"; return 1; }
  # Capture BEFORE the cleanup: rm's exit 0 would otherwise mask a parser failure. This masking
  # is what hid the zero-pending bug above - the two defects have to be fixed together.
  flatpak_parse_remote_ls "$lookup" <<<"$out" || prc=$?
  rm -f "$lookup"
  return $prc
}

# Same one-row-per-name contract as dnf, and the same ascending-version guarantee: sort_name_version
# keeps app ids in the byte order join needs while ordering any repeated id's versions by version.
flatpak_snapshot() { $KEMPT_FLATPAK_LIST_CMD | sort_name_version | collapse_versions; }

# The backend's network step, called only from maybe_refresh_metadata so that one gate - interval,
# mains power, unmetered link - governs every fetch Kempt makes. Both streams go nowhere: the point
# of this call is its side effect (it rewrites the local summary), and the pending list it happens
# to print is flatpak_check's job to produce, so letting it out would contaminate whatever the
# caller was capturing.
# 9>&- for the same reason priv_refresh closes it: this runs inside the check lock, it talks to
# the network, and anything it leaves behind would hold that lock open after it is gone.
flatpak_refresh() { $KEMPT_FLATPAK_REFRESH_CMD >/dev/null 2>&1 9>&-; }

# The backend's apply step, called from cmd_update through apply_with_retry. Argument shape is
# the one the hold logic produces: an optional -y, then the app ids left standing after the held
# ones are removed - no ids at all meaning "every pending app".
# There is deliberately no installed-set re-check here. That check lived in the ROOT helper, where
# distrusting your caller's argv is the whole job; on this side of the boundary the ids were built
# a few lines from the call, out of the same `flatpak list --system` any re-check would consult.
# cmd_update's pre-filter is what keeps an id flatpak does not have off the command line.
# Returns status explicitly, like every other backend function: `if fn` and `fn ||` both disable
# errexit inside the body, so nothing here may lean on set -e. Non-zero is the whole contract -
# every caller tests zero against non-zero and nothing reads the number - so the two branches are
# deliberately not made to agree: the single-command form passes flatpak's own status through
# untouched, where it is worth something in a log, while the loop flattens to 1 because "which of
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
      # as root: KEMPT_NAME_RE is anchored on its first character, which is what stops a name such
      # as `--installation=other` from arriving at flatpak as an OPTION. The whole call is rejected
      # rather than one argument quietly dropped, and nothing has run yet when it is.
      # The message names both possibilities on purpose: everything option-shaped lands here too,
      # and telling someone their `--installroot=/` is an invalid app id sends them looking in the
      # wrong place for the mistake.
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
