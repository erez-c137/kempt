#!/usr/bin/env bash
# dnf5's own records of a transaction: what the restart report reads from `dnf5 history`, and which
# transaction a live run was.
#
# Every dnf5 record here is real: tests/fixtures/MANIFEST.md says how the stages and the history they
# left were captured.
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"

export WORLD="$TESTTMP/world"; mkdir -p "$WORLD"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
exit 0
STUB
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
cat > "$TESTTMP/notify-stub" <<STUB
#!/usr/bin/env bash
echo "NOTIFY \$@" >> "$WORLD/notifications"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"
# dnf5's history, served from the recorded captures. An id with no capture answers `[]` under exit 0,
# which is what real dnf5 answers for an id it does not have. Every call is logged, so a test can
# say that the history was never asked at all.
cat > "$TESTTMP/history-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORLD/history-calls"
case "$*" in
  *"history list --json"*) cat "$HIST_LIST" ;;
  *"history info "*)
    id="$*"; id="${id#*history info }"; id="${id%% *}"
    if [[ -f "$HIST_INFO/dnf-history-info-$id.json" ]]; then cat "$HIST_INFO/dnf-history-info-$id.json"; else echo "[]"; fi ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$TESTTMP"/apply-stub "$TESTTMP"/refresh-stub "$TESTTMP"/notify-stub "$TESTTMP"/dnf-reboot-no \
         "$TESTTMP"/history-stub
export KEMPT_APPLY_HELPER="$TESTTMP/apply-stub"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_NOTIFY="$TESTTMP/notify-stub"
export KEMPT_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
export KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no"
export KEMPT_SKIP_REFRESH=1
export HIST_LIST="$FIXTURES/dnf-history-list.json" HIST_INFO="$FIXTURES"
POISONED_HISTORY="$KEMPT_DNF_HISTORY_CMD"   # tests/lib.sh's: a path that does not exist
"$KEMPT" config set include_flatpak false >/dev/null

notified() { grep -c "$1" "$WORLD/notifications" 2>/dev/null || true; }
events_like() { grep -c "$1" "$KEMPT_STATE_DIR/events.log" 2>/dev/null || true; }

# --- after the restart ---------------------------------------------------------------------------------
# History entry 8 of the capture is the restart's install. Only its times are moved, because a report
# older than two days is an old report.
export KEMPT_DNF_HISTORY_CMD="$TESTTMP/history-stub"
fresh_history() {  # capture dir, list → a list and info files with entry 8 finished an hour ago
  local now=$(( $(date +%s) - 3600 ))
  mkdir -p "$TESTTMP/fresh"; cp "$1"/dnf-history-info-*.json "$TESTTMP/fresh/"
  jq --argjson t "$now" '(.[] | select(.id == 8)) |= (.start_time = $t | .end_time = ($t + 1))' "$2" > "$TESTTMP/fresh-list.json"
  jq --argjson t "$now" '.[0].start_time = $t | .[0].end_time = ($t + 1)' "$1/dnf-history-info-8.json" > "$TESTTMP/fresh/dnf-history-info-8.json"
  HIST_LIST="$TESTTMP/fresh-list.json"; HIST_INFO="$TESTTMP/fresh"
}
report() {  # → the check after the restart; HH is the entry it wrote, or empty
  rm -rf "$KEMPT_STATE_DIR/history" "$KEMPT_STATE_DIR/stage-shown"; mkdir -p "$KEMPT_STATE_DIR/history"
  printf 'curl\t8.18.0-10.fc44\nnano\t8.7.1-1.fc44\npatch\t2.8-2.fc44\nzsh\t5.9-21.fc44\n' > "$WORLD/rpm.tsv"
  : > "$WORLD/notifications"; : > "$WORLD/history-calls"
  KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml" "$KEMPT" check >/dev/null 2>"$TESTTMP/report.err" || true
  HH="$(ls -1 "$KEMPT_STATE_DIR"/history/*.json 2>/dev/null | tail -1)"
}
reported() { jq -r '[.backends.dnf[] | arrays | .[].name] | sort | join(" ")' "$HH"; }
fresh_history "$FIXTURES" "$FIXTURES/dnf-history-list.json"
export HIST_LIST HIST_INFO
report
assert_eq "$(jq -r .surface "$HH")" "offline (applied on reboot)" "dnf5's record of a restart's install is the report"
assert_eq "$(jq -r '.transaction_id // "absent"' "$HH")" "8" "...naming dnf5's history entry for it"
assert_contains " $(reported) " " curl " "...and the report is that entry's packages"
assert_contains " $(reported) " " zsh " "...all of them"
assert_not_contains " $(reported) " " patch " "...and not patch, which something else installed across the same restart"
assert_eq "$(notified 'were installed during the restart')" "1" "...and announced as installed"
# How long it took is dnf5's own record of that entry.
assert_eq "$(jq -r '.duration_sec // "absent"' "$HH")" "1" "...taking as long as dnf5 recorded it taking"
assert_eq "$("$KEMPT" summary 2>/dev/null | awk 'NR==1' | grep -c ', 1s)')" "1" "...which the summary prints"
: > "$WORLD/notifications"
KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml" "$KEMPT" check >/dev/null 2>&1
assert_eq "$(notified 'were installed during the restart')" "0" "...once"

