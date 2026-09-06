// logic.js - the widget's entire derivation layer, in ENGINE-AGNOSTIC JavaScript.
//
// Loaded twice: by the plasmoid (`import "logic.js" as Logic`, QML's JS engine) and by
// tests/test_widget_logic.sh (node, through the CommonJS guard at the bottom). That is the point.
// A QML plasmoid cannot be executed in a test suite, so every rule the panel shows a human - the
// badge number, the icon state, the tooltip, the popup rows - is derived HERE, where a node test
// can pin it. Nothing in this file may touch Qt, i18n, the filesystem or a network.
//
// NOT `.pragma library`: that pragma is not valid JavaScript, so node could not load this file at
// all. The functions are pure, so the one shared copy it would buy buys nothing.
// Old-school JS (var, function expressions, indexOf): this runs unchanged in whatever JS engine
// the installed Plasma version ships.
//
// Input contract: state schema v1 (docs/architecture.md), the CLI's frozen public interface. Two
// of its rules are load-bearing and enforced below:
//   1. empty stdout with exit 0 means "no data, keep the last known state", NEVER "zero updates";
//   2. `status: "stale"` keeps the last known counts - a tooltip fact, not a fabricated 0.

// Titles match the CLI's own renderer (lib/common.sh render_summary) so the popup and the terminal
// never name the same group differently.
var SECTION_TITLES = { dnf: "System (dnf)", flatpak: "Apps (flatpak)" };
var BACKEND_ORDER = ["dnf", "flatpak"];

// --- the copy table ----------------------------------------------------------------------------
// Every user-facing string the QML writes as a literal, in ONE place, so the wording is decided
// once and a node test can pin it. House rules: Title Case for buttons, sentence case for
// messages; a real ellipsis (U+2026) on anything that opens something else; no em dashes; "held",
// never "held back" - the CLI's section is Held and the command is `kempt hold`.
//
// IMPORTANT, and not what it looks like: the QML does NOT read these at runtime. It writes the
// literal, `i18n("Update Now")`, because translation extraction works on LITERALS -
// `i18n(Logic.COPY.updateNow)` extracts nothing and ships an untranslatable widget. This table is
// the SPECIFICATION; the QML repeats the same literal. Do not "fix" that duplication by routing
// these through i18n().
// tests/test_widget_logic.sh pins the duplication so it cannot drift, and it does NOT ask for
// "verbatim in a .qml" - that would be wrong for the 23 entries below that the view model renders
// and the QML therefore never spells out. An entry has to be used in one of three ways: repeated
// verbatim in a .qml, read as `Logic.COPY.<key>` by a .qml where a literal cannot go, or used by
// this file. An entry in none of them is wording kept as a specification for nothing.
//
// What the table does NOT hold is the sentences viewModel ASSEMBLES - footerText, lastRunText,
// postRunLine, relativeTime. QML cannot wrap an assembled string in i18n() at all, and moving
// their fragments in here would not make them translatable either: a fragment is not a
// translatable unit, and this widget has no message-format layer to turn it into one. That layer
// is a later release; meanwhile the tests pin every assembled shape exactly.
var COPY = {
    // Header, and the placeholder under it - deliberately NOT the same sentence, so the popup does
    // not say the same words twice in one glance.
    upToDate: "Up to date",
    everythingUpToDate: "Everything is up to date",

    // `restartMessage` states a fact about the machine; `restartAction` opens KDE's own
    // logout/restart prompt and nothing else. Kempt never restarts anything itself, in any state,
    // with any setting.
    restartMessage: "Restart to apply installed updates",
    restartAction: "Restart…",
    restartFailed: "Could not open the restart prompt.",

    // The two actions. Refresh is icon-only in the header, so this is its tooltip and its
    // accessible name as well as its entry in the contextual-actions menu.
    checkForUpdates: "Check for Updates",
    updateNow: "Update Now",

    // ...and what those icon-only buttons DO, which is a different question from what they are
    // called. `text` is already the accessible name, so a description bound to `text` spends the
    // one slot that could explain the effect.
    checkForUpdatesDescription:
        "Asks dnf and flatpak what is pending now, instead of waiting for the timer.",
    configureDescription:
        "Check interval, where updates run, restart reminders, and the packages you hold.",

    // --- the pin ---------------------------------------------------------------------------------
    // The name carries the STATE, with a residual: a `checkable: false` button exposes no checked
    // state to AT-SPI on Qt 6.11 (measured), and the one role that does - CheckBox - makes Breeze
    // draw its sunken checked background on a control sitting directly under the tray's own
    // checked Keep Open pin. So the state is words: these four sentences, the "Held" token on the
    // row, and the glyph.
    // TWO PAIRS, because a package that is not installed yet has no current version to be held AT:
    // the CLI writes "?" for that `from`, and what the pin does there is refuse the install.
    holdAt: "Hold %1 at %2",
    stopHolding: "Stop holding %1",
    skipInstalling: "Skip installing %1",
    stopSkipping: "Stop skipping %1",
    // The description is the CONSEQUENCE. Per package, and Kempt only - a dnf user reads
    // versionlock into a padlock, and this is where that is answered.
    holdConsequence: "Kempt skips it on every update until you stop holding it.",
    heldConsequence: "Kempt offers its update again.",
    // The state in words on the row. A glyph, a position and an opacity dip are not enough: a dip
    // is a contrast REDUCTION on rows a person deliberately protected.
    heldToken: "Held",
    // What a row draws where the CLI wrote "?": "? → 9.9.9-1.fc44" reads as "the widget does not
    // know". The DATA keeps the "?" - it is the CLI's sentinel and the padlock recognises it too.
    versionNew: "new",
    // ...and the line the Held heading owes a first-timer: a hold is Kempt's own list and does not
    // touch `dnf upgrade`.
    heldKemptOnly: "Held packages are skipped by Kempt only.",
    // The version line as a sentence: on screen it is "3.105-… → 3.106-1.fc44", and that arrow
    // goes through a screen reader's character table as a word nobody wants to hear.
    versionRange: "from %1 to %2",

    // --- the pane a run replaces the popup with ---------------------------------------------------
    // One sentence per surface, each naming where to look, and staging says what it is rather than
    // calling itself an update. Never the CONFIGURED surface, and never the word "surface".
    updatingTerminal: "Updating in a terminal window…",
    updatingBackground: "Updating in the background…",
    updatingHere: "Updating…",
    updatingOffline: "Preparing the install for the next restart…",
    // ...and the way out. Only a state.json change ends the updating state, and a terminal run
    // that is aborted or closed never writes one - so without this the popup sits on an empty pane
    // until a three-hour guard fires. On the default configuration that is what a first-timer gets
    // for taking the default answer to Kempt's one question.
    notUpdatingCheckAgain: "Not updating? Check again",

    // The offline path, named for what it does to the user rather than for the dnf5 flag behind
    // it. The tooltip is the whole argument for choosing it.
    installOnNextRestart: "Install on Next Restart",
    installOnNextRestartTooltip:
        "Applies the update during a restart, so nothing changes underneath your running desktop.",

    // Four spellings, because two things vary: whether a kernel is in the set, and whether the
    // NVIDIA driver is with it (that box has a second, worse failure mode - a kernel module built
    // against a kernel that is not the running one - and naming it makes the advice credible).
    // Each says what the BUTTON underneath does, never "restart when it finishes": recommending
    // the live path over a button offering the offline one reads as an order to restart now.
    kernelRestart:
        "This update includes a kernel. The safest way is to install it on the next restart, "
        + "so nothing changes under the running desktop.",
    kernelNvidiaRestart:
        "This update includes a kernel and the NVIDIA driver. The safest way is to install them "
        + "on the next restart, so nothing changes under the running desktop.",
    // ...and the same recommendation with no kernel in the set. The family list is kept, capped
    // where the count sentence caps it, because it is the evidence for the claim.
    riskySessionOne:
        "This update touches 1 package the running desktop depends on (%1). "
        + "The safest way is to install it on the next restart.",
    riskySessionMore:
        "This update touches %1 packages the running desktop depends on (%2). "
        + "The safest way is to install them on the next restart.",

    // `held` is a suffix to a number ("3 held") rather than a sentence, because the same word has
    // to serve the tooltip too.
    held: "held",
    restartPending: "restart pending",
    // What the footer gains while the counts above it are stale: three words on the line that
    // DATES those counts. The CLI's reason goes in the tooltip of the button that tries again.
    lastCheckFailed: "last check failed",
    // "No SUCCESSFUL check", not "not checked": the footer dates the counts by last_success, so
    // its fallback has to be about last_success. A box whose every check since install has failed
    // HAS checked - and that box is the one most likely to be reading this line.
    noSuccessfulCheckYet: "No successful check yet",

    // The last run: its expander action, and the two phrases that stand in for a package list.
    showLog: "Show Log",
    noPackageChanges: "No package changes",
    updateFailed: "Update failed",

    // THREE spellings, because two things vary independently: the count can be unknown (a marker
    // written before the CLI recorded one), and one update is not the plural with a 1 in it - noun,
    // verb and pronoun move together ("1 update IS staged - IT installs"). `stagedTail` stays a
    // FRAGMENT for the plural spellings only, so the two say the identical thing about the
    // identical transaction; the tests pin the finished sentences, not the pieces.
    stagedTail: "are staged - they install on the next restart",
    stagedOne: "1 update is staged - it installs on the next restart",
    stagedUnknownCount: "Updates are staged - they install on the next restart",

    // ...and the HEADER over that banner, same three spellings, same reasons. While a stage is
    // armed the pending count is a true number saying a false thing: "23 updates available" over a
    // green banner about the same 23 reads as "so it did not work?". The BADGE is deliberately
    // untouched - those updates really are pending until the restart runs.
    stagedHeaderOne: "1 update staged for the next restart",
    stagedHeaderTail: "updates staged for the next restart",
    stagedHeaderUnknown: "Updates staged for the next restart",

    // ...and the three the banner has once a hold lands behind the stage. These REPLACE
    // stagedTail/stagedOne rather than joining them: a warning appended to a reassurance is the
    // contradiction one level down (spec 4.4). "%1"/"%2" because these are the only entries whose
    // subject is a package name from another program, and spec section 7 requires them stated as
    // sentences rather than head/tail fragments; stagedVariantOf substitutes.
    // A NAME then a count of the rest, not familiesOf - collapsing kernel-core and kernel-modules
    // is right for "what is risky here" and wrong here, where the person is owed the number of
    // packages their holds did not stop. In the USER'S order of events, with BOTH remedies: named
    // after the mechanism it has no antecedent once the green banner is gone.
    stagedConflictOne:
        "You held %1 after the next-restart install was prepared, so it still installs. "
        + "Rebuild it to skip %1, or stop holding %1 to keep the current plan.",
    stagedConflictMore:
        "You held %1 and %2 more after the next-restart install was prepared, so they still "
        + "install. Rebuild it to skip them, or stop holding them to keep the current plan.",
    // "may", because that is exactly what is known: names_source "none" means an empty conflict
    // list is "cannot tell", never "no conflict". The spec's rule is that names may CONFIRM a
    // conflict and may never DENY one, so silence here would be denying one on no evidence.
    stagedConflictUnknown:
        "You added holds after the next-restart install was prepared, so it may still install "
        + "held packages. Rebuild it to apply your holds.",
    // The cost, as the banner's SECOND SENTENCE rather than only in the action's tooltip, which
    // discloses it only to somebody who has already hovered the button they are deciding about.
    stagedRebuildCost: "Rebuilding asks for authorization; if it fails, nothing stays staged.",

    // The one action a warning variant offers, and its whole cost. Both facts are real: it runs
    // `kempt update --surface=offline`, a privileged verb, and dnf5 destroys the stored
    // transaction the moment a re-stage begins (spec G2), so a failed rebuild leaves nothing
    // staged. It deliberately does NOT say "re-downloads" - a replace-stage reuses dnf5's package
    // cache (container-measured, spec G8) - and says "removed", the CLI's own word for it.
    stagedRebuildAction: "Rebuild Staged Update",
    stagedRebuildTooltip:
        "Builds the staged update again with your current holds. Asks for authorization; "
        + "if the rebuild fails, the current staged update is removed.",
    // What the rebuild says instead of acting when the stage it was offered over is not the stage
    // on disk any more - the only sentence that stops a press with no effect being
    // indistinguishable from a broken button. main.qml assigns it, like restartFailed.
    stagedChanged:
        "The staged update changed since this was offered. Nothing was rebuilt; "
        + "check the banner above.",

    // The hold round trip. The first two are never DRAWN: the popup speaks them through one
    // Accessible.announce when the row has actually moved, because otherwise a hold lands in
    // complete silence. Their %1 is substituted in the QML - an announcement is one translatable
    // sentence with a name in it.
    holdAnnounce: "Holding %1",
    unholdAnnounce: "No longer holding %1",
    // ...and the failure, reported in the ROW that failed rather than in a message up to 300 px
    // from the pin that caused it. main.qml substitutes and assigns it.
    holdFailed: "Could not change the hold on %1.",

    // Right-click, and the popup's own gear. Opens a dialog, so: real ellipsis.
    configure: "Configure Kempt…",

    // The store-first first run: the KDE Store carries the plasmoid and not the CLI, so a store
    // install's first check runs against nothing. Two entries because the message renders two lines
    // - what is true, then what to type - and a person who cannot act on the second still gets the
    // first. INGREDIENTS: engineMissingMessage assembles them; the tooltip takes the first alone.
    // The commands are WHOLE: half a command line fails somewhere the reader has to debug.
    engineMissing: "Kempt's engine is not installed, so nothing can check for updates yet.",
    engineMissingInstall:
        "On Fedora: sudo dnf copr enable erez-c137/kempt, then sudo dnf install kempt. "
        + "Other systems: github.com/erez-c137/kempt",
    // The CLIPBOARD form: one line, chained, one paste. Separate from engineMissingInstall because
    // that one is a sentence (commas, "then", a URL) and a sentence pasted into a shell fails.
    // The tests drift-guard the two: every command this copies must appear verbatim in the other.
    engineMissingCopy: "sudo dnf copr enable erez-c137/kempt && sudo dnf install kempt"
};

