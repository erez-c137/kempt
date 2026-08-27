#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
KEMPT="$REPO_ROOT/bin/kempt"

# stubs: dnf helper serves fixture; flatpak served via cmd overrides
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
case "\$1" in
  check) cat "$FIXTURES/dnf-check-update.txt"; exit 100 ;;
  refresh) echo refreshed >> "$TESTTMP/refresh-calls"; exit 0 ;;
esac
STUB
chmod +x "$TESTTMP/refresh-stub"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"

# The flatpak refresh arm is unprivileged, so it has no root helper to stub - it goes through its
# own command seam. Recorded rather than run: the real command fetches flathub's summary index,
# and a test suite may not depend on flathub being reachable. The stub is NAMED for flatpak so the
# pkexec recorder below can prove, by grep, that this command never went near an escalation.
cat > "$TESTTMP/flatpak-refresh-stub" <<STUB
#!/usr/bin/env bash
echo fetched >> "$TESTTMP/flatpak-refresh-calls"
STUB
chmod +x "$TESTTMP/flatpak-refresh-stub"
export KEMPT_FLATPAK_REFRESH_CMD="$TESTTMP/flatpak-refresh-stub"
# How many summary fetches have been attempted. A helper, not `wc -l` inline, because the file does
# not exist until the FIRST fetch: a bare redirect failure there prints a shell error and yields an
# empty count, which reads as a broken test rather than as the honest answer "none yet".
fp_fetches() {
  if [[ -f "$TESTTMP/flatpak-refresh-calls" ]]; then wc -l < "$TESTTMP/flatpak-refresh-calls"; else echo 0; fi
}

# A dnf refresh helper that still serves the check fixture but fails the refresh verb. The two arms
# have to be driveable independently, or "one failed, one worked" cannot be tested at all.
cat > "$TESTTMP/refresh-dnf-fails" <<STUB
#!/usr/bin/env bash
case "\$1" in
  check) cat "$FIXTURES/dnf-check-update.txt"; exit 100 ;;
  refresh) exit 1 ;;
esac
STUB
chmod +x "$TESTTMP/refresh-dnf-fails"

# KEMPT_PKEXEC is empty in the sandbox, so nothing normally records what WOULD have been escalated.
# This stub does, and then runs the command anyway, which is what lets a test assert a negative
# about the privilege boundary rather than just trusting the source.
cat > "$TESTTMP/pkexec-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TESTTMP/pkexec-calls"
exec "\$@"
STUB
chmod +x "$TESTTMP/pkexec-stub"
export KEMPT_DNF_INSTALLED_CMD="cat $FIXTURES/rpm-installed.tsv"
export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export KEMPT_FLATPAK_LIST_CMD="cat $FIXTURES/flatpak-list.tsv"
export KEMPT_SKIP_REFRESH=1   # deterministic: no metadata refresh attempts in tests

# cmd_check asks the backend whether a restart is owed, and sandbox() unsets KEMPT_DNF_CMD - so
# without a stub every `kempt check` below would shell out to the REAL dnf5 on whatever box is
# running the suite. That is slow, and worse, its answer depends on whether that box happens to
# be owed a restart today, which is not something a test may depend on. Default here is "no";
# the block at the bottom drives both verdicts deliberately. rc 1 PLUS the package list on
# stdout is the real command's "yes" shape (see dnf_reboot_needed).
write_reboot_stub "$TESTTMP/dnf-reboot-yes"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"
chmod +x "$TESTTMP/dnf-reboot-no"
export KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no"

# Fixture contracts (tests/fixtures/MANIFEST.md): dnf parses to 7 items, flatpak to 3.
n_dnf=7
n_fp=3

# config defaults come from the kempt_default table, so an unset key answers with the real
# default instead of an empty string (fresh sandbox: no config file has been written yet)
assert_eq "$("$KEMPT" config get surface)" "terminal" "unset key falls back to the defaults table"
assert_eq "$("$KEMPT" config get include_flatpak)" "true" "defaults table covers include_flatpak"

