#!/usr/bin/env python3
"""The keyboard and the screen reader (Task P4).

The one probe in this directory that builds a WINDOW, and it is worth being plain about why,
because every other probe here deliberately does not.

`activeFocus` is a property of a scene, not of an item: an item with no window can be told to
take focus and will set its own `focus` flag, but `activeFocus` never becomes true and a Tab key
has nowhere to be delivered. Measured on this box, 2026-08-27:

    without a window   focus=True   activeFocus=False   Tab: nothing moves
    offscreen window   focus=True   activeFocus=True    Tab: focus really moves, in order

So a probe with no window can only assert that the QML SAYS the right thing. That is exactly the
kind of assertion this kit exists to avoid, and P4 is the task where it would matter most - "the
pin is reachable by Tab" is a claim about Qt's focus chain, not about our source. Hence one
offscreen QQuickWindow, here and nowhere else. The other probes stay windowless on purpose: their
assertions were all written under those conditions, and giving them a window would change what
they are measuring.

What is still NOT drivable, and it is the same wall probe_popup describes: `root.expanded` is
AppletQuickItem's C++ property and its setter dereferences an applet that does not exist out
here, so writing it SEGFAULTS the process. Both halves of P4 therefore travel through named
seams that a real panel also uses:

    open    root.popupOpened()  ->  signal popupShown()  ->  the popup's focusPrimary()
    close   Keys.onEscapePressed  ->  signal closeRequested()  ->  main.qml's `expanded = false`

This file drives the whole open chain for real, counts the close signal (and never wires it to
the assignment, which would kill the probe), and pins main.qml's two lines statically so the
drivable seam cannot drift from what the panel really does.
"""
import datetime
import json
import os
import sys

import harness

if not harness.have_pyside():
    print("ok: SKIPPED - PySide6 absent")
    sys.exit(0)

p = harness.Probe("probe-a11y")
os.makedirs(os.path.join(p.state, "logs"))
os.makedirs(p.config)
STATE_JSON = os.path.join(p.state, "state.json")
CHECKSRC = os.path.join(p.sandbox, "checksrc")
RUNJSON = os.path.join(p.sandbox, "runjson")
open(CHECKSRC, "w").write(os.path.join(harness.FIXTURES, "state-live.json"))
open(RUNJSON, "w").write(
    json.dumps(json.load(open(os.path.join(harness.FIXTURES, "run-last.json")))))

# Only the verbs this probe's states need. The command surface itself is probe_popup's subject.
p.stub("""
case "$1" in
  config) [[ "$3" == refresh_interval_min ]] && echo 15; [[ "$3" == surface ]] && echo popup
          [[ "$3" == auto_accept ]] && echo true
          [[ "$3" == restart_reminder ]] && echo true; exit 0 ;;
  check)  cp "$(cat %(SRC)s)" %(ST)s; cat %(ST)s; exit 0 ;;
  summary) if [[ "$2" == "--json" ]]; then cat %(RUNJSON)s; fi; exit 0 ;;
esac
""" % {"SRC": CHECKSRC, "ST": STATE_JSON, "RUNJSON": RUNJSON})

root, ev = p.create("main.qml")
p.wait_for(ev, "root.kemptState !== null", True)


def settle():
    p.wait_for(ev, "root.checking || root.pendingHold !== null", False, timeout_ms=15000)
    # promptExecutor too: the restart prompt runs on its own queue (see main.qml), so a settle
    # that only watched the other two could return with a dbus-send still in flight.
    p.wait_idle(ev, "executor", "tailExecutor", "promptExecutor")


settle()

from PySide6.QtCore import QCoreApplication, QEvent, Qt, QUrl      # noqa: E402
from PySide6.QtGui import QKeyEvent                                # noqa: E402
from PySide6.QtQml import QQmlComponent, QQmlEngine                # noqa: E402
from PySide6.QtQuick import QQuickWindow                           # noqa: E402

