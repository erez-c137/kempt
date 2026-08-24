#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
UPKEEP="$REPO_ROOT/bin/upkeep"

# stubs: dnf helper serves fixture; flatpak served via cmd overrides
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
case "\$1" in
  check) cat "$FIXTURES/dnf-check-update.txt"; exit 100 ;;
  refresh) echo refreshed >> "$TESTTMP/refresh-calls"; exit 0 ;;
esac
STUB
chmod +x "$TESTTMP/refresh-stub"
export UPKEEP_REFRESH_HELPER="$TESTTMP/refresh-stub"
export UPKEEP_DNF_INSTALLED_CMD="cat $FIXTURES/rpm-installed.tsv"
export UPKEEP_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export UPKEEP_FLATPAK_LIST_CMD="cat $FIXTURES/flatpak-list.tsv"
export UPKEEP_SKIP_REFRESH=1   # deterministic: no metadata refresh attempts in tests

# Fixture contracts (tests/fixtures/MANIFEST.md): dnf parses to 7 items, flatpak to 3.
n_dnf=7
n_fp=3

# config defaults come from the upkeep_default table, so an unset key answers with the real
# default instead of an empty string (fresh sandbox: no config file has been written yet)
assert_eq "$("$UPKEEP" config get surface)" "terminal" "unset key falls back to the defaults table"
assert_eq "$("$UPKEEP" config get include_flatpak)" "true" "defaults table covers include_flatpak"

state="$("$UPKEEP" check)"
assert_eq "$(jq -r .status <<<"$state")" "ok" "status ok"
assert_eq "$(jq -r .schema <<<"$state")" "1" "state schema v1"
assert_eq "$(jq '.backends.dnf.items | length' <<<"$state")" "$n_dnf" "dnf items in state"
assert_eq "$(jq '.backends.flatpak.items | length' <<<"$state")" "$n_fp" "flatpak items in state"
assert_eq "$(jq .actionable <<<"$state")" "$((n_dnf + n_fp))" "actionable = all when no holds"
assert_eq "$(jq -r '.last_success == .last_check' <<<"$state")" "true" "a successful check stamps last_success"
assert_eq "$(jq -Sc . "$UPKEEP_STATE_DIR/state.json")" "$(jq -Sc . <<<"$state")" "state persisted atomically"

# holds: hold the first pending dnf package → actionable drops by 1, held_total=1
first="$(jq -r '.backends.dnf.items[0].name' <<<"$state")"
"$UPKEEP" hold "dnf:$first"
state2="$("$UPKEEP" check)"
assert_eq "$(jq .held_total <<<"$state2")" "1" "held_total counts the hold"
assert_eq "$(jq .actionable <<<"$state2")" "$((n_dnf + n_fp - 1))" "badge count excludes held"
assert_eq "$(jq .backends.dnf.actionable <<<"$state2")" "$((n_dnf - 1))" "per-backend actionable excludes held"
assert_eq "$(jq .backends.dnf.held <<<"$state2")" "1" "per-backend held count"

# include_flatpak=false → flatpak absent, and SAID to be disabled rather than merely empty
"$UPKEEP" config set include_flatpak false
state3="$("$UPKEEP" check)"
assert_eq "$(jq '.backends.flatpak.items | length' <<<"$state3")" "0" "flatpak disabled"
assert_eq "$(jq -r .backends.flatpak.enabled <<<"$state3")" "false" "disabled flatpak is flagged, not just empty"
assert_eq "$(jq -r .backends.dnf.enabled <<<"$state3")" "true" "dnf stays enabled"

