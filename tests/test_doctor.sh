#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
KEMPT="$REPO_ROOT/bin/kempt"

# `kempt doctor` exists because of one verified trap: with the root helpers missing, `kempt
# check` exits 0 with status "stale" and actionable 0, which reads to a human (and to a badge) as
# "you are up to date". Doctor is the command that says WHY the answer is empty.

mk_stub() { printf '#!/usr/bin/env bash\nexit 0\n' > "$1"; chmod +x "$1"; }

# A healthy install, expressed entirely through the seams: nothing here depends on what the box
# running the suite happens to have installed.
mk_stub "$TESTTMP/refresh-helper"
mk_stub "$TESTTMP/apply-helper"
cp "$REPO_ROOT/polkit/io.github.erez_c137.kempt.policy" "$TESTTMP/policy.xml"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-helper"
export KEMPT_APPLY_HELPER="$TESTTMP/apply-helper"
export KEMPT_POLICY_FILE="$TESTTMP/policy.xml"
# the flatpak check asks whether the command the BACKEND runs exists, so the backend's own seam
# answers it: first word `cat`, which exists everywhere the suite runs.
export KEMPT_FLATPAK_LIST_CMD="cat $FIXTURES/flatpak-list.tsv"
# Two things need this stub. Doctor now reports on the dnf command itself, and three of the
# cases below run `kempt check`, which asks the backend whether a restart is owed - and
# sandbox() unsets KEMPT_DNF_CMD. Without the stub both would reach for the REAL dnf5 on
# whatever box runs the suite, which is slow and depends on whether that box happens to be owed
# a restart today. exit 0 = no restart owed.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"
chmod +x "$TESTTMP/dnf-reboot-no"
export KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no"
# sandbox() pins this at the `ready` fixture so the offline tests elsewhere have an armed
# transaction to work against. Doctor is the one command that REPORTS on it, so most of this file
# wants the opposite default - a box with nothing staged - and the section at the bottom points the
# seam at each fixture itself. Left at the sandbox default, every unrelated case here would carry a
# staged-transaction line it says nothing about. The symlink goes with it: nothing staged means no
# /system-update either, and sandbox()'s armed one would fail doctor's boot-symlink row.
export KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml"
export KEMPT_OFFLINE_LINK="$TESTTMP/no-system-update"

# Doctor reads the policy from a seam, and the annotated helper paths must not depend on what the box
# running the suite has installed. No user copy of the widget, so no row depends on this box's panel.
STAGE="$TESTTMP/stage"
S_POLICY="$STAGE/io.github.erez_c137.kempt.policy"
mkdir -p "$STAGE"
cp "$REPO_ROOT/polkit/io.github.erez_c137.kempt.policy" "$S_POLICY"
export KEMPT_PLASMOID_DIR="$TESTTMP/no-user-widget"

assert_exit 0 "healthy install: doctor exits 0" "$KEMPT" doctor
assert_contains "$(cat "$TESTTMP/last_output")" 'all checks passed' \
  "healthy install says so"
assert_eq "$(grep -c '^FAIL' "$TESTTMP/last_output" || true)" "0" \
  "no FAIL lines on a healthy install"
# every check reports, pass or fail: a silent doctor is a useless doctor. Matched against the
# REPORT LINES only - the usage text mentions half these words, so a plain grep over the whole
# output passes vacuously.
for want in 'polkit action' \
            'flatpak' 'dnf' 'config file' 'state dir' \
            'package lists' \
            'widget engine' 'startup'; do
  grep -E '^(ok|info|WARN|FAIL) ' "$TESTTMP/last_output" | grep -qF "$want" && echo "ok: reports on $want" \
    || { echo "FAIL: no line for $want"; _fail=1; }
done
assert_exit 2 "doctor takes no arguments" "$KEMPT" doctor --all

# --- how old the package metadata is -------------------------------------------------------------
# A check answers from a cache refreshed at most every three hours and never on battery or a
# metered link, so a box can go a week on one fetch with every count on screen looking freshly
# checked. No other row here would say so. info and never FAIL: old metadata is what those two
# rules are FOR, so it is a fact to put in front of the reader, not a fault to count.
kempt_init_dirs
rm -f "$LAST_REFRESH_FILE" "$LAST_REFRESH_DNF_FILE"
"$KEMPT" doctor > "$TESTTMP/doc-meta" 2>&1 || true
grep -qE '^info +package lists: no dnf refresh recorded yet' "$TESTTMP/doc-meta" \
  && echo "ok: a box that has never fetched metadata says so, rather than dating it" \
  || { echo "FAIL: no metadata row on a box that never fetched"; _fail=1; }
touch -d '3 days ago' "$LAST_REFRESH_DNF_FILE"
"$KEMPT" doctor > "$TESTTMP/doc-meta" 2>&1 || true
grep -qE '^info +package lists are 3 days old' "$TESTTMP/doc-meta" \
  && echo "ok: ...and an old cache is dated in whole days" \
  || { echo "FAIL: no metadata age row"; _fail=1; grep -i metadata "$TESTTMP/doc-meta" | sed 's/^/    /'; }
grep -q 'kempt check --refresh' "$TESTTMP/doc-meta" \
  && echo "ok: ...and names the command that fetches now" \
  || { echo "FAIL: the metadata row offers no remedy"; _fail=1; }
touch -d '1 day ago' "$LAST_REFRESH_DNF_FILE"
"$KEMPT" doctor > "$TESTTMP/doc-meta" 2>&1 || true
grep -qE '^info +package lists are 1 day old' "$TESTTMP/doc-meta" \
  && echo "ok: ...and one day reads as one day, verb and all" \
  || { echo "FAIL: the metadata row says '1 days'"; _fail=1; }
touch "$LAST_REFRESH_DNF_FILE"
"$KEMPT" doctor > "$TESTTMP/doc-meta" 2>&1 || true
grep -qE '^ok +package lists: refreshed' "$TESTTMP/doc-meta" \
  && echo "ok: ...and a cache fetched today is an ok row, not a finding" \
  || { echo "FAIL: fresh metadata is not reported ok"; _fail=1; }
# Fetches have run but no dnf one is on record: the shared stamp also moves for Flatpak alone, so
# it dates nothing, and the row says what to do rather than "refreshed" or "never refreshed".
rm -f "$LAST_REFRESH_DNF_FILE"
touch "$LAST_REFRESH_FILE"
"$KEMPT" doctor > "$TESTTMP/doc-meta" 2>&1 || true
grep -qE '^info +package lists: no dnf refresh recorded yet' "$TESTTMP/doc-meta" \
  && echo "ok: a box with fetches but no dnf stamp does not date the dnf metadata" \
  || { echo "FAIL: the shared stamp is reported as a dnf refresh"; _fail=1; grep -i metadata "$TESTTMP/doc-meta" | sed 's/^/    /'; }
grep -q 'dnf5 makecache --refresh shows why' "$TESTTMP/doc-meta" \
  && echo "ok: ...and says how to see why, if it stays" \
  || { echo "FAIL: the row gives no next step"; _fail=1; }
rm -f "$LAST_REFRESH_FILE"

# --- the ownership branches, which nothing could reach before ---
# doctor checks root:root 0755 only when the helper it was handed IS the path polkit's exec.path
# pins, because that ownership is the whole point: a root-ownership check on a test stub proves
# nothing about the install. That also made BOTH branches unreachable from the suite - every stub
# is a seam override, so every run took the silent exit. The annotated path is
# therefore a seam of its own, and a test reaches the real check by setting it equal to the
# helper seam. Nothing is executed here; doctor only stats the path.
ME_U="$(id -un)"; ME_G="$(id -gn)"
# A regular file that root owns at 0755. Where coreutils is uutils, /usr/bin/ls is a symlink, so it
# is followed to the file itself.
ROOT_FILE="$(readlink -f /usr/bin/ls)"
# /usr/bin/ls is root:root 0755, which is the only reason the ownership branch is reachable without
# root at all.
assert_exit 1 "a helper that IS root:root 0755 at the annotated path passes its ownership check, and only the policy disagrees" \
  env KEMPT_REFRESH_HELPER=$ROOT_FILE KEMPT_REFRESH_HELPER_PATH=$ROOT_FILE "$KEMPT" doctor
assert_contains "$(cat "$TESTTMP/last_output")" "ok    root helper (refresh): $ROOT_FILE (root:root 0755)" \
  "...and the ok line reports the ownership it actually verified"

# The other half: a helper sitting at the annotated path that root does not own is the shape a
# broken or tampered install has, and it must be a FAIL that names what it found.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/wrong-owner-helper"
chmod 644 "$TESTTMP/wrong-owner-helper"
assert_exit 1 "a helper at the annotated path that is not root:root 0755 fails the checkup" \
  env KEMPT_APPLY_HELPER="$TESTTMP/wrong-owner-helper" \
      KEMPT_APPLY_HELPER_PATH="$TESTTMP/wrong-owner-helper" "$KEMPT" doctor
grep -qF "root helper (apply) is $ME_U:$ME_G 644, expected root:root 755" "$TESTTMP/last_output" \
  && echo "ok: ...and the FAIL line names the owner and the mode it found" \
  || { echo "FAIL: ownership mismatch not named - got: $(grep 'root helper (apply)' "$TESTTMP/last_output")"; _fail=1; }
assert_contains "$(cat "$TESTTMP/last_output")" 'sudo dnf reinstall kempt' \
  "...and says how to fix it"

# The directory that holds a helper matters as much as the file: anyone who can write to it can
# rename the helper away and put their own file at the path polkit runs as root. A root-owned
# helper in a directory that is not root-owned, or that the group or everyone can write, is a FAIL.
mkdir -p "$TESTTMP/loose-libexec"; chmod 777 "$TESTTMP/loose-libexec"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/loose-libexec/kempt-apply"
chmod 755 "$TESTTMP/loose-libexec/kempt-apply"
assert_exit 1 "a helper in a directory others can write to fails the checkup" \
  env KEMPT_APPLY_HELPER="$TESTTMP/loose-libexec/kempt-apply" \
      KEMPT_APPLY_HELPER_PATH="$TESTTMP/loose-libexec/kempt-apply" "$KEMPT" doctor
grep -qF "root helper directory (apply) is $ME_U:$ME_G 777, expected root-owned and not group- or world-writable: $TESTTMP/loose-libexec" \
     "$TESTTMP/last_output" \
  && echo "ok: ...and the FAIL line names the directory, its owner and its mode" \
  || { echo "FAIL: loose helper directory not reported - got: $(grep 'root helper' "$TESTTMP/last_output")"; _fail=1; }
# ...and a sound directory adds no line: /usr/bin is root-owned and 0755.
env KEMPT_REFRESH_HELPER=$ROOT_FILE KEMPT_REFRESH_HELPER_PATH=$ROOT_FILE "$KEMPT" doctor \
  > "$TESTTMP/dir-ok.txt" 2>&1 || true
