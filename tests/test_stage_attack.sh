#!/usr/bin/env bash
# What Kempt says about a stored offline update comes from dnf5's own files, its history and rpm. These
# are the cases that used to produce a false report when Kempt kept its own record and reconciled it.
# Each row builds the machine's files, runs a real check, and reads what a person is told.
source "$(dirname "$0")/lib.sh"; sandbox
set +e
KEMPT="$REPO_ROOT/bin/kempt"

export WORLD="$TESTTMP/world"; mkdir -p "$WORLD" "$TESTTMP/stubbin"
for b in dnf5 dnf systemctl pkexec sudo flatpak; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/path-calls"\nexit 1\n' "$b" "$WORLD" > "$TESTTMP/stubbin/$b"
  chmod +x "$TESTTMP/stubbin/$b"
done
export PATH="$TESTTMP/stubbin:$PATH"
cp "$FIXTURES/flatpak-list.tsv" "$WORLD/fp.tsv"
: > "$WORLD/calls"; : > "$WORLD/notifications"; : > "$WORLD/path-calls"
mk() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$TESTTMP/$1"; chmod +x "$TESTTMP/$1"; }
mk apply-stub "echo \"APPLY \$*\" >> \"$WORLD/calls\"; exit 0"
mk fp-update-stub 'exit 0'
mk refresh-stub "[[ \"\$1\" == check ]] && { cat \"$FIXTURES/dnf-check-update.txt\"; exit 100; }; exit 0"
mk notify-stub "printf 'NOTIFY %s\n' \"\$*\" >> \"$WORLD/notifications\""
mk dnf-no-reboot 'exit 0'
# dnf5's history, as files: no list file means history does not answer.
mk history-stub "while [[ \$# -gt 0 && \$1 != list && \$1 != info ]]; do shift; done
echo \"\$1\" >> \"$WORLD/hist-calls\"
[[ \$1 == list ]] && exec cat \"$WORLD/hist-list.json\"
[[ \$1 == info ]] && exec cat \"$WORLD/hist-info-\$2.json\"
exit 1"
export KEMPT_APPLY_HELPER="$TESTTMP/apply-stub" KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_FLATPAK_UPDATE_CMD="$TESTTMP/fp-update-stub" KEMPT_NOTIFY="$TESTTMP/notify-stub"
export KEMPT_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export KEMPT_FLATPAK_LIST_CMD="cat $WORLD/fp.tsv" KEMPT_FLATPAK_SNAP_CMD="cat $WORLD/fp.tsv"
export KEMPT_SKIP_REFRESH=1 KEMPT_DNF_CMD="$TESTTMP/dnf-no-reboot" KEMPT_DNF_HISTORY_CMD="$TESTTMP/history-stub"
export KEMPT_RPM_QA_CMD="cat $WORLD/rpm-qa"
export KEMPT_DNF_INSTALLED_CMD="cat $FIXTURES/snap-before.tsv"
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent
LINK="$TESTTMP/system-update"; export KEMPT_OFFLINE_LINK="$LINK"
export KEMPT_OFFLINE_DATADIR="$TESTTMP/offline"; mkdir -p "$KEMPT_OFFLINE_DATADIR"
TOML="$KEMPT_OFFLINE_DATADIR/offline-transaction-state.toml"; export KEMPT_OFFLINE_TOML="$TOML"
TX="$KEMPT_OFFLINE_DATADIR/transaction.json"; export KEMPT_OFFLINE_TXJSON="$TX"
STATE_FILE="$KEMPT_STATE_DIR/state.json"
SHOWN="$KEMPT_STATE_DIR/stage-shown"
COOKIE=4b51d97de84964839f89b4a348ca7a5d61e17e4bbbf26ba3164aee2a5e97de15

OLD=$'librepo-0:1.20.0-1.fc44.x86_64\naardvark-dns-2:1.17.0-1.fc44.x86_64\n7zip-0:26.02-1.fc44.x86_64'
NEW=$'librepo-0:1.21.0-1.fc44.x86_64\naardvark-dns-2:1.18.0-1.fc44.x86_64\n7zip-0:26.03-1.fc44.x86_64'

