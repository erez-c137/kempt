# Kempt popup: KDE HIG / Plasma 6 interaction review

**Date:** 2026-08-26
**Reviewer role:** KDE Plasma interaction design (read-only; nothing in the repo was modified)
**Platform verified against:** Fedora 44, `plasma-workspace-6.7.4-1.fc44`, `plasma-discover-6.7.4`

---

## 0. What this review is based on

Kempt:

- `/mnt/dev_workspace/projects/kempt/README.md`
- `/mnt/dev_workspace/projects/kempt/plasmoid/contents/ui/FullRepresentation.qml`
- `/mnt/dev_workspace/projects/kempt/plasmoid/contents/ui/UpdateItemDelegate.qml`
- `/mnt/dev_workspace/projects/kempt/plasmoid/contents/ui/main.qml`
- `/mnt/dev_workspace/projects/kempt/plasmoid/contents/ui/logic.js` (`viewModel`, `collectItems`, `rowsOf`, `formatStamp`)
- `/mnt/dev_workspace/projects/kempt/docs/images/kempt-tray-popup.png` (read as an image)
- `/mnt/dev_workspace/projects/kempt/docs/research/2026-08-24-similar-tools-survey.md`
- `/mnt/dev_workspace/projects/kempt/docs/architecture.md` (state schema), `bin/kempt` (`cmd_check`, `cmd_update`), `backends/dnf.sh` (`dnf_reboot_needed`), `lib/common.sh` (`render_summary`)

Plasma 6.7.4 as shipped on this box (all of these were read, not recalled):

- `/usr/lib64/qt6/qml/org/kde/plasma/extras/BasicPlasmoidHeading.qml` - the only heading-injection API there is
- `/usr/lib64/qt6/qml/org/kde/plasma/extras/PlasmoidHeading.qml` (it is a `T.ToolBar`), `Representation.qml` (header + contentItem + footer), `PlaceholderMessage.qml`, `ListSectionHeader.qml`, `ExpandableListItem.qml`
- `/usr/lib64/qt6/qml/org/kde/plasma/plasmoid/plasmoidplugin.qmltypes` - the whole Plasmoid attached API surface
- `/usr/share/plasma/plasmoids/org.kde.plasma.vault/contents/ui/main.qml` - footer + `contextualActions`
- `/usr/share/plasma/plasmoids/org.kde.kdeconnect/contents/ui/FullRepresentation.qml` - no heading at all, actions in `PlaceholderMessage.helpfulAction`
- `/usr/lib64/qt6/qml/org/kde/plasma/private/clipboard/ClipboardMenu.qml` + `KlipperPopup.qml` - header composition and explicit `KeyNavigation`
- `/usr/lib64/qt6/qml/org/kde/bluedevil/components/ForgetDeviceDialog.qml` - KDE's destructive-confirmation pattern
- QML source recovered from the compiled applet plugins in `/usr/lib64/qt6/plugins/plasma/applets/` (`strings` on `org.kde.plasma.bluetooth.so`, `org.kde.plasma.devicenotifier.so`, `org.kde.plasma.networkmanagement.so`, `org.kde.plasma.printmanager.so` - Qt embeds the .qml text in the resource, so these are literal upstream sources)
- `/usr/libexec/DiscoverNotifier` + `/usr/share/locale/en_GB/LC_MESSAGES/plasma-discover-notifier.mo` - how Plasma's own updater words and wires "restart needed"
- `/usr/share/dbus-1/services/org.kde.LogoutPrompt.service`, `/usr/libexec/ksmserver-logout-greeter` (embedded introspection XML), `/usr/bin/plasma-shutdown`
- `/usr/share/locale/en_GB/LC_MESSAGES/plasma_applet_org.kde.plasma.systemtray.mo` - what the tray-drawn heading actually contains

Nothing was built, run, or installed. No subprocesses beyond `ls/cat/grep/sed/strings/msgunfmt`.

---

## 1. Restart: state the fact, or offer the button?

**Offer the button. Plasma's own updater does, and Kempt currently does less than the tool it replaces.**

Evidence from `/usr/libexec/DiscoverNotifier` and its catalogue - these are shipped strings on this box:

```
"Restart is required"
"Restart to apply installed updates"
"The system needs to be restarted for the updates to take effect."
"Update and Restart"          "Install Updates and Restart…"
"Update and Shut Down"        "Install Updates and Shut Down…"
"Click to restart the system"
```

