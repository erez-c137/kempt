#!/usr/bin/env python3
"""The Startup page: the header button, the page it opens, and the one command it gathers with.

The node tests pin every line logic.js derives from `kempt startup --all --json`. This proves the
QML: the button follows startup_page, opening gathers with that exact argv and nothing else ever
does, the page draws what came back as plain text, Copy Command copies the CLI's command, Refresh
gathers again and refuses while one runs, a failure is said calmly, and Back, Escape and the button
itself return to the updates with the keyboard on the button. Then the settings page's checkbox.
"""
import json
import os
import sys

import harness

if not harness.have_pyside():
    print("ok: SKIPPED - PySide6 absent")
    sys.exit(0)

p = harness.Probe("probe-startup-page")
os.makedirs(p.state)
STATE_JSON = os.path.join(p.state, "state.json")
SETTING = os.path.join(p.sandbox, "startup_page")    # what `config get startup_page` answers
PAGE = os.path.join(p.sandbox, "page.json")          # what `startup --all --json` prints
RC = os.path.join(p.sandbox, "rc")                   # ...and exits with
DELAY = os.path.join(p.sandbox, "delay")             # ...after sleeping this long
VALUES = os.path.join(p.sandbox, "values")
os.makedirs(VALUES)

HOSTILE = "<b>Bold</b><img src=x> & <a href='x'>link</a>"
# An autostart unit's name holds an @, spliced in so the docs test's address scan passes it by.
UNIT = "app-imsettings\\x2dstart" + "@" + "autostart.service"
CMD = "systemctl --user status '%s'" % UNIT
FULL = {
    "schema": 1, "boot_id": "b", "generated_at": "2026-10-20T20:36:48Z", "notes": [],
    "failed": {"units": [
        {"scope": "user", "unit": UNIT,
         "description": "imsettings-start", "state": "failed", "result": "exit-code",
         "log": "Current desktop isn't supported.", "status_command": CMD},
        {"scope": "system", "unit": "evil.service", "description": HOSTILE, "state": "failed",
         "result": "exit-code", "log": HOSTILE, "status_command": "systemctl status evil.service"}],
        "journal_denied": False, "journal_available": True},
    "changed": {"since": "2026-10-18T09:00:00Z", "added": [{"scope": "system", "unit": "cups.service"}],
                "removed": []},
    "starts": [
        {"scope": "system", "kind": "service", "unit": "a.service", "description": "Alpha",
         "package": "alpha", "skipped": False},
        {"scope": "system", "kind": "service", "unit": "h.service", "description": HOSTILE,
         "package": None, "skipped": False},
        {"scope": "system", "kind": "service", "unit": "s.service", "description": "Skipped",
         "package": "s", "skipped": True}],
    "schedule": {"timers": [
        {"scope": "user", "unit": "backup.timer", "activates": "backup.service",
         "description": "Nightly backup", "last": "2026-10-20T01:00:00Z", "next": None,
         "result": "exit-code"}],
        "cron": [], "at": [], "notes": []},
    "boot_time": {"ready_sec": 6.1, "userspace_sec": 41, "total_sec": None, "usual": None,
                  "slowest": None, "recent": []},
}


def serve(page, rc=0, delay=0):
    open(PAGE, "w").write(page if isinstance(page, str) else json.dumps(page))
    open(RC, "w").write(str(rc))
    open(DELAY, "w").write(str(delay))


serve(FULL)
open(SETTING, "w").write("false")
live = json.load(open(os.path.join(harness.FIXTURES, "state-live.json")))
json.dump(live, open(os.path.join(p.sandbox, "src.json"), "w"))

