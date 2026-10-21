#!/usr/bin/env python3
"""The Startup page: the menu entry, the page it opens, and the one command it gathers with.

The node tests pin every line logic.js derives from `kempt startup --all --json`. This proves the
QML: the widget's menu offers Startup Page with no setting behind it, choosing it opens the page and
gathers with that exact argv and nothing else ever does, the page draws what came back as plain
text, Copy Command copies the CLI's command, Refresh gathers again and refuses while one runs, a
failure is said calmly, and Back and Escape return to the updates with the keyboard on the header's
Check for Updates. Then the settings page, which has no checkbox for it.
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
""" % {"CFG": harness.config_arm(),
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


# --- the menu entry, with no setting behind it ----------------------------------------------------
p.check("nothing asks for a startup_page setting", p.call_count("config get startup_page"), 0)
p.check("the header has no Startup button", lev("typeof startupButton"), "undefined")
p.check("the widget's menu offers Startup Page, with the icon the button had",
        [ev("startupAction.text"), ev("startupAction.icon.name")], ["Startup Page", "system-run"])
p.check("...registered with Check for Updates", ev("root.contextualActionsClaimed"), True)
_MAIN = " ".join(open(os.path.join(harness.UI, "main.qml")).read().split())
p.check("...beside it, in that order", "Plasmoid.contextualActions = [checkAction, startupAction];" in _MAIN, True)
# Writing `expanded` outside plasmashell segfaults the probe, so the closed case is pinned here and
# the request it leaves is driven at the end of this file.
p.check("...and a closed widget opens first, through the property only main.qml writes",
        "if (!root.popupOnScreen) root.expanded = true;" in _MAIN, True)
p.check("...and asks for the page only if that open happened, so a failed one leaves no request behind",
        "if (!root.popupOnScreen) root.expanded = true; if (root.popupOnScreen) root.startupPageWanted = true;" in _MAIN,
        True)
p.check("...and a request left when the widget closes goes with it",
        "function popupClosed() { popupOnScreen = false; startupPageWanted = false;" in _MAIN, True)

# --- never by the background check ----------------------------------------------------------------
ev("root.doCheck()")
settle()
ev("root.popupOpened()")
settle()
p.check("a check, and opening the widget, gather nothing", p.call_count("startup"), 0)

# --- opening ---------------------------------------------------------------------------------------
serve(FULL, delay=1)
ev("startupAction.trigger()")
p.pump(100)
p.check("the menu entry opens the page in place of the updates",
        [lev("popup.startupOpen"), lev("startupPage.visible"), ev("root.startupPageWanted")], [True, True, False])
p.check("...gathering with kempt startup --all --json", p.argv("startup"), ["startup", "--all", "--json"])
p.check("...a busy indicator and a calm line meanwhile, Refresh still enabled, so focus can stay on it",
        [pev("busyIndicator.running"), pev("loadingLabel.text"), pev("refreshButton.enabled")],
        [True, "Reading what starts with the computer…", True])
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
     // A section header is an ItemDelegate underneath, with no action and no focus: not a button.
     if (o.clicked !== undefined && o.text !== undefined && o.visible && o.Accessible.role !== Accessible.Heading
         && out.indexOf(String(o.text)) < 0)
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
serve({"schema": 1, "boot_id": "b", "generated_at": "x", "notes": ["session_missing"]})
pev("refreshButton.clicked()")
settle()
p.check("a session that could not be reached is said, in place of the empty line",
        [pev("notesRepeater.count"), pev("notesRepeater.itemAt(0).text"), pev("emptyLabel.text")],
        [1, "Your session could not be reached, so what starts when you log in is missing.", ""])
serve("", rc=1)
pev("refreshButton.clicked()")
settle()
pev("page.startsOpen = true")

# --- back ------------------------------------------------------------------------------------------
pev("backButton.clicked()")
p.pump(80)
p.check("Back returns to the updates", [lev("popup.startupOpen"), lev("startupPage.visible")], [False, False])
p.wait_for(lev, "popup.Window.activeFocusItem === refreshButton", True)
p.check("...with the keyboard on the header's Check for Updates, the first control there",
        lev("popup.Window.activeFocusItem === refreshButton"), True)
p.clear_calls()
serve(FULL, delay=1)
ev("startupAction.trigger()")
p.pump(100)
p.check("opening again starts afresh: the last error gone, the loading line, the lists folded",
        [ev("root.startupPage === null"), pev("problemLabel.text"), pev("loadingLabel.text"), pev("page.startsOpen")],
        [True, "", "Reading what starts with the computer…", False])
settle()
p.check("...and gathers again", p.call_count("startup --all"), 1)

# --- the keyboard on Refresh -----------------------------------------------------------------------
serve(FULL, delay=1)
pev("refreshButton.forceActiveFocus(Qt.TabFocusReason)")
press(Qt.Key_Space)
p.pump(100)
p.check("Refresh from the keyboard gathers", [pev("page.busy"), p.call_count("startup --all")], [True, 2])
press(Qt.Key_Space)
p.check("...a second press while it runs is ignored, and the keyboard stays on Refresh",
        [p.call_count("startup --all"), pev("page.Window.activeFocusItem === refreshButton")], [2, True])
settle()
p.check("...still there when the gather answers", pev("page.Window.activeFocusItem === refreshButton"), True)
press(Qt.Key_Escape)
p.wait_for(lev, "popup.Window.activeFocusItem === refreshButton", True)
p.check("...and Escape from there returns to the updates, the keyboard on Check for Updates",
        [lev("popup.startupOpen"), lev("popup.Window.activeFocusItem === refreshButton")], [False, True])
serve(FULL)
ev("startupAction.trigger()")
settle()
before = sev("closes")
press(Qt.Key_Escape)
p.check("Escape on the page goes back, and does not close the widget",
        [lev("popup.startupOpen"), sev("closes") - before], [False, 0])
press(Qt.Key_Escape)
p.check("...and Escape again asks to close", sev("closes") - before, 1)
ev("startupAction.trigger()")
settle()
p.clear_calls()
ev("startupAction.trigger()")
settle()
p.check("choosing it again while the page is open stays there and gathers afresh",
        [lev("popup.startupOpen"), p.call_count("startup --all")], [True, 1])
ev("root.popupClosed()")
p.check("closing the widget leaves the page, so it opens on the updates", lev("popup.startupOpen"), False)
ev("root.popupOpened()")
settle()
p.clear_calls()
ev("root.doCheck()")
settle()
p.check("...and nothing gathers in the background after all that", p.call_count("startup"), 0)

# --- a request while the widget is not on screen ----------------------------------------------------
# The open it asked for did not happen. Nothing gathers out of sight, and the next ordinary open
# shows the updates.
ev("root.popupClosed()")
p.pump(50)
p.clear_calls()
ev("root.startupPageWanted = true")
p.pump(100)
p.check("a request while the widget is not on screen gathers nothing and opens no page",
        [p.call_count("startup --all"), lev("popup.startupOpen"), ev("root.startupPageWanted")], [0, False, False])
ev("root.popupOpened()")
settle()
p.check("...so the next ordinary open shows the updates, and still gathers nothing",
        [lev("popup.startupOpen"), lev("startupPage.visible"), p.call_count("startup --all")], [False, False, 0])
ev("startupAction.trigger()")
settle()
p.check("...and the menu entry still opens the page after that", [lev("popup.startupOpen"), p.call_count("startup --all")],
        [True, 1])
ev("root.popupClosed()")
p.check("a request is gone once the widget closes", ev("root.startupPageWanted"), False)

# --- chosen while the widget was closed ----------------------------------------------------------------
# Plasma builds the full view lazily, on the open the menu entry asks for: the open comes first,
# then the request, which waits on main.qml until the view being built takes it. The view above
# goes first, as there is only ever one, and a second one built now stands in for that first build.
pop.setParentItem(None)
pop.deleteLater()
p.pump(50)
p.clear_calls()
ev("root.popupOpened()")
settle()
p.clear_calls()
ev("root.startupPageWanted = true")
pop2 = full.createWithInitialProperties({"plasmoidItem": root, "vm": root.property("vm")})
QQmlEngine.setObjectOwnership(pop2, QQmlEngine.CppOwnership)
p.keep.append(pop2)
lev2 = p.evaluator(pop2)
settle()
p.check("a view built after the request opens on the Startup page, and takes the request",
        [lev2("popup.startupOpen"), ev("root.startupPageWanted")], [True, False])
p.check("...and gathers once", p.call_count("startup --all"), 1)

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
p.check("the settings page has no Startup page setting to read",
        [p.calls_matching("config get startup_page"), cev("typeof startupPage")], [[], "undefined"])

sys.exit(p.done())
