#!/usr/bin/env bash
# Transaction identity: is the transaction a restart applied the one Kempt staged?
#
# Two gates already stand between a restart and a history entry reading "offline (applied on
# reboot)": the boot changed, and dnf5's stored transaction went away. Neither says WHICH
# transaction that was. `sudo dnf5 offline clean` followed by a stage of somebody's own, then a
# restart, passes both, and the entry used to name that other transaction's packages as Kempt's.
#
# The marker now records the identity dnf5 wrote for the stage (its rpmdb cookie and its command),
# and this file pins what is done with it:
#
#   before the restart, a stored transaction that is not the one recorded is announced once;
#   after the restart, dnf5's history names the entry that ran, and that entry decides the report;
#   and every way the history can fail to answer lands on the harvest exactly as it was before.
#
# Every dnf5 record here is real: tests/fixtures/MANIFEST.md says how the two stages, the replaced
# one and the history they left were captured. The two tomls carry the SAME cookie, which is the
# point of the capture - a stage made over another against the same rpm database keeps it.
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

marker="$KEMPT_STATE_DIR/offline_staged.json"
STAGED_TOML="$FIXTURES/offline-identity-staged.toml"
STAGED_TX="$FIXTURES/offline-identity-staged-transaction.json"
REPLACED_TOML="$FIXTURES/offline-identity-replaced.toml"
REPLACED_TX="$FIXTURES/offline-identity-replaced-transaction.json"
toml_key() { sed -n "s/^$2 = \"\(.*\)\"$/\1/p" "$1"; }
COOKIE="$(toml_key "$STAGED_TOML" rpmdb_cookie)"
notified() { grep -c "$1" "$WORLD/notifications" 2>/dev/null || true; }
events_like() { grep -c "$1" "$KEMPT_STATE_DIR/events.log" 2>/dev/null || true; }

# --- the stage records which transaction it is ------------------------------------------------------
export KEMPT_OFFLINE_TOML="$STAGED_TOML" KEMPT_OFFLINE_TXJSON="$STAGED_TX"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
assert_exit 0 "the stage wrote a marker" -- test -f "$marker"
assert_eq "$(jq -r '.rpmdb_cookie // "absent"' "$marker")" "$COOKIE" \
  "the marker records the rpmdb cookie dnf5 wrote for the transaction"
assert_eq "$(jq -r '.cmd_line // "absent"' "$marker")" "dnf5 upgrade --offline -y --exclude=tree" \
  "...and the command that built it, verbatim"

# A toml that does not read in the shape dnf5 writes today gives no identity, and no identity is
# written: the marker is still written, with every other field, and behaves like one from an older
# build. A command carrying a quote is the case the toml reader cannot carry through intact.
sed -e 's/^rpmdb_cookie = .*/rpmdb_cookie = "sha256:not-the-format"/' \
    -e 's/^cmd_line = .*/cmd_line = "dnf5 upgrade --offline -y --exclude=\\"x\\""/' \
    "$STAGED_TOML" > "$TESTTMP/odd.toml"
rm -f "$marker"
KEMPT_OFFLINE_TOML="$TESTTMP/odd.toml" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
assert_exit 0 "a toml whose identity does not read cleanly still gets a marker" -- test -f "$marker"
assert_eq "$(jq -c '[has("rpmdb_cookie"), has("cmd_line")]' "$marker")" "[false,false]" \
  "...with no cookie and no command in it, absent rather than guessed"
assert_eq "$(jq -r '.staged_names_source' "$marker")" "transaction" "...and everything else recorded as usual"

# --- before the restart ------------------------------------------------------------------------------
rm -f "$marker"
"$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
staged_at="$(jq -r .staged_at "$marker")"
: > "$WORLD/notifications"
"$KEMPT" check >/dev/null
assert_eq "$(jq -r '.replaced // "absent"' "$marker")" "absent" \
  "the transaction Kempt staged, still stored, is not called replaced"
assert_eq "$(notified 'replaced outside Kempt')" "0" "...and nothing is announced"

# The real capture: `dnf5 offline clean`, then a stage with another --exclude. Same cookie, so it is
# the command and the package set that give it away.
export KEMPT_OFFLINE_TOML="$REPLACED_TOML" KEMPT_OFFLINE_TXJSON="$REPLACED_TX"
"$KEMPT" check >/dev/null
assert_eq "$(notified 'replaced outside Kempt')" "1" "a stage replaced outside Kempt is announced"
assert_eq "$(events_like 'offline stage replaced outside Kempt (command, packages) - announced')" "1" \
  "...and the event names what differs: the command and the packages, not the cookie"
