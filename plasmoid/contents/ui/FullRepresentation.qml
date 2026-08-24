// The popup. What is pending, what is held, and the two buttons that act on it.
//
// Like the panel icon, this file decides nothing: every string and every list comes from the view
// model main.qml derives in logic.js, and every action is a call back into main.qml. Both inputs
// are `required`, so a wiring mistake refuses to be created rather than rendering a plausible lie.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

PlasmaExtras.Representation {
    id: popup

    required property PlasmoidItem plasmoidItem
    required property var vm

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
                    // Deliberately NOT the badge text: the badge caps at 99+ because a panel has
                    // no room, and this has plenty. Someone who opened the popup wants the number.
                    text: popup.vm.headerText
                    elide: Text.ElideRight
                }

                PlasmaComponents.ToolButton {
                    icon.name: "configure"
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Configure Upkeep...")
                    PlasmaComponents.ToolTip.text: text
                    PlasmaComponents.ToolTip.visible: hovered
                    PlasmaComponents.ToolTip.delay: Kirigami.Units.toolTipDelay
                    onClicked: Plasmoid.internalAction("configure").trigger()
                }
            }

            // Stale: what went wrong and how old the numbers below therefore are. An explanation,
            // not an alarm - the counts under it are still the best known truth.
            PlasmaComponents.Label {
                Layout.fillWidth: true
                visible: popup.vm.stale && !root.updating
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
                visible: popup.vm.riskySummary.length > 0 && !root.updating
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
                    enabled: !root.updating
                    onClicked: root.stageOffline()
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
                    enabled: !root.updating && popup.vm.actionable > 0
                    onClicked: root.startUpdate()
                }
                PlasmaComponents.Button {
                    text: i18n("Refresh")
                    icon.name: "view-refresh"
                    enabled: !root.checking && !root.updating
                    onClicked: root.doCheck()
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents.BusyIndicator {
                    running: root.checking || root.updating
                    visible: running
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }
            }

            // What the last action did or failed to do. Cleared by main.qml on the next action.
            PlasmaComponents.Label {
                Layout.fillWidth: true
                visible: root.actionMessage.length > 0
                text: root.actionMessage
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
        visible: popup.vm.rows.length > 0 && !root.updating

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
                        busy: root.holdInFlight
                        onToggleHold: (backend, name, hold) => root.setHold(backend, name, hold)
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
        visible: popup.vm.rows.length === 0 && !root.updating && text.length > 0
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
        visible: root.updating
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents.Label {
            Layout.fillWidth: true
            text: root.surface === "popup" ? i18n("Updating...") : i18n("Updating in the %1 surface...", root.surface)
            wrapMode: Text.WordWrap
        }

        PlasmaComponents.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.surface === "popup"

            PlasmaComponents.TextArea {
                readOnly: true
                text: root.logTail
                // The theme's own fixed-width font, not a hardcoded "monospace": dnf output is
                // column-aligned and the user's chosen mono font is the one that will render it.
                font: Kirigami.Theme.fixedWidthFont
                wrapMode: TextEdit.NoWrap
            }
        }

        Item {
            Layout.fillHeight: true
            visible: root.surface !== "popup"
        }
    }
}
