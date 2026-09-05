#!/usr/bin/env python3
"""The popup's actions and the watcher that ends a run (Tasks W3 + the W4 review's B-5 + P3a).

Three things live here that nothing else can reach:

  * the command builders. A package name comes out of the CLI's own JSON and goes back into a
    shell command; the popup's pin toggle is the widget's real injection surface. The node tests
    pin shellQuote, but only this proves the quoted value survives QML, the Executor, /bin/sh and
    argv as ONE argument.
  * the two-queue split. A 2-second log tail sharing the action queue with a 120-second check
    would put ~60 tails in front of every button press.
  * the watcher. /var/lib/rpm is rewritten continuously all the way through a dnf transaction, so
    "any watched path moved" is true every 30 seconds during a run of ours. Treating that as the
    end of the run stopped the spinner a few seconds in, showed a summary of the PREVIOUS run, and
    sent `kempt check` off to queue for the lock the transaction was holding.

P3a added the popup's restart action to that list, and it is the one command in this widget that
must never be got wrong: `org.kde.LogoutPrompt.promptReboot` opens KDE's own cancellable prompt,
while the `org.kde.Shutdown` family reboots the machine on the spot. Both the positive assertion
(the exact argv) and the negative one (neither Shutdown name appears anywhere in the widget) live
below, and the negative one is the more important of the two.

WHAT CANNOT BE DRIVEN HERE, measured 2026-08-26: `root.expanded` is AppletQuickItem's C++
property, and its setter dereferences the applet with no null check. Outside plasmashell there is
no applet, so `root.expanded = true` does not throw - it SEGFAULTS the probe process (rc -11,
before any assertion in this file can report it). Everything the popup does on open and close
therefore goes through named functions - popupOpened() / popupClosed() - which this file drives
directly, with static pins tying them back to the real `onExpandedChanged`. Same shape as the
traysHeading seam at the bottom of this file: neither half proves it alone.
"""
import datetime
import json
import os
import shutil
import subprocess
import sys
import time

import harness

if not harness.have_pyside():
    print("ok: SKIPPED - PySide6 absent")
    sys.exit(0)

p = harness.Probe("probe-popup")
os.makedirs(os.path.join(p.state, "logs"))
os.makedirs(p.config)
open(os.path.join(p.state, "logs", "20260825T000000.log"), "w").write(
    "line one\nline two\nline three\n")
STATE_JSON = os.path.join(p.state, "state.json")
RUNRC = os.path.join(p.sandbox, "runrc")
AUTO = os.path.join(p.sandbox, "auto_accept")
# Which state fixture `kempt check` serves, what `kempt config get restart_reminder` answers, and
# what `kempt summary --json` prints. Files rather than constants because every one of them is a
# world the widget has to react to a CHANGE in, and rewriting a file is how this probe changes the
# world under a running widget.
CHECKSRC = os.path.join(p.sandbox, "checksrc")
RR = os.path.join(p.sandbox, "restart_reminder")
RUNJSON = os.path.join(p.sandbox, "runjson")
open(RUNRC, "w").write("0")
open(AUTO, "w").write("true\n")
open(RR, "w").write("true\n")
open(CHECKSRC, "w").write(os.path.join(harness.FIXTURES, "state-live.json"))
LAST_RUN = json.load(open(os.path.join(harness.FIXTURES, "run-last.json")))
open(RUNJSON, "w").write(json.dumps(LAST_RUN))


def now_stamped(entry):
    """A copy of `entry` stamped at this instant, in the CLI's own `date -Iseconds` format.

    tests/fixtures/run-last.json is a real capture and carries the date it was taken. Any scenario
    below in which a run is FINISHING NOW needs an entry that says so, because main.qml only
    speaks its transient post-run line for an entry stamped at or after the moment the run started
    (Logic.runFinishedSince) - the guard that stops an older run's counts being announced as the
    run that just finished. A fixture dated last year is precisely what that guard exists to
    refuse, so a scenario that wants the line has to date its entry like a real run would.
    """
    return dict(entry,
                timestamp=datetime.datetime.now().astimezone().isoformat(timespec="seconds"))

# --- the two commands that must NOT be the real ones -------------------------------------------
# `dbus-send` would open KDE's restart prompt on the founder's box, and `xdg-open` would open a
# log in a real editor. Both are stubbed by NAME on PATH rather than by prefixing the widget's
# command strings: the Executor hands each command to /bin/sh, which inherits this process's
# environment, so a bin directory in front of PATH is the whole seam - and it costs the shipped
# command string nothing. A `PATH=` glued onto the production string to make it testable would be
# a test the widget pays for at runtime, forever.
os.environ["PATH"] = p.bindir + os.pathsep + os.environ["PATH"]
DBUSRC = os.path.join(p.sandbox, "dbusrc")
XDGRC = os.path.join(p.sandbox, "xdgrc")
open(DBUSRC, "w").write("0")
open(XDGRC, "w").write("0")


def recorder(name, rcfile):
    """A stub on PATH that appends its argv to a file and exits with whatever rcfile says."""
    path = os.path.join(p.bindir, name)
    with open(path, "w") as fh:
        fh.write("#!/usr/bin/env bash\n"
                 "printf '%s\\n' \"$@\" >> " + p.sandbox + "/calls." + name + "\n"
                 "printf -- '--\\n' >> " + p.sandbox + "/calls." + name + "\n"
                 "exit \"$(cat " + rcfile + ")\"\n")
    os.chmod(path, 0o755)


def records(name):
    """Every call to a recorder stub, each as the list of arguments it was given."""
    path = os.path.join(p.sandbox, "calls." + name)
    if not os.path.exists(path):
        return []
    return [c.split("\n")[:-1] for c in open(path).read().split("--\n") if c != ""]


def last_record(name):
    """The argv of the most recent call, or [] if it was never called.

    Never an IndexError: a probe that dies here reports one missing behaviour and hides every
    assertion after it, which is the opposite of what a failing test is for.
    """
    got = records(name)
    return got[-1] if got else []


recorder("dbus-send", DBUSRC)
recorder("xdg-open", XDGRC)

p.stub("""
case "$1" in
  config) [[ "$3" == refresh_interval_min ]] && echo 15; [[ "$3" == surface ]] && echo popup
          [[ "$3" == auto_accept ]] && cat %(AUTO)s
          [[ "$3" == restart_reminder ]] && cat %(RR)s; exit 0 ;;
  check)  cp "$(cat %(SRC)s)" %(ST)s; cat %(ST)s; exit 0 ;;
  run)    rc="$(cat %(RUNRC)s)"
          [[ "$rc" == 0 ]] || { echo "konsole not found - install it or run: kempt config set surface background" >&2; exit "$rc"; }
          exit 0 ;;
  update) exit 0 ;;
  hold|unhold) exit 0 ;;
  summary) if [[ "$2" == "--json" ]]; then cat %(RUNJSON)s
           else echo "Kempt - 2026-08-25T01:00:00 (terminal, 42s) ok"; echo "more detail"; fi
           exit 0 ;;
esac
""" % {"AUTO": AUTO, "RR": RR, "SRC": CHECKSRC, "ST": STATE_JSON, "RUNRC": RUNRC,
       "RUNJSON": RUNJSON})
# The human `kempt summary` branch above is kept deliberately, with the exact ISO line the popup
# used to paste into actionMessage. Nothing calls it any more, and that is the point: a widget
# that regressed to the old command would produce that line again, and the run-end assertion far
# below would fail with it in hand rather than failing vaguely.

root, ev = p.create("main.qml")
p.wait_for(ev, "root.kemptState !== null", True)


def settle():
    p.wait_for(ev, "root.checking || root.pendingHold !== null", False, timeout_ms=15000)
    # promptExecutor too: the restart prompt runs on its own queue (see main.qml), so a settle
    # that only watched the other two could return with a dbus-send still in flight.
    p.wait_idle(ev, "executor", "tailExecutor", "promptExecutor")


settle()
p.check("the popup's surface is read from the CLI", ev("root.surface"), "popup")
p.check("...and so is the confirmation setting", ev("root.autoAccept"), True)
p.check("...which together are what a run will actually do", ev("root.effectiveSurface"), "popup")

# --- the pin toggle, with a name chosen to break a naive command builder ----------------------
hostile = "evil; touch " + p.sandbox + "/PWNED"
ev('root.setHold("dnf", %r, true)' % hostile)
settle()
p.check("holding a package calls the CLI's hold verb", p.call_count("hold") >= 1, True)
p.check("...with exactly two arguments", p.argc("hold"), "2")
p.check("...the second being the backend:name pair, verbatim", p.argv("hold")[1], "dnf:" + hostile)
p.check("...and the injected command never ran",
        os.path.exists(os.path.join(p.sandbox, "PWNED")), False)
p.check("a hold refreshes the list afterwards", p.call_count("check") >= 2, True)
p.check("...and the round trip is over: the row moved, so nothing is pending any more",
        ev("root.pendingHold"), None)

ev('root.setHold("flatpak", "org.gimp.GIMP", false)')
settle()
p.check("unpinning calls the unhold verb", p.call_count("unhold"), 1)
p.check("...with the flatpak backend in the argument", p.argv("unhold")[1], "flatpak:org.gimp.GIMP")

# ==================================================================================================
# The watcher, field by field.
# ==================================================================================================
def fields():
    return str(ev("root.watchStamp")).split()


def poll(trigger):
    ev("root.pollWatch(%s)" % ("true" if trigger else "false"))
    p.wait_idle(ev, "executor")
    settle()


def rebaseline():
    ev('root.watchStamp = ""')
    poll(False)


# The padding first, because the field NUMBERS below mean nothing without it. `stat` prints
# nothing at all for a path that does not exist, so an unpadded `stat -c %Y a b c d` on a box
# missing one of them returns three numbers and every field after the gap shifts left. Here the
# gap is our own state file and the config file, neither of which this sandbox has yet.
if os.path.exists(STATE_JSON):
    os.remove(STATE_JSON)
rebaseline()
f = fields()
p.check("the watch stamp is four fields even when two of the paths do not exist", len(f), 4)
p.check("...the missing ones padded with a zero rather than left out", [f[2], f[3]], ["0", "0"])
p.check("...and the ones that do exist carry a real mtime", f[0].isdigit() and f[0] != "0", True)

# The command itself, read off the live property: this is the string a shell is really handed.
watchcmd = str(ev("root.watchCmd"))
p.check("the watch command pads every path it stats", "|| echo 0" in watchcmd, True)
raw = subprocess.run(["sh", "-c", watchcmd], capture_output=True, text=True,
                     env=dict(os.environ, HOME=p.home))
p.check("...and running it in a real shell does return four fields", len(raw.stdout.split()), 4)

# Now the states. A run of ours is in flight; the package database moves, as it does all the way
# through a dnf transaction.
ev("root.doCheck()")
settle()
ev("root.enterUpdating()")
p.pump(120)
p.check("the widget is in the updating state", ev("root.updating"), True)
rebaseline()

before_check, before_cfg = p.call_count("check"), p.call_count("config")
# Doctoring the PREVIOUS stamp is how a write to /var/lib/rpm is simulated: pollWatch compares
# what it last saw against what it reads now, so a previous stamp whose rpm field is older is
# exactly the world in which rpm has just been written. (/var/lib/rpm is root-owned - a user-level
# probe cannot touch it, and the plan says never to try.)
f = fields(); f[0] = "1"
ev("root.watchStamp = %r" % " ".join(f))
poll(True)
p.check("the rpm database moving mid-run does NOT end the run", ev("root.updating"), True)
p.check("...and does NOT send a check off to fight the transaction for the dnf lock",
        p.call_count("check"), before_check)
p.check("...nor re-read the config for it", p.call_count("config"), before_cfg)

f = fields(); f[1] = "1"
ev("root.watchStamp = %r" % " ".join(f))
poll(True)
p.check("flatpak's database moving mid-run does not end it either", ev("root.updating"), True)
p.check("...and starts no check", p.call_count("check"), before_check)

