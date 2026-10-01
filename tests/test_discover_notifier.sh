#!/usr/bin/env bash
# `kempt discover-notifier off|on|status`: Discover's update notifier, turned off or back on for this
# user through ~/.config/autostart. Every outside command is a stub that only logs, so the notifier
# of the session running the suite is never found, stopped or started.
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
KEMPT="$REPO_ROOT/bin/kempt"

SYS="$TESTTMP/xdg-autostart"; mkdir -p "$SYS"
export KEMPT_XDG_AUTOSTART_DIR="$SYS"
ENTRY=org.kde.discover.notifier.desktop
USER_ENTRY="$XDG_CONFIG_HOME/autostart/$ENTRY"
BACKUP="$USER_ENTRY.before-kempt"
CALLS="$TESTTMP/calls"
system_entry() {
  printf '[Desktop Entry]\nName=Discover\nExec=/usr/libexec/DiscoverNotifier --check-delay 20\nType=Application\nX-KDE-autostart-phase=1\nOnlyShowIn=KDE\n' \
    > "$SYS/$ENTRY"
}
# A stub per command. pgrep answers from $TESTTMP/running, the way the real one answers from /proc.
stub() {  # name body
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >> "%s"\n%s\n' "$1" "$CALLS" "$2" > "$TESTTMP/$1"
  chmod +x "$TESTTMP/$1"
}
stub pgrep "[[ -e $TESTTMP/running ]]"
stub pkill "[[ -e $TESTTMP/running ]] && rm -f $TESTTMP/running"
stub kstart "exit 0"
export KEMPT_DISCOVER_PGREP="$TESTTMP/pgrep" KEMPT_DISCOVER_PKILL="$TESTTMP/pkill"
export KEMPT_DISCOVER_START="$TESTTMP/kstart"
reset() { rm -rf "${SYS:?}/$ENTRY" "$XDG_CONFIG_HOME/autostart" "$KEMPT_STATE_DIR" "$CALLS" "$TESTTMP/running"; }
is() { [[ -e "$1" ]] && echo yes || echo no; }
# kstart is started detached, so its log line can land a moment after the command returns.
wait_for_call() { local _; for _ in 1 2 3 4 5 6 7 8 9 10; do grep -qs "$1" "$CALLS" && return 0; sleep 0.1; done; return 1; }

# --- not installed: off and on say so and change nothing ------------------------------------------
reset
rc=0; out="$("$KEMPT" discover-notifier off)" || rc=$?
assert_eq "$rc" "0" "off without the notifier installed is not an error"
assert_contains "$out" "not installed" "...and says it is not installed"
assert_eq "$(is "$USER_ENTRY")" "no" "...and writes nothing"
assert_eq "$(is "$CALLS")" "no" "...and stops nothing"
out="$("$KEMPT" discover-notifier on)"
assert_contains "$out" "not installed" "on says the same"
assert_eq "$(is "$KEMPT_STATE_DIR/discover-offer-answered")" "no" "...and records no answer"
assert_eq "$("$KEMPT" discover-notifier status --json)" \
  '{"installed":false,"enabled":false,"running":false,"by_kempt":false}' "status --json says not installed"

# --- off: a marked override, and the running notifier stopped ---------------------------------------
reset; system_entry; : > "$TESTTMP/running"
assert_eq "$("$KEMPT" discover-notifier status --json)" \
  '{"installed":true,"enabled":true,"running":true,"by_kempt":false}' "status: installed, on and running"
assert_contains "$("$KEMPT" discover-notifier status)" "notifier: on" "...and the text form says on"
out="$("$KEMPT" discover-notifier off)"
assert_contains "$out" "is off" "off says it is off"
assert_contains "$out" "Stopped the one that was running" "...and that it stopped the running one"
assert_eq "$(grep -c '^Hidden=true$' "$USER_ENTRY")" "1" "the override hides the notifier"
assert_eq "$(grep -c '^X-Kempt-Override=true$' "$USER_ENTRY")" "1" "...and carries Kempt's mark"
assert_eq "$(sed -n 2p "$USER_ENTRY")" "Hidden=true" "...inside the [Desktop Entry] group"
grep -q '^Exec=/usr/libexec/DiscoverNotifier' "$USER_ENTRY" && echo "ok: the system entry's keys are kept" \
  || { echo "FAIL: Exec lost"; _fail=1; }