world() {  # toml status word or gone; link dnf5|none|other
  chmod 644 "$TOML" 2>/dev/null; rm -f "$TOML" "$TX" "$LINK" "$SHOWN" "$STATE_FILE"
  rm -rf "$KEMPT_STATE_DIR/history" "$WORLD/hist-"*
  if [[ "$1" != gone ]]; then
    sed "s/^status = .*/status = \"$1\"/" "$FIXTURES/offline-ready.toml" > "$TOML"
    cat > "$TX" <<'JSON'
{"version":"1.0","rpms":[
 {"nevra":"librepo-1.21.0-1.fc44.x86_64","action":"Upgrade","reason":"Dependency","repo_id":"updates"},
 {"nevra":"aardvark-dns-2:1.18.0-1.fc44.x86_64","action":"Upgrade","reason":"User","repo_id":"updates"},
 {"nevra":"7zip-26.03-1.fc44.x86_64","action":"Upgrade","reason":"User","repo_id":"updates"}]}
JSON
  fi
  case "$2" in
    dnf5) ln -s "$KEMPT_OFFLINE_DATADIR" "$LINK" ;;
    other) ln -s /var/lib/PackageKit/prepared-update "$LINK" ;;
  esac
  printf '%s\n' "$OLD" > "$WORLD/rpm-qa"
  echo '[]' > "$WORLD/hist-list.json"
  : > "$WORLD/notifications"
}
rpm_is() { printf '%s\n' "$@" > "$WORLD/rpm-qa"; }
# A row as dnf5 writes it: the list answers newest first, with command_line, the info with a package
# list of the plan. ROW_COOKIE says the row began from another rpmdb than the stored stage.
row() {  # id status command-line [ended-seconds-ago]
  local at=$(( $(date +%s) - ${4:-60} )) end
  end="$at"; [[ "$2" != Started ]] || end=0
  jq --argjson id "$1" --arg st "$2" --arg cmd "$3" --argjson at "$at" --argjson end "$end" \
    '[{id:$id, command_line:$cmd, start_time:$at, end_time:$end, user_id:0, status:$st, releasever:"44", altered_count:6}] + .' \
    "$WORLD/hist-list.json" > "$WORLD/hist-list.t" && mv "$WORLD/hist-list.t" "$WORLD/hist-list.json"
  jq -n --argjson id "$1" --arg st "$2" --argjson at "$at" --argjson end "$end" --arg c "${ROW_COOKIE:-$COOKIE}" \
    '[{id:$id, start_time:$at, end_time:$end, rpmdb_version_begin:$c, status:$st, description:"dnf5 upgrade --offline -y",
       packages:[
        {nevra:"librepo-0:1.21.0-1.fc44.x86_64",action:"Upgrade"},{nevra:"librepo-0:1.20.0-1.fc44.x86_64",action:"Replaced"},
        {nevra:"aardvark-dns-2:1.18.0-1.fc44.x86_64",action:"Upgrade"},{nevra:"aardvark-dns-2:1.17.0-1.fc44.x86_64",action:"Replaced"},
        {nevra:"7zip-0:26.03-1.fc44.x86_64",action:"Upgrade"},{nevra:"7zip-0:26.02-1.fc44.x86_64",action:"Replaced"}]}]' \
    > "$WORLD/hist-info-$1.json"
}
check() { local rc=0; "$KEMPT" check >/dev/null 2>&1 || rc=$?; assert_eq "$rc" 0 "check ran"; }
said() { sed 's/^NOTIFY //' "$WORLD/notifications" | tr '\n' ' '; }
newest_entry() { ls "$KEMPT_STATE_DIR/history/"*.json 2>/dev/null | LC_ALL=C sort | tail -n 1; }
entries() { ls "$KEMPT_STATE_DIR/history/"*.json 2>/dev/null | wc -l; }
silent() { assert_eq "$(said)" "" "$1: nothing is said"; }
never() { assert_not_contains "$(said)" "No restart will install" "$1: never says it will not install"
          assert_not_contains "$("$KEMPT" status 2>&1)" "no restart will install" "$1: status does not say it either"; }
armed_published() { assert_eq "$(jq -r '.offline_staged.count' "$STATE_FILE")" "$2" "$1: count read from dnf5's list"; }

# --- really armed: nothing to report, and no will-not-install on any surface
world ready dnf5; sed -i '/rpmdb_cookie/d' "$TOML"; check
silent c02; never c02; armed_published c02 3
assert_contains "$("$KEMPT" status)" "3 updates ready for the next restart" "c02: status says ready"
assert_not_contains "$("$KEMPT" doctor 2>&1)" "will not install" "c02: doctor agrees"
assert_not_contains "$("$KEMPT" doctor 2>&1)" "staged outside Kempt" "c02: doctor does not call it foreign"