# The config file IS worth reacting to mid-run: it is the settings page's only way in, and two
# `config get` calls take no locks. It still must not end the run or start a check.
open(os.path.join(p.config, "config"), "w").write("surface=popup\n")
poll(True)
p.check("the settings page writing the config mid-run re-reads the settings",
        p.call_count("config") > before_cfg, True)
p.check("...without ending the run", ev("root.updating"), True)
p.check("...and still without a check", p.call_count("check"), before_check)

# ...and the one signal that does end it: the CLI re-checking itself on the way out of the run.
# The entry the CLI would have just written is stamped now, like a real one - see now_stamped.
open(RUNJSON, "w").write(json.dumps(now_stamped(LAST_RUN)))
rebaseline()
before_check = p.call_count("check")
shutil.copy(os.path.join(harness.FIXTURES, "state-live.json"), STATE_JSON)
harness.touch(STATE_JSON, "2031-01-01")
poll(True)
p.wait_for(ev, "root.updating", False, timeout_ms=8000)
p.check("the CLI writing state.json DOES end the run", ev("root.updating"), False)
settle()
# ...and this check is never debounced. The watcher's quiet window (Logic.watcherCheckDue) drops a
# watcher-triggered check within a minute of the last one, and a run that took twenty seconds after
# a popup-open check is squarely inside it - but the end of a run is the moment the counts on
# screen are most wrong, and the user who pressed Update Now is the one looking at them. Checks
# have been running throughout this probe, so the window IS open here: this line is the regression
# test for that exemption as much as for the check itself.
p.check("...and that is what earns a fresh check", p.call_count("check") > before_check, True)
# What this used to assert, verbatim: root.actionMessage == "Kempt - 2026-08-25T01:00:00
# (terminal, 42s) ok" - the first line of the human `kempt summary`, pasted into the popup as its
# post-run line. It is true and it is an ISO timestamp, which is no answer at all to "what just
# happened?"; the founder's 2026-08-26 review named it as the thing to remove. The run's own
# history entry answers the question instead, and actionMessage goes back to being only what it
# was always good for: a button press that failed and has something to say.
p.wait_for(ev, 'root.postRunLine !== ""', True, timeout_ms=6000)
p.check("...and one line saying what the run actually did", ev("root.postRunLine"),
        "Updated 4 packages in 2s")
p.check("...read from the run's own entry rather than from the human summary",
        p.argv("summary"), ["summary", "--json"])
p.check("...and nothing about a SUCCESSFUL run lands in the failure line any more",
        ev("root.actionMessage"), "")
open(RUNJSON, "w").write(json.dumps(LAST_RUN))   # back to the capture, stamp and all

# With no run in flight the watcher is exactly what it always was: any package change is a reason
# to look, which is the stale-badge killer the whole poll exists for.
p.check("no run is in flight now", ev("root.updating"), False)
rebaseline()
# Past the quiet window, because that is the case this asserts. A `dnf upgrade` typed in a terminal
# minutes after Kempt last looked is the scenario; a package database moving seconds after a check
# is the run's own wake, and probe_state pins that it is dropped. Wound back rather than waited
# out: the window's boundaries are pinned to the millisecond under node.
ev("root.lastCheckFinished = Date.now() - 61000")
before_check = p.call_count("check")
f = fields(); f[0] = "1"
ev("root.watchStamp = %r" % " ".join(f))
poll(True)
p.check("with nothing running, the rpm database moving DOES trigger a check",
        p.call_count("check") > before_check, True)

rebaseline()
before_check, before_cfg = p.call_count("check"), p.call_count("config")
poll(True)
p.check("an unchanged stamp triggers no check", p.call_count("check"), before_check)
p.check("...and no config re-read", p.call_count("config"), before_cfg)

# --- Update Now -------------------------------------------------------------------------------
before = p.call_count("run")
ev("root.startUpdate()")
p.wait_for(ev, "root.updating", True, timeout_ms=8000)
settle()
p.check("Update Now calls `kempt run`", p.call_count("run") - before, 1)
p.check("...and only `run` - the long transaction never enters the queue", p.call_count("update"), 0)
p.check("...the widget enters the updating state", ev("root.updating"), True)
p.check("...and the icon follows it", ev("root.vm.iconState"), "updating")

harness.touch(STATE_JSON, "2032-01-01")
rebaseline()
f = fields(); f[2] = "1"
ev("root.watchStamp = %r" % " ".join(f))
poll(True)
p.wait_for(ev, "root.updating", False, timeout_ms=8000)
p.check("a finished run takes the widget out of the updating state", ev("root.updating"), False)
settle()

# --- a run that could not start says why, in the CLI's words ----------------------------------
open(RUNRC, "w").write("4")
ev("root.startUpdate()")
p.wait_for(ev, 'String(root.actionMessage).indexOf("konsole") >= 0', True, timeout_ms=8000)
p.check("a failed launch reports the CLI's own remedy", ev("root.actionMessage"),
        "konsole not found - install it or run: kempt config set surface background")
p.check("...and does NOT pretend an update is running", ev("root.updating"), False)
open(RUNRC, "w").write("0")

# --- Stage offline ----------------------------------------------------------------------------
ev("root.stageOffline()")
p.wait_for(ev, "root.updating", True, timeout_ms=8000)
p.check("Stage offline asks for the offline surface", p.argv("update"), ["update", "--surface=offline"])
p.check("...and shows the updating state too", ev("root.updating"), True)
ev("root.leaveUpdating()")
settle()

# --- the log tail runs on its own queue -------------------------------------------------------
action_serial = ev("executor.serial")
ev("root.enterUpdating()")
p.wait_for(ev, 'root.logPath !== ""', True, timeout_ms=8000)
p.check("the newest log file is found", os.path.basename(str(ev("root.logPath"))),
        "20260825T000000.log")
ev("root.pollLog()")
p.wait_for(ev, 'root.logTail !== ""', True, timeout_ms=8000)
p.check("the popup tails it", "line three" in str(ev("root.logTail")), True)
# serial counts jobs DISPATCHED. If the tail used the action executor, tailExecutor's would still
# be 0 and the action executor's would have grown - which is the queue-flooding bug.
p.check("the log tail dispatched jobs on the tail executor", ev("tailExecutor.serial") >= 2, True)
p.check("...and the action executor did not run them", ev("executor.serial") == action_serial, True)

# ...and a tail still in flight is not joined by the next tick. Splitting the tail onto its own
# executor stopped it delaying the ACTION queue; it did nothing about it flooding its OWN. The
# timer ticks every two seconds, and a `tail` can outlast that - a loaded box, a log on a slow
# disk, or the executor already sitting on its 10-second timeout - at which point every further
# tick adds another job behind the one that has not come back. Three calls in a row, one job.
guard_serial = ev("tailExecutor.serial")
ev("root.pollLog(); root.pollLog(); root.pollLog()")
p.check("ticks arriving while a tail is in flight are skipped, not queued behind it",
        ev("tailExecutor.serial") - guard_serial, 1)
p.check("...so nothing accumulates on the tail queue", ev("tailExecutor.queue.length"), 0)
p.wait_idle(ev, "tailExecutor")
p.check("...and once it comes back the queue is free again",
        ev("tailExecutor.current === null"), True)
ev("root.pollLog()")
p.check("...dispatching normally", ev("tailExecutor.serial") - guard_serial, 2)
p.wait_idle(ev, "tailExecutor")

# --- auto_accept false is what cmd_run overrides the surface WITH -----------------------------
# Only a terminal can ask the confirmation question, so the stored `popup` cannot survive it. A
# widget that trusted the stored value alone would sit here tailing a log no run will ever write.
open(AUTO, "w").write("false\n")
ev("root.readSurface()")
p.wait_for(ev, 'root.effectiveSurface', "terminal", timeout_ms=8000)
p.check("confirmation on collapses the effective surface to terminal",
        ev("root.effectiveSurface"), "terminal")
p.check("...while the STORED surface is untouched", ev("root.surface"), "popup")
tail_serial = ev("tailExecutor.serial")
ev("root.pollLog()")
p.pump(300)
p.check("...and the popup stops tailing a log the run will not write there",
        ev("tailExecutor.serial"), tail_serial)

open(AUTO, "w").write("true\n")
ev("root.readSurface()")
p.wait_for(ev, "root.effectiveSurface", "popup", timeout_ms=8000)
p.check("confirmation off hands the stored surface back", ev("root.effectiveSurface"), "popup")

# An older CLI that has never heard of the key prints an empty line, exit 0. Read as a value that
# is "false", it would silently retire the in-popup log on a box whose auto_accept is true.
open(AUTO, "w").write("")
ev("root.readSurface()")
p.wait_idle(ev, "executor")
p.check("an empty answer changes nothing rather than being read as false", ev("root.autoAccept"), True)
open(AUTO, "w").write("true\n")
ev("root.leaveUpdating()")
settle()

# ==================================================================================================
# P3a: the clock, refresh-on-open, the last run, and the restart action.
# ==================================================================================================

# --- the 30-second clock ------------------------------------------------------------------------
# hig-review.md P6: "Checked 4 min ago" is a lie within a minute of being drawn if nothing
# re-evaluates it. So there is a clock - and it must not tick while the popup is shut, because a
# panel process has no business waking every 30 seconds for text nobody is looking at.
p.check("the clock is idle while the popup is closed", ev("clockTimer.running"), False)
p.check("...ticking every 30 seconds when it does run", ev("clockTimer.interval"), 30000)
p.check("...and repeating rather than firing once", ev("clockTimer.repeat"), True)
ev("root.nowMs = 0")
ev("root.refreshClock()")
now_ms = time.time() * 1000
p.check("a tick moves the clock the relative times are measured against",
        abs(float(ev("root.nowMs") or 0) - now_ms) < 5000, True)
# ...and the first frame after opening is right rather than up to 30 seconds stale.
ev("root.nowMs = 0")
ev("root.popupOpened()")
settle()
p.check("opening the popup sets the clock before anything is drawn",
        (ev("root.nowMs") or 0) > 0, True)

# --- refresh on open ----------------------------------------------------------------------------
# Plasma's own popups mostly have no refresh button because they refresh themselves on open
# (hig-review.md 2.3). The staleness guard is what keeps that from being dnfdragora's blocking
# re-index: state-live.json is a real capture from 2026-08-25, so by the time anyone runs this it
# is older than both the configured 15 minutes and the 5-minute ceiling.
ev("root.doCheck()")
settle()
before_check = p.call_count("check")
ev("root.popupOpened()")
settle()
p.check("opening the popup on stale counts goes and gets fresh ones",
        p.call_count("check") - before_check, 1)

# The fresh case cannot be a fixture: a file with a fixed stamp is stale the day after it is
# written, so "checked a moment ago" has to be computed when the probe runs. Everything else in
# this state is the real capture, byte for byte.
FRESH = os.path.join(p.sandbox, "state-fresh.json")
fresh = json.load(open(os.path.join(harness.FIXTURES, "state-live.json")))
stamp = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
fresh["last_check"] = stamp
fresh["last_success"] = stamp
open(FRESH, "w").write(json.dumps(fresh))
open(CHECKSRC, "w").write(FRESH)
ev("root.doCheck()")
settle()
p.check("the widget now holds a state checked a moment ago",
        ev("root.kemptState.last_success"), stamp)
before_check = p.call_count("check")
ev("root.popupOpened()")
settle()
p.check("...so opening the popup asks the package manager for nothing",
        p.call_count("check") - before_check, 0)

