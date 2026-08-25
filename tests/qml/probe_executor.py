#!/usr/bin/env python3
"""Executor.qml: the one component every command in the widget goes through.

The whole widget's safety rests on this file behaving: serialized, always async, hard per-call
timeout. A regression here does not look like a bug, it looks like plasmashell freezing - which is
the failure that made Apdatifier notorious and the reason this component exists at all.
"""
import sys

import harness

if not harness.have_pyside():
    print("ok: SKIPPED - PySide6 absent")
    sys.exit(0)

p = harness.Probe("probe-executor")

HOST = """
import QtQuick
Item {
    id: host
    property var log: []
    property int finished: 0
    property string order: ""
    property var results: ({})

    Executor { id: ex }

    function go() {
        ex.run("echo hello-from-executor", 5000, function (out, err, rc) {
            host.results.out1 = out; host.results.err1 = err; host.results.rc1 = rc;
            host.order += "a"; host.finished++;
        });
        // stdout AND a non-zero exit: the widget's answer-first contract needs both to survive.
        ex.run("printf to-stdout; exit 7", 5000, function (out, err, rc) {
            host.results.out2 = out; host.results.rc2 = rc;
            host.order += "b"; host.finished++;
        });
        // Longer than its own timeout. The kill timer must report it, not hang the queue.
        ex.run("sleep 30", 400, function (out, err, rc) {
            host.results.rc3 = rc; host.results.err3 = err;
            host.order += "c"; host.finished++;
        });
    }
    // Two runs of the SAME command string. The executable DataSource de-duplicates identical
    // sources, so without the per-job tag the second one would never come back at all.
    function twice() {
        ex.run("echo same", 5000, function () { host.order += "d"; host.finished++; });
        ex.run("echo same", 5000, function () { host.order += "e"; host.finished++; });
    }
}
"""

host, ev = p.create_inline(HOST, "executor-host.qml")
ev("host.go()")
p.wait_for(ev, "host.finished", 3, timeout_ms=15000)

p.check("every job comes back exactly once", ev("host.finished"), 3)
p.check("...in the order they were queued, never overlapping", ev("host.order"), "abc")
p.check("a command's stdout reaches its callback", ev("host.results.out1"), "hello-from-executor\n")
p.check("...with its exit code", ev("host.results.rc1"), 0)
p.check("stdout survives a NON-ZERO exit (the answer-first contract)",
        ev("host.results.out2"), "to-stdout")
p.check("...and the exit code is reported as it was", ev("host.results.rc2"), 7)
p.check("a job past its timeout is reported, not left hanging", ev("host.results.rc3"), 124)
p.check("...saying so in its stderr", ev("host.results.err3"), "timeout after 400ms")

ev("host.twice()")
p.wait_for(ev, "host.finished", 5, timeout_ms=15000)
p.check("two identical commands both come back - the per-job tag defeats DataSource dedup",
        ev("host.order"), "abcde")
p.check("...and the queue is empty afterwards", ev("ex.current === null && ex.queue.length === 0"), True)

sys.exit(p.done())
