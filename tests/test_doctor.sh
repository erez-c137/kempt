#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
UPKEEP="$REPO_ROOT/bin/upkeep"

# `upkeep doctor` exists because of one verified trap: with the root helpers missing, `upkeep
# check` exits 0 with status "stale" and actionable 0, which reads to a human (and to a badge) as
# "you are up to date". Doctor is the command that says WHY the answer is empty.

mk_stub() { printf '#!/usr/bin/env bash\nexit 0\n' > "$1"; chmod +x "$1"; }

# A healthy install, expressed entirely through the seams: nothing here depends on what the box
# running the suite happens to have installed.
mk_stub "$TESTTMP/refresh-helper"
mk_stub "$TESTTMP/apply-helper"
mk_stub "$TESTTMP/fake-terminal"
cp "$REPO_ROOT/polkit/org.erez.upkeep.policy" "$TESTTMP/policy.xml"
export UPKEEP_REFRESH_HELPER="$TESTTMP/refresh-helper"
export UPKEEP_APPLY_HELPER="$TESTTMP/apply-helper"
export UPKEEP_TERMINAL="$TESTTMP/fake-terminal"
export UPKEEP_POLICY_FILE="$TESTTMP/policy.xml"
# the flatpak check asks whether the command the BACKEND runs exists, so the backend's own seam
# answers it: first word `cat`, which exists everywhere the suite runs.
export UPKEEP_FLATPAK_LIST_CMD="cat $FIXTURES/flatpak-list.tsv"

assert_exit 0 "healthy install: doctor exits 0" "$UPKEEP" doctor
grep -q 'all checks passed' "$TESTTMP/last_output" \
  && echo "ok: healthy install says so" || { echo "FAIL: no all-clear line"; _fail=1; }
grep -q '^FAIL' "$TESTTMP/last_output" \
  && { echo "FAIL: a healthy install reported a problem"; _fail=1; sed 's/^/    /' "$TESTTMP/last_output"; } \
  || echo "ok: no FAIL lines on a healthy install"
# every check reports, pass or fail: a silent doctor is a useless doctor. Matched against the
# REPORT LINES only - the usage text mentions half these words, so a plain grep over the whole
# output passes vacuously.
for want in 'root helper (refresh)' 'root helper (apply)' 'polkit action' 'jq' \
            'terminal emulator' 'flatpak' 'config file' 'state dir' 'checkout'; do
  grep -E '^(ok|info|FAIL) ' "$TESTTMP/last_output" | grep -qF "$want" && echo "ok: reports on $want" \
    || { echo "FAIL: no line for $want"; _fail=1; }
done
assert_exit 2 "doctor takes no arguments" "$UPKEEP" doctor --all

# --- the ownership branches, which nothing could reach before ---
# doctor checks root:root 0755 only when the helper it was handed IS the path polkit's exec.path
# pins, because that ownership is the whole point: a root-ownership check on a test stub proves
# nothing about the install. That also made BOTH branches unreachable from the suite - every stub
# is a seam override, so every run took the "ownership not checked" exit. The annotated path is
# therefore a seam of its own, and a test reaches the real check by setting it equal to the
# helper seam. Nothing is executed here; doctor only stats the path.
ME_U="$(id -un)"; ME_G="$(id -gn)"
assert_exit 0 "a helper that IS root:root 0755 at the annotated path passes" \
  env UPKEEP_REFRESH_HELPER=/usr/bin/ls UPKEEP_REFRESH_HELPER_PATH=/usr/bin/ls "$UPKEEP" doctor
grep -qF 'ok    root helper (refresh): /usr/bin/ls (root:root 0755)' "$TESTTMP/last_output" \
  && echo "ok: ...and the ok line reports the ownership it actually verified" \
  || { echo "FAIL: no verified-ownership ok line - got: $(grep 'root helper (refresh)' "$TESTTMP/last_output")"; _fail=1; }

# The other half: a helper sitting at the annotated path that root does not own is the shape a
# broken or tampered install has, and it must be a FAIL that names what it found.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/wrong-owner-helper"
chmod 644 "$TESTTMP/wrong-owner-helper"
assert_exit 1 "a helper at the annotated path that is not root:root 0755 fails the checkup" \
  env UPKEEP_APPLY_HELPER="$TESTTMP/wrong-owner-helper" \
      UPKEEP_APPLY_HELPER_PATH="$TESTTMP/wrong-owner-helper" "$UPKEEP" doctor
grep -qF "root helper (apply) is $ME_U:$ME_G 644, expected root:root 755" "$TESTTMP/last_output" \
  && echo "ok: ...and the FAIL line names the owner and the mode it found" \
  || { echo "FAIL: ownership mismatch not named - got: $(grep 'root helper (apply)' "$TESTTMP/last_output")"; _fail=1; }
