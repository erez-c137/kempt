#!/usr/bin/env bash
# notify: every notification Kempt sends leaves one events.log line saying whether it reached the
# desktop, and why not when it did not. The notify-send stand-ins only log or fail; nothing here
# talks to the session running the suite.
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
EV="$KEMPT_STATE_DIR/events.log"
BUS="unix:path=$TESTTMP/bus"

stub() {  # name body
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$TESTTMP/$1"; chmod +x "$TESTTMP/$1"
}
stub ok 'printf "%s|" "$@" >> "'"$TESTTMP"'/sent"'
stub fails 'exit 3'
stub hangs 'exec sleep 30'

last_event() { tail -1 "$EV" | cut -f2-; }
send() {  # notify-send-stand-in [bus]  (body is fixed)
  ( KEMPT_NOTIFY="$TESTTMP/$1"; DBUS_SESSION_BUS_ADDRESS="${2-}"; XDG_RUNTIME_DIR="$TESTTMP/no-runtime"
    NOTIFY_TIMEOUT=1
    notify "Kempt" "Updates are ready"$'\n'"and install on the next restart"
    echo "$NOTIFY_SHOWN" > "$TESTTMP/shown" )
}

send ok "$BUS"
assert_contains "$(last_event)" "notification shown: Updates are ready and install on the next restart" \
  "a notification that showed is logged with what it said, on one line"
assert_eq "$(cat "$TESTTMP/shown")" "true" "...and the caller is told it showed"
assert_eq "$(cat "$TESTTMP/sent")" "Kempt|Updates are ready"$'\n'"and install on the next restart|" \
  "...and notify-send got the text as given"

send ok ""
assert_contains "$(last_event)" "notification not shown (no desktop session): Updates are ready" \
  "with no session bus nothing is sent, and the line says why"
assert_eq "$(cat "$TESTTMP/shown")" "false" "...and the caller is told it did not show"

send fails "$BUS"
assert_contains "$(last_event)" "notification not shown (notify-send failed, exit 3):" "a failed send is logged with its exit"

send missing "$BUS"
assert_contains "$(last_event)" "notification not shown (notify-send is missing):" "a missing notify-send is named"

start=$SECONDS
send hangs "$BUS"
assert_contains "$(last_event)" "notification not shown (timed out):" "a send that never answers is logged as timed out"
[[ $((SECONDS - start)) -le 4 ]] || { echo "FAIL: a hung notify-send held the caller $((SECONDS - start)) s"; _fail=1; }

# Never fatal: a caller under errexit carries on after a failed notification.
out="$( set -e; KEMPT_NOTIFY="$TESTTMP/fails"; DBUS_SESSION_BUS_ADDRESS="$BUS"; notify "Kempt" "x"; echo after )"
assert_eq "$out" "after" "a failed notification never stops the caller"

# Plain words for the log view.
event_plain "notification shown: Your prepared updates are installed."
assert_eq "$EVENT_PLAIN" "Notified: Your prepared updates are installed." "a shown notification reads as Notified"
event_plain "notification not shown (no desktop session): Update failed: no network"
assert_eq "$EVENT_PLAIN" "Notification not shown (no desktop session): Update failed: no network" \
  "...and one that did not keeps its reason"

finish
