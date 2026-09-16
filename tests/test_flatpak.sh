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
  # The two runtime seams are PINNED at `true` by sandbox() rather than left unset, so they have to
  # be unset here too or this subshell would read the pin instead of the shipped default.
  unset KEMPT_FLATPAK_REFRESH_CMD KEMPT_FLATPAK_UPDATE_CMD \
        KEMPT_FLATPAK_REMOTE_RUNTIME_CMD KEMPT_FLATPAK_LIST_RUNTIME_CMD
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/backends/flatpak.sh"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$KEMPT_FLATPAK_REMOTE_CMD" "$KEMPT_FLATPAK_REFRESH_CMD" \
                              "$KEMPT_FLATPAK_LIST_CMD"   "$KEMPT_FLATPAK_UPDATE_CMD" \
                              "$KEMPT_FLATPAK_REMOTE_RUNTIME_CMD" "$KEMPT_FLATPAK_LIST_RUNTIME_CMD"
)"
readarray -t FP_DEFAULT <<<"$_fp_defaults"
# Guards the vacuous pass: six empty strings would satisfy several assertions below while proving
# the subshell never ran at all.
assert_eq "${#FP_DEFAULT[@]}" "6" "the six shipped flatpak defaults were read"
FP_REMOTE_DEFAULT="${FP_DEFAULT[0]}"; FP_REFRESH_DEFAULT="${FP_DEFAULT[1]}"
FP_LIST_DEFAULT="${FP_DEFAULT[2]}";   FP_UPDATE_DEFAULT="${FP_DEFAULT[3]}"
FP_REMOTE_RT_DEFAULT="${FP_DEFAULT[4]}"; FP_LIST_RT_DEFAULT="${FP_DEFAULT[5]}"
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
for _v in FP_REMOTE_DEFAULT FP_REFRESH_DEFAULT FP_LIST_DEFAULT FP_UPDATE_DEFAULT \
          FP_REMOTE_RT_DEFAULT FP_LIST_RT_DEFAULT; do
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

# --- runtimes ---------------------------------------------------------------------------------
# `flatpak update` with no ref updates applications AND runtimes (flatpak-update(1): "If no REF is
# given, everything is updated"; --app and --runtime are filters ON that default). A check that
# asked only about apps therefore counted less than the run would change.
assert_eq "$([[ "$FP_REMOTE_RT_DEFAULT" == *--cached* ]] && echo cache-only || echo network)" \
  "cache-only" "the runtime check never leaves the box either"
# The kind flag is what makes these twins rather than duplicates, and it is a FLAG because flatpak
# has no kind column: "apps and runtimes, labelled" is not something one invocation can answer.
assert_eq "$([[ " $FP_REMOTE_RT_DEFAULT " == *" --runtime "* ]] && echo runtime || echo "unfiltered")" \
  "runtime" "the runtime check asks for runtimes"
assert_eq "$([[ " $FP_LIST_RT_DEFAULT " == *" --runtime "* ]] && echo runtime || echo "unfiltered")" \
  "runtime" "...and so does the runtime installed lookup"
# branch is in BOTH runtime queries or the two sides of the join disagree about what a row is.
for _v in FP_REMOTE_RT_DEFAULT FP_LIST_RT_DEFAULT; do
  assert_eq "$([[ "${!_v}" == *branch* ]] && echo branch || echo "no branch: ${!_v}")" "branch" \
    "$_v carries the branch column, because a runtime's identity is id AND branch"
done

# The key fold: one field is what sort, join and collapse_versions all key on, so id and branch
# become `id/branch` and split apart again in the state file.
rt_rows="$(flatpak_runtime_rows < "$FIXTURES/flatpak-remote-ls-runtime.tsv")"
assert_eq "$(awk -F'\t' 'NR==1{print $1}' <<<"$rt_rows")" "org.freedesktop.Platform.GL.default/24.08" \
  "a runtime row is keyed by id and branch together"
# An empty version column is the COMMON case for runtimes, not an edge: flatpak versions a runtime
# by its branch and gives org.kde.Platform no version string at all. `?` is the sentinel the rest
# of Kempt already means "not known" by; an empty string would draw an arrow pointing at nothing.
assert_eq "$(awk -F'\t' '$1=="org.kde.Platform/5.15-24.08"{print $2}' <<<"$rt_rows")" "?" \
  "a runtime with no version string reads as not known, not as empty"