# --- the last run -------------------------------------------------------------------------------
# `kempt summary --json` prints the newest history entry verbatim; tests/fixtures/run-last.json is
# one, captured off the real CLI. What is under test here is that main.qml routes that output
# through Logic.lastRunOf rather than re-deriving any of it.
ev("root.lastRun = null")
ev("root.loadLastRun()")
settle()
p.check("the last run is read from the CLI as data", ev("!!root.lastRun"), True)
p.check("...counting everything the run changed, not just the upgrades",
        ev("root.lastRun.changedCount"), 4)
p.check("...carrying the log Show Log opens", ev("root.lastRun.logPath"), LAST_RUN["log"])
p.check("...and whether that run left a restart owed", ev("root.lastRun.rebootNeeded"), True)

# A box that has never updated. `kempt summary --json` prints NOTHING at all under exit 0 there,
# and the popup must render "no last run" - never a fabricated empty one that claims a run at the
# epoch which changed no packages.
open(RUNJSON, "w").write("")
ev("root.loadLastRun()")
settle()
p.check("a box with no runs yet has no last run rather than an empty one",
        ev("root.lastRun === null"), True)
open(RUNJSON, "w").write(json.dumps(LAST_RUN))
ev("root.loadLastRun()")
settle()

# --- one event, one line at a time ---------------------------------------------------------------
# The transient post-run line and the persistent Last update row are the same fact told two ways,
# so the popup shows one or the other. main.qml owns the clearing half of that rule.
ev('root.postRunLine = "Updated 4 packages in 2s"')
ev("root.popupClosed()")
p.check("closing the popup retires the transient line", ev("root.postRunLine"), "")
ev('root.postRunLine = "Updated 4 packages in 2s"')
ev("root.doCheck()")
p.check("...and so does starting a new check, before its answer arrives",
        ev("root.postRunLine"), "")
settle()

# --- ...and the transient line has to be about the run that just finished ------------------------
# `kempt summary --json` no longer walks back past an unreadable newest entry (it answers with
# nothing, this project's "no data"), so this is the belt to that braces: whatever the CLI hands
# over, the popup only SPEAKS a post-run line for an entry stamped at or after the moment
# enterUpdating() ran. Without it a run whose own history entry could not be read had the previous
# run's counts and duration announced as "just finished", in words no reader could tell from the
# truth.
OLD_RUN = dict(LAST_RUN, timestamp="2020-01-01T00:00:00+03:00")
open(RUNJSON, "w").write(json.dumps(OLD_RUN))
ev("root.lastRun = null")
ev('root.postRunLine = ""')
ev("root.enterUpdating()")
p.pump(60)
ev("root.leaveUpdating()")
settle()
p.pump(120)
p.check("a run that ends with only an OLDER entry to show says nothing about it",
        ev("root.postRunLine"), "")
p.check("...while the persistent Last update row still carries that entry, which is all it claims",
        ev("root.lastRun !== null"), True)

# The ordinary case is untouched: an entry stamped now IS the run that just finished. Local time
# with its offset, exactly as `date -Iseconds` writes it in the CLI.
NOW_RUN = dict(LAST_RUN,
               timestamp=datetime.datetime.now().astimezone().isoformat(timespec="seconds"))
open(RUNJSON, "w").write(json.dumps(NOW_RUN))
ev('root.postRunLine = ""')
ev("root.enterUpdating()")
p.pump(60)
ev("root.leaveUpdating()")
settle()
p.pump(120)
p.check("...and a run whose own entry is there is announced as normal",
        ev("root.postRunLine"), "Updated 4 packages in %ds" % LAST_RUN["duration_sec"])
open(RUNJSON, "w").write(json.dumps(LAST_RUN))
ev("root.loadLastRun()")
ev('root.postRunLine = ""')
settle()

# --- the restart action ---------------------------------------------------------------------------
# The one command in this widget that could do real damage. `org.kde.LogoutPrompt.promptReboot`
# ASKS: KDE draws its own confirmation screen, sessions get to object and save, and the user can
# cancel. `org.kde.Shutdown.logoutAndReboot` does not ask. Kempt must never restart anybody's
# machine, so the argv is pinned word for word.
dbus_before = len(records("dbus-send"))
ev("root.promptRestart()")
settle()
p.check("Restart asks for KDE's own prompt exactly once",
        len(records("dbus-send")) - dbus_before, 1)
p.check("...with the argument list that opens a CANCELLABLE prompt", last_record("dbus-send"),
        ["--session", "--dest=org.kde.LogoutPrompt", "--type=method_call",
         "/LogoutPrompt", "org.kde.LogoutPrompt.promptReboot"])

# The assertion that matters more than the one above: not what the widget DOES send, but what no
# file in it may ever contain. Either of these names would turn the restart button into a machine
# that reboots the founder's box without asking, and neither is a typo away from the right one -
# they are a different D-Bus service that a future edit could reach for in good faith.
_UI_SRC = ""
for _name in sorted(os.listdir(harness.UI)):
    if _name.endswith(".qml") or _name.endswith(".js"):
        _UI_SRC += open(os.path.join(harness.UI, _name)).read()
p.check("no file in the widget names the service that reboots without asking",
        "org.kde.Shutdown" in _UI_SRC, False)
p.check("...nor the method on it", "logoutAndReboot" in _UI_SRC, False)

# A prompt that could not be opened has to SAY so. Silence here is the worst outcome: the user
# pressed Restart, nothing happened, and nothing on screen explains why.
open(DBUSRC, "w").write("1")
ev("root.promptRestart()")
settle()
p.check("a prompt that will not open says so instead of failing silently",
        ev("root.restartError"), ev("Logic.COPY.restartFailed"))
p.check("...in the words the copy table agreed", ev("root.restartError"),
        "Could not open the restart prompt.")
open(DBUSRC, "w").write("0")
ev("root.promptRestart()")
settle()
p.check("...and the next attempt that works clears it", ev("root.restartError"), "")

# --- the reminder setting, and closing the message ------------------------------------------------
# Founder amendment A1. The message is a REMINDER and a person can turn it off; the fact that a
# restart is owed is not a reminder and never goes away.
open(CHECKSRC, "w").write(os.path.join(harness.FIXTURES, "state-reboot-needed.json"))
ev("root.doCheck()")
settle()
p.check("a state that says a restart is owed reaches the view model",
        ev("root.vm.rebootNeeded"), True)
p.check("...and with the reminder on, the popup offers the message",
        ev("root.vm.restartMessageVisible"), True)
p.check("...which is the only place the fact is stated - not twice in one window",
        "restart pending" in str(ev("root.vm.footerText")), False)

open(RR, "w").write("false\n")
ev("root.readRestartReminder()")
settle()
p.check("the reminder setting is read from the CLI like every other setting",
        ev("root.restartReminder"), False)
p.check("...and switching it off takes the message off the screen",
        ev("root.vm.restartMessageVisible"), False)
p.check("...while the status line keeps saying a restart is pending",
        "restart pending" in str(ev("root.vm.footerText")), True)

# An older CLI that has never heard of the key prints an empty line and exits 0. Read as "false"
# that would silently switch the reminder off on a box whose setting is true - the same trap
# auto_accept carries, and the same guard.
open(RR, "w").write("")
ev("root.restartReminder = true")
ev("root.readRestartReminder()")
p.wait_idle(ev, "executor")
p.check("an empty answer changes nothing rather than being read as false",
        ev("root.restartReminder"), True)
open(RR, "w").write("true\n")
ev("root.readRestartReminder()")
settle()
p.check("...and the reminder is back on", ev("root.vm.restartMessageVisible"), True)

# Closing the message. Nothing is written, and the fact moves into the status line.
before_cfg = p.call_count("config")
ev("root.dismissRestart()")
p.pump(200)
p.check("closing the restart message takes it off the screen",
        ev("root.vm.restartMessageVisible"), False)
p.check("...and the status line picks the fact up instead",
        "restart pending" in str(ev("root.vm.footerText")), True)
p.check("...without writing a thing: a dismissal is for this session only",
        p.call_count("config"), before_cfg)
ev("root.restartDismissed = false")
open(CHECKSRC, "w").write(FRESH)
ev("root.doCheck()")
settle()

# --- Show Log -------------------------------------------------------------------------------------
# The log path comes out of the CLI's JSON and goes back onto a command line, which makes this the
# same injection surface as the pin toggle - and the same answer, Logic.shellQuote.
xdg_before = len(records("xdg-open"))
ev("root.showLog(%r)" % LAST_RUN["log"])
settle()
p.check("Show Log hands the log to the desktop's own handler",
        len(records("xdg-open")) - xdg_before, 1)
p.check("...as exactly one argument", last_record("xdg-open"), [LAST_RUN["log"]])

hostile_log = "/tmp/x.log; touch " + p.sandbox + "/PWNED_LOG"
ev("root.showLog(%r)" % hostile_log)
settle()
p.check("a hostile path stays one argument", last_record("xdg-open"), [hostile_log])
p.check("...and never becomes a second command",
        os.path.exists(os.path.join(p.sandbox, "PWNED_LOG")), False)

open(XDGRC, "w").write("3")
ev("root.showLog(%r)" % LAST_RUN["log"])
settle()
p.check("a handler that will not open the log says so, with the path to open by hand",
        LAST_RUN["log"] in str(ev("root.actionMessage")), True)
open(XDGRC, "w").write("0")
ev('root.actionMessage = ""')

# --- Check for Updates as a contextual action -------------------------------------------------------
# The tray heading has no slot a plasmoid can put a button in (hig-review.md 2.1); one QAction in
# Plasmoid.contextualActions is the whole channel, and it buys both the tray's More-actions menu
# and the icon's right-click menu.
#
# The registration itself cannot be observed out here: with no applet behind the attached object
# `Plasmoid.contextualActions` reads back undefined, and the assignment is a silent no-op (the
# same thing that happens to `Plasmoid.status`, and the reason claimTrayPresence has a witness).
# So the witness says the line ran, and the assertions under it say the action itself is wired -
# which is the half that could break silently in a real panel.
p.check("the contextual action was registered", ev("root.contextualActionsClaimed"), True)
p.check("...named exactly what the copy table agreed", ev("checkAction.text"),
        ev("Logic.COPY.checkForUpdates"))
p.check("...with the icon Plasma uses for a refresh", ev("checkAction.icon.name"), "view-refresh")
before_check = p.call_count("check")
ev("checkAction.trigger()")
settle()
p.check("...and triggering it runs the same check the Refresh button does",
        p.call_count("check") - before_check, 1)

# --- the pins that keep the drivable seams honest ---------------------------------------------------
# Everything above drives popupOpened()/popupClosed() directly, because writing `expanded` from a
# probe segfaults the process (see this file's header). These are what tie those functions back to
# the property a real panel actually changes, and the clock back to the same property.
_MAIN = " ".join(open(os.path.join(harness.UI, "main.qml")).read().split())
p.check("the popup's open and close really are the engine's own expanded property",
        "onExpandedChanged: { if (root.expanded) root.popupOpened(); else root.popupClosed(); }"
        in _MAIN, True)
p.check("...and the clock runs on exactly that and nothing else",
        "running: root.expanded" in _MAIN, True)
p.check("...with the tick going through the same function the open does",
        "onTriggered: root.refreshClock()" in _MAIN, True)
p.check("the staleness guard on refresh-on-open is logic.js's, not a second copy",
        "Logic.shouldRefreshOnOpen(" in _MAIN, True)

# --- the popup refuses to be built without its inputs -----------------------------------------
# The load-bearing hand-down. FullRepresentation used to reach across into main.qml's `root` id,
# which resolves right up until it does not - and `!undefined.updating` is TRUE, so the popup
# rendered a permanently-updating pane with every button live. `required` makes that a hard error
# at creation instead of a lie on screen.
from PySide6.QtCore import QUrl                                    # noqa: E402
from PySide6.QtQml import QQmlComponent                            # noqa: E402