assert_eq "$(jq -r '.replaced // "absent"' "$marker")" "true" "...and the marker records it"
assert_eq "$(jq -r .staged_at "$marker")" "$staged_at" "...and is still the marker of the stage Kempt made"
"$KEMPT" check >/dev/null
assert_eq "$(notified 'replaced outside Kempt')" "1" "...said once, not once per check"
assert_eq "$(events_like 'offline stage replaced outside Kempt')" "1" "...in the event log too"

# Another cookie on its own is enough: a transaction built against another rpm database.
jq -c 'del(.replaced)' "$marker" > "$marker.tmp" && mv "$marker.tmp" "$marker"
sed "s/^rpmdb_cookie = .*/rpmdb_cookie = \"$(printf 'a%.0s' {1..64})\"/" "$STAGED_TOML" > "$TESTTMP/other-cookie.toml"
KEMPT_OFFLINE_TOML="$TESTTMP/other-cookie.toml" KEMPT_OFFLINE_TXJSON="$STAGED_TX" "$KEMPT" check >/dev/null
assert_eq "$(events_like 'offline stage replaced outside Kempt (rpmdb cookie) - announced')" "1" \
  "a different rpmdb cookie alone is a replaced stage"

# While a Kempt stage is in flight the two disagree because Kempt is replacing one with the other.
# The stage lock is held here by this shell; the check only tries it and compares nothing.
jq -c 'del(.replaced)' "$marker" > "$marker.tmp" && mv "$marker.tmp" "$marker"
: > "$WORLD/notifications"
exec 5>>"$KEMPT_STATE_DIR/stage.lock"; flock 5
"$KEMPT" check >/dev/null
assert_eq "$(jq -r '.replaced // "absent"' "$marker")" "absent" \
  "while a stage holds the stage lock, a disagreement is not called replaced"
assert_eq "$(notified 'replaced outside Kempt')" "0" "...and a rebuild is never announced as somebody else's"
flock -u 5; exec 5>&-
"$KEMPT" check >/dev/null
assert_eq "$(notified 'replaced outside Kempt')" "1" "...and once the lock is free, the same check announces it"

# A marker from an older build records no identity, and keeps the behaviour it always had.
jq -c 'del(.replaced, .rpmdb_cookie, .cmd_line)' "$marker" > "$marker.tmp" && mv "$marker.tmp" "$marker"
: > "$WORLD/notifications"
"$KEMPT" check >/dev/null
assert_eq "$(jq -r '.replaced // "absent"' "$marker")" "absent" "a marker without an identity is never called replaced"
assert_eq "$(notified 'replaced outside Kempt')" "0" "...and nothing is announced about it"
rm -f "$marker"

