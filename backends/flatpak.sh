#!/usr/bin/env bash
# flatpak backend. Same contract as dnf.sh. Requires lib/common.sh sourced first.

# v1 is SYSTEM-scope flatpaks only, and --system here is a CROSS-BOUNDARY contract, not a detail:
# libexec/kempt-apply validates every app id against `flatpak list --system`, so a per-user app
# surfaced by an unscoped check would be counted in the badge and then refused at update time.
#
# --cached is the network boundary, and it is the whole reason there are two commands below.
# Without it this query fetches flathub's summary index on EVERY check: with the network away it
# returned rc 1 in 48ms ("Unable to load summary from remote flathub"), which failed the entire
# flatpak backend and showed the widget a stale badge on battery, on a metered link and behind
# every captive portal. With it, the same query answered from the local summary, rc 0, network
# blackholed (measured 2026-08-27, flatpak 1.18.1). That leaves the check where dnf's already is:
# read-only against a local cache, filled by a separate step under one policy.
KEMPT_FLATPAK_REMOTE_CMD="${KEMPT_FLATPAK_REMOTE_CMD:-flatpak remote-ls --updates --system --app --cached --columns=application,version}"
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
KEMPT_FLATPAK_REFRESH_CMD="${KEMPT_FLATPAK_REFRESH_CMD:-flatpak remote-ls --updates --system --app --columns=application,version}"
KEMPT_FLATPAK_LIST_CMD="${KEMPT_FLATPAK_LIST_CMD:-flatpak list --system --app --columns=application,version}"

# remote-ls with --columns=application,version may emit an empty version column, and a pending
# app can be missing from the installed lookup entirely. GNU join's `-a1 -e '?' -o` flags are the
# guard that fills both gaps - jq's `//` does NOT catch empty strings, so they are not redundant.
flatpak_parse_remote_ls() {  # $1=installed TSV (sorted); stdin=remote-ls lines → JSON [{name,from,to}]
  # awk, not `grep -vE '^(#|$)'`: same filtering, but grep exits 1 when it selects nothing, and
  # under pipefail that turned the COMMON "no pending updates" case into a check failure.
  awk 'NF && $1 !~ /^#/' \
  | sort -u \
  | join -t "$(printf '\t')" -a1 -e '?' -o '1.1,2.2,1.2' - "$1" \
  | jq -Rn '[inputs | split("\t") | {name:.[0], from:.[1], to:(.[2] // "?")}]'
}

flatpak_check() {  # → items JSON; non-zero on command OR parser failure
  local out lookup prc=0
  out="$($KEMPT_FLATPAK_REMOTE_CMD)" || return 1
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
flatpak_refresh() { $KEMPT_FLATPAK_REFRESH_CMD >/dev/null 2>&1; }