assert_not_contains "$(cat "$TESTTMP/dir-ok.txt")" 'root helper directory' \
  "...while a root-owned directory nobody else can write says nothing"
chmod 755 "$TESTTMP/loose-libexec"

# --- the exec.path the policy pins, against the helper this CLI hands to pkexec ------------------
# pkexec matches an action by the `org.freedesktop.policykit.exec.path` annotation and by nothing
# else. The RPM installs the helpers under /usr/libexec and rewrites the annotation to match
# (kempt.spec); install.sh uses /usr/local/libexec. Mix the two - a package installed over a
# checkout, or a checkout CLI left on the PATH after packaging - and pkexec has no action for the
# path it is handed, so every privileged call falls back to an authentication dialog. A background
# check cannot answer one: it waits out the 120s timeout and reports the check stale, forever.
# Doctor only asked whether the file was READABLE, so it said "ok" for exactly that box.
mk_policy() {  # dest refresh_path apply_path
  sed -e "s|/usr/local/libexec/kempt-refresh|$2|" -e "s|/usr/local/libexec/kempt-apply|$3|" \
      "$REPO_ROOT/polkit/io.github.erez_c137.kempt.policy" > "$1"
}
# Both seams of a helper pointed at one real file, the same trick the ownership section above uses
# and for the same reason: the comparison is only made when the helper seam IS the annotated path,
# because with a stub in play what this CLI runs is not what polkit would ever be asked about.
# /usr/bin/ls because it exists everywhere the suite runs; nothing here executes it.
as_annotated() {  # policy-file -> a checkup with both helpers at $ROOT_FILE
  env KEMPT_POLICY_FILE="$1" \
      KEMPT_REFRESH_HELPER=$ROOT_FILE KEMPT_REFRESH_HELPER_PATH=$ROOT_FILE \
      KEMPT_APPLY_HELPER=$ROOT_FILE   KEMPT_APPLY_HELPER_PATH=$ROOT_FILE "$KEMPT" doctor
}

# Agreement is the ordinary state, and it must cost the report nothing.
mk_policy "$TESTTMP/policy-agree.xml" $ROOT_FILE $ROOT_FILE
assert_exit 0 "a policy that pins the helper this CLI runs is not a problem" \
  -- as_annotated "$TESTTMP/policy-agree.xml"
assert_eq "$(grep -c '^FAIL  polkit exec.path' "$TESTTMP/last_output" || true)" "0" \
  "...and adds no FAIL"
for a in refresh apply; do
  grep -qF "ok    polkit exec.path ($a): $ROOT_FILE" "$TESTTMP/last_output" \
    && echo "ok: ...and the $a line names the path both sides agree on" \
    || { echo "FAIL: no exec.path ok line for $a - got: $(grep 'exec.path' "$TESTTMP/last_output")"; _fail=1; }
done

# The split install itself: one action pinned somewhere else. This is the shape an RPM policy over
# a checkout CLI has, and it is a FAIL because nothing privileged can run without a dialog.
mk_policy "$TESTTMP/policy-split.xml" $ROOT_FILE /usr/libexec/kempt-apply
assert_exit 1 "a policy that pins a different apply helper fails the checkup" \
  -- as_annotated "$TESTTMP/policy-split.xml"
grep -qE '^FAIL  polkit exec.path \(apply\)' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names the action that disagrees" \
  || { echo "FAIL: no exec.path FAIL line - got: $(grep 'exec.path' "$TESTTMP/last_output")"; _fail=1; }
# BOTH paths, because the reader cannot act on either one alone: which is wrong depends on which
# install they meant to have.
ep_line="$(grep '^FAIL  polkit exec.path (apply)' "$TESTTMP/last_output" || true)"
[[ "$ep_line" == */usr/libexec/kempt-apply* && "$ep_line" == *$ROOT_FILE* ]] \
  && echo "ok: ...naming the path the policy pins and the path this CLI runs" \
  || { echo "FAIL: the FAIL line does not name both paths - got: $ep_line"; _fail=1; }
assert_contains "$(cat "$TESTTMP/last_output")" 'authentication dialog' \
  "...and what it costs, which is a dialog on every privileged run"
assert_contains "$(cat "$TESTTMP/last_output")" 'background checks time out' \
  "...including the background check nobody is there to answer"
assert_contains "$(cat "$TESTTMP/last_output")" 'sudo dnf reinstall kempt' \
  "...and the remedy for a package"
# The action that still agrees still passes: two actions, two verdicts, never one summary.
assert_contains "$(cat "$TESTTMP/last_output")" "ok    polkit exec.path (refresh): $ROOT_FILE" \
  "...while the action that agrees is still reported as ok"

# A policy with no annotation at all is not a verdict either way: an action without an exec.path is
# not an action pkexec would run these helpers through, and saying "mismatch" would send the reader
# after a path that is not there.
grep -v 'policykit.exec.path' "$REPO_ROOT/polkit/io.github.erez_c137.kempt.policy" \
  > "$TESTTMP/policy-noann.xml"
assert_exit 0 "a policy with no exec.path annotation is reported, not failed" \
  -- as_annotated "$TESTTMP/policy-noann.xml"
assert_eq "$(grep -c '^FAIL  polkit exec.path' "$TESTTMP/last_output" || true)" "0" \
  "...and an absent annotation is not a problem"
grep -qE '^info  polkit exec.path \(refresh\):' "$TESTTMP/last_output" \
  && echo "ok: ...and says so on an info line" \
  || { echo "FAIL: no info line for the missing annotation - got: $(grep 'exec.path' "$TESTTMP/last_output")"; _fail=1; }

# A policy file doctor cannot read is already a FAIL on its own line above. This check must not
# count it twice, and it cannot compare against a file it cannot open.
assert_exit 1 "an unreadable policy file is not an exec.path verdict" \
  -- as_annotated "$TESTTMP/nope.policy"
grep -qE '^info  polkit exec.path \(refresh\):' "$TESTTMP/last_output" \
  && echo "ok: an unreadable policy leaves an info line, not a second FAIL" \
  || { echo "FAIL: no info line for the unreadable policy"; _fail=1; }

# ...and with a stub helper in play - every other case in this file - there is nothing to compare:
# what this CLI runs is a test stub, which polkit was never asked about.
"$KEMPT" doctor > "$TESTTMP/exec.txt" 2>&1 || true
assert_eq "$(grep -cE '^[a-zA-Z]+ +(polkit exec\.path|root helper) \(' "$TESTTMP/exec.txt" || true)" "0" \
  "a helper seam override adds no row: neither compared against the policy nor checked for ownership"

# --- which kempt the widget would run -----------------------------------------------------------
# The widget runs the CLI as `PATH="$HOME/.local/bin:$PATH" KEMPT_VIA=widget kempt`
# (plasmoid/contents/ui/main.qml), so ~/.local/bin wins - which is how a stale developer symlink
# there goes on shadowing a packaged /usr/bin/kempt for the panel, and only for the panel. Doctor
# ran from whichever kempt the reader typed, so a report could describe one install while the
# widget used another, with nothing anywhere able to say so.
# KEMPT_WIDGET_PATH is that lookup's seam, and tests/lib.sh pins it at a directory with no kempt in
# it: the suite runs on developer boxes where ~/.local/bin/kempt points at a DIFFERENT checkout
# than the one under test, so unpinned, every case in this file would fail on it.
SELF_REAL="$(readlink -f "$REPO_ROOT/bin/kempt")"
WP_SAME="$TESTTMP/wpath-same"; mkdir -p "$WP_SAME"
ln -sfn "$REPO_ROOT/bin/kempt" "$WP_SAME/kempt"
assert_exit 0 "the widget running the same kempt this report describes is not a problem" \
  env KEMPT_WIDGET_PATH="$WP_SAME" "$KEMPT" doctor
grep -qF "ok    widget engine: $SELF_REAL" "$TESTTMP/last_output" \
  && echo "ok: ...and the line names the one kempt both would run" \
  || { echo "FAIL: no widget engine ok line - got: $(grep 'widget engine' "$TESTTMP/last_output")"; _fail=1; }

# The split itself. A second kempt earlier on the widget's PATH is a different FILE, and the
# report has to name both or the reader cannot tell which one to remove.
WP_OTHER="$TESTTMP/wpath-other"; mkdir -p "$WP_OTHER"
cp "$REPO_ROOT/bin/kempt" "$WP_OTHER/kempt"; chmod +x "$WP_OTHER/kempt"
assert_exit 1 "a widget that would run a different kempt fails the checkup" \
  env KEMPT_WIDGET_PATH="$WP_OTHER" "$KEMPT" doctor
we_line="$(grep '^FAIL  widget engine' "$TESTTMP/last_output" || true)"
[[ "$we_line" == *"$WP_OTHER/kempt"* && "$we_line" == *"$SELF_REAL"* ]] \
  && echo "ok: the FAIL line names the widget's kempt and this report's" \
  || { echo "FAIL: the widget engine line does not name both - got: $we_line"; _fail=1; }
assert_contains "$(cat "$TESTTMP/last_output")" 'the widget would run' \
  "...in the order that says which is which"

# Nothing on the widget's PATH is not doctor's problem to solve: the widget already reports the
# engine as missing (main.qml sets engineMissing on rc 127), so a second FAIL here would only
# duplicate a message the user is already looking at.
WP_NONE="$TESTTMP/wpath-none"; mkdir -p "$WP_NONE"
assert_exit 0 "no kempt on the widget's PATH is reported, not failed" \
  env KEMPT_WIDGET_PATH="$WP_NONE" "$KEMPT" doctor
grep -qE '^info  widget engine:' "$TESTTMP/last_output" \
  && echo "ok: ...on an info line, because the widget says it itself" \
  || { echo "FAIL: no widget engine info line - got: $(grep 'widget engine' "$TESTTMP/last_output")"; _fail=1; }

# --- the trap itself: a check that looks like good news, and the command that explains it ---
export KEMPT_SKIP_REFRESH=1
export KEMPT_DNF_INSTALLED_CMD="cat $FIXTURES/rpm-installed.tsv"
export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
rc=0
state="$(KEMPT_REFRESH_HELPER="$TESTTMP/nope-refresh" "$KEMPT" check 2>/dev/null)" || rc=$?
assert_eq "$rc" "0" "with no root helper, check still exits 0"
assert_eq "$(jq -r .backends.dnf.actionable <<<"$state")" "0" \
  "...and reports 0 pending system updates, which reads as up to date"