# An entry whose times do not read as a span is a duration nobody knows, and it is left out rather
# than written as 0: a restart that installed packages did not take no time.
jq '.[0].end_time = .[0].start_time - 5' "$HIST_INFO/dnf-history-info-8.json" > "$HIST_INFO/d8" && mv "$HIST_INFO/d8" "$HIST_INFO/dnf-history-info-8.json"
jq '(.[] | select(.id == 8)) |= (.end_time = .start_time - 5)' "$HIST_LIST" > "$HIST_LIST.t" && mv "$HIST_LIST.t" "$HIST_LIST"
report
assert_eq "$(jq -r '.transaction_id // "absent"' "$HH")" "8" "premise: an entry that ends before it starts is still named"
assert_eq "$(jq -r 'has("duration_sec")' "$HH")" "false" "...with no duration"
export HIST_LIST="$FIXTURES/dnf-history-list.json" HIST_INFO="$FIXTURES"

# --- a live run, and the transaction dnf5 recorded for it ------------------------------------------
# The identity of a live run is the two reads around the apply - where dnf5's history stood before
# it, and the command dnf5 will have recorded for what Kempt ran.
#
# That command is taken from the ROOT HELPER here rather than written out by hand, because the
# helper is what dnf5 sees. A CLI that stopped agreeing with the helper about the command it runs
# would quietly lose every live attribution, and this is the assertion that would not let it.
# The helper's stand-in dnf5 records its argv, argv[0] included: dnf5 records /usr/bin/dnf5 when that is
# how it was started (seen on dnf5 5.4.3 and 5.4.1). Its tree stands in for /usr/bin.
LIVE_ROOT="$TESTTMP/live-root"; mkdir -p "$LIVE_ROOT/usr/bin" "$LIVE_ROOT/run"
# Enough of PID 1 for the argv: dnf5's output in the named file, then the stop step.
cat > "$LIVE_ROOT/usr/bin/systemd-run" <<'STANDIN'
#!/bin/bash -p
out="" stop=""
while [[ "$1" != -- ]]; do
  case "$1" in
    StandardOutput=file:*) out="${1#*:}" ;;
    ExecStopPost=*) stop="${1#*=}" ;;
  esac
  shift
