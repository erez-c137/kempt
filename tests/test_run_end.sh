#!/usr/bin/env bash
# How a run ends, as the widget sees it. The widget leaves its busy pane on the first state.json
# write after a run starts, so that write has to carry the fresh list. A write of the pre-run items
# showed the old list and badge again until the closing check landed, six seconds later.
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"

export WORLD="$TESTTMP/world"; mkdir -p "$WORLD" "$TESTTMP/shim" "$TESTTMP/writes"
TL="$WORLD/timeline"
real_mv="$(command -v mv)"
# Every state.json write goes through atomic_write's mv: keep a copy and its place in the timeline.
cat > "$TESTTMP/shim/mv" <<STUB
#!/usr/bin/env bash
if [[ "\${2:-}" == "$KEMPT_STATE_DIR/state.json" ]]; then
  n=\$(( \$(grep -c '^WRITE' "$TL" 2>/dev/null || true) + 1 ))
  cp "\$1" "$TESTTMP/writes/\$n.json"
  echo "WRITE \$n hist=\$(ls -1 "$KEMPT_STATE_DIR/history" 2>/dev/null | wc -l)" >> "$TL"
fi
exec "$real_mv" "\$@"
STUB
chmod +x "$TESTTMP/shim/mv"
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
case "\$1" in
  dnf-upgrade) cp "$FIXTURES/snap-after.tsv" "$WORLD/rpm.tsv"; touch "$WORLD/applied"
               [[ -f "$WORLD/apply-fails" ]] && exit 1 ;;
  dnf-offline-stage) touch "$WORLD/staged" ;;
esac
exit 0
STUB
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == check ]]; then
  [[ -f "$WORLD/applied" ]] && exit 0
  cat "$FIXTURES/dnf-check-update.txt"; exit 100
fi
echo "FETCH \$*" >> "$TL"
exit 0
STUB
printf '#!/usr/bin/env bash\necho "NOTIFY $*" >> "%s"\n' "$TL" > "$TESTTMP/notify-stub"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"
chmod +x "$TESTTMP/apply-stub" "$TESTTMP/refresh-stub" "$TESTTMP/notify-stub" "$TESTTMP/dnf-reboot-no"
export KEMPT_APPLY_HELPER="$TESTTMP/apply-stub" KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_NOTIFY="$TESTTMP/notify-stub" KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no"
export KEMPT_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv" KEMPT_SKIP_REFRESH=1
export KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml"
"$KEMPT" config set include_flatpak false >/dev/null

