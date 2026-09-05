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
    // buttons, the padlocks and the message actions alike, and no control has to remember to
    // forward
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

    // --- what the popup says out loud ---------------------------------------------------------
    // ONE function, and every announcement in this file goes through it. Two reasons, and the
    // second is the one that made it a function rather than five call sites:
    //   * `Accessible.announce` reaches an accessibility bridge and nothing else, so there is no
    //     way for a test to hear it. `announced` is emitted alongside, and the probes spy on that.
    //   * politeness is a decision, not a parameter to be re-argued at each call. Assertive is for
    //     something that happened TO the person (a banner that flipped, a run that failed); polite
    //     is for the outcome of something they just did.
    // Qt 6.11 has the method and both politeness values (measured on this box, 2026-09-05); an
    // older Qt would not, so the call is guarded rather than assumed.
    signal announced(string sentence)

    function announce(sentence, assertive) {
        const said = String(sentence === undefined || sentence === null ? "" : sentence);
        if (said.length === 0) return;
        popup.announced(said);
        if (typeof popup.Accessible.announce !== "function") return;
        popup.Accessible.announce(said, assertive ? Accessible.AnnouncementPoliteness.Assertive
                                                  : Accessible.AnnouncementPoliteness.Polite);
    }

    // --- how many messages may be on screen -----------------------------------------------------
    // Two, and WHICH two is logic.js's rule rather than four visibility bindings: a binding can
    // say "am I true", and only something that sees all four can say "am I one of the two that
    // fit". Measured before this: five messages left the list 95 px tall at the default popup
    // size, and at Layout.minimumHeight the messages alone overflowed - they are outside the
    // ScrollView, so nothing scrolled and the list was gone entirely (hostile panel, M2).
    readonly property var messageSlots: popup.vm.messageSlots

    function shows(slot) {
        return popup.messageSlots.indexOf(slot) >= 0;
    }

    // A message whose words changed under the reader. Kirigami gives every InlineMessage the
    // AlertMessage role and no name, and a name change on an UNFOCUSED object is not spoken - it
    // is readable in flat review and nothing else. So the banner that flips from "61 updates are
    // staged" to "you held kf6-kio after this was prepared" changed its colour, its type and its
    // buttons, silently, for the person who most needed to hear it.
    //
    // `spoken` is what stops one change being announced twice: `text` and `visible` are two
    // bindings onto the same view-model change and both handlers fire. It is cleared when the
    // message goes away, so a banner that comes back says itself again.
    function speakMessage(item, assertive) {
        if (!item.visible) { item.spoken = ""; return; }
        if (item.text === item.spoken) return;
        item.spoken = item.text;
        popup.announce(item.text, assertive);
    }

    // --- the hold round trip, on this side ------------------------------------------------------
    // main.qml runs the hold and the check that follows it; what arrives here is the moment the
    // model has been replaced and the row has moved. Three things have to happen then, and none of
    // them used to: the keyboard follows the package, the viewport stays where the person left it,
    // and somebody says what happened.

    // The package whose padlock should take the keyboard as soon as its row exists again. Cleared
    // by
    // whoever claims it, so a rebuild that happens for some other reason cannot inherit it.
    property string refocusName: ""
    // How the press arrived. The two owe opposite things: a keyboard press must take the person to
    // the row wherever it has gone, and a pointer press must not move the list under the pointer.
    property bool refocusFromKeyboard: false
    // Where the list was standing when the padlock was pressed. The model is replaced wholesale,
    // and a
    // ListView handed a new model starts at 0 - measured at contentY 884 to 0 on the 24-package
    // fixture and 1685 to 0 on an 80-row list.
    property real savedContentY: 0

    function claimRefocus(name) {
        if (popup.refocusName === "" || name !== popup.refocusName) return false;
        popup.refocusName = "";
        return true;
    }

    function rowIndexOf(name) {
        for (let i = 0; i < popup.vm.rows.length; i++) {
            if (popup.vm.rows[i].kind === "item" && popup.vm.rows[i].name === name) return i;
        }
        return -1;
    }

    // Run one turn of the event loop after the model changed, so the ListView has had its layout.
    // Doing the work here rather than only in the delegate's Component.onCompleted is what makes
    // it work on a real list: a held row lands at the BOTTOM, under "Held", and a ListView only
    // builds the delegates near its viewport - so on an ordinary 80-package update the delegate
    // the refocus is waiting for does not exist until something scrolls to it.
    function settleAfterHold() {
        if (popup.refocusName !== "") {
            const idx = popup.rowIndexOf(popup.refocusName);
            if (idx < 0) popup.refocusName = "";
            else {
                // Contain, so a row already on screen does not move. This also BUILDS the
                // delegate, which is what the two lines after it need.
                rowsView.positionViewAtIndex(idx, ListView.Contain);
                const loader = rowsView.itemAtIndex(idx);
                if (loader && loader.item && popup.claimRefocus(popup.refocusName)) {
                    loader.item.focusPin();
                }
            }
        }
        // ...and last, because focusing a padlock scrolls its row into view (see the delegate's
        // pinFocused): a pointer press gets its viewport back, whatever the focus move just did.
        // Unconditional, so it still runs when a delegate claimed the refocus for itself above.
        if (!popup.refocusFromKeyboard) {
            rowsView.contentY = popup.savedContentY;
            rowsView.returnToBounds();
        }
    }

    Connections {
        target: popup.plasmoidItem
        function onHoldOutcome(name, hold, ok, message) {
            if (!ok) {
                // Assertive: the row now carries an error the person has to act on, and the
                // padlock
                // under their hand is live again.
                popup.announce(message, true);
                return;
            }
            // Polite: they asked for this, and it worked. An assertive announcement here would
            // interrupt whatever the reader was in the middle of, to confirm their own press.
            const sentence = hold ? i18n("Holding %1", name)
                                  : i18n("No longer holding %1", name);
            popup.announce(sentence, false);
            Qt.callLater(popup.settleAfterHold);
        }
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
                Accessible.name: text
                // The tooltip is for whoever hovers; this is for whoever cannot (hig-review P8) -
                // and it says what pressing this DOES rather than repeating the label, which is
                // what QQC2 already hands over as the name.
                //
                // ...and it carries the CLI's own reason when the last check failed. That reason
                // used to be a whole InlineMessage; it belongs on the button that tries again, and
                // the footer beside it says that a check failed at all.
                Accessible.description: popup.vm.stale && popup.vm.staleReason.length > 0
                    ? i18n("Asks dnf and flatpak what is pending now, instead of waiting for the timer.")
                      + "\n" + popup.vm.staleReason
                    : i18n("Asks dnf and flatpak what is pending now, instead of waiting for the timer.")
                PlasmaComponents.ToolTip.text: popup.vm.stale && popup.vm.staleReason.length > 0
                                               ? text + "\n" + popup.vm.staleReason : text
                PlasmaComponents.ToolTip.visible: hovered || visualFocus
                PlasmaComponents.ToolTip.delay: Kirigami.Units.toolTipDelay
                // Enter, which sent nothing at all before: QQC2 activates on Space only. The
                // shipped Plasma pattern is per button, not one handler on the popup.
                Keys.onReturnPressed: animateClick()
                Keys.onEnterPressed: animateClick()
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
                    // ...including the window between pressing Update Now and `kempt run` coming
                    // back, when nothing else on screen says anything is happening yet.
                    running: popup.plasmoidItem.checking || popup.plasmoidItem.updating
                             || popup.plasmoidItem.runRequested
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
                // what it is. Spelled out rather than left to QQC2: a probe measured an empty name
                // on every button here when accessibility was active before construction.
                Accessible.name: text
                // ...and what is behind it, which the label cannot say.
                Accessible.description: i18n("Check interval, where updates run, restart reminders, and the packages you hold.")
                PlasmaComponents.ToolTip.text: text
                PlasmaComponents.ToolTip.visible: hovered || visualFocus
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
        // One action, and it RUNS nothing: Copy Commands puts the two dnf lines on the
        // clipboard. Kempt installs nothing on anyone's behalf, and there is no command to offer
        // that would not need the engine that is missing - but an InlineMessage's text cannot be
        // selected, so without this button the commands have to be retyped, and a retyped command
        // line fails somewhere the reader then has to debug. The clipboard payload is
        // vm.engineMissingCopyText, the chained one-line form, NOT the message's own sentence:
        // pasting a sentence into a shell is its own failure. The rest of the popup needs no new
        // gate to stay out of the way: Update Now is bound to vm.actionable, the list to vm.rows
        // and the placeholder to vm.emptyStateText, and with no state all three are already
        // empty. Refresh deliberately stays: it is how somebody who has just installed the
        // package gets an answer without waiting out the hourly timer.
        Kirigami.InlineMessage {
            id: engineMissingMessage
            Layout.fillWidth: true
            type: Kirigami.MessageType.Information
            text: popup.vm.engineMissingMessage
            Accessible.name: text
            visible: popup.shows("engineMissing")
            actions: [
                Kirigami.Action {
                    text: i18n("Copy Commands")
                    icon.name: "edit-copy"
                    onTriggered: source => {
                        engineCopyClip.text = popup.vm.engineMissingCopyText;
                        engineCopyClip.selectAll();
                        engineCopyClip.copy();
                    }
                }
            ]
            // The clipboard, reached the only way pure QML can: an invisible TextEdit whose
            // copy() is QClipboard underneath. Zero-size and non-visible so it can never take
            // focus or paint; it holds text only for the instant between the click and the copy.
            TextEdit {
                id: engineCopyClip
                visible: false
                width: 0; height: 0
            }
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
            // Every reason this can be hidden is behind this one call, and the handler below
            // re-evaluates the SAME call. See there for why that matters. The third reason is new:
            // the stack fits two, and the restart is the cheapest of the four to displace because
            // the footer says "restart pending" whenever this message is not on screen.
            visible: popup.shows("restart")
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
                    // ...and it goes away while the staged banner is a warning. In that state a
                    // restart applies the staged transaction the warning is about, so this button
                    // offers the very install the person tried to stop - forty pixels above the
                    // sentence saying so. logic.js decides it; nothing here re-derives it.
                    enabled: popup.vm.restartShowAction
                    visible: enabled
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
                if (!popup.shows("restart")) return;
                popup.plasmoidItem.dismissRestart();
                visible = Qt.binding(function () { return popup.shows("restart"); });
            }
        }

        // What the next restart will install. Usually Positive, and that is the whole point of it
        // being here: nothing is wrong, nothing needs pressing, and the work the person asked for
        // is done and waiting. Before this, a staged transaction looked exactly like an un-staged
        // one - the offline offer below was still on screen - and pressing it again was the
        // obvious thing to do.
        //
        // vm.stagedMessage is empty unless the CLI has reconciled its marker against dnf5's own
        // transaction status and found one that is genuinely ARMED, so this message is never shown
        // over a stage that no restart would install.
        //
        // ...and it FLIPS. Once a hold lands on a package the stored transaction contains, the
        // reassurance above is false - dnf5 built that transaction before the hold existed and
        // offers no way to edit a stored one, so the restart installs the package anyway. A second
        // line under a green checkmark would have been the contradiction one level down, with the
        // button still on the reassuring half; so the whole message changes type, drops the
        // restart, and offers the one action that changes the outcome. logic.js decides which
        // banner this is (stagedVariantOf); nothing here re-derives it.
        Kirigami.InlineMessage {
            id: stagedMessage
            Layout.fillWidth: true
            // Bound, never declared. A literal Positive here is the bug this whole message exists
            // to remove, and it is one careless edit away - so the type comes from the view model
            // the same way the text does, and tests/test_widget_logic.sh guards the binding.
            type: popup.vm.stagedType === "warning"
                  ? Kirigami.MessageType.Warning : Kirigami.MessageType.Positive
            text: popup.vm.stagedMessage
            // The flip has to arrive as WORDS. Kirigami gives every InlineMessage the AlertMessage
            // role and no name, so without this a screen reader announces the icon - "Positive",
            // then later "Warning" - and the difference between the two banners would be a colour,
            // which for that person is no difference at all. The sentence already says everything.
            Accessible.name: text
            visible: popup.shows("staged")
            // ...and it has to be HEARD, not merely readable. See popup.speakMessage. Assertive,
            // because this is not the outcome of a press: it is the machine telling the person
            // that what they were promised has changed under them.
            property string spoken: ""
            onTextChanged: popup.speakMessage(stagedMessage, true)
            onVisibleChanged: popup.speakMessage(stagedMessage, true)
            actions: [
                Kirigami.Action {
                    // The same action the restart Warning offers, and never at the same time as it:
                    // vm.stagedShowRestart is false while that message is on screen. Two buttons
                    // for one outcome in one small window is how a person ends up pressing both.
                    // enabled/visible together, the pattern the Show Log action above already uses.
                    //
                    // It also goes away on every warning variant, which is the stricter half of
                    // that rule: the sentence beside it says the next restart will install the
                    // package they tried to keep out, and a Restart… button under that sentence is
                    // an invitation to do exactly that.
                    text: i18n("Restart…")
                    icon.name: "system-reboot"
                    enabled: popup.vm.stagedShowRestart
                    visible: enabled
                    onTriggered: source => popup.plasmoidItem.promptRestart()
                },
                Kirigami.Action {
                    // ...and what stands in its place. ONE action, offered only where there is
                    // something to change: rebuilding an ordinary armed stage would destroy a good
                    // transaction to produce the same one back.
                    //
                    // system-software-update, the icon already on Update Now below, because this
                    // runs the same verb: `kempt update --surface=offline`, the very command
                    // Install on Next Restart runs. view-refresh would have been wrong twice over -
                    // it is this popup's icon for "check again", and it is already on the Refresh
                    // button and the contextual action, so it would say "re-check" on a button
                    // that stages a transaction. system-reboot is taken by the button standing
                    // down right beside it.
                    text: i18n("Rebuild Staged Update")
                    icon.name: "system-software-update"
                    // The tooltip is the disclosure, not a hint: authorization, and the cost of a
                    // rebuild that fails (dnf5 destroys the stored transaction the moment a
                    // re-stage begins, so there is no "keep the old one" outcome to fall back on).
                    // Accessible.description carries the identical words because a polkit dialog
                    // takes the focus the moment this is pressed - a screen-reader user who has not
                    // heard the cost by then hears it never.
                    tooltip: i18n("Builds the staged update again with your current holds. Asks for authorization; if the rebuild fails, the current staged update is removed.")
                    Accessible.description: tooltip
                    enabled: popup.vm.stagedShowRebuild
                    visible: enabled
                    onTriggered: source => popup.plasmoidItem.rebuildStaged()
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
            // INFORMATION, not Warning. Nothing here is broken: one of two ways of doing the same
            // update is safer than the other, and the message says which. An amber box over a
            // button labelled Install on Next Restart, before anything had started, read as an
            // order to restart the machine now (hostile panel, first-run 3).
            type: Kirigami.MessageType.Information
            text: popup.vm.riskyMessage
            Accessible.name: text
            visible: popup.shows("kernel")
            actions: [
                Kirigami.Action {
                    // Named for what it does to the user rather than for the dnf5 flag behind it.
                    text: i18n("Install on Next Restart")
                    // ...and drawn as what it does: this INSTALLS software, at a moment of the
                    // machine's choosing. `system-reboot` sat on this button and on Restart… at
                    // the same time, two adjacent restart-shaped actions under one icon, one of
                    // which opens KDE's logout prompt and one of which stages a transaction
                    // (hostile panel, M3). `system-reboot` is Restart…'s alone now.
                    icon.name: "system-software-update"
                    tooltip: i18n("Applies the update during a restart, so nothing changes underneath your running desktop.")
                    onTriggered: source => popup.plasmoidItem.stageOffline()
                }
            ]
        }

        // ONE slot for the two reports: what the run that just finished did, and what a button
        // press that failed had to say. They were two messages stacked one above the other in a
        // popup that fits two in total, they are never the same event, and the later one is always
        // the one being asked about - so latest wins, and main.qml decides which that is.
        //
        // The stale explanation is not here at all any more. It was a blue "i" box whose first
        // word was "failed", carrying the CLI's raw text with no next step, and the fifth thing
        // competing for the room. It is three words on the footer's dateline now, which is the
        // line it was always explaining, with the reason in the Refresh button's tooltip.
        Kirigami.InlineMessage {
            id: reportMessage
            Layout.fillWidth: true
            type: popup.plasmoidItem.reportFailed ? Kirigami.MessageType.Error
                                                  : Kirigami.MessageType.Positive
            text: popup.plasmoidItem.reportText
            visible: popup.shows("report")
            Accessible.name: text
            // Assertive: a run that has just finished, or a press that failed, is the answer to
            // the one thing the person was waiting for, and the popup may not have the focus.
            property string spoken: ""
            onTextChanged: popup.speakMessage(reportMessage, true)
            onVisibleChanged: popup.speakMessage(reportMessage, true)
            actions: [
                Kirigami.Action {
                    text: i18n("Show Log")
                    icon.name: "text-x-generic"
                    // Only for a RUN, and only for one that recorded a log: a history entry old
                    // enough (or damaged enough) to have none is an ordinary event, and a failed
                    // button press has no log at all.
                    enabled: popup.plasmoidItem.reportLatest === "run"
                             && !!popup.plasmoidItem.lastRun
                             && popup.plasmoidItem.lastRun.logPath.length > 0
                    visible: enabled
                    onTriggered: source => popup.plasmoidItem.showLog(popup.plasmoidItem.lastRun.logPath)
                }
            ]
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
                            ColumnLayout {
                                spacing: 0

                                // Plasma's own section header rather than a bare Heading: it
                                // brings the theme's SVG separator, it is what makes this read as
                                // a Plasma list, and its trailing slot is where a per-section
                                // action would go later.
                                PlasmaExtras.ListSectionHeader {
                                    Layout.fillWidth: true
                                    label: modelData.title
                                    // Kirigami's ListSectionHeader marks its OWN label
                                    // Accessible.ignored (system ListSectionHeader.qml), so every
                                    // group title reached AT-SPI as an unnamed list item - and
                                    // "Held" is the heading that rescues the held state from being
                                    // a glyph and a position. Heading, because that is what a
                                    // screen reader navigates a list by.
                                    Accessible.role: Accessible.Heading
                                    Accessible.name: modelData.title
                                }

                                // The one thing a first-timer is owed under that heading. A dnf
                                // user reads versionlock into a padlock, and a hold is Kempt's own
                                // list: `dnf upgrade` typed in a terminal ignores it entirely.
                                // Gated on the row's own flag rather than on its title, which is a
                                // string a translator will change.
                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    Layout.leftMargin: Kirigami.Units.smallSpacing
                                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                                    visible: modelData.held === true
                                    text: i18n("Held packages are skipped by Kempt only.")
                                    wrapMode: Text.Wrap
                                    opacity: 0.7
                                    font: Kirigami.Theme.smallFont
                                }
                            }
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
                                // Which row is pending, never "a hold is running". The pressed row
                                // keeps its button live and focused; the others stand down.
                                pending: popup.plasmoidItem.pendingHold !== null
                                         && popup.plasmoidItem.pendingHold.name === modelData.name
                                         && popup.plasmoidItem.pendingHold.backend === modelData.backend
                                otherPending: popup.plasmoidItem.pendingHold !== null && !pending
                                // A failed hold belongs to the row it failed on, so the row is
                                // where it is drawn.
                                errorText: (popup.plasmoidItem.holdError !== null
                                            && popup.plasmoidItem.holdError.name === modelData.name
                                            && popup.plasmoidItem.holdError.backend === modelData.backend)
                                           ? popup.plasmoidItem.holdError.text : ""
                                onToggleHold: (backend, name, hold, keyboard) => {
                                    // Noted BEFORE the CLI is asked, because the model is replaced
                                    // by the check that follows and there is nothing left to read
                                    // it off afterwards.
                                    popup.refocusName = name;
                                    popup.refocusFromKeyboard = keyboard;
                                    popup.savedContentY = rowsView.contentY;
                                    popup.plasmoidItem.setHold(backend, name, hold);
                                }
                                // Keyboard focus has arrived in this row. Contain scrolls the
                                // least amount that makes the row whole, so a row already on
                                // screen does not move under a mouse user who just clicked it.
                                // See UpdateItemDelegate for what goes wrong without this.
                                onPinFocused: rowsView.positionViewAtIndex(index, ListView.Contain)
                                // The row the person acted on, rebuilt somewhere else in the list.
                                // settleAfterHold covers the ordinary case; this covers a delegate
                                // the view creates on its own schedule. Deferred, because at
                                // Component.onCompleted the item is not in the window's scene yet
                                // and forceActiveFocus there is a call that does nothing at all.
                                Component.onCompleted: if (popup.claimRefocus(modelData.name)) Qt.callLater(focusPin)
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
            visible: popup.plasmoidItem.lastRun !== null && !popup.shows("report")
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
                                // Same rule as the pending list: a package that was not installed
                                // before the run reads "new", not "?".
                                text: Logic.fromTextOf(historyRow.modelData.from) + " → " + historyRow.modelData.to
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

                // ...and said out loud when the box GOES stale, politely. Keyed on the reason and
                // not on the whole line, because this text is rewritten every thirty seconds by
                // the clock ("Checked 4 min ago") and a screen reader does not want to hear that.
                // Polite, because nothing has gone wrong that needs interrupting: the counts above
                // are still the best known truth and this dates them.
                property string spokenStale: ""
                onTextChanged: {
                    const reason = popup.vm.stale ? popup.vm.staleReason : "";
                    if (reason === footerLabel.spokenStale) return;
                    footerLabel.spokenStale = reason;
                    if (reason !== "") popup.announce(footerLabel.text, false);
                }

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
                //
                // ...and the third condition is the same rule applied to a state nobody had
                // thought about: while a transaction is staged and armed, the work the person
                // asked for is DONE and waiting for a restart, and this button would start it
                // again, live, over the top of it. It sat lit under a green banner saying so
                // (hostile panel, finding 3). Hidden and not disabled, by this file's own rule.
                visible: popup.vm.actionable > 0 && !popup.plasmoidItem.updating
                         && !popup.vm.stagedArmed
                // ...and refusing from the press until `kempt run` comes back. That call launches
                // the surface and returns, and it is allowed fifteen seconds to do it: the guard
                // in startUpdate tested `updating`, which is still false for all of them, so a
                // double press opened TWO terminals, both asking the risky question. Disabled
                // rather than hidden here, because the action still exists - it is happening.
                enabled: !popup.plasmoidItem.runRequested

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

                // Enter as well as Space, the shipped per-button Plasma pattern. Return and keypad
                // Enter on this button used to send nothing at all.
                Keys.onReturnPressed: animateClick()
                Keys.onEnterPressed: animateClick()

                // ...and the press says so on the button itself. Over the icon rather than beside
                // it, at the icon's own size, so the footer does not change width the moment it is
                // pressed: the whole point of the spinner is that nothing else has moved yet.
                PlasmaComponents.BusyIndicator {
                    id: updateBusy
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: updateButton.leftPadding
                    running: popup.plasmoidItem.runRequested
                    visible: running
                    implicitWidth: Kirigami.Units.iconSizes.small
                    implicitHeight: Kirigami.Units.iconSizes.small
                }
            }
        }
    }

    // --- the updating state ----------------------------------------------------------------------
    // Only reached for a run WE started. The log pane appears only on the in-popup surface, since
    // that is the surface whose whole point is that the output comes here.
    ColumnLayout {
        id: updatingPane
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        visible: popup.plasmoidItem.updating
        spacing: Kirigami.Units.smallSpacing

        // The pane replaces the whole content area, so every control the keyboard was standing on
        // goes with it. Measured before this: focus stayed on the INVISIBLE Update Now, and the
        // utterance over a stuck pane was "Update Now push button" for a control nobody was
        // drawing; Tab from there landed on a nameless RowLayout (hostile panel, a11y H1).
        // Both directions, because both are a swap: in, to the one control this pane has; out, to
        // whatever the popup's own rule says is primary now.
        onVisibleChanged: {
            if (visible) {
                if (popup.canTakeFocus(checkAgainButton)) {
                    checkAgainButton.forceActiveFocus(Qt.TabFocusReason);
                }
            } else {
                popup.focusPrimary();
            }
        }

        PlasmaComponents.Label {
            id: updatingLabel
            Layout.fillWidth: true
            // The surface the run is REALLY using, in words rather than in this repo's vocabulary.
            // It used to read "Updating in the %1 surface…" filled in with the CONFIGURED surface,
            // so a staging run started from Install on Next Restart announced itself as a terminal
            // one, and "surface" is a word nobody outside this project knows. The literals are
            // written here, not read out of logic.js, because i18n() extracts literals - see the
            // copy table's own header - and Logic.updatingLabelOf is what a node test pins.
            text: {
                switch (popup.plasmoidItem.runningSurface) {
                case "popup":      return i18n("Updating…");
                case "background": return i18n("Updating in the background…");
                case "offline":    return i18n("Preparing the install for the next restart…");
                default:           return i18n("Updating in a terminal window…");
                }
            }
            wrapMode: Text.WordWrap
        }

        // The way out. A terminal run that is aborted - the DEFAULT answer to the one question
        // Kempt asks, on the default configuration - never writes state.json, and only a state.json
        // change ends this pane. Without this the popup sat here, with no list, no Update Now and a
        // disabled Refresh, for three hours (hostile panel, finding 1).
        //
        // FLAT, not raised: it is a way out of a wrong state, not the thing this pane is for, and
        // a raised button here would read as "press this to finish the update".
        //
        // Deliberately NOT Kirigami.LinkButton, which is what a link-styled control would normally
        // be. Measured on this box: that component is a QQC2.Label with a MouseArea over it - no
        // focus ring, no place in the Tab ring, no animateClick, and nothing that answers Space.
        // This pane's whole problem was a keyboard left on a control nobody was drawing, so its
        // one control has to be a real one. A flat ToolButton is Plasma's own low-emphasis action.
        PlasmaComponents.ToolButton {
            id: checkAgainButton
            Layout.alignment: Qt.AlignLeft
            flat: true
            display: PlasmaComponents.AbstractButton.TextOnly
            text: i18n("Not updating? Check again")
            // Refuses while the check it started is running, so it cannot be pressed twice into
            // the same answer. Disabled rather than hidden: this is the pane's only control, and a
            // control that leaves the screen takes the keyboard with it.
            enabled: !popup.plasmoidItem.checking
            Accessible.name: text
            Accessible.description: i18n("Asks dnf and flatpak what is pending now, instead of waiting for the timer.")
            Keys.onReturnPressed: animateClick()
            Keys.onEnterPressed: animateClick()
            onClicked: popup.plasmoidItem.checkAgain()
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
            visible: popup.plasmoidItem.runningSurface === "popup"
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
            visible: popup.plasmoidItem.runningSurface !== "popup"
        }
    }
}
