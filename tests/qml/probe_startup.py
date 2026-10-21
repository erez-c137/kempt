#!/usr/bin/env python3
"""The startup banner: a service that stopped starting after an update.

The node tests pin every sentence and command logic.js derives. This proves the QML routes them:
the banner draws one message per service, Copy Command puts the right command on the clipboard,
Mute Until It Starts reaches the CLI with the unit as ONE argument, the "running again" line is
acknowledged by its digest only while the popup is open and stays until it closes, and the panel
count never moves. Then the settings page: the notify_startup round trip and the muted list.
"""
import json
import os
import sys

import harness

if not harness.have_pyside():
    print("ok: SKIPPED - PySide6 absent")
    sys.exit(0)

p = harness.Probe("probe-startup")
os.makedirs(p.state)
STATE_JSON = os.path.join(p.state, "state.json")
SRC = os.path.join(p.sandbox, "src.json")       # what `kempt check` serves
ACKRC = os.path.join(p.sandbox, "ackrc")
MUTERC = os.path.join(p.sandbox, "muterc")
MUTEMSG = os.path.join(p.sandbox, "mutemsg")    # what a failed mute says on stderr
VALUES = os.path.join(p.sandbox, "values")      # the settings page's stored config
os.makedirs(VALUES)
STARTUP_JSON = os.path.join(p.sandbox, "startup.json")   # what `kempt startup --json` answers

BT = {"unit": "bluetooth.service", "scope": "system", "description": "Bluetooth service",
      "since": "2026-10-20T20:33:15+03:00"}
ESCAPED = "systemd-fsck@dev-disk-by\\x2duuid-1.service"
HOSTILE = "evil$(touch " + p.sandbox + "/PWNED).service"
USR = {"unit": "plasma-foo.service", "scope": "user", "description": "plasma-foo.service",
       "since": "2026-10-20T20:33:15+03:00"}
live = json.load(open(os.path.join(harness.FIXTURES, "state-live.json")))


def serve(**block):
    st = dict(live)
    b = {"notify": True, "attribution": "update", "announced": [], "already": [], "recovered": [],
         "muted": [], "recovered_digest": ""}
    b.update(block)
    st["startup"] = b
    json.dump(st, open(SRC, "w"))


serve(announced=[BT], recovered=[USR], recovered_digest="0123456789abcdef")
open(ACKRC, "w").write("0")
open(MUTERC, "w").write("0")
open(MUTEMSG, "w").write("kempt: could not write the mutes file\n")

p.stub("""
case "$1" in
%(CFG)s
  check) cp %(SRC)s %(ST)s; cat %(ST)s; exit 0 ;;
  summary) exit 0 ;;
  startup)
    case "$2" in
      ack)  rc="$(cat %(ACKRC)s)"
            # The CLI's memory too (startup.json), so the next check does not bring it back.
            if [[ "$rc" == 0 ]]; then
              for f in %(ST)s %(SRC)s; do
                jq -c '.startup.recovered = [] | .startup.recovered_digest = ""' "$f" > "$f.t" && mv "$f.t" "$f"
              done
            fi
            exit "$rc" ;;
      mute) rc="$(cat %(MRC)s)"
            [[ "$rc" == 0 ]] || { cat %(MSG)s >&2; exit "$rc"; }
            jq -c --arg u "$3" '.startup.announced |= map(select(.unit != $u))' %(ST)s > %(ST)s.t && mv %(ST)s.t %(ST)s
            exit 0 ;;
      --json) cat %(SJ)s; exit 0 ;;
      unmute) exit 0 ;;
    esac ;;
esac
""" % {"CFG": harness.config_arm(), "SRC": SRC, "ST": STATE_JSON, "ACKRC": ACKRC, "MRC": MUTERC,
       "SJ": STARTUP_JSON, "MSG": MUTEMSG})

root, ev = p.create("main.qml")
p.wait_for(ev, "root.kemptState !== null", True)


def settle():
    p.wait_for(ev, "root.checking", False, timeout_ms=15000)
    p.wait_idle(ev, "executor")


settle()

from PySide6.QtCore import QUrl                                    # noqa: E402
from PySide6.QtQml import QQmlComponent, QQmlEngine                # noqa: E402
from PySide6.QtQuick import QQuickWindow                           # noqa: E402

full = QQmlComponent(p.engine, QUrl.fromLocalFile(os.path.join(harness.UI, "FullRepresentation.qml")))
pop = full.createWithInitialProperties({"plasmoidItem": root, "vm": root.property("vm")})
p.check("the popup builds", pop is not None, True)
if pop is None:
    sys.exit(p.done())
