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
SIZE = os.path.join(p.sandbox, "iconsize")
# The first check answers with NOTHING - another check holding the lock, which is the ordinary
# state of a fresh login and the case the bounded retry below exists for.
open(MODE, "w").write("empty")
open(IVAL, "w").write("15")
open(SIZE, "w").write("auto")
STATE_JSON = os.path.join(p.state, "state.json")

p.stub("""
mode="$(cat %(MODE)s)"
if [[ "$1 $2" == "config get" ]]; then
  [[ "$3" == refresh_interval_min ]] && cat %(IVAL)s
  [[ "$3" == widget_icon_size ]] && cat %(SIZE)s
  exit 0
fi
if [[ "$1" == check ]]; then
  # The real CLI PERSISTS state.json and then prints it. The stub must do the same, or the
  # widget's watcher never sees its own footprint and a whole class of race goes untested.
  case "$mode" in
    live)        cp %(FIX)s/state-live.json %(ST)s; cat %(ST)s ;;
    slow)        sleep 1; cp %(FIX)s/state-live.json %(ST)s; touch %(ST)s; cat %(ST)s ;;
    slownever)   sleep 1; cp %(FIX)s/state-never.json %(ST)s; touch %(ST)s; cat %(ST)s ;;
    never)       cp %(FIX)s/state-never.json %(ST)s; cat %(ST)s ;;
    empty)       exit 0 ;;                                   # lock timeout: no data, exit 0
    answerfirst) cp %(FIX)s/state-flatpak-disabled.json %(ST)s; cat %(ST)s; exit 5 ;;
    garbage)     echo 'not json at all'; exit 1 ;;
  esac
  exit 0
fi
""" % {"MODE": MODE, "IVAL": IVAL, "SIZE": SIZE, "FIX": harness.FIXTURES,
       "ST": STATE_JSON})

root, ev = p.create("main.qml")
p.wait_for(ev, "root.checking", False)

# --- 0. the first check answered with nothing: retry, do not sit there dim ---------------------
# `kempt check` prints an empty line and exits 0 when another check already holds the lock. The
# widget is right to keep its last known state - but at startup there is no last known state, so
# the panel showed the dim "unknown" icon and had nothing to change its mind until the hourly
# checkTimer came round: a login where the CLI's own refresh was still running left the widget
# blank for the best part of an hour.
p.check("a first check that answered with nothing leaves the widget without state",
        ev("root.kemptState === null"), True)
p.check("...and the panel says unknown rather than claiming zero updates", ev("root.vm.iconState"), "unknown")
p.check("...with a retry armed instead of an hour of silence", ev("firstCheckRetry.running"), True)
p.check("...at the ten seconds this ships with", ev("firstCheckRetry.interval"), 10000)
p.check("...counted, so it can be bounded", ev("root.firstCheckRetries"), 1)

# The same timer, hurried along: what is proved here is that firing it recovers the widget, and the
# ten seconds are already pinned by the assertion above.
ev("firstCheckRetry.interval = 250")
open(MODE, "w").write("live")
before = p.call_count("check")
p.wait_for(ev, "root.kemptState !== null", True, timeout_ms=8000)
p.check("the retry re-asks and the widget reaches a real state within seconds",
        ev("root.kemptState !== null"), True)
p.check("...having run exactly one more check", p.call_count("check") - before, 1)
p.wait_for(ev, "root.checking", False)
p.check("...and the retry disarms once there is something to show", ev("firstCheckRetry.running"), False)
p.check("...with the counter cleared for the next time", ev("root.firstCheckRetries"), 0)

# Bounded: a box whose lock is genuinely wedged must not become a widget forking a check every ten
# seconds forever. After the last attempt it defers to checkTimer like any other check.
open(MODE, "w").write("empty")
ev("root.kemptState = null; root.cliError = ''; "
   "root.firstCheckRetries = root.maxFirstCheckRetries")
ev("root.doCheck()")
p.wait_for(ev, "root.checking", False)
p.check("after the last attempt the widget stops re-asking", ev("firstCheckRetry.running"), False)
p.check("...and does not push the count past its own bound", ev("root.firstCheckRetries"), 3)

# ...and a CLI we could not run at all is an ANSWER, not a lost lock: the popup carries the error
# already, and re-asking every ten seconds would only repeat it.
ev("root.kemptState = null; root.cliError = 'kempt: command not found'; root.firstCheckRetries = 0")
ev("root.doCheck()")
p.wait_for(ev, "root.checking", False)
p.check("a check that could not run the CLI is not retried on a timer",
        ev("firstCheckRetry.running"), False)
