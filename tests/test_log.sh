#!/usr/bin/env bash
# The event log: `$STATE_DIR/events.log`, written by log_event, read by `kempt log`.
#
# Why it exists. Kempt already wrote three files and they answered three questions:
# logs/<stamp>.log says what the package manager printed, history/<stamp>.json says what a run
# changed, state.json says what is pending now. None of them records that a SETTING was changed,
# a package was held, or a check ran - so "did the change I just made in the widget land?" had no
# answer anywhere on the box. That question is the whole reason this file exists, so the
# assertions below are mostly about exact TEXT: a vocabulary a person can grep, one line per
# thing that happened, and a `via` column that separates "I clicked that" from "something else".
#
# The fake world is the same shape test_update.sh uses: stub helpers on the privileged seams, a
# TSV the installed-package lookup reads, and an apply stub that "upgrades" by swapping which TSV
# is served. Nothing here needs dnf, flatpak, polkit or root.
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"
EV="$KEMPT_STATE_DIR/events.log"

export WORLD="$TESTTMP/world"; mkdir -p "$WORLD"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
cp "$FIXTURES/flatpak-list.tsv" "$WORLD/fp.tsv"

cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
case "\$1" in
  dnf-upgrade)       cp "$FIXTURES/snap-after.tsv" "$WORLD/rpm.tsv" ;;
  dnf-offline-stage) touch "$WORLD/staged" ;;
esac
exit 0
STUB
# The declined authentication, in pkexec's own words. This is the string the founder would
# actually see, and the point of the mapping is that they never see it in a summary.
cat > "$TESTTMP/apply-declined" <<'STUB'
#!/usr/bin/env bash
echo "Error executing command as another user: Not authorized" >&2
exit 127
STUB
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
cat > "$TESTTMP/refresh-declined" <<'STUB'
#!/usr/bin/env bash
echo "Error executing command as another user: Not authorized" >&2
exit 127
STUB
cat > "$TESTTMP/notify-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORLD/notifications"
STUB
chmod +x "$TESTTMP/apply-stub" "$TESTTMP/apply-declined" "$TESTTMP/refresh-stub" \
         "$TESTTMP/refresh-declined" "$TESTTMP/notify-stub"
# rc 1 PLUS the package list = reboot needed; rc 1 alone is the real command's "cannot answer".
cat > "$TESTTMP/dnf-reboot-yes" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
Core libraries or services have been updated since boot-up:
  * kernel-core

Reboot is required to fully utilize these updates.
OUT
exit 1
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"
chmod +x "$TESTTMP/dnf-reboot-yes" "$TESTTMP/dnf-reboot-no"

export KEMPT_APPLY_HELPER="$TESTTMP/apply-stub"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_NOTIFY="$TESTTMP/notify-stub"
export KEMPT_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export KEMPT_FLATPAK_LIST_CMD="cat $WORLD/fp.tsv"
export KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-yes"
export KEMPT_SKIP_REFRESH=1

events()      { cat "$EV" 2>/dev/null || true; }
events_like() { grep -c "$1" "$EV" 2>/dev/null || true; }   # how many lines carry this text
last_event()  { tail -1 "$EV" 2>/dev/null || true; }
# The event text without its timestamp and via column, which is what the vocabulary assertions
# are about. cut -d' ' -f3-, so a text containing spaces survives intact.
text_of()     { cut -d' ' -f3- <<<"$1"; }

# ==================================================================================================
# Nothing recorded yet.
# ==================================================================================================
assert_exit 0 "kempt log on a box with no events exits 0" "$KEMPT" log
assert_eq "$("$KEMPT" log)" "No events recorded yet." "...and says so on stdout, not stderr"

# ==================================================================================================
# The line: timestamp, via, text.
# ==================================================================================================
"$KEMPT" config set surface popup
line="$(last_event)"
stamp="$(awk '{print $1}' <<<"$line")"
assert_eq "$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$' <<<"$stamp")" \
  "1" "the line opens with a local ISO-8601 timestamp"
# The SAME format state.json carries, because the two are read side by side when something has
# gone wrong and a reader must not have to reconcile two notions of "when".
"$KEMPT" check >/dev/null
assert_eq "$(jq -r '.last_check' "$KEMPT_STATE_DIR/state.json" \
             | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$')" \
  "1" "...the same shape state.json's timestamps use"
assert_eq "$(awk '{print $2}' <<<"$line")" "cli" "a command run from a shell is recorded as cli"
assert_eq "$(text_of "$line")" "config set surface=popup (was unset)" \
  "...and the text names the key, the new value and what it replaced"

