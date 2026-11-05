// The settings page. Every value on it is read from and written to `kempt config` - there is no
// plasmoid-local copy of any of these settings, and contents/config/main.xml declares no keys at
// all. A KConfig entry here would be a second copy of a setting the CLI also owns, and the two
// would drift apart the first time somebody typed `kempt config set` in a terminal.
//
// The shell builds this page in its own dialog, so it cannot reach main.qml (there is no rootItem
// to call through). It does not need to: main.qml watches the config file, so writing it here is
// what makes the widget re-read its interval, its surface and its pending list. That back-channel
// is a 30-second mtime poll (main.qml, watchCmd), which is the whole latency budget of this page -
// nothing here waits on, or reports, the widget having noticed.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import "logic.js" as Logic

KCM.SimpleKCM {
    id: page

    // Same prefix main.qml uses: plasmashell does not reliably inherit a login shell's PATH, and
    // the same KEMPT_VIA=widget stamp, so a setting changed here is distinguishable in `kempt log`
    // from one typed in a terminal.
    readonly property string kemptCmd: "PATH=\"$HOME/.local/bin:$PATH\" KEMPT_VIA=widget kempt"

    // Every write this page dispatches goes through here, and this is why.
    //
    // The dialog's OK button is `applyAction.trigger(); configDialog.close()`
    // (AppletConfiguration.qml). trigger() calls saveConfig() below, which DISPATCHES the writes
    // and returns; close() then runs in the same turn. PlasmaQuick::ConfigView deletes itself on
    // hide, taking this page, cfgExecutor and its DataSource with it; the engine then drops the
    // container nobody is connected to any more, deleting the KProcess behind it - and a KProcess
    // destructor SIGKILLs its child, which is the `sh` running our command. So an OK press is a
    // race between a `kempt config set` (about 10 ms) and a teardown a couple of event-loop hops
    // away, and the write can lose it. Apply never had the problem, because nothing is destroyed.
    //
    // `<cmd> & wait $!` settles it: the work is forked into a background job, so the SIGKILL that
    // arrives for the `sh` pid reaches a shell doing nothing but waiting - the job itself is never
    // signalled and finishes on its own. `wait $!` (not a bare `&`) keeps the normal path intact by
    // propagating the job's real exit status, so setIfChanged's rc handling, "Apply stays lit on a
    // failed write" and the error label all still see what the CLI said. Executor appends its
    // ` #kemptN` dedup tag after this; `#kemptN` begins a word, so sh reads it as a comment.
    //
    // Deliberately NOT applied to the reads on this page (a lost `config get` costs nothing - the
    // page is gone), and never to main.qml's action executor, whose timeout has to be able to kill
    // a wedged `kempt check` outright. See Executor.qml's header.
    function durable(cmd) {
        return cmd + " & wait $!";
    }

    // What `kempt config get` said when this page opened. Apply compares against these and writes
    // ONLY what actually changed - so a key the user never touched is never rewritten, and a value
    // set from the CLI that this page cannot represent is left exactly as it was.
    property var loaded: ({})
    // Keys whose `config get` did not answer. Their stored value is unknown, and a key whose
    // stored value is unknown must not be written from a control that is still showing this file's
    // own default - see setIfChanged.
    property var readFailed: ({})
    // Keys the USER moved on this page. The one case where a value may be written over a key we
    // could not read: it is theirs, not a default.
    property var touched: ({})
    property int pendingReads: 0
    // Until every read has landed, the controls are showing QML defaults rather than settings.
    readonly property bool loading: pendingReads > 0
    property string loadError: ""
    property var holds: []
    property bool holdsBusy: false
    // Services muted with Mute Until It Starts, from `kempt startup --json`, and the last one
    // unmuted here, which Undo mutes again. Actions, like the holds: they run at once, not on Apply.
    property var muted: []
    property bool mutedBusy: false
    property var lastUnmuted: null
    property string passwordlessResult: ""
    property bool passwordlessBusy: false
    // Discover's update notifier: what to say and which button to offer (Logic.discoverSettingOf),
    // or null to show nothing. An action, like the password buttons: it runs at once, not on Apply.
    property var discoverSetting: null
    property bool discoverBusy: false
    property string discoverResult: ""

    // Writes dispatched by the current Apply that have not answered yet, and whether any of them
    // came back non-zero. Together they decide WHEN the page is allowed to call itself saved -
    // see saveConfig/finishWrite below.
    property int outstandingWrites: 0
    property bool writeFailed: false
    // The same fact under a name worth reading: an Apply is in flight. Nothing binds to it today
    // (the controls stay live while a save runs - the values were taken at dispatch time, so
    // editing them again is safe and the next Apply will write them). It exists because "is a
    // write outstanding" is the question this page's apply path turns on, and the probes ask it by
    // name rather than by counter arithmetic.
    readonly property bool saving: outstandingWrites > 0

    // THE hook that makes the dialog's Apply button work, and it has to be spelled exactly this
    // way. AppletConfiguration.qml decides whether Apply is clickable in one line:
    //
    //   applyButton.enabled = wasConfigurationChangedSignalSent || isConfigurationChanged()
    //                         || (app?.pageStack?.currentItem?.unsavedChanges ?? false)
    //
    // ...recomputed on three signals: a `cfg_<key>Changed` from an auto-bound KConfig property, a
    // `configurationChanged()` the page emits, or `unsavedChangesChanged`. This page has no cfg_
    // properties BY DESIGN, so the first two hooks do not exist here and Apply sits permanently
    // greyed out - the page would work only if the user pressed OK. Declaring this property gives
    // the shell its third hook for free, since QML emits unsavedChangesChanged on every write.
    //
    // It is also what makes closing the dialog safe: the shell's closing() prompts "apply or
    // discard?" only when the Apply button is enabled, so with no hook a page full of changes
    // closes silently and throws them away.
    property bool unsavedChanges: false

    // Every control's change handler calls this - and only from a signal the USER can cause
    // (onToggled, onValueModified). Never onCheckedChanged/onValueChanged: those also fire when
    // the reads below populate the page, which would arm Apply before anyone touched anything.
    function markChanged(key) {
        page.touched[key] = true;
        page.unsavedChanges = true;
    }

    // The dialog's Apply and OK both land here (the shell calls saveConfig() on the current page).
    // Nothing is written anywhere else.
    function saveConfig() {
        // Nothing has been read yet, so every control below is still showing this file's own
        // default - and writing those would replace the user's stored settings with them. The
        // controls are disabled while the reads are in flight, but the dialog's Apply and OK
        // belong to the shell and are offered regardless, so the guard lives here too.
        if (page.pendingReads > 0) return;
        // An Apply while the previous one is still in flight would reset the counter below out
        // from under callbacks that have not fired yet, and each of those would then decrement a
        // fresh count. The writes already dispatched cover everything on the page anyway.
        if (page.outstandingWrites > 0) return;

        page.writeFailed = false;
        // The sentinel. setIfChanged is dispatched once per key below, and a naive count would
        // pass through zero after the FIRST write answered - clearing unsavedChanges while the
        // rest were still queued. Holding one notional write open across the whole dispatch means
        // the count can only reach zero after every setIfChanged has had its say.
        page.outstandingWrites = 1;
        setIfChanged("include_flatpak", includeFlatpak.checked ? "true" : "false");
        setIfChanged("surface", page.selectedSurface());
        setIfChanged("refresh_interval_min", String(interval.value));
        setIfChanged("notify_startup", notifyStartup.checked ? "true" : "false");
        setIfChanged("reclaim", page.reclaimKey);
        finishWrite();      // release the sentinel
    }

    // The ONLY place unsavedChanges is cleared, and it is reached only when the last write has
    // landed. Clearing it at the end of saveConfig() instead is the page telling the shell "saved"
    // the instant it has finished DISPATCHING: Apply greys out and closing the dialog stops
    // prompting while `kempt config set` calls are still queued behind ANSWER_TIMEOUT_MS (40
    // seconds each), so the user can close the dialog on a write that has not happened yet and get
    // no warning.
    //
    // With nothing to write this still runs immediately - the sentinel is the only outstanding
    // write - so an Apply that legitimately writes nothing is clean at once.
    function finishWrite() {
        page.outstandingWrites--;
        if (page.outstandingWrites > 0) return;
        // A write that came back non-zero leaves Apply live for the retry rather than looking
        // finished. The retry semantics already exist: a failed write is not recorded as the
        // stored value, so the next Apply attempts it again instead of comparing equal.
        if (page.writeFailed) return;
        page.unsavedChanges = false;
    }

    function setIfChanged(key, value) {
        // A key whose read never answered has no known stored value: `loaded[key]` is undefined, so
        // the comparison below would call it changed and write this file's default straight over
        // whatever the user actually has. The exception is a control the user deliberately moved.
        if (page.readFailed[key] && !page.touched[key]) return;
        if (page.loaded[key] === value) return;
        // Counted before it is dispatched, and only here, past both guards above: those return
        // without writing anything, and a write that was never made must not hold the page open.
        page.outstandingWrites++;
        // The value is ours (a checkbox state, a number, one of four known surfaces) but it is
        // quoted anyway. The rule this file follows is that everything reaching a command line is
        // quoted, with no per-case judgement about which values are "obviously safe".
        // ANSWER_TIMEOUT_MS: a write takes the CLI's writers' lock, which waits up to 30 s.
        cfgExecutor.run(page.durable(kemptCmd + " config set " + key + " " + Logic.shellQuote(value)),
                        Logic.ANSWER_TIMEOUT_MS, function (stdout, stderr, rc) {
            if (rc !== 0) {
                page.loadError = Logic.answerOutcomeOf(rc, "", stderr, "",
                                                       i18n("Kempt did not answer in time. The setting may not have changed. Try again.")).text
                                 || ("Could not save " + key + ".");
                // Apply stays on, so the retry is one click rather than a reopened dialog.
                page.writeFailed = true;
                page.unsavedChanges = true;
                page.finishWrite();
                return;
            }
            // Recorded as the stored value only now that it IS the stored value. Recording it
            // before the CLI answered means a FAILED write is remembered as a success: the next
            // Apply compares equal, writes nothing, and the setting the user asked for quietly
            // stays as it was, with no second attempt possible short of changing it twice.
            page.loaded[key] = value;
            page.readFailed[key] = false;
            page.finishWrite();
        });
    }

    // The chosen surface lives HERE, not in the radio buttons. Reading it back out of the delegates
    // looks equivalent and is not: a Repeater whose items are not currently realised answers
    // "nothing is checked", and Apply would then write the wrong value over whatever the user
    // actually had. The view renders this property; it is never the source of it.
    property string surfaceKey: Logic.DEFAULT_SURFACE

    function selectedSurface() {
        return page.surfaceKey;
    }

    function applySurface(key) {
        page.surfaceKey = Logic.resolveSurface(key);
    }

    // The unused-runtimes setting, held here for the same reason as surfaceKey: a Repeater whose
    // delegates are not currently realised reports nothing as checked, and Apply would then write
    // this file's first option over whatever the user has stored.
    property string reclaimKey: "ask"

    // Whether flatpak is installed, asked the way the CLI's flatpak_present asks. True until the
    // answer says otherwise: a page that cannot tell keeps the group usable and says when it applies.
    property bool flatpakPresent: true
    property bool flatpakKnown: false

    function readKey(key, apply) {
        pendingReads++;
        cfgExecutor.run(kemptCmd + " config get " + key, 15000, function (stdout, stderr, rc) {
            page.pendingReads--;
            if (rc !== 0) {
                // Remembered, not just reported. Without this the control keeps this file's
                // default, the page looks like it loaded, and the next Apply writes that default
                // over a stored value nobody ever read.
                page.readFailed[key] = true;
                page.loadError = Logic.firstLineOf(stderr) || "Could not read the Kempt settings.";
                return;
            }
            var v = Logic.firstLineOf(stdout);
            page.loaded[key] = v;
            apply(v);
        });
    }

    function loadHolds() {
        holdsBusy = true;
        cfgExecutor.run(kemptCmd + " holds", 15000, function (stdout, stderr, rc) {
            page.holdsBusy = false;
            page.holds = rc === 0 ? Logic.holdsOf(stdout) : [];
        });
    }

    function loadMuted() {
        mutedBusy = true;
        cfgExecutor.run(kemptCmd + " startup --json", 15000, function (stdout, stderr, rc) {
            page.mutedBusy = false;
            page.muted = rc === 0 ? Logic.startupMutedOf(stdout) : [];
            // After Stop Muting its button is gone with the row, so the keyboard goes to Undo,
            // once the list read has re-enabled it.
            if (page.focusUndo) {
                page.focusUndo = false;
                Qt.callLater(function () {
                    if (undoUnmute.visible && undoUnmute.enabled) undoUnmute.forceActiveFocus(Qt.TabFocusReason);
                });
            }
        });
    }

    // verb is "mute" or "unmute"; the unit is shell-quoted by Logic.startupVerbArgs. Durable, as
    // removeHold is, because the button can be pressed just before OK. A finished unmute is kept
    // in lastUnmuted for Undo; a finished Undo clears it.
    property bool focusUndo: false

    function setMuted(verb, entry) {
        var args = Logic.startupVerbArgs(verb, entry);
        if (args === "") return;
        mutedBusy = true;
        cfgExecutor.run(page.durable(kemptCmd + args), Logic.ANSWER_TIMEOUT_MS,
                        function (stdout, stderr, rc) {
            page.mutedBusy = false;
            if (rc !== 0) {
                // Exit 6 from mute: the service started since it was listed. Not a failure.
                page.loadError = verb === "mute" && rc === 6
                    ? i18n("%1 is running again, so there is nothing to mute.", entry.name)
                    : Logic.answerOutcomeOf(rc, "", stderr, "", "").text
                    || (verb === "mute" ? i18n("Could not mute %1.", entry.name)
                                        : i18n("Could not stop muting %1.", entry.name));
                return;
            }
            page.lastUnmuted = verb === "unmute" ? entry : null;
            page.focusUndo = verb === "unmute";
            page.loadMuted();
        });
    }

    function removeHold(id) {
        holdsBusy = true;
        // Durable, for the same reason the config writes are: this button lives on the settings
        // page, so an unhold pressed just before OK is dispatched into the same teardown.
        cfgExecutor.run(page.durable(kemptCmd + " unhold " + Logic.shellQuote(id)),
                        Logic.ANSWER_TIMEOUT_MS, function (stdout, stderr, rc) {
            page.holdsBusy = false;
            if (rc !== 0) {
                page.loadError = Logic.answerOutcomeOf(rc, "", stderr, "", i18n("Kempt did not answer in time. The hold may not have changed. Try again.")).text
                                 || ("Could not remove the hold on " + id + ".");
                return;
            }
            page.loadHolds();
        });
    }

    // Runs on pwExecutor, NOT cfgExecutor. This call sits on a 120-second timeout because it opens
    // an authentication dialog and then waits for a human. Sharing the settings queue would send an
    // Apply pressed while that dialog is up to the BACK of it: the writes are real and land
    // eventually, but up to two minutes later, with no way for the page to say so.
    //
    // Gating Apply on passwordlessBusy instead is worse: the shell's OK button calls saveConfig()
    // and then closes regardless of what it returns, so a gated save would discard the user's
    // changes silently on OK - trading a slow write for a lost one.
    function runPasswordless(verb) {
        passwordlessBusy = true;
        passwordlessResult = "";
        pwExecutor.run(kemptCmd + " " + verb + "-passwordless", 120000,
                       function (stdout, stderr, rc) {
            page.passwordlessBusy = false;
            // Whatever it said, verbatim: the authentication dialog is the user's, the outcome is
            // theirs to read. A declined dialog and a real failure are both worth showing.
            var out = Logic.lastLinesOf(stdout + "\n" + stderr, 2);
            page.passwordlessResult = out !== "" ? out
                : (rc === 0 ? "Done." : "That did not complete (exit " + rc + ").");
        });
    }

    function loadDiscover() {
        cfgExecutor.run(kemptCmd + " discover-notifier status --json", 15000,
                        function (stdout, stderr, rc) {
            page.discoverSetting = rc === 0 ? Logic.discoverSettingOf(stdout) : null;
        });
    }

    // Durable, like the config writes: the button can be pressed just before OK.
    function setDiscover(verb) {
        if (verb !== "off" && verb !== "on") return;
        discoverBusy = true;
        discoverResult = "";
        cfgExecutor.run(page.durable(kemptCmd + " discover-notifier " + verb), Logic.ANSWER_TIMEOUT_MS,
                        function (stdout, stderr, rc) {
            page.discoverBusy = false;
            var said = Logic.answerOutcomeOf(rc, stdout, stderr, "", i18n("Kempt did not answer in time. The setting may not have changed. Try again."));
            if (!said.ok) page.discoverResult = said.text;
            page.loadDiscover();
        });
    }

    // Its OWN queue. The action executor in main.qml can be sitting on a 120-second `kempt check`,
    // and a settings dialog that takes two minutes to populate is a broken dialog.
    Executor { id: cfgExecutor }

    // And the same argument one level down: the passwordless buttons wait on a human in an
    // authentication dialog, so they get a queue of their own rather than parking every read,
    // write and hold on this page behind that wait.
    Executor { id: pwExecutor }

    Component.onCompleted: {
        readKey("include_flatpak", function (v) { includeFlatpak.checked = Logic.isTrue(v); });
        readKey("surface", function (v) { page.applySurface(Logic.resolveSurface(v)); });
        readKey("refresh_interval_min", function (v) {
            var n = parseInt(v, 10);
            if (isNaN(n) || n < 1) return;
            // The dialog's own floor is 15, but `kempt config set refresh_interval_min 5` is a
            // thing the CLI allows - and a settings page must never silently RAISE a value the
            // user chose elsewhere. When the stored value is lower, the control lowers to meet it.
            if (n < interval.from) interval.from = n;
            interval.value = n;
        });
        // Newer than `kempt config`: "" is an older CLI that does not know the key, which is unknown, not false.
        readKey("notify_startup", function (v) {
            if (v === "") {
                page.readFailed["notify_startup"] = true;
                return;
            }
            notifyStartup.checked = Logic.isTrue(v);
        });
        // Newer than `kempt config` too, so the same guard: an older CLI answers "" for a key it
        // does not know, and that is unknown, not ask.
        readKey("reclaim", function (v) {
            if (v === "") {
                page.readFailed["reclaim"] = true;
                return;
            }
            page.reclaimKey = Logic.resolveReclaimSetting(v);
        });
        // Not a read of a setting, so not counted in pendingReads: the controls do not wait for it.
        cfgExecutor.run("f=\"${KEMPT_FLATPAK_UNINSTALL_CMD:-flatpak}\"; command -v \"${f%% *}\" >/dev/null",
                        15000, function (stdout, stderr, rc) {
            if (rc !== 0 && rc !== 1) return;       // no answer: keep the group usable
            page.flatpakPresent = rc === 0;
            page.flatpakKnown = true;
        });
        loadHolds();
        loadMuted();
        loadDiscover();
    }

    Kirigami.FormLayout {
        anchors.left: parent.left
        anchors.right: parent.right

        QQC2.Label {
            Kirigami.FormData.isSection: false
            visible: page.loadError.length > 0
            text: page.loadError
            wrapMode: Text.WordWrap
            color: Kirigami.Theme.negativeTextColor
        }

        // The controls below hold this file's defaults until the reads land, and a default that
        // looks like a setting is the thing to avoid here. They are disabled meanwhile, and this
        // says why rather than leaving a form that is inert for no visible reason.
        QQC2.Label {
            Kirigami.FormData.isSection: false
            visible: page.loading
            text: i18n("Reading your settings…")
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.8
        }

        // --- what to update ---------------------------------------------------------------------
        QQC2.CheckBox {
            id: includeFlatpak
            Kirigami.FormData.label: i18n("Updates:")
            text: i18n("Include Flatpak apps")
            // Without flatpak the CLI leaves Flatpak out whatever this says (flatpak_included).
            enabled: !page.loading && page.flatpakPresent
            onToggled: page.markChanged("include_flatpak")
        }

        QQC2.Label {
            id: includeFlatpakNote
            visible: !page.flatpakPresent
            text: i18n("Flatpak is not installed.")
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.8
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        }

        // --- unused Flatpak runtimes ---------------------------------------------------------------
        // `reclaim`: what Kempt does with runtimes no installed app uses. The CLI does nothing with
        // it when flatpak is absent or left out of updates, so the group greys out. The note says which
        // when Flatpak is left out; an absent flatpak is said under the checkbox above.
        Repeater {
            id: reclaimRepeater
            // The form label, said once beside the first radio and in each radio's accessible name.
            readonly property string groupLabel: i18n("Unused Flatpak runtimes:")
            model: [
                { key: "ask", label: i18n("Ask me first") },
                { key: "off", label: i18n("Never") }
            ]

            QQC2.RadioButton {
                required property var modelData
                required property int index
                readonly property string reclaimOption: modelData.key

                Kirigami.FormData.label: index === 0 ? reclaimRepeater.groupLabel : ""
                text: modelData.label
                // A screen reader hears the group as well as the option: "Small" alone says
                // nothing about what is small.
                Accessible.name: i18nc("@info:whatsthis a radio button's setting, then its option",
                                       "%1 %2", reclaimRepeater.groupLabel, text)
                // Off for the same reason as the other radio groups on this page: they share one
                // FormLayout parent, and QQC2 would otherwise run them all as one exclusive group.
                autoExclusive: false
                checked: page.reclaimKey === reclaimOption
                enabled: !page.loading && page.flatpakPresent && includeFlatpak.checked
                onToggled: {
                    // autoExclusive is off, so a click can uncheck the selected radio. Flip it back the
                    // way the click did, from C++: assigning true from here would end the binding and
                    // leave it lit after page.surfaceKey moves on.
                    if (!checked) { toggle(); return; }
                    page.reclaimKey = reclaimOption;
                    page.markChanged("reclaim");
                }
            }
        }

        QQC2.Label {
            id: reclaimNote
            // Not installed is said once, under Include Flatpak apps.
            text: !page.flatpakPresent ? ""
                : !includeFlatpak.checked ? i18n("Only applies when Flatpak apps are included in updates.")
                : !page.flatpakKnown ? i18n("Only applies when Flatpak is installed.")
                : ""
            visible: text !== ""
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.8
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        }

        Item { Kirigami.FormData.isSection: true }

        // --- where a run happens -----------------------------------------------------------------
        Repeater {
            id: surfaceRepeater
            // The form label, said once beside the first radio and in each radio's accessible name.
            readonly property string groupLabel: i18n("Run updates in:")
            model: [
                { key: "popup",      label: i18n("In this widget") },
                { key: "offline",    label: i18n("On the next restart") }
            ]

            QQC2.RadioButton {
                required property var modelData
                required property int index
                readonly property string surfaceKey: modelData.key

                Kirigami.FormData.label: index === 0 ? surfaceRepeater.groupLabel : ""
                text: modelData.label
                // A screen reader hears the group as well as the option: "Small" alone says
                // nothing about what is small.
                Accessible.name: i18nc("@info:whatsthis a radio button's setting, then its option",
                                       "%1 %2", surfaceRepeater.groupLabel, text)
                // Exclusivity here is the `checked` binding below and NOTHING else, so QQC2's own
                // must be turned off. A RadioButton with autoExclusive left on joins the group of
                // its PARENT - and a Repeater reparents its delegates to the Repeater's parent, so
                // these and the unused-runtimes buttons further down are all children of the same
                // Kirigami.FormLayout and would be treated as ONE group.
                // Whichever group's `checked` binding evaluates second wins: QQC2 unchecks every
                // other button in the group, and unchecking one is a WRITE that overrides its
                // binding for good - a fresh install then opens with one group showing
                // nothing at all.
                autoExclusive: false
                // A view of page.surfaceKey, and the only writer of it is a click.
                checked: page.surfaceKey === surfaceKey
                onToggled: {
                    // autoExclusive is off, so a click can uncheck the selected radio. Flip it back the
                    // way the click did, from C++: assigning true from here would end the binding and
                    // leave it lit after page.surfaceKey moves on.
                    if (!checked) { toggle(); return; }
                    page.surfaceKey = surfaceKey;
                    page.markChanged("surface");
                }
                enabled: !page.loading
            }
        }

        Item { Kirigami.FormData.isSection: true }

        // --- how often to look --------------------------------------------------------------------
        QQC2.SpinBox {
            id: interval
            Kirigami.FormData.label: i18n("Check every:")
            // A spin box has no words of its own, so a screen reader would say only "spin button".
            // The text field inside it is a stop of its own when typing, so it gets the name too.
            Accessible.name: i18n("Check every")
            Component.onCompleted: {
                if (contentItem)
                    contentItem.Accessible.name = Qt.binding(() => interval.Accessible.name);
            }
            from: 15
            to: 1440
            // 5, not 15. `from` lowers itself below to meet a smaller value the CLI is holding, and
            // SpinBox steps from the CURRENT value rather than snapping to a grid - so a 15-minute
            // step off a floor of 5 walks 5, 20, 35, 50 and never lands on a round interval anyone
            // would pick. Stepping by 5 lands on them from any floor.
            stepSize: 5
            editable: true
            enabled: !page.loading
            onValueModified: page.markChanged("refresh_interval_min")
            textFromValue: function (value) { return i18np("%1 minute", "%1 minutes", value); }
            valueFromText: function (text) { return parseInt(text, 10) || interval.value; }
        }

        Item { Kirigami.FormData.isSection: true }

        // --- services that stop starting after an update ------------------------------------------
        // notify_startup: on by default, like the CLI's own default. The CLI does the looking and
        // the notification; this page writes the key and lists what is muted, below the holds.
        QQC2.CheckBox {
            id: notifyStartup
            Kirigami.FormData.label: i18n("Services:")
            text: i18n("Tell me when something stops starting after an update")
            checked: true
            enabled: !page.loading
            onToggled: page.markChanged("notify_startup")
        }

        QQC2.Label {
            id: notifyStartupNote
            text: i18n("Kempt only looks. It never turns anything on or off, and the update count never includes this.")
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.8
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        }

        Item { Kirigami.FormData.isSection: true }

        // --- holds ----------------------------------------------------------------------------------
        QQC2.Label {
            Kirigami.FormData.label: i18n("Held:")
            visible: page.holds.length === 0
            text: page.holdsBusy ? i18n("Loading…") : i18n("Nothing is being held.")
            font: Kirigami.Theme.smallFont
            opacity: 0.8
        }

        Repeater {
            model: page.holds

            RowLayout {
                required property var modelData
                required property int index
                Kirigami.FormData.label: index === 0 ? i18n("Held:") : ""
                spacing: Kirigami.Units.smallSpacing

                QQC2.Label {
                    text: modelData.name
                    elide: Text.ElideRight
                    Layout.maximumWidth: Kirigami.Units.gridUnit * 14
                }
                QQC2.Label {
                    text: modelData.backend
                    font: Kirigami.Theme.smallFont
                    opacity: 0.7
                }
                QQC2.ToolButton {
                    icon.name: "edit-delete-remove"
                    enabled: !page.holdsBusy
                    // "Stop holding %1", not "...back": nothing is being held BACK, and the popup's
                    // own pin says it in exactly these words (UpdateItemDelegate.qml). Two
                    // spellings of one action is one too many.
                    text: i18n("Stop holding %1", modelData.name)
                    display: QQC2.AbstractButton.IconOnly
                    // Icon-only, so `text` is never drawn and the tooltip is only for a pointer.
                    // The same rule as the popup's padlock: every icon-only button in this widget
                    // says what it is and names the package it would act on - through the NAME,
                    // which QQC2 takes from `text`, spelled out here because a probe measured that
                    // name empty when accessibility was active before construction.
                    Accessible.name: text
                    // ...and the description is the consequence, in the popup's own words for the
                    // identical action, rather than the label read back a second time.
                    Accessible.description: i18n("Kempt offers its update again.")
                    QQC2.ToolTip.text: text
                    QQC2.ToolTip.visible: hovered
                    QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                    onClicked: page.removeHold(modelData.id)
                }
            }
        }

        // --- muted services, beside the holds ---------------------------------------------------
        QQC2.Label {
            id: mutedEmpty
            Kirigami.FormData.label: i18n("Muted:")
            visible: page.muted.length === 0
            text: page.mutedBusy ? i18n("Loading…") : i18n("Nothing is muted.")
            font: Kirigami.Theme.smallFont
            opacity: 0.8
        }

        Repeater {
            id: mutedRepeater
            model: page.muted

            RowLayout {
                required property var modelData
                required property int index
                Kirigami.FormData.label: index === 0 ? i18n("Muted:") : ""
                spacing: Kirigami.Units.smallSpacing

                QQC2.Label {
                    text: modelData.name
                    elide: Text.ElideRight
                    Layout.maximumWidth: Kirigami.Units.gridUnit * 14
                }
                QQC2.Label {
                    text: modelData.unit
                    font: Kirigami.Theme.smallFont
                    opacity: 0.7
                    elide: Text.ElideRight
                    Layout.maximumWidth: Kirigami.Units.gridUnit * 8
                }
                // Icon-only, named and described as the hold's button is.
                QQC2.ToolButton {
                    icon.name: "notifications"
                    enabled: !page.mutedBusy
                    text: i18n("Stop Muting %1", modelData.name)
                    display: QQC2.AbstractButton.IconOnly
                    Accessible.name: text
                    Accessible.description: i18n("Kempt mentions it again if it still does not start.")
                    QQC2.ToolTip.text: text
                    QQC2.ToolTip.visible: hovered
                    QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                    onClicked: page.setMuted("unmute", modelData)
                }
            }
        }

        // Undo, for the one just unmuted: it mutes it again.
        RowLayout {
            id: unmutedRow
            visible: page.lastUnmuted !== null
            spacing: Kirigami.Units.smallSpacing

            QQC2.Label {
                text: page.lastUnmuted ? i18n("Stopped muting %1.", page.lastUnmuted.name) : ""
                font: Kirigami.Theme.smallFont
                elide: Text.ElideRight
                Layout.maximumWidth: Kirigami.Units.gridUnit * 16
            }
            QQC2.Button {
                id: undoUnmute
                text: i18n("Undo")
                icon.name: "edit-undo"
                enabled: !page.mutedBusy
                Accessible.description: page.lastUnmuted ? i18n("Mutes %1 again.", page.lastUnmuted.name) : ""
                onClicked: page.setMuted("mute", page.lastUnmuted)
            }
        }

        Item { Kirigami.FormData.isSection: true }

        // --- Discover's update notifier ----------------------------------------------------------
        // Shown only when it is installed. Turn On only undoes Kempt's own entry, so an entry of the
        // person's own gets no button.
        QQC2.Label {
            id: discoverStatus
            Kirigami.FormData.label: i18n("Discover:")
            visible: page.discoverSetting !== null
            text: !page.discoverSetting ? ""
                : page.discoverSetting.state === "on"
                    ? i18n("Discover also checks for updates, with its own count.")
                : page.discoverSetting.state === "off" ? i18n("Discover's update checks are off.")
                : page.discoverSetting.path
                    ? i18n("Discover's update checks are turned off by a startup file: %1. Delete that file to turn them back on.", page.discoverSetting.path)
                : i18n("Discover's update checks are turned off by a startup file. Delete that file to turn them back on.")
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        }

        QQC2.Button {
            id: discoverButton
            visible: page.discoverSetting !== null && page.discoverSetting.verb !== ""
            text: page.discoverSetting && page.discoverSetting.verb === "on"
                ? i18n("Turn On Discover's Update Checks") : i18n("Turn Off Discover's Update Checks")
            icon.name: page.discoverSetting && page.discoverSetting.verb === "on"
                ? "notifications" : "notifications-disabled"
            enabled: !page.discoverBusy
            onClicked: page.setDiscover(page.discoverSetting.verb)
        }

        QQC2.Label {
            visible: page.discoverResult.length > 0
            text: page.discoverResult
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            color: Kirigami.Theme.negativeTextColor
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        }

        Item {
            Kirigami.FormData.isSection: true
            visible: page.discoverSetting !== null
        }

        // --- passwordless ------------------------------------------------------------------------
        // No state is displayed, and that is not an oversight: the polkit rules directory is
        // 0750 root:polkitd, so a widget running as the user genuinely cannot read whether the
        // rule is installed. Claiming either way would be a guess, and a guess about whether the
        // machine asks for a password is the wrong thing to guess about.
        QQC2.Label {
            Kirigami.FormData.label: i18n("Password prompts:")
            text: i18n("Updates normally ask for your password once per run. You can allow Kempt's update action to run without one. That applies only to this action, and only while you are logged in at this machine.")
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        }

        RowLayout {
            spacing: Kirigami.Units.smallSpacing

            QQC2.Button {
                text: i18n("Allow without password…")
                icon.name: "unlock"
                enabled: !page.passwordlessBusy
                onClicked: page.runPasswordless("enable")
            }
            QQC2.Button {
                text: i18n("Require a password…")
                icon.name: "lock"
                enabled: !page.passwordlessBusy
                onClicked: page.runPasswordless("disable")
            }
        }

        QQC2.Label {
            visible: page.passwordlessResult.length > 0
            text: page.passwordlessResult
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        }

        QQC2.Label {
            text: i18n("Kempt cannot read whether this is currently on: the rule it writes lives in a directory only root can list. Use the buttons to set it either way.")
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        }
    }
}