assert_eq "$(jq -r .status <<<"$state")" "stale" "...with only 'stale' to hint that anything is wrong"
# ...and the one clue check DOES give has to point at the real cause. The raw stderr is
# "timeout: failed to run command '<path>': No such file or directory" - the `timeout` wrapper
# naming a file that does not exist, which reads as "the check timed out" and sends the user
# hunting a network problem they do not have.
assert_eq "$(jq -r .error <<<"$state")" \
  "dnf check failed: root helper not installed. Reinstall it with: sudo dnf reinstall kempt (see: kempt doctor)" \
  "the stale error names the missing helper, not a timeout"
# uutils' timeout says the same thing without the path.
assert_contains "$(bash -c 'source "$1/lib/common.sh"; explain_helper_error "timeout: failed to execute process: No such file or directory (os error 2)"' _ "$REPO_ROOT")" \
  "root helper not installed." "...and so it does from a timeout that leaves the path out"
grep -qi 'timeout' <<<"$(jq -r .error <<<"$state")" \
  && { echo "FAIL: the error still reads as a timeout"; _fail=1; } \
  || echo "ok: no phantom timeout in the error"
# a real backend failure is still reported verbatim: the substitution must not swallow the truth
cat > "$TESTTMP/angry-refresh" <<'STUB'
#!/usr/bin/env bash
echo "Errors during downloading metadata for repository 'updates'" >&2
exit 1
STUB
chmod +x "$TESTTMP/angry-refresh"
astate="$(KEMPT_REFRESH_HELPER="$TESTTMP/angry-refresh" "$KEMPT" check 2>/dev/null)"
grep -q 'Errors during downloading metadata' <<<"$(jq -r .error <<<"$astate")" \
  && echo "ok: an ordinary backend failure still reports its own message" \
  || { echo "FAIL: real backend error lost - got: $(jq -r .error <<<"$astate")"; _fail=1; }
# ...and it reports it EXACTLY, with no trailing space. The stderr tail is flattened to one line
# for the JSON string, and `tr '\n' ' '` turns the file's final newline into a space that command
# substitution does not strip - so every error state.json carried used to end in one, for every
# reader to render. Two lines here, so this also pins the flattening it is named for.
cat > "$TESTTMP/two-line-refresh" <<'STUB'
#!/usr/bin/env bash
echo "first line" >&2
echo "second line" >&2
exit 1
STUB
chmod +x "$TESTTMP/two-line-refresh"
tstate="$(KEMPT_REFRESH_HELPER="$TESTTMP/two-line-refresh" "$KEMPT" check 2>/dev/null)"
assert_eq "$(jq -r .error <<<"$tstate")" "dnf check failed: first line second line" \
  "the stale error joins lines with single spaces and ends with no trailing space"

assert_exit 1 "...while doctor fails and names the missing helper" \
  env KEMPT_REFRESH_HELPER="$TESTTMP/nope-refresh" "$KEMPT" doctor
assert_contains "$(cat "$TESTTMP/last_output")" 'root helper (refresh) not installed' \
  "the FAIL line names the refresh helper"
assert_contains "$(cat "$TESTTMP/last_output")" 'sudo dnf reinstall kempt' \
  "...and says how to fix it"
unset KEMPT_DNF_INSTALLED_CMD KEMPT_FLATPAK_REMOTE_CMD KEMPT_SKIP_REFRESH
# Those checks left a stale state and a failed-fetch marker, each a WARN row of its own (asserted
# at the end). The cases below count warnings from a clean slate.
rm -f "$STATE_FILE" "$REFRESH_DNF_FAILED_FILE"

# --- one failure class at a time, each proving its own FAIL line ---

assert_exit 1 "a missing apply helper fails the checkup" \
  env KEMPT_APPLY_HELPER="$TESTTMP/nope-apply" "$KEMPT" doctor
assert_contains "$(cat "$TESTTMP/last_output")" 'root helper (apply) not installed' \
  "the FAIL line names the apply helper"

assert_exit 1 "a missing polkit action fails the checkup" \
  env KEMPT_POLICY_FILE="$TESTTMP/nope.policy" "$KEMPT" doctor
assert_contains "$(cat "$TESTTMP/last_output")" 'polkit action not installed' \
  "the FAIL line names the polkit action"

# Same rule for flatpak: a backend that is switched off must not be reported as broken. Left at
# its default, include_flatpak means "if Flatpak is here", so a box without it is information too:
# check and update skip Flatpak there, and nothing is broken.
assert_exit 0 "a missing flatpak is an info line while include_flatpak is at its default" \
  env KEMPT_FLATPAK_LIST_CMD="kempt-no-such-flatpak list" "$KEMPT" doctor
assert_contains "$(cat "$TESTTMP/last_output")" "info  Flatpak is not installed, so Kempt checks system packages only" \
  "...saying what Kempt does without it"
# Set to true by hand, check and update still skip it, so doctor is where that is said: a WARN,
# which leaves the exit status alone.
"$KEMPT" config set include_flatpak true
assert_exit 0 "a missing flatpak with include_flatpak=true set by hand is not a failure" \
  env KEMPT_FLATPAK_LIST_CMD="kempt-no-such-flatpak list" "$KEMPT" doctor
assert_contains "$(cat "$TESTTMP/last_output")" "WARN  Flatpak is not installed, so Kempt skips it although include_flatpak is on. Install flatpak, or run: kempt config set include_flatpak false" \
  "...but a WARN saying Kempt skips it and how to settle it"
"$KEMPT" config set include_flatpak false
assert_exit 0 "...but is only an info line when include_flatpak=false" \
  env KEMPT_FLATPAK_LIST_CMD="kempt-no-such-flatpak list" "$KEMPT" doctor
assert_eq "$(grep -qE '^info .*flatpak' "$TESTTMP/last_output" && echo yes || echo no)" "yes" \
  "a disabled backend is information, not a failure"
"$KEMPT" config set include_flatpak true

# The settings count pluralizes itself, and docs/usage.md's sample output is pinned to this
# wording: "(2 settings)", never "(2 setting(s))".
: > "$CONFIG_FILE"; "$KEMPT" config set surface widget
"$KEMPT" doctor > "$TESTTMP/doctor-1key" 2>&1 || true
grep -qF "config file: $CONFIG_FILE (1 setting)" "$TESTTMP/doctor-1key" \
  && echo "ok: one key reads '1 setting'" \
  || { echo "FAIL: singular count - got: $(grep 'config file:' "$TESTTMP/doctor-1key")"; _fail=1; }
"$KEMPT" config set auto_accept true
"$KEMPT" doctor > "$TESTTMP/doctor-2keys" 2>&1 || true
grep -qF "config file: $CONFIG_FILE (2 settings)" "$TESTTMP/doctor-2keys" \
  && echo "ok: two keys read '2 settings'" \
  || { echo "FAIL: plural count - got: $(grep 'config file:' "$TESTTMP/doctor-2keys")"; _fail=1; }

# A config file is read by every command with `grep "^key="`, so a line that is not key=value is
# silently ignored forever - the setting the user thinks they wrote never applies.
printf 'surface offline\n' >> "$CONFIG_FILE"
assert_exit 1 "an unparseable config line fails the checkup" "$KEMPT" doctor
assert_eq "$(grep -qE 'config file line .* is not key=value' "$TESTTMP/last_output" && echo yes || echo no)" "yes" \
  "the FAIL line quotes the bad line"
# a key the config_set validation would refuse is just as dead
printf 'Surface=offline\n' > "$CONFIG_FILE"
assert_exit 1 "a config key that config set would refuse fails the checkup" "$KEMPT" doctor
assert_contains "$(cat "$TESTTMP/last_output")" 'config file line' \
  "an invalid key is reported too"
: > "$CONFIG_FILE"
"$KEMPT" config set surface widget

# State that cannot be written means no badge, no history, no logs.
mkdir -p "$KEMPT_STATE_DIR"; chmod 500 "$KEMPT_STATE_DIR"
assert_exit 1 "an unwritable state dir fails the checkup" "$KEMPT" doctor
assert_contains "$(cat "$TESTTMP/last_output")" 'state dir not writable' \
  "the FAIL line names the state dir"
chmod 700 "$KEMPT_STATE_DIR"

# A tree with no .git still names its release, on the opening line: git is never a requirement.
NOGIT="$TESTTMP/nogit"
mkdir -p "$NOGIT"
cp -r "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/backends" "$REPO_ROOT/polkit" \
      "$REPO_ROOT/libexec" "$REPO_ROOT/plasmoid" "$REPO_ROOT/VERSION" "$NOGIT/"
env KEMPT_POLICY_FILE="$S_POLICY" "$NOGIT/bin/kempt" doctor > "$TESTTMP/skew.txt" 2>&1 || true
grep -qE "^info  kempt $(cat "$REPO_ROOT/VERSION") \(" "$TESTTMP/skew.txt" \
  && echo "ok: a checkout with no git history still names its release" \
  || { echo "FAIL: opening line wrong without git"; _fail=1; sed 's/^/    /' "$TESTTMP/skew.txt"; }

# Fix messages name the package.
env KEMPT_POLICY_FILE="$TESTTMP/no-such.policy" KEMPT_REFRESH_HELPER="$TESTTMP/nope-refresh" \
    KEMPT_REFRESH_HELPER_PATH="$TESTTMP/nope-refresh" "$NOGIT/bin/kempt" doctor > "$TESTTMP/skew.txt" 2>&1 || true
assert_contains "$(cat "$TESTTMP/skew.txt")" \
  "root helper (refresh) not installed: $TESTTMP/nope-refresh. Reinstall it with: sudo dnf reinstall kempt" \
  "a packaged install's missing helper points at dnf reinstall"
assert_contains "$(cat "$TESTTMP/skew.txt")" \
  "polkit action not installed: $TESTTMP/no-such.policy. Reinstall it with: sudo dnf reinstall kempt" \
  "...and so does its missing polkit action"
assert_not_contains "$(cat "$TESTTMP/skew.txt")" "install.sh" \
  "...and nothing names an installer that is gone"
pkg_state="$(KEMPT_REFRESH_HELPER="$TESTTMP/nope-refresh" "$NOGIT/bin/kempt" check 2>/dev/null)" || true
assert_contains "$(jq -r .error <<<"$pkg_state")" \
  "dnf check failed: root helper not installed. Reinstall it with: sudo dnf reinstall kempt (see: kempt doctor)" \
  "a packaged check names the package fix for a missing helper"
rm -f "$STATE_FILE" "$REFRESH_DNF_FAILED_FILE"   # its stale state and marker are WARN rows below

# --- the store copy that shadows a packaged widget ----------------------------------------------
# The widget is installable on its own from the KDE Store, and kpackagetool6 puts what it installs
# in the USER's plasmoid directory. The RPM puts its copy in /usr/share - and Plasma prefers the
# user one. So a widget installed from the store before the package goes on being the widget
# Plasma loads, and every package update after that lands in a directory nothing reads. Nothing
# inside the widget can see it either: the stale copy renders perfectly, forever.
doctor_packaged() {  # user-scope plasmoid dir -> a packaged install's checkup, against that dir
  env KEMPT_POLICY_FILE="$S_POLICY" KEMPT_PLASMOID_DIR="$1" "$NOGIT/bin/kempt" doctor
}

