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
    // A sentence for a screen reader to say now (FullRepresentation's announce).
    signal announceRequested(string sentence)

    // null until the first gather answers; then the page, or {ok: false, problem}.
    readonly property var sp: plasmoidItem.startupPage
    readonly property bool busy: plasmoidItem.startupPageBusy
    readonly property bool showsPage: sp !== null && sp.ok === true

    property bool startsOpen: false
    property bool scheduleOpen: false

    spacing: Kirigami.Units.smallSpacing

    // What the page says, in reading order, for a screen reader: only its buttons are tab stops,
    // so this is Back's description (the keyboard lands on Back) and is said once when a gather
    // lands, since that happens after the page has opened. The long lists are their counts here,
    // as they are on screen; each toggle's description carries its list.
    readonly property string summary: {
        if (sp === null) return "";
        if (sp.ok !== true) return sp.problem;
        const out = [];
        if (sp.empty) out.push(emptyLabel.text);
        for (const note of sp.notes) out.push(note);
        if (sp.bootLine.length > 0) out.push(sp.bootLine);
        if (sp.failed.length > 0)
            out.push(i18nc("@info:accessible a section heading, then what it holds", "%1: %2.", failedHeading.label,
                           sp.failed.map(f => f.title).join(i18nc("@info:accessible list separator", ", "))));
        if (sp.failedNote.length > 0) out.push(sp.failedNote);
        if (sp.changed.length > 0)
            out.push(i18nc("@info:accessible a section heading, then what it holds", "%1: %2", sp.changedTitle, sp.changed.join(" ")));
        if (sp.timerFailures.length > 0)
            out.push(i18nc("@info:accessible a section heading, then what it holds", "%1: %2", timerFailHeading.label, sp.timerFailures.join(" ")));
        if (sp.startsLines.length > 0)
            out.push(i18nc("@info:accessible a section heading, then what it holds", "%1: %2.", startsHeading.label, sp.startsSummary));
        if (sp.skippedLine.length > 0) out.push(sp.skippedLine);
        if (sp.scheduleLines.length > 0)
            out.push(i18nc("@info:accessible a section heading, then what it holds", "%1: %2.", scheduleHeading.label, sp.scheduleSummary));
        return out.join("\n");
    }

    // Said once per gather that lands while the page is open. Later than the change itself, so the
    // summary has caught up with the new page. Not when Back has already said it since the
    // gather started: a fast gather lands before the keyboard reaches Back.
    property string saidByBack: ""
    onBusyChanged: if (busy) saidByBack = ""
    function sayWhatLanded() {
        if (page.visible && page.sp !== null && page.summary !== page.saidByBack)
            page.announceRequested(page.summary);
    }
    onSpChanged: Qt.callLater(page.sayWhatLanded)

    // Where the keyboard lands when the page opens.
    function focusFirst() {
        backButton.forceActiveFocus(Qt.TabFocusReason);
    }

    // A section title, drawn as the update list draws its groups. Kirigami marks the header's own
    // label Accessible.ignored, so the name is set here, and Heading is what a screen reader jumps
    // between. Every label is a fixed string, or one with a date logic.js formatted itself.
    component SectionHeading: PlasmaExtras.ListSectionHeader {
        Layout.fillWidth: true
        Accessible.role: Accessible.Heading
        Accessible.name: label
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
        text: open ? i18n("Hide") : i18n("Show All")
        icon.name: open ? "go-up" : "go-down"
        Accessible.name: i18nc("@action:button Show All or Hide, then the list it opens", "%1: %2", text, section)
        // What the list holds: its count and notes while folded, and every line once open, since
        // the lines themselves are not tab stops.
        property var lines: []
        property var notes: []
        Accessible.description: notes.concat(open ? lines.map(l => l.text) : [])
            .filter(t => t.length > 0).join("\n")
        Keys.onReturnPressed: animateClick()
        Keys.onEnterPressed: animateClick()
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
            Accessible.description: page.summary.length > 0
                ? i18n("Returns to the list of updates.") + "\n" + page.summary
                : i18n("Returns to the list of updates.")
            onActiveFocusChanged: if (activeFocus) page.saidByBack = page.summary
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
            // Never disabled: a disabled button drops the keyboard focus standing on it. A press
            // while a gather runs is ignored, here and in gatherStartupPage.
            Keys.onReturnPressed: animateClick()
            Keys.onEnterPressed: animateClick()
            onClicked: if (!page.busy) page.plasmoidItem.gatherStartupPage()
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
                label: i18n("Didn't start this boot")
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
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                    PlasmaComponents.ToolButton {
                        visible: failedEntry.modelData.command.length > 0
                        icon.name: "edit-copy"
                        text: i18n("Copy Command")
                        Accessible.name: i18nc("@action:button Copy Command, then the service it is for",
                                               "%1: %2", text, failedEntry.modelData.title)
                        // What its log says as well: the line above is not a tab stop.
                        Accessible.description: failedEntry.modelData.log.length > 0
                            ? failedEntry.modelData.log + "\n" + failedEntry.modelData.command
                            : failedEntry.modelData.command
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
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                opacity: 0.8
            }

            // --- what changed since the last update ------------------------------------------------
            SectionHeading {
                visible: page.showsPage && page.sp.changed.length > 0
                label: page.showsPage ? page.sp.changedTitle : ""
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
                id: timerFailHeading
                visible: page.showsPage && page.sp.timerFailures.length > 0
                label: i18n("Last run failed")
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
                label: i18n("Starts with the computer")
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
                    section: startsHeading.label
                    notes: page.showsPage ? [page.sp.startsSummary, page.sp.skippedLine] : []
                    lines: page.showsPage ? page.sp.startsLines : []
                    onClicked: page.startsOpen = !page.startsOpen
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
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                opacity: 0.8
            }

            // --- what runs on a schedule: a count and its notes, the list on request ---------------
            SectionHeading {
                id: scheduleHeading
                visible: page.showsPage && page.sp.scheduleLines.length > 0
                label: i18n("Runs on a schedule")
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
                    section: scheduleHeading.label
                    notes: page.showsPage ? [page.sp.scheduleSummary].concat(page.sp.scheduleNotes) : []
                    lines: page.showsPage ? page.sp.scheduleLines : []
                    onClicked: page.scheduleOpen = !page.scheduleOpen
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
