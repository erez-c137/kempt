#!/usr/bin/env python3
"""The restart message: asking for the prompt, and what the popup remembers about it.

Adopted from the 2026-08-27 review's probe_review.py (findings 3 and 6), kept as the sequences
they were found by.

The restart prompt is the one action in this widget with no work behind it: `dbus-send` returns as
soon as KDE has been ASKED to draw its confirmation screen. It takes no lock, touches no package
database, and finishes in milliseconds. Queued behind a `kempt check` it can still sit unsent for
up to two minutes with nothing on screen to say why - the user presses Restart..., the popup does
not react, and the only honest reading of that is that the button is broken.

`dbus-send` is shadowed on PATH so nothing here can reach a real session: on this box the real one
would open the founder's logout screen.
"""
import json
import os
import sys
import time

import harness

if not harness.have_pyside():
    print("ok: SKIPPED - PySide6 absent")
    sys.exit(0)

p = harness.Probe("probe-restart")
os.makedirs(os.path.join(p.state, "logs"))
os.makedirs(p.config)
STATE_JSON = os.path.join(p.state, "state.json")
CHECKSRC = os.path.join(p.sandbox, "checksrc")
RUNJSON = os.path.join(p.sandbox, "runjson")
SLEEP = os.path.join(p.sandbox, "checksleep")
open(SLEEP, "w").write("0")
open(CHECKSRC, "w").write(os.path.join(harness.FIXTURES, "state-reboot-needed.json"))
open(RUNJSON, "w").write(
    json.dumps(json.load(open(os.path.join(harness.FIXTURES, "run-last.json")))))

os.environ["PATH"] = p.bindir + os.pathsep + os.environ["PATH"]
DBUSRC = os.path.join(p.sandbox, "dbusrc")
open(DBUSRC, "w").write("0")

# A recorder rather than a bare `exit 0`: what is under test is WHEN the call happens, so each
# invocation stamps the wall clock next to its arguments.
_dbus = os.path.join(p.bindir, "dbus-send")
with open(_dbus, "w") as fh:
    fh.write("#!/usr/bin/env bash\n"
             "date +%s.%N >> " + p.sandbox + "/dbus.times\n"
             "printf '%s\\n' \"$@\" >> " + p.sandbox + "/dbus.calls\n"
             "printf -- '--\\n' >> " + p.sandbox + "/dbus.calls\n"
             "exit \"$(cat " + DBUSRC + ")\"\n")
os.chmod(_dbus, 0o755)


def dbus_calls():
    path = os.path.join(p.sandbox, "dbus.calls")
    if not os.path.exists(path):
        return []
    return [c.split("\n")[:-1] for c in open(path).read().split("--\n") if c != ""]


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
    p.wait_for(ev, "root.checking || root.holdInFlight", False, timeout_ms=30000)
    p.wait_idle(ev, "executor", "tailExecutor", "promptExecutor", timeout_ms=30000)


settle()

# ==================================================================================================
# F3. Restart... while the action queue is busy with a check
# ==================================================================================================
# 6 seconds here; the real check is allowed 120. The queue is strictly first-in-first-out, so on
# the shared executor the prompt could not be asked for until the whole check had finished.
open(SLEEP, "w").write("6")
ev("root.doCheck()")
p.pump(300)
p.check("a check is in flight and holding the action queue",
        [ev("root.checking"), ev("executor.current !== null")], [True, True])

before = len(dbus_calls())
t0 = time.time()
ev("root.promptRestart()")
# No pump: this is the same tick. Executor.run pushes and pumps synchronously, so a command that
# was DISPATCHED has already left the queue and is `current`, and one that was merely queued has
# not. That distinction is the whole finding, and it is measurable without waiting for anything.
p.check("the prompt is dispatched in the same tick, not queued behind the check",
        [ev("promptExecutor.current !== null"), ev("promptExecutor.queue.length")], [True, 0])
p.check("...on an executor of its own, leaving the check where it was",
        [ev("executor.current !== null"), ev("executor.queue.length")], [True, 0])

for _ in range(40):
    if len(dbus_calls()) - before > 0:
        break
    p.pump(50)
elapsed = time.time() - t0
p.check("KDE's prompt really is asked for, while the check is still running",
        [len(dbus_calls()) - before, ev("root.checking")], [1, True])
p.check("...in under a second rather than behind a two-minute check", elapsed < 2.0, True)
p.check("...with the argument list that opens a CANCELLABLE prompt",
        dbus_calls()[-1] if dbus_calls() else [],
        ["--session", "--dest=org.kde.LogoutPrompt", "--type=method_call",
         "/LogoutPrompt", "org.kde.LogoutPrompt.promptReboot"])
p.check("...and the popup has nothing to apologise for", ev("root.restartError"), "")

open(SLEEP, "w").write("0")
settle()

# The queue it does NOT share is the log tail's either: a run showing its log in the popup tails
# it every two seconds, and a prompt waiting behind one of those would be the same bug in miniature.
p.check("the prompt executor is its own instance, not the tail's",
        ev("promptExecutor !== tailExecutor && promptExecutor !== executor"), True)

# ==================================================================================================
# Unverified #6. a prompt that would not open leaves a message with no way out
# ==================================================================================================
# restartError is the popup's own report of a Restart... that failed, shown inside the restart
# message where the user pressed. Nothing ever cleared it except a LATER successful press, so an
# apology for a prompt that failed once sat inside the message for the rest of the plasmashell
# session - over a box that had since been checked twice and might not owe a restart at all.
# Same rule as the transient post-run line above it: an event has its moment, and the next event
# ends it.
open(DBUSRC, "w").write("1")
ev("root.promptRestart()")
settle()
p.check("a prompt that will not open says so", ev("root.restartError"),
        ev("Logic.COPY.restartFailed"))
ev("root.popupClosed()")
p.check("...and closing the popup retires that apology, like every other transient line",
        ev("root.restartError"), "")

ev("root.promptRestart()")
settle()
p.check("the apology comes back if it fails again", ev("root.restartError") != "", True)
ev("root.doCheck()")
p.check("...and a new check clears it too, before its answer even arrives",
        ev("root.restartError"), "")
settle()

open(DBUSRC, "w").write("0")
ev("root.promptRestart()")
settle()
p.check("a prompt that DOES open leaves nothing to apologise for", ev("root.restartError"), "")

sys.exit(p.done())
