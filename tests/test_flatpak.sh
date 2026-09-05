#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
# sandbox() POISONS KEMPT_FLATPAK_REFRESH_CMD and KEMPT_FLATPAK_UPDATE_CMD with paths that do not
# exist, so that no test file can reach flathub or update the machine running the suite by accident.
# This file is the one that has to see the real SHIPPED defaults, and it reads them in a subshell
# that never exports them rather than dropping the poison in the live shell.
#
# That distinction is the whole point. An earlier version of this file unset both seams, ran three
# dozen lines of assertions, and put the poison back at the end. For the REFRESH seam that window
# was survivable: the worst an unstubbed refresh does is fetch a summary. For the APPLY seam it is
# not - one `flatpak_apply` call landing inside that window updates the developer's own machine,
# which is exactly the thing sandbox() exists to make impossible. So the window is gone: the live
# shell below is poisoned from the first line to the last.
#
# `trap - EXIT` is not decoration. sandbox() installs an EXIT trap that removes $TESTTMP, and a
# subshell that ran it would delete this file's sandbox out from under the assertions.
_fp_defaults="$(
  trap - EXIT
  unset KEMPT_FLATPAK_REFRESH_CMD KEMPT_FLATPAK_UPDATE_CMD
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/backends/flatpak.sh"
  printf '%s\n%s\n%s\n%s\n' "$KEMPT_FLATPAK_REMOTE_CMD" "$KEMPT_FLATPAK_REFRESH_CMD" \
                              "$KEMPT_FLATPAK_LIST_CMD"   "$KEMPT_FLATPAK_UPDATE_CMD"
)"
readarray -t FP_DEFAULT <<<"$_fp_defaults"
# Guards the vacuous pass: four empty strings would satisfy several assertions below while proving
# the subshell never ran at all.
assert_eq "${#FP_DEFAULT[@]}" "4" "the four shipped flatpak defaults were read"
FP_REMOTE_DEFAULT="${FP_DEFAULT[0]}"; FP_REFRESH_DEFAULT="${FP_DEFAULT[1]}"
FP_LIST_DEFAULT="${FP_DEFAULT[2]}";   FP_UPDATE_DEFAULT="${FP_DEFAULT[3]}"
# The functions are what the live shell needs, and they are identical whatever the seams hold.
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/backends/flatpak.sh"

# --- the network boundary ------------------------------------------------------------------------
# The check is cache-only. Without --cached every single check fetches flathub's summary index, so
# a box behind a captive portal, on battery or on a metered link got rc 1 in 48ms ("Unable to load
# summary from remote flathub") and the WHOLE flatpak backend went stale. With --cached the same
# query answers from the local summary in 1.6s with the network blackholed. Measured on this box,
# 2026-08-27, flatpak 1.18.1.
assert_eq "$([[ "$FP_REMOTE_DEFAULT" == *--cached* ]] && echo cache-only || echo network)" \
  "cache-only" "the default flatpak check never leaves the box"
# The refresh arm is the one command on this side that may. It is not optional: --cached does NOT
# fall back to the network, so a cache nothing ever filled stays a hard rc-1 failure forever.
assert_eq "$([[ "$FP_REFRESH_DEFAULT" == *--cached* ]] && echo cache-only || echo network)" \
  "network" "the flatpak refresh seam is the arm that fetches"
# One query in two modes, derived by string so a later edit to either cannot silently desynchronise
# them: the refresh has to fetch EXACTLY what the check then reads back, --system included (the
# scope contract asserted just below).
assert_eq "${FP_REMOTE_DEFAULT/ --cached/}" "$FP_REFRESH_DEFAULT" \
  "the refresh is the check command minus --cached"

# --- the scope contract ---------------------------------------------------------------------------
# v1 is system scope only, and all four flatpak commands are built in this one file now (the apply
# used to be built inside the root helper, which is why this contract used to be asserted by
# grepping libexec/kempt-apply). One disagreeing scope means an app the badge counts is an app the
# run does not touch, or the reverse.
# The pattern is anchored on BOTH sides: a bare `*" --system"*` substring test is satisfied by
# `--systemwide`, which is a different installation entirely.
for _v in FP_REMOTE_DEFAULT FP_REFRESH_DEFAULT FP_LIST_DEFAULT FP_UPDATE_DEFAULT; do
  assert_eq "$([[ " ${!_v} " == *" --system "* ]] && echo system || echo "unscoped: ${!_v}")" "system" \
    "$_v is --system scoped"
