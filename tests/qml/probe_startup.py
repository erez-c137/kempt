#!/usr/bin/env python3
"""A service that stopped starting after an update: the banner and the Startup Report's top block.

The node tests pin every sentence and command logic.js derives. This proves the QML routes them:
the banner is one sentence with one button, that button lands on the report, the report lists each
service with its two buttons, Mute Until It Starts reaches the CLI with the unit as ONE argument,
what recovered is acknowledged by its digest only while the widget is open, and the panel count
never moves. Then the settings page: the notify_startup round trip and the muted list.
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

# Evaluated in StartupPage.qml's own context, where its ids live: the context of the page's root
# object is the file that instantiated it, so go through a child.
rev = p.evaluator(lev("startupPage.children[0]"))

# --- the banner, and the panel it leaves alone ---------------------------------------------------
p.check("a failed service takes the startup slot", ev("root.vm.messageSlots.indexOf('startup') >= 0"), True)
p.check("the banner is one warning, one sentence and one button",
        [lev("startupBanner.visible"), lev("startupBanner.type === Kirigami.MessageType.Warning"),
         lev("startupBanner.text"), lev("startupBanner.actions.length"), lev("startupBanner.actions[0].text")],
        [True, True, "Bluetooth failed to start after the update.", 1, "Startup Report"])
p.check("...which a screen reader hears as written", lev("startupBanner.Accessible.name"), lev("startupBanner.text"))
p.check("the badge counts updates and nothing else", ev("root.vm.badgeText"), "10")

# Writing `expanded` outside plasmashell segfaults the probe, so this is the widget already open.
ev("root.popupOnScreen = true")
lev("startupBanner.actions[0].trigger()")
p.pump(200)
p.check("the banner's Startup Report lands on the report, in place of the updates",
        [lev("popup.startupOpen"), lev("startupPage.visible"), lev("startupBanner.visible")], [True, True, False])
p.wait_for(rev, "page.Window.activeFocusItem === backButton", True)
p.check("...with the keyboard on Back, which says what failed",
        rev("backButton.Accessible.description"),
        "Returns to the list of updates.\nBluetooth failed to start after the update.")
p.check("...and the service on top, with title, body and its two buttons, and no heading for one",
        [rev("failedRepeater.count"), rev("failedRepeater.itemAt(0).label.text"),
         rev("failedRepeater.itemAt(0).copyButton.text"), rev("failedRepeater.itemAt(0).muteButton.text"),
         rev("failedHeading.visible")],
        [1, "Bluetooth failed to start after the update.\nSystem service: bluetooth.service.",
         "Copy Command", "Mute Until It Starts", False])
lev("popup.closeStartup()")
p.pump(200)
ev("root.popupOnScreen = false")

# --- what recovered: nothing on screen, acknowledged only while open -------------------------------
p.check("a recovered service puts no line up", lev("startupBanner.visible"), True)
p.check("...and nothing is acknowledged while the popup is closed", p.call_count("startup ack"), 0)
open(ACKRC, "w").write("6")
ev("root.popupOpened()")
settle()
p.check("opening the popup acknowledges it by its digest",
        p.calls_matching("startup ack"), ["startup ack --expect=0123456789abcdef"])
p.check("...a refused acknowledgement is not retried while it stays open",
        p.call_count("startup ack"), 1)
ev("root.popupClosed()")
open(ACKRC, "w").write("0")
ev("root.popupOpened()")
settle()
p.check("the next open tries again", p.call_count("startup ack"), 2)
p.check("...the CLI cleared it", ev("root.kemptState.startup.recovered.length"), 0)
ev("root.popupClosed()")
serve(announced=[], recovered=[USR], recovered_digest="00000000000000aa")
ev("root.doCheck()")
settle()
p.check("recovered with nothing else failing leaves no slot and no banner",
        [ev("root.vm.messageSlots.indexOf('startup')"), lev("startupBanner.visible")], [-1, False])
serve(announced=[BT])
ev("root.doCheck()")
settle()

# --- the Startup Report's top block, and Mute Until It Starts ---------------------------------------
serve(announced=[BT, USR, dict(BT, unit=ESCAPED, description="File System Check"),
                 dict(BT, unit=HOSTILE, description="Hostile")],
      already=[{"unit": "im.service", "scope": "user", "description": "Input Method starter"}])
ev("root.doCheck()")
settle()
ev("root.popupOnScreen = true")
lev("startupBanner.actions[0].trigger()")
p.pump(200)
ROW = "failedRepeater.itemAt(%d)"
p.check("a unit name the CLI would refuse gets no row, so three services: a heading with the count, one row each",
        [rev("failedHeading.text"), rev("failedRepeater.count")],
        ["3 services failed to start after the update, including Bluetooth and plasma-foo.service.", 3])
p.check("...the banner saying the same one sentence", lev("startupBanner.text"), rev("failedHeading.text"))
p.check("...and what was already failing under them",
        rev("alreadyLabel.text"), "Already failing before the update: Input Method starter.")
# Three of each button, and the words on them are the same three times. What a screen reader is
# told is not: each button's accessible name carries its service.
_names = [rev((ROW % i) + ".service.name") for i in range(3)]
p.check("each Mute button names its own service to a screen reader",
        [rev((ROW % i) + ".muteButton.Accessible.name") for i in range(3)],
        ["Mute Until It Starts: %s" % n for n in _names])
p.check("...and so does each Copy Command",
        [rev((ROW % i) + ".copyButton.Accessible.name") for i in range(3)],
        ["Copy Command: %s" % n for n in _names])
p.check("...while the words drawn on them stay as they were",
        [rev((ROW % 0) + ".copyButton.text"), rev((ROW % 0) + ".muteButton.text")],
        ["Copy Command", "Mute Until It Starts"])
p.check("...Copy Command describes its command, and Mute what muting does",
        [rev((ROW % 0) + ".copyButton.Accessible.description"), rev((ROW % 0) + ".muteButton.Accessible.description")],
        ["systemctl status bluetooth.service", "Kempt stops mentioning it until it starts cleanly again."])
p.check("a session service's command has --user", rev((ROW % 1) + ".service.command"),
        "systemctl --user status plasma-foo.service")
p.check("a unit with a backslash is single-quoted", rev((ROW % 2) + ".service.command"),
        "systemctl status '" + ESCAPED + "'")
# A short window: the buttons of the last service are below the list's fold until the keyboard gets there.
pop.setHeight(240)
p.pump(200)
LIST = "failedScroll.contentItem"
p.check("premise: the list is taller than its window", rev(LIST + ".contentHeight > " + LIST + ".height"), True)
p.check("premise: it starts at the top", rev(LIST + ".contentY"), 0)
rev((ROW % 2) + ".muteButton.forceActiveFocus(Qt.TabFocusReason)")
p.pump(50)
_shown = ("(function (b) { const l = " + LIST + "; const t = b.mapToItem(l.contentItem, 0, 0).y;"
          " return t >= l.contentY && t + b.height <= l.contentY + l.height; })(%s)")
p.check("Tab onto the last service's button scrolls it into view", rev(_shown % ((ROW % 2) + ".muteButton")), True)
rev((ROW % 0) + ".copyButton.forceActiveFocus(Qt.BacktabFocusReason)")
p.pump(50)
p.check("...and back onto the first scrolls that into view too", rev(_shown % ((ROW % 0) + ".copyButton")), True)
pop.setHeight(900)
p.pump(200)
lev("engineCopyClip.text = ''")
rev((ROW % 2) + ".copyButton.clicked()")
p.check("Copy Command copies that command, quotes intact", lev("engineCopyClip.text"),
        "systemctl status '" + ESCAPED + "'")
p.clear_calls()
rev((ROW % 1) + ".muteButton.clicked()")
settle()
p.check("Mute runs kempt startup mute <unit> --user",
        p.argv("startup"), ["startup", "mute", "plasma-foo.service", "--user"])
p.check("...and the muted service leaves the report",
        [rev("failedRepeater.count"), ev("root.startupMutePending")], [2, ""])
NEXT_FOCUSED = "page.Window.activeFocusItem === " + (ROW % 1) + ".copyButton"
p.wait_for(rev, NEXT_FOCUSED, True)
p.check("...and the keyboard moves to the next service's first button",
        [rev(NEXT_FOCUSED), rev((ROW % 1) + ".service.unit")], [True, ESCAPED])
p.clear_calls()
rev((ROW % 1) + ".muteButton.clicked()")
settle()
p.check("an escaped unit reaches the CLI as one argument, backslash intact",
        p.argv("startup"), ["startup", "mute", ESCAPED])
p.wait_for(rev, "page.Window.activeFocusItem === backButton", True)
p.check("with no service after it, the keyboard moves to Back", rev("page.Window.activeFocusItem === backButton"), True)
# Characters systemd allows and a shell would not leave alone: one argument, exactly as named.
ODD = "systemd-backlight@backlight:acpi\\x2dvideo0.service"
p.clear_calls()
ev("root.muteStartup(%s, 'system', 'Backlight')" % json.dumps(ODD))
settle()
p.check("a unit with @, a colon and a backslash reaches the CLI as one argument, unchanged",
        p.argv("startup"), ["startup", "mute", ODD])
open(MUTERC, "w").write("1")
rev((ROW % 0) + ".muteButton.clicked()")
settle()
p.check("a mute that failed says so in that service's row",
        rev((ROW % 0) + ".label.text.split('\\n')[2]"), "kempt: could not write the mutes file")
p.check("...and the button says Mute again", rev((ROW % 0) + ".muteButton.text"), "Mute Until It Starts")
open(MUTEMSG, "w").write("")
rev((ROW % 0) + ".muteButton.clicked()")
settle()
p.check("a failure that says nothing names the service as the person knows it",
        rev((ROW % 0) + ".label.text.split('\\n')[2]"), "Could not mute Bluetooth service.")
# The service started between the check and the press: the CLI's exit 6, said calmly, by name.
open(MUTERC, "w").write("6")
open(MUTEMSG, "w").write("bluetooth.service is running, so there is nothing to mute.\n")
rev((ROW % 0) + ".muteButton.clicked()")
settle()
p.check("a service that started before the press is said to be running again, not a failure",
        rev((ROW % 0) + ".label.text.split('\\n')[2]"),
        "Bluetooth service is running again, so there is nothing to mute.")
ev("root.popupOpened()")
ev("root.popupClosed()")
p.check("...and closing the widget clears it",
        [ev("root.startupMuteError"), rev((ROW % 0) + ".label.text.split('\\n').length")], [None, 2])

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