state="$("$KEMPT" check)"
assert_eq "$(jq -r .status <<<"$state")" "ok" "status ok"
assert_eq "$(jq -r .schema <<<"$state")" "1" "state schema v1"
assert_eq "$(jq '.backends.dnf.items | length' <<<"$state")" "$n_dnf" "dnf items in state"
assert_eq "$(jq '.backends.flatpak.items | length' <<<"$state")" "$n_fp" "flatpak items in state"
assert_eq "$(jq .actionable <<<"$state")" "$((n_dnf + n_fp))" "actionable = all when no holds"
assert_eq "$(jq -r '.last_success == .last_check' <<<"$state")" "true" "a successful check stamps last_success"
assert_eq "$(jq -Sc . "$KEMPT_STATE_DIR/state.json")" "$(jq -Sc . <<<"$state")" "state persisted atomically"

# holds: hold the first pending dnf package → actionable drops by 1, held_total=1
first="$(jq -r '.backends.dnf.items[0].name' <<<"$state")"
"$KEMPT" hold "dnf:$first"
state2="$("$KEMPT" check)"
assert_eq "$(jq .held_total <<<"$state2")" "1" "held_total counts the hold"
assert_eq "$(jq .actionable <<<"$state2")" "$((n_dnf + n_fp - 1))" "badge count excludes held"
assert_eq "$(jq .backends.dnf.actionable <<<"$state2")" "$((n_dnf - 1))" "per-backend actionable excludes held"
assert_eq "$(jq .backends.dnf.held <<<"$state2")" "1" "per-backend held count"

# include_flatpak=false → flatpak absent, and SAID to be disabled rather than merely empty
"$KEMPT" config set include_flatpak false
state3="$("$KEMPT" check)"
assert_eq "$(jq '.backends.flatpak.items | length' <<<"$state3")" "0" "flatpak disabled"
assert_eq "$(jq -r .backends.flatpak.enabled <<<"$state3")" "false" "disabled flatpak is flagged, not just empty"
assert_eq "$(jq -r .backends.dnf.enabled <<<"$state3")" "true" "dnf stays enabled"

# dnf failure → stale, previous counts kept, last_success frozen at the last real success
cat > "$TESTTMP/refresh-stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
state4="$("$KEMPT" check)"
assert_eq "$(jq -r .status <<<"$state4")" "stale" "check failure → stale"
assert_eq "$(jq '.backends.dnf.items | length' <<<"$state4")" "$(jq '.backends.dnf.items | length' <<<"$state2")" "stale keeps previous dnf items"
assert_eq "$(jq -r .last_success <<<"$state4")" "$(jq -r .last_success <<<"$state3")" "stale preserves the previous last_success"
assert_eq "$(jq -r '.last_success != null' <<<"$state4")" "true" "preserved last_success is non-null"
assert_eq "$(jq -r '.error | startswith("dnf check failed")' <<<"$state4")" "true" "stale error names the failing backend"

# unhold rejects unknown backends exactly like hold does (a typo must never silently no-op)
assert_exit 2 "unhold validates backend" "$KEMPT" unhold apt:foo

