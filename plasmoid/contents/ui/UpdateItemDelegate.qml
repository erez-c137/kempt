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
    required property bool busy      // a hold/unhold is in flight: do not let it be clicked twice

    signal toggleHold(string backend, string name, bool hold)

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
    }

    PlasmaComponents.ToolButton {
        // The icon is the ACTION, not the state: a pinned row offers to unpin.
        icon.name: row.held ? "window-unpin" : "window-pin"
        checkable: false
        enabled: !row.busy
        display: PlasmaComponents.AbstractButton.IconOnly
        text: row.held ? i18n("Stop holding %1", row.name) : i18n("Hold %1 at its current version", row.name)
        PlasmaComponents.ToolTip.text: text
        PlasmaComponents.ToolTip.visible: hovered
        PlasmaComponents.ToolTip.delay: Kirigami.Units.toolTipDelay
        onClicked: row.toggleHold(row.backend, row.name, !row.held)
    }
}