STORE_COPY="$TESTTMP/store-widget"
assert_exit 0 "a packaged install with no user copy of the widget is healthy" \
  -- doctor_packaged "$STORE_COPY"
assert_not_contains "$(cat "$TESTTMP/last_output")" 'shadows' \
  "...and says nothing about one"

# A store copy with only the CLI package installed is NOT shadowing anything: it is the one widget
# on the box. Failing over it would tell somebody to delete their only panel. It gets a pointer
# instead, in the order that keeps a widget on the panel: the package first, then the removal.
mkdir -p "$STORE_COPY/contents/ui"
cp "$REPO_ROOT/plasmoid/metadata.json" "$STORE_COPY/metadata.json"
assert_exit 0 "a store copy with no packaged widget does not fail the checkup" \
  -- doctor_packaged "$STORE_COPY"
assert_not_contains "$(cat "$TESTTMP/last_output")" 'shadows' \
  "...and does not call it shadowing, because there is nothing to shadow"
assert_contains "$(cat "$TESTTMP/last_output")" "info  store widget in use: the panel runs the KDE Store copy in $STORE_COPY, and package updates do not reach it" \
  "...it says the widget in use is the store copy, which package updates do not reach"
assert_contains "$(cat "$TESTTMP/last_output")" 'sudo dnf install kempt-plasmoid, then remove the store copy with: kpackagetool6 -t Plasma/Applet -r io.github.erez_c137.kempt' \
  "...and to install the widget package first, then remove the store copy"
assert_not_contains "$(cat "$TESTTMP/last_output")" 'panel widget not installed' \
  "...and does not also claim there is no widget on the panel"

# The trap itself: both copies on the box at once.
SYS_WIDGET="$TESTTMP/sys-widget"; mkdir -p "$SYS_WIDGET/contents"
doctor_packaged_both() {
  env KEMPT_POLICY_FILE="$S_POLICY" KEMPT_PLASMOID_DIR="$1" KEMPT_SYSTEM_PLASMOID_DIR="$SYS_WIDGET" \
    "$NOGIT/bin/kempt" doctor
}
assert_exit 1 "a user copy shadowing the packaged widget fails the checkup" \
  -- doctor_packaged_both "$STORE_COPY"
grep -qF "user widget copy shadows the package: $STORE_COPY" "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names the directory" \
  || { echo "FAIL: no shadow line"; _fail=1; sed 's/^/    /' "$TESTTMP/last_output"; }
# The consequence, in words, because "shadows" is jargon on its own: what the user loses is every
# future update of the widget, silently.
assert_contains "$(cat "$TESTTMP/last_output")" 'package updates never reach your panel' \
  "...and what it costs, which is every future update of the widget"
# ...and the exact fix, which needs no root and which the user cannot be expected to guess.
assert_contains "$(cat "$TESTTMP/last_output")" 'kpackagetool6 -t Plasma/Applet -r io.github.erez_c137.kempt' \
  "...and the exact command that removes it"
assert_contains "$(cat "$TESTTMP/last_output")" 'plasmashell --replace' \
  "...and that the shell has to reload before it takes effect"

# --- the widget is its own package, and a packaged install has to say so ------------------------
# The CLI and the panel widget ship separately (kempt / kempt-plasmoid), so a perfectly healthy CLI
# can sit on a box with no widget in the panel and nothing anywhere would explain why.
doctor_packaged "$TESTTMP/absent-user-widget" > "$TESTTMP/skew.txt" 2>&1 || true
assert_contains "$(cat "$TESTTMP/skew.txt")" 'panel widget not installed. It is a separate package: sudo dnf install kempt-plasmoid' \
  "a packaged install with no widget names the package that carries it"
# ...and what going without it means, because the CLI alone is not a quieter widget: nothing runs a
# check on a schedule, and polkit refuses both actions from a session that is not active and local.
assert_contains "$(cat "$TESTTMP/skew.txt")" 'Without it nothing runs checks on a schedule, so the CLI checks only when you run it, from an active local session (not over SSH)' \
  "...and says that without it nothing checks on a schedule, and not over SSH"
# ...and says nothing once the package IS installed. The line is a pointer, not a nag.
env KEMPT_POLICY_FILE="$S_POLICY" KEMPT_PLASMOID_DIR="$TESTTMP/absent-user-widget" \
    KEMPT_SYSTEM_PLASMOID_DIR="$SYS_WIDGET" "$NOGIT/bin/kempt" doctor > "$TESTTMP/skew.txt" 2>&1 || true
assert_not_contains "$(cat "$TESTTMP/skew.txt")" 'panel widget not installed' \
  "...and stays quiet once the widget package is there"

# --- the staged transaction, which doctor is the only surface that can explain --------------------
# Every surface says what the stage is; doctor also says what to do about it, with the command. A
# real box spent a day with a transaction downloaded and never armed, and every surface reporting a
# pending install that no restart could deliver.
# Armed is TWO things - dnf5 at `ready` AND the /system-update symlink - and the sandbox pins the
# symlink at a path that does not exist, because that is the state of every box that has not just
# staged something. So the whole staged section below runs with a live one, and the cases that are
# ABOUT the symlink being gone point the seam back at nothing themselves.
export KEMPT_OFFLINE_LINK="$TESTTMP/armed-system-update"
ln -sfn "$TESTTMP" "$KEMPT_OFFLINE_LINK"
NO_LINK="$TESTTMP/no-system-update"
mkdir -p "$KEMPT_STATE_DIR"
doctor_out() { "$KEMPT" doctor > "$TESTTMP/staged.txt" 2>&1 || true; }
tx_of() { jq -n '{version:"1.0", rpms:[$ARGS.positional[] | {nevra:., action:"Upgrade"}]}' --args "$@" > "$TESTTMP/tx-of.json"; }

# Nothing staged: nothing to say, and doctor does not say it. A line per run about a transaction that
# does not exist is noise on every box that has never staged one.
KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml" KEMPT_OFFLINE_LINK="$NO_LINK" doctor_out
grep -qiE '^(ok|info|WARN|FAIL)  .*staged' "$TESTTMP/staged.txt" \
  && { echo "FAIL: a box with nothing staged still reported on it"; _fail=1; } \
  || echo "ok: no staged transaction, no line about one"

# ARMED and pending: the normal case, and information rather than a problem. It is the one thing
# the report can say that answers "why is `kempt check` still listing these packages?".
assert_exit 0 "an armed staged transaction is not a problem" \
  env KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" "$KEMPT" doctor
assert_contains "$(cat "$TESTTMP/last_output")" 'info  staged update: 3 packages install on the next restart' \
  "...and doctor says how many, and when"
assert_contains "$(cat "$TESTTMP/last_output")" 'If that fails: sudo dnf5 offline clean' \
  "...and names the fix for when the discard fails, which is what the failed discard points here for"
# One package is its own sentence here too. Doctor's rows are read by people pasting them into bug
# reports, and "1 packages" is the line that gets quoted back.
tx_of a-1-1.noarch
KEMPT_OFFLINE_TXJSON="$TESTTMP/tx-of.json" KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" doctor_out
assert_contains "$(cat "$TESTTMP/staged.txt")" 'info  staged update: 1 package installs on the next restart' \
  "a single staged package reads as one"
tx_of a-1-1.noarch b-1-1.noarch
KEMPT_OFFLINE_TXJSON="$TESTTMP/tx-of.json" KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" doctor_out
assert_contains "$(cat "$TESTTMP/staged.txt")" 'info  staged update: 2 packages install on the next restart' \
  "...and two is back to the plural"
# dnf5's list unreadable is no promise about a restart.
printf 'not a transaction\n' > "$TESTTMP/tx-garbage.json"
KEMPT_OFFLINE_TXJSON="$TESTTMP/tx-garbage.json" KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" doctor_out
assert_contains "$(cat "$TESTTMP/staged.txt")" 'WARN  staged update: Kempt cannot tell what the stored update will do' \
  "an unreadable list: cannot tell, not installs"
assert_not_contains "$(cat "$TESTTMP/staged.txt")" 'on the next restart' "...and no promise about the restart"

# THE STUCK STAGE FROM A REAL BOX, and the reason this section exists. `dnf5 upgrade --offline`
# leaves the transaction at download-complete; only `dnf5 offline reboot` arms it. Until then it
# installs on no restart ever.
KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml" KEMPT_OFFLINE_LINK="$NO_LINK" doctor_out
assert_contains "$(cat "$TESTTMP/staged.txt")" 'WARN  prepared updates will not install: dnf5 says "download-complete"' \
  "a stage that was never armed says it will not install, not that it is pending"
assert_contains "$(cat "$TESTTMP/staged.txt")" 'kempt unstage' "...and names the command that clears it"

# --- an image-based Fedora ------------------------------------------------------------------------
# The report that used to end "all checks passed" on a machine Kempt cannot update at all. Kinoite
# ships dnf5 and plasma-workspace, so every row below the first one passes honestly and the whole
# thing is still wrong: it describes dnf, which is not what installs updates on that box.
touch "$TESTTMP/ostree-booted"
ib_out="$(KEMPT_OSTREE_MARKER="$TESTTMP/ostree-booted" "$KEMPT" doctor 2>&1)" || true
ib_plain="$("$KEMPT" doctor 2>&1)" || true
# A DELTA against the same report on an ordinary box, not a bare "doctor failed": this part of the
# file runs in a sandbox that already has failing rows, so "exit 1" would have passed without the
# row existing at all and proved nothing.
# Scoped to the ROW it is about rather than to the whole report. A delta over every FAIL line says
# "one more problem", which is true of the wrong row just as easily as of this one: the day any
# other doctor row starts failing in this sandbox, a count like that passes for a reason nobody
# asked for, and the day one stops it fails for another.
assert_eq "$(printf '%s\n' "$ib_out" | grep -c '^FAIL  Kempt does not update atomic Fedora (Kinoite, Silverblue, bootc image mode); use Discover, rpm-ostree or bootc upgrade.' || true)" "1" \
  "on an image-based system doctor reports the rpm-ostree problem"
assert_eq "$(printf '%s\n' "$ib_plain" | grep -c '^FAIL  Kempt does not update atomic Fedora (Kinoite, Silverblue, bootc image mode); use Discover, rpm-ostree or bootc upgrade.' || true)" "0" \
  "...and on an ordinary one it says nothing of the kind"
case "$ib_out" in
  *"FAIL"*"rpm-ostree"*) echo "ok: ...and says so as a FAIL, naming the tool that does update it" ;;
  *) echo "FAIL: no rpm-ostree FAIL row"; echo "$ib_out" | awk 'NR<=5'; _fail=1 ;;
