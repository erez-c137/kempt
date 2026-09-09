#!/usr/bin/env bash
# What Kempt does on a machine that is a long way behind.
#
# Every other fixture in this suite is about ten packages wide, and that is the whole reason this
# file exists: the failure it covers is invisible at ten and certain at a thousand. Linux caps a
# SINGLE argv entry at 128 KiB (MAX_ARG_STRLEN), and three jq calls used to hand the pending list
# or the run's report across `execve` as one argument. Measured on Fedora 44: the check died at 925
# pending updates and a run's history entry at about 1,200 updated packages, both with exit 126 -
# which the widget reads as "no engine", so a working install told its owner to reinstall a package
# they already had.
#
# A fresh install from a several-month-old ISO, or a laptop switched off for a season, sits in that
# range routinely. The tool got less usable the further behind the box was.
#
# All three sites are driven through the code that carries them in production - a real check, a
# real run, a real harvest - because what is under test is the shape of the call, and a stand-in
# for the call would test the stand-in. The fixtures are GENERATED rather than committed: the
# largest committed fixture is ten packages, and a two-thousand-row one would be a file nobody
# reads guarded by a MANIFEST entry nobody checks.
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"

# Past both measured walls with room to spare, and past them in EVERY payload: the names are long
# enough that the pending list, the two snapshots and the diff between them each clear 128 KiB on
# their own. A smaller N would pass on a fix and also pass without one.
N=2000
pkg() { printf 'kf6-volume-probe-with-a-realistically-long-name-%04d' "$1"; }

export WORLD="$TESTTMP/world"; mkdir -p "$WORLD"
awk -v n="$N" 'BEGIN{for(i=0;i<n;i++) printf "kf6-volume-probe-with-a-realistically-long-name-%04d.x86_64   6.20.%d-1.fc44   updates\n", i, i}' \
  > "$TESTTMP/pending.txt"
awk -v n="$N" 'BEGIN{for(i=0;i<n;i++) printf "kf6-volume-probe-with-a-realistically-long-name-%04d\t6.19.%d-1.fc44\n", i, i}' \
  > "$TESTTMP/before.tsv"
awk -v n="$N" 'BEGIN{for(i=0;i<n;i++) printf "kf6-volume-probe-with-a-realistically-long-name-%04d\t6.20.%d-1.fc44\n", i, i}' \
  > "$TESTTMP/after.tsv"
cp "$TESTTMP/before.tsv" "$WORLD/rpm.tsv"

assert_exit 0 "the generated pending list is past the single-argument cap on its own" \
  -- test "$(wc -c < "$TESTTMP/pending.txt")" -gt 131071

# The pending list follows the world rather than being fixed, because one of the assertions below
# is about the check that runs AFTER a run: a stub that offers the same 2,000 updates whether or
# not they were installed can never tell "the post-run check wrote state" from "it did nothing".
# rc 100 is `dnf check-update` for "there are updates", rc 0 for "there are none".
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] || exit 0
cmp -s "$WORLD/rpm.tsv" "$TESTTMP/after.tsv" && exit 0
cat "$TESTTMP/pending.txt"; exit 100
STUB
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
[[ "\$1" == dnf-upgrade ]] && cp "$TESTTMP/after.tsv" "$WORLD/rpm.tsv"
exit 0
STUB
cat > "$TESTTMP/notify-stub" <<STUB
#!/usr/bin/env bash
echo "NOTIFY \$@" >> "$WORLD/notifications"
STUB
chmod +x "$TESTTMP/refresh-stub" "$TESTTMP/apply-stub" "$TESTTMP/notify-stub"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/noop"; chmod +x "$TESTTMP/noop"

export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_APPLY_HELPER="$TESTTMP/apply-stub"
export KEMPT_NOTIFY="$TESTTMP/notify-stub"
export KEMPT_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
export KEMPT_DNF_CMD="$TESTTMP/noop"
export KEMPT_SKIP_REFRESH=1
"$KEMPT" config set include_flatpak false >/dev/null

# --- 1. the check ---------------------------------------------------------------------------
# The site in assemble_state. This is the one an ordinary user reaches without doing anything: the
# widget runs a check every hour.
rc=0
"$KEMPT" check >/dev/null 2>"$TESTTMP/check.err" || rc=$?
assert_eq "$rc" "0" "a check with $N pending updates exits 0"
assert_eq "$(grep -c 'Argument list too long' "$TESTTMP/check.err" || true)" "0" \
  "...without handing the pending list to a command as one argument"
