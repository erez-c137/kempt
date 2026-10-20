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
            [[ "$rc" == 0 ]] || { echo "kempt: could not write the mutes file" >&2; exit "$rc"; }
            jq -c --arg u "$3" '.startup.announced |= map(select(.unit != $u))' %(ST)s > %(ST)s.t && mv %(ST)s.t %(ST)s
            exit 0 ;;
      --json) cat %(SJ)s; exit 0 ;;
      unmute) exit 0 ;;
    esac ;;
esac
""" % {"CFG": harness.config_arm(), "SRC": SRC, "ST": STATE_JSON, "ACKRC": ACKRC, "MRC": MUTERC,
       "SJ": STARTUP_JSON})

root, ev = p.create("main.qml")
p.wait_for(ev, "root.kemptState !== null", True)


def settle():
    p.wait_for(ev, "root.checking", False, timeout_ms=15000)
    p.wait_idle(ev, "executor")


settle()

from PySide6.QtCore import QUrl                                    # noqa: E402
from PySide6.QtQml import QQmlComponent, QQmlEngine                # noqa: E402

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
p.check("...and the failure is still there", lev("startupBanner.visible"), True)

# --- Mute Until It Starts ------------------------------------------------------------------------
serve(announced=[BT, USR, dict(BT, unit=ESCAPED, description="File System Check"),
                 dict(BT, unit=HOSTILE, description="Hostile")])
ev("root.doCheck()")
settle()
p.check("a unit name the CLI would refuse gets no message, so three services: a heading with the count, one message each",
        [lev("startupHeading.text"), lev("startupRepeater.count")],
        ["3 services didn't start after the update.", 3])
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
p.clear_calls()
lev("startupRepeater.itemAt(1).actions[1].trigger()")
settle()
p.check("an escaped unit reaches the CLI as one argument, backslash intact",
        p.argv("startup"), ["startup", "mute", ESCAPED])
p.check("...and the refused name never reached a shell", os.path.exists(os.path.join(p.sandbox, "PWNED")), False)
open(MUTERC, "w").write("1")
lev("startupRepeater.itemAt(0).actions[1].trigger()")
settle()
p.check("a mute that failed says so in that service's message",
        lev("startupRepeater.itemAt(0).text.split('\\n')[2]"), "kempt: could not write the mutes file")
p.check("...and the buttons are live again", lev("startupRepeater.itemAt(0).actions[1].enabled"), True)

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
p.clear_calls()
pev("undoUnmute.clicked()")
p.wait_for(pev, "page.mutedBusy", False)
p.wait_idle(pev, "cfgExecutor")
p.check("Undo mutes it again", [c for c in p.calls_matching("startup") if " mute" in c],
        ["startup mute plasma-foo.service --user"])
p.check("...and the Undo goes away", pev("unmutedRow.visible"), False)
p.check("none of this is an unsaved change", pev("page.unsavedChanges"), False)

sys.exit(p.done())