# Corrupt state recovery. state.json is the fallback a failing check leans on, so a damaged one
# used to take the whole check down with it: a truncated file fed "" to --argjson (rc 2), a
# wrong-shaped .items fed a STRING into an array concat (rc 5). Every shape must degrade to [].
# (dnf stub is still the failing one from the stale section above - that is the point.)
# The multi-doc shape carries last_success in BOTH documents on purpose: a per-document read
# concatenates them into one newline-joined string that reaches the widget as "Invalid Date".
for corrupt in '' 'garbage' '{"backends":{"dnf":{"items":"nope"}}}' '{"last_success":"2020-01-01T00:00:00+00:00"}{"last_success":"2021-01-01T00:00:00+00:00"}'; do
  shape="${corrupt:-<empty file>}"
  printf '%s' "$corrupt" > "$KEMPT_STATE_DIR/state.json"
  rc=0; out="$("$KEMPT" check 2>/dev/null)" || rc=$?
  assert_eq "$rc" "0" "corrupt state ($shape) → check still exits 0"
  assert_eq "$(jq -r .status <<<"$out")" "stale" "corrupt state ($shape) → stale"
  assert_eq "$(jq -c '.backends.dnf.items' <<<"$out")" "[]" "corrupt state ($shape) → no fabricated items"
  assert_eq "$(jq -r '(.last_success // "") | contains("\n")' <<<"$out")" "false" "corrupt state ($shape) → last_success is a single value"
done

# Concurrency: the widget guarantees overlapping checks (timer + event watch + post-run check).
# A fixed tmp name in write_state made them race - one process's mv stole another's tmp file and
# the loser died with "mv: cannot stat" (measured: 19/80 non-zero). Restore the working stub
# first; the stale section above left it exiting 1.
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
case "\$1" in
  check) cat "$FIXTURES/dnf-check-update.txt"; exit 100 ;;
  refresh) echo refreshed >> "$TESTTMP/refresh-calls"; exit 0 ;;
esac
STUB
chmod +x "$TESTTMP/refresh-stub"
rm -f "$TESTTMP"/conc-rc.*
for i in 1 2 3 4 5 6 7 8 9 10; do
  ( rc=0; "$KEMPT" check >/dev/null 2>&1 || rc=$?; printf '%s\n' "$rc" > "$TESTTMP/conc-rc.$i" ) &
done
wait
# comma-joins the DISTINCT exit codes seen, so a failure names the rc instead of just a count
assert_eq "$(sort -u "$TESTTMP"/conc-rc.* | paste -sd, -)" "0" "concurrent checks never collide"
assert_exit 0 "state intact after concurrent writes" -- jq -e .actionable "$KEMPT_STATE_DIR/state.json"
# guards the vacuous pass: 10 runs that all serve a cached stale state would satisfy the rc
# assertion above while proving nothing about the write path
assert_eq "$(jq -r .status "$KEMPT_STATE_DIR/state.json")" "ok" "concurrent block ends in real ok state"

# Serialization, not just collision-freedom: without the check lock the last FINISHER wins, so a
# slow check that started earlier lands ON TOP of a newer, faster one and the widget shows a
# pending count that was already obsolete when it was written. Slow serves 7 pending; fast serves
# zero pending and starts later - the only correct final state is the fast one's.
cat > "$TESTTMP/slow-stub" <<STUB
#!/usr/bin/env bash
case "\$1" in
  check) sleep 2; cat "$FIXTURES/dnf-check-update.txt"; exit 100 ;;
esac
STUB
cat > "$TESTTMP/fast-stub" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  check) exit 0 ;;   # zero pending: dnf5 exits 0 with no output
esac
STUB
chmod +x "$TESTTMP/slow-stub" "$TESTTMP/fast-stub"
KEMPT_REFRESH_HELPER="$TESTTMP/slow-stub" "$KEMPT" check >/dev/null 2>&1 &
slow_pid=$!
sleep 0.5
KEMPT_REFRESH_HELPER="$TESTTMP/fast-stub" "$KEMPT" check >/dev/null 2>&1
wait "$slow_pid" || true
assert_eq "$(jq .backends.dnf.actionable "$KEMPT_STATE_DIR/state.json")" "0" "a slow in-flight check cannot overwrite a newer result"