and inside the binary: `needsReboot`, `RebootRequired`, `rebootPrompt`, `shutdownPrompt`, plus logind's `CanReboot` / `Reboot` / `PrepareForShutdown`. So the incumbent notifier both states the fact *and* hands the user the action, in the notification and in its own tray entry. A Kempt popup that only says "restart needed" is strictly less useful than the thing the README says it replaces.

Three constraints on how:

**a. Never reboot yourself. Call KDE's prompt.** Verified on disk, `/usr/libexec/ksmserver-logout-greeter` carries this introspection XML:

```xml
<interface name="org.kde.LogoutPrompt">
  <method name="promptLogout"/><method name="promptShutDown"/>
  <method name="promptReboot"/><method name="promptAll"/>
```

and `/usr/bin/plasma-shutdown` carries `org.kde.Shutdown` with `logout`, `logoutAndReboot`, `logoutAndShutdown`. The first family prompts (KDE's own confirmation screen, cancellable, lets sessions object and save); the second family just does it. Kempt must use `org.kde.LogoutPrompt.promptReboot` on `/LogoutPrompt`. That single choice satisfies the HIG rule about confirming destructive/irreversible actions without Kempt owning a dialog at all - the confirmation is KDE's, looks like KDE's, and honours the user's session settings. If you ever did need your own confirm, the shipped pattern is `ForgetDeviceDialog.qml`: `Kirigami.PromptDialog`, `standardButtons: NoButton`, custom footer actions where the accept button is named with the verb ("Forget Device", not "OK"), and `onOpened:` focuses **Cancel**.

**b. `Restart…` with a real ellipsis is the correct label.** KDE marks actions that lead to further interaction with `…`, and Discover's own string is `Install Updates and Restart…`. Do not write `Restart` (implies immediate) and do not write `Restart...` with three dots (see §4 wording).

**c. The container should be `Kirigami.InlineMessage`, and this is where the proposal is wrong about placement.** InlineMessage is a legitimate Plasma-side component - it is used in a shipped plasmoid, `/usr/share/plasma/plasmoids/org.kde.desktopcontainment/contents/ui/FolderView.qml` (the "too many files on the desktop" warning). Use its own `actions:` list rather than hand-rolling a `RowLayout`, so it wraps correctly at popup width. But: **a pending restart is not an "up to date" fact.** You can owe a restart *and* have twelve new updates pending (kernel installed this morning, new flatpaks published this afternoon). The proposed layout only shows the restart banner in the up-to-date state. It belongs at the top of the content area in **every** state.

**d. The data is the real problem, and it is a "fix the write path" problem.** Today `kempt check` does not know about restarts at all: `docs/architecture.md`'s schema v1 has `status`, `last_success`, `actionable`, `held_total`, `risky_pending` and per-backend items - no reboot key. `reboot_needed` exists only on a **history entry** written by `cmd_update`, and is rendered by `render_summary` in `lib/common.sh` as "Reboot: needed / not needed". Driving the banner from history would be wrong twice over:

- it keeps claiming "restart to finish installing updates" after the user has already restarted (history is a fact about the past; the banner is a claim about now);
- it says nothing when a restart is owed because of an update applied by something else - a plain `dnf5 upgrade` in a terminal, or an offline transaction harvested at boot - which is exactly the "front-end disagrees with the CLI" failure the survey lists as trust-destroying.

The truthful source already exists and is cheap: `dnf_reboot_needed` in `backends/dnf.sh` runs `dnf5 -C needs-restarting` - cache-only, no network, no stdin prompt, with the rc mapping already handled. **Amendment: have `cmd_check` write `reboot_needed: true|false` into the state file as an additive key** (same "readers must tolerate its absence" rule the schema already states for `risky_pending`), expose it as `vm.rebootNeeded`, and bind the InlineMessage to that. Also heed the survey's own ADOPT #8: `needs-restarting` has documented kernel false negatives (dnf5#2562), so treat `false` as "nothing to say" and never render an affirmative "no restart needed" line.

Wording, borrowed from the incumbent so users recognise it: title `Restart to apply installed updates`, body optional, action `Restart…`.

---

## 2. Refresh placement

### 2.1 The tray-heading idea is not achievable. This is settled, not a judgement call.

- The only API for putting your own controls in a plasmoid heading is `BasicPlasmoidHeading`'s `default property alias extraControls` (`/usr/lib64/qt6/qml/org/kde/plasma/extras/BasicPlasmoidHeading.qml`), and that whole component carries `visible: !(Plasmoid.containmentDisplayHints & PlasmaCore.Types.ContainmentDrawsPlasmoidHeading)`. In the tray, the heading and everything you put in it is gone.
- Its own docstring states the contract: *"By default, it will be invisible when the plasmoid is in the system tray, as it provides a replacement header with the same features."* The replacement is the tray's, not yours.
- The Plasmoid attached API (`plasmoidplugin.qmltypes`) exposes `contextualActions`, `internalAction()`, `setInternalAction()`, an `ActionPriority` enum with no property to set it from QML - and **no slot, list, or property for heading items**. There is no supported injection point, and an unsupported one would be a private API of `org.kde.plasma.private.systemtray` (whose `ExpandedRepresentation.qml` is AOT-compiled into `/usr/lib64/qt6/plugins/plasma/applets/org.kde.plasma.systemtray.so`, i.e. not extendable from a third-party plasmoid either way).
- What the tray heading does contain, from its own catalogue (`plasma_applet_org.kde.plasma.systemtray.mo`): `Go Back`, `More actions`, `Keep Open`, `Close popup`. So the single channel a plasmoid has into that heading is a `QAction` in `Plasmoid.contextualActions`, which lands inside the **More actions** hamburger. That is two clicks and a menu for something whose entire value is being one click.

### 2.2 What Plasma's own popups do about "rescan / refresh"

Mostly: **they do not have one.** The NetworkManager applet catalogue (`plasma_applet_org.kde.plasma.networkmanagement.mo`) contains no "Refresh", "Rescan" or "Scan" action string at all - only `Configure Network Connections…`. Its popup rescans while it is open. Bluetooth's catalogue likewise has no refresh string. The deeper convention is: **refresh on open and while open; do not make the user ask.**

Where an applet does need an action in its own header, the shipped shape is identical everywhere. Bluetooth's `Header.qml` (recovered from `org.kde.plasma.bluetooth.so`):

```qml
PlasmaExtras.PlasmoidHeading {
    contentItem: RowLayout {
        PlasmaComponents3.Switch { ... focus: root.plasmoidItem.expanded ... }   // primary, left
        Item { Layout.fillWidth: true }
        PlasmaComponents3.ToolButton {              // secondary, right
            visible: !(Plasmoid.containmentDisplayHints & PlasmaCore.Types.ContainmentDrawsPlasmoidHeading)
            text: qAction.text
            display: PlasmaComponents3.AbstractButton.IconOnly
            icon.name: "list-add-symbolic"
            PlasmaComponents3.ToolTip { text: addDeviceButton.qAction.text }
        }
        PlasmaComponents3.ToolButton { id: moreActionsButton ... Accessible.role: Accessible.ButtonMenu ... }
    }
}
```

Klipper does the same (`ClipboardMenu.qml`: `[SearchField fillWidth][icon-only "Clear History" ToolButton + ToolTip]`). Device Notifier does the same with a bulk action (`org.kde.plasma.devicenotifier.so`): `header: PlasmaExtras.PlasmoidHeading { visible: !(...ContainmentDrawsPlasmoidHeading) && mountedRemovables > 1; ToolButton { anchors.right: parent.right; icon.name: "media-eject"; text: i18n("Remove All"); Accessible.description: i18n("Click to safely remove all devices") } }`.

Note what Bluetooth does *differently* from Device Notifier and Vault: Bluetooth keeps the heading itself visible in the tray and hides only the individual buttons that the tray already duplicates. That is the pattern Kempt should copy, because Kempt's heading carries the count, which nothing else carries.

### 2.3 Verdict

**Our heading row, icon-only `ToolButton`, always visible - plus a contextual action as a second route.**

- `icon.name: "view-refresh"`, `display: IconOnly`, `text: i18n("Check for Updates")`, a `ToolTip` bound to that text, `Accessible.description`, placed after an `Item { Layout.fillWidth: true }` spacer. This is Bluetooth's `addDeviceButton` verbatim minus the visibility gate.
- **Do not** gate it on `ContainmentDrawsPlasmoidHeading`. Bluetooth can hide its button because the same action is in the tray's More-actions menu; a refresh that costs two clicks and a menu is not worth having.
- **Also** register it as a `PlasmaCore.Action` in `Plasmoid.contextualActions`. That puts it in the tray heading's More actions menu and in the tray icon's right-click menu for free, which is where a Plasma user's hand goes first. Vault ships exactly this dual arrangement: `Plasmoid.contextualActions: [ createAction ]` plus a footer button running the same action. Notifications ships the same duality (`Clear All Notifications` button, `&Configure Event Notifications and Actions…` action).
- Keep the existing `BusyIndicator`, but attach it to the button (swap or overlay) rather than adding a separate widget to the row - one spinner, at the control the user pressed.
- **Add refresh-on-open**, guarded by staleness: when `plasmoidItem.expanded` goes true and `last_success` is older than the configured interval (or ~5 minutes), fire `doCheck()`. That answers "is this number current?" before the user asks, which is why Plasma's own popups need no button. The survey's dnfdragora lesson applies: never a blocking re-index on open. Kempt's check is already async and cache-backed, so a staleness guard is enough. The text button loses nothing by becoming an icon: a demoted refresh with auto-refresh on open is a net gain in both space and truth.

**Corrected 2026-08-28, from a live panel.** The "do not gate it" bullet above rests on a premise this survey got wrong: that the only route into the tray heading is the More-actions hamburger, so the contextual action costs two clicks. Plasma 6.7 renders a *single* contextual action as an icon in the heading it draws, beside the pin and the gear - so registering `checkAction` puts a `view-refresh` icon on screen at one click, and the popup's own button underneath it is a second refresh icon. The button is now gated, but on `traysHeading && contextualActionsClaimed` rather than on the hint alone: a claim that failed means nothing is drawing the action, and the popup must keep its own way to re-check. The rest of the verdict stands, including keeping the heading itself visible for the count. Note the spinner bullet reads the other way now too - it is a sibling cell rather than attached to the button, because in the tray it is the only thing left saying a check is running.

Text button vs icon: text is only warranted when the action is the popup's point (Vault's `Create a New Vault…`). Refresh is a maintenance verb on a widget that refreshes itself on a timer. Icon.