p.check("...and nothing was counted against the retry budget", ev("root.firstCheckRetries"), 0)

open(MODE, "w").write("live")
ev("root.cliError = ''")
ev("root.doCheck()")
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
# The tray claim RAN. It is one assignment inside a try/catch, and a swallowed exception looks
# exactly like a line that was never called - so without this witness, deleting claimTrayPresence()
# would put the widget back to being installed in the tray, enabled and invisible, with the whole
# suite still green.
p.check("the widget claims an active status so the system tray shows it",
        ev("root.trayPresenceClaimed"), True)

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

# ...and the caller that reaches this most often is the popup opening, which docs/usage.md used to
# describe as waiting for the running check rather than asking for another. Adopted from the
# review's probe_review.py finding 4: it does ask, and asking is right - the running check read
# the system BEFORE whatever prompted this open, so treating its answer as good enough would leave
# the counts stale until the hourly timer. What must not happen is a QUEUE of them.
open(MODE, "w").write("slow")
before = p.call_count("check")
ev("root.doCheck()")
p.pump(100)
ev("root.popupOpened()")
ev("root.popupClosed()")
ev("root.popupOpened()")
ev("root.popupClosed()")
p.check("opening the popup during a check does not start a second one on top of it",
        p.call_count("check") - before, 1)
p.check("...it is remembered instead", ev("root.recheckPending"), True)
p.wait_for(ev, "root.checking || root.recheckPending", False, timeout_ms=15000)
p.check("...and two opens during one check cost exactly one extra check, not two",
        p.call_count("check") - before, 2)

# The box with no successful check at all: there is no stamp to be old, so every open asks. That
# is the box whose counts are most worth getting - a fresh install behind a broken repo has
# nothing to show and no other way to learn it has started working. Adopted from the review's
# probe_review.py finding 5, which read this as a possible bug; it is the intended answer, and it
# is documented now rather than left to be re-found.
open(MODE, "w").write("never")
ev("root.doCheck()")
p.wait_for(ev, "root.checking", False, timeout_ms=15000)
p.check("the state says no check has ever succeeded", ev("root.vm.lastSuccessText"), "never")
before = p.call_count("check")
for _ in range(3):
    ev("root.popupOpened()")
    p.wait_for(ev, "root.checking", False, timeout_ms=15000)
    ev("root.popupClosed()")
p.check("three opens on a never-succeeded box ask three times, by design",
        p.call_count("check") - before, 3)
open(MODE, "w").write("live")
ev("root.doCheck()")
p.wait_for(ev, "root.checking", False, timeout_ms=15000)

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
# Outside the quiet window (section 8b), so what is proved here is the watcher's reaction and not
# the debounce sitting on top of it. Winding the stamp back rather than sleeping a minute: the
# window's boundaries are pinned to the millisecond by the node tests, and a probe that waited them
# out would add a minute to the battery for nothing.
ev("root.lastCheckFinished = Date.now() - 61000")
harness.touch(STATE_JSON, "2030-01-01")
before = p.call_count("check")
ev("root.pollWatch(true)")
p.wait_for(ev, "root.checking", True, timeout_ms=4000)
p.wait_for(ev, "root.checking", False)
p.check("a package database change from ANY source triggers a check",
        p.call_count("check") > before, True)

# --- 8b. the wake of a run is not news ---------------------------------------------------------
# The bug this closes, in the order it happened on a real box (2026-08-28): a run finished, its
# post-run check ran at 00:36:53, and the 30-second watcher then found the run's own footprint
# twice more - `widget check ok` again at 00:37:24 and at 00:37:30. Each was cache-only and cost
# about two seconds; what they really cost was two lines in `kempt log` that describe nothing.
# A check has just completed above, so the window is open from here.
ev("root.doCheck()")                                   # stands in for the post-run check
p.wait_for(ev, "root.checking", False, timeout_ms=15000)
before = p.call_count("check")
harness.touch(STATE_JSON, "2030-02-01")                # the run's own state write, arriving late
ev("root.pollWatch(true)")
p.pump(600)
p.check("a watcher tick inside the minute after a check starts nothing",
        p.call_count("check") - before, 0)
harness.touch(STATE_JSON, "2030-02-02")                # ...and the next poll, still inside it
ev("root.pollWatch(true)")
p.pump(600)
p.check("...and neither does the one after it, so a run costs exactly one check",
        p.call_count("check") - before, 0)

