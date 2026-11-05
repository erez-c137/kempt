#!/usr/bin/env python3
"""The Startup Report: the menu entry, the page it opens, and the one command it gathers with.

The widget's menu offers Startup Report with no setting behind it, choosing it opens the page and
gathers with that exact argv and nothing else ever does, the CLI's text lands unchanged in the one
keyboard-readable text area, Refresh gathers again and refuses while one runs, a failure is said
calmly, and Back and Escape return to the updates with the keyboard on the header's Check for
Updates. The services with their two buttons are in probe_startup.py. Then the settings page, which
has no checkbox for it.
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
PAGE = os.path.join(p.sandbox, "page.txt")           # what `startup --all` prints
RC = os.path.join(p.sandbox, "rc")                   # ...and exits with
DELAY = os.path.join(p.sandbox, "delay")             # ...after sleeping this long
VALUES = os.path.join(p.sandbox, "values")
os.makedirs(VALUES)

HOSTILE = "<b>Bold</b><img src=x> & <a href='x'>link</a>"
FULL = """Failed this boot:
  imsettings-start (user)
    Current desktop isn't supported.
  %s

Runs on a schedule:
  Nightly backup: last run failed
""" % HOSTILE


def serve(page, rc=0, delay=0):
    open(PAGE, "w").write(page)
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
      [[ "$rc" == 0 ]] || echo "kempt: could not gather the Startup Report" >&2
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
QtObject {
    id: spy
    property int closes: 0
    property var said: []
    function bump() { spy.closes++; }
    function hear(sentence) { var a = spy.said.slice(); a.push(sentence); spy.said = a; }
}
""", "close-spy.qml")
p.engine.rootContext().setContextProperty("closeSpy", spy)
lev("popup.closeRequested.connect(closeSpy.bump)")
lev("popup.announced.connect(closeSpy.hear)")
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
p.check("the widget's menu offers Startup Report, with the icon the button had",
        [ev("startupAction.text"), ev("startupAction.icon.name")], ["Startup Report", "system-run"])
p.check("...registered with Check for Updates", ev("root.contextualActionsClaimed"), True)
_MAIN = " ".join(open(os.path.join(harness.UI, "main.qml")).read().split())
p.check("...beside it, in that order", "Plasmoid.contextualActions = [checkAction, startupAction, stageAction];" in _MAIN, True)
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
p.check("premise: the footer offers Update Now", [lev("popup.footer.visible"), lev("updateButton.visible")],
        [True, True])
serve(FULL, delay=1)
ev("startupAction.trigger()")
p.pump(100)
p.check("the menu entry opens the page in place of the updates",
        [lev("popup.startupOpen"), lev("startupPage.visible"), ev("root.startupPageWanted")], [True, True, False])
p.check("...gathering with kempt startup --all", p.argv("startup"), ["startup", "--all"])
p.check("...a busy indicator and a calm line meanwhile, Refresh still enabled, so focus can stay on it",
        [pev("busyIndicator.running"), pev("noteLabel.text"), pev("refreshButton.enabled")],
        [True, "Reading what starts with the computer…", True])
pev("refreshButton.clicked()")
settle()
p.check("...so a second press while it runs gathers nothing more", p.call_count("startup --all"), 1)
p.wait_for(pev, "page.Window.activeFocusItem === backButton", True)
p.check("the keyboard lands on Back", pev("page.Window.activeFocusItem === backButton"), True)
p.check("the updates are out of the way", lev("startupPage.visible && !updatingPane.visible"), True)
# The page only reads: Update Now there would start a run, or open the risky question, behind it.
p.check("...the footer too, Update Now with it, while the header's Check for Updates stays",
        [lev("popup.footer.visible"), lev("updateButton.visible"), lev("refreshButton.visible")],
        [False, False, True])
p.check("...and the keyboard is on a control that is drawn",
        lev("popup.Window.activeFocusItem.visible && popup.Window.activeFocusItem.enabled"), True)

SHOWN = FULL.rstrip("\n")
p.check("the CLI's text is shown as printed, in the one text area", pev("report.text"), SHOWN)
p.check("...nothing is on top of it when no service was announced",
        [pev("failedScroll.visible"), pev("noteLabel.visible"), pev("report.visible")], [False, False, True])
p.check("...named for a screen reader, its schedule section with it",
        [pev("report.area.Accessible.name"), "Runs on a schedule:" in pev("report.area.text")],
        ["Startup Report", True])
p.check("...and it is the shared component doctor's full report uses",
        ["ReportText {\n        id: report" in open(os.path.join(harness.UI, "StartupPage.qml")).read(),
         "ReportText {\n" in open(os.path.join(harness.UI, "FullRepresentation.qml")).read()],
        [True, True])
p.check("...which takes the keyboard and cannot be edited",
        [pev("report.area.readOnly"), pev("report.area.activeFocusOnTab"), pev("report.area.selectByKeyboard")],
        [True, True, True])
pev("report.area.forceActiveFocus(Qt.TabFocusReason)")
p.pump(30)
pev("report.area.cursorPosition = 0")
for _ in range(2):
    press(Qt.Key_Down)
p.check("the arrow keys walk the report's lines",
        pev("report.area.text.slice(0, report.area.cursorPosition).split('\\n').length"), 3)
