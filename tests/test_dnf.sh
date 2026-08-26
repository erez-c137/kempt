#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/backends/dnf.sh"

# Pure parser: fixture lines + installed lookup → items JSON
# Fixture contract (tests/fixtures/MANIFEST.md): parses to exactly 7 items — the
# bash.i686/bash.x86_64 multilib pair collapses despite DIVERGENT EVRs, the indented
# "Obsoleting Packages" row and its header are filtered, brandnew is absent from rpm-installed.tsv.
out="$(dnf_parse_check_update "$FIXTURES/rpm-installed.tsv" < "$FIXTURES/dnf-check-update.txt")"
assert_eq "$(jq 'length' <<<"$out")" "7" "7 items (multilib collapses, obsoleted rows and headers filtered)"
assert_eq "$(jq -r '.[0] | has("name") and has("from") and has("to")' <<<"$out")" "true" "item shape"
assert_eq "$(jq -r '[.[].name] | any(test("\\.(x86_64|noarch|i686)$"))' <<<"$out")" "false" "arch suffix stripped"
assert_eq "$(jq -r '[.[].name] | map(select(. == "bash")) | length' <<<"$out")" "1" "bash appears once despite two arches"
# The wrinkle this pins: LEXICALLY, 5.3.10-1 sorts BEFORE 5.3.9-4 ("1" < "9" at the third
# character), so a plain sort put the older build last - and "last" is what every consumer calls
# newest (render_summary's newest(), the widget's newestOf). Version-aware sorting is what makes
# the set ascending, so the newest EVR really is the last element.
assert_eq "$(jq -r '.[] | select(.name == "bash") | .to' <<<"$out")" "5.3.9-4.fc44,5.3.10-1.fc44" "divergent multilib EVRs collapse into one comma-joined to-version, oldest first"
assert_eq "$(jq -r '[.[].name] | any(. == "old-tool")' <<<"$out")" "false" "obsoleted package is not reported as a pending update"
assert_eq "$(jq -r '[.[].name] | any(test("^Obsoleting"))' <<<"$out")" "false" "section header is not parsed as a package"
assert_eq "$(jq -r '.[] | select(.name == "brandnew") | .from' <<<"$out")" "?" "not-installed package falls back to ?"
assert_eq "$(jq -r '[.[] | select(.name != "brandnew") | .from] | any(. == "?" or . == "")' <<<"$out")" "false" "installed packages resolve real from-versions"

# --- a collapsed set is ASCENDING, and both branches of the lookup get there the same way ---
# "Last element = newest" is the contract every consumer relies on (render_summary's newest(),
# the widget's newestOf). Lexically it is simply false for the everyday pair 1.9 vs 1.10, because
# "1" sorts before "9" at the third character. And the seam branch of dnf_installed_lookup used
# to skip the sort entirely, so a stub could hand collapse_versions rows in any order at all and
# no test could notice - the exact shape that hid this.
printf 'zsh\t5.9-11.fc44\npkg\t1.10\npkg\t1.9\n' > "$TESTTMP/unsorted.tsv"
lookup="$(KEMPT_DNF_INSTALLED_CMD="cat $TESTTMP/unsorted.tsv" dnf_installed_lookup)"
assert_eq "$(awk -F'\t' '$1=="pkg"{print $2}' <<<"$lookup")" "1.9,1.10" \
  "1.9 and 1.10 collapse in version order, so the last element is the newest"
assert_eq "$(cut -f1 <<<"$lookup" | paste -sd, -)" "pkg,zsh" \
  "names stay in byte order, which is what join and tsv_diff_updates require"

# Nothing pending is a normal state, not an error: the parser must yield [] and exit 0.
prc=0
empty_out="$(dnf_parse_check_update "$FIXTURES/rpm-installed.tsv" </dev/null)" || prc=$?
assert_eq "$prc" "0" "parser on empty stdin exits 0"
assert_json_eq "$empty_out" "[]" "parser on empty stdin → []"

# A failure mid-pipeline (unreadable lookup) must not surface as a successful empty parse.
# pipefail must come from lib/common.sh itself, not from tests/lib.sh: bin/kempt sources only
# the former, and without it a mid-pipe failure returns rc 0 + [] = a silent "nothing pending".
rc=0
bash -c 'set +o pipefail
  source "'"$REPO_ROOT"'/lib/common.sh"; source "'"$REPO_ROOT"'/backends/dnf.sh"
  dnf_parse_check_update /nonexistent/lookup.tsv </dev/null >/dev/null 2>&1' || rc=$?
assert_eq "$rc" "1" "lib/common.sh itself sets pipefail (production path)"

# Impure check with stubbed helper: exit 100 + fixture on stdout
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == "check" ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_DNF_INSTALLED_CMD="cat $FIXTURES/rpm-installed.tsv"
got="$(dnf_check)"
assert_eq "$(jq 'length' <<<"$got")" "7" "dnf_check wires helper→parser"

