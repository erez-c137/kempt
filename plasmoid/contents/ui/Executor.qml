// The ONE place commands run. Serialized queue, hard per-call timeout, always async.
// Wraps the deprecated Plasma5Support executable engine (swap point when KDE drops it).
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
