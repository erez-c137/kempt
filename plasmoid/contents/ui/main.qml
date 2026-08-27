// The widget's state machine. It owns exactly three things: the parsed CLI state, whether a run
// is in flight, and the view model derived from those two. Everything else - the panel icon, the
// badge, the tooltip, the popup - is a binding onto `vm` and holds no state of its own.
//
// Nothing here parses or decides anything: that is all in logic.js, which node can test. Nothing
// here runs a command directly either: that is Executor.qml, which serializes and hard-timeouts
// every call so a slow dnf can never block the panel process.
import QtQuick
import org.kde.plasma.core as PlasmaCore
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
    // How many times we have re-asked after a check that answered with NOTHING. `kempt check`
    // prints an empty line and exits 0 when another check already holds the lock, and on a fresh
    // login that is the ordinary case rather than the exotic one: the CLI's own refresh is very
    // often still running when plasmashell starts us. The answer to that is "keep the last known
    // state" - but at startup there is no last known state, so the panel sat dim, said "no data
    // yet", and had nothing to change its mind until the hourly checkTimer came round.
    property int firstCheckRetries: 0
    readonly property int maxFirstCheckRetries: 3

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
    // How big the panel icon should be: `auto`, or one of the three named steps. Validated HERE
    // rather than by the CLI - `kempt config set` checks that a key looks like a key and stores
    // whatever value it is given, so a typo, an older CLI that answers with an empty line, and a
    // value written by a future version all arrive the same way. Logic.resolveIconSizeSetting
    // turns every one of them into `auto` without a word of complaint, which is the right
    // behaviour for a panel icon: it draws, at a sensible size, no matter what the file says.
    property string iconSizeSetting: "auto"
    // Whether the popup may REMIND the user that a restart is owed (`restart_reminder`, default
    // true). Not whether a restart is owed - that is the state file's `reboot_needed`, and it is a
    // fact rather than a reminder: with this off the message and its button disappear and the
    // status line still ends "restart pending". Read from the CLI like every other setting.
    property bool restartReminder: true

    // ...and whether the user closed that message in THIS plasmashell session.
    //
    // Deliberately not persisted, and this is the whole argument for it: a dismissal written to
    // disk is a promise to remember something across a restart, and a restart is the exact event
    // that makes the underlying fact go away. The user would come back from the reboot they were
    // being reminded about to a widget that had carefully remembered not to mention it - and if
    // the same box owed a restart again a week later, the reminder they never turned off would
    // stay silent. Session-only means the answer is always about the machine as it is now.
    // Somebody who never wants the message turns the setting off; that IS the durable answer.
    property bool restartDismissed: false

    // Our own report of a restart prompt that could not be opened. Empty means nothing to say.
    // Kept apart from actionMessage because it belongs to the restart message rather than to the
    // buttons: the popup shows it where the user pressed, which is the only place they are
    // looking. Silence here would be the worst outcome of all - a button that appears to do
    // nothing is indistinguishable from a button that did something invisible.
    property string restartError: ""

    // The newest history entry as DATA (`kempt summary --json` through Logic.lastRunOf), or null
    // on a box that has never run an update. null is a first-class value: it renders as no last
    // run at all, never as a fabricated empty one that claims a run which changed no packages.
    property var lastRun: null

    // The transient line about a run WE started - "Updated 4 packages in 2s", or why it failed.
    // Replaces what this file used to paste into actionMessage: the first line of the human
    // `kempt summary`, which is an ISO timestamp and no answer to "what just happened?".
    // The rule it lives under is one event, one line at a time: while this is on screen the
    // persistent Last update row is hidden, and it clears when the popup closes or a check starts.
    property string postRunLine: ""

    // When the run we are watching STARTED, as milliseconds. Only meaningful while `updating` is
    // true, and 0 means we never saw one start.
    //
    // It exists for one sentence: the transient post-run line, which is the only thing in this
    // popup that claims to describe the run the user just started. `kempt summary --json` answers
    // with the newest history entry it can read - normally that run's - and this is what lets
    // Logic.runFinishedSince check that the entry we got back is actually from after we started
    // watching, rather than the run before it.
    property double updateStartedMs: 0

    // The clock the relative times ("Checked 4 min ago") are measured against, refreshed while the
    // popup is open and never while it is shut. 0 means "no clock yet", which logic.js answers by
    // falling back to the absolute stamp - never a wrong relative time.
    property double nowMs: 0

    // The single derived value. Re-evaluated by the engine whenever either input changes, which is
    // why nothing below ever recomputes or caches a label. null is a first-class input here: it
    // renders as "unknown", never as "zero updates".
    //
    // The three extras are the facts that are NOT in the state file: the clock, and the two halves
    // of the restart reminder. They go in as an object rather than as more positional arguments so
    // that a caller who does not know about one of them (the node tests' three-argument calls)
    // keeps working, and so that adding the next one is not a signature change.
    readonly property var vm: Logic.viewModel(kemptState, updating, cliError,
                                              { nowMs: nowMs,
                                                restartReminder: restartReminder,
                                                restartDismissed: restartDismissed })

    // --- the CLI -------------------------------------------------------------------------------
    // plasmashell does not necessarily inherit a login shell's PATH, and install.sh puts the CLI
    // in ~/.local/bin. The prefix makes the widget find it either way: from a symlink install or
    // from a package that dropped `kempt` in /usr/bin. The engine runs the string through a
    // shell, so a per-command assignment is all this needs to be.
    //
    // KEMPT_VIA=widget rides along on the same assignment. It changes nothing about what the CLI
    // does - it is read in exactly one place, lib/common.sh's log_event, which stamps each line
    // of `kempt log` with `widget` or `cli`. That is the difference between "did my click land?"
    // and "something changed this setting at 21:10", and it costs one word per command.
    readonly property string kemptCmd: "PATH=\"$HOME/.local/bin:$PATH\" KEMPT_VIA=widget kempt"

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
        // A check is the next event, so the last one's line has had its moment. Cleared BEFORE the
        // coalesce guard on purpose: a Refresh pressed while a check is already running is still
        // the user asking for the next thing, and a transient line that survived it would sit
        // there over counts it no longer describes.
        //
        // Ordering with leaveUpdating(), because the two run back to back at the end of every run
        // and the wrong order would mean the post-run line NEVER appeared. leaveUpdating queues
        // `summary --json` and doCheck runs its clear synchronously, so the clear happens first
        // and the callback that sets the line lands after it. The Executor's queue is strictly
        // first-in-first-out, which is what makes that a rule rather than a race.
        postRunLine = "";
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
                // ...and the last run may not be the one we knew about. A `kempt update` typed in
                // a terminal writes a history entry and then re-checks itself, and that state
                // write is what brought us here - so this is the moment the Last update row would
                // otherwise start lying about a run it never saw.
                root.loadLastRun();
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
                return;
            }
            // Still nothing to show, and nothing of our OWN to report either (a missing CLI sets
            // cliError and the popup says so - that is an answer, and re-asking would not change
            // it). An empty answer is a lock we lost, so ask again shortly instead of leaving the
            // panel dim for an hour. Bounded on purpose: a box where the lock is genuinely wedged
            // must not turn into a widget forking a check every ten seconds forever, so after the
            // last attempt this defers to checkTimer like any other check.
            if (root.kemptState === null && root.cliError === "") {
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
                if (delta.config) {
                    root.readInterval(); root.readSurface(); root.readIconSize();
                    root.readRestartReminder();
                }
                return;
            }

            // Cheap enough to do unconditionally (two `config get` calls) and it is the only way
            // a settings apply reaches this file. include_flatpak can change what is pending, so
            // the check below has to happen either way.
            root.readInterval();
            root.readSurface();
            root.readIconSize();
            root.readRestartReminder();
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

    // The panel icon's size preference. Read on the same schedule as the two above - at load, and
    // again whenever the config file moves - so the settings page reaches the panel icon through
    // the same 30-second back-channel as everything else, and so does `kempt config set` typed in
    // a terminal. A read that fails or answers with nothing leaves the current setting alone;
    // anything it does answer is put through the validator before it can reach a binding.
    function readIconSize() {
        executor.run(kemptCmd + " config get widget_icon_size", 10000, function(stdout, stderr, rc) {
            var v = Logic.firstLineOf(stdout);
            if (rc === 0 && v !== "") root.iconSizeSetting = Logic.resolveIconSizeSetting(v);
        });
    }

    // Whether the popup may remind the user about an owed restart. Same schedule and same guard as
    // the three above: an older CLI prints an empty line and exits 0 for a key it has never heard
    // of, and isTrue("") is false - which is the value that would silently switch the reminder off
    // on a box whose setting is true. No answer means keep what we have, which at load is the
    // CLI's own default.
    function readRestartReminder() {
        executor.run(kemptCmd + " config get restart_reminder", 10000, function(stdout, stderr, rc) {
            var v = Logic.firstLineOf(stdout);
            if (rc === 0 && v !== "") root.restartReminder = Logic.isTrue(v);
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

    // The restart, ASKED FOR and never performed.
    //
    // `org.kde.LogoutPrompt.promptReboot` opens KDE's own confirmation screen: it is cancellable,
    // running sessions get the chance to object and save, and it honours whatever the user has set
    // about confirming logouts. `/usr/bin/plasma-shutdown` carries a SECOND family of methods that
    // take no answer and simply reboot - and Kempt must NEVER restart anybody's machine. The
    // introspection XML for both was read off this box (`/usr/libexec/ksmserver-logout-greeter`)
    // and is quoted in docs/research/2026-08-26-popup-panel/hig-review.md section 1a; the
    // difference between them is one service name and one method name.
    //
    // Neither of those two names appears anywhere under plasmoid/contents/ui/, and tests/qml/
    // probe_popup.py asserts exactly that by grepping this directory - so they are spelled out
    // there, in the test that forbids them, and deliberately not here. A pin that tolerated the
    // strings in a comment is a pin that a future edit can satisfy by writing a comment.
    //
    // The service is D-Bus activatable (/usr/share/dbus-1/services/org.kde.LogoutPrompt.service),
    // so nothing has to be running first. Ten seconds is a generous timeout for a call that
    // returns as soon as the prompt has been ASKED for - it does not wait for an answer, and it
    // must not: the user may sit and think about it, and the executor queue is shared.
    function promptRestart() {
        restartError = "";
        // promptExecutor, never the shared one - see its declaration for the two minutes of
        // silence that came of queueing this behind a check.
        promptExecutor.run("dbus-send --session --dest=org.kde.LogoutPrompt --type=method_call"
                     + " /LogoutPrompt org.kde.LogoutPrompt.promptReboot", 10000,
                     function(stdout, stderr, rc) {
            if (rc !== 0) root.restartError = Logic.COPY.restartFailed;
        });
    }

    // Closing the restart message. Session-only by design - see restartDismissed above for why
    // persisting it would be a promise this widget cannot honour. Nothing is written, nothing is
    // asked of the CLI, and logic.js turns the flag into a message that is gone and a status line
    // that now ends "restart pending", so the popup stops nagging without starting to lie.
    function dismissRestart() {
        restartDismissed = true;
    }

    // Show Log. The desktop's own handler opens it, so the user gets whatever they have chosen for
    // a text file rather than whatever this widget would have picked.
    //
    // The path came out of the CLI's JSON and is going back onto a command line, which puts it in
    // the same class as a package name: through Logic.shellQuote, no exceptions. xdg-open is used
    // on the log path and on nothing else in this file - it is a "open this with whatever is
    // registered" verb, and the set of things it is allowed to be pointed at should stay this
    // small and this obvious.
    function showLog(path) {
        actionMessage = "";
        var target = String(path === undefined || path === null ? "" : path).trim();
        // A history entry old enough (or damaged enough) to have no log is an ordinary event, not
        // corruption - and `xdg-open ''` opens the user's home directory, which is a confusing
        // answer to "show me that log".
        if (target === "") {
            actionMessage = "That run did not record a log file.";
            return;
        }
        executor.run("xdg-open " + Logic.shellQuote(target), 10000, function(stdout, stderr, rc) {
            // The path is in the message on purpose: whatever went wrong with the handler, the
            // user can still open that file themselves, and nothing else the widget could say
            // would be as useful.
            if (rc !== 0) {
                root.actionMessage = "Could not open " + target
                    + (Logic.firstLineOf(stderr) !== "" ? " - " + Logic.firstLineOf(stderr) : ".");
            }
        });
    }

    // --- the updating state ----------------------------------------------------------------------

    function enterUpdating() {
        updating = true;
        // Noted BEFORE anything is launched, so the entry the run writes can only ever be stamped
        // at or after this - see updateStartedMs, and Logic.runFinishedSince for the comparison.
        updateStartedMs = Date.now();
        logTail = "";
        logPath = "";
        updateGuard.restart();
        if (effectiveSurface === "popup") findLog();
    }

    function leaveUpdating() {
        if (!updating) return;
        updating = false;
        updateGuard.stop();
        // The transient line is DERIVED from the entry, so the entry has to arrive first. The
        // executor is callback-based, so "first" means inside the callback - setting the line
        // after the call would read the PREVIOUS run's entry every single time, and on a box
        // whose first run this is, no entry at all.
        //
        // ...and it is only spoken for an entry that is actually OURS. The CLI is the primary
        // guard here (`summary --json` answers with nothing rather than serving the run underneath
        // an unreadable newest entry); runFinishedSince is the belt to that braces, and covers the
        // case the CLI cannot see - a summary answered before this run's entry landed. Note the
        // row itself is NOT gated: loadLastRun has already set `lastRun`, and "Last update ..." is
        // a true thing to say about an older entry. Only "this is what just happened" is not.
        loadLastRun(function(run) {
            root.postRunLine = Logic.runFinishedSince(run, root.updateStartedMs)
                ? Logic.postRunLine(run) : "";
        });
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

    // What the last run DID, as data. `--json` and not the human `kempt summary`, because the
    // human form is a rendering (`render_summary` in lib/common.sh) and re-deriving counts from a
    // rendered line would put a second, lossier copy of those rules in the widget. This asks the
    // CLI the question the popup actually has: which packages, how many, how long, which log.
    //
    // `kempt summary --json` prints NOTHING at all under exit 0 on a box with no history, and
    // Logic.lastRunOf answers null for that. null is the answer, and it must stay null all the way
    // to the screen: "no last run" is a true thing to show, an empty run is not.
    //
    // `done` is optional, runs after lastRun is set, and is handed THIS call's run - which is how
    // the post-run line gets the run that just finished rather than the one before it.
    //
    // The three-way contract is doCheck's, for the same reason: a usable answer wins whatever the
    // exit code was; "nothing, exit 0" is the CLI saying there are no runs and is a real answer;
    // "nothing, non-zero" means we could not ask, and the row keeps showing the last run we do
    // know about instead of blanking. `done` still fires in that case, with null - so a run that
    // ended while the CLI was unreachable says nothing at all rather than describing the run
    // before it.
    function loadLastRun(done) {
        executor.run(kemptCmd + " summary --json", 15000, function(stdout, stderr, rc) {
            var run = Logic.lastRunOf(stdout);
            if (run !== null || rc === 0) root.lastRun = run;
            if (done) done(run);
        });
    }

    // --- the popup opening and closing -------------------------------------------------------------

    // One read of the wall clock, shared by the tick and by the open below so there is only ever
    // one place the relative times get their "now" from.
    function refreshClock() {
        nowMs = Date.now();
    }

    // The popup came on screen.
    //
    // The clock first, so the very first frame says "4 min ago" rather than whatever was true up
    // to thirty seconds before the user looked.
    //
    // Then the refresh: Plasma's own popups mostly have no Refresh button at all because they
    // refresh themselves on open (the NetworkManager and Bluetooth applets ship no such string),
    // and answering "are these numbers current?" before the user has to ask is the whole reason.
    // The staleness guard is what keeps it from being dnfdragora's blocking re-index on open: it
    // fires only when the last SUCCESSFUL check is older than the smaller of the configured
    // interval and five minutes, and refuses on a clock that has moved. All of that lives in
    // Logic.shouldRefreshOnOpen where node pins every boundary of it.
    //
    // No second in-flight guard here. doCheck already coalesces through `checking`/`recheckPending`
    // - and a second guard that could disagree with the first is how a popup ends up unable to
    // refresh at all after some sequence nobody tested.
    function popupOpened() {
        refreshClock();
        var lastSuccess = (kemptState && typeof kemptState.last_success === "string")
            ? kemptState.last_success : "";
        if (Logic.shouldRefreshOnOpen(lastSuccess, refreshIntervalMin, Date.now())) doCheck();
        root.popupShown();
    }

    // ...and last, the announcement. This file owns `expanded`, so it owns the news that the popup
    // is on screen; what any given surface DOES about it is that surface's business - today
    // FullRepresentation puts the keyboard on Update Now, and nothing here needs to know that.
    // A signal rather than a call into the popup, because the popup item is created lazily by
    // AppletQuickItem: reaching for it from here would be reaching for something that, on the very
    // open being announced, may not exist yet.
    signal popupShown()

    // ...and it went away. The transient post-run line was about one event and it has now been
    // seen, so the persistent Last update row takes over: one event, one line at a time.
    function popupClosed() {
        postRunLine = "";
    }

    // `expanded` is the engine's own property and the only honest source for this. It is also the
    // reason both branches are named functions: AppletQuickItem's setter dereferences the applet
    // with no null check, so outside plasmashell WRITING this property segfaults the process - a
    // probe cannot drive the popup open. It drives these two instead, and pins this line.
    onExpandedChanged: {
        if (root.expanded) root.popupOpened();
        else root.popupClosed();
    }

    // --- wiring --------------------------------------------------------------------------------
    Executor { id: executor }

    // A SECOND executor, for the log tail alone. The queue is strictly first-in-first-out, so a
    // 2-second tail sharing it with a 120-second check would put ~60 tails in front of everything
    // else - the Refresh button would appear dead for two minutes. Separating them means the tail
    // can never delay an action, and an action can never stall the tail.
    Executor { id: tailExecutor }

    // ...and a THIRD, carrying one command: the restart prompt. Same rule as the tail and the
    // opposite reason - this one is not fast and periodic, it is instant and rare, and it has no
    // work behind it at all. `dbus-send` returns as soon as KDE has been ASKED to draw its
    // confirmation screen: no lock, no package database, milliseconds.
    //
    // On the shared queue it sat behind whatever was running, and a `kempt check` is allowed 120
    // seconds. So the user pressed Restart..., nothing happened, and nothing on screen said why -
    // which is indistinguishable from a broken button, and the popup's own refresh-on-open makes
    // a check in flight the LIKELY state at the moment somebody reads that message and acts on it.
    // Its own instance rather than sharing the tail's: a run showing its log in the popup tails it
    // every two seconds, and a prompt waiting behind one of those is the same bug in miniature.
    Executor { id: promptExecutor }

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

    // The bounded retry described on firstCheckRetries above. One-shot: doCheck arms it, and only
    // an empty answer arms it again.
    Timer {
        id: firstCheckRetry
        interval: 10000
        repeat: false
        onTriggered: root.doCheck()
    }

    // The clock behind "Checked 4 min ago". Without it that line is a lie within a minute of being
    // drawn: the popup stays open, nothing re-evaluates, and it still says "4 min ago" when
    // the honest answer is twenty.
    //
    // Only while the popup is open, and that is not an optimisation: this is a panel process, and
    // a widget that wakes every thirty seconds to recompute text nobody is looking at is a widget
    // that costs battery for nothing. The counts have their own timer; this one is about the
    // wording of a line that only exists on screen.
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
        iconSizeSetting: root.iconSizeSetting
    }
    fullRepresentation: FullRepresentation {
        plasmoidItem: root
        vm: root.vm
        // Escape. The popup asks; this is the only file allowed to answer, for the same reason the
        // open goes through popupOpened(): writing `expanded` outside plasmashell segfaults the
        // process, so the popup states the intent and the assignment lives here, once, next to the
        // handler that reads the property back.
        onCloseRequested: root.expanded = false
    }

    // What the system tray does with this entry when the user leaves it on "Auto". The tray reads
    // this and nothing else: PassiveStatus tucks an entry away behind the expander arrow, and an
    // applet that never sets a status is lower than passive - so without this the widget would
    // install into the tray, be enabled there, and appear to do nothing at all.
    //
    // Always active, deliberately, and that is a product decision rather than a technical one.
    // Kempt's whole promise is a badge that is simply THERE and truthful, so hiding the icon on
    // the days there is nothing to report would be the widget disappearing exactly when it is
    // telling you the good news. NeedsAttentionStatus is the other tempting value and is worse:
    // it makes the tray force the entry back into view even when the user has deliberately hidden
    // it, which is not a thing an update notifier should do to somebody. A user who wants it out
    // of the way sets this entry to Hidden in the tray's own settings, and that choice sticks.
    //
    // Assigned once here rather than declared as `Plasmoid.status:` above, and the reason is the
    // test kit rather than taste. `Plasmoid` is an ATTACHED object backed by a real Plasma applet;
    // a declarative assignment makes creating it a precondition of creating this file at all, and
    // outside plasmashell there is no applet, so main.qml stops instantiating and every QML probe
    // dies with it. The value never changes, so one assignment is exactly equivalent - and it runs
    // last, after the reads above, so the catch below can only ever swallow this one line.
    //
    // The try/catch is why this needs a witness. A swallowed exception and a line that was never
    // called look identical from outside, so deleting the call below - or letting the assignment
    // start throwing after a Plasma API change - would silently put the widget back to being
    // installed in the tray, enabled, and invisible. This property is set INSIDE the try, after
    // the assignment, so the probe can assert the claim was actually made.
    property bool trayPresenceClaimed: false

    function claimTrayPresence() {
        try {
            Plasmoid.status = PlasmaCore.Types.ActiveStatus;
            root.trayPresenceClaimed = true;
        } catch (e) {
            // No applet behind us: a test harness, not a panel. Nothing to tell a tray about -
            // but say so, because the same catch would swallow a real Plasma API change and the
            // only symptom in a panel is a tray entry that never appears.
            console.warn("kempt: could not claim tray presence:", e);
        }
    }

    // Check for Updates, as a menu entry rather than a button.
    //
    // The popup's own Refresh button is one click, and it is the one a user reaches for while the
    // popup is open. This is the other route: a QAction in Plasmoid.contextualActions lands in the
    // system tray heading's "More actions" menu AND in the tray icon's right-click menu, which is
    // where a Plasma user's hand goes first and is the only channel a plasmoid HAS into the tray's
    // chrome (there is no API for putting a control in that heading - BasicPlasmoidHeading's
    // extraControls is hidden in the tray by its own design). org.kde.plasma.vault ships exactly
    // this pairing: one action, registered here and offered as a button too.
    //
    // The literal is repeated from Logic.COPY.checkForUpdates rather than read out of it, because
    // translation extraction works on literals - see the note at the top of logic.js. The probe
    // asserts the two are identical, which is the half a human would get wrong.
    PlasmaCore.Action {
        id: checkAction
        text: i18n("Check for Updates")
        icon.name: "view-refresh"
        onTriggered: root.doCheck()
    }

    // Assigned imperatively, in a try, with a witness - the same shape and the same reason as
    // claimTrayPresence above. `Plasmoid` is an attached object backed by a real Plasma applet;
    // a declarative `Plasmoid.contextualActions:` makes creating that applet a precondition of
    // creating this file at all, and outside plasmashell there is no applet, so every QML probe
    // would die with it. Measured out here: `Plasmoid.contextualActions` reads back undefined and
    // the assignment is a silent no-op, exactly like the status assignment - which is why the
    // witness exists. A swallowed exception and a line that was never called look identical from
    // outside, and the only symptom in a real panel is an entry missing from a menu.
    //
    // Array assignment rather than `.push()`: push is what org.kde.desktopcontainment uses, but it
    // needs the list property to already be readable, and here it throws before anything is
    // registered at all.
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
        // true to say the first time it is opened rather than filling in after the first check.
        loadLastRun();
        doCheck();
        claimTrayPresence();
        claimContextualActions();
    }
}
