#!/usr/bin/env bash
# The version, and the agreement it exists to enforce.
#
# Publishing needs four numbers to agree: the git tag, the RPM `Version:`, the AppStream
# `<release version=>` and the widget's `KPlugin.Version`. Nothing but a single source and a test
# makes that happen, and the failure is silent by construction - a widget shipped as 0.1.0 from a
# tree tagged 0.2.0 works perfectly and reports the wrong build in every bug report it causes.
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"

# --- the source of truth -----------------------------------------------------------------------
assert_exit 0 "the VERSION file exists" -- test -f "$REPO_ROOT/VERSION"
VER="$(head -1 "$REPO_ROOT/VERSION")"
# Shape, not value: a test that pinned the literal string would have to be edited by every bump,
# which is exactly the kind of edit people make without reading.
assert_eq "$([[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo semver || echo "not semver: $VER")" \
  "semver" "VERSION holds a plain three-part version"
# No trailing newline, spaces or CR may leak into what a human reads.
assert_eq "$(printf '%s' "$VER" | wc -c)" "$(printf '%s' "$VER" | tr -d '[:space:]' | wc -c)" \
  "VERSION carries no stray whitespace"

# --- the agreement -----------------------------------------------------------------------------
# THE assertion this file exists for. The widget's metadata.json is the one other place a version
# is written down today, and it is written in a different language in a different directory, so
# nothing but this line connects them.
assert_eq "$(jq -r '.KPlugin.Version' "$REPO_ROOT/plasmoid/metadata.json")" "$VER" \
  "the widget's KPlugin.Version agrees with VERSION"

# The third number: what a software centre reads. It is written in a third language in a third
# file, and a metainfo whose newest <release> lags VERSION tells every Discover user the wrong
# thing while the widget and the CLI both say the right one.
META="$REPO_ROOT/io.github.erez_c137.kempt.metainfo.xml"
assert_exit 0 "the AppStream metainfo exists" -- test -f "$META"
# The FIRST <release> element: AppStream orders releases newest-first, so the top one is this
# build's. grep and sed rather than an XML parser - the suite's whole dependency list is bash, jq
# and coreutils, and CI checks for exactly those.
assert_eq "$(grep -o '<release [^>]*>' "$META" | head -1 | sed -n 's/.*version="\([^"]*\)".*/\1/p')" \
  "$VER" "the metainfo's newest release version agrees with VERSION"

# The fourth: what `rpm -q kempt` answers. A spec that lags ships a package whose own version
# disagrees with the binary inside it, and the person reading both is holding one install.
SPEC="$REPO_ROOT/kempt.spec"
assert_exit 0 "the RPM spec exists" -- test -f "$SPEC"
assert_eq "$(awk '/^Version:/{print $2; exit}' "$SPEC")" "$VER" \
  "kempt.spec's Version agrees with VERSION"

# --- what a person types -----------------------------------------------------------------------
assert_eq "$("$KEMPT" --version)" "kempt $VER" "--version prints the version"
# Three spellings because all three get typed: --version is the convention, `version` is the guess,
# -V is the habit. They must not be able to disagree.
assert_eq "$("$KEMPT" version)" "kempt $VER" "the bare version subcommand agrees"
assert_eq "$("$KEMPT" -V)" "kempt $VER" "-V agrees"
# A trailing argument is refused rather than ignored, like every other argument-free command here:
# `kempt --version --json` must not print a version and look like it honoured the flag.
assert_exit 2 "a trailing argument is refused" "$KEMPT" --version --json
# Discoverable, or it does not exist as far as a user is concerned.
"$KEMPT" help > "$TESTTMP/help.txt" 2>&1 || true
assert_exit 0 "help lists it" -- grep -q -- '--version' "$TESTTMP/help.txt"
# doctor answers "which build is this?" too - it is the command people are asked to paste.
KEMPT_POLICY_FILE="$TESTTMP/nopolicy" "$KEMPT" doctor > "$TESTTMP/doctor.txt" 2>&1 || true
assert_exit 0 "doctor reports the version" -- grep -qE "^info +kempt $VER " "$TESTTMP/doctor.txt"

# --- a version is a diagnostic, so it degrades rather than failing ------------------------------
# A tree with no VERSION file must still be able to update the machine. The KEMPT_ROOT seam points
# the library at a tree that has none, which is also what an incomplete install looks like.
mkdir -p "$TESTTMP/noversion"
assert_eq "$(KEMPT_ROOT="$TESTTMP/noversion" "$KEMPT" --version)" "kempt unknown" \
  "a missing VERSION file reads as unknown, not as an error"
assert_exit 0 "...and does not break the command" -- \
  env KEMPT_ROOT="$TESTTMP/noversion" "$KEMPT" --version
: > "$TESTTMP/noversion/VERSION"
assert_eq "$(KEMPT_ROOT="$TESTTMP/noversion" "$KEMPT" --version)" "kempt unknown" \
  "an empty VERSION file reads as unknown too"
# A file written by an editor that adds a newline, or checked out with CRLF, must still print
# clean: "kempt 0.1.0\r" in a bug report is a version nobody can grep for.
printf '0.9.9\r\n' > "$TESTTMP/noversion/VERSION"
assert_eq "$(KEMPT_ROOT="$TESTTMP/noversion" "$KEMPT" --version)" "kempt 0.9.9" \
  "a CRLF VERSION file still prints a clean version"
# Only the first line, so a file that grew a comment or a second entry cannot smuggle it into the
# string every bug report quotes.
printf '1.2.3\nnot a version\n' > "$TESTTMP/noversion/VERSION"
assert_eq "$(KEMPT_ROOT="$TESTTMP/noversion" "$KEMPT" --version)" "kempt 1.2.3" \
  "only the first line of VERSION is the version"
finish
