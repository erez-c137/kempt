#!/usr/bin/env bash
# dnf5's stored offline state has three answers: armed, not armed, and cannot tell. A stored state
# that cannot be read is the third, and over it Kempt acts on nothing: no history entry claims
# anything was installed, status and the widget say it cannot tell, and `kempt doctor` says why.
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"

export WORLD="$TESTTMP/world"; mkdir -p "$WORLD" "$TESTTMP/stubbin"
for b in dnf5 dnf systemctl pkexec sudo flatpak; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/path-calls"\nexit 1\n' "$b" "$WORLD" > "$TESTTMP/stubbin/$b"
  chmod +x "$TESTTMP/stubbin/$b"
done
export PATH="$TESTTMP/stubbin:$PATH"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"; cp "$FIXTURES/flatpak-list.tsv" "$WORLD/fp.tsv"
: > "$WORLD/calls"; : > "$WORLD/notifications"; : > "$WORLD/path-calls"
mk() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$TESTTMP/$1"; chmod +x "$TESTTMP/$1"; }
mk apply-stub "echo \"APPLY \$*\" >> \"$WORLD/calls\"; exit 0"
mk fp-update-stub 'exit 0'
mk refresh-stub "[[ \"\$1\" == check ]] && { cat \"$FIXTURES/dnf-check-update.txt\"; exit 100; }; exit 0"
mk notify-stub "printf 'NOTIFY %s\n' \"\$*\" >> \"$WORLD/notifications\""
mk dnf-no-reboot 'exit 0'
export KEMPT_APPLY_HELPER="$TESTTMP/apply-stub" KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_FLATPAK_UPDATE_CMD="$TESTTMP/fp-update-stub" KEMPT_NOTIFY="$TESTTMP/notify-stub"
export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export KEMPT_FLATPAK_LIST_CMD="cat $WORLD/fp.tsv" KEMPT_FLATPAK_SNAP_CMD="cat $WORLD/fp.tsv"
export KEMPT_SKIP_REFRESH=1 KEMPT_DNF_CMD="$TESTTMP/dnf-no-reboot" KEMPT_DNF_HISTORY_CMD=false
LINK="$TESTTMP/system-update"; export KEMPT_OFFLINE_LINK="$LINK"
export KEMPT_OFFLINE_DATADIR="$TESTTMP/offline"; mkdir -p "$KEMPT_OFFLINE_DATADIR"
TOML="$KEMPT_OFFLINE_DATADIR/offline-transaction-state.toml"; export KEMPT_OFFLINE_TOML="$TOML"
TX="$KEMPT_OFFLINE_DATADIR/transaction.json"; export KEMPT_OFFLINE_TXJSON="$TX"
AFTER="$WORLD/after.tsv"; mkdir -p "$KEMPT_STATE_DIR/snapshots"
STATE_FILE="$KEMPT_STATE_DIR/state.json"

# A stage that was armed: dnf5's status and its boot link.
armed_world() {
  chmod 755 "$KEMPT_OFFLINE_DATADIR"; chmod 644 "$TOML" 2>/dev/null || true; rm -f "$TOML" "$TX" "$LINK"
  cp "$FIXTURES/offline-ready.toml" "$TOML"
  cat > "$TX" <<'JSON'
{"version":"1.0","rpms":[
 {"nevra":"librepo-1.21.0-1.fc44.x86_64","action":"Upgrade","reason":"Dependency","repo_id":"updates"},
 {"nevra":"aardvark-dns-2:1.18.0-1.fc44.x86_64","action":"Upgrade","reason":"User","repo_id":"updates"},
 {"nevra":"7zip-26.03-1.fc44.x86_64","action":"Upgrade","reason":"User","repo_id":"updates"}]}
JSON
  ln -s "$KEMPT_OFFLINE_DATADIR" "$LINK"
  { cat "$FIXTURES/rpm-installed.tsv"; printf 'librepo\t1.20.0-1.fc44\n'; } | LC_ALL=C sort -u > "$AFTER"
  : > "$WORLD/notifications"; rm -rf "$KEMPT_STATE_DIR/history"
}
moved() {  # "name<TAB>version"...
  local l n
  for l in "$@"; do
    n="${l%%$'\t'*}"
    grep -v "^$n"$'\t' "$AFTER" > "$AFTER.t" || true
    printf '%s\n' "$l" >> "$AFTER.t"
    LC_ALL=C sort "$AFTER.t" > "$AFTER"; rm -f "$AFTER.t"
  done
}
check_on() {  # boot id
  awk -F'\t' '{ v=$2; if (v !~ /:/) v="0:" v; print $1 "-" v ".x86_64" }' "$AFTER" > "$WORLD/qa"
  KEMPT_BOOT_ID="$1" KEMPT_RPM_QA_CMD="cat $WORLD/qa" KEMPT_DNF_INSTALLED_CMD="cat $AFTER" "$KEMPT" check >/dev/null 2>&1 || true
}
history_count() { find "$KEMPT_STATE_DIR/history" -name '*.json' 2>/dev/null | wc -l; }
state_is_silent() {  # label
  assert_eq "$(cat "$WORLD/notifications")" "" "$1: nothing is said"
  assert_eq "$(history_count)" "0" "...with no history entry"
  assert_eq "$(jq -c '.offline_staged // "none"' "$STATE_FILE")" '"none"' "...and no stage is promised either"
  assert_eq "$(jq -r '.offline_stage_problem // "none"' "$STATE_FILE")" "unknown" "...and the state says nobody can tell"
}

