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
            'terminal emulator' 'flatpak' 'dnf' 'config file' 'state dir' 'checkout'; do
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
  env KEMPT_POLICY_FILE="$S_POLICY" "$KEMPT" doctor
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
grep -qE "^info  version: kempt $(cat "$REPO_ROOT/VERSION") \(checkout [0-9a-f]{7,} (clean|dirty)\)$" "$TESTTMP/skew.txt" \
  && echo "ok: the version line carries the commit and whether the tree is clean" \
  || { echo "FAIL: no version/commit line"; _fail=1; grep '^info  version' "$TESTTMP/skew.txt" | sed 's/^/    /'; }

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

# Several problems at once still exit 1 and still report every one of them: a checkup that stops
# at the first failure sends the user round the loop once per problem.
assert_exit 1 "several problems at once still exit 1" \
  env KEMPT_REFRESH_HELPER="$TESTTMP/nope-refresh" KEMPT_POLICY_FILE="$TESTTMP/nope.policy" "$KEMPT" doctor
assert_eq "$(grep -c '^FAIL' "$TESTTMP/last_output")" "2" "every problem is reported, not just the first"
grep -q '2 problems found' "$TESTTMP/last_output" \
  && echo "ok: the summary counts them" || { echo "FAIL: no problem count"; _fail=1; }
finish