# --- cannot tell: said plainly, nothing claimed
world ready dnf5; chmod 000 "$TOML"; check
silent c03; never c03
assert_eq "$(jq -r '.offline_stage_problem' "$STATE_FILE")" "unknown" "c03: unreadable toml reads as unknown"
assert_eq "$(jq -r '.offline_staged // "none"' "$STATE_FILE")" "none" "c03: no count published over it"
assert_contains "$("$KEMPT" status)" "Kempt cannot tell what the next restart will do" "c03: status says it plainly"
assert_contains "$("$KEMPT" doctor 2>&1)" "cannot be read" "c03: doctor names why"
assert_contains "$("$KEMPT" doctor 2>&1)" "sudo dnf5 offline clean" "c03: doctor names the fix"
chmod 644 "$TOML"

world ready dnf5; chmod 000 "$TOML"; rpm_is "$NEW"; check
silent c03m; assert_eq "$(entries)" 0 "c03m: packages moved under an unreadable toml claim no install"
chmod 644 "$TOML"

world ready dnf5; : > "$TOML"; check
silent c04; never c04
assert_eq "$(jq -r '.offline_stage_problem' "$STATE_FILE")" "unknown" "c04: empty toml reads as unknown"

world ready dnf5; sed -i "s/^status = .*/status = 'ready'/" "$TOML"; check
silent c04q; never c04q
assert_not_contains "$(jq -r '.offline_stage_problem // "none"' "$STATE_FILE")" "lost" "c04q: quoting it does not know is never lost"

# A record with a status and no format version is a format this build has not seen.
world ready dnf5; sed -i '/^state_version/d' "$TOML"; check
assert_eq "$(jq -r .offline_stage_problem "$STATE_FILE")" unknown "no state_version: cannot tell"
assert_eq "$(jq -r '.offline_staged // "none"' "$STATE_FILE")" none "no state_version: not published as ready"
# Only what this build was measured against can be armed. A new dnf5 format is what `unknown` is for.
cannot_tell() {
  check
  assert_eq "$(jq -r .offline_stage_problem "$STATE_FILE")" unknown "$1: cannot tell"
  assert_eq "$(jq -r '.offline_staged // "none"' "$STATE_FILE")" none "$1: not published as armed"
  assert_not_contains "$("$KEMPT" status 2>&1)" "ready for the next restart" "$1: no promise on status"
}
world ready dnf5; sed -i 's/^state_version.*/state_version = 3/' "$TOML"; cannot_tell "another state_version"
world ready dnf5; sed -i 's/^state_version.*/state_version = 22/' "$TOML"; cannot_tell "a state_version beginning with 2"
world ready dnf5; rm -f "$TX"; cannot_tell "no transaction.json"
world ready dnf5; : > "$TX"; cannot_tell "empty transaction.json"
world ready dnf5; printf '{"version":"2.0","rpms":[{"nevra":"a-1-1.noarch","action":"Upgrade"}]}\n' > "$TX"; cannot_tell "another transaction.json version"
world ready dnf5; printf '{"version":"1.0","rpms":[]}\n' > "$TX"; cannot_tell "zero rpms"
world ready none; printf '{"version":"1.0","rpms":[]}\n' > "$TX"; cannot_tell "zero rpms and no link"

# --- something else armed: it is what dnf5 holds that is described
world ready dnf5; sed -i "s/^rpmdb_cookie = .*/rpmdb_cookie = \"$(printf 'a%.0s' {1..64})\"/" "$TOML"
cat > "$TX" <<'JSON'
{"version":"1.0","rpms":[{"nevra":"tOther-2-1.noarch","action":"Upgrade","reason":"User","repo_id":"r"}]}
JSON
check
silent c05; never c05; armed_published c05 1
assert_eq "$(jq -r '.offline_staged.names_source' "$STATE_FILE")" transaction "c05: names come from the stored transaction"

# --- ready, no link, everything already there: nothing to run and nothing lost
world ready none; rpm_is "$NEW"; check
silent c07; never c07; assert_eq "$(entries)" 0 "c07: claims no restart ran"
assert_contains "$("$KEMPT" doctor 2>&1)" "kempt unstage" "c07: doctor offers the tidy-up"

# c18 is the same on the same boot: a boot does not enter into it any more
world ready none; rpm_is "$NEW"; check; check
silent c18; never c18

# --- nothing stored: packages moving is not news, whichever way they went
world gone none; rpm_is 'librepo-0:1.21.0-1.fc44.x86_64'; row 7 Ok '/usr/bin/dnf5 upgrade -y'; check
silent c08; assert_eq "$(entries)" 0 "c08: a live run's row is not a restart"

world gone none; rpm_is 'librepo-0:1.19.0-1.fc44.x86_64'; check
silent c10

