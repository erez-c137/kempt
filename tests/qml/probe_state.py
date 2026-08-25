#!/usr/bin/env python3
"""main.qml's state machine, and the panel icon it drives (Task W2).

doCheck's three-way contract is the part that matters most here, because two of its three branches
are about what the widget must NOT do. `kempt check` printing nothing with exit 0 means another
check held the lock - "no data, keep the last known state" - and a widget that read that as zero
would sit there telling the user they are up to date while updates wait. Same for unparseable
output. Only the node tests can pin the derivation; only this can pin that main.qml routes into it.

Also carries the compact representation's geometry: the badge must never overflow the panel cell,
and the icon must be requested at a size the icon theme actually hints.
"""
import os
import sys

import harness

if not harness.have_pyside():
    print("ok: SKIPPED - PySide6 absent")
    sys.exit(0)

p = harness.Probe("probe-state")
os.makedirs(p.state)
MODE = os.path.join(p.sandbox, "mode")
IVAL = os.path.join(p.sandbox, "interval")
open(MODE, "w").write("live")
open(IVAL, "w").write("15")
STATE_JSON = os.path.join(p.state, "state.json")

p.stub("""
mode="$(cat %(MODE)s)"
if [[ "$1 $2" == "config get" ]]; then
  [[ "$3" == refresh_interval_min ]] && cat %(IVAL)s
  exit 0
fi
if [[ "$1" == check ]]; then
  # The real CLI PERSISTS state.json and then prints it. The stub must do the same, or the
  # widget's watcher never sees its own footprint and a whole class of race goes untested.
  case "$mode" in
    live)        cp %(FIX)s/state-live.json %(ST)s; cat %(ST)s ;;
    slow)        sleep 1; cp %(FIX)s/state-live.json %(ST)s; touch %(ST)s; cat %(ST)s ;;
    empty)       exit 0 ;;                                   # lock timeout: no data, exit 0
    answerfirst) cp %(FIX)s/state-flatpak-disabled.json %(ST)s; cat %(ST)s; exit 5 ;;
    garbage)     echo 'not json at all'; exit 1 ;;
  esac
  exit 0
fi
""" % {"MODE": MODE, "IVAL": IVAL, "FIX": harness.FIXTURES, "ST": STATE_JSON})

root, ev = p.create("main.qml")
p.wait_for(ev, "root.kemptState !== null", True)
p.wait_for(ev, "root.checking", False)

# --- 1. what a fresh widget knows -------------------------------------------------------------
p.check("a fresh widget runs a check on load", ev("root.kemptState !== null"), True)
p.check("the badge shows the CLI's actionable count", ev("root.vm.badgeText"), "10")
p.check("...and the icon state that goes with it", ev("root.vm.iconState"), "updates")
p.check("the tooltip comes out of the same view model", ev("root.vm.tooltipMain"), "10 updates available")
p.check("the check interval is read from `kempt config`", ev("root.refreshIntervalMin"), 15)
p.check("...and the timer actually uses it", ev("checkTimer.interval"), 15 * 60000)
p.check("the watcher has a baseline after the first check", ev("root.watchStamp !== ''"), True)
p.check("nothing is left in flight", ev("root.checking"), False)

# --- 2. empty stdout, exit 0: no data, keep what we had ---------------------------------------
open(MODE, "w").write("empty")
before = p.call_count("check")
ev("root.doCheck()")
p.wait_for(ev, "root.checking", False)
p.check("an empty answer still ran the check", p.call_count("check") > before, True)
p.check("an empty answer keeps the last known count", ev("root.vm.badgeText"), "10")
p.check("...and does not fall back to up-to-date", ev("root.vm.iconState"), "updates")

# --- 3. answer-first: usable stdout is used WHATEVER the exit code was -------------------------
open(MODE, "w").write("answerfirst")
ev("root.doCheck()")
p.wait_for(ev, "root.checking", False)
p.check("stdout is used even when the CLI exits non-zero", ev("root.vm.badgeText"), "7")
p.check("...and the disabled backend drops out of the popup", ev("root.vm.sections.length"), 1)

# --- 4. garbage: leave the last good state alone ----------------------------------------------
open(MODE, "w").write("garbage")
ev("root.doCheck()")
p.wait_for(ev, "root.checking", False)
p.check("unparseable output leaves the last known state alone", ev("root.vm.badgeText"), "7")
open(MODE, "w").write("live")

# --- 5. the watcher must not react to the widget's own footprint ------------------------------
ev("root.doCheck()")
p.wait_for(ev, "root.checking", False)
stamp_after_check = ev("root.watchStamp")
before = p.call_count("check")
ev("root.pollWatch(true)")
p.pump(600)
p.check("a poll straight after a check triggers no new check", p.call_count("check"), before)
p.check("...and the baseline is unchanged", ev("root.watchStamp"), stamp_after_check)

# --- 6. overlapping checks coalesce, never drop -----------------------------------------------
open(MODE, "w").write("slow")
before = p.call_count("check")
ev("root.doCheck()")
p.pump(100)
ev("root.doCheck()")
p.check("a second check while one runs is deferred, not started", p.call_count("check") - before, 1)
p.check("...and it is remembered", ev("root.recheckPending"), True)
ev("root.doCheck()")
ev("root.doCheck()")
p.wait_for(ev, "root.checking || root.recheckPending", False, timeout_ms=15000)
p.check("three overlapping requests collapse into exactly one re-check",
        p.call_count("check") - before, 2)
