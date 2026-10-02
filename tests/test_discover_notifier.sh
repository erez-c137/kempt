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
# kstart and the binary "start" the notifier by making pgrep find it; a dud starts nothing.
stub kstart ": > $TESTTMP/running"
stub dud "exit 0"
export KEMPT_DISCOVER_PGREP="$TESTTMP/pgrep" KEMPT_DISCOVER_PKILL="$TESTTMP/pkill"
export KEMPT_DISCOVER_START="$TESTTMP/kstart" KEMPT_DISCOVER_START_POLLS=10
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

assert_contains "$out" "Started it for this session" "...and says so once pgrep finds it"
rm -f "$TESTTMP/running"

# The started notifier outlives the command, and must not take the writers' lock with it: a
# notifier holding it would make every later `config set`, `hold` or `unhold` wait 30 s and fail.
reset; system_entry
"$KEMPT" discover-notifier off >/dev/null
stub lingers ": > $TESTTMP/running; echo \$\$ > $TESTTMP/lingers.pid; exec sleep 60"
KEMPT_DISCOVER_START="$TESTTMP/lingers" "$KEMPT" discover-notifier on >/dev/null
wait_for_call "^lingers"
rc=0; timeout 10 "$KEMPT" config set restart_reminder true >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "config set right after on does not wait for the notifier's lock"
kill "$(cat "$TESTTMP/lingers.pid")" 2>/dev/null || true
rm -f "$TESTTMP/running" "$TESTTMP/lingers.pid"

# No kstart: the binary itself, detached. Neither: it starts at the next login.
stub notifier ": > $TESTTMP/running"
rm -f "$CALLS"
out="$(KEMPT_DISCOVER_START="$TESTTMP/no-kstart" KEMPT_DISCOVER_BIN="$TESTTMP/notifier" "$KEMPT" discover-notifier on)"
wait_for_call "^notifier" && echo "ok: without kstart, the binary is started" \
  || { echo "FAIL: binary not started - got: $(cat "$CALLS" 2>/dev/null)"; _fail=1; }
assert_contains "$out" "Started it" "...and found running"
rm -f "$TESTTMP/running" "$CALLS"
# kstart that starts nothing: the binary is tried next, and the message waits for pgrep.
out="$(KEMPT_DISCOVER_START="$TESTTMP/dud" KEMPT_DISCOVER_BIN="$TESTTMP/notifier" "$KEMPT" discover-notifier on)"
assert_contains "$(cat "$CALLS")" "dud --application" "a kstart that starts nothing is tried first"
assert_contains "$out" "Started it" "...then the binary, which does"
rm -f "$TESTTMP/running"
rc=0; out="$(KEMPT_DISCOVER_START="$TESTTMP/dud" KEMPT_DISCOVER_BIN="$TESTTMP/no-notifier" "$KEMPT" discover-notifier on)" || rc=$?
assert_eq "$rc" "0" "when nothing starts it, on still succeeds"
assert_not_contains "$out" "Started it" "...and never claims it started"
assert_contains "$out" "Could not start it now. It starts when you log in again." "...and says when it will"
rc=0; out="$(KEMPT_DISCOVER_START="$TESTTMP/no-kstart" KEMPT_DISCOVER_BIN="$TESTTMP/no-notifier" "$KEMPT" discover-notifier on)" || rc=$?
assert_eq "$rc" "0" "with nothing to start it with, on still succeeds"
assert_contains "$out" "log in again" "...and says it starts at the next login"

# The kill pattern is the binary at the start of a command line, nothing that merely names it.
grep -qE "$DISCOVER_PATTERN" <<<"$KEMPT_DISCOVER_BIN --check-delay 20" \
  && echo "ok: the pattern matches the notifier" || { echo "FAIL: pattern misses the notifier"; _fail=1; }
grep -qE "$DISCOVER_PATTERN" <<<"$KEMPT_DISCOVER_BIN" \
  && echo "ok: ...with no arguments too" || { echo "FAIL: pattern misses the bare notifier"; _fail=1; }