# KEMPT_VIA is the widget's stamp and nothing else: two answers, so the log can separate "I
# clicked that" from "something else did it".
KEMPT_VIA=widget "$KEMPT" config set surface background
assert_eq "$(awk '{print $2}' <<<"$(last_event)")" "widget" \
  "KEMPT_VIA=widget is recorded as widget"
assert_eq "$(text_of "$(last_event)")" "config set surface=background (was popup)" \
  "...and the old value is the one the previous write left"
KEMPT_VIA=something-else "$KEMPT" config set surface popup
assert_eq "$(awk '{print $2}' <<<"$(last_event)")" "cli" \
  "anything that is not exactly 'widget' is cli - there is no third answer"

assert_eq "$(stat -c %a "$EV")" "600" "the file is 0600 from the moment it exists"

# ==================================================================================================
# One line per call site, in the documented words.
# ==================================================================================================
: > "$EV"
"$KEMPT" hold dnf:vim-common
assert_eq "$(text_of "$(last_event)")" "hold dnf:vim-common" "hold records the backend:name pair"
assert_eq "$(grep -c '' "$EV")" "1" "...as exactly one line"
"$KEMPT" unhold dnf:vim-common
assert_eq "$(text_of "$(last_event)")" "unhold dnf:vim-common" "unhold records the same pair"
assert_eq "$(grep -c '' "$EV")" "2" "...also as exactly one line"
# A rejected hold changed nothing, so it must leave nothing behind - and it must still exit 2.
assert_exit 2 "an invalid hold name still exits 2" "$KEMPT" hold 'dnf:*'
assert_eq "$(grep -c '' "$EV")" "2" "...and writes no event, because nothing was held"

: > "$EV"
"$KEMPT" check >/dev/null
state="$KEMPT_STATE_DIR/state.json"
assert_eq "$(text_of "$(last_event)")" \
  "check ok actionable=$(jq -r .actionable "$state") held=$(jq -r .held_total "$state")" \
  "a successful check records the numbers the badge is about to show"
assert_eq "$(grep -c '' "$EV")" "1" "...as exactly one line"

# ==================================================================================================
# A run, end to end.
# ==================================================================================================
: > "$EV"
"$KEMPT" config set surface background >/dev/null
"$KEMPT" config set auto_accept true >/dev/null
: > "$EV"
assert_exit 0 "a successful background run exits 0" "$KEMPT" update
assert_eq "$(events | grep -c '^.* run start ')" "1" "...recording exactly one run start"
assert_eq "$(text_of "$(events | grep ' run start ' | tail -1)")" "run start surface=background" \
  "...which names the surface it ran on"
hist="$(ls -1t "$KEMPT_STATE_DIR/history"/*.json | head -1)"
assert_eq "$(text_of "$(events | grep ' run done ' | tail -1)")" \
  "run done rc=0 updated=$(jq -r '[.backends[].updated | length] | add' "$hist") reboot=needed" \
  "...and one run done carrying the update count and the reboot verdict"
export KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no"
: > "$EV"
"$KEMPT" update >/dev/null
assert_eq "$(text_of "$(events | grep ' run done ' | tail -1)")" \
  "run done rc=0 updated=0 reboot=no" "a run that changed nothing says so, reboot verdict and all"
export KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-yes"

# ==================================================================================================
# Staging, and the reboot that applies it.
# ==================================================================================================
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
"$KEMPT" check >/dev/null
pending="$(jq -r '.backends.dnf.actionable' "$state")"
: > "$EV"
"$KEMPT" update --surface=offline >/dev/null
assert_eq "$(text_of "$(events | grep ' offline staged ' | tail -1)")" "offline staged $pending" \
  "a staged run records the count the check it was made from reported"
assert_eq "$(events_like ' run done ')" "0" \
  "...and NOT run done: nothing has been applied, the reboot will do that"

# A staged transaction can only be applied by a reboot, and the marker records the boot session it
# was staged in. Rewriting that field is the only way a test can say "the machine rebooted".
jq '.boot_id = "00000000-0000-0000-0000-000000000000"' "$KEMPT_STATE_DIR/offline_staged.json" \
  > "$TESTTMP/m.json" && mv "$TESTTMP/m.json" "$KEMPT_STATE_DIR/offline_staged.json"
cp "$FIXTURES/snap-after.tsv" "$WORLD/rpm.tsv"     # the transaction applied during boot
: > "$EV"
"$KEMPT" check >/dev/null
assert_eq "$(events_like '^.* harvest applied ')" "1" \
  "the check after the reboot harvests it, and says so once"
harvest_hist="$(ls -1t "$KEMPT_STATE_DIR/history"/*.json | head -1)"
assert_eq "$(text_of "$(events | grep ' harvest applied ' | tail -1)")" \
  "harvest applied ($(bash -c "source '$REPO_ROOT/lib/common.sh'; run_counts_phrase '$harvest_hist'"))" \
  "...carrying the same counts phrase the notification carries"