shell, _ = p.create_inline("""
import QtQuick
import org.kde.plasma.plasmoid
PlasmoidItem { id: shell; property var vm: null }
""", "popup-shell.qml")
full = QQmlComponent(p.engine, QUrl.fromLocalFile(os.path.join(harness.UI, "FullRepresentation.qml")))
p.check("FullRepresentation compiles", [e.description() for e in full.errors()], [])
made = full.create(p.engine.contextForObject(shell))
p.check("FullRepresentation refuses to be created without its inputs", made is None, True)
if made is None:
    msgs = [e.description() for e in full.errors()]
    p.check("...naming both required properties",
            sorted(m.split()[2] for m in msgs if "Required property" in m), ["plasmoidItem", "vm"])

# --- one gear, not two -------------------------------------------------------------------------
# Inside the system tray, Plasma wraps the popup in a heading of its own - the plasmoid's name, a
# pin, and a configure gear pointing at the very dialog our gear opens. The founder's screenshot is
# two gears, one above the other. On a panel or the desktop nobody draws that heading and ours is
# the only way into the settings, so this cannot simply be deleted; it has to be conditional.
#
# The condition is not drivable at its source: `containmentDisplayHints` is read-only on
# Plasma::Applet, and out here the attached `Plasmoid` has no applet at all. So the file holds the
# answer in `traysHeading`, this drives THAT, and the static pins below tie it back to the real
# hint - together they cover what neither half proves alone.
from PySide6.QtQml import QQmlEngine                                # noqa: E402