// MIDDLE DOT with a space each side. One constant, because the footer status line and the Last
// update row both use it and two would drift the first time one was edited.
var DOT = " \u00b7 ";

// How big the pending download is, in words.
// "~", never "up to": the figure has error in BOTH directions, so any wording implying a ceiling
// is false - dnf pulls in dependencies `--upgrades` never listed, flatpak transfers ostree deltas
// far smaller than the published size, and a transaction already staged offline is downloaded in
// full while the number still counts it.
// Under a megabyte it says "< 1 MB": nobody decides differently between 300 kB and 800 kB, and a
// number that small next to an update button invites the reader to think it is precise.
// "" for absent, zero, negative or not-a-number, and empty means render NOTHING: no "unknown",
// no "0 MB", no dash.
function formatDownload(bytes) {
    if (typeof bytes !== "number" || !isFinite(bytes) || bytes <= 0) return "";
    if (bytes < 1000000) return "< 1 MB";
    var mb = Math.round(bytes / 100000) / 10;
    // 999999999 bytes rounds to 1000.0 MB, which is a gigabyte spelled the long way.
    if (mb < 1000) return "~" + trimZero(mb) + " MB";
    return "~" + trimZero(Math.round(bytes / 100000000) / 10) + " GB";
}

// One decimal, minus a pointless one. Not toFixed(1) plus a string trim: toFixed rounds a second
// time on an already-rounded value, and the two can disagree at the boundary.
function trimZero(n) {
    return String(Math.round(n * 10) / 10);
}

// How many session-critical families the offline recommendation names before ", ...". Same number
// the CLI's notification uses (bin/kempt).
var RISKY_FAMILIES_SHOWN = 4;

// Highest number the panel badge spells out; above this it reads "999+". COMPACT ONLY - the popup
// header is never capped, and a person opening it is asking for the real number.
// 999 and not 99: a Fedora box left alone for a few weeks routinely has two or three hundred
// pending, so a cap of 99 would be vague in the ordinary case rather than the extreme one.
var BADGE_MAX = 999;

// shellQuote(s) -> the string as ONE shell word, safe to paste into a command line.
//
// The widget's only injection surface, and a real one: package names come out of the CLI's JSON
// and the popup builds `kempt hold <backend>:<name>` from them, so a name containing `;` or a
// backtick would be a second command running as the user from inside the panel process. POSIX
// single quotes disable every expansion the shell has; the only character that cannot appear
// inside them is the single quote, which is closed, escaped and reopened ('\'').
// Anything state-derived that reaches a command line goes through here. No exceptions - not
// "obviously safe" package names, not log paths.
function shellQuote(s) {
    if (s === undefined || s === null) return "''";
    return "'" + String(s).split("'").join("'\\''") + "'";
}

// fill(template, token, value) -> EVERY occurrence replaced. String.replace with a string needle
// replaces one, and stagedConflictOne names its package three times. split/join rather than a
// regex, because the value is a package name from another program and a regex would interpret it.
function fill(template, token, value) {
    return String(template).split(token).join(value);
}

// Is this really an array? `typeof v.length === "number"` is not enough: a STRING has a length,
// and iterating one yields characters that would render as packages.
function isArray(v) { return Object.prototype.toString.call(v) === "[object Array]"; }
function arrayOf(v) { return isArray(v) ? v : []; }

// The run surfaces the CLI knows, in the order the settings page offers them.
var SURFACES = ["terminal", "popup", "background", "offline"];

// isTrue(s) -> the same answer lib/common.sh's is_true() gives. The settings page reads booleans
// back as the TEXT `kempt config get` printed, and the two must not disagree about what "yes"
// means: a checkbox that renders a config value as its opposite is how a user turns something off
// and finds it back on.
function isTrue(value) {
    if (typeof value === "boolean") return value;
    var s = String(value === undefined || value === null ? "" : value).trim().toLowerCase();
    return s === "true" || s === "1" || s === "yes";
}

// resolveSurface(s) -> a surface the CLI recognises, mirroring bin/kempt's resolve_surface():
// anything unknown is `terminal`, because that is what the CLI itself would run.
function resolveSurface(value) {
    var s = String(value === undefined || value === null ? "" : value).trim().toLowerCase();
    return SURFACES.indexOf(s) >= 0 ? s : "terminal";
}

// updatingLabelOf(surface) -> what the pane says while a run on that surface is in flight. Takes
// the surface the RUNNING transaction is using, which is not always the configured one: with
// confirmation on `kempt run` collapses every surface to terminal, and Install on Next Restart
// stages offline whatever the setting says.
function updatingLabelOf(surface) {
    switch (resolveSurface(surface)) {
    case "popup":      return COPY.updatingHere;
    case "background": return COPY.updatingBackground;
    case "offline":    return COPY.updatingOffline;
    default:           return COPY.updatingTerminal;
    }
}

// effectiveSurfaceOf(surface, autoAccept) -> the surface a run will ACTUALLY use. bin/kempt's
// cmd_run resolves the configured surface and then overrides it: with auto_accept false only a
// terminal can ask the confirmation question. The popup has to apply the same rule or it offers an
// in-widget log pane while a terminal window is what opens.
function effectiveSurfaceOf(surface, autoAccept) {
    return isTrue(autoAccept) ? resolveSurface(surface) : "terminal";
}

// --- how big the panel icon is asked to be -----------------------------------------------------
// snapIconSize answers "how big when nobody said" (the `auto` setting); resolveIconSize answers
// "how big, given what the user asked for".
//
// The hinted sizes an icon theme actually draws, smallest first. Breeze ships 16px and 22px
// symbolics as SEPARATE artwork, each aligned to the pixel grid AT THAT SIZE, so asking for 15 or
// 24 scales one by a fraction and every hinted stroke lands between pixels. Every size below is
// one of these steps, never an arithmetic result; the QML passes Kirigami's own values in this
// order.
var ICON_STEPS = [16, 22, 32, 48, 64];

// The cell thickness at which each step takes over, paired by index with the steps above.
// NOT "the largest icon that fits": a 44px panel fits 32px, but the system tray beside it draws
// 22, and an icon that fills its cell when nothing around it does reads as a mistake. So the rungs
// are pinned to what the tray does at ordinary panel thicknesses - a 22px panel up to a 47px one
// asks for 22. 48 is where a panel stops being an ordinary panel.
var ICON_CELL_MIN = [16, 22, 48, 96, 192];