p.check("nothing is left pending afterwards", ev("root.recheckPending"), False)
p.check("nothing is left in flight afterwards", ev("root.checking"), False)
open(MODE, "w").write("live")

# --- 7. an absurd interval must not overflow Timer.interval into a negative --------------------
# refresh_interval_min is a line in a text file a human edits. n * 60000 overflows a 32-bit
# interval past ~35791 minutes and comes back NEGATIVE, which makes a repeating timer spin the
# panel process instead of sleeping.
open(IVAL, "w").write("999999")
ev("root.readInterval()")
p.wait_for(ev, "root.refreshIntervalMin", 999999)
p.check("an absurd interval is read as written", ev("root.refreshIntervalMin"), 999999)
p.check("...but the timer clamps it to a day", ev("checkTimer.interval"), 1440 * 60000)
p.check("...and stays positive", ev("checkTimer.interval") > 0, True)
open(IVAL, "w").write("15")
ev("root.readInterval()")
p.wait_for(ev, "root.refreshIntervalMin", 15)

# --- 8. ...but a real change from another source does trigger one ------------------------------
harness.touch(STATE_JSON, "2030-01-01")
before = p.call_count("check")
ev("root.pollWatch(true)")
p.wait_for(ev, "root.checking", True, timeout_ms=4000)
p.wait_for(ev, "root.checking", False)
p.check("a package database change from ANY source triggers a check",
        p.call_count("check") > before, True)

# ==================================================================================================
# The compact representation's geometry.
# ==================================================================================================
CELL = """
import QtQuick
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami
PlasmoidItem {
    id: shell
    width: %d; height: %d
    property var vm: ({ iconState: "updates", badgeText: "%s", badgeVisible: true })
    CompactRepresentation { id: cr; anchors.fill: parent; plasmoidItem: shell; vm: shell.vm }
    function badge() {
        for (var i = 0; i < cr.children.length; i++)
            if (cr.children[i].radius !== undefined) return cr.children[i];
        return null;
    }
    // `mainIcon` is an id private to CompactRepresentation.qml, so it is found by what it is:
    // the Kirigami.Icon showing one of the Breeze update-* glyphs. The warning emblem is the
    // other Kirigami.Icon in there and carries `emblem-warning`, so the prefix separates them.
    function mainIcon() {
        for (var i = 0; i < cr.children.length; i++) {
            var c = cr.children[i];
            if (c.source !== undefined && String(c.source).indexOf("update-") === 0) return c;
        }
        return null;
    }
    readonly property int steps0: Kirigami.Units.iconSizes.small
    readonly property int steps1: Kirigami.Units.iconSizes.smallMedium
    readonly property int steps2: Kirigami.Units.iconSizes.medium
}
"""


def cell(size, text="7"):
    return p.create_inline(CELL % (size, size, text), "cell-%d.qml" % size)


# The badge must fit its label AND stay inside the panel cell at every size and every count the
# cap allows. "999+" at the two-digit font size would be as wide as the whole icon.
overflow = 0
for size in (22, 32, 44, 64):
    for txt in ("7", "42", "347", "999+"):
        obj, cev = cell(size, txt)
        p.pump(60)
        bw, iw = cev("badge().width"), cev("badge().children[0].implicitWidth")
        if bw is None or iw is None or iw > bw + 0.5 or bw > size + 0.5:
            print("  overflow: cell=%s text=%s badge_w=%s label_w=%s" % (size, txt, bw, iw))
            overflow += 1
p.check("the badge fits its count and stays inside the panel cell at every size", overflow, 0)

# The icon is requested at a size the theme hints, so a hinted symbolic renders 1:1 instead of
# being scaled by a fraction and going soft. Snapping is Logic.snapIconSize; this proves the
# binding actually feeds Kirigami.Icon the snapped number at real panel thicknesses.
obj, cev = cell(32)
small, smallmed, medium = cev("shell.steps0"), cev("shell.steps1"), cev("shell.steps2")
p.check("the Kirigami steps this box reports are the usual ones",
        [small, smallmed, medium], [16, 22, 32])
expected = {22: smallmed, 24: smallmed, 28: smallmed, 32: medium,
            36: medium, 44: medium, 64: 64}
for size, want in sorted(expected.items()):
    obj, cev = cell(size)
    p.pump(40)
    got = cev("cr.iconSize")
    p.check("a %d px panel asks the icon theme for %d px" % (size, want), got, want)
    p.check("...and Kirigami.Icon is actually given that size", cev("mainIcon().width"), want)
    p.check("...without overflowing the cell", got <= size, True)

# Below the smallest hinted step there is nothing to snap to, so it must still be a whole number
# of pixels rather than a fraction.
obj, cev = cell(12)
p.pump(40)
p.check("a cell smaller than the smallest hinted icon still gets a whole number of pixels",
        cev("cr.iconSize"), 12)

sys.exit(p.done())
