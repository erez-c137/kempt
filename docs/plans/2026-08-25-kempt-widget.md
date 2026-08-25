# Kempt Widget (Plan 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Plasma 6 panel widget - the product's face. A panel icon whose badge is always truthful, a popup with the pending/held lists and one-click Update Now, a settings page over `kempt config`, and the offline recommendation surfaced where the user can act on it.

**Architecture:** The widget is THIN. It shells out to the `kempt` CLI for everything (the frozen contracts: state schema v1 from `kempt check` stdout, `kempt run`, `kempt config get/set`, `kempt hold/unhold/holds`, `kempt summary`) and contains zero package-manager knowledge. All command execution goes through ONE component (`Executor.qml`) wrapping the deprecated-but-current `Plasma5Support.DataSource` executable engine - async, serialized, hard per-call timeouts, so plasmashell can never freeze on us (the Apdatifier lesson). All parsing/derivation lives in `contents/ui/logic.js`, written in ENGINE-AGNOSTIC JavaScript (no Qt APIs) so it is unit-testable with node, which exists on this box - the QML layer binds to logic.js outputs and stays declarative.

**Code-completeness contract:** contracts and tricky mechanics below are code-complete (metadata, logic.js API + core functions, Executor.qml, install arm, tests). UI layout sections are DIRECTIVE specs - exact behavior and element inventory, layout details left to the implementer within Plasma/Kirigami idiom. The review gates hold the line either way; "looks right" is verified in the founder's morning visual gate, not overnight.

**Hard overnight constraints (repeat in every dispatch):** user-level only - NEVER pkexec/sudo/dnf; never modify the panel or plasmashell config; `kpackagetool6` install/upgrade of the package IS allowed (user-scoped, does not place the widget on any panel) but only in Task W5; plasmoidviewer is NOT installed (needs plasma-sdk = root) - do not install it; probe for `qml`/`qmllint` and use them if present, otherwise structural verification is `qmljs`-free: node tests + careful review. Real HOME artifacts limited to `~/.local/share/plasma/plasmoids/io.github.erez_c137.kempt` (W5 only, removable with `kpackagetool6 -t Plasma/Applet -r io.github.erez_c137.kempt`).

**Spec:** `docs/specs/2026-08-24-kempt-design.md` §Layer 2. Two spec deltas this plan introduces (sync the spec in W5): (1) event-driven refresh is implemented as a 30s mtime POLL of `/var/lib/rpm` + `/var/lib/flatpak` + the state file (KDirWatch is not reachable from pure QML; a 30s stat costs nothing and meets "within seconds" for human purposes); (2) passwordless STATUS cannot be displayed - `/etc/polkit-1/rules.d` is 0750 root:polkitd, unreadable as the user (WP5 lesson) - so the settings page offers Enable/Disable actions with explanatory text and never claims current state.

---

## File Structure

```
plasmoid/
├── metadata.json
└── contents/
    ├── ui/
    │   ├── main.qml                  # PlasmoidItem root: state machine, timers, Executor instance
    │   ├── CompactRepresentation.qml # panel icon + badge
    │   ├── FullRepresentation.qml    # popup
    │   ├── UpdateItemDelegate.qml    # one pending/held row incl. pin toggle
    │   ├── Executor.qml              # THE one DataSource wrapper
    │   └── logic.js                  # pure JS: parse + derive (node-testable)
    └── config/
        ├── config.qml                # one category: General
        └── main.xml                  # KConfig skeleton (no real keys - config lives in `kempt config`)
    # configuration page:
    └── ui/configGeneral.qml
tests/test_widget_logic.sh            # node-driven tests for logic.js
tests/fixtures/state-*.json           # captured `kempt check` outputs (real + crafted)
```

---

### Task W1: Package skeleton, logic.js + node tests, install arm

**Files:** Create `plasmoid/metadata.json`, `plasmoid/contents/ui/logic.js`, minimal `main.qml`/`CompactRepresentation.qml`/`FullRepresentation.qml` stubs, `plasmoid/contents/config/{config.qml,main.xml}`, `tests/test_widget_logic.sh`, fixtures; Modify `install.sh`, `tests/test_install.sh`.

- [ ] **Step 1: metadata.json** (verbatim):
```json
{
    "KPlugin": {
        "Id": "io.github.erez_c137.kempt",
        "Name": "Kempt",
        "Description": "One-click system updates with a truthful badge",
        "Icon": "system-software-update",
        "Category": "System Information",
        "Authors": [{ "Name": "Erez Avital" }],
        "License": "MIT",
        "Version": "0.1.0",
        "Website": "https://github.com/erez-c137/kempt"
    },
    "X-Plasma-API-Minimum-Version": "6.0",
    "KPackageStructure": "Plasma/Applet"
}
```