world gone none; rpm_is 'kernel-core-0:6.2.0-1.fc44.x86_64'; check
silent c11

# --- a restart that really installed: no snapshot was needed
world gone none; rpm_is "$NEW"; row 20 Ok 'dnf5 upgrade --offline -y'; check
assert_contains "$(said)" "were installed during the restart: 3 updated" "c13: the install is reported"
never c13
assert_eq "$(jq -r .surface "$(newest_entry)")" "offline (applied on reboot)" "c13: entry surface"
assert_eq "$(jq -r .transaction_id "$(newest_entry)")" 20 "c13: entry names dnf5's row"
assert_eq "$(jq -c '[.backends.dnf.updated[].name] | sort' "$(newest_entry)")" '["7zip","aardvark-dns","librepo"]' "c13: names from the row"
assert_eq "$(jq -r '.backends.dnf.updated[] | select(.name=="aardvark-dns").from' "$(newest_entry)")" "2:1.17.0-1.fc44" "c13: from version, epoch kept"
assert_eq "$(jq -r '.backends.dnf.updated[] | select(.name=="librepo").to' "$(newest_entry)")" "1.21.0-1.fc44" "c13: to version, epoch 0 dropped"
: > "$WORLD/notifications"; check
silent c13-again; assert_eq "$(entries)" 1 "c13: one restart is one entry"

# --- rpm cannot answer: no will-not-install on a guess
world ready none; export KEMPT_RPM_QA_CMD=false; check
silent c14; never c14
assert_eq "$(jq -r '.offline_stage_problem' "$STATE_FILE")" "unknown" "c14: rpm not answering is unknown"
export KEMPT_RPM_QA_CMD="cat $WORLD/rpm-qa"

# --- did not finish wins: history lists the plan, rpm says what arrived
world transaction-incomplete none; rpm_is 'librepo-0:1.21.0-1.fc44.x86_64' 'aardvark-dns-2:1.17.0-1.fc44.x86_64' '7zip-0:26.02-1.fc44.x86_64'
row 21 Error 'dnf5 upgrade --offline -y'; check
assert_contains "$(said)" "did not finish" "c15: says it did not finish"; never c15
assert_eq "$(jq -r .status "$(newest_entry)")" failed "c15: a failed entry"
assert_eq "$(jq -c '[.backends.dnf.updated[].name]' "$(newest_entry)")" '["librepo"]' "c15: only what arrived counts as updated"
assert_contains "$("$KEMPT" doctor 2>&1)" "dnf5 recorded a failure" "c15: doctor says what dnf5 recorded"
assert_contains "$("$KEMPT" status 2>&1)" "dnf5 recorded a failure" "c15: and status"
assert_contains "$("$KEMPT" doctor 2>&1)" "sudo dnf5 offline clean" "c15: doctor names the fix"
: > "$WORLD/notifications"; check
silent c15-again; assert_eq "$(entries)" 1 "c15: told once, one entry"

# %posttrans: Error, and everything arrived
world transaction-incomplete none; rpm_is "$NEW"; row 22 Error 'dnf5 upgrade --offline -y'; check
assert_contains "$(said)" "a package's script failed" "posttrans: says the script failed"
assert_not_contains "$(said)" "did not finish" "posttrans: not called unfinished"
assert_not_contains "$("$KEMPT" status 2>&1)" "did not finish" "posttrans: nor on status"
assert_contains "$("$KEMPT" status 2>&1)" "dnf5 recorded a failure" "posttrans: status says what dnf5 recorded"
assert_not_contains "$("$KEMPT" doctor 2>&1)" "did not finish" "posttrans: nor in doctor"
assert_contains "$("$KEMPT" doctor 2>&1)" "dnf5 recorded a failure" "posttrans: doctor says what dnf5 recorded"
assert_eq "$(jq -r .surface "$(newest_entry)")" "offline (applied on reboot)" "posttrans: they were applied"

# transaction-incomplete with no row to report: still a failed restart, and no count is invented
world transaction-incomplete none; check
assert_contains "$(said)" "did not finish" "no row: said"
assert_eq "$(jq -r .status "$(newest_entry)")" failed "no row: a failed entry"
assert_eq "$(jq -r '.backends.dnf.updated | length' "$(newest_entry)")" 0 "no row: no count"
assert_contains "$("$KEMPT" history 2>&1)" "did not finish" "no row: history reads"
: > "$WORLD/notifications"; check
assert_eq "$(entries)" 1 "no row: one entry"; silent no-row-again