state="$KEMPT_STATE_DIR/state.json"
assert_exit 0 "...and writes the state file the widget reads" -- test -s "$state"
assert_eq "$(jq -s 'length' "$state")" "1" "...as exactly one JSON document, which is what parses"
assert_eq "$(jq -r '.backends.dnf.actionable' "$state")" "$N" "...counting every one of them"
assert_eq "$(jq -r '.status' "$state")" "ok" "...and calls the check a success, because it was"
# The failure this file exists for did not only lose the answer, it lost the record of trying.
grep -q 'check' "$KEMPT_STATE_DIR/events.log" \
  && echo "ok: ...with the check in the event log, so a failure here could never be silent" \
  || { echo "FAIL: no check event logged"; _fail=1; }

# --- 2. the run's own history entry -------------------------------------------------------------
# The worse of the three, because it is on the FAR SIDE of the update: dnf5 has already installed
# everything by the time this runs. Losing it loses the history entry, the summary, the
# notification, the run-done event and the post-run check - and that last one is the only thing
# that takes the widget out of its updating state, so a successful two-thousand-package update
# would present as a spinner that never stops.
: > "$WORLD/notifications"
# History filenames are per-second, and the harvest below appends `-offline` to break a collision -
# which sorts BEFORE the plain name, not after ("-" is 0x2D, "." is 0x2E). So the newest entry is
# found by DIFFING the directory, never by `ls | tail -1`: that reads the wrong entry whenever two
# of these land in the same second, which is a matter of how fast the machine is.
# `|| true` on the whole pipeline: the first call runs against an EMPTY history directory, where
# the glob matches nothing and ls exits 2 - which pipefail plus errexit turns into a test file that
# stops after its first section having printed nothing about why.
hist_list() { ls -1 "$KEMPT_STATE_DIR"/history/*.json 2>/dev/null | sort || true; }
hist_list > "$TESTTMP/hist-before.txt"
rc=0
"$KEMPT" update >/dev/null 2>"$TESTTMP/update.err" || rc=$?
assert_eq "$rc" "0" "a run that updates $N packages exits 0"
hist_list > "$TESTTMP/hist-after.txt"
h="$(comm -13 "$TESTTMP/hist-before.txt" "$TESTTMP/hist-after.txt" | head -1)"
assert_eq "$(jq -r .status "$h")" "ok" "...and writes a history entry that calls it a success"
assert_eq "$(jq '.backends.dnf.updated | length' "$h")" "$N" "...naming every package it moved"
assert_exit 0 "...from a report far past the cap" \
  -- test "$(jq -c '.backends.dnf' "$h" | wc -c)" -gt 131071
grep -q NOTIFY "$WORLD/notifications" \
  && echo "ok: ...and the person is told the run finished" \
  || { echo "FAIL: no notification after a large run"; _fail=1; }
# The post-run check is what clears the widget's spinner. Nothing else does.
assert_eq "$(jq -r '.backends.dnf.actionable' "$state")" "0" \
  "...and the state file no longer offers updates that have been installed"

# --- 3. the harvest -------------------------------------------------------------------------
# The third site, and the one that does not recover on its own: harvest_offline runs at the top of
# EVERY check and deletes the marker ten lines after writing this entry. A failure here leaves the
# marker in place, so the next check fails in the same spot, forever - the box stops checking.
# Reached by staging a transaction, then presenting the world a reboot would leave behind: the
# installed set moved, and dnf5's transaction went with it.
pre="$KEMPT_STATE_DIR/snapshots/offline-pre-volume.tsv"
mkdir -p "$KEMPT_STATE_DIR/snapshots"; cp "$TESTTMP/before.tsv" "$pre"
jq -n --arg snap "$pre" '{staged_at:"x", pre_snapshot:$snap, armed:true}' \
  > "$KEMPT_STATE_DIR/offline_staged.json"
export KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml"   # applied: dnf5 removed it
cp "$TESTTMP/after.tsv" "$WORLD/rpm.tsv"
hist_list > "$TESTTMP/hist-before.txt"
: > "$WORLD/notifications"
rc=0
"$KEMPT" check >/dev/null 2>"$TESTTMP/harvest.err" || rc=$?
assert_eq "$rc" "0" "the check that harvests $N applied packages exits 0"
assert_exit 0 "...and consumes the marker, so the next check is an ordinary one" \
  -- test ! -f "$KEMPT_STATE_DIR/offline_staged.json"
hist_list > "$TESTTMP/hist-after.txt"
comm -13 "$TESTTMP/hist-before.txt" "$TESTTMP/hist-after.txt" > "$TESTTMP/hist-new.txt"
assert_eq "$(wc -l < "$TESTTMP/hist-new.txt")" "1" \
  "...writing exactly one history entry for the reboot that applied them"
hh="$(head -1 "$TESTTMP/hist-new.txt")"
assert_eq "$(jq -r .surface "$hh")" "offline (applied on reboot)" "...which names the surface"
assert_eq "$(jq '.backends.dnf.updated | length' "$hh")" "$N" "...and every package it found moved"

finish