live = full.createWithInitialProperties({"plasmoidItem": root, "vm": root.property("vm")})
p.check("the popup builds once both its inputs are handed to it", live is not None, True)
if live is not None:
    QQmlEngine.setObjectOwnership(live, QQmlEngine.CppOwnership)
    p.keep.append((full, live))
    lev = p.evaluator(live)

    # No applet behind the attached object here, exactly as on a panel where the containment draws
    # nothing: the expression evaluates (a `False`, not the `None` an EXPR ERROR would give) and
    # says no host heading, so the gear is ours to show.
    p.check("the hint expression evaluates in a real engine rather than throwing",
            lev("(Plasmoid.containmentDisplayHints"
                " & PlasmaCore.Types.ContainmentDrawsPlasmoidHeading) !== 0"), False)
    p.check("...and with nothing else drawing a heading, the popup says so",
            lev("popup.traysHeading"), False)
    p.check("...so the popup keeps its own way into the settings", lev("configureButton.visible"),
            True)

    # ...and the tray case, which is the bug.
    lev("popup.traysHeading = true")
    p.check("a host that draws the heading takes our duplicate gear off the screen",
            lev("configureButton.visible"), False)
    p.check("...and does not take the header with it - the count is ours to draw, and the tray's "
            "chrome does not carry one", lev("popup.header.visible"), True)
    p.check("...the status heading included, which is the pending count and not a second title",
            lev("popup.vm.headerText === popup.plasmoidItem.vm.headerText"), True)

    # --- one refresh icon, not two ----------------------------------------------------------------
    # The same bug as the gear, one control along, and only a real panel could show it. Plasma 6.7
    # renders a SINGLE contextual action as an ICON in the heading it draws, next to the pin and
    # the gear - so registering checkAction (main.qml) does not merely fill a menu, it puts a
    # view-refresh icon on screen. Ours sits underneath it, and the founder's screenshot is both.
    #
    # This is where the file's earlier reasoning was wrong rather than merely incomplete: it copied
    # Bluetooth's pairing but kept the button on the argument that the tray only offers the action
    # through a menu, so hiding ours would cost two clicks. The tray draws it as one click, and the
    # premise is gone.
    #
    # The condition is the PAIR, never the hint alone. claimContextualActions() can fail - it is a
    # try with a witness for exactly that reason - and a tray heading with no action registered
    # draws no refresh icon at all. Gating on the hint by itself would leave the popup with no way
    # to re-check on the one host where the registration did not take.
    p.check("a tray already drawing the registered action does not get our second icon",
            lev("refreshButton.visible"), False)
    p.check("...and the claim really did happen, so that is the both-of-them case",
            ev("root.contextualActionsClaimed"), True)

    # The spinner is a sibling cell, not the button's child, so hiding the button must not take it
    # with it. In the tray it becomes the ONLY thing on screen saying a check is running: the
    # heading's icon is the host's and does not spin.
    ev("root.checking = true")
    p.pump(50)
    p.check("...while the spinner beside it still says a check is running",
            [lev("refreshBusy.running"), lev("refreshBusy.visible")], [True, True])
    p.check("...which is why it must not live inside the button that just went away",
            lev("refreshBusy.parent !== refreshButton"), True)
    ev("root.checking = false")
    p.pump(50)

    # A control nobody can see must not hold the keyboard either. canTakeFocus is visible &&
    # enabled and focusPrimary walks Update Now, then Refresh, then the gear, so both hidden
    # controls have to fall out of that walk on their own.
    p.check("a hidden refresh button cannot take the keyboard",
            lev("canTakeFocus(refreshButton)"), False)
    p.check("...nor can the hidden gear", lev("canTakeFocus(configureButton)"), False)

    # A registration that did NOT take: the hint is still set, nothing is drawing the action, so
    # our button is the only refresh there is and it comes back.
    ev("root.contextualActionsClaimed = false")
    p.pump(50)
    p.check("a tray heading with no action registered keeps our refresh button",
            lev("refreshButton.visible"), True)
    ev("root.contextualActionsClaimed = true")
    p.pump(50)
    p.check("...and registering it takes ours away again", lev("refreshButton.visible"), False)

    # Back to the standalone panel for everything below, which is also the case that matters most
    # here: nobody else is drawing a refresh icon, so ours is the only one and it stays.
    lev("popup.traysHeading = false")
    p.pump(50)
    p.check("off the tray the refresh button is ours to show, registered action or not",
            lev("refreshButton.visible"), True)

    # ==============================================================================================
    # P3b: the layout - the message stack, the list, the Last update row and the footer.
    # ==============================================================================================
    # This one line is the difference between a test and a decoration. createWithInitialProperties
    # above assigns a VALUE; main.qml writes `vm: root.vm`, which is a BINDING that re-reads the
    # view model every time the state changes. Without this, every assertion below would be
    # measuring one frozen view model from the moment the popup was built - every state driven
    # through the stubbed CLI would look identical, and every assertion would pass anyway.
    lev("popup.vm = Qt.binding(function () { return popup.plasmoidItem.vm; })")

    # Everything the popup says out loud. Accessible.announce reaches an accessibility bridge and
    # nothing else, so the popup emits `announced` alongside it and this is what hears it.
    _spy, _sev = p.create_inline("""
import QtQuick
QtObject {
    id: spy
    property var said: []
    function hear(sentence) { var a = spy.said.slice(); a.push(sentence); spy.said = a; }
    function clear() { spy.said = []; }
}
""", "popup-announce-spy.qml")
    p.engine.rootContext().setContextProperty("popupAnnounceSpy", _spy)
    lev("popup.announced.connect(popupAnnounceSpy.hear)")

    def said():
        return json.loads(str(_sev("JSON.stringify(said)")))

    def fixture(name):
        return os.path.join(harness.FIXTURES, name)

    def state(path):
        """Point the stubbed CLI at a state document and let the widget go and read it."""
        open(CHECKSRC, "w").write(path)
        ev("root.doCheck()")
        settle()

    def uptodate_from(source, name):
        """A real capture with nothing left pending - the one shape no fixture carries.

        Derived here rather than added to tests/fixtures/ on purpose: it is the shipped capture
        with its item lists emptied, so it cannot drift away from the real document shape.
        """
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

    def staged_from(source, name, count):
        """The same capture with an ARMED offline transaction recorded on it.

        Derived rather than added to tests/fixtures/ for the same reason as uptodate_from: it is
        the shipped capture plus exactly one key, so it cannot drift away from the real document.
        `offline_staged` is what the CLI publishes only after reconciling its own marker against
        dnf5's transaction status (lib/common.sh, offline_staged_state) - its presence here is the
        widget being told the reconciliation already happened.
        """
        doc = json.load(open(fixture(source)))
        doc["offline_staged"] = {"staged_at": "2026-09-02T10:31:00+03:00",
                                 "count": count, "armed": True}
        path = os.path.join(p.sandbox, name)
        open(path, "w").write(json.dumps(doc))
        return path

    UPTODATE = uptodate_from("state-live.json", "state-uptodate.json")
    UPTODATE_REBOOT = uptodate_from("state-reboot-needed.json", "state-uptodate-reboot.json")

    MESSAGES = [("engineMissingMessage", "the missing-engine message"),
                ("restartMessage", "the restart message"),
                ("stagedMessage", "the staged-transaction message"),
                ("riskyMessage", "the session-critical warning"),
                ("reportMessage", "the report of the last thing that happened")]

    def stack(situation, *shown):
        """Assert the WHOLE stack for one real state: what is up, and what is not."""
        for name, prose in MESSAGES:
            want = name in shown
            p.check("%s, %s is %s" % (situation, prose, "shown" if want else "not shown"),
                    lev(name + ".visible"), want)

    ev("root.restartDismissed = false")
    ev('root.actionMessage = ""')

    state(fixture("state-live.json"))
    ev('root.postRunLine = ""')
    stack("with updates pending and nothing else to say")

    state(fixture("state-reboot-needed.json"))
    stack("with a restart owed", "restartMessage")

    state(fixture("state-risky-heavy.json"))
    stack("with a session-critical transaction pending", "riskyMessage")

    # The same transaction, already staged. The staged message replaces the offer rather than
    # joining it: leaving "Install on Next Restart" on screen over an armed transaction is an
    # invitation to stage the same updates twice, which is what happened on 2026-09-01.
    STAGED_RISKY = staged_from("state-risky-heavy.json", "state-staged-risky.json", 61)
    _sev("clear()")
    state(STAGED_RISKY)
    stack("with that transaction already staged", "stagedMessage")
    # The top of the popup, which is where the person looks first and where staging used to change
    # nothing at all: the header went on counting the same updates as available and Update Now
    # stayed lit under a green banner saying they were staged (hostile panel, finding 3).
    p.check("...with the header saying staged rather than counting the same updates as available",
            lev("popup.vm.headerText"), "61 updates staged for the next restart")
    p.check("...the panel tooltip saying it too, so hover and popup cannot disagree",
            ev("root.vm.tooltipMain"), "61 updates staged for the next restart")
    p.check("...the badge still the true actionable count, which no restart has run yet",
            ev("root.vm.badgeText"), str(ev("root.vm.actionable")))
    p.check("...and Update Now GONE, because the work it would start is already done and waiting",
            lev("updateButton.visible"), False)
    p.check("...announced as it arrives, since a name change on an unfocused alert is readable "
            "and not spoken", said(), ["61 updates are staged - they install on the next restart"])
    p.check("...saying how many updates the restart will install",
            lev("stagedMessage.text"),
            "61 updates are staged - they install on the next restart")
    p.check("...as a Positive message: nothing is wrong and nothing needs pressing",
            lev("stagedMessage.type"), lev("Kirigami.MessageType.Positive"))
    p.check("...and offering the restart, since no restart message is carrying it",
            lev("stagedMessage.actions[0].visible"), True)
    p.check("...under the same label the restart message uses",
            lev("stagedMessage.actions[0].text"), ev("Logic.COPY.restartAction"))
    dbus_staged = len(records("dbus-send"))
    lev("stagedMessage.actions[0].trigger()")
    settle()
    p.check("...and it opens KDE's own prompt, the one place a restart is ever asked for",
            len(records("dbus-send")) - dbus_staged, 1)

    # A staged transaction on a box that ALSO owes a restart for updates already installed. Both
    # messages are true and both are shown - but only the Warning carries the button.
    STAGED_REBOOT = staged_from("state-reboot-needed.json", "state-staged-reboot.json", 4)
    state(STAGED_REBOOT)
    stack("staged, on a box that already owed a restart", "restartMessage", "stagedMessage")
    p.check("...and the staged message stands its button down rather than showing a second one",
            lev("stagedMessage.actions[0].visible"), False)

    # A marker from before the CLI recorded a count still describes a real pending install.
    STAGED_NOCOUNT = staged_from("state-live.json", "state-staged-nocount.json", None)
    state(STAGED_NOCOUNT)
    p.check("an unknown count loses the number, not the sentence",
            lev("stagedMessage.text"), ev("Logic.COPY.stagedUnknownCount"))

    # --- the banner FLIPS when a hold lands behind the stage (spec 4.4) ------------------------
    # The trap, in the user's own order: stage 61 updates with a kernel among them, read something
    # worrying, press the pin on kernel-core - and restart into the kernel you just tried to keep
    # out. dnf5 built that transaction before the hold existed and offers no way to edit a stored
    # one, so the hold is real and so is the install. Before this, the popup's last chance to say
    # so was a green Positive banner with a live Restart… button over the very package the person
    # had just tried to stop, and appending a line to it would have been the contradiction one
    # level down. So the message changes TYPE, loses the restart, and gains one action.
    def conflict_from(source, name, names, names_source, count=61):
        """A capture with an armed stage AND the CLI's conflict verdict on it.

        Derived rather than added to tests/fixtures/ for the same reason as staged_from: it is a
        shipped capture plus one key, so it cannot drift away from the real document shape.
        holds_conflict and names_source are what WP-B publishes - the held packages the stored
        transaction will install anyway, and whether an empty list means "no conflict" or
        "could not tell".
        """
        doc = json.load(open(fixture(source)))
        doc["offline_staged"] = {"staged_at": "2026-09-02T10:31:00+03:00", "count": count,
                                 "armed": True, "holds_conflict": list(names),
                                 "names_source": names_source}
        path = os.path.join(p.sandbox, name)
        open(path, "w").write(json.dumps(doc))
        return path

    CONFLICT1 = conflict_from("state-risky-heavy.json", "state-staged-conflict1.json",
                              ["kernel-core"], "transaction")
    CONFLICT3 = conflict_from("state-risky-heavy.json", "state-staged-conflict3.json",
                              ["kernel-core", "kernel-modules", "systemd"], "transaction")
    # names_source "none" over a state whose dnf items are all HELD: the staged list could not be
    # read at all, so an empty holds_conflict is "cannot tell" rather than "nothing to report", and
    # a box that is holding dnf packages is owed the vague warning instead of the reassurance.
    GENERIC = conflict_from("state-held-only.json", "state-staged-generic.json", [], "none")

    REBUILD_TIP = ("Builds the staged update again with your current holds. Asks for "
                   "authorization; if the rebuild fails, the current staged update is removed.")

    state(CONFLICT1)
    stack("with a hold on a package the staged update contains", "stagedMessage")
    p.check("...the banner tells it in the person's own order of events, with both ways out and "
            "the cost of the one on the button",
            lev("stagedMessage.text"),
            "You held kernel-core after the next-restart install was prepared, so it still"
            " installs. Rebuild it to skip kernel-core, or stop holding kernel-core to keep the"
            " current plan. Rebuilding asks for authorization; if it fails, nothing stays staged.")
    p.check("...as a Warning, because the reassurance is no longer true",
            lev("stagedMessage.type"), lev("Kirigami.MessageType.Warning"))
    # The flip has to arrive as WORDS. Kirigami gives every InlineMessage the AlertMessage role and
    # no name, so a screen reader announcing this one would otherwise read out its icon - and the
    # difference between the two banners would be a colour, which is not a difference at all.
    p.check("...announced to a screen reader as the sentence, not as a change of colour",
            lev("stagedMessage.Accessible.name"), lev("stagedMessage.text"))
    p.check("...offering two actions in the list, one of which is standing down",
            lev("stagedMessage.actions.length"), 2)
    p.check("...and the Restart… button is NOT one of them: offering a restart here offers the "
            "very install they tried to stop", lev("stagedMessage.actions[0].visible"), False)
    p.check("...inert as well as invisible", lev("stagedMessage.actions[0].enabled"), False)
    p.check("...the one action offered is the rebuild", lev("stagedMessage.actions[1].text"),
            "Rebuild Staged Update")
    p.check("...and it is on screen", lev("stagedMessage.actions[1].visible"), True)
    p.check("...disclosing the authorization and the discard cost in its tooltip",
            lev("stagedMessage.actions[1].tooltip"), REBUILD_TIP)
    # ...and the same words to a screen reader, which is the load-bearing half: a polkit dialog
    # takes focus the moment this is pressed, so a person who has not heard the cost by then hears
    # it never (spec, UX finding 9).
    p.check("...in the same words a screen reader gets, before polkit takes the focus",
            lev("stagedMessage.actions[1].Accessible.description"), REBUILD_TIP)
    p.check("...which is the copy table's tooltip, not a second copy of it",
            lev("stagedMessage.actions[1].tooltip"), ev("Logic.COPY.stagedRebuildTooltip"))

    # HIG M1: the only Restart button on screen sat forty pixels above the sentence saying what a
    # restart would install. The design had already removed it from the warning for that reason.
    CONFLICT_REBOOT = conflict_from("state-reboot-needed.json", "state-staged-conflict-reboot.json",
                                    ["kf6-kio"], "transaction", count=4)
    ev("root.restartDismissed = false")
    state(CONFLICT_REBOOT)
    p.check("premise: a restart is owed AND the staged banner is a warning",
            [lev("restartMessage.visible"), ev("root.vm.stagedType")], [True, "warning"])
    p.check("the restart message stands its own button down rather than offering the install the "
            "warning under it is about", lev("restartMessage.actions[0].visible"), False)
    p.check("...inert as well as invisible", lev("restartMessage.actions[0].enabled"), False)
    p.check("...and the staged warning has none either, so nothing on screen offers that restart",
            lev("stagedMessage.actions[0].visible"), False)

    # --- the cap, with more true things to say than there is room for ---------------------------
    # Five messages left the list 95 px tall at the default popup size, and at the minimum they
    # overflowed the popup entirely - they sit outside the ScrollView, so nothing scrolled and the
    # list was gone (hostile panel, M2). Three want the screen here: a press that failed, a staged
    # transaction with a hold behind it, and a restart the box already owes.
    ev('root.actionMessage = "Could not change the hold on bash."')
    p.pump(80)
    p.check("three things are true at once", ev("root.vm.restartMessageVisible"), True)
    stack("with three messages wanting the screen", "reportMessage", "stagedMessage")
    p.check("...so exactly two are drawn, and no more", lev("popup.messageSlots.length"), 2)
    p.check("...in priority order: what you just did, then what changed under you",
            json.loads(str(lev("JSON.stringify(popup.messageSlots)"))), ["report", "staged"])
    p.check("...and the restart is not lost, it is in the footer, which is why it gives way first",
            "restart pending" in str(lev("footerLabel.text")), True)
    ev('root.actionMessage = ""')
    p.pump(80)
    p.check("with the failed press cleared, the restart comes back into the second slot",
            json.loads(str(lev("JSON.stringify(popup.messageSlots)"))), ["staged", "restart"])
    p.check("...and the footer stops repeating what the message is now carrying",
            "restart pending" in str(lev("footerLabel.text")), False)

    # ...and the engine-missing case, which shows ALONE however much else is true.
    ev("root.engineMissing = true")
    ev("root.kemptState = null")
    p.pump(80)
    p.check("a box with no engine says that and nothing else",
            json.loads(str(lev("JSON.stringify(popup.messageSlots)"))), ["engineMissing"])
    ev("root.engineMissing = false")
    state(fixture("state-live.json"))
    ev('root.postRunLine = ""')
    ev("root.restartDismissed = false")
    p.pump(80)

    state(CONFLICT3)
    p.check("three held packages read as the first one and a count, every word moved with it",
            lev("stagedMessage.text"),
            "You held kernel-core and 2 more after the next-restart install was prepared, so they"
            " still install. Rebuild it to skip them, or stop holding them to keep the current"
            " plan. Rebuilding asks for authorization; if it fails, nothing stays staged.")
    p.check("...still a warning", lev("stagedMessage.type"), lev("Kirigami.MessageType.Warning"))

    state(GENERIC)
    stack("with a staged list that could not be read and dnf packages held", "stagedMessage")
    p.check("...the banner says may, because that is what is known",
            lev("stagedMessage.text"),
            "You added holds after the next-restart install was prepared, so it may still install"
            " held packages. Rebuild it to apply your holds. Rebuilding asks for authorization;"
            " if it fails, nothing stays staged.")
    p.check("...as a warning all the same", lev("stagedMessage.type"),
            lev("Kirigami.MessageType.Warning"))
    p.check("...offering the same rebuild, which applies every current hold whatever the list said",
            lev("stagedMessage.actions[1].visible"), True)
    p.check("...and no restart", lev("stagedMessage.actions[0].visible"), False)

    # The unchanged case, asserted again from the other side of the flip: the plain armed stage is
    # still Positive with a live Restart… and no rebuild. This is the regression pin - a variant
    # that fired too eagerly would turn every ordinary staged transaction into a warning.
    state(STAGED_RISKY)
    p.check("an armed stage with no hold behind it is the Positive banner it always was",
            lev("stagedMessage.type"), lev("Kirigami.MessageType.Positive"))
    p.check("...with the restart still on it", lev("stagedMessage.actions[0].visible"), True)
    p.check("...and no rebuild offered", lev("stagedMessage.actions[1].visible"), False)

    # --- the precondition re-verify, at click time (spec 4.4, systems finding 8) ----------------
    # Consent is given to a BANNER, and the banner describes one transaction. Between rendering it
    # and the click, that transaction can be consumed by a restart, replaced by another stage, or
    # cleaned away - and a rebuild is destructive at its start (dnf5 destroys the stored
    # transaction the moment a re-stage begins, spec G2). So the click re-reads state.json and
    # proceeds only if it is still looking at the same stage, still in conflict. Anything else and
    # it runs nothing and says so.
    # The 30-second watcher would otherwise be a coin toss inside this section: it polls mtimes,
    # and rewriting the state file under the widget is exactly what it exists to notice. A check it
    # triggered would re-read the STUB's fixture and put the old stage back mid-assertion. Its own
    # behaviour is pinned further up this file; here it is noise.
    ev("watchTimer.running = false")

    def mutate_state(source, **changes):
        """Rewrite the state file UNDER the running widget, without telling it."""
        doc = json.load(open(source))
        if changes.get("drop_staged"):
            doc.pop("offline_staged", None)
        else:
            doc["offline_staged"].update(changes)
        open(STATE_JSON, "w").write(json.dumps(doc))

    state(CONFLICT1)
    p.check("premise: the banner is derived from the stage staged at 10:31",
            ev("root.vm.stagedStagedAt"), "2026-09-02T10:31:00+03:00")
    mutate_state(CONFLICT1, staged_at="2026-09-05T08:00:00+03:00")
    p.clear_calls()
    ev('root.actionMessage = ""')
    lev("stagedMessage.actions[1].trigger()")
    settle()
    p.check("a rebuild clicked over a stage that has since been replaced runs NOTHING",
            p.call_count("update"), 0)
    p.check("...and does not pretend an update started", ev("root.updating"), False)
    p.check("...it says the stage moved, in the popup, where the press happened",
            ev("root.actionMessage"), ev("Logic.COPY.stagedChanged"))
    p.check("...and the banner is re-derived from what is really on disk now",
            ev("root.vm.stagedStagedAt"), "2026-09-05T08:00:00+03:00")

    # The stage cleaned away entirely between the render and the click: same refusal, and the
    # banner goes with it rather than standing over nothing.
    state(CONFLICT1)
    mutate_state(CONFLICT1, drop_staged=True)
    p.clear_calls()
    ev('root.actionMessage = ""')
    lev("stagedMessage.actions[1].trigger()")
    settle()
    p.check("a rebuild clicked over a stage that is gone runs nothing either",
            p.call_count("update"), 0)
    p.check("...and the banner goes with it", ev("root.vm.stagedMessage"), "")

    # ...and the path that DOES act: nothing moved, so the click spends the consent it was given,
    # on the same command Install on Next Restart runs. Same verb, same polkit action, same dialog.
    state(CONFLICT1)
    p.clear_calls()
    ev('root.actionMessage = ""')
    lev("stagedMessage.actions[1].trigger()")
    p.wait_for(ev, "root.updating", True, timeout_ms=8000)
    # calls_matching and not argv(): argv.<verb> is the LAST call's arguments and survives from
    # the stageOffline test far above, so it would answer correctly for a rebuild that never ran.
    # The call log is cleared right before the trigger, so only this press can fill it.
    p.check("an unchanged stage rebuilds through the offline surface, exactly once",
            p.calls_matching("update"), ["update --surface=offline"])
    p.check("...with nothing to apologise for", ev("root.actionMessage"), "")
    p.check("...and the popup goes into its updating state", ev("root.updating"), True)
    ev("root.leaveUpdating()")
    settle()

    # A rebuild asked for while a run is already in flight does nothing, the same guard
    # stageOffline has: two staging runs at once is the double-press this widget already learned
    # about, with a destructive first step this time.
    ev("root.enterUpdating()")
    p.clear_calls()
    ev("root.rebuildStaged()")
    settle()
    p.check("a rebuild asked for during a run is not a second run", p.call_count("update"), 0)
    ev("root.leaveUpdating()")
    settle()
    ev('root.actionMessage = ""')

    # Stale is not a message any more. It is three words on the footer's dateline, with the CLI's
    # own reason in the tooltip of the button that tries again.
    state(fixture("state-stale.json"))
    stack("with the last check failed over known counts")
    p.check("...the footer says a check failed, on the line that dates the counts it explains",
            "last check failed" in str(lev("footerLabel.text")), True)
    p.check("...and the reason is on the button that would try again",
            str(lev("refreshButton.PlasmaComponents.ToolTip.text")).endswith(
                str(ev("root.vm.staleReason"))), True)
    p.check("...for a screen reader too, since a tooltip is a pointer's channel",
            str(lev("refreshButton.Accessible.description")).endswith(
                str(ev("root.vm.staleReason"))), True)

    state(UPTODATE)
    stack("with nothing at all pending")

    # hig-review.md P1, and the single easiest thing in this redesign to get wrong: a pending
    # restart is a fact about the machine, not an "up to date" fact. You can owe one with twelve
    # updates pending, and you can owe one with nothing pending at all.
    state(UPTODATE_REBOOT)
    stack("up to date and still owing a restart", "restartMessage")

    state(fixture("state-held-only.json"))
    stack("with every pending update held")

    # --- the store-first first run: a widget with no engine behind it -----------------------------
    # The KDE Store carries the plasmoid and nothing else, so a widget with no CLI under it is the
    # ORDINARY first run of a store install rather than an exotic failure. Driven through the
    # property a check answering rc 127 sets; probe_state.py pins that half.
    ev("root.kemptState = null")
    ev("root.engineMissing = true")
    ev('root.postRunLine = ""')
    p.pump(80)
    stack("with the engine not installed", "engineMissingMessage")
    p.check("...as Information, because nothing is broken: something is not set up yet",
            lev("engineMissingMessage.type"), lev("Kirigami.MessageType.Information"))
    p.check("...carrying logic.js's sentence rather than a second copy of it",
            lev("engineMissingMessage.text"), ev("root.vm.engineMissingMessage"))
    p.check("...with the copr command readable in the body",
            "sudo dnf copr enable erez-c137/kempt" in str(lev("engineMissingMessage.text")), True)
    p.check("...and the install command that follows it",
            "sudo dnf install kempt" in str(lev("engineMissingMessage.text")), True)
    p.check("...and somewhere to go for a box that is not Fedora",
            "github.com/erez-c137/kempt" in str(lev("engineMissingMessage.text")), True)
    p.check("...never the shell's own sentence, which is what the popup used to quote",
            "command not found" in str(lev("engineMissingMessage.text")), False)
    p.check("...announced to a screen reader in the same words",
            lev("engineMissingMessage.Accessible.name"), lev("engineMissingMessage.text"))
    # Nothing else that presumes an engine renders beside it. The placeholder is the one that had
    # to be silenced deliberately: it would otherwise promise that a first check is on its way,
    # about a check that is never going to finish.
    p.check("...the placeholder stands down rather than saying a second thing",
            lev("placeholder.visible"), False)
    p.check("...there is nothing pending to list", lev("rowsView.count"), 0)
    p.check("...and no Update Now to press", lev("updateButton.visible"), False)
    # Refresh STAYS, and that is the point of it: it is how somebody who has just installed the
    # package gets an answer without waiting out the hourly timer.
    p.check("...while Refresh stays, because it is what brings the widget back",
            lev("refreshButton.visible && refreshButton.enabled"), True)
    # Copy Commands: the ONE action, and it runs nothing - it puts the chained one-line install
    # on the clipboard, because an InlineMessage's text cannot be selected and a retyped command
    # fails somewhere the reader then has to debug. Triggered here for real: the payload must be
    # vm's copy text (the "&&" form), never the message's own sentence.
    p.check("...offering exactly one action", lev("engineMissingMessage.actions.length"), 1)
    p.check("...named Copy Commands", lev("engineMissingMessage.actions[0].text"), "Copy Commands")
    lev("engineMissingMessage.actions[0].trigger()")
    p.pump(80)
    p.check("...whose payload is the chained one-line form",
            lev("engineCopyClip.text"), ev("root.vm.engineMissingCopyText"))
    p.check("...which is a command line, not the message's sentence",
            " && " in str(lev("engineCopyClip.text")), True)

    ev("root.engineMissing = false")
    state(fixture("state-live.json"))
    p.check("an engine that answers takes the message away again",
            lev("engineMissingMessage.visible"), False)

    state(fixture("state-live.json"))
    ev('root.actionMessage = "Could not change the hold on bash."')
    p.pump(50)
    stack("after a button press that failed", "reportMessage")
    p.check("...saying what failed, in the words main.qml was given",
            lev("reportMessage.text"), "Could not change the hold on bash.")
    p.check("...as an error", lev("reportMessage.type"), lev("Kirigami.MessageType.Error"))
    p.check("...with no Show Log on it, because a failed press wrote no log",
            lev("reportMessage.actions[0].visible"), False)
    ev('root.actionMessage = ""')
    p.pump(50)

    # --- what the up-to-date state actually shows ---------------------------------------------------
    state(UPTODATE)
    p.check("up to date: the header says so", lev("popup.vm.headerText"), "Up to date")
    p.check("...the placeholder carries the sentence", lev("placeholder.visible"), True)
    p.check("...in different words, so the popup never says the same thing twice in one glance",
            lev("placeholder.text") != lev("popup.vm.headerText"), True)
    p.check("...and Update Now is GONE rather than greyed out - a dead primary button in this "
            "exact state was the founder's original complaint", lev("updateButton.visible"), False)
    p.check("...while the footer still dates the counts",
            str(lev("footerLabel.text")).startswith("Checked "), True)

    # Held is the one state where "everything is up to date" would be a lie by omission: nothing is
    # actionable, but there ARE pending updates and the Held group is on screen saying so.
    state(fixture("state-held-only.json"))
    p.check("held only: the Held group carries the truth, so the placeholder stays away",
            lev("placeholder.visible"), False)
    p.check("...there really are rows for it to carry", lev("popup.vm.rows.length") > 0, True)
    p.check("...nothing is actionable, so there is still no Update Now",
            lev("updateButton.visible"), False)
    p.check("...and the footer counts them", "10 held" in str(lev("footerLabel.text")), True)

    # No answer at all is not "nothing to update". vm.actionable is null there rather than 0, and a
    # visibility test written as `!== 0` would have put a live primary button over a popup that has
    # no idea what is pending.
    ev("root.kemptState = null")
    p.pump(50)
    p.check("with no answer at all there is nothing to offer, so no Update Now",
            lev("updateButton.visible"), False)
    p.check("...and the popup says it has no data rather than claiming zero updates",
            lev("placeholder.visible"), True)

    # --- the refresh icon, and the one spinner ---------------------------------------------------------
    state(fixture("state-live.json"))
    before_check = p.call_count("check")
    lev("refreshButton.clicked()")
    settle()
    p.check("the refresh icon runs the same check the menu entry does",
            p.call_count("check") - before_check, 1)
    ev("root.checking = true")
    p.pump(50)
    p.check("a check in flight puts the spinner beside the control that started it",
            lev("refreshBusy.running"), True)
    # It used to take the button's PLACE. That read well and behaved badly: a control that leaves
    # the screen takes the keyboard with it, and Space on a Refresh nobody could see queued
    # another check behind the running one. It refuses in place instead, which says the same thing
    # to the eye and the truth to the keyboard. Where focus goes in that state is probe_focus.py's
    # subject; what this pins is that the button stays and the spinner is a separate item.
    p.check("...while the button stays on screen and refuses",
            [lev("refreshButton.visible"), lev("refreshButton.enabled")], [True, False])
    p.check("...the spinner being its own item, not this button's child",
            lev("refreshBusy.parent !== refreshButton"), True)
    ev("root.checking = false")
    p.pump(50)
    p.check("...and handing the button back when it is done",
            [lev("refreshButton.visible"), lev("refreshButton.enabled")], [True, True])

    # --- the primary action, and the row nobody can take away ----------------------------------------
    state(fixture("state-live.json"))
    p.check("with updates pending, Update Now is on screen", lev("updateButton.visible"), True)
    p.check("...under the icon Plasma uses for an update", lev("updateButton.icon.name"),
            "system-software-update")
    before_run = p.call_count("run")
    lev("updateButton.clicked()")
    p.wait_for(ev, "root.updating", True, timeout_ms=8000)
    settle()
    p.check("...and pressing it starts the run", p.call_count("run") - before_run, 1)
    p.check("...at which point it is gone, not disabled", lev("updateButton.visible"), False)
    ev("root.updating = false")
    p.pump(50)

    # The footer is the whole reason the primary action moved out of the heading row: the heading is
    # the row Plasma's contract lets the containment replace, and org.kde.plasma.vault gates its own
    # footer on exactly that hint. Copying vault verbatim would put Update Now back on the one piece
    # of ground Plasma reserves for itself (hig-review.md 3).
    lev("popup.traysHeading = true")
    p.check("a host that draws its own heading does not take the footer with it",
            lev("popup.footer.visible"), True)
    p.check("...nor the primary action inside it", lev("updateButton.visible"), True)
    lev("popup.traysHeading = false")
    p.check("the footer's tooltip is the absolute stamp people compare the relative one against",
            lev("footerToolTip.text"), ev("root.vm.footerTooltip"))

    # --- a run hides the stack, and that is the trap the close handler has to survive -----------------
    # Kirigami's close button hides its message by ASSIGNING visible = false, so the handler that
    # turns a close into dismissRestart() sees the same signal when an ancestor hides. A handler
    # that only asked "does the view model still want this?" would read a run starting as the user
    # closing the message, and an update would silently switch the reminder off for the session.
    state(fixture("state-reboot-needed.json"))
    ev("root.restartDismissed = false")
    p.check("the restart message is up before the run", lev("restartMessage.visible"), True)
    ev("root.updating = true")
    p.pump(50)
    p.check("...and a run in flight puts the whole message stack away",
            lev("restartMessage.visible"), False)
    ev("root.updating = false")
    p.pump(50)
    p.check("...without that being mistaken for the user closing it",
            ev("root.restartDismissed"), False)
    p.check("...so it is back when the run ends", lev("restartMessage.visible"), True)

    # --- closing the restart message ------------------------------------------------------------------
    # Kirigami's close button does exactly one thing:
    #     onClicked: root.visible = false
    # (/usr/lib64/qt6/qml/org/kde/kirigami/templates/InlineMessage.qml line 448), so driving that
    # assignment IS pressing the button. The assignment is also the hazard: assigning to a property
    # destroys the binding on it, and a message that did not intercept this would go away for good
    # and never come back when the machine's answer changed.
    p.check("the message offers a close button at all", lev("restartMessage.showCloseButton"), True)
    p.check("the footer is not repeating the fact while the message is on screen",
            "restart pending" in str(lev("footerLabel.text")), False)
    lev("restartMessage.visible = false")
    p.pump(50)
    p.check("closing the restart message tells main.qml rather than merely hiding an item",
            ev("root.restartDismissed"), True)
    p.check("...so it stays closed", lev("restartMessage.visible"), False)
    p.check("...and the footer picks the fact up instead, because the popup still must not lie",
            "restart pending" in str(lev("footerLabel.text")), True)
    ev("root.restartDismissed = false")
    p.pump(50)
    p.check("...and the message can come back at all, which the raw assignment would have prevented",
            lev("restartMessage.visible"), True)
    p.check("...with the footer quiet about it again",
            "restart pending" in str(lev("footerLabel.text")), False)

    # A prompt that could not be opened is said HERE, where the user pressed. Silence is the worst
    # outcome of all: a button that appears to do nothing looks exactly like one that did something
    # invisible.
    ev('root.restartError = "Could not open the restart prompt."')
    p.pump(50)
    p.check("a restart prompt that would not open says so inside the message itself",
            "Could not open the restart prompt." in str(lev("restartMessage.text")), True)
    p.check("...without losing the message's own sentence",
            "Restart to apply installed updates" in str(lev("restartMessage.text")), True)
    ev('root.restartError = ""')
    p.pump(50)
    p.check("...and the message is itself again once the error clears",
            lev("restartMessage.text"), "Restart to apply installed updates")

    dbus_before = len(records("dbus-send"))
    lev("restartMessage.actions[0].trigger()")
    settle()
    p.check("the message's own action is what opens KDE's prompt",
            len(records("dbus-send")) - dbus_before, 1)
    p.check("...labelled with a real ellipsis, KDE's mark for an action that opens something else",
            lev("restartMessage.actions[0].text"), ev("Logic.COPY.restartAction"))

    # --- the session-critical recommendation ----------------------------------------------------------
    state(fixture("state-risky-heavy.json"))
    p.check("the session-critical message says what to DO about it",
            lev("riskyMessage.text"), ev("root.vm.riskyMessage"))
    # Information, not Warning. Nothing is wrong: there is a safer of two ways to do this, and an
    # amber box above a button labelled Install on Next Restart read as an order to restart now
    # (hostile panel, first-run 3).
    p.check("...as Information, because nothing is broken - one path is safer than the other",
            lev("riskyMessage.type"), lev("Kirigami.MessageType.Information"))
    p.check("...in the sentence that recommends the button standing under it",
            lev("riskyMessage.text"),
            "This update includes a kernel. The safest way is to install it on the next restart,"
            " so nothing changes under the running desktop.")
    p.check("...never telling anybody to restart when something unnamed finishes",
            "Restart when it finishes" in str(lev("riskyMessage.text")), False)
    # Two restart-shaped buttons used to share `system-reboot` and sit adjacent, one opening KDE's
    # logout prompt and the other staging a transaction (hostile panel, M3).
    p.check("...under the icon for installing software, not the one for restarting a machine",
            lev("riskyMessage.actions[0].icon.name"), "system-software-update")
    p.check("...and not the count sentence as well, which for a kernel-free set is the same words",
            lev("riskyMessage.text") == ev("root.vm.riskySummary"), False)
    p.check("...offering the offline install under a name that is not dnf jargon",
            lev("riskyMessage.actions[0].text"), ev("Logic.COPY.installOnNextRestart"))
    p.check("...with the argument for choosing it in the tooltip",
            lev("riskyMessage.actions[0].tooltip"), ev("Logic.COPY.installOnNextRestartTooltip"))
    before_update = p.call_count("update")
    lev("riskyMessage.actions[0].trigger()")
    p.wait_for(ev, "root.updating", True, timeout_ms=8000)
    p.check("...and pressing it stages the update for the next restart",
            p.call_count("update") - before_update, 1)
    ev("root.leaveUpdating()")
    settle()
    ev('root.postRunLine = ""')

    # --- the stale explanation --------------------------------------------------------------------------
    state(fixture("state-stale.json"))
    p.check("staleness is not a message at all any more: the popup fits two, and this was the fifth",
            json.loads(str(lev("JSON.stringify(popup.messageSlots)"))), [])
    p.check("...the fact is on the footer's dateline",
            "last check failed" in str(lev("footerLabel.text")), True)
    p.check("...and the CLI's own reason, which is what a person has to act on, is one hover from "
            "the button that acts", "dnf check failed"
            in str(lev("refreshButton.PlasmaComponents.ToolTip.text")), True)

    # --- the post-run line -------------------------------------------------------------------------------
    state(fixture("state-live.json"))
    ev("root.loadLastRun()")
    settle()
    ev("root.postRunLine = Logic.postRunLine(root.lastRun)")
    p.pump(50)
    p.check("a run that worked reports as a positive message",
            lev("reportMessage.type"), lev("Kirigami.MessageType.Positive"))
    p.check("...saying what the run actually did", lev("reportMessage.text"),
            "Updated 4 packages in 2s")
    xdg_before = len(records("xdg-open"))
    lev("reportMessage.actions[0].trigger()")
    settle()
    p.check("...and its Show Log opens that run's own log", last_record("xdg-open"),
            [LAST_RUN["log"]])

    failed = dict(LAST_RUN)
    failed["status"] = "failed"
    failed["error"] = "dnf5 exited 1 - could not resolve the transaction"
    open(RUNJSON, "w").write(json.dumps(failed))
    ev("root.loadLastRun()")
    settle()
    ev("root.postRunLine = Logic.postRunLine(root.lastRun)")
    p.pump(50)
    p.check("a run that failed reports as an error instead",
            lev("reportMessage.type"), lev("Kirigami.MessageType.Error"))
    p.check("...in the CLI's own worked-out reason", lev("reportMessage.text"),
            "Update failed: dnf5 exited 1 - could not resolve the transaction")

    nolog = dict(LAST_RUN)
    nolog["log"] = ""
    open(RUNJSON, "w").write(json.dumps(nolog))
    ev("root.loadLastRun()")
    settle()
    ev("root.postRunLine = Logic.postRunLine(root.lastRun)")
    p.pump(50)
    p.check("a run old enough to have lost its log offers no Show Log to press",
            lev("reportMessage.actions[0].visible"), False)
    open(RUNJSON, "w").write(json.dumps(LAST_RUN))
    ev("root.loadLastRun()")
    settle()

    # --- the Last update row ------------------------------------------------------------------------------
    ev("root.postRunLine = Logic.postRunLine(root.lastRun)")
    p.pump(50)
    p.check("one event, one line: the persistent row stays off while the transient line is up",
            lev("lastRunView.visible"), False)
    ev('root.postRunLine = ""')
    p.pump(50)
    p.check("...and takes over the moment that clears", lev("lastRunView.visible"), True)
    p.check("...from inside a ListView, the only shape ExpandableListItem tolerates: it reads "
            "ListView.view in a BINDING, so a ColumnLayout would throw on the first frame",
            "ListView" in str(lev("String(lastRunView)")), True)

    # Nothing here has a window, so a ListView is never polished and lays nothing out. forceLayout()
    # is the documented way to make it build its items anyway.
    #
    # The message handler is a net rather than the guard. MEASURED 2026-08-26 by standing this
    # delegate outside a ListView on purpose: the probe reported no warning at all, because the
    # binding that reaches for ListView.view is only evaluated by a layout pass and there is none
    # here. So the wrong parent is caught by the structural assertion above, and this catches
    # everything ELSE a freshly built delegate can say - a binding loop, a type error, an undefined
    # property - none of which any ordinary assertion would notice.
    from PySide6.QtCore import qInstallMessageHandler                  # noqa: E402
    _noise = []
    qInstallMessageHandler(lambda mode, ctx, msg: _noise.append(msg))
    lev("lastRunView.width = 400; lastRunView.height = 200; lastRunView.forceLayout()")
    p.pump(100)
    _built = lev("lastRunView.itemAtIndex(0) !== null")
    qInstallMessageHandler(None)
    p.check("the row is really built", _built, True)
    p.check("...saying nothing at all on the way, warnings included", _noise, [])
    p.check("...titled by logic.js rather than by a second copy of that rule written here",
            lev("lastRunView.itemAtIndex(0).title"),
            ev("Logic.lastRunText(root.lastRun, root.nowMs)"))
    p.check("...and expandable, so the run's package list is one click away",
            lev("lastRunView.itemAtIndex(0).hasExpandableContent"), True)
    p.check("...with that run's own log reachable from the row",
            lev("lastRunView.itemAtIndex(0).contextualActions[0].text"), ev("Logic.COPY.showLog"))
    p.check("...and the packages it installed under it",
            lev("lastRunView.itemAtIndex(0).customExpandedViewContent !== null"), True)

    ev("root.lastRun = null")
    p.pump(50)
    p.check("a box that has never updated shows no Last update row rather than an empty one",
            lev("lastRunView.visible"), False)
    ev("root.loadLastRun()")
    settle()

    # --- the rows themselves --------------------------------------------------------------------------------
    # The delegates are built directly rather than scrolled into view: with no window the main list
    # is never laid out either, and building the real delegate from a real model row is the same
    # code path with the geometry left out.
    def row(model, expr):
        # `index` is handed over as well as `modelData`: the delegate declares both as required
        # (the row scrolls itself into view when its pin takes focus, and needs to know which row
        # it is), and a required property left unset is a delegate that will not build at all.
        return lev('(function () {'
                   ' var loader = rowsView.delegate.createObject('
                   '     rowsView, {"modelData": %s, "index": 0});'
                   ' if (loader === null) return "THE DELEGATE WOULD NOT BUILD";'
                   ' var it = loader.item;'
                   ' if (it === null) return "THE DELEGATE LOADED NOTHING";'
                   ' var answer = (%s);'
                   ' loader.destroy();'
                   ' return answer; })()' % (json.dumps(model), expr))

    def labelled(predicate):
        """The first descendant whose `text` satisfies `predicate` (written against `o`)."""
        return ('(function walk(o) {'
                ' if (o.text !== undefined && (%s)) return o;'
                ' for (var i = 0; i < o.children.length; i++) {'
                '  var hit = walk(o.children[i]); if (hit !== null) return hit; }'
                ' return null; })(it)' % predicate)

    # The heading is wrapped now: a ColumnLayout carrying Plasma's own section header and, under
    # the Held one only, the line that tells a dnf user a hold is Kempt's own list.
    SECTION = ('(function find(o) {'
               ' if (o.label !== undefined && String(o.label) !== "") return o;'
               ' for (var i = 0; i < o.children.length; i++) {'
               '  var hit = find(o.children[i]); if (hit !== null) return hit; }'
               ' return null; })(it)')
    HEADER_ROW = {"kind": "header", "title": "System (dnf)", "held": False}
    HELD_HEADER_ROW = {"kind": "header", "title": "Held", "held": True}
    p.check("a group header is Plasma's own ListSectionHeader, not a bare Heading",
            row(HEADER_ROW, 'String(%s).indexOf("ListSectionHeader") >= 0' % SECTION), True)
    p.check("...carrying the group's name in the property that component documents",
            row(HEADER_ROW, "(%s).label" % SECTION), "System (dnf)")
    p.check("...and handing that name to a screen reader, which the component itself refuses to "
            "do: Kirigami marks its own label Accessible.ignored",
            row(HEADER_ROW, "(%s).Accessible.name" % SECTION), "System (dnf)")
    p.check("...as a heading, which is what a screen reader navigates a list by",
            row(HEADER_ROW, "(%s).Accessible.role === Accessible.Heading" % SECTION), True)
    # The extra line, and where it must NOT be. A backend section that grew it would be telling a
    # person their pending updates are skipped.
    KEMPT_ONLY = ('(function find(o) {'
                  ' if (o.text !== undefined'
                  '     && String(o.text) === "Held packages are skipped by Kempt only.")'
                  '   return o.visible;'
                  ' for (var i = 0; i < o.children.length; i++) {'
                  '  var hit = find(o.children[i]); if (hit !== null) return hit; }'
                  ' return null; })(it)')
    p.check("the Held heading carries the line that says a hold is Kempt's own list",
            row(HELD_HEADER_ROW, KEMPT_ONLY), True)
    p.check("...and a backend section does not, because its rows are not skipped at all",
            row(HEADER_ROW, KEMPT_ONLY), False)

    # What a power user compares between two machines: the epoch, the release and the vendor tag all
    # carry meaning, and eliding the tail throws away exactly the half that differs.
    FROM = "2:24.19.0-1nodesource"
    TO = "2:24.20.0-1nodesource"
    ITEM_ROW = {"kind": "item", "name": "nodejs", "from": FROM, "to": TO,
                "held": False, "backend": "dnf"}
    version = labelled('String(o.text).indexOf("1nodesource") >= 0')
    name = labelled('String(o.text) === "nodejs"')
    p.check("a full version string with an epoch and a vendor tag reaches the row untouched",
            row(ITEM_ROW, "(%s).text" % version), FROM + " → " + TO)
    p.check("...and is never elided, whatever the popup's width",
            row(ITEM_ROW, "(%s).elide === Text.ElideNone" % version), True)
    p.check("...wrapping instead, which is what makes that possible",
            row(ITEM_ROW, "(%s).wrapMode !== Text.NoWrap" % version), True)
    p.check("...while the package name still elides, so a long one cannot push the pin off the row",
            row(ITEM_ROW, "(%s).elide === Text.ElideRight" % name), True)

    # A package that is not installed yet. The CLI writes "?" for its current version and the row
    # drew "? → 9.9.9-1.fc44", which reads as "the widget does not know" (hostile panel, first-run
    # and a11y S4). The DATA keeps the sentinel; the row draws the word.
    NEW_ROW = {"kind": "item", "name": "brandnew", "from": "?", "to": "1.0-1.fc44",
               "held": False, "backend": "dnf"}
    new_version = labelled('String(o.text).indexOf("1.0-1.fc44") >= 0')
    p.check("a package with no current version reads as new rather than as a question mark",
            row(NEW_ROW, "(%s).text" % new_version), "new → 1.0-1.fc44")
    p.check("...and says the same thing to a screen reader",
            row(NEW_ROW, "(%s).Accessible.name" % new_version), "from new to 1.0-1.fc44")
    # ...and its padlock offers the only thing a hold can mean there: do not install it at all.
    new_pin = labelled('String(o.text).indexOf("brandnew") >= 0'
                       ' && o.animateClick !== undefined')
    p.check("...while the padlock offers a refusal to install rather than a hold at no version",
            row(NEW_ROW, "(%s).text" % new_pin), "Skip installing brandnew")