esac
case "$ib_out" in
  *"is planned"*) echo "ok: ...as a not-yet rather than a never, as the other surfaces say" ;;
  *) echo "FAIL: the doctor row does not say support is planned"; echo "$ib_out" | awk 'NR<=5'; _fail=1 ;;
esac
case "$ib_out" in
  *"all checks passed"*) echo "FAIL: it still says everything is fine"; _fail=1 ;;
  *) echo "ok: ...so the report never ends by saying everything is fine" ;;
esac
# It is the FIRST row, above every other, because it decides whether the rest means anything.
# The version line is first - it is the fact every other line is read against - and this is second,
# above every check. A reader should not have to get past twenty passing rows to learn that none of
# them is about the tool their machine actually uses.
assert_eq "$(printf '%s\n' "$ib_out" | sed -n '2p' | grep -c 'rpm-ostree')" "1" \
  "...directly under the version line, above every check, not as a footnote below them"

# ...and when that transaction is a Fedora RELEASE upgrade, say so. "Something is staged" and "your
# machine restarts into Fedora 45" are different things to be told, and this is the one case where
# Kempt's own offline button is refused - a person who presses it and is turned down should be able
# to find out here why, rather than only from the failure.
KEMPT_OFFLINE_TOML="$FIXTURES/offline-release-upgrade.toml" doctor_out
grep -qE '^info  a Fedora release upgrade \(44 -> 45\) is prepared outside Kempt' "$TESTTMP/staged.txt" \
  && echo "ok: a staged release upgrade is named as one, with both releases" \
  || { echo "FAIL: no release-upgrade line - got: $(grep -i staged "$TESTTMP/staged.txt")"; _fail=1; }
# ...and the state it is usually in: downloaded, not started. The row used to print "it installs on
# the next restart" immediately after the status word that disproves it - and the row twelve lines
# up in the same report says the opposite about that identical status when the transaction is
# Kempt's own, so one report contradicted itself depending only on who owned the marker.
KEMPT_OFFLINE_TOML="$FIXTURES/offline-release-upgrade-downloaded.toml" doctor_out
assert_contains "$(cat "$TESTTMP/staged.txt")" 'downloaded outside Kempt but not started' \
  "a downloaded release upgrade is not described as installing on the next restart"
assert_contains "$(cat "$TESTTMP/staged.txt")" 'system-upgrade reboot' \
  "...and it says what starts it, which is the thing the person still has to do"
assert_not_contains "$(cat "$TESTTMP/staged.txt")" 'installs on the next restart' \
  "...and never claims a restart installs something that is not armed"
# ...and the third state, which is neither: `ready` with the boot symlink gone. A restart has
# already been past it. Both other sentences are false here - one promises the next restart, and
# the other calls a transaction that WAS armed one that was never started, quoting a status word
# that says the opposite.
KEMPT_OFFLINE_LINK="$NO_LINK" KEMPT_OFFLINE_TOML="$FIXTURES/offline-release-upgrade.toml" doctor_out
# Asserted against the INFO row alone. The FAIL row beside it carries the same phrase, so a plain
# grep over the whole report passed with the info arm deleted entirely - proved by deleting it.
relup_info="$(grep -E '^info  a Fedora release upgrade' "$TESTTMP/staged.txt" || true)"
case "$relup_info" in
  *"restart went by without installing it"*) echo "ok: a stranded release upgrade is described as one a restart has already passed" ;;
  *) echo "FAIL: the info row does not describe the stranded state"; echo "  got: $relup_info"; _fail=1 ;;
esac
case "$relup_info" in
  *"not started"*) echo "FAIL: the info row calls a transaction that WAS armed one that was never started"; _fail=1 ;;
  *) echo "ok: ...and not as one that was never started" ;;
esac
assert_not_contains "$(cat "$TESTTMP/staged.txt")" 'installs on the next restart' \
  "...and promises no restart that will not happen"
# The FAIL beside it must not call somebody else's release upgrade a "staged update", nor offer the
# rebuild command that pre-flight refuses while one is stored.
assert_contains "$(cat "$TESTTMP/staged.txt")" 'the stored Fedora release upgrade can never install' \
  "...and the failure names whose transaction it is"
assert_not_contains "$(cat "$TESTTMP/staged.txt")" 'kempt update --surface=offline' \
  "...and offers no command that always ends in a refusal"

# ...and the fourth state, which dnf5 records when a transaction did not finish.
KEMPT_OFFLINE_TOML="$FIXTURES/offline-release-upgrade-incomplete.toml" doctor_out
ic_info="$(grep -E '^info  a Fedora release upgrade' "$TESTTMP/staged.txt" || true)"
case "$ic_info" in
  *"did not finish"*) echo "ok: an unfinished release upgrade is described as unfinished" ;;
  *) echo "FAIL: the unfinished state was mis-described"; echo "  got: $ic_info"; _fail=1 ;;
esac
case "$ic_info" in
  *"has been downloaded"*) echo "FAIL: download-incomplete is called downloaded"; _fail=1 ;;
  *) echo "ok: ...and never called downloaded, which is the opposite of what dnf5 recorded" ;;
esac
KEMPT_OFFLINE_TOML="$FIXTURES/offline-release-upgrade.toml" doctor_out
assert_contains "$(cat "$TESTTMP/staged.txt")" 'will not prepare updates over it' \
  "...saying why Kempt refuses to stage while it is there"
grep -qE '^FAIL' "$TESTTMP/staged.txt" \
  && { echo "FAIL: a release upgrade waiting to install was reported as a fault"; _fail=1; } \
  || echo "ok: ...and it is information, not a fault: nothing here is broken"

# --- what stops a stage, one row each -------------------------------------------------------------
# A stored file that cannot be read, or says something this version does not know: a real answer,
# with the fix, and never dnf5 "saying" a word Kempt made up. (Skipped as root, who can read anything.)
garbage_toml="$TESTTMP/garbage.toml"; printf 'not a transaction-state file\n' > "$garbage_toml"
KEMPT_OFFLINE_TOML="$garbage_toml" doctor_out
assert_contains "$(cat "$TESTTMP/staged.txt")" 'WARN  staged update: Kempt cannot tell what the stored update will do' \
  "a stored record nobody can read is reported as exactly that"
assert_contains "$(cat "$TESTTMP/staged.txt")" 'sudo dnf5 offline clean' "...with the fix"
assert_not_contains "$(cat "$TESTTMP/staged.txt")" 'says "unknown"' "...and without putting a word in dnf5's mouth"
assert_not_contains "$(cat "$TESTTMP/staged.txt")" 'installs on the next restart' \
  "...and claims nothing about what a restart would do"

# The stage a refresh took the restart step from: the answer is staging again.
printf 'bash-0:5.3.9-1.fc44.x86_64\n' > "$TESTTMP/rpm-qa-other"
KEMPT_RPM_QA_CMD="cat $TESTTMP/rpm-qa-other" KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" KEMPT_OFFLINE_LINK="$NO_LINK" doctor_out
assert_contains "$(cat "$TESTTMP/staged.txt")" 'prepared updates will not install' "a stage that lost its restart step says so"
assert_contains "$(cat "$TESTTMP/staged.txt")" 'Prepare them again with: kempt update --surface=offline' "...and says to stage again"

# --- the hold that arrived after the stage, on the report a worried person runs --------------------
# info and not FAIL: doctor has ok/info/FAIL and nothing between, and a package installing despite a
# hold is a legitimate state (dnf5 built that transaction before the hold existed and offers no way
# to edit a stored one). A FAIL for something legitimate is how a report teaches people to ignore
# FAILs. The bluntness lives in the sentence, and the sentence ends with BOTH remedies: the person
# who held a kernel may want the stage gone rather than rebuilt.
"$KEMPT" hold dnf:librepo >/dev/null 2>&1
assert_exit 0 "a hold behind an armed stage is reported, and is not a failure" \
  env KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" "$KEMPT" doctor
assert_contains "$(cat "$TESTTMP/last_output")" 'info  staged update: it installs librepo on the next restart despite the hold.' \
  "...leading with what happens and naming the package"
grep -qF 'kempt update --surface=offline' "$TESTTMP/last_output" \
  && grep -qF 'kempt unstage' "$TESTTMP/last_output" \
  && echo "ok: ...and ending with both remedies, rebuild it or remove it" \
  || { echo "FAIL: the conflict line does not carry both remedies"; _fail=1; }

# Three names, and the verb moves with them.
"$KEMPT" hold dnf:ca-certificates >/dev/null 2>&1
"$KEMPT" hold dnf:openldap >/dev/null 2>&1
KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" doctor_out
assert_contains "$(cat "$TESTTMP/staged.txt")" 'staged update: it installs ca-certificates, librepo and openldap on the next restart despite the holds.' \
  "three held packages read as a sentence, plural verb included"

# Six, which is where the cap earns its place: a Qt or KDE bump legitimately puts dozens of names in
# the set, and a doctor row that lists them all is a row nobody reads to the end.
tx_of bash-1-1.noarch curl-1-1.noarch glibc-1-1.noarch kernel-core-1-1.noarch mesa-1-1.noarch systemd-1-1.noarch
for n in bash curl glibc kernel-core mesa systemd; do "$KEMPT" hold "dnf:$n" >/dev/null 2>&1; done
KEMPT_OFFLINE_TXJSON="$TESTTMP/tx-of.json" KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" doctor_out
assert_contains "$(cat "$TESTTMP/staged.txt")" 'staged update: it installs bash, curl, glibc, kernel-core, and 2 more on the next restart despite the holds.' \
  "past four names the rest are counted, not listed"


# Nothing held: no line at all. The row exists to answer a question nobody has asked otherwise.
for n in librepo ca-certificates openldap bash curl glibc kernel-core mesa systemd; do
  "$KEMPT" unhold "dnf:$n" >/dev/null 2>&1
done
KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" doctor_out
grep -qE 'despite the hold|may still install held packages' "$TESTTMP/staged.txt" \
  && { echo "FAIL: a conflict line with nothing held"; _fail=1; } \
  || echo "ok: no hold, no conflict line"

# --- the boot symlink, and the state nothing in Kempt could see -----------------------------------
# Arming creates /system-update, and systemd's system-update-generator looks for that symlink and
# nothing else. Leave it behind over a transaction that is not `ready` - which is exactly what a
# replace-stage leaves in the middle, since dnf5 destroys the old transaction the moment the new one
# begins - and the next boot detours into the offline updater, installs nothing, and comes back with
# no trace anywhere. Kempt read the toml and never the symlink, so this state was invisible to the
# one command whose job is to see it.
D_LINK="$TESTTMP/system-update"
# DANGLING on purpose: the symlink is the mechanism, its target is not, and a check that resolved
# the target would answer "no problem" for the boot that is about to detour.
ln -s "$TESTTMP/nothing-here" "$D_LINK"

