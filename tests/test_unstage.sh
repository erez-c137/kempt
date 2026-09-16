#!/usr/bin/env bash
# `kempt unstage` - discarding a staged offline transaction from the CLI.
#
# It goes through the same root helper verb the failure unwinds already use
# (dnf-offline-clean), so it inherits that verb's one refusal: dnf5 keeps ONE stored transaction,
# and a Fedora release upgrade sits in the same slot. Discarding "the staged update" over one would
# throw away gigabytes somebody spent hours downloading, so it is refused as the user AND as root -
# and nothing here may ever answer with `sudo dnf5 offline clean`, which is the command the refusal
# exists to protect against.
#
# The other rule this file pins: Kempt's marker goes only when dnf5's transaction is really gone. A
# marker cleared over a transaction that is still armed leaves an install coming that no surface
# mentions, which is the same failure the harvest's own clearing rule avoids from the other side.
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"

export WORLD="$TESTTMP/world"; mkdir -p "$WORLD"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"

cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"
chmod +x "$TESTTMP/refresh-stub" "$TESTTMP/dnf-reboot-no"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no"
export KEMPT_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
export KEMPT_SKIP_REFRESH=1
"$KEMPT" config set include_flatpak false >/dev/null

# dnf5's state file for this world is a COPY, so a stub can change it mid-run exactly as the real
# verb would - a clean that works removes it, one that quietly does nothing leaves it standing.
TOML="$TESTTMP/offline-transaction-state.toml"
export KEMPT_OFFLINE_TOML="$TOML"
stored() { cp "$FIXTURES/$1" "$TOML"; }
RELUP="$FIXTURES/offline-release-upgrade.toml"
marker="$KEMPT_STATE_DIR/offline_staged.json"

apply_stub() {  # name 'case arms' → an apply helper recording every call
  cat > "$TESTTMP/apply-$1" <<STUB
#!/usr/bin/env bash
echo "APPLY \$*" >> "$WORLD/apply-calls"
case "\$1" in
$2
esac
exit 0
STUB
  chmod +x "$TESTTMP/apply-$1"
}
calls()     { grep -c "APPLY $1" "$WORLD/apply-calls" 2>/dev/null || true; }
reset_run() { : > "$WORLD/apply-calls"; }
logged()    { grep -q "$1" "$KEMPT_STATE_DIR/events.log"; }
no_clean_advice() {  # label - the one command every message here must never name
  if grep -qF 'dnf5 offline clean' "$TESTTMP/err" 2>/dev/null; then
    echo "FAIL: $1"; _fail=1; sed 's/^/    /' "$TESTTMP/err"
  else
    echo "ok: $1"
  fi
}

apply_stub ok ''
apply_stub clean-ok 'dnf-offline-clean) rm -f "'"$TOML"'" ;;'
stage_real() {  # a real armed stage from this world, so there is a marker to act on
  stored offline-ready.toml
  rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
  KEMPT_APPLY_HELPER="$TESTTMP/apply-ok" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1
}

# --- nothing staged ------------------------------------------------------------------------------
# The answer on most boxes, and not a failure. Said in words on stdout, the shape `kempt summary`
# uses for a box with no runs: empty output would read as a command that did not work.
rm -f "$marker" "$TOML"; reset_run
rc=0; out="$(KEMPT_APPLY_HELPER="$TESTTMP/apply-clean-ok" "$KEMPT" unstage 2>"$TESTTMP/err")" || rc=$?
assert_eq "$rc" "0" "unstage with nothing staged is not a failure"
assert_eq "$out" "Nothing is staged, so there is nothing to discard." "...and says so in words"
assert_eq "$(calls dnf-offline-clean)" "0" "...without asking root to do anything"

# --- the ordinary discard -------------------------------------------------------------------------
stage_real
assert_exit 0 "the fixture starts from a real armed stage" -- test -f "$marker"
reset_run
rc=0; out="$(KEMPT_APPLY_HELPER="$TESTTMP/apply-clean-ok" "$KEMPT" unstage 2>"$TESTTMP/err")" || rc=$?
assert_eq "$rc" "0" "unstage over an armed stage succeeds"
assert_eq "$(calls dnf-offline-clean)" "1" "...through the helper verb that already existed"
assert_exit 1 "...and Kempt's marker goes with the transaction" -- test -f "$marker"
assert_eq "$out" "Discarded the staged update. The next restart installs nothing." \
  "...and says plainly what it did, and what that means"
logged 'unstage discarded the staged update' \
  && echo "ok: ...and the event log records it" || { echo "FAIL: no unstage event"; _fail=1; }

