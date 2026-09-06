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

# --- a staged transaction is TWO facts kept in two places, and a check is what reconciles them.
# Kempt's marker says a stage was made and how many updates it covers; dnf5's own
# offline-transaction-state.toml says whether that transaction is still there and still armed.
# Neither is enough alone: the founder's box had a marker whose transaction was sitting at
# download-complete, which installs on no restart at all, and every surface kept describing it as
# a pending install.
toml="$TESTTMP/offline-state.toml"
marker="$KEMPT_STATE_DIR/offline_staged.json"
pre="$KEMPT_STATE_DIR/snapshots/offline-pre-t4.tsv"
# The baseline has to be the snapshot the check itself takes, byte for byte: the harvest decides
# "still pending" with cmp, and a hand-built file would differ for reasons that have nothing to
# do with what is being tested (the fixture goes through sort_name_version and collapse_versions).
snapshot_now() { bash -c 'source "$1/lib/common.sh"; source "$1/backends/dnf.sh"; dnf_snapshot' _ "$REPO_ROOT"; }
stage_marker() {  # boot_id staged-count-or-null → a marker as cmd_update would have written it
  mkdir -p "$KEMPT_STATE_DIR/snapshots"
  snapshot_now > "$pre"
  jq -n --arg snap "$pre" --arg boot "$1" --argjson staged "$2" \
    '{staged_at:"2026-09-02T10:31:00+03:00", pre_snapshot:$snap, boot_id:$boot, staged:$staged, armed:true}' \
    > "$marker"
}
events_since() { grep -c "$1" "$KEMPT_STATE_DIR/events.log" 2>/dev/null || true; }
export KEMPT_BOOT_ID="boot-t4"

# ARMED and pending: the state carries the key, and it carries the count the stage was made with.
export KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml"
stage_marker boot-t4 61
"$KEMPT" check >/dev/null
assert_exit 0 "an armed stage in the same boot is still pending" -- test -f "$marker"
assert_eq "$(jq -r '.offline_staged.armed' "$st")" "true" "the state says a staged install is armed"
assert_eq "$(jq -r '.offline_staged.count' "$st")" "61" "...and how many updates it covers"
assert_eq "$(jq -r '.offline_staged.staged_at' "$st")" "2026-09-02T10:31:00+03:00" "...and when it was staged"
assert_eq "$(jq -r .schema "$st")" "1" "offline_staged is additive: the schema does not move"
# The two fields the widget cannot derive for itself - it reads state.json and cannot stat a file,
# let alone dnf5's. With no dnf hold in place there is nothing to conflict, and the source says the
# emptiness is a FINDING (the transaction was read) rather than an absence of evidence.
assert_eq "$(jq -c '.offline_staged.holds_conflict' "$st")" "[]" "no hold, so nothing conflicts with the stage"
assert_eq "$(jq -r '.offline_staged.names_source' "$st")" "transaction" \
  "...and the empty list is one dnf5's own transaction vouches for"

# A marker written before the count existed still describes a real pending install. null is the
# honest answer - every reader drops the number from the sentence rather than inventing one.
jq 'del(.staged)' "$marker" > "$marker.tmp" && mv "$marker.tmp" "$marker"
"$KEMPT" check >/dev/null
assert_eq "$(jq -r '.offline_staged.count' "$st")" "null" "a marker with no count says null, not a guess"
assert_eq "$(jq -r '.offline_staged.armed' "$st")" "true" "...and is still a pending install"

# THE FOUNDER'S BOX. A transaction that was downloaded and never armed installs on no restart, so
# it is not a pending install and must not be published as one. The marker stays: the stage is
# really there, and `kempt doctor` is where that discrepancy gets explained.
export KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml"
stage_marker boot-t4 61
"$KEMPT" check >/dev/null
assert_eq "$(jq -r '.offline_staged // "absent"' "$st")" "absent" \
  "a stage that was never armed is not advertised as a pending install"
assert_exit 0 "...and its marker is left for the doctor to explain" -- test -f "$marker"

