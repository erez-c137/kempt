// Task W1 SKELETON - a plain icon with no state behind it yet. Task W2 replaces this with the
// icon / badge / tooltip mapping driven by Logic.viewModel.
// `root` below is main.qml's PlasmoidItem: a representation is created in main.qml's context, so
// its ids are in scope here. This file's own root carries a different id on purpose, so that
// reference can never be shadowed by accident.
import QtQuick
import org.kde.kirigami as Kirigami

Item {
    id: compactRoot

    Kirigami.Icon {
        anchors.fill: parent
        source: "system-software-update"
        active: mouseArea.containsMouse

        MouseArea {
            id: mouseArea
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.expanded = !root.expanded
        }
    }
}