done
shift
"$@" > "$out"; export EXIT_CODE=exited EXIT_STATUS=$?
eval "$stop"
STANDIN
printf '#!/bin/bash -p\necho "/usr/bin/dnf5 $*"\n' > "$LIVE_ROOT/usr/bin/dnf5"
chmod +x "$LIVE_ROOT/usr/bin/systemd-run" "$LIVE_ROOT/usr/bin/dnf5"
LIVE_CMD="$(KEMPT_HELPER_ROOT="$LIVE_ROOT" bash "$REPO_ROOT/libexec/kempt-apply" dnf-upgrade -y)"
assert_eq "$LIVE_CMD" "/usr/bin/dnf5 upgrade -y" "premise: the root helper runs the command dnf5 records"
# ...and the excludes, where the CLI puts them. cmd_update builds `/usr/bin/dnf5 upgrade "${yflag[@]}"
# "${excl[@]}"` and hands the helper the same two arrays; dnf5 records argv verbatim, so a helper
# that moved --exclude ahead of -y would match nothing and lose the attribution of every run on a
# box that holds a package - silently, and only on those boxes. Nothing else compares the two.
_excl_cmd="$(KEMPT_HELPER_ROOT="$LIVE_ROOT" bash "$REPO_ROOT/libexec/kempt-apply" dnf-upgrade -y --exclude=nano --exclude=zsh)"
assert_eq "$_excl_cmd" \
  "/usr/bin/dnf5 upgrade -y --exclude=nano --exclude=zsh" "premise: ...with the held packages excluded in that order"

LIVE_LIST="$TESTTMP/live-list.json"
mkdir -p "$TESTTMP/live-info"; cp "$FIXTURES"/dnf-history-info-*.json "$TESTTMP/live-info/"
# The history the apply leaves behind. Both new entries come from the capture: entry 10 is history
# info 8, a real `dnf5 upgrade` transaction, under the id and the command line this run's helper
# gives it; entry 9 is the capture's entry 3, somebody else's install, landing in the same window.
# Entry 9 is never looked up - its command is not the one Kempt ran - which is the point.
jq --arg cmd "$LIVE_CMD" '
    [ (.[] | select(.id == 8) | .id = 10 | .command_line = $cmd | .start_time += 2),
      (.[] | select(.id == 3) | .id = 9 | .start_time += 1) ] + .' \
   "$FIXTURES/dnf-history-list.json" > "$TESTTMP/live-list-after.json"
jq '.[0].id = 10' "$FIXTURES/dnf-history-info-8.json" > "$TESTTMP/live-info/dnf-history-info-10.json"
# The apply moves the world AND the history, the way a real one does: the list Kempt reads afterwards
# is not the list it read before.
cat > "$TESTTMP/live-apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
[[ "\$1" == dnf-upgrade ]] || exit 0
printf 'curl\t8.18.0-10.fc44\nnano\t8.7.1-1.fc44\npatch\t2.8-2.fc44\nzsh\t5.9-21.fc44\n' > "$WORLD/rpm.tsv"
cp "\$LIVE_AFTER" "$LIVE_LIST"
exit 0
STUB
chmod +x "$TESTTMP/live-apply-stub"
export LIVE_BEFORE="$FIXTURES/dnf-history-list.json" LIVE_AFTER="$TESTTMP/live-list-after.json"

# Across the run: curl and zsh moved (both in the transaction dnf5 recorded), nano did not, and
# patch arrived from somewhere else - the same world the restart report above uses, so both halves of
# the lookup are judged on identical evidence.
live_run() {  # → one live update; HH is the entry it wrote
  rm -rf "$KEMPT_STATE_DIR/history" "$KEMPT_STATE_DIR/snapshots"
  mkdir -p "$KEMPT_STATE_DIR/history" "$KEMPT_STATE_DIR/snapshots"
  printf 'curl\t8.18.0-9.fc44\nnano\t8.7.1-1.fc44\nzsh\t5.9-19.fc44\n' > "$WORLD/rpm.tsv"
  cp "$LIVE_BEFORE" "$LIVE_LIST"
  : > "$WORLD/notifications"; : > "$WORLD/history-calls"; : > "$WORLD/apply-calls"
  KEMPT_APPLY_HELPER="$TESTTMP/live-apply-stub" KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml" \
    HIST_LIST="$LIVE_LIST" HIST_INFO="$TESTTMP/live-info" \
    "$KEMPT" update --no-flatpak >/dev/null 2>&1 || true
  HH="$(ls -1 "$KEMPT_STATE_DIR"/history/*.json 2>/dev/null | tail -1)"
}

