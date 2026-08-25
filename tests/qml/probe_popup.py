#!/usr/bin/env python3
"""The popup's actions and the watcher that ends a run (Tasks W3 + the W4 review's B-5).

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
"""
import os
import shutil
import subprocess
import sys

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
open(RUNRC, "w").write("0")
open(AUTO, "w").write("true\n")

p.stub("""
case "$1" in
  config) [[ "$3" == refresh_interval_min ]] && echo 15; [[ "$3" == surface ]] && echo popup
          [[ "$3" == auto_accept ]] && cat %(AUTO)s; exit 0 ;;
  check)  cp %(FIX)s/state-live.json %(ST)s; cat %(ST)s; exit 0 ;;
  run)    rc="$(cat %(RUNRC)s)"
          [[ "$rc" == 0 ]] || { echo "konsole not found - install it or run: kempt config set surface background" >&2; exit "$rc"; }
          exit 0 ;;
  update) exit 0 ;;
  hold|unhold) exit 0 ;;
  summary) echo "Kempt - 2026-08-25T01:00:00 (terminal, 42s) ok"; echo "more detail"; exit 0 ;;
esac
""" % {"AUTO": AUTO, "FIX": harness.FIXTURES, "ST": STATE_JSON, "RUNRC": RUNRC})

root, ev = p.create("main.qml")
p.wait_for(ev, "root.kemptState !== null", True)


def settle():
    p.wait_for(ev, "root.checking || root.holdInFlight", False, timeout_ms=15000)
    p.wait_idle(ev, "executor", "tailExecutor")


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
p.check("...and the pins are live again", ev("root.holdInFlight"), False)

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
rebaseline()
before_check = p.call_count("check")
shutil.copy(os.path.join(harness.FIXTURES, "state-live.json"), STATE_JSON)
harness.touch(STATE_JSON, "2031-01-01")
poll(True)
p.wait_for(ev, "root.updating", False, timeout_ms=8000)
p.check("the CLI writing state.json DOES end the run", ev("root.updating"), False)
settle()
p.check("...and that is what earns a fresh check", p.call_count("check") > before_check, True)
p.wait_for(ev, 'root.actionMessage !== ""', True, timeout_ms=6000)
p.check("...and one line about what the run did",
        ev("root.actionMessage"), "Kempt - 2026-08-25T01:00:00 (terminal, 42s) ok")

# With no run in flight the watcher is exactly what it always was: any package change is a reason
# to look, which is the stale-badge killer the whole poll exists for.
p.check("no run is in flight now", ev("root.updating"), False)
rebaseline()
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

sys.exit(p.done())