# --- after the restart ---------------------------------------------------------------------------------
# One world for every case below, so the only thing that varies is the marker and the history.
# Across the restart: curl and zsh moved (both in the replaced transaction), nano did not (it was
# excluded from it), and patch arrived from somewhere else entirely.
PRE="$KEMPT_STATE_DIR/snapshots/offline-pre-identity.tsv"
STAGED_AT="2026-09-15T19:25:30+00:00"   # between history entries 7 and 8 of the capture
export KEMPT_DNF_HISTORY_CMD="$TESTTMP/history-stub"
tx_names() { KEMPT_OFFLINE_TXJSON="$1" bash -c 'source "$1/lib/common.sh"; offline_txjson_names' _ "$REPO_ROOT"; }
marker_from() {  # toml transaction.json → a marker as a stage of that transaction writes it
  jq -cn --arg c "$(toml_key "$1" rpmdb_cookie)" --arg l "$(toml_key "$1" cmd_line)" \
         --arg n "$(tx_names "$2")" --arg pre "$PRE" --arg at "$STAGED_AT" \
    '{staged_at:$at, boot_id:"boot-old", staged:2, armed:true, pre_snapshot:$pre,
      staged_names_source:"transaction", staged_names:($n | split("\n") | map(select(length > 0))),
      staged_excluded:[], rpmdb_cookie:$c, cmd_line:$l}'
}
harvest() {  # marker-json → the post-restart check; HH is the entry it wrote, or empty
  rm -rf "$KEMPT_STATE_DIR/history"; mkdir -p "$KEMPT_STATE_DIR/history" "$KEMPT_STATE_DIR/snapshots"
  printf 'curl\t8.18.0-9.fc44\nnano\t8.7.1-1.fc44\nzsh\t5.9-19.fc44\n' > "$PRE"
  printf 'curl\t8.18.0-10.fc44\nnano\t8.7.1-1.fc44\npatch\t2.8-2.fc44\nzsh\t5.9-21.fc44\n' > "$WORLD/rpm.tsv"
  printf '%s\n' "$1" > "$marker"
  : > "$WORLD/notifications"; : > "$WORLD/history-calls"
  KEMPT_BOOT_ID=boot-new KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml" \
    "$KEMPT" check >/dev/null 2>"$TESTTMP/harvest.err" || true
  HH="$(ls -1 "$KEMPT_STATE_DIR"/history/*.json 2>/dev/null | tail -1)"
}
reported() { jq -r '[.backends.dnf[] | arrays | .[].name] | sort | join(" ")' "$HH"; }
# .log goes out with .timestamp, and for the same reason: the harvest's log path is DERIVED from
# that timestamp ($LOG_DIR/$ts.log), so it moves every run and is no more part of an entry's shape
# than the timestamp itself. What this helper compares is which FIELDS a harvest produced and what
# it reported, not which second it happened in.
shape() { jq -Sc 'del(.timestamp, .log)' "$HH"; }
MARKER_STAGED="$(marker_from "$STAGED_TOML" "$STAGED_TX")"
MARKER_REPLACED="$(marker_from "$REPLACED_TOML" "$REPLACED_TX")"

# The baseline every "cannot tell" case must reproduce: a marker from an older build, which is the
# harvest as it was before identity existed. Its history is never asked.
harvest "$(jq -c 'del(.rpmdb_cookie, .cmd_line)' <<<"$MARKER_REPLACED")"
BASE="$(shape)"
assert_eq "$(jq -r .surface "$HH")" "offline (applied on reboot)" "a marker without an identity is harvested as it always was"
assert_eq "$(reported)" "curl patch zsh" "...with the whole snapshot diff as the report"
assert_eq "$(jq -r '.transaction_id // "absent"' "$HH")" "absent" "...and no transaction named"
assert_eq "$(grep -c . "$WORLD/history-calls" || true)" "0" "...and dnf5's history is never asked"

# MATCHED. History entry 8 began at the recorded cookie and ran the recorded command.
harvest "$MARKER_REPLACED"
assert_eq "$(jq -r .surface "$HH")" "offline (applied on reboot)" "the transaction the marker records ran: harvested as the stage"
assert_eq "$(jq -r '.transaction_id // "absent"' "$HH")" "8" "...naming dnf5's history entry for it"
assert_eq "$(reported)" "curl zsh" \
  "...and the report is that entry's packages: patch, which something else installed across the same restart, is not in it"
assert_eq "$(jq -r '.backends.dnf.updated[] | select(.name == "curl") | "\(.from) \(.to)"' "$HH")" \
  "8.18.0-9.fc44 8.18.0-10.fc44" "...with the versions the snapshots saw"
assert_eq "$(notified 'were applied on reboot')" "1" "...and announced as applied"
assert_exit 0 "...and the marker is consumed" -- test ! -f "$marker"
assert_exit 0 "...and so is its snapshot copy" -- test ! -f "$PRE"

# DID NOT RUN. The marker records the FIRST stage; what ran began at the same cookie with another
# command and another package set (nano is in the first and not in what ran).
harvest "$MARKER_STAGED"
assert_eq "$(jq -r .surface "$HH")" "restart (staged update did not run)" \
  "a restart that ran another transaction is not recorded as the stage"
assert_eq "$(jq -r '.transaction_id // "absent"' "$HH")" "absent" "...names no transaction as Kempt's"
assert_eq "$(reported)" "curl patch zsh" "...and keeps the whole snapshot diff as the report"
assert_eq "$(notified 'did not run on the restart')" "1" "...and says the staged update did not run"
assert_eq "$(notified 'were applied on reboot')" "0" "...never that it was applied"
assert_eq "$(events_like 'harvest found the staged transaction did not run (2 updated, +1 installed)')" "1" \
  "...and the event carries the counts of what did change"