if grep -qE "$DISCOVER_PATTERN" <<<"less $KEMPT_DISCOVER_BIN"; then
  echo "FAIL: the pattern matches a pager reading the binary"; _fail=1
else echo "ok: ...and not a command that only names it"; fi

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

# off, then a new entry of the person's own, then off again: the first copy is never overwritten,
# and the new entry is not lost either. Nothing changes, and it says why.
reset; system_entry
mkdir -p "$(dirname "$USER_ENTRY")"
printf '[Desktop Entry]\nExec=/usr/libexec/DiscoverNotifier\nX-Own=A\n' > "$USER_ENTRY"
"$KEMPT" discover-notifier off >/dev/null
printf '[Desktop Entry]\nExec=/usr/libexec/DiscoverNotifier\nX-Own=B\n' > "$USER_ENTRY"
rc=0; out="$("$KEMPT" discover-notifier off 2>&1)" || rc=$?
assert_eq "$rc" "1" "off over a new entry of the person's own, with a copy already kept, refuses"
assert_contains "$out" "already kept at $BACKUP" "...and names the copy in the way"
assert_contains "$(cat "$USER_ENTRY")" "X-Own=B" "...leaving the new entry as it is"
assert_contains "$(cat "$BACKUP")" "X-Own=A" "...and the first copy as it was"

# A symlinked entry: the link itself is kept, and put back as a link to the same file.
reset; system_entry
mkdir -p "$(dirname "$USER_ENTRY")" "$TESTTMP/dotfiles"
printf '[Desktop Entry]\nExec=/usr/libexec/DiscoverNotifier\nX-Own=link\n' > "$TESTTMP/dotfiles/notifier.desktop"
ln -s "$TESTTMP/dotfiles/notifier.desktop" "$USER_ENTRY"
"$KEMPT" discover-notifier off >/dev/null
assert_eq "$(readlink "$BACKUP")" "$TESTTMP/dotfiles/notifier.desktop" "off keeps the symlink itself"
assert_eq "$([[ -L "$USER_ENTRY" ]] && echo link || echo file)" "file" "...and writes its own entry beside it"
assert_eq "$(grep -c '^Hidden=' "$TESTTMP/dotfiles/notifier.desktop" || true)" "0" "...without writing through the link"
"$KEMPT" discover-notifier on >/dev/null
assert_eq "$(readlink "$USER_ENTRY")" "$TESTTMP/dotfiles/notifier.desktop" "on puts the same symlink back"

# An entry of the person's own that hides it: on cannot turn it on, and says why.
reset; system_entry
mkdir -p "$(dirname "$USER_ENTRY")"
printf '[Desktop Entry]\nType=Application\nX-Own=1\nHidden=true\n' > "$USER_ENTRY"
own="$(cat "$USER_ENTRY")"
assert_eq "$("$KEMPT" discover-notifier status --json)" \
  '{"installed":true,"enabled":false,"running":false,"by_kempt":false,"entry":"'"$USER_ENTRY"'"}' "status: off by the person's own entry"
rc=0; out="$("$KEMPT" discover-notifier on 2>&1)" || rc=$?
assert_eq "$rc" "1" "on over the person's own hiding entry fails"
assert_contains "$out" "A startup file keeps Discover's notifier off: $USER_ENTRY. Delete it, then run kempt discover-notifier on." \
  "...and says which file keeps it off, and how to undo it"
assert_eq "$(cat "$USER_ENTRY")" "$own" "...and leaves that entry alone"