# --- power loss: Started, cookie matches, link gone
world ready none; row 23 Started 'dnf5 upgrade --offline -y'; check
assert_contains "$(said)" "A restart stopped before" "power loss: told"
assert_eq "$(jq -r .offline_stage_problem "$STATE_FILE")" interrupted "power loss: the word"
assert_eq "$(jq -r .status "$(newest_entry)")" failed "power loss: failed entry"
assert_contains "$(jq -r .error "$(newest_entry)")" "stopped before" "power loss: entry reason"
assert_contains "$("$KEMPT" status)" "a restart began installing them and stopped" "power loss: status"

# --- lost link: told, offered the way back, told once
world ready none; check
assert_contains "$(said)" "No restart will install your prepared updates now." "lost: told"
assert_contains "$(said)" "kempt update --surface=offline" "lost: offered"
assert_eq "$(jq -r .offline_stage_problem "$STATE_FILE")" lost "lost: the word"
assert_eq "$(jq -r '.offline_staged // "none"' "$STATE_FILE")" none "lost: not published as ready"
assert_contains "$("$KEMPT" status)" "no restart will install them now" "lost: status"
assert_contains "$("$KEMPT" doctor 2>&1)" "kempt update --surface=offline" "lost: doctor offers it"
: > "$WORLD/notifications"; check
silent lost-again

# A notification that did not show is not remembered: the person hears at the next check that can.
world ready none; export KEMPT_NOTIFY="$TESTTMP/notify-fails"; mk notify-fails 'exit 1'
check
assert_not_contains "$(cat "$SHOWN")" "told=" "lost, notification failed: not remembered as told"
export KEMPT_NOTIFY="$TESTTMP/notify-stub"; check
assert_contains "$(said)" "No restart will install your prepared updates now." "lost: told at the next check that can show it"

# status reads now: the link going between checks is seen before the next check
world ready dnf5; check
assert_contains "$("$KEMPT" status)" "ready for the next restart" "between checks: ready while armed"
rm -f "$LINK"
assert_not_contains "$("$KEMPT" status)" "ready for the next restart" "between checks: not ready once the link went"
assert_contains "$("$KEMPT" status)" "no restart will install them now" "between checks: says so"

# The last run's line promises a restart only over an armed stage, and otherwise says what the run did.
staging_entry() {
  mkdir -p "$KEMPT_STATE_DIR/history"
  jq -n --arg t "$(date -d '1 hour ago' +%Y-%m-%dT%H:%M:%S%:z)" '{timestamp:$t,surface:"offline",status:"ok",staged:3,duration_sec:40,
    reboot_needed:false,log:"",error:"",backends:{dnf:{status:"ok",skipped_held:[],updated:[],added:[],removed:[]}}}' \
    > "$KEMPT_STATE_DIR/history/$(date -d '1 hour ago' +%Y%m%dT%H%M%S).json"
}
last_line() { "$KEMPT" status 2>&1 | tail -n 1; }
world ready dnf5; check; staging_entry
assert_contains "$(last_line)" "· staged 3 updates for a restart" "last run, armed: for a restart"
world gone none; check; staging_entry
assert_eq "$(last_line)" "Last update 1 hour ago · staged 3 updates" "last run, none: no restart promised"
world ready none; rpm_is "$NEW"; check; staging_entry
assert_eq "$(last_line)" "Last update 1 hour ago · staged 3 updates" "last run, done: no restart promised"
world ready dnf5; check; sed -i '/^state_version/d' "$TOML"; staging_entry
assert_eq "$(last_line)" "Last update 1 hour ago · staged 3 updates" "last run, unknown: no restart promised"
world ready dnf5; check; cp "$FIXTURES/offline-release-upgrade.toml" "$TOML"; staging_entry
assert_eq "$(last_line)" "Last update 1 hour ago · staged 3 updates" "last run, upgrade: no restart promised"
world ready none; check; staging_entry
assert_contains "$(last_line)" "but no restart will install them now" "last run, lost: says so"

# --- PackageKit installed its own: no command line, so not Kempt's to announce
world gone none; rpm_is "$NEW"; row 24 Ok null; jq '.[0].command_line = null' "$WORLD/hist-list.json" > "$WORLD/l" && mv "$WORLD/l" "$WORLD/hist-list.json"; check
silent packagekit; assert_eq "$(entries)" 0 "packagekit: no entry"

