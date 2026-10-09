// The popup: what is pending, what is held, what needs saying about it, and the one button that
// acts on it.
//
// This file DERIVES nothing. Every string and list it draws comes from the view model main.qml
// builds in logic.js, and every action is a call back into main.qml - but it also reaches directly
// for about two dozen members of main.qml through the untyped `plasmoidItem` handle (updating,
// checking, runRequested, pendingHold, holdError, lastRun, reportText, restartError, logTail,
// nowMs, setHold, promptRestart, rebuildStaged, showLog, ...). Those are live state and verbs, not
// derived values: anything that is a DERIVED string or list belongs in the view model, and adding
// a derivation here instead is the drift to watch for.
//
// The shape follows Plasma's own applets:
//   header  - the pending count and a refresh icon. Nothing else. A PlasmoidHeading is a
//             T.ToolBar, and a toolbar is for flat controls, not for messages.
//   content - a Kirigami.InlineMessage per thing that needs saying, then the list, then what the
//             last run did.
//   footer  - the status line and Update Now. The heading is the row Plasma's contract lets the
//             containment REPLACE; the footer is not, and Update Now is the one control in this
//             widget that must exist on every host, in every containment.
//
// EVERY reference to the widget goes through `plasmoidItem`, never through main.qml's `root` id.
// A representation whose required properties are satisfied is created successfully, and if it then
// reaches for an id from a context it does not have, each such binding throws a ReferenceError and
// evaluates to undefined - so `!undefined.updating` is true, every button enables itself, and the
// popup renders a confident, permanently-updating lie.
//
// `plasmoidItem` is typed `var` and not `PlasmoidItem` on purpose: most of what this file needs is
// declared in main.qml's QML body, not on the C++ type, so a typed handle would be a promise the
// type system cannot keep.
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
    // its popup comes with a title bar carrying the plasmoid's name, a pin and a configure gear,
    // so our own gear underneath would be the SECOND one opening the same dialog. On a panel or
    // the desktop nothing draws that heading and ours is the only way in.
    // `containmentDisplayHints & ContainmentDrawsPlasmoidHeading` is the shipped convention:
    // libplasma's BasicPlasmoidHeading uses it to hide itself in the tray, org.kde.plasma.vault to
    // drop its footer button there.
    //
    // A named property rather than the expression inline, because this is the only seam a test can
    // reach: `containmentDisplayHints` is READ-ONLY on Plasma::Applet, and outside plasmashell the
    // attached `Plasmoid` has no applet and answers undefined - which is also why the default that
    // falls out is the safe one (no host heading known, keep our own gear).
    // tests/qml/probe_popup.py overwrites this AND pins the expression verbatim.
    //
    // TWO controls read this and it must stay two - the gear and the refresh icon, because the
    // tray's heading genuinely draws both. Vault gates its whole footer this way and Kempt must
    // not copy that: a host that draws its own heading would take Update Now with it, and the
    // footer is the one row a containment may not replace.
    property bool traysHeading: (Plasmoid.containmentDisplayHints
                                 & PlasmaCore.Types.ContainmentDrawsPlasmoidHeading) !== 0

    // The representation-switch heuristic, not decoration: Plasma compares the space it has
    // against these to decide between the panel icon and this popup. Removing them is how a widget
    // ends up showing the popup inside a panel.
    Layout.minimumWidth: Kirigami.Units.gridUnit * 22
    Layout.minimumHeight: Kirigami.Units.gridUnit * 18
    Layout.preferredWidth: Kirigami.Units.gridUnit * 26
    // 28, not 24: at 24, with Last update expanded, the pending list showed two and a half rows.
    Layout.preferredHeight: Kirigami.Units.gridUnit * 28

    collapseMarginsHint: true

    // Room between the popup's border and everything in it, on both sides. collapseMarginsHint
    // hands the edges to us, and what the dialog leaves there depends on the Plasma style: some
    // leave nothing visible, and the rows touched the border. The SVG cannot tell us where its
    // visible border is, so the inset is always added.
    readonly property real edgeInset: Kirigami.Units.largeSpacing

    // --- the keyboard ------------------------------------------------------------------------------
    // All of this is about the popup as a WHOLE - which key reaches it, and what holds focus the
    // moment it appears - so it sits above the three rows rather than inside any one of them.

    // Escape ASKS to close. It does not close, and the difference is structural: `expanded` is
    // AppletQuickItem's C++ property and its setter dereferences the applet with no null check, so
    // a file that assigned it here would be a file no test could ever press Escape in - the probe
    // would segfault before reporting anything. main.qml owns that property and carries it out.
    signal closeRequested()

    // Klipper's precedent. On the popup rather than on any one control because key events travel
    // from whatever holds focus UP the parent chain: one handler here catches Escape from the
    // buttons, the padlocks and the message actions alike. Accepted, so a host that would also act
    // on it does not get a second go.
    Keys.onEscapePressed: event => {
        popup.closeRequested();
        event.accepted = true;
    }

    // Return on a message's own button. Our buttons each carry Keys.onReturnPressed, because QQC2
    // activates on Space only; the message buttons are Kirigami's, built inside its tool bar where
    // no handler of ours can go. So their Return travels up to here, and is pressed only for a
    // focused, enabled button that carries an action, which is what those buttons are. The risky
    // choice puts the keyboard on Install on Next Restart, and Enter there must stage.
    function pressFocusedAction(event) {
        const it = popup.Window.activeFocusItem;
        if (it && it !== popup && it.action && it.enabled && typeof it.animateClick === "function") {
            it.animateClick();
            event.accepted = true;
        } else {
            event.accepted = false;
        }
    }
    Keys.onReturnPressed: event => popup.pressFocusedAction(event)
    Keys.onEnterPressed: event => popup.pressFocusedAction(event)

    // Both halves, and `enabled` is the half that is easy to forget: an open that coincides with a
    // check in flight would otherwise put the keyboard on a Refresh button that is refusing to be
    // pressed, and a disabled QQC2 control does not accept focus - so forceActiveFocus is ignored
    // and the popup opens with focus nowhere.
    function canTakeFocus(item) {
        return item.visible && item.enabled;
    }

    // What the keyboard lands on when the popup opens, in the order of what the user came to do.
    // The last resort is the popup itself, where Keys.onEscapePressed lives, so even a popup whose
    // every control is unusable can be closed.
    // Refresh is the fallback rather than a greyed-out Update Now, because Update Now is HIDDEN
    // when there is nothing to run (see the footer) and forcing focus onto an invisible item
    // leaves the popup with no focus at all - at which point every key goes nowhere, the Escape
    // handler included.
    // Qt.TabFocusReason is the difference between focus and VISIBLE focus: a QQC2 control draws
    // its ring on `visualFocus`, which only the keyboard reasons set.
    function focusPrimary() {
        if (canTakeFocus(updateButton)) updateButton.forceActiveFocus(Qt.TabFocusReason);
        else if (canTakeFocus(refreshButton)) refreshButton.forceActiveFocus(Qt.TabFocusReason);
        else if (canTakeFocus(configureButton)) configureButton.forceActiveFocus(Qt.TabFocusReason);
        else popup.forceActiveFocus(Qt.TabFocusReason);
    }

    // The button an InlineMessage drew for one of its actions. Kirigami builds them inside its own
    // tool bar and names none of them, so the only handle is the action each one carries.
    function buttonFor(item, action) {
        if (!item) return null;
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++) {
            const kid = kids[i];
            if (kid.action === action && kid.visible) return kid;
            const found = popup.buttonFor(kid, action);
            if (found) return found;
        }
        return null;
    }

    // The risky choice opens on the recommended answer, so Enter stages rather than installs.
    // Later, not now: the message's buttons are laid out after the visibility change that shows them.
    // `then` runs after the focus move, in the same turn, so what it says is queued behind the
    // button's name rather than cut off by it.
    function focusRiskyChoice(then) {
        Qt.callLater(function () {
            const button = popup.buttonFor(riskyMessage, riskyStageAction);
            if (button && popup.canTakeFocus(button)) button.forceActiveFocus(Qt.TabFocusReason);
            if (typeof then === "function") then();
        });
    }

    // --- what the popup says out loud ---------------------------------------------------------
    // ONE function, and every announcement in this file goes through it:
    //   * `Accessible.announce` reaches an accessibility bridge and nothing else, so there is no
    //     way for a test to hear it. `announced` is emitted alongside, and the probes spy on that.
    //   * politeness is a decision, not a parameter to be re-argued at each call. Assertive is for
    //     something that happened TO the person (a banner that flipped, a run that failed); polite
    //     is for the outcome of something they just did.
    // Qt 6.11 has the method and both politeness values (measured); an older Qt would not, so the
    // call is guarded rather than assumed.
    signal announced(string sentence)
    // ...and how the last one was said, for the same reason: the bridge cannot be asked.
    property bool lastAnnounceAssertive: false

    function announce(sentence, assertive) {
        const said = String(sentence === undefined || sentence === null ? "" : sentence);
        if (said.length === 0) return;
        popup.lastAnnounceAssertive = assertive === true;
        popup.announced(said);
        if (typeof popup.Accessible.announce !== "function") return;
        popup.Accessible.announce(said, assertive ? Accessible.AnnouncementPoliteness.Assertive
                                                  : Accessible.AnnouncementPoliteness.Polite);
    }

    // --- how many messages may be on screen -----------------------------------------------------
    // Two, and WHICH two is logic.js's rule rather than four visibility bindings: a binding can say
    // "am I true", and only something that sees all four can say "am I one of the two that fit".
    // Measured: five messages left the list 95 px tall at the default popup size, and at
    // Layout.minimumHeight the messages alone overflowed - they are outside the ScrollView, so
    // nothing scrolled and the list was gone entirely.
    readonly property var messageSlots: popup.vm.messageSlots

    function shows(slot) {
        return popup.messageSlots.indexOf(slot) >= 0;
    }

    // A message whose words changed under the reader. Kirigami gives every InlineMessage the
    // AlertMessage role and no name, and a name change on an UNFOCUSED object is not spoken - it
    // is readable in flat review and nothing else. So a banner that flips from "61 updates are
    // staged" to "you held kf6-kio after this was prepared" changes its colour, its type and its
    // buttons silently, for the person who most needs to hear it.
    //
    // closedByButton(message, key) -> did this message's close button just hide it?
    // `visible` is the EFFECTIVE visibility, so it also goes false when an ancestor hides: Plasma
    // builds the popup in a hidden container and hides it on every close. The close button hides
    // only the message, so its parent is still visible then; an ancestor hiding takes the parent
    // with it (Qt updates a parent before its children). And the view model must still want the
    // message, which is what a run starting (the stack put away) fails.
    function closedByButton(message, key) {
        return message.parent !== null && message.parent.visible && popup.shows(key);
    }

    // `spoken` is what stops one change being announced twice: `text` and `visible` are two
    // bindings onto the same view-model change and both handlers fire. It is cleared when the
    // message goes away, so a banner that comes back says itself again.
    // `sentence`, when given, is what is said. A caller passes it when the item's Accessible.name
    // is bound to the same change and may not have updated yet when this handler runs.
    function speakMessage(item, assertive, sentence) {
        if (!item.visible) { item.spoken = ""; return; }
        const said = (typeof sentence === "string" && sentence.length > 0)
            ? sentence : (item.Accessible.name || item.text);
        if (said === item.spoken) return;
        item.spoken = said;
        popup.announce(said, assertive);
    }

    // The report slot, which speaks for itself except while a Check for Updates answer lands: a
    // failed check puts its report here, and the answer (vm.checkAnswerText) is the one that says
    // it, politely, from whichever of the popup and the panel icon is on screen.
    function speakReport() {
        if (popup.plasmoidItem.answeringCheck) {
            reportMessage.spoken = reportMessage.visible ? reportMessage.text : "";
            return;
        }
        // Assertive for a run that finished or a press that failed. Polite for good news about
        // something the person just did (actionDone), which is the answer to their own press.
        popup.speakMessage(reportMessage, popup.plasmoidItem.reportLatest !== "done");
    }

    // A message's words come from outside the widget (flatpak's error line, the CLI's stderr), so
    // they are shown as they are, never read as markup. InlineMessage has no textFormat of its
    // own; its label is the one child of contentItem that has one.
    // The clipboard, through the invisible TextEdit in the engine message. Every Copy button uses it.
    function copyToClipboard(text) {
        engineCopyClip.text = text;
        engineCopyClip.selectAll();
        engineCopyClip.copy();
    }

    function plainTextMessage(message) {
        var kids = message.contentItem ? message.contentItem.children : [];
        for (var i = 0; i < kids.length; i++) {
            if (kids[i].textFormat !== undefined) kids[i].textFormat = TextEdit.PlainText;
        }
    }

    // --- the hold round trip, on this side ------------------------------------------------------
    // main.qml runs the hold and the check that follows it; what arrives here is the moment the
    // model has been replaced and the row has moved. Three things have to happen then: the
    // keyboard follows the package, the viewport stays where the person left it, and somebody says
    // what happened.

    // The package whose padlock should take the keyboard as soon as its row exists again. Cleared
    // by whoever claims it, so a rebuild for some other reason cannot inherit it.
    property string refocusName: ""
    // How the press arrived. The two owe opposite things: a keyboard press must take the person to
    // the row wherever it has gone, and a pointer press must not move the list under the pointer.
    property bool refocusFromKeyboard: false
    // Where the list was standing when the padlock was pressed. The model is replaced wholesale,
    // and a ListView handed a new model starts at 0 (measured: contentY 884 to 0 on the 24-package
    // fixture, 1685 to 0 on an 80-row list).
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
    // Doing the work here rather than only in the delegate's Component.onCompleted is what makes it
    // work on a real list: a held row lands at the BOTTOM, under "Held", and a ListView only builds
    // the delegates near its viewport - so on an 80-package update the delegate the refocus is
    // waiting for does not exist until something scrolls to it.
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
                // padlock under their hand is live again.
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

    // Check for Updates, answered. The line at the top changes, and nothing announces it, so a
    // reader who pressed the button heard nothing at all. Polite, because the person asked. The
    // sentence is vm.checkAnswerText (a failed check says which half failed and how old the counts
    // are), and only while the popup is on screen: while it is closed, the panel icon says it
    // instead. An empty answer (a lost lock) is not signalled.
    Connections {
        target: popup.plasmoidItem
        function onFreshCheckAnswered() {
            // The answer has said any failure, so the footer counts it as said. Without this a
            // new reason behind the same footer line would be spoken again at the next clock tick.
            footerLabel.spokenStale = popup.vm.stale ? popup.vm.staleReason : "";
            if (!popup.plasmoidItem.popupOnScreen) return;
            popup.announce(popup.vm.checkAnswerText, false);
        }
    }

    // The open itself. main.qml owns `expanded` and therefore owns the announcement.
    // Component.onCompleted covers the FIRST open and only that one: this item is built lazily, as
    // a consequence of the popup being expanded, so on that one occasion it is not yet around to
    // hear the signal. Every open after it is the Connections.
    Connections {
        target: popup.plasmoidItem
        function onPopupShown() { popup.focusPrimary(); }
    }
    Component.onCompleted: if (popup.plasmoidItem.expanded) popup.focusPrimary()

    // --- keeping the keyboard on something ------------------------------------------------------
    // A message button can hide itself under the keyboard: Use This Widget ends its offer, Install
    // Now closes its question, a close button closes its message. A hidden control keeps the focus
    // while nobody can see it, and the next key goes to it anyway.
    //
    // rescueFocus() puts the keyboard back on the primary control, later rather than now (the
    // change that caused it is still being laid out), and only if what holds focus by then is not
    // something on screen that a person could press or tab to. The message buttons call it after
    // their action too, because an answer disables them while it is saved, and a button that will
    // not press again is not where the keyboard should wait. A control that refuses only for a
    // moment (Refresh while a check runs) keeps the keyboard: nothing calls this for it.
    function rescueFocus() {
        Qt.callLater(popup.rescueFocusNow);
    }
    function rescueFocusNow() {
        if (!popup.plasmoidItem.popupOnScreen || !popup.visible) return;
        const it = popup.Window.activeFocusItem;
        if (it && it.visible && it.enabled && (it === popup || it.activeFocusOnTab === true)) return;
        popup.focusPrimary();
    }
    // Every message's buttons, without a line in each: watch whatever holds the keyboard, and
    // rescue when it hides, or when the focus left it because it was hidden or destroyed.
    readonly property Item focusHolder: popup.Window.activeFocusItem
    property var lastFocusHolder: null
    onFocusHolderChanged: {
        const was = popup.lastFocusHolder;
        popup.lastFocusHolder = popup.focusHolder;
        if (was && was.visible !== true) popup.rescueFocus();
    }
    Connections {
        target: popup.focusHolder
        ignoreUnknownSignals: true
        function onVisibleChanged() {
            if (popup.focusHolder && !popup.focusHolder.visible) popup.rescueFocus();
        }
    }

    // --- the header ------------------------------------------------------------------------------
    // One row: the count, the refresh icon, the gear. Nothing else - three of the things that used
    // to be stacked in this toolbar were messages rather than controls, and they are InlineMessages
    // in the content area now.
    header: PlasmaExtras.PlasmoidHeading {
        // PlasmoidHeading sets no side padding of its own, so this lines it up with the content.
        leftPadding: popup.edgeInset
        rightPadding: popup.edgeInset
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

            // Refresh, in Bluetooth's Header.qml shape, and hidden in the
            // tray for the same reason Bluetooth hides its own: Plasma 6.7 renders a SINGLE
            // contextual action as an ICON in the heading it draws, beside the pin and the gear,
            // so registering checkAction (main.qml) already puts a view-refresh icon on screen at
            // one click and ours underneath it would be the second.
            PlasmaComponents.ToolButton {
                id: refreshButton
                // Both halves, never the hint alone. claimContextualActions() is a try with a
                // witness precisely because it can fail, and a tray heading with no action
                // registered draws no refresh icon at all - gating on the hint by itself would
                // leave the popup with no way to re-check on the one host where the claim did not
                // take. Off the tray this button is the only refresh there is, which is why the
                // default that falls out of an undefined hint is to show it.
                visible: !(popup.traysHeading
                           && popup.plasmoidItem.contextualActionsClaimed)
                // DISABLED while a check or a run is in flight, and still on screen. A control
                // that leaves the screen takes the keyboard with it: QQC2 delivers Space to
                // whatever holds activeFocus whether it is drawn or not, so swapping a spinner in
                // for this button leaves the keyboard on a Refresh nobody can see, where Space
                // queues another check. The popup's own open walks into it - popupOpened() starts
                // the refresh-on-open check before it announces popupShown().
                // This is the one control in the popup where "disabled" is the honest state -
                // unlike Update Now, whose absence means there is genuinely nothing to run.
                enabled: !popup.plasmoidItem.checking && !popup.plasmoidItem.updating
                icon.name: "view-refresh"
                display: PlasmaComponents.AbstractButton.IconOnly
                text: i18n("Check for Updates")
                Accessible.name: text
                // The tooltip is for whoever hovers; this is for whoever cannot - and it says what
                // pressing this DOES rather than repeating the label, which QQC2 already hands over
                // as the name. It also carries the CLI's own reason when the last check failed:
                // that reason belongs on the button that tries again, and the footer beside it says
                // that a check failed at all.
                Accessible.description: popup.vm.stale && popup.vm.staleReason.length > 0
                    ? i18n("Asks dnf and flatpak what is pending now, instead of waiting for the timer.")
                      + "\n" + popup.vm.staleReason
                    : i18n("Asks dnf and flatpak what is pending now, instead of waiting for the timer.")
                PlasmaComponents.ToolTip.text: popup.vm.stale && popup.vm.staleReason.length > 0
                                               ? text + "\n" + popup.vm.staleReason : text
                PlasmaComponents.ToolTip.visible: hovered || visualFocus
                PlasmaComponents.ToolTip.delay: Kirigami.Units.toolTipDelay
                // QQC2 activates on Space only. The shipped Plasma pattern is per button, not one
                // handler on the popup.
                Keys.onReturnPressed: animateClick()
                Keys.onEnterPressed: animateClick()
                // The same belt Update Now wears: a control that is refusing must not act, however
                // the press reached it.
                onClicked: if (enabled) popup.plasmoidItem.doCheck(false, true)
            }

            // The spinner, BESIDE Refresh rather than over it. Wrapped in an Item that keeps the
            // cell's width whether it is running or not, so the header does not jump sideways the
            // moment a check starts.
            //
            // A SIBLING and not the button's child: in the tray the button is hidden and this
            // becomes the only thing on screen saying a check is running (the heading's icon
            // belongs to the host and does not spin), so a spinner parented to the button would
            // disappear with it and a tray check would run with no sign at all.
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
                // typographic tell that a widget was not written by KDE.
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
    // A ColumnLayout rather than anchored siblings, because the message stack has to PUSH the list
    // down rather than float over it. PlasmaExtras.Representation is a Page whose default property
    // is contentData, so this is reparented into the content area and the footer can never overlap.
    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: popup.edgeInset
        anchors.rightMargin: popup.edgeInset
        spacing: Kirigami.Units.smallSpacing
        // A run of ours replaces this whole pane with the log tail below.
        visible: !popup.plasmoidItem.updating

        // --- the message stack -------------------------------------------------------------------
        // Kirigami.InlineMessage each, with their own `actions:` list rather than a hand-rolled
        // RowLayout, so they wrap correctly at popup width and get consistent iconography. Shipped
        // precedent inside a plasmoid: org.kde.desktopcontainment's FolderView.qml.

        // No WORKING engine on the box. Two situations share this message because they share a
        // consequence - nothing can be checked - and the view model decides which sentence and
        // which command it carries: the engine is not installed (the ORDINARY first run of a KDE
        // Store install), or it is installed and will not start. FIRST in the stack because it is
        // the only message saying the widget cannot do anything at all yet.
        //
        // Information and not Error even for the second: the emblem on the PANEL icon is where a
        // malfunction is raised (logic.js, iconState, which dims for one and warns for the other),
        // and a popup already showing one message about one problem does not need to shout as well.
        //
        // One action, and it RUNS nothing: it puts the remedy on the clipboard, because an
        // InlineMessage's text cannot be selected and a retyped command line fails somewhere the
        // reader then has to debug. The payload is vm.engineFaultCopyText, the pasteable form, NOT
        // the message's own sentence: pasting a sentence into a shell is its own failure, and the
        // label comes from the view model with it so it can say Command or Commands truthfully.
        // The rest of the popup needs no new gate - Update Now, the list and the placeholder are
        // all bound to view-model values that are empty with no state. Refresh deliberately stays:
        // it is how somebody who has just installed or repaired the package gets an answer without
        // waiting out the hourly timer.
        Kirigami.InlineMessage {
            id: engineFaultMessage
            Layout.fillWidth: true
            type: Kirigami.MessageType.Information
            text: popup.vm.engineFaultMessage
            Accessible.name: text
            visible: popup.shows("engineFault")
            actions: [
                // Runs the command the message names, for an engine that is there and will not
                // start. Its error is the answer, and it shows in the message below this one.
                Kirigami.Action {
                    text: i18n("Check Installation")
                    icon.name: "tools-report-bug"
                    enabled: popup.vm.engineFaultOffersDoctor
                    visible: enabled
                    onTriggered: source => popup.plasmoidItem.runDoctor()
                },
                Kirigami.Action {
                    text: popup.vm.engineFaultActionLabel
                    icon.name: "edit-copy"
                    onTriggered: source => popup.copyToClipboard(popup.vm.engineFaultCopyText)
                }
            ]
            // The clipboard, reached the only way pure QML can: an invisible TextEdit whose copy()
            // is QClipboard underneath. Zero-size and non-visible so it can never take focus or
            // paint; it holds text only for the instant between the click and the copy.
            TextEdit {
                id: engineCopyClip
                visible: false
                width: 0; height: 0
            }
        }

        // The restart. Shown in EVERY state, including up to date: you can owe a restart and have
        // twelve updates pending at once, and you can owe one with nothing pending at all.
        // Bound to vm.restartMessageVisible, which has already folded in the
        // `restart_reminder` setting and this session's dismissal - binding it to either half
        // separately would be a second copy of that rule.
        Kirigami.InlineMessage {
            id: restartMessage
            Layout.fillWidth: true
            type: Kirigami.MessageType.Warning
            showCloseButton: true
            // Kirigami gives every InlineMessage the AlertMessage role and no NAME, so a screen
            // reader announcing this alert reads out its icon - "Warning" - and nothing about what
            // happened. Every message in this stack carries this, the two that only ever report a
            // failure included: a message nobody can hear is not being shown.
            Accessible.name: text
            // Every reason this can be hidden is behind this one call, and the handler below
            // re-evaluates the SAME call. The third reason is the cap: the stack fits two, and the
            // restart is the cheapest of the four to displace because the footer says "restart
            // pending" whenever this message is not on screen.
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
                    // would offer the very install the person tried to stop, forty pixels above the
                    // sentence saying so. logic.js decides it; nothing here re-derives it.
                    enabled: popup.vm.restartShowAction
                    visible: enabled
                    onTriggered: source => popup.plasmoidItem.promptRestart()
                }
            ]

            // Kirigami's close button does exactly one thing:
            //     onClicked: root.visible = false
            // (templates/InlineMessage.qml). That is an ASSIGNMENT, and assigning to a property
            // destroys the binding on it for good - so without this the message would not merely
            // close, it would never come back when the machine's answer changed. This turns that
            // assignment into the call it was meant to be and puts the binding back.
            //
            // The guard re-evaluates the whole visibility expression rather than reading a cached
            // flag, and THAT is the load-bearing part: this handler also fires when an ancestor
            // hides, which happens every time a run starts. A guard that only asked "does the view
            // model still want this?" would read a run beginning as the user closing the message,
            // and an update would quietly switch the reminder off for the rest of the session.
            onVisibleChanged: {
                if (visible) return;
                if (!popup.closedByButton(restartMessage, "restart")) return;
                popup.plasmoidItem.dismissRestart();
                visible = Qt.binding(function () { return popup.shows("restart"); });
            }
        }

        // What the next restart will install. Usually Positive: nothing is wrong, nothing needs
        // pressing, and the work the person asked for is done and waiting. Without it a staged
        // transaction looks exactly like an un-staged one, with the offline offer below still on
        // screen and pressing it again the obvious thing to do. vm.stagedMessage is empty unless
        // the CLI has found a transaction genuinely ARMED, so this is never shown over a stage no
        // restart would install.
        //
        // ...and it FLIPS. Once a hold lands on a package the stored transaction contains the
        // reassurance is false, and a second line under a green checkmark would be the
        // contradiction one level down with the button still on the reassuring half - so the whole
        // message changes type, drops the restart, and offers the one action that changes the
        // outcome. logic.js decides which banner this is (stagedVariantOf).
        Kirigami.InlineMessage {
            id: stagedMessage
            Layout.fillWidth: true
            // Bound, never declared. A literal Positive here is the bug this whole message exists
            // to remove, and it is one careless edit away - so the type comes from the view model
            // the same way the text does, and tests/test_widget_logic.sh guards the binding.
            type: popup.vm.stagedType === "warning"
                  ? Kirigami.MessageType.Warning : Kirigami.MessageType.Positive
            // The plain banner shows only what the header does not say. Its accessible name, and
            // what is announced, is the whole sentence (`sentence` below).
            text: popup.vm.stagedBanner
            // The flip has to arrive as WORDS. Without a name a screen reader announces the icon,
            // "Positive" and later "Warning", and the difference between the two banners would
            // be a colour, which for that person is no difference at all.
            Accessible.name: popup.vm.stagedMessage
            visible: popup.shows("staged")
            // ...and it has to be HEARD, not merely readable. See popup.speakMessage. Assertive,
            // because this is not the outcome of a press: it is the machine telling the person
            // that what they were promised has changed under them.
            property string spoken: ""
            // On the whole sentence, which changes with the count while the banner may not.
            readonly property string sentence: popup.vm.stagedMessage
            onSentenceChanged: popup.speakMessage(stagedMessage, true, sentence)
            onVisibleChanged: popup.speakMessage(stagedMessage, true, sentence)
            actions: [
                Kirigami.Action {
                    // The same action the restart Warning offers, and never at the same time as it:
                    // vm.stagedShowRestart is false while that message is on screen. Two buttons
                    // for one outcome in one small window is how a person ends up pressing both.
                    //
                    // It also goes away on every warning variant, which is the stricter half of
                    // that rule: the sentence beside it says the next restart will install the
                    // package they tried to keep out.
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
                    // runs the same verb: `kempt update --surface=offline`. view-refresh would be
                    // wrong twice over - it is this popup's icon for "check again" and already sits
                    // on the Refresh button and the contextual action; system-reboot is taken by
                    // the button standing down right beside it.
                    text: i18n("Rebuild Staged Update")
                    icon.name: "system-software-update"
                    // The tooltip is the disclosure, not a hint: authorization, and the cost of a
                    // rebuild that fails (dnf5 destroys the stored transaction the moment a
                    // re-stage begins, so there is no "keep the old one" outcome).
                    // Accessible.description carries the identical words because a polkit dialog
                    // takes the focus the moment this is pressed - a screen-reader user who has not
                    // heard the cost by then hears it never.
                    tooltip: i18n("Builds the staged update again with your current holds. May ask for your password. If the rebuild fails, the current staged update is removed.")
                    Accessible.description: tooltip
                    // Shown by the view model, and disabled while a staging action is already
                    // pending (main.qml, actionPending): a second press would queue a second
                    // action behind the first. Disabled and not hidden, because the banner it
                    // stands on has not changed - the answer is on its way.
                    visible: popup.vm.stagedShowRebuild
                    enabled: visible && !popup.plasmoidItem.actionPending
                    onTriggered: source => popup.plasmoidItem.rebuildStaged()
                },
                Kirigami.Action {
                    // The way out that is neither a restart nor a rebuild, and the one somebody who
                    // simply changed their mind is looking for. LAST in the list on purpose: on a
                    // warning it stands BESIDE the rebuild rather than where the rebuild stands,
                    // because the conflict remedy is what that message is for. It is on the green
                    // banner too - staging an update and then thinking better of it is not a
                    // problem anybody should have to open a terminal to fix.
                    //
                    // edit-delete, which is what it does: system-software-update is the staging
                    // icon and sits on the action right above this one, view-refresh is Refresh,
                    // and system-reboot is the button standing down beside it.
                    text: i18n("Discard Staged Update")
                    icon.name: "edit-delete"
                    // The tooltip is the disclosure, not a hint, and its second half is the fact
                    // that separates this from the rebuild above: a rebuild reuses dnf5's package
                    // cache, and this deletes it. Accessible.description carries the identical
                    // words for the identical reason - a polkit dialog takes the focus the moment
                    // this is pressed.
                    tooltip: i18n("Removes the update waiting for the next restart, so the restart installs nothing. May ask for your password. It deletes the packages it downloaded, so staging again downloads them again.")
                    Accessible.description: tooltip
                    visible: popup.vm.stagedShowDiscard
                    enabled: visible && !popup.plasmoidItem.actionPending
                    onTriggered: source => popup.plasmoidItem.discardStaged()
                }
            ]
        }

        // An image-based Fedora: Silverblue, Kinoite, Bazzite, a bootc image. rpm-ostree owns /usr,
        // dnf is not how the machine updates, and `kempt update` aborts in pre-flight. Those images
        // ship dnf5 and plasma-workspace, so Kempt installs cleanly and everything here fills in
        // with dnf's answers - which is exactly why this has to be said outright rather than left
        // to a button press to discover.
        //
        // Information: the machine is not broken and neither is Kempt, it is the wrong tool for
        // this box. No action of its own - Discover is where this belongs, and an update widget
        // launching another updater is not a button anybody asked for.
        Kirigami.InlineMessage {
            id: imageBasedMessage
            Layout.fillWidth: true
            type: Kirigami.MessageType.Information
            text: popup.vm.imageBasedMessage
            Accessible.name: text
            visible: popup.shows("imageBased")
        }

        // A Fedora release upgrade staged outside Kempt. dnf5 keeps ONE stored transaction for that
        // and for an ordinary offline update alike, so staging updates for a restart would cancel it
        // - and re-downloading a release upgrade is gigabytes. The CLI refuses the press; this is
        // what makes the popup stop offering it, so nobody presses a button to be told no.
        //
        // Information, and no action of its own: nothing here is broken, there is nothing to fix,
        // and the two things a person might want to do about it - restart, or drop the upgrade -
        // are theirs to choose rather than a button in an update widget. It displaces the kernel
        // recommendation deliberately (logic.js, messageStack), because that message recommends the
        // one thing this state does not allow.
        Kirigami.InlineMessage {
            id: releaseUpgradeMessage
            Layout.fillWidth: true
            type: Kirigami.MessageType.Information
            text: popup.vm.releaseUpgradeMessage
            Accessible.name: text
            visible: popup.shows("releaseUpgrade")
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
            // button labelled Install on Next Restart, before anything has started, reads as an
            // order to restart the machine now.
            type: Kirigami.MessageType.Information
            // The same words become a question after Update Now on a surface that cannot ask for
            // itself (logic.js, updateAsksFirst): staging, recommended, or installing now. The
            // lead-in says the click did not start anything, and the question ends it on screen
            // as it does out loud.
            text: asking ? Logic.COPY.riskyAskLead + " " + popup.vm.riskyMessage
                           + " " + Logic.COPY.riskyAskQuestion
                         : popup.vm.riskyMessage
            Accessible.name: text
            readonly property bool asking: popup.shows("riskyChoice")
            visible: popup.shows("kernel") || asking
            // Polite: it answers the click. Said after the focus lands on Install on Next Restart,
            // so it follows the button's name instead of being cut off by it, and it ends on the
            // question that button answers.
            onAskingChanged: {
                if (!asking) return;
                popup.focusRiskyChoice(function () {
                    if (!riskyMessage.asking) return;
                    popup.announce(riskyMessage.text, false);
                });
            }
            actions: [
                Kirigami.Action {
                    id: riskyStageAction
                    // Named for what it does to the user rather than for the dnf5 flag behind it.
                    text: i18n("Install on Next Restart")
                    // ...and drawn as what it does: this INSTALLS software, at a moment of the
                    // machine's choosing. `system-reboot` is Restart…'s alone - two adjacent
                    // restart-shaped actions under one icon, one opening KDE's logout prompt and
                    // one staging a transaction, is not a distinction anybody can make.
                    icon.name: "system-software-update"
                    // Promises Flatpak apps update now only when some are waiting.
                    tooltip: popup.vm.stageTooltipNamesFlatpak
                        ? i18n("Installs system updates during the next restart. Flatpak apps update now.")
                        : i18n("Installs system updates during the next restart.")
                    // Gone, not greyed, while a Fedora release upgrade is stored: the message that
                    // replaces this one says why, and a disabled button with its explanation in a
                    // different message is a puzzle rather than an answer.
                    visible: popup.vm.offlineStageOffered
                    enabled: visible && !popup.plasmoidItem.actionPending
                    onTriggered: source => { popup.plasmoidItem.stageOffline(); popup.rescueFocus(); }
                },
                Kirigami.Action {
                    id: riskyInstallNowAction
                    // Only as the answer to Update Now. Runs what Update Now would have run, and
                    // tells the CLI the person chose it, so no notification repeats the question.
                    text: i18n("Install Now")
                    tooltip: i18n("Installs the update now, while your desktop is running.")
                    icon.name: "run-build-install"
                    visible: riskyMessage.asking
                    enabled: visible && !popup.plasmoidItem.runRequested
                             && !popup.plasmoidItem.actionPending
                    onTriggered: source => { popup.plasmoidItem.startUpdate(true); popup.rescueFocus(); }
                }
            ]
        }

        // The one-time offer to update here instead of in a terminal window, made to a box that had
        // the terminal before the popup became the default (bin/kempt, surface_migrate). Either
        // answer is written as the setting, which is what ends the offer.
        Kirigami.InlineMessage {
            id: surfaceOfferMessage
            Layout.fillWidth: true
            type: Kirigami.MessageType.Information
            text: i18n("Updates can now run in this widget instead of a terminal window.")
            Accessible.name: text
            visible: popup.shows("surfaceOffer")
            actions: [
                Kirigami.Action {
                    text: i18n("Use This Widget")
                    icon.name: "dialog-ok"
                    onTriggered: source => { popup.plasmoidItem.useSurface("popup"); popup.rescueFocus(); }
                },
                Kirigami.Action {
                    text: i18n("Keep the Terminal Window")
                    icon.name: "utilities-terminal"
                    onTriggered: source => { popup.plasmoidItem.useSurface("terminal"); popup.rescueFocus(); }
                }
            ]
        }

        // The one-time offer to turn off Discover's own update notifier, which counts updates on
        // its own schedule. Either answer ends it. Settings can turn the notifier back on.
        Kirigami.InlineMessage {
            id: discoverOfferMessage
            Layout.fillWidth: true
            type: Kirigami.MessageType.Information
            text: i18n("Discover, Plasma's software center, also shows update notifications. Its count can differ from Kempt's, and its checks can make an update wait. Kempt shows new updates on its panel icon and does not send notifications for them.")
            Accessible.name: text
            visible: popup.shows("discoverOffer")
            actions: [
                Kirigami.Action {
                    text: i18n("Turn Off Discover's Notifier")
                    icon.name: "notifications-disabled"
                    enabled: !popup.plasmoidItem.actionPending
                    onTriggered: source => { popup.plasmoidItem.setDiscoverNotifier("off"); popup.rescueFocus(); }
                },
                Kirigami.Action {
                    text: i18n("Keep Discover's Notifier")
                    icon.name: "dialog-ok"
                    enabled: !popup.plasmoidItem.actionPending
                    onTriggered: source => { popup.plasmoidItem.setDiscoverNotifier("keep"); popup.rescueFocus(); }
                }
            ]
        }

        // ONE slot for the two reports: what the run that just finished did, and what a button
        // press that failed had to say. They are never the same event, and the later one is always
        // the one being asked about - so latest wins, and main.qml decides which that is.
        //
        // The stale explanation is not here at all: it is three words on the footer's dateline,
        // which is the line it was always explaining, with the reason in the Refresh tooltip.
        Kirigami.InlineMessage {
            id: reportMessage
            Component.onCompleted: popup.plainTextMessage(reportMessage)
            Layout.fillWidth: true
            type: popup.plasmoidItem.reportFailed ? Kirigami.MessageType.Error
                                                  : Kirigami.MessageType.Positive
            text: popup.plasmoidItem.reportText
            visible: popup.shows("report")
            Accessible.name: text
            // Assertive: a run that has just finished, or a press that failed, is the answer to
            // the one thing the person was waiting for, and the popup may not have the focus.
            property string spoken: ""
            onTextChanged: popup.speakReport()
            onVisibleChanged: popup.speakReport()
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
                },
                // A report that says to run kempt doctor gets the button. Copy Command is on the
                // result it opens: three buttons and a close do not fit the narrowest popup.
                Kirigami.Action {
                    text: i18n("Check Installation")
                    icon.name: "tools-report-bug"
                    enabled: popup.plasmoidItem.reportOffersDoctor
                    visible: enabled
                    onTriggered: source => popup.plasmoidItem.runDoctor()
                }
            ]
        }

        // What Check Installation found: a busy line while `kempt doctor` waits or runs, then the
        // first problem in doctor's own words, or that there were none. Show Full Report opens
        // everything it printed under the message, where it can be selected and copied.
        Kirigami.InlineMessage {
            id: doctorMessage
            Component.onCompleted: popup.plainTextMessage(doctorMessage)
            Layout.fillWidth: true
            readonly property bool running: popup.plasmoidItem.doctorRunning
            type: running ? Kirigami.MessageType.Information
                  : (popup.plasmoidItem.doctorFailed ? Kirigami.MessageType.Error
                                                     : Kirigami.MessageType.Positive)
            text: running ? i18n("Checking Kempt's installation…") : popup.plasmoidItem.doctorSummary
            visible: popup.shows("doctor")
            // Closable while it runs too: doctor can wait minutes behind a check or Free Up Space.
            showCloseButton: true
            property bool showingReport: false
            Accessible.name: text
            // Polite: the answer to the person's own press.
            property string spoken: ""
            onTextChanged: popup.speakMessage(doctorMessage, false)
            actions: [
                Kirigami.Action {
                    text: i18n("Show Full Report")
                    icon.name: "view-list-details"
                    checkable: true
                    checked: doctorMessage.showingReport
                    enabled: !doctorMessage.running && popup.plasmoidItem.doctorReport.length > 0
                    visible: enabled
                    onTriggered: source => doctorMessage.showingReport = !doctorMessage.showingReport
                },
                Kirigami.Action {
                    text: i18n("Copy Command")
                    icon.name: "edit-copy"
                    // The will-not-run message above has the same button for the same command.
                    visible: !popup.vm.engineFaultOffersDoctor
                    onTriggered: source => popup.copyToClipboard(Logic.COPY.engineUnrunnableCopy)
                }
            ]
            // A new check starts with the report folded away.
            onRunningChanged: if (running) showingReport = false
            // The close button breaks the visibility binding, as on the restart message: turn it
            // into a dismissal and put the binding back.
            onVisibleChanged: {
                if (visible) { popup.speakMessage(doctorMessage, false); return; }
                doctorMessage.spoken = "";
                if (!popup.closedByButton(doctorMessage, "doctor")) return;
                popup.plasmoidItem.dismissDoctor();
                popup.rescueFocus();
                visible = Qt.binding(function () { return popup.shows("doctor"); });
            }
        }

        // The full report, at most a third of the popup tall, so the list keeps its room.
        PlasmaComponents.ScrollView {
            id: doctorReportView
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(doctorReportText.implicitHeight,
                                             Math.round(popup.height / 3))
            visible: doctorMessage.visible && doctorMessage.showingReport
                     && popup.plasmoidItem.doctorReport.length > 0
            PlasmaComponents.TextArea {
                id: doctorReportText
                readOnly: true
                textFormat: TextEdit.PlainText
                wrapMode: TextEdit.Wrap
                font.family: "monospace"
                text: popup.plasmoidItem.doctorReport
                Accessible.name: i18n("Full report")
            }
        }

        // A Check for Updates that could not fetch fresh lists: why, and how old the lists behind
        // the counts are. Information, because those counts are still the best known. It goes at
        // the next check, whoever starts it, or with its close button.
        Kirigami.InlineMessage {
            id: fetchMissedMessage
            Component.onCompleted: popup.plainTextMessage(fetchMissedMessage)
            Layout.fillWidth: true
            type: Kirigami.MessageType.Information
            showCloseButton: true
            // Passed to speakMessage as it is, as on the staged banner: Accessible.name follows
            // `text` a binding later, so reading it in this handler would say the previous one.
            readonly property string sentence: popup.vm.fetchMissedMessage
            text: sentence
            Accessible.name: text
            visible: popup.shows("fetchMissed")
            // On battery or a metered connection, one press downloads the lists anyway.
            actions: [
                Kirigami.Action {
                    id: fetchAnywayAction
                    text: i18n("Download Anyway")
                    icon.name: "download"
                    visible: popup.vm.fetchMissedAnyway.length > 0
                    tooltip: popup.vm.fetchMissedAnyway === "metered"
                             ? i18n("Downloads fresh package lists now over this metered connection.")
                             : i18n("Downloads fresh package lists now, on battery power.")
                    enabled: visible && !popup.plasmoidItem.updating
                    onTriggered: source => popup.plasmoidItem.downloadAnyway()
                }
            ]
            // Polite. While the check's answer lands, that answer says this sentence itself.
            property string spoken: ""
            function speak() {
                if (popup.plasmoidItem.answeringCheck) {
                    fetchMissedMessage.spoken = fetchMissedMessage.visible ? sentence : "";
                    return;
                }
                popup.speakMessage(fetchMissedMessage, false, sentence);
            }
            onSentenceChanged: speak()
            // The close button breaks the visibility binding, as on the restart message: turn it
            // into a dismissal and put the binding back.
            onVisibleChanged: {
                if (visible) { speak(); return; }
                fetchMissedMessage.spoken = "";
                if (!popup.closedByButton(fetchMissedMessage, "fetchMissed")) return;
                popup.plasmoidItem.dismissFetchMissed();
                popup.rescueFocus();
                visible = Qt.binding(function () { return popup.shows("fetchMissed"); });
            }
        }

        // Unused Flatpak runtimes: space `kempt reclaim` can free. Information, because nothing is
        // wrong, and LAST in the order (logic.js, MESSAGE_ORDER): the offer keeps until the next open.
        // Show Runtimes adds one line per runtime under the sentence, so the name read out lists them too.
        Kirigami.InlineMessage {
            id: reclaimMessage
            Component.onCompleted: popup.plainTextMessage(reclaimMessage)
            Layout.fillWidth: true
            type: Kirigami.MessageType.Information
            showCloseButton: true
            property bool showingWhat: false
            text: showingWhat && popup.vm.reclaimLines.length > 0
                  ? popup.vm.reclaimMessage + "\n" + popup.vm.reclaimLines.join("\n")
                  : popup.vm.reclaimMessage
            Accessible.name: text
            visible: popup.shows("reclaim")
            // Polite: an offer, not something that happened to the person.
            property string spoken: ""
            onTextChanged: popup.speakMessage(reclaimMessage, false)
            actions: [
                Kirigami.Action {
                    id: reclaimAction
                    // The label is also what a screen reader reads, so the running state is words.
                    text: popup.plasmoidItem.reclaimRunning ? i18n("Freeing Up Space…")
                        : popup.vm.reclaimAutomatic ? i18n("Free Up Space Now") : i18n("Free Up Space")
                    icon.name: "edit-clear-all"
                    tooltip: i18n("Removes the Flatpak runtimes listed under Show Runtimes.")
                    Accessible.description: tooltip
                    enabled: !popup.plasmoidItem.actionPending && !popup.plasmoidItem.runRequested
                             && !popup.plasmoidItem.updating
                    onTriggered: source => popup.plasmoidItem.reclaimSpace()
                },
                Kirigami.Action {
                    id: reclaimShowWhat
                    text: i18n("Show Runtimes")
                    icon.name: "view-list-details"
                    checkable: true
                    checked: reclaimMessage.showingWhat
                    onTriggered: source => reclaimMessage.showingWhat = !reclaimMessage.showingWhat
                }
            ]
            // The close button assigns visible = false and breaks the binding, as on the restart
            // message: turn it into a dismissal of this digest and put the binding back. The guard
            // tells a close apart from the popup hiding for a run.
            onVisibleChanged: {
                if (visible) { popup.speakMessage(reclaimMessage, false); return; }
                reclaimMessage.spoken = "";
                if (!popup.closedByButton(reclaimMessage, "reclaim")) return;
                popup.plasmoidItem.dismissReclaim();
                visible = Qt.binding(function () { return popup.shows("reclaim"); });
            }
        }

        // --- the list, and what stands in for it when there is none --------------------------------
        // One Item holding both, so the placeholder is centred in the space the list would have
        // occupied rather than in the whole popup.
        Item {
            id: listArea
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
                    // Recycling delegates is the one thing this list must NOT do, and the reason is
                    // the keyboard rather than the frame rate. Qt walks the focus chain in the
                    // order the delegates are children of the view, and a recycled delegate keeps
                    // the place it was created in - so once the pool starts handing rows back, the
                    // row after the one holding focus is no longer the next child. Measured on an
                    // 80-package list: with reuseItems, Tab threw the user out of the list and back
                    // through the header twice on the way down. These delegates are two labels and
                    // a button, so building them the ordinary way costs nothing worth having.
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

                                // Plasma's own section header rather than a bare Heading: it brings
                                // the theme's SVG separator, it is what makes this read as a Plasma
                                // list, and its trailing slot is where a per-section action would
                                // go later.
                                PlasmaExtras.ListSectionHeader {
                                    Layout.fillWidth: true
                                    label: modelData.title
                                    // Kirigami's ListSectionHeader marks its OWN label
                                    // Accessible.ignored (system ListSectionHeader.qml), so every
                                    // group title reaches AT-SPI as an unnamed list item - and
                                    // "Held" is the heading that rescues the held state from being
                                    // a glyph and a position. Heading, because that is what a
                                    // screen reader navigates a list by.
                                    Accessible.role: Accessible.Heading
                                    Accessible.name: modelData.title
                                }

                                // The one thing a first-timer is owed under that heading: a dnf
                                // user reads versionlock into a padlock, and a hold is Kempt's own
                                // list - `dnf upgrade` typed in a terminal ignores it entirely.
                                // Gated on the row's own flag rather than on its title, which is a
                                // string a translator will change.
                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    Layout.leftMargin: Kirigami.Units.smallSpacing
                                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                                    visible: modelData.held === true
                                    text: i18n("Kempt skips these. Other updaters still see them.")
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
                                // Both default in the delegate, so a row from a state file written
                                // before runtimes were counted carries neither and renders as it
                                // always did.
                                branch: modelData.branch || ""
                                holdable: modelData.holdable !== false
                                forYouOnly: modelData.forYouOnly === true
                                bothScopes: modelData.bothScopes === true
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
                                // Keyboard focus has arrived in this row. Contain scrolls the least
                                // amount that makes the row whole, so a row already on screen does
                                // not move under a mouse user who just clicked it.
                                onPinFocused: rowsView.positionViewAtIndex(index, ListView.Contain)
                                // The row the person acted on, rebuilt somewhere else in the list.
                                // settleAfterHold covers the ordinary case; this covers a delegate
                                // the view creates on its own schedule. Deferred, because at
                                // Component.onCompleted the item is not in the window's scene yet
                                // and forceActiveFocus there does nothing at all.
                                Component.onCompleted: if (popup.claimRefocus(modelData.name)) Qt.callLater(focusPin)
                            }
                        }
                    }
                }
            }

            // Up to date, no data yet, or a CLI we could not run. The third is the only one that
            // owes the user an instruction, and it gets the CLI's own words plus the command that
            // diagnoses it. Note what it is NOT shown for: a box whose only pending updates are
            // held has rows, so the Held group carries the truth instead and "everything is up to
            // date" is never said over the top of it.
            //
            // Centred, it grows both ways, so in an area shorter than itself it paints over the
            // messages above - measured at the smallest popup size with the reclaim offer up. So
            // it never takes more than the area has: the icon goes first, and when even the words
            // do not fit the whole thing stands down, because the header already says the same.
            // The heights come from the two copies below, never from the placeholder itself:
            // dropping the icon changes its height, and a test against that would be a loop.
            PlasmaExtras.PlaceholderMessage {
                id: placeholder
                anchors.centerIn: parent
                width: parent.width - Kirigami.Units.gridUnit * 4
                readonly property bool wanted: popup.vm.rows.length === 0 && text.length > 0
                readonly property bool iconFits: listArea.height >= placeholderFull.implicitHeight
                visible: wanted && listArea.height >= placeholderWords.implicitHeight
                iconName: !iconFits ? ""
                          : popup.vm.iconState === "error" ? "dialog-error"
                          : (popup.vm.iconState === "unknown" ? "view-refresh" : "update-none")
                text: popup.vm.emptyStateText
                explanation: popup.vm.problemHint
                helpfulAction: popup.vm.problemAnyway.length > 0 ? anywayPlaceholderAction
                                                                 : doctorPlaceholderAction
                // The tool's own words, in small print under the plain headline, for anyone who
                // needs them. Selectable, so they can be pasted into a search or a bug report.
                PlaceholderDetail { id: placeholderDetail; text: popup.vm.problemDetail }
            }

            component PlaceholderDetail: Kirigami.SelectableLabel {
                Layout.fillWidth: true
                Layout.maximumWidth: Kirigami.Units.gridUnit * 20
                Layout.alignment: Qt.AlignHCenter
                visible: text.length > 0
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                font: Kirigami.Theme.smallFont
                opacity: 0.7
                Accessible.name: text
            }

            // The placeholder's button. Enabled whenever the explanation names the command, so it
            // stays on screen and keeps the keyboard while doctor runs; runDoctor ignores a second
            // press. The two measuring copies below carry it too, so they measure its height.
            Kirigami.Action {
                id: doctorPlaceholderAction
                text: i18n("Check Installation")
                icon.name: "tools-report-bug"
                enabled: popup.vm.remedyCommand.length > 0
                onTriggered: source => popup.plasmoidItem.runDoctor()
            }

            // ...or, under the battery and metered hints, Download Anyway: the lists were never
            // downloaded, and one press fetches them now. Enabled while a check runs: the press
            // runs next.
            Kirigami.Action {
                id: anywayPlaceholderAction
                text: i18n("Download Anyway")
                icon.name: "download"
                tooltip: popup.vm.problemAnyway === "metered"
                         ? i18n("Downloads fresh package lists now over this metered connection.")
                         : i18n("Downloads fresh package lists now, on battery power.")
                enabled: popup.vm.problemAnyway.length > 0 && !popup.plasmoidItem.updating
                onTriggered: source => popup.plasmoidItem.downloadAnyway()
            }

            // Two copies of the placeholder, never shown, to measure it with and without the
            // icon: its own height cannot be the test, because the test changes it. Copies rather
            // than arithmetic on its parts, because PlaceholderMessage adds space of its own: a sum
            // of the icon and the words came out 14 px short in a real window.
            PlasmaExtras.PlaceholderMessage {
                id: placeholderFull
                visible: false
                width: placeholder.width
                iconName: "update-none"
                text: placeholder.text
                explanation: placeholder.explanation
                helpfulAction: placeholder.helpfulAction
                PlaceholderDetail { text: popup.vm.problemDetail }
            }
            PlasmaExtras.PlaceholderMessage {
                id: placeholderWords
                visible: false
                width: placeholder.width
                text: placeholder.text
                explanation: placeholder.explanation
                helpfulAction: placeholder.helpfulAction
                PlaceholderDetail { text: popup.vm.problemDetail }
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
            // ...but never more than a third of the popup. An ordinary weekly Fedora update installs
            // fifty to two hundred packages, and this row expands to ALL of them: without a
            // ceiling, one click on the expander hands the whole popup to a history entry and
            // squeezes the pending list, which is what the popup is for, down to nothing. Half was
            // too much: it left the list two and a half rows at the default size.
            Layout.maximumHeight: Math.round(popup.height / 3)
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
                // Only a failure earns a second line here, or extensions the run's automatic removal
                // took from an app (once per run, see Logic.lastRunSubtitle), and it is logic.js's
                // own sentence about that run rather than a new one written in QML. NOT the entry's
                // reboot_needed: that is a fact about the moment the run ended, and the state
                // file's live answer is what the restart message above is bound to. Repeating the
                // history entry here would go on claiming a restart after the user had done it.
                subtitle: Logic.lastRunSubtitle(popup.plasmoidItem.lastRun,
                                                popup.plasmoidItem.reclaimInUseSeen)
                subtitleCanWrap: true
                customExpandedViewContent: lastRunPackages
                contextualActions: [
                    Kirigami.Action {
                        text: i18n("Show Log")
                        icon.name: "text-x-generic"
                        enabled: !!popup.plasmoidItem.lastRun
                                 && popup.plasmoidItem.lastRun.logPath.length > 0
                        onTriggered: source => popup.plasmoidItem.showLog(popup.plasmoidItem.lastRun.logPath)
                    },
                    // A failed run whose reason says to run kempt doctor: the button that does it.
                    Kirigami.Action {
                        text: i18n("Check Installation")
                        icon.name: "tools-report-bug"
                        enabled: Logic.mentionsDoctor(Logic.lastRunSubtitle(
                            popup.plasmoidItem.lastRun, popup.plasmoidItem.reclaimInUseSeen))
                        visible: enabled
                        onTriggered: source => popup.plasmoidItem.runDoctor()
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
                                // The join key split back into a name, so a runtime reads here the
                                // way it reads in the pending list above.
                                text: Logic.displayNameOf(historyRow.modelData.name)
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                            }
                            PlasmaComponents.Label {
                                // Same rule as the pending list, through the same function: a
                                // package that was not installed before the run reads "new" and not
                                // "?", and a version that did not move draws no arrow.
                                visible: text !== ""
                                text: Logic.versionTextOf(historyRow.modelData.from,
                                                          historyRow.modelData.to)
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
    // NOT gated on the containment hint, and this is the whole argument for the row existing:
    // gating it the way org.kde.plasma.vault gates its footer would put the primary action back on
    // the one piece of ground Plasma reserves for itself, which every shipped applet treats as
    // expendable because the contract says the host may replace it. Update Now
    // must exist on every host, and a footer keeps it in reach while a 1200-row list scrolls.
    footer: PlasmaExtras.PlasmoidHeading {
        leftPadding: popup.edgeInset
        rightPadding: popup.edgeInset
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
                // not on the whole line, because this text is rewritten every thirty seconds by the
                // clock ("Checked 4 min ago") and a screen reader does not want to hear that.
                // Polite, because nothing has gone wrong that needs interrupting: the counts above
                // are still the best known truth and this dates them.
                // Not while a Check for Updates is landing: that answer says the check failed and
                // how old the counts are (vm.checkAnswerText), even when the failure is the same
                // as last time.
                property string spokenStale: ""
                onTextChanged: {
                    const reason = popup.vm.stale ? popup.vm.staleReason : "";
                    if (reason === footerLabel.spokenStale) return;
                    footerLabel.spokenStale = reason;
                    if (reason !== "" && !popup.plasmoidItem.answeringCheck)
                        popup.announce(footerLabel.text, false);
                }

                // The relative time in the line is the convenience; the absolute stamp is the
                // truth, and people compare the two. A HoverHandler rather than
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
                // With updates set to run on the next restart and system updates to stage, the
                // press downloads now and installs at the restart, so it carries the risky
                // choice's words (Logic.updateButtonOf).
                text: popup.vm.updateStages ? i18n("Install on Next Restart") : i18n("Update Now")
                icon.name: "system-software-update"
                readonly property string stagesTooltip: !popup.vm.updateStages ? ""
                    : popup.vm.stageTooltipNamesFlatpak
                        ? i18n("Installs system updates during the next restart. Flatpak apps update now.")
                        : i18n("Installs system updates during the next restart.")
                Accessible.name: text
                Accessible.description: stagesTooltip
                PlasmaComponents.ToolTip.text: stagesTooltip
                PlasmaComponents.ToolTip.visible: (hovered || visualFocus) && stagesTooltip.length > 0
                PlasmaComponents.ToolTip.delay: Kirigami.Units.toolTipDelay
                // A raised Button and not a ToolButton: this is the primary action and it is not in
                // a toolbar any more.
                //
                // HIDDEN and not disabled when there is nothing to do: an up-to-date box has no run
                // to start, so there is no action to offer rather than an action being refused.
                //
                // ...and the third condition is that same rule applied to the staged state: while a
                // transaction is staged and armed the work the person asked for is DONE and waiting
                // for a restart, and this button would start it again, live, over the top of it.
                // ...and the fourth is a machine dnf cannot update at all, where the run would
                // abort in pre-flight whatever it was asked to do.
                // ...and the fifth is the risky question: while it is open, its two buttons are the
                // answers, and a third that asks the same question again is noise. It comes back
                // when the question closes, however that happens (main.qml, riskyChoiceOpen).
                visible: popup.vm.actionable > 0 && !popup.plasmoidItem.updating
                         && !popup.vm.stagedArmed && popup.vm.updateOffered
                         && !riskyMessage.asking
                // ...and refusing from the press until `kempt run` comes back. That call launches
                // the surface and returns, and is allowed fifteen seconds to do it; startUpdate's
                // guard tests `updating`, which is still false for all of them. Disabled rather
                // than hidden here, because the action still exists - it is happening. Likewise
                // while a staging action from a banner is pending (main.qml, actionPending).
                enabled: !popup.plasmoidItem.runRequested && !popup.plasmoidItem.actionPending

                // ...which means this control can go off screen while the popup is open and the
                // keyboard is standing on it: `actionable` reaches 0 on its own - the 30s watcher,
                // the hourly timer, or a `kempt update` finishing in a terminal - and nothing calls
                // focusPrimary() again, because the popup did not open, it just changed. QQC2
                // delivers Space and Return to whatever holds activeFocus whether it is drawn or
                // not, so what is left is an invisible button that starts `kempt run` on a box with
                // nothing to update.
                onVisibleChanged: if (!visible && activeFocus && !riskyMessage.asking) popup.focusPrimary()

                // The belt to that braces. A control that is invisible and still operable is a trap
                // however the keyboard reached it, and the focus move above is not the only route
                // in - a screen reader, a shortcut, or a future edit can all put focus back.
                onClicked: if (visible) popup.plasmoidItem.startUpdate()

                // Enter as well as Space, the shipped per-button Plasma pattern.
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
        anchors.leftMargin: popup.edgeInset
        anchors.rightMargin: popup.edgeInset
        visible: popup.plasmoidItem.updating
        spacing: Kirigami.Units.smallSpacing

        // The pane replaces the whole content area, so every control the keyboard was standing on
        // goes with it. Measured: focus stayed on the INVISIBLE Update Now, and the utterance over
        // a stuck pane was "Update Now push button" for a control nobody was drawing; Tab from
        // there landed on a nameless RowLayout. Both directions, because both are a swap: in, to
        // the one control this pane has; out, to whatever the popup's rule says is primary now.
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
            // The surface the run is REALLY using, in words rather than in this repo's vocabulary:
            // the configured value is wrong for a staging run started from Install on Next Restart,
            // and "surface" is a word nobody outside this project knows. The literals are written
            // here, not read out of logic.js, because i18n() extracts literals - see the copy
            // table's own header - and Logic.updatingLabelOf is what a node test pins.
            text: {
                switch (popup.plasmoidItem.runningSurface) {
                case "popup":      return i18n("Updating…");
                case "background": return i18n("Updating in the background…");
                case "offline":    return i18n("Staging updates for the next restart…");
                default:           return i18n("Updating in a terminal window…");
                }
            }
            // Not for a run in this widget: the header already says "Updating…", and the log
            // under it shows where.
            visible: popup.plasmoidItem.runningSurface !== "popup"
            wrapMode: Text.WordWrap
        }

        // The way out. A terminal run that is aborted - the DEFAULT answer to the one question
        // Kempt asks, on the default configuration - never writes state.json, and only a state.json
        // change ends this pane, so without this the popup sits here for three hours with no list,
        // no Update Now and a disabled Refresh.
        // FLAT, not raised: a raised button here would read as "press this to finish the update".
        // Deliberately NOT Kirigami.LinkButton: measured on this box, that component is a
        // QQC2.Label with a MouseArea over it - no focus ring, no place in the Tab ring, no
        // animateClick, nothing that answers Space. This pane's whole problem is a keyboard left on
        // a control nobody is drawing, so its one control has to be a real one; a flat ToolButton
        // is Plasma's own low-emphasis action.
        // The icon is what makes it read as a button rather than a line of text. Pulled left by its
        // padding, so the icon lines up with the text above and below it.
        PlasmaComponents.ToolButton {
            id: checkAgainButton
            Layout.alignment: Qt.AlignLeft
            Layout.leftMargin: -leftPadding
            flat: true
            icon.name: "view-refresh"
            display: PlasmaComponents.AbstractButton.TextBesideIcon
            text: i18n("Not Updating? Check for Updates")
            // Refuses while the check it started is running, so it cannot be pressed twice into the
            // same answer. Disabled rather than hidden: this is the pane's only control, and a
            // control that leaves the screen takes the keyboard with it.
            enabled: !popup.plasmoidItem.checking
            Accessible.name: text
            Accessible.description: i18n("Asks dnf and flatpak what is pending now, instead of waiting for the timer.")
            Keys.onReturnPressed: animateClick()
            Keys.onEnterPressed: animateClick()
            onClicked: popup.plasmoidItem.checkAgain()
        }

        // A tail, so it stays at the tail. The text is replaced wholesale every two seconds, and
        // any view that keeps its own scroll position across that jumps back to the first line each
        // time - precisely useless for watching an update run. So: a plain Flickable, re-pinned to
        // the bottom whenever the content grows. `stickToBottom` is what keeps it from fighting the
        // user: scroll up to read something and it stops following, scroll back down and it
        // resumes.
        Flickable {
            id: logFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: popup.plasmoidItem.runningSurface === "popup"
            clip: true
            // Long lines wrap rather than run off the edge: a package name has no spaces, so
            // they break anywhere.
            contentWidth: width
            contentHeight: logText.paintedHeight
            boundsBehavior: Flickable.StopAtBounds

            property bool stickToBottom: true
            function pin() {
                if (stickToBottom) contentY = Math.max(0, contentHeight - height);
            }
            onContentHeightChanged: pin()
            onHeightChanged: pin()
            onMovementEnded: stickToBottom = (contentY >= contentHeight - height - Kirigami.Units.gridUnit)

            PlasmaComponents.ScrollBar.vertical: PlasmaComponents.ScrollBar { id: logScroll }

            Text {
                id: logText
                text: popup.plasmoidItem.logTail
                color: Kirigami.Theme.textColor
                // The theme's own fixed-width font, not a hardcoded "monospace": dnf output is
                // column-aligned and the user's chosen mono font is the one that will render it.
                font: Kirigami.Theme.fixedWidthFont
                width: logFlick.width - logScroll.width
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            }
        }

        Item {
            Layout.fillHeight: true
            visible: popup.plasmoidItem.runningSurface !== "popup"
        }
    }
}
