#!/usr/bin/env bash
# `kempt discover-notifier off|on|keep|status`: one marked file in ~/.config/autostart, and nothing
# else of the person's touched. Every outside command is a stub that only logs, so the notifier of
# the session running the suite is never found, stopped or started.
source "$(dirname "$0")/lib.sh"; sandbox
SYS="$TESTTMP/xdg-autostart"; mkdir -p "$SYS"
export KEMPT_XDG_AUTOSTART_DIR="$SYS"
source "$REPO_ROOT/lib/common.sh"
KEMPT="$REPO_ROOT/bin/kempt"

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
stub kstart ": > $TESTTMP/running"
stub dud "exit 0"
export KEMPT_DISCOVER_PGREP="$TESTTMP/pgrep" KEMPT_DISCOVER_PKILL="$TESTTMP/pkill" KEMPT_DISCOVER_START="$TESTTMP/kstart"
reset() {
  rm -rf "${SYS:?}/$ENTRY" "$XDG_CONFIG_HOME/autostart" "$KEMPT_STATE_DIR" "$CALLS" "$TESTTMP/running"
  mkdir -p "$(dirname "$USER_ENTRY")"
}
is() { [[ -e "$1" ]] && echo yes || echo no; }
# kstart is started detached, so its log line can land a moment after the command returns.
wait_for_call() { local _; for _ in 1 2 3 4 5 6 7 8 9 10; do grep -qs "$1" "$CALLS" && return 0; sleep 0.1; done; return 1; }
# The command, its status and its words. Run it with `attempt off`, then read rc and out.
attempt() { rc=0; out="$("$KEMPT" discover-notifier "$@" 2>&1)" || rc=$?; }

# --- not installed: off and on say so and change nothing ------------------------------------------
reset
attempt off
assert_eq "$rc" "0" "off without the notifier installed is not an error"
assert_contains "$out" "not installed" "...and says it is not installed"
assert_eq "$(is "$USER_ENTRY")" "no" "...and writes nothing"
assert_eq "$(is "$CALLS")" "no" "...and stops nothing"
assert_contains "$("$KEMPT" discover-notifier on)" "not installed" "on says the same"
assert_contains "$("$KEMPT" discover-notifier keep)" "not installed" "keep says the same"
assert_eq "$(is "$KEMPT_STATE_DIR/discover-offer-answered")" "no" "...and no answer is recorded"
assert_eq "$("$KEMPT" discover-notifier status --json)" \
  '{"installed":false,"enabled":false,"running":false,"by_kempt":false,"unattended":false}' "status --json says not installed"

# --- off: one marked file, and the running notifier stopped ---------------------------------------
reset; system_entry; : > "$TESTTMP/running"
assert_eq "$("$KEMPT" discover-notifier status --json)" \
  '{"installed":true,"enabled":true,"running":true,"by_kempt":false,"unattended":false}' "status: installed, on and running"
assert_contains "$("$KEMPT" discover-notifier status)" "notifier: on" "...and the text form says on"
attempt off
assert_eq "$rc" "0" "off succeeds"
assert_contains "$out" "is off" "...and says it is off"
assert_contains "$out" "Stopped the one that was running" "...and that it stopped the running one"
assert_eq "$(cat "$USER_ENTRY")" $'[Desktop Entry]\nType=Application\nName=Discover\nHidden=true\nX-Kempt-Override=true' \
  "the file is the group, a valid name and type, Hidden=true and the mark"
assert_contains "$(cat "$CALLS")" "pkill -u $(id -u) -f" "pkill is limited to this user's processes"
assert_eq "$(is "$TESTTMP/running")" "no" "...and the notifier is no longer running"
assert_eq "$("$KEMPT" discover-notifier status --json)" \
  '{"installed":true,"enabled":false,"running":false,"by_kempt":true,"unattended":false}' "status: off, by Kempt"
assert_contains "$("$KEMPT" discover-notifier status)" "turned off by Kempt" "...in words too"
assert_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "Discover's update notifier turned off" "the change is in kempt log"
attempt off
assert_contains "$out" "already off" "off again says so"
assert_eq "$(grep -c '^Hidden=' "$USER_ENTRY")" "1" "...and leaves one Hidden= line"

