#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/backends/dnf.sh"

# Pure parser: fixture lines + installed lookup → items JSON
# Fixture contract (tests/fixtures/MANIFEST.md): parses to exactly 7 items - the
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
# failure - Task 8 must not read the most common state on a maintained box as "stale".
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

# A broken installed-lookup must FAIL, not silently report every package as from="?" - an
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
write_reboot_stub "$TESTTMP/dnf-stub-1"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-stub-0"
printf '#!/usr/bin/env bash\nexit 2\n' > "$TESTTMP/dnf-stub-2"
# The cold-cache shape, byte-faithful: the complaint goes to stderr, stdout stays empty, rc is 1.
cat > "$TESTTMP/dnf-stub-1-silent" <<'STUB'
#!/usr/bin/env bash
echo 'Cache-only enabled but no cache for repository "fedora"' >&2
exit 1
STUB
chmod +x "$TESTTMP/dnf-stub-0" "$TESTTMP/dnf-stub-2" "$TESTTMP/dnf-stub-1-silent"
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

# Blank stdout is not a package list either. Nobody has seen the real dnf5 emit this - it is here
# because the rc-1 branch promises POSITIVE evidence, and "non-empty" is a weaker test than that
# promise: $( ) strips trailing newlines but not the spaces before them, so three spaces used to
# read as a full reboot verdict. Hardening the promise, not chasing an observed bug.
cat > "$TESTTMP/dnf-stub-1-blank" <<'STUB'
#!/usr/bin/env bash
printf '   \n\n'
exit 1
STUB
chmod +x "$TESTTMP/dnf-stub-1-blank"
export KEMPT_DNF_CMD="$TESTTMP/dnf-stub-1-blank"
assert_eq "$(dnf_reboot_needed 2>/dev/null)" "false" "rc 1 with only whitespace on stdout → false: still no evidence"
_err="$(dnf_reboot_needed 2>&1 >/dev/null)"
assert_eq "$(grep -q 'warning: reboot check could not answer' <<<"$_err" && echo yes || echo no)" "yes" \
  "...and warns, exactly as the empty-stdout case does"

# rc 1 with NOISE on stdout, which is the case the "non-empty stdout" test never could tell apart
# from a real verdict. dnf5 5.4.3 on this box keeps its repo chatter on STDERR (measured
# 2026-08-27: "Updating and loading repositories:" / "Repositories loaded." both go to fd 2), so
# today's stdout is clean - but the rc-1 branch's promise is POSITIVE EVIDENCE, and any sentence
# at all satisfied "non-empty". One dnf5 release that moves a line to stdout, one plugin that
# prints a deprecation notice, and every check on the box answers "a restart is owed" forever.
# The evidence is therefore the thing itself: a package-list line, or dnf5's own verdict sentence.
cat > "$TESTTMP/dnf-stub-1-noise" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
Cache-only enabled but no cache for repository "fedora"
OUT
exit 1
STUB
chmod +x "$TESTTMP/dnf-stub-1-noise"
export KEMPT_DNF_CMD="$TESTTMP/dnf-stub-1-noise"
assert_eq "$(dnf_reboot_needed 2>/dev/null)" "false" \
  "rc 1 with prose on stdout but no package list → false: prose is not evidence"
_err="$(dnf_reboot_needed 2>&1 >/dev/null)"
assert_eq "$(grep -q 'warning: reboot check could not answer' <<<"$_err" && echo yes || echo no)" "yes" \
  "...and warns, exactly as the empty-stdout case does"

# ...and the other half of that rule: dnf5's own verdict sentence counts on its own. The real
# command prints it under the list (verified against dnf5 5.4.3 on this box), so a future release
# that drops the indented list and keeps the sentence must still answer "yes" rather than turning
# every restart-owed box silent.
cat > "$TESTTMP/dnf-stub-1-marker" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
Reboot is required to fully utilize these updates.
More information: https://access.redhat.com/solutions/27943
OUT
exit 1
STUB
chmod +x "$TESTTMP/dnf-stub-1-marker"
export KEMPT_DNF_CMD="$TESTTMP/dnf-stub-1-marker"
assert_eq "$(dnf_reboot_needed 2>/dev/null)" "true" \
  "rc 1 with dnf5's own verdict sentence and no list → true"

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

