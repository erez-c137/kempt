#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
UPKEEP="$REPO_ROOT/bin/upkeep"

# Fake world: apply-stub "upgrades" by swapping which snapshot the installed-cmd serves.
export WORLD="$TESTTMP/world"; mkdir -p "$WORLD"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
cp "$FIXTURES/flatpak-list.tsv" "$WORLD/fp.tsv"
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
case "\$1" in
  dnf-upgrade)     cp "$FIXTURES/snap-after.tsv" "$WORLD/rpm.tsv" ;;
  dnf-offline-stage) touch "$WORLD/staged" ;;
  flatpak-update)  : ;;   # no flatpak changes in this fake world
esac
exit 0
STUB
chmod +x "$TESTTMP/apply-stub"
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub"
cat > "$TESTTMP/notify-stub" <<STUB
#!/usr/bin/env bash
echo "NOTIFY \$@" >> "$WORLD/notifications"
STUB
chmod +x "$TESTTMP/notify-stub"
export UPKEEP_APPLY_HELPER="$TESTTMP/apply-stub"
export UPKEEP_REFRESH_HELPER="$TESTTMP/refresh-stub"
export UPKEEP_NOTIFY="$TESTTMP/notify-stub"
export UPKEEP_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
export UPKEEP_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export UPKEEP_FLATPAK_LIST_CMD="cat $WORLD/fp.tsv"
export UPKEEP_SKIP_REFRESH=1
# The reboot check is the backend's (dnf_reboot_needed), so it is stubbed through the backend's
# own seam: UPKEEP_DNF_CMD, exit 1 = reboot needed, exit 0 = not needed.
printf '#!/usr/bin/env bash\nexit 1\n' > "$TESTTMP/dnf-reboot-yes"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"
chmod +x "$TESTTMP/dnf-reboot-yes" "$TESTTMP/dnf-reboot-no"
export UPKEEP_DNF_CMD="$TESTTMP/dnf-reboot-yes"

"$UPKEEP" config set surface background
"$UPKEEP" hold dnf:vim-common

out="$("$UPKEEP" update)"
hist="$(ls "$UPKEEP_STATE_DIR/history/" | tail -1)"
h="$UPKEEP_STATE_DIR/history/$hist"
assert_eq "$(jq -r .status "$h")" "ok" "history status ok"
assert_eq "$(jq '.backends.dnf.updated | length' "$h")" "2" "dnf updated from snapshot diff"
assert_eq "$(jq -r '.backends.dnf.skipped_held[0]' "$h")" "vim-common" "held pkg recorded as skipped"
assert_eq "$(jq -r .reboot_needed "$h")" "true" "reboot flag captured"
grep -q -- '--exclude=vim-common' "$WORLD/apply-calls" && echo "ok: hold became --exclude" || { echo "FAIL: exclude"; _fail=1; }
grep -q 'flatpak-update' "$WORLD/apply-calls" && echo "ok: flatpak ran" || { echo "FAIL: flatpak"; _fail=1; }
grep -q NOTIFY "$WORLD/notifications" && echo "ok: non-terminal surface notified" || { echo "FAIL: notify"; _fail=1; }

# A flatpak hold switches the whole backend to PER-APP updates, and that list is pre-filtered to
# apps that are actually installed: com.example.NotInstalled is pending in the remote fixture but
# absent from the installed list, and the root helper's installed-set check is only a BACKSTOP —
# it must never be what stops it, or a normal run would die on "not installed".
: > "$WORLD/apply-calls"
"$UPKEEP" hold flatpak:org.gimp.GIMP
"$UPKEEP" update >/dev/null
assert_eq "$(grep 'flatpak-update' "$WORLD/apply-calls")" "APPLY flatpak-update -y net.mkiol.SpeechNote" \
  "flatpak hold → per-app update of the pending, non-held, installed app only"
grep -q 'com.example.NotInstalled' "$WORLD/apply-calls" && { echo "FAIL: uninstalled app reached the helper"; _fail=1; } \
  || echo "ok: pending-but-not-installed app never reaches the privileged helper"
"$UPKEEP" unhold flatpak:org.gimp.GIMP

# A typo'd flag must never be treated as "run with the configured defaults".
assert_exit 2 "unknown update option rejected" "$UPKEEP" update --bogus

# auto_accept=false is enforced in cmd_update ITSELF, not only in cmd_run: `upkeep update` is a
# real entry point (widget/cron/user), and only a terminal can answer dnf5's prompt. So the run
# is forced to the terminal surface and -y must NOT reach the privileged helper.
: > "$WORLD/apply-calls"
"$UPKEEP" config set auto_accept false
# dnf-reboot-no → rc 0 → no reboot needed: the everyday case, and the one the reboot-needed
# stub above can never prove.
UPKEEP_DNF_CMD="$TESTTMP/dnf-reboot-no" "$UPKEEP" update >/dev/null
h2="$UPKEEP_STATE_DIR/history/$(ls "$UPKEEP_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .reboot_needed "$h2")" "false" "no-reboot-needed run completes and records false"
assert_eq "$(jq -r .surface "$h2")" "terminal" "auto_accept=false forces the terminal surface"
assert_eq "$(grep -c -- ' -y' "$WORLD/apply-calls")" "0" "auto_accept=false never sends -y to the helper"
"$UPKEEP" config set auto_accept true

