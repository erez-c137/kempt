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
mk_stub "$TESTTMP/fake-terminal"
cp "$REPO_ROOT/polkit/io.github.erez_c137.kempt.policy" "$TESTTMP/policy.xml"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-helper"
export KEMPT_APPLY_HELPER="$TESTTMP/apply-helper"
export KEMPT_TERMINAL="$TESTTMP/fake-terminal"
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
# staged-transaction line it says nothing about.
export KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml"

# Where a REAL install puts its copies, staged into the sandbox through install.sh's own --destdir
# seam - so what the install-skew section compares is a real staged install rather than a
# hand-built lookalike that could agree with a bug in either file. Exported for the whole file:
# left at their defaults these point into /usr/local/libexec and the developer's own plasmoid
# directory, and the skew verdict would then depend on what the box running the suite happens to
# have installed, which is the one thing this file promises never to do.
# The ANNOTATED paths, not the executable seams: doctor compares the copies the INSTALLER wrote,
# which in production are the paths polkit pins. The stubs above stay where they are, so every
# helper line keeps taking its "seam override" branch exactly as before.
STAGE="$TESTTMP/stage"
bash "$REPO_ROOT/install.sh" --destdir "$STAGE" >/dev/null
S_REFRESH="$STAGE/usr/local/libexec/kempt-refresh"
S_APPLY="$STAGE/usr/local/libexec/kempt-apply"
S_POLICY="$STAGE/usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy"
S_WIDGET="$STAGE$HOME/.local/share/plasma/plasmoids/io.github.erez_c137.kempt"
export KEMPT_REFRESH_HELPER_PATH="$S_REFRESH" KEMPT_APPLY_HELPER_PATH="$S_APPLY"
export KEMPT_PLASMOID_DIR="$S_WIDGET"
for f in "$S_REFRESH" "$S_APPLY" "$S_POLICY"; do
  [[ -f "$f" ]] || { echo "FAIL: --destdir staged no $f"; _fail=1; }
done
[[ -d "$S_WIDGET" ]] || { echo "FAIL: --destdir staged no widget package"; _fail=1; }

assert_exit 0 "healthy install: doctor exits 0" "$KEMPT" doctor
grep -q 'all checks passed' "$TESTTMP/last_output" \
  && echo "ok: healthy install says so" || { echo "FAIL: no all-clear line"; _fail=1; }
grep -q '^FAIL' "$TESTTMP/last_output" \
  && { echo "FAIL: a healthy install reported a problem"; _fail=1; sed 's/^/    /' "$TESTTMP/last_output"; } \
  || echo "ok: no FAIL lines on a healthy install"
# every check reports, pass or fail: a silent doctor is a useless doctor. Matched against the
# REPORT LINES only - the usage text mentions half these words, so a plain grep over the whole
# output passes vacuously.
for want in 'root helper (refresh)' 'root helper (apply)' 'polkit action' 'jq' \
            'terminal emulator' 'flatpak' 'dnf' 'config file' 'state dir' 'checkout' \
            'polkit exec.path (refresh)' 'polkit exec.path (apply)' 'widget engine'; do
  grep -E '^(ok|info|FAIL) ' "$TESTTMP/last_output" | grep -qF "$want" && echo "ok: reports on $want" \
    || { echo "FAIL: no line for $want"; _fail=1; }
done
assert_exit 2 "doctor takes no arguments" "$KEMPT" doctor --all

# --- the ownership branches, which nothing could reach before ---
# doctor checks root:root 0755 only when the helper it was handed IS the path polkit's exec.path
# pins, because that ownership is the whole point: a root-ownership check on a test stub proves
# nothing about the install. That also made BOTH branches unreachable from the suite - every stub
# is a seam override, so every run took the "ownership not checked" exit. The annotated path is
# therefore a seam of its own, and a test reaches the real check by setting it equal to the
# helper seam. Nothing is executed here; doctor only stats the path.
ME_U="$(id -un)"; ME_G="$(id -gn)"
# Exit 1 rather than 0, and the extra FAIL is the install-skew section doing its job on the same
# fixture: /usr/bin/ls is root:root 0755, which is the only reason the ownership branch is
# reachable without root at all, and it is just as obviously not this checkout's kempt-refresh. The
# ownership line is what this case is about; the skew line is asserted with it so the pair cannot
# drift apart unnoticed.
assert_exit 1 "a helper that IS root:root 0755 at the annotated path passes its ownership check" \
  env KEMPT_REFRESH_HELPER=/usr/bin/ls KEMPT_REFRESH_HELPER_PATH=/usr/bin/ls "$KEMPT" doctor
grep -qF 'ok    root helper (refresh): /usr/bin/ls (root:root 0755)' "$TESTTMP/last_output" \
  && echo "ok: ...and the ok line reports the ownership it actually verified" \
  || { echo "FAIL: no verified-ownership ok line - got: $(grep 'root helper (refresh)' "$TESTTMP/last_output")"; _fail=1; }
grep -qF 'FAIL  helpers: DIFFER from checkout' "$TESTTMP/last_output" \
  && echo "ok: ...while the skew check says that file is not the checkout's helper" \
  || { echo "FAIL: skew check accepted /usr/bin/ls as the installed helper"; _fail=1; }

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
grep -q 're-run ./install.sh' "$TESTTMP/last_output" \
  && echo "ok: ...and says how to fix it" || { echo "FAIL: no remedy in the ownership message"; _fail=1; }

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
as_annotated() {  # policy-file -> a checkup with both helpers at /usr/bin/ls
  env KEMPT_POLICY_FILE="$1" \
      KEMPT_REFRESH_HELPER=/usr/bin/ls KEMPT_REFRESH_HELPER_PATH=/usr/bin/ls \
      KEMPT_APPLY_HELPER=/usr/bin/ls   KEMPT_APPLY_HELPER_PATH=/usr/bin/ls "$KEMPT" doctor
}

# Agreement is the ordinary state, and it must cost the report nothing. The one FAIL is the install
# skew section doing its job: /usr/bin/ls is obviously not this checkout's kempt-refresh.
mk_policy "$TESTTMP/policy-agree.xml" /usr/bin/ls /usr/bin/ls
assert_exit 1 "a policy that pins the helper this CLI runs is not a problem of its own" \
  -- as_annotated "$TESTTMP/policy-agree.xml"
grep -q '^FAIL  polkit exec.path' "$TESTTMP/last_output" \
  && { echo "FAIL: agreement was reported as a problem"; _fail=1; } \
  || echo "ok: ...and adds no FAIL of its own (the one there is the install skew)"
for a in refresh apply; do
  grep -qF "ok    polkit exec.path ($a): /usr/bin/ls" "$TESTTMP/last_output" \
    && echo "ok: ...and the $a line names the path both sides agree on" \
    || { echo "FAIL: no exec.path ok line for $a - got: $(grep 'exec.path' "$TESTTMP/last_output")"; _fail=1; }
done

