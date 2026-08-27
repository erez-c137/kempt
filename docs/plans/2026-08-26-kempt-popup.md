# Kempt Popup Redesign (Plan 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The popup tells the truth a person needs in the first second (is it clean, as of when, does it need a restart, what changed last) and offers exactly one primary action. Today it shows a greyed-out primary button in the up-to-date state, a CLI summary header with an ISO timestamp as its post-run line, and nothing at all about a restart that the CLI already knows is owed.

**Provenance:** founder review 2026-08-26 (the ISO line and the button row questioned), a six-persona simulated user panel (`~/scratch/kempt-popup-panel/user-panel.md`) and a Plasma HIG review that read Plasma 6.7.4's own plasmoids off this box (`~/scratch/kempt-popup-panel/hig-review.md`). Copy both into `docs/research/2026-08-26-popup-panel/` as Task P0 so the reasoning survives `~/scratch` cleanup.

**Decisions (founder, 2026-08-26):** Restart button = YES (opens KDE's own prompt, never automatic). Refresh = icon. Persistent last-update line = YES. Primary action = footer (HIG reviewer's evidence, see below).

**Hard constraints (repeat in every dispatch):** user-level only - never pkexec/sudo/dnf writes; the test suite runs serially (`tests/qml/safe_probe.py` for probes, never a fan-out); one heavy job on this box at a time; throwaway files in `~/scratch/`; no em dashes in any user-facing string or doc; no AI attribution in commits; plain conventional commit subjects; state schema v1 stays backward compatible (additive keys only, readers tolerate absence); the widget stays THIN (all knowledge in the CLI, all derivation in `logic.js`, all commands through `Executor.qml`).

---

## Layout (directive)

Both states share one skeleton: `PlasmaExtras.Representation` with `header`, `contentItem`, `footer`.

```
header  : [ 3 updates available                              ] [↻]
content : InlineMessage stack (only the ones that apply, in this order):
            ⚠ Restart to apply installed updates          [Restart…]
            ⚠ This includes a kernel update. Restart when it finishes.   [Install on Next Restart]
            ⓘ <stale reason> (last successful check: <stamp>)
            ✓ Updated 1 package in 38s  /  ✗ Update failed: <first line>  [Show Log]   (transient, post-run)
          System (dnf)                                  <- PlasmaExtras.ListSectionHeader
            nodejs     2:24.19.0-1nodesource → 2:24.20.0-1nodesource    [📌]
          Apps (flatpak)
            Firefox    140 → 141                                        [📌]
          Held
            kernel     6.15.1 → 6.15.3                                  [📌]
          Last update 18 min ago · 1 package                        [▾]   <- ExpandableListItem, expands to the history entry's package list
footer  : Checked 4 min ago · 1 held                          [ Update Now ]
```

Up-to-date state: header `Up to date`; content = InlineMessage stack (restart, stale) + `PlaceholderMessage` `Everything is up to date` (no full stop; when something is held the placeholder is NOT shown, the Held group is, so the state is never a lie by omission) + the Last update row; footer `Checked 4 min ago · 1 held` and **no Update Now button** (hidden, not disabled). Updating state: unchanged from today (log tail for the popup surface, one-line notice otherwise).

Why footer and not the heading row for the primary action: Plasma's contract lets the containment replace the heading (`ContainmentDrawsPlasmoidHeading`), every shipped applet treats heading contents as expendable, `PlasmoidHeading` is a `ToolBar` (flat controls only), and the KDE HIG puts the primary action bottom-right. `org.kde.plasma.vault` is the precedent (`footer:` with its primary button). A footer also keeps Update Now visible while a long list scrolls.

Why Refresh is on OUR heading row and not the tray's: there is no API. `BasicPlasmoidHeading.extraControls` is hidden in the tray by design, `Plasmoid` exposes no heading slot, and the tray's ExpandedRepresentation is compiled into the systemtray plugin. The shipped shape is Bluetooth's `Header.qml`: spacer, icon-only `ToolButton` (`view-refresh`), `text: i18n("Check for Updates")`, ToolTip bound to it, `Accessible.description`. NOT gated on the containment hint. Additionally registered as a `PlasmaCore.Action` in `Plasmoid.contextualActions` so the tray's "More actions" menu and the icon's right-click menu carry it for free (`org.kde.plasma.vault` precedent).

---

## Tasks

### P0 - Research provenance (docs only)
- [x] Copy the two panel reports into `docs/research/2026-08-26-popup-panel/` (`user-panel.md`, `hig-review.md`), add a 10-line `README.md` there with the decisions above and links.