# The two pins that keep the drivable seam honest: a `traysHeading` that stopped being computed
# from the containment's hint, or a gear whose visibility stopped being that property, would leave
# every assertion above passing.
_src = " ".join(open(os.path.join(harness.UI, "FullRepresentation.qml")).read().split())


def _code(name):
    """One .qml file with its comments removed, on one line.

    The counting pins below are about what the popup EVALUATES, and these files are unusually
    heavily commented - the prose explains why the containment hint is consulted exactly once, and
    naming it there would make the pin count two. Nothing under plasmoid/contents/ui/ has a `//`
    inside a string literal, so cutting each line at the first one is enough.
    """
    lines = [ln.split("//")[0] for ln in open(os.path.join(harness.UI, name))]
    return " ".join(" ".join(lines).split())


_code_src = _code("FullRepresentation.qml")
p.check("traysHeading is computed from the containment's own display hint",
        "property bool traysHeading: (Plasmoid.containmentDisplayHints"
        " & PlasmaCore.Types.ContainmentDrawsPlasmoidHeading) !== 0" in _src, True)
p.check("...and the gear's visibility is that property and nothing else",
        "visible: !popup.traysHeading" in _src, True)
p.check("...while the refresh icon's is that property AND the claim, never the hint on its own",
        "visible: !(popup.traysHeading && popup.plasmoidItem.contextualActionsClaimed)" in _src,
        True)