# The entry install.sh wrote before 0.1.8: a copy of the system entry plus Hidden=true. Nothing
# tells it apart from a copy the person hid themselves, so it is the person's: already off, it is
# left exactly as it is.
reset; system_entry
mkdir -p "$(dirname "$USER_ENTRY")"
{ cat "$SYS/$ENTRY"; echo Hidden=true; } > "$USER_ENTRY"
legacy="$(cat "$USER_ENTRY")"
assert_eq "$(discover_entry_kind)" "own" "a copy of the system entry plus Hidden=true is the person's"
rc=0; out="$("$KEMPT" discover-notifier off)" || rc=$?
assert_eq "$rc" "0" "off over an entry that already hides it succeeds"
assert_contains "$out" "already off. Nothing changed." "...and says it is already off"
assert_eq "$(cat "$USER_ENTRY")" "$legacy" "...leaving the entry as it was"
assert_eq "$(ls -A "$(dirname "$USER_ENTRY")" | wc -l)" "1" "...with nothing moved or added beside it"
assert_eq "$(is "$KEMPT_STATE_DIR/discover-offer-answered")" "yes" "...and answers the offer"
# The same shape with a key of the person's own, as System Settings can write: never parked.
reset; system_entry
mkdir -p "$(dirname "$USER_ENTRY")"
{ cat "$SYS/$ENTRY"; echo X-Own=1; echo Hidden=true; } > "$USER_ENTRY"
own="$(cat "$USER_ENTRY")"
"$KEMPT" discover-notifier off >/dev/null
assert_eq "$(cat "$USER_ENTRY")" "$own" "a hidden entry with a key of the person's own survives off"
rc=0; out="$("$KEMPT" discover-notifier on 2>&1)" || rc=$?
assert_eq "$rc" "1" "...and on says it cannot turn it on"
assert_contains "$out" "A startup file keeps Discover's notifier off" "...because the person's entry keeps it off"
assert_eq "$(cat "$USER_ENTRY")" "$own" "...and still leaves it as it was"
# The three-line entry it wrote when there was no system entry, byte for byte: Kempt's, removed.
reset; system_entry
mkdir -p "$(dirname "$USER_ENTRY")"
printf '[Desktop Entry]\nType=Application\nName=Discover Notifier\nHidden=true\n' > "$USER_ENTRY"
assert_eq "$(discover_entry_kind)" "kempt" "the earlier installer's exact three-line entry is Kempt's"
"$KEMPT" discover-notifier on >/dev/null
assert_eq "$(is "$USER_ENTRY")" "no" "...so on removes it"
printf '[Desktop Entry]\nType=Application\nName=Discover Notifier\nX-Own=1\nHidden=true\n' > "$USER_ENTRY"
assert_eq "$(discover_entry_kind)" "own" "...but one byte more and it is the person's"
# A plain copy of the system entry a person made is theirs, and comes back on on.
reset; system_entry
mkdir -p "$(dirname "$USER_ENTRY")"
cp "$SYS/$ENTRY" "$USER_ENTRY"
assert_eq "$(discover_entry_kind)" "own" "a plain copy of the system entry is the person's"
out="$("$KEMPT" discover-notifier off)"
assert_contains "$out" "Your earlier entry is kept at $BACKUP" "off says where the person's entry went"
out="$("$KEMPT" discover-notifier on)"
assert_contains "$out" "Your earlier entry is back at $USER_ENTRY" "on says it is back"
assert_eq "$(cat "$USER_ENTRY")" "$(cat "$SYS/$ENTRY")" "...and it is, as it was"

# Kempt's entry, edited by the person after off: on keeps the edit, and says where.
reset; system_entry
"$KEMPT" discover-notifier off >/dev/null
assert_eq "$(discover_entry_kind)" "kempt" "the entry off wrote is Kempt's, byte for byte"
printf 'X-Mine=1\n' >> "$USER_ENTRY"
edited="$(cat "$USER_ENTRY")"
assert_eq "$(discover_entry_kind)" "edited" "...and once edited it is not"
assert_contains "$("$KEMPT" discover-notifier status --json)" '"by_kempt":true' "...though status still says Kempt turned it off"
rc=0; out="$("$KEMPT" discover-notifier on)" || rc=$?
assert_eq "$rc" "0" "on over an edited entry turns the notifier on"
assert_contains "$out" "Your version is kept at $USER_ENTRY.kempt-edited" "...and says where the edit went"
assert_eq "$(cat "$USER_ENTRY.kempt-edited")" "$edited" "...which holds the edit"
assert_eq "$(is "$USER_ENTRY")" "no" "...with the entry itself gone"

