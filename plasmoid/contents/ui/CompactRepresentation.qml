// The panel icon and its badge. Pure presentation: every value below comes from the view model
// main.qml derives in logic.js, which the node tests pin. Nothing is decided here.
//
// Both inputs are `required`, and that is the safety property. Reaching across into main.qml's ids
// works right up until it does not - and the failure mode is silent, because a binding that cannot
// resolve its object falls back to whatever the `?:` says and the panel calmly renders a lie. A
// required property cannot be forgotten: the component refuses to be created at all. This is the
// pattern KDE's own widgets use (see org.kde.kdeconnect's CompactRepresentation).
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import "logic.js" as Logic

Item {
    id: compactRoot

    required property PlasmoidItem plasmoidItem   // for expanding the popup on click
    required property var vm                      // the derived view model, never null
    required property string iconSizeSetting      // `widget_icon_size`, straight from `kempt config`

    readonly property string iconState: compactRoot.vm.iconState
    readonly property string badgeText: compactRoot.vm.badgeText
    readonly property bool badgeVisible: compactRoot.vm.badgeVisible

    // What the containment is allowed to squeeze this to. Copied from the shell's own
    // DefaultCompactRepresentation.qml (contents/applet/) rather than invented, because the system
    // tray is a containment too: it hands each entry a square cell at ITS icon size, and a compact
    // representation that asks for more than that pushes every other tray entry around. Asking for
    // a square - the panel's thickness in the direction it is NOT thick - is what both a panel and
    // a tray already want to give, so this constrains nothing and fights nothing.
    Layout.minimumWidth: {
        switch (Plasmoid.formFactor) {
        case PlasmaCore.Types.Vertical:   return 0;
        case PlasmaCore.Types.Horizontal: return height;
        default:                          return Kirigami.Units.gridUnit * 3;
        }
    }
    Layout.minimumHeight: {
        switch (Plasmoid.formFactor) {
        case PlasmaCore.Types.Vertical:   return width;
        case PlasmaCore.Types.Horizontal: return 0;
        default:                          return Kirigami.Units.gridUnit * 3;
        }
    }

    readonly property real shortSide: Math.min(width, height)

    // The size the ICON is asked for, which is not the same as the size of the cell it sits in.
    // Icon themes hint their glyphs at specific pixel sizes - Breeze ships 16px and 22px symbolics
    // as separate artwork, each aligned to the pixel grid at that size. A panel 22px tall handed
    // straight to Kirigami.Icon used to ask for whatever fraction the layout produced, and every
    // hinted stroke landed between pixels: soft, muddy, worst exactly where the icon is smallest.
    //
    // Which step it lands on is Logic.resolveIconSize, and the ladder there is pinned to what the
    // system tray does at ordinary panel thicknesses rather than to "the biggest that fits" - the
    // whole reason this changed is that a 44px panel fits 32px, and a 32px icon standing in a row
    // of 22px tray entries reads as a mistake. Kirigami's own values are passed in so a theme
    // whose steps are not Breeze's still gets its own artwork.
    readonly property int iconSize: Logic.resolveIconSize(compactRoot.iconSizeSetting,
                                                          compactRoot.shortSide, [
        Kirigami.Units.iconSizes.small,        // 16
        Kirigami.Units.iconSizes.smallMedium,  // 22
        Kirigami.Units.iconSizes.medium,       // 32
        Kirigami.Units.iconSizes.large,        // 48
        Kirigami.Units.iconSizes.huge          // 64
    ])

    // Below this there is no room for a legible number, and Plasma widgets drop the overlay
    // rather than draw mush. Measured against the ICON and not the cell, because the icon is now
    // the smaller of the two: a cell-based test would hide the badge on a thin panel while the
    // icon is perfectly capable of carrying it.
    //
    // The floor is the 22px step, not the 16px one, and that is a legibility measurement rather
    // than a guess. The pill is 0.6 of the icon and the label 0.5 of the pill once the count runs
    // past two characters, so a 16px icon renders "347" at FIVE pixels - a grey smudge that says
    // something is pending without saying what, which is worse than saying nothing. At 16 the
    // count lives in the tooltip, which is never capped and never abbreviated; the icon itself
    // still changes (update-none -> update-low), so the panel still says there is something to do.
    readonly property bool roomForBadge: compactRoot.iconSize >= Kirigami.Units.iconSizes.smallMedium

    Kirigami.Icon {
        id: mainIcon
        // Centred at a hinted size rather than stretched to fill: see iconSize above.
        anchors.centerIn: parent
        width: compactRoot.iconSize
        height: compactRoot.iconSize
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
            // NOT update-high. Plasma's own notifier uses the high icon for SECURITY updates, so
            // a Plasma user who sees it opens the popup expecting security fixes and reads "Kempt
            // cannot check for updates" (hostile panel, 4). The error state is drawn by the
            // warning emblem hanging off the icon below, which is a statement about the widget
            // rather than about the transaction; update-high is reserved for a future security
            // classification, which is the one thing that would earn it.
            default:        return "update-none";   // error, uptodate, updating, unknown
            }
        }
        // Dimmed means "we do not know yet", which is a different statement from "up to date".
        opacity: compactRoot.iconState === "unknown" ? 0.6 : 1.0
    }

    // Bottom LEFT, because the count badge owns the bottom right.
    // ONLY for a real error - a state we cannot read, or a CLI we could not run. Staleness does
    // not get one: see the icon mapping above.
    //
    // Anchored to the ICON, not to the cell. Everything in this file used to measure itself
    // against the cell, which was the same thing back when the icon filled it. It no longer does:
    // on a 44px panel the icon is 22, so a cell-anchored emblem floated in a corner 11 pixels away
    // from the glyph it is supposed to be marking, at nearly the glyph's own size.
    Kirigami.Icon {
        id: warningEmblem
        visible: compactRoot.iconState === "error"
        source: "emblem-warning"
        width: Math.round(compactRoot.iconSize * 0.45)
        height: width
        anchors.left: mainIcon.left
        anchors.bottom: mainIcon.bottom
    }

    PlasmaComponents.BusyIndicator {
        id: busy
        visible: compactRoot.iconState === "updating"
        running: visible                     // never animate an invisible spinner in the panel process
        anchors.centerIn: mainIcon
        width: Math.round(compactRoot.iconSize * 0.9)
        height: width
    }

    Rectangle {
        id: badge
        visible: compactRoot.badgeVisible && compactRoot.roomForBadge
        anchors.right: mainIcon.right
        anchors.bottom: mainIcon.bottom
        // 0.6 of the ICON, where it used to be 0.5 of the cell. Both numbers came out around the
        // same size while the icon filled the cell; now that it does not, 0.5 of a 22px icon is an
        // 11px pill and a two-digit count inside it is a smudge. Six tenths of the glyph is the
        // proportion Plasma's own tray badges read as, and at the 22px step that is a 13px pill -
        // legible, and still inside a cell twice as tall.
        height: Math.round(compactRoot.iconSize * 0.6)
        // Grows for a longer count instead of clipping it, never narrower than a circle, and
        // never wider than the icon it sits on. The cap is 999+, so four characters is the most
        // this ever has to hold.
        width: Math.min(compactRoot.iconSize,
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
