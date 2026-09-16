#!/usr/bin/env python3
"""Run ONE QML probe, serially, and guarantee nothing survives it.

Why this exists: an earlier version of these probes was driven by `subprocess.run()` with no
timeout and by a bare `timeout 300` (SIGTERM, no -k). Neither can kill a Qt process wedged in
teardown, so every wedged probe stayed resident and every retry of the battery added more. One
afternoon that reached ~2,200 Qt processes and took production down with it.

What this does instead:
  * refuses to start if the box is already carrying probe processes (count guard, before AND after)
  * runs the probe in its OWN process group, so the kill reaches the shells the QML spawned too
  * SIGKILLs (never SIGTERMs) the whole group on timeout, then reaps
  * arms the in-process watchdog in _safe/sitecustomize.py, which fires FIRST - the probe
    self-terminates and this supervisor is only the backstop

    safe_probe.py <secs> <cmd...>

Exit codes: the probe's own, or 4 if it had to be killed, or 3/4 for the count guards.
"""
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
# How many probe processes may already be resident before this refuses to add another. It counts
# THIS supervisor too, so the floor is 1. Deliberately not a census of python3 on the box: that
# number says nothing about this battery on a machine that runs other things, and an absolute
# ceiling of 10 python3 meant a busy box refused to run the tests for no reason.
CEILING = 3


def pycount():
    """How many python3 are resident. Read from /proc, NOT from `ps`.

    This census is the guard that exists because a probe battery once reached ~2,200 Qt
    processes and OOM-killed production. It used to shell out to `ps`, which is procps-ng and
    is absent from a minimal Fedora image and from Fedora's build root: there the subprocess
    raised OSError for the missing binary, that exception escaped, and the battery reported
    that no probe processes had survived - a safety guard failing OPEN, in the one place
    that must not. /proc is always there on Linux and needs no package at all.

    Counting OUR probes by name rather than every python3 on the box. The old form matched a
    line beginning "python3", which missed a probe started as /usr/bin/python3 and counted
    unrelated python3 services as if they were leaked probes - on a box that runs other things
    that is noise in both directions, and this census only means anything if it is exact.
    """
    n = 0
    try:
        entries = os.listdir("/proc")
    except OSError as exc:
        raise SystemExit("REFUSING TO RUN: cannot read /proc, so the process census "
                         "that keeps this battery from filling the machine is not "
                         "available (%s)" % exc)
    for pid in entries:
        if not pid.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % pid, "rb") as fh:
                cmdline = fh.read()
        except OSError:
            continue                       # it exited while we looked; not ours to count
        # The WHOLE command line, never argv[0] alone. A probe is started as
        # `python3 /path/probe_x.py`, so argv[0] is the string "python3" and the probe's name is
        # in argv[1]: reading only argv[0] made this census answer 0 on every box, every time,
        # while printing that number as though it had counted something. The census is the guard
        # that exists because a battery once reached ~2,200 Qt processes, and it was failing open.
        # tests/test_widget_qml.sh's own pycount reads the whole line, which is the shape to match.
        if b"probe_" in cmdline or b"safe_probe" in cmdline:
            n += 1
    return n


def main():
    secs = float(sys.argv[1])
    cmd = sys.argv[2:]

    before = pycount()
    if before > CEILING:
        print("REFUSING TO RUN: %d probe process(es) already resident (ceiling %d) - something "
              "from an earlier run did not die" % (before, CEILING))
        return 3

    env = dict(os.environ)
    env["PYTHONPATH"] = os.path.join(HERE, "_safe") + os.pathsep + env.get("PYTHONPATH", "")
    env["PROBE_WATCHDOG_SECS"] = str(secs)          # the probe kills itself first
    env["PROBE_EXIT_SECS"] = "10"
    env["QT_QPA_PLATFORM"] = "offscreen"
    # Everything the probe creates lands under a directory THIS process owns, and this process
    # removes it once the whole group is gone. harness.Probe already deletes its own sandbox when
    # the probe finishes, and that is not enough: Plasma's icon cache writes into the probe's
    # $HOME again during Qt teardown, which happens AFTER that delete, so every battery left a
    # /tmp/kempt-probe-* directory behind holding a `.cache/ksvg-elements`. A cleanup can only be
    # reliable in a process that outlives the one making the mess.
    workdir = tempfile.mkdtemp(prefix="kempt-probe-run.")
    env["TMPDIR"] = workdir

    t0 = time.time()
    p = subprocess.Popen(cmd, cwd=HERE, env=env, start_new_session=True,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    killed = False
    try:
        out, _ = p.communicate(timeout=secs + 20)   # backstop: 20s past the in-probe watchdog
    except subprocess.TimeoutExpired:
        killed = True
        os.killpg(p.pid, signal.SIGKILL)
        try:
            out, _ = p.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            out = "(supervisor could not even reap it)"
    dt = time.time() - t0

    # Whatever the outcome, the process GROUP must be gone: the QML executor spawns real shells.
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    # Only now: while anything in that group still breathes it can write here again.
    shutil.rmtree(workdir, ignore_errors=True)

    print(out, end="" if out.endswith("\n") else "\n")
    after = pycount()
    print("--- safe_probe: rc=%s killed=%s %.1fs  probe procs before=%d after=%d ---"
          % (p.returncode, killed, dt, before, after))
    # A DELTA against what this run started with, not against an absolute number: the question is
    # whether THIS probe left anything behind, and an absolute ceiling answers a different one.
    if after > before:
        print("!!! LEAK: %d probe process(es) survived this run (%d -> %d) - STOP AND FIX"
              % (after - before, before, after))
        return 4
    return 4 if killed else (p.returncode or 0)


if __name__ == "__main__":
    sys.exit(main())