# --- metadata refresh gating: the only place maybe_refresh_metadata actually runs ---
# on_battery/metered_connection read real hardware and have no seam, so skip rather than fail
# on a laptop that happens to be unplugged or on a metered link.
unset KEMPT_SKIP_REFRESH
# include_flatpak has been false since the disabled-backend section above, and the flatpak arm of
# the refresh is gated on it - so switch it back on, or every assertion below about that arm would
# pass for the wrong reason.
"$KEMPT" config set include_flatpak true >/dev/null
if on_battery || metered_connection; then
  echo "ok: refresh gating skipped (box is on battery or on a metered link)"
else
  rm -f "$LAST_REFRESH_FILE" "$TESTTMP/refresh-calls" "$TESTTMP/flatpak-refresh-calls" \
        "$TESTTMP/pkexec-calls"
  "$KEMPT" check >/dev/null
  assert_eq "$(wc -l < "$TESTTMP/refresh-calls")" "1" "cold check refreshes metadata once"
  assert_exit 0 "cold refresh stamps last_refresh" -- test -f "$LAST_REFRESH_FILE"
  "$KEMPT" check >/dev/null
  assert_eq "$(wc -l < "$TESTTMP/refresh-calls")" "1" "a second check inside the 3h window does not refresh"
  touch -d '4 hours ago' "$LAST_REFRESH_FILE"
  "$KEMPT" check >/dev/null
  assert_eq "$(wc -l < "$TESTTMP/refresh-calls")" "2" "refresh resumes once the 3h window lapses"

  # Both backends are refresh-then-read-cache, and they ride ONE gate. A second gate would be a
  # second interval, a second battery rule and a second timestamp to keep in step with this one -
  # three more ways for a box to quietly stop fetching half its metadata.
  assert_eq "$(fp_fetches)" "2" "the flatpak summary rides the same gate, fetch for fetch"

  # Unprivileged, and that is the whole point: the SYSTEM remote's summary as an ordinary user sees
  # it is cached under that user's own ~/.cache/flatpak, so root buys nothing here. pkexec seeing a
  # flatpak command would mean a new privileged surface nobody reviewed.
  touch -d '4 hours ago' "$LAST_REFRESH_FILE"
  KEMPT_PKEXEC="$TESTTMP/pkexec-stub" "$KEMPT" check >/dev/null
  assert_eq "$(fp_fetches)" "3" "the summary is still fetched with pkexec in play"
  # Guards the vacuous pass: an empty log would satisfy the grep below while proving nothing.
  assert_exit 0 "...and the pkexec recorder really was in the path" -- test -s "$TESTTMP/pkexec-calls"
  assert_eq "$(grep -c flatpak "$TESTTMP/pkexec-calls" || true)" "0" \
    "the flatpak refresh never goes through pkexec"

  # A backend the user switched off must not cost them a fetch. Metadata for something that will
  # never be checked is network nobody asked for, on the one path whose whole job is to be careful
  # with it.
  "$KEMPT" config set include_flatpak false >/dev/null
  touch -d '4 hours ago' "$LAST_REFRESH_FILE"
  "$KEMPT" check >/dev/null
  assert_eq "$(fp_fetches)" "3" "include_flatpak=false fetches no flatpak summary"
  "$KEMPT" config set include_flatpak true >/dev/null

  # The marker rate-limits the NETWORK step, so ANY arm succeeding stamps it. Stamping only on a
  # clean sweep would re-fetch a summary that had just been fetched on the very next check, for as
  # long as one dnf repo stayed broken.
  rm -f "$LAST_REFRESH_FILE"
  KEMPT_REFRESH_HELPER="$TESTTMP/refresh-dnf-fails" "$KEMPT" check >/dev/null
  assert_eq "$(fp_fetches)" "4" "a failed dnf arm does not stop the flatpak one"
  assert_exit 0 "one arm succeeding stamps last_refresh" -- test -f "$LAST_REFRESH_FILE"

  # ...and nothing fetched means nothing to rate-limit, so the window has to stay open.
  rm -f "$LAST_REFRESH_FILE"
  KEMPT_REFRESH_HELPER="$TESTTMP/refresh-dnf-fails" KEMPT_FLATPAK_REFRESH_CMD=false \
    "$KEMPT" check >/dev/null
  assert_exit 1 "both arms failing leaves the window open" -- test -f "$LAST_REFRESH_FILE"

  # A refresh failure is never the check's failure. The check carries on against whatever cache it
  # already has, which is the entire reason the fetch and the read are separate steps.
  rm -f "$LAST_REFRESH_FILE"
  assert_exit 0 "a failed flatpak refresh does not fail the check" -- \
    env KEMPT_FLATPAK_REFRESH_CMD=false "$KEMPT" check
