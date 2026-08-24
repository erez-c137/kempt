#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
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

state="$("$UPKEEP" check)"
assert_eq "$(jq -r .status <<<"$state")" "ok" "status ok"
assert_eq "$(jq '.backends.dnf.items | length' <<<"$state")" "$n_dnf" "dnf items in state"
assert_eq "$(jq '.backends.flatpak.items | length' <<<"$state")" "$n_fp" "flatpak items in state"
assert_eq "$(jq .actionable <<<"$state")" "$((n_dnf + n_fp))" "actionable = all when no holds"
assert_eq "$(jq -Sc . "$UPKEEP_STATE_DIR/state.json")" "$(jq -Sc . <<<"$state")" "state persisted atomically"

# holds: hold the first pending dnf package → actionable drops by 1, held_total=1
first="$(jq -r '.backends.dnf.items[0].name' <<<"$state")"
"$UPKEEP" hold "dnf:$first"
state2="$("$UPKEEP" check)"
assert_eq "$(jq .held_total <<<"$state2")" "1" "held_total counts the hold"
assert_eq "$(jq .actionable <<<"$state2")" "$((n_dnf + n_fp - 1))" "badge count excludes held"

# include_flatpak=false → flatpak absent
"$UPKEEP" config set include_flatpak false
state3="$("$UPKEEP" check)"
assert_eq "$(jq '.backends.flatpak.items | length' <<<"$state3")" "0" "flatpak disabled"

# dnf failure → stale, previous counts kept
cat > "$TESTTMP/refresh-stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
state4="$("$UPKEEP" check)"
assert_eq "$(jq -r .status <<<"$state4")" "stale" "check failure → stale"
assert_eq "$(jq '.backends.dnf.items | length' <<<"$state4")" "$(jq '.backends.dnf.items | length' <<<"$state2")" "stale keeps previous dnf items"

# unhold rejects unknown backends exactly like hold does (a typo must never silently no-op)
assert_exit 2 "unhold validates backend" "$UPKEEP" unhold apt:foo

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
finish