# The split install itself: one action pinned somewhere else. This is the shape an RPM policy over
# a checkout CLI has, and it is a FAIL because nothing privileged can run without a dialog.
mk_policy "$TESTTMP/policy-split.xml" /usr/bin/ls /usr/libexec/kempt-apply
assert_exit 1 "a policy that pins a different apply helper fails the checkup" \
  -- as_annotated "$TESTTMP/policy-split.xml"
grep -qE '^FAIL  polkit exec.path \(apply\)' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names the action that disagrees" \
  || { echo "FAIL: no exec.path FAIL line - got: $(grep 'exec.path' "$TESTTMP/last_output")"; _fail=1; }
# BOTH paths, because the reader cannot act on either one alone: which is wrong depends on which
# install they meant to have.
ep_line="$(grep '^FAIL  polkit exec.path (apply)' "$TESTTMP/last_output" || true)"
[[ "$ep_line" == */usr/libexec/kempt-apply* && "$ep_line" == */usr/bin/ls* ]] \
  && echo "ok: ...naming the path the policy pins and the path this CLI runs" \
  || { echo "FAIL: the FAIL line does not name both paths - got: $ep_line"; _fail=1; }
grep -qF 'authentication dialog' "$TESTTMP/last_output" \
  && echo "ok: ...and what it costs, which is a dialog on every privileged run" \
  || { echo "FAIL: the consequence is not named"; _fail=1; }
grep -qF 'background checks time out' "$TESTTMP/last_output" \
  && echo "ok: ...including the background check nobody is there to answer" \
  || { echo "FAIL: the background-check consequence is not named"; _fail=1; }
grep -qF './install.sh' "$TESTTMP/last_output" \
  && echo "ok: ...and the remedy for a checkout" || { echo "FAIL: no checkout remedy"; _fail=1; }
grep -qF 'sudo dnf reinstall kempt' "$TESTTMP/last_output" \
  && echo "ok: ...and the remedy for a package" || { echo "FAIL: no package remedy"; _fail=1; }
# The action that still agrees still passes: two actions, two verdicts, never one summary.
grep -qF 'ok    polkit exec.path (refresh): /usr/bin/ls' "$TESTTMP/last_output" \
  && echo "ok: ...while the action that agrees is still reported as ok" \
  || { echo "FAIL: a mismatch on one action condemned the other"; _fail=1; }

# A policy with no annotation at all is not a verdict either way: an action without an exec.path is
# not an action pkexec would run these helpers through, and saying "mismatch" would send the reader
# after a path that is not there.
grep -v 'policykit.exec.path' "$REPO_ROOT/polkit/io.github.erez_c137.kempt.policy" \
  > "$TESTTMP/policy-noann.xml"
assert_exit 1 "a policy with no exec.path annotation is reported, not failed" \
  -- as_annotated "$TESTTMP/policy-noann.xml"
grep -q '^FAIL  polkit exec.path' "$TESTTMP/last_output" \
  && { echo "FAIL: an absent annotation was reported as a mismatch"; _fail=1; } \
  || echo "ok: ...and an absent annotation is not a problem"
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
grep -qE '^info  polkit exec.path \(refresh\): not compared' "$TESTTMP/exec.txt" \
  && echo "ok: a helper seam override is not compared against the policy" \
  || { echo "FAIL: no seam-override info line - got: $(grep 'exec.path' "$TESTTMP/exec.txt")"; _fail=1; }

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
grep -qF 'the widget would run' "$TESTTMP/last_output" \
  && echo "ok: ...in the order that says which is which" \
  || { echo "FAIL: no 'the widget would run' wording"; _fail=1; }

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
  "dnf check failed: root helper not installed - run ./install.sh (see: kempt doctor)" \
  "the stale error names the missing helper, not a timeout"
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
grep -q 'root helper (refresh) not installed' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names the refresh helper" || { echo "FAIL: no refresh-helper line"; _fail=1; }
grep -q 'install.sh' "$TESTTMP/last_output" \
  && echo "ok: ...and says how to fix it" || { echo "FAIL: no remedy in the message"; _fail=1; }
unset KEMPT_DNF_INSTALLED_CMD KEMPT_FLATPAK_REMOTE_CMD KEMPT_SKIP_REFRESH

# --- one failure class at a time, each proving its own FAIL line ---

assert_exit 1 "a missing apply helper fails the checkup" \
  env KEMPT_APPLY_HELPER="$TESTTMP/nope-apply" "$KEMPT" doctor
grep -q 'root helper (apply) not installed' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names the apply helper" || { echo "FAIL: no apply-helper line"; _fail=1; }

assert_exit 1 "a missing polkit action fails the checkup" \
  env KEMPT_POLICY_FILE="$TESTTMP/nope.policy" "$KEMPT" doctor
grep -q 'polkit action not installed' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names the polkit action" || { echo "FAIL: no polkit line"; _fail=1; }

# The terminal emulator matters only where it is actually used. surface=terminal (the default)
# means `kempt run` exits 4 every time without it, so that is a failure; a detached surface does
# not launch one at all, so saying "FAIL" there would be a lie the user cannot act on.
assert_exit 1 "a missing terminal emulator fails while surface=terminal" \
  env KEMPT_TERMINAL=kempt-no-such-terminal "$KEMPT" doctor
grep -q "terminal emulator 'kempt-no-such-terminal' not found" "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names the missing emulator" || { echo "FAIL: no terminal line"; _fail=1; }
"$KEMPT" config set surface background
assert_exit 0 "...but not on a detached surface" \
  env KEMPT_TERMINAL=kempt-no-such-terminal "$KEMPT" doctor
grep -q "^info .*terminal emulator" "$TESTTMP/last_output" \
  && echo "ok: it is an info line for a surface that never launches one" \
  || { echo "FAIL: expected an info line for the unused emulator"; _fail=1; }
"$KEMPT" config set surface terminal

# Same rule for flatpak: a backend that is switched off must not be reported as broken.
assert_exit 1 "a missing flatpak fails while include_flatpak=true" \
  env KEMPT_FLATPAK_LIST_CMD="kempt-no-such-flatpak list" "$KEMPT" doctor
grep -q '^FAIL .*flatpak' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names flatpak" || { echo "FAIL: no flatpak line"; _fail=1; }
"$KEMPT" config set include_flatpak false
assert_exit 0 "...but is only an info line when include_flatpak=false" \
  env KEMPT_FLATPAK_LIST_CMD="kempt-no-such-flatpak list" "$KEMPT" doctor
grep -q '^info .*flatpak' "$TESTTMP/last_output" \
  && echo "ok: a disabled backend is information, not a failure" \
  || { echo "FAIL: expected an info line for the disabled backend"; _fail=1; }
"$KEMPT" config set include_flatpak true