# Kempt's own file with the Hidden line taken out, so it starts: off writes it again.
sed -i '/^Hidden=/d' "$USER_ENTRY"
attempt off
assert_eq "$rc|$(grep -c '^Hidden=true$' "$USER_ENTRY")" "0|1" "off puts Hidden back in Kempt's own file"

# --- on: Kempt's file removed, and the notifier started again ----------------------------------------
reset; system_entry
"$KEMPT" discover-notifier off >/dev/null
attempt on
assert_eq "$rc" "0" "on succeeds"
assert_contains "$out" "is on" "...and says it is on"
assert_contains "$out" "Started it for this session" "...and that it started, once pgrep finds it"
assert_eq "$(is "$USER_ENTRY")" "no" "on removes the file Kempt wrote"
wait_for_call "kstart --application org.kde.discover.notifier" \
  && echo "ok: on starts the notifier through kstart --application" \
  || { echo "FAIL: kstart not called - got: $(cat "$CALLS" 2>/dev/null)"; _fail=1; }
assert_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "Discover's update notifier turned on" "the change is in kempt log"
rm -f "$CALLS"
"$KEMPT" discover-notifier on >/dev/null
sleep 0.3
assert_eq "$(grep -c kstart "$CALLS" || true)" "0" "a notifier already running is not started again"

# The started notifier outlives the command, and must not take the writers' lock with it: a
# notifier holding it would make every later `config set`, `hold` or `unhold` wait 30 s and fail.
reset; system_entry
"$KEMPT" discover-notifier off >/dev/null
stub lingers ": > $TESTTMP/running; echo \$\$ > $TESTTMP/lingers.pid; exec sleep 60"
KEMPT_DISCOVER_START="$TESTTMP/lingers" "$KEMPT" discover-notifier on >/dev/null
wait_for_call "^lingers"
rc=0; timeout 10 "$KEMPT" config set auto_accept true >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "config set right after on does not wait for the notifier's lock"
kill "$(cat "$TESTTMP/lingers.pid")" 2>/dev/null || true
rm -f "$TESTTMP/running" "$TESTTMP/lingers.pid"

# A starter that starts nothing, or none at all: never a claim that it started.
out="$(KEMPT_DISCOVER_START="$TESTTMP/dud" "$KEMPT" discover-notifier on)"; rc=$?
assert_eq "$rc" "0" "when nothing starts it, on still succeeds"
assert_not_contains "$out" "Started it" "...and never claims it started"
assert_contains "$out" "Could not start it now. It starts when you log in again." "...and says when it will"

# The kill pattern is the binary at the start of a command line, nothing that merely names it.
BIN=/usr/libexec/DiscoverNotifier
grep -qE "$DISCOVER_PATTERN" <<<"$BIN --check-delay 20" \
  && echo "ok: the pattern matches the notifier" || { echo "FAIL: pattern misses the notifier"; _fail=1; }
grep -qE "$DISCOVER_PATTERN" <<<"$BIN" \
  && echo "ok: ...with no arguments too" || { echo "FAIL: pattern misses the bare notifier"; _fail=1; }
if grep -qE "$DISCOVER_PATTERN" <<<"less $BIN"; then
  echo "FAIL: the pattern matches a pager reading the binary"; _fail=1
else echo "ok: ...and not a command that only names it"; fi

# --- a file Kempt did not write: never altered or deleted, and named ---------------------------------
reset; system_entry; : > "$TESTTMP/running"
printf '[Desktop Entry]\nType=Application\nExec=/usr/libexec/DiscoverNotifier --check-delay 600\nX-Own=1\n' > "$USER_ENTRY"
chmod 600 "$USER_ENTRY"
own="$(cat "$USER_ENTRY")"
attempt off
assert_eq "$rc" "1" "off over the person's own file refuses"
assert_contains "$out" "Kempt did not write $USER_ENTRY, so nothing changed." "...and names the file"
assert_contains "$out" "Add Hidden=true to its [Desktop Entry] group, or delete it and run kempt discover-notifier off" "...and says what to do"
assert_eq "$(cat "$USER_ENTRY")" "$own" "...leaving it as it was"
assert_eq "$(stat -c %a "$USER_ENTRY")" "600" "...with its permissions"
assert_eq "$(is "$BACKUP")" "no" "...with no copy beside it"
assert_eq "$(is "$TESTTMP/running")" "yes" "...and stops nothing"
assert_eq "$(is "$KEMPT_STATE_DIR/discover-offer-answered")" "no" "...and answers nothing"
attempt on
assert_eq "$rc" "0" "on with the person's own file that starts it succeeds"
assert_eq "$(cat "$USER_ENTRY")" "$own" "...and leaves that file alone"