# A stage that VANISHED in this same boot - somebody ran `dnf5 offline clean`, or a supersede
# discarded the transaction and could not remove the marker. Nothing can apply it and no reboot is
# coming to change that, so the marker is cleared here rather than re-read on every check forever.
export KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml"
stage_marker boot-t4 61
"$KEMPT" check >/dev/null
assert_exit 0 "a marker whose transaction is gone is cleared" -- test ! -f "$marker"
assert_exit 0 "...along with the snapshot copy it owned" -- test ! -f "$pre"
assert_eq "$(events_since 'offline marker cleared (stage gone)')" "1" "...and the clearing is recorded"
assert_eq "$(jq -r '.offline_staged // "absent"' "$st")" "absent" "...and nothing is published about it"

# The same emptiness after a REBOOT, with a package set that did not move. Before the toml was
# read this was a dead end: the snapshot comparison said "not applied yet" and the marker waited
# for an apply that had already been thrown away, on every check, forever.
export KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml"
stage_marker boot-before-reboot 61
"$KEMPT" check >/dev/null
assert_exit 0 "a rebooted box with no transaction left stops waiting for it" -- test ! -f "$marker"
assert_eq "$(events_since 'offline marker cleared (stage gone)')" "2" "...and says so the same way"

# ...and the same shape with the transaction STILL THERE and STILL ARMED stays pending, which is
# the whole reason the branch above needs the toml: a reboot that has not yet got round to running
# the transaction must not have its marker thrown away. Armed is TWO things - `ready` and the
# /system-update symlink - so the symlink has to be there for this to be that case.
export KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml"
LIVE_LINK="$TESTTMP/system-update"; ln -sfn "$TESTTMP" "$LIVE_LINK"
export KEMPT_OFFLINE_LINK="$LIVE_LINK"
stage_marker boot-before-reboot 61
"$KEMPT" check >/dev/null
assert_exit 0 "an untouched transaction after a reboot is still pending" -- test -f "$marker"
assert_eq "$(jq -r '.offline_staged.count' "$st")" "61" "...and is still published as one"
export KEMPT_OFFLINE_LINK="$TESTTMP/no-system-update"
rm -f "$marker" "$pre"

# No marker at all: an offline transaction somebody else staged is not Kempt's to announce.
"$KEMPT" check >/dev/null
assert_eq "$(jq -r '.offline_staged // "absent"' "$st")" "absent" \
  "a transaction Kempt did not stage is not published as Kempt's"

# --- the restart that detoured and installed nothing ---------------------------------------------
# The state a failed rebuild leaves behind, seen from the other side of the reboot: the transaction
# is there but is not `ready`, the boot symlink was still standing, so the restart went into the
# offline updater, found nothing it could apply, and came back. Nothing was installed, and nothing
# ever will be from this transaction - only `dnf5 offline reboot` arms one, and nothing is going to
# run that on its own.
#
# The old reconciliation keyed on the toml's PRESENCE alone, so this was silent: the boot changed,
# the package set had not moved, the transaction was still there, and the check said "not applied
# yet" forever. Meanwhile `offline_staged` had already vanished from the state (it is published for
# `ready` and nothing else), so the popup's staged banner disappeared with no explanation at all.
#
# So: announce ONCE, and demote the marker to `armed: false`. Never clear it - the marker is what
# lets `kempt doctor` say this transaction can never install, and without it that row degrades into
# "an offline transaction is staged outside Kempt", which is a misattribution of Kempt's own stage.
notify_log="$TESTTMP/detour-notifications"
cat > "$TESTTMP/notify-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$notify_log"
STUB
chmod +x "$TESTTMP/notify-stub"
# Without cmp on PATH (nocmp_dir): the decision "did the package set move" must not need diffutils.
detour_check() { PATH="$(nocmp_dir):$PATH" KEMPT_NOTIFY="$TESTTMP/notify-stub" "$KEMPT" check >/dev/null; }

export KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml"
stage_marker boot-before-reboot 61
before_marker="$(jq -Sc . "$marker")"
: > "$notify_log"
detour_check
assert_exit 0 "a stage that a restart could not install is not cleared" -- test -f "$marker"
assert_eq "$(cat "$notify_log")" \
  "Kempt Your staged update can no longer install on a restart. Re-stage it, or run sudo dnf5 offline clean." \
  "...the one notification that keeps the banner's disappearance from being silent"
assert_eq "$(events_since 'offline stage cannot install (status download-complete) - announced')" "1" \
  "...and the event log carries the status it was announced for"
assert_eq "$(jq -r '.armed' "$marker")" "false" "...and the marker is demoted rather than deleted"
assert_json_eq "$(jq -c 'del(.armed)' "$marker")" "$(jq -c 'del(.armed)' <<<"$before_marker")" \
  "...with every other field of it kept"
assert_eq "$(jq -r '.offline_staged // "absent"' "$st")" "absent" \
  "...while nothing is published as a pending install, because nothing is"

# Announce-once, keyed on the marker itself. A box checks every ten minutes; a second notification
# would be 144 of them a day about one dead transaction.
after_marker="$(jq -Sc . "$marker")"
: > "$notify_log"
detour_check
assert_eq "$(cat "$notify_log")" "" "the second check says nothing about it again"
assert_eq "$(events_since 'offline stage cannot install (status download-complete) - announced')" "1" \
  "...and records nothing again either"
assert_eq "$(jq -Sc . "$marker")" "$after_marker" "...and leaves the marker exactly as it demoted it"

# Demoted is not the same as gone: the transaction really vanishing still clears the marker, on the
# same branch, by the same rule as ever.
KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml" detour_check
assert_exit 0 "a demoted marker whose transaction then vanishes is still cleared" -- test ! -f "$marker"

# The SAME toml status in the SAME boot means the opposite thing: a stage that is being written
# right now. `dnf5 upgrade --offline` sits at download-complete for the whole of the download, and
# a check that fired in that window and called it dead would announce a transaction that is about
# to be armed perfectly.
stage_marker boot-t4 61
inflight_marker="$(jq -Sc . "$marker")"
: > "$notify_log"
KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml" detour_check
assert_eq "$(cat "$notify_log")" "" "a download-complete stage in this boot is a stage in flight, not a dead one"
assert_eq "$(events_since 'offline stage cannot install')" "1" "...so nothing new is announced"
assert_eq "$(jq -Sc . "$marker")" "$inflight_marker" "...and the marker is left alone"
# The state nothing used to name at all: `ready`, with the /system-update symlink GONE. Arming is
# TWO things - the status and the symlink - and Kempt read the symlink in exactly one place, in
# one direction, inside doctor. systemd.offline-updates(7) is explicit that the symlink is the
# mechanism and that systemd removes it once system-update.target has been reached, so a boot that
# has been and gone leaving the status at `ready` is a boot that did not run the transaction and
# never will: only `dnf5 offline reboot` makes that symlink again. The popup said "installs on the
# next restart" after every restart, forever, and `kempt doctor` exited 0 the whole time.
export KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml"
before_dead="$(events_since 'offline stage cannot install')"
stage_marker boot-before-reboot 61
: > "$notify_log"
detour_check
assert_exit 0 "a ready transaction with no restart marker keeps its marker for the doctor" -- test -f "$marker"
assert_eq "$(jq -r '.armed' "$marker")" "false" "...but the marker is demoted, so no surface promises it"
assert_eq "$(jq -r '.offline_staged // "absent"' "$st")" "absent" \
  "...and it stops being published as a pending install"
grep -q 'can no longer install' "$notify_log" \
  && echo "ok: ...and the user is told, in the same words the detour uses" \
  || { echo "FAIL: no announcement for a ready transaction that cannot install"; _fail=1; }
assert_eq "$(events_since 'offline stage cannot install')" "$((before_dead + 1))" \
  "...exactly once, not once per check"
