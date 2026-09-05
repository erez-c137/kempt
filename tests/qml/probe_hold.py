#!/usr/bin/env python3
"""The hold round trip: the seconds between pressing a pin and the row having moved (WP-U2 T1).

Everything this file measures happens AFTER the click, which is exactly the half nothing tested.
The hostile panel measured four separate failures in that window
(internal/research/2026-09-05-ux-hostile-review/): `enabled: !row.busy` strips keyboard focus 30 ms
after Space onto an anonymous Loader; the row goes on saying "Hold" and accepts a second press
until the follow-up check lands, and a duplicate `hold` really did reach the CLI; when the check
lands the list snaps to the top (contentY 884 to 0 on the fixture, 1685 to 0 on an 80-row list) and
the row reappears under "Held", below the fold; and nothing at all is announced.

So the stub here is not the usual one. Its `hold` REALLY MOVES THE ROW: the verb rewrites what the
next `check` serves, which is what makes "where did the keyboard go when the model was replaced" a
question this file can ask at all. `holdsleep` holds the pending window open on purpose, so a
second press can be delivered inside it, and `holdrc` turns the same press into a failure.

Like probe_a11y.py and probe_focus.py this one builds a real offscreen window, because
`activeFocus` is a property of a scene: without a window an item can be told to take focus and will
set its own `focus` flag while `activeFocus` stays false and a Space key has nowhere to be
delivered. `dbus-send` and `xdg-open` are shadowed on PATH so nothing here can reach a real session.
"""
import json
import os
import sys

import harness

if not harness.have_pyside():
    print("ok: SKIPPED - PySide6 absent")
    sys.exit(0)

p = harness.Probe("probe-hold")
os.makedirs(os.path.join(p.state, "logs"))
os.makedirs(p.config)
STATE_JSON = os.path.join(p.state, "state.json")
RUNJSON = os.path.join(p.sandbox, "runjson")
open(RUNJSON, "w").write(
    json.dumps(json.load(open(os.path.join(harness.FIXTURES, "run-last.json")))))

os.environ["PATH"] = p.bindir + os.pathsep + os.environ["PATH"]
for _name in ("dbus-send", "xdg-open"):
    _path = os.path.join(p.bindir, _name)
    open(_path, "w").write("#!/usr/bin/env bash\nexit 0\n")
    os.chmod(_path, 0o755)


def _code(name):
    """One .qml file with its comments removed, on one line."""
    lines = [ln.split("//")[0] for ln in open(os.path.join(harness.UI, name))]
    return " ".join(" ".join(lines).split())


# --- the shape, before anything is built ---------------------------------------------------------
# These need no widget, so they run first and report first. Each one is a rule the live half below
# would go on passing without: a probe can only press the pins it happens to reach.
_popup_src = _code("FullRepresentation.qml")
_delegate_src = _code("UpdateItemDelegate.qml")
_main_src = _code("main.qml")

# The global disable is the thing that has to stay gone. Qt strips focus from a control the instant
# it is disabled, so a pin that disables itself on its own press throws the keyboard away every
# time it is used - measured at 30 ms after Space, onto the delegate's Loader.
p.check("no pin disables itself on its own press", "enabled: !row.busy" in _delegate_src, False)
p.check("...it stands down only while some OTHER row's hold is in flight",
        "enabled: !row.otherPending" in _delegate_src, True)
p.check("...and the guard against a second press is in the handler, where it costs no focus",
        "onClicked: if (!row.pending)" in _delegate_src, True)

# One announce, in one place: one thing for a probe to spy on, and one place the politeness is
# decided rather than five call sites that can drift apart.
p.check("every announcement goes through the popup's own function",
        _popup_src.count("Accessible.announce("), 1)
p.check("...which is also what this file can hear", "signal announced(string sentence)"
        in _popup_src, True)
p.check("a hold that worked is announced politely, because the person caused it",
        "popup.announce(sentence, false)" in _popup_src, True)
p.check("...and one that failed assertively, because they are about to try again",
        "popup.announce(message, true)" in _popup_src, True)

