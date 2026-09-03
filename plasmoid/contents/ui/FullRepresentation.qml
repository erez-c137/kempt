// The popup: what is pending, what is held, what needs saying about it, and the one button that
// acts on it.
//
// Like the panel icon, this file decides nothing: every string and every list comes from the view
// model main.qml derives in logic.js, and every action is a call back into main.qml.
//
// The SHAPE is Plasma's own, and each of the three rows is a decision with evidence behind it in
// docs/research/2026-08-26-popup-panel/hig-review.md:
//   header  - the pending count and a refresh icon. Nothing else. A PlasmoidHeading is a
//             T.ToolBar, and a toolbar is for flat controls, not for messages.
//   content - a Kirigami.InlineMessage per thing that needs saying, then the list, then what the
//             last run did. Every message that used to be stacked in the header lives here now.
//   footer  - the status line and Update Now. The heading is the row Plasma's contract lets the
//             containment REPLACE; the footer is not, and Update Now is the one control in this
//             widget that must exist on every host, in every containment.
//
// EVERY reference to the widget goes through `plasmoidItem`, never through main.qml's `root` id.
// That distinction is not style. A representation whose required properties are all satisfied is
// created successfully; if it then reaches for an id from a context it does not have, each such
// binding throws a ReferenceError and silently evaluates to undefined - so `!undefined.updating`
// is true, every button enables itself, and the popup renders a confident, permanently-updating
// lie. The required properties only protect what actually flows through them.
//
// `plasmoidItem` is typed `var` and not `PlasmoidItem` on purpose: most of what this file needs
// (updating, actionMessage, setHold, ...) is declared in main.qml's QML body, not on the C++
// PlasmoidItem type, so a typed handle would be a promise the type system cannot keep.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami
import "logic.js" as Logic

