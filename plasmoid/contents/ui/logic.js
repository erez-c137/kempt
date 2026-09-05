// logic.js - the widget's entire derivation layer, in ENGINE-AGNOSTIC JavaScript.
//
// Loaded twice, from two different worlds:
//   * the plasmoid, with `import "logic.js" as Logic` (QML's own JS engine), and
//   * tests/test_widget_logic.sh, with node, through the CommonJS guard at the bottom.
// That is the whole point: a QML plasmoid cannot be executed in a test suite, so every rule the
// panel shows a human - the badge number, the icon state, the tooltip, the popup rows - is
// derived HERE, where a node test can pin it. Nothing in this file may touch Qt, i18n, the
// filesystem or a network: it takes the CLI's state JSON in and returns plain data out.
//
// Deliberately NOT `.pragma library`: that pragma is not valid JavaScript, so it would stop node
// from loading this file at all and take the tests with it. The functions are pure, so the only
// thing the pragma would buy (one shared copy) buys nothing here.
// Deliberately old-school JS (var, function expressions, indexOf): this has to run unchanged in
// whatever JS engine the installed Plasma version ships.
//
// Input contract: state schema v1 (docs/architecture.md), the CLI's frozen public interface.
// Two rules from that document are load-bearing and are enforced below:
//   1. empty stdout with exit 0 means "no data, keep the last known state", NEVER "zero updates";
//   2. `status: "stale"` keeps the last known counts - it is a tooltip fact, not a fabricated 0.

// Section titles match the CLI's own summary renderer (lib/common.sh render_summary) so the
// popup and the terminal never name the same group differently.
var SECTION_TITLES = { dnf: "System (dnf)", flatpak: "Apps (flatpak)" };
var BACKEND_ORDER = ["dnf", "flatpak"];