QQmlEngine.setObjectOwnership(pop, QQmlEngine.CppOwnership)
p.keep.append((full, pop))
lev = p.evaluator(pop)
# The popup's vm is handed down once; keep it following main.qml's, as the real binding does.
lev("popup.vm = Qt.binding(function () { return popup.plasmoidItem.vm; })")
# A real offscreen window, as in probe_focus.py: without a scene there is no activeFocus to check.
win = QQuickWindow()
win.resize(460, 900)
pop.setParentItem(win.contentItem())
pop.setWidth(460)
pop.setHeight(900)
win.show()
p.pump(200)

# --- the banner, and the panel it leaves alone ---------------------------------------------------
p.check("a failed service takes the startup slot", ev("root.vm.messageSlots.indexOf('startup') >= 0"), True)
p.check("...and the banner shows", lev("startupBanner.visible"), True)
p.check("one service: one message, drawn, with title and body",
        [lev("startupRepeater.count"), lev("startupRepeater.itemAt(0).visible"), lev("startupRepeater.itemAt(0).text")],
        [1, True, "Bluetooth service didn't start after the update.\n"
            "It stopped with an error. A system service (bluetooth.service)."])
p.check("...which a screen reader hears as written", lev("startupRepeater.itemAt(0).Accessible.name"),
        lev("startupRepeater.itemAt(0).text"))
p.check("...a warning, with its two buttons",
        [lev("startupRepeater.itemAt(0).type === Kirigami.MessageType.Warning"),
         lev("startupRepeater.itemAt(0).actions[0].text"), lev("startupRepeater.itemAt(0).actions[1].text")],
        [True, "Copy Command", "Mute Until It Starts"])
p.check("...the mute saying what it does",
        lev("startupRepeater.itemAt(0).actions[1].tooltip"),
        "Kempt stops mentioning it until it starts cleanly again.")
p.check("no heading for one service", lev("startupHeading.visible"), False)
p.check("the badge counts updates and nothing else",
        [ev("root.vm.badgeText"), ev("root.vm.needsAttention"), ev("root.trayStatusShown")], ["10", False, "active"])

lev("engineCopyClip.text = ''")
lev("startupRepeater.itemAt(0).actions[0].trigger()")
p.check("Copy Command copies the systemctl command", lev("engineCopyClip.text"), "systemctl status bluetooth.service")

# --- the recovered line: acknowledged only while open, kept until close --------------------------
p.check("the running-again line shows", [lev("startupRecovered.visible"), lev("startupRecovered.text")],
        [True, "plasma-foo.service is running again."])
p.check("...and nothing is acknowledged while the popup is closed", p.call_count("startup ack"), 0)
open(ACKRC, "w").write("6")
ev("root.popupOpened()")
settle()
p.check("opening the popup acknowledges it by its digest",
        p.calls_matching("startup ack"), ["startup ack --expect=0123456789abcdef"])
p.check("...a refused acknowledgement is not retried while it stays open",
        [p.call_count("startup ack"), lev("startupRecovered.visible")], [1, True])
ev("root.popupClosed()")
open(ACKRC, "w").write("0")
ev("root.popupOpened()")
settle()
p.check("the next open tries again", p.call_count("startup ack"), 2)
p.check("...the CLI cleared it", ev("root.kemptState.startup.recovered.length"), 0)
p.check("...and the line stays on screen until the widget closes",
        [lev("startupRecovered.visible"), lev("startupRecovered.text")],
        [True, "plasma-foo.service is running again."])
ev("root.popupClosed()")
p.check("closed, it is gone", lev("startupRecovered.visible"), False)
# A recorded acknowledgement whose state.json patch failed (exit 1): the CLI may already have
# forgotten the line, so it stays for this open rather than vanishing unread at the next refresh.
serve(announced=[], recovered=[USR], recovered_digest="00000000000000aa")
ev("root.doCheck()")
settle()
p.check("the running-again line alone has its own slot, below the restart",
        [ev("root.vm.messageSlots.indexOf('startupRecovered') >= 0"), lev("startupBanner.visible"),
         lev("startupRecovered.visible")], [True, True, True])
open(ACKRC, "w").write("1")
ev("root.popupOpened()")
settle()
serve(announced=[BT])
ev("root.doCheck()")
settle()
p.check("an acknowledgement that exited 1 keeps the line for this open",
        [lev("startupRecovered.visible"), lev("startupRecovered.text")],
        [True, "plasma-foo.service is running again."])
ev("root.popupClosed()")
open(ACKRC, "w").write("0")
p.check("...until the widget closes", lev("startupRecovered.visible"), False)
p.check("...and the failure is still there", lev("startupBanner.visible"), True)

# --- Mute Until It Starts ------------------------------------------------------------------------
serve(announced=[BT, USR, dict(BT, unit=ESCAPED, description="File System Check"),
                 dict(BT, unit=HOSTILE, description="Hostile")],
      already=[{"unit": "im.service", "scope": "user", "description": "Input Method starter"}])
