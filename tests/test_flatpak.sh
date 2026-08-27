#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
# sandbox() POISONS KEMPT_FLATPAK_REFRESH_CMD (a nonexistent path) so that no test file can reach
# flathub by accident. This file is the one that has to see the real shipped default, so it drops
# the poison for the block below and puts it straight back - anything after that block which calls
# the refresh has to name its own stub, exactly as every other seam here does.
# KEMPT_FLATPAK_UPDATE_CMD is poisoned by sandbox() for a louder reason still (an unstubbed apply
# would update the machine running the suite), and gets the same treatment: dropped for the block
# that has to see the shipped default, then put straight back.
_poisoned_fp_refresh="$KEMPT_FLATPAK_REFRESH_CMD"
_poisoned_fp_update="$KEMPT_FLATPAK_UPDATE_CMD"
unset KEMPT_FLATPAK_REFRESH_CMD KEMPT_FLATPAK_UPDATE_CMD
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
# scope contract asserted just below).
assert_eq "${KEMPT_FLATPAK_REMOTE_CMD/ --cached/}" "$KEMPT_FLATPAK_REFRESH_CMD" \
  "the refresh is the check command minus --cached"

# --- the scope contract ---------------------------------------------------------------------------
# v1 is system scope only, and all four flatpak commands are built in this one file now (the apply
# used to be built inside the root helper, which is why this contract used to be asserted by
# grepping libexec/kempt-apply). One disagreeing scope means an app the badge counts is an app the
# run does not touch, or the reverse.
FP_UPDATE_DEFAULT="$KEMPT_FLATPAK_UPDATE_CMD"
for _v in KEMPT_FLATPAK_REMOTE_CMD KEMPT_FLATPAK_REFRESH_CMD KEMPT_FLATPAK_LIST_CMD KEMPT_FLATPAK_UPDATE_CMD; do
  assert_eq "$([[ "${!_v}" == *" --system"* ]] && echo system || echo "unscoped: ${!_v}")" "system" \
    "$_v is --system scoped"
done
# The apply arm is unprivileged - it is `flatpak update`, nothing more. A pkexec or a helper path
# creeping back into this default is the regression this change exists to prevent.
assert_eq "$FP_UPDATE_DEFAULT" "flatpak update --system" "the apply arm is plain flatpak, run as the user"
export KEMPT_FLATPAK_REFRESH_CMD="$_poisoned_fp_refresh"
export KEMPT_FLATPAK_UPDATE_CMD="$_poisoned_fp_update"

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

# App ids arrive from a REMOTE's summary. NAME_RE is anchored on its first character, which is what
# keeps a name that looks like an option from arriving at flatpak AS an option.
: > "$TESTTMP/fp-update-calls"
assert_exit 2 "an option-shaped app id is rejected" flatpak_apply -y --installation=other
assert_exit 2 "an injection-shaped app id is rejected" flatpak_apply -y 'evil;id'
assert_eq "$(fp_calls | wc -c)" "0" "a rejected call updates nothing at all"
export KEMPT_FLATPAK_UPDATE_CMD="$_poisoned_fp_update"
finish