// snapIconSize(cell, steps) -> the hinted size an `auto` icon asks for in a cell this thick.
// Below the first rung there is no hinted size to snap to, so it falls back to a whole number of
// pixels: scaling is the only option left, but it can at least be scaled to an integer.
function snapIconSize(cell, steps) {
    var c = Number(cell), list = usableSteps(steps), chosen = 0, i;
    if (!isFinite(c) || c <= 0) return 0;
    for (i = 0; i < list.length && i < ICON_CELL_MIN.length; i++) {
        if (c >= ICON_CELL_MIN[i]) chosen = list[i];
    }
    // Never wider than the cell holding it, whatever a caller's step list says.
    return chosen > 0 ? Math.min(chosen, Math.floor(c)) : Math.floor(c);
}

// The step list a caller supplied, cleaned - or the built-in one when they supplied nothing
// usable. An empty list is a caller that could not read its theme, and the right answer to that is
// still a hinted size. It is also what lets node call snapIconSize(44) with no second argument.
function usableSteps(steps) {
    var out = [], i, s;
    if (!steps || !steps.length) return ICON_STEPS.slice();
    for (i = 0; i < steps.length; i++) {
        s = Number(steps[i]);
        if (isFinite(s) && s > 0) out.push(s);
    }
    return out.length ? out : ICON_STEPS.slice();
}

// The `widget_icon_size` values the settings page offers, and the step each names. INDEXES into
// the step list rather than pixel counts, so a theme whose "small" is not 16 still gets its own
// hinted artwork rather than a number this file invented.
var ICON_SIZE_SETTINGS = { auto: -1, small: 0, medium: 1, large: 2 };

// ...and the ones that must never come out SMALLER than `auto` would have drawn. Only the largest
// option, and the asymmetry is the point: see resolveIconSize.
var ICON_SIZE_FLOOR_AT_AUTO = { large: true };

// resolveIconSizeSetting(value) -> a setting the widget recognises; anything unknown is `auto`.
// This is the ONLY validation `widget_icon_size` gets - the CLI stores whatever it is handed
// (config_set checks the key's shape, not the value's meaning), so a typo, an older CLI's empty
// line and a future version's value all land here and all mean: decide automatically, say nothing.
function resolveIconSizeSetting(value) {
    var s = String(value === undefined || value === null ? "" : value).trim().toLowerCase();
    return Object.prototype.hasOwnProperty.call(ICON_SIZE_SETTINGS, s) ? s : "auto";
}

// resolveIconSize(setting, cell, steps) -> the pixel size the icon is actually asked for.
// A chosen size the cell cannot hold falls back to `auto` rather than overflowing: inside the tray
// the cell is the tray's to decide, and 32px in a 22px slot pushes every other entry around.
function resolveIconSize(setting, cell, steps) {
    var list = usableSteps(steps), c = Number(cell);
    var auto = snapIconSize(c, list);
    if (!isFinite(c) || c <= 0) return auto;          // no cell yet: nothing to draw into
    var key = resolveIconSizeSetting(setting);
    var idx = ICON_SIZE_SETTINGS[key];
    if (idx < 0) return auto;
    var want = Number(list[idx]);
    if (!isFinite(want) || want <= 0) return auto;    // a step list too short to name it
    // "Large" is a promise about size, and on a big cell the named step breaks it: auto reaches 48
    // at a 96px cell and 64 at 192, while `large` names the third step (32) - so on a vertical dock
    // or a HiDPI panel, Large would draw SMALLER than Automatic. Floored rather than relabelling
    // the options as pixel counts, which would make every label a number the user must translate.
    // Small and Medium are deliberately NOT floored: going below Automatic is why they exist.
    if (ICON_SIZE_FLOOR_AT_AUTO[key]) want = Math.max(want, auto);
    return want > c ? auto : want;
}

// --- the watcher stamp -----------------------------------------------------------------------
// main.qml polls four mtimes every 30 seconds. WHICH of them moved is the part that matters,
// because /var/lib/rpm is rewritten continuously all the way through a dnf transaction: comparing
// the stamp as one string says only "something changed", which during a run of ours is true every
// 30 seconds - so the widget declares the run finished a few seconds in, prints a summary of the
// PREVIOUS run, and starts a `kempt check` that wants the lock the transaction is holding. Only
// OUR state file says a run ended, and these field names are that distinction (here, not in QML,
// so node can pin them).
var WATCH_FIELDS = 4;
var WATCH_STATE_FIELD = 2;      // the order in main.qml's watchCmd: rpm, flatpak, state, config
var WATCH_CONFIG_FIELD = 3;

// watchChange(prev, next) -> { any, packages, state, config, comparable }
// `comparable` is false when either stamp is not the four fields main.qml asks for (an older
// widget's stamp left across a reload, say). Then the answer degrades to a whole-string comparison
// with every category true, rather than guessing which column is which: wrong-but-noisy beats
// wrong-and-silent when what is at stake is noticing a finished run.
function watchChange(prev, next) {
    var a = watchFieldsOf(prev), b = watchFieldsOf(next), i;
    var out = { any: false, packages: false, state: false, config: false, comparable: false };
    if (a.length !== WATCH_FIELDS || b.length !== WATCH_FIELDS) {
        out.any = a.length > 0 && b.length > 0 && a.join(" ") !== b.join(" ");
        out.packages = out.any;
        out.state = out.any;
        out.config = out.any;
        return out;
    }
    out.comparable = true;
    for (i = 0; i < WATCH_FIELDS; i++) {
        if (a[i] === b[i]) continue;
        out.any = true;
        if (i === WATCH_STATE_FIELD) out.state = true;
        else if (i === WATCH_CONFIG_FIELD) out.config = true;
        else out.packages = true;
    }
    return out;
}

function watchFieldsOf(stamp) {
    var raw = String(stamp === undefined || stamp === null ? "" : stamp).trim(), out = [], i;
    if (raw === "") return out;
    raw = raw.split(/\s+/);
    for (i = 0; i < raw.length; i++) if (raw[i] !== "") out.push(raw[i]);
    return out;
}

// --- the quiet window after a check ------------------------------------------------------------
// A run leaves a wake - rpm rewritten throughout, state.json rewritten by the CLI's own post-run
// check, /var/lib/flatpak moved - so the 30-second watcher goes on finding changes for a minute
// after that check has accounted for all of them, and each one is a line in `kempt log`.
//
// So a WATCHER-triggered check is dropped while the last completed check is still recent. Only the
// watcher's: a Refresh press, the scheduled check, the popup opening and a settings write are all
// somebody ASKING, and the post-run check is exempt because it is the moment the counts are most
// wrong (main.qml, pollWatch's `endedRun`). The cost is bounded - a change from elsewhere inside
// the window is absorbed and the next scheduled check finds it, so the badge can only
// over-report, never under-report.
var CHECK_QUIET_MS = 60000;

// watcherCheckDue(lastCheckFinished, now) -> whether a watcher-triggered check should run.
// `lastCheckFinished` is 0 until a check has completed, and that answers yes: with no check behind
// us there is no footprint of ours for this change to be.
function watcherCheckDue(lastCheckFinished, now) {
    var last = Number(lastCheckFinished), t = Number(now);
    if (!isFinite(last) || last <= 0) return true;
    if (!isFinite(t)) return true;
    var since = t - last;
    // A clock that moved backwards (NTP, a suspend) must never suppress a check: an optimisation
    // that can silence the widget indefinitely on a bad clock is not one.
    if (since < 0) return true;
    return since >= CHECK_QUIET_MS;
}

// holdsOf(text) -> [{ id, backend, name }] from `kempt holds` output (raw `backend:name` lines).
// Split at the FIRST colon, exactly like cmd_hold's ${1%%:*} / ${1#*:}, so a name containing a
// colon still round-trips to the same hold the CLI would remove.
function holdsOf(text) {
    var out = [], lines, i, line, cut;
    if (typeof text !== "string") return out;
    lines = text.split("\n");
    for (i = 0; i < lines.length; i++) {
        line = lines[i].trim();
        if (line === "") continue;
        cut = line.indexOf(":");
        if (cut <= 0 || cut === line.length - 1) continue;   // not a backend:name pair
        out.push({ id: line, backend: line.substring(0, cut), name: line.substring(cut + 1) });
    }
    return out;
}

// lastLinesOf(text, max) -> the last `max` non-blank lines, trimmed, joined with " ". The result
// line under the passwordless buttons. The LAST lines: pkexec and polkit print their progress
// before their verdict, and the verdict is the part worth showing.
function lastLinesOf(text, max) {
    var kept = [], lines, i, line;
    if (typeof text !== "string") return "";
    if (!max || max < 1) max = 2;
    lines = text.split("\n");
    for (i = 0; i < lines.length; i++) {
        line = lines[i].trim();
        if (line !== "") kept.push(line);
    }
    return kept.slice(Math.max(0, kept.length - max)).join(" ");
}

// firstLineOf(text) -> the first non-blank line, trimmed, or "". Trimming here rather than in QML
// is what lets a node test pin it.
function firstLineOf(text) {
    if (typeof text !== "string") return "";
    var lines = text.split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (line !== "") return line;
    }
    return "";
}

// parseState(text) -> the state object, or null.
// null means "we learned nothing from this call". Every caller must treat it as "keep what you
// had", which is why nothing here ever invents an empty-but-valid state.
function parseState(text) {
    if (typeof text !== "string") return null;
    if (text.trim() === "") return null;
    var parsed;
    try {
        parsed = JSON.parse(text);
    } catch (e) {
        return null;
    }
    // A number, a string, null or an array are all valid JSON and none of them is a state.
    if (parsed === null || typeof parsed !== "object") return null;
    if (Object.prototype.toString.call(parsed) === "[object Array]") return null;
    return parsed;
}

// Is this object schema-v1 shaped? A parsed object carrying neither a count nor backends is
// something else (a future schema, a foreign file), and the widget says so rather than rendering
// it as "no updates".
function looksLikeState(state) {
    if (!state || typeof state !== "object") return false;
    // A declared schema we do not know is NOT rendered optimistically. Version skew is the normal
    // state of this pair, not an edge case: the CLI is installed as a symlink into the checkout
    // while the widget is a COPY, so after a `git pull` the CLI is new and the widget is whatever
    // was last installed - and a schema 2 field could mean anything.
    if (typeof state.schema === "number" && state.schema !== 1) return false;
    if (typeof state.actionable === "number") return true;
    if (state.backends && typeof state.backends === "object") return true;
    return false;
}

