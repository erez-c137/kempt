// One row in the popup: a package, the version it is moving between, and the pin that decides
// whether it moves at all.
//
// The pin is the spec's Holds promise made clickable. Pinning runs `kempt hold <backend>:<name>`
// and re-checks, so the row moves down into the Held group on the next refresh - the same hold
// the CLI would apply, written to the same file, visible to `kempt holds`. There is no
// widget-local idea of a hold.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

RowLayout {
    id: row

    required property string name
    required property string from
    required property string to
    required property bool held
    required property string backend
    // THIS row's hold is in flight and its follow-up check has not landed. The button stays
    // enabled - Qt strips focus from a control the moment it is disabled, and this is the control
    // the person is standing on - so the guard against a second press lives in onClicked instead.
    required property bool pending
    // ...and some OTHER row's is. Those stand down, which is where the old global disable was
    // right: two holds at once is not something the CLI or the re-check are built for.
    required property bool otherPending
    // What went wrong with the last hold on THIS package, or "". Under the version rather than at
    // the top of the popup, because that is where the hand is.
    required property string errorText

    // `keyboard` is how the press arrived: the pin's visualFocus, which QQC2 sets only for the
    // keyboard focus reasons. The popup needs it because the two presses owe opposite things after
    // the row moves - the keyboard has to be taken to the row, and a pointer must not have the
    // list scrolled out from under it.
    signal toggleHold(string backend, string name, bool hold, bool keyboard)

    // The list refocuses this row by name after the model is rebuilt, and it cannot reach into the
    // delegate for a private id. Qt.TabFocusReason and not the default: a QQC2 control draws its
    // ring on `visualFocus`, which only the keyboard reasons set, so any other reason here would
    // be focus nobody can see.
    function focusPin() {
        pinButton.forceActiveFocus(Qt.TabFocusReason);
    }

    // The pin has taken keyboard focus. A row does not know it is in a list and cannot scroll
    // itself, so it says so and the list decides what to do about it.
    signal pinFocused()

    spacing: Kirigami.Units.smallSpacing

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        PlasmaComponents.Label {
            Layout.fillWidth: true
            text: row.name
            // The name is the line that gives way. It elides on purpose: a package name long
            // enough to need the whole row would otherwise push the pin off the end of it, and a
            // truncated name is still recognisable in a way a truncated version string is not.
            elide: Text.ElideRight
            // A held row is still legible, just visibly out of the running.
            opacity: row.held ? 0.7 : 1.0
        }

        PlasmaComponents.Label {
            Layout.fillWidth: true
            // logic.js has already reduced any comma-joined multilib or installonly set to the
            // newest member, the same way `kempt summary` renders it.
            text: row.from + " → " + row.to
            // FULL, always. This is the line a person compares between two machines, and the
            // epoch, the release and the vendor tag all carry meaning - `2:24.19.0-1nodesource`
            // says something `2:24.19.0-1no…` does not. Eliding throws away the tail, which is
            // precisely the half that differs. So it wraps onto a second line instead: the row
            // gets taller, and nothing is lost.
            elide: Text.ElideNone
            wrapMode: Text.Wrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
        }

        // What went wrong with the last hold on this package. Here rather than in the message
        // stack at the top of the popup: a failed hold used to arrive as the fifth InlineMessage,
        // up to 300 px from the pin that caused it, saying neither hold nor unhold (HIG P6). It is
        // announced as well, so the report reaches a screen reader at the same moment.
        PlasmaComponents.Label {
            Layout.fillWidth: true
            visible: row.errorText.length > 0
            text: row.errorText
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.Wrap
            font: Kirigami.Theme.smallFont
        }
    }

    PlasmaComponents.ToolButton {
        id: pinButton
        // The icon is the ACTION, not the state: a pinned row offers to unpin.
        // ...and nothing at all while this row's own hold is in flight: the spinner below stands
        // in its place, at the same size, so the row says "working" where the person pressed.
        icon.name: row.pending ? "" : (row.held ? "window-unpin" : "window-pin")
        checkable: false
        // ONLY for a hold on some other row. The pressed row's own button stays live, which is the
        // whole finding: a control that disables itself under the press throws the keyboard onto
        // an anonymous container 30 ms later, and the person is left with no focus and no news.
        enabled: !row.otherPending
        display: PlasmaComponents.AbstractButton.IconOnly
        text: row.held ? i18n("Stop holding %1", row.name) : i18n("Hold %1 at its current version", row.name)
        // Icon-only, so `text` is never drawn: the tooltip is what a pointer gets and this is what
        // everybody else gets. It has to be the same sentence and it has to name the PACKAGE - a
        // list of twelve identical "Hold" buttons is a list nobody can use from the keyboard - so
        // it is bound to `text` rather than written out, which is also the only form that can
        // carry a name.
        Accessible.description: text
        // A ListView only builds the delegates near its viewport, so on a real Fedora update -
        // a hundred packages, most of them never rendered - the focus chain contains only the
        // rows that happen to exist, and Tab walks as far as the last one and then leaves the
        // list entirely. Measured on the 24-package fixture, 2026-08-27: 17 pins reachable, 7
        // unreachable. Announcing the focus lets the list scroll this row into view, which puts
        // the focus ring back on screen AND builds the rows after it.
        onActiveFocusChanged: if (activeFocus) row.pinFocused()
        PlasmaComponents.ToolTip.text: text
        PlasmaComponents.ToolTip.visible: hovered
        PlasmaComponents.ToolTip.delay: Kirigami.Units.toolTipDelay
        // The guard the `enabled` binding used to be. A second press on the package already in
        // flight is refused HERE, where refusing costs no focus - the CLI never gets the duplicate
        // `hold` a probe measured on the old code.
        onClicked: if (!row.pending) row.toggleHold(row.backend, row.name, !row.held,
                                                    pinButton.visualFocus)

        // ...and what the row shows meanwhile. In the icon's place rather than beside it, at the
        // icon's own size, so nothing in the row moves: the only feedback before this was a 16 px
        // spinner in the header cell, which says a check is running and nothing about this row.
        // A plain child of a Control, so it contributes nothing to the button's implicit size.
        PlasmaComponents.BusyIndicator {
            id: pinBusy
            anchors.centerIn: parent
            running: row.pending
            visible: running
            implicitWidth: Kirigami.Units.iconSizes.small
            implicitHeight: Kirigami.Units.iconSizes.small
        }
    }
}
