// The settings page. Every value on it is read from and written to `kempt config` - there is no
// plasmoid-local copy of any of these settings, and contents/config/main.xml declares no keys at
// all. That is deliberate: a KConfig entry here would be a second copy of a setting the CLI also
// owns, and the two would drift apart the first time somebody typed `kempt config set` in a
// terminal. The CLI is the single source of truth; this page is a front-end to it.
//
// The shell builds this page in its own dialog, so it cannot reach main.qml (there is no rootItem
// to call through). It does not need to: main.qml watches the config file, so writing it here is
// what makes the widget re-read its interval, its surface and its pending list.
//
// That back-channel is a 30-second mtime poll (main.qml, watchCmd), so a setting applied here
// reaches the panel within 30 seconds rather than instantly. By design - KDirWatch is not
// reachable from pure QML - and it is the whole latency budget of this page: nothing here waits
// on, or reports, the widget having noticed. (W5: say so in docs/usage.md's settings section.)
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import "logic.js" as Logic

KCM.SimpleKCM {
    id: page

    // Same prefix main.qml uses: plasmashell does not reliably inherit a login shell's PATH.
    readonly property string kemptCmd: "PATH=\"$HOME/.local/bin:$PATH\" kempt"

    // What `kempt config get` said when this page opened. Apply compares against these and
    // writes ONLY what actually changed - so a key the user never touched is never rewritten,
    // and a value set from the CLI that this page cannot represent is left exactly as it was.
    property var loaded: ({})
    // Keys whose `config get` did not answer. Their stored value is unknown, and a key whose
    // stored value is unknown must not be written from a control that is still showing this
    // file's own default - see setIfChanged.
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
    property string passwordlessResult: ""
    property bool passwordlessBusy: false

    // Writes dispatched by the current Apply that have not answered yet, and whether any of them
    // came back non-zero. Together they decide WHEN the page is allowed to call itself saved -
    // see saveConfig/finishWrite below.
    property int outstandingWrites: 0
    property bool writeFailed: false
    // The same fact under a name worth reading: an Apply is in flight. Nothing on the page binds
    // to it today (the controls stay live while a save runs - the values were taken at dispatch
    // time, so editing them again is safe and the next Apply will write them). It exists because
    // "is a write outstanding" is the question this page's whole apply path turns on, and the
    // probes ask it by name rather than by counter arithmetic.
    readonly property bool saving: outstandingWrites > 0

    // THE hook that makes the dialog's Apply button work, and it has to be spelled exactly this
    // way. AppletConfiguration.qml decides whether Apply is clickable in one line:
    //
    //   applyButton.enabled = wasConfigurationChangedSignalSent || isConfigurationChanged()
    //                         || (app?.pageStack?.currentItem?.unsavedChanges ?? false)
    //
    // ...and it recomputes that line on three signals: a `cfg_<key>Changed` from an auto-bound
    // KConfig property, a `configurationChanged()` the page emits, or `unsavedChangesChanged`
    // (it connects to all three when the page is pushed). This page has no cfg_ properties BY
    // DESIGN - `kempt config` owns every setting and main.xml declares no keys - so the first two
    // hooks do not exist here and Apply sat permanently greyed out: the page worked only if the
    // user pressed OK. Declaring this property gives the shell its third hook for free, since
    // QML emits unsavedChangesChanged on every write to it.
    //
    // It is also what makes closing the dialog safe. The shell's closing() prompts "apply or
    // discard?" only when the Apply button is enabled, so with no hook a page full of changes
    // closed silently and threw them away.
    property bool unsavedChanges: false

    // Every control's change handler calls this - and only from a signal the USER can cause
    // (onToggled, onValueModified). Never onCheckedChanged/onValueChanged: those also fire when
    // the reads below populate the page, which would arm Apply before anyone touched anything.
    function markChanged(key) {
        page.touched[key] = true;
        page.unsavedChanges = true;
    }

    // The dialog's Apply and OK both land here (the shell calls saveConfig() on the current page
    // when it exists - AppletConfiguration.qml). Nothing is written anywhere else.
    function saveConfig() {
        // Nothing has been read yet, so every control below is still showing this file's own
        // default - and writing those would replace the user's stored settings with them. The
        // controls are disabled while the reads are in flight, but the dialog's Apply and OK
        // belong to the shell and are offered regardless, so the guard lives here too. Not an
        // error: the reads land in well under a second, and there is nothing yet to save.
        if (page.pendingReads > 0) return;
        // An Apply while the previous one is still in flight would reset the counter below out
        // from under callbacks that have not fired yet, and each of those would then decrement a
        // fresh count. The writes already dispatched cover everything on the page anyway - the
        // values were read at dispatch time - so there is nothing a second pass would add.
        if (page.outstandingWrites > 0) return;

        page.writeFailed = false;
        // The sentinel. setIfChanged is dispatched four times in a row, and a naive count would
        // pass through zero after the FIRST write answered - clearing unsavedChanges while three
        // more were still queued. Holding one notional write open across the whole dispatch means
        // the count can only reach zero after every setIfChanged has had its say.
        page.outstandingWrites = 1;
        setIfChanged("include_flatpak", includeFlatpak.checked ? "true" : "false");
        setIfChanged("auto_accept", autoAccept.checked ? "true" : "false");
        setIfChanged("surface", page.selectedSurface());
        setIfChanged("refresh_interval_min", String(interval.value));
        finishWrite();      // release the sentinel
    }

    // The ONLY place unsavedChanges is cleared, and it is reached only when the last write has
    // landed. Clearing it at the end of saveConfig() instead - which is what this file used to do -
    // was the page telling the shell "saved" the instant it had finished DISPATCHING: Apply greyed
    // out, closing the dialog stopped prompting, and both happened while `kempt config set` calls
    // were still queued behind a 15-second timeout. The user could close the dialog on a write
    // that had not happened yet and get no warning at all.
    //
    // With nothing to write (nothing changed) this still runs immediately - the sentinel is the
    // only outstanding write - so an Apply that legitimately writes nothing is clean at once.
    function finishWrite() {
        page.outstandingWrites--;
        if (page.outstandingWrites > 0) return;
        // A write that came back non-zero leaves Apply live for the retry rather than looking
        // finished. The retry semantics behind it already exist: a failed write is not recorded
        // as the stored value, so the next Apply attempts it again instead of comparing equal.
        if (page.writeFailed) return;
        page.unsavedChanges = false;
    }

    function setIfChanged(key, value) {
        // A key whose read never answered has no known stored value: `loaded[key]` is undefined,
        // so the comparison below would call it changed and write this file's default straight
        // over whatever the user actually has. The exception is a control the user deliberately
        // moved, where the value on screen is theirs rather than a default.
        if (page.readFailed[key] && !page.touched[key]) return;
        if (page.loaded[key] === value) return;
        // Counted before it is dispatched, and only here, past both guards above: those return
        // without writing anything, and a write that was never made must not hold the page open.
        page.outstandingWrites++;
        // The value is ours (a checkbox state, a number, one of four known surfaces) but it is
        // quoted anyway. The rule this file follows is that everything reaching a command line is
        // quoted, with no per-case judgement about which values are "obviously safe".
        cfgExecutor.run(kemptCmd + " config set " + key + " " + Logic.shellQuote(value), 15000,
                        function (stdout, stderr, rc) {
            if (rc !== 0) {
                page.loadError = Logic.firstLineOf(stderr) || ("Could not save " + key + ".");
                // Apply stays on, so the retry is one click rather than a reopened dialog.
                page.writeFailed = true;
                page.unsavedChanges = true;
                page.finishWrite();
                return;
            }
            // Recorded as the stored value only now that it IS the stored value. Recording it
            // before the CLI answered meant a FAILED write was remembered as a success: the next
            // Apply compared equal, wrote nothing, and the setting the user asked for quietly
            // stayed as it was, with no second attempt possible short of changing it twice.
            page.loaded[key] = value;
            page.readFailed[key] = false;
            page.finishWrite();
        });
    }

    // The chosen surface lives HERE, not in the radio buttons. Reading it back out of the
    // delegates looked equivalent and was not: a Repeater whose items are not currently realised
    // answers "nothing is checked", which this function would have reported as `terminal` - and
    // Apply would then have written terminal over whatever the user actually had. The view
    // renders this property; it is never the source of it.
    property string surfaceKey: "terminal"

    // Only the terminal surface can ask a question, so with confirmation on the others cannot run
    // at all. The radios grey out and say so, and this is why. What it does NOT do is change the
    // selection: see below.
    readonly property bool surfacesLocked: !autoAccept.checked

    // The stored preference, whatever the confirmation setting happens to be right now.
    // Collapsing it to terminal here was this page rewriting a preference nobody touched: with
    // auto_accept already false, opening the settings and pressing Apply replaced a stored
    // `popup` with `terminal`, and turning confirmation back off later left the user on a surface
    // they never chose. The lock is a RUN-time fact and the run already applies it - bin/kempt's
    // cmd_run overrides the surface itself, and main.qml mirrors that in Logic.effectiveSurfaceOf
    // so the popup shows the truth. None of that needs baking into the stored value.
    function selectedSurface() {
        return page.surfaceKey;
    }

    function applySurface(key) {
        page.surfaceKey = Logic.resolveSurface(key);
    }

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

    function removeHold(id) {
        holdsBusy = true;
        cfgExecutor.run(kemptCmd + " unhold " + Logic.shellQuote(id), 15000,
                        function (stdout, stderr, rc) {
            page.holdsBusy = false;
            if (rc !== 0) {
                page.loadError = Logic.firstLineOf(stderr) || ("Could not remove the hold on " + id + ".");
                return;
            }
            page.loadHolds();
        });
    }

    // Runs on pwExecutor, NOT cfgExecutor, and that is the whole fix for it. This call sits on a
    // 120-second timeout because it opens an authentication dialog and then waits for a human to
    // deal with it. Sharing the settings queue meant an Apply pressed while that dialog was up
    // went to the BACK of it: the writes were real and would eventually land, but they landed up
    // to two minutes later, and in the meantime the page had no way to say so. Its own queue means
    // Apply is never behind it - the two do not touch the same file, so nothing is serialised by
    // sharing a queue except the waiting.
    //
    // Gating Apply on passwordlessBusy instead was the other option and is worse: the shell's OK
    // button calls saveConfig() and then closes regardless of what it returns, so a gated save
    // would discard the user's changes silently on OK - trading a slow write for a lost one.
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

    // Its OWN queue. The action executor in main.qml can be sitting on a 120-second `kempt
    // check`, and a settings dialog that takes two minutes to populate is a broken dialog.
    Executor { id: cfgExecutor }

    // And the same argument one level down: the passwordless buttons wait on a human in an
    // authentication dialog, so they get a queue of their own rather than parking every read,
    // write and hold on this page behind that wait. Same split, same reason as main.qml's
    // executor/tailExecutor pair - a long job never blocks a short one.
    Executor { id: pwExecutor }

    Component.onCompleted: {
        readKey("include_flatpak", function (v) { includeFlatpak.checked = Logic.isTrue(v); });
        readKey("auto_accept", function (v) { autoAccept.checked = Logic.isTrue(v); });
        readKey("surface", function (v) { page.applySurface(Logic.resolveSurface(v)); });
        readKey("refresh_interval_min", function (v) {
            var n = parseInt(v, 10);
            if (isNaN(n) || n < 1) return;
            // The dialog's own floor is 15 (below that a desktop is checking for updates more
            // often than anyone needs). But `kempt config set refresh_interval_min 5` is a thing
            // the CLI allows, and a settings page must never silently RAISE a value the user
            // chose elsewhere - so when the stored value is lower, the control lowers to meet it
            // and shows the truth instead.
            if (n < interval.from) interval.from = n;
            interval.value = n;
        });
        loadHolds();
    }

    // There is deliberately no onSurfacesLockedChanged here. Snapping the selection to terminal
    // the moment confirmation was switched on threw away a preference the user had expressed and
    // could not get back by switching confirmation off again - a checkbox silently editing a
    // different setting. Locking greys the radios out and the label above them explains why; the
    // choice underneath is kept, and only the RUN collapses it to terminal.

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
            text: i18n("Reading your settings...")
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.8
        }

        // --- what to update ---------------------------------------------------------------------
        QQC2.CheckBox {
            id: includeFlatpak
            Kirigami.FormData.label: i18n("Updates:")
            text: i18n("Include Flatpak apps")
            enabled: !page.loading
            onToggled: page.markChanged("include_flatpak")
        }

        QQC2.CheckBox {
            id: autoAccept
            text: i18n("Apply updates without asking for confirmation")
            enabled: !page.loading
            onToggled: page.markChanged("auto_accept")
        }

        QQC2.Label {
            visible: !autoAccept.checked
            text: i18n("With confirmation on, updates can only run in a terminal window: the other surfaces have no way to ask you. Your choice below is kept for when you turn confirmation off again.")
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        }

        Item { Kirigami.FormData.isSection: true }

        // --- where a run happens -----------------------------------------------------------------
        Repeater {
            id: surfaceRepeater
            model: [
                { key: "terminal",   label: i18n("Terminal window") },
                { key: "popup",      label: i18n("In this widget") },
                { key: "background", label: i18n("In the background") },
                { key: "offline",    label: i18n("On next reboot (offline)") }
            ]

            QQC2.RadioButton {
                required property var modelData
                required property int index
                readonly property string surfaceKey: modelData.key

                Kirigami.FormData.label: index === 0 ? i18n("Run updates in:") : ""
                text: modelData.label
                // A view of page.surfaceKey, and the only writer of it is a click.
                checked: page.surfaceKey === surfaceKey
                onToggled: {
                    if (!checked) return;
                    page.surfaceKey = surfaceKey;
                    page.markChanged("surface");
                }
                // Only the terminal can prompt, so the rest are unreachable with confirmation on.
                // The reason is stated above rather than left as a mystery grey-out - and a
                // locked selection stays visibly selected, just not changeable.
                enabled: !page.loading && (!page.surfacesLocked || surfaceKey === "terminal")
            }
        }

        Item { Kirigami.FormData.isSection: true }

        // --- how often to look --------------------------------------------------------------------
        QQC2.SpinBox {
            id: interval
            Kirigami.FormData.label: i18n("Check every:")
            from: 15
            to: 1440
            // 5, not 15. `from` lowers itself below to meet a smaller value the CLI is holding,
            // and SpinBox steps from the CURRENT value rather than snapping to a grid - so a
            // 15-minute step off a floor of 5 walks 5, 20, 35, 50 and never lands on a round
            // interval anyone would pick. Stepping by 5 lands on them from any floor, and the box
            // is editable for anyone who wants a number the arrows would take a while to reach.
            stepSize: 5
            editable: true
            enabled: !page.loading
            onValueModified: page.markChanged("refresh_interval_min")
            textFromValue: function (value) { return i18np("%1 minute", "%1 minutes", value); }
            valueFromText: function (text) { return parseInt(text, 10) || interval.value; }
        }

        Item { Kirigami.FormData.isSection: true }

        // --- holds ----------------------------------------------------------------------------------
        QQC2.Label {
            Kirigami.FormData.label: i18n("Held back:")
            visible: page.holds.length === 0
            text: page.holdsBusy ? i18n("Loading...") : i18n("Nothing is being held back.")
            font: Kirigami.Theme.smallFont
            opacity: 0.8
        }

        Repeater {
            model: page.holds

            RowLayout {
                required property var modelData
                required property int index
                Kirigami.FormData.label: index === 0 ? i18n("Held back:") : ""
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
                    text: i18n("Stop holding %1 back", modelData.name)
                    display: QQC2.AbstractButton.IconOnly
                    QQC2.ToolTip.text: text
                    QQC2.ToolTip.visible: hovered
                    QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                    onClicked: page.removeHold(modelData.id)
                }
            }
        }

        Item { Kirigami.FormData.isSection: true }

        // --- passwordless ------------------------------------------------------------------------
        // No state is displayed, and that is not an oversight: the polkit rules directory is
        // 0750 root:polkitd, so a widget running as the user genuinely cannot read whether the
        // rule is installed. Claiming either way would be a guess, and a guess about whether the
        // machine asks for a password is the wrong thing to guess about.
        QQC2.Label {
            Kirigami.FormData.label: i18n("Password prompts:")
            text: i18n("Updates normally ask for your password once per run. You can allow Kempt's update action to run without one - it applies only to this action, and only while you are logged in at this machine.")
            wrapMode: Text.WordWrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        }

        RowLayout {
            spacing: Kirigami.Units.smallSpacing

            QQC2.Button {
                text: i18n("Allow without password...")
                icon.name: "unlock"
                enabled: !page.passwordlessBusy
                onClicked: page.runPasswordless("enable")
            }
            QQC2.Button {
                text: i18n("Require a password...")
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