# The normal armed state, which must stay silent: symlink present, transaction ready. This is what
# every successfully staged box looks like between the stage and the restart.
KEMPT_OFFLINE_LINK="$D_LINK" KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" doctor_out
grep -qE '^FAIL' "$TESTTMP/staged.txt" \
  && { echo "FAIL: an armed transaction was reported as a problem"; _fail=1; } \
  || echo "ok: symlink plus a ready transaction is the armed state, not a fault"

# Symlink over a transaction that was never armed: somebody else's stage, or ours replaced
# mid-rebuild. The remedy needs root, so it is spelled out.
assert_exit 1 "a live boot symlink over a transaction not set to install fails the checkup" \
  env KEMPT_OFFLINE_LINK="$D_LINK" KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml" "$KEMPT" doctor
assert_contains "$(cat "$TESTTMP/last_output")" 'FAIL  boot symlink is live over a transaction that is not set to install (status "download-complete")' \
  "...naming the status the boot will detour on"
assert_contains "$(cat "$TESTTMP/last_output")" 'sudo dnf5 offline clean' \
  "...and the exact command that clears it"

# Symlink with no transaction behind it at all. Worse, not better: the boot still detours, and
# there is not even a transaction for it to consider.
assert_exit 1 "a boot symlink with nothing staged behind it fails the checkup" \
  env KEMPT_OFFLINE_LINK="$D_LINK" KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml" "$KEMPT" doctor
assert_contains "$(cat "$TESTTMP/last_output")" 'FAIL  boot symlink is live with nothing prepared behind it' \
  "...and says the transaction is not there rather than quoting a status"

# Both rows when both apply: they are two different facts about the same box - one says the stage
# will not install, the other says the next boot detours on the way to finding that out.
KEMPT_OFFLINE_LINK="$D_LINK" KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml" doctor_out
assert_eq "$(grep -c '^FAIL  boot symlink is live over a transaction that is not set to install' "$TESTTMP/staged.txt" || true)" "1" \
  "a stage that will not install does not suppress the symlink row"
assert_eq "$(grep -c '^WARN  prepared updates' "$TESTTMP/staged.txt" || true)" "1" \
  "...and the symlink does not suppress the stage's"
# No symlink is no row, whatever the toml says.
KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml" KEMPT_OFFLINE_LINK="$NO_LINK" doctor_out
assert_eq "$(grep -c '^FAIL  boot symlink' "$TESTTMP/staged.txt" || true)" "0" \
  "no boot symlink, no symlink row"
assert_eq "$(grep -c 'prepared updates' "$TESTTMP/staged.txt" || true)" "1" \
  "...and the transaction not set to install is reported exactly once"
# ...and with the symlink there, a ready transaction is fine.
assert_exit 0 "a ready transaction with its symlink standing is not a problem" \
  env KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" "$KEMPT" doctor

rm -f "$D_LINK"
# ...and out of the staged section: back to a box with no restart marker, which is what every
# case below assumes and what a box that has not just staged something actually looks like.
export KEMPT_OFFLINE_LINK="$NO_LINK"