fi

# --- risky-transaction detection: the CLI half of the spec's offline recommendation ---
export KEMPT_SKIP_REFRESH=1   # back to deterministic after the gating section above

# risky_names is pure: prefix match on session-critical families, and a HELD package is never
# recommended (the user already said no to it).
_items='[{"name":"kernel-core","held":false},{"name":"qt6-qtbase","held":false},
         {"name":"systemd-libs","held":false},{"name":"vim-common","held":false},
         {"name":"kernel-headers","held":true},{"name":"kf6-kio","held":false}]'
assert_eq "$(risky_names <<<"$_items" | paste -sd, -)" "kernel-core,qt6-qtbase,systemd-libs,kf6-kio" \
  "risky_names matches session-critical families, skips ordinary and held packages"
assert_eq "$(risky_names <<<'[]' | wc -l)" "0" "no items → no recommendation, not an error"

# Build and doc tails are never loaded by the running session, so they cannot break it. Counting
# them turned an ordinary Qt bump into a 168-package "session-critical" scare. kwin can.
_tails='[{"name":"kernel-devel","held":false},{"name":"kernel-headers","held":false},
         {"name":"qt6-qtbase-devel","held":false},{"name":"kf6-kio-doc","held":false},
         {"name":"systemd-rpm-macros","held":false},{"name":"kwin-x11","held":false},
         {"name":"systemd-udev","held":false}]'
assert_eq "$(risky_names <<<"$_tails" | paste -sd, -)" "kwin-x11,systemd-udev" \
  "devel/headers/doc/macros tails are excluded, the session's own packages are not"

# the everyday fixture has nothing session-critical: the key must be present and EMPTY, never absent
state5="$("$KEMPT" check)"
assert_eq "$(jq -c .risky_pending <<<"$state5")" "[]" "risky_pending is published even when empty"
assert_eq "$(jq -r .schema <<<"$state5")" "1" "additive key does not bump the frozen schema"

# a pending kernel IS session-critical, and the widget has to be able to see that
printf 'kernel-core.x86_64   6.15.4-200.fc44   updates\n' > "$TESTTMP/risky-check.txt"
cat > "$TESTTMP/risky-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$TESTTMP/risky-check.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/risky-stub"
state6="$(KEMPT_REFRESH_HELPER="$TESTTMP/risky-stub" "$KEMPT" check)"
assert_eq "$(jq -r '.risky_pending[0]' <<<"$state6")" "kernel-core" "pending session-critical package is flagged"
"$KEMPT" hold dnf:kernel-core
state7="$(KEMPT_REFRESH_HELPER="$TESTTMP/risky-stub" "$KEMPT" check)"
assert_eq "$(jq -c .risky_pending <<<"$state7")" "[]" "holding it stops the recommendation"
"$KEMPT" unhold dnf:kernel-core

# the pattern is a config key, not a hardcode: a box with its own session-critical package can say so
"$KEMPT" config set risky_regex '^bash'
state8="$("$KEMPT" check)"
assert_eq "$(jq -r '.risky_pending[0]' <<<"$state8")" "bash" "risky_regex is configurable"