// What a `from` looks like when there is no current version: the package is not installed and the
// update would ADD it. The CLI's own sentinel, named because the popup recognises it twice - to
// say "Skip installing X" instead of "Hold X at ?", and to draw it as a word.
var VERSION_UNKNOWN = "?";

// What ANY row draws for a `from` the CLI could not know. The pending list and the Last update
// history rows both go through this, so a package that was not installed reads "new" in both
// places rather than "?" in one of them.
function fromTextOf(from) {
    return from === VERSION_UNKNOWN ? COPY.versionNew : from;
}

// newestOf("a,b,c") -> "c". The CLI collapses multilib and installonly duplicates into ONE row
// with the versions comma-joined, and its own renderer shows the last of the set (lib/common.sh:
// `def newest(v): v | split(",") | last`). The widget copies that rule exactly: a popup that
// renders a version differently from `kempt summary` is the front-end disagreeing with the CLI.
function newestOf(versionSet) {
    if (versionSet === null || versionSet === undefined) return VERSION_UNKNOWN;
    var s = String(versionSet);
    if (s === "") return VERSION_UNKNOWN;
    var parts = s.split(",");
    return parts[parts.length - 1];
}

// familiesOf(names, max) -> { shown: [families, capped at max], total: <unique family count> }.
// A family is the name up to its first "-" or "." - kernel-core and kernel-modules are one
// decision - unique and sorted, exactly like the CLI's `sed 's/[-.].*//' | sort -u`.
// max <= 0 (or omitted) means no cap.
function familiesOf(names, max) {
    var seen = {}, families = [], i, family;
    if (!names || typeof names.length !== "number") return { shown: [], total: 0 };
    for (i = 0; i < names.length; i++) {
        family = String(names[i]).replace(/[-.][\s\S]*$/, "");
        if (family === "") continue;
        // "#" prefix: a family called "constructor" or "toString" would otherwise collide with
        // Object.prototype and silently vanish from the list.
        if (seen["#" + family]) continue;
        seen["#" + family] = true;
        families.push(family);
    }
    families.sort();
    return {
        shown: (max && max > 0 && families.length > max) ? families.slice(0, max) : families.slice(0),
        total: families.length
    };
}

// The families in a risky set, capped, as both sentences below name them. One function, because a
// count sentence and a recommendation listing the same set differently would be the popup
// disagreeing with itself about one transaction.
function riskyFamiliesOf(names) {
    var fams = familiesOf(names, RISKY_FAMILIES_SHOWN);
    return fams.shown.join(", ") + (fams.total > fams.shown.length ? ", ..." : "");
}

// "20 session-critical pending (dbus, glibc, kernel, kf6, ...)", worded from the same parts as the
// CLI's notification. Published as vm.riskySummary and deliberately not drawn: the popup shows the
// RECOMMENDATION below, which answers the next question.
function riskySummaryOf(names) {
    if (!names || !names.length) return "";
    return names.length + " session-critical pending (" + riskyFamiliesOf(names) + ")";
}

// riskyMessageOf(names) -> what to DO about a session-critical transaction, in one sentence.
// A kernel changes the answer: staging it offline does not help, because the kernel you are
// running keeps running until you restart either way. The two ingredient tests are deliberately
// different shapes:
//   * KERNEL is a FAMILY test - kernel-core, kernel-modules and kernel.x86_64 are one decision,
//     and it keeps kernelcare, which merely starts the same, out of it.
//   * NVIDIA is a SUBSTRING test, case-insensitive, because the driver arrives under families with
//     nothing in common: akmod-nvidia, xorg-x11-drv-nvidia, nvidia-settings.
// NVIDIA without a kernel says nothing special: the extra sentence is about a module built against
// a kernel that is about to stop being the running one.
function riskyMessageOf(names) {
    if (!isArray(names) || names.length === 0) return "";
    // The 0 is a cap of NONE and has to stay one. This is a LOOKUP, not a list being shown:
    // RISKY_FAMILIES_SHOWN caps what riskySummaryOf PRINTS, and passing it here - the
    // obvious-looking tidy-up - would make the kernel warning depend on where "kernel" falls in an
    // alphabetical sort. Four families ahead of it (akmod, alsa, atk, bash) and the most important
    // sentence this popup has silently stops being said.
    if (familiesOf(names, 0).shown.indexOf("kernel") < 0) {
        // No kernel: the offline install really is safer and nothing has to be said about the
        // running kernel. Whole literals, because count, noun and pronoun move together.
        var fams = riskyFamiliesOf(names);
        return names.length === 1
            ? fill(COPY.riskySessionOne, "%1", fams)
            : fill(fill(COPY.riskySessionMore, "%1", String(names.length)), "%2", fams);
    }
    for (var i = 0; i < names.length; i++) {
        if (String(names[i]).toLowerCase().indexOf("nvidia") >= 0) return COPY.kernelNvidiaRestart;
    }
    return COPY.kernelRestart;
}

// stagedMessageOf(offline_staged) -> what the next restart will install, in one sentence.
//
// The CLI publishes this key only after reconciling its own marker against dnf5's transaction
// status, and only for a transaction genuinely ARMED (lib/common.sh, offline_staged_state), so the
// judgement is not re-derived here: the key's presence IS the answer. The count is optional and no
// reader may invent it - a marker written before the count existed carries null, and the sentence
// loses the number rather than gaining a wrong one. The type check matters because this is JSON
// from another program: a string here would reach `.count` as undefined and render the popup's
// most reassuring sentence about a transaction that does not exist.
function stagedMessageOf(staged) {
    if (!staged || typeof staged !== "object" || isArray(staged)) return "";
    var n = staged.count;
    if (typeof n !== "number" || !isFinite(n) || n < 0) return COPY.stagedUnknownCount;
    // Exactly one takes the singular - zero is plural in English ("0 updates"), so `=== 1`.
    return n === 1 ? COPY.stagedOne : n + " updates " + COPY.stagedTail;
}

// --- how many messages the popup may show at once ------------------------------------------------
// Two. Measured: at the default popup size (26 x 24 grid units = 468 x 432 px) five messages left
// the list 95 px tall, and at Layout.minimumHeight the messages alone overflowed - they sit
// OUTSIDE the ScrollView, so nothing scrolled and the list was simply gone.
//
// A RULE and not four visibility bindings, which is why it lives where a node test can state it: a
// binding can say "am I true", and only something that sees all four can say "am I one of the two
// that fit".
var MESSAGE_CAP = 2;

// Priority order, and each position is an argument:
//   report   what the person just did. First: it answers a question asked seconds ago.
//   staged   what the next restart will install, and whether a hold landed behind it. The one
//            message that changes what the rest of the popup may offer.
//   restart  a restart is owed. Displaced most cheaply of the four: the footer says "restart
//            pending" whenever this message is not on screen, so the fact is never lost.
//   kernel   the offline recommendation. Last: it is advice about a transaction that will still be
//            there next time the popup is opened.
var MESSAGE_ORDER = ["report", "staged", "restart", "kernel"];

// messageStack(wants) -> the messages that may actually be drawn, in order.
// `engineMissing` is not in the order at all: it shows ALONE, because everything below it presumes
// an engine that answered. Anything displaced shows NOTHING - it does not shuffle into the next
// slot mid-glance and it does not stack below the fold.
function messageStack(wants) {
    var w = (wants && typeof wants === "object") ? wants : {};
    if (w.engineMissing) return ["engineMissing"];
    var out = [], i;
    for (i = 0; i < MESSAGE_ORDER.length && out.length < MESSAGE_CAP; i++) {
        if (w[MESSAGE_ORDER[i]]) out.push(MESSAGE_ORDER[i]);
    }
    return out;
}

// stagedHeaderOf(offline_staged) -> what the popup header and the panel tooltip say while a
// transaction is armed, or "" when none is. Same input and tolerance as stagedMessageOf, but a
// second function rather than a flag on it: the banner states what the next restart will DO, while
// this replaces a count of what is available.
function stagedHeaderOf(staged) {
    if (!staged || typeof staged !== "object" || isArray(staged)) return "";
    var n = staged.count;
    if (typeof n !== "number" || !isFinite(n) || n < 0) return COPY.stagedHeaderUnknown;
    return n === 1 ? COPY.stagedHeaderOne : n + " " + COPY.stagedHeaderTail;
}

// stagedVariantOf(staged, heldDnf) -> which of the three banners this stage gets, and its words:
//   { type: "positive" | "warning", message, conflictNames: [...], stagedAt: "" }
//
// THE PROBLEM IT EXISTS FOR: stage 83 updates with a kernel among them, press the pin on
// kernel-core, and restart into the kernel you just tried to keep out. dnf5 built and stored that
// transaction at stage time and offers no way to edit a stored one, so a hold applies from the
// NEXT transaction Kempt builds while this one still installs the package. The banner does not
// GAIN a warning line - that is a contradiction one level down, with the button on the reassuring
// half - it changes what it IS.
//
// The judgement is NOT re-derived here. `holds_conflict` is the CLI's own answer, computed at
// check time from dnf5's stored transaction read live, and `names_source` says what an EMPTY list
// means: "transaction"/"marker" mean it was read and there is nothing in it, "none" means it could
// not be read at all. Two states, two sentences.
//
// heldDnf is the one fact this file supplies itself: whether the box holds any dnf package at all.
// It gates the generic warning only - with nothing held there is nothing to be vague ABOUT. dnf
// only, because the offline surface stages dnf and only dnf (spec, UX finding 2).
//
// TOLERANCE: a key of the wrong type is IGNORED, never duck-typed - a string has a length and
// indexes into its own characters, so a duck-typed check would warn about a package called "k".
// Everything malformed falls back to the plain banner and nothing throws. The ONE asymmetry is
// deliberate: a well-formed list of names warns whether or not names_source is readable, because
// names may CONFIRM a conflict and may never DENY one.
function stagedVariantOf(staged, heldDnf) {
    var plain = { type: "positive", message: stagedMessageOf(staged), conflictNames: [],
                  stagedAt: "" };
    if (plain.message === "") return plain;
    // A stamp that is not a string is not a stamp. main.qml compares this for EQUALITY against the
    // state file at click time, and a number here would compare equal to a number there and spend
    // the user's consent on a transaction they never saw.
    if (typeof staged.staged_at === "string") plain.stagedAt = staged.staged_at;

    var names = [], i, name;
    if (isArray(staged.holds_conflict)) {
        for (i = 0; i < staged.holds_conflict.length; i++) {
            name = staged.holds_conflict[i];
            // One bad entry discards the LIST, not just the entry: "kernel-core and 2 more" is
            // only worth saying when the 2 is true.
            if (typeof name !== "string" || name === "") { names = []; break; }
            names.push(name);
        }
    }

    // The cost is joined on HERE rather than written into each of the three templates: one fact
    // about one button, identical in all three, and three copies would drift. It only ever rides a
    // warning, because the warning is the only variant that offers the button it is about.
    if (names.length > 0) {
        return { type: "warning",
                 message: (names.length === 1
                     ? fill(COPY.stagedConflictOne, "%1", names[0])
                     : fill(fill(COPY.stagedConflictMore, "%1", names[0]),
                            "%2", String(names.length - 1)))
                     + " " + COPY.stagedRebuildCost,
                 conflictNames: names, stagedAt: plain.stagedAt };
    }
    if (staged.names_source === "none" && heldDnf) {
        return { type: "warning",
                 message: COPY.stagedConflictUnknown + " " + COPY.stagedRebuildCost,
                 conflictNames: [], stagedAt: plain.stagedAt };
    }
    return plain;
}