# --- the command behind the reboot verdict -----------------------------------------------------
# `kempt check` is the hourly, detached path, so when this command cannot run its
# "warning: reboot check failed (rc=127)" goes to a stderr nobody is attached to, and the event
# log records nothing about it either. reboot_needed then answers false on every check forever,
# which is the safe direction and is also indistinguishable from "no restart is owed". Doctor is
# where a permanently broken check becomes visible instead.
#
# info, not FAIL: nothing else in Kempt runs this command. The pending list and the update itself
# both go through the root helper, so updates keep working exactly as they did - one derived
# answer degrades, and it degrades safely.
assert_exit 0 "a missing dnf command does not fail doctor" \
  env KEMPT_DNF_CMD=kempt-no-such-dnf "$KEMPT" doctor
grep -q "^info .*dnf command 'kempt-no-such-dnf' not found" "$TESTTMP/last_output" \
  && echo "ok: the info line names the missing dnf command" \
  || { echo "FAIL: no dnf info line"; _fail=1; }
grep '^info .*dnf command' "$TESTTMP/last_output" | grep -q 'restart' \
  && echo "ok: ...and says which answer degrades, not merely that a file is missing" \
  || { echo "FAIL: the dnf info line does not say what stops working"; _fail=1; }
# The healthy line names the command the BACKEND would run - first word of the seam - so a seam
# carrying arguments is still resolved rather than reported as one long missing filename.
assert_exit 0 "a dnf command carrying arguments still resolves" \
  env KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no --setopt=keepcache=1" "$KEMPT" doctor
grep -qF "ok    dnf: $TESTTMP/dnf-reboot-no" "$TESTTMP/last_output" \
  && echo "ok: the ok line names the resolved dnf command" \
  || { echo "FAIL: no dnf ok line"; _fail=1; }

# The settings count pluralizes itself, and docs/usage.md's sample output is pinned to this
# wording: "(2 settings)", never "(2 setting(s))".
: > "$CONFIG_FILE"; "$KEMPT" config set surface terminal
"$KEMPT" doctor > "$TESTTMP/doctor-1key" 2>&1 || true
grep -qF "config file: $CONFIG_FILE (1 setting)" "$TESTTMP/doctor-1key" \
  && echo "ok: one key reads '1 setting'" \
  || { echo "FAIL: singular count - got: $(grep 'config file:' "$TESTTMP/doctor-1key")"; _fail=1; }
"$KEMPT" config set auto_accept true
"$KEMPT" doctor > "$TESTTMP/doctor-2keys" 2>&1 || true
grep -qF "config file: $CONFIG_FILE (2 settings)" "$TESTTMP/doctor-2keys" \
  && echo "ok: two keys read '2 settings', the sample docs/usage.md prints" \
  || { echo "FAIL: plural count - got: $(grep 'config file:' "$TESTTMP/doctor-2keys")"; _fail=1; }

# A config file is read by every command with `grep "^key="`, so a line that is not key=value is
# silently ignored forever - the setting the user thinks they wrote never applies.
printf 'surface terminal\n' >> "$CONFIG_FILE"
assert_exit 1 "an unparseable config line fails the checkup" "$KEMPT" doctor
grep -q 'config file line .* is not key=value' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line quotes the bad line" || { echo "FAIL: no config-parse line"; _fail=1; }
# a key the config_set validation would refuse is just as dead
printf 'Surface=terminal\n' > "$CONFIG_FILE"
assert_exit 1 "a config key that config set would refuse fails the checkup" "$KEMPT" doctor
grep -q 'config file line' "$TESTTMP/last_output" \
  && echo "ok: an invalid key is reported too" || { echo "FAIL: invalid key accepted"; _fail=1; }
: > "$CONFIG_FILE"
"$KEMPT" config set surface terminal

# State that cannot be written means no badge, no history, no logs.
mkdir -p "$KEMPT_STATE_DIR"; chmod 500 "$KEMPT_STATE_DIR"
assert_exit 1 "an unwritable state dir fails the checkup" "$KEMPT" doctor
grep -q 'state dir not writable' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names the state dir" || { echo "FAIL: no state-dir line"; _fail=1; }
chmod 700 "$KEMPT_STATE_DIR"

# The checkout is load-bearing (the CLI is a symlink into it), and the pieces that are NOT sourced
# at startup can go missing without anything noticing until the day they are needed.
CO="$TESTTMP/checkout"
mkdir -p "$CO"
cp -r "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/backends" "$REPO_ROOT/polkit" "$CO/"
rm -f "$CO/polkit/49-kempt.rules.in"
assert_exit 1 "an incomplete checkout fails the checkup" "$CO/bin/kempt" doctor
grep -q 'checkout incomplete' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line says the checkout is incomplete" || { echo "FAIL: no checkout line"; _fail=1; }
grep -q '49-kempt.rules.in' "$TESTTMP/last_output" \
  && echo "ok: ...and names the missing file" || { echo "FAIL: missing file not named"; _fail=1; }

# --- install skew: the copies that `git pull` cannot move ---------------------------------------
# The CLI is a symlink into the checkout, so a pull updates it the moment it lands. The two root
# helpers, the polkit action and the widget package are COPIES, and a pull without ./install.sh
# leaves all three behind - the code root runs is still the code from the last install, and until
# this section existed nothing anywhere said so. The staged install exported at the top of this
# file is what stands in for one here.
doctor_staged() {  # -> $TESTTMP/last_output, via assert_exit
  # Without cmp on PATH (nocmp_dir): "match checkout" must be decided without diffutils, or a
  # minimal box reports every helper as drifted.
  env PATH="$(nocmp_dir):$PATH" KEMPT_POLICY_FILE="$S_POLICY" "$KEMPT" doctor
}

assert_exit 0 "a freshly staged install matches the checkout it came from" -- doctor_staged
for want in 'ok    helpers: match checkout' 'ok    policy: match checkout' 'ok    widget: match checkout'; do
  grep -qF "$want" "$TESTTMP/last_output" && echo "ok: reports $want" \
    || { echo "FAIL: no '$want' line"; _fail=1; sed 's/^/    /' "$TESTTMP/last_output"; }
done

# The whole point, one file at a time. A byte appended to a staged copy is what a pull that
# changed that file looks like from doctor's side, and each one must be caught on its own.
printf '# drifted\n' >> "$S_APPLY"
assert_exit 1 "a root helper that drifted from the checkout fails the checkup" -- doctor_staged
grep -qF 'FAIL  helpers: DIFFER from checkout - run ./install.sh' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names the fix" || { echo "FAIL: no helpers skew line"; _fail=1; }
bash "$REPO_ROOT/install.sh" --destdir "$STAGE" >/dev/null
assert_exit 0 "...and re-running the installer clears it" -- doctor_staged

printf '<!-- drifted -->\n' >> "$S_POLICY"
assert_exit 1 "a polkit action that drifted from the checkout fails the checkup" -- doctor_staged
grep -qF 'FAIL  policy: DIFFER from checkout - run ./install.sh' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names the fix" || { echo "FAIL: no policy skew line"; _fail=1; }
bash "$REPO_ROOT/install.sh" --destdir "$STAGE" >/dev/null