assert_exit 0 "...and the marker is consumed: its transaction is gone either way" -- test ! -f "$marker"

# Nothing in the history began at the recorded cookie at all.
harvest "$(jq -c --arg c "$(printf 'b%.0s' {1..64})" '.rpmdb_cookie = $c' <<<"$MARKER_REPLACED")"
assert_eq "$(jq -r .surface "$HH")" "restart (staged update did not run)" \
  "no history entry began at the recorded cookie: the stage did not run"

# The check before the restart already found it replaced: that is the answer, without the history.
KEMPT_DNF_HISTORY_CMD="$POISONED_HISTORY" harvest "$(jq -c '. + {replaced: true}' <<<"$MARKER_REPLACED")"
assert_eq "$(jq -r .surface "$HH")" "restart (staged update did not run)" \
  "a marker found replaced before the restart is never harvested as Kempt's"

# --- every way the history cannot answer is the harvest as it was --------------------------------------
cannot_tell() {  # label → asserts the last harvest is the baseline, entry for entry
  assert_eq "$(shape)" "$BASE" "$1: the harvest is exactly the one without an identity"
}
KEMPT_DNF_HISTORY_CMD="$POISONED_HISTORY" harvest "$MARKER_REPLACED"
cannot_tell "dnf5's history does not answer"

printf 'Error: history database is locked\n' > "$TESTTMP/list-garbage.json"
HIST_LIST="$TESTTMP/list-garbage.json" harvest "$MARKER_REPLACED"
cannot_tell "the history list is not JSON"
printf '{"id":8}\n' > "$TESTTMP/list-object.json"
HIST_LIST="$TESTTMP/list-object.json" harvest "$MARKER_REPLACED"
cannot_tell "the history list is JSON of another shape"
jq 'map(del(.command_line))' "$FIXTURES/dnf-history-list.json" > "$TESTTMP/list-nocmd.json"
HIST_LIST="$TESTTMP/list-nocmd.json" harvest "$MARKER_REPLACED"
cannot_tell "the history list carries no command lines"

mkdir -p "$TESTTMP/info"; cp "$FIXTURES"/dnf-history-info-*.json "$TESTTMP/info/"
printf '[{"id":8,' > "$TESTTMP/info/dnf-history-info-8.json"
HIST_INFO="$TESTTMP/info" harvest "$MARKER_REPLACED"
cannot_tell "the history entry is truncated"
jq '.[0].rpmdb_version_begin = "sha256:" + .[0].rpmdb_version_begin' "$FIXTURES/dnf-history-info-8.json" \
  > "$TESTTMP/info/dnf-history-info-8.json"
HIST_INFO="$TESTTMP/info" harvest "$MARKER_REPLACED"
cannot_tell "the history entry records its starting rpmdb in another format"
cp "$FIXTURES/dnf-history-info-7.json" "$TESTTMP/info/dnf-history-info-8.json"
HIST_INFO="$TESTTMP/info" harvest "$MARKER_REPLACED"
cannot_tell "the history answers an id with another entry"
rm -f "$TESTTMP/info/dnf-history-info-8.json"
HIST_INFO="$TESTTMP/info" harvest "$MARKER_REPLACED"
cannot_tell "the history has no entry for an id its own list named"

# Another command from the cookie, and nothing to tell it from the stage by: the one shape a dnf5
# that recorded its commands differently would leave. Never evidence that the stage did not run.
harvest "$(jq -c 'del(.staged_names) | .staged_names_source = "none"' <<<"$MARKER_STAGED")"
cannot_tell "another command began at the cookie and the marker recorded no package set"
harvest "$(jq -c --argjson n "$(tx_names "$REPLACED_TX" | jq -Rn '[inputs]')" '.staged_names = $n' <<<"$MARKER_STAGED")"
cannot_tell "another command began at the cookie with exactly the packages the marker recorded"

# Two entries, both the stage by every test: cannot say which one the restart ran.
jq '[.[0] | .id = 9] + .' "$FIXTURES/dnf-history-list.json" > "$TESTTMP/list-twice.json"
jq '.[0].id = 9' "$FIXTURES/dnf-history-info-8.json" > "$TESTTMP/info/dnf-history-info-9.json"
cp "$FIXTURES/dnf-history-info-8.json" "$TESTTMP/info/dnf-history-info-8.json"
HIST_LIST="$TESTTMP/list-twice.json" HIST_INFO="$TESTTMP/info" harvest "$MARKER_REPLACED"
cannot_tell "two history entries match the stage"