# A marker whose snapshot has been deleted can never be harvested. Clearing it is the right
# outcome, and it is worth a line: it is the only trace a staged transaction ever left.
printf '{"staged_at":"x","pre_snapshot":"/nonexistent/gone.tsv","boot_id":"stale"}' \
  > "$KEMPT_STATE_DIR/offline_staged.json"
: > "$EV"
"$KEMPT" check >/dev/null
assert_eq "$(events_like ' harvest cleared stale marker')" "1" \
  "a marker pointing at a snapshot that is gone is cleared, and recorded as cleared"

# ==================================================================================================
# A refused authentication, all the way through.
#
# pkexec's own words - "Error executing command as another user: Not authorized" - read as a
# broken installation. What happened is that somebody closed the dialog. The mapping is one
# helper, so every surface that renders a failure says the same friendly sentence, and the raw
# text stays in the run log for whoever needs it.
# ==================================================================================================
FRIENDLY="authentication declined or cancelled"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
export KEMPT_APPLY_HELPER="$TESTTMP/apply-declined"
: > "$EV"; : > "$WORLD/notifications"
# --no-flatpak so exactly one privileged call is made, and the counts below are exact.
assert_exit 1 "a run whose authentication was refused exits 1" "$KEMPT" update --no-flatpak
assert_eq "$(text_of "$(events | grep ' run failed ' | tail -1)")" "run failed rc=1: $FRIENDLY" \
  "the event line says it in plain words, with the run's own exit status"
runlog="$(ls -1t "$KEMPT_STATE_DIR/logs"/*.log | head -1)"
assert_eq "$(grep -c 'Not authorized' "$runlog")" "1" \
  "...while the raw pkexec text is kept, in the run log where it belongs"
assert_eq "$(grep -c "$FRIENDLY" "$runlog")" "0" \
  "...which is not rewritten: the log is evidence, not a summary"
failhist="$(ls -1t "$KEMPT_STATE_DIR/history"/*.json | head -1)"
assert_eq "$(jq -r '.error' "$failhist")" "$FRIENDLY" "the history entry carries the same sentence"
assert_eq "$(grep -c "FAILED - see .* ($FRIENDLY)" <<<"$("$KEMPT" summary)")" "1" \
  "...so the summary explains the failure instead of pointing at a log file"
assert_eq "$(grep -c "($FRIENDLY)" <<<"$("$KEMPT" history)")" "1" \
  "...and so does the history listing"
assert_eq "$(grep -c "Update FAILED ($FRIENDLY)" "$WORLD/notifications")" "1" \
  "...and the notification, which is the only one of these a detached run's user sees"
export KEMPT_APPLY_HELPER="$TESTTMP/apply-stub"

# The same mapping on the check path, where it lands in state.json for the widget to render.
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-declined"
: > "$EV"
"$KEMPT" check >/dev/null
assert_eq "$(jq -r '.status' "$state")" "stale" "a check whose authentication was refused is stale"
assert_eq "$(jq -r '.error' "$state")" "dnf check failed: $FRIENDLY" \
  "...and state.json names the backend and then says it in plain words"
assert_eq "$(text_of "$(last_event)")" "check stale dnf check failed: $FRIENDLY" \
  "...with the event line carrying exactly the same reason"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"

# ==================================================================================================
# The metadata refresh is its own step, because its failure is invisible everywhere else: the
# check that follows carries on against the cached metadata and reports "ok".
# ==================================================================================================
unset KEMPT_SKIP_REFRESH
: > "$EV"
"$KEMPT" check >/dev/null
assert_eq "$(events_like ' refresh ok')" "1" "a metadata refresh that worked is recorded"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-declined"
rm -f "$KEMPT_STATE_DIR/last_refresh"     # the 3h window, reopened
: > "$EV"
"$KEMPT" check >/dev/null 2>&1 || true
assert_eq "$(events_like ' refresh failed')" "1" "...and one that did not is recorded too"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_SKIP_REFRESH=1

# ==================================================================================================
# The passwordless grant: the setting with the largest security consequence Kempt can change, and
# the only one that used to leave no trace of having been attempted.
# ==================================================================================================
: > "$EV"
# `install -o root` cannot succeed as an ordinary user, which is the realistic unprivileged
# outcome and exactly what the rc in the line is for.
assert_exit 1 "enable-passwordless fails unprivileged" \
  env KEMPT_RULES_DST="$TESTTMP/pw.rules" "$KEMPT" enable-passwordless
assert_eq "$(text_of "$(last_event)")" "passwordless enable rc=1" \
  "...and the attempt is recorded with the exit status it ended on"