# Not a file at all: a directory, or a symlink to nothing. Refused, and nothing written.
reset; system_entry
mkdir -p "$USER_ENTRY"
rc=0; out="$("$KEMPT" discover-notifier off 2>&1)" || rc=$?
assert_eq "$rc" "1" "off with a directory at the entry path refuses"
assert_contains "$out" "is not a file, so nothing changed" "...and says why"
assert_eq "$(ls -A "$USER_ENTRY" | wc -l)" "0" "...writing nothing into it"
assert_eq "$(ls -A "$(dirname "$USER_ENTRY")" | wc -l)" "1" "...or beside it"
rc=0; "$KEMPT" discover-notifier on >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "on refuses it too"
reset; system_entry
mkdir -p "$(dirname "$USER_ENTRY")"
ln -s "$TESTTMP/gone.desktop" "$USER_ENTRY"
rc=0; out="$("$KEMPT" discover-notifier off 2>&1)" || rc=$?
assert_eq "$rc" "1" "off with a symlink to nothing refuses"
assert_contains "$out" "is a symlink to $TESTTMP/gone.desktop, which does not exist" "...and says so plainly"
assert_not_contains "$out" "awk" "...with no tool's raw error"
assert_eq "$(readlink "$USER_ENTRY")" "$TESTTMP/gone.desktop" "...leaving the link as it was"
assert_eq "$(is "$BACKUP")" "no" "...and keeping no copy of it"

# Two offs at once, as the widget and Settings can: one at a time, and the copy is never lost.
reset; system_entry
mkdir -p "$(dirname "$USER_ENTRY")"
printf '[Desktop Entry]\nExec=/usr/libexec/DiscoverNotifier\nX-Own=race\n' > "$USER_ENTRY"
own="$(cat "$USER_ENTRY")"
"$KEMPT" discover-notifier off > "$TESTTMP/race1" 2>&1 & r1=$!
"$KEMPT" discover-notifier off > "$TESTTMP/race2" 2>&1 & r2=$!
rc1=0; wait "$r1" || rc1=$?
rc2=0; wait "$r2" || rc2=$?
assert_eq "$rc1 $rc2" "0 0" "two offs at once both succeed"
assert_eq "$(cat "$BACKUP")" "$own" "...and the person's entry is the copy kept"
assert_eq "$(cat "$TESTTMP/race1" "$TESTTMP/race2" | grep -c 'already off' || true)" "1" \
  "...because the second waited and found it already off"

# --- the widget's offer, as state.json carries it ------------------------------------------------------
reset; system_entry
assert_eq "$(discover_offer_pending && echo yes || echo no)" "yes" "an enabled notifier nobody has answered about is offered"
mkdir -p "$(dirname "$USER_ENTRY")"; cp "$SYS/$ENTRY" "$USER_ENTRY"; rm -f "$CALLS"
rc=0; out="$("$KEMPT" discover-notifier keep)" || rc=$?
assert_eq "$rc" "0" "keep succeeds"
assert_eq "$(discover_offer_pending && echo yes || echo no)" "no" "keep answers the offer"
assert_eq "$(cat "$USER_ENTRY")" "$(cat "$SYS/$ENTRY")" "...and leaves even a plain copy of the system entry alone"
assert_eq "$(is "$CALLS")" "no" "...and starts and stops nothing"
assert_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "discover-notifier keep" "...and is in kempt log"
reset
assert_contains "$("$KEMPT" discover-notifier keep)" "not installed" "keep without the notifier says so"
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
assert_exit 2 "keep takes no option" -- "$KEMPT" discover-notifier keep --json
assert_contains "$("$KEMPT" help)" "discover-notifier off | on | keep | status" "the help text lists it"

finish
