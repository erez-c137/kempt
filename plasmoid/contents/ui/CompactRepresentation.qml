// The panel icon and its badge. Pure presentation: every value below is read from main.qml's view
// model, which is derived in logic.js and pinned by the node tests. Nothing is decided here.
//
// `root` is main.qml's PlasmoidItem - a representation is created in main.qml's context, so its
// ids are in scope. This file's own root carries a different id on purpose, so that reference can
// never be shadowed by accident.
import QtQuick
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

Item {
    id: compactRoot

    // Read through guards. A representation is built and torn down independently of main.qml, and
    // on teardown `root` itself can already be gone - so this tests the object before the property
    // rather than only the property. "unknown" is the honest fallback: it renders as "no data yet",
    // never as zero updates.
    readonly property string iconState: (root && root.vm) ? root.vm.iconState : "unknown"
    readonly property string badgeText: (root && root.vm) ? root.vm.badgeText : ""
    readonly property bool badgeVisible: (root && root.vm) ? root.vm.badgeVisible : false

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
        source: {
            switch (compactRoot.iconState) {
            case "updates": return "update-low";
            case "stale":
            case "error":   return "update-high";
            default:        return "update-none";   // uptodate, updating, unknown
            }
        }
        // Dimmed means "we do not know yet", which is a different statement from "up to date".
        opacity: compactRoot.iconState === "unknown" ? 0.6 : 1.0
    }

    // Bottom LEFT, because the count badge owns the bottom right.
    Kirigami.Icon {
        id: warningEmblem
        visible: compactRoot.iconState === "stale" || compactRoot.iconState === "error"
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
        // Grows for a three-digit count instead of clipping it; never narrower than a circle.
        width: Math.max(height, badgeLabel.implicitWidth + Kirigami.Units.smallSpacing)
        radius: height / 2
        color: Kirigami.Theme.highlightColor

        PlasmaComponents.Label {
            id: badgeLabel
            anchors.centerIn: parent
            text: compactRoot.badgeText
            color: Kirigami.Theme.highlightedTextColor
            // Math.max(1, ...): a zero pixelSize is a Qt warning on every layout pass while the
            // panel is still sizing itself.
            font.pixelSize: Math.max(1, Math.round(badge.height * 0.7))
            font.bold: true
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded
    }
}