full = QQmlComponent(p.engine, QUrl.fromLocalFile(
    os.path.join(harness.UI, "FullRepresentation.qml")))
p.check("FullRepresentation compiles", [e.description() for e in full.errors()], [])
live = full.createWithInitialProperties({"plasmoidItem": root, "vm": root.property("vm")})
p.check("the popup builds with both its inputs handed to it", live is not None, True)
if live is None:
    sys.exit(p.done())
QQmlEngine.setObjectOwnership(live, QQmlEngine.CppOwnership)
p.keep.append((full, live))
lev = p.evaluator(live)
# A VALUE is not a BINDING: createWithInitialProperties assigns the view model once, and every
# state driven below would otherwise be measured against the one frozen at construction.
lev("popup.vm = Qt.binding(function () { return popup.plasmoidItem.vm; })")

# The window. Sized like a real popup rather than arbitrarily - Layout.preferredWidth/Height are
# 26x24 grid units, and a list that is never laid out creates no delegates, so a window too small
# for the list would be a probe that could not see the pins it is here to reach.
win = QQuickWindow()
win.resize(460, 560)
live.setParentItem(win.contentItem())
live.setWidth(460)
live.setHeight(560)
win.show()
p.pump(200)

# closeRequested, counted and deliberately NOT acted on. main.qml answers this signal with
# `root.expanded = false`; a probe that copied that wiring would segfault on the first Escape.
spy, sev = p.create_inline("""
import QtQuick
QtObject { id: spy; property int closes: 0; function bump() { spy.closes++; } }
""", "close-spy.qml")
p.engine.rootContext().setContextProperty("closeSpy", spy)
lev("popup.closeRequested.connect(closeSpy.bump)")


def closes():
    return sev("closes")


# --- reading the focus chain --------------------------------------------------------------------
# What holds focus, named for the assertion output. Controls inside the list, inside the last-run
# row and inside a message are named by their container as well as their label, because "which
# message does this button belong to" is half of what the tab order has to get right.
FOCUSED = """(function () {
  var it = popup.Window.activeFocusItem;
  if (!it) return "nothing";
  if (it === updateButton) return "updateButton";
  if (it === refreshButton) return "refreshButton";
  if (it === configureButton) return "configureButton";
  var t = (it.text === undefined || it.text === null) ? "" : String(it.text);
  function within(c) { for (var q = it; q; q = q.parent) if (q === c) return true; return false; }
  if (within(rowsView)) return "row:" + t;
  if (within(lastRunView)) return "lastRun:" + t;
  var msgs = {restartMessage: restartMessage, riskyMessage: riskyMessage,
              stagedMessage: stagedMessage, reportMessage: reportMessage};
  for (var k in msgs) if (within(msgs[k])) return k + ":" + t;
  return "elsewhere:" + t;
})()"""


def focused():
    return lev(FOCUSED)


def press(key, mod=Qt.NoModifier):
    """A real key event, delivered to the window the way a keyboard delivers one."""
    QCoreApplication.sendEvent(win, QKeyEvent(QEvent.KeyPress, key, mod))
    QCoreApplication.sendEvent(win, QKeyEvent(QEvent.KeyRelease, key, mod))
    p.pump(20)


def walk(steps, back=False):
    """Where Tab (or Shift+Tab) goes, `steps` times, starting from wherever focus is now."""
    seen = []
    for _ in range(steps):
        press(Qt.Key_Backtab if back else Qt.Key_Tab,
              Qt.ShiftModifier if back else Qt.NoModifier)
        seen.append(focused())
    return seen


def fixture(name):
    return os.path.join(harness.FIXTURES, name)


def state(path):
    """Point the stubbed CLI at a state document and let the widget go and read it."""
    open(CHECKSRC, "w").write(path)
    ev("root.doCheck()")
    settle()
    p.pump(120)