# The window suppresses the WATCHER and nothing else. Refresh is the same call the popup's button
# makes, and a person pressing it inside the window has to get a check: they pressed it because
# they do not believe what is on screen.
ev("root.doCheck()")
p.wait_for(ev, "root.checking", False, timeout_ms=15000)
p.check("...while a Refresh press inside the same window still checks",
        p.call_count("check") - before, 1)

# Past the window, the watcher is believed again.
ev("root.lastCheckFinished = Date.now() - 61000")
harness.touch(STATE_JSON, "2030-02-03")
before = p.call_count("check")
ev("root.pollWatch(true)")
p.wait_for(ev, "root.checking", True, timeout_ms=4000)
p.wait_for(ev, "root.checking", False, timeout_ms=15000)
p.check("a watcher tick after the window checks again", p.call_count("check") - before, 1)

# The one exemption, and it is a promise docs/usage.md makes out loud: the settings page writes
# with `kempt config set` and this watcher is its ONLY way into main.qml, so "changes reach the
# panel within 30 seconds" is measured through exactly this line. include_flatpak can change what
# is pending, so re-reading the settings is not enough on its own.
CONFIG_FILE = os.path.join(p.config, "config")
os.makedirs(p.config, exist_ok=True)
open(CONFIG_FILE, "w").write("surface=background\n")
ev("root.watchStamp = ''; root.pollWatch(false)")      # learn the config file's mtime
p.pump(600)
ev("root.doCheck()")                                   # ...and open the window on it
p.wait_for(ev, "root.checking", False, timeout_ms=15000)
before = p.call_count("check")
harness.touch(CONFIG_FILE, "2030-03-01")
ev("root.pollWatch(true)")
p.wait_for(ev, "root.checking", True, timeout_ms=4000)
p.wait_for(ev, "root.checking", False, timeout_ms=15000)
p.check("a settings apply inside the window is still acted on at once",
        p.call_count("check") - before, 1)

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
    property string sizeSetting: "%s"
    CompactRepresentation {
        id: cr; anchors.fill: parent; plasmoidItem: shell; vm: shell.vm
        iconSizeSetting: shell.sizeSetting
    }
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
    function busyWidth() {
        for (var i = 0; i < cr.children.length; i++)
            if (cr.children[i].running !== undefined) return cr.children[i].width;
        return -1;
    }
    readonly property int steps0: Kirigami.Units.iconSizes.small
    readonly property int steps1: Kirigami.Units.iconSizes.smallMedium
    readonly property int steps2: Kirigami.Units.iconSizes.medium
}
"""

_serial = [0]


def cell(size, text="7", setting="auto"):
    _serial[0] += 1
    return p.create_inline(CELL % (size, size, text, setting),
                           "cell-%d-%d.qml" % (size, _serial[0]))


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
# being scaled by a fraction and going soft. WHICH step it lands on is Logic.resolveIconSize, and
# its ladder is pinned to what the system tray draws rather than to "the largest that fits" - the
# founder's screenshot was a 32px Kempt icon standing in a row of 22px tray entries. This proves
# the binding actually feeds Kirigami.Icon the laddered number at real panel thicknesses.
obj, cev = cell(32)
small, smallmed, medium = cev("shell.steps0"), cev("shell.steps1"), cev("shell.steps2")
p.check("the Kirigami steps this box reports are the usual ones",
        [small, smallmed, medium], [16, 22, 32])
expected = {16: small, 21: small, 22: smallmed, 24: smallmed, 32: smallmed,
            36: smallmed, 44: smallmed, 47: smallmed, 48: medium, 64: medium}
for size, want in sorted(expected.items()):
    obj, cev = cell(size)
    p.pump(40)
    got = cev("cr.iconSize")
    p.check("a %d px panel asks the icon theme for %d px" % (size, want), got, want)
    p.check("...and Kirigami.Icon is actually given that size", cev("mainIcon().width"), want)
    p.check("...without overflowing the cell", got <= size, True)

# The badge's legibility floor. The pill is 0.6 of the icon and the label half of the pill once the
# count runs past two characters, so at the 16px step "347" renders at FIVE pixels - a smudge that
# says something is pending without saying what. Below 22 the count lives in the tooltip, which is
# never capped, and the icon still changes to say there is something to do.
for txt in ("7", "347"):
    obj, cev = cell(16, txt)
    p.pump(60)
    p.check("a 16px cell draws the icon at 16", cev("cr.iconSize"), 16)
    p.check("...and drops the %s badge rather than drawing an unreadable one" % txt,
            cev("badge().visible"), False)
obj, cev = cell(44, "347", "small")
p.pump(60)
p.check("choosing Small on an ordinary panel puts the icon on the 16px step", cev("cr.iconSize"), 16)
p.check("...so the badge goes with it", cev("badge().visible"), False)
obj, cev = cell(22, "347")
p.pump(60)
p.check("the 22px step is where the badge comes back", cev("cr.iconSize"), 22)
p.check("...and it is drawn", cev("badge().visible"), True)
p.check("...at a size a count can be read at", cev("badge().children[0].font.pixelSize") >= 6, True)

# Below the smallest hinted step there is nothing to snap to, so it must still be a whole number
# of pixels rather than a fraction.
obj, cev = cell(12)
p.pump(40)
p.check("a cell smaller than the smallest hinted icon still gets a whole number of pixels",
        cev("cr.iconSize"), 12)

# --- the widget_icon_size setting, bound ------------------------------------------------------
# The three named sizes and the automatic one, on the SAME 44px panel - the ordinary Plasma
# default, and the thickness the founder was actually looking at.
for setting, want in (("auto", smallmed), ("small", small), ("medium", smallmed),
                      ("large", medium)):
    obj, cev = cell(44, "7", setting)
    p.pump(40)
    p.check("widget_icon_size=%s on a 44px panel draws at %d px" % (setting, want),
            cev("cr.iconSize"), want)
    p.check("...and the Kirigami.Icon is given exactly that", cev("mainIcon().width"), want)
# A value the widget does not recognise must draw, not vanish or throw: `kempt config set` stores
# whatever it is handed, so this is the only place a typo is ever caught.
obj, cev = cell(44, "7", "enormous")
p.pump(40)
p.check("an unrecognised setting falls back to automatic rather than breaking the icon",
        cev("cr.iconSize"), smallmed)
# ...and a size the cell cannot hold gives way to the cell. This is what makes the system tray's
# slot win over the setting: the tray hands each entry a square at its own icon size.
obj, cev = cell(22, "7", "large")
p.pump(40)
p.check("a chosen size larger than the cell gives way to the cell", cev("cr.iconSize"), smallmed)
p.check("...and never overflows it", cev("cr.iconSize") <= 22, True)

# The badge is drawn against the ICON now, not the cell. While the icon filled its cell the two
# were the same thing; on a 44px panel the icon is 22, and a cell-anchored badge sat eleven pixels
# away from the glyph it belongs to, at nearly the glyph's own size.
obj, cev = cell(44)
p.pump(60)
p.check("the badge is no taller than the icon it marks",
        cev("badge().height") <= cev("cr.iconSize"), True)
p.check("...and sits at the icon's corner, not the cell's",
        cev("badge().y + badge().height"), cev("mainIcon().y + mainIcon().height"))
p.check("...with a pill tall enough to read a count in", cev("badge().height") >= 12, True)
p.check("the busy spinner is sized off the icon too",
        cev("busyWidth()") <= cev("cr.iconSize"), True)

# ...and main.qml really reads the setting out of the CLI. Everything above proves the compact
# representation obeys the value it is handed; this proves where that value comes from. A widget
# that never re-read it would keep whatever it had at startup until plasmashell restarted.
p.check("a fresh widget starts on the CLI's default", ev("root.iconSizeSetting"), "auto")
open(SIZE, "w").write("large")
ev("root.readIconSize()")
p.wait_for(ev, "root.iconSizeSetting", "large")
p.check("changing widget_icon_size in the CLI reaches the panel icon", ev("root.iconSizeSetting"),
        "large")
# The widget is the ONLY validator this setting has - `kempt config set` stores whatever it is
# handed - so a value it does not know must land on `auto` rather than on an undefined size.
open(SIZE, "w").write("gargantuan")
ev("root.readIconSize()")
p.wait_for(ev, "root.iconSizeSetting", "auto")
p.check("a value the widget does not know falls back to automatic", ev("root.iconSizeSetting"),
        "auto")
# An empty answer is an OLDER CLI that has never heard of the key, and that must leave the
# widget's current setting alone rather than reset it.
open(SIZE, "w").write("medium")
ev("root.readIconSize()")
p.wait_for(ev, "root.iconSizeSetting", "medium")
open(SIZE, "w").write("")
ev("root.readIconSize()")
p.pump(400)
p.check("an older CLI that answers with nothing does not reset the setting",
        ev("root.iconSizeSetting"), "medium")

sys.exit(p.done())