assert_contains "$(cat "$CALLS")" "pkill -u $(id -u) -f" "pkill is limited to this user's processes"
assert_eq "$(is "$TESTTMP/running")" "no" "...and the notifier is no longer running"
assert_eq "$(is "$BACKUP")" "no" "with no entry of the person's own, nothing is backed up"
assert_eq "$("$KEMPT" discover-notifier status --json)" \
  '{"installed":true,"enabled":false,"running":false,"by_kempt":true}' "status: off, by Kempt"
assert_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "discover-notifier off" "the change is in kempt log"
"$KEMPT" discover-notifier off >/dev/null
"$KEMPT" discover-notifier off >/dev/null
assert_eq "$(grep -c '^Hidden=' "$USER_ENTRY")" "1" "off again never adds a second Hidden= line"
assert_eq "$(grep -c '^X-Kempt-Override=' "$USER_ENTRY")" "1" "...or a second mark"

# A system entry with Hidden=false and a second group: one Hidden= line, in the right group.
reset; printf '[Desktop Entry]\nType=Application\nHidden=false\nExec=x\n[Desktop Action foo]\nName=Foo\n' > "$SYS/$ENTRY"
"$KEMPT" discover-notifier off >/dev/null
assert_eq "$(grep -c '^Hidden=' "$USER_ENTRY")" "1" "a Hidden=false from the system entry is replaced"
assert_eq "$(awk '/^\[Desktop Action/ {exit} /^Hidden=true$/ {print "first"}' "$USER_ENTRY")" "first" \
  "...and Hidden=true sits in the [Desktop Entry] group, not the last one"

# --- on: Kempt's file removed, and the notifier started again ----------------------------------------
reset; system_entry
"$KEMPT" discover-notifier off >/dev/null
rc=0; out="$("$KEMPT" discover-notifier on)" || rc=$?
assert_eq "$rc" "0" "on succeeds"
assert_contains "$out" "is on" "...and says it is on"
assert_eq "$(is "$USER_ENTRY")" "no" "on removes the file Kempt wrote"
wait_for_call "kstart --application org.kde.discover.notifier" \
  && echo "ok: on starts the notifier through kstart --application" \
  || { echo "FAIL: kstart not called - got: $(cat "$CALLS" 2>/dev/null)"; _fail=1; }
assert_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "discover-notifier on" "the change is in kempt log"
# Already running: nothing is started twice.
rm -f "$CALLS"; : > "$TESTTMP/running"
"$KEMPT" discover-notifier on >/dev/null
sleep 0.3
assert_eq "$(grep -c kstart "$CALLS" || true)" "0" "a notifier already running is not started again"
rm -f "$TESTTMP/running"

# No kstart: the binary itself, detached. Neither: it starts at the next login.
stub notifier "exit 0"
rm -f "$CALLS"
out="$(KEMPT_DISCOVER_START="$TESTTMP/no-kstart" KEMPT_DISCOVER_BIN="$TESTTMP/notifier" "$KEMPT" discover-notifier on)"
wait_for_call "^notifier" && echo "ok: without kstart, the binary is started" \
  || { echo "FAIL: binary not started - got: $(cat "$CALLS" 2>/dev/null)"; _fail=1; }
rc=0; out="$(KEMPT_DISCOVER_START="$TESTTMP/no-kstart" KEMPT_DISCOVER_BIN="$TESTTMP/no-notifier" "$KEMPT" discover-notifier on)" || rc=$?
assert_eq "$rc" "0" "with nothing to start it with, on still succeeds"
assert_contains "$out" "log in again" "...and says it starts at the next login"