live_run
assert_eq "$(grep -c '^APPLY dnf-upgrade' "$WORLD/apply-calls" || true)" "1" "premise: the run upgraded live"
assert_eq "$(jq -r '.transaction_id // "absent"' "$HH")" "10" \
  "a live run records the dnf5 transaction that was its own"
assert_eq "$(reported)" "curl zsh" \
  "...and that transaction's packages are the report: patch, installed by something else while the run was going, is not in it"
assert_eq "$(jq -r '.backends.dnf.updated[] | select(.name == "curl") | "\(.from) \(.to)"' "$HH")" \
  "8.18.0-9.fc44 8.18.0-10.fc44" "...with the versions the snapshots saw"
assert_eq "$(grep -c 'history list' "$WORLD/history-calls" || true)" "3" \
  "...found by two reads of the list, one on each side of the apply, beside the one every check makes"
assert_eq "$(grep -c 'history info' "$WORLD/history-calls" || true)" "1" \
  "...and one entry opened: the only one whose command is the command Kempt ran"

# Every way the history cannot answer is the run as it was before this lookup existed: the whole
# snapshot diff, and no transaction named.
live_cannot_tell() {  # label → asserts the last run is that baseline
  assert_eq "$(jq -r '.transaction_id // "absent"' "$HH")" "absent" "$1: no transaction is named"
  assert_eq "$(reported)" "curl patch zsh" "$1: ...and the whole snapshot diff is the report"
}

LIVE_AFTER="$FIXTURES/dnf-history-list.json"; live_run
live_cannot_tell "dnf5 recorded nothing for the run"
LIVE_AFTER="$TESTTMP/live-list-after.json"

KEMPT_DNF_HISTORY_CMD="$POISONED_HISTORY" live_run
live_cannot_tell "dnf5's history does not answer"
assert_eq "$(grep -c '^APPLY dnf-upgrade' "$WORLD/apply-calls" || true)" "1" \
  "...and the update itself ran regardless"

# Only an entry that arrived AFTER the run started can be the run. One that was already there ran
# before Kempt did, whatever command it carries.
jq --arg cmd "$LIVE_CMD" '[.[] | select(.id == 8) | .command_line = $cmd] + (map(select(.id != 8)))' \
   "$FIXTURES/dnf-history-list.json" > "$TESTTMP/live-list-early.json"
LIVE_BEFORE="$TESTTMP/live-list-early.json"; LIVE_AFTER="$TESTTMP/live-list-early.json"; live_run
live_cannot_tell "an entry that ran the same command was already there before the run"
LIVE_BEFORE="$FIXTURES/dnf-history-list.json"; LIVE_AFTER="$TESTTMP/live-list-after.json"

# Two of them, both the run by every test there is - an apply that was retried leaves exactly this.
# Which one to report is not something the ids can settle, and reporting either would be a guess.
jq '[.[0] | .id = 11] + .' "$TESTTMP/live-list-after.json" > "$TESTTMP/live-list-twice.json"
jq '.[0].id = 11' "$FIXTURES/dnf-history-info-8.json" > "$TESTTMP/live-info/dnf-history-info-11.json"
LIVE_AFTER="$TESTTMP/live-list-twice.json"; live_run
live_cannot_tell "two entries ran the command Kempt ran"
LIVE_AFTER="$TESTTMP/live-list-after.json"

# The entry IS the run's, and it names no packages - the live twin of the restart report above, and
# the same answer: identified, reported in full.
jq '.[0].packages = []' "$TESTTMP/live-info/dnf-history-info-10.json" > "$TESTTMP/live-info-10-empty.json"
mv "$TESTTMP/live-info/dnf-history-info-10.json" "$TESTTMP/live-info-10.json"
cp "$TESTTMP/live-info-10-empty.json" "$TESTTMP/live-info/dnf-history-info-10.json"
live_run
assert_eq "$(jq -r '.transaction_id // "absent"' "$HH")" "10" \
  "a live entry that names no packages is still the run's transaction"