# No entry at all since the stage: the package set moved, so a history that shows nothing is not
# telling the whole story, and "did not run" would be a claim without evidence.
harvest "$(jq -c '.staged_at = "2027-03-01T00:00:00+00:00"' <<<"$MARKER_STAGED")"
cannot_tell "the history has no entry since the stage"
assert_eq "$(grep -c 'history info' "$WORLD/history-calls" || true)" "0" "...and no entry was asked for"

jq '[range(21) as $i | .[0] | .id = 100 + $i]' "$FIXTURES/dnf-history-list.json" > "$TESTTMP/list-many.json"
HIST_LIST="$TESTTMP/list-many.json" harvest "$MARKER_REPLACED"
cannot_tell "more than 20 entries since the stage"
assert_eq "$(grep -c 'history info' "$WORLD/history-calls" || true)" "0" "...and none of them was asked for"

harvest "$(jq -c '.staged_at = "not a time"' <<<"$MARKER_REPLACED")"
cannot_tell "a staged_at that is not a time"

# The contract every caller relies on, in a strict shell: a history it cannot read is "cannot tell",
# never an exit.
strict() {  # marker-json → what a strict shell prints
  bash -c 'set -euo pipefail; source "$1/lib/common.sh"
           if v="$(offline_history_attribution "$2")"; then echo "verdict:${v%%$'"'\n'"'*}"; else echo "cannot tell"; fi
           echo "still running"' _ "$REPO_ROOT" "$1"
}
assert_eq "$(HIST_LIST="$TESTTMP/list-garbage.json" strict "$MARKER_REPLACED")" "$(printf 'cannot tell\nstill running')" \
  "a strict shell survives a history it cannot read"
assert_eq "$(strict "$MARKER_REPLACED")" "$(printf 'verdict:applied 8\nstill running')" \
  "...and reads the real one in the same shell"

# --- a live run, and the transaction dnf5 recorded for it ------------------------------------------
# A stage has a marker and a restart to bridge, so its identity has to be written down and looked up
# afterwards. A live run has neither, and needs neither: the identity is the two reads around the
# apply - where dnf5's history stood before it, and the command dnf5 will have recorded for what
# Kempt ran.
#
# That command is taken from the ROOT HELPER here rather than written out by hand, because the
# helper is what dnf5 sees. A CLI that stopped agreeing with the helper about the command it runs
# would quietly lose every live attribution, and this is the assertion that would not let it.
LIVE_CMD="$(KEMPT_APPLY_ECHO=1 bash "$REPO_ROOT/libexec/kempt-apply" dnf-upgrade -y)"
assert_eq "$LIVE_CMD" "dnf5 upgrade -y" "premise: the root helper runs the command dnf5 records"

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
# patch arrived from somewhere else - the same world the harvest cases above use, so both halves of
# the lookup are judged on identical evidence.
live_run() {  # → one live update; HH is the entry it wrote
  rm -rf "$KEMPT_STATE_DIR/history" "$KEMPT_STATE_DIR/snapshots"
  mkdir -p "$KEMPT_STATE_DIR/history" "$KEMPT_STATE_DIR/snapshots"
  printf 'curl\t8.18.0-9.fc44\nnano\t8.7.1-1.fc44\nzsh\t5.9-19.fc44\n' > "$WORLD/rpm.tsv"
  cp "$LIVE_BEFORE" "$LIVE_LIST"
  rm -f "$marker"
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
assert_eq "$(grep -c 'history list' "$WORLD/history-calls" || true)" "2" \
  "...found by two reads of the list, one on each side of the apply"
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

# The list named an entry the history then has nothing for. `[]` is what real dnf5 answers for an id
# it does not have, and an id its own list just named is not a history this build can read.
mv "$TESTTMP/live-info/dnf-history-info-10.json" "$TESTTMP/live-info-10.json"
live_run
live_cannot_tell "the history has no entry for an id its own list named"
mv "$TESTTMP/live-info-10.json" "$TESTTMP/live-info/dnf-history-info-10.json"

finish