# The mark counts only as a whole line. In a comment or a value it is the person's words.
for line in '# X-Kempt-Override=true' 'Comment=X-Kempt-Override=true'; do
  reset; system_entry
  printf '[Desktop Entry]\nType=Application\nExec=/usr/libexec/DiscoverNotifier\n%s\n' "$line" > "$USER_ENTRY"
  own="$(cat "$USER_ENTRY")"
  attempt off
  assert_eq "$rc|$(cat "$USER_ENTRY")" "1|$own" "off refuses a file with \"$line\" and leaves it alone"
  attempt on
  assert_eq "$rc|$(cat "$USER_ENTRY")" "0|$own" "...and on leaves it alone too"
  printf 'Hidden=true\n' >> "$USER_ENTRY"
  own="$(cat "$USER_ENTRY")"
  attempt on
  assert_eq "$rc|$(cat "$USER_ENTRY")" "1|$own" "...and refuses it when it hides the notifier"
done

# A plain copy of the system entry is the person's too.
reset; system_entry
cp "$SYS/$ENTRY" "$USER_ENTRY"
attempt off
assert_eq "$rc|$(cat "$USER_ENTRY")" "1|$(cat "$SYS/$ENTRY")" "a plain copy of the system entry is the person's, and stays"

# The person's own file that hides it: off has nothing to do, on cannot do it, and says why.
reset; system_entry
printf '[Desktop Entry]\nType=Application\nX-Own=1\nHidden=true\n' > "$USER_ENTRY"
own="$(cat "$USER_ENTRY")"
assert_eq "$("$KEMPT" discover-notifier status --json)" \
  '{"installed":true,"enabled":false,"running":false,"by_kempt":false,"unattended":false,"entry":"'"$USER_ENTRY"'"}' "status: off by the person's own entry"
assert_contains "$("$KEMPT" discover-notifier status)" "off (by $USER_ENTRY)" "...in words too"
attempt off
assert_eq "$rc" "0" "off over the person's own hiding file is nothing to do"
assert_contains "$out" "already off" "...and says so"
assert_eq "$(cat "$USER_ENTRY")" "$own" "...and leaves it alone"
attempt on
assert_eq "$rc" "1" "on over the person's own hiding file fails"
assert_contains "$out" "A startup file keeps Discover's notifier off: $USER_ENTRY. Delete it, then run kempt discover-notifier on." \
  "...and says which file keeps it off, and how to undo it"
assert_eq "$(cat "$USER_ENTRY")" "$own" "...and leaves it alone"

# A symlink, even to a file with the mark: the person's. Nothing is written through it.
reset; system_entry
mkdir -p "$TESTTMP/dotfiles"
printf '[Desktop Entry]\nExec=x\nX-Kempt-Override=true\n' > "$TESTTMP/dotfiles/notifier.desktop"
own="$(cat "$TESTTMP/dotfiles/notifier.desktop")"
ln -s "$TESTTMP/dotfiles/notifier.desktop" "$USER_ENTRY"
attempt off
assert_eq "$rc" "1" "off over a symlink refuses"
assert_contains "$out" "Kempt did not write $USER_ENTRY" "...and names it"
assert_eq "$(readlink "$USER_ENTRY")|$(cat "$TESTTMP/dotfiles/notifier.desktop")" "$TESTTMP/dotfiles/notifier.desktop|$own" "...leaving link and target as they were"

# Not a file at all: a directory, or a symlink to nothing.
reset; system_entry
mkdir -p "$USER_ENTRY"
attempt off
assert_eq "$rc" "1" "off with a directory at the path refuses"
assert_contains "$out" "$USER_ENTRY" "...and names it"
assert_eq "$(ls -A "$USER_ENTRY" | wc -l)" "0" "...writing nothing into it"
reset; system_entry
ln -s "$TESTTMP/gone.desktop" "$USER_ENTRY"
attempt off
assert_eq "$rc" "1" "off with a symlink to nothing refuses"
assert_eq "$(readlink "$USER_ENTRY")" "$TESTTMP/gone.desktop" "...leaving the link as it was"