# --- reboot_needed: a fact about NOW, live in the state file -----------------------------------
# The popup's restart banner reads this key rather than the last run's history entry, because a
# history entry answers a different question: it says a restart was owed WHEN THAT RUN FINISHED.
# It keeps saying so after the user has restarted, and it says nothing at all when the restart is
# owed because of a `sudo dnf5 upgrade` somebody typed in a terminal. The state key is rewritten
# by every check, so it clears itself and it notices updates Kempt did not apply.
rb_no="$("$KEMPT" check)"
assert_eq "$(jq -r '.reboot_needed' <<<"$rb_no")" "false" "a check with no restart owed records false"
rb_yes="$(KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-yes" "$KEMPT" check)"
assert_eq "$(jq -r '.reboot_needed' <<<"$rb_yes")" "true" "...and true when the backend says one is owed"
assert_eq "$(jq -r '.reboot_needed' "$KEMPT_STATE_DIR/state.json")" "true" \
  "...written to the state file, not merely printed"
assert_eq "$(jq -r '.schema' <<<"$rb_yes")" "1" "an additive key does not bump the frozen schema"
# ...and it goes back to false on its own, which is the whole reason it is not read from history.
assert_eq "$(jq -r '.reboot_needed' <<<"$("$KEMPT" check)")" "false" \
  "the next check clears it, the way a real restart would"

# An unusable reboot verdict must not cost the user the whole check. What this stub actually
# drives is the BACKEND's fallback: rc 7 with a line of prose on stdout lands in
# dnf_reboot_needed's `*)` branch, which answers a well-shaped `false` - so what is asserted is
# that the check survives the trip with its pending-updates answer intact.
#
# It is NOT coverage of the shape guard at bin/kempt:70-72. Replacing that guard and its twin in
# cmd_update with `:` leaves this file at 62/62 and test_update at 126/126, because
# dnf_reboot_needed's output alphabet is exactly {true,false} for every rc-and-stdout combination
# there is: no stub reachable through KEMPT_DNF_CMD can put a third value in front of --argjson.
# The guard is a boundary on the backend contract, and reaching it would need a seam that existed
# only for the test.
cat > "$TESTTMP/dnf-weird" <<'STUB'
#!/usr/bin/env bash
echo "no idea"
exit 7
STUB
chmod +x "$TESTTMP/dnf-weird"
rb_weird="$(KEMPT_DNF_CMD="$TESTTMP/dnf-weird" "$KEMPT" check 2>/dev/null)"
assert_eq "$(jq -r '.reboot_needed' <<<"$rb_weird")" "false" \
  "an unusable reboot verdict degrades to false instead of losing the check"
assert_eq "$(jq -r '.status' <<<"$rb_weird")" "ok" "...and the check it rode in on is still ok"
assert_eq "$(jq '.actionable' <<<"$rb_weird")" "$(jq '.actionable' <<<"$rb_no")" \
  "...still carrying exactly the pending items a healthy check reports"

# --- download sizes in the state -----------------------------------------------------------------
# The rule the whole feature turns on: a backend publishes a total only when EVERY non-held item in
# it has a size. A total over the items that happen to be priced looks authoritative and is short
# by however much the rest weigh, and the reader cannot see which ones were left out.
export KEMPT_DNF_SIZES_CMD="cat $FIXTURES/dnf-repoquery-sizes.tsv"
export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls-sizes.tsv"
"$KEMPT" config set include_flatpak true >/dev/null
st="$KEMPT_STATE_DIR/state.json"
# The holds section near the top of this file held $first and never released it, and a held item
# is excluded from these totals - so the numbers below would be this file's history rather than
# the fixture's arithmetic. Released here so the block states its own premises. (That the totals
# moved by exactly that package's 210107 bytes when it was held is itself the exclusion working.)
"$KEMPT" unhold "dnf:$first" >/dev/null

# `brandnew` is pending and has no size row, so dnf is partially covered: no figure anywhere.
"$KEMPT" check >/dev/null
assert_eq "$(jq -r '.backends.dnf.download_bytes // "absent"' "$st")" "absent" \
  "one unpriced item omits that backend's total"