# The window that has to close. `pendingHold` outlives the hold command itself: the row does not
# move until the check the hold triggers has landed, and the duplicate was measured in between.
p.check("the pending hold is cleared by the check the hold triggers, not by the hold returning",
        "root.afterCheck = function () { root.pendingHold = null;" in _main_src, True)
p.check("...and nothing keeps a global in-flight flag any more",
        "holdInFlight" in _main_src or "holdInFlight" in _popup_src, False)


def fixture(name):
    return os.path.join(harness.FIXTURES, name)


BASE = json.load(open(fixture("state-live.json")))
DNF = [i for i in BASE["backends"]["dnf"]["items"] if not i.get("held")]
TARGET = DNF[0]["name"]                    # the package every assertion below presses
OTHER = DNF[1]["name"]


def stretched(count):
    """`count` pending dnf rows, cloned off the capture - an ordinary weekly Fedora update.

    Derived from the real document rather than added to tests/fixtures/, the way every other probe
    here derives its scenarios: it is the capture with its list stretched, so it cannot drift away
    from the shape a real check produces.
    """
    seed = [i for i in BASE["backends"]["dnf"]["items"] if not i.get("held")]
    items = []
    while len(items) < count:
        for it in seed:
            if len(items) >= count:
                break
            clone = dict(it)
            clone["name"] = "%s-%03d" % (it["name"], len(items))
            items.append(clone)
    return items


def variant(name, held_names, items=None):
    """The shipped capture with `items` (default: its own) and `held_names` marked held."""
    doc = json.loads(json.dumps(BASE))
    rows = [dict(i) for i in (items if items is not None else doc["backends"]["dnf"]["items"])]
    for it in rows:
        it["held"] = it["name"] in held_names
    doc["backends"] = {"dnf": dict(doc["backends"]["dnf"], items=rows,
                                   actionable=len([i for i in rows if not i["held"]]),
                                   held=len([i for i in rows if i["held"]]))}
    doc["actionable"] = len([i for i in rows if not i["held"]])
    doc["held_total"] = len([i for i in rows if i["held"]])
    path = os.path.join(p.sandbox, name)
    open(path, "w").write(json.dumps(doc))
    return path


LONG = stretched(80)
# Deep in the list on purpose: the scroll assertions are about a viewport that is a long way from
# the top, and a row at the top of an 80-row list would answer them by accident.
LONG_TARGET = LONG[40]["name"]

PENDING = variant("state-pending.json", [])
HELD = variant("state-held.json", [TARGET])
LONG_PENDING = variant("state-long-pending.json", [], items=LONG)
LONG_HELD = variant("state-long-held.json", [LONG_TARGET], items=LONG)

# What `kempt check` will serve next. The hold verb rewrites it, which is the whole point: the row
# really moves, the model really is replaced, and every assertion below is about what survives that.
CURRENT = os.path.join(p.sandbox, "current")
PENDING_SRC = os.path.join(p.sandbox, "pending_src")
HELD_SRC = os.path.join(p.sandbox, "held_src")
HOLDSLEEP = os.path.join(p.sandbox, "holdsleep")
HOLDRC = os.path.join(p.sandbox, "holdrc")
open(CURRENT, "w").write(open(PENDING).read())
open(PENDING_SRC, "w").write(PENDING)
open(HELD_SRC, "w").write(HELD)
open(HOLDSLEEP, "w").write("0")
open(HOLDRC, "w").write("0")