assert_eq "$(reported)" "curl patch zsh" "...and the report stays the whole snapshot diff"
mv "$TESTTMP/live-info-10.json" "$TESTTMP/live-info/dnf-history-info-10.json"

# The list named an entry the history then has nothing for. `[]` is what real dnf5 answers for an id
# it does not have, and an id its own list just named is not a history this build can read.
mv "$TESTTMP/live-info/dnf-history-info-10.json" "$TESTTMP/live-info-10.json"
live_run
live_cannot_tell "the history has no entry for an id its own list named"
mv "$TESTTMP/live-info-10.json" "$TESTTMP/live-info/dnf-history-info-10.json"


# --- the helper could not tell, and dnf5's history can -------------------------------------------
# A run whose helper exits non-zero after dnf5 finished, or a package's setup step printed something
# alarming. When the history names this run's transaction
# and records it as Ok, the run is recorded as the success it was, and the log says where the
# result came from. A `>>> ` line is a package's setup step talking, so it is never the reason.
sed -e 's/^exit 0$/echo ">>> Running %post scriptlet: demo-1.0"; echo ">>> Remote peer disconnected"; exit 1/' \
  "$TESTTMP/live-apply-stub" > "$TESTTMP/live-apply-lost"
chmod +x "$TESTTMP/live-apply-lost"
live_lost_run() {  # → live_run with the helper that exits 1 after dnf5 finished
  cp "$TESTTMP/live-apply-stub" "$TESTTMP/live-apply-stub.keep"
  cp "$TESTTMP/live-apply-lost" "$TESTTMP/live-apply-stub"
  : > "$KEMPT_STATE_DIR/events.log"
  live_run
  cp "$TESTTMP/live-apply-stub.keep" "$TESTTMP/live-apply-stub"
}
live_lost_run
assert_contains "$(tail -n 1 "$WORLD/apply-calls" 2>/dev/null)" "APPLY dnf-upgrade" "premise: the helper that exits 1 ran"
assert_eq "$(jq -r .status "$HH")" "ok" "the helper exits 1, the history records this run's transaction as Ok: the run is a success"
assert_eq "$(jq -r '.transaction_id // "absent"' "$HH")" "10" "...naming that transaction"
assert_eq "$(jq -r '.error // ""' "$HH")" "" "...with no failure reason"
assert_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "The update succeeded, as dnf's history records (transaction 10)" \
  "...and the event log says where the result came from"

jq '(.[] | select(.id == 10) | .status) = "Error"' "$TESTTMP/live-list-after.json" > "$TESTTMP/live-list-error.json"
LIVE_AFTER="$TESTTMP/live-list-error.json"; live_lost_run
LIVE_AFTER="$TESTTMP/live-list-after.json"
assert_eq "$(jq -r .status "$HH")" "failed" "...but a transaction the history records as failed stays a failed run"
assert_not_contains "$(jq -r '.error // ""' "$HH")" "Remote peer disconnected" "...whose reason is not a package's setup-step line"
assert_not_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "as dnf's history records" "...and nothing was read from history"
jq '[.[0] | .id = 11] + .' "$TESTTMP/live-list-after.json" > "$TESTTMP/live-list-twice-lost.json"
LIVE_AFTER="$TESTTMP/live-list-twice-lost.json"; live_lost_run
LIVE_AFTER="$TESTTMP/live-list-after.json"
assert_eq "$(jq -r .status "$HH")" "failed" "...and so does a run the history cannot name"
# The helper's busy answer started nothing: the Ok entry is the earlier run's, never this one's.
sed -i 's/exit 1$/exit 5/' "$TESTTMP/live-apply-lost"
live_lost_run
sed -i 's/exit 5$/exit 1/' "$TESTTMP/live-apply-lost"
assert_eq "$(jq -r .status "$HH")" "failed" "...and so does a run the helper turned away as busy"
assert_not_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "as dnf's history records" "...which reads nothing from history"
# Only an exit that can follow a dnf5 that ran is overridden: 1 (dnf5's failure), 255 (killed) and
# 128 and up (stopped by a signal). 2 and 3 are the helper turning the run away, and 126 and 127 are pkexec's: nothing
# ran, so the Ok entry is another run's.
for rc in 2 126 127; do
  sed -i "s/exit 1\$/exit $rc/" "$TESTTMP/live-apply-lost"
  live_lost_run
  sed -i "s/exit $rc\$/exit 1/" "$TESTTMP/live-apply-lost"
  assert_eq "$(jq -r .status "$HH")" "failed" "...and so does a helper exit of $rc, which ran nothing"
  assert_not_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "as dnf's history records" "...$rc: nothing read from history"
