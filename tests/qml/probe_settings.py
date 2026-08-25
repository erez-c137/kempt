#!/usr/bin/env python3
"""The settings page's apply path (Task W4, and the five findings its review turned up).

Everything on this page is a front-end to `kempt config`; there is no plasmoid-local copy of any
setting. That design is right, and it removed the shell's usual machinery along with the problem:
with no `cfg_` properties, the configuration dialog has nothing to watch, so its Apply button
stayed grey and closing the dialog threw the changes away without asking. The MiniShell below is
AppletConfiguration.qml's own wiring transcribed, so this proves the fix against the contract the
real shell actually uses rather than against a description of it.

The other four are all one shape: writing a setting the page does not actually know.
"""
import os
import sys

import harness

if not harness.have_pyside():
    print("ok: SKIPPED - PySide6 absent")
    sys.exit(0)

p = harness.Probe("probe-settings")
VALUES = os.path.join(p.sandbox, "values")     # the stub's idea of the stored config
FAILGET = os.path.join(p.sandbox, "failget")   # keys the stub refuses to read
FAILSET = os.path.join(p.sandbox, "failset")   # ...and to write
# Keys the stub takes its time over. Every real `kempt config set` is a process the shell forks,
# so a write is never instant - and "the page is saved" is a claim about a write that came BACK.
# Without a slow seam here every write answers inside one event-loop turn, and a page that clears
# its unsaved flag on the dispatching line looks identical to one that clears it on the callback.
SLOWSET = os.path.join(p.sandbox, "slowset")
PWSLOW = os.path.join(p.sandbox, "pwslow")     # ...and the passwordless action, which waits on a human
for d in (VALUES, FAILGET, FAILSET, SLOWSET):
    os.makedirs(d)

DEFAULTS = (("include_flatpak", "true"), ("auto_accept", "true"),
            ("surface", "popup"), ("refresh_interval_min", "60"),
            ("widget_icon_size", "medium"))


def setval(k, v):
    open(os.path.join(VALUES, k), "w").write(v)


def stored(k):
    path = os.path.join(VALUES, k)
    return open(path).read() if os.path.exists(path) else "(absent)"


def toggle_fail(where, key, on=True):
    path = os.path.join(where, key)
    if on:
        open(path, "w").close()
    elif os.path.exists(path):
        os.remove(path)


for k, v in DEFAULTS:
    setval(k, v)
HOSTILE_HOLD = "dnf:evil; touch " + p.sandbox + "/PWNED"
open(os.path.join(p.sandbox, "holds"), "w").write(
    "dnf:vim-common\nflatpak:org.gimp.GIMP\n" + HOSTILE_HOLD + "\n")

p.stub("""
case "$1" in
  config)
    case "$2" in
      get) [[ -e %(FG)s/"$3" ]] && { echo "kempt: cannot read $3" >&2; exit 1; }
           cat %(V)s/"$3" 2>/dev/null; exit 0 ;;
      set) [[ -e %(FS)s/"$3" ]] && { echo "kempt: cannot write $3" >&2; exit 1; }
           [[ -e %(SS)s/"$3" ]] && sleep 2
           printf '%%s' "$4" > %(V)s/"$3"; exit 0 ;;
    esac ;;
  holds)  cat %(SB)s/holds; exit 0 ;;
  unhold) grep -vxF "$2" %(SB)s/holds > %(SB)s/h.tmp; mv %(SB)s/h.tmp %(SB)s/holds; exit 0 ;;
  enable-passwordless)  [[ -e %(PW)s ]] && sleep 3
                        echo "some polkit chatter"; echo "Passwordless updates enabled"; exit 0 ;;
  disable-passwordless) echo "Passwordless updates disabled"; exit 0 ;;
esac
""" % {"FG": FAILGET, "FS": FAILSET, "SS": SLOWSET, "PW": PWSLOW, "V": VALUES, "SB": p.sandbox})

