// One row in the popup: a package, the version it is moving between, and the padlock that decides
// whether it moves at all.
//
// The padlock is the spec's Holds promise made clickable. Pressing it runs
// `kempt hold <backend>:<name>` and re-checks, so the row moves down into the Held group on the
// next refresh - the same hold the CLI would apply, written to the same file, visible to
// `kempt holds`. There is no widget-local idea of a hold.
//
// It used to be a pushpin, and that was the hostile panel's finding 4. `window-pin` is the icon of
// Plasma's own checkable "Keep Open" button - in the system tray heading, in the calendar popup,
// in the folder-view popup: three shipped uses, one meaning, and this column of pins sits directly
// beneath the tray's. `window-unpin` paints its slash in the scheme's NegativeText red, so the two
// rows a person had deliberately protected carried the popup's only red mark and read as cancelled.
// `object-locked` / `object-unlocked` has a package-manager precedent (Synaptic's Lock Version,
// dnf's own versionlock) and no Plasma collision. The residual, stated: a dnf user may read
// versionlock into a padlock, which Kempt's hold is not - and that is what the description and the
// line under the Held heading answer.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "logic.js" as Logic

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

    // `keyboard` is how the press arrived: the padlock's visualFocus, which QQC2 sets only for
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

    // A package that is not installed yet: the CLI writes "?" for its current version, and there
    // is nothing to hold it AT. What the padlock does on such a row is refuse the install, and it
    // says so - see COPY.skipInstalling.
    readonly property bool newPackage: row.from === Logic.VERSION_UNKNOWN

    // ...and what the version line draws in its place. One property, read by the line and by its
    // accessible name, so the two cannot say different things about the same row.
    readonly property string fromText: row.newPackage ? i18n("new") : row.from

    spacing: Kirigami.Units.smallSpacing

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        PlasmaComponents.Label {
            Layout.fillWidth: true
            text: row.name
            // The name is the line that gives way. It elides on purpose: a package name long
            // enough to need the whole row would otherwise push the padlock off the end of it,
            // and a
            // truncated name is still recognisable in a way a truncated version string is not.
            elide: Text.ElideRight
            // NO opacity dip on a held row. It used to drop to 0.7, which is a contrast REDUCTION
            // applied to the rows a person deliberately protected, and in a high-contrast or
            // fallback theme it was the loudest cue there was (a11y P6). The state is the token
            // beside the version and the padlock at the end of the row: words and a glyph, never
            // a shade.
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            // The state, as a word, on the row. Before the version rather than after it, so a scan
            // down the list reads the tokens in one column.
            PlasmaComponents.Label {
                visible: row.held
                text: i18n("Held")
                font: Kirigami.Theme.smallFont
            }

            PlasmaComponents.Label {
                Layout.fillWidth: true
                // logic.js has already reduced any comma-joined multilib or installonly set to the
                // newest member, the same way `kempt summary` renders it.
                text: row.fromText + " → " + row.to
                // FULL, always. This is the line a person compares between two machines, and the
                // epoch, the release and the vendor tag all carry meaning - `2:24.19.0-1nodesource`
                // says something `2:24.19.0-1no…` does not. Eliding throws away the tail, which is
                // precisely the half that differs. So it wraps onto a second line instead: the row
                // gets taller, and nothing is lost.
                elide: Text.ElideNone
                wrapMode: Text.Wrap
                opacity: 0.7
                font: Kirigami.Theme.smallFont
                // ...and the same fact in words, because that arrow reaches a screen reader
                // through its character table and "3.105 right arrow 3.106" is not a version.
                Accessible.name: i18n("from %1 to %2", row.fromText, row.to)
            }
        }

        // What went wrong with the last hold on this package. Here rather than in the message
        // stack at the top of the popup: a failed hold used to arrive as the fifth InlineMessage,
        // up to 300 px from the padlock that caused it, saying neither hold nor unhold (HIG P6).
        // It is
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
        // The icon is the STATE now: a closed padlock is a held row, an open one is a row that can
        // be held. That is the opposite of what this file used to say, and the reason is the HIG's
        // own rule for two-state controls - a scan of the list has to show the state, and a person
        // was never told the "icon is the action" convention. The verb lives in the name and the
        // tooltip, which is where a verb can be a sentence.
        // ...and nothing at all while this row's own hold is in flight: the spinner below stands
        // in its place, at the same size, so the row says "working" where the person pressed.
        icon.name: row.pending ? "" : (row.held ? "object-locked" : "object-unlocked")
        // Still not checkable, and that is the HIG ("avoid making buttons checkable": their
        // checkability is not obvious when unchecked). It also decides the AT-SPI residual: on
        // Qt 6.11 a checked state reaches an assistive technology only through the CheckBox role,
        // which would draw Breeze's sunken checked background on a control sitting under the
        // tray's own checked Keep Open pin. So the name carries the state instead.
        checkable: false
        // The row's full height, which is 43 px against the button's own 30: WCAG 2.5.5 wants 44,
        // adjacent padlocks were 13 px apart, and the row is already that tall.
        Layout.fillHeight: true
        // ONLY for a hold on some other row. The pressed row's own button stays live, which is the
        // whole finding: a control that disables itself under the press throws the keyboard onto
        // an anonymous container 30 ms later, and the person is left with no focus and no news.
        enabled: !row.otherPending
        display: PlasmaComponents.AbstractButton.IconOnly
        // Four spellings, and the state is in every one of them: this is the only channel that
        // carries it to a screen reader. The version is named rather than called "its current
        // version" - it is the fact a person checks - and a package with no current version is
        // offered a refusal to install rather than a hold at a version it does not have.
        text: row.newPackage
              ? (row.held ? i18n("Stop skipping %1", row.name) : i18n("Skip installing %1", row.name))
              : (row.held ? i18n("Stop holding %1", row.name)
                          : i18n("Hold %1 at %2", row.name, row.from))
        // Icon-only, so `text` is never drawn: the tooltip is what a pointer gets and this is what
        // everybody else gets. Spelled out rather than left to QQC2, which does hand `text` over as
        // the accessible name - except that a probe measured an EMPTY name on every button in this
        // widget when accessibility was activated before construction. A belt, not a duplicate.
        Accessible.name: text
        // ...and the description is the CONSEQUENCE. It used to be `text` again, so a screen
        // reader said the same sentence twice and the one slot that could explain what pressing
        // this does was spent saying nothing (a11y P4). Kempt-only and per package, because a dnf
        // user reads versionlock into a padlock and a kernel is three rows.
        Accessible.description: row.held ? i18n("Kempt offers its update again.")
                                         : i18n("Kempt skips it on every update until you stop holding it.")
        // A ListView only builds the delegates near its viewport, so on a real Fedora update -
        // a hundred packages, most of them never rendered - the focus chain contains only the
        // rows that happen to exist, and Tab walks as far as the last one and then leaves the
        // list entirely. Measured on the 24-package fixture, 2026-08-27: 17 padlocks reachable, 7
        // unreachable. Announcing the focus lets the list scroll this row into view, which puts
        // the focus ring back on screen AND builds the rows after it.
        onActiveFocusChanged: if (activeFocus) row.pinFocused()
        PlasmaComponents.ToolTip.text: text
        // On focus as well as on hover. The tooltip is the best copy in this widget and it was
        // reachable only with a pointer, so a sighted keyboard user got an unlabelled icon (a11y P8).
        PlasmaComponents.ToolTip.visible: hovered || visualFocus
        PlasmaComponents.ToolTip.delay: Kirigami.Units.toolTipDelay
        // Return and keypad Enter sent nothing at all: QQC2 activates a button on Space only, and
        // half the world presses Enter. animateClick() is the shipped Plasma pattern, per button
        // (MonthViewHeader.qml), and it draws the press as well as sending it.
        Keys.onReturnPressed: animateClick()
        Keys.onEnterPressed: animateClick()
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