# ...and that the footer never learns the same trick. org.kde.plasma.vault gates its footer on the
# containment hint, and copying it verbatim would put the primary action back on the one row
# Plasma's contract lets the host replace - the exact bug moving it here exists to prevent
# (hig-review.md 3). Counted rather than searched, because "the string is not next to the word
# footer" is a pin that a reformatting would satisfy.
#
# TWO readers, and the number is the assertion: the gear and the refresh icon, which are the two
# controls the tray's own heading genuinely draws. A third would mean something else had started
# letting a host take it away, and the footer is where that would hurt.
p.check("the containment hint is consulted exactly once in the whole popup",
        _code_src.count("ContainmentDrawsPlasmoidHeading"), 1)
p.check("...and the answer it computes is read exactly twice, by the gear and the refresh icon - "
        "so the footer and the button in it cannot be taken away by a host",
        _code_src.count("popup.traysHeading"), 2)

# The group header's property. `label` is what ListSectionHeader documents and what its own example
# uses; the pin is here because this is a one-word seam that a reviewer cannot see from the popup.
p.check("the group header sets the property ListSectionHeader documents, and the two the "
        "component itself refuses to expose",
        "PlasmaExtras.ListSectionHeader { Layout.fillWidth: true label: modelData.title"
        " Accessible.role: Accessible.Heading Accessible.name: modelData.title }"
        in _code_src, True)