---

## 3. Primary action: heading row, or its own row?

**Neither, strictly: put it in a footer `PlasmoidHeading`. Right-aligned, always visible.**

Reasoning, in order of weight:

1. **The heading is the row the host is allowed to take away.** Vault hides its whole action bar in the tray; Device Notifier hides its whole heading in the tray, accepting the loss of "Remove All"; Bluetooth hides individual heading buttons in the tray. Every shipped applet treats heading contents as expendable, because Plasma's contract says the container may replace the heading. `Update Now` is the one control in Kempt that must exist on every host, in every containment, forever. Putting it in a row governed by `ContainmentDrawsPlasmoidHeading` semantics is building the product's core action on the one piece of ground Plasma reserves for itself. (Today Kempt's own heading is unconditional, so it works. It works by not using the standard heading component - which is also why the popup carries the hand-rolled `traysHeading` property. One future refactor to `BasicPlasmoidHeading` and the primary action silently disappears in the tray.)
2. **`PlasmoidHeading` is a `T.ToolBar`** (read the file). Toolbar contents in Plasma are flat: `ToolButton`, `Switch`, `SearchField`. A raised, emphasised primary button is not a toolbar item. `PlasmaExtras.Representation` is a `Page` with `header`, `contentItem` and `footer`, and the footer variant of `PlasmoidHeading` renders with footer margins (`position === T.ToolBar.Footer` branches in `PlasmoidHeading.qml`). Vault uses exactly that for its primary action.
3. **KDE HIG puts the primary action at the bottom-right of the surface**, with secondary actions to its left. A footer bar gives you that for free, keeps `Update Now` pinned while a 1200-row list scrolls, and gives `Stage Offline Instead` a natural secondary position instead of floating inside a warning row in the toolbar.

Concrete shape:

```
header  :  [ 3 updates                                        ]  [↻]
content :  [ InlineMessage: restart / risky / last-run message ]
           System (dnf)      nodejs   24.19 → 24.20        [📌]
           Apps (flatpak)    Firefox  140 → 141            [📌]
footer  :  Checked 4 min ago · 1 held     [Stage Offline Instead] [ Update Now ]
```

If Erez prefers the one-row heading anyway (it does save roughly 2.5 grid units of height, and Device Notifier's "Remove All" is precedent for a bulk action living in the heading row), it is not a hard violation - but then it must be a `ToolButton` with `display: TextBesideIcon` rather than a raised `Button`, and the row must never be gated on the containment hint. My recommendation stands with the footer.

---

## 4. Problems in the proposed layout, and what is missing

**P1 - Restart banner scoped to the wrong state.** Covered in §1c: show it in both states, at the top of the content area, never inside the header toolbar (a `ToolBar` is not a message surface).

**P2 - The header toolbar is being used as a message stack.** Today `FullRepresentation.qml`'s `header:` holds five stacked rows: heading + gear, the stale explanation (line ~101), the risky warning with its own button (line ~114), the action row (line ~138), and `actionMessage` (line ~166). The proposal keeps the risky row there. Three of those are *messages*, not controls. The Plasma-correct home for each is a `Kirigami.InlineMessage` at the top of the content area (`FolderView.qml` precedent), with the risky message's `Stage Offline Instead` as one of its `actions`. That turns a four-row "toolbar" into a one-row toolbar and gives every message consistent wrapping, iconography and dismissal.

**P3 - Two competing accounts of the same run.** The proposal adds a persistent `Last update: 18 min ago · 1 package [Details ▾]` while `main.qml`'s `loadSummary()` still writes the CLI's summary header into `actionMessage`. After a run, the popup would show the same event twice in two formats. Keep `actionMessage` for immediate outcome feedback - it is the only surface that reports a **failure** ("FAILED - see <log>") - and let the persistent history line take over once it clears. One event, one line at a time.

**P4 - `Details ▾` should be `PlasmaExtras.ExpandableListItem`,** not a hand-rolled disclosure. Its docstring warns it is only for lists of ideally fewer than 10 items - fine for one "last update" row, wrong for the package list (Kempt handles 1200 rows via a flat lazy model, which is right and should stay).

**P5 - Wording.** Every KDE string on this box uses title case for buttons and a real `…`: "Forget Device", "Clear History", "Remove All", "Create a New Vault…", "Pair a Device…", "Return to Network Connections", "Install Updates and Restart…".
- `Stage offline instead` → `Stage Offline Instead`. Consider also that "offline" is dnf jargon; Discover's users are taught "Update and Restart". `Install on Next Restart` says the same thing in user language, with the tooltip carrying the dnf detail. (Naming call is yours; the capitalisation is not.)
- `i18n("Configure Kempt...")` → `Configure Kempt…` (U+2026). Three ASCII dots is the one typographic tell that a widget was not written by KDE.
- `Everything is up to date.` → drop the full stop. Compare `No paired devices` (KDE Connect), `No Vaults have been set up` (Vault). The proposal already does this - good.
- `1 held back` → `1 held`. The CLI says "Held (skipped)", the section header says "Held", the command is `kempt hold`, the tooltip already builds `heldTotal + " held"` in `viewModel`. One vocabulary.
- `3 updates` vs `logic.js`'s `countPhrase` = `"3 updates available"`. If the heading is shortened, shorten it **in `logic.js`**, because `headerText` and `tooltipMain` share that string and the node tests pin it. Do not let QML and the view model disagree about the same sentence.

**P6 - "Checked 4 min ago" needs two things it does not have.** (a) It must tick while the popup is open, or it is a lie within a minute - a `Timer` re-evaluating it. (b) `formatStamp` in `logic.js` is deliberately `Date`-free, and the comment explains why: it cannot print "Invalid Date", cannot timezone-shift, and survives the recorded corruption where two state documents get newline-joined. Do not throw that away for prettiness. Either compute the relative string in the same defensive style (parse defensively, fall back to the absolute stamp on anything unexpected), or use KCoreAddons, which is installed: `/usr/lib64/qt6/qml/org/kde/coreaddons/` exposes `formatRelativeDateTime`, `formatDuration`, `formatByteSize`. Either way keep the absolute timestamp as the tooltip - the stale banner already prints it and users compare the two.

**P7 - Keyboard: nothing at all today.** `grep -n "Keys\.\|KeyNavigation\|focus\|activeFocus" plasmoid/contents/ui/*.qml` returns zero hits across the whole widget. Plasma's own popups wire this explicitly: Bluetooth's header gives its primary control `focus: root.plasmoidItem.expanded`; Klipper wires `KeyNavigation.up/down/left/right` between search field, clear button, tab bar and list and has `Keys.onEscapePressed: requestHidePopup()`; Print Manager's `ListView` takes `focus: true`. Minimum for Kempt: focus lands on `Update Now` when the popup opens (on the refresh button when there is nothing to update), Tab moves heading → list → footer, Escape closes, and the per-row pin is reachable.

**P8 - Accessibility strings.** Icon-only buttons carry `text` + `ToolTip` (correct, matches Klipper), but no `Accessible.description`. Device Notifier sets one on its header button; Bluetooth sets `Accessible.role: Accessible.ButtonMenu` on its menu button. The pin most needs it: `UpdateItemDelegate.qml`'s own comment says "The icon is the ACTION, not the state" - a screen-reader user needs that sentence too, not just a sighted hoverer.

**P9 - Download size: do not add it.** Discover shows sizes so some users will expect them, but `dnf5 check-update` (see `dnf_parse_check_update` in `backends/dnf.sh`) does not report bytes; producing a size means a full depsolve on every check, which is precisely the dnfdragora behaviour the survey names as "the single behaviour that destroys perceived quality". If a size is ever wanted, take it from the transaction that the *update* path already resolves and show it in the run summary, not in the check state.

**P10 - Group headers.** `System (dnf)` / `Apps (flatpak)` / `Held` are rendered as a bare `PlasmaExtras.Heading level: 5, opacity: 0.8`. Plasma ships `PlasmaExtras.ListSectionHeader` for exactly this ("intended to make all listviews look coherent", with the theme's SVG separator and a trailing slot for content items). Swapping to it is a small change that makes the list read as a Plasma list, and the trailing slot is where a future per-section action would go.

**Not broken, do not touch:** `PlasmaExtras.PlaceholderMessage` for the empty/error states (correct component, and `kdeconnect`/`vault` show `helpfulAction` is available if you ever want "Check Now" there); the flat lazily-built row model; the badge and tooltip contract in `viewModel`; keeping the gear conditional on `ContainmentDrawsPlasmoidHeading` (the reasoning in the file's comment is exactly right and matches `BasicPlasmoidHeading` and `vault`).

---

## 5. Verdict and amendments

**PROPOSED wins, with amendments.** It fixes the three things that are actually wrong with CURRENT: two equal-weight buttons where there is one primary action; a dead band of vertical space between the button row and the placeholder (visible in `docs/images/kempt-tray-popup.png`); and a widget that knows a restart is owed and does not say so. But as drawn it rests on one impossible premise (the tray-heading icon), puts the primary action on the one row Plasma may take away, and scopes the restart message to the wrong state.

Five amendments, in priority order:

1. **Restart, from live data, in both states.** `Kirigami.InlineMessage` at the top of the content area whenever a restart is owed, title `Restart to apply installed updates`, one action `Restart…` calling `org.kde.LogoutPrompt.promptReboot` (never `org.kde.Shutdown.logoutAndReboot`). Source of truth: a new additive `reboot_needed` key written by `cmd_check` via the existing `dnf_reboot_needed` (`dnf5 -C needs-restarting`), **not** the history entry. Never render an affirmative "no restart needed".
2. **Primary action to a footer `PlasmoidHeading`:** `Checked 4 min ago · 1 held` left, `[Stage Offline Instead]` then `[Update Now]` right. Always visible, never scrolled away, host-independent. (`PlasmaExtras.Representation` supports `footer:`; `vault/contents/ui/main.qml` is the precedent.)
3. **Refresh becomes an icon-only `ToolButton` in our own heading row** (Bluetooth `Header.qml` shape: spacer, `view-refresh`, `ToolTip`, `Accessible.description`), *plus* a `Check for Updates` entry in `Plasmoid.contextualActions` so the tray's More-actions menu and the icon's right-click menu both carry it, *plus* refresh-on-open behind a staleness guard. Drop the tray-heading idea: there is no API, and `BasicPlasmoidHeading`'s `extraControls` is hidden in the tray by design.
4. **Get the messages out of the toolbar.** Stale explanation, risky/offline recommendation and the post-run summary line become a message area at the top of the content (InlineMessage with `actions:` for the offline one). The header keeps the count and the refresh icon, nothing else.
5. **Strings, keyboard, a11y pass.** Title-case buttons and real `…`; `1 held` not `1 held back`; drop the placeholder's full stop; shorten the count phrase in `logic.js` rather than in QML; relative time that ticks with the absolute stamp as tooltip and `formatStamp`'s defensive habits intact; `focus:` on the primary action when expanded, `KeyNavigation` header → list → footer, Escape closes; `Accessible.description` on every icon-only button, especially the pin.

Optional sixth, cheap: `PlasmaExtras.ListSectionHeader` for the three group headers, and `PlasmaExtras.ExpandableListItem` for the `Details ▾` row.