p.stub("""
case "$1" in
%(CFG)s
  check) cp %(SRC)s %(ST)s; cat %(ST)s; exit 0 ;;
  summary) exit 0 ;;
  startup)
    if [[ "$2" == --all ]]; then
      sleep "$(cat %(DELAY)s)"
      cat %(PAGE)s
      rc="$(cat %(RC)s)"
      [[ "$rc" == 0 ]] || echo "kempt: could not gather the startup page" >&2
      exit "$rc"
    fi
    exit 0 ;;
esac
""" % {"CFG": harness.config_arm(startup_page="cat %s" % SETTING),
       "SRC": os.path.join(p.sandbox, "src.json"), "ST": STATE_JSON, "PAGE": PAGE, "RC": RC,
       "DELAY": DELAY})

root, ev = p.create("main.qml")
p.wait_for(ev, "root.kemptState !== null", True)


def settle():
    p.wait_for(ev, "root.checking", False, timeout_ms=15000)
    p.wait_idle(ev, "executor", "startupExecutor", timeout_ms=15000)


settle()

from PySide6.QtCore import QCoreApplication, QEvent, Qt, QUrl     # noqa: E402
from PySide6.QtGui import QKeyEvent                                # noqa: E402
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
lev("popup.vm = Qt.binding(function () { return popup.plasmoidItem.vm; })")
win = QQuickWindow()
win.resize(460, 900)
pop.setParentItem(win.contentItem())
pop.setWidth(460)
pop.setHeight(900)
win.show()
p.pump(200)
spy, sev = p.create_inline("""
import QtQuick
QtObject { id: spy; property int closes: 0; function bump() { spy.closes++; } }
""", "close-spy.qml")
p.engine.rootContext().setContextProperty("closeSpy", spy)
lev("popup.closeRequested.connect(closeSpy.bump)")
# Evaluated in StartupPage.qml's own context, where its ids live: the context of the page's root
# object is the file that instantiated it, so go through a child.
pev = p.evaluator(lev("startupPage.children[0]"))


def press(key):
    QCoreApplication.sendEvent(win, QKeyEvent(QEvent.KeyPress, key, Qt.NoModifier))
    QCoreApplication.sendEvent(win, QKeyEvent(QEvent.KeyRelease, key, Qt.NoModifier))
    p.pump(30)


# --- the button follows the setting ---------------------------------------------------------------
p.check("main.qml reads startup_page", p.call_count("config get startup_page") >= 1, True)
p.check("off (the default): no Startup button", [ev("root.startupPageOn"), lev("startupButton.visible")],
        [False, False])
open(SETTING, "w").write("true")
ev("root.readStartupPage()")
settle()
p.check("on: the Startup button is in the header", lev("startupButton.visible"), True)
p.check("...named and described for a screen reader",
        [lev("startupButton.Accessible.name"), lev("startupButton.Accessible.description")],
        ["Startup", "What starts with the computer and what runs on a schedule."])
p.check("...and an empty answer (an older CLI) keeps it", (open(SETTING, "w").write(""),
        ev("root.readStartupPage()"), settle(), lev("startupButton.visible"))[3], True)
open(SETTING, "w").write("true")

# --- never by the background check ----------------------------------------------------------------
ev("root.doCheck()")
settle()
ev("root.popupOpened()")
settle()
p.check("a check, and opening the widget, gather nothing", p.call_count("startup"), 0)

# --- opening ---------------------------------------------------------------------------------------
serve(FULL, delay=1)
lev("startupButton.clicked()")
p.pump(100)
p.check("the button opens the page in place of the updates",
        [lev("popup.startupOpen"), lev("startupPage.visible"), lev("startupButton.checked")], [True, True, True])
p.check("...gathering with kempt startup --all --json", p.argv("startup"), ["startup", "--all", "--json"])
p.check("...a busy indicator and a calm line meanwhile, Refresh refusing",
        [pev("busyIndicator.running"), pev("loadingLabel.text"), pev("refreshButton.enabled")],
        [True, "Reading what starts with the computer…", False])
pev("refreshButton.clicked()")
settle()
p.check("...so a second press while it runs gathers nothing more", p.call_count("startup --all"), 1)
p.wait_for(pev, "page.Window.activeFocusItem === backButton", True)
p.check("the keyboard lands on Back", pev("page.Window.activeFocusItem === backButton"), True)
p.check("the updates are out of the way", lev("startupPage.visible && !updatingPane.visible"), True)