// The head of anything formatStamp can RENDER. Anything else it hands back verbatim, and
// isRenderableStamp is how a caller asks which of the two it is about to get.
var STAMP_HEAD_RE = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/;
// ...and the offset on the end, in either spelling `date -Iseconds` and its neighbours produce
// (+HH:MM, +HHMM), or Z.
var STAMP_OFFSET_RE = /(Z|[+-]\d{2}:?\d{2})$/;

function isRenderableStamp(iso) {
    return typeof iso === "string" && STAMP_HEAD_RE.test(iso.split("\n")[0].trim());
}

// formatStamp(iso) -> "2026-08-24 22:11 +03:00", or "never" when there is no stamp.
// Textual, not Date-based, on purpose: it cannot print "Invalid Date", it cannot shift a stamp
// into another timezone, and it survives the recorded corruption where two state documents arrive
// newline-joined. The OFFSET is part of the answer - this is the EXACT stamp people hover a
// relative line to compare against, and as a bare wall-clock reading it can disagree with that
// line by hours with nothing on screen to explain the gap. Normalised to one shape (+HH:MM, Z as
// +00:00) so two stamps from two producers can be read against each other.
function formatStamp(iso) {
    if (typeof iso !== "string") return "never";
    var s = iso.split("\n")[0].trim();
    if (s === "") return "never";
    var m = STAMP_HEAD_RE.exec(s);
    if (!m) return s;
    var z = STAMP_OFFSET_RE.exec(s);
    var off = "";
    if (z) off = " " + (z[1] === "Z" ? "+00:00" : z[1].slice(0, 3) + ":" + z[1].slice(-2));
    return m[1] + " " + m[2] + off;
}

// The one strict shape relativeTime will do arithmetic on: YYYY-MM-DDTHH:MM:SS, optionally
// fractional, optionally with Z or an offset (+HH:MM or +HHMM - `date -Iseconds` writes the colon,
// some producers do not). Anything else is not a timestamp here, and the answer to that is always
// the absolute stamp.
var ISO_STAMP_RE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$/;

// stampMs(iso) -> the stamp as UTC milliseconds, or NaN. The one place a stamp becomes a number,
// shared by relativeTime and shouldRefreshOnOpen so the two can never disagree about what counts
// as readable.
function stampMs(iso) {
    if (typeof iso !== "string") return NaN;
    var m = ISO_STAMP_RE.exec(iso.split("\n")[0].trim());
    if (!m) return NaN;

    var y = Number(m[1]), mo = Number(m[2]), d = Number(m[3]);
    var h = Number(m[4]), mi = Number(m[5]), s = Number(m[6]);
    // The regex proves the digits are digits, not that they are a date: Date.UTC happily rolls
    // month 13 into next January and would answer with a confident wrong number.
    if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || s > 60) return NaN;

    var off = 0, zone = m[7];
    // No zone at all is read as UTC: the only reading available without Date's own string parsing,
    // since local time is a property of the machine and not of the text. The CLI's now_iso always
    // writes an offset, so this is a foreign-file case.
    if (zone && zone !== "Z") {
        var digits = zone.substring(1).replace(":", "");
        off = (Number(digits.substring(0, 2)) * 60 + Number(digits.substring(2))) * 60000;
        if (zone.charAt(0) === "-") off = -off;
    }
    // The offset says how far AHEAD of UTC the wall clock is, so it comes off to get UTC.
    return Date.UTC(y, mo - 1, d, h, mi, s) - off;
}

// relativeTime(iso, nowMs) -> "4 min ago", or the absolute stamp when it cannot be sure.
// No Date parsing, same as formatStamp: Date.UTC is pure arithmetic, with no locale, no local
// timezone and no string parsing, which is what keeps formatStamp's three guarantees. The clock is
// an ARGUMENT rather than a Date.now() call, so every bucket boundary is something a node test can
// assert exactly instead of racing. Everything it cannot be sure about hands back to formatStamp,
// including a NEGATIVE age: "in -3 minutes" is worse than a date in every way.
function relativeTime(iso, nowMs) {
    var at = stampMs(iso);
    if (!isFinite(at) || typeof nowMs !== "number" || !isFinite(nowMs)) return formatStamp(iso);

    var age = nowMs - at;
    if (age < 0) return formatStamp(iso);
    if (age < 60000) return "just now";
    var n = Math.floor(age / 60000);
    if (n < 60) return n === 1 ? "1 min ago" : n + " min ago";
    n = Math.floor(age / 3600000);
    if (n < 24) return n === 1 ? "1 hour ago" : n + " hours ago";
    n = Math.floor(age / 86400000);
    // A week is the last age at which counting days answers "when?" better than the date does.
    // Past it, "23 days ago" makes a person do the arithmetic the stamp would have saved.
    if (n <= 7) return n === 1 ? "1 day ago" : n + " days ago";
    return formatStamp(iso);
}

// The oldest the popup's counts may be before opening it asks for fresh ones. A CEILING, not an
// alternative to the configured interval: somebody who set an hour still opened the popup to LOOK
// at the counts. Somebody who set two minutes gets two, because the smaller always wins.
var REFRESH_ON_OPEN_CEILING_MS = 5 * 60000;

// shouldRefreshOnOpen(lastSuccessIso, intervalMin, nowMs) -> should the popup re-check now?
// The order of the guards matters: an unusable clock is checked FIRST, so it beats "we know
// nothing, so ask" - firing a package-manager command on every popup open because an argument was
// undefined is worse than not auto-refreshing. A missing stamp with a usable clock still asks.
function shouldRefreshOnOpen(lastSuccessIso, intervalMin, nowMs) {
    if (typeof nowMs !== "number" || !isFinite(nowMs)) return false;
    var at = stampMs(lastSuccessIso);
    if (!isFinite(at)) return true;
    var age = nowMs - at;
    if (age < 0) return false;      // a stamp from the future is a moved clock, not a due check
    // Number(), because config values arrive as the TEXT `kempt config get` printed.
    var mins = Number(intervalMin);
    var limit = (isFinite(mins) && mins > 0)
        ? Math.min(mins * 60000, REFRESH_ON_OPEN_CEILING_MS)
        : REFRESH_ON_OPEN_CEILING_MS;
    return age > limit;             // OLDER than the limit; exactly at it is not yet stale
}

// Backend iteration order: the two we know, then anything the CLI grew since this widget was
// written. architecture.md promises a new backend is an additive schema-1 key, so an unknown key
// must appear in the popup under its own name, never be silently dropped.
function backendKeys(backends) {
    var out = [], i, key;
    for (i = 0; i < BACKEND_ORDER.length; i++) {
        if (backends[BACKEND_ORDER[i]]) out.push(BACKEND_ORDER[i]);
    }
    for (key in backends) {
        if (!Object.prototype.hasOwnProperty.call(backends, key)) continue;
        if (out.indexOf(key) < 0) out.push(key);
    }
    return out;
}

// Walk the backends once, producing the popup's pending sections and the flat Held list.
// A backend with enabled:false contributes NOTHING - no section, no held rows, no counts - so
// "include_flatpak=false" renders as an absent Apps section rather than an empty one.
function collectItems(state) {
    var sections = [], heldItems = [], actionable = 0, heldTotal = 0;
    var backends = (state && state.backends && typeof state.backends === "object") ? state.backends : {};
    var keys = backendKeys(backends), i, j;
    for (i = 0; i < keys.length; i++) {
        var key = keys[i];
        var backend = backends[key];
        if (!backend || typeof backend !== "object") continue;
        if (backend.enabled === false) continue;
        var items = (backend.items && typeof backend.items.length === "number") ? backend.items : [];
        var pending = [];
        for (j = 0; j < items.length; j++) {
            var item = items[j] || {};
            var row = {
                name: item.name === undefined || item.name === null ? "" : String(item.name),
                from: newestOf(item.from),
                to: newestOf(item.to),
                held: !!item.held,
                backend: key   // half of the `kempt hold <backend>:<name>` argument
            };
            if (row.held) { heldItems.push(row); heldTotal++; }
            else { pending.push(row); actionable++; }
        }
        if (pending.length > 0) {
            sections.push({ title: SECTION_TITLES[key] || key, backend: key, items: pending });
        }
    }
    return { sections: sections, heldItems: heldItems, actionable: actionable, heldTotal: heldTotal };
}

// rowsOf(sections, heldItems) -> ONE flat list for the popup's ListView, as
// {kind: "header", title, held} or {kind: "item", ...the item, plus `held`}. A flat model creates
// delegates lazily, so 1200 pending updates cost what six cost, and flattening here makes the
// grouping something a node test can check. A header carries `held` so the popup can find the Held
// heading without comparing the title against the literal "Held", which a translator will change.
function rowsOf(sections, heldItems) {
    var rows = [], i, j;
    for (i = 0; i < sections.length; i++) {
        rows.push({ kind: "header", title: sections[i].title, held: false });
        for (j = 0; j < sections[i].items.length; j++) rows.push(rowOf(sections[i].items[j], "item"));
    }
    // Held last and always its own group: the spec's promise is that a held item stays VISIBLE
    // with its waiting version, just out of the way of the things you can act on.
    if (heldItems.length > 0) {
        rows.push({ kind: "header", title: "Held", held: true });
        for (i = 0; i < heldItems.length; i++) rows.push(rowOf(heldItems[i], "item"));
    }
    return rows;
}