p.stub("""
case "$1" in
  config) [[ "$3" == refresh_interval_min ]] && echo 15; [[ "$3" == surface ]] && echo terminal
          [[ "$3" == auto_accept ]] && echo true
          [[ "$3" == restart_reminder ]] && echo true; exit 0 ;;
  hold)   sleep "$(cat %(SLEEP)s)"
          rc="$(cat %(RC)s)"
          if [[ "$rc" != 0 ]]; then echo "kempt: could not write the holds file" >&2; exit "$rc"; fi
          cat "$(cat %(HELDSRC)s)" > %(CUR)s; exit 0 ;;
  unhold) sleep "$(cat %(SLEEP)s)"
          cat "$(cat %(PENDSRC)s)" > %(CUR)s; exit 0 ;;
  check)  cp %(CUR)s %(ST)s; cat %(ST)s; exit 0 ;;
  summary) if [[ "$2" == "--json" ]]; then cat %(RUNJSON)s; fi; exit 0 ;;
esac
""" % {"CUR": CURRENT, "ST": STATE_JSON, "RUNJSON": RUNJSON, "SLEEP": HOLDSLEEP,
       "RC": HOLDRC, "HELDSRC": HELD_SRC, "PENDSRC": PENDING_SRC})

root, ev = p.create("main.qml")
p.wait_for(ev, "root.kemptState !== null", True)


def settle():
    # `!= null`, loosely, on purpose: it reads an ABSENT pendingHold as "nothing pending", so this
    # file fails with assertions against a build that does not have the property yet instead of
    # waiting thirty seconds per settle for something that will never arrive.
    p.wait_for(ev, "root.checking || root.pendingHold != null", False, timeout_ms=30000)
    p.wait_idle(ev, "executor", "tailExecutor", "promptExecutor", timeout_ms=30000)
    p.pump(80)


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

win = QQuickWindow()
win.resize(460, 560)
live.setParentItem(win.contentItem())
live.setWidth(460)
live.setHeight(560)
win.show()
p.pump(250)

# Everything the popup said out loud, in order. The popup routes every Accessible.announce through
# one function that also emits this signal, which is the only way a probe can hear an announcement
# at all: QAccessible hands it to an accessibility bridge, and there is no bridge in here.
spy, sev = p.create_inline("""
import QtQuick
QtObject {
    id: spy
    property var said: []
    function hear(sentence) { var a = spy.said.slice(); a.push(sentence); spy.said = a; }
    function clear() { spy.said = []; }
}
""", "announce-spy.qml")
p.engine.rootContext().setContextProperty("announceSpy", spy)
lev("popup.announced.connect(announceSpy.hear)")


def said():
    return json.loads(str(sev("JSON.stringify(said)")))


def press(key, mod=Qt.NoModifier):
    QCoreApplication.sendEvent(win, QKeyEvent(QEvent.KeyPress, key, mod))
    QCoreApplication.sendEvent(win, QKeyEvent(QEvent.KeyRelease, key, mod))
    p.pump(25)


FOCUSED = """(function () {
  var it = popup.Window.activeFocusItem;
  if (!it) return "nothing";
  if (it === updateButton) return "updateButton";
  if (it === refreshButton) return "refreshButton";
  if (it === configureButton) return "configureButton";
  var t = (it.text === undefined || it.text === null) ? "" : String(it.text);
  return t === "" ? "unnamed:" + String(it) : t;
})()"""


def focused():
    return lev(FOCUSED)


def state(path):
    """Serve `path` from the next check and let the widget go and read it."""
    open(CURRENT, "w").write(open(path).read())
    ev("root.doCheck()")
    settle()
    p.pump(150)


# The pin of a given row, found by walking the delegate rather than through an id the widget would
# only have for tests: an AbstractButton is the one descendant of a row that can be clicked.
PIN_OF = """(function (idx) {
  var loader = rowsView.itemAtIndex(idx);
  if (loader === null || loader.item === null) return null;
  var out = null;
  (function walk(o) {
     if (out !== null) return;
     if (o.animateClick !== undefined) { out = o; return; }
     for (var i = 0; i < o.children.length; i++) walk(o.children[i]);
  })(loader.item);
  return out;
})"""


def pin(idx, expr):
    return lev("(function (b) { return b === null ? 'NO PIN AT THAT ROW' : (%s); })((%s)(%d))"
               % (expr, PIN_OF, idx))


def rows_now():
    return json.loads(str(lev("JSON.stringify(popup.vm.rows)")))


def row_index(name, held):
    for i, r in enumerate(rows_now()):
        if r.get("kind") == "item" and r.get("name") == name and bool(r.get("held")) == held:
            return i
    return -1