done
for rc in 255 143; do
  sed -i "s/exit 1\$/exit $rc/" "$TESTTMP/live-apply-lost"
  live_lost_run
  sed -i "s/exit $rc\$/exit 1/" "$TESTTMP/live-apply-lost"
  assert_eq "$(jq -r .status "$HH")" "ok" "a helper exit of $rc after this run's Ok transaction: the run is a success"
done

# The other way round: the helper says 0, and the history names this run's transaction as failed.
# That happens when the helper read "gone" as success because another run reset the failed unit.
# The history is the evidence, and the run is a failure.
: > "$KEMPT_STATE_DIR/events.log"
LIVE_AFTER="$TESTTMP/live-list-error.json"; live_run
LIVE_AFTER="$TESTTMP/live-list-after.json"
assert_eq "$(jq -r .status "$HH")" "failed" "the helper exits 0, the history records this run's transaction as Error: the run failed"
assert_eq "$(jq -r '.transaction_id // "absent"' "$HH")" "10" "...naming that transaction"
assert_contains "$(jq -r '.error // ""' "$HH")" "dnf5 recorded this update as failed" "...with a plain reason"
assert_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "The update failed, as dnf's history records (transaction 10: Error)" \
  "...and the event log says where the result came from"
jq '(.[] | select(.id == 10)) |= del(.status)' "$TESTTMP/live-list-after.json" > "$TESTTMP/live-list-nostatus.json"
LIVE_AFTER="$TESTTMP/live-list-nostatus.json"; live_run
LIVE_AFTER="$TESTTMP/live-list-after.json"
assert_eq "$(jq -r .status "$HH")" "ok" "...but a transaction with no status Kempt can read leaves the helper's 0 as it is"

# The reason picker skips `>>> ` lines wherever they come from.
printf '%s\n' "== System (dnf) ==" ">>> Running %post scriptlet: demo-1.0" ">>> [RPM] Remote peer disconnected: error" \
  "Error: Transaction failed" > "$TESTTMP/reason.log"
assert_eq "$(bash -c 'source "$1/lib/common.sh"; run_failure_reason "$2"' _ "$REPO_ROOT" "$TESTTMP/reason.log")" \
  "Error: Transaction failed" "the failure reason is dnf5's own line, never a package's setup-step line"
printf '%s\n' ">>> Running %post scriptlet: demo-1.0" ">>> Remote peer disconnected" "Complete!" > "$TESTTMP/reason.log"
assert_eq "$(bash -c 'source "$1/lib/common.sh"; run_failure_reason "$2"' _ "$REPO_ROOT" "$TESTTMP/reason.log")" \
  "Complete!" "...also when no line names a failure"
# When nothing else names a failure, a setup-step line that does is a better reason than the last
# line. "Remote peer disconnected" is never one of them: dnf5 prints it when a step restarts a service.
printf '%s\n' "== System (dnf) ==" ">>> Running %post scriptlet: demo-1.0" ">>> Remote peer disconnected: error" \
  ">>> Scriptlet failed: %post(demo-1.0) exit status 1" "Complete!" > "$TESTTMP/reason.log"