: > "$notify_log"
detour_check
assert_eq "$(cat "$notify_log")" "" "a second check says nothing more about it"
# ...and while the symlink IS there, the same transaction is still a pending install: this must
# not become "any ready stage is dead".
export KEMPT_OFFLINE_LINK="$TESTTMP/system-update"; ln -sfn "$TESTTMP" "$KEMPT_OFFLINE_LINK"
stage_marker boot-before-reboot 61
detour_check
assert_eq "$(jq -r '.offline_staged.count' "$st")" "61" \
  "a ready transaction whose restart marker still stands is still pending"
export KEMPT_OFFLINE_LINK="$TESTTMP/no-system-update"
export KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml"
stage_marker boot-before-reboot 61
detour_check   # back to the demoted state the announce-once cases below expect
rm -f "$marker" "$pre"

rm -f "$marker" "$pre"
export KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml"

# --- the hold that arrived after the stage, published for every surface --------------------------
# The trap this closes, in one sequence: stage 83 packages, learn something about the kernel, run
# `kempt hold dnf:kernel-core`, restart - and kernel-core installs, because dnf5 built that
# transaction before the hold existed and offers no way to edit a stored one. The hold is recorded
# and correct; it applies from the NEXT transaction Kempt builds. Nothing said so.
#
# The predicate is a SET INTERSECTION and never a clock: the staged names against the dnf names
# currently held. Order-free, restore-proof, and immune to the in-flight-stage race a timestamp
# comparison loses either way round.
#
# Computed here, in the check, because the widget parses state.json and can stat nothing at all -
# it cannot read the marker, and it certainly cannot read dnf5's transaction.
export KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml"
export KEMPT_BOOT_ID="boot-t4"
printf 'not a transaction\n' > "$TESTTMP/tx-garbage.json"
stage_marker boot-t4 61
"$KEMPT" hold dnf:librepo >/dev/null 2>&1
"$KEMPT" hold flatpak:org.gimp.GIMP >/dev/null 2>&1
"$KEMPT" check >/dev/null
assert_eq "$(jq -c '.offline_staged.holds_conflict' "$st")" '["librepo"]' \
  "a package held after the stage, and in that stage, is named"
assert_eq "$(jq -r '.offline_staged.names_source' "$st")" "transaction" \
  "...on the authority of dnf5's own record, not a snapshot of it"
# The offline surface stages dnf and nothing else, so a flatpak hold can never conflict with a
# staged transaction. It is filtered at the source rather than left to come out empty by accident.
"$KEMPT" hold dnf:vim-common >/dev/null 2>&1
"$KEMPT" check >/dev/null
assert_eq "$(jq -c '.offline_staged.holds_conflict' "$st")" '["librepo"]' \
  "a hold on a package that is not in the transaction changes nothing"
assert_eq "$(jq -c '.backends.flatpak.items | map(select(.held)) | length' "$st")" "1" \
  "...and the flatpak hold is real, it just cannot reach an offline transaction"
"$KEMPT" unhold dnf:vim-common >/dev/null 2>&1
"$KEMPT" unhold flatpak:org.gimp.GIMP >/dev/null 2>&1

# The live record unreadable, and a marker whose own names came from the transaction: the marker
# decides. This is the fallback the marker's copy exists for - dnf5 cleaning up after a boot, or a
# format we no longer parse - and it is still transaction-derived evidence, so it may still deny.
jq '. + {staged_names_source:"transaction", staged_names:["ca-certificates","librepo","openldap"], staged_excluded:[]}' \
  "$marker" > "$marker.tmp" && mv "$marker.tmp" "$marker"
KEMPT_OFFLINE_TXJSON="$TESTTMP/tx-garbage.json" "$KEMPT" check >/dev/null
assert_eq "$(jq -c '.offline_staged.holds_conflict' "$st")" '["librepo"]' \
  "a transaction record that will not parse falls back to the marker's own list"
assert_eq "$(jq -r '.offline_staged.names_source' "$st")" "marker" "...and says which list answered"