# --- a live command whose words only contain the flag is not a restart's row
world gone none; rpm_is "$NEW"; echo row=9 > "$SHOWN"; row 25 Ok 'dnf5 install foo--offline-tool'; row 26 Ok 'dnf5 install --offline-tool'; row 29 Ok 'dnf5 remove foo--offline'; check
silent "a package named like the flag"; assert_eq "$(entries)" 0 "...and no entry"
# ...and the flag first or last is still the flag.
world gone none; rpm_is "$NEW"; echo row=9 > "$SHOWN"; row 27 Ok 'dnf5 --offline upgrade'; row 28 Ok 'dnf5 upgrade --offline'; check
assert_eq "$(entries)" 2 "the flag anywhere as a word is a restart's row"

# --- `ready` with no link, downloaded or half downloaded: one word and one sentence, with no cause
for st in ready download-complete download-incomplete; do
  world "$st" none; check
  assert_contains "$(said)" "No restart will install your prepared updates now." "$st: told"
  assert_not_contains "$(said)" "cancelled" "$st: the notification gives no cause"
  assert_not_contains "$(said)" "no longer" "$st: the notification does not say it once would have"
  assert_eq "$(jq -r .offline_stage_problem "$STATE_FILE")" lost "$st: published as lost"
  assert_contains "$("$KEMPT" status 2>&1)" "Prepared updates: no restart will install them now. To prepare them again, run: kempt update --surface=offline" "$st: status says so"
  dr="$("$KEMPT" doctor 2>&1)"
  assert_contains "$dr" "dnf5 says \"$st\", and no restart will install them now" "$st: doctor prints the real status"
  assert_not_contains "$dr" "removed it" "$st: doctor gives no cause"
  assert_not_contains "$dr" "downloads nothing" "$st: doctor promises no download"
  : > "$WORLD/notifications"; check; silent "$st, told already"
done

# --- another updater holds the restart, and dnf5's list cannot be read or is empty: the holder is
# known all the same, and a clean would remove the other updater's link
for how in empty missing; do
  world ready other
  if [[ "$how" == empty ]]; then : > "$TX"; else rm -f "$TX"; fi
  assert_eq "$(bash -c '. "$1"; stage_read' _ "$REPO_ROOT/lib/common.sh")" other "$how list behind another updater: the word is other"
  check; silent "$how list behind another updater"
  assert_eq "$(jq -r 'has("offline_stage_blocked")' "$STATE_FILE")" true "$how list: published as blocked"
  assert_eq "$(jq -r 'has("offline_stage_problem")' "$STATE_FILE")" false "$how list: no problem published"
  assert_not_contains "$("$KEMPT" status 2>&1)" "cannot tell" "$how list: status can tell"
  dr="$("$KEMPT" doctor 2>&1)"
  assert_not_contains "$dr" "cannot tell what the stored update" "$how list: doctor can tell"
  assert_not_contains "$dr" "offline clean" "$how list: doctor offers no clean"
  assert_contains "$dr" "another updater has prepared the next restart" "$how list: doctor names the holder"
done

# --- two restarts since the last check: told oldest first, and the newest is what is remembered
world gone none; rpm_is "$NEW"; echo row=59 > "$SHOWN"; row 60 Ok 'dnf5 upgrade --offline -y'; row 61 Ok 'dnf5 upgrade --offline -y'; check
assert_eq "$(entries)" 2 "two rows: two entries"
assert_eq "$(grep '^row=' "$SHOWN")" "row=61" "two rows: the newest is remembered"
: > "$WORLD/notifications"; check
silent "two rows, the next check"; assert_eq "$(entries)" 2 "...and no third entry"

# --- an old Started row and a stage made since: that restart is not this stage's
world ready none; echo row=62 > "$SHOWN"; ROW_COOKIE=aaaa1111 row 62 Started 'dnf5 upgrade --offline -y'; check
assert_eq "$(jq -r .offline_stage_problem "$STATE_FILE")" lost "a Started row from another stage: lost, not interrupted"
assert_not_contains "$(said)" "stopped before" "...and no restart is said to have stopped"
# ...and only the newest row counts, whichever way the old one points.
world ready none; echo row=64 > "$SHOWN"; row 63 Started 'dnf5 upgrade --offline -y'; row 64 Ok 'dnf5 upgrade --offline -y'; check
assert_eq "$(jq -r .offline_stage_problem "$STATE_FILE")" lost "an old Started row under a newer Ok: lost"
world ready none; echo row=66 > "$SHOWN"; row 65 Ok 'dnf5 upgrade --offline -y'; row 66 Started 'dnf5 upgrade --offline -y'; check
assert_eq "$(jq -r .offline_stage_problem "$STATE_FILE")" interrupted "a Started row over an old Ok, from this stage: interrupted"