# The widget is a whole directory, so the comparison is recursive: a change anywhere under it
# counts, and a file that a pull DELETED counts too.
printf '// drifted\n' >> "$S_WIDGET/contents/ui/logic.js"
assert_exit 1 "a widget package that drifted from the checkout fails the checkup" -- doctor_staged
grep -qF 'FAIL  widget: DIFFER from checkout - run ./install.sh, then plasmashell --replace' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line says the shell has to reload too" || { echo "FAIL: no widget skew line"; _fail=1; }
rm -rf "$S_WIDGET"; bash "$REPO_ROOT/install.sh" --destdir "$STAGE" >/dev/null
rm -f "$S_WIDGET/contents/ui/UpdateItemDelegate.qml"
assert_exit 1 "a file the checkout no longer has is skew as well" -- doctor_staged
grep -qF 'FAIL  widget: DIFFER' "$TESTTMP/last_output" \
  && echo "ok: a missing file inside the package is reported" || { echo "FAIL: deletion not caught"; _fail=1; }
rm -rf "$S_WIDGET"; bash "$REPO_ROOT/install.sh" --destdir "$STAGE" >/dev/null

# Absence is not skew, and the two must not be confused. The widget is optional (install.sh says
# so, and a box with no kpackagetool6 gets a working CLI without it), so a missing one is an info.
rm -rf "$S_WIDGET"
assert_exit 0 "a widget that was never installed is not a problem" -- doctor_staged
grep -qF 'info  widget: not installed (the CLI works without it)' "$TESTTMP/last_output" \
  && echo "ok: ...and says so in one line" || { echo "FAIL: no widget-absent line"; _fail=1; }

# A missing root helper IS a problem, but it is already a FAIL on its own line: counting it twice
# would make one broken install read as two.
rm -f "$S_APPLY"
doctor_staged > "$TESTTMP/skew.txt" 2>&1 || true
grep -qF 'info  helpers: not installed - run ./install.sh' "$TESTTMP/skew.txt" \
  && echo "ok: a helper that is absent rather than drifted is an info, not a second FAIL" \
  || { echo "FAIL: absent helper misreported"; _fail=1; sed 's/^/    /' "$TESTTMP/skew.txt"; }
bash "$REPO_ROOT/install.sh" --destdir "$STAGE" >/dev/null

# --- which build is this, and which kind of install -------------------------------------------
# The opening line names the release; this one names the COMMIT, which is the difference between
# "0.1.0" and the several commits of 0.1.0 a reporter might be running.
doctor_staged > "$TESTTMP/skew.txt" 2>&1 || true
# Only a git checkout can carry a commit; a release tarball (the RPM check stage runs the
# suite from one) exercises the no-git form, which the next assertion covers on its own.
if [[ -d "$REPO_ROOT/.git" ]]; then
  grep -qE "^info  version: kempt $(cat "$REPO_ROOT/VERSION") \(checkout [0-9a-f]{7,} (clean|dirty)\)$" "$TESTTMP/skew.txt" \
    && echo "ok: the version line carries the commit and whether the tree is clean" \
    || { echo "FAIL: no version/commit line"; _fail=1; grep '^info  version' "$TESTTMP/skew.txt" | sed 's/^/    /'; }
else
  echo "skip: not a git checkout - the no-git version line is asserted below"
fi

# A tree with no .git still reports a version: git is a diagnostic here, never a requirement.
NOGIT="$TESTTMP/nogit"
mkdir -p "$NOGIT"
cp -r "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/backends" "$REPO_ROOT/polkit" \
      "$REPO_ROOT/libexec" "$REPO_ROOT/plasmoid" "$REPO_ROOT/VERSION" "$NOGIT/"
cp "$REPO_ROOT/install.sh" "$NOGIT/install.sh"
env KEMPT_POLICY_FILE="$S_POLICY" "$NOGIT/bin/kempt" doctor > "$TESTTMP/skew.txt" 2>&1 || true
grep -qE "^info  version: kempt $(cat "$REPO_ROOT/VERSION")$" "$TESTTMP/skew.txt" \
  && echo "ok: a checkout with no git history still names its release" \
  || { echo "FAIL: version line wrong without git"; _fail=1; grep '^info  version' "$TESTTMP/skew.txt" | sed 's/^/    /'; }

# A packaged install has nothing to compare: the RPM ships bin/, lib/ and backends/ and none of
# libexec/, polkit/ or plasmoid/, because those become files the package manager owns. install.sh
# is the file a checkout has and a package does not, so its absence is what decides.
rm -f "$NOGIT/install.sh"
env KEMPT_POLICY_FILE="$S_POLICY" "$NOGIT/bin/kempt" doctor > "$TESTTMP/skew.txt" 2>&1 || true
grep -qF 'info  install: packaged - the package manager keeps these files in step' "$TESTTMP/skew.txt" \
  && echo "ok: a packaged install says so" || { echo "FAIL: not reported as packaged"; _fail=1; }
grep -qE '^(ok|info|FAIL)  (helpers|policy|widget):' "$TESTTMP/skew.txt" \
  && { echo "FAIL: a packaged install still compared against a checkout"; _fail=1; } \
  || echo "ok: ...and skips the comparison entirely"

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
grep -q 'shadows' "$TESTTMP/last_output" \
  && { echo "FAIL: warned about a user copy that is not there"; _fail=1; } \
  || echo "ok: ...and says nothing about one"

# The trap itself: both copies on the box at once.
mkdir -p "$STORE_COPY/contents/ui"
cp "$REPO_ROOT/plasmoid/metadata.json" "$STORE_COPY/metadata.json"
assert_exit 1 "a user copy shadowing the packaged widget fails the checkup" \
  -- doctor_packaged "$STORE_COPY"
grep -qF "user widget copy shadows the package: $STORE_COPY" "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names the directory" \
  || { echo "FAIL: no shadow line"; _fail=1; sed 's/^/    /' "$TESTTMP/last_output"; }
# The consequence, in words, because "shadows" is jargon on its own: what the user loses is every
# future update of the widget, silently.
grep -qF 'package updates never reach your panel' "$TESTTMP/last_output" \
  && echo "ok: ...and what it costs, which is every future update of the widget" \
  || { echo "FAIL: the consequence is not named"; _fail=1; }
# ...and the exact fix, which needs no root and which the user cannot be expected to guess.
grep -qF 'kpackagetool6 -t Plasma/Applet -r io.github.erez_c137.kempt' "$TESTTMP/last_output" \
  && echo "ok: ...and the exact command that removes it" \
  || { echo "FAIL: the removal command is not spelled out"; _fail=1; }
grep -qF 'plasmashell --replace' "$TESTTMP/last_output" \
  && echo "ok: ...and that the shell has to reload before it takes effect" \
  || { echo "FAIL: the plasmashell reload is not named"; _fail=1; }