# Fixture contract (MANIFEST.md): 4 pending runtimes, two of them the same id on two branches.
rt_lookup="$TESTTMP/rt-lookup.tsv"
flatpak_runtime_rows < "$FIXTURES/flatpak-list-runtime.tsv" | sort_name_version | collapse_versions > "$rt_lookup"
rt_out="$(flatpak_parse_remote_ls_runtime "$rt_lookup" <<<"$rt_rows")"
assert_eq "$(jq 'length' <<<"$rt_out")" "4" "four pending runtimes"
assert_eq "$(jq -r '.[0] | .kind' <<<"$rt_out")" "runtime" "every runtime item says it is one"
assert_eq "$(jq -r '[.[] | select(.branch == null)] | length' <<<"$rt_out")" "0" \
  "...and every one of them carries its branch"
# THE two-branch case, which is the whole reason identity is a pair. This runtime is installed on
# two branches on the box these fixtures were captured from; keyed by id alone the pair collapses
# into one row carrying both versions, which is wrong about both of them.
gl="$(jq -c '[.[] | select(.name == "org.freedesktop.Platform.GL.default")] | sort_by(.branch)' <<<"$rt_out")"
assert_eq "$(jq 'length' <<<"$gl")" "2" "one runtime on two branches is TWO rows, not one"
assert_eq "$(jq -r '[.[].branch] | join(",")' <<<"$gl")" "24.08,24.08extra" "...one per branch"
assert_eq "$(jq -r '[.[].to] | join(",")' <<<"$gl")" "26.1.9,26.2.0" \
  "...each moving to its own version, never comma-joined into one"
assert_eq "$(jq -r '[.[].to] | map(select(test(","))) | length' <<<"$gl")" "0" \
  "...so no row carries a collapsed set that would claim both versions at once"
assert_eq "$(jq -r '.[] | select(.name == "org.example.NotInstalledRuntime") | .from' <<<"$rt_out")" "?" \
  "a runtime that is not installed falls back to ?"

# Both arms in one answer, which is what the badge counts and the run acts on.
export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export KEMPT_FLATPAK_LIST_CMD="cat $FIXTURES/flatpak-list.tsv"
export KEMPT_FLATPAK_REMOTE_RUNTIME_CMD="cat $FIXTURES/flatpak-remote-ls-runtime.tsv"
export KEMPT_FLATPAK_LIST_RUNTIME_CMD="cat $FIXTURES/flatpak-list-runtime.tsv"
both="$(flatpak_check)"
assert_eq "$(jq 'length' <<<"$both")" "7" "flatpak_check counts apps AND runtimes (3 + 4)"
assert_eq "$(jq '[.[] | select(.kind == "runtime")] | length' <<<"$both")" "4" "...four of them runtimes"
assert_eq "$(jq '[.[] | select(.kind == null)] | length' <<<"$both")" "3" \
  "...and an app carries no kind at all, which is what makes the key additive"
# The app half must be untouched, byte for byte: this change may not move an app row.
apps_only="$(KEMPT_FLATPAK_REMOTE_RUNTIME_CMD=true KEMPT_FLATPAK_LIST_RUNTIME_CMD=true flatpak_check)"
assert_json_eq "$apps_only" "$(jq -c '[.[] | select(.kind == null)]' <<<"$both")" \
  "the app items are identical with and without the runtime arm"

# A failing runtime arm fails the whole backend, exactly as the app arm does. A check that answered
# for half the transaction would be the original bug wearing a different hat.
# One-line wrappers rather than an `env` prefix: assert_exit runs its argument with "$@", and env(1)
# execs a PROGRAM - handed a shell function it exits 127, which would have passed for a failure here
# while proving nothing at all about the backend.
rt_check_no_remote() { KEMPT_FLATPAK_REMOTE_RUNTIME_CMD=false flatpak_check; }
rt_check_no_list()   { KEMPT_FLATPAK_LIST_RUNTIME_CMD=false flatpak_check; }
assert_exit 1 "a failing runtime check fails the backend" rt_check_no_remote
assert_exit 1 "a failing runtime lookup fails the backend" rt_check_no_list

# Sizes: one file, two key shapes, and the branch is what keeps the two GL rows apart. Joined by
# name alone they would both take whichever of the two size rows landed in the table.
# The app remote fixture used above carries no size column at all, so the priced app half has to
# come from the fixture that does - otherwise "an app still joins by name" would be asserted over an
# app that has no size to join.
export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls-sizes.tsv"
rt_sz="$TESTTMP/fp-rt-sizes.tsv"
assert_exit 0 "flatpak_check prices both arms" flatpak_check "$rt_sz"
assert_eq "$(awk -F'\t' '$1=="org.freedesktop.Platform.GL.default/24.08"{print $2}' < "$rt_sz")" "149400000" \
  "a runtime's size row is keyed by id and branch"