### P1 - CLI: live `reboot_needed` in the state file (fix the data, not the surface)
- [x] `cmd_check` writes an additive `reboot_needed: true|false` into state JSON using the existing `dnf_reboot_needed` (cache-only `dnf5 -C needs-restarting`, no network, no stdin). History keeps its own `reboot_needed` (a fact about that run); the state key is the fact about NOW, so it clears on its own after a restart and also turns on when a plain `sudo dnf5 upgrade` in a terminal owed one.
- [x] Schema doc: `docs/architecture.md` state schema table gains the key with the rule "readers must tolerate its absence; `false` means nothing to say, never render 'no restart needed'" (needs-restarting can fail to compute a verdict at all, which the repo's own rc-1-with-empty-stdout case demonstrates). **Correction, 2026-08-26:** this bullet originally cited dnf5#2562 for "known kernel false negatives". Both tracker links the claim inherited from the 2026-08-24 survey were fetched and neither supports it - dnf5#2562 is a sudo/D-Bus report about `--services`, and RHBZ 2137935 is "dnf needs-restarting always true", a fixed false-POSITIVE bug in dnf4. The rule stands on the repo's own executed evidence instead; do not ship either citation.
- [x] `kempt summary` unchanged. `kempt check` cost: one extra cache-only dnf5 call; measure and record it in the commit body.
- [x] Tests: state contains the key for both values (use the dnf echo seam), corrupt/missing key tolerated by `viewModel` (node test), fixture `state-reboot-needed.json` added with MANIFEST provenance.

### P2 - logic.js: view model for the new surfaces (node-tested, engine-agnostic)
- [x] `vm.rebootNeeded` (bool; false when absent).
- [x] `vm.footerText`: `Checked <relative> ago` joined with ` · N held` when held > 0. Relative time computed in `logic.js` in the same defensive style as `formatStamp` (never "Invalid Date", never a timezone shift, falls back to the absolute stamp on anything unexpected); absolute stamp exposed as `vm.footerTooltip`. Ticks: a 30 s `Timer` in the popup re-evaluates while expanded.
- [x] `countPhrase` shortened in `logic.js` (shared by header and tooltip; node tests pinned): `3 updates available` stays as is unless width forces it; do not fork the string in QML.
- [x] `lastRunOf(historyJson)`: `{ when, updatedCount, failed, items:[{name,from,to}], logPath, rebootNeeded }` from `kempt summary --json` if it exists, else from the newest history file read through `kempt history --json`/`--last` (check which exists; if neither, add `kempt summary --json` to the CLI as the smallest addition and document it).
- [x] Post-run transient line: `Updated N packages in Ns` / `No package changes` / `Update failed: <first stderr line>` (with `Show Log`). Replaces the CLI summary header verbatim. Rule: while the transient line is visible the persistent Last update row is hidden (one event, one line at a time); once the transient clears (popup closed or next check), the persistent row shows.
- [x] Copy table (all strings live in one place, node-tested): `Up to date`, `Everything is up to date`, `Restart to apply installed updates`, `Restart…` (U+2026), `Check for Updates`, `Update Now`, `Install on Next Restart` (tooltip: `Applies the update during a restart, so nothing changes underneath your running desktop.`), `This includes a kernel update. Restart when it finishes.` (when `akmod-nvidia`/`nvidia` is in `risky_pending`: `This includes a kernel update and the NVIDIA driver. Restart when it finishes.`), `N held` (never "held back"), `Last update <relative> · N packages`, `Show Log`, `Configure Kempt…` (real ellipsis). Title case for buttons, sentence case for messages.

### P3 - QML: header / message area / list / footer
- [x] `header`: our `PlasmoidHeading` with `Heading` (vm.headerText) left, spacer, Refresh `ToolButton` right (BusyIndicator overlays or replaces the icon while a check runs; one spinner only). Gear stays conditional on `ContainmentDrawsPlasmoidHeading` exactly as today.
- [x] `Plasmoid.contextualActions` gains `Check for Updates` (same `doCheck()` as the button).
- [x] Refresh-on-open: when `expanded` turns true and `last_success` is older than the configured interval (or 5 min, whichever is smaller), call `doCheck()`; never a blocking call; never more than one in flight (Executor already serializes).
- [x] Content top: `Kirigami.InlineMessage` per message with `actions:`; restart message `type: Warning`, action `Restart…` runs (through the action Executor) `dbus-send --session --dest=org.kde.LogoutPrompt --type=method_call /LogoutPrompt org.kde.LogoutPrompt.promptReboot` (service is D-Bus activatable: `/usr/share/dbus-1/services/org.kde.LogoutPrompt.service`). NEVER `org.kde.Shutdown.logoutAndReboot`. Failure to reach the prompt shows in the message's own text (`Could not open the restart prompt.`), never silent. Shown in EVERY state when `vm.rebootNeeded`.
- [x] Risky/offline message: moves out of the header into the stack; `Install on Next Restart` is its action (same `runOffline()` as today). Stale explanation: `type: Information` in the stack.
- [x] Group headers become `PlasmaExtras.ListSectionHeader`. Version strings stay FULL and untruncated (power users compare epoch/vendor tags; two machines are compared by eye).
- [x] Last update row: `PlasmaExtras.ExpandableListItem` (title `Last update 18 min ago · 1 package`, subtitle reboot/failed if so, expanded content = the package list from `lastRunOf`, plus `Show Log` action). Hidden while the transient post-run line is visible.
- [x] `footer`: `PlasmoidHeading` footer variant; `Label` (vm.footerText, tooltip absolute stamp) left, spacer, `Update Now` `Button` right (icon `system-software-update`), `visible: vm.actionable > 0 && !updating`.
- [x] Remove: the old button row, the `actionMessage` ISO line, the duplicate "Up to date" heading in the empty state (header keeps `Up to date`; the placeholder carries the sentence; never both at once with the same words - node test pins that headerText and emptyStateText are not equal).

### P4 - Keyboard and accessibility (today: zero `Keys.`/`focus` in the widget)
- [x] Focus lands on `Update Now` when the popup opens (on Refresh when there is nothing to update). Tab order: Update Now, list rows (pin reachable), message actions, Refresh. `Keys.onEscapePressed` closes the popup (Klipper precedent).
- [x] `Accessible.description` on every icon-only button (Refresh, pin: reuse the pin's existing `text`), `Accessible.role: Button` where needed. Restart/stale/risky messages announce via `Accessible.name` on the InlineMessage.
- [x] Probe: focus item after expand for both states; tab sequence; Escape closes.

### P5 - Tests, docs, install
- [x] Node tests for every P2 function and the copy table; QML probes for both states and the message stack (with the fixtures: pending, pending+risky, up-to-date, up-to-date+held, reboot-needed, stale, post-run success, post-run failure); screenshot probe if the kit supports it, else structural.
- [x] Docs: `docs/usage.md` popup section rewritten with the new anatomy (annotated ASCII, both states), the restart behaviour (`Restart…` opens KDE's own prompt; nothing restarts on its own; if you never press it, the updates are still applied), refresh-on-open, `Install on Next Restart` naming; README screenshot retaken by the founder (note as an owed item, do not fake). CHANGELOG Unreleased. `docs/ROADMAP.md`: add to v1.x "Remind me later / tonight / Wi-Fi only" (panel finding #2), "download size next to Update Now, from the update transaction, never from check" (finding #1 and HIG P9), "spoken result after an action" (a11y).
- [x] `kpackagetool6 -t Plasma/Applet -u plasmoid`; leave the hicolor icon alone; do not restart plasmashell (tell the founder the popup needs `plasmashell --replace` or a re-login to pick up QML changes if it does not on its own).

### Review gates
Two-stage per task (spec reviewer, then quality reviewer with an EXECUTED probe per claim). Founder visual gate at the end: tray popup in both states, screenshot for the README.

---

## Founder amendments, 2026-08-26 (in scope for this run, not a follow-up)

### A1 - The restart reminder must be something a user can turn off (P1/P2/P3 + settings page)

- New config key `restart_reminder`, default `true`, owned by the CLI like every other key:
  the `kempt_default` table in `lib/common.sh`, the key table in `docs/configuration.md`, the
  man page, and the settings section of `docs/usage.md`.
- The settings page gains a checkbox **Remind me when a restart is needed**, wired with the same
  read / compare / write pattern as `include_flatpak`, using the durable-write form, with node
  and probe tests.
- **On:** the `Kirigami.InlineMessage` carrying `Restart…` shows in every state as planned, and
  it has a close button. Closing it hides it for the rest of this plasmashell session. Nothing
  is persisted; document that explicitly so the behaviour is not mistaken for a bug.
- **Off:** no message, no button, no nag. The footer status line still carries the two-word fact
  `· restart pending`, so the popup never lies. That is a fact, not a reminder.
- The footer text derivation in `logic.js` is node-tested for all three cases: reminder off,
  reminder on, reminder on but dismissed this session.
- The desktop notification the CLI already sends after a run (which mentions a needed reboot) is
  unchanged.

### A2 - The P5 documentation sweep is explicit, not best-effort

- `docs/ROADMAP.md`: the **Now** section is rewritten to reflect what is actually shipped at
  HEAD (the CLI, the tray widget, the six-tooth icon, `kempt log`, durable settings writes, and
  this popup redesign), with the remaining v1.0 items listed truthfully: founder visual gate,
  README screenshot, merge to main, public flip. **v1.x** gains the three panel items already in
  the plan, plus "restart reminder dismissal persisted across sessions" if the dismissal stays
  session-only.
- Sweep, and make truthful: `README.md` (feature list, commands, screenshot note),
  `docs/usage.md` (popup anatomy in both states, the settings section with the new key, the log
  section already there), `docs/configuration.md`, `docs/architecture.md` (the `reboot_needed`
  state key, and where the popup gets its last-run data), `docs/man/kempt.1`, `CHANGELOG.md`
  Unreleased, and `docs/specs/2026-08-24-kempt-design.md` (a short "Plan 3 deltas" note in the
  same shape as the existing Plan 2 deltas).
- Grep every doc for the strings this plan retires and fix them: `Stage offline instead`,
  `held back`, the old two-button row description, and the ISO summary line.

### A3 - P6: a shorter code of conduct (own commit, `docs: shorter code of conduct`)

The Contributor Covenant was excessive for a project this size. `CODE_OF_CONDUCT.md` is replaced
with a short document, and every reference to the old template or to its section anchors is updated
so nothing points at text that no longer exists.

---

## Progress, 2026-08-27 (checkbox audit)

The boxes above were ticked against the code at 8441040, not against the commit log: every
ticked item was grepped in the file it claims to live in. What that audit found:

- **P0, P1, P2, P3 are done.** Twenty-one boxes, each with a named home:
  `docs/research/2026-08-26-popup-panel/`, `cmd_check`'s `reboot_needed` write, the
  `docs/architecture.md` schema row, `logic.js`'s `COPY` table and its six derivations,
  and `FullRepresentation.qml`'s header / message stack / list / footer.
- **A1 (the restart-reminder checkbox) was mid-flight** and is finished as its own commit.
  The settings page carried the control, the read and the write, and a comment describing
  a guard for a `kempt` too old to know the key - but not the guard itself. The five
  probe assertions written for it were failing, which is the honest way that was found.
- **P4 (keyboard and accessibility) had not started.** Zero `Keys.` and one
  `Accessible.description` in the whole widget.
- **P5 is half done.** The tests are there; the documentation sweep (A2) is not.

## Closed, 2026-08-27

All twenty-six boxes are ticked and the suite is green: **17 files, 1932 assertions,
0 failures**, run serially, probes one at a time under `safe_probe.py`, nothing left
resident afterwards. The widget is 1221 of those (640 derivation rules under node, 581
across five QML probes). `kpackagetool6 -t Plasma/Applet -u plasmoid` has run and
`diff -rq` between the repo and the installed package is empty.

What the last stretch changed beyond the plan's own words:

- **A1's guard was written to match its comment.** The settings page described a guard
  for a `kempt` too old to know `restart_reminder` and did not have one. Five probe
  assertions were failing on it; a six-mutation pass now stands behind the fix.
- **P4 shipped the plan's INTENT, not its literal tab order.** Qt's focus chain is
  creation order, and the plan's sequence would need `KeyNavigation` links into a list
  delegate that comes and goes with scrolling and into the private buttons inside a
  Kirigami InlineMessage. The measured ring is Update Now, Refresh, Configure, the
  message actions, every pin in list order, Last update, and back. It is asserted stop
  by stop with real Tab keys in an offscreen window, and the reasoning is in 9540705.
- **Measuring the keyboard found two real defects**, both fixed: a ListView builds only
  the delegates near its viewport, so 7 of 24 pins could not be reached by keyboard at
  all; and `reuseItems` left recycled rows in their original place among the view's
  children, which threw the user out of an 80-package list and back through the header.
- **The vocabulary sweep reached the settings page too**: "Held back" became "Held" in
  three places, and the two password buttons that open an authentication dialog got a
  real ellipsis.

Owed, and founder-only: the visual gate on real hardware, and the README screenshot,
which still shows the pre-redesign popup and says so on the page.
