// The Startup page: what starts with the computer and what runs on a schedule, from
// `kempt startup --all --json`. FullRepresentation shows it in place of the update list while its
// header's Startup button is on.
//
// It only reads. Nothing here starts, stops, fixes or edits anything: the one action is Copy
// Command, which puts the CLI's own `systemctl status` line on the clipboard.
//
// Every string is derived in logic.js (startupPageOf) and came from outside the widget (unit
// files, logs, crontabs), so every label is Text.PlainText. Sections with nothing in them are not
// drawn. What failed or changed is listed in full; the long lists are a count until asked for.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

ColumnLayout {
    id: page

    required property var plasmoidItem

    signal backRequested()
    signal copyRequested(string text)

    // null until the first gather answers; then the page, or {ok: false, problem}.
    readonly property var sp: plasmoidItem.startupPage
    readonly property bool busy: plasmoidItem.startupPageBusy
    readonly property bool showsPage: sp !== null && sp.ok === true

    property bool startsOpen: false
    property bool scheduleOpen: false

    spacing: Kirigami.Units.smallSpacing

    // Where the keyboard lands when the page opens.
    function focusFirst() {
        backButton.forceActiveFocus(Qt.TabFocusReason);
    }

    // A section title. A heading to a screen reader, so its headings list can jump between them.
    component SectionHeading: PlasmaExtras.Heading {
        Layout.fillWidth: true
        Layout.topMargin: Kirigami.Units.smallSpacing
        level: 5
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        Accessible.role: Accessible.Heading
        Accessible.name: text
    }

    // A line of text from the page.
    component PageLine: PlasmaComponents.Label {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        visible: text.length > 0
    }

    // Show All and Hide for one long list. `section` names the list for a screen reader, since
    // two of these share the page.
    component ListToggle: PlasmaComponents.ToolButton {
        property bool open: false
        property string section: ""
        signal toggled()
        text: open ? i18n("Hide") : i18n("Show All")
        icon.name: open ? "go-up" : "go-down"
        Accessible.name: text + ": " + section
        Keys.onReturnPressed: animateClick()
        Keys.onEnterPressed: animateClick()
        onClicked: toggled()
    }

    // --- the page's own row: Back, then the spinner and Refresh ---------------------------------
    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents.ToolButton {
            id: backButton
            icon.name: "go-previous"
            text: i18n("Back")
            Accessible.name: text
            Accessible.description: i18n("Returns to the list of updates.")
            Keys.onReturnPressed: animateClick()
            Keys.onEnterPressed: animateClick()
            onClicked: page.backRequested()
        }

        Item { Layout.fillWidth: true }

        PlasmaComponents.BusyIndicator {
            id: busyIndicator
            running: page.busy
            visible: running
            implicitWidth: Kirigami.Units.iconSizes.small
            implicitHeight: Kirigami.Units.iconSizes.small
        }

        PlasmaComponents.ToolButton {
            id: refreshButton
            icon.name: "view-refresh"
            display: PlasmaComponents.AbstractButton.IconOnly
            text: i18n("Refresh")
            Accessible.name: text
            Accessible.description: i18n("Reads the startup list again.")
            PlasmaComponents.ToolTip.text: Accessible.description
            PlasmaComponents.ToolTip.visible: hovered || visualFocus
            PlasmaComponents.ToolTip.delay: Kirigami.Units.toolTipDelay
            // Disabled, not hidden, while a gather runs: the keyboard may be standing on it.
            enabled: !page.busy
            Keys.onReturnPressed: animateClick()
            Keys.onEnterPressed: animateClick()
            onClicked: if (enabled) page.plasmoidItem.gatherStartupPage()
        }
    }

    PlasmaComponents.ScrollView {
        id: scroll
        Layout.fillWidth: true
        Layout.fillHeight: true
        PlasmaComponents.ScrollBar.horizontal.policy: PlasmaComponents.ScrollBar.AlwaysOff
        contentWidth: availableWidth

        ColumnLayout {
            id: body
            width: scroll.availableWidth
            spacing: Kirigami.Units.smallSpacing

            PageLine {
                id: loadingLabel
                text: page.busy && page.sp === null ? i18n("Reading what starts with the computer…") : ""
                opacity: 0.8
            }

            // A gather that failed or answered garbage: said once, calmly, with Refresh above.
            PageLine {
                id: problemLabel
                text: page.sp !== null && page.sp.ok !== true ? page.sp.problem : ""
            }

            PageLine {
                id: emptyLabel
                text: page.showsPage && page.sp.empty ? i18n("Kempt found nothing to list.") : ""
                opacity: 0.8
            }

            Repeater {
                id: notesRepeater
                model: page.showsPage ? page.sp.notes : []
                PageLine {
                    required property string modelData
                    text: modelData
                }
            }

            PageLine {
                id: bootLabel
                text: page.showsPage ? page.sp.bootLine : ""
            }

            // --- what failed, in full --------------------------------------------------------------
            SectionHeading {
                id: failedHeading
                visible: page.showsPage && page.sp.failed.length > 0
                text: i18n("Didn't start this boot")
            }

            Repeater {
                id: failedRepeater
                model: page.showsPage ? page.sp.failed : []

                ColumnLayout {
                    id: failedEntry
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.largeSpacing
                    spacing: 0

                    PageLine {
                        text: failedEntry.modelData.title
                        font.weight: Font.DemiBold
                    }
                    PageLine {
                        text: failedEntry.modelData.log
                        font: Kirigami.Theme.smallFont
                    }
                    PlasmaComponents.ToolButton {
                        visible: failedEntry.modelData.command.length > 0
                        icon.name: "edit-copy"
                        text: i18n("Copy Command")
                        Accessible.name: text + ": " + failedEntry.modelData.title
                        Accessible.description: failedEntry.modelData.command
                        PlasmaComponents.ToolTip.text: failedEntry.modelData.command
                        PlasmaComponents.ToolTip.visible: hovered || visualFocus
                        PlasmaComponents.ToolTip.delay: Kirigami.Units.toolTipDelay
                        Keys.onReturnPressed: animateClick()
                        Keys.onEnterPressed: animateClick()
                        onClicked: page.copyRequested(failedEntry.modelData.command)
                    }
                }
            }

            PageLine {
                id: failedNoteLabel
                text: page.showsPage ? page.sp.failedNote : ""
                font: Kirigami.Theme.smallFont
                opacity: 0.8
            }

            // --- what changed since the last update ------------------------------------------------
            SectionHeading {
                visible: page.showsPage && page.sp.changed.length > 0
                text: page.showsPage ? page.sp.changedTitle : ""
            }

            Repeater {
                id: changedRepeater
                model: page.showsPage ? page.sp.changed : []
                PageLine {
                    required property string modelData
                    Layout.leftMargin: Kirigami.Units.largeSpacing
                    text: modelData
                }
            }

            // --- scheduled jobs whose last run failed ----------------------------------------------
            SectionHeading {
                visible: page.showsPage && page.sp.timerFailures.length > 0
                text: i18n("Last run failed")
            }

            Repeater {
                id: timerFailRepeater
                model: page.showsPage ? page.sp.timerFailures : []
                PageLine {
                    required property string modelData
                    Layout.leftMargin: Kirigami.Units.largeSpacing
                    text: modelData
                }
            }

            // --- what starts: a count, the list on request -----------------------------------------
            SectionHeading {
                id: startsHeading
                visible: page.showsPage && (page.sp.startsLines.length > 0 || page.sp.skippedLine.length > 0)
                text: i18n("Starts with the computer")
            }

            RowLayout {
                Layout.fillWidth: true
                visible: page.showsPage && page.sp.startsLines.length > 0
                PageLine {
                    id: startsSummaryLabel
                    text: page.showsPage ? page.sp.startsSummary : ""
                }
                ListToggle {
                    id: startsToggle
                    open: page.startsOpen
                    section: startsHeading.text
                    onToggled: page.startsOpen = !page.startsOpen
                }
            }

            Repeater {
                id: startsRepeater
                model: page.showsPage && page.startsOpen ? page.sp.startsLines : []
                PageLine {
                    required property var modelData
                    Layout.leftMargin: Kirigami.Units.largeSpacing * (modelData.indent + 1)
                    text: modelData.text
                    font.weight: modelData.heading ? Font.DemiBold : Font.Normal
                }
            }

            PageLine {
                id: skippedLabel
                text: page.showsPage ? page.sp.skippedLine : ""
                font: Kirigami.Theme.smallFont
                opacity: 0.8
            }

            // --- what runs on a schedule: a count and its notes, the list on request ---------------
            SectionHeading {
                id: scheduleHeading
                visible: page.showsPage && page.sp.scheduleLines.length > 0
                text: i18n("Runs on a schedule")
            }

            RowLayout {
                Layout.fillWidth: true
                visible: scheduleHeading.visible
                PageLine {
                    id: scheduleSummaryLabel
                    text: page.showsPage ? page.sp.scheduleSummary : ""
                }
                ListToggle {
                    id: scheduleToggle
                    open: page.scheduleOpen
                    section: scheduleHeading.text
                    onToggled: page.scheduleOpen = !page.scheduleOpen
                }
            }

            Repeater {
                id: scheduleNotesRepeater
                model: page.showsPage ? page.sp.scheduleNotes : []
                PageLine {
                    required property string modelData
                    text: modelData
                }
            }

            Repeater {
                id: scheduleRepeater
                model: page.showsPage && page.scheduleOpen ? page.sp.scheduleLines : []
                PageLine {
                    required property var modelData
                    Layout.leftMargin: Kirigami.Units.largeSpacing * (modelData.indent + 1)
                    text: modelData.text
                    font.weight: modelData.heading ? Font.DemiBold : Font.Normal
                }
            }
        }
    }
}