// --- the copy table ----------------------------------------------------------------------------
// Every user-facing string the QML writes as a literal, in ONE place, so the wording is decided
// once and a node test can pin it. House rules, from the KDE HIG review in
// docs/research/2026-08-26-popup-panel/hig-review.md:
//   * Title Case for buttons, sentence case for messages.
//   * A real ellipsis (U+2026) on a label that opens something else, never three ASCII dots -
//     P5 of that review calls the three dots the one typographic tell that a widget was not
//     written by KDE.
//   * No em dashes anywhere (project rule).
//   * "held", never "held back": the CLI's section is Held, the command is `kempt hold`, and the
//     tooltip already says "N held". One vocabulary across the widget and the terminal.
//
// IMPORTANT, and it is not what it looks like: the QML side does NOT read these at runtime. It
// keeps writing the literal, `i18n("Update Now")`, because translation extraction works on
// LITERALS - `i18n(Logic.COPY.updateNow)` extracts nothing at all and ships an untranslatable
// widget. So this table is the SPECIFICATION and the place the wording is agreed and tested; the
// QML repeats the same literal, and a later task adds a test asserting every value here appears
// verbatim in the .qml files. Do not "fix" that duplication by routing these through i18n().
//
// So what this table holds is exactly one category, and it is worth being plain about the one it
// does NOT hold, because that omission is structural rather than an oversight. viewModel's
// footerText, and lastRunText, postRunLine and relativeTime, ASSEMBLE sentences right here -
// "Checked 4 min ago", "Last update 3 days ago", "Updated 7 packages in 41s", "no package
// changes" - and hand the finished string to a QML binding. QML cannot wrap an assembled string
// in i18n() at all, so those words are not translatable today, and moving their fragments into
// this table would not make them so: a fragment is not a translatable unit, and the plural and
// word-order rules that would turn it into one do not exist in this widget. Building them is a
// real design question for a later release (a message-format layer, with its own plural
// handling), not something to improvise into a copy table. What IS available without one is an
// exact test of every assembled shape, and tests/test_widget_logic.sh has one for each.
var COPY = {
    // Header, and the placeholder under it. Deliberately NOT the same sentence: the popup would
    // otherwise say the same words twice in one glance (user panel, redundancy finding).
    upToDate: "Up to date",
    everythingUpToDate: "Everything is up to date",

    // The restart message and its button. `restartMessage` states a fact about the machine;
    // `restartAction` opens KDE's own logout/restart prompt and nothing else - Kempt never
    // restarts anything itself, in any state, with any setting.
    restartMessage: "Restart to apply installed updates",
    restartAction: "Restart…",
    restartFailed: "Could not open the restart prompt.",

    // The two actions. Refresh is icon-only in the header, so this is its tooltip and its
    // accessible name as well as its entry in the contextual-actions menu.
    checkForUpdates: "Check for Updates",
    updateNow: "Update Now",

    // ...and what those two icon-only buttons DO, which is a different question from what they
    // are called. `text` is already the accessible name of an icon-only button, so a description
    // bound to `text` was the label read back twice and the one slot that could explain the
    // effect, wasted (hostile panel, a11y P4). Same rule as the pin's two below.
    checkForUpdatesDescription:
        "Asks dnf and flatpak what is pending now, instead of waiting for the timer.",
    configureDescription:
        "Check interval, where updates run, restart reminders, and the packages you hold.",

    // --- the pin ---------------------------------------------------------------------------------
    // The name carries the STATE, and that is a decision with a residual. A `checkable: false`
    // button exposes no checked state to AT-SPI on Qt 6.11 (measured), and the one role that does
    // - CheckBox - makes Breeze draw its sunken checked background on a control sitting directly
    // under the system tray's own checked Keep Open pin. So the state is words: these four
    // sentences, plus the "Held" token on the row and the glyph.
    //
    // TWO PAIRS, because a package that is not installed yet has no current version to be held AT.
    // The CLI writes "?" for that `from`, and "Hold brandnew at ?" is not a sentence; what the pin
    // does there is refuse the install, which is what it says.
    holdAt: "Hold %1 at %2",
    stopHolding: "Stop holding %1",
    skipInstalling: "Skip installing %1",
    stopSkipping: "Stop skipping %1",
    // The description is the CONSEQUENCE. Per package, and Kempt only - a dnf user reads
    // versionlock into a padlock, and this is where that is answered.
    holdConsequence: "Kempt skips it on every update until you stop holding it.",
    heldConsequence: "Kempt offers its update again.",
    // The state, in words, on the row itself. The only cues used to be a glyph, a position and a
    // 0.7 opacity dip - and an opacity dip is a contrast REDUCTION, which is the wrong direction
    // for the rows a person deliberately protected (a11y P6).
    heldToken: "Held",
    // What a row draws where the CLI wrote "?" - a package that is not installed yet, whose update
    // would ADD it. "? → 9.9.9-1.fc44" reads as "the widget does not know", on every row of a
    // fresh box (hostile panel, first-run and a11y S4). The DATA keeps the "?": it is the CLI's
    // own sentinel and the padlock recognises it too.
    versionNew: "new",
    // ...and the one line the Held heading owes a first-timer. A hold is Kempt's own list; it does
    // not touch `dnf upgrade`, and nothing anywhere said so.
    heldKemptOnly: "Held packages are skipped by Kempt only.",
    // The version line as a sentence. On screen it is "3.105-… → 3.106-1.fc44", and that arrow
    // goes through a screen reader's character table as a word nobody wants to hear.
    versionRange: "from %1 to %2",

    // --- the pane a run replaces the popup with ---------------------------------------------------
    // It used to read "Updating in the %1 surface…", filled in with the CONFIGURED surface rather
    // than the one the run is actually using - and "surface" is a word nobody outside this repo
    // knows (hostile panel, first-run vocabulary). One sentence per surface, each naming where to
    // look, and staging says what it is rather than calling itself an update.
    updatingTerminal: "Updating in a terminal window…",
    updatingBackground: "Updating in the background…",
    updatingHere: "Updating…",
    updatingOffline: "Preparing the install for the next restart…",
    // ...and the way out. A terminal run that is aborted or whose window is closed never writes
    // state.json, and only a state.json change ends the widget's updating state - so the popup sat
    // on an empty pane, with no list, no Update Now and a disabled Refresh, until a three-hour
    // guard fired. On the default configuration that is what happens when a first-timer takes the
    // default answer to the one question Kempt asks (hostile panel, finding 1).
    notUpdatingCheckAgain: "Not updating? Check again",

    // The offline path, named for what it does to the user rather than for the dnf5 flag that
    // implements it. The tooltip is the whole argument for choosing it.
    installOnNextRestart: "Install on Next Restart",
    installOnNextRestartTooltip:
        "Applies the update during a restart, so nothing changes underneath your running desktop.",

    // What a session-critical transaction is told to do about it. Four spellings, because two
    // things vary: whether a kernel is in the set, and whether the NVIDIA driver is with it (a box
    // with that driver has a second, worse failure mode - a kernel module built against a kernel
    // that is not the running one - and naming it is what makes the advice credible).
    //
    // "Restart when it finishes." is gone, and it is the sentence this whole message existed to
    // fix. It recommended the LIVE path while the only button underneath it offered the offline
    // one, over an amber box, before anything had started - so a first-timer read an order to
    // restart now and had no idea what "it" was (hostile panel, first-run 3). What replaces it
    // says what the button does and why: install on the next restart, so nothing changes under the
    // desktop that is running. The message type goes with it, from Warning to Information: nothing
    // is wrong, there is a safer of two ways to do this.
    kernelRestart:
        "This update includes a kernel. The safest way is to install it on the next restart, "
        + "so nothing changes under the running desktop.",
    kernelNvidiaRestart:
        "This update includes a kernel and the NVIDIA driver. The safest way is to install them "
        + "on the next restart, so nothing changes under the running desktop.",
    // ...and the same recommendation for a set with no kernel in it, which used to get the bare
    // count instead ("20 session-critical pending (dbus, glibc, kf6, mesa, ...)") - true, and no
    // answer at all to the question the person actually has. The family list is kept, capped where
    // the count sentence caps it, because it is the evidence for the claim.
    riskySessionOne:
        "This update touches 1 package the running desktop depends on (%1). "
        + "The safest way is to install it on the next restart.",
    riskySessionMore:
        "This update touches %1 packages the running desktop depends on (%2). "
        + "The safest way is to install them on the next restart.",

    // Status-line vocabulary. `held` is a suffix to a number ("3 held"); it is a word rather than
    // a sentence because the same word has to serve the tooltip, which was already saying it.
    held: "held",
    restartPending: "restart pending",
    // What the footer gains while the counts above it are stale. It replaces a whole InlineMessage
    // - a blue "i" box whose first word was "failed", carrying raw CLI text and no next step, and
    // the fifth thing competing for a popup that fits two (hostile panel, M2 and M5). The line it
    // joins is the DATELINE for those counts, which is exactly what staleness is about; the
    // reason goes in the tooltip of the button that tries again.
    lastCheckFailed: "last check failed",
    // What the footer says instead of a date. "No SUCCESSFUL check", not "not checked": the
    // footer's whole job is to date the counts by last_success, so its fallback has to be a
    // statement about last_success too. A box whose every check since install has failed HAS
    // checked, and "Not checked yet" was false there - on the one box, a fresh install behind a
    // broken repo, most likely to be reading this line.
    noSuccessfulCheckYet: "No successful check yet",

    // The last run: its expander action, and the two phrases that stand in for a package list.
    showLog: "Show Log",
    noPackageChanges: "No package changes",
    updateFailed: "Update failed",

    // A transaction that is already staged and armed: a statement about what the next restart
    // will do, not about anything to press now. THREE spellings, because two things vary
    // independently. The count can be unknown (a marker written before the CLI recorded one), and
    // "N updates" without an N is not a sentence. And one update is not the plural sentence with a
    // 1 in it: the noun, the verb and the pronoun all move together ("1 update IS staged - IT
    // installs"), which is why the singular is a whole literal and not a fragment swap.
    // `stagedTail` stays a FRAGMENT for the plural spellings only, on the same grounds as `held`
    // above: those two must say the identical thing about the identical transaction, and two full
    // literals would drift the first time one was edited. Same caveat - a fragment is not a
    // translatable unit - and tests/test_widget_logic.sh pins the finished sentences, not pieces.
    stagedTail: "are staged - they install on the next restart",
    stagedOne: "1 update is staged - it installs on the next restart",
    stagedUnknownCount: "Updates are staged - they install on the next restart",

    // ...and the HEADER over that banner, in the same three spellings and for the same reasons.
    // Staging used to change nothing at the top of the popup: the header went on saying "23
    // updates available" and Update Now stayed lit, directly under a green banner about the same
    // 23 updates. What a first-timer read out of that was "so it did not work?" - which is the
    // exact reading this widget exists to remove. The BADGE is deliberately untouched: those
    // updates really are still pending until the restart runs, and the count stays true.
    stagedHeaderOne: "1 update staged for the next restart",
    stagedHeaderTail: "updates staged for the next restart",
    stagedHeaderUnknown: "Updates staged for the next restart",

    // ...and the THREE more spellings the same banner has once a hold lands behind the stage. Not
    // extra lines under the sentence above: the sentence above is the reassurance, and a warning
    // appended to a reassurance is the contradiction one level down (spec 4.4, UX finding 1). The
    // banner changes what it IS, so these replace stagedTail/stagedOne rather than joining them.
    //
    // "%1" and "%2", which nothing else in this table does, because these are the only entries
    // whose subject is a package name that came out of another program. The alternative was four
    // head/tail fragments, and a fragment is not something a reviewer can read as a sentence -
    // which is the whole reason spec section 7 states these as sentences. stagedVariantOf below
    // substitutes; tests/test_widget_logic.sh pins both the templates and the finished sentences.
    //
    // First the name, then a count of the rest. NOT familiesOf: that collapses kernel-core and
    // kernel-modules into one decision, which is right when the question is "what is risky about
    // this transaction" and wrong here, where the person is owed the number of packages their
    // holds did not stop.
    //
    // "still installs" / "still install": singular and plural move the verb, the possessive AND
    // the pronoun together, the same rule stagedOne follows above.
    // IN THE USER'S ORDER OF EVENTS. "Staged before your hold - dbus still installs" named the
    // mechanism rather than what the person did, and once the green banner was gone "Staged" had
    // no antecedent at all; the other way out - stop holding the package and the current plan
    // stands - was offered nowhere (hostile panel, M4 and first-run 8). So: what you did, what
    // follows from it, and both remedies.
    stagedConflictOne:
        "You held %1 after the next-restart install was prepared, so it still installs. "
        + "Rebuild it to skip %1, or stop holding %1 to keep the current plan.",
    stagedConflictMore:
        "You held %1 and %2 more after the next-restart install was prepared, so they still "
        + "install. Rebuild it to skip them, or stop holding them to keep the current plan.",
    // And the spelling for a stage whose package list could not be read at all. "may", because
    // that is exactly what is known - the CLI said names_source "none", which means an empty
    // conflict list is "cannot tell" and never "no conflict". A reader that stayed quiet here
    // would be denying a conflict on no evidence; the spec's rule is that names may CONFIRM a
    // conflict and may never DENY one.
    stagedConflictUnknown:
        "You added holds after the next-restart install was prepared, so it may still install "
        + "held packages. Rebuild it to apply your holds.",
    // ...and the cost, as the banner's SECOND SENTENCE. It was disclosed only in the action's
    // tooltip, which is to say only to somebody who had already hovered the button they were
    // deciding about (hostile panel, M4). Short, because it is the third sentence in the box and
    // the tooltip still carries the long form.
    stagedRebuildCost: "Rebuilding asks for authorization; if it fails, nothing stays staged.",

    // The one action a warning variant offers, and the whole cost of pressing it. Both facts are
    // in the tooltip because both are real: it runs `kempt update --surface=offline`, which is a
    // privileged verb (a polkit dialog), and dnf5 destroys the stored transaction the moment a
    // re-stage begins (spec G2), so a rebuild that fails leaves nothing staged.
    //
    // What it deliberately does NOT say is "re-downloads". Container-measured (spec G8): a
    // replace-stage reuses dnf5's package cache - re-staging with an exclude transferred 0.0 B,
    // ">>> Already downloaded" - so a download warning here would be a cost this project invented.
    // "removed", not "unstaged": the CLI's own remedy is `sudo dnf5 offline clean`, and it removes.
    stagedRebuildAction: "Rebuild Staged Update",
    stagedRebuildTooltip:
        "Builds the staged update again with your current holds. Asks for authorization; "
        + "if the rebuild fails, the current staged update is removed.",
    // What the rebuild says instead of acting when the stage it was offered over is not the stage
    // on disk any more. Short, and about the transaction rather than about the widget: the person
    // pressed a button and nothing happened, and this is the only sentence that stops that being
    // indistinguishable from a broken button. main.qml assigns it, the way it assigns restartFailed.
    stagedChanged:
        "The staged update changed since this was offered. Nothing was rebuilt; "
        + "check the banner above.",

    // The hold round trip, in three sentences. Two of them are never DRAWN: the popup speaks them
    // through one Accessible.announce when the row has actually moved, because until now a hold
    // landed in complete silence - no message, no focus move, nothing (hostile panel, a11y P2).
    // The %1 is substituted in the QML, which is why these two carry a placeholder rather than
    // being assembled here: an announcement is one translatable sentence with a name in it.
    holdAnnounce: "Holding %1",
    unholdAnnounce: "No longer holding %1",
    // ...and the failure, which is reported in the ROW that failed. It used to be the fifth
    // InlineMessage at the top of the content, up to 300 px from the pin that caused it, saying
    // neither hold nor unhold (HIG P6). main.qml substitutes and assigns it, the way it assigns
    // restartFailed and stagedChanged.
    holdFailed: "Could not change the hold on %1.",

    // Right-click, and the popup's own gear. Opens a dialog, so: real ellipsis.
    configure: "Configure Kempt…",

    // The store-first first run. The widget installs from the KDE Store on its own, and the CLI
    // that does every piece of the work does not come with it - so the very first check on a
    // store install runs against nothing. Two entries rather than one because they are two
    // different kinds of sentence and the message renders them on two lines: what is true, then
    // what to type. A person who cannot act on the second line still gets the first.
    //
    // INGREDIENTS, like kernelRestart and stagedTail: engineMissingMessage below assembles them
    // and the popup binds the finished string, the same way it binds riskyMessage. The tooltip
    // takes the first one alone, because two command lines under a panel hover is noise.
    //
    // The commands are WHOLE. Half a command line is worse than none - it fails somewhere the
    // reader then has to debug - so both dnf lines are complete and pasteable, and the URL is
    // there for the boxes that are not Fedora. tests/test_widget_logic.sh pins all three.
    engineMissing: "Kempt's engine is not installed, so nothing can check for updates yet.",
    engineMissingInstall:
        "On Fedora: sudo dnf copr enable erez-c137/kempt, then sudo dnf install kempt. "
        + "Other systems: github.com/erez-c137/kempt",
    // The CLIPBOARD form of the same two commands: one line, chained, so one paste in one
    // terminal does the whole install. Separate from engineMissingInstall because the display
    // string is a sentence (commas, "then", a URL) and a sentence pasted into a shell fails
    // somewhere the reader then has to debug. tests/test_widget_logic.sh drift-guards the two:
    // every command this copies must appear verbatim in the sentence the message shows.
    engineMissingCopy: "sudo dnf copr enable erez-c137/kempt && sudo dnf install kempt"
};

// The separator between the facts on one line: MIDDLE DOT (U+00B7) with a space on each side, the
// same one the plan's layout draws. One constant, because the footer's status line and the Last
// update row both use it and two of them would drift apart the first time one was edited.
var DOT = " \u00b7 ";

// How big the pending download is, in words a person reads at a glance.
//
// "~", never "up to". The figure is an estimate with error in BOTH directions, so any wording
// that implies a ceiling is false: dnf pulls in new dependencies `--upgrades` never listed, while
// flatpak transfers ostree static deltas that are routinely a fraction of the published
// download-size, and a transaction Kempt already staged offline has been downloaded in full while
// the number still counts it.
//
// SI units with a lowercase k, matching what both package managers report, and one decimal - but
// a trailing ".0" is dropped, because "~140 MB" is what a person would say and "~140.0 MB" is
// what a machine would.
//
// Under a megabyte it says "< 1 MB" rather than a kB figure. Nobody decides anything differently
// between 300 kB and 800 kB, and a number that small next to an update button invites the reader
// to think the estimate is precise, which it is not.
//
// Returns "" for anything not worth showing - absent, zero, negative, not a number. Empty is the
// signal to render NOTHING: no "unknown", no "0 MB", no dash. Same way the surfaces already
// degrade for reboot_needed.
function formatDownload(bytes) {
    if (typeof bytes !== "number" || !isFinite(bytes) || bytes <= 0) return "";
    if (bytes < 1000000) return "< 1 MB";
    var mb = Math.round(bytes / 100000) / 10;
    // 999999999 bytes rounds to 1000.0 MB, which is a gigabyte spelled the long way.
    if (mb < 1000) return "~" + trimZero(mb) + " MB";
    return "~" + trimZero(Math.round(bytes / 100000000) / 10) + " GB";
}