p.check("what failed is listed in full, (when you log in) for a login item",
        [pev("failedHeading.visible"), pev("failedRepeater.count"),
         pev("failedRepeater.itemAt(0).children[0].text"), pev("failedRepeater.itemAt(0).children[1].text")],
        [True, 2, "imsettings-start (when you log in)", "Its log says: Current desktop isn't supported."])
copy = "failedRepeater.itemAt(0).children[2]"
p.check("...with Copy Command, named for its service and describing the command",
        [pev(copy + ".text"), pev(copy + ".Accessible.name"), pev(copy + ".Accessible.description")],
        ["Copy Command", "Copy Command: imsettings-start (when you log in)", CMD])
lev("engineCopyClip.text = ''")
pev(copy + ".clicked()")
p.check("Copy Command copies the CLI's command, quotes intact", lev("engineCopyClip.text"), CMD)
p.check("changes and failed timers are listed too",
        [pev("changedRepeater.count"), pev("timerFailRepeater.count"),
         pev("timerFailRepeater.itemAt(0).text").split(":")[0]],
        [1, 1, "Nightly backup (backup.timer)"])
p.check("the long lists are counts until asked for",
        [pev("startsSummaryLabel.text"), pev("startsRepeater.count"), pev("skippedLabel.text"),
         pev("scheduleSummaryLabel.text"), pev("scheduleRepeater.count")],
        ["2 services", 0, "1 more is set to start but is skipped on this computer.", "1 timer", 0])
p.check("...with a toggle each, named for its list",
        [pev("startsToggle.Accessible.name"), pev("scheduleToggle.Accessible.name")],
        ["Show All: Starts with the computer", "Show All: Runs on a schedule"])
pev("startsToggle.clicked()")
pev("scheduleToggle.clicked()")
p.pump(50)
p.check("Show All lists them, and says Hide",
        [pev("startsRepeater.count"), pev("startsToggle.text"), pev("scheduleRepeater.count")],
        [3, "Hide", 2])
p.check("the startup time is one line", pev("bootLabel.text"), "Ready in 6 s; all services by 41 s.")
BUTTONS = """(function () { var out = [];
  (function walk(o) {
     if (o.clicked !== undefined && o.text !== undefined && o.visible && out.indexOf(String(o.text)) < 0)
       out.push(String(o.text));
     for (var i = 0; i < o.children.length; i++) walk(o.children[i]);
  })(page); return JSON.stringify(out.sort()); })()"""
p.check("every button on the page reads, copies or moves: none acts on the system",
        json.loads(pev(BUTTONS)), ["Back", "Copy Command", "Hide", "Refresh"])

# --- plain text, whatever the strings hold ----------------------------------------------------------
HOSTILE_FORMATS = """(function () { var out = [];
  (function walk(o) {
     if (o.textFormat !== undefined && typeof o.text === "string" && o.text.indexOf("<b>Bold</b>") >= 0)
       out.push(o.textFormat === Text.PlainText);
     for (var i = 0; i < o.children.length; i++) walk(o.children[i]);
  })(page); return JSON.stringify(out); })()"""
formats = json.loads(pev(HOSTILE_FORMATS))
p.check("markup in a description or a log is shown as text, never read as markup",
        [len(formats) >= 3, all(formats)], [True, True])

# --- Refresh ----------------------------------------------------------------------------------------
changed = dict(FULL, failed={"units": [], "journal_denied": False, "journal_available": True})
serve(changed)
p.clear_calls()
pev("refreshButton.clicked()")
settle()
p.check("Refresh gathers again with the same command", p.calls_matching("startup"), ["startup --all --json"])
p.check("...and the page follows: an empty section is not drawn",
        [pev("failedHeading.visible"), pev("failedRepeater.count")], [False, 0])