pev("backButton.forceActiveFocus(Qt.TabFocusReason)")
p.pump(30)
BUTTONS = """(function () { var out = [];
  (function walk(o) {
     if (o.clicked !== undefined && o.text !== undefined && o.visible && out.indexOf(String(o.text)) < 0)
       out.push(String(o.text));
     for (var i = 0; i < o.children.length; i++) walk(o.children[i]);
  })(page); return JSON.stringify(out.sort()); })()"""
p.check("every button here reads or moves: none acts on the system", json.loads(pev(BUTTONS)), ["Back", "Refresh"])

# --- plain text, whatever the strings hold ----------------------------------------------------------
p.check("markup in a description or a log is shown as text, never read as markup",
        [pev("report.area.textFormat === TextEdit.PlainText"), HOSTILE in pev("report.area.getText(0, report.area.length)")],
        [True, True])

# --- Refresh ----------------------------------------------------------------------------------------
serve("Starts with the computer:\n  Nothing else\n")
p.clear_calls()
pev("refreshButton.clicked()")
settle()
p.check("Refresh gathers again with the same command", p.calls_matching("startup"), ["startup --all"])
p.check("...and the page follows", pev("report.text"), "Starts with the computer:\n  Nothing else")

# --- problems, said calmly --------------------------------------------------------------------------
serve("")
pev("refreshButton.clicked()")
settle()
p.check("nothing printed is one calm line, and no text area",
        [pev("noteLabel.text"), pev("report.visible")], ["Kempt could not read the startup list.", False])
serve("", rc=1)
pev("refreshButton.clicked()")
settle()
p.check("a failed gather gives the CLI's reason",
        pev("noteLabel.text"), "Kempt could not gather the startup list: kempt: could not gather the Startup Report")
p.check("...and says it out loud, since no text area is there to read",
        json.loads(str(sev("JSON.stringify(said)")))[-1], pev("noteLabel.text"))

# --- back ------------------------------------------------------------------------------------------
pev("backButton.clicked()")
p.pump(80)
p.check("Back returns to the updates", [lev("popup.startupOpen"), lev("startupPage.visible")], [False, False])
p.check("...and the footer with Update Now comes back", [lev("popup.footer.visible"), lev("updateButton.visible")],
        [True, True])
p.wait_for(lev, "popup.Window.activeFocusItem === refreshButton", True)
p.check("...with the keyboard on the header's Check for Updates, the first control there",
        lev("popup.Window.activeFocusItem === refreshButton"), True)
p.clear_calls()
serve(FULL, delay=1)
ev("startupAction.trigger()")
p.pump(100)
p.check("opening again starts afresh: the last error gone, the loading line",
        [ev("root.startupPage === null"), pev("noteLabel.text")], [True, "Reading what starts with the computer…"])
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

# --- during a run of ours --------------------------------------------------------------------------
# The page only reads, on its own queue, so a run does not keep it shut: it shows in place of the
# run's log, and Back or Escape brings the log back with the keyboard on the run's own control.
FOCUS = "popup.Window.activeFocusItem === "
p.check("the page gathers on its own queue, never the run's or its log's",
        "startupExecutor.run(kemptCmd + Logic.STARTUP_PAGE_ARGS," in _MAIN, True)
ev('root.enterUpdating("popup")')
p.pump(120)
p.check("premise: a run shows its log, the keyboard on its own control",
        [lev("updatingPane.visible"), lev(FOCUS + "checkAgainButton")], [True, True])
serve(FULL)
p.clear_calls()
ev("startupAction.trigger()")
settle()
p.check("the menu entry opens the page during a run, in place of the log",
        [lev("popup.startupOpen"), lev("startupPage.visible"), lev("updatingPane.visible"),
         p.call_count("startup --all")], [True, True, False, 1])
p.check("...with no footer under it", lev("popup.footer.visible"), False)
p.wait_for(pev, "page.Window.activeFocusItem === backButton", True)
p.check("...with the keyboard on Back", pev("page.Window.activeFocusItem === backButton"), True)
pev("backButton.clicked()")
p.pump(80)
p.check("Back returns to the run's log", [lev("popup.startupOpen"), lev("startupPage.visible"),
                                          lev("updatingPane.visible")], [False, False, True])
p.wait_for(lev, FOCUS + "checkAgainButton", True)
p.check("...with the keyboard on the run's own control", lev(FOCUS + "checkAgainButton"), True)
p.check("...and the footer back under the log", lev("popup.footer.visible"), True)
ev("startupAction.trigger()")
settle()
press(Qt.Key_Escape)
p.wait_for(lev, FOCUS + "checkAgainButton", True)
p.check("Escape does the same, and does not close the widget",
        [lev("popup.startupOpen"), lev("updatingPane.visible"), lev(FOCUS + "checkAgainButton")],
        [False, True, True])
ev("startupAction.trigger()")
settle()
p.check("premise: the keyboard is on Back", pev("page.Window.activeFocusItem === backButton"), True)
ev("root.leaveUpdating()")
settle()
p.pump(120)
p.check("the run ending while the page is open leaves the page as it was",
        [lev("popup.startupOpen"), lev("startupPage.visible"), lev("updatingPane.visible"),
         pev("report.text")], [True, True, False, SHOWN])
p.check("...the keyboard where it was", pev("page.Window.activeFocusItem === backButton"), True)
pev("backButton.clicked()")
p.wait_for(lev, FOCUS + "refreshButton", True)
p.check("...then Back returns to the updates, the run over", [lev("popup.startupOpen"), lev("updatingPane.visible"),
                                                             lev(FOCUS + "refreshButton")], [False, False, True])

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