// One decimal, minus a pointless one. Not toFixed(1) followed by a string trim: toFixed rounds a
// second time and the value has already been rounded, so the two can disagree at the boundary.
function trimZero(n) {
    return String(Math.round(n * 10) / 10);
}

// How many session-critical families the offline recommendation names before it says ", ...".
// Same number the CLI's notification uses (bin/kempt).
var RISKY_FAMILIES_SHOWN = 4;

// Highest number the panel badge spells out; above this it reads "999+".
// COMPACT ONLY. The popup header is never capped: there is room for the real number there, and
// a person opening the popup is asking for the real number.
// 999 and not 99: a Fedora box left alone for a few weeks routinely has two or three hundred
// updates pending, so a cap of 99 would be vague in the ordinary case rather than the extreme
// one - and a badge that is exactly right is the entire pitch of this widget.
var BADGE_MAX = 999;

// shellQuote(s) -> the string as ONE shell word, safe to paste into a command line.
//
// This is the widget's only injection surface and it is a real one. Package names come out of
// the CLI's JSON, and the popup builds `kempt hold <backend>:<name>` from them - a name
// containing `;` or a backtick would otherwise be a second command running as the user, from
// inside the panel process. POSIX single quotes disable every expansion the shell has; the only
// character that cannot appear inside them is the single quote itself, which is closed, escaped
// and reopened ('\'') in the usual way.
// Anything state-derived that reaches a command line goes through here. No exceptions - not
// "obviously safe" package names, not log paths.
function shellQuote(s) {
    if (s === undefined || s === null) return "''";
    return "'" + String(s).split("'").join("'\\''") + "'";
}

// fill(template, token, value) -> every occurrence replaced, not just the first.
//
// String.replace with a string needle replaces ONE occurrence, and stagedConflictOne names its
// package three times ("You held dbus ... Rebuild it to skip dbus, or stop holding dbus ..."), so
// a replace() there would ship a banner reading "Rebuild it to skip %1". split/join rather than a
// regex because the value is a package name from another program and a regex would interpret it.
function fill(template, token, value) {
    return String(template).split(token).join(value);
}

// Is this really an array? `typeof v.length === "number"` is not enough: a STRING has a length,
// and iterating one yields characters that would render as packages.
function isArray(v) { return Object.prototype.toString.call(v) === "[object Array]"; }
function arrayOf(v) { return isArray(v) ? v : []; }

// The run surfaces the CLI knows, in the order the settings page offers them.
var SURFACES = ["terminal", "popup", "background", "offline"];

// isTrue(s) -> the same answer lib/common.sh's is_true() gives.
// The settings page reads booleans back as the TEXT `kempt config get` printed, and the two must
// not disagree about what "yes" means - a checkbox that renders a config value as its opposite is
// how a user turns something off and finds it back on.
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

// updatingLabelOf(surface) -> what the pane says while a run on that surface is in flight.
//
// Takes the surface the RUNNING transaction is using, which is not always the configured one: with
// confirmation on, `kempt run` collapses every surface to terminal, and Install on Next Restart
// stages offline whatever the setting says. Anything unrecognised falls back to terminal for the
// same reason resolveSurface does - that is what the CLI itself would have run.
function updatingLabelOf(surface) {
    switch (resolveSurface(surface)) {
    case "popup":      return COPY.updatingHere;
    case "background": return COPY.updatingBackground;
    case "offline":    return COPY.updatingOffline;
    default:           return COPY.updatingTerminal;
    }
}

// effectiveSurfaceOf(surface, autoAccept) -> the surface a run will ACTUALLY use.
// bin/kempt's cmd_run resolves the configured surface and then overrides it: with auto_accept
// false only a terminal can ask the confirmation question, so every other surface becomes
// `terminal` regardless of what is stored. The popup has to apply the same rule or it will offer
// an in-widget log pane while a terminal window is what actually opens.
function effectiveSurfaceOf(surface, autoAccept) {
    return isTrue(autoAccept) ? resolveSurface(surface) : "terminal";
}

// --- how big the panel icon is asked to be -----------------------------------------------------
// Two rules live here, and they answer different questions. snapIconSize answers "how big should
// this be when nobody said" (the `auto` setting); resolveIconSize answers "how big is it, given
// what the user asked for".
//
// The hinted sizes an icon theme actually draws, smallest first. Breeze ships a 16px symbolic and
// a 22px symbolic as SEPARATE artwork, each with its strokes aligned to the pixel grid AT THAT
// SIZE. Ask for 15px, or 24px, and the renderer scales one of them by a fraction and every hinted
// stroke lands between pixels: the icon goes soft exactly where a panel icon is smallest and can
// least afford it. Every size below is one of these steps, never an arithmetic result.
// The QML passes Kirigami's own values in this order; node uses these when it does not.
var ICON_STEPS = [16, 22, 32, 48, 64];

// The cell thickness at which each step takes over, paired by index with the steps above.
//
// This ladder is NOT "the largest icon that fits", which is what it used to be, and the difference
// is the whole bug: a 44px panel fits a 32px icon, so the widget asked for 32 and sat next to a
// system tray whose entries were all 22. It looked like a mistake because it was one - the tray
// does not fill its cell either, and an icon that does is simply bigger than everything around it.
// So the rungs are pinned to what the tray does at ordinary panel thicknesses: anything from a
// 22px panel up to a 47px one asks for 22, which is what the tray asks for over that whole range.
// 48 is where a panel stops being an ordinary panel and a bigger glyph stops looking out of place.
var ICON_CELL_MIN = [16, 22, 48, 96, 192];

// snapIconSize(cell, steps) -> the hinted size an `auto` icon asks for in a cell this thick.
// Below the first rung there is no hinted size to snap to, so it falls back to a whole number of
// pixels: scaling is the only option left down there, but it can at least be scaled to an integer.
function snapIconSize(cell, steps) {
    var c = Number(cell), list = usableSteps(steps), chosen = 0, i;
    if (!isFinite(c) || c <= 0) return 0;
    for (i = 0; i < list.length && i < ICON_CELL_MIN.length; i++) {
        if (c >= ICON_CELL_MIN[i]) chosen = list[i];
    }
    // Never wider than the cell holding it, whatever a caller's step list says.
    return chosen > 0 ? Math.min(chosen, Math.floor(c)) : Math.floor(c);
}

// The step list a caller supplied, cleaned - or the built-in one when they supplied nothing usable.
// Falling back to ICON_STEPS rather than to raw pixels is deliberate: an empty list is a caller
// that could not read its theme, and the right answer to that is still a hinted size. It is also
// what lets node call snapIconSize(44) with no second argument and get the shipping answer.
function usableSteps(steps) {
    var out = [], i, s;
    if (!steps || !steps.length) return ICON_STEPS.slice();
    for (i = 0; i < steps.length; i++) {
        s = Number(steps[i]);
        if (isFinite(s) && s > 0) out.push(s);
    }
    return out.length ? out : ICON_STEPS.slice();
}

// The `widget_icon_size` values the settings page offers, and the step each one names. They are
// INDEXES into the step list rather than literal pixel counts, so a theme whose "small" is not 16
// still gets its own hinted artwork rather than a number this file invented.
var ICON_SIZE_SETTINGS = { auto: -1, small: 0, medium: 1, large: 2 };

// ...and the ones that must never come out SMALLER than what `auto` would have drawn. Only the
// largest option is in here, and the asymmetry is the point: see resolveIconSize below.
var ICON_SIZE_FLOOR_AT_AUTO = { large: true };

// resolveIconSizeSetting(value) -> a setting the widget recognises, mirroring resolveSurface:
// anything unknown is `auto`. This is the ONLY validation `widget_icon_size` gets - the CLI
// stores whatever it is handed (config_set checks the key's shape, not the value's meaning), so
// a typo, an older CLI answering with an empty line, or a value from a future version all land
// here and all mean the same thing: decide it automatically, say nothing.
function resolveIconSizeSetting(value) {
    var s = String(value === undefined || value === null ? "" : value).trim().toLowerCase();
    return Object.prototype.hasOwnProperty.call(ICON_SIZE_SETTINGS, s) ? s : "auto";
}

// resolveIconSize(setting, cell, steps) -> the pixel size the icon is actually asked for.
// A chosen size that the cell cannot hold falls back to `auto` rather than overflowing: inside the
// system tray the cell is the tray's to decide, and a widget that drew 32px into a 22px tray slot
// would push every other tray entry around. The panel always wins; the setting is a preference
// within what it allows.
function resolveIconSize(setting, cell, steps) {
    var list = usableSteps(steps), c = Number(cell);
    var auto = snapIconSize(c, list);
    if (!isFinite(c) || c <= 0) return auto;          // no cell yet: nothing to draw into
    var key = resolveIconSizeSetting(setting);
    var idx = ICON_SIZE_SETTINGS[key];
    if (idx < 0) return auto;
    var want = Number(list[idx]);
    if (!isFinite(want) || want <= 0) return auto;    // a step list too short to name it
    // "Large" is a promise about size, and on a big cell the named step broke it: the auto ladder
    // reaches 48 at a 96px cell and 64 at 192, while `large` names the third step (32) - so on a
    // vertical dock or a HiDPI panel, choosing Large made the icon SMALLER than the one Automatic
    // was already drawing. Floored against auto rather than renaming the options to pixel counts,
    // which would have made every label a number the user has to translate for themselves.
    // Small and Medium are deliberately NOT floored: they are requests to go below Automatic,
    // which is the entire reason they exist (an ordinary 44px panel draws 22 on auto, 16 on Small).
    if (ICON_SIZE_FLOOR_AT_AUTO[key]) want = Math.max(want, auto);
    return want > c ? auto : want;
}

// --- the watcher stamp -----------------------------------------------------------------------
// main.qml polls the mtimes of four paths every 30 seconds and compares the result with the last
// one. WHICH of them moved is the part that matters, and the reason is dnf: /var/lib/rpm is
// rewritten continuously all the way through a transaction. Comparing the stamp as one string
// says only "something changed", which during a run of ours is true every 30 seconds - so the
// widget declared the run finished a few seconds in, printed a summary of the run before it,
// and started a `kempt check` that wanted the same dnf lock the transaction was holding.
// Only OUR state file says a run ended. These field names are that distinction, and they are
// here rather than in QML so node can pin them.
var WATCH_FIELDS = 4;
var WATCH_STATE_FIELD = 2;      // the order in main.qml's watchCmd: rpm, flatpak, state, config
var WATCH_CONFIG_FIELD = 3;

