// Task W1 SKELETON. Its only job is that `kpackagetool6 -t Plasma/Applet -i plasmoid` has a
// structurally complete package to install from this commit onwards. Task W2 replaces this file
// with the real state machine: the Executor instance, the check flow, the config-driven check
// timer and the 30s mtime watcher.
import QtQuick
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root

    // In a panel the widget is the icon; on the desktop it is the popup.
    preferredRepresentation: Plasmoid.compactRepresentation

    compactRepresentation: CompactRepresentation {}
    fullRepresentation: FullRepresentation {}
}
