// The panel icon and its badge. Pure presentation: every value below comes from the view model
// main.qml derives in logic.js, which the node tests pin. Nothing is decided here.
//
// Both inputs are `required`, and that is the safety property. Reaching across into main.qml's ids
// works right up until it does not - and the failure mode is silent, because a binding that cannot
// resolve its object falls back to whatever the `?:` says and the panel calmly renders a lie. A
// required property cannot be forgotten: the component refuses to be created at all. This is the
// pattern KDE's own widgets use (see org.kde.kdeconnect's CompactRepresentation).
import QtQuick
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

Item {
    id: compactRoot

    required property PlasmoidItem plasmoidItem   // for expanding the popup on click
    required property var vm                      // the derived view model, never null

    readonly property string iconState: compactRoot.vm.iconState
    readonly property string badgeText: compactRoot.vm.badgeText
    readonly property bool badgeVisible: compactRoot.vm.badgeVisible

    // A panel a few pixels tall cannot show a legible number; Plasma widgets drop the overlay
    // rather than draw mush.
    readonly property real shortSide: Math.min(width, height)
    readonly property bool roomForBadge: shortSide >= Kirigami.Units.iconSizes.small * 1.5

    Kirigami.Icon {
        id: mainIcon
        anchors.fill: parent
        active: mouseArea.containsMouse
        // update-none / update-low / update-high are the Breeze update icons the rest of Plasma
        // uses for exactly this, so the panel stays visually consistent with Discover's notifier.
        //
        // Stale renders its CONTENTS, not its staleness: a repo that flapped for one check is not
        // a broken machine, and an alarm icon for it trains the user to ignore alarms. The counts
        // are still the best known truth, so a stale state with pending updates looks exactly like
        // a fresh one with pending updates - and the tooltip carries the reason and the age.
        source: {
            switch (compactRoot.iconState) {
            case "updates": return "update-low";
            case "stale":   return compactRoot.badgeVisible ? "update-low" : "update-none";
            case "error":   return "update-high";
            default:        return "update-none";   // uptodate, updating, unknown
            }
        }
        // Dimmed means "we do not know yet", which is a different statement from "up to date".
        opacity: compactRoot.iconState === "unknown" ? 0.6 : 1.0
    }

    // Bottom LEFT, because the count badge owns the bottom right.
    // ONLY for a real error - a state we cannot read, or a CLI we could not run. Staleness does
    // not get one: see the icon mapping above.
    Kirigami.Icon {
        id: warningEmblem
        visible: compactRoot.iconState === "error"
        source: "emblem-warning"
        width: Math.round(compactRoot.shortSide * 0.45)
        height: width
        anchors.left: parent.left
        anchors.bottom: parent.bottom
    }

    PlasmaComponents.BusyIndicator {
        id: busy
        visible: compactRoot.iconState === "updating"
        running: visible                     // never animate an invisible spinner in the panel process
        anchors.centerIn: parent
        width: Math.round(compactRoot.shortSide * 0.7)
        height: width
    }

    Rectangle {
        id: badge
        visible: compactRoot.badgeVisible && compactRoot.roomForBadge
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.round(compactRoot.shortSide * 0.5)
        // Grows for a longer count instead of clipping it, never narrower than a circle, and
        // never wider than the icon it sits on. The cap is 999+, so four characters is the most
        // this ever has to hold.
        width: Math.min(compactRoot.width,
                        Math.max(height, badgeLabel.implicitWidth + Kirigami.Units.smallSpacing))
        radius: height / 2
        color: Kirigami.Theme.highlightColor

        PlasmaComponents.Label {
            id: badgeLabel
            anchors.centerIn: parent
            text: compactRoot.badgeText
            color: Kirigami.Theme.highlightedTextColor
            // Long counts get a smaller face rather than a wider badge: "999+" at the two-digit
            // size would be as wide as the whole panel icon.
            // Math.max(1, ...): a zero pixelSize is a Qt warning on every layout pass while the
            // panel is still sizing itself.
            font.pixelSize: Math.max(1, Math.round(badge.height * (text.length > 2 ? 0.5 : 0.7)))
            font.bold: true
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        onClicked: compactRoot.plasmoidItem.expanded = !compactRoot.plasmoidItem.expanded
    }
}