# The same marker with a CHECK-derived list, and the answer changes: names_source is "none" and the
# conflict list is empty even though the name is sitting right there in it. That is the suppression
# rule doing its job - a check cannot see the packages the resolver added, so a list built from one
# may confirm a conflict but must never be the reason Kempt stays quiet about a held package. An
# empty list under "none" means CANNOT TELL, and every surface reading this must treat it that way.
jq '.staged_names_source = "check"' "$marker" > "$marker.tmp" && mv "$marker.tmp" "$marker"
KEMPT_OFFLINE_TXJSON="$TESTTMP/tx-garbage.json" "$KEMPT" check >/dev/null
assert_eq "$(jq -r '.offline_staged.names_source' "$st")" "none" \
  "a marker whose names only ever came from a check cannot deny a conflict"
assert_eq "$(jq -c '.offline_staged.holds_conflict' "$st")" "[]" \
  "...so it publishes no conflict list at all, and the source says why"

# A marker written before any of this existed - the legacy shape, which every reader must still
# work against. It knows no names, so there is nothing to intersect and nothing to claim.
stage_marker boot-t4 61
KEMPT_OFFLINE_TXJSON="$TESTTMP/tx-garbage.json" "$KEMPT" check >/dev/null
assert_eq "$(jq -r '.offline_staged.names_source' "$st")" "none" "a marker with no names says so"
assert_eq "$(jq -c '.offline_staged.holds_conflict' "$st")" "[]" "...and claims no conflict either way"
assert_eq "$(jq -r '.offline_staged.count' "$st")" "61" "...while everything it does know is published as before"

# Not armed, so there is no staged transaction to conflict WITH: the whole key stays absent rather
# than growing an empty conflict list nobody should read.
KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml" "$KEMPT" check >/dev/null
assert_eq "$(jq -r '.offline_staged // "absent"' "$st")" "absent" \
  "an unarmed stage publishes no conflict fields, because it publishes nothing"
"$KEMPT" unhold dnf:librepo >/dev/null 2>&1
rm -f "$marker" "$pre"
unset KEMPT_BOOT_ID
export KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml"

# Schema 1 stays schema 1. Every field here is additive, so a reader written before this feature
# sees exactly what it saw before.
assert_eq "$(jq -r .schema "$st")" "1" "the schema is not bumped by an additive field"

# --- the check that gives up on the lock hands back ONE document ---------------------------------
# When a check cannot take the lock it serves the previous state file directly, and that is the one
# path in Kempt that promises "never corrupt bytes under exit 0". It was reading the file with
# `jq -e .`, which is precisely the form the same file documents 780 lines further down as the bug
# it fixed elsewhere: a MULTI-DOCUMENT file is valid input to jq, so that form printed BOTH
# documents, and the widget's JSON.parse throws on the second. A state file grows a second document
# when a write is interrupted, which is exactly when a reader is most likely to be waiting on it.
lock_state="$KEMPT_STATE_DIR/state.json"
printf '{"schema":1,"marker":"FIRST"}\n{"schema":1,"marker":"SECOND"}\n' > "$lock_state"
# Hold the lock from another process for longer than the check will wait for it.
( flock 9; sleep 5 ) 9>"$KEMPT_STATE_DIR/check.lock" &
lock_holder=$!
for _ in $(seq 1 200); do
  flock -w 0 -n "$KEMPT_STATE_DIR/check.lock" true 2>/dev/null || break; sleep 0.02
done
KEMPT_CHECK_LOCK_WAIT=1 "$KEMPT" check > "$TESTTMP/served.json" 2>"$TESTTMP/served.err"
served_rc=$?
kill "$lock_holder" 2>/dev/null; wait "$lock_holder" 2>/dev/null || true
assert_eq "$served_rc" "0" "a check that cannot take the lock still exits 0"
grep -q 'serving previous state' "$TESTTMP/served.err" \
  && echo "ok: ...and says on stderr that the answer is the previous one" \
  || { echo "FAIL: no warning about serving the previous state"; _fail=1; }
assert_eq "$(jq -s 'length' "$TESTTMP/served.json" 2>/dev/null || echo PARSE-ERROR)" "1" \
  "...and hands back exactly ONE json document, whatever the file holds"