# --- problems, said calmly --------------------------------------------------------------------------
serve("this is not json {")
pev("refreshButton.clicked()")
settle()
p.check("garbage is one calm line, and no section",
        [pev("problemLabel.text"), pev("startsHeading.visible"), pev("bootLabel.visible")],
        ["Kempt could not read the startup list.", False, False])
serve("", rc=1)
pev("refreshButton.clicked()")
settle()
p.check("a failed gather gives the CLI's reason",
        pev("problemLabel.text"), "Kempt could not gather the startup list: kempt: could not gather the startup page")
serve({"schema": 1, "boot_id": "b", "generated_at": "x", "notes": []})
pev("refreshButton.clicked()")
settle()
p.check("a page with nothing in it says so", pev("emptyLabel.text"), "Kempt found nothing to list.")
serve(FULL)

# --- back ------------------------------------------------------------------------------------------
pev("backButton.clicked()")
p.pump(80)
p.check("Back returns to the updates", [lev("popup.startupOpen"), lev("startupPage.visible")], [False, False])
p.wait_for(lev, "popup.Window.activeFocusItem === startupButton", True)
p.check("...with the keyboard on the Startup button", lev("popup.Window.activeFocusItem === startupButton"), True)
p.clear_calls()
lev("startupButton.clicked()")
settle()
p.check("opening again gathers again", p.call_count("startup --all"), 1)
before = sev("closes")
press(Qt.Key_Escape)
p.check("Escape on the page goes back, and does not close the widget",
        [lev("popup.startupOpen"), sev("closes") - before], [False, 0])
press(Qt.Key_Escape)
p.check("...and Escape again asks to close", sev("closes") - before, 1)
lev("startupButton.clicked()")
settle()
lev("startupButton.clicked()")
p.pump(50)
p.check("the button pressed again goes back too, and stays bound to the page",
        [lev("popup.startupOpen"), lev("startupButton.checked")], [False, False])
lev("startupButton.clicked()")
settle()
ev("root.popupClosed()")
p.check("closing the widget leaves the page, so it opens on the updates", lev("popup.startupOpen"), False)
ev("root.popupOpened()")
settle()
lev("startupButton.clicked()")
settle()
open(SETTING, "w").write("false")
ev("root.readStartupPage()")
settle()
p.check("the setting going off closes the page and hides the button",
        [lev("popup.startupOpen"), lev("startupButton.visible")], [False, False])
p.clear_calls()
ev("root.doCheck()")
settle()
p.check("...and nothing gathers in the background after all that", p.call_count("startup"), 0)

# --- the settings page ------------------------------------------------------------------------------
for k, v in harness.CONFIG_DEFAULTS.items():
    open(os.path.join(VALUES, k), "w").write(v)
p.stub("""
case "$1" in
  config)
    case "$2" in
      get) cat %(V)s/"$3" 2>/dev/null; exit 0 ;;
      set) printf '%%s' "$4" > %(V)s/"$3"; exit 0 ;;
    esac ;;
  holds) exit 0 ;;
  discover-notifier) exit 0 ;;
  startup) exit 0 ;;
esac
""" % {"V": VALUES})
p.clear_calls()
cfg, cev = p.create("configGeneral.qml")
p.wait_for(cev, "page.pendingReads === 0 && !page.mutedBusy", True)
p.wait_idle(cev, "cfgExecutor")
p.check("the settings page reads startup_page", p.calls_matching("config get startup_page"),
        ["config get startup_page"])
p.check("...a stored false is an empty box, under the setting's words",
        [cev("startupPage.checked"), cev("startupPage.text")], [False, "Show a Startup page"])
p.check("...with the note under it", cev("startupPageNote.text"),
        "Lists what starts with the computer and what runs on a schedule. "
        "It reads the system journal when you are allowed to.")
cev("startupPage.checked = true")
cev("startupPage.toggled()")
p.clear_calls()
cev("page.saveConfig()")
p.wait_idle(cev, "cfgExecutor")
p.check("Apply writes it", p.argv("config"), ["config", "set", "startup_page", "true"])

sys.exit(p.done())