# AppletConfiguration.qml's Apply wiring, transcribed. Nothing invented: the connect is the one at
# its line 197-199, and settingValueChanged() is its line 105 with the two hooks this page does not
# have (cfg_ auto-binding, configurationChanged) left out - because it does not have them, which is
# the entire reason the third one has to work.
MINISHELL = """
import QtQuick
Item {
    id: host
    // Assigned from Python with setProperty - deliberately NOT via a root context property, which
    // re-evaluates every binding in the engine and would reset the page's own
    // `property var loaded: ({})` to empty behind our backs.
    property var page: null
    property bool applyEnabled: false
    property int hookFires: 0

    function attach() {
        var pg = host.page;
        if (!pg) return false;
        var sig = pg.unsavedChangesChanged;
        if (!sig) return false;
        sig.connect(function () { host.hookFires++; host.settingValueChanged(); });
        host.settingValueChanged();
        return true;
    }
    // wasConfigurationChangedSignalSent || isConfigurationChanged() || unsavedChanges.
    // With no KConfig keys declared, the first two are constant false on this page.
    function settingValueChanged() {
        host.applyEnabled = (host.page && host.page.unsavedChanges) ? true : false;
    }
    // ...and its closing(): a dialog only ASKS about unsaved changes when Apply is live.
    function closingWouldPrompt() { return host.applyEnabled; }
}
"""


def build(wait=True):
    obj, ev = p.create("configGeneral.qml")
    if wait:
        p.wait_for(ev, "page.pendingReads === 0 && !page.holdsBusy", True)
        p.wait_idle(ev, "cfgExecutor")
    return obj, ev


def shell_for(page):
    host, hev = p.create_inline(MINISHELL, "minishell.qml")
    host.setProperty("page", page)
    return host, hev


# ==================================================================================================
# Apply BEFORE the reads land must write nothing.
# The measured failure: create the page, press Apply immediately, and all four keys are rewritten
# from the QML defaults - include_flatpak flipped, the surface reset, the interval snapped to 15.
# This runs before a single pump(), so the four `config get` calls are still in flight.
# ==================================================================================================
p.clear_calls()
page0, ev0 = build(wait=False)
p.check("the page has reads outstanding the instant it is created", ev0("page.pendingReads") > 0, True)
p.check("...so it reports itself as still loading", ev0("page.loading"), True)
p.check("...and its controls are disabled meanwhile",
        [ev0("includeFlatpak.enabled"), ev0("autoAccept.enabled"), ev0("interval.enabled")],
        [False, False, False])
ev0("page.saveConfig()")
p.wait_idle(ev0, "cfgExecutor")
p.check("an Apply before the settings have been read writes NOTHING", p.calls_matching("config set"), [])
p.check("...so the stored surface is untouched", stored("surface"), "popup")
p.check("...and the stored interval", stored("refresh_interval_min"), "60")
p.check("...and the boolean the QML default disagrees with", stored("include_flatpak"), "true")
# The icon size is the sharpest version of this: the page's own default is "auto" and the stored
# value is "medium", so an Apply that ran on the page's defaults would be visible immediately.
p.check("...and the stored panel icon size", stored("widget_icon_size"), "medium")
p.wait_for(ev0, "page.pendingReads", 0)
p.check("once the reads land the controls come back", ev0("includeFlatpak.enabled"), True)
p.check("...and the page holds the stored values, not its defaults", ev0("interval.value"), 60)
p.check("...including the panel icon size it was never told to guess", ev0("page.iconSizeKey"),
        "medium")
p.check("...shown as the selected radio, not merely held in a property",
        ev0("iconSizeRepeater.itemAt(2).checked"), True)

# ==================================================================================================
# The Apply button, wired the way the shell wires it.
# ==================================================================================================
p.clear_calls()
page, ev = build()
host, hev = shell_for(page)
p.check("the page exposes the unsavedChangesChanged signal the config dialog connects to",
        hev("host.attach()"), True)
p.check("a freshly loaded page has nothing to save", ev("page.unsavedChanges"), False)
p.check("...so the dialog's Apply button starts out greyed, correctly", hev("host.applyEnabled"), False)
p.check("...and the async reads that populated it did NOT arm it", hev("host.hookFires") <= 1, True)