# --- control: the same world with a readable state still behaves ---------------------------------
armed_world
check_on boot-before
assert_eq "$(jq -r '.offline_staged.count' "$STATE_FILE")" "3" "premise: with a readable stored state the stage is published"
assert_eq "$(jq -r '.offline_stage_problem // "none"' "$STATE_FILE")" "none" "premise: ...and no problem is"
armed_world; rm -f "$TOML" "$TX"; rm -f "$LINK"
check_on boot-before
assert_eq "$(jq -r '.offline_stage_problem // "none"' "$STATE_FILE")" "none" "premise: a stored state really gone is no problem either"

# --- same boot ---------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  armed_world; chmod 000 "$TOML"
  check_on boot-before
  state_is_silent "armed, the stored state unreadable"
  armed_world; chmod 000 "$KEMPT_OFFLINE_DATADIR"
  check_on boot-before
  chmod 755 "$KEMPT_OFFLINE_DATADIR"
  state_is_silent "armed, its folder unreadable"
else
  skip "running as root reads a file of mode 000, so an unreadable state could not be made"
fi

armed_world; : > "$TOML"
check_on boot-before
state_is_silent "armed, the stored state empty"

armed_world; sed -i "s/^status = .*/status = 'ready'/" "$TOML"
check_on boot-before
state_is_silent "armed, the status word in a form this reader does not take"

armed_world; sed -i '/^status = /d' "$TOML"
check_on boot-before
state_is_silent "armed, no status in the stored state"

# --- a later boot, which is when a false claim would be made ---------------------------------------
if [[ $EUID -ne 0 ]]; then
  armed_world; chmod 000 "$TOML"
  moved $'librepo\t1.21.0-1.fc44' $'zzz-unrelated\t1.0-1.fc44'
  check_on boot-after
  state_is_silent "a later boot, a staged package moved, the stored state unreadable"
  assert_not_contains "$(cat "$WORLD/notifications")" "installed" "...and above all nothing was installed, as far as anyone says"
  armed_world; chmod 000 "$TOML"
  check_on boot-after
  state_is_silent "a later boot, nothing moved, the stored state unreadable"
fi
armed_world; : > "$TOML"
moved $'librepo\t1.21.0-1.fc44' $'aardvark-dns\t2:1.18.0-1.fc44' $'7zip\t26.03-1.fc44'
check_on boot-after
state_is_silent "a later boot, every staged package moved, the stored state empty"

# ...and when it can be read again, the ordinary answer comes back, nothing lost on the way.
sed "s/^status = .*/status = \"ready\"/" "$FIXTURES/offline-ready.toml" > "$TOML"; rm -f "$LINK"
check_on boot-after
assert_eq "$(jq -r '.offline_stage_problem // "none"' "$STATE_FILE")" "none" "readable again: installed, so nothing is wrong"

# --- discard is the root helper's call, because root may read what this user cannot ------------------
unstage_with() {  # the helper's script
  mk apply-stub "echo \"APPLY \$*\" >> \"$WORLD/calls\"; $1"
  armed_world; : > "$TOML"; : > "$WORLD/calls"
  rc=0; out="$("$KEMPT" unstage 2>&1)" || rc=$?
}
unstage_with 'echo "kempt-apply: refusing dnf-offline-clean: the stored offline transaction cannot be read, so it may be a Fedora release upgrade" >&2; exit 3'
assert_eq "$rc" "5" "the helper refuses: discard over an unreadable state refuses"
assert_contains "$out" "Nothing was discarded, because the stored offline transaction could not be read" "...and says why"
assert_contains "$(cat "$WORLD/calls")" "APPLY dnf-offline-clean" "...which the helper decided"
assert_contains "$out" "kempt doctor" "...and points at the doctor"
assert_contains "$("$KEMPT" doctor 2>&1)" "sudo dnf5 offline clean" "...which is not silent about it, and names the fix"

unstage_with 'exit 0'
assert_eq "$rc" "1" "the helper reports success over a state still there: not called discarded"
assert_contains "$out" "cannot be read" "...and says what it can tell"
assert_not_contains "$out" 'status "unknown"' "...without quoting Kempt's word as dnf5's"

unstage_with "rm -f \"$TOML\" \"$TX\" \"$LINK\"; exit 0"
assert_eq "$rc" "0" "a state root can read is discarded by root"
mk apply-stub "echo \"APPLY \$*\" >> \"$WORLD/calls\"; exit 0"

# --- doctor says it cannot tell, and makes no other claim -------------------------------------------
armed_world; : > "$TOML"
drep="$(KEMPT_BOOT_ID=boot-before KEMPT_RPM_QA_CMD="cat $WORLD/qa" "$KEMPT" doctor 2>&1 || true)"
assert_not_contains "$drep" "staged outside Kempt" "doctor over an unreadable state: not a stage made elsewhere"
assert_not_contains "$drep" "can never install" "...not one that can never install"
assert_not_contains "$drep" "boot symlink is live" "...not a live symlink over a bad status"
assert_not_contains "$drep" "status unknown" "...and the word is never quoted as dnf5's"
assert_contains "$drep" "Kempt cannot tell what the stored update will do" "...and it says it cannot tell"
assert_contains "$drep" "Clear it with: sudo dnf5 offline clean" "...and how to clear it"

assert_eq "$(cat "$WORLD/path-calls")" "" "nothing here reached a real dnf, pkexec or systemctl"
finish
