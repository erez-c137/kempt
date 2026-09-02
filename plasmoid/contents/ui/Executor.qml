// The ONE place commands run. Serialized queue, hard per-call timeout, always async.
// Wraps the deprecated Plasma5Support executable engine (swap point when KDE drops it).
//
// WHAT THE ENGINE ACTUALLY STARTS, and what the timeout can therefore reach. The executable
// engine hands the whole string to `/bin/sh -c "<cmd> <tag>"` through a KProcess it owns. Both
// ways a job can end early - killTimer below, and the engine dropping an unused container when
// this Item is destroyed - end with that KProcess being deleted, and its destructor SIGKILLs the
// `sh` PARENT. Nothing signals the process tree underneath it.
//
// For an ordinary command that does not matter: `sh -c 'kempt check'` execs kempt in place, so
// the pid the kill reaches IS kempt. But a command written in the durable form the settings page
// uses - `<cmd> & wait $!` - forks the real work into a background job and leaves `sh` doing
// nothing but waiting for it. Killing that `sh` ends the WAIT, not the job: the job runs to
// completion on its own, and `wait $!` had already been chosen so that, in the normal case, the
// job's real exit status is what this component reports.
//
// That trade is right for a `kempt config set` (about 10 ms of work, and losing the write is the
// bug the form exists to fix - see configGeneral.qml's page.durable) and WRONG for `kempt check`
// or `kempt run`. Those are the commands the timeout exists for: a wedged check must actually
// die when the kill timer fires, not carry on unwatched inside plasmashell's process group. So
// the durable form is applied by the caller, one command at a time, and never here.
import QtQuick
import org.kde.plasma.plasma5support as Plasma5Support

Item {
    id: root
    property int defaultTimeoutMs: 30000

    // run("kempt check", 120000, function(stdout, stderr, rc) {...})
    function run(cmd, timeoutMs, callback) {
        queue.push({ cmd: cmd, timeoutMs: timeoutMs || defaultTimeoutMs, callback: callback,
                     tag: "#kempt" + (++serial) });
        pump();
    }

    property var queue: []
    property var current: null
    property int serial: 0

    function pump() {
        if (current || queue.length === 0) return;
        current = queue.shift();
        // unique trailing comment defeats DataSource's same-source dedup
        current.source = current.cmd + " " + current.tag;
        killTimer.interval = current.timeoutMs;
        killTimer.restart();
        engine.connectSource(current.source);
    }

    function finish(stdout, stderr, rc) {
        killTimer.stop();
        var job = current; current = null;
        if (job && job.callback) job.callback(stdout || "", stderr || "", rc);
        pump();
    }

    Plasma5Support.DataSource {
        id: engine
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            if (!root.current || source !== root.current.source) { disconnectSource(source); return; }
            disconnectSource(source);
            root.finish(data.stdout, data.stderr, data["exit code"]);
        }
    }

    Timer {
        id: killTimer
        repeat: false
        onTriggered: {
            if (!root.current) return;
            engine.disconnectSource(root.current.source);
            root.finish("", "timeout after " + interval + "ms", 124);
        }
    }
}
