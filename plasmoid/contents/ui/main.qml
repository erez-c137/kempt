// The widget's state machine. It owns exactly three things: the parsed CLI state, whether a run
// is in flight, and the view model derived from those two. Everything else - the panel icon, the
// badge, the tooltip, the popup - is a binding onto `vm` and holds no state of its own.
//
// Nothing here parses or decides anything: that is all in logic.js, which node can test. Nothing
// here runs a command directly either: that is Executor.qml, which serializes and hard-timeouts
// every call so a slow dnf can never block the panel process.
import QtQuick
import org.kde.plasma.plasmoid
import "logic.js" as Logic

PlasmoidItem {
    id: root

    // --- state ---------------------------------------------------------------------------------
    // The parsed `upkeep check` state (schema v1), or null when we have never had an answer.
    // NOT called `state`: QQuickItem already has a string property by that name, and shadowing it
    // with an object is the kind of thing that works in review and misbehaves in a real panel.
    property var upkeepState: null
    property bool updating: false          // a run WE started is in flight (Task W3 sets it)
    property bool checking: false          // a check is in flight; keeps checks from piling up
    property bool recheckPending: false    // ...and remembers the one we deferred while it ran

    // The single derived value. Re-evaluated by the engine whenever either input changes, which is
    // why nothing below ever recomputes or caches a label. null is a first-class input here: it
    // renders as "unknown", never as "zero updates".
    readonly property var vm: Logic.viewModel(upkeepState, updating)

    // --- the CLI -------------------------------------------------------------------------------
    // plasmashell does not necessarily inherit a login shell's PATH, and install.sh puts the CLI
    // in ~/.local/bin. The prefix makes the widget find it either way: from a symlink install or
    // from a package that dropped `upkeep` in /usr/bin. The engine runs the string through a
    // shell, so a per-command assignment is all this needs to be.
    readonly property string upkeepCmd: "PATH=\"$HOME/.local/bin:$PATH\" upkeep"

    // The event-driven half of the refresh (spec: an update applied from ANY source must show up
    // within seconds). KDirWatch is not reachable from pure QML, so this is a 30s stat of the two
    // package databases plus our own state file - three stats cost nothing and catch a manual
    // `dnf upgrade`, a Discover run and another Upkeep run alike.
    // The state path matches lib/common.sh's UPKEEP_STATE_DIR default exactly.
    readonly property string watchCmd:
        "stat -c %Y /var/lib/rpm /var/lib/flatpak \"$HOME/.local/state/upkeep/state.json\" 2>/dev/null | tr '\\n' ' '"

    property string watchStamp: ""         // last seen mtime set; "" until the first poll answers
    property int refreshIntervalMin: 60    // the CLI's own default until `config get` answers

    // --- flows ---------------------------------------------------------------------------------

    // The check. Three outcomes, and the difference between them is the whole contract:
    //   parseable stdout            -> use it, WHATEVER the exit code was. `upkeep check` prints
    //                                  the fresh state before it reports a persistence failure,
    //                                  so the answer is still the answer (answer-first contract).
    //   empty stdout, exit 0        -> "no data, keep the last known state". Another check held
    //                                  the lock. Changing anything here would turn a lock timeout
    //                                  into a badge that says zero updates.
    //   nothing usable, non-zero rc -> leave the state alone as well; the CLI reports its own
    //                                  failures inside the state as `status: "stale"`.
    function doCheck() {
        // Asked again while one is running: coalesce, never drop. Dropping looks harmless because
        // the running check will finish anyway - but its answer was read BEFORE the change that
        // asked for this one, and the re-baseline below would then swallow that change as if we
        // had already accounted for it. The badge would sit there stale until the next interval,
        // which is the exact bug the watcher exists to prevent.
        if (checking) { recheckPending = true; return; }
        checking = true;
        executor.run(upkeepCmd + " check", 120000, function(stdout, stderr, rc) {
            root.checking = false;
            var parsed = Logic.parseState(stdout);
            if (parsed !== null) {
                root.upkeepState = parsed;
            }
            // Re-baseline the watcher: the check just rewrote state.json, and without this the
            // next poll would see its own footprint as a change and check again, forever.
            // Clearing the stamp FIRST is what closes the race. A watcher poll queued while the
            // check was still running has not read the mtimes yet - it reads them after, sees our
            // own fresh state.json against the pre-check baseline, and calls that a change from
            // elsewhere. An empty stamp means "no baseline", so that poll learns the new mtimes
            // instead of reacting to them, and only a change from somewhere else can trigger.
            root.watchStamp = "";
            root.pollWatch(false);
            if (root.recheckPending) {
                root.recheckPending = false;
                root.doCheck();
            }
        });
    }

    // One stat of the watched paths. `triggerCheck` is what separates the 30s watcher (which must
    // react to a change) from the post-check re-baseline (which must not).
    function pollWatch(triggerCheck) {
        executor.run(watchCmd, 10000, function(stdout, stderr, rc) {
            var stamp = String(stdout).trim();
            if (stamp === "") return;              // stat found nothing: learn nothing, change nothing
            var changed = (root.watchStamp !== "" && stamp !== root.watchStamp);
            root.watchStamp = stamp;
            if (changed && triggerCheck) root.doCheck();
        });
    }

    // The check interval is a CLI setting, not a plasmoid setting - read at load, and again after
    // the settings page applies (Task W4 calls this).
    function readInterval() {
        executor.run(upkeepCmd + " config get refresh_interval_min", 10000, function(stdout, stderr, rc) {
            var n = parseInt(String(stdout).trim(), 10);
            if (rc === 0 && !isNaN(n) && n >= 1) root.refreshIntervalMin = n;
        });
    }

    // --- wiring --------------------------------------------------------------------------------
    Executor { id: executor }

    Timer {
        id: checkTimer
        // Clamped at BOTH ends, because this number comes from a text file a human can edit.
        // A 0 interval on a repeating timer spins the panel process; a large enough one overflows
        // Timer's 32-bit interval when multiplied by 60000 and comes out NEGATIVE, which spins it
        // just the same. A day is already far past any sensible check interval.
        interval: Math.min(1440, Math.max(1, root.refreshIntervalMin)) * 60000
        repeat: true
        running: true
        onTriggered: root.doCheck()
    }

    Timer {
        id: watchTimer
        interval: 30000
        repeat: true
        running: true
        onTriggered: root.pollWatch(true)
    }

    // The standard panel tooltip. Both strings come from the view model, so what the tooltip says
    // is pinned by the node tests rather than assembled here.
    toolTipMainText: vm ? vm.tooltipMain : "Upkeep"
    toolTipSubText: vm ? vm.tooltipSub : ""

    // preferredRepresentation is deliberately NOT set. Plasma's own switch already does the right
    // thing - the icon in a panel, the popup on the desktop - by comparing the available space
    // with the full representation's Layout.minimumWidth/Height. (Worth knowing: the
    // `preferredRepresentation: Plasmoid.compactRepresentation` line copied around third-party
    // widgets is a no-op on Plasma 6. Both properties live on PlasmoidItem, not on the Plasmoid
    // attached object, so that expression is undefined and the default heuristic runs anyway.)
    // Both inputs are handed down explicitly rather than reached for across files. They are
    // `required` on the other side, so a wiring mistake is a hard error at creation instead of a
    // panel that quietly renders the fallback branch of a guard.
    compactRepresentation: CompactRepresentation {
        plasmoidItem: root
        vm: root.vm
    }
    fullRepresentation: FullRepresentation {}

    Component.onCompleted: {
        readInterval();
        doCheck();
    }
}