function rowOf(item, kind) {
    return { kind: kind, title: "", name: item.name, from: item.from, to: item.to,
             held: item.held, backend: item.backend };
}

// --- the last run --------------------------------------------------------------------------------
// Everything below reads ONE history entry, served byte for byte by `kempt summary --json` rather
// than re-rendered, so what arrives is what cmd_update wrote:
//   {timestamp, surface, status, duration_sec, reboot_needed, log, error,
//    backends: {<name>: {updated:[{name,from,to}], added:[{name,to}], removed:[{name,from}],
//                        status, skipped_held:[]}}}
// Re-deriving any of this from the human summary text would be a second, lossier copy of
// render_summary's rules living in the widget. Hence --json.

// lastRunOf(text) -> the last run as data, or null.
// null means "no last run", and every caller must render NOTHING for it - never a fabricated empty
// run. Same contract `kempt summary --json` keeps: with no history it prints empty stdout under
// exit 0, because a box that has never updated has not "updated 0 packages".
// Every field tolerates absence, because history entries outlive the build that wrote them. The
// one field that is deliberately NOT optimistic is `failed`: a status we cannot read is not a
// success, and the cost of the two mistakes is not symmetric.
function lastRunOf(text) {
    // The same tolerant parse the state file gets: empty, whitespace, truncated, a bare number and
    // a JSON array all mean "we learned nothing".
    var entry = parseState(text);
    if (entry === null) return null;

    var backends = (entry.backends && typeof entry.backends === "object") ? entry.backends : {};
    var keys = backendKeys(backends);
    var items = [], updated = 0, added = 0, removed = 0, i, j, backend, up, item;
    for (i = 0; i < keys.length; i++) {
        backend = backends[keys[i]];
        if (!backend || typeof backend !== "object") continue;
        up = arrayOf(backend.updated);
        for (j = 0; j < up.length; j++) {
            item = up[j] || {};
            // newestOf on both sides: a multilib pair or an installonly kernel set arrives
            // comma-joined and the popup's own rows already render the last element, so anything
            // else here would be the same package rendered two ways on one screen.
            items.push({ name: item.name === undefined || item.name === null ? "" : String(item.name),
                         from: newestOf(item.from), to: newestOf(item.to) });
        }
        updated += up.length;
        added += arrayOf(backend.added).length;
        removed += arrayOf(backend.removed).length;
    }

    var status = typeof entry.status === "string" ? entry.status : "";
    var when = typeof entry.timestamp === "string" ? entry.timestamp : "";
    return {
        when: when,
        whenStamp: formatStamp(when),
        surface: typeof entry.surface === "string" ? entry.surface : "",
        status: status,
        failed: status !== "ok",
        error: typeof entry.error === "string" ? entry.error : "",
        // null when the entry does not say, NOT 0 - 0 is a real duration here. The CLI writes
        // `$(date +%s) - start`, so any run finishing inside a second records zero, and collapsing
        // absent onto zero puts "in 0s" on a run this build had no timing for.
        durationSec: (typeof entry.duration_sec === "number" && isFinite(entry.duration_sec))
            ? entry.duration_sec : null,
        updatedCount: updated,
        addedCount: added,
        removedCount: removed,
        // Installs and removals changed the machine as much as upgrades did, and the CLI counts
        // them (run_counts_phrase). Counting only upgrades announces "No package changes" after a
        // transaction that added two.
        changedCount: updated + added + removed,
        items: items,
        logPath: typeof entry.log === "string" ? entry.log : "",
        // Strictly the boolean. This entry's reboot_needed is a fact about THAT RUN, not about now
        // - the state file carries the live answer - so nothing renders an affirmative from it.
        rebootNeeded: entry.reboot_needed === true
    };
}

// postRunLine(run) -> the transient line shown once, right after a run finishes.
// A failed run is reported as failed WHATEVER its counts say: a transaction that upgraded four
// packages and then died is a failure, and "Updated 4 packages" is the worst thing to say about it.
function postRunLine(run) {
    if (!run) return "";
    if (run.failed) {
        // The CLI's own worked-out reason (run_failure_reason), not a generic apology - first line
        // only, because a panel is one line wide and the log is one click away.
        var why = firstLineOf(run.error);
        return why === "" ? COPY.updateFailed : COPY.updateFailed + ": " + why;
    }
    // The staging run's entry has empty package lists BY CONSTRUCTION - nothing changes until the
    // restart - so the count sentences below would call it "No package changes": true about the
    // rpm set and no answer to what the person just did. Exact match, never a prefix: the harvest
    // writes "offline (applied on reboot)" and its counts are real changes.
    if (run.surface === "offline") return COPY.stagedUnknownCount;
    var n = typeof run.changedCount === "number" ? run.changedCount : 0;
    if (n === 0) return COPY.noPackageChanges;
    // The duration is a CLAUSE, not a field with a default: a run whose entry does not say how
    // long it took is described without it rather than described as instantaneous.
    var secs = run.durationSec;
    var howLong = (typeof secs === "number" && isFinite(secs)) ? " in " + secs + "s" : "";
    return "Updated " + n + (n === 1 ? " package" : " packages") + howLong;
}

// runFinishedSince(run, sinceMs) -> is this entry the run we just watched finish?
// `kempt summary --json` answers with the newest entry it can read; the CLI is the primary guard
// and this is the belt to those braces, covering what the CLI cannot see - a summary answered from
// a history directory that has not caught up yet.
//
// SECOND resolution on both sides, not as a rounding convenience: the CLI stamps entries with
// `date -Iseconds`, so a run that took 400ms carries a stamp truncated to the second it finished
// in, which can be numerically BELOW the millisecond clock noted when the run started. Full
// precision would silently drop the line for the fastest runs, which are the ordinary ones.
//
// A stamp that cannot be read answers NO, unlike every other field of an entry (see lastRunOf):
// this question is about identity. It costs only the transient line - the persistent Last update
// row is bound to `lastRun`.
function runFinishedSince(run, sinceMs) {
    if (!run) return false;
    // No moment to compare against - a widget that never saw this run start - means the question
    // does not apply rather than that the answer is no.
    if (typeof sinceMs !== "number" || !isFinite(sinceMs) || sinceMs <= 0) return true;
    var at = stampMs(run.when);
    if (!isFinite(at)) return false;
    return Math.floor(at / 1000) >= Math.floor(sinceMs / 1000);
}

// lastRunText(run, nowMs) -> the persistent Last update row's title.
// The counting phrases are built here rather than kept in COPY because they are grammar around a
// number, not a wording decision. The zero case is the exception: "no package changes" is the
// CLI's own wording, emitted verbatim by KEMPT_JQ_COUNTS in lib/common.sh, and this line quotes
// the terminal (lowercase because it sits mid sentence after the dot). Do NOT reword it here
// alone - the tests tie all three spellings together.
function lastRunText(run, nowMs) {
    if (!run) return "";
    // An entry we cannot DATE gets no row. relativeTime answers "never" for a missing stamp, so
    // the sentence would describe a run in the same breath as denying there was one; an unreadable
    // stamp pastes "not a date" into an English sentence. WHEN it happened is the one thing this
    // line exists to say. A test of the STAMP, not of relativeTime's output: with an unusable
    // clock relativeTime falls back to the absolute stamp, which is a perfectly good row.
    if (!isRenderableStamp(run.when)) return "";
    // The staging run, between the stage and the restart: its zero counts are true and misleading,
    // same reasoning as postRunLine. `failed` is checked because this row otherwise ignores
    // failure, and a staging run that FAILED staged nothing. Exact match on "offline" - the
    // harvest's surface is "offline (applied on reboot)" and its counts render.
    if (!run.failed && run.surface === "offline") {
        return "Last update " + relativeTime(run.when, nowMs) + DOT + "staged for restart";
    }
    var n = typeof run.changedCount === "number" ? run.changedCount : 0;
    var what = n === 0 ? "no package changes" : (n === 1 ? "1 package" : n + " packages");
    return "Last update " + relativeTime(run.when, nowMs) + DOT + what;
}