done
# The apply arm is unprivileged - it is `flatpak update`, nothing more. A pkexec or a helper path
# creeping back into this default is the regression this change exists to prevent.
assert_eq "$FP_UPDATE_DEFAULT" "flatpak update --system" "the apply arm is plain flatpak, run as the user"

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

# --- the apply arm ---------------------------------------------------------------------------------
# It runs as the user: no pkexec, no root helper, no Kempt polkit action. What is asserted here is
# the command line it builds, which is the command line the old root helper built - the two
# assertions that pinned it in tests/test_helpers.sh moved here with the code.
cat > "$TESTTMP/fp-update-rec" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TESTTMP/fp-update-calls"
[[ "\$*" == *FAILME* ]] && exit 1
exit 0
STUB
chmod +x "$TESTTMP/fp-update-rec"
export KEMPT_FLATPAK_UPDATE_CMD="$TESTTMP/fp-update-rec"
fp_calls() { cat "$TESTTMP/fp-update-calls" 2>/dev/null || true; }
# The recorder sees only the arguments, so the shipped default is prepended back on: together
# these two halves are the exact string the helper test used to assert in one piece.
fp_line() { local a; a="$(sed -n "${1}p" "$TESTTMP/fp-update-calls")"; printf '%s%s\n' "$FP_UPDATE_DEFAULT" "${a:+ $a}"; }

: > "$TESTTMP/fp-update-calls"
assert_exit 0 "flatpak_apply with no ids updates everything" flatpak_apply -y
assert_eq "$(fp_line 1)" "flatpak update --system --noninteractive -y" "all-apps command"
# auto_accept=false must reach flatpak: --noninteractive is part of the -y mapping, never hardcoded,
# or a user who turned auto-accept off would still get a silent unattended flatpak upgrade.
: > "$TESTTMP/fp-update-calls"
flatpak_apply
assert_eq "$(fp_line 1)" "flatpak update --system" "no -y omits the auto-accept flags"

# Holds are what the per-app form exists for: the held app is simply not in the list.
: > "$TESTTMP/fp-update-calls"
assert_exit 0 "flatpak_apply with ids runs one update per app" flatpak_apply -y org.gimp.GIMP net.mkiol.SpeechNote
assert_eq "$(fp_calls | wc -l)" "2" "...one command per id, not one command with two ids"
assert_eq "$(fp_line 1)" "flatpak update --system --noninteractive -y org.gimp.GIMP" "first app's command"
assert_eq "$(fp_line 2)" "flatpak update --system --noninteractive -y net.mkiol.SpeechNote" "second app's command"

# One app failing fails the whole call - a run that silently reported success while an app stayed
# on its old version is the failure mode this guards - and the loop still finishes, because the
# other apps have no reason to be skipped.
: > "$TESTTMP/fp-update-calls"
assert_exit 1 "one failing app fails the call" flatpak_apply -y org.a.Ok net.FAILME.App org.b.Ok
assert_eq "$(fp_calls | wc -l)" "3" "...without abandoning the apps after it"

# App ids arrive from a REMOTE's summary. KEMPT_NAME_RE is anchored on its first character, which
# is what keeps a name that looks like an option from arriving at flatpak AS an option. (The bare
# name `NAME_RE` belongs to a different constant, the root helper's own copy in libexec/kempt-apply,
# which no longer sees a flatpak argument at all.)
: > "$TESTTMP/fp-update-calls"
assert_exit 2 "an option-shaped app id is rejected" flatpak_apply -y --installation=other
assert_exit 2 "an injection-shaped app id is rejected" flatpak_apply -y 'evil;id'
assert_eq "$(fp_calls | wc -c)" "0" "a rejected call updates nothing at all"

# --- download sizes ------------------------------------------------------------------------------
# flatpak reports a HUMAN string, not bytes: "1.2 GB", rounded to one decimal by g_format_size, and
# remote-info returns the same rounded string - so exact bytes are unavailable from the CLI at all.
# The separator is U+00A0 NO-BREAK SPACE for kB/MB/GB and a PLAIN space for `bytes`. The fixture
# carries the real byte sequences (MANIFEST.md records the cat -A output), because a fixture
# written with an ordinary space would pass a parser that cannot read a single real flathub row.
fp_sizes="$(flatpak_parse_sizes < "$FIXTURES/flatpak-remote-ls-sizes.tsv")"
assert_eq "$(awk -F'\t' '$1=="net.mkiol.SpeechNote"{print $2}' <<<"$fp_sizes")" "1200000000" \
  "a GB row separated by a NO-BREAK SPACE parses"