- [ ] **Step 2: TDD logic.js via node.** Write `tests/test_widget_logic.sh` FIRST (bash harness sourcing tests/lib.sh conventions; each case runs `node -e 'const L=require(...)/...'`) - since logic.js must load in both QML (`.import`-free plain functions attached to a `var Logic = {...}` or plain top-level functions) and node, structure it as: plain top-level functions + a trailing CommonJS export guard:
```js
// logic.js - pure derivation layer. NO Qt APIs. Loaded by QML (import "logic.js" as Logic)
// and by node (tests) via the guard at the bottom.

function parseState(text) {
    // stdin contract from `kempt check` (state schema v1):
    // empty/whitespace text => null ("no data - keep last known", NEVER zero updates)
    // invalid JSON => null; valid => the object
}

function viewModel(state, updating) {
    // state: parsed schema-v1 object or null; updating: bool
    // returns { iconState: "updating"|"error"|"stale"|"updates"|"uptodate"|"unknown",
    //   badgeText: ""|String(actionable), badgeVisible, tooltipMain, tooltipSub,
    //   headerText, sections: [{title, items:[{name, from, to, held, backend}]}],
    //   heldItems: [...], riskySummary: ""|"N session-critical pending (fam1, fam2, ...)",
    //   staleReason: ""|error string, lastSuccessText }
    // Rules (each one is a test):
    //  - null state + !updating => "unknown", no badge, tooltip says no data yet
    //  - actionable 0 + held>0 => "uptodate" icon, tooltip notes "N held" (spec Holds promise)
    //  - badge cap: RATIFIED at 999+ during W5, not 99 - a box left alone a few weeks routinely
    //    has two or three hundred pending, so 99 would be vague in the ORDINARY case. The
    //    tooltip and the popup header are never capped. (spec §Layer 2 carries the same note.)
    //  - status stale => "stale", badge shows LAST KNOWN actionable, tooltipSub carries
    //    "last successful check: <last_success>" or "never"
    //  - version display: newestOf() both sides (installonly comma-sets render newest)
    //  - backends with enabled:false contribute nothing and render no empty section
    //  - riskySummary derives families exactly like the CLI: strip at first '-' or '.',
    //    unique, max 4 shown then ", ..."
}

function newestOf(versionSet) { /* "a,b,c" -> "c" ; plain -> itself ; "?" -> "?" */ }
function familiesOf(names, max) { /* shared by riskySummary */ }

if (typeof module !== "undefined") { module.exports = { parseState, viewModel, newestOf, familiesOf }; }
```
Fixtures: capture a REAL `kempt check` output into `tests/fixtures/state-live.json` (stub-sandboxed, like the CLI tests do) plus crafted variants: stale-with-last_success, held-only, flatpak-disabled, risky-heavy (20 names), empty-string, garbage, schema-v0 (missing risky_pending - must not throw). Every rule above = at least one assertion. Suite hookup: the test file must run under `tests/run_tests.sh` and SKIP LOUDLY (ok-line, not failure) if node is absent.

- [ ] **Step 3: minimal QML stubs** - main.qml as `PlasmoidItem` with compact/full representations wired but showing placeholder text; config.qml/main.xml minimal valid. Goal: the package is structurally installable; W2/W3 fill it.

- [ ] **Step 4: install.sh widget arm** - real mode: after the CLI symlinks, `kpackagetool6 -t Plasma/Applet -i "$ROOT/plasmoid" 2>/dev/null || kpackagetool6 -t Plasma/Applet -u "$ROOT/plasmoid"` (install-or-upgrade, user-level, no auth) with a clear echo; skip with a warning if kpackagetool6 absent. `--destdir`: copy the tree to `$DESTDIR$HOME/.local/share/plasma/plasmoids/io.github.erez_c137.kempt`. `--uninstall`: `kpackagetool6 -t Plasma/Applet -r io.github.erez_c137.kempt || true` (+ staged variant removes the copied tree). REAL MODE STILL NOT RUN in tests - destdir + echo seams only; extend test_install.sh (staged tree contains metadata.json + main.qml; uninstall removes it; echo mode shows the kpackagetool command).
- [ ] **Step 5:** suite ALL PASS; commit `feat(widget): package skeleton, logic layer + node tests, install arm`

### Task W2: Executor + live state + panel icon

**Files:** Create `Executor.qml`; rewrite `main.qml`, `CompactRepresentation.qml`.