assert_eq "$(jq -r '.marker' "$TESTTMP/served.json" 2>/dev/null)" "FIRST" \
  "...the first one, which is the state the last complete write left"
rm -f "$lock_state"

# --- a stage made WHILE a harvest is running is not deleted by it -------------------------------
# The marker is shared mutable state between two commands holding DIFFERENT locks: the harvest runs
# under check.lock, `kempt update` writes the marker under the update lock, and neither waits for
# the other. Between the harvest's read and its delete there is a package snapshot and a diff -
# 0.5 to 1.5 s on a real box - and a stage landing inside that window used to be deleted by it:
# "Updates staged - they install on the next restart", and a second later the panel shows nothing
# staged, over a transaction that is armed and will install.
# Injected at exactly that moment rather than raced: the snapshot seam itself writes the new
# marker, which is the same interleaving without the flakiness of a real race.
export KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml"   # the reboot applied and cleared it
export KEMPT_OFFLINE_LINK="$TESTTMP/no-system-update"
race_pre="$KEMPT_STATE_DIR/snapshots/race-pre.tsv"
mkdir -p "$KEMPT_STATE_DIR/snapshots"
printf 'bash\t1-1\nzsh\t1-1\n' > "$race_pre"
jq -n --arg s "$race_pre" '{staged_at:"STAGE-A", pre_snapshot:$s, boot_id:"boot-old", staged:2, armed:true}' \
  > "$marker"
# ONCE, on the first call only: this seam is read again later in the same check, and a stub that
# rewrote the marker every time would re-create it after the harvest and make the assertions below
# pass whether or not the harvest deleted it.
cat > "$TESTTMP/racing-installed" <<STUB
#!/usr/bin/env bash
if [[ ! -e "$TESTTMP/raced" ]]; then
  : > "$TESTTMP/raced"
  # The stage that lands mid-harvest, written the way cmd_update writes it.
  jq -n '{staged_at:"STAGE-B", pre_snapshot:"$TESTTMP/b.tsv", boot_id:"boot-new", staged:9, armed:true}' \
    > "$marker"
fi
printf 'bash\t2-1\nzsh\t1-1\n'
STUB
chmod +x "$TESTTMP/racing-installed"
KEMPT_DNF_INSTALLED_CMD="$TESTTMP/racing-installed" KEMPT_BOOT_ID=boot-new "$KEMPT" check >/dev/null 2>&1
assert_exit 0 "a stage written while the harvest ran survives it" -- test -f "$marker"
assert_eq "$(jq -r '.staged_at' "$marker")" "STAGE-B" \
  "...and it is the NEW stage that is on disk, not the one the harvest read"
assert_eq "$(events_since 'offline marker kept (a new stage arrived while the check ran)')" "1" \
  "...and the harvest records that it kept somebody else's marker"
# The harvest's own work still happened: the reboot really did apply the old transaction, so it is
# still reported. Keeping the new marker must not cost the user the record of the old run.
assert_eq "$(ls -1 "$KEMPT_STATE_DIR"/history/*.json 2>/dev/null | grep -c . || true)" "1" \
  "...while the applied transaction is still written to history"
rm -f "$marker" "$race_pre"

# --- something else moved the packages under a stage that is still armed -------------------------
# Applying an offline transaction removes dnf5's stored transaction, its transaction.json and the
# /system-update symlink. So a package set that moved across a reboot while all of that is STILL
# there was moved by something else - dnf-automatic, GNOME Software, a terminal `sudo dnf5
# upgrade`. Harvesting it wrote a history entry naming the other tool's packages, announced an
# install that had not happened, and deleted the record of a transaction that was still going to
# install. Recorded once instead, and the stage is left exactly as it is.
export KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml"
export KEMPT_OFFLINE_LINK="$TESTTMP/system-update"; ln -sfn "$TESTTMP" "$KEMPT_OFFLINE_LINK"
moved_pre="$KEMPT_STATE_DIR/snapshots/moved-pre.tsv"
printf 'bash\t1-1\nzsh\t1-1\n' > "$moved_pre"
jq -n --arg s "$moved_pre" '{staged_at:"MOVED", pre_snapshot:$s, boot_id:"boot-old", staged:2, armed:true}' \
  > "$marker"
