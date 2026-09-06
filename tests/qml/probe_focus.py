#!/usr/bin/env python3
"""Controls that vanish or go inert under the keyboard, and where the focus goes then.

Kept as the sequences these bugs were found by rather than rewritten - each one is a sequence a user
can walk into, and the bug in every case is a control that stopped being on screen while it still
held the keyboard.

  F1  Update Now is HIDDEN when there is nothing to run, and the box can become up to date while
      the popup is open (the 30s watcher, the hourly timer, a `kempt update` finishing in a
      terminal). Focus stayed on the hidden button, so Space started `kempt run` on a box with
      nothing to update.
  F4  the same trap on Refresh, which used to be hidden while a check ran, plus the open that
      walks straight into it: popupOpened() fires the refresh-on-open check FIRST and announces
      popupShown() after, so focusPrimary() chose a Refresh button the check had just taken off
      the screen - and the popup opened with the keyboard on nothing at all.

Like probe_a11y.py this one builds a real offscreen window, because `activeFocus` is a property of
a scene: without a window an item can be told to take focus and will set its own `focus` flag
while `activeFocus` stays false and a Tab key has nowhere to be delivered. `dbus-send` and
`xdg-open` are shadowed on PATH so nothing here can reach a real session.
"""
import json
import os
import sys

import harness

if not harness.have_pyside():
    print("ok: SKIPPED - PySide6 absent")
    sys.exit(0)

p = harness.Probe("probe-focus")
os.makedirs(os.path.join(p.state, "logs"))
os.makedirs(p.config)
STATE_JSON = os.path.join(p.state, "state.json")
# Which state `kempt check` serves, and how long it takes to serve it. Both are files because both
# are worlds the widget has to react to a CHANGE in while it is running.
CHECKSRC = os.path.join(p.sandbox, "checksrc")
RUNJSON = os.path.join(p.sandbox, "runjson")
SLEEP = os.path.join(p.sandbox, "checksleep")
open(SLEEP, "w").write("0")
open(CHECKSRC, "w").write(os.path.join(harness.FIXTURES, "state-live.json"))
open(RUNJSON, "w").write(
    json.dumps(json.load(open(os.path.join(harness.FIXTURES, "run-last.json")))))

os.environ["PATH"] = p.bindir + os.pathsep + os.environ["PATH"]
for _name in ("dbus-send", "xdg-open"):
    _path = os.path.join(p.bindir, _name)
    open(_path, "w").write("#!/usr/bin/env bash\nexit 0\n")
    os.chmod(_path, 0o755)

p.stub("""
case "$1" in
  config) [[ "$3" == refresh_interval_min ]] && echo 15; [[ "$3" == surface ]] && echo terminal
          [[ "$3" == auto_accept ]] && echo true
          [[ "$3" == restart_reminder ]] && echo true; exit 0 ;;
  check)  sleep "$(cat %(SLEEP)s)"; cp "$(cat %(SRC)s)" %(ST)s; cat %(ST)s; exit 0 ;;
  run)    exit 0 ;;
  summary) if [[ "$2" == "--json" ]]; then cat %(RUNJSON)s; fi; exit 0 ;;
esac
""" % {"SRC": CHECKSRC, "ST": STATE_JSON, "RUNJSON": RUNJSON, "SLEEP": SLEEP})

root, ev = p.create("main.qml")
p.wait_for(ev, "root.kemptState !== null", True)


def settle():
    p.wait_for(ev, "root.checking || root.pendingHold !== null", False, timeout_ms=30000)
    p.wait_idle(ev, "executor", "tailExecutor", timeout_ms=30000)


settle()

from PySide6.QtCore import QCoreApplication, QEvent, Qt, QUrl      # noqa: E402
from PySide6.QtGui import QKeyEvent                                # noqa: E402
from PySide6.QtQml import QQmlComponent, QQmlEngine                # noqa: E402
from PySide6.QtQuick import QQuickWindow                           # noqa: E402