# An unknown surface must not silently mean "detached, and definitely not offline". auto_accept is
# true again here, so terminal can ONLY have come from the surface guard.
surferr="$("$UPKEEP" update --surface=bogus 2>&1 >/dev/null)"
grep -q "unknown surface 'bogus'" <<<"$surferr" && echo "ok: unknown surface warns" || { echo "FAIL: surface warning"; _fail=1; }
hs="$UPKEEP_STATE_DIR/history/$(ls "$UPKEEP_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .surface "$hs")" "terminal" "unknown surface falls back to terminal in update"

# offline surface: stage instead of upgrading live, and leave a marker owning its OWN copy of the
# pre-snapshot (a later update overwrites dnf-before.tsv, and the harvest still has to diff
# against the state as it was when the transaction was staged).
: > "$WORLD/apply-calls"; : > "$WORLD/notifications"
"$UPKEEP" update --surface=offline >/dev/null
grep -q 'dnf-offline-stage' "$WORLD/apply-calls" && echo "ok: offline stages the transaction" || { echo "FAIL: offline stage"; _fail=1; }
grep -q 'APPLY dnf-upgrade' "$WORLD/apply-calls" && { echo "FAIL: offline also upgraded live"; _fail=1; } || echo "ok: offline did not upgrade live"
marker="$UPKEEP_STATE_DIR/offline_staged.json"
assert_exit 0 "offline marker written" -- test -f "$marker"
pre="$(jq -r .pre_snapshot "$marker")"
assert_exit 0 "marker owns its own pre-snapshot copy" -- test -f "$pre"
[[ "$pre" != "$UPKEEP_STATE_DIR/snapshots/dnf-before.tsv" ]] && echo "ok: copy is not the shared before-snapshot" \
  || { echo "FAIL: marker points at the reusable dnf-before.tsv"; _fail=1; }
grep -q 'staged' "$WORLD/notifications" && echo "ok: offline notification says staged" || { echo "FAIL: offline notify"; _fail=1; }

# The run is over the moment the helper returns: a report step that dies afterwards would take the
# HISTORY ENTRY and the notification down with it, leaving a system that changed and a CLI that
# says nothing happened. Fail the AFTER-snapshot only (2nd call in a run) and demand a clean,
# honest, empty report instead of a crash — and never a report claiming everything was removed.
cat > "$TESTTMP/flaky-installed" <<STUB
#!/usr/bin/env bash
n=0; [[ -f "$WORLD/installed-calls" ]] && n=\$(cat "$WORLD/installed-calls")
n=\$((n + 1)); echo \$n > "$WORLD/installed-calls"
[[ \$n -ge 2 ]] && exit 7
cat "$WORLD/rpm.tsv"
STUB
chmod +x "$TESTTMP/flaky-installed"
rm -f "$WORLD/installed-calls"
snaprc=0
snaperr="$(UPKEEP_DNF_INSTALLED_CMD="$TESTTMP/flaky-installed" "$UPKEEP" update --no-flatpak 2>&1 >/dev/null)" || snaprc=$?
assert_eq "$snaprc" "0" "a broken after-snapshot never crashes the run"
h3="$UPKEEP_STATE_DIR/history/$(ls "$UPKEEP_STATE_DIR/history/" | tail -1)"
grep -q 'snapshot after the run failed' <<<"$snaperr" && echo "ok: broken after-snapshot warns" || { echo "FAIL: snapshot warning"; _fail=1; }
assert_eq "$(jq -r .status "$h3")" "ok" "a broken report does not turn a good run into a failure"
assert_eq "$(jq '.backends.dnf.updated + .backends.dnf.removed | length' "$h3")" "0" \
  "broken after-snapshot degrades to an empty report, never phantom removals"

# second update while lock held → refuses.
# $$ (this test shell) is deliberately a LIVE pid: a fabricated one is correctly cleared as a
# stale lock, which would make this assertion pass for the wrong reason.
mkdir -p "$UPKEEP_STATE_DIR"; echo $$ > "$UPKEEP_STATE_DIR/lock"
assert_exit 3 "concurrent update refused" "$UPKEEP" update
rm -f "$UPKEEP_STATE_DIR/lock"