- [ ] **Step 1: Executor.qml** (verbatim - this is the component the whole widget's safety rests on):
```qml
// The ONE place commands run. Serialized queue, hard per-call timeout, always async.
// Wraps the deprecated Plasma5Support executable engine (swap point when KDE drops it).
import QtQuick
import org.kde.plasma.plasma5support as Plasma5Support

Item {
    id: root
    property int defaultTimeoutMs: 30000

    // run("kempt check", 120000, function(stdout, stderr, rc) {...})
    function run(cmd, timeoutMs, callback) {
        queue.push({ cmd: cmd, timeoutMs: timeoutMs || defaultTimeoutMs, callback: callback,
                     tag: "#kempt" + (++serial) });
        pump();
    }

    property var queue: []
    property var current: null
    property int serial: 0

    function pump() {
        if (current || queue.length === 0) return;
        current = queue.shift();
        // unique trailing comment defeats DataSource's same-source dedup
        current.source = current.cmd + " " + current.tag;
        killTimer.interval = current.timeoutMs;
        killTimer.restart();
        engine.connectSource(current.source);
    }

    function finish(stdout, stderr, rc) {
        killTimer.stop();
        var job = current; current = null;
        if (job && job.callback) job.callback(stdout || "", stderr || "", rc);
        pump();
    }

    Plasma5Support.DataSource {
        id: engine
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            if (!root.current || source !== root.current.source) { disconnectSource(source); return; }
            disconnectSource(source);
            root.finish(data.stdout, data.stderr, data["exit code"]);
        }
    }

    Timer {
        id: killTimer
        repeat: false
        onTriggered: {
            if (!root.current) return;
            engine.disconnectSource(root.current.source);
            root.finish("", "timeout after " + interval + "ms", 124);
        }
    }
}
```

- [ ] **Step 2: main.qml state machine.** Properties: `state` (parsed object or null), `updating`, `vm` (re-derived via `Logic.viewModel` on every change). Flows:
  - `doCheck()`: executor.run("kempt check", 120000, ...) → `Logic.parseState`; null stdout with rc 0 = KEEP previous state (the spec's empty-stdout caller rule); rc != 0 with valid stdout = still use the stdout (answer-first contract).
  - Check timer: interval from `kempt config get refresh_interval_min` (read once at load and after every settings apply) * 60000; fires doCheck.
  - Watcher timer, 30s: `stat -c %Y /var/lib/rpm /var/lib/flatpak ~/.local/state/kempt/state.json 2>/dev/null | tr '\n' ' '` → if the concatenated string changed since last poll, doCheck() (this is the stale-badge killer; a change from ANY source refreshes within 30s).
    - **AS BUILT (W4 review finding B-5, and this block is superseded):** the config file is watched too (it is the settings page's only back-channel), every path is padded (`stat -c %Y "$p" 2>/dev/null || echo 0` per path) so a missing one cannot shift the fields, and the stamp is compared FIELD-WISE. Comparing the whole string was wrong in a way that only showed up during a real transaction: `/var/lib/rpm` is rewritten continuously throughout a dnf run, so "something changed" was true every 30 seconds and the widget declared the run finished a few seconds in. Only the state-file field ends the updating state; while a run of ours is in flight a package-database change starts no check at all. See spec §Layer 2.
  - On load: doCheck.
- [ ] **Step 3: CompactRepresentation** - Kirigami.Icon bound to vm.iconState mapping: uptodate `update-none`, updates `update-low`, STALE keeps a calm presentation (same icon as its last-known contents, badge preserved, tooltip carries the stale reason + last_success - a transient repo flap must never panic the panel; this is the adjudicated resolution of the plan-vs-architecture.md conflict, architecture.md wins), true error/unknown-CLI `update-high` + emblem-warning, updating shows a small BusyIndicator overlay, unknown `update-none` dimmed. Badge: small rounded Rectangle bottom-right, text vm.badgeText, visible vm.badgeVisible, highlight color, hidden when panel too small per Plasma idiom. Tooltip: mainText/subText from vm. Click toggles the popup (default PlasmoidItem behavior).
- [ ] **Step 4:** if `qml`/`qmllint` exist (probe), lint every .qml; else document the gap for the morning gate. **W5 result: neither exists on this box** (they ship in `qt6-qtdeclarative-devel`, which is not installed and would need root) - the standing substitute is the PySide6 compile gate in `tests/test_widget_logic.sh` plus the four executing probes in `tests/test_widget_qml.sh`. Node suite green. Commit `feat(widget): executor, live state, panel icon with truthful badge`

### Task W3: The popup

**Files:** rewrite `FullRepresentation.qml`, create `UpdateItemDelegate.qml`.

Directive spec (behavior binding, layout free within Plasma idiom):
- [ ] Header: "N updates available" (or "Up to date" / "Checking..." / stale banner with vm.staleReason + lastSuccessText). Row of buttons: **Update Now** (runs `kempt run`; rc 4 → inline error label with the CLI's remedy text; rc 3 → "an update is already running"), **Refresh** (doCheck with spinner), and when vm.riskySummary is non-empty an inline warning chip: the summary text + a **Stage offline instead** button → executor.run("setsid kempt update --surface=offline >/dev/null 2>&1 &", 10000) then enter updating state. Gear icon → `Plasmoid.internalAction("configure").trigger()`.
- [ ] Sections list (ListView, scrollable, popup height capped per Plasma idiom): System (dnf) / Apps (flatpak) from vm.sections; each row = UpdateItemDelegate: name, `from → to` (already newest-rendered by logic.js), and a PIN TOGGLE (ToolButton, icon `pin`) → `kempt hold <backend>:<name>` / `unhold` then doCheck (row moves between sections on refresh; this is the spec's Holds UI promise). Held section below, visually muted, rows show the waiting version + unpin toggle.
- [ ] Updating state: entered on Update Now / stage-offline / detecting `status==updating`-like conditions is NOT in schema - so: enter on our own action OR when the watcher sees state.json change while a run lock exists is overkill - keep it action-scoped. While updating: buttons disabled, BusyIndicator, and if `kempt config get surface` == popup, a monospace log tail pane: executor.run("tail -n 25 " newest log, every 2s) (newest log = `ls -1t ~/.local/state/kempt/logs/*.log | head -1` via executor once). Exit updating when state.json mtime changes (the CLI self-refreshes at run end) → doCheck → show a transient "last run" line: first line of `kempt summary`.
- [ ] Empty/edge states each get a friendly line (no data yet; all held; flatpak disabled shows no Apps section).
- [ ] Node tests for any new logic.js helpers (e.g. newest-log parsing stays in QML? no - put pure string logic in logic.js and test it). Commit `feat(widget): popup with pending/held lists, update flow, offline recommendation`

### Task W4: Settings page

**Files:** create `configGeneral.qml`; wire `config.qml`.

Directive spec:
- [ ] On open: parallel executor reads of `kempt config get include_flatpak / auto_accept / surface / refresh_interval_min` + `kempt holds`. Controls: two checkboxes, surface radio (Terminal/In-popup/Background/Offline), refresh-interval SpinBox (minutes, min 15), holds list with per-row remove (runs `unhold`, refreshes list). Auto-accept OFF disables the non-Terminal radios AND shows the reason inline (spec promise); if a disabled one was selected, snap to Terminal.
- [ ] Apply: write ONLY changed keys via `kempt config set`; then main.qml re-reads the check interval. (KConfig keys in main.xml stay empty - `kempt config` is the single source of truth; the page sets `cfg_`-less manual apply per Plasma config-page idiom with `saveConfig`-triggering handled via the standard configurationRequired pattern - implementer picks the clean Plasma 6 way, reviewers verify no plasmoid-local shadow settings exist.)
- [ ] Passwordless: explanatory paragraph (what it grants, active+local scoping) + two buttons Enable... / Disable... running the CLI commands (auth dialog appears - user-initiated, correct); status is NOT displayed (unreadable as user - say so in a subtle hint). Buttons show the command's stdout/stderr tail as a result line.
- [ ] Commit `feat(widget): settings page over kempt config`

### Task W5: Integration, local install, morning gate

- [ ] Probe + record: `qml`/`qmllint` availability and results over all .qml (fix findings).
- [ ] Real user-level install: `kpackagetool6 -t Plasma/Applet -i plasmoid` (or -u). Verify with `kpackagetool6 -t Plasma/Applet -l | grep io.github.erez_c137.kempt`. This does NOT touch the panel.
- [ ] Spec sync (§Layer 2): mtime-poll mechanism note; passwordless-status-unreadable note; anything W1-W4 changed.
- [ ] Docs: usage.md widget stub → real section (add to panel, what each state means, settings); README screenshot placeholder stays until the founder captures one; CHANGELOG Unreleased gains the widget.
- [ ] Append MORNING VISUAL GATE items to Plan 1's live checklist section (founder-gated): W-1 right-click panel → Add Widgets → search Kempt → add. W-2 badge shows the real actionable count; hover tooltip truthful. W-3 popup lists match `kempt check` JSON; pin toggle moves a row to Held and back. W-4 Update Now end-to-end from the widget (real auth dialog). W-5 settings round-trip (flip include_flatpak off/on; verify via `kempt config get`). W-6 Spectacle screenshot → docs/ + README swap. W-7 (if staged from item 9) reboot → badge reflects harvest.
- [ ] Suite ALL PASS; commit `feat(widget): local install, docs, morning visual gate`

---

## Review protocol

Same as Plan 1: fresh implementer per task (W1+W2 may be one package; W3, W4, W5 separate), spec review then quality review per package, mutation-proof what is provable (logic.js rules, install arm), honest flags where only the morning gate can verify (visual layout, DataSource behavior inside a real plasmashell). QML that cannot be executed overnight gets extra-careful line review INSTEAD of optimism - reviewers must trace every binding chain and every Executor call for: unguarded nulls (state before first check), binding loops, i18n-unsafe string building, and anything synchronous.