assert_eq "$(awk -F'\t' '$1=="org.gimp.GIMP"{print $2}' <<<"$fp_sizes")" "99700000" \
  "...and an MB one"
# `bytes` is the unit that uses an ordinary space, so it proves the normalisation handles both
# rather than having simply swapped one separator for the other.
assert_eq "$(awk -F'\t' '$1=="com.example.NotInstalled"{print $2}' <<<"$fp_sizes")" "847" \
  "a plain-space bytes row parses too"
# The fixture really does contain the NBSP. Without this, a fixture silently rewritten with an
# ordinary space would keep all three assertions above green while the parser rotted.
assert_eq "$(grep -c $'\xc2\xa0' "$FIXTURES/flatpak-remote-ls-sizes.tsv")" "2" \
  "the fixture carries real U+00A0 bytes, not spaces"
# Not knowing is not zero. Both of these must yield NO ROW, so the coverage rule suppresses the
# figure rather than reporting a free download.
assert_eq "$(awk -F'\t' '$1=="org.example.NoSize"' <<<"$fp_sizes" | wc -l)" "0" "an empty size column yields no row"
assert_eq "$(awk -F'\t' '$1=="org.example.Unknown"' <<<"$fp_sizes" | wc -l)" "0" "a literal ? yields no row"
assert_eq "$(grep -c . <<<"$fp_sizes")" "3" "three of the five rows priced"
# SI decimal with a lowercase k, matching g_format_size. kB is 1000, never 1024.
assert_eq "$(printf 'a.b.C\t1.0\t780.5\xc2\xa0kB\n' | flatpak_parse_sizes | cut -f2)" "780500" \
  "kB is SI, not 1024"
assert_eq "$(printf 'a.b.C\t1.0\t2.5\xc2\xa0TB\n' | flatpak_parse_sizes | cut -f2)" "2500000000000" "TB parses"
assert_eq "$(printf 'a.b.C\t1.0\t9\xc2\xa0PB\n' | flatpak_parse_sizes | wc -l)" "0" \
  "a unit nobody has seen is not guessed at"
assert_eq "$(printf 'a.b.C\t1.0\n' | flatpak_parse_sizes | wc -l)" "0" "a two-column row has no size to read"
assert_eq "$(printf '' | flatpak_parse_sizes | wc -l)" "0" "no rows in, no rows out"

# The item parser must survive the wider row: the size column rides along in the same output and
# must not reach the join, which selects fields by position.
three_col="$(flatpak_parse_remote_ls "$FIXTURES/flatpak-list.tsv" < "$FIXTURES/flatpak-remote-ls-sizes.tsv")"
assert_eq "$(jq -r '.[] | select(.name=="org.gimp.GIMP") | .to' <<<"$three_col")" "3.0.4" \
  "the item parser reads version from a three-column row"
assert_eq "$(jq -r '.[] | select(.name=="org.gimp.GIMP") | .from' <<<"$three_col")" "3.0.2" \
  "...and still joins the installed version onto it"
assert_eq "$(jq -r '[.[] | .to] | map(select(test("GB|MB|bytes"))) | length' <<<"$three_col")" "0" \
  "no size string leaks into a version field"

# flatpak_check writes the sizes out of the rows it ALREADY fetched. A second remote-ls to re-read
# bytes that arrived with the first copy would double the flatpak cost of every check (about 1.6s
# on this box) for nothing.
export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls-sizes.tsv"
export KEMPT_FLATPAK_LIST_CMD="cat $FIXTURES/flatpak-list.tsv"
sz_out="$TESTTMP/fp-sizes.tsv"
assert_exit 0 "flatpak_check accepts a sizes path" flatpak_check "$sz_out"
assert_eq "$(grep -c . "$sz_out")" "3" "...and fills it from the rows it already had"
# The path is optional, and omitting it must not change the function's verdict.
assert_exit 0 "flatpak_check without a sizes path still succeeds" flatpak_check
finish
