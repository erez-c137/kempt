// The popup. What is pending, what is held, and the two buttons that act on it.
//
// Like the panel icon, this file decides nothing: every string and every list comes from the view
// model main.qml derives in logic.js, and every action is a call back into main.qml.
//
// EVERY reference to the widget goes through `plasmoidItem`, never through main.qml's `root` id.
// That distinction is not style. A representation whose required properties are all satisfied is
// created successfully; if it then reaches for an id from a context it does not have, each such
// binding throws a ReferenceError and silently evaluates to undefined - so `!undefined.updating`
// is true, every button enables itself, and the popup renders a confident, permanently-updating
// lie. The required properties only protect what actually flows through them.
//
// `plasmoidItem` is typed `var` and not `PlasmoidItem` on purpose: most of what this file needs
// (updating, actionMessage, setHold, ...) is declared in main.qml's QML body, not on the C++
// PlasmoidItem type, so a typed handle would be a promise the type system cannot keep.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

PlasmaExtras.Representation {
    id: popup

    required property var plasmoidItem
    required property var vm

    // Whether whatever is hosting us has already drawn a heading of its own. The system tray has:
    // the popup it puts us in comes with a title bar carrying the plasmoid's name, a pin, and a
    // configure gear - so our own gear underneath it is the SECOND one on screen, opening the same
    // dialog. On a panel or the desktop nothing draws that heading and ours is the only way in.
    //
    // `Plasmoid.containmentDisplayHints & ContainmentDrawsPlasmoidHeading` is the shipped
    // convention for this question rather than a guess: it is the test libplasma's own
    // BasicPlasmoidHeading uses to hide itself in the tray, and the one org.kde.plasma.vault uses
    // to drop its footer button there.
    //
    // Named property rather than the expression written inline on the button, because this is the
    // only seam a test can reach. `containmentDisplayHints` is READ-ONLY on Plasma::Applet, and
    // outside plasmashell the attached `Plasmoid` object has no applet behind it at all - it
    // answers undefined, which is also why the default that falls out below is the safe one (no
    // host heading known, so keep our own gear). A probe can neither set the hint nor fake the
    // applet, but it can overwrite this; tests/qml/probe_popup.py drives it AND pins the
    // expression verbatim, so the drivable seam cannot drift from what the panel evaluates.
    property bool traysHeading: (Plasmoid.containmentDisplayHints
                                 & PlasmaCore.Types.ContainmentDrawsPlasmoidHeading) !== 0

    // These are the representation-switch heuristic, not decoration: Plasma compares the space it
    // has against them to decide between the panel icon and this popup. Removing them is how a
    // widget ends up showing the popup inside a panel.
    Layout.minimumWidth: Kirigami.Units.gridUnit * 22
    Layout.minimumHeight: Kirigami.Units.gridUnit * 18
    Layout.preferredWidth: Kirigami.Units.gridUnit * 26
    Layout.preferredHeight: Kirigami.Units.gridUnit * 24

    collapseMarginsHint: true

    header: PlasmaExtras.PlasmoidHeading {
        contentItem: ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaExtras.Heading {
                    Layout.fillWidth: true
                    level: 4
                    // Deliberately NOT the badge text: the badge caps at 999+ because a panel has
                    // no room, and this has plenty. Someone who opened the popup wants the number.
                    text: popup.vm.headerText
                    elide: Text.ElideRight
                }

                PlasmaComponents.ToolButton {
                    id: configureButton
                    // Ours only when nobody else is offering one - see popup.traysHeading.
                    visible: !popup.traysHeading
                    icon.name: "configure"
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Configure Kempt...")
                    PlasmaComponents.ToolTip.text: text
                    PlasmaComponents.ToolTip.visible: hovered
                    PlasmaComponents.ToolTip.delay: Kirigami.Units.toolTipDelay
                    onClicked: {
                        // The action is registered by the shell, and a plasmoid can be built in
                        // contexts where it is not there yet. Calling trigger() on null takes the
                        // whole binding down with it.
                        const a = Plasmoid.internalAction("configure");
                        if (a) a.trigger();
                    }
                }
            }

            // Stale: what went wrong and how old the numbers below therefore are. An explanation,
            // not an alarm - the counts under it are still the best known truth.
            PlasmaComponents.Label {
                Layout.fillWidth: true
                visible: popup.vm.stale && !popup.plasmoidItem.updating
                text: popup.vm.staleReason.length > 0
                      ? i18n("%1 (last successful check: %2)", popup.vm.staleReason, popup.vm.lastSuccessText)
                      : ""
                wrapMode: Text.WordWrap
                font: Kirigami.Theme.smallFont
                opacity: 0.8
            }

            // The offline recommendation. The CLI has already decided this transaction touches
            // session-critical packages; the widget's job is to make acting on it one click.
            RowLayout {
                Layout.fillWidth: true
                visible: popup.vm.riskySummary.length > 0 && !popup.plasmoidItem.updating
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    source: "emblem-warning"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: popup.vm.riskySummary
                    wrapMode: Text.WordWrap
                    font: Kirigami.Theme.smallFont
                }
                PlasmaComponents.Button {
                    text: i18n("Stage offline instead")
                    icon.name: "system-reboot"
                    enabled: !popup.plasmoidItem.updating
                    onClicked: popup.plasmoidItem.stageOffline()
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Button {
                    text: i18n("Update Now")
                    icon.name: "system-software-update"
                    // Nothing to do is not the same as cannot: an up-to-date box has no run to
                    // start, and a box whose CLI we could not reach has nothing to start it with.
                    enabled: !popup.plasmoidItem.updating && popup.vm.actionable > 0
                    onClicked: popup.plasmoidItem.startUpdate()
                }
                PlasmaComponents.Button {
                    text: i18n("Refresh")
                    icon.name: "view-refresh"
                    enabled: !popup.plasmoidItem.checking && !popup.plasmoidItem.updating
                    onClicked: popup.plasmoidItem.doCheck()
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents.BusyIndicator {
                    running: popup.plasmoidItem.checking || popup.plasmoidItem.updating
                    visible: running
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }
            }

            // What the last action did or failed to do. Cleared by main.qml on the next action.
            PlasmaComponents.Label {
                Layout.fillWidth: true
                visible: popup.plasmoidItem.actionMessage.length > 0
                text: popup.plasmoidItem.actionMessage
                wrapMode: Text.WordWrap
                font: Kirigami.Theme.smallFont
                opacity: 0.8
            }
        }
    }

    // --- the list ------------------------------------------------------------------------------
    // One flat model with header rows in it, built by logic.js. A ListView creates delegates
    // lazily, so a box with 1200 pending updates costs what a box with six costs.
    PlasmaComponents.ScrollView {
        anchors.fill: parent
        visible: popup.vm.rows.length > 0 && !popup.plasmoidItem.updating

        ListView {
            id: rowsView
            model: popup.vm.rows
            clip: true
            reuseItems: true

            delegate: Loader {
                width: rowsView.width
                required property var modelData
                sourceComponent: modelData.kind === "header" ? headerComponent : itemComponent

                Component {
                    id: headerComponent
                    PlasmaExtras.Heading {
                        level: 5
                        text: modelData.title
                        opacity: 0.8
                        topPadding: Kirigami.Units.smallSpacing
                    }
                }

                Component {
                    id: itemComponent
                    UpdateItemDelegate {
                        width: rowsView.width
                        name: modelData.name
                        from: modelData.from
                        to: modelData.to
                        held: modelData.held
                        backend: modelData.backend
                        busy: popup.plasmoidItem.holdInFlight
                        onToggleHold: (backend, name, hold) => popup.plasmoidItem.setHold(backend, name, hold)
                    }
                }
            }
        }
    }

    // --- the empty state -----------------------------------------------------------------------
    // Up to date, no data yet, or a CLI we could not run. The third one is the only one that owes
    // the user an instruction, and it gets the CLI's own words plus the command that diagnoses it.
    PlasmaExtras.PlaceholderMessage {
        anchors.centerIn: parent
        width: parent.width - Kirigami.Units.gridUnit * 4
        visible: popup.vm.rows.length === 0 && !popup.plasmoidItem.updating && text.length > 0
        iconName: popup.vm.iconState === "error" ? "dialog-error"
                  : (popup.vm.iconState === "unknown" ? "view-refresh" : "update-none")
        text: popup.vm.emptyStateText
        explanation: popup.vm.remedyCommand.length > 0
                     ? i18n("Run `%1` in a terminal to find out why.", popup.vm.remedyCommand)
                     : ""
    }

    // --- the updating state ----------------------------------------------------------------------
    // Only reached for a run WE started. The log pane appears only on the in-popup surface, since
    // that is the surface whose whole point is that the output comes here.
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        visible: popup.plasmoidItem.updating
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents.Label {
            Layout.fillWidth: true
            text: popup.plasmoidItem.effectiveSurface === "popup" ? i18n("Updating...") : i18n("Updating in the %1 surface...", popup.plasmoidItem.effectiveSurface)
            wrapMode: Text.WordWrap
        }

        // A tail, so it stays at the tail. The text is replaced wholesale every two seconds, and
        // any view that keeps its own scroll position across that jumps back to the first line
        // each time - which is precisely useless for watching an update run. So: a plain
        // Flickable, re-pinned to the bottom whenever the content grows.
        // `stickToBottom` is what keeps it from fighting the user: scroll up to read something and
        // it stops following, scroll back down and it resumes.
        Flickable {
            id: logFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: popup.plasmoidItem.effectiveSurface === "popup"
            clip: true
            contentWidth: logText.paintedWidth
            contentHeight: logText.paintedHeight
            boundsBehavior: Flickable.StopAtBounds

            property bool stickToBottom: true
            function pin() {
                if (stickToBottom) contentY = Math.max(0, contentHeight - height);
            }
            onContentHeightChanged: pin()
            onHeightChanged: pin()
            onMovementEnded: stickToBottom = (contentY >= contentHeight - height - Kirigami.Units.gridUnit)

            PlasmaComponents.ScrollBar.vertical: PlasmaComponents.ScrollBar {}

            Text {
                id: logText
                text: popup.plasmoidItem.logTail
                color: Kirigami.Theme.textColor
                // The theme's own fixed-width font, not a hardcoded "monospace": dnf output is
                // column-aligned and the user's chosen mono font is the one that will render it.
                font: Kirigami.Theme.fixedWidthFont
                wrapMode: Text.NoWrap
            }
        }

        Item {
            Layout.fillHeight: true
            visible: popup.plasmoidItem.effectiveSurface !== "popup"
        }
    }
}