# --- the person's own entry: kept on off, and put back exactly on on ----------------------------------
reset; system_entry
mkdir -p "$(dirname "$USER_ENTRY")"
printf '[Desktop Entry]\nType=Application\nExec=/usr/libexec/DiscoverNotifier --check-delay 600\nX-Own=1\n' > "$USER_ENTRY"
chmod 600 "$USER_ENTRY"
own="$(cat "$USER_ENTRY")"
"$KEMPT" discover-notifier off >/dev/null
assert_eq "$(cat "$BACKUP")" "$own" "off keeps a copy of the person's own entry"
assert_eq "$(grep -c '^Hidden=true$' "$USER_ENTRY")" "1" "...and hides the notifier"
grep -q '^X-Own=1' "$USER_ENTRY" && echo "ok: ...keeping the person's own keys" || { echo "FAIL: own keys lost"; _fail=1; }
"$KEMPT" discover-notifier off >/dev/null
assert_eq "$(cat "$BACKUP")" "$own" "a second off leaves that copy alone"
"$KEMPT" discover-notifier on >/dev/null
assert_eq "$(cat "$USER_ENTRY")" "$own" "on puts the person's own entry back as it was"
assert_eq "$(stat -c %a "$USER_ENTRY")" "600" "...with its permissions"
assert_eq "$(is "$BACKUP")" "no" "...and removes the copy"

# An entry of the person's own that hides it: on cannot turn it on, and says why.
reset; system_entry
mkdir -p "$(dirname "$USER_ENTRY")"
printf '[Desktop Entry]\nType=Application\nX-Own=1\nHidden=true\n' > "$USER_ENTRY"
own="$(cat "$USER_ENTRY")"
assert_eq "$("$KEMPT" discover-notifier status --json)" \
  '{"installed":true,"enabled":false,"running":false,"by_kempt":false}' "status: off by the person's own entry"
rc=0; out="$("$KEMPT" discover-notifier on 2>&1)" || rc=$?
assert_eq "$rc" "1" "on over the person's own hiding entry fails"
assert_contains "$out" "Your own autostart entry" "...and says their own entry keeps it off"
assert_eq "$(cat "$USER_ENTRY")" "$own" "...and leaves that entry alone"

# The entry install.sh wrote before the mark: a copy of the system entry plus Hidden=true.
reset; system_entry
mkdir -p "$(dirname "$USER_ENTRY")"
{ cat "$SYS/$ENTRY"; echo Hidden=true; } > "$USER_ENTRY"
assert_eq "$(discover_entry_is_kempts && echo yes || echo no)" "yes" "an entry from the earlier installer counts as Kempt's"
"$KEMPT" discover-notifier on >/dev/null
assert_eq "$(is "$USER_ENTRY")" "no" "...so on removes it"
assert_eq "$(is "$BACKUP")" "no" "...with nothing to put back"

# --- the widget's offer, as state.json carries it ------------------------------------------------------
reset; system_entry
assert_eq "$(discover_offer_pending && echo yes || echo no)" "yes" "an enabled notifier nobody has answered about is offered"
"$KEMPT" discover-notifier on >/dev/null
assert_eq "$(discover_offer_pending && echo yes || echo no)" "no" "Keep It (on) answers the offer"
reset; system_entry
"$KEMPT" discover-notifier off >/dev/null
rm -f "$KEMPT_STATE_DIR/discover-offer-answered"
assert_eq "$(discover_offer_pending && echo yes || echo no)" "no" "a notifier that is off is not offered"
reset
assert_eq "$(discover_offer_pending && echo yes || echo no)" "no" "...and neither is one that is not installed"

# --- usage -----------------------------------------------------------------------------------------------
assert_exit 2 "no verb is a usage error" -- "$KEMPT" discover-notifier
assert_exit 2 "an unknown verb is a usage error" -- "$KEMPT" discover-notifier pause
assert_exit 2 "an option off does not take is a usage error" -- "$KEMPT" discover-notifier off --json
assert_contains "$("$KEMPT" help)" "discover-notifier off | on | status" "the help text lists it"

finish