def long_from(source, name, count):
    """A pending list far longer than the popup can show - an ordinary weekly Fedora update.

    Derived from the shipped capture rather than added to tests/fixtures/, for the same reason
    uptodate_from is: it is the real document with its dnf list stretched, so it cannot drift
    away from the shape the CLI writes.
    """
    doc = json.load(open(fixture(source)))
    seed = [i for i in doc["backends"]["dnf"]["items"] if not i.get("held")]
    items = []
    while len(items) < count:
        for it in seed:
            if len(items) >= count:
                break
            clone = dict(it)
            clone["name"] = "%s-%03d" % (it["name"], len(items))
            items.append(clone)
    doc["backends"] = {"dnf": dict(doc["backends"]["dnf"], items=items,
                                   actionable=len(items), held=0)}
    doc["actionable"] = len(items)
    doc["held_total"] = 0
    path = os.path.join(p.sandbox, name)
    open(path, "w").write(json.dumps(doc))
    return path


def uptodate_from(source, name, fresh=False):
    """A real capture with nothing left pending - the one shape no fixture carries.

    `fresh` restamps last_success to now. Every fixture here is a dated capture, so a popup opened
    over one re-checks on open (Logic.shouldRefreshOnOpen) - which is correct behaviour and a
    confound for any assertion about where the keyboard LANDS, because Refresh is disabled while
    that check runs. Where focus goes when Refresh is the one unusable control is probe_focus.py's
    subject; here the question is only which control is the primary one, so the state says it was
    checked a moment ago and no check starts.
    """
    doc = json.load(open(fixture(source)))
    if fresh:
        doc["last_success"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    for backend in doc["backends"].values():
        backend["items"] = []
        backend["actionable"] = 0
        backend["held"] = 0
    doc["actionable"] = 0
    doc["held_total"] = 0
    path = os.path.join(p.sandbox, name)
    open(path, "w").write(json.dumps(doc))
    return path


def pin_label(row):
    """What the pin on this row says - which is also its accessible name.

    Four spellings, because the state is carried by the NAME (a `checkable: false` button exposes
    no checked state to AT-SPI on Qt 6.11) and because a package with no current version has
    nothing to be held AT: "Hold brandnew at ?" is not a sentence.
    """
    if row["from"] == "?":
        return ("Stop skipping %s" if row.get("held") else "Skip installing %s") % row["name"]
    if row.get("held"):
        return "Stop holding %s" % row["name"]
    return "Hold %s at %s" % (row["name"], row["from"])


def pins():
    """The pin stop this probe expects for every package row, in the list's own order.

    Derived from the live view model rather than written out, so it stays true to whatever the
    fixture holds - and so it asserts the pin's OWN sentence at every stop, which is the thing
    that makes a list of twelve identical buttons usable from the keyboard.
    """
    rows = json.loads(str(lev("JSON.stringify(popup.vm.rows)")))
    return ["row:" + pin_label(r) for r in rows if r.get("kind") == "item"]


# ==================================================================================================
# Where the keyboard lands when the popup opens.
# ==================================================================================================
# Driven through popupOpened(), which is the function a real `expanded` change calls (probe_popup
# pins that line) - so this exercises the whole chain the panel uses, signal included, rather than
# calling focusPrimary() and calling it proof.
state(fixture("state-live.json"))
ev('root.postRunLine = ""')
p.pump(100)
lev("configureButton.forceActiveFocus()")          # focus somewhere else first, so a pass means
p.check("...somewhere else to start from", focused(), "configureButton")   # something moved it

ev("root.popupOpened()")
p.pump(50)
p.check("opening the popup puts the keyboard on Update Now", focused(), "updateButton")
p.check("...with real focus in a real scene, not just a flag on the item",
        lev("updateButton.activeFocus"), True)
p.check("...and visibly so: a focus ring is drawn from visualFocus, which only the keyboard "
        "focus reasons set, so Qt.PopupFocusReason here would be focus nobody can see",
        lev("updateButton.visualFocus"), True)
settle()

# ...and the state where that button is not on screen at all. It is HIDDEN rather than disabled,
# so focusing it would leave the popup with no focus anywhere - and a popup with no focus is one
# where Tab starts from nothing and Escape does not work.
UPTODATE = uptodate_from("state-live.json", "state-uptodate.json", fresh=True)
state(UPTODATE)
ev('root.postRunLine = ""')
p.pump(100)
p.check("up to date: there is no Update Now to focus", lev("updateButton.visible"), False)
p.check("...and the counts are fresh, so this open starts no check to disable Refresh",
        ev("root.checking"), False)
lev("configureButton.forceActiveFocus()")
ev("root.popupOpened()")
p.pump(50)
p.check("...so opening the popup puts the keyboard on Refresh instead", focused(), "refreshButton")
p.check("...and nothing is focusing the hidden button", lev("updateButton.activeFocus"), False)
settle()

# ==================================================================================================
# The tab order, measured with real Tab keys.
# ==================================================================================================
# The plan named an order - Update Now, list rows, message actions, Refresh - and this is what Qt
# actually does, which is creation order and NOT that. The departure is deliberate and argued in
# the commit body; what matters here is that the order is stated exactly, so a change to it shows
# up as a failing assertion rather than as nobody noticing.
state(fixture("state-live.json"))
ev('root.postRunLine = ""')
p.pump(100)
ev("root.popupOpened()")
settle()
lev("popup.focusPrimary()")
p.pump(50)
expected = ["refreshButton", "configureButton"] + pins() + ["lastRun:Expand", "updateButton"]
got = walk(len(expected))
p.check("Tab walks the whole popup from Update Now and comes back to it", got, expected)
p.check("...which means every package row's pin is a tab stop", len(pins()), 10)

# The pin the user is standing on names ITS package, and that is the property a screen reader
# reads out. Asserted off the focused item rather than off a delegate built by hand: it is the
# same control the Tab above arrived at.
lev("popup.focusPrimary()")
p.pump(20)
walk(3)
p.check("the first pin is where three Tabs from Update Now lands", focused(), pins()[0])
p.check("...and it introduces itself by naming its own package, at its own version",
        lev("popup.Window.activeFocusItem.text"),
        "Hold aajohan-comfortaa-fonts at 3.105-0.9.20210729git2a87ac6.fc44")
# The description is the CONSEQUENCE and not the name read back. QQC2 already hands `text` to
# AT-SPI as the accessible name, so a description bound to `text` was the sentence spoken twice
# and the one slot that could explain what pressing this does, wasted (hostile panel, a11y P4).
p.check("...while the description says what holding it will DO, which nothing else says anywhere",
        lev("popup.Window.activeFocusItem.Accessible.description"),
        "Kempt skips it on every update until you stop holding it.")
p.check("...and is not the name a second time",
        lev("popup.Window.activeFocusItem.Accessible.description"
            " === popup.Window.activeFocusItem.text"), False)

# Backwards, once, because a chain that only walks one way is a chain with a trap in it.
lev("popup.focusPrimary()")
p.pump(20)
p.check("Shift+Tab from Update Now goes to the other end of the ring rather than nowhere",
        walk(1, back=True), ["lastRun:Expand"])

# A message that appears puts its actions in the ring, between the header and the list, and takes
# them away again when it goes. Both halves matter: an action nobody can reach by keyboard is not
# an action, and a stale stop left behind by a hidden message is a Tab into nothing.
state(fixture("state-reboot-needed.json"))
ev("root.restartDismissed = false")
ev('root.postRunLine = ""')
p.pump(120)
p.check("a restart is owed, so the message is up", lev("restartMessage.visible"), True)
lev("popup.focusPrimary()")
p.pump(50)
expected = (["refreshButton", "configureButton",
             "restartMessage:Restart…", "restartMessage:Close"]
            + pins() + ["lastRun:Expand", "updateButton"])
p.check("...and its Restart button and its close button are both in the tab order, in the "
        "message stack's own place: after the header, before the list",
        walk(len(expected)), expected)

state(fixture("state-risky-heavy.json"))
ev('root.postRunLine = ""')
p.pump(120)
p.check("a session-critical transaction is pending, so that message is up instead",
        lev("riskyMessage.visible"), True)
lev("popup.focusPrimary()")
p.pump(50)
expected = (["refreshButton", "configureButton", "riskyMessage:Install on Next Restart"]
            + pins() + ["lastRun:Expand", "updateButton"])
p.check("...so its action is the stop after the header, and the restart message's two are gone",
        walk(len(expected)), expected)

# The state this widget is actually FOR. A weekly Fedora update is fifty to two hundred packages,
# and a ListView only builds the delegates near its viewport - so before P4's scroll-into-view,
# the focus chain simply ended at whichever row happened to exist and Tab jumped out of the list.
# Measured on the 24-package fixture before the fix: 17 of 24 pins reachable, the other 7 not
# reachable by keyboard at all.
LONG = long_from("state-live.json", "state-long.json", 80)
state(LONG)
ev('root.postRunLine = ""')
p.pump(150)
lev("popup.focusPrimary()")
p.pump(50)
_rows = pins()
p.check("eighty packages pending, which is an ordinary Tuesday", len(_rows), 80)
# Two for the header, one for the last-run row, one to land back on Update Now: a complete ring.
_seq = walk(len(_rows) + 4)
_stops = [x for x in _seq if x.startswith("row:")]
p.check("...and Tab reaches every one of their pins", len(_stops), len(_rows))
p.check("...each exactly once", len(set(_stops)), len(_rows))
p.check("...the last package in the list included, which is the one a viewport-sized focus chain "
        "loses", _rows[-1] in _stops, True)
p.check("...in the list's own order", _stops == _rows, True)
# The rest of the ring, in one assertion, because the failure this catches is an EXTRA stop
# rather than a missing one: a recycled delegate is no longer the next child of the view, so the
# chain leaves the list at the end of the pool, goes round the header, and comes back in.
p.check("...and the header is passed once on the way round, not once per screenful of list",
        [x for x in _seq if not x.startswith("row:")],
        ["refreshButton", "configureButton", "lastRun:Expand", "updateButton"])

# The quietest state, where most of the popup is not there: the ring still closes, and it still
# never stops on the hidden Update Now.
state(UPTODATE)
ev('root.postRunLine = ""')
p.pump(120)
lev("popup.focusPrimary()")
p.pump(50)
p.check("up to date: Tab still has somewhere to go and comes back",
        walk(3), ["configureButton", "lastRun:Expand", "refreshButton"])

# ==================================================================================================
# Escape.
# ==================================================================================================
state(fixture("state-live.json"))
ev('root.postRunLine = ""')
p.pump(120)
lev("popup.focusPrimary()")
p.pump(50)
before = closes()
press(Qt.Key_Escape)
p.check("Escape on the primary button asks the popup to close", closes() - before, 1)

# From inside the list, which is the half that would break if the handler had been put on a
# control instead of on the popup: key events travel UP the parent chain, so one handler at the
# top catches every descendant and no control has to remember to forward anything.
lev("popup.focusPrimary()")
p.pump(20)
walk(3)
p.check("...standing on a pin deep inside the list", focused(), pins()[0])
before = closes()
press(Qt.Key_Escape)
p.check("...and Escape from there asks just the same", closes() - before, 1)

# ...and nothing else does. A popup that asked to close on every keystroke would be a popup that
# could not be used from the keyboard at all.
before = closes()
press(Qt.Key_Tab)
press(Qt.Key_Down)
press(Qt.Key_Space)
p.check("no other key asks the popup to close", closes() - before, 0)

# ==================================================================================================
# What a screen reader is told.
# ==================================================================================================
# Icon-only buttons first. `text` is set on all of them - it is what the tooltip shows - but it is
# never DRAWN, so without this the control is an unnamed icon to anybody not using a pointer.
p.check("the Refresh icon says what it is", lev("refreshButton.Accessible.name"),
        "Check for Updates")
p.check("...and so does the gear", lev("configureButton.Accessible.name"), "Configure Kempt…")
p.check("...each one saying exactly what its tooltip says, so the two can never disagree",
        [lev("refreshButton.Accessible.name") == lev("refreshButton.text"),
         lev("configureButton.Accessible.name") == lev("configureButton.text")],
        [True, True])
# ...and the description is the second thing a screen reader reads, so it is the slot for what
# pressing this DOES. Bound to `text` it was the label spoken twice and nothing learned (a11y P4).
p.check("the Refresh icon also says what pressing it does",
        lev("refreshButton.Accessible.description"),
        "Asks dnf and flatpak what is pending now, instead of waiting for the timer.")
p.check("...and the gear says what is behind it", lev("configureButton.Accessible.description"),
        "Check interval, where updates run, restart reminders, and the packages you hold.")
p.check("...neither of them repeating its own label",
        [lev("refreshButton.Accessible.description") == lev("refreshButton.text"),
         lev("configureButton.Accessible.description") == lev("configureButton.text")],
        [False, False])

# The message stack. Kirigami gives every InlineMessage the AlertMessage role and no NAME, so an
# alert with nothing added announces its icon - "Warning" - and not a word about what happened.
state(fixture("state-reboot-needed.json"))
ev("root.restartDismissed = false")
p.pump(120)
p.check("the restart message announces its own sentence",
        lev("restartMessage.Accessible.name"), "Restart to apply installed updates")
p.check("...as the alert it already was, rather than in place of it",
        lev("restartMessage.Accessible.role === Accessible.AlertMessage"), True)

state(fixture("state-risky-heavy.json"))
p.pump(120)
p.check("the session-critical warning announces the sentence it is showing",
        lev("riskyMessage.Accessible.name"), lev("riskyMessage.text"))
p.check("...which is the one logic.js wrote, not a second copy",
        lev("riskyMessage.Accessible.name"), lev("popup.vm.riskyMessage"))

# Staleness is no longer a message: it is three words on the footer's dateline, and the popup says
# them out loud when the box goes stale - politely, because nothing needs interrupting.
state(fixture("state-stale.json"))
p.pump(120)
p.check("staleness is on the footer now, beside the date it explains",
        "last check failed" in str(lev("footerLabel.text")), True)
p.check("...and the reason a person has to act on is on the button that acts",
        "dnf check failed" in str(lev("refreshButton.Accessible.description")), True)

# ==================================================================================================
# What AT-SPI is actually handed, with accessibility ACTIVE.
# ==================================================================================================
# Everything above asserts what the QML says. This asks the other question, and they are not the
# same one: with accessibility activated the way a bridge activates it, QQC2 hands a button's
# `text` over as its accessible name - and the hostile panel measured an EMPTY name on every
# button, Update Now included, when accessibility was active before construction. So the popup
# spells `Accessible.name: text` out, and this is the gate that says the spelling worked.
#
# Activated HERE rather than at the top of the file, after the popup is built, which is also what
# the earlier assertions were written under: turning it on changes what QQuickItem reports.
from PySide6.QtGui import QAccessible                              # noqa: E402

QAccessible.setActive(True)
p.check("accessibility can be activated on this Qt at all", QAccessible.isActive(), True)


def at_of(item):
    """(name, role) as an assistive technology would be handed them."""
    if item is None:
        return (None, None)
    iface = QAccessible.queryAccessibleInterface(item)
    if iface is None:
        return (None, None)
    return (iface.text(QAccessible.Text.Name), iface.role())


state(fixture("state-live.json"))
ev('root.postRunLine = ""')
p.pump(120)
lev("popup.focusPrimary()")
p.pump(50)

_ring = ["refreshButton", "configureButton"] + pins() + ["lastRun:Expand", "updateButton"]
_unnamed, _mis_roled = [], []
for _stop in _ring:
    press(Qt.Key_Tab)
    _where = focused()
    _name, _role = at_of(lev("popup.Window.activeFocusItem"))
    if not _name:
        _unnamed.append((_where, _name))
    if _role != QAccessible.Role.Button:
        _mis_roled.append((_where, str(_role)))
p.check("every stop in the tab ring reaches AT-SPI with a name on it", _unnamed, [])
p.check("...and as a button, which is what it is", _mis_roled, [])

# The pin, read the way an assistive technology reads it: name, then role, then description. The
# name carries the state (there is no checked state to carry it - a `checkable: false` button
# exposes none on Qt 6.11, and the CheckBox role that would draws Breeze's sunken checked
# background under the tray's own checked Keep Open pin).
lev("popup.focusPrimary()")
p.pump(20)
walk(3)
_pin_name, _pin_role = at_of(lev("popup.Window.activeFocusItem"))
p.check("the pin hands AT-SPI its own sentence, state and package and version included",
        _pin_name, "Hold aajohan-comfortaa-fonts at 3.105-0.9.20210729git2a87ac6.fc44")
p.check("...as a button", _pin_role, QAccessible.Role.Button)

# The group headings. PlasmaExtras.ListSectionHeader marks its own label Accessible.ignored
# (system ListSectionHeader.qml), so "Held" reached AT-SPI as role Client with an empty name -
# which is the one thing that rescues the held state from being a colour and a position.
state(fixture("state-held-only.json"))
ev('root.postRunLine = ""')
p.pump(150)
lev("rowsView.positionViewAtBeginning()")
p.pump(80)
_heading = lev("""(function () {
  var loader = rowsView.itemAtIndex(0);
  if (loader === null || loader.item === null) return null;
  var out = null;
  (function walk(o) {
     if (out !== null) return;
     if (o.label !== undefined && String(o.label) !== "") { out = o; return; }
     for (var i = 0; i < o.children.length; i++) walk(o.children[i]);
  })(loader.item);
  return out;
})()""")
_head_name, _head_role = at_of(_heading)
p.check("the Held heading reaches AT-SPI by name", _head_name, "Held")
p.check("...as a heading, which is what Orca navigates by", _head_role, QAccessible.Role.Heading)
p.check("...with the one line a dnf user needs under it, because they read versionlock into this",
        lev("""(function () {
  var hit = false;
  (function walk(o) {
     if (hit) return;
     if (o.text !== undefined
         && String(o.text) === "Held packages are skipped by Kempt only." && o.visible) {
       hit = true; return;
     }
     for (var i = 0; i < o.children.length; i++) walk(o.children[i]);
  })(rowsView.itemAtIndex(0).item);
  return hit; })()"""), True)

# ...and the version line, which used to hand over "3.105… → 3.106-1.fc44" and send the arrow
# through Orca's character table.
_version = lev("""(function () {
  var out = null;
  (function walk(o) {
     if (out !== null) return;
     if (o.text !== undefined && String(o.text).indexOf(" → ") > 0) { out = o; return; }
     for (var i = 0; i < o.children.length; i++) walk(o.children[i]);
  })(rowsView.itemAtIndex(1).item);
  return out; })()""")
p.check("the version line says its two versions in words",
        at_of(_version)[0], "from 3.105-0.9.20210729git2a87ac6.fc44 to 3.106-1.fc44")

state(fixture("state-live.json"))
ev('root.postRunLine = ""')
p.pump(120)

# --- and the rule behind those, applied to the whole widget ---------------------------------------
# Live assertions can only cover the controls a probe happens to reach. These two are the rule
# itself: a new icon-only button, or a sixth message, cannot arrive unannounced.


def _code(name):
    """One .qml file with its comments removed, on one line."""
    lines = [ln.split("//")[0] for ln in open(os.path.join(harness.UI, name))]
    return " ".join(" ".join(lines).split())


# Descriptions that belong to something OTHER than an icon-only button, named here so the count
# below can stay an equality. Equality is what makes it a gate: `>=` would go on passing when a new
# icon-only button arrived with no description, because some unrelated description elsewhere was
# already covering for it.
#
# FullRepresentation.qml has two. The Rebuild Staged Update action is a labelled button, not an
# icon-only one, and it carries a description anyway: its tooltip discloses that the rebuild asks
# for authorization and that a failed rebuild removes the current staged update, and a polkit
# dialog takes the focus the instant it is pressed. A disclosure that has not been heard by then is
# never heard, so the same words are bound to Accessible.description. The second is the updating
# pane's escape hatch, which is text-only and says what pressing it does - it is the ONLY control
# in that pane, so a person who cannot see the label has nothing else to go on.
_EXTRA_DESCRIPTIONS = {"FullRepresentation.qml": 2}

for _name in sorted(n for n in os.listdir(harness.UI) if n.endswith(".qml")):
    _s = _code(_name)
    if "IconOnly" not in _s:
        continue
    p.check("every icon-only button in %s carries an accessible description" % _name,
            _s.count("Accessible.description"),
            _s.count("IconOnly") + _EXTRA_DESCRIPTIONS.get(_name, 0))
    # ...and an explicit NAME, which is the half this gate used to miss entirely. `text` is what
    # makes an icon-only button speak; a probe measured an EMPTY name on every button, Update Now
    # included, when accessibility was activated before construction, so the belt is spelled out.
    p.check("...and an explicit accessible name, because `text` alone was measured empty",
            _s.count("Accessible.name: text") >= _s.count("IconOnly"), True)
    # The bug the count above cannot see: a description that is the name read back. It passes a
    # count and says nothing (a11y P4), so it is forbidden outright.
    p.check("...and no icon-only button describes itself with its own label",
            "Accessible.description: text" in _s, False)

_popup = _code("FullRepresentation.qml")

# Scoped to the message stack rather than counted over the whole file: the header's own icon-only
# buttons spell their accessible names out too, so a whole-file count would be satisfied by those
# and pass with a message carrying nothing. The stack is one contiguous run between the first
# InlineMessage and the list.
_raw = open(os.path.join(harness.UI, "FullRepresentation.qml")).read()
_stack = _raw[_raw.index("Kirigami.InlineMessage {"):_raw.index("--- the list, and what stands")]
p.check("every message in the stack announces its own words",
        _stack.count("Accessible.name: text"), _stack.count("Kirigami.InlineMessage {"))

# ==================================================================================================
# The pins that keep the drivable seams honest.
# ==================================================================================================
# Everything above drives popupOpened() and calls focusPrimary(), because writing `expanded` from
# a probe segfaults the process. These tie both ends back to the property a real panel changes.
_MAIN = _code("main.qml")

p.check("the open really does announce itself, from the function a real expand calls",
        "if (Logic.shouldRefreshOnOpen(lastSuccess, refreshIntervalMin, Date.now())) doCheck();"
        " root.popupShown(); }" in _MAIN, True)
p.check("...and the popup is listening to that signal on the widget it was handed",
        "Connections { target: popup.plasmoidItem"
        " function onPopupShown() { popup.focusPrimary(); } }" in _popup, True)
p.check("...with the first open, where the popup is built too late to hear it, covered separately",
        "Component.onCompleted: if (popup.plasmoidItem.expanded) popup.focusPrimary()" in _popup,
        True)

p.check("Escape asks and nothing more - the popup emits, and does not act",
        "Keys.onEscapePressed: event => { popup.closeRequested(); event.accepted = true; }"
        in _popup, True)
p.check("...and main.qml is what answers it, next to the property it owns",
        "onCloseRequested: root.expanded = false" in _MAIN, True)

# The rule that makes all of the above necessary, stated as a count. `expanded` is the property
# whose setter segfaults outside plasmashell: one assignment in the whole widget, in the file that
# owns it, and none at all in a popup that a test has to be able to press keys in.
p.check("the popup never writes the property that would take a test down with it",
        "expanded =" in _popup, False)
p.check("...and main.qml writes it exactly once", _MAIN.count("expanded = "), 1)

sys.exit(p.done())