ev("root.doCheck()")
settle()
p.check("a unit name the CLI would refuse gets no message, so three services: a heading with the count, one message each",
        [lev("startupHeading.text"), lev("startupRepeater.count")],
        ["3 services didn't start after the update.", 3])
# Three of each button, and the words on them are the same three times. What a screen reader is
# told is not: each button's accessible name carries its service, and the Copy button, the first
# stop in each message, carries what happened as its description.
p.pump(100)
BTN = "popup.buttonFor(startupRepeater.itemAt(%d), startupRepeater.itemAt(%d).actions[%d])"
_names = [lev("startupRepeater.itemAt(%d).modelData.name" % i) for i in range(3)]
p.check("each Mute button names its own service to a screen reader",
        [lev(BTN % (i, i, 1) + ".Accessible.name") for i in range(3)],
        ["Mute %s until it starts" % n for n in _names])
p.check("...and so does each Copy Command button",
        [lev(BTN % (i, i, 0) + ".Accessible.name") for i in range(3)],
        ["Copy command for %s" % n for n in _names])
p.check("...while the words drawn on them stay as they were",
        [lev(BTN % (0, 0, 0) + ".text"), lev(BTN % (0, 0, 1) + ".text")],
        ["Copy Command", "Mute Until It Starts"])
p.check("...Copy Command says what happened to the service, and the command it copies",
        lev(BTN % (0, 0, 0) + ".Accessible.description"),
        "It stopped with an error. A system service (bluetooth.service).\n"
        "systemctl status bluetooth.service")
p.check("...and Mute says what muting does",
        lev(BTN % (0, 0, 1) + ".Accessible.description"),
        "Kempt stops mentioning it until it starts cleanly again.")

lev("engineCopyClip.text = ''")
lev("startupRepeater.itemAt(1).actions[0].trigger()")
p.check("a session service's command has --user", lev("engineCopyClip.text"),
        "systemctl --user status plasma-foo.service")
lev("startupRepeater.itemAt(2).actions[0].trigger()")
p.check("a unit with a backslash is single-quoted", lev("engineCopyClip.text"),
        "systemctl status '" + ESCAPED + "'")
p.clear_calls()
lev("startupRepeater.itemAt(1).actions[1].trigger()")
settle()
p.check("Mute runs kempt startup mute <unit> --user",
        p.argv("startup"), ["startup", "mute", "plasma-foo.service", "--user"])
p.check("...and the muted service leaves the banner",
        [lev("startupRepeater.count"), ev("root.startupMutePending")], [2, ""])
NEXT_FOCUSED = ("popup.Window.activeFocusItem !== null"
                " && popup.Window.activeFocusItem === popup.buttonFor(startupRepeater.itemAt(1),"
                " startupRepeater.itemAt(1).actions[0])")
p.wait_for(lev, NEXT_FOCUSED, True)
p.check("...and the keyboard moves to the next service's first button",
        [lev(NEXT_FOCUSED), lev("startupRepeater.itemAt(1).modelData.unit")], [True, ESCAPED])
p.clear_calls()
lev("startupRepeater.itemAt(1).actions[1].trigger()")
settle()
p.check("an escaped unit reaches the CLI as one argument, backslash intact",
        p.argv("startup"), ["startup", "mute", ESCAPED])
# The list hands its focus on to its current row, so the list is asked, not the focused item.
p.wait_for(lev, "rowsView.activeFocus", True)
p.check("with no service after it, the keyboard moves to the list, past the already-failing text",
        [lev("rowsView.activeFocus"), lev("startupAlready.activeFocus"), lev("startupAlready.visible")],
        [True, False, True])
# Characters systemd allows and a shell would not leave alone: one argument, exactly as named.
ODD = "systemd-backlight@backlight:acpi\\x2dvideo0.service"
p.clear_calls()
ev("root.muteStartup(%s, 'system', 'Backlight')" % json.dumps(ODD))
settle()
p.check("a unit with @, a colon and a backslash reaches the CLI as one argument, unchanged",
        p.argv("startup"), ["startup", "mute", ODD])
open(MUTERC, "w").write("1")
lev("startupRepeater.itemAt(0).actions[1].trigger()")
settle()
p.check("a mute that failed says so in that service's message",
        lev("startupRepeater.itemAt(0).text.split('\\n')[2]"), "kempt: could not write the mutes file")
p.check("...and the buttons are live again", lev("startupRepeater.itemAt(0).actions[1].enabled"), True)
open(MUTEMSG, "w").write("")
lev("startupRepeater.itemAt(0).actions[1].trigger()")
settle()
p.check("a failure that says nothing names the service as the person knows it",
        lev("startupRepeater.itemAt(0).text.split('\\n')[2]"), "Could not mute Bluetooth service.")