# A user click: the control flips its own `checked` and THEN emits `toggled`. Setting `checked`
# alone is what the reads do, and that must stay silent - which the assertion above just showed.
ev("includeFlatpak.checked = false")
ev("includeFlatpak.toggled()")
p.pump(50)
p.check("changing a checkbox marks the page unsaved", ev("page.unsavedChanges"), True)
p.check("...which is what turns the dialog's Apply button on", hev("host.applyEnabled"), True)
p.check("...through the signal, not a poll", hev("host.hookFires") >= 1, True)
p.check("...and closing the dialog now ASKS instead of discarding silently",
        hev("host.closingWouldPrompt()"), True)

p.clear_calls()
ev("page.saveConfig()")
p.wait_idle(ev, "cfgExecutor")
p.check("Apply writes the key that changed",
        sorted(c.split()[2] for c in p.calls_matching("config set")), ["include_flatpak"])
p.check("...the CLI got the new value", stored("include_flatpak"), "false")
p.check("...the page is clean again", ev("page.unsavedChanges"), False)
p.check("...and Apply greys back out", hev("host.applyEnabled"), False)

# The interval box: `valueModified` is the user-driven signal, `valueChanged` is not.
ev("interval.value = 120")
ev("interval.valueModified()")
p.pump(50)
p.check("moving the interval arms Apply too", hev("host.applyEnabled"), True)
p.clear_calls()
ev("page.saveConfig()")
p.wait_idle(ev, "cfgExecutor")
p.check("...and Apply writes it", stored("refresh_interval_min"), "120")
p.check("the surface was NOT rewritten alongside it", stored("surface"), "popup")
p.clear_calls()
ev("page.saveConfig()")
p.wait_idle(ev, "cfgExecutor")
p.check("saving twice does not rewrite what it just wrote", p.calls_matching("config set"), [])

# The panel icon size. Same shape as the surface radios - the selection lives in a page property
# and the delegates are a view of it - and the same failure if it did not: a Repeater whose
# delegates are not realised reports nothing checked, and Apply would write the first option over
# whatever the user has.
ev("iconSizeRepeater.itemAt(3).checked = true")
ev("iconSizeRepeater.itemAt(3).toggled()")
p.pump(50)
p.check("choosing a panel icon size arms Apply", hev("host.applyEnabled"), True)
p.check("...and the page holds the choice, not the delegate", ev("page.iconSizeKey"), "large")
p.clear_calls()
ev("page.saveConfig()")
p.wait_idle(ev, "cfgExecutor")
p.check("...and Apply writes exactly that one key",
        sorted(c.split()[2] for c in p.calls_matching("config set")), ["widget_icon_size"])
p.check("...with the value the widget reads back", stored("widget_icon_size"), "large")
p.check("the interval was not rewritten alongside it", stored("refresh_interval_min"), "120")
p.check("...nor the surface", stored("surface"), "popup")
p.clear_calls()
ev("page.saveConfig()")
p.wait_idle(ev, "cfgExecutor")
p.check("...and a second Apply writes nothing at all", p.calls_matching("config set"), [])
# Back to Automatic, which is a real choice and not just the absence of one.
ev("iconSizeRepeater.itemAt(0).checked = true")
ev("iconSizeRepeater.itemAt(0).toggled()")
p.pump(50)
p.clear_calls()
ev("page.saveConfig()")
p.wait_idle(ev, "cfgExecutor")
p.check("Automatic is stored as a value like any other", stored("widget_icon_size"), "auto")

# ==================================================================================================
# The surface lock is a RUN-time fact, not an edit.
# Measured: with auto_accept already false in the config, opening the settings and pressing Apply -
# touching nothing - rewrote a stored `popup` to `terminal`.
# ==================================================================================================
setval("auto_accept", "false")
setval("surface", "popup")
setval("include_flatpak", "true")
setval("refresh_interval_min", "60")
p.clear_calls()
page2, ev2 = build()
p.check("the page opens on a config whose confirmation is on", ev2("autoAccept.checked"), False)
p.check("...so the non-terminal surfaces are locked", ev2("page.surfacesLocked"), True)
p.check("...but the stored choice is still the selected one", ev2("page.surfaceKey"), "popup")
p.check("...and it is what Apply would write", ev2("page.selectedSurface()"), "popup")
p.check("...shown as selected, just not changeable", ev2("surfaceRepeater.itemAt(1).checked"), True)
p.check("...greyed out, with the reason stated above it",
        ev2("surfaceRepeater.itemAt(1).enabled"), False)