assert_eq "$(awk -F'\t' '$1=="org.freedesktop.Platform.GL.default/24.08extra"{print $2}' < "$rt_sz")" "149500000" \
  "...so the other branch keeps its own, different size"
priced="$(attach_sizes "$rt_sz" <<<"$(mark_held flatpak <<<"$(flatpak_check)")")"
assert_eq "$(jq -r '.[] | select(.name=="org.freedesktop.Platform.GL.default" and .branch=="24.08") | .size_bytes' <<<"$priced")" \
  "149400000" "attach_sizes joins a runtime on name AND branch"
assert_eq "$(jq -r '.[] | select(.name=="org.freedesktop.Platform.GL.default" and .branch=="24.08extra") | .size_bytes' <<<"$priced")" \
  "149500000" "...giving the two branches their own figures rather than one twice"
assert_eq "$(jq -r '.[] | select(.name=="net.mkiol.SpeechNote") | .size_bytes' <<<"$priced")" "1200000000" \
  "...while an app with no branch still joins by name exactly as before"

# The snapshot, which is what the run's report diffs. One row per id/branch: collapsed onto the id,
# the two branches would merge into a single row and tsv_diff_updates would report a change to a
# runtime that never moved.
snap_rt="$(flatpak_snapshot)"
assert_eq "$(grep -c . <<<"$snap_rt")" "9" "the snapshot carries both apps and runtimes"
assert_eq "$(awk -F'\t' '$1 ~ /GL.default/' <<<"$snap_rt" | wc -l)" "2" \
  "a runtime on two branches is two snapshot rows"
# The contract tsv_diff_updates enforces with exit 65, checked here so a fold that stopped being
# unique fails in this file rather than as a mysterious diff failure mid-run.
assert_eq "$(cut -f1 <<<"$snap_rt" | sort | uniq -d | wc -l)" "0" \
  "...and no name repeats, which is what tsv_diff_updates refuses input for"
rt_snap_no_list() { KEMPT_FLATPAK_LIST_RUNTIME_CMD=false flatpak_snapshot; }
rt_snap_no_app()  { KEMPT_FLATPAK_LIST_CMD=false flatpak_snapshot; }
assert_exit 1 "a failing runtime lookup fails the snapshot too" rt_snap_no_list
# A group pipeline would have masked this one: a group's status is its LAST command's, so a broken
# app arm with a working runtime arm would have reported an empty installed set as success.
assert_exit 1 "...and so does a failing app lookup, which a group pipeline would have hidden" rt_snap_no_app

# Runtimes are never held, whatever the holds file says. mark_held keys on the bare name, and a
# holds file written before runtimes were counted can already name one.
held_rt="$(mark_held flatpak <<<'[{"name":"org.kde.Platform","branch":"5.15-24.08","kind":"runtime"},{"name":"org.kde.Platform"}]' | flatpak_runtimes_never_held)"
assert_eq "$(jq -r '.[0].held' <<<"$held_rt")" "false" "a runtime is never held"
assert_eq "$(jq -r '.[1].held' <<<"$held_rt")" "false" "...and an app of the same id is untouched by that rule"

# The apply arm's runtime form: every runtime in one command, which is how a run with app holds
# still updates them. Per-ref is not an option - holds are per app and runtimes cannot be held.
: > "$TESTTMP/fp-update-calls"
assert_exit 0 "flatpak_apply --runtime updates every runtime" flatpak_apply -y --runtime
assert_eq "$(fp_line 1)" "flatpak update --system --noninteractive -y --runtime" "the runtime command"
assert_eq "$(fp_calls | wc -l)" "1" "...as ONE command, not one per runtime"
# It is still not a free pass for an option-shaped id: --runtime is matched by name, ahead of the
# validation, and everything else option-shaped still lands on the reject arm.
: > "$TESTTMP/fp-update-calls"
assert_exit 2 "an option-shaped id is still rejected beside it" flatpak_apply -y --runtime --installation=other
assert_eq "$(fp_calls | wc -c)" "0" "...updating nothing at all"

# flatpak_id_is_runtime is what `kempt hold` refuses on.
assert_exit 0 "an installed runtime id is recognised" flatpak_id_is_runtime org.kde.Platform
assert_exit 1 "an app id is not a runtime" flatpak_id_is_runtime net.mkiol.SpeechNote
assert_exit 1 "...and neither is a name nothing answers to" flatpak_id_is_runtime org.example.Nothing
finish
