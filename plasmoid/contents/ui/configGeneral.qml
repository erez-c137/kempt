// The settings page. Every value on it is read from and written to `kempt config` - there is no
// plasmoid-local copy of any of these settings, and contents/config/main.xml declares no keys at
// all. That is deliberate: a KConfig entry here would be a second copy of a setting the CLI also
// owns, and the two would drift apart the first time somebody typed `kempt config set` in a
// terminal. The CLI is the single source of truth; this page is a front-end to it.
//
// The shell builds this page in its own dialog, so it cannot reach main.qml (there is no rootItem
// to call through). It does not need to: main.qml watches the config file, so writing it here is
// what makes the widget re-read its interval, its surface and its pending list.
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
    property int pendingReads: 0
    property string loadError: ""
    property var holds: []
    property bool holdsBusy: false
    property string passwordlessResult: ""
    property bool passwordlessBusy: false

    // The dialog's Apply and OK both land here (the shell calls saveConfig() on the current page
    // when it exists - AppletConfiguration.qml). Nothing is written anywhere else.
    function saveConfig() {
        setIfChanged("include_flatpak", includeFlatpak.checked ? "true" : "false");
        setIfChanged("auto_accept", autoAccept.checked ? "true" : "false");
        setIfChanged("surface", page.selectedSurface());
        setIfChanged("refresh_interval_min", String(interval.value));
    }

    function setIfChanged(key, value) {
        if (page.loaded[key] === value) return;
        page.loaded[key] = value;
        // The value is ours (a checkbox state, a number, one of four known surfaces) but it is
        // quoted anyway. The rule this file follows is that everything reaching a command line is
        // quoted, with no per-case judgement about which values are "obviously safe".
        cfgExecutor.run(kemptCmd + " config set " + key + " " + Logic.shellQuote(value), 15000,
                        function (stdout, stderr, rc) {
            if (rc !== 0) page.loadError = Logic.firstLineOf(stderr) || ("Could not save " + key + ".");
        });
    }

    // The chosen surface lives HERE, not in the radio buttons. Reading it back out of the
    // delegates looked equivalent and was not: a Repeater whose items are not currently realised
    // answers "nothing is checked", which this function would have reported as `terminal` - and
    // Apply would then have written terminal over whatever the user actually had. The view
    // renders this property; it is never the source of it.
    property string surfaceKey: "terminal"

    // Only the terminal surface can ask a question, so with confirmation on the others cannot run
    // at all. The radios say so, and this is why.
    readonly property bool surfacesLocked: !autoAccept.checked

    function selectedSurface() {
        return surfacesLocked ? "terminal" : page.surfaceKey;
    }

    function applySurface(key) {
        page.surfaceKey = Logic.resolveSurface(key);
    }

    function readKey(key, apply) {
        pendingReads++;
        cfgExecutor.run(kemptCmd + " config get " + key, 15000, function (stdout, stderr, rc) {
            page.pendingReads--;
            if (rc !== 0) {
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

    function runPasswordless(verb) {
        passwordlessBusy = true;
        passwordlessResult = "";
        cfgExecutor.run(kemptCmd + " " + verb + "-passwordless", 120000,
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

    // A selection that just became impossible snaps to the one that is not. Done here rather than
    // in the delegate, so it happens whether or not the radios are currently realised.
    onSurfacesLockedChanged: {
        if (surfacesLocked && page.surfaceKey !== "terminal") page.surfaceKey = "terminal";
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

        // --- what to update ---------------------------------------------------------------------
        QQC2.CheckBox {
            id: includeFlatpak
            Kirigami.FormData.label: i18n("Updates:")
            text: i18n("Include Flatpak apps")
        }

        QQC2.CheckBox {
            id: autoAccept
            text: i18n("Apply updates without asking for confirmation")
        }

        QQC2.Label {
            visible: !autoAccept.checked
            text: i18n("With confirmation on, updates can only run in a terminal window: the other surfaces have no way to ask you.")
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
                onToggled: if (checked) page.surfaceKey = surfaceKey
                // Only the terminal can prompt, so the rest are unreachable with confirmation on.
                // The reason is stated above rather than left as a mystery grey-out.
                enabled: !page.surfacesLocked || surfaceKey === "terminal"
            }
        }

        Item { Kirigami.FormData.isSection: true }

        // --- how often to look --------------------------------------------------------------------
        QQC2.SpinBox {
            id: interval
            Kirigami.FormData.label: i18n("Check every:")
            from: 15
            to: 1440
            stepSize: 15
            editable: true
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
