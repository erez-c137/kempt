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
    // The parsed `kempt check` state (schema v1), or null when we have never had an answer.
    // NOT called `state`: QQuickItem already has a string property by that name, and shadowing it
    // with an object is the kind of thing that works in review and misbehaves in a real panel.
    property var kemptState: null
    property bool updating: false          // a run WE started is in flight
    property bool checking: false          // a check is in flight; keeps checks from piling up
    property bool recheckPending: false    // ...and remembers the one we deferred while it ran
    property bool holdInFlight: false      // a hold/unhold is running; the pins go inert meanwhile

    // Our OWN report of a check that produced nothing usable - the CLI missing from PATH, say.
    // Distinct from the CLI reporting a problem, which arrives inside the state as `error`.
    property string cliError: ""
    // The result of the last button press, shown under the buttons until the next one.
    property string actionMessage: ""
    // Configured run surface and confirmation setting, read from the CLI. Only their COMBINATION
    // says what a run will really do, which is why the popup binds to effectiveSurface below.
    property string surface: "terminal"
    property bool autoAccept: true
    // What `kempt run` would actually launch: with confirmation on, only a terminal can ask the
    // question, so everything else collapses to terminal (bin/kempt, cmd_run).
    readonly property string effectiveSurface: Logic.effectiveSurfaceOf(surface, autoAccept)
    property string logTail: ""
    property string logPath: ""

    // The single derived value. Re-evaluated by the engine whenever either input changes, which is
    // why nothing below ever recomputes or caches a label. null is a first-class input here: it
    // renders as "unknown", never as "zero updates".
    readonly property var vm: Logic.viewModel(kemptState, updating, cliError)

    // --- the CLI -------------------------------------------------------------------------------
    // plasmashell does not necessarily inherit a login shell's PATH, and install.sh puts the CLI
    // in ~/.local/bin. The prefix makes the widget find it either way: from a symlink install or
    // from a package that dropped `kempt` in /usr/bin. The engine runs the string through a
    // shell, so a per-command assignment is all this needs to be.
    readonly property string kemptCmd: "PATH=\"$HOME/.local/bin:$PATH\" kempt"

    // Where the CLI keeps its state, resolved the way lib/common.sh resolves it:
    // KEMPT_STATE_DIR when set, else ~/.local/state/kempt. Deliberately NOT XDG_STATE_HOME -
    // the CLI does not honour it, so honouring it here would point the watcher at a directory
    // `kempt` never writes to, and the badge would stop noticing its own runs. If the CLI ever
    // adopts XDG_STATE_HOME, this line follows it, not the other way round.
    readonly property string stateDir: "${KEMPT_STATE_DIR:-$HOME/.local/state/kempt}"
    // ...and its config, resolved the same way (lib/common.sh line 19).
    readonly property string configDir: "${KEMPT_CONFIG_DIR:-$HOME/.config/kempt}"

    // The event-driven half of the refresh (spec: an update applied from ANY source must show up
    // within seconds). KDirWatch is not reachable from pure QML, so this is a 30s stat of the two
    // package databases plus our own state file - three stats cost nothing and catch a manual
    // `dnf upgrade`, a Discover run and another Kempt run alike.
    // The config file is watched too, and that is what makes the settings page work at all: a
    // config page is built by the shell in its own dialog, so it cannot call back into this file
    // (there is no rootItem to reach through). It writes with `kempt config set`, this notices
    // the file change, and the interval, the surface and the pending list are all re-read from
    // the CLI - which also means a `kempt config set` typed in a terminal updates the widget.
    // That back-channel is this 30-second poll, so a settings apply reaches the widget within 30
    // seconds rather than instantly. Deliberate, and the whole latency budget of the settings
    // page: nothing there waits on the widget having noticed.
    //
    // One field per path, ALWAYS. `stat` prints nothing at all for a path that does not exist, so
    // a bare `stat -c %Y a b c d` on a box without flatpak returns THREE numbers and every field
    // after the missing one shifts left - state.json would then be read in the flatpak column,
    // and the field-wise comparison below (Logic.watchChange) would attribute our own state
    // writes to the package database and dnf's writes to us. `|| echo 0` keeps the columns
    // aligned; a machine without flatpak is the ordinary case, not the exotic one.
    readonly property string watchCmd:
        "for p in /var/lib/rpm /var/lib/flatpak \"" + stateDir + "/state.json\" \"" + configDir
        + "/config\"; do stat -c %Y \"$p\" 2>/dev/null || echo 0; done | tr '\\n' ' '"

    property string watchStamp: ""         // last seen mtime set; "" until the first poll answers
    property int refreshIntervalMin: 60    // the CLI's own default until `config get` answers

    // --- flows ---------------------------------------------------------------------------------

    // The check. Three outcomes, and the difference between them is the whole contract:
    //   parseable stdout            -> use it, WHATEVER the exit code was. `kempt check` prints
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
        executor.run(kemptCmd + " check", 120000, function(stdout, stderr, rc) {
            root.checking = false;
            var parsed = Logic.parseState(stdout);
            if (parsed !== null) {
                root.kemptState = parsed;
                // The CLI answered. Whatever it thinks is wrong is inside that answer now, so our
                // own "could not run it" report has to go, or the popup would show a stale excuse
                // next to fresh data.
                root.cliError = "";
            } else if (rc !== 0) {
                // Nothing usable AND a failure: this is the one case where the widget itself has
                // something to report - the CLI is missing, or it could not start at all.
                root.cliError = Logic.firstLineOf(stderr);
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
            var previous = root.watchStamp;
            root.watchStamp = stamp;
            if (previous === "" || !triggerCheck) return;
            // WHICH path moved, not merely that one did. See Logic.watchChange.
            var delta = Logic.watchChange(previous, stamp);
            if (!delta.any) return;
            // A run of ours ends when the CLI writes state.json - it re-checks itself on the way
            // out, and that write is the signal there is something new to show. Nothing else is:
            // /var/lib/rpm is rewritten all the way THROUGH a dnf transaction, so ending the
            // updating state on any watched change meant the spinner stopped and a summary of the
            // PREVIOUS run appeared about thirty seconds into this one.
            if (delta.state) root.leaveUpdating();

            // ...and for the same reason, a package database moving while a run of OURS is still
            // in flight is not news - it IS the run. Checking on it would put `kempt check` in a
            // queue for the dnf lock the transaction is holding, every 30 seconds, for the length
            // of it. The config file is the one exception worth acting on meanwhile: it is the
            // settings page's only way into this file, and two `config get` calls take no locks.
            // (A run that just ENDED left `updating` false on the line above, so it falls past
            // this and gets the full re-read.)
            if (root.updating) {
                if (delta.config) { root.readInterval(); root.readSurface(); }
                return;
            }

            // Cheap enough to do unconditionally (two `config get` calls) and it is the only way
            // a settings apply reaches this file. include_flatpak can change what is pending, so
            // the check below has to happen either way.
            root.readInterval();
            root.readSurface();
            root.doCheck();
        });
    }

    // The check interval is a CLI setting, not a plasmoid setting - read at load, and again after
    // the settings page applies (Task W4 calls this).
    function readInterval() {
        executor.run(kemptCmd + " config get refresh_interval_min", 10000, function(stdout, stderr, rc) {
            var n = parseInt(String(stdout).trim(), 10);
            if (rc === 0 && !isNaN(n) && n >= 1) root.refreshIntervalMin = n;
        });
    }

    // Which surface a run will use. Only the popup surface makes the log pane worth showing - and
    // auto_accept is half of that answer, so both are read together.
    function readSurface() {
        executor.run(kemptCmd + " config get surface", 10000, function(stdout, stderr, rc) {
            var s = Logic.firstLineOf(stdout);
            if (rc === 0 && s !== "") root.surface = s;
        });
        // Guarded on emptiness exactly like the surface read above, and for a sharper reason:
        // `kempt config get` prints an empty line for a key it does not know, exit 0. An older
        // CLI on PATH would therefore hand us "" - and isTrue("") is false, which is the value
        // that forces terminal. The widget would quietly stop offering the in-popup log on a box
        // whose auto_accept is perfectly true. No answer means keep the CLI's own default.
        executor.run(kemptCmd + " config get auto_accept", 10000, function(stdout, stderr, rc) {
            var v = Logic.firstLineOf(stdout);
            if (rc === 0 && v !== "") root.autoAccept = Logic.isTrue(v);
        });
    }

    // --- actions -------------------------------------------------------------------------------

    // Update Now. `kempt run` is the verb built for this caller: it launches the configured
    // surface and RETURNS, so it gets a short timeout - the update itself is detached and never
    // occupies the executor. Putting a 40-minute dnf transaction through this queue would block
    // every check and every pin behind it, and the kill timer would only disconnect the reader
    // anyway: the child would keep running, unwatched.
    function startUpdate() {
        if (updating) return;
        actionMessage = "";
        executor.run(kemptCmd + " run", 15000, function(stdout, stderr, rc) {
            if (rc === 0) {
                root.enterUpdating();
                return;
            }
            // The CLI's own words. rc 4 is a missing terminal emulator and its message carries the
            // remedy; rc 3 is another run already holding the lock.
            var msg = Logic.firstLineOf(stderr) || Logic.firstLineOf(stdout);
            if (rc === 3 && msg === "") msg = "An update is already running.";
            root.actionMessage = msg !== "" ? msg : "Could not start the update (exit " + rc + ").";
        });
    }

    // The offline recommendation, acted on. `kempt update --surface=offline` runs the staging
    // synchronously, so unlike `run` it has to be detached here - and detached means it must NOT
    // be waited on by the executor.
    function stageOffline() {
        if (updating) return;
        actionMessage = "";
        // `setsid sh -c '<script>'` and not `setsid <script>`: kemptCmd begins with a PATH=
        // assignment, and setsid would try to EXECUTE a program by that name rather than set a
        // variable. The quoted script keeps the expansion for the inner shell, which is where it
        // is supposed to happen.
        executor.run("setsid sh -c " + Logic.shellQuote(kemptCmd + " update --surface=offline")
                     + " >/dev/null 2>&1 &", 10000,
                     function(stdout, stderr, rc) {
            if (rc === 0) root.enterUpdating();
            else root.actionMessage = Logic.firstLineOf(stderr) || "Could not stage the offline update.";
        });
    }

    // The pin toggle. The name comes out of the CLI's own JSON and goes back into a shell command,
    // so it is quoted - see Logic.shellQuote. Nothing about a hold is stored in the widget: the
    // CLI owns the holds file, and the re-check is what moves the row between groups.
    function setHold(backend, name, hold) {
        if (holdInFlight) return;
        holdInFlight = true;
        actionMessage = "";
        var verb = hold ? " hold " : " unhold ";
        executor.run(kemptCmd + verb + Logic.shellQuote(backend + ":" + name), 15000,
                     function(stdout, stderr, rc) {
            root.holdInFlight = false;
            if (rc !== 0) {
                root.actionMessage = Logic.firstLineOf(stderr) || "Could not change the hold on " + name + ".";
                return;
            }
            root.doCheck();
        });
    }

    // --- the updating state ----------------------------------------------------------------------

    function enterUpdating() {
        updating = true;
        logTail = "";
        logPath = "";
        updateGuard.restart();
        if (effectiveSurface === "popup") findLog();
    }

    function leaveUpdating() {
        if (!updating) return;
        updating = false;
        updateGuard.stop();
        loadSummary();
    }

    // The newest log file, found once per run.
    // stateDir is NOT shellQuote'd, and that distinction is the whole rule: it is a shell
    // expression this file wrote, whose ${...} expansion is the point of it, and single quotes
    // would turn it into a literal directory name that cannot exist. shellQuote is for values
    // that came from OUTSIDE - package names, paths the CLI printed - which must never be
    // interpreted. Double quotes give stateDir its expansion and still survive a space in $HOME;
    // the glob stays outside them so it can still glob.
    function findLog() {
        tailExecutor.run("ls -1t \"" + stateDir + "\"/logs/*.log 2>/dev/null | head -1",
                         10000, function(stdout, stderr, rc) {
            root.logPath = Logic.firstLineOf(stdout);
        });
    }

    function pollLog() {
        if (!updating || effectiveSurface !== "popup" || logPath === "") return;
        // One tail in flight at a time. The timer ticks every 2 seconds, and a `tail` that takes
        // longer than that - a loaded box, a log on a slow disk, an executor already sitting on
        // its 10-second timeout - would have the next tick queued behind it before it came back,
        // and from there the queue only grows. Skipping a tick costs nothing: another is two
        // seconds away and reads the same file. Separating the tail onto its own Executor stopped
        // it delaying the ACTION queue; this stops it flooding its own.
        if (tailExecutor.current) return;
        tailExecutor.run("tail -n 25 " + Logic.shellQuote(logPath), 10000, function(stdout, stderr, rc) {
            if (rc === 0) root.logTail = stdout;
        });
    }

    // One line saying what the run actually did, from the same renderer the terminal and the
    // notification use.
    function loadSummary() {
        executor.run(kemptCmd + " summary", 15000, function(stdout, stderr, rc) {
            if (rc === 0) root.actionMessage = Logic.firstLineOf(stdout);
        });
    }

    // --- wiring --------------------------------------------------------------------------------
    Executor { id: executor }

    // A SECOND executor, for the log tail alone. The queue is strictly first-in-first-out, so a
    // 2-second tail sharing it with a 120-second check would put ~60 tails in front of everything
    // else - the Refresh button would appear dead for two minutes. Separating them means the tail
    // can never delay an action, and an action can never stall the tail.
    Executor { id: tailExecutor }

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

    Timer {
        id: logTimer
        interval: 2000
        repeat: true
        // Only while a run is actually in flight AND the output is meant to land here. On any
        // other surface this never starts, so there is no tail process at all.
        running: root.updating && root.effectiveSurface === "popup" && root.expanded
        onTriggered: root.pollLog()
    }

    // The safety net on `updating`. A run ends when the CLI writes state.json - but a user who
    // closes the terminal window, or an update that dies, never writes it, and the popup would
    // sit on a spinner until plasmashell restarted. Three hours is far longer than any real
    // transaction and far shorter than forever.
    Timer {
        id: updateGuard
        interval: 3 * 60 * 60 * 1000
        repeat: false
        onTriggered: {
            root.updating = false;
            root.actionMessage = "Stopped waiting for the update to report back. Check: kempt summary";
            root.doCheck();
        }
    }

    // The standard panel tooltip. Both strings come from the view model, so what the tooltip says
    // is pinned by the node tests rather than assembled here.
    toolTipMainText: vm ? vm.tooltipMain : "Kempt"
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
    fullRepresentation: FullRepresentation {
        plasmoidItem: root
        vm: root.vm
    }

    Component.onCompleted: {
        readInterval();
        readSurface();
        doCheck();
    }
}