# --- the widget is its own package, and a packaged install has to say so ------------------------
# The CLI and the panel widget ship separately (kempt / kempt-plasmoid), so a perfectly healthy CLI
# can sit on a box with no widget in the panel and nothing anywhere would explain why.
doctor_packaged "$TESTTMP/absent-user-widget" > "$TESTTMP/skew.txt" 2>&1 || true
grep -qF 'panel widget not installed - it is a separate package: sudo dnf install kempt-plasmoid' \
     "$TESTTMP/skew.txt" \
  && echo "ok: a packaged install with no widget names the package that carries it" \
  || { echo "FAIL: no widget-package line"; _fail=1; sed 's/^/    /' "$TESTTMP/skew.txt"; }
# ...and says nothing once the package IS installed. The line is a pointer, not a nag.
SYS_WIDGET="$TESTTMP/sys-widget"; mkdir -p "$SYS_WIDGET/contents"
env KEMPT_POLICY_FILE="$S_POLICY" KEMPT_PLASMOID_DIR="$TESTTMP/absent-user-widget" \
    KEMPT_SYSTEM_PLASMOID_DIR="$SYS_WIDGET" "$NOGIT/bin/kempt" doctor > "$TESTTMP/skew.txt" 2>&1 || true
grep -q 'panel widget not installed' "$TESTTMP/skew.txt" \
  && { echo "FAIL: told a box with the widget package that it has no widget"; _fail=1; } \
  || echo "ok: ...and stays quiet once the widget package is there"

# --- a packaged install refuses to certify a hijacked update path -------------------------------
# The seams below are how the suite runs, and on a real box they are how `kempt update` becomes a
# no-op that reports success: six lines in ~/.config/environment.d pointing them at /bin/true, and
# every other row in this report goes on describing an install those lines have stepped around. A
# checkout catches it by comparing files; a packaged install has no checkout to compare, so this
# is the only thing standing between a box that quietly stopped updating and a report saying it is
# healthy.
# Read-only, because that is what makes it a package rather than a fixture: the row is gated on a
# tree the caller cannot write, which is the one thing about a packaged install that an
# environment variable cannot fake.
chmod a-w "$NOGIT"
for seam in KEMPT_PKEXEC KEMPT_APPLY_HELPER KEMPT_REFRESH_HELPER; do
  env KEMPT_POLICY_FILE="$S_POLICY" KEMPT_PLASMOID_DIR="$TESTTMP/absent-user-widget" \
      "$NOGIT/bin/kempt" doctor > "$TESTTMP/skew.txt" 2>&1 || true
  grep -qF "privileged path overridden in the environment" "$TESTTMP/skew.txt" \
    && grep -qF "$seam" "$TESTTMP/skew.txt" \
    && echo "ok: a packaged install names $seam as an override rather than certifying itself" \
    || { echo "FAIL: $seam override not reported"; _fail=1; sed 's/^/    /' "$TESTTMP/skew.txt"; }
done
grep -q 'all checks passed' "$TESTTMP/skew.txt" \
  && { echo "FAIL: a hijacked packaged install still certified itself"; _fail=1; } \
  || echo "ok: ...and does not end with 'all checks passed'"
chmod u+w "$NOGIT"
# The fix has to be findable: the person reading this did not set these on purpose.
grep -qF 'look in ~/.config/environment.d and your shell profile' "$TESTTMP/skew.txt" \
  && echo "ok: ...and says where such a setting comes from" \
  || { echo "FAIL: no pointer to where the override lives"; _fail=1; }
# A CHECKOUT is where the suite lives, and there the file comparisons already tell the truth about
# what is installed, so the same seams must NOT fail - or no test in this suite could run doctor.
doctor_staged > "$TESTTMP/skew.txt" 2>&1 || true
grep -q 'privileged path overridden' "$TESTTMP/skew.txt" \
  && { echo "FAIL: a checkout was told its test seams are an override"; _fail=1; } \
  || echo "ok: a checkout says nothing about them - its file comparisons answer the question"

# On a CHECKOUT install that same directory IS the install - install.sh puts it there with the
# same kpackagetool6 - so there is nothing shadowing anything and nothing to remove. A warning
# here would be telling a developer to delete their own widget.
doctor_staged > "$TESTTMP/skew.txt" 2>&1 || true
grep -q 'shadows' "$TESTTMP/skew.txt" \
  && { echo "FAIL: a checkout install was told its own widget shadows something"; _fail=1; } \
  || echo "ok: in a checkout the user copy IS the install, so nothing warns about it"

# The removal command needs no root and cannot be guessed, so it is documented as well as
# reported. A reader who hits this at install time should not have to run doctor to find it.
grep -qF 'kpackagetool6 -t Plasma/Applet -r io.github.erez_c137.kempt' "$REPO_ROOT/docs/install.md" \
  && echo "ok: docs/install.md spells out the same removal command doctor names" \
  || { echo "FAIL: install.md does not carry the removal command"; _fail=1; }

# --- the staged transaction, which doctor is the only surface that can explain --------------------
# TWO facts in two places: Kempt's marker, and dnf5's own transaction status. Every other surface
# reads them reconciled; doctor reads them side by side, and its whole value is the case where they
# disagree. A real box spent a day in exactly that state - a marker over a transaction that was
# downloaded and never armed - with every surface reporting a pending install that no restart
# could deliver, and nothing anywhere able to say so.
D_MARKER="$KEMPT_STATE_DIR/offline_staged.json"
# Armed is TWO things - dnf5 at `ready` AND the /system-update symlink - and the sandbox pins the
# symlink at a path that does not exist, because that is the state of every box that has not just
# staged something. So the whole staged section below runs with a live one, and the cases that are
# ABOUT the symlink being gone point the seam back at nothing themselves.
export KEMPT_OFFLINE_LINK="$TESTTMP/armed-system-update"
ln -sfn "$TESTTMP" "$KEMPT_OFFLINE_LINK"
NO_LINK="$TESTTMP/no-system-update"
mkdir -p "$KEMPT_STATE_DIR"
doctor_out() { "$KEMPT" doctor > "$TESTTMP/staged.txt" 2>&1 || true; }

# Nothing staged and no marker: nothing to say, and doctor does not say it. A line per run about a
# transaction that does not exist is noise on every box that has never staged one.
rm -f "$D_MARKER"
KEMPT_OFFLINE_LINK="$NO_LINK" doctor_out   # nothing staged means no symlink either
grep -qiE '^(ok|info|FAIL)  .*staged' "$TESTTMP/staged.txt" \
  && { echo "FAIL: a box with nothing staged still reported on it"; _fail=1; } \
  || echo "ok: no staged transaction, no line about one"

# ARMED and pending: the normal case, and information rather than a problem. It is the one thing
# the report can say that answers "why is `kempt check` still listing these packages?".
printf '{"staged_at":"2026-09-02T10:31:00+03:00","pre_snapshot":"/x.tsv","boot_id":"b","staged":61,"armed":true}\n' > "$D_MARKER"
assert_exit 0 "an armed staged transaction is not a problem" \
  env KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" "$KEMPT" doctor
