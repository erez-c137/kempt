// Task W1 SKELETON. Task W3 replaces this with the real popup: the pending and held lists,
// Update Now / Refresh, the offline recommendation and the updating log tail.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

Item {
    Layout.minimumWidth: Kirigami.Units.gridUnit * 20
    Layout.minimumHeight: Kirigami.Units.gridUnit * 14

    PlasmaComponents.Label {
        anchors.centerIn: parent
        text: "Upkeep"
    }
}