# dnf failure → stale, previous counts kept, last_success frozen at the last real success
cat > "$TESTTMP/refresh-stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
state4="$("$UPKEEP" check)"
assert_eq "$(jq -r .status <<<"$state4")" "stale" "check failure → stale"
assert_eq "$(jq '.backends.dnf.items | length' <<<"$state4")" "$(jq '.backends.dnf.items | length' <<<"$state2")" "stale keeps previous dnf items"
assert_eq "$(jq -r .last_success <<<"$state4")" "$(jq -r .last_success <<<"$state3")" "stale preserves the previous last_success"
assert_eq "$(jq -r '.last_success != null' <<<"$state4")" "true" "preserved last_success is non-null"
assert_eq "$(jq -r '.error | startswith("dnf check failed")' <<<"$state4")" "true" "stale error names the failing backend"

# unhold rejects unknown backends exactly like hold does (a typo must never silently no-op)
assert_exit 2 "unhold validates backend" "$UPKEEP" unhold apt:foo

# Corrupt state recovery. state.json is the fallback a failing check leans on, so a damaged one
# used to take the whole check down with it: a truncated file fed "" to --argjson (rc 2), a
# wrong-shaped .items fed a STRING into an array concat (rc 5). Every shape must degrade to [].
# (dnf stub is still the failing one from the stale section above — that is the point.)
for corrupt in '' 'garbage' '{"backends":{"dnf":{"items":"nope"}}}' '{"a":1}{"b":2}'; do
  shape="${corrupt:-<empty file>}"
  printf '%s' "$corrupt" > "$UPKEEP_STATE_DIR/state.json"
  rc=0; out="$("$UPKEEP" check 2>/dev/null)" || rc=$?
  assert_eq "$rc" "0" "corrupt state ($shape) → check still exits 0"
  assert_eq "$(jq -r .status <<<"$out")" "stale" "corrupt state ($shape) → stale"
  assert_eq "$(jq -c '.backends.dnf.items' <<<"$out")" "[]" "corrupt state ($shape) → no fabricated items"
done

# Concurrency: the widget guarantees overlapping checks (timer + event watch + post-run check).
# A fixed tmp name in write_state made them race — one process's mv stole another's tmp file and
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
  ( rc=0; "$UPKEEP" check >/dev/null 2>&1 || rc=$?; printf '%s\n' "$rc" > "$TESTTMP/conc-rc.$i" ) &
done
wait
# comma-joins the DISTINCT exit codes seen, so a failure names the rc instead of just a count
assert_eq "$(sort -u "$TESTTMP"/conc-rc.* | paste -sd, -)" "0" "concurrent checks never collide"
assert_exit 0 "state intact after concurrent writes" -- jq -e .actionable "$UPKEEP_STATE_DIR/state.json"
# guards the vacuous pass: 10 runs that all serve a cached stale state would satisfy the rc
# assertion above while proving nothing about the write path
assert_eq "$(jq -r .status "$UPKEEP_STATE_DIR/state.json")" "ok" "concurrent block ends in real ok state"

# --- metadata refresh gating: the only place maybe_refresh_metadata actually runs ---
# on_battery/metered_connection read real hardware and have no seam, so skip rather than fail
# on a laptop that happens to be unplugged or on a metered link.
unset UPKEEP_SKIP_REFRESH
if on_battery || metered_connection; then
  echo "ok: refresh gating skipped (box is on battery or on a metered link)"
else
  rm -f "$LAST_REFRESH_FILE" "$TESTTMP/refresh-calls"
  "$UPKEEP" check >/dev/null
  assert_eq "$(wc -l < "$TESTTMP/refresh-calls")" "1" "cold check refreshes metadata once"
  assert_exit 0 "cold refresh stamps last_refresh" -- test -f "$LAST_REFRESH_FILE"
  "$UPKEEP" check >/dev/null
  assert_eq "$(wc -l < "$TESTTMP/refresh-calls")" "1" "a second check inside the 3h window does not refresh"
  touch -d '4 hours ago' "$LAST_REFRESH_FILE"
  "$UPKEEP" check >/dev/null
  assert_eq "$(wc -l < "$TESTTMP/refresh-calls")" "2" "refresh resumes once the 3h window lapses"
fi
finish