// viewModel(state, updating, cliError, opts) -> everything the QML layer binds to. Called on every
// state change; the QML side holds no derived state of its own.
//
// `opts` and every field in it are optional, so the three-argument call keeps working. It carries
// the facts that are not in the state file:
//   nowMs            - the clock. Absent means every relative time falls back to its absolute
//                      stamp rather than guessing.
//   restartReminder  - the `restart_reminder` config value. ABSENT is not false: the caller did
//                      not say, and the CLI's default is true. Read with isTrue, because config
//                      values arrive as text.
//   restartDismissed - closed in THIS plasmashell session. Nothing persists it, by design.
//   engineMissing    - no CLI on the box (main.qml reads rc 127/126). Strictly `=== true`, because
//                      it replaces the popup's whole body. A separate input rather than a magic
//                      cliError value: "we could not get an answer" and "there is nothing here to
//                      answer" are different facts.
//
// cliError is the widget's own report of a check that produced nothing usable; a failure INSIDE
// `kempt check` arrives in the state's own `error` field and comes out as staleReason.
//
// iconState is decided in this order, and the order is the contract. Two steps answer `unknown`,
// which is not an oversight: "the engine is not installed" and "the first check has not finished"
// are different sentences about the same honest verdict, and the panel has no idea what is pending
// in either.
//   updating          - we started a run; it wins over whatever the last check said
//   unknown (engine)  - no engine and nothing to show. NOT the error state; see the branch
//   error             - no state AND the CLI failed us, or an object that is not schema v1
//   unknown (no data) - no state, but nothing has gone wrong yet (first load, still checking)
//   stale             - the last check failed; the counts below are the last known good ones
//   updates           - actionable > 0
//   uptodate          - actionable == 0 (held items do not count: spec, Holds semantics)
//
// "stale" is deliberately NOT an error: the counts are the best known truth and the user does not
// need alarming about a repo that flapped, so the panel keeps rendering the CONTENTS and the
// explanation goes in the tooltip. Only "we cannot read this at all" earns a warning emblem.
function viewModel(state, updating, cliError, opts) {
    updating = !!updating;
    cliError = firstLineOf(typeof cliError === "string" ? cliError : "");
    opts = (opts && typeof opts === "object") ? opts : {};
    var engineMissing = opts.engineMissing === true;
    var usable = looksLikeState(state);
    var counted = collectItems(usable ? state : null);
    var stale = usable && state.status === "stale";

    // The count and the list under it are ONE answer, and the walk is what produces the list. The
    // CLI's totals come from the same items this file walks (lib/common.sh:
    // `[.[] | select(.held|not)] | length`), so the two can only disagree when something is wrong,
    // and whatever the cause the ROWS are what the person is looking at. The totals are still the
    // answer when there is nothing to walk: a state with counts and no items is a state with no
    // list, and reading it as zero is the confident-zero mistake rule 1 exists to prevent.
    var walked = counted.sections.length > 0 || counted.heldItems.length > 0;
    var actionable = usable
        ? (walked ? counted.actionable
                  : (typeof state.actionable === "number" ? state.actionable : counted.actionable))
        : null;
    var heldTotal = usable
        ? (walked ? counted.heldTotal
                  : (typeof state.held_total === "number" ? state.held_total : counted.heldTotal))
        : null;

    var noState = (state === null || state === undefined);
    var everSucceeded = usable && typeof state.last_success === "string" && state.last_success.trim() !== "";
    var nothingKnown = counted.sections.length === 0 && counted.heldItems.length === 0;

    // Calm-stale is for a FLAP OVER KNOWN COUNTS: we had an answer, this check failed, the old
    // numbers stand. A box that has never had a successful check has no counts to be calm about -
    // "up to date" there is a clean lie, and it is exactly what a box whose root helpers were
    // never installed looks like. That belongs with the errors.
    var neverAnswered = usable && stale && !everSucceeded && nothingKnown;

    var iconState;
    if (updating) iconState = "updating";
    // A SETUP STEP, not a malfunction. `error` is the panel's alarm - CompactRepresentation hangs
    // a warning emblem off the icon - and that is a statement about a machine that cannot be
    // trusted; alarming a first-timer trains them to ignore the emblem for the day it means
    // something. `uptodate` would be worse: knowing nothing and rendering a clean icon is the
    // confident zero rule 1 forbids. `unknown` renders dimmed with no emblem, which is exactly
    // what is true. Only where there is nothing else to show - with counts from an earlier working
    // engine the rows are still the best truth there is, and they keep their own state below.
    else if (engineMissing && noState) iconState = "unknown";
    else if (noState && cliError !== "") iconState = "error";
    else if (noState) iconState = "unknown";
    else if (!usable) iconState = "error";
    else if (neverAnswered) iconState = "error";
    else if (stale) iconState = "stale";
    else if (actionable > 0) iconState = "updates";
    else iconState = "uptodate";

    // No count, no badge: rule 1 in one line, "no data" must never reach the panel as a confident
    // zero. Capped at BADGE_MAX because a four-digit badge is a layout problem in a panel; it
    // stays truthful, and the exact number is one hover away in a tooltip that is never capped.
    var badgeText = "";
    if (usable && actionable > 0) badgeText = actionable > BADGE_MAX ? BADGE_MAX + "+" : String(actionable);

    var countPhrase = "";
    if (usable) {
        // "Up to date" over rows with waiting versions in them is a lie by omission, which is what
        // a box whose every pending update is held would draw. Nothing is ACTIONABLE, which is
        // what the badge and the button are about; the header is the sentence, and the sentence
        // owes the held count.
        countPhrase = actionable === 0
            ? (heldTotal > 0 ? COPY.upToDate + DOT + heldTotal + " " + COPY.held : COPY.upToDate)
            : (actionable === 1 ? "1 update available" : actionable + " updates available");
    }

    // --- a transaction that is already staged and armed ------------------------------------------
    // Derived HERE, above the header, because it changes what the header may say: while a stage is
    // armed the pending count is a true number saying a false thing. Nine of the returned fields
    // depend on it.
    //
    // heldDnf is walked out of the items collectItems already built rather than re-read from the
    // state: those rows are what the popup is SHOWING as held, and a banner whose warning
    // disagreed with the Held group under it would contradict itself in one glance.
    var heldDnf = false;
    for (var h = 0; h < counted.heldItems.length; h++) {
        if (counted.heldItems[h].backend === "dnf") { heldDnf = true; break; }
    }
    var stagedVariant = stagedVariantOf(usable ? state.offline_staged : null, heldDnf);
    var stagedMessage = stagedVariant.message;
    var staged = stagedMessage !== "";
    // The flip, in one boolean. Everything downstream reads THIS rather than re-testing the
    // variant, so "which banner is this" is decided in exactly one place.
    var stagedWarning = stagedVariant.type === "warning";

    // What to DO about a session-critical set, which is a different question from how big it is.
    // Silent while a transaction is already staged: this message IS the "Install on Next Restart"
    // offer, and offering it over an armed transaction invites a second staging of the same
    // updates. riskySummary is deliberately NOT silenced - those packages really are still pending
    // until the restart runs.
    // isArray, not a duck-typed length check: a STRING has a numeric length and indexes into its
    // own characters, so `risky_pending: "kernel-core"` would walk out of here as "11
    // session-critical pending (c, e, k, l, ...)".
    var riskyMessage = staged ? "" : riskyMessageOf(
        usable && isArray(state.risky_pending) ? state.risky_pending : []);

    // Strictly the boolean, and only out of a state this build can read. In this schema `false`
    // means "nothing to say", NEVER "no restart needed": backends/dnf.sh's dnf_reboot_needed
    // answers false plus a warning whenever it could not work the verdict out - rc 1 with empty
    // stdout (a cold user cache, the DEFAULT on a fresh install) and every unexpected rc land
    // there. So a false is indistinguishable from "we could not tell", and nothing renders an
    // affirmative from it. docs/architecture.md states the same rule for every reader.
    // Derived up here rather than with the restart message below, because the panel tooltip reads
    // it too.
    var rebootNeeded = usable && state.reboot_needed === true;

    var tooltipMain, headerText;
    if (updating) {
        tooltipMain = COPY.updatingHere;
        headerText = COPY.updatingHere;
    } else if (engineMissing) {
        // Names the missing piece instead of quoting the shell: `sh: line 1: kempt: command not
        // found` is true, unreadable, and about a program the reader has never heard of.
        tooltipMain = "Kempt";
        headerText = "Kempt's engine is not installed";
    } else if (iconState === "unknown") {
        tooltipMain = "Kempt";
        headerText = "No update data yet";
    } else if (iconState === "error") {
        tooltipMain = "Kempt";
        headerText = (cliError !== "" || neverAnswered)
            ? "Kempt cannot check for updates"
            : "Could not read the update state";
    } else if (staged) {
        // The one place the count gives way. Not a second line under it and not a badge emblem:
        // the header is the sentence a person reads first, and while a stage is armed the honest
        // answer to "where do I stand" is that the work is done and waiting for a restart.
        headerText = stagedHeaderOf(state.offline_staged);
        tooltipMain = headerText;
    } else {
        tooltipMain = countPhrase;
        headerText = countPhrase;
    }

    var lastSuccessText = usable ? formatStamp(state.last_success) : "";
    var staleReason = stale
        ? (typeof state.error === "string" && state.error !== "" ? state.error : "the last check failed")
        : "";

    // The one sentence an error state owes the user, in descending order of how much it knows.
    var problemText = "";
    if (iconState === "error") {
        if (cliError !== "") problemText = cliError;                 // we could not run the CLI
        else if (neverAnswered) problemText = staleReason;           // it ran, and told us why not
        else problemText = "the update state could not be read";     // it answered something else
    }

    // The whole answer for a box with no engine, assembled here so the popup binds one string:
    // what is true, then what to type. Empty in every other state, which is what the popup gates
    // on - and the same for the clipboard text, whose button only exists while the message does.
    var engineMissingMessage = engineMissing
        ? COPY.engineMissing + "\n" + COPY.engineMissingInstall : "";
    var engineMissingCopyText = engineMissing ? COPY.engineMissingCopy : "";

    // Read only out of a state this build can read, like every optional key: a schema-1 reader
    // tolerates the key being absent (every file written before this existed) and being the wrong
    // type. formatDownload answers "" to both.
    var downloadText = usable ? formatDownload(state.download_bytes) : "";

    var subParts = [];
    // The fact, and only the fact. The install commands belong in the popup, where they can be
    // read and copied; two command lines under a panel hover is noise.
    if (engineMissing) subParts.push(COPY.engineMissing);
    else if (iconState === "unknown") subParts.push("no data yet - the first check has not finished");
    else if (iconState === "error") subParts.push(problemText);
    else {
        // The Holds promise: a box whose only pending updates are held LOOKS up to date, and the
        // tooltip is where it still says the held ones exist.
        if (heldTotal > 0) subParts.push(heldTotal + " " + COPY.held);
        // Only with something to download AND something to press. On an up-to-date box the number
        // is zero or absent; next to a held-only list it would describe bytes no run will fetch.
        if (actionable > 0 && downloadText !== "") subParts.push(downloadText + " to download");
        // Staleness is a tooltip fact, not an icon alarm, so the tooltip carries BOTH halves: what
        // went wrong, and how old the numbers above it therefore are.
        if (stale) {
            subParts.push(staleReason);
            subParts.push("last successful check: " + lastSuccessText);
        }
        // A pending restart is the one fact needing an action from the person; without this line
        // it could only be found by opening the popup. Last, because it is about the machine
        // rather than about the counts above it.
        if (rebootNeeded) subParts.push(COPY.restartPending);
    }

    // What the popup shows where the list would be, when there is no list to show.
    var emptyStateText = "";
    if (updating) emptyStateText = "";
    // Silent, and that silence keeps the popup from saying one thing twice: the engine-missing
    // message already carries the whole answer, and the placeholder's own sentence ("the first
    // check has not finished") would be a promise about a check that will never finish. The
    // placeholder hides itself on empty text.
    else if (engineMissing) emptyStateText = "";
    else if (iconState === "unknown") emptyStateText = "No update data yet. The first check has not finished.";
    else if (iconState === "error") emptyStateText = problemText;
    else if (nothingKnown) {
        emptyStateText = stale ? "No updates in the last known state." : COPY.everythingUpToDate;
    }

    // The one thing a stuck user can usefully be told to type - offered ONLY where the widget has
    // nothing else to show. NOT on calm staleness: keeping quiet about a repo that flapped is the
    // point of that state, and staleReason already names doctor when that is what is wrong. NOT
    // when the engine is missing either, which is the case that proves the rule: `kempt doctor` is
    // a kempt subcommand, so on the box where kempt is what is absent this would tell the user to
    // run the very thing they do not have.
    var remedyCommand = (!engineMissing && (cliError !== "" || neverAnswered)) ? "kempt doctor" : "";

    // --- the restart, and what the popup is allowed to say about it -----------------------------
    // `rebootNeeded` itself is derived above, next to the tooltip that reads it.
    // Absent is not false: the caller simply did not say, and the CLI's default is true.
    var restartReminder = (opts.restartReminder === undefined || opts.restartReminder === null)
        ? true : isTrue(opts.restartReminder);
    var restartMessageVisible = rebootNeeded && restartReminder && !isTrue(opts.restartDismissed);

    // --- which messages actually fit ------------------------------------------------------------
    // Decided HERE and not in the popup, because the footer depends on the answer: a restart the
    // cap displaced has to reappear as "restart pending" on the status line, and a popup deciding
    // this by itself would leave logic.js unable to tell whether it had.
    // `reportShown` is the one input this file cannot derive - the post-run line and a failed press
    // are main.qml's own state, not the CLI's.
    var messageSlots = messageStack({
        engineMissing: engineMissingMessage !== "",
        report: opts.reportShown === true,
        // ...including `updating`, because a run hides the whole stack. Without it the popup's own
        // dismissal guard could not tell a run starting from the user closing the message.
        restart: restartMessageVisible && !updating,
        staged: staged,
        kernel: riskyMessage !== ""
    });
    var restartShown = messageSlots.indexOf("restart") >= 0;

    // --- the footer status line ------------------------------------------------------------------
    // "Checked ..." is derived from last_success and NOT last_check, because the counts above it
    // are as of the last check that told us something; dating them by a failed check would put a
    // fresh time on stale numbers. The fallback is worded off last_success too: this line is a
    // DATELINE for the counts, and "Not checked yet" would conflate "no counts of any age" with a
    // box that never ran a check - the two differ precisely on the bad day, where a stale state
    // carries a last_check and an empty last_success.
    var footerParts = [];
    if (usable) {
        // Three answers, and the third is silence. A stamp that is present and unreadable gives
        // relativeTime nothing to work with, so it hands the text back verbatim - right for a
        // tooltip, wrong in a sentence, where it reads "Checked not a date". The raw stamp stays
        // one hover away in footerTooltip.
        if (!everSucceeded) footerParts.push(COPY.noSuccessfulCheckYet);
        else if (isRenderableStamp(state.last_success)) {
            footerParts.push("Checked " + relativeTime(state.last_success, opts.nowMs));
        }
        // ...and the staleness, beside the date it explains. Not an alarm - the counts above are
        // still the best known truth - with the CLI's reason one hover away on the retry button.
        if (stale) footerParts.push(COPY.lastCheckFailed);
    } else if (noState) {
        // No state at all - the first seconds of a session, or a CLI that could not be run. There
        // has been no successful check as far as this widget knows, and saying so is true.
        footerParts.push(COPY.noSuccessfulCheckYet);
    }
    // ...and the case with no branch: a state we HOLD and cannot read (a schema this build does
    // not know). It may well record a successful check; we cannot tell, and the header already
    // says the state could not be read.
    if (heldTotal > 0) footerParts.push(heldTotal + " " + COPY.held);
    // Beside Update Now, which is the question it answers: pressing this costs about this much.
    // Same two conditions as the tooltip, and the same silence when either fails.
    if (actionable > 0 && downloadText !== "") footerParts.push(downloadText);
    // ...and the restart, whenever the message is not carrying it - including one the CAP
    // displaced, which is what makes displacing it honest rather than merely quiet. With the
    // reminder off, or dismissed for this session, this line is the only place it is said.
    if (rebootNeeded && !restartShown) footerParts.push(COPY.restartPending);

    return {
        iconState: iconState,
        badgeText: badgeText,
        badgeVisible: badgeText !== "",
        tooltipMain: tooltipMain,
        tooltipSub: subParts.join(" - "),
        headerText: headerText,
        sections: counted.sections,
        heldItems: counted.heldItems,
        rows: rowsOf(counted.sections, counted.heldItems),
        actionable: actionable,
        heldTotal: heldTotal,
        stale: stale,
        // "" when fine; otherwise the CLI's own error text, so the popup says what actually went
        // wrong instead of a generic apology.
        staleReason: staleReason,
        cliError: cliError,
        // The fact, then the commands that fix it, on two lines. Empty means there is nothing to
        // say, and that empty string is the popup's only gate - exactly how riskyMessage and
        // stagedMessage already work.
        engineMissingMessage: engineMissingMessage,
        engineMissingCopyText: engineMissingCopyText,
        emptyStateText: emptyStateText,
        remedyCommand: remedyCommand,
        // isArray, not a duck-typed length check - see the riskyMessage derivation above for what
        // a string in this key otherwise renders as. These two must agree about the same key.
        riskySummary: riskySummaryOf(
            usable && isArray(state.risky_pending) ? state.risky_pending : []),
        riskyMessage: riskyMessage,
        stagedMessage: stagedMessage,
        // "there is an armed transaction", for the surfaces that have to stand down rather than
        // say something about it. Update Now is hidden on this: pressing it over an armed stage
        // starts a second, live update of the same packages.
        stagedArmed: staged,
        // "positive" for the ordinary armed stage, "warning" once a hold has landed behind it. A
        // string rather than a boolean because the QML binds it to a Kirigami.MessageType, and a
        // third spelling is a plausible next state for this banner rather than an exotic one.
        stagedType: stagedVariant.type,
        // Never two Restart… buttons in one popup: the restart Warning already carries one
        // whenever it is on screen.
        // ...and never a Restart… on a warning variant at all, which is the stricter rule and the
        // reason the flip is worth anything: the person is looking at a sentence saying the next
        // restart will install the package they tried to keep out.
        stagedShowRestart: staged && !restartMessageVisible && !stagedWarning,
        // ...and what stands in its place. Only on the variants where there is something to
        // change: rebuilding an ordinary armed stage would destroy a good transaction (spec G2) to
        // produce the same one back.
        stagedShowRebuild: stagedWarning,
        // Published rather than left as a literal in the QML's Accessible.description, so the
        // words a screen reader hears and the words the tooltip shows are one decision. The QML
        // still writes the literal for i18n extraction; the probe ties the two together.
        stagedRebuildTooltip: COPY.stagedRebuildTooltip,
        // The stamp this banner was derived from, for main.qml's click-time re-verify. Consent is
        // given to a BANNER, and a banner describes ONE transaction: between render and click it
        // can be consumed by a restart, replaced or cleaned away, and a rebuild is destructive at
        // its start. "" means there is nothing to compare, which the re-verify reads as "do not
        // act".
        stagedStagedAt: stagedVariant.stagedAt,
        // The names behind the sentence. The banner shows the first and a count; anything that has
        // to say them again takes them from here rather than parsing them out of the sentence.
        stagedConflictNames: stagedVariant.conflictNames,
        lastSuccessText: lastSuccessText,
        rebootNeeded: rebootNeeded,
        restartMessageVisible: restartMessageVisible,
        // ...and whether that message may carry its own Restart button. Everywhere else it may: a
        // restart applies updates that are already installed. NOT while the staged banner is a
        // warning - in that state a restart installs the very package the warning says the person
        // tried to keep out.
        restartShowAction: restartShown && !stagedWarning,
        // Which messages the popup may draw, in order, and never more than two. The rule and its
        // reasons are messageStack above.
        messageSlots: messageSlots,
        footerText: footerParts.join(DOT),
        // Published rather than left inside the two strings above, so a future surface (a
        // notification, a `check --human` line) renders the same words instead of its own.
        downloadText: downloadText,
        // The relative time in footerText is the convenience; this is the truth, and people
        // compare the two. Empty rather than "never" when there has been no successful check: the
        // footer already says so in words.
        footerTooltip: everSucceeded ? lastSuccessText : ""
    };
}