def pin_label(name, held):
    """What the padlock on this row says - which is also its accessible name.

    Derived from the live view model rather than written out, because the pending spelling names
    the version the package is being held AT and that comes from the fixture.
    """
    for r in rows_now():
        if r.get("kind") == "item" and r.get("name") == name and bool(r.get("held")) == held:
            if r["from"] == "?":
                return ("Stop skipping %s" if held else "Skip installing %s") % name
            return ("Stop holding %s" % name) if held else ("Hold %s at %s" % (name, r["from"]))
    return "NO SUCH ROW"


# ==================================================================================================
# The pending window: one hold at a time, and the pressed row is the one that stays live.
# ==================================================================================================
state(PENDING)
idx = row_index(TARGET, False)
p.check("premise: the package this file presses is pending", idx >= 0, True)
lev("rowsView.positionViewAtIndex(%d, ListView.Contain)" % idx)
p.pump(80)

open(HOLDSLEEP, "w").write("2")          # hold the pending window open, on purpose
p.clear_calls()
sev("clear()")
pin(idx, "b.forceActiveFocus(Qt.TabFocusReason)")
p.pump(60)
p.check("the keyboard is on the pin of the row about to be pressed",
        focused(), pin_label(TARGET, False))
press(Qt.Key_Space)
p.pump(200)

p.check("a press names the ROW whose hold is in flight rather than setting a global busy flag",
        [ev("root.pendingHold != null"), ev("root.pendingHold.name"),
         ev("root.pendingHold.backend")],
        [True, TARGET, "dnf"])
p.check("...and the pressed pin keeps the keyboard, because it was never disabled",
        [pin(idx, "b.enabled"), pin(idx, "b.activeFocus")], [True, True])
p.check("...visibly so: the focus ring is drawn from visualFocus, and nothing took it away",
        pin(idx, "b.visualFocus"), True)
p.check("...with a spinner where its icon was, so the row itself says it is working",
        pin(idx, "(function () { for (var i = 0; i < b.children.length; i++)"
                 " if (b.children[i].running === true) return true; return false; })()"), True)

other = row_index(OTHER, False)
p.check("...while every OTHER pin stands down for the duration", pin(other, "b.enabled"), False)

# The duplicate the panel measured. The window used to be seconds long - the hold call, then the
# whole re-check - and the row went on saying "Hold" throughout, so a second Space sent a second
# `hold dnf:<name>` to the CLI.
press(Qt.Key_Space)
press(Qt.Key_Space)
p.pump(250)
p.check("a second press inside that window reaches the CLI as nothing at all",
        p.call_count("hold"), 1)

open(HOLDSLEEP, "w").write("0")
settle()
p.pump(250)

# ==================================================================================================
# After the model rebuild: the keyboard follows the row, and the outcome is spoken.
# ==================================================================================================
p.check("the hold really moved the row into the Held group", row_index(TARGET, True) >= 0, True)
p.check("...and the pending state was cleared by the check it triggered, not by the hold returning",
        ev("root.pendingHold"), None)
p.check("the keyboard followed the package it was standing on, into its new group",
        focused(), "Stop holding %s" % TARGET)
p.check("...and it is VISIBLE focus, not a flag on an item nobody can see",
        lev("popup.Window.activeFocusItem.visualFocus"), True)
p.check("the outcome is spoken, which it never was before", said(), ["Holding %s" % TARGET])

# ...and back again, which is the sentence the other half of the toggle owes.
sev("clear()")
held_idx = row_index(TARGET, True)
pin(held_idx, "b.forceActiveFocus(Qt.TabFocusReason)")
p.pump(60)
press(Qt.Key_Space)
settle()
p.pump(250)
p.check("unholding says the opposite, in the same shape", said(),
        ["No longer holding %s" % TARGET])
p.check("...and the row is pending again", row_index(TARGET, False) >= 0, True)

# ==================================================================================================
# A mouse press keeps the viewport where the pointer left it.
# ==================================================================================================
open(PENDING_SRC, "w").write(LONG_PENDING)
open(HELD_SRC, "w").write(LONG_HELD)
state(LONG_PENDING)