PlasmaExtras.Representation {
    id: popup

    required property var plasmoidItem
    required property var vm

    // Whether whatever is hosting us has already drawn a heading of its own. The system tray has:
    // the popup it puts us in comes with a title bar carrying the plasmoid's name, a pin, and a
    // configure gear - so our own gear underneath it is the SECOND one on screen, opening the same
    // dialog. On a panel or the desktop nothing draws that heading and ours is the only way in.
    //
    // `Plasmoid.containmentDisplayHints & ContainmentDrawsPlasmoidHeading` is the shipped
    // convention for this question rather than a guess: it is the test libplasma's own
    // BasicPlasmoidHeading uses to hide itself in the tray, and the one org.kde.plasma.vault uses
    // to drop its footer button there.
    //
    // Named property rather than the expression written inline on the button, because this is the
    // only seam a test can reach. `containmentDisplayHints` is READ-ONLY on Plasma::Applet, and
    // outside plasmashell the attached `Plasmoid` object has no applet behind it at all - it
    // answers undefined, which is also why the default that falls out below is the safe one (no
    // host heading known, so keep our own gear). A probe can neither set the hint nor fake the
    // applet, but it can overwrite this; tests/qml/probe_popup.py drives it AND pins the
    // expression verbatim, so the drivable seam cannot drift from what the panel evaluates.
    //
    // TWO controls read this, and it must stay two: the gear and the refresh icon, because the
    // tray's own heading genuinely draws both. It must NOT grow past them. Vault gates its whole
    // footer this way and Kempt must not copy that - a host that draws its own heading would then
    // take Update Now away with it, and the footer is the one row Plasma's contract does not let
    // a containment replace.
    property bool traysHeading: (Plasmoid.containmentDisplayHints
                                 & PlasmaCore.Types.ContainmentDrawsPlasmoidHeading) !== 0

    // These are the representation-switch heuristic, not decoration: Plasma compares the space it
    // has against them to decide between the panel icon and this popup. Removing them is how a
    // widget ends up showing the popup inside a panel.
    Layout.minimumWidth: Kirigami.Units.gridUnit * 22
    Layout.minimumHeight: Kirigami.Units.gridUnit * 18
    Layout.preferredWidth: Kirigami.Units.gridUnit * 26
    Layout.preferredHeight: Kirigami.Units.gridUnit * 24

    collapseMarginsHint: true

    // --- the keyboard ------------------------------------------------------------------------------
    // All of this is about the popup as a WHOLE - which key reaches it, and what holds focus the
    // moment it appears - so it sits above the three rows rather than inside any one of them.

    // Escape ASKS to close. It does not close, and the difference is structural rather than
    // stylistic: `expanded` is AppletQuickItem's C++ property and its setter dereferences the
    // applet with no null check, so a file that assigned it here would be a file no test could
    // ever press Escape in - the probe would segfault before reporting anything (main.qml says
    // the same thing over its onExpandedChanged). So the popup states the intent and main.qml,
    // which owns that property, is the one file that carries it out.
    signal closeRequested()

    // Klipper's precedent. On the popup rather than on any one control because key events travel
    // from whatever holds focus UP the parent chain: one handler here catches Escape from the
    // buttons, the pins and the message actions alike, and no control has to remember to forward
    // it. Accepted, so a host that would also act on it does not get a second go.
    Keys.onEscapePressed: event => {
        popup.closeRequested();
        event.accepted = true;
    }

    // What the keyboard lands on when the popup opens: the thing the user came to press.
    //
    // Refresh is the fallback rather than a greyed-out Update Now because Update Now is HIDDEN
    // when there is nothing to run (see the footer for why), and forcing focus onto an invisible
    // item leaves the popup with no focus at all - at which point every key goes nowhere and the
    // Escape handler above stops working with them.
    //
    // Qt.TabFocusReason, and that argument is the difference between focus and VISIBLE focus: a
    // QQC2 control draws its focus ring on `visualFocus`, which is only true for the keyboard
    // reasons - Tab, Backtab, a shortcut. Given Qt.PopupFocusReason instead, the button really
    // would hold focus and nothing on screen would say so.

    // Both halves, and the second one is the half this used to get wrong. `visible` was tested and
    // `enabled` was not, so an open that coincided with a check in flight put the keyboard on a
    // Refresh button that was refusing to be pressed. A disabled QQC2 control does not accept
    // focus, so the forceActiveFocus was simply ignored and the popup opened with focus nowhere.
    function canTakeFocus(item) {
        return item.visible && item.enabled;
    }

    // In the order of what the person came to do: run the update, ask for fresh counts, open the
    // settings. The last resort is the popup itself, which is where Keys.onEscapePressed lives -
    // so even a popup whose every control is unusable can still be closed with a key.
    function focusPrimary() {
        if (canTakeFocus(updateButton)) updateButton.forceActiveFocus(Qt.TabFocusReason);
        else if (canTakeFocus(refreshButton)) refreshButton.forceActiveFocus(Qt.TabFocusReason);
        else if (canTakeFocus(configureButton)) configureButton.forceActiveFocus(Qt.TabFocusReason);
        else popup.forceActiveFocus(Qt.TabFocusReason);
    }

    // The open itself. main.qml owns `expanded` and therefore owns the announcement; what any
    // given surface does about it is that surface's business - the same split as closeRequested.
    //
    // Component.onCompleted covers the FIRST open and only that one: this item is built lazily,
    // as a consequence of the popup being expanded, so on that one occasion it is not yet around
    // to hear the announcement. Every open after it is the Connections.
    Connections {
        target: popup.plasmoidItem
        function onPopupShown() { popup.focusPrimary(); }
    }
    Component.onCompleted: if (popup.plasmoidItem.expanded) popup.focusPrimary()

    // --- the header ------------------------------------------------------------------------------
    // One row, and that is the whole change here: the count, the refresh icon, the gear. The stale
    // explanation, the risky warning and the last action's report all used to be stacked in this
    // toolbar; three of them were messages rather than controls, and they are InlineMessages in the
    // content area now (hig-review.md P2).
    header: PlasmaExtras.PlasmoidHeading {
        contentItem: RowLayout {
            spacing: Kirigami.Units.smallSpacing

            PlasmaExtras.Heading {
                // fillWidth is what pushes the two buttons to the trailing edge, so it does the job
                // Bluetooth's `Item { Layout.fillWidth: true }` spacer does in a row whose leading
                // control has no width of its own.
                Layout.fillWidth: true
                level: 4
                // Deliberately NOT the badge text: the badge caps at 999+ because a panel has
                // no room, and this has plenty. Someone who opened the popup wants the number.
                text: popup.vm.headerText
                elide: Text.ElideRight
            }

            // Refresh, in Bluetooth's Header.qml shape (hig-review.md 2.2) - and hidden in the
            // tray for the same reason Bluetooth hides its own, which took a real panel to see.
            // The note here used to say the opposite: that Kempt could keep the button because the
            // tray only offers the action buried in a More-actions menu, and a refresh costing two
            // clicks and a menu is not worth having. That premise is wrong. Plasma 6.7 renders a
            // SINGLE contextual action as an ICON in the heading it draws, beside the pin and the
            // gear, so registering checkAction (main.qml) puts a view-refresh icon on screen at
            // one click - and ours underneath it was the second one.
            PlasmaComponents.ToolButton {
                id: refreshButton
                // Both halves, never the hint alone. claimContextualActions() is a try with a
                // witness precisely because it can fail, and a tray heading with no action
                // registered draws no refresh icon at all - gating on the hint by itself would
                // leave the popup with no way to re-check on the one host where the claim did not
                // take. Off the tray nobody draws anything and this button is the only refresh
                // there is, which is why the default that falls out of an undefined hint is to
                // show it.
                visible: !(popup.traysHeading
                           && popup.plasmoidItem.contextualActionsClaimed)
                // DISABLED while a check or a run is in flight, and still on screen. The spinner
                // used to take this button's place instead, on the argument that one spinner
                // belongs on the control the user pressed - which is right about the spinner and
                // wrong about the button. A control that leaves the screen takes the keyboard with
                // it: QQC2 delivers Space to whatever holds activeFocus whether it is drawn or
                // not, so the keyboard sat on a Refresh nobody could see, and Space there queued
                // another check behind the one already running. Worse, the popup's own open walks
                // into it - popupOpened() starts the refresh-on-open check before it announces
                // popupShown(), so focusPrimary ran at the one moment this control was gone.
                //
                // Refusing in place says the same thing to the eye AND to the keyboard: the
                // button is there, it is greyed, the spinner beside it says why. This is the one
                // control in the popup where "disabled" is the honest state - unlike Update Now,
                // whose absence means there is genuinely nothing to run.
                enabled: !popup.plasmoidItem.checking && !popup.plasmoidItem.updating
                icon.name: "view-refresh"
                display: PlasmaComponents.AbstractButton.IconOnly
                text: i18n("Check for Updates")
                // The tooltip is for whoever hovers; this is for whoever cannot (hig-review P8).
                Accessible.description: i18n("Check for Updates")
                PlasmaComponents.ToolTip.text: text
                PlasmaComponents.ToolTip.visible: hovered
                PlasmaComponents.ToolTip.delay: Kirigami.Units.toolTipDelay
                // The same belt Update Now wears: a control that is refusing must not act, however
                // the press reached it.
                onClicked: if (enabled) popup.plasmoidItem.doCheck()
            }

            // The spinner, BESIDE Refresh rather than over it. Wrapped in an Item that keeps the
            // cell's width whether it is running or not, so the header does not jump sideways the
            // moment a check starts.
            //
            // A SIBLING and not the button's child, which matters twice over now: in the tray the
            // button is hidden and this becomes the only thing on screen saying a check is running
            // (the heading's icon belongs to the host and does not spin), so a spinner parented to
            // the button would disappear with it and a tray check would run with no sign at all.
            Item {
                implicitWidth: refreshBusy.implicitWidth
                implicitHeight: refreshBusy.implicitHeight
                Layout.preferredWidth: implicitWidth
                Layout.preferredHeight: implicitHeight

                PlasmaComponents.BusyIndicator {
                    id: refreshBusy
                    anchors.centerIn: parent
                    running: popup.plasmoidItem.checking || popup.plasmoidItem.updating
                    visible: running
                    implicitWidth: Kirigami.Units.iconSizes.small
                    implicitHeight: Kirigami.Units.iconSizes.small
                }
            }

            PlasmaComponents.ToolButton {
                id: configureButton
                // Ours only when nobody else is offering one - see popup.traysHeading.
                visible: !popup.traysHeading
                icon.name: "configure"
                display: PlasmaComponents.AbstractButton.IconOnly
                // A real ellipsis, because this opens a dialog. Three ASCII dots are the one
                // typographic tell that a widget was not written by KDE (hig-review.md P5).
                text: i18n("Configure Kempt…")
                // Icon-only, so `text` is never drawn and this is the only place the button says
                // what it is. Bound rather than spelled out again: one sentence, one literal for
                // a translator to find.
                Accessible.description: text
                PlasmaComponents.ToolTip.text: text
                PlasmaComponents.ToolTip.visible: hovered
                PlasmaComponents.ToolTip.delay: Kirigami.Units.toolTipDelay
                onClicked: {
                    // The action is registered by the shell, and a plasmoid can be built in
                    // contexts where it is not there yet. Calling trigger() on null takes the
                    // whole binding down with it.
                    const a = Plasmoid.internalAction("configure");
                    if (a) a.trigger();
                }
            }
        }
    }

    // --- the content -----------------------------------------------------------------------------
    // A ColumnLayout rather than the anchored siblings this used to be, because the message stack
    // has to PUSH the list down rather than float over it. PlasmaExtras.Representation is a Page
    // whose default property is contentData, so this is reparented into the content area and the
    // footer below can never overlap it.
    ColumnLayout {
        anchors.fill: parent
        spacing: Kirigami.Units.smallSpacing
        // A run of ours replaces this whole pane with the log tail below.
        visible: !popup.plasmoidItem.updating

        // --- the message stack -------------------------------------------------------------------
        // Kirigami.InlineMessage each, with their own `actions:` list rather than a hand-rolled
        // RowLayout, so they wrap correctly at popup width and get consistent iconography. Shipped
        // precedent inside a plasmoid: org.kde.desktopcontainment's FolderView.qml.

        // No engine on the box, which is the ORDINARY first run of a KDE Store install: the store
        // carries this plasmoid and nothing else, and every piece of the work is the CLI's. FIRST
        // in the stack because it is the only message that says the widget cannot do anything at
        // all yet; everything under it presumes an engine that answered.
        //
        // Information and not Error, and that is the whole decision: nothing is broken, a step has
        // not been taken. The panel agrees - the icon stays dim rather than raising a warning
        // emblem (logic.js, iconState) - and the two must not say different things about the same
        // machine.
        //
        // No action button. Kempt installs nothing on anyone's behalf, and there is no command to
        // offer that would not need the engine that is missing, so the commands are in the body
        // where they can be read and copied. The rest of the popup needs no new gate to stay out
        // of the way: Update Now is bound to vm.actionable, the list to vm.rows and the
        // placeholder to vm.emptyStateText, and with no state all three are already empty. Refresh
        // deliberately stays: it is how somebody who has just installed the package gets an answer
        // without waiting out the hourly timer.
        Kirigami.InlineMessage {
            id: engineMissingMessage
            Layout.fillWidth: true
            type: Kirigami.MessageType.Information
            text: popup.vm.engineMissingMessage
            Accessible.name: text
            visible: popup.vm.engineMissingMessage.length > 0
        }

        // The restart. Shown in EVERY state, including up to date: you can owe a restart and have
        // twelve updates pending at once, and you can owe one with nothing pending at all
        // (hig-review.md 1c). Bound to vm.restartMessageVisible, which has already folded in the
        // `restart_reminder` setting and this session's dismissal - binding it to either half
        // separately would be a second copy of that rule.
        Kirigami.InlineMessage {
            id: restartMessage
            Layout.fillWidth: true
            type: Kirigami.MessageType.Warning
            showCloseButton: true
            // Kirigami gives every InlineMessage the AlertMessage role and no NAME, so a screen
            // reader announcing this alert reads out its icon - "Warning" - and nothing about
            // what happened. The words are already right here; this is what makes them the
            // alert's own. Every message in this stack carries it, the two that only ever report
            // a failure included: a message nobody can hear is a message that is not being shown.
            Accessible.name: text
            // Both reasons this can be hidden are written into this one expression, and the handler
            // below re-evaluates the SAME expression. See there for why that matters.
            visible: popup.vm.restartMessageVisible && !popup.plasmoidItem.updating
            // A prompt that could not be opened says so HERE, where the user pressed. Silence is
            // the worst outcome available: a button that appears to do nothing is indistinguishable
            // from one that did something invisible.
            text: popup.plasmoidItem.restartError.length > 0
                  ? i18n("Restart to apply installed updates") + "\n" + popup.plasmoidItem.restartError
                  : i18n("Restart to apply installed updates")
            actions: [
                Kirigami.Action {
                    // A real ellipsis: this opens KDE's own confirmation screen, and Kempt never
                    // restarts anything itself.
                    text: i18n("Restart…")
                    icon.name: "system-reboot"
                    onTriggered: source => popup.plasmoidItem.promptRestart()
                }
            ]

            // Kirigami's close button does exactly one thing:
            //     onClicked: root.visible = false
            // (/usr/lib64/qt6/qml/org/kde/kirigami/templates/InlineMessage.qml, line 448). That is
            // an ASSIGNMENT, and assigning to a property destroys the binding on it for good - so
            // without this the message would not merely close, it would never come back when the
            // machine's answer changed. This turns that assignment into the call it was meant to
            // be and puts the binding back.
            //
            // The guard re-evaluates the whole visibility expression rather than reading a cached
            // flag, and THAT is the load-bearing part: this handler also fires when an ancestor
            // hides, which happens every time a run starts. A guard that only asked "does the view
            // model still want this?" would read a run beginning as the user closing the message,
            // and an update would quietly switch the reminder off for the rest of the session.
            onVisibleChanged: {
                if (visible) return;
                if (!(popup.vm.restartMessageVisible && !popup.plasmoidItem.updating)) return;
                popup.plasmoidItem.dismissRestart();
                visible = Qt.binding(function () {
                    return popup.vm.restartMessageVisible && !popup.plasmoidItem.updating;
                });
            }
        }

        // What the next restart will install. Positive rather than Warning, and that is the whole
        // point of it being here: nothing is wrong, nothing needs pressing, and the work the person
        // asked for is done and waiting. Before this, a staged transaction looked exactly like an
        // un-staged one - the offline offer below was still on screen - and pressing it again was
        // the obvious thing to do.
        //
        // vm.stagedMessage is empty unless the CLI has reconciled its marker against dnf5's own
        // transaction status and found one that is genuinely ARMED, so this message is never shown
        // over a stage that no restart would install.
        Kirigami.InlineMessage {
            id: stagedMessage
            Layout.fillWidth: true
            type: Kirigami.MessageType.Positive
            text: popup.vm.stagedMessage
            Accessible.name: text
            visible: popup.vm.stagedMessage.length > 0
            actions: [
                Kirigami.Action {
                    // The same action the restart Warning offers, and never at the same time as it:
                    // vm.stagedShowRestart is false while that message is on screen. Two buttons
                    // for one outcome in one small window is how a person ends up pressing both.
                    // enabled/visible together, the pattern the Show Log action above already uses.
                    text: i18n("Restart…")
                    icon.name: "system-reboot"
                    enabled: popup.vm.stagedShowRestart
                    visible: enabled
                    onTriggered: source => popup.plasmoidItem.promptRestart()
                }
            ]
        }

        // The offline recommendation. The CLI has already decided this transaction touches
        // session-critical packages; the widget's job is to make acting on it one click.
        //
        // vm.riskyMessage and NOT vm.riskySummary, and only ever one of them: with no kernel in the
        // set riskyMessageOf falls back to the very sentence riskySummary holds, so rendering both
        // would print the same words twice inside one message.
        Kirigami.InlineMessage {
            id: riskyMessage
            Layout.fillWidth: true
            type: Kirigami.MessageType.Warning
            text: popup.vm.riskyMessage
            Accessible.name: text
            visible: popup.vm.riskyMessage.length > 0
            actions: [
                Kirigami.Action {
                    // Named for what it does to the user rather than for the dnf5 flag behind it.
                    text: i18n("Install on Next Restart")
                    icon.name: "system-reboot"
                    tooltip: i18n("Applies the update during a restart, so nothing changes underneath your running desktop.")
                    onTriggered: source => popup.plasmoidItem.stageOffline()
                }
            ]
        }

        // Stale: what went wrong, and how old the numbers below it therefore are. Information and
        // not Warning, deliberately - the counts under it are still the best known truth, and this
        // is an explanation rather than an alarm.
        Kirigami.InlineMessage {
            id: staleMessage
            Layout.fillWidth: true
            type: Kirigami.MessageType.Information
            visible: popup.vm.stale && popup.vm.staleReason.length > 0
            Accessible.name: text
            text: i18n("%1 (last successful check: %2)", popup.vm.staleReason, popup.vm.lastSuccessText)
        }

        // What the run that just finished did, once. main.qml clears this when the popup closes or
        // the next check starts, and while it is on screen the persistent Last update row below
        // stays away: one event, one line at a time.
        Kirigami.InlineMessage {
            id: postRunMessage
            Layout.fillWidth: true
            // A failed run is an error whatever its counts say. The counts come from the same
            // entry, so the two can never disagree about which run this was.
            type: (popup.plasmoidItem.lastRun && popup.plasmoidItem.lastRun.failed)
                  ? Kirigami.MessageType.Error : Kirigami.MessageType.Positive
            text: popup.plasmoidItem.postRunLine
            visible: popup.plasmoidItem.postRunLine.length > 0
            Accessible.name: text
            actions: [
                Kirigami.Action {
                    text: i18n("Show Log")
                    icon.name: "text-x-generic"
                    // A history entry old enough - or damaged enough - to have no log is an
                    // ordinary event, and an action that cannot do anything should not be offered.
                    enabled: !!popup.plasmoidItem.lastRun
                             && popup.plasmoidItem.lastRun.logPath.length > 0
                    visible: enabled
                    onTriggered: source => popup.plasmoidItem.showLog(popup.plasmoidItem.lastRun.logPath)
                }
            ]
        }

        // All that is left of the old label under the buttons: a button press that failed and has
        // something to say. main.qml clears it on the next press.
        Kirigami.InlineMessage {
            id: actionFailureMessage
            Layout.fillWidth: true
            type: Kirigami.MessageType.Error
            text: popup.plasmoidItem.actionMessage
            Accessible.name: text
            visible: popup.plasmoidItem.actionMessage.length > 0
        }

        // --- the list, and what stands in for it when there is none --------------------------------
        // One Item holding both, so the placeholder is centred in the space the list would have
        // occupied rather than in the whole popup.
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // One flat model with header rows in it, built by logic.js. A ListView creates
            // delegates lazily, so a box with 1200 pending updates costs what a box with six costs.
            PlasmaComponents.ScrollView {
                anchors.fill: parent
                visible: popup.vm.rows.length > 0

                ListView {
                    id: rowsView
                    model: popup.vm.rows
                    clip: true
                    // Recycling delegates is the one thing this list must NOT do, and the reason
                    // is the keyboard rather than the frame rate. Qt walks the focus chain in the
                    // order the delegates are children of the view, and a recycled delegate keeps
                    // the place it was created in - so once the pool starts handing rows back, the
                    // row after the one holding focus is no longer the next child. Measured on an
                    // 80-package list, 2026-08-27: with reuseItems, Tab threw the user out of the
                    // list and back through the header twice on the way down. Every row was still
                    // reachable, and it was still wrong. These delegates are two labels and a
                    // button, so building them the ordinary way costs nothing worth having.
                    reuseItems: false

                    delegate: Loader {
                        width: rowsView.width
                        required property var modelData
                        // Only the scroll-into-view below needs this; a Loader gets `index` from
                        // the view the same way it gets `modelData`, and required is how this
                        // file asks for either.
                        required property int index
                        sourceComponent: modelData.kind === "header" ? headerComponent : itemComponent

                        Component {
                            id: headerComponent
                            // Plasma's own section header rather than a bare Heading: it brings the
                            // theme's SVG separator, it is what makes this read as a Plasma list,
                            // and its trailing slot is where a per-section action would go later.
                            PlasmaExtras.ListSectionHeader { label: modelData.title }
                        }

                        Component {
                            id: itemComponent
                            UpdateItemDelegate {
                                width: rowsView.width
                                name: modelData.name
                                from: modelData.from
                                to: modelData.to
                                held: modelData.held
                                backend: modelData.backend
                                busy: popup.plasmoidItem.holdInFlight
                                onToggleHold: (backend, name, hold) => popup.plasmoidItem.setHold(backend, name, hold)
                                // Keyboard focus has arrived in this row. Contain scrolls the
                                // least amount that makes the row whole, so a row already on
                                // screen does not move under a mouse user who just clicked it.
                                // See UpdateItemDelegate for what goes wrong without this.
                                onPinFocused: rowsView.positionViewAtIndex(index, ListView.Contain)
                            }
                        }
                    }
                }
            }

            // Up to date, no data yet, or a CLI we could not run. The third one is the only one
            // that owes the user an instruction, and it gets the CLI's own words plus the command
            // that diagnoses it. Note what it is NOT shown for: a box whose only pending updates
            // are held has rows, so the Held group carries the truth instead and "everything is up
            // to date" is never said over the top of it.
            PlasmaExtras.PlaceholderMessage {
                id: placeholder
                anchors.centerIn: parent
                width: parent.width - Kirigami.Units.gridUnit * 4
                visible: popup.vm.rows.length === 0 && text.length > 0
                iconName: popup.vm.iconState === "error" ? "dialog-error"
                          : (popup.vm.iconState === "unknown" ? "view-refresh" : "update-none")
                text: popup.vm.emptyStateText
                explanation: popup.vm.remedyCommand.length > 0
                             ? i18n("Run `%1` in a terminal to find out why.", popup.vm.remedyCommand)
                             : ""
            }
        }

        // --- what the last run did -------------------------------------------------------------
        // PlasmaExtras.ExpandableListItem is hard-coupled to being a ListView delegate: it reads
        // `ListView.view.highlightResizeDuration` in a BINDING, reaches for
        // `ListView.view.currentIndex` in half its handlers, and its own width comment says
        // "Assume that we will be used as a delegate, not placed in a layout". Standing it in this
        // ColumnLayout throws on the first frame. So it gets a ListView of its own, one item long -
        // which also leaves the main list's `rows.length === 0` empty-state guard undisturbed, and
        // that matters: the up-to-date state has to show the placeholder AND this row at once.
        ListView {
            id: lastRunView
            Layout.fillWidth: true
            Layout.preferredHeight: contentHeight
            // ...but never more than half the popup. An ordinary weekly Fedora update installs
            // fifty to two hundred packages, and this row expands to ALL of them: without a
            // ceiling, one click on the expander would hand the whole popup to a history entry and
            // squeeze the pending list, which is what the popup is for, down to nothing.
            Layout.maximumHeight: Math.round(popup.height / 2)
            clip: true
            // Which makes the row's own view scrollable exactly when it overflows and inert when
            // it does not, so a one-line row never eats a wheel event meant for the list above it.
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            // One event, one line at a time: while the transient post-run message is up there, this
            // is the same fact told twice.
            visible: popup.plasmoidItem.lastRun !== null && popup.plasmoidItem.postRunLine.length === 0
            model: 1

            delegate: PlasmaExtras.ExpandableListItem {
                // Stated rather than injected. The component declares `index` as a property of its
                // own, which shadows the one a view hands its delegates, and its click handling
                // writes that value into the view's currentIndex. One item, so it is 0.
                index: 0
                icon: "documentinfo"
                title: Logic.lastRunText(popup.plasmoidItem.lastRun, popup.plasmoidItem.nowMs)
                // Only a failure earns a second line here, and it is logic.js's own sentence about
                // that run rather than a new one written in QML. Deliberately NOT the entry's
                // reboot_needed: that is a fact about the moment the run ended, and the state
                // file's live answer is what the restart message above is bound to. Repeating the
                // history entry here would go on claiming a restart after the user had done it.
                subtitle: (popup.plasmoidItem.lastRun && popup.plasmoidItem.lastRun.failed)
                          ? Logic.postRunLine(popup.plasmoidItem.lastRun) : ""
                subtitleCanWrap: true
                customExpandedViewContent: lastRunPackages
                contextualActions: [
                    Kirigami.Action {
                        text: i18n("Show Log")
                        icon.name: "text-x-generic"
                        enabled: !!popup.plasmoidItem.lastRun
                                 && popup.plasmoidItem.lastRun.logPath.length > 0
                        onTriggered: source => popup.plasmoidItem.showLog(popup.plasmoidItem.lastRun.logPath)
                    }
                ]
            }

            // The run's own package list, exactly as the CLI recorded it. Not a second reading of
            // the pending list: these are the versions that were actually installed.
            Component {
                id: lastRunPackages
                ColumnLayout {
                    spacing: 0
                    Repeater {
                        model: popup.plasmoidItem.lastRun ? popup.plasmoidItem.lastRun.items : []
                        delegate: RowLayout {
                            id: historyRow
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            PlasmaComponents.Label {
                                Layout.fillWidth: true
                                text: historyRow.modelData.name
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                            }
                            PlasmaComponents.Label {
                                text: historyRow.modelData.from + " → " + historyRow.modelData.to
                                opacity: 0.7
                                font: Kirigami.Theme.smallFont
                            }
                        }
                    }
                }
            }
        }
    }

    // --- the footer ------------------------------------------------------------------------------
    // PlasmoidHeading again: it branches internally on `position === T.ToolBar.Footer` for its
    // margins and its SVG prefix, so the same component is both header and footer, and a Page
    // assigns that position itself.
    //
    // NOT gated on the containment hint, and this is the whole argument for the row existing.
    // org.kde.plasma.vault gates its footer that way, and copying it would put the primary action
    // back on the one piece of ground Plasma reserves for itself: every shipped applet treats
    // heading contents as expendable because the contract says the host may replace them
    // (hig-review.md 3). Update Now must exist on every host, in every containment. A footer also
    // keeps it in reach while a 1200-row list scrolls.
    footer: PlasmaExtras.PlasmoidHeading {
        contentItem: RowLayout {
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents.Label {
                id: footerLabel
                Layout.fillWidth: true
                text: popup.vm.footerText
                elide: Text.ElideRight
                font: Kirigami.Theme.smallFont
                opacity: 0.8

                // The relative time in the line is the convenience; the absolute stamp is the
                // truth, and people compare the two (hig-review.md P6). A HoverHandler rather than
                // a control's `hovered`, because a Label is not a control.
                HoverHandler { id: footerHover }
                PlasmaComponents.ToolTip {
                    id: footerToolTip
                    text: popup.vm.footerTooltip
                    // Empty until a check has ever succeeded, and an empty tooltip is worse than
                    // none: it flickers a bare frame under the pointer.
                    visible: footerHover.hovered && text.length > 0
                    delay: Kirigami.Units.toolTipDelay
                }
            }

            PlasmaComponents.Button {
                id: updateButton
                text: i18n("Update Now")
                icon.name: "system-software-update"
                // A raised Button and not a ToolButton: this is the primary action and it is not in
                // a toolbar any more.
                //
                // HIDDEN and not disabled when there is nothing to do. A greyed-out primary button
                // over "Everything is up to date" was the founder's original complaint about this
                // popup, and it is the correct call: an up-to-date box has no run to start, so
                // there is no action to offer rather than an action being refused.
                visible: popup.vm.actionable > 0 && !popup.plasmoidItem.updating

                // ...which means this control can go off screen while the popup is open and the
                // keyboard is standing on it. `actionable` reaches 0 on its own - the 30s watcher,
                // the hourly timer, or a `kempt update` finishing in a terminal - and nothing
                // calls focusPrimary() again, because the popup did not open, it just changed.
                //
                // QQC2 delivers Space and Return to whatever holds activeFocus whether it is
                // drawn or not, so what was left was an invisible button that started `kempt run`
                // on a box with nothing to update. The keyboard therefore leaves with the button,
                // by the same rule that put it here: focusPrimary picks the best control that is
                // actually usable, which with nothing pending is Refresh.
                onVisibleChanged: if (!visible && activeFocus) popup.focusPrimary()

                // The belt to that braces. A control that is invisible and still operable is a
                // trap however the keyboard reached it, and the focus move above is not the only
                // route in - a screen reader, a shortcut, or a future edit can all put focus back.
                onClicked: if (visible) popup.plasmoidItem.startUpdate()
            }
        }
    }

    // --- the updating state ----------------------------------------------------------------------
    // Only reached for a run WE started. The log pane appears only on the in-popup surface, since
    // that is the surface whose whole point is that the output comes here.
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        visible: popup.plasmoidItem.updating
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents.Label {
            Layout.fillWidth: true
            text: popup.plasmoidItem.effectiveSurface === "popup" ? i18n("Updating…") : i18n("Updating in the %1 surface…", popup.plasmoidItem.effectiveSurface)
            wrapMode: Text.WordWrap
        }

        // A tail, so it stays at the tail. The text is replaced wholesale every two seconds, and
        // any view that keeps its own scroll position across that jumps back to the first line
        // each time - which is precisely useless for watching an update run. So: a plain
        // Flickable, re-pinned to the bottom whenever the content grows.
        // `stickToBottom` is what keeps it from fighting the user: scroll up to read something and
        // it stops following, scroll back down and it resumes.
        Flickable {
            id: logFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: popup.plasmoidItem.effectiveSurface === "popup"
            clip: true
            contentWidth: logText.paintedWidth
            contentHeight: logText.paintedHeight
            boundsBehavior: Flickable.StopAtBounds

            property bool stickToBottom: true
            function pin() {
                if (stickToBottom) contentY = Math.max(0, contentHeight - height);
            }
            onContentHeightChanged: pin()
            onHeightChanged: pin()
            onMovementEnded: stickToBottom = (contentY >= contentHeight - height - Kirigami.Units.gridUnit)

            PlasmaComponents.ScrollBar.vertical: PlasmaComponents.ScrollBar {}

            Text {
                id: logText
                text: popup.plasmoidItem.logTail
                color: Kirigami.Theme.textColor
                // The theme's own fixed-width font, not a hardcoded "monospace": dnf output is
                // column-aligned and the user's chosen mono font is the one that will render it.
                font: Kirigami.Theme.fixedWidthFont
                wrapMode: Text.NoWrap
            }
        }

        Item {
            Layout.fillHeight: true
            visible: popup.plasmoidItem.effectiveSurface !== "popup"
        }
    }
}