grep -qF 'info  staged update: 61 packages install on the next restart' "$TESTTMP/last_output" \
  && echo "ok: ...and doctor says how many, and when" \
  || { echo "FAIL: no staged line - got: $(grep -i staged "$TESTTMP/last_output")"; _fail=1; }
# One package is its own sentence here too. Doctor's rows are read by people pasting them into bug
# reports, and "1 packages" is the line that gets quoted back.
printf '{"staged_at":"x","pre_snapshot":"/x.tsv","boot_id":"b","staged":1,"armed":true}\n' > "$D_MARKER"
KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" doctor_out
grep -qF 'info  staged update: 1 package installs on the next restart' "$TESTTMP/staged.txt" \
  && echo "ok: a single staged package reads as one" \
  || { echo "FAIL: singular staged row - got: $(grep -i staged "$TESTTMP/staged.txt")"; _fail=1; }
printf '{"staged_at":"x","pre_snapshot":"/x.tsv","boot_id":"b","staged":2,"armed":true}\n' > "$D_MARKER"
KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" doctor_out
grep -qF 'info  staged update: 2 packages install on the next restart' "$TESTTMP/staged.txt" \
  && echo "ok: ...and two is back to the plural" \
  || { echo "FAIL: plural staged row - got: $(grep -i staged "$TESTTMP/staged.txt")"; _fail=1; }
# A marker from before the count existed still describes a real pending install.
printf '{"staged_at":"x","pre_snapshot":"/x.tsv","boot_id":"b"}\n' > "$D_MARKER"
KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" doctor_out
grep -qF 'info  staged update: it installs on the next restart' "$TESTTMP/staged.txt" \
  && echo "ok: an unknown count loses the number, not the line" \
  || { echo "FAIL: no countless staged line - got: $(grep -i staged "$TESTTMP/staged.txt")"; _fail=1; }

# THE STUCK STAGE FROM A REAL BOX, and the reason this section exists. `dnf5 upgrade --offline`
# leaves the transaction at download-complete; only `dnf5 offline reboot` arms it. Unarmed, it
# installs on no restart ever, and the marker over it makes every other surface promise it will.
printf '{"staged_at":"2026-09-01T10:31:00+03:00","pre_snapshot":"/x.tsv","boot_id":"b","staged":61}\n' > "$D_MARKER"
assert_exit 1 "a stage that was never armed is a problem, and doctor exits on it" \
  env KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml" "$KEMPT" doctor
grep -qE '^FAIL  staged update can never install' "$TESTTMP/last_output" \
  && echo "ok: ...saying it can never install, not that it is pending" \
  || { echo "FAIL: no never-install line - got: $(grep -i staged "$TESTTMP/last_output")"; _fail=1; }
# The exact command, because a diagnosis a person cannot act on is half a diagnosis - and this one
# needs root, so it cannot be a kempt subcommand.
grep -qF 'sudo dnf5 offline clean' "$TESTTMP/last_output" \
  && echo "ok: ...and names the exact command that clears it" \
  || { echo "FAIL: the fix command is missing"; _fail=1; }

# A marker whose transaction is gone. Nothing for the user to do: the next check clears it, and
# saying so is more useful than either silence or an alarm.
KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml" KEMPT_OFFLINE_LINK="$NO_LINK" doctor_out
grep -qE '^info  staged update: the transaction is gone' "$TESTTMP/staged.txt" \
  && echo "ok: a marker with no transaction left is reported, and not as a problem" \
  || { echo "FAIL: no gone-transaction line - got: $(grep -i staged "$TESTTMP/staged.txt")"; _fail=1; }
grep -qE '^FAIL' "$TESTTMP/staged.txt" \
  && { echo "FAIL: a marker the next check clears was reported as a problem"; _fail=1; } \
  || echo "ok: ...and it does not fail the checkup"

# Somebody else's transaction: `dnf5 upgrade --offline` typed in a terminal, or another tool. Kempt
# did not stage it, will not harvest it, and must not claim it - but a person reading this report
# because a restart installed something they did not expect deserves to be told it is there.
rm -f "$D_MARKER"
KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" doctor_out
grep -qE '^info  an offline transaction is staged outside Kempt' "$TESTTMP/staged.txt" \
  && echo "ok: a transaction Kempt did not stage is named as somebody else's" \
  || { echo "FAIL: no outside-Kempt line - got: $(grep -i staged "$TESTTMP/staged.txt")"; _fail=1; }
grep -qF 'dnf5 offline status' "$TESTTMP/staged.txt" \
  && echo "ok: ...pointing at the command that describes it" \
  || { echo "FAIL: no dnf5 offline status pointer"; _fail=1; }

# --- the marker read the way every other reader reads it ------------------------------------------
# doctor used to jq the marker file directly, so a torn or garbage one answered `empty` for the
# count and fell straight through to the armed row: a report whose whole job is to catch a
# disagreement between two files was describing a pending install off a file it could not parse.
printf '{"staged_at":"2026-09-02T10:31:00+03:0' > "$D_MARKER"
assert_exit 0 "a marker that will not parse does not crash the checkup" \
  env KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" "$KEMPT" doctor
grep -qE '^info  staged update: the marker cannot be read' "$TESTTMP/last_output" \
  && echo "ok: ...and says so instead of describing a pending install it cannot see" \
  || { echo "FAIL: no unreadable-marker line - got: $(grep -i staged "$TESTTMP/last_output")"; _fail=1; }
grep -qF 'installs on the next restart' "$TESTTMP/last_output" \
  && { echo "FAIL: an unparsable marker was still reported as a pending install"; _fail=1; } \
  || echo "ok: ...and claims nothing about what a restart would do"

# The marker a detour boot demoted: `armed: false`, over a transaction that is not ready. The row
# that matters is unchanged - this transaction can never install - and it is still a FAIL, which is
# the whole reason reconciliation demotes the marker instead of clearing it.
jq -n '{staged_at:"2026-09-02T10:31:00+03:00", pre_snapshot:"/x.tsv", boot_id:"b", staged:61,
        armed:false}' > "$D_MARKER"
assert_exit 1 "a demoted marker still fails the checkup over a transaction that cannot install" \
  env KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml" "$KEMPT" doctor
grep -qE '^FAIL  staged update can never install' "$TESTTMP/last_output" \
  && echo "ok: ...with the same precise row, which is what clearing the marker would have lost" \
  || { echo "FAIL: no never-install line for a demoted marker - got: $(grep -i staged "$TESTTMP/last_output")"; _fail=1; }