assert_eq "$(bash -c 'source "$1/lib/common.sh"; run_failure_reason "$2"' _ "$REPO_ROOT" "$TESTTMP/reason.log")" \
  ">>> Scriptlet failed: %post(demo-1.0) exit status 1" "...but a setup-step line that names a failure beats the last line"
printf '%s\n' ">>> Running %post scriptlet: demo-1.0" ">>> Remote peer disconnected: error" "Complete!" > "$TESTTMP/reason.log"
assert_eq "$(bash -c 'source "$1/lib/common.sh"; run_failure_reason "$2"' _ "$REPO_ROOT" "$TESTTMP/reason.log")" \
  "Complete!" "...and \"Remote peer disconnected\" never does"

# A download that failed names the package. The lines are dnf5's on Fedora 44, from a run where one
# third-party server answered 504. The rpm's file name is not name-version-release, so the name comes
# from the transaction table, and the longest name the file starts with wins, in whichever section.
dl_log() {  # file-name-in-librepo-line
  printf '%s\n' "== System (dnf) ==" \
    "Package                                      Arch   Version                 Repository                            Size" \
    "Upgrading:" \
    " claude-desktop-unofficial                   x86_64 0:4.23118.0-3.3.15.fc42 claude-desktop                   657.8 MiB" \
    "   replacing claude-desktop-unofficial       x86_64 0:4.16336.0-3.3.15.fc42 claude-desktop                   652.6 MiB" \
    " createrepo_c-libs                           x86_64 0:1.2.6-1.fc44          updates                          285.6 KiB" \
    "Installing dependencies:" \
    " createrepo_c                                x86_64 0:1.2.6-1.fc44          updates                          194.4 KiB" \
    ">>> No more mirrors to try - All mirrors were already tried without success" \
    ">>> Not finished - interrupted by error: Cannot download $1: All mirrors were tried" \
    "Failed to download packages" \
    " Librepo error: Cannot download $1: All mirrors were tried" "" "== Apps (flatpak) ==" "Nothing to update."
}
dl_reason() { bash -c 'source "$1/lib/common.sh"; run_failure_reason "$2"' _ "$REPO_ROOT" "$TESTTMP/reason.log"; }
dl_log "claude-desktop-unofficial-4.23118.0-3.3.15-1.x86_64.rpm" > "$TESTTMP/reason.log"
assert_eq "$(dl_reason)" "Could not download claude-desktop-unofficial from its server. Try again later." \
  "a failed download names the package, by its name in the transaction table"
dl_log "createrepo_c-libs-1.2.6-1.fc44.x86_64.rpm" > "$TESTTMP/reason.log"
assert_eq "$(dl_reason)" "Could not download createrepo_c-libs from its server. Try again later." \
  "...the longest name the file starts with"
dl_log "unknown-pkg-1.0-1.x86_64.rpm" > "$TESTTMP/reason.log"
assert_eq "$(dl_reason)" "Failed to download packages" "...and a file no listed package matches keeps dnf5's words"
dl_log "createrepo_c-1.2.6-1.fc44.x86_64.rpm" | grep -v 'Librepo error' > "$TESTTMP/reason.log"
assert_eq "$(dl_reason)" "Failed to download packages" "...as does a log with no librepo line"

# A transaction PackageKit ran has no command line, and dnf5 lists it with command_line null. That
# is another command, not a history of another shape: one such entry must not blind either reader.
jq '[.[0] | .id = 9 | .command_line = null] + .' "$FIXTURES/dnf-history-list.json" > "$TESTTMP/list-pk.json"
assert_eq "$(HIST_LIST="$TESTTMP/list-pk.json" bash -c 'source "$1/lib/common.sh"; live_history_attribution 7 "dnf5 upgrade --offline -y --exclude=nano"' _ "$REPO_ROOT" | head -1)" \
  "8" "an entry with no command line is another command to the live reader"
fresh_history "$FIXTURES" "$TESTTMP/list-pk.json"
report
assert_eq "$(jq -r '.transaction_id // "absent"' "$HH")" "8" "...and to the restart's reader"

finish