# --- another updater in the same session -------------------------------------------------------
# Discover's notifier checks on its own schedule and PackageKit's background work takes the dnf5
# lock, which makes a Kempt run wait until it lets go. This row tells, and names the command and
# the widget button that turn it off. info and never FAIL: running both is a valid choice.
NOTIFIER=org.kde.discover.notifier.desktop
SYS_AUTOSTART="$TESTTMP/xdg-autostart"; mkdir -p "$SYS_AUTOSTART"
USER_AUTOSTART="$XDG_CONFIG_HOME/autostart"; mkdir -p "$USER_AUTOSTART"
notifier_entry() {  # dest, extra lines...
  local dest="$1"; shift
  { printf '[Desktop Entry]\nType=Application\nName=Discover Notifier\nExec=/usr/bin/DiscoverNotifier\n'
    if [[ $# -gt 0 ]]; then printf '%s\n' "$@"; fi; } > "$dest"
}
doctor_with_autostart() {  # → the report, with the seam pointed at the test's own directory
  env KEMPT_XDG_AUTOSTART_DIR="$SYS_AUTOSTART" "$KEMPT" doctor > "$TESTTMP/notifier.txt" 2>&1 || true
  cat "$TESTTMP/notifier.txt"
}

# Nothing installed: no row at all. A report is read line by line, and a line about something that
# is not on the machine is noise in every one of them.
assert_eq "$(doctor_with_autostart | grep -c Discover || true)" "0" \
  "with no notifier entry anywhere, doctor says nothing about it"

# The system entry is there, so it starts.
notifier_entry "$SYS_AUTOSTART/$NOTIFIER"
assert_eq "$(doctor_with_autostart | grep -c "^info  Discover" || true)" "1" \
  "an enabled notifier is reported as info, not as a problem"
assert_contains "$(doctor_with_autostart)" "$NOTIFIER" \
  "...and the row names the file, so it can be found"
assert_contains "$(doctor_with_autostart | grep '^info  Discover')" "kempt discover-notifier off" \
  "...and the command that turns it off"
assert_contains "$(doctor_with_autostart | grep '^info  Discover')" "Turn Off Discover's Notifier" \
  "...and the widget's button for the same"
assert_contains "$(doctor_with_autostart | grep '^info  Discover')" \
  "so its number can differ from Kempt's. Its background work can make a Kempt run wait. To turn it off, run" \
  "...in short sentences"
assert_exit 0 "...and it never makes the checkup fail" \
  env KEMPT_XDG_AUTOSTART_DIR="$SYS_AUTOSTART" "$KEMPT" doctor

# The opt-out the installer writes: a user entry with Hidden=true overrides the system one.
notifier_entry "$USER_AUTOSTART/$NOTIFIER" "Hidden=true"
assert_eq "$(doctor_with_autostart | grep -c "^ok    Discover" || true)" "1" \
  "the installer's opt-out is confirmed as ok"
assert_eq "$(doctor_with_autostart | grep -c '^info  Discover' || true)" "0" \
  "...and the enabled row is gone"

# A user entry that does not hide it is not an opt-out. Hidden=false is what the system entry
# ships on some systems, and copying it without editing is the mistake this catches.
notifier_entry "$USER_AUTOSTART/$NOTIFIER" "Hidden=false"
assert_eq "$(doctor_with_autostart | grep -c "^info  Discover" || true)" "1" \
  "a user entry with Hidden=false still starts, and is reported"

# Discover set to install updates by itself. Its prepared update takes /system-update and dnf5
# leaves that symlink alone, so the next restart installs Discover's update, not Kempt's stage.
# Reported only while the notifier that does it starts here or is running, and WARN only when
# Kempt is set to stage.
UNATTENDED='Discover is set to install updates by itself on restart'
notifier_entry "$USER_AUTOSTART/$NOTIFIER" "Hidden=true"
printf '[Global]\nUseUnattendedUpdates=true\n' > "$TESTTMP/discover-updates"
export KEMPT_DISCOVER_UPDATES_CONF="$TESTTMP/discover-updates"
assert_eq "$(doctor_with_autostart | grep -c "$UNATTENDED" || true)" "0" \
  "the setting is not reported while the notifier neither starts here nor runs"
assert_eq "$(KEMPT_DISCOVER_PGREP=true doctor_with_autostart | grep -c "^info  $UNATTENDED" || true)" "1" \
  "...but is while it runs"
rm -f "$USER_AUTOSTART/$NOTIFIER"
saved_surface="$("$KEMPT" config get surface)"
"$KEMPT" config set surface popup
out="$(doctor_with_autostart)"
assert_eq "$(grep -c "^info  $UNATTENDED" <<<"$out" || true)" "1" "a notifier that starts here and installs by itself is reported as info"
assert_contains "$out" "the next restart installs that and not an update Kempt staged. To leave updates to Kempt, run kempt discover-notifier off" \
  "...saying what it does to a stage, and the command"
"$KEMPT" config set surface offline
out="$(doctor_with_autostart)"
assert_eq "$(grep -c "^WARN  $UNATTENDED" <<<"$out" || true)" "1" "...and as WARN when Kempt is set to stage"
assert_exit 0 "...which never makes the checkup fail" env KEMPT_XDG_AUTOSTART_DIR="$SYS_AUTOSTART" "$KEMPT" doctor
assert_eq "$(tail -1 <<<"$out")" "kempt doctor: no problems, 1 warning" \
  "...and the report ends by counting the warning, not with all checks passed"
printf '[Global]\nUseUnattendedUpdates=false\n' > "$TESTTMP/discover-updates"
assert_eq "$(doctor_with_autostart | grep -c "$UNATTENDED" || true)" "0" "the setting turned off is not reported"
printf '[Other]\nUseUnattendedUpdates=true\n' > "$TESTTMP/discover-updates"
assert_eq "$(doctor_with_autostart | grep -c "$UNATTENDED" || true)" "0" "...nor the key in another section"
# The small read on its own. A bool may be written 1, and the last line wins.
unatt() { printf "$1" > "$TESTTMP/discover-updates"
  bash -c 'source "$1/lib/common.sh"; discover_unattended' _ "$REPO_ROOT"; }
assert_exit 0 "1 reads as true" -- unatt '[Global]\nUseUnattendedUpdates=1\n'
assert_exit 0 "...and so does On, spaces included" -- unatt '[Global]\nUseUnattendedUpdates = On\n'
assert_exit 1 "0 reads as false" -- unatt '[Global]\nUseUnattendedUpdates=0\n'
assert_exit 1 "the last line wins" -- unatt '[Global]\nUseUnattendedUpdates=true\nUseUnattendedUpdates=false\n'
assert_exit 1 "a commented line is not the setting" -- unatt '[Global]\n#UseUnattendedUpdates=true\n'
assert_exit 1 "no file is not the setting" -- env KEMPT_DISCOVER_UPDATES_CONF="$TESTTMP/no-such-conf" bash -c 'source "$1/lib/common.sh"; discover_unattended' _ "$REPO_ROOT"
"$KEMPT" config set surface "$saved_surface"
export KEMPT_DISCOVER_UPDATES_CONF="$TESTTMP/no-discover-updates-conf"

rm -f "$USER_AUTOSTART/$NOTIFIER" "$SYS_AUTOSTART/$NOTIFIER"

# Several problems at once still exit 1 and still report every one of them: a checkup that stops
# at the first failure sends the user round the loop once per problem.
assert_exit 1 "several problems at once still exit 1" \
  env KEMPT_REFRESH_HELPER="$TESTTMP/nope-refresh" KEMPT_POLICY_FILE="$TESTTMP/nope.policy" "$KEMPT" doctor
assert_eq "$(grep -c '^FAIL  root helper (refresh) not installed' "$TESTTMP/last_output" || true)" "1" \
  "every problem is reported, not just the first: the missing helper"
assert_eq "$(grep -c '^FAIL  polkit action not installed' "$TESTTMP/last_output" || true)" "1" \
  "...and the missing polkit action beside it"
assert_contains "$(cat "$TESTTMP/last_output")" '2 problems found' \
  "the summary counts them"

# --- files other users can change in dnf5's cache and state, left by helpers that kept the caller's umask ---
# Reported with the fix, never repaired. An entry counts when root does not own it, or when it is
# world-writable and not a link. Group-writable counts only with a group other than root: root's
# files belong to group root, and a umask of 002 sets that bit on every Fedora box that uses one.
# The test user owns everything it makes, so a plain run shows the "not root's" case; the rest run
# as root in a user namespace with spare ids, where chown to another user works.
DC="$TESTTMP/dnf cache"; mkdir -p "$DC/updates-1/repodata"
: > "$DC/updates-1/repodata/repomd.xml"; chmod 644 "$DC/updates-1/repodata/repomd.xml"
printf -v DCQ '%q' "$DC"
MOVE="t=\$(sudo mktemp -d $DCQ-unsafe.XXXXXX) && sudo mv -T --no-copy $DCQ \"\$t/old\" && sudo mkdir -m 0755 $DCQ && sudo restorecon $DCQ && sudo rm -rf --one-file-system \"\$t\""
# Another user still writing there can make that last rm fail, so the row says how to finish later.
RERUN="If the last step says the directory is not empty, run this again later: sudo rm -rf --one-file-system $DCQ-unsafe.*"
KEMPT_DNF_CACHE_DIR="$DC" "$KEMPT" doctor > "$TESTTMP/dc.txt" 2>&1 || true
assert_contains "$(cat "$TESTTMP/dc.txt")" "FAIL  dnf folders: other users can change files in $DC (for example $DC)" \
  "a cache root does not own is a FAIL, even with nothing world-writable in it"
assert_contains "$(tail -1 "$TESTTMP/dc.txt")" "1 problem found" "...and the last line counts it"
assert_contains "$(cat "$TESTTMP/dc.txt")" ". Do not use dnf5 clean all on it, because it can delete files outside the cache. Replace the cache with: $MOVE" \
  "...with the move-aside command, its path quoted for the shell, and a warning against dnf5 clean all"
assert_contains "$(cat "$TESTTMP/dc.txt")" "Replace the cache with: $MOVE. $RERUN" \
  "...followed by the rerun for a leftover directory, its path quoted the same way"
assert_not_contains "$(cat "$TESTTMP/dc.txt")" "sudo dnf5 clean all" "...and dnf5 clean all is never the advice"
assert_not_contains "$(cat "$TESTTMP/dc.txt")" "chmod -R go-w $DC" "...nor a chmod, which leaves another user's files theirs"
# A staged update keeps its packages outside the cache, so the fix is the same and never asks to discard it.
KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" KEMPT_DNF_CACHE_DIR="$DC" "$KEMPT" doctor > "$TESTTMP/dc.txt" 2>&1 || true
assert_contains "$(cat "$TESTTMP/dc.txt")" ". Do not use dnf5 clean all on it, because it can delete files outside the cache. Replace the cache with: $MOVE. $RERUN" \
  "with an offline transaction stored, the fix is the same move"
assert_not_contains "$(cat "$TESTTMP/dc.txt")" "unstage" "...and does not ask to discard the staged update"
assert_not_contains "$(cat "$TESTTMP/dc.txt")" "sudo dnf5 clean all" "...and never offers dnf5 clean all"
assert_eq "$(stat -c %a "$DC/updates-1/repodata/repomd.xml")" "644" "...and doctor changes nothing itself"
DS="$TESTTMP/dnf-sysimage"; mkdir -p "$DS/offline"
# dir → the state fix up to its chown -R: the directories locked first, then every second hard link deleted.
state_lock() {
  printf 'sudo find -P %s -type d -execdir chown -h root:root {} \\; -execdir chmod go-w {} \\; && sudo find -P %s ! -type d -links +1 -print -delete' "$1" "$1"
}
KEMPT_DNF_SYSIMAGE_DIR="$DS" "$KEMPT" doctor > "$TESTTMP/dc.txt" 2>&1 || true
assert_contains "$(cat "$TESTTMP/dc.txt")" "FAIL  dnf folders: other users can change files in $DS (for example $DS). Kempt 0.1.7 or earlier may have left them that way. Fix it with: $(state_lock "$DS") && sudo chown -R -h root:root $DS && sudo chmod -R go-w $DS && sudo find -P $DS -type l -print -delete && sudo dnf5 offline clean. The last step discards any update staged for the next restart, because its record may have been changed; stage it again afterwards. Then restart the computer. A program that opened one of these files earlier can still write to it until it stops. Run kempt doctor again afterwards, and repeat the fix if this line is still there." \
  "a state directory root does not own is a FAIL: lock the directories, drop hard links, chown, chmod, then the links, a restart and a second look"
# A staged update's packages install as root at the restart without a second signature check.
DO="$TESTTMP/dnf-offline"; mkdir -p "$DO/packages"; : > "$DO/packages/p.rpm"
KEMPT_DNF_OFFLINE_PKG_DIR="$DO" "$KEMPT" doctor > "$TESTTMP/dc.txt" 2>&1 || true
assert_contains "$(cat "$TESTTMP/dc.txt")" "FAIL  dnf folders: other users can change files in $DO (for example $DO). Kempt 0.1.7 or earlier may have left them that way. A changed package there installs as root at the next restart. Before you restart, discard the staged update and remove the folder: sudo dnf5 offline clean && sudo rm -rf --one-file-system $DO. Then stage the updates again." \
  "a staged-update folder root does not own is a FAIL: discard, remove, stage again"
assert_not_contains "$(cat "$TESTTMP/dc.txt")" "kempt doctor: all checks passed" "...and doctor does not call the box clean"
rm -rf "$DO"

ns_doctor() {  # var dir setup [env...] → kempt doctor's output as root in a user namespace; dir removed after
  local var="$1" dir="$2" setup="$3"; shift 3
  timeout 60 unshare --map-auto --map-root-user env KEMPT_ALLOW_ROOT=1 "$var=$dir" "$@" bash -c '
    mkdir -p "$1" && cd "$1" && eval "$2" || { echo "setup failed"; exit 9; }
    cd / && "$3" doctor 2>&1; rm -rf "$1" "$4"' _ "$dir" "$setup" "$KEMPT" "$TESTTMP/outside" || true
}
no_folder_fail() {  # doctor's output, title
  assert_not_contains "$1" "FAIL  dnf folders" "$2"
  assert_contains "$(tail -1 <<<"$1")" "kempt doctor:" "...and doctor ran to its end"
}
if timeout 20 unshare --map-auto --map-root-user true 2>/dev/null; then
  # Some cases need a second user inside the namespace. That takes subordinate ids (newuidmap and
  # /etc/subuid), which a CI runner may lack even when the namespace itself works.
  if timeout 20 unshare --map-auto --map-root-user bash -c 'f=$(mktemp) && chown 1000:1000 "$f"; r=$?; rm -f "$f"; exit $r' 2>/dev/null; then
    other_ids() { :; }
  else
    other_ids() { skip "no spare user ids in this namespace, so this case did not run: $1"; return 1; }
  fi
  NC="$TESTTMP/ns-cache"; printf -v NCQ '%q' "$NC"
  NMOVE="t=\$(sudo mktemp -d $NCQ-unsafe.XXXXXX) && sudo mv -T --no-copy $NCQ \"\$t/old\""
  out="$(ns_doctor KEMPT_DNF_CACHE_DIR "$NC" 'mkdir -p r/repodata; : > r/repodata/repomd.xml; chmod 644 r/repodata/repomd.xml; ln -s repomd.xml r/repodata/link')"
  assert_not_contains "$out" "setup failed" "the namespace run set up its cache"
  assert_contains "$(tail -1 <<<"$out")" "kempt doctor:" "...and reached the end of kempt doctor"
  no_folder_fail "$out" "a root-owned cache with no world-writable file adds no row"
  out="$(ns_doctor KEMPT_DNF_CACHE_DIR "$NC" ': > f; chmod 664 f')"
  no_folder_fail "$out" "...nor one that is only group-writable, group root"
  if other_ids "group-writable with a group other than root counts"; then
    out="$(ns_doctor KEMPT_DNF_CACHE_DIR "$NC" ': > f; chown 0:1000 f; chmod 664 f')"
    assert_contains "$out" "FAIL  dnf folders: other users can change files in $NC (for example $NC/f)" \
      "group-writable with a group other than root counts"
  fi
  if other_ids "a file another user owns counts, though nobody else can write it"; then
    out="$(ns_doctor KEMPT_DNF_CACHE_DIR "$NC" ': > f; chown 1000:0 f; chmod 644 f')"
    assert_contains "$out" "FAIL  dnf folders: other users can change files in $NC (for example $NC/f)" \
      "a file another user owns counts, though nobody else can write it"
  fi
  out="$(ns_doctor KEMPT_DNF_CACHE_DIR "$NC" ': > f; chmod 666 f')"
  assert_contains "$out" "FAIL  dnf folders: other users can change files in $NC (for example $NC/f)" \
    "a world-writable file counts"
  assert_contains "$out" "Replace the cache with: $NMOVE" "...with the move-aside command for that path"
  assert_not_contains "$out" "sudo dnf5 clean all" "...and never dnf5 clean all"
  out="$(ns_doctor KEMPT_DNF_CACHE_DIR "$NC" 'mkdir d; chmod 777 d')"
  assert_contains "$out" "FAIL  dnf folders: other users can change files in $NC (for example $NC/d)" \
    "a world-writable directory counts too"
  # A link planted in the cache is reported only for itself. Doctor never reads through it.
  if other_ids "links to another user's world-writable files outside are not followed"; then
    out="$(ns_doctor KEMPT_DNF_CACHE_DIR "$NC" 'mkdir -p "$4"; chmod 777 "$4"; : > "$4/open"; chmod 666 "$4/open"; chown -R 1000:1000 "$4"; mkdir r; ln -s "$4" r/packages; ln -s "$4/open" r/repodata')"
    no_folder_fail "$out" "links to another user's world-writable files outside are not followed"
  fi
  if other_ids "a link another user owns is reported as the link itself"; then
    out="$(ns_doctor KEMPT_DNF_CACHE_DIR "$NC" 'mkdir r; ln -s / r/packages; chown -h 1000:1000 r/packages')"
    assert_contains "$out" "FAIL  dnf folders: other users can change files in $NC (for example $NC/r/packages)" \
      "a link another user owns is reported as the link itself"
  fi
  NS="$TESTTMP/ns-state"
  if other_ids "a state file another user owns is a FAIL, the chown before the chmod"; then
    out="$(ns_doctor KEMPT_DNF_SYSIMAGE_DIR "$NS" 'mkdir offline; : > offline/transaction.json; chown 1000:0 offline/transaction.json')"
    assert_contains "$out" "FAIL  dnf folders: other users can change files in $NS (for example $NS/offline/transaction.json). Kempt 0.1.7 or earlier may have left them that way. Fix it with: $(state_lock "$NS") && sudo chown -R -h root:root $NS && sudo chmod -R go-w $NS" \
      "a state file another user owns is a FAIL, the chown before the chmod"
  fi
  out="$(ns_doctor KEMPT_DNF_SYSIMAGE_DIR "$NS" ': > f; chmod 666 f')"
  assert_contains "$out" "Fix it with: $(state_lock "$NS") && sudo chown -R -h root:root $NS && sudo chmod -R go-w $NS" \
    "a world-writable state file gets the same fix"
  out="$(ns_doctor KEMPT_DNF_SYSIMAGE_DIR "$NS" ': > f')"
  no_folder_fail "$out" "a root-owned state directory adds no row"
  # dnf5 keeps no links in its state, so the fix deletes them after the chown and chmod.
  out="$(ns_doctor KEMPT_DNF_SYSIMAGE_DIR "$NS" ': > f; chmod 666 f')"
  assert_contains "$out" "sudo chmod -R go-w $NS && sudo find -P $NS -type l -print -delete && sudo dnf5 offline clean. The last step discards any update staged for the next restart, because its record may have been changed; stage it again afterwards. Then restart the computer." \
    "...and the fix deletes the links last, then asks for a restart"
  # A hard link is the same file under a second name. Another user can link a file of theirs, or
  # one they can write, into the state folder, and chown -R would then make that file root's. The
  # fix, run as printed with sudo dropped and the dnf5 step stubbed, deletes the second name and
  # leaves the file outside exactly as it was. The rest of the folder still becomes root's.
  if other_ids "the state fix deletes a hard link to another user's file and leaves that file alone"; then
    # shellcheck disable=SC2016 # expanded by the inner bash
    out="$(timeout 60 unshare --map-auto --map-root-user env KEMPT_ALLOW_ROOT=1 KEMPT_DNF_SYSIMAGE_DIR="$NS" bash -c '
      mkdir -p "$1/offline" "$3" && : > "$3/victim" && chmod 664 "$3/victim" && chown 1000:1000 "$3/victim" \
        && ln "$3/victim" "$1/offline/transaction.json" && : > "$1/mine" && chown 1000:1000 "$1/mine" \
        || { echo "setup failed"; exit 9; }
      "$2" doctor > "$1.out" 2>&1
      grep -F "dnf folders:" "$1.out"
      fix="$(sed -n "s/^FAIL  dnf folders: .* Fix it with: \(.*\)\. The last step discards .*/\1/p" "$1.out")"
      [[ -n "$fix" ]] || { echo "no fix printed"; exit 9; }
      fix="${fix//sudo /}"; fix="${fix%dnf5 offline clean}true"
      eval "$fix" >/dev/null 2>&1 || echo "the fix failed"
      echo "victim $(stat -c "%u:%g %a %h" "$3/victim")"
      [[ -e "$1/offline/transaction.json" ]] && echo "linked name kept" || echo "linked name gone"
      echo "mine $(stat -c "%u:%g" "$1/mine")"
      rm -rf "$1" "$1.out" "$3"' _ "$NS" "$KEMPT" "$TESTTMP/outside")" || true
    assert_contains "$out" "FAIL  dnf folders: other users can change files in $NS (for example $NS/" \
      "a hard link to another user's file in the state folder is a FAIL"
    assert_contains "$out" "$(state_lock "$NS") && sudo chown -R -h root:root $NS" \
      "...and the fix deletes second hard links after locking the directories, before any chown"
    assert_not_contains "$out" "the fix failed" "...and the printed fix runs as written"
    assert_contains "$out" "victim 1000:1000 664 1" "...leaving the other user's file with its owner and mode"
    assert_contains "$out" "linked name gone" "...deleting only the name inside the state folder"
    assert_contains "$out" "mine 0:0" "...while the rest of the folder becomes root's"
  fi
  NO="$TESTTMP/ns-offline"
  out="$(ns_doctor KEMPT_DNF_OFFLINE_PKG_DIR "$NO" 'mkdir packages; : > packages/p.rpm')"
  no_folder_fail "$out" "a root-owned staged-update folder adds no row"
  out="$(ns_doctor KEMPT_DNF_OFFLINE_PKG_DIR "$NO" 'mkdir -m 0777 packages; : > packages/p.rpm')"
  assert_contains "$out" "FAIL  dnf folders: other users can change files in $NO (for example $NO/packages)" \
    "a world-writable staged-update folder is a FAIL"
  # The name is another user's choice: control bytes, C1 bytes and bidi controls all print as ?.
  if other_ids "a reported name keeps only printable ASCII, every other byte a ?"; then
    out="$(ns_doctor KEMPT_DNF_SYSIMAGE_DIR "$NS" ': > "$(printf "a\033[2Jb\302\233c\342\200\256d")"; chown 1000:0 a*')"
    assert_contains "$out" "(for example $NS/a?[2Jb??c???d)" \
      "a reported name keeps only printable ASCII, every other byte a ?"
  fi
else
  skip "no user namespace with spare ids here, so the root-owned dnf cache and state cases did not run"
fi
rm -rf "$DC" "$DS"


# --- offline: the failed fetch and the failed check are WARN rows, and the last line counts them ---
# A box where every check fails offline must not read "no problems" with nothing beside it.
warns_of() { local l; l="$(tail -1 "$1")"
  [[ "$l" =~ ([0-9]+)\ warnings?$ ]] && { echo "${BASH_REMATCH[1]}"; return; }; echo 0; }
rm -f "$STATE_FILE" "$REFRESH_DNF_FAILED_FILE"
"$KEMPT" doctor > "$TESTTMP/off.txt" 2>&1 || true
off_base="$(warns_of "$TESTTMP/off.txt")"
assert_not_contains "$(cat "$TESTTMP/off.txt")" "the last download failed" "no failure marker, no download row"
mkdir -p "$KEMPT_STATE_DIR"
printf 'Curl error (6): Could not resolve host: mirrors.fedoraproject.org\nsecond line\n' > "$REFRESH_DNF_FAILED_FILE"
printf '%s\n' '{"schema":1,"status":"stale","error":"dnf check failed: Cache-only enabled but no cache\nmore","actionable":0,"backends":{}}' > "$STATE_FILE"
"$KEMPT" doctor > "$TESTTMP/off.txt" 2>&1 || true
assert_contains "$(cat "$TESTTMP/off.txt")" \
  "WARN  package lists: the last download failed (Curl error (6): Could not resolve host: mirrors.fedoraproject.org). Checks answer from the lists already on this computer. Check the network connection, then run: kempt check --refresh" \
  "a failed dnf fetch is a WARN with the first line of its error"
assert_not_contains "$(cat "$TESTTMP/off.txt")" "never refreshed" "...and no second row contradicts it"
assert_not_contains "$(cat "$TESTTMP/off.txt")" "no dnf refresh recorded" "...in either wording"
assert_contains "$(cat "$TESTTMP/off.txt")" \
  "WARN  last check failed: dnf check failed: Cache-only enabled but no cache. There are no counts yet" \
  "a stale state is a WARN with the first line of its error, and no earlier check means no counts"
assert_eq "$(warns_of "$TESTTMP/off.txt")" "$(( off_base + 2 ))" "...and the last line counts both"
# dnf's no-cache text reads in the words kempt status uses, from the refresh error that says why.
printf '%s\n' '{"schema":1,"status":"stale","error":"dnf check failed: Cache-only enabled but no cache for repository \"fedora\"","last_success":"2026-08-20T10:00:00+03:00","actionable":0,"backends":{"dnf":{"refresh_error":"Curl error (6): Could not resolve host: mirrors.fedoraproject.org"}}}' > "$STATE_FILE"
"$KEMPT" doctor > "$TESTTMP/off.txt" 2>&1 || true
assert_contains "$(cat "$TESTTMP/off.txt")" \
  "WARN  last check failed: Package lists could not be downloaded: Curl error (6): Could not resolve host: mirrors.fedoraproject.org. The counts Kempt shows are from an earlier check" \
  "dnf's no-cache text becomes plain words, and an earlier success means the lists were downloaded once"
assert_not_contains "$(cat "$TESTTMP/off.txt")" "never been downloaded" "...so it never says never"
assert_not_contains "$(cat "$TESTTMP/off.txt")" "Cache-only" "...never dnf's raw text"
assert_not_contains "$(cat "$TESTTMP/off.txt")" "if any" "...and no hedge after the counts"
# The same reason kempt status gives (test_status.sh): a failure other than no cache keeps its own.
printf '%s\n' '{"schema":1,"status":"stale","error":"dnf check failed: Error: GPG check FAILED","actionable":0,"backends":{"dnf":{"refresh_error":"Status code: 404"}}}' > "$STATE_FILE"
"$KEMPT" doctor > "$TESTTMP/off.txt" 2>&1 || true
assert_contains "$(cat "$TESTTMP/off.txt")" "WARN  last check failed: dnf check failed: Error: GPG check FAILED. There are no counts yet" \
  "a failure other than no cache keeps its reason, as kempt status gives it"
# Refreshing turned off: the marker is from a download Kempt no longer tries, and the advice would
# fetch nothing, so there is no download row. The marker stays.
printf 'Curl error (6): Could not resolve host\n' > "$REFRESH_DNF_FAILED_FILE"
printf '%s\n' '{"schema":1,"status":"ok","actionable":0,"refresh_skipped":"off","backends":{}}' > "$STATE_FILE"
"$KEMPT" doctor > "$TESTTMP/off.txt" 2>&1 || true
assert_not_contains "$(cat "$TESTTMP/off.txt")" "the last download failed" "with refreshing turned off, no download row"
assert_exit 0 "...and the marker is left in place" -- test -f "$REFRESH_DNF_FAILED_FILE"
printf '%s\n' '{"schema":1,"status":"ok","actionable":0,"backends":{}}' > "$STATE_FILE"
KEMPT_SKIP_REFRESH=1 "$KEMPT" doctor > "$TESTTMP/off.txt" 2>&1 || true
assert_not_contains "$(cat "$TESTTMP/off.txt")" "the last download failed" "...the same when the switch is set for this run"
printf '%s\n' '{"schema":1,"status":"ok","actionable":0,"backends":{}}' > "$STATE_FILE"
rm -f "$REFRESH_DNF_FAILED_FILE"
"$KEMPT" doctor > "$TESTTMP/off.txt" 2>&1 || true
assert_not_contains "$(cat "$TESTTMP/off.txt")" "last check failed" "a state that is not stale adds no row"
rm -f "$STATE_FILE"

finish
