// The widget's state machine. It owns exactly three things: the parsed CLI state, whether a run
// is in flight, and the view model derived from those two. Everything else - the panel icon, the
// badge, the tooltip, the popup - is a binding onto `vm` and holds no state of its own.
//
// Nothing here parses or decides anything: that is logic.js, which node can test. Nothing here
// runs a command directly either: that is Executor.qml, which serializes and hard-timeouts every
// call so a slow dnf can never block the panel process.
import QtQuick
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import "logic.js" as Logic

PlasmoidItem {
    id: root

    // --- state ---------------------------------------------------------------------------------
    // The parsed `kempt check` state (schema v1), or null when we have never had an answer.
    // NOT called `state`: QQuickItem already has a string property by that name.
    property var kemptState: null
    property bool updating: false          // a run WE started is in flight
    property bool checking: false          // a check is in flight; keeps checks from piling up
    property bool recheckPending: false    // ...and remembers the one we deferred while it ran
    // When the last check FINISHED, as Date.now(); 0 until one has. The watcher's quiet window is
    // measured from here - see Logic.watcherCheckDue. A `double`, not an `int`: Date.now() is
    // milliseconds since 1970 and does not fit in QML's 32-bit int.
    property double lastCheckFinished: 0
    // The hold whose ROUND TRIP is not finished: {backend, name}, or null. Not "a hold command is
    // running": it stays set through the follow-up check, because the row does not move until that
    // check lands and the window in between is where the damage is.
    //
    // Naming the ONE pending row is what lets that row keep its button enabled and focused while
    // the others stand down. A global `enabled: !busy` cannot: Qt strips focus from a control the
    // instant it is disabled, so the keyboard leaves the pressed pin for the delegate's anonymous
    // Loader while the row goes on saying "Hold" and accepts a second press.
    property var pendingHold: null

    // The last hold that failed: {backend, name, text}. Reported IN THAT ROW - see COPY.holdFailed.
    // Cleared by the next press and the next check: it is a fact about one press, not about the box.
    property var holdError: null

    // A one-shot continuation for the next check that COMPLETES. setHold uses it to hold
    // `pendingHold` open until the row has really moved, and it survives a coalesced re-check: the
    // answer a caller is waiting for is the answer that includes its own write.
    property var afterCheck: null

    // What the popup says out loud when a hold finishes. This file owns the round trip, so it owns
    // the news; what a surface DOES about it is that surface's business - the same split as
    // popupShown(). `message` carries the sentence to speak when `ok` is false.
    signal holdOutcome(string name, bool hold, bool ok, string message)
    // How many times we have re-asked after a check that answered with NOTHING. `kempt check`
    // prints an empty line and exits 0 when another check holds the lock, which on a fresh login
    // is the ordinary case. That means "keep the last known state" - but at startup there is none,
    // so without a retry the panel sits dim until the hourly timer.
    property int firstCheckRetries: 0
    readonly property int maxFirstCheckRetries: 3

    // Our OWN report of a check that produced nothing usable - a CLI that started and failed, say.
    // Distinct from the CLI reporting a problem, which arrives inside the state as `error`.
    property string cliError: ""

    // ...and the one shape of that which is not a failure: there is no CLI on this box. The KDE
    // Store carries the plasmoid and nothing else, so a store install's first run has no engine.
    // Kept apart from cliError because the popup answers them differently: cliError is "we could
    // not get an answer" (report it, offer `kempt doctor`), this is "there is nothing here to
    // answer" (say what to install, offer nothing to run - kempt is the missing thing).
    //
    // Read off the EXIT CODE and never off the text: `sh -c` answers 127 for a command it could
    // not find and 126 for one it found and could not execute, and those numbers are the same in
    // every locale where the message beside them is not. Both get "install it".
    property bool engineMissing: false
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
    // `auto`, or one of the three named steps. Validated HERE, not by the CLI: `kempt config set`
    // checks that a key looks like a key and stores whatever value it is handed, so a typo, an
    // older CLI's empty line and a future version's value all arrive the same way.
    // Logic.resolveIconSizeSetting turns every one of them into `auto` without complaint, which is
    // right for a panel icon: it draws, at a sensible size, whatever the file says.
    property string iconSizeSetting: "auto"
    // Whether the popup may REMIND the user that a restart is owed (`restart_reminder`, default
    // true). Not whether one is owed - that is the state file's `reboot_needed`, a fact rather
    // than a reminder: with this off the message and its button go and the status line still ends
    // "restart pending".
    property bool restartReminder: true

    // ...and whether the user closed that message in THIS plasmashell session. Deliberately not
    // persisted: a dismissal written to disk is a promise to remember across a restart, and a
    // restart is the exact event that makes the underlying fact go away. Somebody who never wants
    // the message turns the setting off; that IS the durable answer.
    property bool restartDismissed: false

    // Switching the reminder OFF and back ON is a person saying "show me this again". Only on the
    // TRANSITION, which is what a property change signal is: the config file is polled every 30
    // seconds, so a handler that fired whenever the value was simply true would revoke a dismissal
    // within half a minute of it being made.
    onRestartReminderChanged: if (restartReminder) restartDismissed = false;

    // Our own report of a restart prompt that could not be opened; empty means nothing to say.
    // Kept apart from actionMessage because it belongs to the restart message, which is where the
    // user pressed. Silence is the worst outcome available: a button that appears to do nothing is
    // indistinguishable from one that did something invisible.
    property string restartError: ""

    // The newest history entry as DATA (`kempt summary --json` through Logic.lastRunOf), or null
    // on a box that has never run an update. null is a first-class value: it renders as no last
    // run at all, never as a fabricated empty one claiming a run that changed no packages.
    property var lastRun: null

    // The transient line about a run WE started - "Updated 4 packages in 2s", or why it failed.
    // One event, one line at a time: while this is on screen the persistent Last update row is
    // hidden, and it clears when the popup closes or a check starts.
    property string postRunLine: ""

    // Which of the two reports is the LATEST, and therefore the one the popup shows: "run" for
    // postRunLine, "failure" for actionMessage, "" for neither. The popup fits two messages in
    // total and these two are never the same event.
    //
    // A third property rather than a timestamp on each, because these two are assigned from a
    // dozen places between them and a stamp one assignment forgot would silently pick the wrong
    // winner. A change handler fires on every assignment there is, including the ones that clear.
    property string reportLatest: ""
    onActionMessageChanged: reportLatest = actionMessage.length > 0 ? "failure"
                            : (postRunLine.length > 0 ? "run" : "")
    onPostRunLineChanged: reportLatest = postRunLine.length > 0 ? "run"
                          : (actionMessage.length > 0 ? "failure" : "")
    readonly property string reportText: reportLatest === "failure" ? actionMessage
                                         : (reportLatest === "run" ? postRunLine : "")
    // A failed press is an error; a run is an error when the run failed, whatever its counts say.
    readonly property bool reportFailed:
        reportLatest === "failure"
        || (reportLatest === "run" && lastRun !== null && lastRun.failed)

    // When the run we are watching STARTED, as milliseconds; 0 means we never saw one start. It
    // exists for the transient post-run line: `kempt summary --json` answers with the newest entry
    // it can read, and this is what lets Logic.runFinishedSince check that entry is from after we
    // started watching rather than the run before it.
    property double updateStartedMs: 0

    // Which surface the run IN FLIGHT is using - one of the CLI's four, or "" when nothing is
    // running. Not `effectiveSurface`, which is what a run started NOW would use: the configured
    // value is wrong for a staging run started from Install on Next Restart, and it moves under
    // the pane when the settings change mid-run.
    property string runningSurface: ""

    // A `kempt run` has been asked for and has not come back. Not the same as `updating`, which
    // only begins once that call succeeds: `run` launches the surface and returns, and is allowed
    // fifteen seconds to do it. In that window `updating` is still false, so this is the only
    // thing between a double press and two terminals both asking the risky question.
    property bool runRequested: false

    // The clock the relative times ("Checked 4 min ago") are measured against, refreshed while the
    // popup is open and never while it is shut. 0 means "no clock yet", which logic.js answers
    // with the absolute stamp - never a wrong relative time.
    property double nowMs: 0

    // The single derived value, re-evaluated by the engine whenever either input changes - which
    // is why nothing below recomputes or caches a label. null is a first-class input: it renders
    // as "unknown", never as "zero updates".
    //
    // The extras are the facts that are NOT in the state file. An object rather than more
    // positional arguments, so a caller that does not know about one of them (the node tests'
    // three-argument calls) keeps working and adding the next one is not a signature change.
    readonly property var vm: Logic.viewModel(kemptState, updating, cliError,
                                              { nowMs: nowMs,
                                                restartReminder: restartReminder,
                                                restartDismissed: restartDismissed,
                                                engineMissing: engineMissing,
                                                // The one input logic.js cannot derive: the
                                                // post-run line and a failed press are this
                                                // file's own state, not the CLI's, and the
                                                // message cap has to see them.
                                                reportShown: reportText.length > 0 })

    // --- the CLI -------------------------------------------------------------------------------
    // plasmashell does not necessarily inherit a login shell's PATH, and install.sh puts the CLI
    // in ~/.local/bin - so the prefix finds it from a symlink install or from a package.
    // KEMPT_VIA=widget changes nothing the CLI does; it is read only by lib/common.sh's log_event,
    // which stamps each line of `kempt log` with `widget` or `cli`.
    readonly property string kemptCmd: "PATH=\"$HOME/.local/bin:$PATH\" KEMPT_VIA=widget kempt"

    // Where the CLI keeps its state, resolved the way lib/common.sh resolves it. Deliberately NOT
    // XDG_STATE_HOME - the CLI does not honour it, so honouring it here would point the watcher at
    // a directory `kempt` never writes to and the badge would stop noticing its own runs. If the
    // CLI ever adopts XDG_STATE_HOME, this line follows it, not the other way round.
    readonly property string stateDir: "${KEMPT_STATE_DIR:-$HOME/.local/state/kempt}"
    // ...and its config, resolved the same way (lib/common.sh's KEMPT_CONFIG_DIR default).
    readonly property string configDir: "${KEMPT_CONFIG_DIR:-$HOME/.config/kempt}"

    // The event-driven half of the refresh (spec: an update applied from ANY source shows up
    // within seconds). KDirWatch is not reachable from pure QML, so this is a 30s stat of the two
    // package databases plus our own state file. The config file is watched too, and that is what
    // makes the settings page work at all: the page is built by the shell in its own dialog and
    // cannot call back into this file, so it writes with `kempt config set` and this notices the
    // mtime. That 30-second poll is the settings page's whole latency budget.
    //
    // One field per path, ALWAYS. `stat` prints nothing for a path that does not exist, so a bare
    // `stat -c %Y a b c d` on a box without flatpak returns THREE numbers and every field after
    // the missing one shifts left - state.json would be read in the flatpak column, and
    // Logic.watchChange would attribute our own writes to the package database and dnf's to us.
    // rpmdb.sqlite and NOT the /var/lib/rpm directory that used to be here. Fedora's rpm database
    // is sqlite and is modified IN PLACE, so the directory's mtime does not move for an install or
    // a remove: on a machine updated tonight it still read April. Watching the directory was true
    // of the old Berkeley DB layout, where a transaction replaced files inside it, and it means
    // this half of the refresh has never once fired on Fedora - a `dnf upgrade` typed in a
    // terminal went unnoticed until the next timed check, up to an hour later, which is the exact
    // thing this poll exists to prevent. The directory stays in the list as well: it is what moves
    // if a future rpm layout goes back to replacing files, and an extra stat costs nothing.
    readonly property string watchCmd:
        "for p in /var/lib/rpm/rpmdb.sqlite /var/lib/rpm /var/lib/flatpak \"" + stateDir
        + "/state.json\" \"" + configDir
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
        // The last event's reports have had their moment. Cleared BEFORE the coalesce guard: a
        // Refresh pressed while a check runs is still the user asking for the next thing.
        //
        // Ordering with leaveUpdating() is load-bearing, because the two run back to back at the
        // end of every run: leaveUpdating queues `summary --json` and this clear is synchronous,
        // so the clear happens first and the callback that sets the line lands after it. The
        // Executor queue is strictly FIFO, which is what makes that a rule rather than a race.
        postRunLine = "";
        restartError = "";
        holdError = null;
        // Asked again while one is running: coalesce, never drop. The running check read its
        // answer BEFORE the change that asked for this one, and the re-baseline below would then
        // swallow that change as if we had accounted for it - leaving the badge stale until the
        // next interval, which is the exact bug the watcher exists to prevent.
        if (checking) { recheckPending = true; return; }
        checking = true;
        executor.run(kemptCmd + " check", 120000, function(stdout, stderr, rc) {
            root.checking = false;
            // Stamped for EVERY completed check, whatever it answered: the quiet window below is
            // about the writes a check makes, and it makes those either way.
            root.lastCheckFinished = Date.now();
            var parsed = Logic.parseState(stdout);
            if (parsed !== null) {
                root.kemptState = parsed;
                // Something answered, so whatever is wrong is inside that answer now, and there IS
                // an engine. Nothing else clears engineMissing: it is what lets the widget come
                // back on its own after the package is installed.
                root.cliError = "";
                root.engineMissing = false;
                // ...and the last run may not be the one we knew about. A `kempt update` typed in
                // a terminal writes a history entry and then re-checks itself, and that state
                // write is what brought us here.
                root.loadLastRun();
            } else if (rc === 127 || rc === 126) {
                // No engine: nothing to run (127), or something unrunnable (126). cliError is
                // cleared so the popup shows one message about one situation instead of both.
                root.engineMissing = true;
                root.cliError = "";
            } else if (rc !== 0) {
                // Nothing usable AND a failure: the one case where the widget itself has something
                // to report - the CLI ran and could not answer.
                root.engineMissing = false;
                root.cliError = Logic.firstLineOf(stderr);
            } else {
                // rc 0 with nothing usable: a lock we lost. An engine that exits 0 EXISTS, so a
                // standing missing-engine verdict is stale - and it must not stand, because the
                // retry below skips retrying while it does.
                root.engineMissing = false;
            }
            // Re-baseline the watcher: the check just rewrote state.json, and without this the
            // next poll would see its own footprint as a change and check again, forever.
            // Clearing the stamp FIRST closes the race - a watcher poll queued while the check was
            // running reads the mtimes afterwards and would compare our fresh state.json against
            // the pre-check baseline. No baseline means it learns the new mtimes instead.
            root.watchStamp = "";
            root.pollWatch(false);
            if (root.recheckPending) {
                root.recheckPending = false;
                root.doCheck();
                return;
            }
            // Anything waiting for a check to LAND is free now. Before the bounded retry on
            // purpose: that branch waits ten seconds, and a pin left spinning that long is the
            // state this replaced.
            root.runAfterCheck();
            // Still nothing to show and nothing of our OWN to report: an empty answer is a lock we
            // lost, so ask again shortly rather than leaving the panel dim for an hour. A cliError
            // or a missing engine is an answer, and re-asking would only re-fail. Bounded, so a
            // wedged lock cannot turn into a widget forking a check forever.
            if (root.kemptState === null && root.cliError === "" && !root.engineMissing) {
                if (root.firstCheckRetries < root.maxFirstCheckRetries) {
                    root.firstCheckRetries++;
                    firstCheckRetry.restart();
                }
                return;
            }
            root.firstCheckRetries = 0;
            firstCheckRetry.stop();
        });
    }

    // The one-shot continuation above, run and forgotten. Cleared BEFORE it is called, so a
    // continuation that itself starts a check cannot be handed its own leftovers.
    function runAfterCheck() {
        if (afterCheck === null) return;
        var done = afterCheck;
        afterCheck = null;
        done();
    }

    // One stat of the watched paths. `triggerCheck` separates the 30s watcher (which must react to
    // a change) from the post-check re-baseline (which must not).
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
            // out. Nothing else is that signal: /var/lib/rpm is rewritten all the way THROUGH a
            // dnf transaction, so ending the updating state on any watched change stops the
            // spinner and shows a summary of the PREVIOUS run thirty seconds into this one.
            // Read BEFORE leaveUpdating clears it: whether this tick ended a run is what exempts
            // the post-run check from the quiet window below.
            var endedRun = delta.state && root.updating;
            if (delta.state) root.leaveUpdating();

            // ...and a package database moving while a run of OURS is in flight is not news, it IS
            // the run: checking on it would queue `kempt check` behind the dnf lock the
            // transaction holds, every 30 seconds, for the length of it. The config file is the
            // one exception worth acting on meanwhile - it is the settings page's only way in, and
            // two `config get` calls take no locks. (A run that just ENDED cleared `updating` on
            // the line above, so it falls past this and gets the full re-read.)
            if (root.updating) {
                if (delta.config) {
                    root.readInterval(); root.readSurface(); root.readIconSize();
                    root.readRestartReminder();
                }
                return;
            }

            // Cheap enough to do unconditionally and the only way a settings apply reaches this
            // file. include_flatpak can change what is pending, so the check below happens anyway.
            root.readInterval();
            root.readSurface();
            root.readIconSize();
            root.readRestartReminder();

            // ...and the check itself, unless this change is still the wake of the last one.
            // Logic.watcherCheckDue carries the rule and the trade it makes. Two exemptions,
            // neither an optimisation:
            //   endedRun    the moment a run of OURS finishes is the moment the counts on screen
            //               are most wrong, and the user who pressed Update Now a minute ago is
            //               the one looking at them.
            //   delta.config the settings page has no other way in, "changes reach the panel
            //               within 30 seconds" (docs/usage.md) is measured through this line, and
            //               include_flatpak changes what is pending.
            if (endedRun || delta.config
                || Logic.watcherCheckDue(root.lastCheckFinished, Date.now())) {
                root.doCheck();
            }
        });
    }

    // The check interval is a CLI setting, not a plasmoid setting - read at load, and again when
    // the config file moves.
    function readInterval() {
        executor.run(kemptCmd + " config get refresh_interval_min", 10000, function(stdout, stderr, rc) {
            var n = parseInt(String(stdout).trim(), 10);
            if (rc === 0 && !isNaN(n) && n >= 1) root.refreshIntervalMin = n;
        });
    }

    // Which surface a run will use. Only the popup surface makes the log pane worth showing, and
    // auto_accept is half of that answer, so both are read together.
    //
    // THE RULE FOR EVERY `config get` READER BELOW: an empty answer means keep what we have.
    // `kempt config get` prints an empty line and exits 0 for a key it does not know, so an older
    // CLI hands back "" - and isTrue("") is false, which is not the CLI's default for any of these
    // keys. Taken at face value it silently switches a setting off on a box where it is on.
    function readSurface() {
        executor.run(kemptCmd + " config get surface", 10000, function(stdout, stderr, rc) {
            var s = Logic.firstLineOf(stdout);
            if (rc === 0 && s !== "") root.surface = s;
        });
        executor.run(kemptCmd + " config get auto_accept", 10000, function(stdout, stderr, rc) {
            var v = Logic.firstLineOf(stdout);
            if (rc === 0 && v !== "") root.autoAccept = Logic.isTrue(v);
        });
    }

    // The panel icon's size preference, on the same schedule and under the same empty-answer rule.
    // Anything it does answer goes through the validator before it can reach a binding.
    function readIconSize() {
        executor.run(kemptCmd + " config get widget_icon_size", 10000, function(stdout, stderr, rc) {
            var v = Logic.firstLineOf(stdout);
            if (rc === 0 && v !== "") root.iconSizeSetting = Logic.resolveIconSizeSetting(v);
        });
    }

    // Whether the popup may remind the user about an owed restart. Same rule as readSurface.
    function readRestartReminder() {
        executor.run(kemptCmd + " config get restart_reminder", 10000, function(stdout, stderr, rc) {
            var v = Logic.firstLineOf(stdout);
            if (rc === 0 && v !== "") root.restartReminder = Logic.isTrue(v);
        });
    }

    // --- actions -------------------------------------------------------------------------------

    // Update Now. `kempt run` launches the configured surface and RETURNS, so it gets a short
    // timeout - the update itself is detached and never occupies the executor. A 40-minute dnf
    // transaction on this queue would block every check and every pin behind it, and the kill
    // timer would only disconnect the reader anyway: the child would keep running, unwatched.
    function startUpdate() {
        if (updating || runRequested) return;
        runRequested = true;
        actionMessage = "";
        executor.run(kemptCmd + " run", 15000, function(stdout, stderr, rc) {
            root.runRequested = false;
            if (rc === 0) {
                // The surface the CLI just launched, remembered for the pane. Read here rather
                // than in the pane, because the setting can change while the run is in flight.
                root.enterUpdating(root.effectiveSurface);
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
        // assignment, and setsid would try to EXECUTE a program by that name. The quoted script
        // keeps the expansion for the inner shell, where it is supposed to happen.
        executor.run("setsid sh -c " + Logic.shellQuote(kemptCmd + " update --surface=offline")
                     + " >/dev/null 2>&1 &", 10000,
                     function(stdout, stderr, rc) {
            // Offline whatever the configured surface says: this command carries --surface=offline.
            if (rc === 0) root.enterUpdating("offline");
            else root.actionMessage = Logic.firstLineOf(stderr) || "Could not stage the offline update.";
        });
    }

    // The conflict banner's one action. It runs EXACTLY what stageOffline runs above, detached the
    // same way, the same polkit action: a rebuild IS a stage, and dnf5 replaces the stored
    // transaction with the one the current holds produce.
    //
    // What is new is the RE-VERIFY, and it is why this is not stageOffline() under a second label.
    // Consent is given to a BANNER, and a banner describes ONE transaction: the popup can sit open
    // for an hour, in which the stage can be consumed by a restart, replaced, or cleaned away. A
    // rebuild is destructive at its START - dnf5 destroys the stored transaction the moment a
    // re-stage begins - so acting on a stale banner throws away a transaction the person never
    // agreed to lose (spec 4.4). So: read the state file as it is NOW, and proceed only if it is
    // still the same stage and still in conflict. stateDir is NOT shellQuote'd - see findLog().
    function rebuildStaged() {
        // The same guard stageOffline has, and it matters more here: two staging runs at once is a
        // double press with a destructive first step.
        if (updating) return;
        actionMessage = "";
        // Read HERE, synchronously, before anything can move it: this is the stamp of the banner
        // the person was looking at when they pressed. Comparing against root.vm instead would
        // compare the new file with itself once the fresh state has been assigned in, and always
        // agree.
        var offered = vm.stagedStagedAt;
        executor.run("cat \"" + stateDir + "/state.json\"", 10000, function(stdout, stderr, rc) {
            // Deliberately NOT re-running `kempt check`. The file IS what check publishes, reading
            // it costs nothing and cannot take a lock, and a check would put a command that can
            // run for two minutes between the click and the action it was meant to authorise.
            var fresh = Logic.parseState(stdout);
            // Re-derived from the bytes just read, so the banner after a refusal is the truth
            // rather than the thing they clicked. Only when there is something to derive from:
            // null means we learned nothing, and rule 1 of the schema says keep what we had.
            if (fresh !== null) root.kemptState = fresh;
            var vmNow = Logic.viewModel(fresh, false, "");
            // Three conditions, all about the SAME transaction still being there and still being
            // wrong: a stage is published at all, it is the one this banner was built from
            // (staged_at, compared as published - see logic.js stagedStagedAt), and it would still
            // raise a warning. The third stops a rebuild running over a conflict already resolved.
            if (vmNow.stagedStagedAt === "" || vmNow.stagedStagedAt !== offered
                    || !vmNow.stagedShowRebuild) {
                root.actionMessage = Logic.COPY.stagedChanged;
                return;
            }
            // `executor`, not `root.executor`: an id is resolved lexically and is NOT a property
            // of the object that declares it, so `root.executor` is undefined and calling .run on
            // it throws inside the callback - silently, as far as the person who pressed is
            // concerned.
            executor.run("setsid sh -c "
                         + Logic.shellQuote(root.kemptCmd + " update --surface=offline")
                         + " >/dev/null 2>&1 &", 10000,
                         function(stdout2, stderr2, rc2) {
                if (rc2 === 0) root.enterUpdating("offline");
                else root.actionMessage = Logic.firstLineOf(stderr2)
                                          || "Could not rebuild the staged update.";
            });
        });
    }

    // The pin toggle. The name comes out of the CLI's own JSON and goes back into a shell command,
    // so it is quoted - see Logic.shellQuote. Nothing about a hold is stored in the widget: the
    // CLI owns the holds file, and the re-check is what moves the row between groups.
    function setHold(backend, name, hold) {
        // One hold at a time, and this guard is what the other rows' disabled state is FOR. The
        // pressed row keeps its button live so it can keep the keyboard, so a second press on the
        // pending package really does arrive here - and has to reach the CLI as nothing at all.
        if (pendingHold !== null) return;
        pendingHold = { backend: backend, name: name };
        holdError = null;
        actionMessage = "";
        var verb = hold ? " hold " : " unhold ";
        executor.run(kemptCmd + verb + Logic.shellQuote(backend + ":" + name), 15000,
                     function(stdout, stderr, rc) {
            if (rc !== 0) {
                // In the row, not at the top of the stack - and said out loud, because a row is
                // where the person is standing and a message 300 px away is not a report.
                var msg = Logic.firstLineOf(stderr)
                          || Logic.COPY.holdFailed.split("%1").join(name);
                root.holdError = { backend: backend, name: name, text: msg };
                root.pendingHold = null;
                root.holdOutcome(name, hold, false, msg);
                return;
            }
            // The row moves when the CHECK lands, not when this call returns, so the pending state
            // stays set until then. That is the whole window a duplicate `hold` lives in.
            root.afterCheck = function () { root.pendingHold = null;
                                            root.holdOutcome(name, hold, true, ""); };
            root.doCheck();
        });
    }

    // The restart, ASKED FOR and never performed. `org.kde.LogoutPrompt.promptReboot` opens KDE's
    // own confirmation screen: cancellable, sessions get to object and save, and it honours the
    // user's logout-confirmation setting. `/usr/bin/plasma-shutdown` carries a SECOND family of
    // methods that take no answer and simply reboot - and Kempt must NEVER restart anybody's
    // machine. Neither of those two names appears anywhere under plasmoid/contents/ui/, and
    // tests/qml/probe_popup.py asserts that by grepping this directory; they are spelled out
    // there, in the test that forbids them, and deliberately not here - a pin that tolerated the
    // strings in a comment is a pin a future edit can satisfy by writing a comment.
    //
    // The service is D-Bus activatable, so nothing has to be running first. Ten seconds is
    // generous for a call that returns as soon as the prompt has been ASKED for; it must not wait
    // for an answer, because the user may sit and think about it.
    function promptRestart() {
        restartError = "";
        // promptExecutor, never the shared one - see its declaration.
        promptExecutor.run("dbus-send --session --dest=org.kde.LogoutPrompt --type=method_call"
                     + " /LogoutPrompt org.kde.LogoutPrompt.promptReboot", 10000,
                     function(stdout, stderr, rc) {
            if (rc !== 0) root.restartError = Logic.COPY.restartFailed;
        });
    }

    // Closing the restart message. Session-only by design - see restartDismissed. Nothing is
    // written and nothing is asked of the CLI: logic.js turns the flag into a message that is gone
    // and a status line that ends "restart pending", so the popup stops nagging without lying.
    function dismissRestart() {
        restartDismissed = true;
    }

    // Show Log, through the desktop's own handler so the user gets whatever they have chosen for a
    // text file. The path came out of the CLI's JSON and is going back onto a command line, which
    // puts it in the same class as a package name: through Logic.shellQuote, no exceptions.
    // xdg-open is used on the log path and nothing else in this file - it is an "open with
    // whatever is registered" verb, and what it may be pointed at should stay this small.
    function showLog(path) {
        actionMessage = "";
        var target = String(path === undefined || path === null ? "" : path).trim();
        // A history entry old enough (or damaged enough) to have no log is an ordinary event, not
        // corruption - and `xdg-open ''` opens the user's home directory.
        if (target === "") {
            actionMessage = "That run did not record a log file.";
            return;
        }
        executor.run("xdg-open " + Logic.shellQuote(target), 10000, function(stdout, stderr, rc) {
            // The path is in the message on purpose: whatever went wrong with the handler, the
            // user can still open that file themselves.
            if (rc !== 0) {
                root.actionMessage = "Could not open " + target
                    + (Logic.firstLineOf(stderr) !== "" ? " - " + Logic.firstLineOf(stderr) : ".");
            }
        });
    }

    // --- the updating state ----------------------------------------------------------------------

    function enterUpdating(surface) {
        // Resolved, so this is always one of the four the CLI knows and the pane can switch on it
        // without a fifth branch for "we do not know".
        runningSurface = Logic.resolveSurface(surface === undefined ? effectiveSurface : surface);
        updating = true;
        // Noted BEFORE anything is launched, so the entry the run writes can only be stamped at or
        // after this - see Logic.runFinishedSince for the comparison.
        updateStartedMs = Date.now();
        logTail = "";
        logPath = "";
        updateGuard.restart();
        if (runningSurface === "popup") findLog();
    }

    function leaveUpdating() {
        if (!updating) return;
        updating = false;
        runningSurface = "";
        updateGuard.stop();
        // The transient line is DERIVED from the entry, so the entry has to arrive first - which
        // with a callback-based executor means inside the callback. Setting it after the call
        // would read the PREVIOUS run's entry every time.
        //
        // ...and it is only spoken for an entry that is actually OURS. runFinishedSince is the
        // belt to the CLI's own braces, and covers the case the CLI cannot see: a summary answered
        // before this run's entry landed. The Last update ROW is not gated - "Last update ..." is
        // a true thing to say about an older entry. Only "this is what just happened" is not.
        loadLastRun(function(run) {
            root.postRunLine = Logic.runFinishedSince(run, root.updateStartedMs)
                ? Logic.postRunLine(run) : "";
        });
    }

    // The way out of an updating state nothing is going to end. A run ends when the CLI writes
    // state.json, and a terminal run that is aborted - the DEFAULT answer to the one question
    // Kempt asks, on the default configuration - exits before the CLI's own post-run check, as
    // does closing the window. Without this the popup sits on an empty pane with no list, no
    // Update Now and a disabled Refresh until the three-hour guard fires.
    //
    // The updating state is left when the check LANDS rather than at the press, so the popup comes
    // back with fresh counts. afterCheck is the same one-shot the hold round trip uses.
    function checkAgain() {
        if (!updating || checking) return;
        afterCheck = function () { root.leaveUpdating(); };
        doCheck();
    }

    // The newest log file, found once per run.
    // stateDir is NOT shellQuote'd, and that distinction is the whole rule: it is a shell
    // expression this file wrote, whose ${...} expansion is the point of it, and single quotes
    // would turn it into a literal directory name that cannot exist. shellQuote is for values that
    // came from OUTSIDE - package names, paths the CLI printed - which must never be interpreted.
    // Double quotes give stateDir its expansion and still survive a space in $HOME; the glob stays
    // outside them so it can still glob.
    function findLog() {
        tailExecutor.run("ls -1t \"" + stateDir + "\"/logs/*.log 2>/dev/null | head -1",
                         10000, function(stdout, stderr, rc) {
            root.logPath = Logic.firstLineOf(stdout);
        });
    }

    function pollLog() {
        // The RUNNING surface, not the configured one: a settings change mid-run does not move
        // where the transaction already in flight is writing.
        if (!updating || runningSurface !== "popup" || logPath === "") return;
        // One tail in flight at a time. The timer ticks every 2 seconds, and a `tail` that takes
        // longer than that would have the next tick queued behind it before it came back - from
        // there the queue only grows. Skipping a tick costs nothing: another is two seconds away
        // and reads the same file.
        if (tailExecutor.current) return;
        tailExecutor.run("tail -n 25 " + Logic.shellQuote(logPath), 10000, function(stdout, stderr, rc) {
            if (rc === 0) root.logTail = stdout;
        });
    }

    // What the last run DID, as data. `--json` and not the human `kempt summary`: the human form
    // is a rendering (`render_summary` in lib/common.sh), and re-deriving counts from a rendered
    // line would put a second, lossier copy of those rules in the widget.
    //
    // `kempt summary --json` prints NOTHING at all under exit 0 on a box with no history, and
    // Logic.lastRunOf answers null for that. null must stay null all the way to the screen: "no
    // last run" is a true thing to show, an empty run is not. `done` is optional, runs after
    // lastRun is set, and is handed THIS call's run - which is how the post-run line gets the run
    // that just finished rather than the one before it.
    //
    // The three-way contract is doCheck's: a usable answer wins whatever the exit code was;
    // "nothing, exit 0" means there are no runs; "nothing, non-zero" means we could not ask, so
    // the row keeps the last run we know about instead of blanking. `done` still fires there, with
    // null, so a run that ended while the CLI was unreachable says nothing at all.
    function loadLastRun(done) {
        executor.run(kemptCmd + " summary --json", 15000, function(stdout, stderr, rc) {
            var run = Logic.lastRunOf(stdout);
            if (run !== null || rc === 0) root.lastRun = run;
            if (done) done(run);
        });
    }

    // --- the popup opening and closing -------------------------------------------------------------

    // One read of the wall clock, shared by the tick and the open below, so there is only ever one
    // place the relative times get their "now" from.
    function refreshClock() {
        nowMs = Date.now();
    }

    // The popup came on screen. The clock first, so the very first frame says "4 min ago" rather
    // than whatever was true up to thirty seconds ago. Then the refresh, which is what keeps a
    // Refresh button from being the only way to answer "are these numbers current?" - guarded by
    // Logic.shouldRefreshOnOpen so it is not a blocking re-index on every open, and node pins
    // every boundary of that guard.
    //
    // No second in-flight guard here: doCheck already coalesces through `checking`/
    // `recheckPending`, and a second guard that could disagree with the first is how a popup ends
    // up unable to refresh at all after some sequence nobody tested.
    function popupOpened() {
        refreshClock();
        var lastSuccess = (kemptState && typeof kemptState.last_success === "string")
            ? kemptState.last_success : "";
        if (Logic.shouldRefreshOnOpen(lastSuccess, refreshIntervalMin, Date.now())) doCheck();
        root.popupShown();
    }

    // This file owns `expanded`, so it owns the news that the popup is on screen; what a surface
    // DOES about it is that surface's business. A signal rather than a call into the popup,
    // because the popup item is created lazily by AppletQuickItem and on the very open being
    // announced may not exist yet.
    signal popupShown()

    // ...and it went away. One event, one line at a time: the transient post-run line has been
    // seen, so the persistent Last update row takes over.
    function popupClosed() {
        postRunLine = "";
        // Same rule as doCheck: the apology is about a press the user has walked away from, and it
        // must not be waiting for them next time they open this.
        restartError = "";
    }

    // `expanded` is the engine's own property and the only honest source for this. It is also why
    // both branches are named functions: AppletQuickItem's setter dereferences the applet with no
    // null check, so outside plasmashell WRITING this property segfaults the process. A probe
    // cannot drive the popup open; it drives these two instead, and pins this line.
    onExpandedChanged: {
        if (root.expanded) root.popupOpened();
        else root.popupClosed();
    }

    // --- wiring --------------------------------------------------------------------------------
    Executor { id: executor }

    // A SECOND executor, for the log tail alone. The queue is strictly first-in-first-out, so a
    // 2-second tail sharing it with a 120-second check would put ~60 tails in front of everything
    // else and Refresh would appear dead for two minutes.
    Executor { id: tailExecutor }

    // ...and a THIRD, carrying one command: the restart prompt. `dbus-send` returns as soon as KDE
    // has been ASKED to draw its confirmation screen - no lock, milliseconds - but on the shared
    // queue it sits behind whatever is running, and a `kempt check` is allowed 120 seconds. The
    // popup's refresh-on-open makes a check in flight the LIKELY state at the moment somebody
    // reads the restart message and acts on it, and a button that appears to do nothing is
    // indistinguishable from a broken one. Its own instance rather than the tail's: an in-popup
    // run tails its log every two seconds, which is the same bug in miniature.
    Executor { id: promptExecutor }

    Timer {
        id: checkTimer
        // Clamped at BOTH ends, because this number comes from a text file a human can edit. A 0
        // interval on a repeating timer spins the panel process; a large enough one overflows
        // Timer's 32-bit interval when multiplied by 60000 and comes out NEGATIVE, which spins it
        // just the same.
        interval: Math.min(1440, Math.max(1, root.refreshIntervalMin)) * 60000
        repeat: true
        running: true
        onTriggered: root.doCheck()
    }

    // The bounded retry described on firstCheckRetries above. One-shot: doCheck arms it, and only
    // an empty answer arms it again.
    Timer {
        id: firstCheckRetry
        interval: 10000
        repeat: false
        onTriggered: root.doCheck()
    }

    // The clock behind "Checked 4 min ago", which is a lie within a minute of being drawn without
    // it. Only while the popup is open, and that is not an optimisation: this is a panel process,
    // and waking every thirty seconds to recompute text nobody is looking at costs battery for
    // nothing. The counts have their own timer.
    Timer {
        id: clockTimer
        interval: 30000
        repeat: true
        running: root.expanded
        onTriggered: root.refreshClock()
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
        // Only while a run is in flight AND the output is meant to land here. On any other surface
        // this never starts, so there is no tail process at all.
        running: root.updating && root.runningSurface === "popup" && root.expanded
        onTriggered: root.pollLog()
    }

    // The safety net on `updating`. A run ends when the CLI writes state.json - but a user who
    // closes the terminal window, or an update that dies, never writes it. Three hours is far
    // longer than any real transaction and far shorter than forever.
    Timer {
        id: updateGuard
        interval: 3 * 60 * 60 * 1000
        repeat: false
        onTriggered: {
            root.updating = false;
            root.runningSurface = "";
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
    // with the full representation's Layout.minimumWidth/Height. (The
    // `preferredRepresentation: Plasmoid.compactRepresentation` line copied around third-party
    // widgets is a no-op on Plasma 6: both properties live on PlasmoidItem, not on the Plasmoid
    // attached object, so that expression is undefined and the default heuristic runs anyway.)
    // Both inputs are handed down explicitly rather than reached for across files. They are
    // `required` on the other side, so a wiring mistake is a hard error at creation instead of a
    // panel that quietly renders the fallback branch of a guard.
    compactRepresentation: CompactRepresentation {
        plasmoidItem: root
        vm: root.vm
        iconSizeSetting: root.iconSizeSetting
    }
    fullRepresentation: FullRepresentation {
        plasmoidItem: root
        vm: root.vm
        // Escape. The popup asks; this is the only file allowed to answer, for the same reason the
        // open goes through popupOpened(): writing `expanded` outside plasmashell segfaults the
        // process, so the assignment lives here, next to the handler that reads the property back.
        onCloseRequested: root.expanded = false
    }

    // What the system tray does with this entry on "Auto". The tray reads this and nothing else,
    // and an applet that never sets a status is lower than PassiveStatus - so without this the
    // widget installs into the tray, is enabled there, and appears to do nothing at all.
    // ActiveStatus always: hiding the icon when there is nothing to report would be the widget
    // disappearing exactly when it is telling you the good news, and NeedsAttentionStatus forces
    // the entry back into view even when the user has deliberately hidden it.
    //
    // Assigned once here rather than declared as `Plasmoid.status:`, for the test kit rather than
    // taste: `Plasmoid` is an ATTACHED object backed by a real Plasma applet, so a declarative
    // assignment makes creating that applet a precondition of creating this file - and outside
    // plasmashell there is none, so every QML probe dies with it. The value never changes.
    // The try/catch is why this needs a witness: a swallowed exception and a line that was never
    // called look identical from outside, and either would silently put the widget back to being
    // installed in the tray, enabled, and invisible.
    property bool trayPresenceClaimed: false

    function claimTrayPresence() {
        try {
            Plasmoid.status = PlasmaCore.Types.ActiveStatus;
            root.trayPresenceClaimed = true;
        } catch (e) {
            // No applet behind us: a test harness, not a panel. Say so anyway, because the same
            // catch would swallow a real Plasma API change whose only symptom in a panel is a tray
            // entry that never appears.
            console.warn("kempt: could not claim tray presence:", e);
        }
    }

    // Check for Updates, as a menu entry rather than a button. A QAction in
    // Plasmoid.contextualActions lands in the tray heading's "More actions" menu AND in the tray
    // icon's right-click menu, which is the only channel a plasmoid HAS into the tray's chrome
    // (BasicPlasmoidHeading's extraControls is hidden in the tray by its own design).
    // The literal is repeated from Logic.COPY.checkForUpdates rather than read out of it, because
    // translation extraction works on literals - see the note at the top of logic.js.
    PlasmaCore.Action {
        id: checkAction
        text: i18n("Check for Updates")
        icon.name: "view-refresh"
        onTriggered: root.doCheck()
    }

    // Assigned imperatively, in a try, with a witness - same shape and reason as claimTrayPresence.
    // Measured: `Plasmoid.contextualActions` reads back undefined outside plasmashell and the
    // assignment is a silent no-op, whose only symptom in a real panel is an entry missing from a
    // menu. Array assignment rather than `.push()`, which needs the list property to already be
    // readable and throws here before anything is registered.
    property bool contextualActionsClaimed: false

    function claimContextualActions() {
        try {
            Plasmoid.contextualActions = [checkAction];
            root.contextualActionsClaimed = true;
        } catch (e) {
            console.warn("kempt: could not register the contextual action:", e);
        }
    }

    Component.onCompleted: {
        readInterval();
        readSurface();
        readIconSize();
        readRestartReminder();
        // Before any run happens in this session, so the popup's Last update row has something
        // true to say the first time it is opened.
        loadLastRun();
        doCheck();
        claimTrayPresence();
        claimContextualActions();
    }
}
