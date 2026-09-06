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
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CEILING = 10  # more python3 than this already on the box and we are not adding to it


def pycount():
    """How many python3 are resident. Read from /proc, NOT from `ps`.

    This census is the guard that exists because a probe battery once reached ~2,200 Qt
    processes and OOM-killed production. It used to shell out to `ps`, which is procps-ng and
    is absent from a minimal Fedora image and from Fedora's build root: there the subprocess
    raised FileNotFoundError, the exception escaped, and the battery reported that no probe
    processes had survived - a safety guard failing OPEN, in the one place that must not.
    /proc is always there on Linux and needs no package at all.

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
                argv0 = fh.read().split(b"\0", 1)[0]
        except OSError:
            continue                       # it exited while we looked; not ours to count
        if b"probe_" in argv0 or b"safe_probe" in argv0:
            n += 1
    return n


def main():
    secs = float(sys.argv[1])
    cmd = sys.argv[2:]

    before = pycount()
    if before > CEILING:
        print("REFUSING TO RUN: %d python3 already resident (ceiling %d)" % (before, CEILING))
        return 3

    env = dict(os.environ)
    env["PYTHONPATH"] = os.path.join(HERE, "_safe") + os.pathsep + env.get("PYTHONPATH", "")
    env["PROBE_WATCHDOG_SECS"] = str(secs)          # the probe kills itself first
    env["PROBE_EXIT_SECS"] = "10"
    env["QT_QPA_PLATFORM"] = "offscreen"

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

    print(out, end="" if out.endswith("\n") else "\n")
    after = pycount()
    print("--- safe_probe: rc=%s killed=%s %.1fs  python3 before=%d after=%d ---"
          % (p.returncode, killed, dt, before, after))
    if after > CEILING:
        print("!!! LEAK: python3 count above the ceiling after the run - STOP AND FIX")
        return 4
    return 4 if killed else (p.returncode or 0)


if __name__ == "__main__":
    sys.exit(main())