# --- download sizes ------------------------------------------------------------------------------
# Fixture provenance is in MANIFEST.md: real `downloadsize` values this box reports today, in the
# captured repoquery format, for the names already in dnf-check-update.txt - plus the live glibc
# multilib pair, and deliberately NO row for `brandnew`.
export KEMPT_DNF_SIZES_CMD="cat $FIXTURES/dnf-repoquery-sizes.tsv"
sizes="$(dnf_sizes)"

# THE reason sizes are summed per name before anything joins. `--latest-limit 1` is per name.arch,
# and multilib twins are BOTH downloaded, so glibc costs the x86_64 build plus the i686 one. The
# item pipeline strips the arch and collapses the pair, so a size joined onto the collapsed item
# would silently drop 2282613 bytes - a 48% under-count on this package.
assert_eq "$(awk -F'\t' '$1=="glibc"{print $2}' <<<"$sizes")" "4765890" \
  "a multilib pair sums to the bytes BOTH arches would download"
assert_eq "$(awk -F'\t' '$1=="bash"{print $2}' <<<"$sizes")" "4005217" \
  "...and so does the pending multilib twin the check fixture carries"
assert_eq "$(awk -F'\t' '$1=="curl"{print $2}' <<<"$sizes")" "245706" "a single-arch package is itself"
# One row per NAME, never per name.arch: attach_sizes joins on name and would otherwise see two.
assert_eq "$(cut -f1 <<<"$sizes" | sort -u | wc -l)" "$(grep -c . <<<"$sizes")" "one row per name"
assert_eq "$(cut -f1 <<<"$sizes" | LC_ALL=C sort -c && echo sorted)" "sorted" "rows come out sorted by name"
# `brandnew` is pending and unpriced on purpose, so the coverage guard downstream has something to
# fire on. A size table that invented a row for it would hide that.
assert_eq "$(awk -F'\t' '$1=="brandnew"' <<<"$sizes" | wc -l)" "0" "an unpriced package gets no row"

# Installed packages report downloadsize 0 - the rpmdb does not keep the figure - so any row that
# resolved to @System is worthless. Counting it would report a package as free to download.
assert_eq "$(KEMPT_DNF_SIZES_CMD="printf 'zero\tx86_64\t1.0-1\t0\n'" dnf_sizes | wc -l)" "0" \
  "a zero-byte row is dropped, not counted as free"
# Anything non-numeric in the size column is a format that changed under us, not a size.
assert_eq "$(KEMPT_DNF_SIZES_CMD="printf 'junk\tx86_64\t1.0-1\t%%{download_size}\n'" dnf_sizes | wc -l)" "0" \
  "a literal tag name (the wrong %{download_size} spelling) is not a size"
# The whole point of the non-fatal contract: a failed size query is silence, never an error.
assert_eq "$(KEMPT_DNF_SIZES_CMD=false dnf_sizes | wc -c)" "0" "a failed size command yields no rows"
assert_exit 0 "...and exits clean, because a check must answer without it" -- \
  env KEMPT_DNF_SIZES_CMD=false bash -c 'source "'"$REPO_ROOT"'/lib/common.sh"; source "'"$REPO_ROOT"'/backends/dnf.sh"; dnf_sizes'
assert_eq "$(KEMPT_DNF_SIZES_CMD=true dnf_sizes | wc -c)" "0" "nothing pending yields no rows"

# The shipped default must stay cache-only and must keep --latest-limit 1. Without the limit,
# `--upgrades` returns one row PER newer candidate version (27 for nodejs on a box a few releases
# behind), and a naive sum counts the same package several times over.
unset KEMPT_DNF_SIZES_CMD
default_sizes_cmd="$(declare -f dnf_sizes)"
assert_eq "$([[ "$default_sizes_cmd" == *"--latest-limit 1"* ]] && echo yes || echo no)" "yes" \
  "the default size query keeps --latest-limit 1"
assert_eq "$([[ "$default_sizes_cmd" == *" -C repoquery"* ]] && echo yes || echo no)" "yes" \
  "the default size query is cache-only"
assert_eq "$([[ "$default_sizes_cmd" == *"downloadsize"* ]] && echo yes || echo no)" "yes" \
  "the default size query asks for the tag that exists"
assert_eq "$([[ "$default_sizes_cmd" == *"timeout "* ]] && echo yes || echo no)" "yes" \
  "the default size query cannot block a check forever"
finish