# --- the hold that arrived after the stage, on the report a worried person runs --------------------
# info and not FAIL: doctor has ok/info/FAIL and nothing between, and a package installing despite a
# hold is a legitimate state (dnf5 built that transaction before the hold existed and offers no way
# to edit a stored one). A FAIL for something legitimate is how a report teaches people to ignore
# FAILs. The bluntness lives in the sentence, and the sentence ends with BOTH remedies: the person
# who held a kernel may want the stage gone rather than rebuilt.
d_marker() {  # names-source names-json
  jq -n --arg src "$1" --argjson names "$2" \
    '{staged_at:"2026-09-02T10:31:00+03:00", pre_snapshot:"/x.tsv", boot_id:"b", staged:3,
      armed:true, staged_names_source:$src, staged_names:$names, staged_excluded:[]}' > "$D_MARKER"
}
printf 'not a transaction\n' > "$TESTTMP/tx-garbage.json"
d_marker transaction '["ca-certificates","librepo","openldap"]'
"$KEMPT" hold dnf:librepo >/dev/null 2>&1
assert_exit 0 "a hold behind an armed stage is reported, and is not a failure" \
  env KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" "$KEMPT" doctor
grep -qF 'info  staged update: it installs librepo on the next restart despite the hold -' "$TESTTMP/last_output" \
  && echo "ok: ...leading with what happens and naming the package" \
  || { echo "FAIL: no conflict line - got: $(grep -i staged "$TESTTMP/last_output")"; _fail=1; }
grep -qF 'kempt update --surface=offline' "$TESTTMP/last_output" \
  && grep -qF 'sudo dnf5 offline clean' "$TESTTMP/last_output" \
  && echo "ok: ...and ending with both remedies, rebuild it or remove it" \
  || { echo "FAIL: the conflict line does not carry both remedies"; _fail=1; }

# Three names, and the verb moves with them.
"$KEMPT" hold dnf:ca-certificates >/dev/null 2>&1
"$KEMPT" hold dnf:openldap >/dev/null 2>&1
KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" doctor_out
grep -qF 'staged update: it installs ca-certificates, librepo and openldap on the next restart despite the holds -' "$TESTTMP/staged.txt" \
  && echo "ok: three held packages read as a sentence, plural verb included" \
  || { echo "FAIL: no plural conflict line - got: $(grep -i staged "$TESTTMP/staged.txt")"; _fail=1; }

# Six, which is where the cap earns its place: a Qt or KDE bump legitimately puts dozens of names in
# the set, and a doctor row that lists them all is a row nobody reads to the end.
d_marker transaction '["bash","curl","glibc","kernel-core","mesa","systemd"]'
for n in bash curl glibc kernel-core mesa systemd; do "$KEMPT" hold "dnf:$n" >/dev/null 2>&1; done
KEMPT_OFFLINE_TXJSON="$TESTTMP/tx-garbage.json" KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" doctor_out
grep -qF 'staged update: it installs bash, curl, glibc, kernel-core, and 2 more on the next restart despite the holds -' "$TESTTMP/staged.txt" \
  && echo "ok: past four names the rest are counted, not listed" \
  || { echo "FAIL: no capped conflict line - got: $(grep -i staged "$TESTTMP/staged.txt")"; _fail=1; }

# No list may be trusted - the names came from a check, which cannot see the packages the resolver
# added - and there is a dnf hold on the box. The generic form fires: it can be wrong by warning
# about a package that is not in there, and must never be wrong by staying quiet about one that is.
d_marker check '["kernel-core"]'
KEMPT_OFFLINE_TXJSON="$TESTTMP/tx-garbage.json" KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" doctor_out
grep -qF 'info  staged update: it may still install held packages on the next restart -' "$TESTTMP/staged.txt" \
  && echo "ok: a list that cannot deny anything gets the generic line, not silence" \
  || { echo "FAIL: no generic conflict line - got: $(grep -i staged "$TESTTMP/staged.txt")"; _fail=1; }
grep -qF 'sudo dnf5 offline clean' "$TESTTMP/staged.txt" \
  && echo "ok: ...carrying both remedies as well" \
  || { echo "FAIL: the generic line does not carry both remedies"; _fail=1; }

# Nothing held: no line at all. The row exists to answer a question nobody has asked otherwise.
for n in librepo ca-certificates openldap bash curl glibc kernel-core mesa systemd; do
  "$KEMPT" unhold "dnf:$n" >/dev/null 2>&1
done
d_marker transaction '["ca-certificates","librepo","openldap"]'
KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" doctor_out
grep -qE 'despite the hold|may still install held packages' "$TESTTMP/staged.txt" \
  && { echo "FAIL: a conflict line with nothing held"; _fail=1; } \
  || echo "ok: no hold, no conflict line"

# --- and the drift line: the staged transaction is not the one Kempt built -------------------------
# The marker records what Kempt staged; dnf5's own transaction file says what is stored right now.
# They can disagree - anything running as this user inside the authentication keep window can
# replace an armed transaction - and then every Kempt surface is describing a set that is not there.
# FAIL, because unlike the hold above this is nothing anyone chose.
d_marker transaction '["ca-certificates","kernel-core"]'
assert_exit 1 "a staged transaction that is not the one Kempt built fails the checkup" \
  env KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" "$KEMPT" doctor
grep -qF 'FAIL  staged update is not the one Kempt built' "$TESTTMP/last_output" \
  && echo "ok: ...saying whose record it is reading, not just that something is wrong" \
  || { echo "FAIL: no drift line - got: $(grep -i staged "$TESTTMP/last_output")"; _fail=1; }
grep -qF -- "+librepo and +openldap in dnf5's record only" "$TESTTMP/last_output" \
  && grep -qF -- "-kernel-core in Kempt's only" "$TESTTMP/last_output" \
  && echo "ok: ...and names both directions of the difference" \
  || { echo "FAIL: the drift line does not name both directions - got: $(grep -i 'not the one' "$TESTTMP/last_output")"; _fail=1; }
grep -qF 'kempt update --surface=offline' "$TESTTMP/last_output" \
  && grep -qF 'sudo dnf5 offline clean' "$TESTTMP/last_output" \
  && echo "ok: ...and ends with both remedies too" \
  || { echo "FAIL: the drift line does not carry both remedies"; _fail=1; }

# The same two sets, agreeing: no line. A report that fires on equality is a report that gets muted.
d_marker transaction '["ca-certificates","librepo","openldap"]'
assert_exit 0 "a transaction that matches what Kempt staged is not drift" \
  env KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" "$KEMPT" doctor
grep -qF 'is not the one Kempt built' "$TESTTMP/last_output" \
  && { echo "FAIL: equal sets reported as drift"; _fail=1; } \
  || echo "ok: equal sets say nothing"

# A CHECK-derived list is not evidence of drift: a check cannot see the packages the resolver added,
# so it disagrees with the stored transaction routinely and legitimately. There is nothing to
# compare honestly, so nothing is claimed.
d_marker check '["kernel-core"]'
assert_exit 0 "a check-derived list is never compared against dnf5's record" \
  env KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" "$KEMPT" doctor
