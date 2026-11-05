// The Startup Report: the services that failed after an update, each with its two buttons, over
// the text of `kempt startup --all`. FullRepresentation shows it in place of the update list. It
// starts, stops and fixes nothing. Mute only tells Kempt to stop mentioning a service.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

ColumnLayout {
    id: page

    required property var plasmoidItem

    signal backRequested()
    signal copyRequested(string text)
    // A sentence for a screen reader to say now (FullRepresentation's announce).
    signal announceRequested(string sentence)

    readonly property var vm: plasmoidItem.vm
    // null until the first gather answers; then {ok: true, text} or {ok: false, problem}.
    readonly property var sp: plasmoidItem.startupPage
    readonly property bool busy: plasmoidItem.startupPageBusy

    spacing: Kirigami.Units.smallSpacing

    onSpChanged: if (visible && sp !== null && sp.ok !== true) announceRequested(sp.problem)
    // A mute that failed is said in its row, and to a screen reader, where the press was.
    readonly property var muteError: plasmoidItem.startupMuteError
    onMuteErrorChanged: if (visible && muteError !== null) announceRequested(muteError.text)

    // Where the keyboard lands when the page opens.
    function focusFirst() {
        backButton.forceActiveFocus(Qt.TabFocusReason);
    }

    // A muted service leaves the list, so the keyboard goes to the next one's first button, or to
    // Back when none is left. Later, because the buttons are rebuilt from the new state first.
    function mute(at) {
        const s = vm.startupEntries[at];
        if (s) plasmoidItem.muteStartup(s.unit, s.scope, s.name, () => Qt.callLater(() => {
            const next = failedRepeater.itemAt(at);
            (next ? next.copyButton : backButton).forceActiveFocus(Qt.TabFocusReason);
        }));
    }

    // In the scrolling list, the keyboard must not end up on a button below its fold.
    function keepInView(button) {
        const list = failedScroll.contentItem;
        const top = button.mapToItem(list.contentItem, 0, 0).y;
        list.contentY = Math.max(0, Math.min(top, Math.max(list.contentY, top + button.height - list.height)));
    }

    component PageLine: PlasmaComponents.Label {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        visible: text.length > 0
    }

    component PageButton: PlasmaComponents.ToolButton {
        Accessible.name: text
        PlasmaComponents.ToolTip.text: Accessible.description
        PlasmaComponents.ToolTip.visible: (hovered || visualFocus) && Accessible.description.length > 0
        PlasmaComponents.ToolTip.delay: Kirigami.Units.toolTipDelay
        Keys.onReturnPressed: animateClick()
        Keys.onEnterPressed: animateClick()
    }

    RowLayout {
        Layout.fillWidth: true
        PageButton {
            id: backButton
            icon.name: "go-previous"
            text: i18n("Back")
            Accessible.description: [i18n("Returns to the list of updates."), page.vm.startupTitle]
                .filter(t => t.length > 0).join("\n")
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
        PageButton {
            id: refreshButton
            icon.name: "view-refresh"
            display: PlasmaComponents.AbstractButton.IconOnly
            text: i18n("Refresh")
            Accessible.description: i18n("Reads the startup list again.")
            // Never disabled: that would drop the keyboard standing on it. A press during a
            // gather is ignored.
            onClicked: if (!page.busy) page.plasmoidItem.gatherStartupPage()
        }
    }

    PlasmaComponents.ScrollView {
        id: failedScroll
        visible: failedRepeater.count > 0
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(failedColumn.implicitHeight, page.height / 2)
        PlasmaComponents.ScrollBar.horizontal.policy: PlasmaComponents.ScrollBar.AlwaysOff

        ColumnLayout {
            id: failedColumn
            width: failedScroll.availableWidth
            PageLine {
                id: failedHeading
                text: page.vm.startupHeading
                font.weight: Font.DemiBold
            }
            Repeater {
                id: failedRepeater
                // A count, not the array: a new state read must not rebuild the button under the keyboard.
                model: page.vm.startupEntries.length
                ColumnLayout {
                    id: entry
                    required property int index
                    readonly property var service: page.vm.startupEntries[index]
                        || ({ unit: "", scope: "", name: "", command: "", text: "" })
                    readonly property string key: service.scope + ":" + service.unit
                    readonly property var muteError: page.plasmoidItem.startupMuteError
                    readonly property bool muting: page.plasmoidItem.startupMutePending === key
                    readonly property alias copyButton: copyButton
                    readonly property alias muteButton: muteButton
                    readonly property alias label: label
                    Layout.fillWidth: true
                    spacing: 0
                    PageLine {
                        id: label
                        text: entry.muteError && entry.muteError.key === entry.key
                            ? entry.service.text + "\n" + entry.muteError.text : entry.service.text
                    }
                    Flow {
                        Layout.fillWidth: true
                        PageButton {
                            id: copyButton
                            onActiveFocusChanged: if (activeFocus) page.keepInView(this)
                            icon.name: "edit-copy"
                            text: i18n("Copy Command")
                            Accessible.name: i18nc("@action:button a service's name follows", "Copy Command: %1", entry.service.name)
                            Accessible.description: entry.service.command
                            onClicked: page.copyRequested(entry.service.command)
                        }
                        PageButton {
                            id: muteButton
                            onActiveFocusChanged: if (activeFocus) page.keepInView(this)
                            icon.name: "notifications-disabled"
                            text: entry.muting ? i18n("Muting…") : i18n("Mute Until It Starts")
                            Accessible.name: entry.muting
                                ? i18nc("@action:button a service's name follows", "Muting…: %1", entry.service.name)
                                : i18nc("@action:button a service's name follows", "Mute Until It Starts: %1", entry.service.name)
                            Accessible.description: i18n("Kempt stops mentioning it until it starts cleanly again.")
                            onClicked: page.mute(entry.index)
                        }
                    }
                }
            }
            PageLine {
                id: alreadyLabel
                text: page.vm.startupAlready
                font: Kirigami.Theme.smallFont
                opacity: 0.7
            }
        }
    }

    PageLine {
        id: noteLabel
        text: page.sp === null ? (page.busy ? i18n("Reading what starts with the computer…") : "")
            : (page.sp.ok === true ? "" : page.sp.problem)
    }
    ReportText {
        id: report
        name: i18n("Startup Report")
        text: page.sp !== null && page.sp.ok === true ? page.sp.text : ""
        visible: text.length > 0
        Layout.fillWidth: true
        Layout.fillHeight: true
    }
    Item {
        visible: !report.visible
        Layout.fillHeight: true
    }
}
