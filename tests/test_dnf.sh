#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/backends/dnf.sh"

# Pure parser: fixture lines + installed lookup → items JSON
# Fixture contract (tests/fixtures/MANIFEST.md): 8 data lines parse to exactly 7 items —
# the bash.i686/bash.x86_64 multilib pair collapses; brandnew is absent from rpm-installed.tsv.
out="$(dnf_parse_check_update "$FIXTURES/rpm-installed.tsv" < "$FIXTURES/dnf-check-update.txt")"
assert_eq "$(jq 'length' <<<"$out")" "7" "8 fixture lines → 7 items (multilib pair collapses)"
assert_eq "$(jq -r '.[0] | has("name") and has("from") and has("to")' <<<"$out")" "true" "item shape"
assert_eq "$(jq -r '[.[].name] | any(test("\\.(x86_64|noarch|i686)$"))' <<<"$out")" "false" "arch suffix stripped"
assert_eq "$(jq -r '[.[].name] | map(select(. == "bash")) | length' <<<"$out")" "1" "bash appears once despite two arches"
assert_eq "$(jq -r '.[] | select(.name == "brandnew") | .from' <<<"$out")" "?" "not-installed package falls back to ?"
assert_eq "$(jq -r '[.[] | select(.name != "brandnew") | .from] | any(. == "?" or . == "")' <<<"$out")" "false" "installed packages resolve real from-versions"

# Nothing pending is a normal state, not an error: the parser must yield [] and exit 0.
prc=0
empty_out="$(dnf_parse_check_update "$FIXTURES/rpm-installed.tsv" </dev/null)" || prc=$?
assert_eq "$prc" "0" "parser on empty stdin exits 0"
assert_json_eq "$empty_out" "[]" "parser on empty stdin → []"

# Impure check with stubbed helper: exit 100 + fixture on stdout
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == "check" ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub"
export UPKEEP_REFRESH_HELPER="$TESTTMP/refresh-stub"
export UPKEEP_DNF_INSTALLED_CMD="cat $FIXTURES/rpm-installed.tsv"
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

# Helper failure (exit 1, not 100) → dnf_check exits non-zero
cat > "$TESTTMP/refresh-stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
assert_exit 1 "dnf_check propagates failure" dnf_check
finish