grep -qF 'is not the one Kempt built' "$TESTTMP/last_output" \
  && { echo "FAIL: a check-derived list was reported as drift"; _fail=1; } \
  || echo "ok: nothing to compare, nothing claimed"

# ...and neither is a record that will not parse: the marker's list may be perfect and there is
# simply nothing to hold it against.
d_marker transaction '["ca-certificates","kernel-core"]'
assert_exit 0 "a transaction record that will not parse is not drift either" \
  env KEMPT_OFFLINE_TXJSON="$TESTTMP/tx-garbage.json" KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" "$KEMPT" doctor
grep -qF 'is not the one Kempt built' "$TESTTMP/last_output" \
  && { echo "FAIL: an unreadable record was reported as drift"; _fail=1; } \
  || echo "ok: an unreadable record makes no claim about the marker"
rm -f "$D_MARKER"

# --- the boot symlink, and the state nothing in Kempt could see -----------------------------------
# Arming creates /system-update, and systemd's system-update-generator looks for that symlink and
# nothing else. Leave it behind over a transaction that is not `ready` - which is exactly what a
# replace-stage leaves in the middle, since dnf5 destroys the old transaction the moment the new one
# begins - and the next boot detours into the offline updater, installs nothing, and comes back with
# no trace anywhere. Kempt read the toml and never the symlink, so with no marker on the box this
# state was invisible to the one command whose job is to see it.
D_LINK="$TESTTMP/system-update"
# DANGLING on purpose: the symlink is the mechanism, its target is not, and a check that resolved
# the target would answer "no problem" for the boot that is about to detour.
ln -s "$TESTTMP/nothing-here" "$D_LINK"
rm -f "$D_MARKER"

# The normal armed state, which must stay silent: symlink present, transaction ready. This is what
# every successfully staged box looks like between the stage and the restart.
KEMPT_OFFLINE_LINK="$D_LINK" KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" doctor_out
grep -qE '^FAIL' "$TESTTMP/staged.txt" \
  && { echo "FAIL: an armed transaction was reported as a problem"; _fail=1; } \
  || echo "ok: symlink plus a ready transaction is the armed state, not a fault"

# Symlink over a transaction that was never armed, with NO marker: somebody else's stage, or ours
# replaced mid-rebuild. The remedy needs root, so it is spelled out.
assert_exit 1 "a live boot symlink over an unarmed transaction fails the checkup" \
  env KEMPT_OFFLINE_LINK="$D_LINK" KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml" "$KEMPT" doctor
grep -qF 'FAIL  boot symlink is live over a transaction that is not armed (status "download-complete")' "$TESTTMP/last_output" \
  && echo "ok: ...naming the status the boot will detour on" \
  || { echo "FAIL: no unarmed-symlink line - got: $(grep -i symlink "$TESTTMP/last_output")"; _fail=1; }
grep -qF 'sudo dnf5 offline clean' "$TESTTMP/last_output" \
  && echo "ok: ...and the exact command that clears it" \
  || { echo "FAIL: the fix command is missing from the symlink row"; _fail=1; }

# Symlink with no transaction behind it at all. Worse, not better: the boot still detours, and
# there is not even a transaction for it to consider.
assert_exit 1 "a boot symlink with nothing staged behind it fails the checkup" \
  env KEMPT_OFFLINE_LINK="$D_LINK" KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml" "$KEMPT" doctor
grep -qF 'FAIL  boot symlink is live with nothing staged behind it' "$TESTTMP/last_output" \
  && echo "ok: ...and says the transaction is not there rather than quoting a status" \
  || { echo "FAIL: no orphan-symlink line - got: $(grep -i symlink "$TESTTMP/last_output")"; _fail=1; }

# Marker or no marker, and both rows when both apply: they are two different facts about the same
# box - one says the stage can never install, the other says the next boot detours on the way to
# finding that out - and each has a reader who needs it.
printf '{"staged_at":"x","pre_snapshot":"/x.tsv","boot_id":"b","staged":61}\n' > "$D_MARKER"
KEMPT_OFFLINE_LINK="$D_LINK" KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml" doctor_out
assert_eq "$(grep -c '^FAIL' "$TESTTMP/staged.txt")" "2" \
  "a marker does not suppress the symlink row, and the symlink does not suppress the marker's"

# No symlink is no row, whatever the toml says: the marker's own FAIL is the only one left. Without
# this the two conditions could be read as one and the check would fire on the toml alone.
KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml" KEMPT_OFFLINE_LINK="$NO_LINK" doctor_out
assert_eq "$(grep -c '^FAIL' "$TESTTMP/staged.txt")" "1" \
  "no boot symlink, no symlink row - the unarmed transaction is reported once"
# The INVERSE of the row above, and it had no row at all: dnf5 says `ready` and the symlink is
# GONE. Arming is both, systemd removes the symlink once system-update.target has been reached,
# and only `dnf5 offline reboot` makes it again - so this transaction installs on no restart,
# ever. Every surface used to call it a pending install and doctor exited 0.
printf '{"staged_at":"x","pre_snapshot":"/x.tsv","boot_id":"b","staged":7,"armed":true}\n' > "$D_MARKER"
assert_exit 1 "a ready transaction with no boot symlink fails the checkup" \
  env KEMPT_OFFLINE_LINK="$NO_LINK" KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" "$KEMPT" doctor
grep -qF 'staged update can never install: dnf5 says "ready" but' "$TESTTMP/last_output" \
  && echo "ok: ...and the row says the transaction can never install" \
  || { echo "FAIL: no ready-without-symlink row"; _fail=1; grep -i staged "$TESTTMP/last_output" | sed 's/^/    /'; }
grep -qF 'kempt update --surface=offline' "$TESTTMP/last_output" \
  && echo "ok: ...and offers the re-stage that fixes it" \
  || { echo "FAIL: the row does not say how to re-arm it"; _fail=1; }
# ...and with the symlink there, the same transaction is fine. The two conditions are one row, and
# reading them as one would make every armed stage a failure.
assert_exit 0 "the same transaction with its symlink standing is not a problem" \
  env KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" "$KEMPT" doctor

rm -f "$D_MARKER" "$D_LINK"
# ...and out of the staged section: back to a box with no restart marker, which is what every
# case below assumes and what a box that has not just staged something actually looks like.
export KEMPT_OFFLINE_LINK="$NO_LINK"

# Several problems at once still exit 1 and still report every one of them: a checkup that stops
# at the first failure sends the user round the loop once per problem.
assert_exit 1 "several problems at once still exit 1" \
  env KEMPT_REFRESH_HELPER="$TESTTMP/nope-refresh" KEMPT_POLICY_FILE="$TESTTMP/nope.policy" "$KEMPT" doctor
assert_eq "$(grep -c '^FAIL' "$TESTTMP/last_output")" "2" "every problem is reported, not just the first"
grep -q '2 problems found' "$TESTTMP/last_output" \
  && echo "ok: the summary counts them" || { echo "FAIL: no problem count"; _fail=1; }
finish