# A file that cannot be read cannot be shown to be Kempt's.
reset; system_entry
printf '[Desktop Entry]\nX-Kempt-Override=true\n' > "$USER_ENTRY"
chmod 000 "$USER_ENTRY"
if [[ -r "$USER_ENTRY" ]]; then echo "ok: (running as root, the unreadable case is skipped)"
else
  attempt off
  assert_eq "$rc" "1" "off with an unreadable file refuses"
  assert_contains "$out" "Kempt did not write $USER_ENTRY" "...and names it"
  attempt on
  assert_eq "$(is "$USER_ENTRY")" "yes" "on leaves it there"
fi
chmod 644 "$USER_ENTRY"

# --- upgrade: what 0.2.0 wrote is Kempt's, and its kept copy comes back ---------------------------------
# What 0.2.0's discover_write_entry wrote: the seed's keys, with Hidden=true and the mark in the group.
from_020() { awk 'NR == 1 { print; print "Hidden=true"; print "X-Kempt-Override=true"; next } { print }' "$1" > "$USER_ENTRY"; }
reset; system_entry
from_020 "$SYS/$ENTRY"
assert_contains "$("$KEMPT" discover-notifier status --json)" '"by_kempt":true' "0.2.0's entry is Kempt's"
attempt off
assert_contains "$out" "already off" "...off leaves it"
attempt on
assert_eq "$rc|$(is "$USER_ENTRY")" "0|no" "...and on removes it"

reset; system_entry
printf '[Desktop Entry]\nExec=/usr/libexec/DiscoverNotifier\nX-Own=1\n' > "$BACKUP"
chmod 600 "$BACKUP"; own="$(cat "$BACKUP")"
from_020 "$BACKUP"
attempt on
assert_eq "$rc" "0" "on after 0.2.0 kept a person's entry succeeds"
assert_contains "$out" "Your earlier entry is back at $USER_ENTRY" "...and says it is back"
assert_eq "$(cat "$USER_ENTRY")|$(stat -c %a "$USER_ENTRY")" "$own|600" "...as it was"
assert_eq "$(is "$BACKUP")" "no" "...with the copy gone"

# Kept as a symlink, it comes back as one.
reset; system_entry
mkdir -p "$TESTTMP/dotfiles"; printf '[Desktop Entry]\nExec=x\n' > "$TESTTMP/dotfiles/n.desktop"
ln -s "$TESTTMP/dotfiles/n.desktop" "$BACKUP"
from_020 "$TESTTMP/dotfiles/n.desktop"
"$KEMPT" discover-notifier on >/dev/null
assert_eq "$(readlink "$USER_ENTRY")" "$TESTTMP/dotfiles/n.desktop" "a kept symlink comes back as a symlink"

# A kept copy with a newer file of the person's in its place: both stay, and the copy is named.
reset; system_entry
printf '[Desktop Entry]\nX-Own=old\n' > "$BACKUP"
printf '[Desktop Entry]\nX-Own=new\n' > "$USER_ENTRY"
attempt on
assert_eq "$rc" "0" "on with a kept copy and a newer file of the person's succeeds"
assert_contains "$out" "Your earlier entry is still kept at $BACKUP" "...and names the copy"
assert_contains "$(cat "$USER_ENTRY")" "X-Own=new" "...leaving the newer file"
assert_contains "$(cat "$BACKUP")" "X-Own=old" "...and the copy"

# --- the widget's offer, as state.json carries it ------------------------------------------------------
reset; system_entry
assert_eq "$(discover_offer_pending && echo yes || echo no)" "yes" "an enabled notifier nobody has answered about is offered"
rm -f "$CALLS"
attempt keep
assert_eq "$rc" "0" "keep succeeds"
assert_eq "$(discover_offer_pending && echo yes || echo no)" "no" "keep answers the offer"
assert_eq "$(is "$USER_ENTRY")|$(is "$CALLS")" "no|no" "...writes nothing, and starts and stops nothing"
assert_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "Discover's update notifier kept as it is" "...and is in kempt log"
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