assert_eq "$(jq -r '.download_bytes // "absent"' "$st")" "absent" \
  "...and the top-level total with it"
# The items that DO have sizes still carry them: partial coverage suppresses the total, not the
# per-item facts, so a reader that wants to show a size per row still can.
assert_eq "$(jq '[.backends.dnf.items[] | select(has("size_bytes"))] | length' "$st")" "6" \
  "the priced items keep their own size_bytes"
assert_eq "$(jq -r '.backends.dnf.items[] | select(.name=="brandnew") | has("size_bytes")' "$st")" "false" \
  "and the unpriced one has no size key at all, rather than a zero"
# The multilib sum reaches the item, not just the size table: bash is pending on two arches.
assert_eq "$(jq -r '.backends.dnf.items[] | select(.name=="bash") | .size_bytes' "$st")" "4005217" \
  "a multilib item carries the bytes both arches would download"

# Hold the unpriced item and coverage completes. This is also the "held items are excluded"
# assertion: brandnew is still pending, still in the list, and contributes nothing.
"$KEMPT" hold dnf:brandnew >/dev/null
"$KEMPT" hold flatpak:org.example.NoSize >/dev/null
"$KEMPT" hold flatpak:org.example.Unknown >/dev/null
"$KEMPT" check >/dev/null
assert_eq "$(jq -r '.backends.dnf.download_bytes' "$st")" "11978084" "full coverage publishes a dnf total"
assert_eq "$(jq -r '.backends.flatpak.download_bytes' "$st")" "1299700847" "...and a flatpak one"
assert_eq "$(jq -r '.download_bytes' "$st")" "1311678931" "...and the top level is their sum"
assert_eq "$(jq -r '.backends.dnf.items[] | select(.name=="brandnew") | .held' "$st")" "true" \
  "the held item is still listed as pending"
# The arithmetic, stated once so a future edit cannot quietly change what is being claimed: the
# total is the sum of the two backends and nothing else.
assert_eq "$(jq -r '.download_bytes == (.backends.dnf.download_bytes + .backends.flatpak.download_bytes)' "$st")" \
  "true" "the top-level total is exactly the two backend totals"

# A backend switched off must not suppress the top-level figure: its items will not be fetched
# either, so the total is still complete for the run that would actually happen.
"$KEMPT" config set include_flatpak false >/dev/null
"$KEMPT" check >/dev/null
assert_eq "$(jq -r '.backends.flatpak.download_bytes // "absent"' "$st")" "absent" \
  "a disabled backend gets no total, not a zero"
assert_eq "$(jq -r '.download_bytes' "$st")" "11978084" \
  "...and does not suppress the top-level total either"
"$KEMPT" config set include_flatpak true >/dev/null

# A size query that fails is silence. It must never fail the check, never make it stale, and never
# report a zero - the three ways a nicety could damage the thing it sits on top of.
"$KEMPT" check >/dev/null   # priming: the assertion below is about THIS check's status
assert_exit 0 "a failed size query does not fail the check" -- \
  env KEMPT_DNF_SIZES_CMD=false "$KEMPT" check
KEMPT_DNF_SIZES_CMD=false "$KEMPT" check >/dev/null
assert_eq "$(jq -r .status "$st")" "ok" "...and does not make it stale"
assert_eq "$(jq -r '.download_bytes // "absent"' "$st")" "absent" "...and reports nothing rather than zero"
"$KEMPT" unhold dnf:brandnew >/dev/null
"$KEMPT" unhold flatpak:org.example.NoSize >/dev/null
"$KEMPT" unhold flatpak:org.example.Unknown >/dev/null

# Schema 1 stays schema 1. Every field here is additive, so a reader written before this feature
# sees exactly what it saw before.
assert_eq "$(jq -r .schema "$st")" "1" "the schema is not bumped by an additive field"
finish