# Fully up-to-date box: check-update prints nothing and exits 0 (not 100). Normal state, not a
# failure — Task 8 must not read the most common state on a maintained box as "stale".
cat > "$TESTTMP/refresh-stub" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "check" ]] || exit 2
exit 0
STUB
crc=0
none="$(dnf_check)" || crc=$?
assert_eq "$crc" "0" "zero pending dnf is success"
assert_json_eq "$none" "[]" "zero pending dnf → empty items"

# A parser failure must survive the cleanup rm instead of being masked by its exit 0.
_real_parse="$(declare -f dnf_parse_check_update)"
dnf_parse_check_update() { return 3; }
assert_exit 3 "parser failure propagates past cleanup rm" dnf_check
eval "$_real_parse"

# A broken installed-lookup must FAIL, not silently report every package as from="?" — an
# all-"?" report looks plausible and would ship a fabricated update list to the user.
_saved_installed="$KEMPT_DNF_INSTALLED_CMD"
export KEMPT_DNF_INSTALLED_CMD=false
assert_exit 1 "failing installed-lookup is loud" dnf_check
export KEMPT_DNF_INSTALLED_CMD="$_saved_installed"

# --- reboot check: offline, non-interactive, rc-mapped (seam: KEMPT_DNF_CMD) ---
# rc 1 alone is not evidence. `dnf5 -C needs-restarting` exits 1 both when a restart really is
# owed and when it could not work the answer out at all, and the second shape is the everyday one
# on a fresh install (cold user cache - see the silent stub below). So the stub that stands in for
# a real "yes" prints what the real command prints, because that output is now half the verdict.
cat > "$TESTTMP/dnf-stub-1" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
Core libraries or services have been updated since boot-up:
  * kernel
  * kernel-core

Reboot is required to fully utilize these updates.
OUT
exit 1
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-stub-0"
printf '#!/usr/bin/env bash\nexit 2\n' > "$TESTTMP/dnf-stub-2"
# The cold-cache shape, byte-faithful: the complaint goes to stderr, stdout stays empty, rc is 1.
cat > "$TESTTMP/dnf-stub-1-silent" <<'STUB'
#!/usr/bin/env bash
echo 'Cache-only enabled but no cache for repository "fedora"' >&2
exit 1
STUB
chmod +x "$TESTTMP/dnf-stub-0" "$TESTTMP/dnf-stub-1" "$TESTTMP/dnf-stub-2" "$TESTTMP/dnf-stub-1-silent"
export KEMPT_DNF_CMD="$TESTTMP/dnf-stub-0"
assert_eq "$(dnf_reboot_needed 2>/dev/null)" "false" "reboot check rc 0 → false"
export KEMPT_DNF_CMD="$TESTTMP/dnf-stub-1"
assert_eq "$(dnf_reboot_needed 2>/dev/null)" "true" "reboot check rc 1 WITH the package list → true"
export KEMPT_DNF_CMD="$TESTTMP/dnf-stub-2"
assert_eq "$(dnf_reboot_needed 2>/dev/null)" "false" "reboot check unexpected rc → false, never a hang"
_err="$(dnf_reboot_needed 2>&1 >/dev/null)"
assert_eq "$(grep -q 'warning: reboot check failed' <<<"$_err" && echo yes || echo no)" "yes" "unexpected rc warns on stderr"

# The regression this whole shape exists for. Before `--disablerepo='*'`, a box whose user cache
# had never been filled (the default: kempt-refresh fills root's, not the user's) got exactly this
# from dnf5 on every single check, and the old rc mapping read it as "a restart is owed" - forever.
export KEMPT_DNF_CMD="$TESTTMP/dnf-stub-1-silent"
assert_eq "$(dnf_reboot_needed 2>/dev/null)" "false" "rc 1 with NOTHING on stdout → false: it could not answer"
_err="$(dnf_reboot_needed 2>&1 >/dev/null)"
assert_eq "$(grep -q 'warning: reboot check could not answer' <<<"$_err" && echo yes || echo no)" "yes" \
  "...and says so, rather than answering false silently"

# The two flags are the verdict's foundation, and a seam that quietly stopped passing them would
# leave every assertion above passing while the real command went back to needing a warm cache
# (or, without -C, to doing network I/O on the widget's hourly path). So assert the argv itself.
cat > "$TESTTMP/dnf-argv" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TESTTMP/dnf-argv-out"
exit 0
STUB
chmod +x "$TESTTMP/dnf-argv"
export KEMPT_DNF_CMD="$TESTTMP/dnf-argv"
dnf_reboot_needed >/dev/null 2>&1
assert_eq "$(grep -cx -- '-C' "$TESTTMP/dnf-argv-out")" "1" "the reboot check really is cache-only"
assert_eq "$(grep -cx -- "--disablerepo=\*" "$TESTTMP/dnf-argv-out")" "1" "...and really does disable every repo"
assert_eq "$(grep -cx -- 'needs-restarting' "$TESTTMP/dnf-argv-out")" "1" "...on the needs-restarting verb"

# Helper failure (exit 1, not 100) → dnf_check exits non-zero
cat > "$TESTTMP/refresh-stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
assert_exit 1 "dnf_check propagates failure" dnf_check
finish