p.check("...while the terminal option stays reachable",
        ev2("surfaceRepeater.itemAt(0).enabled"), True)
ev2("page.saveConfig()")
p.wait_idle(ev2, "cfgExecutor")
p.check("an untouched Apply on a locked page writes NOTHING", p.calls_matching("config set"), [])
p.check("...and the stored preference survives it", stored("surface"), "popup")

# ...and ticking confirmation IN the page does not quietly edit the surface either.
setval("auto_accept", "true")
p.clear_calls()
page3, ev3 = build()
p.check("a page opened with confirmation off is unlocked", ev3("page.surfacesLocked"), False)
ev3("autoAccept.checked = false")
ev3("autoAccept.toggled()")
p.pump(60)
p.check("ticking confirmation locks the other surfaces", ev3("page.surfacesLocked"), True)
p.check("...and does NOT throw away the surface the user had chosen", ev3("page.surfaceKey"), "popup")
ev3("autoAccept.checked = true")
ev3("autoAccept.toggled()")
p.pump(60)
p.check("...so unticking it hands that choice straight back", ev3("page.surfaceKey"), "popup")
p.check("...and the radios are live again", ev3("surfaceRepeater.itemAt(1).enabled"), True)
p.clear_calls()
ev3("page.saveConfig()")
p.wait_idle(ev3, "cfgExecutor")
# Ticked then unticked: auto_accept is back to the value the CLI already holds, so there is
# nothing to write. A page that wrote it anyway would be rewriting a key on the strength of
# having been LOOKED at, which is the whole class of bug this section exists for.
p.check("a setting toggled and toggled back writes nothing at all",
        sorted(c.split()[2] for c in p.calls_matching("config set")), [])
p.check("...and the surface is still what it was", stored("surface"), "popup")

# A deliberate surface change still writes, of course.
ev3("page.applySurface('offline'); page.markChanged('surface')")
p.pump(50)
p.check("choosing a different surface arms Apply", ev3("page.unsavedChanges"), True)
p.clear_calls()
ev3("page.saveConfig()")
p.wait_idle(ev3, "cfgExecutor")
p.check("...and Apply stores it", stored("surface"), "offline")

# ==================================================================================================
# A `config set` that failed is not remembered as a success.
# Measured: the page recorded the value as stored BEFORE the CLI answered, so a failed write
# compared equal on the next Apply, wrote nothing, and could never be retried.
# ==================================================================================================
for k, v in DEFAULTS:
    setval(k, v)
page4, ev4 = build()
host4, hev4 = shell_for(page4)
hev4("host.attach()")
toggle_fail(FAILSET, "include_flatpak")
ev4("includeFlatpak.checked = false")
ev4("includeFlatpak.toggled()")
p.clear_calls()
ev4("page.saveConfig()")
p.wait_idle(ev4, "cfgExecutor")
p.check("a write that fails is attempted once", p.call_count("config set include_flatpak"), 1)
p.check("...the stored value did not change, because the write failed", stored("include_flatpak"), "true")
p.check("...the page says so", "cannot write include_flatpak" in str(ev4("page.loadError")), True)
p.check("...and it is NOT recorded as saved", ev4("page.loaded['include_flatpak']"), "true")
p.check("...so the page is still unsaved", ev4("page.unsavedChanges"), True)
p.check("...and the dialog's Apply button is live for the retry", hev4("host.applyEnabled"), True)

p.clear_calls()
ev4("page.saveConfig()")
p.wait_idle(ev4, "cfgExecutor")
p.check("a second Apply RETRIES the write instead of comparing it equal",
        p.call_count("config set include_flatpak"), 1)
p.check("...still failing while the CLI still refuses", stored("include_flatpak"), "true")