// watchChange(prev, next) -> { any, packages, state, config, comparable }
// `comparable` is false when either stamp is not the four fields main.qml asks for - an older
// widget's stamp left in place across a reload, say. In that case the answer degrades to the old
// whole-string comparison (every category true) rather than guessing which column is which:
// wrong-but-noisy beats wrong-and-silent when what is at stake is noticing a finished run.
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
// A run leaves a wake. `kempt update` rewrites /var/lib/rpm all the way through the transaction,
// re-checks itself on the way out (which rewrites state.json), and with flatpak in the mix moves
// /var/lib/flatpak too - so the 30-second watcher goes on finding changes for a minute after the
// post-run check has already accounted for every one of them. Measured on a real run (2026-08-28):
// three `widget check ok` lines inside 40 seconds. Each is cache-only and costs about two seconds,
// so the waste is small; what is not small is that each one is a line in `kempt log`, which is the
// file a person reads to find out what happened, and two of the three describe nothing.
//
// So a WATCHER-triggered check is dropped while the last completed check is still recent. Only the
// watcher's: a Refresh press, the scheduled check, the popup opening and the settings page's own
// config write all go straight through, because each of those is somebody ASKING rather than the
// machine noticing its own footprint. The post-run check is exempt for a different reason and an
// even better one - it is the moment the counts on screen are most wrong, and the user who pressed
// Update Now a minute ago is the one looking at them (main.qml, pollWatch's `endedRun`).
//
// The cost is bounded and named: a change from somewhere else landing inside the window is
// absorbed along with ours, and the next scheduled check is what finds it. That is the right trade
// for a notifier - absorbing one can only leave the badge over-reporting for a while, never
// under-reporting, and the surface a person actually looks at asks for itself on open.
var CHECK_QUIET_MS = 60000;