# The service started between the check and the press: the CLI's exit 6, said calmly, by name.
open(MUTERC, "w").write("6")
open(MUTEMSG, "w").write("bluetooth.service is running, so there is nothing to mute.\n")
lev("startupRepeater.itemAt(0).actions[1].trigger()")
settle()
p.check("a service that started before the press is said to be running again, not a failure",
        lev("startupRepeater.itemAt(0).text.split('\\n')[2]"),
        "Bluetooth service is running again, so there is nothing to mute.")
ev("root.popupOpened()")
ev("root.popupClosed()")
p.check("...and closing the widget clears it", [ev("root.startupMuteError"), lev("startupRepeater.itemAt(0).text.split('\\n').length")],
        [None, 2])

# --- the settings page ---------------------------------------------------------------------------
for k, v in harness.CONFIG_DEFAULTS.items():
    open(os.path.join(VALUES, k), "w").write(v)
open(os.path.join(VALUES, "notify_startup"), "w").write("false")
json.dump({"notify": True, "muted": [{"unit": "plasma-foo.service", "scope": "user",
                                     "description": "Plasma Foo"}]}, open(STARTUP_JSON, "w"))
p.stub("""
case "$1" in
  config)
    case "$2" in
      get) cat %(V)s/"$3" 2>/dev/null; exit 0 ;;
      set) printf '%%s' "$4" > %(V)s/"$3"; exit 0 ;;
    esac ;;
  holds) exit 0 ;;
  discover-notifier) exit 0 ;;
  startup)
    case "$2" in
      --json) cat %(SJ)s; exit 0 ;;
      mute|unmute) exit 0 ;;
    esac ;;
esac
""" % {"V": VALUES, "SJ": STARTUP_JSON})
p.clear_calls()
page, pev = p.create("configGeneral.qml")
p.wait_for(pev, "page.pendingReads === 0 && !page.mutedBusy", True)
win2 = QQuickWindow()
win2.resize(460, 1600)
page.setParentItem(win2.contentItem())
page.setWidth(460)
page.setHeight(1600)
win2.show()
p.pump(200)
p.wait_idle(pev, "cfgExecutor")
p.check("the page reads notify_startup", p.calls_matching("config get notify_startup"),
        ["config get notify_startup"])
p.check("...a stored false is an empty box, under the setting's words",
        [pev("notifyStartup.checked"), pev("notifyStartup.text")],
        [False, "Tell me when something stops starting after an update"])
p.check("...with the note under it", pev("notifyStartupNote.text"),
        "Kempt only looks. It never turns anything on or off, and the update count never includes this.")
pev("notifyStartup.checked = true")
pev("notifyStartup.toggled()")
p.clear_calls()
pev("page.saveConfig()")
p.wait_idle(pev, "cfgExecutor")
p.check("Apply writes it", p.argv("config"), ["config", "set", "notify_startup", "true"])

p.check("the muted list comes from kempt startup --json",
        [pev("page.muted.length"), pev("page.muted[0].name"), pev("mutedEmpty.visible")], [1, "Plasma Foo", False])
btn = "mutedRepeater.itemAt(0).children[2]"
p.check("...each with Stop Muting, named for a screen reader",
        [pev(btn + ".text"), pev(btn + ".Accessible.name"), pev(btn + ".Accessible.description")],
        ["Stop Muting Plasma Foo", "Stop Muting Plasma Foo", "Kempt mentions it again if it still does not start."])
json.dump({"notify": True, "muted": []}, open(STARTUP_JSON, "w"))
p.clear_calls()
pev(btn + ".clicked()")
p.wait_for(pev, "page.mutedBusy", False)
p.wait_idle(pev, "cfgExecutor")
p.check("Stop Muting runs kempt startup unmute <unit> --user",
        [c for c in p.calls_matching("startup") if "unmute" in c],
        ["startup unmute plasma-foo.service --user"])
p.check("...the list is read again, and Undo is offered",
        [pev("page.muted.length"), pev("mutedEmpty.text"), pev("unmutedRow.visible")],
        [0, "Nothing is muted.", True])
p.wait_for(pev, "page.Window.activeFocusItem === undoUnmute", True)
p.check("...and the keyboard is on Undo", pev("page.Window.activeFocusItem === undoUnmute"), True)
p.clear_calls()
pev("undoUnmute.clicked()")
p.wait_for(pev, "page.mutedBusy", False)
p.wait_idle(pev, "cfgExecutor")
p.check("Undo mutes it again", [c for c in p.calls_matching("startup") if " mute" in c],
        ["startup mute plasma-foo.service --user"])
p.check("...and the Undo goes away", pev("unmutedRow.visible"), False)
p.check("none of this is an unsaved change", pev("page.unsavedChanges"), False)

sys.exit(p.done())