fresh_world() {  # a box with updates pending and a state file that lists them
  rm -f "$WORLD/applied" "$WORLD/apply-fails" "$WORLD/staged" "$TL" "$TESTTMP"/writes/*.json
  rm -f "$KEMPT_STATE_DIR"/history/*.json
  cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
  "$KEMPT" check >/dev/null 2>&1
  PRE="$(jq -r .actionable "$KEMPT_STATE_DIR/state.json")"
  # Long before the run, so a stamp can only be at its finish if a check made it there.
  jq -c '.last_check = "2026-01-01T00:00:00+00:00"' "$KEMPT_STATE_DIR/state.json" > "$WORLD/st"
  cat "$WORLD/st" > "$KEMPT_STATE_DIR/state.json"
}
run() { PATH="$TESTTMP/shim:$PATH" "$KEMPT" update --no-flatpak "$@" >"$WORLD/out" 2>&1 || true; }
first_write() { grep -m1 -E '^WRITE [0-9]+ hist=[1-9]' "$TL" | cut -d' ' -f2; }    # after the entry
line_of() { grep -n -m1 -E "$1" "$TL" | cut -d: -f1; }

# --- the ordinary run ----------------------------------------------------------------------------
fresh_world
assert_eq "$([[ "$PRE" -gt 0 ]] && echo yes)" "yes" "fixture guard: updates are pending before the run"
run --surface=widget
n="$(first_write)"
assert_eq "$(jq -r .actionable "$TESTTMP/writes/$n.json")" "0" \
  "the first write after the run's history entry leaves out what was just installed"
assert_eq "$(jq -r '.backends.dnf.items | length' "$TESTTMP/writes/$n.json")" "0" "...in the list as well as the count"
entry="$(ls -1 "$KEMPT_STATE_DIR"/history/*.json | tail -1)"
assert_eq "$(( $(date -d "$(jq -r .last_check "$TESTTMP/writes/$n.json")" +%s) >= $(stat -c %Y "$entry") ))" "1" \
  "...and it is stamped at or after the run's finish"
assert_eq "$(( $(line_of "^WRITE $n ") < $(line_of '^NOTIFY') ))" "1" "the notification comes after that write"
assert_eq "$(sed -n "$(( $(line_of '^NOTIFY') - 1 ))p" "$TL" | cut -d' ' -f1)" "WRITE" \
  "...and the end signal is still written just before it"
assert_eq "$(grep -c '^NOTIFY' "$TL")" "1" "one notification"
assert_eq "$(grep -c 'Checked:' <(tail -n 3 "$KEMPT_STATE_DIR/events.log"))" "1" "one closing check"

# --- a closing check that writes nothing ---------------------------------------------------------
# Another check holds the lock for the whole run, so the end signal is the only write there is.
fresh_world
( flock 9; sleep 8 ) 9>"$KEMPT_STATE_DIR/check.lock" &
holder=$!
for _i in $(seq 1 100); do flock -n "$KEMPT_STATE_DIR/check.lock" true 2>/dev/null || break; sleep 0.02; done
KEMPT_CHECK_LOCK_WAIT=0 run --surface=widget
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
n="$(first_write)"
assert_eq "$([[ -n "$n" ]] && echo written)" "written" "a closing check that cannot run still leaves the end-signal write"
assert_eq "$(( $(line_of "^WRITE $n ") < $(line_of '^NOTIFY') ))" "1" "...before the notification"

# A check that is busy for a moment: the person is told at once, and the list still comes right.
fresh_world
( flock 9; sleep 2 ) 9>"$KEMPT_STATE_DIR/check.lock" &
holder=$!
for _i in $(seq 1 100); do flock -n "$KEMPT_STATE_DIR/check.lock" true 2>/dev/null || break; sleep 0.02; done
run --surface=widget
wait "$holder" 2>/dev/null || true
assert_eq "$(sed -n "$(( $(line_of '^NOTIFY') + 1 ))p" "$TL" | cut -d' ' -f1)" "WRITE" \
  "a busy check lock does not hold the notification back: the closing check runs after it"
assert_eq "$(jq -r .actionable "$KEMPT_STATE_DIR/state.json")" "0" "...and the list is right when the run ends"

# --- the closing check downloads nothing ---------------------------------------------------------
# A fetch takes minutes on a slow mirror, and the person is waiting for the result.
fresh_world
rm -f "$KEMPT_STATE_DIR/last-refresh"* 2>/dev/null
env -u KEMPT_SKIP_REFRESH KEMPT_ON_BATTERY_CMD=false PATH="$TESTTMP/shim:$PATH" \
  "$KEMPT" update --no-flatpak --surface=widget >/dev/null 2>&1 || true
assert_eq "$(grep -c '^FETCH' "$TL" || true)" "0" "the closing check does not fetch package lists"
assert_eq "$(jq -r '.refresh_skipped // "absent"' "$KEMPT_STATE_DIR/state.json")" "absent" \
  "...and does not report a fetch as skipped"

# --- a failed run and a stage end the same way ----------------------------------------------------
fresh_world
touch "$WORLD/apply-fails"
run --surface=widget
n="$(first_write)"
assert_eq "$(( $(line_of "^WRITE $n ") < $(line_of '^NOTIFY') ))" "1" "a failed run: the state moves before the notification"
assert_contains "$(grep '^NOTIFY' "$TL")" "Update failed" "...which says it failed"
assert_eq "$(jq -r .status "$(ls -1 "$KEMPT_STATE_DIR"/history/*.json | tail -1)")" "failed" "...and so does the entry"

fresh_world
export KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" KEMPT_OFFLINE_LINK="$TESTTMP/system-update"
run --surface=offline
n="$(first_write)"
assert_eq "$(( $(line_of "^WRITE $n ") < $(line_of '^NOTIFY') ))" "1" "a stage: the state moves before the notification"
assert_eq "$(jq -r '.offline_staged.armed // "absent"' "$KEMPT_STATE_DIR/state.json")" "true" "...and the state holds the stage"
assert_contains "$(grep '^NOTIFY' "$TL")" "Updates are ready and install on the next restart" "...and the notification says so"
export KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml"; unset KEMPT_OFFLINE_LINK

# --- at a terminal -------------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  fresh_world
  python3 -c 'import os, pty, sys
out = open(sys.argv[1], "wb")
def read(fd):
    data = os.read(fd, 65536)
    out.write(data)
    return data
pty.spawn(sys.argv[2:], read)' "$WORLD/tty" "$KEMPT" update --no-flatpak --surface=widget --answered >/dev/null 2>&1 </dev/null || true
  tty_out="$(tr -d '\r' < "$WORLD/tty")"
  at="$(grep -n -m1 'Checking for anything left to update' <<<"$tty_out" | cut -d: -f1 || true)"
  assert_eq "$([[ -n "$at" ]] && echo told)" "told" "a terminal is told what the pause is"
  assert_contains "$(tail -n +"${at:-1}" <<<"$tty_out")" "updated" "...and the summary still prints after it"
else
  skip "python3 is absent, so the terminal half of a run's end was NOT checked"
fi

finish