: > "$EV"
assert_exit 0 "disabling something never enabled is a clean no-op" \
  env KEMPT_RULES_DST="$TESTTMP/pw.rules" "$KEMPT" disable-passwordless
assert_eq "$(text_of "$(last_event)")" "passwordless disable rc=0" "...and is recorded as rc 0"

# ==================================================================================================
# kempt log itself.
# ==================================================================================================
: > "$EV"
for i in $(seq 1 40); do "$KEMPT" config set surface "s$i" >/dev/null; done
assert_eq "$("$KEMPT" log | wc -l)" "30" "kempt log shows the last 30 by default"
assert_eq "$("$KEMPT" log -n 5 | wc -l)" "5" "-n takes a count"
assert_eq "$(text_of "$("$KEMPT" log -n 1)")" "config set surface=s40 (was s39)" \
  "...counting back from the newest, which is printed last"
assert_eq "$("$KEMPT" log -n 500 | wc -l)" "40" "asking for more than exist shows all of them"
assert_exit 2 "a zero count is a usage error" "$KEMPT" log -n 0
assert_exit 2 "so is a non-numeric one" "$KEMPT" log -n five
assert_exit 2 "so is -n with nothing after it" "$KEMPT" log -n
assert_exit 2 "and so is an unknown option" "$KEMPT" log --since=yesterday
: > "$EV"
assert_eq "$("$KEMPT" log)" "No events recorded yet." "an empty file reads the same as no file"

# ==================================================================================================
# Retention. Nothing else ever deletes from this file, and the widget checks on a timer.
# ==================================================================================================
: > "$EV"
for i in $(seq 1 2500); do printf '2026-01-01T00:00:00+00:00 cli seed %s\n' "$i"; done >> "$EV"
"$KEMPT" config set surface popup >/dev/null      # the 2501st line
assert_eq "$(grep -c '' "$EV")" "2000" "past 2500 lines the file is rewritten to the last 2000"
assert_eq "$(text_of "$(head -1 "$EV")")" "seed 502" "...keeping the NEWEST 2000, oldest first"
assert_eq "$(text_of "$(last_event)")" "config set surface=popup (was s40)" \
  "...with the event that tripped it still at the end"
assert_eq "$(stat -c %a "$EV")" "600" "...and the rewrite keeps the file 0600"
# One line under the threshold nothing moves: the rewrite runs once every 500 events, not on
# every append.
: > "$EV"
for i in $(seq 1 2400); do printf '2026-01-01T00:00:00+00:00 cli seed %s\n' "$i"; done >> "$EV"
"$KEMPT" config set surface background >/dev/null
assert_eq "$(grep -c '' "$EV")" "2401" "below the threshold the file is left exactly as it is"

# ==================================================================================================
# Best-effort, and that is a contract. A log line is never worth changing the exit status of the
# command that emitted it, and a state directory nobody can write is not an error to report on
# every command for the rest of time.
# ==================================================================================================
# The file is removed first on purpose. A directory at mode 500 still allows an APPEND to a file
# that already exists inside it - write permission on a directory governs creating and deleting
# entries, not writing to them - so leaving the file in place would have tested nothing.
rm -f "$EV"
chmod 500 "$KEMPT_STATE_DIR"
assert_exit 0 "a config write still succeeds when the event log cannot be written" \
  "$KEMPT" config set surface terminal
assert_eq "$(cat "$TESTTMP/last_output")" "" "...silently: no warning, no stderr noise"
assert_exit 0 "...and nothing was created in a directory that refused it" -- test ! -e "$EV"
chmod 700 "$KEMPT_STATE_DIR"
assert_eq "$("$KEMPT" config get surface)" "terminal" "...while the write it was logging landed"

# ==================================================================================================
# doctor ends with the last five events, because "is this install sound?" is followed by "then
# why did my change not take effect?" and the answer is right there.
# ==================================================================================================
: > "$EV"
out="$("$KEMPT" doctor 2>&1 || true)"
assert_eq "$(grep -c 'Recent events (kempt log):' <<<"$out")" "1" "doctor has a Recent events section"
assert_eq "$(grep -cE '^  none$' <<<"$out")" "1" "...which says none when there are none"
for i in $(seq 1 8); do "$KEMPT" config set surface "d$i" >/dev/null; done
out="$("$KEMPT" doctor 2>&1 || true)"
assert_eq "$(sed -n '/Recent events/,$p' <<<"$out" | grep -c '^  2[0-9][0-9][0-9]-')" "5" \
  "...and the last five when there are more"
assert_eq "$(grep -c '^  .* config set surface=d8 (was d7)$' <<<"$out")" "1" \
  "...ending on the newest one"
assert_eq "$(grep -c '^FAIL' <<<"$out")" "0" "...and the section cannot be mistaken for a report line"

finish