printf '#!/usr/bin/env bash\nprintf "bash\\t2-1\\nzsh\\t1-1\\n"\n' > "$TESTTMP/moved-installed"
chmod +x "$TESTTMP/moved-installed"
hist_before="$(ls -1 "$KEMPT_STATE_DIR"/history/*.json 2>/dev/null | grep -c . || true)"
before_def="$(events_since 'harvest deferred')"
: > "$notify_log"
KEMPT_DNF_INSTALLED_CMD="$TESTTMP/moved-installed" KEMPT_NOTIFY="$TESTTMP/notify-stub" \
  KEMPT_BOOT_ID=boot-new "$KEMPT" check >/dev/null 2>&1
assert_exit 0 "a stage whose packages moved underneath it keeps its marker" -- test -f "$marker"
assert_eq "$(jq -r '.armed' "$marker")" "true" "...and stays armed, because it is"
assert_eq "$(jq -r '.staged_at' "$marker")" "MOVED" "...and is still the stage that was made"
assert_eq "$(ls -1 "$KEMPT_STATE_DIR"/history/*.json 2>/dev/null | grep -c . || true)" "$hist_before" \
  "...and no history entry is invented for an install that did not happen"
grep -q 'applied on reboot' "$notify_log" \
  && { echo "FAIL: announced somebody else's packages as the staged update installing"; _fail=1; } \
  || echo "ok: ...and the user is not told their staged update was applied"
assert_eq "$(events_since 'harvest deferred')" "$((before_def + 1))" \
  "...the deferral is recorded"
assert_eq "$(jq -r '.set_moved' "$marker")" "true" "...on the marker, which is how it is recorded"
KEMPT_DNF_INSTALLED_CMD="$TESTTMP/moved-installed" KEMPT_BOOT_ID=boot-new "$KEMPT" check >/dev/null 2>&1
assert_eq "$(events_since 'harvest deferred')" "$((before_def + 1))" \
  "...exactly once, not once per check for as long as the stage waits"
rm -f "$marker" "$moved_pre"
export KEMPT_OFFLINE_LINK="$TESTTMP/no-system-update"

# --- the check lock is not handed to the helpers ------------------------------------------------
# bash sets no FD_CLOEXEC and a flock lives on the open file description, so it is held while ANY
# descriptor referring to it is open - a child's included. A grandchild outliving `timeout 120`
# therefore kept the CHECK lock: the next check blocked for its whole life, and past 60 s every
# check after that served stale state without saying so. harvest_offline runs inside that lock, so
# a staged transaction's post-reboot harvest is stuck behind it too.
cat > "$TESTTMP/fd-refresh" <<STUB
#!/usr/bin/env bash
for fd in /proc/self/fd/*; do
  printf '%s -> %s\n' "\${fd##*/}" "\$(readlink "\$fd" 2>/dev/null)"
done > "$TESTTMP/helper-fds"
[[ "\$1" == check ]] && exit 0
exit 0
STUB
chmod +x "$TESTTMP/fd-refresh"
: > "$TESTTMP/helper-fds"
KEMPT_REFRESH_HELPER="$TESTTMP/fd-refresh" KEMPT_SKIP_REFRESH= "$KEMPT" check >/dev/null 2>&1
if [[ -s "$TESTTMP/helper-fds" ]]; then
  grep -q 'check\.lock' "$TESTTMP/helper-fds" \
    && { echo "FAIL: the refresh helper inherited the check lock"; _fail=1
         sed 's/^/    /' "$TESTTMP/helper-fds"; } \
    || echo "ok: the refresh helper is handed no descriptor for the check lock"
else
  skip "the refresh helper was not reached in this run, so its descriptors say nothing"
fi
finish