toggle_fail(FAILSET, "include_flatpak", False)
p.clear_calls()
ev4("page.saveConfig()")
p.wait_idle(ev4, "cfgExecutor")
p.check("...and once the CLI stops refusing, the retry lands", stored("include_flatpak"), "false")
p.check("...now it is remembered as stored", ev4("page.loaded['include_flatpak']"), "false")
p.clear_calls()
ev4("page.saveConfig()")
p.wait_idle(ev4, "cfgExecutor")
p.check("...and is not written a fourth time", p.calls_matching("config set"), [])

# ==================================================================================================
# A READ that failed must not become a write of the page's default.
# ==================================================================================================
setval("include_flatpak", "true")
setval("surface", "popup")
setval("auto_accept", "true")
setval("refresh_interval_min", "45")
toggle_fail(FAILGET, "include_flatpak")
p.clear_calls()
page5, ev5 = build()
p.check("a read that fails still finishes the load", ev5("page.pendingReads"), 0)
p.check("...and is remembered as unread", ev5("page.readFailed['include_flatpak']"), True)
p.check("...and reported to the user", "cannot read include_flatpak" in str(ev5("page.loadError")), True)
p.check("...while the other keys loaded normally", ev5("interval.value"), 45)
ev5("page.saveConfig()")
p.wait_idle(ev5, "cfgExecutor")
p.check("Apply does NOT write the page's default over the key it could not read",
        p.calls_matching("config set include_flatpak"), [])
p.check("...so the stored value stands", stored("include_flatpak"), "true")
# ...unless the user deliberately moves that control, where the value on screen is theirs.
ev5("includeFlatpak.checked = false")
ev5("includeFlatpak.toggled()")
p.clear_calls()
ev5("page.saveConfig()")
p.wait_idle(ev5, "cfgExecutor")
p.check("but a control the user DID move is written, unread key or not",
        p.call_count("config set include_flatpak"), 1)
p.check("...with their value", stored("include_flatpak"), "false")
toggle_fail(FAILGET, "include_flatpak", False)

# ==================================================================================================
# The rest of the page.
# ==================================================================================================
for k, v in DEFAULTS:
    setval(k, v)
p.clear_calls()
page6, ev6 = build()
p.check("all five settings are read on open",
        sorted(c.split()[2] for c in p.calls_matching("config get")),
        ["auto_accept", "include_flatpak", "refresh_interval_min", "surface",
         "widget_icon_size"])
p.check("...and the holds list too", p.call_count("holds"), 1)
p.check("a true boolean renders as a ticked box", ev6("includeFlatpak.checked"), True)
p.check("the stored surface is the selected radio", ev6("page.selectedSurface()"), "popup")
p.check("the interval box shows the stored value", ev6("interval.value"), 60)
p.check("the holds list is populated", ev6("page.holds.length"), 3)
p.check("...with the CLI's own ids", ev6("page.holds[0].id"), "dnf:vim-common")
p.check("an untouched page writes nothing at all", p.calls_matching("config set"), [])

p.clear_calls()
ev6('page.removeHold("dnf:vim-common")')
p.wait_for(ev6, "page.holdsBusy", False)
p.wait_idle(ev6, "cfgExecutor")
p.check("removing a hold calls unhold", p.call_count("unhold"), 1)
p.check("...with the whole backend:name pair as ONE argument",
        p.argv("unhold"), ["unhold", "dnf:vim-common"])
p.check("...and the list is re-read afterwards", ev6("page.holds.length"), 2)
p.check("...leaving the other hold alone", ev6("page.holds[0].id"), "flatpak:org.gimp.GIMP")
p.check("...and removing a hold is not an unsaved change", ev6("page.unsavedChanges"), False)

# A hold line the CLI would never have written, because the holds file is a plain text file a
# human can edit - and the page hands whatever it finds there to a shell.
p.clear_calls()
ev6("page.removeHold(%r)" % HOSTILE_HOLD)
p.wait_for(ev6, "page.holdsBusy", False)
p.wait_idle(ev6, "cfgExecutor")
p.check("a hostile hold id reaches unhold as ONE argument", p.argv("unhold"), ["unhold", HOSTILE_HOLD])
p.check("...and its injected command never ran",
        os.path.exists(os.path.join(p.sandbox, "PWNED")), False)

