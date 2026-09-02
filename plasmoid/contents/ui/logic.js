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

    // The offline path, named for what it does to the user rather than for the dnf5 flag that
    // implements it. The tooltip is the whole argument for choosing it.
    installOnNextRestart: "Install on Next Restart",
    installOnNextRestartTooltip:
        "Applies the update during a restart, so nothing changes underneath your running desktop.",

    // What a session-critical transaction is told to do about it. Two sentences, because a box
    // with the NVIDIA driver in the set has a second, worse failure mode (a kernel module built
    // against a kernel that is not the running one), and naming it is what makes the advice
    // credible to the person it happens to.
    kernelRestart: "This includes a kernel update. Restart when it finishes.",
    kernelNvidiaRestart:
        "This includes a kernel update and the NVIDIA driver. Restart when it finishes.",

    // Status-line vocabulary. `held` is a suffix to a number ("3 held"); it is a word rather than
    // a sentence because the same word has to serve the tooltip, which was already saying it.
    held: "held",
    restartPending: "restart pending",
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

    // Right-click, and the popup's own gear. Opens a dialog, so: real ellipsis.
    configure: "Configure Kempt…"
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
function newestOf(versionSet) {
    if (versionSet === null || versionSet === undefined) return "?";
    var s = String(versionSet);
    if (s === "") return "?";
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

// "20 session-critical pending (dbus, glibc, kernel, kf6, ...)" - the popup's offline
// recommendation, worded from the same parts as the CLI's notification.
function riskySummaryOf(names) {
    if (!names || !names.length) return "";
    var fams = familiesOf(names, RISKY_FAMILIES_SHOWN);
    return names.length + " session-critical pending ("
        + fams.shown.join(", ") + (fams.total > fams.shown.length ? ", ..." : "") + ")";
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
    if (familiesOf(names, 0).shown.indexOf("kernel") < 0) return riskySummaryOf(names);
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
// Each row is {kind: "header", title} or {kind: "item", ...the item, plus `held`}.
function rowsOf(sections, heldItems) {
    var rows = [], i, j;
    for (i = 0; i < sections.length; i++) {
        rows.push({ kind: "header", title: sections[i].title });
        for (j = 0; j < sections[i].items.length; j++) rows.push(rowOf(sections[i].items[j], "item"));
    }
    // Held last and always its own group: the spec's promise is that a held item stays VISIBLE
    // with its waiting version, just out of the way of the things you can act on.
    if (heldItems.length > 0) {
        rows.push({ kind: "header", title: "Held" });
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
//
// cliError is the widget's own report of a check that produced nothing usable - the CLI missing
// from PATH, say. It is NOT the same thing as the CLI reporting a problem: when `kempt check`
// runs and something inside it fails, it says so in the state's own `error` field and that comes
// out as staleReason. This argument is only for "we could not get an answer at all".
//
// iconState is decided in this order, and the order is the contract:
//   updating   - we started a run; it wins over whatever the last check said
//   error      - no state AND the CLI failed us, or an object that is not schema v1
//   unknown    - no state, but nothing has gone wrong yet (first load, still checking)
//   stale      - the last check failed; the counts below are the last known good ones
//   updates    - actionable > 0
//   uptodate   - actionable == 0 (held items do not count: spec, Holds semantics)
//
// Note what "stale" deliberately is NOT: an error. The counts are the best known truth and the
// user does not need alarming about a repo that flapped, so the panel keeps rendering the
// CONTENTS (a count badge, or nothing) and the explanation goes in the tooltip. Only a genuine
// "we cannot read this at all" earns a warning emblem.
function viewModel(state, updating, cliError, opts) {
    updating = !!updating;
    cliError = firstLineOf(typeof cliError === "string" ? cliError : "");
    opts = (opts && typeof opts === "object") ? opts : {};
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
        countPhrase = actionable === 0 ? COPY.upToDate
            : (actionable === 1 ? "1 update available" : actionable + " updates available");
    }

    var tooltipMain, headerText;
    if (updating) {
        tooltipMain = "Updating…";
        headerText = "Updating…";
    } else if (iconState === "unknown") {
        tooltipMain = "Kempt";
        headerText = "No update data yet";
    } else if (iconState === "error") {
        tooltipMain = "Kempt";
        headerText = (cliError !== "" || neverAnswered)
            ? "Kempt cannot check for updates"
            : "Could not read the update state";
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

    // Read only out of a state this build can read, like every other optional key: a schema-1
    // reader has to tolerate the key being absent (every file written before this existed) and
    // being the wrong type (it is JSON from another program). formatDownload answers "" to both.
    var downloadText = usable ? formatDownload(state.download_bytes) : "";

    var subParts = [];
    if (iconState === "unknown") subParts.push("no data yet - the first check has not finished");
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
    }

    // What the popup shows where the list would be, when there is no list to show.
    var emptyStateText = "";
    if (updating) emptyStateText = "";
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
    var remedyCommand = (cliError !== "" || neverAnswered) ? "kempt doctor" : "";

    // --- the restart, and what the popup is allowed to say about it -----------------------------
    // Strictly the boolean, and only out of a state this build can read. In this schema `false`
    // means "nothing to say", NEVER "no restart needed", and that is not a theoretical caution:
    // backends/dnf.sh's dnf_reboot_needed answers false plus a warning whenever the command could
    // not work the verdict out - rc 1 with an empty stdout (a cold user cache, the DEFAULT state
    // on a fresh install) and every unexpected rc both land there. So a false is indistinguishable
    // from "we could not tell", and nothing here renders an affirmative from it: a message when it
    // is true, silence otherwise. docs/architecture.md's state schema table states the same rule
    // for every reader.
    var rebootNeeded = usable && state.reboot_needed === true;
    // Absent is not false: the caller simply did not say, and the CLI's default is true.
    var restartReminder = (opts.restartReminder === undefined || opts.restartReminder === null)
        ? true : isTrue(opts.restartReminder);
    var restartMessageVisible = rebootNeeded && restartReminder && !isTrue(opts.restartDismissed);

    // A transaction that is already staged and armed, which changes what the rest of the popup may
    // offer. Derived once, here, because three of the returned fields depend on it.
    var stagedMessage = usable ? stagedMessageOf(state.offline_staged) : "";
    var staged = stagedMessage !== "";

    // --- the footer status line ------------------------------------------------------------------
    // "Checked ..." is derived from last_success and NOT last_check, because the counts above it
    // are as of the last check that actually told us something. A check that failed has the stale
    // message to explain itself; dating the counts by it would put a fresh time on stale numbers.
    // The fallback is worded off last_success as well, for the same reason: this line is a
    // DATELINE for the counts, and when no check has ever succeeded there are no counts of any
    // age to date. "Not checked yet" would have conflated that with a box that never ran a check
    // at all - and the two differ precisely on the bad day, where a stale state carries a
    // last_check and an empty last_success.
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
    if (rebootNeeded && !restartMessageVisible) footerParts.push(COPY.restartPending);

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
        riskyMessage: staged ? "" : riskyMessageOf(
            usable && isArray(state.risky_pending) ? state.risky_pending : []),
        stagedMessage: stagedMessage,
        // Never two Restart… buttons in one popup: the restart Warning already carries one
        // whenever it is on screen, and this is the same action in a second place.
        stagedShowRestart: staged && !restartMessageVisible,
        lastSuccessText: lastSuccessText,
        rebootNeeded: rebootNeeded,
        restartMessageVisible: restartMessageVisible,
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