grep -q 're-run ./install.sh' "$TESTTMP/last_output" \
  && echo "ok: ...and says how to fix it" || { echo "FAIL: no remedy in the ownership message"; _fail=1; }

# --- the trap itself: a check that looks like good news, and the command that explains it ---
export UPKEEP_SKIP_REFRESH=1
export UPKEEP_DNF_INSTALLED_CMD="cat $FIXTURES/rpm-installed.tsv"
export UPKEEP_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
rc=0
state="$(UPKEEP_REFRESH_HELPER="$TESTTMP/nope-refresh" "$UPKEEP" check 2>/dev/null)" || rc=$?
assert_eq "$rc" "0" "with no root helper, check still exits 0"
assert_eq "$(jq -r .backends.dnf.actionable <<<"$state")" "0" \
  "...and reports 0 pending system updates, which reads as up to date"
assert_eq "$(jq -r .status <<<"$state")" "stale" "...with only 'stale' to hint that anything is wrong"
# ...and the one clue check DOES give has to point at the real cause. The raw stderr is
# "timeout: failed to run command '<path>': No such file or directory" - the `timeout` wrapper
# naming a file that does not exist, which reads as "the check timed out" and sends the user
# hunting a network problem they do not have.
assert_eq "$(jq -r .error <<<"$state")" \
  "dnf check failed: root helper not installed - run ./install.sh (see: upkeep doctor)" \
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
astate="$(UPKEEP_REFRESH_HELPER="$TESTTMP/angry-refresh" "$UPKEEP" check 2>/dev/null)"
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
tstate="$(UPKEEP_REFRESH_HELPER="$TESTTMP/two-line-refresh" "$UPKEEP" check 2>/dev/null)"
assert_eq "$(jq -r .error <<<"$tstate")" "dnf check failed: first line second line" \
  "the stale error joins lines with single spaces and ends with no trailing space"

assert_exit 1 "...while doctor fails and names the missing helper" \
  env UPKEEP_REFRESH_HELPER="$TESTTMP/nope-refresh" "$UPKEEP" doctor
grep -q 'root helper (refresh) not installed' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names the refresh helper" || { echo "FAIL: no refresh-helper line"; _fail=1; }
grep -q 'install.sh' "$TESTTMP/last_output" \
  && echo "ok: ...and says how to fix it" || { echo "FAIL: no remedy in the message"; _fail=1; }
unset UPKEEP_DNF_INSTALLED_CMD UPKEEP_FLATPAK_REMOTE_CMD UPKEEP_SKIP_REFRESH

# --- one failure class at a time, each proving its own FAIL line ---

assert_exit 1 "a missing apply helper fails the checkup" \
  env UPKEEP_APPLY_HELPER="$TESTTMP/nope-apply" "$UPKEEP" doctor
grep -q 'root helper (apply) not installed' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names the apply helper" || { echo "FAIL: no apply-helper line"; _fail=1; }

assert_exit 1 "a missing polkit action fails the checkup" \
  env UPKEEP_POLICY_FILE="$TESTTMP/nope.policy" "$UPKEEP" doctor
grep -q 'polkit action not installed' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names the polkit action" || { echo "FAIL: no polkit line"; _fail=1; }

# The terminal emulator matters only where it is actually used. surface=terminal (the default)
# means `upkeep run` exits 4 every time without it, so that is a failure; a detached surface does
# not launch one at all, so saying "FAIL" there would be a lie the user cannot act on.
assert_exit 1 "a missing terminal emulator fails while surface=terminal" \
  env UPKEEP_TERMINAL=upkeep-no-such-terminal "$UPKEEP" doctor
grep -q "terminal emulator 'upkeep-no-such-terminal' not found" "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names the missing emulator" || { echo "FAIL: no terminal line"; _fail=1; }
"$UPKEEP" config set surface background
assert_exit 0 "...but not on a detached surface" \
  env UPKEEP_TERMINAL=upkeep-no-such-terminal "$UPKEEP" doctor
grep -q "^info .*terminal emulator" "$TESTTMP/last_output" \
  && echo "ok: it is an info line for a surface that never launches one" \
  || { echo "FAIL: expected an info line for the unused emulator"; _fail=1; }
"$UPKEEP" config set surface terminal

# Same rule for flatpak: a backend that is switched off must not be reported as broken.
assert_exit 1 "a missing flatpak fails while include_flatpak=true" \
  env UPKEEP_FLATPAK_LIST_CMD="upkeep-no-such-flatpak list" "$UPKEEP" doctor