p.clear_calls()
ev6('page.runPasswordless("enable")')
p.wait_for(ev6, "page.passwordlessBusy", False)
p.check("the enable button runs the CLI's enable verb",
        p.calls_matching("enable-passwordless"), ["enable-passwordless"])
p.check("...and shows the command's own last words",
        ev6("page.passwordlessResult"), "some polkit chatter Passwordless updates enabled")
p.check("...and is not an unsaved change either", ev6("page.unsavedChanges"), False)
ev6('page.runPasswordless("disable")')
p.wait_for(ev6, "page.passwordlessBusy", False)
p.check("the disable button runs the disable verb",
        p.calls_matching("disable-passwordless"), ["disable-passwordless"])
p.check("...with its own result line", ev6("page.passwordlessResult"), "Passwordless updates disabled")

# An interval set below the dialog's floor is shown, not silently raised - and the arrows can
# still reach a round number from there (stepSize 5, not 15: 5 -> 20 -> 35 never lands on 60).
setval("refresh_interval_min", "5")
page7, ev7 = build()
p.check("a CLI-set interval below the dialog floor is displayed truthfully", ev7("interval.value"), 5)
p.check("...the control lowers its floor to meet it", ev7("interval.from"), 5)
p.check("...and one step from there lands on a number a human would choose",
        [ev7("interval.stepSize"), ev7("interval.value + interval.stepSize")], [5, 10])
p.clear_calls()
ev7("page.saveConfig()")
p.wait_idle(ev7, "cfgExecutor")
p.check("...and saving without touching it does not raise it", stored("refresh_interval_min"), "5")

# ==================================================================================================
# "Saved" is a claim about writes that LANDED, not writes that were dispatched.
# Measured: saveConfig() cleared unsavedChanges on the line after it handed four asynchronous
# `kempt config set` calls to the executor. The shell reads that one property to decide both
# whether Apply is clickable and whether closing the dialog prompts - so for as long as the writes
# were in flight (up to their 15-second timeout) Apply was grey and Escape closed silently on a
# setting that had not been written yet. The stub sleeps below to make that window observable;
# on a real box it is a fork, an exec and a file write, every time.
# ==================================================================================================
for k, v in DEFAULTS:
    setval(k, v)
toggle_fail(SLOWSET, "include_flatpak")
page8, ev8 = build()
host8, hev8 = shell_for(page8)
hev8("host.attach()")
ev8("includeFlatpak.checked = false")
ev8("includeFlatpak.toggled()")
p.pump(50)
p.clear_calls()
ev8("page.saveConfig()")
# Deliberately no pump between those two lines: this is the state the shell sees on the very next
# turn after Apply, which is when it recomputes the button.
p.check("Apply does not call the page saved on the line it dispatches the write",
        ev8("page.unsavedChanges"), True)
p.check("...so the dialog's Apply button stays live while the write is in flight",
        hev8("host.applyEnabled"), True)
p.check("...and closing the dialog in that window still ASKS",
        hev8("host.closingWouldPrompt()"), True)
p.check("...with the write genuinely outstanding, not merely unflagged", ev8("page.saving"), True)
p.pump(500)
p.check("...still unsaved half a second in, while the CLI has yet to answer",
        ev8("page.unsavedChanges"), True)
p.check("...and the stored value has not moved yet either", stored("include_flatpak"), "true")
p.wait_idle(ev8, "cfgExecutor")
p.check("once the write lands the page is clean", ev8("page.unsavedChanges"), False)
p.check("...the button greys out THEN, and not before", hev8("host.applyEnabled"), False)
p.check("...and what the CLI holds is what the user chose", stored("include_flatpak"), "false")
p.check("...with nothing left outstanding", ev8("page.outstandingWrites"), 0)

# A second Apply while the first round is still in flight must not start another. Its callbacks
# would decrement a counter that had been reset under them, and the page could reach zero - and
# report itself saved - with writes still queued.
toggle_fail(SLOWSET, "surface")
ev8("page.applySurface('background'); page.markChanged('surface')")
p.pump(50)
p.clear_calls()
serial8 = ev8("cfgExecutor.serial")
ev8("page.saveConfig()")
ev8("page.saveConfig()")
# serial counts jobs DISPATCHED, and run() pushes synchronously - so this is answerable on the
# same turn, before the stub has been forked and long before it could log a call.
p.check("a second Apply on top of one still running dispatches nothing extra",
        ev8("cfgExecutor.serial") - serial8, 1)
