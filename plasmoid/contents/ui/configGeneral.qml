// Task W1 SKELETON - config.qml points here, so the package would be broken without it.
// Task W4 replaces this with the real settings page over `upkeep config`: the two checkboxes,
// the run-surface radios, the refresh interval, the holds list and the passwordless actions.
import QtQuick
import org.kde.plasma.components as PlasmaComponents

Item {
    PlasmaComponents.Label {
        anchors.centerIn: parent
        text: i18n("Settings are not wired up yet.")
    }
}