grep -q '^FAIL .*flatpak' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names flatpak" || { echo "FAIL: no flatpak line"; _fail=1; }
"$UPKEEP" config set include_flatpak false
assert_exit 0 "...but is only an info line when include_flatpak=false" \
  env UPKEEP_FLATPAK_LIST_CMD="upkeep-no-such-flatpak list" "$UPKEEP" doctor
grep -q '^info .*flatpak' "$TESTTMP/last_output" \
  && echo "ok: a disabled backend is information, not a failure" \
  || { echo "FAIL: expected an info line for the disabled backend"; _fail=1; }
"$UPKEEP" config set include_flatpak true

# The settings count pluralizes itself, and docs/usage.md's sample output is pinned to this
# wording: "(2 settings)", never "(2 setting(s))".
: > "$CONFIG_FILE"; "$UPKEEP" config set surface terminal
"$UPKEEP" doctor > "$TESTTMP/doctor-1key" 2>&1 || true
grep -qF "config file: $CONFIG_FILE (1 setting)" "$TESTTMP/doctor-1key" \
  && echo "ok: one key reads '1 setting'" \
  || { echo "FAIL: singular count - got: $(grep 'config file:' "$TESTTMP/doctor-1key")"; _fail=1; }
"$UPKEEP" config set auto_accept true
"$UPKEEP" doctor > "$TESTTMP/doctor-2keys" 2>&1 || true
grep -qF "config file: $CONFIG_FILE (2 settings)" "$TESTTMP/doctor-2keys" \
  && echo "ok: two keys read '2 settings', the sample docs/usage.md prints" \
  || { echo "FAIL: plural count - got: $(grep 'config file:' "$TESTTMP/doctor-2keys")"; _fail=1; }

# A config file is read by every command with `grep "^key="`, so a line that is not key=value is
# silently ignored forever - the setting the user thinks they wrote never applies.
printf 'surface terminal\n' >> "$CONFIG_FILE"
assert_exit 1 "an unparseable config line fails the checkup" "$UPKEEP" doctor
grep -q 'config file line .* is not key=value' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line quotes the bad line" || { echo "FAIL: no config-parse line"; _fail=1; }
# a key the config_set validation would refuse is just as dead
printf 'Surface=terminal\n' > "$CONFIG_FILE"
assert_exit 1 "a config key that config set would refuse fails the checkup" "$UPKEEP" doctor
grep -q 'config file line' "$TESTTMP/last_output" \
  && echo "ok: an invalid key is reported too" || { echo "FAIL: invalid key accepted"; _fail=1; }
: > "$CONFIG_FILE"
"$UPKEEP" config set surface terminal

# State that cannot be written means no badge, no history, no logs.
mkdir -p "$UPKEEP_STATE_DIR"; chmod 500 "$UPKEEP_STATE_DIR"
assert_exit 1 "an unwritable state dir fails the checkup" "$UPKEEP" doctor
grep -q 'state dir not writable' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line names the state dir" || { echo "FAIL: no state-dir line"; _fail=1; }
chmod 700 "$UPKEEP_STATE_DIR"

# The checkout is load-bearing (the CLI is a symlink into it), and the pieces that are NOT sourced
# at startup can go missing without anything noticing until the day they are needed.
CO="$TESTTMP/checkout"
mkdir -p "$CO"
cp -r "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/backends" "$REPO_ROOT/polkit" "$CO/"
rm -f "$CO/polkit/49-upkeep.rules.in"
assert_exit 1 "an incomplete checkout fails the checkup" "$CO/bin/upkeep" doctor
grep -q 'checkout incomplete' "$TESTTMP/last_output" \
  && echo "ok: the FAIL line says the checkout is incomplete" || { echo "FAIL: no checkout line"; _fail=1; }
grep -q '49-upkeep.rules.in' "$TESTTMP/last_output" \
  && echo "ok: ...and names the missing file" || { echo "FAIL: missing file not named"; _fail=1; }

# Several problems at once still exit 1 and still report every one of them: a checkup that stops
# at the first failure sends the user round the loop once per problem.
assert_exit 1 "several problems at once still exit 1" \
  env UPKEEP_REFRESH_HELPER="$TESTTMP/nope-refresh" UPKEEP_POLICY_FILE="$TESTTMP/nope.policy" "$UPKEEP" doctor
assert_eq "$(grep -c '^FAIL' "$TESTTMP/last_output")" "2" "every problem is reported, not just the first"
grep -q '2 problems found' "$TESTTMP/last_output" \
  && echo "ok: the summary counts them" || { echo "FAIL: no problem count"; _fail=1; }
finish