full = QQmlComponent(p.engine, QUrl.fromLocalFile(
    os.path.join(harness.UI, "FullRepresentation.qml")))
live = full.createWithInitialProperties({"plasmoidItem": root, "vm": root.property("vm")})
QQmlEngine.setObjectOwnership(live, QQmlEngine.CppOwnership)
p.keep.append((full, live))
lev = p.evaluator(live)
# createWithInitialProperties sets `vm` ONCE; the popup's own file binds it to the plasmoid, and
# without re-binding it here every later state change would leave this copy on the first view
# model the widget ever built.
lev("popup.vm = Qt.binding(function () { return popup.plasmoidItem.vm; })")

win = QQuickWindow()
win.resize(460, 560)
live.setParentItem(win.contentItem())
live.setWidth(460)
live.setHeight(560)
win.show()
p.pump(200)

# Escape is a REQUEST in this widget - main.qml owns `expanded`, and assigning it out here would
# segfault the probe - so the signal is counted instead of acted on.
spy, sev = p.create_inline("""
import QtQuick
QtObject { id: spy; property int closes: 0; function bump() { spy.closes++; } }
""", "close-spy.qml")
p.engine.rootContext().setContextProperty("closeSpy", spy)
lev("popup.closeRequested.connect(closeSpy.bump)")

# What the keyboard is standing on, named. Anything that is not one of the three controls comes
# back with its text so a failure says where focus actually went.
FOCUSED = """(function () {
  var it = popup.Window.activeFocusItem;
  if (!it) return "nothing";
  if (it === updateButton) return "updateButton";
  if (it === refreshButton) return "refreshButton";
  if (it === configureButton) return "configureButton";
  if (it === popup) return "popup";
  if (it === checkAgainButton) return "checkAgainButton";
  var t = (it.text === undefined || it.text === null) ? "" : String(it.text);
  return "elsewhere:" + t;
})()"""


def focused():
    return lev(FOCUSED)


def press(key, mod=Qt.NoModifier):
    QCoreApplication.sendEvent(win, QKeyEvent(QEvent.KeyPress, key, mod))
    QCoreApplication.sendEvent(win, QKeyEvent(QEvent.KeyRelease, key, mod))
    p.pump(30)


def fixture(name):
    return os.path.join(harness.FIXTURES, name)


def state(path):
    """Run a real check that serves `path`, exactly as the watcher or the hourly timer would."""
    open(CHECKSRC, "w").write(path)
    ev("root.doCheck()")
    settle()
    p.pump(150)


def uptodate_from(source, name):
    """The same state with nothing pending: what a box looks like the moment a run finishes."""
    doc = json.load(open(fixture(source)))
    for backend in doc["backends"].values():
        backend["items"] = []
        backend["actionable"] = 0
        backend["held"] = 0
    doc["actionable"] = 0
    doc["held_total"] = 0
    path = os.path.join(p.sandbox, name)
    open(path, "w").write(json.dumps(doc))
    return path


UPTODATE = uptodate_from("state-live.json", "state-uptodate.json")

# ==================================================================================================
# F1. the focused Update Now disappears under the keyboard
# ==================================================================================================
state(fixture("state-live.json"))
ev('root.postRunLine = ""')
p.pump(120)
ev("root.popupOpened()")
p.pump(80)
p.check("the popup opens with the keyboard on Update Now, as designed",
        [focused(), lev("updateButton.visible"), ev("root.vm.actionable") > 0],
        ["updateButton", True, True])

state(UPTODATE)          # the box went up to date while the popup stayed open
ev('root.postRunLine = ""')
p.pump(200)
p.check("...the box goes up to date under it and the button is gone",
        [lev("updateButton.visible"), ev("root.vm.actionable")], [False, 0])
p.check("...so the keyboard does not stay on a button nobody can see",
        lev("popup.Window.activeFocusItem === updateButton"), False)