# --- one reading of the stage per check, because it costs seconds on a lost stage. The report asks
# the history once, and each reading once more.
list_calls() { grep -c '^list$' "$WORLD/hist-calls" 2>/dev/null || true; }
world ready none; : > "$WORLD/hist-calls"; check
assert_contains "$(said)" "No restart will install your prepared updates now." "the check that tells of a lost stage"
assert_eq "$(list_calls)" 3 "...reads it twice: to tell, and to publish"
: > "$WORLD/hist-calls"; check
assert_eq "$(list_calls)" 2 "the next check reads it once"
# The env cannot answer for the machine.
world ready dnf5; STAGE_WORD_NOW=lost check
assert_eq "$(jq -r '.offline_stage_problem // "none"' "$STATE_FILE")" none "a word in the environment is not a reading"

# --- memory: a history that does not answer writes none, or its old rows are all new at the next check
world gone none; row 40 Ok 'dnf5 upgrade --offline -y' 400000; row 41 Ok 'dnf5 upgrade --offline -y' 300000
KEMPT_DNF_HISTORY_CMD=/bin/false check
assert_eq "$(sed -n '/^row=/p' "$SHOWN" 2>/dev/null)" "" "history failed on the first check: no baseline"
silent "history failed"
check
silent "the history answers later, with old rows"; assert_eq "$(entries)" 0 "...and no entries for them"
assert_eq "$(grep '^row=' "$SHOWN")" "row=41" "...and the baseline is the newest"
# ...and a file with no valid row is no memory either.
for junk in 'told=abc' 'row=abc'; do
  world gone none; row 40 Ok 'dnf5 upgrade --offline -y' 400000; printf '%s\n' "$junk" > "$SHOWN"; check
  silent "memory is only $junk"; assert_eq "$(grep '^row=' "$SHOWN")" "row=40" "...and $junk gets a baseline"
done
# ...while an empty history answers: a row that arrives later is new.
world gone none; check; assert_eq "$(grep '^row=' "$SHOWN")" "row=0" "no offline rows yet: the baseline is zero"
row 42 Ok 'dnf5 upgrade --offline -y' 400000; check
assert_contains "$(said)" "were installed during the restart" "...so any later row is reported"

# --- upgrading from 0.2.0: it told of this restart itself and kept no row, so no second report
world gone none; rpm_is "$NEW"; row 50 Ok 'dnf5 upgrade --offline -y'
mkdir -p "$KEMPT_STATE_DIR/history"
jq -n --arg t "$(date +%Y-%m-%dT%H:%M:%S%:z)" '{timestamp:$t,surface:"offline (applied on reboot)",status:"ok",transaction_id:50,
  log:"",error:"",backends:{dnf:{status:"ok",skipped_held:[],updated:[],added:[],removed:[]}}}' > "$KEMPT_STATE_DIR/history/20260101T000000.json"
check
silent "0.2.0 already reported it"; assert_eq "$(entries)" 1 "...and no second entry"
assert_eq "$(grep '^row=' "$SHOWN")" "row=50" "...and the row is remembered"
# ...and a row that entry does not name is still a report.
row 51 Ok 'dnf5 upgrade --offline -y'; check
assert_contains "$(said)" "were installed during the restart" "the next restart is reported"; assert_eq "$(entries)" 2 "...with its entry"

# --- memory: an old restart is known, a recent one is not lost to a deleted folder
world gone none; row 30 Ok 'dnf5 upgrade --offline -y' 400000; check
silent old-row; assert_eq "$(entries)" 0 "old-row: no entry"
assert_contains "$(cat "$SHOWN")" "row=30" "old-row: baseline remembered"
row 31 Ok 'dnf5 upgrade --offline -y'; check
assert_contains "$(said)" "installed during the restart" "new row after a baseline is reported"

# --- deleting the state folder: one repeat at most, then quiet, and nothing lost to a stage still armed
world gone none; rpm_is "$NEW"; row 32 Ok 'dnf5 upgrade --offline -y'; check
rm -rf "$KEMPT_STATE_DIR"; : > "$WORLD/notifications"; check; check
assert_eq "$(wc -l < "$WORLD/notifications")" 1 "folder deleted after a restart: told once again, and no more"
world transaction-incomplete none; rpm_is "$OLD"; row 33 Error 'dnf5 upgrade --offline -y'; check
rm -rf "$KEMPT_STATE_DIR"; : > "$WORLD/notifications"; check; check
assert_eq "$(wc -l < "$WORLD/notifications")" 1 "folder deleted after a failed restart: told once again, and no more"