// The node half of the double life. `module` does not exist in QML's JS engine, so this is a
// no-op there; typeof on an undeclared name is safe in every engine.
if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        COPY: COPY,
        VERSION_UNKNOWN: VERSION_UNKNOWN,
        fromTextOf: fromTextOf,
        parseState: parseState,
        viewModel: viewModel,
        newestOf: newestOf,
        familiesOf: familiesOf,
        formatStamp: formatStamp,
        formatDownload: formatDownload,
        relativeTime: relativeTime,
        shouldRefreshOnOpen: shouldRefreshOnOpen,
        riskyMessageOf: riskyMessageOf,
        stagedMessageOf: stagedMessageOf,
        stagedVariantOf: stagedVariantOf,
        messageStack: messageStack,
        MESSAGE_CAP: MESSAGE_CAP,
        lastRunOf: lastRunOf,
        postRunLine: postRunLine,
        runFinishedSince: runFinishedSince,
        lastRunText: lastRunText,
        shellQuote: shellQuote,
        firstLineOf: firstLineOf,
        rowsOf: rowsOf,
        isTrue: isTrue,
        resolveSurface: resolveSurface,
        effectiveSurfaceOf: effectiveSurfaceOf,
        updatingLabelOf: updatingLabelOf,
        SURFACES: SURFACES,
        holdsOf: holdsOf,
        lastLinesOf: lastLinesOf,
        snapIconSize: snapIconSize,
        resolveIconSize: resolveIconSize,
        resolveIconSizeSetting: resolveIconSizeSetting,
        ICON_STEPS: ICON_STEPS,
        watchChange: watchChange,
        watchFieldsOf: watchFieldsOf,
        WATCH_FIELDS: WATCH_FIELDS,
        watcherCheckDue: watcherCheckDue,
        CHECK_QUIET_MS: CHECK_QUIET_MS
    };
}