# --- the marker goes ONLY when the transaction is really gone --------------------------------------
# The helper can exit 0 having changed less than it meant to. Clearing the marker on that status
# alone would leave a transaction armed and every Kempt surface silent about it - the popup, the
# doctor row and the harvest all stop mentioning an install that is still coming.
stage_real
apply_stub clean-noop 'dnf-offline-clean) : ;;'
reset_run
rc=0; KEMPT_APPLY_HELPER="$TESTTMP/apply-clean-noop" "$KEMPT" unstage >/dev/null 2>"$TESTTMP/err" || rc=$?
assert_eq "$rc" "1" "a clean that left the transaction behind is a failure"
assert_exit 0 "...and the marker is KEPT, so doctor can still describe the stage" -- test -f "$marker"
grep -q 'still reports a stored transaction' "$TESTTMP/err" \
  && echo "ok: ...and the message says what is still there" \
  || { echo "FAIL: no stored-transaction warning"; _fail=1; sed 's/^/    /' "$TESTTMP/err"; }

# --- a stored Fedora release upgrade is refused, as the user ---------------------------------------
# 0.1.3's refusal, kept. dnf5 has one slot and this is not our transaction in it, so discarding
# would cancel an upgrade that took gigabytes to download.
stage_real
cp "$RELUP" "$TOML"
reset_run
rc=0; KEMPT_APPLY_HELPER="$TESTTMP/apply-clean-ok" "$KEMPT" unstage >/dev/null 2>"$TESTTMP/err" || rc=$?
assert_eq "$rc" "5" "a stored release upgrade refuses the unstage before anything is changed"
assert_eq "$(calls dnf-offline-clean)" "0" "...without asking root to do anything"
assert_exit 0 "...and the marker is untouched" -- test -f "$marker"
grep -q '44 -> 45' "$TESTTMP/err" \
  && echo "ok: ...and the message names the upgrade it protected" \
  || { echo "FAIL: the refusal does not name the release upgrade"; _fail=1; sed 's/^/    /' "$TESTTMP/err"; }
no_clean_advice "...and never advises the command that would delete it"
logged 'unstage refused' \
  && echo "ok: ...and the refusal is in the event log" || { echo "FAIL: no refusal event"; _fail=1; }

# --- and refused as root, which is the case the CLI cannot see -------------------------------------
# A release upgrade stored between the CLI's own check and the helper's. The helper exits 3, and
# the CLI reports it in apply_refusal_reason's words rather than as an ordinary failure.
stage_real
apply_stub clean-refused 'dnf-offline-clean) echo "kempt-apply: refusing dnf-offline-clean: the stored offline transaction cannot be read, so it may be a Fedora release upgrade" >&2; exit 3 ;;'
reset_run
rc=0; KEMPT_APPLY_HELPER="$TESTTMP/apply-clean-refused" "$KEMPT" unstage >/dev/null 2>"$TESTTMP/err" || rc=$?
assert_eq "$rc" "5" "a refusal from the root helper is a refusal here too, not a failed run"
assert_exit 0 "...and the marker stays, because nothing changed" -- test -f "$marker"
grep -q 'the stored offline transaction could not be read' "$TESTTMP/err" \
  && echo "ok: ...and the reason is the one the boundary gives" \
  || { echo "FAIL: the refusal does not carry apply_refusal_reason's words"; _fail=1; sed 's/^/    /' "$TESTTMP/err"; }
no_clean_advice "...and does not advise a clean either"

# --- a marker with no transaction under it ---------------------------------------------------------
# Nothing for root to do: the transaction is already gone, and all that is left is Kempt's record
# of it. Cleared without an authentication dialog nobody needed to see.
stage_real
rm -f "$TOML"
reset_run
rc=0; out="$(KEMPT_APPLY_HELPER="$TESTTMP/apply-clean-ok" "$KEMPT" unstage 2>"$TESTTMP/err")" || rc=$?
assert_eq "$rc" "0" "a marker whose transaction has gone is cleared, not an error"
assert_eq "$(calls dnf-offline-clean)" "0" "...without asking root for anything"
assert_exit 1 "...and the marker is gone" -- test -f "$marker"
grep -q 'already gone' <<<"$out" \
  && echo "ok: ...and it says the stage was already gone, never that it discarded one" \
  || { echo "FAIL: the message claims a discard that did not happen"; _fail=1; echo "  got: $out"; }

assert_exit 2 "unstage takes no arguments" "$KEMPT" unstage --all

finish