# ...and a lock left behind by a DEAD process must not freeze updates forever (the restic lock
# that silently froze retention for 8 days). 99999999 is above pid_max: guaranteed not running.
echo 99999999 > "$UPKEEP_STATE_DIR/lock"
lockerr="$("$UPKEEP" update --no-flatpak 2>&1 >/dev/null)"
grep -q 'stale' <<<"$lockerr" && echo "ok: stale lock cleared, with a note" || { echo "FAIL: stale lock note"; _fail=1; }
assert_exit 0 "stale lock does not block the run" -- test ! -f "$UPKEEP_STATE_DIR/lock"

# helper failure with lock-ish stderr → retried then fails cleanly.
# --no-flatpak keeps the retry count scoped to ONE apply call (both backends would retry).
cat > "$TESTTMP/apply-stub" <<'STUB'
#!/usr/bin/env bash
echo "cannot open lock file: held by another process" >&2; exit 1
STUB
export UPKEEP_RETRY_DELAY=0
assert_exit 1 "busy rpm lock eventually fails" "$UPKEEP" update --no-flatpak
assert_eq "$(grep -c 'retrying' "$(ls -t "$UPKEEP_STATE_DIR"/logs/* | head -1)")" "2" "two retries logged"
# 3 attempts = 2 retries: the last failure must not promise a retry that never comes.
assert_eq "$(grep -c 'giving up' "$(ls -t "$UPKEEP_STATE_DIR"/logs/* | head -1)")" "1" "gives up loudly after the last attempt"
# the marker's snapshot copy survives runs that rewrite dnf-before.tsv
assert_exit 0 "marker snapshot survives later runs" -- test -f "$pre"

# --- offline harvest: the staged transaction applies during a reboot, and the next check has to
# notice and turn it into a normal history entry + notification.
# The marker OWNS its pre-snapshot copy and harvest deletes it, so a marker must never point at a
# shared file — pointing this one at tests/fixtures/ would delete a repo fixture.
pre_copy="$UPKEEP_STATE_DIR/snapshots/offline-pre-harvest.tsv"
cp "$FIXTURES/snap-before.tsv" "$pre_copy"
jq -n --arg snap "$pre_copy" '{staged_at:"x", pre_snapshot:$snap}' > "$UPKEEP_STATE_DIR/offline_staged.json"
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub"

# not applied yet (reboot hasn't happened): the installed set still matches the pre-snapshot
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
before_n="$(ls "$UPKEEP_STATE_DIR"/history/*.json | wc -l)"
"$UPKEEP" check >/dev/null
assert_exit 0 "unapplied stage keeps its marker" -- test -f "$UPKEEP_STATE_DIR/offline_staged.json"
assert_eq "$(ls "$UPKEEP_STATE_DIR"/history/*.json | wc -l)" "$before_n" "unapplied stage records nothing"

# applied on reboot: the installed set moved
cp "$FIXTURES/snap-after.tsv" "$WORLD/rpm.tsv"
: > "$WORLD/notifications"
sleep 1   # history filenames are per-second; keep the harvested entry from landing on an older one
"$UPKEEP" check >/dev/null
[[ ! -f "$UPKEEP_STATE_DIR/offline_staged.json" ]] && echo "ok: marker consumed" || { echo "FAIL: marker"; _fail=1; }
ls "$UPKEEP_STATE_DIR"/history/*.json >/dev/null 2>&1 && echo "ok: harvest wrote history" || { echo "FAIL: harvest"; _fail=1; }
assert_eq "$(ls "$UPKEEP_STATE_DIR"/history/*.json | wc -l)" "$((before_n + 1))" "exactly one history entry harvested"
hh="$UPKEEP_STATE_DIR/history/$(ls "$UPKEEP_STATE_DIR/history/" | tail -1)"
assert_eq "$(jq -r .surface "$hh")" "offline (applied on reboot)" "harvested entry names the surface"
assert_eq "$(jq '.backends.dnf.updated | length' "$hh")" "2" "harvest diffs against the marker's own snapshot"
assert_exit 0 "harvest removes the snapshot copy it owned" -- test ! -f "$pre_copy"
grep -q NOTIFY "$WORLD/notifications" && echo "ok: harvest notifies" || { echo "FAIL: harvest notify"; _fail=1; }

# a consumed marker must not be harvested twice (a second entry would double-count the run)
"$UPKEEP" check >/dev/null
assert_eq "$(ls "$UPKEEP_STATE_DIR"/history/*.json | wc -l)" "$((before_n + 1))" "harvest does not repeat"

# cmd_update prints the rendered summary on stdout — that is the terminal surface's whole point
# ($out was captured from the very first run, before the stub renderer was replaced)
grep -q 'kernel-core 6.15.3-200.fc44 → 6.15.4-200.fc44' <<<"$out" && echo "ok: update printed a rendered summary" \
  || { echo "FAIL: update printed no summary — got: $out"; _fail=1; }

finish