p.check("...it moves to the control that IS on screen", focused(), "refreshButton")
p.check("...and it moves there VISIBLY, which is the whole point of a focus ring",
        lev("refreshButton.visualFocus"), True)

runs_before = p.call_count("run")
press(Qt.Key_Space)
press(Qt.Key_Return)
settle()
p.check("pressing the keys that used to press it starts no update run",
        p.call_count("run") - runs_before, 0)
p.check("...and the popup never enters the updating state on an up-to-date box",
        ev("root.updating"), False)
# Whatever the two assertions above found, the rest of this file needs a widget that is not mid
# run: `updating` hides Update Now on its own, and a probe that left it set would go on measuring
# a hidden button for the wrong reason and report success for it.
ev("root.updating = false")
p.pump(50)

# The guard on its own, with focus PUT BACK on the hidden button by force. The focus move above is
# the fix; this is the belt to it, because a control that is invisible and still operable is a
# trap whatever route the keyboard took to reach it.
lev("updateButton.forceActiveFocus(Qt.TabFocusReason)")
p.pump(40)
runs_before = p.call_count("run")
press(Qt.Key_Space)
press(Qt.Key_Return)
settle()
p.check("...and even forced onto it, an invisible primary button cannot be activated",
        [p.call_count("run") - runs_before, ev("root.updating")], [0, False])
ev("root.updating = false")

# Focus that went nowhere would take Escape and Tab with it: the Escape handler lives on the popup
# and key events travel UP from whatever holds focus, so "no focus" means no keys reach it at all.
lev("popup.focusPrimary()")
p.pump(40)
before = sev("closes")
press(Qt.Key_Escape)
p.check("Escape still closes the popup after the button vanished", sev("closes") - before, 1)
press(Qt.Key_Tab)
p.check("...and Tab still has somewhere to go", focused() != "nothing", True)

# ==================================================================================================
# F4. the same trap on Refresh, and the open that walks straight into it
# ==================================================================================================
# Refresh used to be REPLACED by its spinner while a check ran. Same shape as F1 and the same
# consequence: the keyboard stayed on a control that was no longer on screen. It is disabled now
# and stays where it is, with the spinner beside it.
state(fixture("state-live.json"))
ev('root.postRunLine = ""')
lev("refreshButton.forceActiveFocus(Qt.TabFocusReason)")
p.pump(60)
p.check("the keyboard is on Refresh", focused(), "refreshButton")

open(SLEEP, "w").write("4")
ev("root.doCheck()")
p.pump(400)
p.check("a check is running, and the spinner is up", [ev("root.checking"), lev("refreshBusy.running")],
        [True, True])
p.check("...Refresh is still on screen, refusing rather than disappearing",
        [lev("refreshButton.visible"), lev("refreshButton.enabled")], [True, False])
p.check("...so the spinner sits BESIDE it rather than in its place",
        lev("refreshBusy.parent !== refreshButton"), True)

before_pending = ev("root.recheckPending")
press(Qt.Key_Space)
press(Qt.Key_Space)
press(Qt.Key_Space)
p.pump(200)
p.check("pressing a Refresh that is refusing queues nothing",
        [ev("root.recheckPending"), before_pending], [False, False])
open(SLEEP, "w").write("0")
settle()
p.check("...and it takes the keyboard back the moment the check is done",
        [lev("refreshButton.enabled"), lev("refreshButton.visible")], [True, True])

# The open that used to land on nothing. On an up-to-date box whose last successful check is old,
# popupOpened() starts the refresh FIRST (doCheck sets `checking` synchronously) and announces
# popupShown() after - so focusPrimary ran at the exact moment Refresh was unusable, with Update
# Now already hidden because there is nothing pending.
state(UPTODATE)
ev('root.postRunLine = ""')
p.check("up to date, with a stamp old enough for the popup to re-check on open",
        [ev("root.vm.actionable"),
         ev("Logic.shouldRefreshOnOpen(root.kemptState.last_success, root.refreshIntervalMin,"
            " Date.now())")],
        [0, True])