world gone none; rpm_is "$NEW"; row 32 Ok 'dnf5 upgrade --offline -y'; row 33 Ok 'dnf5 upgrade --offline -y'; check
rm -rf "$KEMPT_STATE_DIR"; : > "$WORLD/notifications"; check; check
assert_eq "$(wc -l < "$WORLD/notifications")" 1 "folder deleted with two recent restarts: told once, about the newest"
assert_eq "$(jq -r .transaction_id "$(newest_entry)")" 33 "...which is the one in the entry"

# --- the report's own record
world gone none; rpm_is "$NEW"; row 34 Ok 'dnf5 upgrade --offline -y'; check
_log="$(jq -r .log "$(newest_entry)")"
assert_contains "$(cat "$_log")" "Kempt's own record" "the log says what it is"
assert_contains "$(cat "$_log")" "dnf5 history info 34" "...and where dnf5's own account is"
# Filenames are per-second: one written this second must not be overwritten by the report.
world gone none; rpm_is "$NEW"; mkdir -p "$KEMPT_STATE_DIR/history"
for _o in -2 -1 0 1 2 3; do echo '{"decoy":true}' > "$KEMPT_STATE_DIR/history/$(date -d "$_o sec" +%Y%m%dT%H%M%S).json"; done
_decoys="$(entries)"; row 35 Ok 'dnf5 upgrade --offline -y'; check
assert_eq "$(entries)" "$(( _decoys + 1 ))" "a report landing on a used second adds an entry and overwrites none"
assert_eq "$(jq -r 'select(.decoy) | .decoy' "$KEMPT_STATE_DIR"/history/*.json | sort -u)" "true" "...and the entries there are intact"
# A history folder it cannot write to: the person is still told, and the check still publishes.
world gone none; rpm_is "$NEW"; mkdir -p "$KEMPT_STATE_DIR/history"; chmod 500 "$KEMPT_STATE_DIR/history"
row 36 Ok 'dnf5 upgrade --offline -y'; check
chmod 700 "$KEMPT_STATE_DIR/history"
assert_contains "$(said)" "installed during the restart" "history unwritable: still told"
assert_contains "$(cat "$KEMPT_STATE_DIR/events.log" 2>/dev/null)" "restart result not written" "history unwritable: the log says so"
assert_eq "$(jq -r .offline_staged "$STATE_FILE")" null "history unwritable: state still published"

# --- what 0.2.0 left: gone on the first check, with a stage still armed and reported correctly
world ready dnf5; mkdir -p "$KEMPT_STATE_DIR/snapshots"
echo '{"version":1,"staged":3}' > "$KEMPT_STATE_DIR/offline_staged.json"
: > "$KEMPT_STATE_DIR/offline-partial"; : > "$KEMPT_STATE_DIR/snapshots/offline-pre-x.tsv"
check
assert_exit 1 "upgrade: marker removed" -- test -e "$KEMPT_STATE_DIR/offline_staged.json"
assert_exit 1 "upgrade: pre-snapshot removed" -- test -e "$KEMPT_STATE_DIR/snapshots/offline-pre-x.tsv"
armed_published upgrade 3; silent upgrade

# --- same cookie, a different command: published from what is stored
world ready dnf5; sed -i 's/^cmd_line = .*/cmd_line = "dnf5 install --offline -y kernel-core"/' "$TOML"
cat > "$TX" <<'JSON'
{"version":"1.0","rpms":[{"nevra":"kernel-core-6.3.0-1.fc44.x86_64","action":"Install","reason":"User","repo_id":"updates"}]}
JSON
check
silent c21; armed_published c21 1
assert_eq "$(jq -r .offline_staged.names_source "$STATE_FILE")" transaction "c21: names from the stored transaction"

# --- T5: a stage armed with nothing of Kempt's on disk is whole on every surface
world ready dnf5; check
armed_published T5 3
holdout="$("$KEMPT" hold dnf:librepo 2>&1)"
assert_contains "$holdout" "still contains" "T5: hold warns the stage contains it"
check
assert_eq "$(jq -c .offline_staged.holds_conflict "$STATE_FILE")" '["librepo"]' "T5: conflict published"
assert_contains "$("$KEMPT" status)" "3 updates ready" "T5: status"
assert_contains "$("$KEMPT" doctor 2>&1)" "librepo" "T5: doctor names the conflict"
assert_not_contains "$("$KEMPT" doctor 2>&1)" "will not install" "T5: doctor does not deny it"
"$KEMPT" unhold dnf:librepo >/dev/null 2>&1

assert_eq "$(cat "$WORLD/path-calls")" "" "no real command was reached"
finish