p.wait_idle(ev8, "cfgExecutor")
p.check("...and the single round that ran wrote the value", stored("surface"), "background")
p.check("...having called the CLI exactly once", p.call_count("config set surface"), 1)
p.check("...leaving the page clean exactly once", ev8("page.unsavedChanges"), False)
toggle_fail(SLOWSET, "include_flatpak", False)
toggle_fail(SLOWSET, "surface", False)

# The keys are written in a fixed order, so "clear it when the last callback returns" would be
# precisely the wrong rule on its own: a failure on the FIRST key followed by a success on the
# last would report the page saved with a setting silently dropped. Any failure keeps it armed.
for k, v in DEFAULTS:
    setval(k, v)
page9, ev9 = build()
host9, hev9 = shell_for(page9)
hev9("host.attach()")
toggle_fail(FAILSET, "include_flatpak")
ev9("includeFlatpak.checked = false")
ev9("includeFlatpak.toggled()")
ev9("interval.value = 90")
ev9("interval.valueModified()")
p.pump(50)
p.clear_calls()
ev9("page.saveConfig()")
p.wait_idle(ev9, "cfgExecutor")
p.check("both changed keys are attempted",
        sorted(c.split()[2] for c in p.calls_matching("config set")),
        ["include_flatpak", "refresh_interval_min"])
p.check("...the writable one lands", stored("refresh_interval_min"), "90")
p.check("...the refused one does not", stored("include_flatpak"), "true")
p.check("a LATER write succeeding does not clear a page whose earlier write failed",
        ev9("page.unsavedChanges"), True)
p.check("...so Apply is live for the retry", hev9("host.applyEnabled"), True)
toggle_fail(FAILSET, "include_flatpak", False)
p.clear_calls()
ev9("page.saveConfig()")
p.wait_idle(ev9, "cfgExecutor")
p.check("...and the retry, once it lands, is what finally clears it",
        ev9("page.unsavedChanges"), False)
p.check("...having written the value that was dropped", stored("include_flatpak"), "false")
p.check("...without rewriting the key that had already succeeded",
        p.calls_matching("config set refresh_interval_min"), [])

# ==================================================================================================
# A settings write is never stuck behind the passwordless action.
# runPasswordless waits on a HUMAN in an authentication dialog, and carries a 120-second timeout to
# match. Sharing the page's one queue meant an Apply pressed meanwhile went to the back of it: the
# write was real and would eventually land, but it could land two minutes later. Its own executor
# is the fix - the two touch different files, so nothing was being serialised except the waiting.
# ==================================================================================================
for k, v in DEFAULTS:
    setval(k, v)
open(PWSLOW, "w").close()      # ...and now the stub waits, the way the polkit dialog does
page10, ev10 = build()
p.clear_calls()
ev10('page.runPasswordless("enable")')
p.pump(50)
p.check("the passwordless action is in flight", ev10("page.passwordlessBusy"), True)
p.check("...on a queue of its own", ev10("pwExecutor.current !== null"), True)
p.check("...leaving the settings queue completely free",
        ev10("cfgExecutor.current === null && cfgExecutor.queue.length === 0"), True)
ev10("includeFlatpak.checked = false")
ev10("includeFlatpak.toggled()")
ev10("page.saveConfig()")
p.wait_idle(ev10, "cfgExecutor")
p.check("an Apply pressed during it writes straight away", stored("include_flatpak"), "false")
p.check("...and the page reports itself saved as soon as that write lands",
        ev10("page.unsavedChanges"), False)
p.check("...all while the passwordless action is STILL running", ev10("page.passwordlessBusy"), True)
p.wait_for(ev10, "page.passwordlessBusy", False, timeout_ms=15000)
p.check("...which then finishes normally, with its own last words",
        ev10("page.passwordlessResult"), "some polkit chatter Passwordless updates enabled")

sys.exit(p.done())
