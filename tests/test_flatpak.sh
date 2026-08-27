#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
# sandbox() POISONS KEMPT_FLATPAK_REFRESH_CMD (a nonexistent path) so that no test file can reach
# flathub by accident. This file is the one that has to see the real shipped default, so it drops
# the poison for the block below and puts it straight back - anything after that block which calls
# the refresh has to name its own stub, exactly as every other seam here does.
_poisoned_fp_refresh="$KEMPT_FLATPAK_REFRESH_CMD"
unset KEMPT_FLATPAK_REFRESH_CMD
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/backends/flatpak.sh"

# --- the network boundary ------------------------------------------------------------------------
# The check is cache-only. Without --cached every single check fetches flathub's summary index, so
# a box behind a captive portal, on battery or on a metered link got rc 1 in 48ms ("Unable to load
# summary from remote flathub") and the WHOLE flatpak backend went stale. With --cached the same
# query answers from the local summary in 1.6s with the network blackholed. Measured on this box,
# 2026-08-27, flatpak 1.18.1.
assert_eq "$([[ "$KEMPT_FLATPAK_REMOTE_CMD" == *--cached* ]] && echo cache-only || echo network)" \
  "cache-only" "the default flatpak check never leaves the box"
# The refresh arm is the one command on this side that may. It is not optional: --cached does NOT
# fall back to the network, so a cache nothing ever filled stays a hard rc-1 failure forever.
assert_eq "$([[ "$KEMPT_FLATPAK_REFRESH_CMD" == *--cached* ]] && echo cache-only || echo network)" \
  "network" "the flatpak refresh seam is the arm that fetches"
# One query in two modes, derived by string so a later edit to either cannot silently desynchronise
# them: the refresh has to fetch EXACTLY what the check then reads back, --system included (the
# cross-boundary contract with libexec/kempt-apply).
assert_eq "${KEMPT_FLATPAK_REMOTE_CMD/ --cached/}" "$KEMPT_FLATPAK_REFRESH_CMD" \
  "the refresh is the check command minus --cached"
export KEMPT_FLATPAK_REFRESH_CMD="$_poisoned_fp_refresh"

# Fixture contract (MANIFEST.md): 3 pending apps; com.example.NotInstalled is absent from flatpak-list.tsv.
out="$(flatpak_parse_remote_ls "$FIXTURES/flatpak-list.tsv" < "$FIXTURES/flatpak-remote-ls.txt")"
assert_eq "$(jq 'length' <<<"$out")" "3" "three pending flatpaks"
assert_eq "$(jq -r '.[0] | has("name") and has("from") and has("to")' <<<"$out")" "true" "item shape"
assert_eq "$(jq -r '.[] | select(.name == "com.example.NotInstalled") | .from' <<<"$out")" "?" "not-installed app falls back to ?"

# Nothing pending is the COMMON case, not an error: the parser must yield [] and exit 0.
prc=0
empty_out="$(flatpak_parse_remote_ls "$FIXTURES/flatpak-list.tsv" </dev/null)" || prc=$?
assert_eq "$prc" "0" "parser on empty stdin exits 0"
assert_json_eq "$empty_out" "[]" "parser on empty stdin → []"

export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export KEMPT_FLATPAK_LIST_CMD="cat $FIXTURES/flatpak-list.tsv"
got="$(flatpak_check)"
assert_eq "$(jq 'length' <<<"$got")" "3" "flatpak_check wires cmds→parser"

# Same ascending-set contract as the dnf side: consumers read the LAST element of a comma set as
# the newest version, and a plain sort puts 1.10 before 1.9.
printf 'org.x.App\t1.10\norg.x.App\t1.9\ncom.a.B\t2.0\n' > "$TESTTMP/fp-unsorted.tsv"
snap="$(KEMPT_FLATPAK_LIST_CMD="cat $TESTTMP/fp-unsorted.tsv" flatpak_snapshot)"
assert_eq "$(awk -F'\t' '$1=="org.x.App"{print $2}' <<<"$snap")" "1.9,1.10" \
  "a flatpak version set collapses in version order too"
assert_eq "$(cut -f1 <<<"$snap" | paste -sd, -)" "com.a.B,org.x.App" \
  "app ids stay in byte order for join"

# Fully up-to-date box: remote-ls prints nothing, exits 0. Must NOT look like a failed check
# (Task 8 would misread a non-zero rc as "stale" on the most common state there is).
export KEMPT_FLATPAK_REMOTE_CMD="true"
crc=0
none="$(flatpak_check)" || crc=$?
assert_eq "$crc" "0" "zero pending flatpak is success, not stale"
assert_json_eq "$none" "[]" "zero pending flatpak → empty items"

# A parser failure must survive the cleanup rm instead of being masked by its exit 0.
_real_parse="$(declare -f flatpak_parse_remote_ls)"
flatpak_parse_remote_ls() { return 3; }
assert_exit 3 "parser failure propagates past cleanup rm" flatpak_check
eval "$_real_parse"

# A broken installed-lookup must FAIL, not report every app as from="?".
export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export KEMPT_FLATPAK_LIST_CMD="false"
assert_exit 1 "failing installed-lookup is loud" flatpak_check
export KEMPT_FLATPAK_LIST_CMD="cat $FIXTURES/flatpak-list.tsv"

export KEMPT_FLATPAK_REMOTE_CMD="false"
assert_exit 1 "flatpak_check propagates failure" flatpak_check

# --- the refresh arm -----------------------------------------------------------------------------
# It swallows both streams. The fetch is the whole point (it rewrites the local summary); the
# pending list it happens to print is the CHECK's job to produce, and a refresh that leaked it
# would land in whatever the caller was capturing at the time.
cat > "$TESTTMP/fp-refresh-noisy" <<STUB
#!/usr/bin/env bash
echo "com.example.App	2.0"
echo "fetching flathub summary" >&2
touch "$TESTTMP/fp-refresh-ran"
STUB
chmod +x "$TESTTMP/fp-refresh-noisy"
export KEMPT_FLATPAK_REFRESH_CMD="$TESTTMP/fp-refresh-noisy"
assert_eq "$(flatpak_refresh 2>&1)" "" "flatpak_refresh keeps both of the seam's streams to itself"
# Guards the vacuous pass: a refresh that never ran also prints nothing.
assert_exit 0 "...having actually run the seam" -- test -f "$TESTTMP/fp-refresh-ran"
# A fetch that failed has to stay distinguishable, or maybe_refresh_metadata cannot tell its two
# event lines apart and a box whose summary is a month old reports a healthy refresh every time.
export KEMPT_FLATPAK_REFRESH_CMD="false"
assert_exit 1 "flatpak_refresh propagates failure" flatpak_refresh
finish