open(SLEEP, "w").write("4")
lev("configureButton.forceActiveFocus()")
p.pump(40)
ev("root.popupOpened()")
p.pump(120)
p.check("the refresh-on-open check really is in flight as focus is placed",
        ev("root.checking"), True)
landed = focused()
p.check("the popup never puts the keyboard on a control that cannot take it",
        [landed != "nothing",
         lev("popup.Window.activeFocusItem === null"
             " || (popup.Window.activeFocusItem.visible"
             "     && popup.Window.activeFocusItem.enabled)")],
        [True, True])
p.check("...and with nothing pending and Refresh refusing, that is the gear",
        landed, "configureButton")
open(SLEEP, "w").write("0")
settle()

# ==================================================================================================
# F5. the pane that replaces the whole content area, and where the keyboard goes with it
# ==================================================================================================
# Measured before this: a run replaces the content wholesale, the keyboard stayed on the INVISIBLE
# Update Now, and the utterance over the stuck pane was "Update Now push button" for a control
# nobody was drawing. Tab from there landed on a nameless RowLayout. On the default configuration
# that state could last three hours.
state(fixture("state-live.json"))
ev('root.postRunLine = ""')
p.pump(120)
lev("popup.focusPrimary()")
p.pump(50)
p.check("premise: the keyboard is on Update Now, with a run to start", focused(), "updateButton")

ev('root.enterUpdating("terminal")')
p.pump(120)
p.check("a run swaps the pane in and takes the primary button off the screen",
        lev("updateButton.visible"), False)
p.check("...so the keyboard moves to a control that is actually drawn", focused(),
        "checkAgainButton")
p.check("...visibly, which is the whole point of a focus ring",
        lev("checkAgainButton.visualFocus"), True)
p.check("...and it is a real control, not the pane or nothing at all",
        [lev("popup.Window.activeFocusItem.visible"),
         lev("popup.Window.activeFocusItem.enabled")], [True, True])
p.check("...naming the surface the run is really using rather than the configured one",
        lev("updatingLabel.text"), "Updating in a terminal window…")

# ...and Space on it really is the way out, from the keyboard, without a pointer.
before_check = p.call_count("check")
press(Qt.Key_Space)
p.wait_for(ev, "root.updating", False, timeout_ms=20000)
settle()
p.check("Space on the hatch asks for a check", p.call_count("check") - before_check >= 1, True)
p.check("...and the pane goes when that check lands", ev("root.updating"), False)
p.pump(120)
p.check("...handing the keyboard back to a control that is on screen",
        [focused() != "nothing",
         lev("popup.Window.activeFocusItem.visible && popup.Window.activeFocusItem.enabled")],
        [True, True])

# The other three surfaces say where to look, which "Updating in the terminal surface…" never did.
for _surface, _said in (("popup", "Updating…"),
                        ("background", "Updating in the background…"),
                        ("offline", "Preparing the install for the next restart…")):
    ev('root.enterUpdating("%s")' % _surface)
    p.pump(80)
    p.check("a run on the %s surface says where to look for it" % _surface,
            lev("updatingLabel.text"), _said)
    ev("root.leaveUpdating()")
    settle()
    ev('root.postRunLine = ""')
    p.pump(60)

# focusPrimary's own rule, stated once and driven in both directions, so a later edit cannot make
# it "the first control in the row" again.
state(fixture("state-live.json"))
ev('root.postRunLine = ""')
p.pump(120)
lev("popup.focusPrimary()")
p.pump(50)
p.check("with something to run, the primary is Update Now", focused(), "updateButton")
state(UPTODATE)
ev('root.postRunLine = ""')
p.pump(150)
lev("popup.focusPrimary()")
p.pump(50)
p.check("with nothing to run, it is Refresh", focused(), "refreshButton")

sys.exit(p.done())