// watcherCheckDue(lastCheckFinished, now) -> whether a watcher-triggered check should run.
// `lastCheckFinished` is 0 until a check has completed, and that case answers yes: with no check
// behind us there is no footprint of ours for this change to be.
function watcherCheckDue(lastCheckFinished, now) {
    var last = Number(lastCheckFinished), t = Number(now);
    if (!isFinite(last) || last <= 0) return true;
    if (!isFinite(t)) return true;
    var since = t - last;
    // A clock that moved backwards (an NTP correction, a suspend) must never suppress a check: the
    // window is an optimisation, and an optimisation that can silence the widget indefinitely on a
    // bad clock is not one.
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

// lastLinesOf(text, max) -> the last `max` non-blank lines, trimmed and joined with " ".
// The result line under the passwordless buttons. The LAST lines and not the first: pkexec and
// polkit print their progress before their verdict, and the verdict is the part worth showing.
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

// firstLineOf(text) -> the first non-blank line, trimmed, or "".
// `ls -1t | head -1` and `kempt summary` both hand back text the popup shows on one line; doing
// the trimming here rather than in QML is what lets a node test pin it.
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

// Is this object schema-v1 shaped? A parsed object that carries neither a count nor backends is
// something else entirely (a future schema, a foreign file): the widget says so rather than
// rendering it as "no updates".
function looksLikeState(state) {
    if (!state || typeof state !== "object") return false;
    // A declared schema we do not know is NOT something to render optimistically. This matters
    // more here than it would in most readers: the CLI is installed as a symlink into the
    // checkout while the widget is a COPY, so after a `git pull` the CLI is new and the widget is
    // whatever was last installed. Version skew is the normal state of this pair, not an edge
    // case, and a schema 2 field could mean anything. Say "error" and let the tooltip explain,
    // rather than badge a number whose meaning we are guessing at.
    if (typeof state.schema === "number" && state.schema !== 1) return false;
    if (typeof state.actionable === "number") return true;
    if (state.backends && typeof state.backends === "object") return true;
    return false;
}

// newestOf("a,b,c") -> "c". The CLI collapses multilib and installonly duplicates into ONE row
// with the versions comma-joined, and its own human renderer shows the last of the set
// (lib/common.sh: `def newest(v): v | split(",") | last`). The widget copies that rule exactly,
// because a popup that renders a version differently from `kempt summary` is the front-end
// disagreeing with the CLI - the one thing this design forbids.
// What a `from` looks like when there is no current version: the package is not installed, and
// the update would ADD it. The CLI's own fallback, kept as a named constant because the popup has
// to recognise it twice - once to say "Skip installing X" instead of "Hold X at ?", and once to
// draw it as a word rather than as a punctuation mark.
var VERSION_UNKNOWN = "?";

// What ANY row draws for a `from` the CLI could not know: the pending list and the Last update
// history rows both go through this, so a package that was not installed reads "new" in both
// places rather than "?" in one of them (the a11y reviewer's S4: "?" reads as a fault).
function fromTextOf(from) {
    return from === VERSION_UNKNOWN ? COPY.versionNew : from;
}

function newestOf(versionSet) {
    if (versionSet === null || versionSet === undefined) return VERSION_UNKNOWN;
    var s = String(versionSet);
    if (s === "") return VERSION_UNKNOWN;
    var parts = s.split(",");
    return parts[parts.length - 1];
}

// familiesOf(names, max) -> { shown: [families, capped at max], total: <unique family count> }.
// A family is the name up to its first "-" or "." - kernel-core and kernel-modules are one
// decision, not two - and the list is unique and sorted, exactly like the CLI's
// `sed 's/[-.].*//' | sort -u`. max <= 0 (or omitted) means no cap.
function familiesOf(names, max) {
    var seen = {}, families = [], i, family;
    if (!names || typeof names.length !== "number") return { shown: [], total: 0 };
    for (i = 0; i < names.length; i++) {
        family = String(names[i]).replace(/[-.][\s\S]*$/, "");
        if (family === "") continue;
        // "#" prefix: a package family called "constructor" or "toString" would otherwise collide
        // with Object.prototype and silently vanish from the list.
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

// "dbus, glibc, kernel, kf6, ..." - the families in a risky set, capped, as both sentences below
// name them. One function, because a count sentence and a recommendation that listed the same set
// differently would be the popup disagreeing with itself about the same transaction.
function riskyFamiliesOf(names) {
    var fams = familiesOf(names, RISKY_FAMILIES_SHOWN);
    return fams.shown.join(", ") + (fams.total > fams.shown.length ? ", ..." : "");
}

// "20 session-critical pending (dbus, glibc, kernel, kf6, ...)" - the count, worded from the same
// parts as the CLI's notification. Published as vm.riskySummary and deliberately not drawn: the
// popup shows the RECOMMENDATION below, which answers the next question.
function riskySummaryOf(names) {
    if (!names || !names.length) return "";
    return names.length + " session-critical pending (" + riskyFamiliesOf(names) + ")";
}

// riskyMessageOf(names) -> what to DO about a session-critical transaction, in one sentence.
//
// riskySummaryOf above answers "how much of this is risky". This answers the question the person
// actually has next, and a kernel changes the answer: staging it offline does not help, because
// the kernel you are running keeps running until you restart either way.
//
// The two ingredient tests are deliberately different shapes:
//   * KERNEL is a FAMILY test. kernel-core, kernel-modules and kernel.x86_64 are one decision, and
//     collapsing them is exactly what familiesOf exists for (the name up to its first - or .). It
//     also keeps kernelcare, which merely starts with the same letters, out of it.
//   * NVIDIA is a SUBSTRING test, because the driver arrives under families with nothing in
//     common: akmod-nvidia is the "akmod" family, xorg-x11-drv-nvidia is "xorg", nvidia-settings
//     is "nvidia". A family test would catch one of the three and miss the two that matter most.
//     Case-insensitive, because the packaging of that driver is not consistent about it.
// NVIDIA without a kernel says nothing special: the extra sentence is about a kernel module built
// against a kernel that is about to stop being the running one, which needs the kernel to be in
// the set at all.
function riskyMessageOf(names) {
    if (!isArray(names) || names.length === 0) return "";
    // The 0 is a cap of NONE and has to stay one. This is a LOOKUP, not a list being shown to
    // anybody: RISKY_FAMILIES_SHOWN caps what riskySummaryOf PRINTS, and passing it here - the
    // obvious-looking tidy-up, since four is the number the other call uses - would make the
    // kernel warning depend on where "kernel" falls in an alphabetical sort. Four families
    // ahead of it (akmod, alsa, atk, bash is an ordinary Fedora transaction, not a contrived
    // one) and the most important sentence this popup has silently stops being said.
    if (familiesOf(names, 0).shown.indexOf("kernel") < 0) {
        // No kernel: the offline install really is the safer path and nothing has to be said about
        // the running kernel. Singular and plural are whole literals, because the count, the noun
        // and the pronoun ("it" / "them") all move together.
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
// status, and only for a transaction that is genuinely ARMED (lib/common.sh, offline_staged_state).
// So the judgement is not re-derived here: the key's presence IS the answer. What this adds is the
// count, which is optional and which no reader may invent - a marker written before the count
// existed carries null, and the sentence loses the number rather than gaining a wrong one.
//
// The type check is the same one riskyMessageOf's caller learned the hard way: state.json is JSON
// written by another program, and a schema-1 reader has to tolerate a key of the wrong type.
// Tolerating it means IGNORING it - a string here would otherwise reach `.count` as undefined and
// render the popup's most reassuring sentence about a transaction that does not exist.
function stagedMessageOf(staged) {
    if (!staged || typeof staged !== "object" || isArray(staged)) return "";
    var n = staged.count;
    if (typeof n !== "number" || !isFinite(n) || n < 0) return COPY.stagedUnknownCount;
    // Exactly one, and only one, takes the singular - zero is plural in English ("0 updates"), so
    // the test is `=== 1` and not `<= 1`. Same shape as the header's own count and the relative
    // times above it.
    return n === 1 ? COPY.stagedOne : n + " updates " + COPY.stagedTail;
}

// --- how many messages the popup may show at once ------------------------------------------------
//
// Two. Measured: at the default popup size (26 x 24 grid units = 468 x 432 px) five messages left
// the list 95 px tall, and at Layout.minimumHeight the messages alone overflowed - they sit
// OUTSIDE the ScrollView, so nothing scrolled and the list, which is what the popup is for, was
// simply gone (hostile panel, M2).
//
// This is a RULE and not four visibility bindings, which is why it lives here where a node test
// can state it. A binding can say "am I true"; only something that sees all four can say "am I one
// of the two that fit".
var MESSAGE_CAP = 2;

// Priority order, and each position is an argument:
//   report   the thing the person just did - a run that finished, or a press that failed. First,
//            because it is the answer to a question they asked seconds ago.
//   staged   what the next restart will install, and whether a hold landed behind it. The one
//            message that changes what the rest of the popup may offer.
//   restart  a restart is owed. Displaced most cheaply of the four: the footer says "restart
//            pending" whenever this message is not on screen, so the fact is never lost.
//   kernel   the offline recommendation. Last because it is advice about a transaction that is
//            still sitting there, and it will still be there next time the popup is opened.
var MESSAGE_ORDER = ["report", "staged", "restart", "kernel"];

// messageStack(wants) -> the names of the messages that may actually be drawn, in order.
//
// `engineMissing` is not in the order at all: it shows ALONE. Everything below it presumes an
// engine that answered, and a box with no CLI has nothing else true to say.
//
// Anything displaced shows NOTHING. It does not shuffle into the next slot when something above
// it goes away mid-glance, and it does not stack below the fold - a message the person cannot see
// is a message that is not being shown, and pretending otherwise is how five of them got here.
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
// transaction is armed, or "" when none is.
//
// Same input, same tolerance and the same three spellings as stagedMessageOf above - deliberately
// a second function rather than a flag on that one, because these are two different sentences with
// two different jobs. The banner states what the next restart will DO; this replaces a count of
// what is available, which while a stage is armed is a true number saying a false thing.
function stagedHeaderOf(staged) {
    if (!staged || typeof staged !== "object" || isArray(staged)) return "";
    var n = staged.count;
    if (typeof n !== "number" || !isFinite(n) || n < 0) return COPY.stagedHeaderUnknown;
    return n === 1 ? COPY.stagedHeaderOne : n + " " + COPY.stagedHeaderTail;
}

// stagedVariantOf(staged, heldDnf) -> which of the three banners this stage gets, and its words.
//
//   { type: "positive" | "warning", message, conflictNames: [...], stagedAt: "" }
//
// THE PROBLEM THIS EXISTS FOR, in the user's own order: stage 83 updates with a kernel among
// them, read something worrying, press the pin on kernel-core - and restart into the kernel you
// just tried to keep out. Nothing lied. dnf5 built and stored that transaction at stage time, and
// it offers no way to edit a stored one, so a hold applies from the NEXT transaction Kempt builds
// while this one still installs the package. The person assembled a true belief out of Kempt's own
// surfaces and reality contradicted it, which is the exact failure this project exists to remove.
//
// The popup is the last surface that could have said so, and it was saying the opposite: a green
// Positive banner with a live Restart… button over the package they had just tried to stop. So the
// banner does not GAIN a line here - a warning appended to a reassurance is the contradiction one
// level down, and the reassurance is the half with the button on it. It changes what it is.
//
// The judgement itself is NOT re-derived here, exactly as stagedMessageOf does not re-derive
// "armed". `holds_conflict` is the CLI's own answer - the held dnf packages that are in the stored
// transaction anyway, computed at check time from dnf5's stored transaction read live - and
// `names_source` says what an EMPTY list means: "transaction"/"marker" mean it was read and there
// is nothing in it, "none" means it could not be read at all, so an empty list there is "cannot
// tell". Two states, two sentences, and the difference between them is the whole honesty of this.
//
// heldDnf is the one fact this file has to supply itself: whether the box is holding any dnf
// package at all (backends.dnf.items[] with held true). It gates the generic warning only - with
// nothing held there is nothing to be vague ABOUT, and worrying a box that holds nothing over a
// list nobody could read is noise. dnf only, and not because flatpak is less important: the
// offline surface stages dnf and only dnf, so a held flatpak can never be in a staged transaction
// (spec, UX finding 2).
//
// TOLERANCE, and it is the same rule the isArray note in viewModel argues for risky_pending: this
// is JSON from another program, and a schema-1 reader tolerates a key of the wrong type by
// IGNORING it. A string has a length and indexes into its own characters, so a duck-typed check
// would warn about a package called "k". Everything malformed falls back to the banner that was
// there before these fields existed, and nothing here throws.
//
// The ONE asymmetry in that tolerance is deliberate: a well-formed list of names warns whether or
// not names_source is readable. The spec's rule is that names may CONFIRM a conflict and may never
// DENY one, and a reader that demanded a valid names_source before believing a list of package
// names would be denying one on a technicality.
function stagedVariantOf(staged, heldDnf) {
    var plain = { type: "positive", message: stagedMessageOf(staged), conflictNames: [],
                  stagedAt: "" };
    if (plain.message === "") return plain;
    // Not shellQuote-adjacent, but the same instinct: a stamp that is not a string is not a stamp.
    // main.qml compares this for EQUALITY against the state file at click time, and a number here
    // would compare equal to a number there and spend the user's consent on a transaction they
    // never saw.
    if (typeof staged.staged_at === "string") plain.stagedAt = staged.staged_at;

    var names = [], i, name;
    if (isArray(staged.holds_conflict)) {
        for (i = 0; i < staged.holds_conflict.length; i++) {
            name = staged.holds_conflict[i];
            // One bad entry discards the LIST, not just the entry. A sentence built from the
            // survivors of a list we could not read is a count the user cannot check, and
            // "kernel-core and 2 more" is only worth saying when the 2 is true.
            if (typeof name !== "string" || name === "") { names = []; break; }
            names.push(name);
        }
    }

    // The cost is joined on HERE rather than written into each of the three templates: it is one
    // fact about one button, it is identical in all three, and three copies of it would drift the
    // first time one was edited. It only ever rides a warning, because the warning is the only
    // variant that offers the button it is about.
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
// ...and the offset on the end of it, in either of the two spellings `date -Iseconds` and its
// neighbours produce (+HH:MM, +HHMM), or Z.
var STAMP_OFFSET_RE = /(Z|[+-]\d{2}:?\d{2})$/;

function isRenderableStamp(iso) {
    return typeof iso === "string" && STAMP_HEAD_RE.test(iso.split("\n")[0].trim());
}

// formatStamp(iso) -> "2026-08-24 22:11 +03:00", or "never" when there is no stamp.
// Textual, not Date-based, on purpose: it cannot print "Invalid Date", it cannot shift a
// timestamp into another timezone, and it survives the recorded corruption where two state
// documents end up concatenated and a per-document read hands us both, newline-joined.
//
// The OFFSET is part of the answer, and leaving it off was a quiet way of being wrong. This is
// the EXACT stamp under a relative line - "Checked 4 min ago" hovers to this, and people hover it
// to compare the two - so rendered as a bare wall-clock reading it can disagree with the line
// above it by hours with nothing on screen to explain the gap. A state file written before a
// timezone change, or copied off another machine, is all it takes. Normalised to one shape
// (+HH:MM, with Z as +00:00) so two stamps from two producers can be read against each other.
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

// The one strict shape relativeTime will do arithmetic on: YYYY-MM-DDTHH:MM:SS, optionally with a
// fractional part, optionally with Z or an offset (+HH:MM or +HHMM - `date -Iseconds` writes the
// colon, some other producers do not). Anything else is not a timestamp as far as this file is
// concerned, and the answer to "not a timestamp" is always the absolute stamp.
var ISO_STAMP_RE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$/;

// stampMs(iso) -> the stamp as UTC milliseconds, or NaN when it is not a timestamp.
// The one place a stamp is turned into a number, shared by relativeTime and shouldRefreshOnOpen so
// the two can never disagree about what counts as a readable stamp.
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
    // No zone at all is read as UTC. It is the only reading available without Date's own string
    // parsing (local time is a property of the machine, not of the text), and the CLI's now_iso
    // always writes an offset - so this is a foreign-file case, not an everyday one.
    if (zone && zone !== "Z") {
        var digits = zone.substring(1).replace(":", "");
        off = (Number(digits.substring(0, 2)) * 60 + Number(digits.substring(2))) * 60000;
        if (zone.charAt(0) === "-") off = -off;
    }
    // The offset says how far AHEAD of UTC the wall clock is, so it comes off to get UTC.
    return Date.UTC(y, mo - 1, d, h, mi, s) - off;
}

// relativeTime(iso, nowMs) -> "4 min ago", or the absolute stamp when it cannot be sure.
//
// The popup's status line, and the same deliberate design as formatStamp above: NO Date parsing.
// Date.UTC is pure arithmetic - it takes six numbers and returns a millisecond count, with no
// locale, no local timezone and no string parsing anywhere in it - which is what keeps the three
// guarantees formatStamp makes: it cannot print "Invalid Date", it cannot shift a stamp into
// another timezone, and it survives the recorded corruption where two state documents arrive
// newline-joined (first line, same as formatStamp).
//
// The clock is an ARGUMENT rather than a call to Date.now(): it makes the function pure, so every
// bucket boundary is something a node test can assert exactly instead of racing.
//
// Everything it cannot be sure about hands back to formatStamp, on purpose. A relative time is a
// convenience; the absolute stamp is the truth, and showing the truth is never the wrong answer.
// A NEGATIVE age falls back too: a stamp from the future means the clock moved (or the state came
// from another machine), and "in -3 minutes" is worse than a date in every way.
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
    // A week is the last age at which counting days still answers "when?" better than the date
    // does. Past it, "23 days ago" makes a person do the arithmetic the stamp would have saved.
    if (n <= 7) return n === 1 ? "1 day ago" : n + " days ago";
    return formatStamp(iso);
}

// The oldest the popup's counts may be before opening it asks for fresh ones. A CEILING, not an
// alternative to the configured interval: somebody who set the interval to an hour still opened
// the popup to LOOK at the counts, and counts an hour old are not what they came to see. Somebody
// who set two minutes gets two, because the smaller of the two always wins.
var REFRESH_ON_OPEN_CEILING_MS = 5 * 60000;

// shouldRefreshOnOpen(lastSuccessIso, intervalMin, nowMs) -> should the popup re-check now?
//
// Note the order of the guards, because two of the rules overlap and only one of them can win:
// an unusable clock is checked FIRST, so it beats "we know nothing, so ask". Firing a check is
// running a package-manager command, and doing that on every single popup open because an
// argument was undefined is a worse failure than simply not auto-refreshing - the Refresh button
// is right there. A missing stamp with a usable clock still asks: a box that has never had a
// successful check is exactly the one whose counts are worth going and getting.
function shouldRefreshOnOpen(lastSuccessIso, intervalMin, nowMs) {
    if (typeof nowMs !== "number" || !isFinite(nowMs)) return false;
    var at = stampMs(lastSuccessIso);
    if (!isFinite(at)) return true;
    var age = nowMs - at;
    if (age < 0) return false;      // a stamp from the future is a moved clock, not a due check
    // Number(), because the widget reads config values back as the TEXT `kempt config get`
    // printed: "15" is the ordinary shape of this argument, not an edge case.
    var mins = Number(intervalMin);
    var limit = (isFinite(mins) && mins > 0)
        ? Math.min(mins * 60000, REFRESH_ON_OPEN_CEILING_MS)
        : REFRESH_ON_OPEN_CEILING_MS;
    return age > limit;             // OLDER than the limit; exactly at it is not yet stale
}

// Backend iteration order: the two we know, then anything else the CLI grew since this widget
// was written. architecture.md promises a new backend is an additive schema-1 key, so an unknown
// key must appear in the popup under its own name, never be silently dropped.
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

// rowsOf(sections, heldItems) -> ONE flat list for the popup's ListView.
// A ListView with a flat model creates delegates lazily, so a box with 1200 pending updates costs
// the same as a box with six. Building the flattening here (rather than nesting Repeaters in QML)
// also means the grouping is something a node test can check.
// Each row is {kind: "header", title, held} or {kind: "item", ...the item, plus `held`}.
//
// A header carries `held` for the same reason an item does: the popup draws one extra line under
// the Held heading ("Held packages are skipped by Kempt only") and must not decide which heading
// that is by comparing the title against the literal "Held" - the title is a string a translator
// will change, and a comparison against it would silently stop matching in every other language.
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
// Everything below reads ONE history entry, as `kempt summary --json` hands it over. The CLI
// serves that entry byte for byte rather than re-rendering it, so what arrives here is exactly
// what cmd_update wrote:
//   {timestamp, surface, status, duration_sec, reboot_needed, log, error,
//    backends: {<name>: {updated:[{name,from,to}], added:[{name,to}], removed:[{name,from}],
//                        status, skipped_held:[]}}}
// Re-deriving any of this from the human summary text would be a second, lossier copy of
// render_summary's rules living in the widget, and the two would drift. Hence --json.

// lastRunOf(text) -> the last run as data, or null.
//
// null means "no last run", and every caller must render NOTHING for it - never a fabricated empty
// run. That is the same contract `kempt summary --json` itself keeps: with no history it prints
// empty stdout under exit 0 rather than an empty object, because a box that has never updated has
// not "updated 0 packages".
//
// Every field tolerates absence. History entries outlive the build that wrote them (the newest 50
// are kept, and this widget is a COPY that a `git pull` leaves older than the CLI), so an entry
// missing a key this build expects is an ordinary event, not corruption. The one field that is
// deliberately NOT optimistic is `failed`: a status we cannot read is not a success, because the
// cost of the two mistakes is not symmetric.
function lastRunOf(text) {
    // The same tolerant parse the state file gets, reused deliberately: empty, whitespace,
    // truncated, a bare number and a JSON array all mean "we learned nothing", and there is no
    // reason for this file to hold two opinions about that.
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
            // newestOf on both sides, because a multilib pair or an installonly kernel set arrives
            // comma-joined and the popup's own rows already render the last element. A run's
            // expanded list that showed the set differently would be the same package rendered two
            // ways on one screen.
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
        // null when the entry does not say, NOT 0 - because 0 is a real duration here. The CLI
        // writes `$(date +%s) - start`, so any run that finished inside a second records zero.
        // Collapsing "absent" onto "zero" put "in 0s" on the end of a sentence about a run this
        // build had no timing for at all.
        durationSec: (typeof entry.duration_sec === "number" && isFinite(entry.duration_sec))
            ? entry.duration_sec : null,
        updatedCount: updated,
        addedCount: added,
        removedCount: removed,
        // Installs and removals changed the machine as much as upgrades did, and the CLI counts
        // them (run_counts_phrase: "0 updated, +2 installed, -1 removed"). A popup that counted
        // only upgrades would announce "No package changes" after a transaction that added two.
        changedCount: updated + added + removed,
        items: items,
        logPath: typeof entry.log === "string" ? entry.log : "",
        // Strictly the boolean. This entry's reboot_needed is a fact about THAT RUN, not about now
        // - the state file carries the live answer - so nothing renders an affirmative from it.
        rebootNeeded: entry.reboot_needed === true
    };
}

// postRunLine(run) -> the transient line shown once, right after a run finishes.
// It replaces what the popup used to paste there: the first line of `kempt summary`, which is an
// ISO timestamp. True, and no answer at all to "what just happened?".
// A failed run is reported as failed WHATEVER its counts say: a transaction that upgraded four
// packages and then died is a failure, and "Updated 4 packages" would be the worst thing this
// popup could say about it.
function postRunLine(run) {
    if (!run) return "";
    if (run.failed) {
        // The CLI's own worked-out reason (run_failure_reason), not a generic apology - its first
        // line only, because a panel is one line wide and the log is one click away.
        var why = firstLineOf(run.error);
        return why === "" ? COPY.updateFailed : COPY.updateFailed + ": " + why;
    }
    // The staging run's entry has empty package lists BY CONSTRUCTION - nothing changes until
    // the restart - so the count sentences below would call it "No package changes": true about
    // the rpm set and no answer at all to what the person just did. The staged banner says the
    // same thing seconds later once the follow-up check lands; until then this line is the only
    // voice. Exact match, never a prefix: the harvest writes "offline (applied on reboot)" and
    // its counts are real changes that must keep rendering as changes.
    if (run.surface === "offline") return COPY.stagedUnknownCount;
    var n = typeof run.changedCount === "number" ? run.changedCount : 0;
    if (n === 0) return COPY.noPackageChanges;
    // The duration is a CLAUSE, not a field with a default: a run whose entry does not say how
    // long it took is described without that clause rather than described as instantaneous.
    var secs = run.durationSec;
    var howLong = (typeof secs === "number" && isFinite(secs)) ? " in " + secs + "s" : "";
    return "Updated " + n + (n === 1 ? " package" : " packages") + howLong;
}

// runFinishedSince(run, sinceMs) -> is this entry the run we just watched finish?
//
// The transient line above is the one sentence in this popup that makes a claim about ONE run:
// the one the user just started. `kempt summary --json` answers with the newest entry it can
// read, and this asks the follow-up question - is the entry it gave us actually from after we
// started watching? The CLI is the primary guard (it now says nothing at all when the newest
// entry is unreadable, rather than serving the run underneath); this is the belt to that braces,
// and it also covers the case the CLI cannot see: a summary answered from a history directory
// that has not caught up yet.
//
// SECOND resolution on both sides, and that is not a rounding convenience. The CLI stamps an
// entry with `date -Iseconds`, so a run that took 400ms carries a stamp truncated to the second
// it finished in - which can be numerically BELOW the millisecond clock the widget noted when the
// run started. Comparing at full precision would silently drop the line for the fastest runs,
// which are the ordinary ones on a small transaction.
//
// A stamp that cannot be read answers NO, and that is deliberate even though every other field of
// an entry tolerates absence (see lastRunOf). This question is about identity, and an entry that
// cannot be placed in time cannot answer it. It costs only the transient line: the persistent
// Last update row is bound to `lastRun` and goes on showing that entry, so the popup falls silent
// about "just now" rather than claiming a run it cannot date.
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
// The counting phrases are built here rather than kept in COPY because they are grammar (one
// package, seven packages) around a number, not a wording decision; the decision the copy table
// owns is the shape of the line, which is what this file's tests pin.
// The zero case is the exception, and it is not grammar. "no package changes" is the CLI's
// wording, emitted verbatim by KEMPT_JQ_COUNTS in lib/common.sh, and the popup is quoting the
// terminal rather than choosing words of its own; it is lowercase because it sits mid sentence
// after the dot, not because the popup disagrees with COPY.noPackageChanges about capitals.
// Do NOT reword it here alone. That is the run_counts_phrase bug this project already has a scar
// from - two renderers carrying one fact and drifting - so the tests tie all three spellings
// together: lib/common.sh's emission, the copy table, and this line.
function lastRunText(run, nowMs) {
    if (!run) return "";
    // An entry we cannot DATE gets no row. "Last update never - 1 package" was the shape of that
    // bug: relativeTime answers "never" for a missing or empty stamp, and the sentence went on to
    // describe a run in the same breath as denying there was one. An unreadable stamp is the same
    // mistake in the other direction, pasting "not a date" into an English sentence. The counts
    // are not lost - the entry is still there, and the popup still holds it - but WHEN it happened
    // is the one thing this line exists to say, so with no answer to that there is no line.
    // Note this is a test of the STAMP, not of relativeTime's output: with an unusable clock
    // relativeTime falls back to the absolute stamp, which is a perfectly good row.
    if (!isRenderableStamp(run.when)) return "";
    // The staging run, between the stage and the restart that applies it: its zero counts are
    // true and misleading, same reasoning as postRunLine's branch. `failed` is checked because
    // this row otherwise ignores failure: a staging run that FAILED staged nothing, and "staged
    // for restart" about it would be the promise postRunLine refuses to make. Exact match on
    // "offline" - the harvest's surface is "offline (applied on reboot)" and its counts render.
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
// `opts` is OPTIONAL and every field in it is optional, so the three-argument call every existing
// caller makes keeps working unchanged. It carries the facts that are not in the state file:
//   nowMs            - the clock, for the relative times. Absent means "no clock", and every
//                      relative time falls back to its absolute stamp rather than guessing.
//   restartReminder  - the `restart_reminder` config value. ABSENT is not false: it means the
//                      caller did not say, and the CLI's default for that key is true, so an
//                      unstated reminder is on. Present, it is read with isTrue, because the
//                      widget gets config values back as the text `kempt config get` printed.
//   restartDismissed - whether the restart message was closed in THIS plasmashell session.
//                      Nothing persists it; that is deliberate and documented.
//   engineMissing    - the CLI is not on the box at all (main.qml reads rc 127/126 off the check).
//                      Strictly `=== true`, unlike the two above: this one replaces the popup's
//                      whole body, so it is turned on by a real boolean and by nothing else.
//                      A separate input rather than a magic value inside cliError, because they
//                      are different facts - "we could not get an answer" against "there is
//                      nothing here to answer".
//
// cliError is the widget's own report of a check that produced nothing usable - the CLI missing
// from PATH, say. It is NOT the same thing as the CLI reporting a problem: when `kempt check`
// runs and something inside it fails, it says so in the state's own `error` field and that comes
// out as staleReason. This argument is only for "we could not get an answer at all".
//
// iconState is decided in this order, and the order is the contract. Two of these seven steps
// answer `unknown`, which is not an oversight: "the engine is not installed" and "the first check
// has not finished" are different sentences about the same honest verdict, and the panel draws
// them identically because in both the widget has no idea what is pending.
//   updating          - we started a run; it wins over whatever the last check said
//   unknown (engine)  - no engine on the box and nothing to show. Deliberately NOT the error
//                       state; the rationale is on the branch itself
//   error             - no state AND the CLI failed us, or an object that is not schema v1
//   unknown (no data) - no state, but nothing has gone wrong yet (first load, still checking)
//   stale             - the last check failed; the counts below are the last known good ones
//   updates           - actionable > 0
//   uptodate          - actionable == 0 (held items do not count: spec, Holds semantics)
//
// Note what "stale" deliberately is NOT: an error. The counts are the best known truth and the
// user does not need alarming about a repo that flapped, so the panel keeps rendering the
// CONTENTS (a count badge, or nothing) and the explanation goes in the tooltip. Only a genuine
// "we cannot read this at all" earns a warning emblem.
function viewModel(state, updating, cliError, opts) {
    updating = !!updating;
    cliError = firstLineOf(typeof cliError === "string" ? cliError : "");
    opts = (opts && typeof opts === "object") ? opts : {};
    var engineMissing = opts.engineMissing === true;
    var usable = looksLikeState(state);
    var counted = collectItems(usable ? state : null);
    var stale = usable && state.status === "stale";

    // The count and the list under it are ONE answer, and the walk is what produces the list.
    //
    // The CLI's own totals used to win outright, on the reasoning that the badge should come from
    // the command path that performs the update. But they are computed from the same items this
    // file walks (lib/common.sh: `[.[] | select(.held|not)] | length`), so the two can only
    // disagree when something is wrong - a half-written state, an entry from an older build, a
    // backend key this widget drops because it is disabled. And whatever the cause, the ROWS are
    // what the person is looking at: "Up to date" sitting over a list of pending updates is the
    // worst thing this popup can say, and the badge would be telling the same lie in the panel.
    //
    // The totals are still the answer when there is nothing to walk. A state that carries counts
    // and no items is not a disagreement, it is a state with no list, and reading it as zero would
    // be exactly the confident-zero mistake rule 1 of the schema exists to prevent.
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
    // numbers stand. A box that has never had a successful check and knows nothing has no counts
    // to be calm about - "up to date" there would be a clean lie, and it is exactly what a box
    // whose root helpers were never installed looks like. That belongs with the errors.
    var neverAnswered = usable && stale && !everSucceeded && nothingKnown;

    var iconState;
    if (updating) iconState = "updating";
    // A SETUP STEP, not a malfunction, and the state vocabulary already has the honest word for
    // it. `error` is the panel's alarm - CompactRepresentation paints update-high and hangs a
    // warning emblem off the icon - and that is a statement about a machine that cannot be
    // trusted. A box where somebody installed the widget and has not installed the engine yet is
    // not that; alarming them on their very first look trains them to ignore the emblem for the
    // day it means something. `uptodate` would be worse: knowing nothing and rendering a clean
    // icon is the confident zero rule 1 of the schema exists to forbid. `unknown` already means
    // exactly what is true here - we have no idea what is pending - and it renders dimmed, with
    // no emblem, which is the panel saying "not answering yet" rather than "broken".
    // Only where there is nothing else to show. With counts from an earlier working engine the
    // rows are still the best truth there is, and they keep their own state below; the message
    // is what says the engine has gone.
    else if (engineMissing && noState) iconState = "unknown";
    else if (noState && cliError !== "") iconState = "error";
    else if (noState) iconState = "unknown";
    else if (!usable) iconState = "error";
    else if (neverAnswered) iconState = "error";
    else if (stale) iconState = "stale";
    else if (actionable > 0) iconState = "updates";
    else iconState = "uptodate";

    // No count, no badge. This is rule 1 of the state schema in one line: "no data" must never
    // reach the panel as a confident zero.
    // Capped at BADGE_MAX ("999+" - see its declaration above for why 999 and not 99) because a
    // four-digit badge stops being a badge and starts being a layout problem in a panel. It stays
    // truthful - "more than 999" is a fact - and the exact number is one hover away in the
    // tooltip, which is never capped.
    var badgeText = "";
    if (usable && actionable > 0) badgeText = actionable > BADGE_MAX ? BADGE_MAX + "+" : String(actionable);

    var countPhrase = "";
    if (usable) {
        // "Up to date" over a list of rows with waiting versions in it is a lie by omission, and
        // the popup draws exactly that whenever every pending update is held (hostile panel, P8).
        // Nothing is ACTIONABLE, which is what the badge and the button are about; the header is
        // the sentence, and the sentence owes the held count.
        countPhrase = actionable === 0
            ? (heldTotal > 0 ? COPY.upToDate + DOT + heldTotal + " " + COPY.held : COPY.upToDate)
            : (actionable === 1 ? "1 update available" : actionable + " updates available");
    }

    // --- a transaction that is already staged and armed ------------------------------------------
    // Derived HERE, above the header, because it changes what the header may say: while a stage is
    // armed the pending count is a true number saying a false thing, and the popup's own banner is
    // already saying the true one. Nine of the returned fields depend on this.
    //
    // heldDnf is walked out of the items collectItems already built rather than re-read from the
    // state: those rows are what the popup is SHOWING as held, and a banner whose warning
    // disagreed with the Held group under it would be the popup contradicting itself in one
    // glance - the same failure the risky_pending isArray note below describes from the other end.
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
    //
    // Silent while a transaction is already staged, and that is not a tidying-up: this message IS
    // the "Install on Next Restart" offer, and offering it over a transaction that is already
    // armed invites a second staging of the same updates. On 2026-09-01 that is exactly what
    // happened - staged at 10:31, nothing visibly changed, staged again at 10:36. The staged
    // message takes its place and explains why nothing is being offered. riskySummary is
    // deliberately NOT silenced: those packages really are still pending until the restart runs.
    //
    // isArray, not a duck-typed length check. A STRING has a numeric length and indexes into its
    // own characters, so `risky_pending: "kernel-core"` used to walk out of here as "11
    // session-critical pending (c, e, k, l, ...)" - eleven package families invented out of one
    // word. The state file is JSON from another program and a schema-1 reader has to tolerate a
    // key of the wrong type; tolerating it means ignoring it, not iterating it.
    var riskyMessage = staged ? "" : riskyMessageOf(
        usable && isArray(state.risky_pending) ? state.risky_pending : []);

    // Strictly the boolean, and only out of a state this build can read. In this schema `false`
    // means "nothing to say", NEVER "no restart needed", and that is not a theoretical caution:
    // backends/dnf.sh's dnf_reboot_needed answers false plus a warning whenever the command could
    // not work the verdict out - rc 1 with an empty stdout (a cold user cache, the DEFAULT state
    // on a fresh install) and every unexpected rc both land there. So a false is indistinguishable
    // from "we could not tell", and nothing here renders an affirmative from it: a message when it
    // is true, silence otherwise. docs/architecture.md's state schema table states the same rule
    // for every reader.
    //
    // Derived up here rather than with the restart message below, because the panel TOOLTIP reads
    // it too now: a pending restart used to be invisible from the panel entirely.
    var rebootNeeded = usable && state.reboot_needed === true;

    var tooltipMain, headerText;
    if (updating) {
        tooltipMain = COPY.updatingHere;
        headerText = COPY.updatingHere;
    } else if (engineMissing) {
        // Names the missing piece instead of quoting the shell. What the panel used to put here
        // was `sh: line 1: kempt: command not found`, which is true, unreadable, and about a
        // program the reader has never heard of.
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
        // The one place the count gives way. Not a second line under the count and not a badge
        // emblem: the header is the sentence a person reads first, and while a stage is armed the
        // honest answer to "where do I stand" is that the work is done and waiting for a restart.
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

    // The whole answer for a box with no engine, assembled here so the popup binds one string.
    // Two lines: what is true, and what to type. Empty in every other state, which is what the
    // popup gates on.
    var engineMissingMessage = engineMissing
        ? COPY.engineMissing + "\n" + COPY.engineMissingInstall : "";
    // What the message's Copy Commands button puts on the clipboard. Empty in every other state
    // for the same reason the message is: the button only exists while the message does.
    var engineMissingCopyText = engineMissing ? COPY.engineMissingCopy : "";

    // Read only out of a state this build can read, like every other optional key: a schema-1
    // reader has to tolerate the key being absent (every file written before this existed) and
    // being the wrong type (it is JSON from another program). formatDownload answers "" to both.
    var downloadText = usable ? formatDownload(state.download_bytes) : "";

    var subParts = [];
    // The fact, and only the fact. The install commands belong in the popup, where they can be
    // read and copied; a panel tooltip is a hover, and two command lines in one is noise there.
    if (engineMissing) subParts.push(COPY.engineMissing);
    else if (iconState === "unknown") subParts.push("no data yet - the first check has not finished");
    else if (iconState === "error") subParts.push(problemText);
    else {
        // The Holds promise: a box whose only pending updates are held LOOKS up to date, and the
        // tooltip is where it still says the held ones exist.
        if (heldTotal > 0) subParts.push(heldTotal + " " + COPY.held);
        // Only when there is something to download AND something to press. On an up-to-date box
        // the number is zero or absent and would say nothing; next to a held-only list it would
        // describe bytes no run is going to fetch.
        if (actionable > 0 && downloadText !== "") subParts.push(downloadText + " to download");
        // Staleness is a tooltip fact, not an icon alarm - so the tooltip has to actually carry
        // BOTH halves: what went wrong, and how old the numbers above it therefore are. Without
        // the reason, "last successful check: yesterday" leaves the user guessing why.
        if (stale) {
            subParts.push(staleReason);
            subParts.push("last successful check: " + lastSuccessText);
        }
        // A pending restart was invisible from the panel: neither the icon nor this line mentioned
        // it, so the one fact that needs an action from the person could only be found by opening
        // the popup. Discover's own notifier has a "Restart is required" state (hostile panel, 4).
        // Last, because it is a fact about the machine rather than about the counts above it.
        if (rebootNeeded) subParts.push(COPY.restartPending);
    }

    // What the popup shows where the list would be, when there is no list to show.
    var emptyStateText = "";
    if (updating) emptyStateText = "";
    // Silent, and that silence is what keeps the popup from saying one thing twice: the
    // engine-missing InlineMessage is already carrying the whole answer, and the placeholder's
    // own sentence ("the first check has not finished") would be a promise about a check that is
    // never going to finish. The placeholder hides itself on empty text.
    else if (engineMissing) emptyStateText = "";
    else if (iconState === "unknown") emptyStateText = "No update data yet. The first check has not finished.";
    else if (iconState === "error") emptyStateText = problemText;
    else if (nothingKnown) {
        emptyStateText = stale ? "No updates in the last known state." : COPY.everythingUpToDate;
    }

    // The one thing a stuck user can usefully be told to type - offered ONLY where the widget has
    // nothing else to show: a CLI it could not run, or a box that has never had a successful
    // check. Deliberately NOT offered on calm staleness. Keeping quiet about a repo that flapped
    // is the entire point of that state, and a "run kempt doctor" line under counts that are
    // perfectly good is exactly the noise it exists to avoid. The CLI's own words are still
    // shown there via staleReason, which names doctor itself when that is what is wrong.
    //
    // ...and NOT offered when the engine is missing either, which is the case that proved the
    // rule. `kempt doctor` is a kempt subcommand: on the box where kempt is what is absent, this
    // line told the user to run the very thing they do not have. Nothing is runnable in that
    // state, so nothing is offered, and the message carries the install commands instead.
    var remedyCommand = (!engineMissing && (cliError !== "" || neverAnswered)) ? "kempt doctor" : "";

    // --- the restart, and what the popup is allowed to say about it -----------------------------
    // `rebootNeeded` itself is derived above, next to the tooltip that reads it.
    // Absent is not false: the caller simply did not say, and the CLI's default is true.
    var restartReminder = (opts.restartReminder === undefined || opts.restartReminder === null)
        ? true : isTrue(opts.restartReminder);
    var restartMessageVisible = rebootNeeded && restartReminder && !isTrue(opts.restartDismissed);

    // A transaction that is already staged and armed, which changes what the rest of the popup may
    // offer. Derived once, here, because seven of the returned fields depend on it.
    //
    // heldDnf is walked out of the items collectItems already built rather than re-read from the
    // state: those rows are what the popup is SHOWING as held, and a banner whose warning
    // disagreed with the Held group under it would be the popup contradicting itself in one
    // glance - the same failure the risky_pending isArray note below describes from the other end.

    // --- the footer status line ------------------------------------------------------------------
    // "Checked ..." is derived from last_success and NOT last_check, because the counts above it
    // are as of the last check that actually told us something. A check that failed has the stale
    // message to explain itself; dating the counts by it would put a fresh time on stale numbers.
    // The fallback is worded off last_success as well, for the same reason: this line is a
    // DATELINE for the counts, and when no check has ever succeeded there are no counts of any
    // age to date. "Not checked yet" would have conflated that with a box that never ran a check
    // at all - and the two differ precisely on the bad day, where a stale state carries a
    // last_check and an empty last_success.
    // --- which messages actually fit ------------------------------------------------------------
    // Decided HERE and not in the popup, because the footer depends on the answer: a restart the
    // cap displaced has to reappear as "restart pending" on the status line, and a popup that made
    // this decision by itself would leave logic.js unable to tell whether it had.
    //
    // `reportShown` is the one input this file cannot derive. The post-run line and a failed
    // press are main.qml's own state, not the CLI's, so the caller passes the answer in - the same
    // way it passes the clock and the two halves of the restart reminder.
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

    var footerParts = [];
    if (usable) {
        // Three answers, and the third one is silence. A stamp that is present and unreadable
        // gives relativeTime nothing to work with, so it hands the text back verbatim - right for
        // a tooltip, wrong in a sentence, where it reads "Checked not a date". Nothing is said
        // instead, and the raw stamp stays one hover away in footerTooltip, which is where a
        // value we cannot interpret belongs.
        if (!everSucceeded) footerParts.push(COPY.noSuccessfulCheckYet);
        else if (isRenderableStamp(state.last_success)) {
            footerParts.push("Checked " + relativeTime(state.last_success, opts.nowMs));
        }
        // ...and the staleness, right beside the date it explains. This is the whole of the stale
        // InlineMessage now: three words on the line that dates the counts, with the CLI's own
        // reason one hover away on the button that tries again. It is not an alarm - the counts
        // above are still the best known truth - and it never was worth a box of its own.
        if (stale) footerParts.push(COPY.lastCheckFailed);
    } else if (noState) {
        // No state at all - the first seconds of a session, or a CLI that could not be run. There
        // has been no successful check as far as this widget knows, and saying so is true.
        footerParts.push(COPY.noSuccessfulCheckYet);
    }
    // ...and the case with no branch: a state we HOLD and cannot read (a schema this build does
    // not know). It may well record a successful check; we cannot tell. "No successful check yet"
    // over it is a claim with nothing behind it, and the header already says the state could not
    // be read.
    if (heldTotal > 0) footerParts.push(heldTotal + " " + COPY.held);
    // Founder amendment A1: the two-word fact, and ONLY when the message is not already carrying
    // it. With the reminder switched off (or dismissed for this session) there is no message and
    // no button, but the popup still says a restart is pending - a popup that hides that is lying
    // to the person looking at it. With the message on screen, repeating it would be the same fact
    // twice in one small window.
    // Beside Update Now, which is the question it answers: pressing this costs about this much.
    // Same two conditions as the tooltip, and the same silence when either fails.
    if (actionable > 0 && downloadText !== "") footerParts.push(downloadText);
    // ...and the restart, whenever the message is not the thing carrying it. That now includes a
    // restart the CAP displaced, which is what makes displacing it honest rather than merely
    // quiet: the fact is never lost, it moves to the line that always has room.
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
        // "" when fine; otherwise the CLI's own error text, so the popup's stale banner says what
        // actually went wrong instead of a generic apology.
        staleReason: staleReason,
        cliError: cliError,
        // What the popup says when there is no engine on the box: the fact, then the commands
        // that fix it, on two lines. Empty means there is nothing to say, and that empty string
        // is the popup's only gate - exactly how riskyMessage and stagedMessage already work.
        engineMissingMessage: engineMissingMessage,
        engineMissingCopyText: engineMissingCopyText,
        emptyStateText: emptyStateText,
        remedyCommand: remedyCommand,
        // isArray, not a duck-typed length check. A STRING has a numeric length and indexes into
        // its own characters, so `risky_pending: "kernel-core"` used to walk out of here as
        // "11 session-critical pending (c, e, k, l, ...)" - eleven package families invented out
        // of one word - while riskyMessage below, which already checks properly, said nothing at
        // all. Two answers about the same key, contradicting each other inside one returned
        // object. The state file is JSON from another program and a schema-1 reader has to
        // tolerate a key of the wrong type; tolerating it means ignoring it, not iterating it.
        riskySummary: riskySummaryOf(
            usable && isArray(state.risky_pending) ? state.risky_pending : []),
        // What to DO about that risky set, which is a different question from how big it is.
        //
        // Silent while a transaction is already staged, and that is not a tidying-up: this message
        // IS the "Install on Next Restart" offer, and offering it over a transaction that is
        // already armed invites a second staging of the same updates. On 2026-09-01 that is
        // exactly what happened - staged at 10:31, nothing visibly changed, staged again at 10:36.
        // The staged message takes its place and explains why nothing is being offered.
        // riskySummary above is deliberately NOT silenced: those packages really are still
        // pending until the restart runs, and the count stays true.
        riskyMessage: riskyMessage,
        stagedMessage: stagedMessage,
        // "there is an armed transaction", in one boolean, for the surfaces that have to stand
        // down rather than say something about it. Update Now is hidden on this: pressing it over
        // an armed stage starts a second, live update of the same packages.
        stagedArmed: staged,
        // "positive" for the ordinary armed stage - nothing is wrong, the work is done and
        // waiting - and "warning" once a hold has landed behind it. A string rather than a
        // boolean because the QML binds it to a Kirigami.MessageType, and a third spelling
        // (Information, say) is a plausible next state for this banner rather than an exotic one.
        stagedType: stagedVariant.type,
        // Never two Restart… buttons in one popup: the restart Warning already carries one
        // whenever it is on screen, and this is the same action in a second place.
        //
        // ...and never a Restart… on a warning variant at all, which is the stricter rule and the
        // reason the flip is worth anything. The person is looking at a sentence that says the
        // next restart will install the package they tried to keep out; a button labelled
        // Restart… under it is an invitation to do exactly that.
        stagedShowRestart: staged && !restartMessageVisible && !stagedWarning,
        // ...and what stands in its place. One action, only on the variants where there is
        // something to change: rebuilding an ordinary armed stage would destroy a good
        // transaction (spec G2) to produce the same one back.
        stagedShowRebuild: stagedWarning,
        // Published rather than left as a literal in the QML's Accessible.description, so the
        // words a screen reader hears and the words the tooltip shows are one decision. The QML
        // still writes the literal for i18n extraction; the probe ties the two together.
        stagedRebuildTooltip: COPY.stagedRebuildTooltip,
        // The stamp this banner was derived from, for main.qml's click-time re-verify. Consent is
        // given to a BANNER, and a banner describes ONE transaction: between the render and the
        // click that transaction can be consumed by a restart, replaced by another stage or
        // cleaned away, and a rebuild is destructive at its start. "" means there is nothing to
        // compare, which the re-verify reads as "do not act".
        stagedStagedAt: stagedVariant.stagedAt,
        // The names behind the sentence. The banner shows the first one and a count; anything that
        // has to say them again - a test, an accessible description, a later surface - takes them
        // from here rather than parsing them back out of the sentence.
        stagedConflictNames: stagedVariant.conflictNames,
        lastSuccessText: lastSuccessText,
        rebootNeeded: rebootNeeded,
        restartMessageVisible: restartMessageVisible,
        // ...and whether that message may carry its own Restart button. Everywhere else it may:
        // a restart applies updates that are already installed, which is what the message says.
        // NOT while the staged banner is a warning, and that is the whole point of the flip - in
        // that state a restart installs the very package the warning says the person tried to keep
        // out, and the design had already removed the button from the warning for exactly that
        // reason while leaving the identical one a row above it (hostile panel, HIG M1).
        restartShowAction: restartShown && !stagedWarning,
        // Which messages the popup may draw, in order, and never more than two of them. The rule
        // and its reasons are messageStack above.
        messageSlots: messageSlots,
        footerText: footerParts.join(DOT),
        // Published rather than left inside the two strings above, so a future surface (a
        // notification, a `check --human` line) renders the same words instead of its own.
        downloadText: downloadText,
        // The relative time in footerText is the convenience; this is the truth, and people
        // compare the two. Empty rather than "never" when there has been no successful check: the
        // footer already says there has been none in words, and a tooltip saying "never" under it
        // would be the same nothing said twice.
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