p.check("premise: eighty packages pending, which is an ordinary Tuesday",
        ev("root.vm.actionable"), 80)
long_idx = row_index(LONG_TARGET, False)
lev("rowsView.positionViewAtIndex(%d, ListView.Center)" % long_idx)
p.pump(120)
scrolled = float(lev("rowsView.contentY"))
p.check("premise: the list is scrolled well down it, with that row on screen",
        scrolled > 100, True)
# A MOUSE press: the keyboard is somewhere else, so the pin has no visualFocus and the popup reads
# the press as one that must not move the viewport under the pointer.
lev("updateButton.forceActiveFocus(Qt.TabFocusReason)")
p.pump(60)
sev("clear()")
pin(long_idx, "b.clicked()")
settle()
p.pump(300)
p.check("a mouse press leaves the list where the pointer left it rather than snapping to the top",
        abs(float(lev("rowsView.contentY")) - scrolled) < 4, True)
p.check("...and still says what happened", said(), ["Holding %s" % LONG_TARGET])

# ...and a keyboard press on the same long list, which has the opposite obligation: the row is now
# the last one in the popup, and the person standing on it has to be taken with it.
sev("clear()")
long_held = row_index(LONG_TARGET, True)
lev("rowsView.positionViewAtIndex(%d, ListView.Contain)" % long_held)
p.pump(80)
pin(long_held, "b.forceActiveFocus(Qt.TabFocusReason)")
p.pump(60)
press(Qt.Key_Space)
settle()
p.pump(300)
_back_pending = pin_label(LONG_TARGET, False)
p.check("a keyboard press takes the keyboard to the row wherever it has gone",
        focused(), _back_pending)
p.check("...scrolled into view rather than left below the fold",
        lev("(function (b) { var q = b.mapToItem(rowsView, 0, 0);"
            " return q.y >= -2 && q.y <= rowsView.height; })(popup.Window.activeFocusItem)"),
        True)

# ==================================================================================================
# A hold that failed is reported in the row, and said out loud.
# ==================================================================================================
# It used to be the fifth InlineMessage at the top of the content, up to 300 px from the pin, and
# it did not say hold or unhold (HIG P6).
open(PENDING_SRC, "w").write(PENDING)
open(HELD_SRC, "w").write(HELD)
state(PENDING)

open(HOLDRC, "w").write("1")
sev("clear()")
ev('root.actionMessage = ""')
fail_idx = row_index(TARGET, False)
pin(fail_idx, "b.forceActiveFocus(Qt.TabFocusReason)")
p.pump(60)
press(Qt.Key_Space)
settle()
p.pump(250)
p.check("a hold that failed names the row it failed on",
        [ev("root.holdError != null"), ev("root.holdError.name")], [True, TARGET])
p.check("...in the CLI's own words", ev("root.holdError.text"),
        "kempt: could not write the holds file")
p.check("...and not as a message at the top of the stack",
        ev("root.actionMessage"), "")
p.check("...said out loud too, because a report three hundred pixels away is not a report",
        said(), ["kempt: could not write the holds file"])
p.check("...with the row still pressable, so the person can try again",
        [ev("root.pendingHold"), pin(fail_idx, "b.enabled")], [None, True])
p.check("...and the row itself carrying the sentence, under the version",
        lev("(function (o) { var hit = false;"
            " (function walk(x) { if (hit) return;"
            "    if (x.text !== undefined"
            "        && String(x.text) === 'kempt: could not write the holds file'"
            "        && x.visible) { hit = true; return; }"
            "    for (var i = 0; i < x.children.length; i++) walk(x.children[i]); })(o);"
            " return hit; })(rowsView.itemAtIndex(%d).item)" % fail_idx), True)

# ...and the next check clears it, because the row's error is about one press, not about the box.
open(HOLDRC, "w").write("0")
ev("root.doCheck()")
settle()
p.check("the next check clears the row's error", ev("root.holdError"), None)

sys.exit(p.done())
