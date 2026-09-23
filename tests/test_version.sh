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
# `awk NR==1` and never `head -1`: head CLOSES the pipe on its first line, the writer behind it
# takes SIGPIPE, and pipefail turns that into status 141 for the whole command substitution -
# which errexit then takes the file down on, with no FAIL line printed and nothing to read
# afterwards. It is a race, so it fails about one run in three and passes every time it is run by
# hand. awk reads its input to the end and cannot close anything early.
assert_eq "$(grep -o '<release [^>]*>' "$META" | awk 'NR==1' | sed -n 's/.*version="\([^"]*\)".*/\1/p')" \
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
# Every spelling the dispatcher accepts is named in the list, or the one a user has in their
# fingers looks unsupported.
assert_exit 0 "help names the -V alias for the version" -- grep -qw -- '-V' "$TESTTMP/help.txt"
assert_exit 0 "...and the ways to ask for this list" -- grep -qw -- '-h' "$TESTTMP/help.txt"
# --help or -h after a command is a request for help, not a mistake to exit 2 over. update and run
# go through the same line of the dispatcher; they are left out here so that no test can ever start
# a run if that line goes.
for sub in check summary history log doctor config hold unhold holds enable-passwordless disable-passwordless; do
  for flag in --help -h; do
    assert_exit 0 "kempt $sub $flag prints the usage and exits 0" "$KEMPT" "$sub" "$flag"
    grep -q '^usage: kempt <command>' "$TESTTMP/last_output" \
      && echo "ok: ...and what it prints is the usage list" \
      || { echo "FAIL: kempt $sub $flag did not print the usage list"; _fail=1; }
  done
done
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

# --- hand builds say so, and still lose to the real thing ---------------------------------------
# Two builds of DIFFERENT CONTENT both calling themselves <version>-1 is not a theory: a pre-fix
# build sat installed on a machine looking identical to the fixed one, and only hashing the files
# could tell them apart. `--define kempt_local <stamp>` stamps the Release. UNDEFINED it must expand
# to exactly what it always did, because that is what every release, COPR and Koji build uses - a
# stamp leaking into a released NEVR would be worse than the problem it solves.
if command -v rpmspec >/dev/null 2>&1; then
  # awk, not head - see the note on the metainfo above. rpmspec prints a line per subpackage and
  # kempt.spec has two, so this is the pipeline that was actually losing the race.
  vr_plain="$(rpmspec -q --qf '%{release}\n' "$REPO_ROOT/kempt.spec" 2>/dev/null | awk 'NR==1')"
  vr_stamped="$(rpmspec -q --define 'kempt_local local19700101T0000' --qf '%{release}\n' \
                  "$REPO_ROOT/kempt.spec" 2>/dev/null | awk 'NR==1')"
  assert_eq "${vr_plain%%.*}" "1" "with no stamp the Release starts at 1, as every release build expects"
  assert_eq "$([[ "$vr_stamped" == 0.local19700101T0000.* ]] && echo stamped || echo "$vr_stamped")" \
    "stamped" "a hand build carries its stamp in the Release"
  # ...and sorts BELOW the release, which is the whole point of putting the stamp in FRONT as 0.:
  # the official package upgrades over a scratch build by itself. A suffix sorts ABOVE it and leaves
  # the scratch build pinned on the machine with dnf reporting nothing to do.
  if command -v rpmdev-vercmp >/dev/null 2>&1; then
    # `|| rc=` and not a bare call: rpmdev-vercmp ANSWERS in its exit status (12 = the first is
    # older), which under errexit takes the whole file down before the assertion can read it - this
    # file exited 12 with no FAIL line at all until the status was captured.
    rc_cmp=0
    rpmdev-vercmp "$VER-$vr_stamped" "$VER-$vr_plain" >/dev/null 2>&1 || rc_cmp=$?
    assert_eq "$rc_cmp" "12" "a hand build sorts below the release it was built from"
  fi
fi

# --- tools/build-local.sh names a hand build after the release it previews ---------------------
# A scratch repo with its own tags, so the numbers are fixed and the real history never enters.
if command -v git >/dev/null 2>&1; then
  BR="$TESTTMP/buildrepo"; mkdir -p "$BR/tools"
  cp "$REPO_ROOT/tools/build-local.sh" "$BR/tools/"
  bl() { "$BR/tools/build-local.sh" --print-name; }
  g() { git -C "$BR" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
  printf '0.1.4\n' > "$BR/VERSION"
  g init -q; g add -A; g commit -qm one; g tag v0.1.4
  sha() { g rev-parse --short=7 HEAD; }
  assert_eq "$(bl)" "0.1.5~dev.0+git$(sha)" "the tagged commit itself previews the next patch, dev.0"
  g commit -q --allow-empty -m two; g commit -q --allow-empty -m three
  assert_eq "$(bl)" "0.1.5~dev.2+git$(sha)" "dev.N counts the commits since the release tag"
  echo edit >> "$BR/VERSION.note"
  assert_eq "$(bl)" "0.1.5~dev.2+git$(sha).dirty" "a tree with changes the commit does not have says so"
  rm "$BR/VERSION.note"
  # A release bump names the next version itself - including a minor or major one.
  printf '0.2.0\n' > "$BR/VERSION"; g commit -qam bump
  assert_eq "$(bl)" "0.2.0~dev.3+git$(sha)" "a release bump past the tag is the version previewed"
  if command -v rpmdev-vercmp >/dev/null 2>&1; then
    # The point of the tilde: every hand build loses to the release it previews, and a later hand
    # build beats an earlier one. dev.10 against dev.9 is the case a plain string sort gets wrong.
    rc_cmp=0; rpmdev-vercmp "0.1.5~dev.9" "0.1.5" >/dev/null 2>&1 || rc_cmp=$?
    assert_eq "$rc_cmp" "12" "a dev build sorts below the release it previews"
    rc_cmp=0; rpmdev-vercmp "0.1.5~dev.10" "0.1.5~dev.9" >/dev/null 2>&1 || rc_cmp=$?
    assert_eq "$rc_cmp" "11" "a later dev build sorts above an earlier one"
    rc_cmp=0; rpmdev-vercmp "0.1.5~dev.1" "0.1.4" >/dev/null 2>&1 || rc_cmp=$?
    assert_eq "$rc_cmp" "11" "...and above the release before it"
  fi
  # And the display string survives kempt_version, which strips whitespace but nothing else.
  mkdir -p "$TESTTMP/devtree"; printf '0.1.5~dev.2+git1a2b3c4\n' > "$TESTTMP/devtree/VERSION"
  assert_eq "$(KEMPT_ROOT="$TESTTMP/devtree" "$KEMPT" --version)" "kempt 0.1.5~dev.2+git1a2b3c4" \
    "an installed dev build prints its whole name"
fi

finish