# ...and decides which heading gets the Kempt-only line from the ROW's own flag, never from its
# title: the title is a string a translator will change, and a comparison against the literal
# "Held" would silently stop matching in every other language.
p.check("...and the Held line is gated on the row's flag rather than on the word Held",
        "visible: modelData.held === true" in _code_src, True)

# Founder amendment A1: the message a person can turn off must also be one they can close.
p.check("the restart message carries a close button", "showCloseButton: true" in _src, True)

# Geometry, which nothing in this file can measure: with no window the popup is never laid out. The
# ceiling matters anyway - the expanded history row would otherwise be two hundred packages tall
# and would squeeze the pending list out of the popup entirely - so it is pinned where it lives.
p.check("the Last update row cannot grow past half the popup",
        "Layout.maximumHeight: Math.round(popup.height / 2)" in _code_src, True)
p.check("...and scrolls within that rather than clipping what it cannot show",
        "interactive: contentHeight > height" in _code_src, True)

# --- the copy table is the specification, and the QML has to repeat it verbatim ---------------------
# logic.js's COPY is where the wording is decided and node-tested, but the QML cannot READ it:
# translation extraction works on literals, and `i18n(Logic.COPY.updateNow)` extracts nothing at all
# and ships an untranslatable widget. So the QML writes the same literal, and this is what stops the
# two drifting.
#
# Only the LABEL entries are pinned. The rest are ingredients logic.js assembles its own sentences
# from - they reach the popup through the view model as DATA, and a QML file that wrote them as
# literals would be the second copy this arrangement exists to prevent. Every key must be in one
# bucket or the other, so a new entry cannot slip in unclassified.
_QML_SRC = ""
for _name in sorted(os.listdir(harness.UI)):
    if _name.endswith(".qml"):
        _QML_SRC += " " + " ".join(open(os.path.join(harness.UI, _name)).read().split())

# ...and the third bucket, which is neither: a sentence with a name in it that the QML substitutes
# itself. `i18n("Holding %1", name)` is one translatable unit with an argument, so the literal a
# translator extracts ends at the comma rather than at the closing bracket - which is the only
# thing that makes these different from the labels below.
_SUBSTITUTED_IN_QML = {
    "holdAnnounce",         # -> popup.announce, when a hold has landed
    "unholdAnnounce",       # -> popup.announce, when one has been lifted
    "holdAt",               # -> the padlock's name and tooltip on a pending row
    "stopHolding",          # -> ...on a held one, and the settings page's remove button
    "skipInstalling",       # -> ...on a row whose package is not installed yet
    "stopSkipping",         # -> ...and its way out
    "versionRange",         # -> the version line's accessible name
}

_ASSEMBLED_IN_LOGIC = {
    "upToDate",             # -> countPhrase -> vm.headerText
    "everythingUpToDate",   # -> vm.emptyStateText
    "restartFailed",        # -> root.restartError, rendered inside the restart message
    "kernelRestart",        # -> riskyMessageOf -> vm.riskyMessage
    "kernelNvidiaRestart",  # -> riskyMessageOf -> vm.riskyMessage
    "riskySessionOne",      # -> riskyMessageOf -> vm.riskyMessage (the family list goes in)
    "riskySessionMore",     # -> riskyMessageOf -> vm.riskyMessage (a count and the family list)
    "held",                 # -> vm.footerText and vm.tooltipSub
    "restartPending",       # -> vm.footerText
    "noSuccessfulCheckYet",  # -> vm.footerText
    "lastCheckFailed",      # -> vm.footerText, beside the date it explains
    "noPackageChanges",     # -> postRunLine
    "updateFailed",         # -> postRunLine
    "stagedTail",           # -> stagedMessageOf -> vm.stagedMessage
    "stagedOne",            # -> stagedMessageOf -> vm.stagedMessage
    "stagedUnknownCount",   # -> stagedMessageOf -> vm.stagedMessage
    "stagedHeaderOne",      # -> stagedHeaderOf -> vm.headerText and vm.tooltipMain
    "stagedHeaderTail",     # -> stagedHeaderOf -> vm.headerText and vm.tooltipMain
    "stagedHeaderUnknown",  # -> stagedHeaderOf -> vm.headerText and vm.tooltipMain
    "stagedConflictOne",    # -> stagedVariantOf -> vm.stagedMessage (a name goes into the %1)
    "stagedConflictMore",   # -> stagedVariantOf -> vm.stagedMessage (a name and a count)
    "stagedConflictUnknown",  # -> stagedVariantOf -> vm.stagedMessage
    "stagedRebuildCost",    # -> stagedVariantOf, joined onto every warning as its second sentence
    "stagedChanged",        # -> root.actionMessage, the same way restartFailed is assigned
    "holdFailed",           # -> root.holdError.text, assigned by main.qml with the name filled in
    "engineMissing",        # -> vm.engineMissingMessage, and vm.tooltipSub on its own
    "engineMissingCopy",    # -> vm.engineMissingCopyText: a clipboard payload of shell commands,
                            #    bound as data - and never a translatable unit at all
    "engineMissingInstall",  # -> vm.engineMissingMessage
}
_COPY = json.loads(str(ev("JSON.stringify(Logic.COPY)")))
p.check("every string said to be assembled in logic.js is still in the copy table",
        sorted(k for k in _ASSEMBLED_IN_LOGIC if k not in _COPY), [])
for _key in sorted(_COPY):
    if _key in _ASSEMBLED_IN_LOGIC:
        continue
    if _key in _SUBSTITUTED_IN_QML:
        p.check("the widget writes the agreed `%s` as a literal with its argument after it" % _key,
                'i18n("%s", ' % _COPY[_key] in _QML_SRC, True)
        continue
    p.check("the widget writes the agreed `%s` as a literal a translator can extract" % _key,
            'i18n("%s")' % _COPY[_key] in _QML_SRC, True)

sys.exit(p.done())
