// logic.js - the widget's entire derivation layer, in ENGINE-AGNOSTIC JavaScript.
//
// Loaded twice: by the plasmoid (`import "logic.js" as Logic`, QML's JS engine) and by
// tests/test_widget_logic.sh (node, through the CommonJS guard at the bottom). That is the point.
// A QML plasmoid cannot be executed in a test suite, so every rule the panel shows a human - the
// badge number, the icon state, the tooltip, the popup rows - is derived HERE, where a node test
// can pin it. Nothing in this file may touch Qt, the filesystem or a network.
//
// Words go through i18n(): one whole sentence per call, written where it is used, with i18np for
// counts. Plasma provides i18n in the scope this file shares with the QML that imports it, and the
// node guard at the bottom provides an English one. Never call it at load time, in a table: it
// must run for each answer, and a sentence built from fragments cannot be translated.
//
// NOT `.pragma library`: that pragma is not valid JavaScript, so node could not load this file at
// all, and a library file cannot see the i18n of the QML that imports it.
// Old-school JS (var, function expressions, indexOf): this runs unchanged in whatever JS engine
// the installed Plasma version ships.
//
// Input contract: state schema v1 (docs/architecture.md), the CLI's frozen public interface. Two
// of its rules are load-bearing and enforced below:
//   1. empty stdout with exit 0 means "no data, keep the last known state", NEVER "zero updates";
//   2. `status: "stale"` keeps the last known counts - a tooltip fact, not a fabricated 0.

var BACKEND_ORDER = ["dnf", "flatpak"];

// Titles match the CLI's own renderer (lib/common.sh render_summary) so the popup and the terminal
// never name the same group differently.
function sectionTitleOf(key) {
    return key === "dnf" ? i18n("System") : key === "flatpak" ? i18n("Apps") : key;
}

// A backend may group its pending items further, by the `kind` its items carry. Flatpak is the one
// that does: `flatpak update` updates runtimes as well as apps, so Kempt counts and itemizes them -
// and they get a heading of their own UNDER the apps rather than sitting among them beneath a title
// that says "Apps". An item with no `kind` at all is the ordinary case and keeps the backend's own
// heading, which is what makes the key additive: every state file written before runtimes were
// counted has no `kind` anywhere in it and renders exactly as it always did.
function kindTitleOf(key, kind) {
    return key === "flatpak" && kind === "runtime" ? i18n("Flatpak runtimes") : key + " " + kind;
}

// MIDDLE DOT with a space each side. One constant, because the footer status line and the Last
// update row both use it and two would drift the first time one was edited.
var DOT = " \u00b7 ";

// How big the pending download is, in words.
// "~", never "up to": the figure has error in BOTH directions, so any wording implying a ceiling
// is false - dnf pulls in dependencies `--upgrades` never listed, flatpak transfers ostree deltas
// far smaller than the published size, and a transaction already staged offline is downloaded in
// full while the number still counts it, so the view model shows no figure while a stage is armed.
// Under a megabyte it says "< 1 MB": nobody decides differently between 300 kB and 800 kB, and a
// number that small next to an update button invites the reader to think it is precise.
// "" for absent, zero, negative or not-a-number, and empty means render NOTHING: no "unknown",
// no "0 MB", no dash.
function formatDownload(bytes) {
    if (typeof bytes !== "number" || !isFinite(bytes) || bytes <= 0) return "";
    if (bytes < 1000000) return i18n("< 1 MB");
    var mb = Math.round(bytes / 100000) / 10;
    // 999999999 bytes rounds to 1000.0 MB, which is a gigabyte spelled the long way.
    if (mb < 1000) return i18n("~%1 MB", trimZero(mb));
    return i18n("~%1 GB", trimZero(Math.round(bytes / 100000000) / 10));
}

// One decimal, minus a pointless one. Not toFixed(1) plus a string trim: toFixed rounds a second
// time on an already-rounded value, and the two can disagree at the boundary.
function trimZero(n) {
    return String(Math.round(n * 10) / 10);
}

// How many session-critical families the offline recommendation names before ", …". Same number
// the CLI's notification uses (bin/kempt), which ends its list in three ASCII dots instead.
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

// Is this really an array? `typeof v.length === "number"` is not enough: a STRING has a length,
// and iterating one yields characters that would render as packages.
function isArray(v) { return Object.prototype.toString.call(v) === "[object Array]"; }
function arrayOf(v) { return isArray(v) ? v : []; }

// What a config with no `surface` key runs on: lib/common.sh's kempt_default, which this twins.
var DEFAULT_SURFACE = "popup";

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
// anything unknown is `popup`, because that is what the CLI itself would run.
// `widget` is the CLI's other name for the stored `popup`, and an older config's `background` or
// `terminal` reads as it too (lib/common.sh, surface_canon).
function resolveSurface(value) {
    var s = String(value === undefined || value === null ? "" : value).trim().toLowerCase();
    return s === "offline" ? s : "popup";
}

// updatingLabelOf(surface) -> what the pane says while a run on that surface is in flight. Takes
// the surface the RUNNING transaction is using, which is not always the configured one: Install on
// Next Restart stages offline whatever the setting says.
function updatingLabelOf(surface) {
    return resolveSurface(surface) === "offline" ? i18n("Preparing updates for the next restart…") : i18n("Updating…");
}

// updateButtonOf(surface, dnfActionable, flatpakPending) -> the footer button: whether the press
// stages, its label, and its tooltip. Only system updates stage, so with none actionable (only Flatpak pending, or every dnf update
// held) the press stages nothing and the button says Update Now. The tooltip names Flatpak only
// when Flatpak apps are waiting.
function updateButtonOf(surface, dnfActionable, flatpakPending) {
    if (resolveSurface(surface) !== "offline" || typeof dnfActionable !== "number" || !(dnfActionable > 0))
        return { stages: false, text: i18n("Update Now"), tooltip: "" };
    return { stages: true, text: i18n("Install on Next Restart"),
             tooltip: stageTooltipOf(flatpakPending) };
}

// stageTooltipOf(flatpakPending) -> the tooltip of a press that installs at the next restart. Only
// promises that Flatpak apps update now when some are waiting.
function stageTooltipOf(flatpakPending) {
    return flatpakPending === true ? i18n("System updates install during the next restart. Apps update now.")
                                   : i18n("System updates install during the next restart.");
}

// backendActionable(state, key) -> the actionable count of one backend: 0 when it is disabled or
// absent, its own count when it publishes one, else its items that are not held.
function backendActionable(state, key) {
    var b = (state && state.backends && typeof state.backends === "object") ? state.backends[key] : null;
    if (!b || typeof b !== "object" || b.enabled === false) return 0;
    if (typeof b.actionable === "number") return b.actionable;
    var items = (b.items && typeof b.items.length === "number") ? b.items : [], n = 0;
    for (var i = 0; i < items.length; i++) if (items[i] && !items[i].held) n++;
    return n;
}

// --- how big the panel icon is asked to be -----------------------------------------------------
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

// snapIconSize(cell, steps) -> the hinted size the icon asks for in a cell this thick.
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

// resolveReclaimSetting(value) -> ask | off, read as the CLI's reclaim_mode reads it: case-folded,
// and anything that is not exactly off is ask.
function resolveReclaimSetting(value) {
    return String(value === undefined || value === null ? "" : value).toLowerCase() === "off" ? "off" : "ask";
}

// --- the watcher stamp -----------------------------------------------------------------------
// main.qml polls eight mtimes every 30 seconds. WHICH of them moved is the part that matters,
// because /var/lib/rpm is rewritten continuously all the way through a dnf transaction: comparing
// the stamp as one string says only "something changed", which during a run of ours is true every
// 30 seconds - so the widget declares the run finished a few seconds in, prints a summary of the
// PREVIOUS run, and starts a `kempt check` that wants the lock the transaction is holding. Only
// OUR state file says a run ended, and these field names are that distinction (here, not in QML,
// so node can pin them).
// The eight paths main.qml stats, in its order: rpmdb.sqlite, the rpm directory, flatpak,
// state.json, config, then dnf5's offline directory, its state file and /system-update. The first
// two are one question - "did the package database move" - asked of the file Fedora actually
// writes and of the directory an older rpm layout wrote. The last three are another: did a stage
// appear, get armed or go away. `dnf5 offline clean` moves none of the first five, so a stage
// cleaned in a terminal went unseen until the next timed check.
var WATCH_FIELDS = 8;
var WATCH_STATE_FIELD = 3;
var WATCH_CONFIG_FIELD = 4;
var WATCH_STAGE_FROM = 5;

// watchChange(prev, next) -> { any, packages, state, config, stage, comparable }
// `comparable` is false when either stamp is neither the eight fields main.qml asks for nor the
// five an older widget asked for. Then the answer degrades to a whole-string comparison with
// every category true, rather than guessing which column is which: wrong-but-noisy beats
// wrong-and-silent when what is at stake is noticing a finished run. A five-field stamp is the
// first five of today's in the same order, so beside an eight-field one those five are compared
// and the stage fields, which one side never saw, are not news.
function watchChange(prev, next) {
    var a = watchFieldsOf(prev), b = watchFieldsOf(next), i, n;
    var out = { any: false, packages: false, state: false, config: false, stage: false,
                comparable: false };
    if (!watchLayoutKnown(a.length) || !watchLayoutKnown(b.length)) {
        out.any = a.length > 0 && b.length > 0 && a.join(" ") !== b.join(" ");
        out.packages = out.any;
        out.state = out.any;
        out.config = out.any;
        out.stage = out.any;
        return out;
    }
    out.comparable = true;
    n = Math.min(a.length, b.length);
    for (i = 0; i < n; i++) {
        if (a[i] === b[i]) continue;
        out.any = true;
        if (i === WATCH_STATE_FIELD) out.state = true;
        else if (i === WATCH_CONFIG_FIELD) out.config = true;
        else if (i >= WATCH_STAGE_FROM) out.stage = true;
        else out.packages = true;
    }
    return out;
}

function watchLayoutKnown(n) {
    return n === WATCH_FIELDS || n === WATCH_STAGE_FROM;
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
// somebody ASKING. The end of a run is not checked from the widget at all: the CLI checks on its
// way out, and the widget waits for that (main.qml, pollWatch's `endedRun`). A package database
// move inside the window is postponed to its end (watcherQuietLeft), never dropped: it is never a
// check's or a run's own footprint, and a dropped one stayed missed, so a stage another program
// had cancelled still read as staged.
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

// watcherQuietLeft(lastCheckFinished, now) -> milliseconds until the quiet window ends, at least 1
// (a Timer with interval 0 never fires), and 1 whenever watcherCheckDue would already say yes.
function watcherQuietLeft(lastCheckFinished, now) {
    if (watcherCheckDue(lastCheckFinished, now)) return 1;
    return Math.max(1, CHECK_QUIET_MS - (Number(now) - Number(lastCheckFinished)));
}

// checkedSince(state, sinceMs) -> whether `state` was written by a check that ran after `sinceMs`.
// A run ends with the CLI's own check (the end of cmd_update), and that check is what the widget
// used to run a second time. last_check has whole seconds, so `sinceMs` is floored to its second:
// a check stamped in the same second as the press counts. A state with no readable last_check
// answers no, which means the caller checks - the safe side.
function checkedSince(state, sinceMs) {
    if (!state || typeof state !== "object") return false;
    var at = stampMs(state.last_check), since = Number(sinceMs);
    if (!isFinite(at) || !isFinite(since) || since <= 0) return false;
    return at >= Math.floor(since / 1000) * 1000;
}

// checkedAfterRun(state, run, sinceMs) -> checkedSince, anchored to the run's END rather than its
// press. `run` is the newest history entry. The CLI writes it before its closing check, so a check
// stamped at or after it is that check - and one stamped between the press and the entry is not:
// a check somebody asked for mid-run. That check's last_check survives into the state the run
// publishes on its way out (publish_staged_state touches only the staged key), so the press alone
// would take it for the closing check and stand the fallback down before the real one had landed.
// With no entry of this run's (a run that ended before writing one, or a summary that did not
// answer) the press is the only anchor there is.
function checkedAfterRun(state, run, sinceMs) {
    var at = run ? stampMs(run.when) : NaN;
    var anchor = isFinite(at) && runFinishedSince(run, sinceMs) ? at : sinceMs;
    return checkedSince(state, anchor);
}

// holdsOf(text) -> [{ id, backend, name }] from `kempt holds` output (raw `backend:name` lines).
// Split at the FIRST colon, exactly like cmd_hold's ${1%%:*} / ${1#*:}, so a name containing a
// colon still round-trips to the same hold the CLI would remove.
// discoverSettingOf(stdout) -> what Settings shows for Discover's notifier, from
// `kempt discover-notifier status --json`: {state, verb}. state is "on", "off" (by Kempt) or "own"
// (off by the person's own entry), and picks the sentence: discoverStatusOn, Off or Own. verb is
// the command the button runs, "off" or "on", or "" for no button. null when there is nothing to
// show: not installed, or no answer. Turn On is offered only for Kempt's own entry, the one `on`
// can remove.
function discoverSettingOf(stdout) {
    var st;
    try { st = JSON.parse(String(stdout === undefined || stdout === null ? "" : stdout)); }
    catch (e) { return null; }
    if (!st || typeof st !== "object" || st.installed !== true) return null;
    if (st.enabled === true) return { state: "on", verb: "off" };
    if (st.by_kempt === true) return { state: "off", verb: "on" };
    return { state: "own", verb: "", path: typeof st.entry === "string" ? st.entry : "" };
}

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

// logTailOf(text) -> the run's log tail as the widget shows it. dnf pads a line out to a counter
// at the right edge ("Upgrading bash-5.3-1.fc44.x86_64          31/62"). The widget wraps long
// lines, so the padding would push the counter onto a line of its own. It becomes one space.
function logTailOf(text) {
    if (typeof text !== "string") return "";
    return text.replace(/[ \t]{2,}(\d+\/\d+)[ \t]*$/gm, " $1");
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
    // state of this pair, not an edge case: the CLI and the widget are separate packages, and Plasma
    // keeps the QML it loaded until it restarts - and a schema 2 field could mean anything.
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
    return from === VERSION_UNKNOWN ? i18n("new") : from;
}

// What a row draws BETWEEN two versions, which is not always an arrow. A Flatpak runtime can get a
// genuine update whose version string does not move: most runtimes carry a date, or nothing at all,
// in their version metadata, and the commit is what actually differs. Measured on a real box: 3 of 7
// installed runtimes had NO version string, so an update to them arrived as "? -> ?", and a theme
// runtime's update arrived as "2024-05-30 -> 2024-05-30". An arrow between two identical values, or
// between two unknowns, tells the reader the update is fictional.
//
// Returns "" when there is nothing honest to draw at all, and the caller hides the line rather than
// printing punctuation around two blanks. Both QML sites and the CLI's own summary follow this rule,
// so one update reads the same everywhere.
function versionTextOf(from, to) {
    if (from === VERSION_UNKNOWN && to === VERSION_UNKNOWN) return "";
    if (from === to) return i18n("%1 (new build)", String(to));
    return fromTextOf(from) + " \u2192 " + to;
}

// A runtime's identity is its id AND its branch, and the two are folded into one `id/branch` key so
// that sort, join and the snapshot diff have a single field to work on. That key is a JOIN KEY, not
// a name: the pending rows already split it back apart and draw "org.kde.Platform 5.15-24.08", while
// the history rows drew the raw fold, so one transaction was spelled two ways by one product.
//
// The LAST slash is always the one Kempt added - a flatpak app id cannot contain one, which is
// exactly why that character was chosen as the separator - and a dnf package name has no slash at
// all, so this is a no-op for everything else.
function displayNameOf(name) {
    var s = String(name === null || name === undefined ? "" : name);
    var i = s.lastIndexOf("/");
    return i > 0 ? s.slice(0, i) + " " + s.slice(i + 1) : s;
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

// The families Kempt ships a plain-language name for. "mesa" is a package name, not a word, and
// this popup asks somebody whether it is safe to update their graphics driver while the desktop is
// running - a question nobody can answer in vocabulary they do not have.
//
// Mirrors family_label in lib/common.sh on purpose: the terminal listing, this popup and the
// notification all describe one transaction, and three vocabularies for it would be the product
// disagreeing with itself. Cases are FAMILIES as familiesOf derives them (the name up to its first
// - or .), so plasma-workspace is "plasma" and kwin-x11 is "kwin".
//
// ONLY the families in the DEFAULT risky_regex appear here. risky_regex is the user's to extend, so
// an unknown family keeps its bare name rather than wearing a description nobody wrote for it.
function labelFor(family) {
    switch (family) {
    // TRANSLATORS: A name in a comma list, in brackets inside a longer sentence.
    case "kernel": return i18n("the Linux kernel");
    // TRANSLATORS: A name in a comma list, in brackets inside a longer sentence.
    case "systemd": return i18n("the service manager");
    // TRANSLATORS: A name in a comma list, in brackets inside a longer sentence.
    case "glibc": return i18n("the core system library");
    // TRANSLATORS: A name in a comma list, in brackets inside a longer sentence.
    case "dbus": return i18n("the system message bus");
    // TRANSLATORS: A name in a comma list, in brackets inside a longer sentence.
    case "mesa": return i18n("graphics drivers");
    // TRANSLATORS: A name in a comma list, in brackets inside a longer sentence.
    case "qt6": return i18n("the desktop toolkit");
    // TRANSLATORS: A name in a comma list, in brackets inside a longer sentence.
    case "kf6": return i18n("KDE framework libraries");
    // TRANSLATORS: A name in a comma list, in brackets inside a longer sentence.
    case "plasma": return i18n("the Plasma desktop");
    // TRANSLATORS: A name in a comma list, in brackets inside a longer sentence.
    case "kwin": return i18n("the window manager");
    }
    return "";
}

// The families in a risky set, capped, as both sentences below name them. One function, because a
// count sentence and a recommendation listing the same set differently would be the popup
// disagreeing with itself about one transaction.
//
// LABELS, not package names: the popup already lists every pending package by name in its rows, so
// the sentence's job is to say what those packages ARE. The terminal listing keeps the name beside
// the label, because there the name is the row's identity and there is room for both.
function riskyFamiliesOf(names) {
    // Only the parts with a plain name. A set with none of them still says what it holds.
    var all = familiesOf(names, 0).shown, out = [], i, lbl;
    for (i = 0; i < all.length; i++) {
        lbl = labelFor(all[i]);
        if (lbl !== "") out.push(lbl);
    }
    if (out.length === 0) out = all;
    var shown = out.slice(0, RISKY_FAMILIES_SHOWN);
    return shown.join(", ") + (out.length > shown.length ? ", …" : "");
}

// pendingNamesOf(sections, riskyNames) -> "kernel-core, bash, curl and 7 more", for the panel
// tooltip. The session-critical rows come first, then the list's own order. Only names that are
// rows in the list, so the tooltip never names a package the popup does not show.
var PENDING_NAMES_SHOWN = 3;
function pendingNamesOf(sections, riskyNames) {
    var risky = [], rest = [], i, j, items, name;
    var riskySet = {};
    for (i = 0; riskyNames && i < riskyNames.length; i++) riskySet[String(riskyNames[i])] = true;
    for (i = 0; sections && i < sections.length; i++) {
        items = sections[i].items || [];
        for (j = 0; j < items.length; j++) {
            name = items[j].name;
            if (!name) continue;
            (Object.prototype.hasOwnProperty.call(riskySet, name) ? risky : rest).push(name);
        }
    }
    var all = risky.concat(rest), shown = all.slice(0, PENDING_NAMES_SHOWN);
    if (shown.length === 0) return "";
    // TRANSLATORS: A list of package names goes into a longer sentence as this. %2 is the names and %1 how many more.
    if (all.length > shown.length) return i18np("%2 and %1 more", "%2 and %1 more", all.length - shown.length, shown.join(", "));
    if (shown.length === 1) return shown[0];
    // TRANSLATORS: A list of package names goes into a longer sentence as this.
    return i18n("%1 and %2", shown.slice(0, -1).join(", "), shown[shown.length - 1]);
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
    if (!riskyHasKernel(names)) return i18n("The next restart is the safest time to change parts your desktop is using (%1).", riskyFamiliesOf(names));
    for (var i = 0; i < names.length; i++) {
        if (String(names[i]).toLowerCase().indexOf("nvidia") >= 0) return i18n("The next restart is the safest time to install a new kernel and NVIDIA driver.");
    }
    return i18n("The next restart is the safest time to install a new kernel.");
}

// statusLineOf(count, names) -> the status line over a set with a session-critical package in it.
function statusLineOf(count, names) {
    return riskyHasKernel(names)
        ? i18np("1 update, including a new kernel", "%1 updates, including a new kernel", count)
        : i18np("1 update, including parts your desktop is using", "%1 updates, including parts your desktop is using", count);
}

function riskyHasKernel(names) {
    // The 0 is a cap of NONE and has to stay one. This is a LOOKUP, not a list being shown:
    // RISKY_FAMILIES_SHOWN caps what riskyFamiliesOf PRINTS, and passing it here - the
    // obvious-looking tidy-up - would make the kernel warning depend on where "kernel" falls in an
    // alphabetical sort. Four families ahead of it (akmod, alsa, atk, bash) and the most important
    // sentence this popup has silently stops being said.
    return familiesOf(names, 0).shown.indexOf("kernel") >= 0;
}

// stagedMessageOf(offline_staged) -> what the next restart will install, in one sentence.
//
// The CLI publishes this key only for a transaction genuinely ARMED, read from dnf5's own files
// (lib/common.sh, offline_staged_state), so the judgement is not re-derived here: the key's presence
// IS the answer. The count is optional and no reader may invent it - with dnf5's list unreadable the
// sentence loses the number rather than gaining a wrong one. The type check matters because this is JSON
// from another program: a string here would reach `.count` as undefined and render the popup's
// most reassuring sentence about a transaction that does not exist.
function stagedMessageOf(staged) {
    if (!staged || typeof staged !== "object" || isArray(staged)) return "";
    var n = staged.count;
    if (typeof n !== "number" || !isFinite(n) || n < 0) return i18n("They install the next time you restart.");
    // Exactly one takes the singular - zero is plural in English ("0 updates"), so `=== 1`.
    return n === 1 ? i18n("It installs the next time you restart.") : i18n("They install the next time you restart.");
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
//   restart  a restart is owed. The footer says "restart pending" whenever this message is not on
//            screen, and the footer wraps rather than cutting its last words off.
//   reclaim  unused Flatpak runtimes. Last: the space stays free to take at any later open.
// `releaseUpgrade` sits below the report and imageBased, above Kempt's own staged transaction:
// the next restart replaces the whole operating system, which outranks anything below it, and it is the reason the offline
// button is missing - a person looking for that button needs this message, not the one it displaced.
// `question` comes first because it answers the Update Now press just made, and nothing runs until
// it is answered. Either a session-critical set or another updater's restart asks it, never both.
// `discover`, in its serious form, moves up to right after `staged`: it says who may take the
// restart that message is counting on. It draws once, so what it displaces is back on the next open.
// In its mild form it stays last but one: it is about something that may happen.
// `startup` (a service that stopped starting after an update) sits above the restart: a live run
// that broke a service and owes a restart shows its report and the failure, and the footer says
// `restart pending`.
var MESSAGE_ORDER = ["question", "report", "blocked", "staged", "startup",
                     "restart", "discover", "reclaim"];

// messageStack(wants) -> the messages that may actually be drawn, in order.
// `engineFault` is not in the order at all: it shows ALONE, because everything below it presumes
// an engine that answered. The one exception is the result of its own Check Installation button.
// Anything displaced is not shown. It does not shuffle into the next slot mid-glance, and it does
// not stack below the fold.
// `doctor`, the result of Check Installation, is outside the cap. It answers a press made seconds
// ago, so it must show whatever else is up, and it must not push out the staged or restart banner
// to do it. It sits under the report whose button asked for it, or first when there is none, and
// it closes with its own button.
function messageStack(wants) {
    var w = (wants && typeof wants === "object") ? wants : {};
    if (w.engineFault) return w.doctor ? ["engineFault", "doctor"] : ["engineFault"];
    var out = [], i, order = MESSAGE_ORDER;
    if (w.discover === "serious") {
        order = MESSAGE_ORDER.filter(function (key) { return key !== "discover"; });
        order.splice(order.indexOf("staged") + 1, 0, "discover");
    }
    for (i = 0; i < order.length && out.length < MESSAGE_CAP; i++) {
        if (w[order[i]]) out.push(order[i]);
    }
    if (w.doctor) {
        var at = out.indexOf("report");
        out.splice(at >= 0 ? at + 1 : 0, 0, "doctor");
    }
    return out;
}

// --- did everything come back after the update? (state.json `startup`) -----------------------
// The block is optional: absent while notify_startup is off or systemctl does not answer. Every
// entry is checked before it is believed, and a unit name outside systemd's alphabet (the one
// `kempt startup mute` accepts) is left out rather than given buttons that cannot work.
var STARTUP_UNIT_RE = /^[A-Za-z0-9_@\\][A-Za-z0-9_.@:\\-]*$/;
var STARTUP_DIGEST_RE = /^[0-9a-f]{16}$/;

function startupEntriesOf(list) {
    var out = [], items = arrayOf(list), i, e;
    for (i = 0; i < items.length; i++) {
        e = items[i];
        if (!e || typeof e !== "object" || typeof e.unit !== "string") continue;
        if (e.unit.length > 255 || !STARTUP_UNIT_RE.test(e.unit)) continue;
        // A scope Kempt does not know is left out: guessing "system" would point the buttons at
        // a different unit than the one that failed.
        if (e.scope !== "user" && e.scope !== "system") continue;
        out.push({ unit: e.unit, scope: e.scope,
                   name: typeof e.description === "string" && e.description !== "" ? e.description : e.unit });
    }
    return out;
}

// The command Copy Command copies, as `kempt startup` prints it: quoted when the unit holds a
// backslash (systemd's escapes), which a shell would otherwise eat.
function startupCommandOf(entry) {
    var u = entry.unit.indexOf("\\") >= 0 ? "'" + entry.unit + "'" : entry.unit;
    return (entry.scope === "user" ? "systemctl --user status " : "systemctl status ") + u;
}

// startupVerbArgs("mute"|"unmute", entry) -> the arguments after `kempt`, unit shell-quoted.
function startupVerbArgs(verb, entry) {
    if (verb !== "mute" && verb !== "unmute") return "";
    if (!entry || typeof entry.unit !== "string") return "";
    return " startup " + verb + " " + shellQuote(entry.unit) + (entry.scope === "user" ? " --user" : "");
}

// startupShortName(entry) -> its name in a sentence, without the word the sentence supplies.
function startupShortName(e) {
    return e.name.replace(/ service$/, "");
}

// startupOf(state) -> what the banner says, and the digest of what recovered: that one is
// acknowledged, so `kempt startup` stops listing it, and the warning having gone is the news.
function startupOf(state) {
    var b = state && state.startup && typeof state.startup === "object" && !isArray(state.startup)
        ? state.startup : null;
    var none = { entries: [], title: "", heading: "", already: "", digest: "" };
    if (b === null || b.notify !== true) return none;
    var afterUpdate = b.attribution === "update";
    var announced = startupEntriesOf(b.announced), i;
    var one = announced.length > 0 ? startupShortName(announced[0]) : "";
    var two = announced.length > 1 ? startupShortName(announced[1]) : "";
    var title = announced.length === 0 ? ""
        : announced.length === 1
            ? (afterUpdate ? i18n("%1 failed to start after the update.", one)
                           : i18n("%1 failed to start after the last restart.", one))
        : announced.length === 2
            ? (afterUpdate ? i18n("%1 and %2 failed to start after the update.", one, two)
                           : i18n("%1 and %2 failed to start after the last restart.", one, two))
        : afterUpdate ? i18n("%1 services failed to start after the update, including %2 and %3.", announced.length, one, two)
                      : i18n("%1 services failed to start after the last restart, including %2 and %3.", announced.length, one, two);
    var entries = [];
    for (i = 0; i < announced.length; i++) {
        var a = announced[i];
        var body = a.scope === "user" ? i18n("Session service: %1.", a.unit) : i18n("System service: %1.", a.unit);
        entries.push({ unit: a.unit, scope: a.scope, name: a.name, command: startupCommandOf(a),
                       text: (announced.length === 1 ? title : a.name) + "\n" + body });
    }
    var already = startupEntriesOf(b.already).map(function (e) { return e.name; });
    var recovered = startupEntriesOf(b.recovered);
    var digest = recovered.length > 0 && typeof b.recovered_digest === "string"
        && STARTUP_DIGEST_RE.test(b.recovered_digest) ? b.recovered_digest : "";
    return {
        entries: entries,
        title: title,
        heading: announced.length > 1 ? title : "",
        already: announced.length > 0 && already.length > 0
            ? (afterUpdate ? i18n("Already failing before the update: %1.", already.join(", "))
                           : i18n("Already failing before the last restart: %1.", already.join(", "))) : "",
        digest: digest
    };
}

// startupMutedOf(stdout of `kempt startup --json`) -> [{unit, scope, name}] for the settings page.
function startupMutedOf(text) {
    var block;
    try { block = JSON.parse(String(text)); } catch (e) { return []; }
    return block && typeof block === "object" ? startupEntriesOf(block.muted) : [];
}

// --- the Startup Report (`kempt startup --all`) --------------------------------------------------
// The page shows the CLI's text as it is. The CLI turns control characters into spaces, and the
// QML shows the text as plain text.
var STARTUP_PAGE_ARGS = " startup --all";
// The CLI keeps every outside call within 8 s; the rest is margin for a busy box.
var STARTUP_PAGE_TIMEOUT_MS = 20000;

// startupPageOutcomeOf(stdout, stderr, rc) -> {ok: true, text} or {ok: false, problem}.
function startupPageOutcomeOf(stdout, stderr, rc) {
    if (isExecutorTimeout(rc, stderr)) return { ok: false, problem: i18n("Kempt did not answer in time. Press Refresh to try again.") };
    if (rc !== 0) {
        var why = firstLineOf(stderr);
        return { ok: false, problem: why !== "" ? i18n("Kempt could not gather the startup list: %1", why)
                                                : i18n("Kempt could not gather the startup list (exit %1).", rc) };
    }
    var text = String(stdout).replace(/\s+$/, "");
    return text !== "" ? { ok: true, text: text } : { ok: false, problem: i18n("Kempt could not read the startup list.") };
}

// --- the reclaim offer ------------------------------------------------------------------------
// Below 1 GB the message is not worth one of the two slots. SI bytes, as formatDownload counts.
var RECLAIM_MIN_BYTES = 1000 * 1000 * 1000;
var RECLAIM_DIGEST_RE = /^[0-9a-f]{16}$/;
// How long Free Up Space waits for `kempt reclaim`. Above the engine's worst case, from
// backends/flatpak.sh and lib/common.sh: KEMPT_RECLAIM_PKCHECK_TIMEOUT (10 s),
// KEMPT_RECLAIM_UNINSTALL_TIMEOUT (600 s, both removal passes together), five listings of
// KEMPT_RECLAIM_LIST_TIMEOUT (15 s: the offer, the removal's own, the re-check, the one between
// the two passes, the after-list), two runs of KEMPT_RECLAIM_DU_TIMEOUT (30 s), then the closing
// check: KEMPT_CHECK_LOCK_WAIT (60 s) and the check itself (CHECK_BODY_MS, 150 s). 955 s in all,
// plus over half a minute of margin.
// Killing the CLI sooner frees the update lock while the uninstall still runs. A test ties the two.
var RECLAIM_TIMEOUT_MS = 990000;

// The size on offer, or null when the CLI could not work it out. A value of the wrong type is
// read as unknown, never coerced.
function reclaimBytesOf(reclaim) {
    var b = reclaim.offerable_bytes;
    return (typeof b === "number" && isFinite(b) && b >= 0) ? b : null;
}

// reclaimOffered(state.reclaim) -> may the popup offer to remove these? Only with a digest: the
// CLI leaves it empty when nothing is unused or part of the list is younger than an hour. A size
// the CLI could not work out is not known to reach the minimum, so it is no offer.
function reclaimOffered(reclaim) {
    if (!reclaim || typeof reclaim !== "object" || isArray(reclaim)) return false;
    if (typeof reclaim.digest !== "string" || !RECLAIM_DIGEST_RE.test(reclaim.digest)) return false;
    var bytes = reclaimBytesOf(reclaim);
    return bytes !== null && bytes >= RECLAIM_MIN_BYTES;
}

// reclaimMessageOf(state.reclaim) -> the offer's one line.
function reclaimMessageOf(reclaim) {
    if (!reclaimOffered(reclaim)) return "";
    return i18n("%1 can be freed. No installed app uses these Flatpak runtimes.", formatDownload(reclaimBytesOf(reclaim)));
}

// reclaimRefLineOf({ref, eol}) -> "org.kde.Platform 5.15-23.08", the id and branch of a
// kind/id/arch/branch ref. Any other shape is shown as the CLI wrote it.
function reclaimRefLineOf(entry) {
    if (!entry || typeof entry !== "object" || typeof entry.ref !== "string") return "";
    var parts = entry.ref.split("/");
    var line = parts.length === 4 ? parts[1] + " " + parts[3] : entry.ref;
    return typeof entry.eol === "string" && entry.eol !== "" ? i18n("%1 (no longer supported)", line) : line;
}

// stagedHeaderOf(offline_staged) -> what the popup header and the panel tooltip say while a
// transaction is armed, or "" when none is. Same input and tolerance as stagedMessageOf, but a
// second function rather than a flag on it: the banner states what the next restart will DO, while
// this replaces a count of what is available.
function stagedHeaderOf(staged) {
    if (!staged || typeof staged !== "object" || isArray(staged)) return "";
    var n = staged.count;
    if (typeof n !== "number" || !isFinite(n) || n < 0) return i18n("Updates ready for the next restart");
    return i18np("1 update ready for the next restart", "%1 updates ready for the next restart", n);
}

// stagedOthersOf(staged, fpPending) -> the sentence for updates the stage leaves out, or "".
// not_staged is the CLI's count, absent when it could not compare; fpPending is the Flatpak count.
function stagedOthersOf(staged, fpPending) {
    var n = 0;
    if (staged && typeof staged.not_staged === "number" && isFinite(staged.not_staged)
        && staged.not_staged > 0) n += Math.floor(staged.not_staged);
    if (typeof fpPending === "number" && isFinite(fpPending) && fpPending > 0) n += Math.floor(fpPending);
    if (n === 0) return "";
    return i18np("1 other update waits until after that.", "%1 other updates wait until after that.", n);
}

// stagedVariantOf(staged, heldDnf[, fpPending]) -> which of the three banners this stage gets, and its words:
//   { type: "positive" | "warning", message, stagedAt: "" }
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
// means: "transaction" means it was read and there is nothing in it, "none" means it could not be
// read at all. Two states, two sentences.
//
// heldDnf is the one fact this file supplies itself: whether the box holds any dnf package at all.
// It gates the generic warning only - with nothing held there is nothing to be vague ABOUT. dnf
// only, because the offline surface stages dnf and only dnf.
//
// TOLERANCE: a key of the wrong type is IGNORED, never duck-typed - a string has a length and
// indexes into its own characters, so a duck-typed check would warn about a package called "k".
// Everything malformed falls back to the plain banner and nothing throws. The ONE asymmetry is
// deliberate: a well-formed list of names warns whether or not names_source is readable, because
// names may CONFIRM a conflict and may never DENY one.
function stagedVariantOf(staged, heldDnf, fpPending) {
    var plain = { type: "positive", message: stagedMessageOf(staged), stagedAt: "" };
    if (plain.message === "") return plain;
    var others = stagedOthersOf(staged, fpPending);
    if (others !== "") plain.message += " " + others;
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

    if (names.length > 0) {
        return { type: "warning",
                 message: names.length === 1
                     ? i18n("You held %1 after these updates were prepared, so it still installs. Discard them and install again to skip it.", names[0])
                     : i18np("You held %2 and 1 more after these updates were prepared, so they still install. Discard them and install again to skip them.",
                             "You held %2 and %1 more after these updates were prepared, so they still install. Discard them and install again to skip them.",
                             names.length - 1, names[0]),
                 stagedAt: plain.stagedAt };
    }
    if (staged.names_source === "none" && heldDnf) {
        return { type: "warning", message: i18n("You added holds after these updates were prepared, so held packages may still install. Discard them and install again to apply your holds."), stagedAt: plain.stagedAt };
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
    if (typeof iso !== "string") return i18n("never");
    var s = iso.split("\n")[0].trim();
    if (s === "") return i18n("never");
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
    // TRANSLATORS: A time that goes after "Last update", "Checked" and similar as %1.
    if (age < 60000) return i18n("just now");
    var n = Math.floor(age / 60000);
    // TRANSLATORS: A time that goes after "Last update", "Checked" and similar as %1.
    if (n < 60) return i18np("1 min ago", "%1 min ago", n);
    n = Math.floor(age / 3600000);
    // TRANSLATORS: A time that goes after "Last update", "Checked" and similar as %1.
    if (n < 24) return i18np("1 hour ago", "%1 hours ago", n);
    n = Math.floor(age / 86400000);
    // A week is the last age at which counting days answers "when?" better than the date does.
    // Past it, "23 days ago" makes a person do the arithmetic the stamp would have saved.
    // TRANSLATORS: A time that goes after "Last update", "Checked" and similar as %1.
    if (n <= 7) return i18np("1 day ago", "%1 days ago", n);
    return formatStamp(iso);
}

// How old the package metadata behind the counts is, in words, or "" when it is not worth saying.
// A check answers from a cache that is refreshed at most once every three hours and not at all on
// battery or a metered link, so "Checked 4 min ago" can sit above counts derived from week-old
// metadata - and nothing else on the popup would give that away.
// 24 hours is the floor because under it there is nothing to report: that is the ordinary state of
// a plugged-in machine, and a line on every popup would be noise that teaches people to skip the
// footer. The clock is an ARGUMENT, like relativeTime's, so a test can assert each boundary.
// `floorMs` lowers that floor. The footer passes 60000 after a Check for Updates whose refresh did
// not land (battery, metered, offline), so the person can tell the list may be old.
var METADATA_STALE_MS = 86400000;
function metadataAgeText(iso, nowMs, floorMs) {
    if (typeof nowMs !== "number" || !isFinite(nowMs)) return "";
    var at = stampMs(iso);
    // Unreadable or absent says nothing at all, the same silence relativeTime falls back to: an
    // age nobody could work out is not an age to put a number on.
    if (!isFinite(at)) return "";
    var age = nowMs - at;
    var floor = (typeof floorMs === "number" && isFinite(floorMs) && floorMs >= 60000)
        ? floorMs : METADATA_STALE_MS;
    if (age < floor) return "";
    if (age >= METADATA_STALE_MS) {
        var days = Math.floor(age / METADATA_STALE_MS);
        // TRANSLATORS: Shown after a dot in the footer, and also as its own sentence with its first letter capitalized by the widget.
        return i18np("update info 1 day old", "update info %1 days old", days);
    }
    var hours = Math.floor(age / 3600000);
    // TRANSLATORS: Shown after a dot in the footer, and also as its own sentence with its first letter capitalized by the widget.
    if (hours >= 1) return i18np("update info 1 hour old", "update info %1 hours old", hours);
    // TRANSLATORS: Shown after a dot in the footer, and also as its own sentence with its first letter capitalized by the widget.
    return i18np("update info 1 min old", "update info %1 min old", Math.floor(age / 60000));
}

// refreshMissed(state, askedMs) -> whether the check a Check for Updates press started at `askedMs`
// answered without fresh metadata: the refresh was skipped (battery, metered) or failed (offline).
// metadata_refreshed has whole seconds, so `askedMs` is floored to its second. With no stamp (the
// lists here were fetched by dnf or Discover, never by Kempt) only a refresh_error the check left
// behind says the fetch failed; otherwise no stamp, no claim.
function refreshMissed(state, askedMs) {
    var asked = Number(askedMs);
    if (!state || typeof state !== "object" || !isFinite(asked) || asked <= 0) return false;
    var at = stampMs(state.metadata_refreshed);
    // ...unless refreshing is turned off: that error is from a download Kempt no longer tries.
    if (!isFinite(at)) return refreshErrorOf(state) !== "" && state.refresh_skipped !== "off";
    return at < Math.floor(asked / 1000) * 1000;
}

// refreshErrorOf(state) -> the first line of the dnf refresh error the check published, or "".
function refreshErrorOf(state) {
    return state && typeof state === "object" && state.backends && typeof state.backends === "object"
        && state.backends.dnf && typeof state.backends.dnf.refresh_error === "string"
        ? firstLineOf(state.backends.dnf.refresh_error) : "";
}

// fetchMissedOf(state, askedMs, pressStamp) -> the notice for a Check for Updates press whose fetch
// did not land, or "". Only while the state on screen is the one that press's own check answered
// with: `pressStamp` is that answer's last_check (main.qml records it), so the next check, whoever
// starts it, takes the notice away. A state served while another check held the lock (last_check
// before the press) tried nothing. A stale check has its own report.
// The lead comes from what the check published. A press passes the 3-hour gate, so with no
// refresh_skipped the fetch ran, and a missed one left refresh_error behind. An engine older than
// both fields, or one with refreshing turned off, gets the lead that says only what is known.
// The age is measured at the check, not now, so the sentence does not change while it is on
// screen and a screen reader hears it once.
function fetchMissedOf(state, askedMs, pressStamp) {
    if (!refreshMissed(state, askedMs) || state.status === "stale") return "";
    if (typeof pressStamp !== "string" || pressStamp === "" || state.last_check !== pressStamp) {
        return "";
    }
    var asked = Math.floor(Number(askedMs) / 1000) * 1000;
    var checked = stampMs(state.last_check);
    if (!isFinite(checked) || checked < asked) return "";
    var stamped = isFinite(stampMs(state.metadata_refreshed));
    if (stamped && stampMs(state.metadata_refreshed) > checked) return "";
    var err = refreshErrorOf(state);
    if (state.refresh_skipped === "battery") return i18n("Kempt skips the online check on battery, so this may be out of date.");
    if (state.refresh_skipped === "metered") return i18n("Kempt skips the online check on a metered connection, so this may be out of date.");
    var named = err === "" || typeof state.refresh_skipped === "string";
    if (!named && REFRESH_NETWORK_RE.test(err)) return i18n("Kempt could not reach the update servers, so this may be out of date.");
    // No stamp means nobody knows how old the lists are. Measured at the check, so the sentence does
    // not change while the widget is open.
    if (!stamped) return named ? i18n("Kempt did not download fresh update info, so this may be out of date.") : i18n("The check failed, so this may be out of date.");
    var when = relativeTime(state.metadata_refreshed, checked);
    if (when === i18n("just now")) return named ? i18n("Kempt did not download fresh update info, so this may be out of date.") : i18n("The check failed, so this may be out of date.");
    return named ? i18n("Kempt did not download fresh update info, so this is from %1.", when)
                 : i18n("The check failed, so this is from %1.", when);
}

// servedBeforePress(state, askedMs) -> whether a check started at `askedMs` answered with a state
// some earlier check wrote: last_check before the press, which is what the CLI prints when another
// check held the lock past its wait. Both are floored to whole seconds, as last_check is. No
// stamp, no claim.
function servedBeforePress(state, askedMs) {
    var asked = Number(askedMs);
    if (!state || typeof state !== "object" || !isFinite(asked) || asked <= 0) return false;
    var checked = stampMs(state.last_check);
    return isFinite(checked) && checked < Math.floor(asked / 1000) * 1000;
}

// anywayReasonOf(refreshSkipped) -> "battery" or "metered" when Check Anyway can pass the rule
// that skipped the fetch, else "". Fetching turned off ("off") is a setting no press overrides.
function anywayReasonOf(refreshSkipped) {
    return refreshSkipped === "battery" || refreshSkipped === "metered" ? refreshSkipped : "";
}

// --- the check command ------------------------------------------------------------------------
// checkArgs(automatic, refresh, anyway) -> what doCheck appends to `kempt`. Check for Updates fetches
// fresh metadata (`--refresh`). Check Anyway also passes the battery and metering rules, and
// only for a press: never for a check nobody asked for. The checks nobody asked for coalesce and
// keep the CLI's 3-hour interval. Any other press (a hold, Check again) runs a check of its own
// from the cache.
function checkArgs(automatic, refresh, anyway) {
    if (anyway === true && refresh === true && automatic !== true) return " check --anyway";
    if (refresh === true) return " check --refresh";
    return automatic === true ? " check --coalesce" : " check";
}

// How long the widget waits for any `kempt check` before giving up on it. A ceiling for EVERY check,
// because an automatic one fetches too once the 3-hour interval is up, and a kill mid-fetch leaves
// a root dnf5 running unwatched. A check with no fetch ends in seconds anyway.
// CHECK_BODY_MS is the check without its fetch: 120 s for its own queries, and 30 s for the rest
// (lib/common.sh: the 15 s advisory query, two 5 s waits for the writers' lock and a 5 s
// notification). The fetch adds Flatpak's KEMPT_REFRESH_TIMEOUT (120 s) once per
// installation, system and per-user, and dnf's makecache. That one runs as root, where the CLI's
// timeout cannot reach it, so libexec/kempt-refresh bounds it as root with the same 120 s, plus a
// 10 s grace before SIGKILL. Plus 30 s, which covers that grace:
// 150 + 240 + 120 + 30 = 540 s.
var CHECK_BODY_MS = 150000;
var CHECK_TIMEOUT_MS = 540000;

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

// securityOf(state) -> the CLI's `security` block as the widget uses it, or an empty one. The block
// is optional (an older CLI, a check whose advisory query failed), and every field is checked
// before it is believed.
function securityOf(state) {
    var s = state && state.security && typeof state.security === "object" ? state.security : null;
    var none = { count: 0, names: {} };
    if (s === null || typeof s.count !== "number" || !(s.count >= 1)) return none;
    var names = {}, packages = arrayOf(s.packages), i;
    for (i = 0; i < packages.length; i++) names[String(packages[i])] = true;
    return { count: Math.floor(s.count), names: names };
}

// Walk the backends once, producing the popup's pending sections and the flat Held list.
// A backend with enabled:false contributes NOTHING - no section, no held rows, no counts - so
// "include_flatpak=false" renders as an absent Apps section rather than an empty one.
function collectItems(state) {
    var sections = [], heldItems = [], actionable = 0, heldTotal = 0;
    var securityNames = securityOf(state).names;
    var backends = (state && state.backends && typeof state.backends === "object") ? state.backends : {};
    var keys = backendKeys(backends), i, j;
    for (i = 0; i < keys.length; i++) {
        var key = keys[i];
        var backend = backends[key];
        if (!backend || typeof backend !== "object") continue;
        if (backend.enabled === false) continue;
        var items = (backend.items && typeof backend.items.length === "number") ? backend.items : [];
        // The backend's own group, then one group per `kind` its items carry, in the order the
        // kinds are first seen - so the CLI decides the order here too, exactly as it does for rows.
        var pending = [], byKind = {}, kindOrder = [], k;
        // Which ids are installed both ways. A hold is by id, so it covers both copies, and the
        // padlock on either row says so.
        var scopesOf = {};
        for (j = 0; j < items.length; j++) {
            var it = items[j] || {};
            if (it.name === undefined || it.name === null) continue;
            var sk = String(it.name);
            if (!scopesOf[sk]) scopesOf[sk] = {};
            scopesOf[sk][it.scope === "user" ? "user" : "system"] = true;
        }
        for (j = 0; j < items.length; j++) {
            var item = items[j] || {};
            var itemKind = (item.kind === undefined || item.kind === null) ? "" : String(item.kind);
            var row = {
                name: item.name === undefined || item.name === null ? "" : String(item.name),
                from: newestOf(item.from),
                to: newestOf(item.to),
                held: !!item.held,
                backend: key,  // half of the `kempt hold <backend>:<name>` argument
                // A runtime's identity is its id AND its branch: the same runtime is routinely
                // installed on two branches, and two rows reading the same name with no branch
                // between them are two rows a person cannot tell apart. "" for everything else.
                branch: (item.branch === undefined || item.branch === null) ? "" : String(item.branch),
                // Whether this row gets a padlock. Runtimes do not: `kempt hold` refuses them,
                // because apps share a runtime and holding one breaks the next app that needs it.
                // A padlock that reports a refusal every time is worse than no padlock.
                holdable: itemKind !== "runtime",
                // Installed with `flatpak install --user`, so it is this person's alone. The row
                // says so, which also tells apart one id installed both ways.
                forYouOnly: item.scope === "user",
                // A system package the CLI's security block names. dnf rows only: Flatpak apps
                // publish no security notices, and a name shared with an app must not borrow it.
                security: key === "dnf" && item.name !== undefined && item.name !== null
                          && securityNames[String(item.name)] === true,
                bothScopes: !!(item.name !== undefined && item.name !== null
                               && scopesOf[String(item.name)].user && scopesOf[String(item.name)].system)
            };
            if (row.held) { heldItems.push(row); heldTotal++; }
            else {
                if (itemKind === "") pending.push(row);
                else {
                    if (!byKind[itemKind]) { byKind[itemKind] = []; kindOrder.push(itemKind); }
                    byKind[itemKind].push(row);
                }
                actionable++;
            }
        }
        if (pending.length > 0) {
            sections.push({ title: sectionTitleOf(key), backend: key, items: pending });
        }
        // A kind this build has never heard of still gets a section, under a title built from its
        // own two words - the same rule backendKeys follows for an unknown backend. Dropping it
        // would hide pending updates the badge has already counted.
        for (k = 0; k < kindOrder.length; k++) {
            var kd = kindOrder[k];
            sections.push({ title: kindTitleOf(key, kd),
                            backend: key, kind: kd, items: byKind[kd] });
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
        rows.push({ kind: "header", title: i18n("Held"), held: true });
        for (i = 0; i < heldItems.length; i++) rows.push(rowOf(heldItems[i], "item"));
    }
    return rows;
}

// `kind` here is the ROW kind - "item" or "header" - and has nothing to do with an item's flatpak
// kind, which never reaches a row: the section above it already carries that, and the two facts a
// row itself needs are its branch and whether it can be held.
function rowOf(item, kind) {
    return { kind: kind, title: "", name: item.name, from: item.from, to: item.to,
             held: item.held, backend: item.backend,
             branch: item.branch || "",
             // Absent means holdable, so a row built by an older caller keeps its padlock.
             holdable: item.holdable !== false,
             forYouOnly: item.forYouOnly === true,
             security: item.security === true,
             bothScopes: item.bothScopes === true };
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
        rebootNeeded: entry.reboot_needed === true,
        // Why a staging run staged nothing, or null when it staged something - AND null for an
        // entry written before the CLI recorded this, which is the same answer for a different
        // reason and deliberately so: those two cannot be told apart, and guessing would report a
        // real stage as nothing. Only the two words the CLI writes are accepted; anything else is
        // a build this one does not understand, and "I do not know" is the honest reading of it.
        stagedNothing: (entry.staged_nothing === "held" || entry.staged_nothing === "nothing_pending")
            ? entry.staged_nothing : null,
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
        if (/(other users|users other than root) can change/.test(why)) return i18n("A system folder has unsafe permissions, so Kempt has paused updates. Check Installation shows how to fix it.");
        if (why === "") return i18n("The update failed.");
        return /[.!?:]$/.test(why) ? i18n("The update failed: %1", why) : i18n("The update failed: %1.", why);
    }
    // The staging run's entry has empty package lists BY CONSTRUCTION - nothing changes until the
    // restart - so the count sentences below would call it "No package changes": true about the
    // rpm set and no answer to what the person just did. Exact match, never a prefix: the harvest
    // writes "offline (applied on reboot)" and its counts are real changes.
    // ...unless the run staged nothing, which is a successful `offline` run too and was described
    // in the same words as one that staged sixty packages.
    if (run.surface === "offline" && run.stagedNothing !== null) {
        return run.stagedNothing === "held" ? i18n("Every waiting update is held, so the next restart has nothing to install.") : i18n("No updates are waiting, so the next restart has nothing to install.");
    }
    if (run.surface === "offline") return i18n("Updates are ready and install on the next restart.");
    var n = typeof run.changedCount === "number" ? run.changedCount : 0;
    if (n === 0) return i18n("No packages changed.");
    // The duration is a CLAUSE, not a field with a default: a run whose entry does not say how
    // long it took is described without it rather than described as instantaneous. A negative
    // duration is the clock stepping backwards during the run, not a measurement, so it is left
    // out the same way.
    var secs = run.durationSec;
    return typeof secs === "number" && isFinite(secs) && secs >= 0
        ? i18np("Updated 1 package in %2 s.", "Updated %1 packages in %2 s.", n, secs)
        : i18np("Updated 1 package.", "Updated %1 packages.", n);
}

// reportRepeatsStaged(run) -> does the post-run line only say what the staged message says?
// A clean staging run reports "Updates are staged", and the staged message above it says the same
// with the count and its Restart and Discard buttons. Two boxes for one fact, so the report gives
// way while that message is on screen, and the Last update row (with Show Log) takes its place.
// Anything the line adds keeps it: a run that staged nothing, a failure.
function reportRepeatsStaged(run) {
    // A stamp the row cannot render would leave the Last update row with no title in its place.
    return !!run && !run.failed && run.surface === "offline" && run.stagedNothing === null
        && isRenderableStamp(run.when);
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

// runStartMessage(rc, stdout, stderr) -> "" when `kempt run` started a run, otherwise what to tell
// the person. Only exit 0 means a run began, so only exit 0 may enter the updating pane: any other
// status is a run that will never write state.json, and the pane would wait three hours for it.
// The CLI's own first line wherever there is one: exit 3 names the update already holding the lock.
function runStartMessage(rc, stdout, stderr) {
    if (rc === 0) return "";
    var msg = firstLineOf(stderr) || firstLineOf(stdout);
    if (msg !== "") return msg;
    if (rc === 3) return i18n("An update is already running.");
    return i18n("Could not start the update (exit %1).", String(rc));
}

// discardStagedMessage(rc, stdout, stderr) -> the one sentence the popup reports after
// `kempt unstage`. NEVER "", which is where it differs from runStartMessage: that one enters the
// updating pane on success and the pane is the report, while this press only makes a banner
// disappear, and a message that merely vanished says nothing to somebody who was not looking at it
// and nothing at all to a screen reader.
//
// The CLI's own first line wherever there is one, exactly as runStartMessage does it: exit 5 names
// the Fedora release upgrade the refusal protected, exit 3 the update holding the lock, exit 1
// what could not be discarded. Success reads stdout for the same reason and a stronger one - the
// CLI says two different true things there ("Discarded the staged update", and nothing was staged
// to discard) and the exit code cannot tell them apart, so the words come from the run rather than
// from a guess here.
function discardStagedMessage(rc, stdout, stderr) {
    if (rc === 0) return firstLineOf(stdout) || i18n("These updates are gone. The next restart installs nothing.");
    var msg = firstLineOf(stderr) || firstLineOf(stdout);
    if (msg !== "") return msg;
    // Nothing was read and nothing was changed, which is what makes exit 5 a refusal rather than a
    // failed run - the CLI's own distinction, and the reason these are two sentences.
    if (rc === 5) return i18n("Nothing was discarded. Press Check Installation to find out why.");
    if (rc === 3) return i18n("An update is running, so nothing was discarded. Try again when it has finished.");
    return i18n("These updates could not be discarded (exit %1). Press Check Installation to find out why.", String(rc));
}

// --- answering an offer, or changing a setting through a CLI verb ----------------------------------
// How long the widget waits for `kempt config set` or `kempt discover-notifier`. Each takes the
// CLI's writers' lock, which waits up to 30 s for another writer before it gives up, so anything
// shorter would report a write as lost while the CLI was still about to make it.
var ANSWER_TIMEOUT_MS = 40000;

// answerOutcomeOf(rc, stdout, stderr, fallback, timedOut) -> {ok, text}: what the popup or the
// settings page says after such a verb. Success is the CLI's first line, or `fallback` when it
// printed nothing. Failure is its own reason, except the Executor's kill, which gets a sentence:
// `timedOut` when given (a setting, a hold), the general sentence otherwise.
function answerOutcomeOf(rc, stdout, stderr, fallback, timedOut) {
    if (rc === 0) {
        return { ok: true, text: firstLineOf(stdout) || (typeof fallback === "string" ? fallback : "") };
    }
    if (isExecutorTimeout(rc, stderr)) {
        return { ok: false, text: typeof timedOut === "string" && timedOut !== "" ? timedOut
                                                                                 : i18n("Kempt did not answer in time, so your answer may not be saved. Try again.") };
    }
    return { ok: false, text: firstLineOf(stderr) || firstLineOf(stdout) };
}

// --- Check Installation (`kempt doctor`) --------------------------------------------------------
// How long the widget waits for doctor. It reads files and takes well under a second; its slowest
// row is the unused-runtime listing, capped at KEMPT_RECLAIM_LIST_TIMEOUT (15 s).
var DOCTOR_TIMEOUT_MS = 60000;

// mentionsDoctor(text) -> does this message tell the person to run `kempt doctor`? The CLI's own
// refusals end "See: kempt doctor", and these sentences of the widget's name the button. A translator
// may inflect the button's name inside a sentence, so the test reads whole sentences, never the name.
// Digits become %1 because the one number in them is an exit code.
function mentionsDoctor(text) {
    if (typeof text !== "string") return false;
    if (/\bkempt doctor\b/.test(text)) return true;
    var shape = text.replace(/\d+/g, "%1");
    var naming = [
        i18n("A system folder has unsafe permissions, so Kempt has paused updates. Check Installation shows how to fix it."),
        i18n("Kempt cannot tell what the next restart will do. Check Installation shows why."),
        i18n("Nothing was discarded. Press Check Installation to find out why."),
        i18n("These updates could not be discarded (exit %1). Press Check Installation to find out why.", "%1")
    ];
    for (var i = 0; i < naming.length; i++) {
        if (shape.indexOf(naming[i]) >= 0) return true;
    }
    return false;
}

// The CLI's pointer at the command, for a message drawn beside Check Installation, which is that
// command. mentionsDoctor keeps reading the raw string, which is how the button gets there.
function withoutDoctorPointer(text) {
    return typeof text === "string" ? text.replace(/\s*See: kempt doctor\.?\s*$/, "") : "";
}

// The longest result sentence. Longer ones end at a word, with the full report one press away.
var DOCTOR_SUMMARY_MAX = 150;

function capAtWord(text, max) {
    if (text.length <= max) return text;
    var cut = text.slice(0, max - 1);
    var space = cut.lastIndexOf(" ");
    if (space > max / 2) cut = cut.slice(0, space);
    return cut.replace(/[\s,;:.]+$/, "") + "…";
}

// doctorOutcomeOf(rc, stdout, stderr) -> {failed, summary, report}: what the popup says after
// Check Installation. Doctor prints one row per check, "FAIL  <text>" for each problem, and exits
// 1 when there is one. The summary quotes the first problem; the report is everything it printed.
// A doctor that printed no rows did not run, and stderr says why: on a box whose engine will not
// start, that is the shell's own reason.
// A stored Fedora release upgrade is not a problem with Kempt, but the blocked message sends the
// person here to learn how to finish or remove it. So its row, which holds the commands, replaces
// "no problems", and neither that row nor doctor's FAIL row about it is cut short.
function doctorOutcomeOf(rc, stdout, stderr) {
    var said = doctorVerdictOf(rc, stdout, stderr);
    if (!said.failed) {
        var row = /^info\s+(a Fedora release upgrade .*\S)\s*$/m.exec(typeof stdout === "string" ? stdout : "");
        if (row) said.summary = row[1].charAt(0).toUpperCase() + row[1].slice(1) + ".";
    }
    if (said.summary.indexOf("Fedora release upgrade") < 0) said.summary = capAtWord(said.summary, DOCTOR_SUMMARY_MAX);
    return said;
}

function doctorVerdictOf(rc, stdout, stderr) {
    var out = typeof stdout === "string" ? stdout : "";
    var err = typeof stderr === "string" ? stderr : "";
    var report = [out.replace(/\s+$/, ""), err.replace(/\s+$/, "")]
        .filter(function (t) { return t !== ""; }).join("\n");
    var fails = [];
    out.split("\n").forEach(function (line) {
        var m = /^FAIL\s+(.*\S)\s*$/.exec(line);
        if (m) fails.push(m[1]);
    });
    if (fails.length > 0) {
        return { failed: true, report: report,
                 summary: i18np("Kempt found a problem with its installation: %2",
                                "Kempt found %1 problems with its installation. The first: %2", fails.length, fails[0]) };
    }
    // Exit 0 with no FAIL row is a clean report, printed or not: doctor exits 1 on any problem.
    if (rc === 0) return { failed: false, summary: i18n("Kempt checked its installation and found no problems."), report: report };
    // The Executor's own kill: it answers 124 and names its timeout on stderr.
    if (rc === 124) return { failed: true, summary: i18n("Kempt stopped waiting for the installation check. Try again in a minute."), report: report };
    // Only stderr explains a failure. Stdout holds doctor's info rows, which do not. The
    // report carries stderr, so the sentence only says where to read it.
    var why = firstLineOf(err);
    return { failed: true, report: report,
             summary: why !== "" ? i18n("Kempt could not check its installation. The full report has the error.")
                                 : i18n("Kempt could not check its installation (exit %1).", String(rc)) };
}

// reclaimSaid(rc, stdout, stderr) -> {ok, text}: what the popup reports after Free Up Space, in the
// CLI's words. With -y stdout starts with the list of runtimes, so on success its LAST line is the
// outcome, followed by what stderr added. On failure stderr's first line is the outcome.
function reclaimSaid(rc, stdout, stderr) {
    if (isExecutorTimeout(rc, stderr)) return { ok: false, text: i18n("Kempt stopped waiting. The removal may still finish. Press Check for Updates in a few minutes.") };
    var msg = firstLineOf(stderr);
    if (rc !== 0) return { ok: false, text: msg !== "" ? msg : i18n("Could not free the space (exit %1).", String(rc)) };
    var lines = String(stdout === undefined || stdout === null ? "" : stdout).split("\n");
    var tail = "";
    for (var i = lines.length - 1; i >= 0 && tail === ""; i--) tail = lines[i].trim();
    return { ok: true, text: ((tail !== "" ? tail : i18n("Nothing to remove. Every installed Flatpak runtime is in use.")) + " " + msg).trim() };
}

// lastRunText(run, nowMs, restartHeld, armed) -> the persistent Last update row's title. "no package changes" is the
// CLI's own wording, emitted verbatim by KEMPT_JQ_COUNTS in lib/common.sh, and this line quotes the
// terminal (lowercase because it sits mid sentence after the dot). Do NOT reword it here alone -
// the tests tie all three spellings together.
function lastRunText(run, nowMs, restartHeld, armed) {
    if (!run) return "";
    // An entry we cannot DATE gets no row. relativeTime answers "never" for a missing stamp, so
    // the sentence would describe a run in the same breath as denying there was one; an unreadable
    // stamp pastes "not a date" into an English sentence. WHEN it happened is the one thing this
    // line exists to say. A test of the STAMP, not of relativeTime's output: with an unusable
    // clock relativeTime falls back to the absolute stamp, which is a perfectly good row.
    if (!isRenderableStamp(run.when)) return "";
    // The staging run, between the stage and the restart: its zero counts are true and misleading,
    // same reasoning as postRunLine. `failed` is checked because a staging run that FAILED staged
    // nothing. Exact match on "offline": the
    // harvest's surface is "offline (applied on reboot)" and its counts render.
    if (!run.failed && run.surface === "offline") {
        // The same exception postRunLine makes, for the same reason: a run that staged nothing is
        // `offline` and `ok`, and "ready for the next restart" over it promises an install that no restart
        // performs. WHICH reason is left to the post-run line - this row is one line among several
        // and the distinction needs a clause it has no room for.
        if (run.stagedNothing !== null) {
            return i18n("Last update %1 · the next restart has nothing to install", relativeTime(run.when, nowMs));
        }
        // ...and over a stage the next restart will not install, the same promise for a like reason.
        if (restartHeld === true) {
            return i18n("Last update %1 · another updater has prepared the next restart", relativeTime(run.when, nowMs));
        }
        // The promise is the machine's to make, not the run's: after a lost link, an unstage or a
        // restart that installed nothing this run is still the newest, and nothing is coming.
        if (armed === true) {
            return i18n("Last update %1 · ready for the next restart", relativeTime(run.when, nowMs));
        }
    }
    var n = typeof run.changedCount === "number" ? run.changedCount : 0;
    var when = relativeTime(run.when, nowMs);
    // Failed goes in the words of the title, because the transient line that said so clears when
    // the popup closes and this row is what is left.
    if (n === 0) return run.failed ? i18n("Last update failed %1 · no package changes", when)
                                   : i18n("Last update %1 · no package changes", when);
    return run.failed ? i18np("Last update failed %2 · 1 package", "Last update failed %2 · %1 packages", n, when)
                      : i18np("Last update %2 · 1 package", "Last update %2 · %1 packages", n, when);
}

// lastRunSubtitle(run) -> the Last update row's second line, or "": why a failed run failed, as
// postRunLine says it.
function lastRunSubtitle(run) {
    return run && run.failed ? postRunLine(run) : "";
}

// isExecutorTimeout(rc, stderr) -> did Executor.qml's kill timer end this call? It reports that as
// rc 124 with "timeout after Nms", words meant for a log, never for a person.
function isExecutorTimeout(rc, stderr) {
    return rc === 124 && firstLineOf(stderr).indexOf("timeout after ") === 0;
}

// checkErrorOf(rc, stderr) -> the widget's own report of a check that answered nothing, with no
// state to fall back on (main.qml's cliError). The CLI's first stderr line, except for the
// Executor's kill, which gets a sentence.
function checkErrorOf(rc, stderr) {
    if (isExecutorTimeout(rc, stderr)) return i18n("The check did not finish in time.");
    return firstLineOf(stderr);
}

// The words of a check that could not reach a server. Bare "timed out" is left out: a lock or a
// polkit prompt can time out too. The dnf check is cache-only, so these come from flatpak; dnf
// says only that it has no cache, and NO_CACHE_RE below handles that. librepo's "Curl error",
// "Cannot download" and "All mirrors were tried" are not here: flatpak never prints them.
var NETWORK_ERROR_RE = new RegExp([
    "could(n't| not) resolve", "temporary failure in name resolution",
    "name or service not known", "error resolving", "failed to download",
    "could(n't| not) connect", "connection (refused|reset|timed out)",
    "operation timed out", "timeout was reached", "network is unreachable", "no route to host",
    "while fetching"
].join("|"), "i");

// The same for dnf's own refresh error (backends.dnf.refresh_error), and stricter: a repository
// that answers 404 also gives "Curl error" and "Cannot download", and that server was reached.
var REFRESH_NETWORK_RE = new RegExp([
    "could(n't| not) resolve", "temporary failure in name resolution", "name or service not known",
    "could(n't| not) connect", "failed to connect", "connection (refused|reset|timed out)",
    "operation timed out", "timeout was reached", "network is unreachable", "no route to host"
].join("|"), "i");

// dnf5 --cacheonly with no metadata: 'Cache-only enabled but no cache for repository "fedora"'.
var NO_CACHE_RE = /no cache for repository/i;

// checkProblemOf(text, dnfRefreshError, refreshSkipped) -> {network, noCache, headline, detail, hint} for a check
// that answered nothing and left no counts. The headline is plain words, and the hint the line
// under it. The tool's first line is kept as the detail, for the small print. The widget's own
// timeout sentence is already plain, so it has no detail.
// The CLI joins the dnf and flatpak failures with "; ". It is a network failure only when every
// part is one. dnf's "no cache" counts as one only when dnf's own refresh error (a string while
// the latest refresh failed) is a network error and this check did not skip the fetch on battery
// or a metered link. A text that names kempt doctor never is.
function checkProblemOf(text, dnfRefreshError, refreshSkipped) {
    var raw = firstLineOf(typeof text === "string" ? text : "");
    var none = { network: false, noCache: false, headline: "", detail: "", hint: "" };
    if (raw === "") return none;
    if (raw === i18n("The check did not finish in time.")) {
        return { network: false, noCache: false, headline: raw, detail: "", hint: i18n("Check Installation can find out why.") };
    }
    var failed = { network: false, noCache: false, headline: i18n("The check failed"), detail: raw,
                   hint: i18n("Check Installation can find out why.") };
    if (mentionsDoctor(raw)) return failed;
    var refreshError = typeof dnfRefreshError === "string" ? firstLineOf(dnfRefreshError) : null;
    // A fetch this check skipped on battery or a metered link was never tried, so an older
    // network error on record does not explain the missing lists.
    var skippedByRule = refreshSkipped === "battery" || refreshSkipped === "metered";
    var refreshNetwork = refreshError !== null && !skippedByRule
        && REFRESH_NETWORK_RE.test(refreshError);
    var parts = raw.split(/; (?=(?:dnf|flatpak) check failed\b)/);
    var network = 0, noCache = 0;
    for (var i = 0; i < parts.length; i++) {
        var dnfNoCache = /^dnf check failed\b/.test(parts[i]) && NO_CACHE_RE.test(parts[i]);
        if (dnfNoCache ? refreshNetwork : NETWORK_ERROR_RE.test(parts[i])) network++;
        else if (dnfNoCache) noCache++;
    }
    if (network === parts.length) {
        return { network: true, noCache: false, headline: i18n("Kempt could not reach the update servers"), detail: raw,
                 hint: i18n("Check your network connection.") };
    }
    if (noCache === parts.length) {
        // This check's own skip comes first: a refresh error on record can be older than it, and
        // the power and metered hints are the ones Check Anyway sits under. That error is still
        // the detail. Otherwise a refresh that failed says why in its own words, and with none on
        // record it was skipped or turned off.
        var hasRefreshError = refreshError !== null && refreshError !== "";
        if (skippedByRule) {
            return { network: false, noCache: true, headline: i18n("The package lists have not been downloaded yet"),
                     detail: hasRefreshError ? refreshError : raw,
                     hint: refreshSkipped === "battery" ? i18n("Plug in, then press Check for Updates.")
                         : i18n("Switch to an unmetered connection, then press Check for Updates.") };
        }
        return hasRefreshError
            ? { network: false, noCache: true, headline: i18n("The package lists have not been downloaded yet"),
                detail: refreshError, hint: i18n("The download failed. The error is below.") }
            : { network: false, noCache: true, headline: i18n("The package lists have not been downloaded yet"), detail: raw,
                hint: refreshSkipped === "off" ? i18n("Fetching package lists is turned off.") : i18n("Press Check for Updates to download them.") };
    }
    return failed;
}

// checkFailedOverOf(rc) -> the report for a Check for Updates that answered nothing while a state
// is still held. The counts on screen do not change, so without this the press looked ignored.
function checkFailedOverOf(rc) {
    return rc === 124 ? i18n("The check did not finish. The counts shown are from the last check.") : i18n("The check failed. The counts shown are from the last check.");
}

// staleAnswerOf(state, nowMs) -> what Check for Updates says out loud for a check that reported a
// failure. Which half failed comes from the CLI's own `error` ("dnf check failed: ...; flatpak
// check failed: ..."), by its fixed prefixes only: what follows them is a tool's stderr, which is
// not something to read to a person. Then how old the counts are, from last_success.
function staleAnswerOf(state, nowMs) {
    var said = staleSaidOf(state);
    var ls = typeof state.last_success === "string" ? state.last_success.trim() : "";
    if (ls === "") return said + " " + i18n("No successful check yet.");
    if (!isRenderableStamp(ls)) return said;
    var when = relativeTime(ls, nowMs);
    if (when === i18n("just now")) when = i18n("a moment ago");
    return said + " " + i18n("The counts are from %1.", when);
}

// staleSaidOf(state) -> which half of a failed check failed, in the words the popup's lists use.
function staleSaidOf(state) {
    var parts = (typeof state.error === "string" ? state.error : "").split("; ");
    var system = false, apps = false;
    for (var i = 0; i < parts.length; i++) {
        var m = /^(dnf|flatpak) check failed/.exec(parts[i]);
        if (m === null) continue;
        if (m[1] === "flatpak") apps = true; else system = true;
    }
    return system && apps ? i18n("The check failed for System and Apps.")
        : system ? i18n("The check failed for System.")
        : apps ? i18n("The check failed for Apps.") : i18n("The check failed.");
}

// viewModel(state, updating, cliError, opts) -> everything the QML layer binds to. Called on every
// state change; the QML side holds no derived state of its own.
//
// `opts` and every field in it are optional, so the three-argument call keeps working. It carries
// the facts that are not in the state file:
//   nowMs            - the clock. Absent means every relative time falls back to its absolute
//                      stamp rather than guessing.
//   restartDismissed - closed in THIS plasmashell session. Nothing persists it, by design.
//   reclaimDismissed - the reclaim digest whose offer was closed in this session, or "". A new
//                      digest (a different set of runtimes) shows the offer again.
//   engineFault      - "" when the engine answered, else WHICH way it did not: "missing" (rc 127,
//                      nothing to run) or "unrunnable" (rc 126, there and would not start). Any
//                      other value reads as "", because this replaces the popup's whole body and
//                      an unrecognised one must not be able to blank it. A separate input rather
//                      than a magic cliError value: "we could not get an answer" and "there is
//                      nothing here to answer" are different facts.
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
    var engineFault = (opts.engineFault === "missing" || opts.engineFault === "unrunnable")
        ? opts.engineFault : "";
    var noEngine = engineFault !== "";
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
    // ...and only while the engine is MISSING. An engine that is installed and will not start is
    // a malfunction, which is what the warning emblem is for; dimming it would file a broken
    // installation under "nothing has happened yet".
    else if (engineFault === "missing" && noState) iconState = "unknown";
    else if (engineFault === "unrunnable" && noState) iconState = "error";
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

    // The per-user apps could not be listed, so the check answered for the system ones only. The
    // CLI keeps the last check's per-user rows, and this says they are not today's answer.
    var fpBackend = usable && state.backends && typeof state.backends === "object"
        ? state.backends.flatpak : null;
    var userUnchecked = !!(fpBackend && typeof fpBackend === "object" && fpBackend.scopes
        && typeof fpBackend.scopes === "object" && fpBackend.scopes.user === "failed");

    var countPhrase = "";
    if (usable) {
        // "Up to date" over rows with waiting versions in them is a lie by omission, which is what
        // a box whose every pending update is held would draw. Nothing is ACTIONABLE, which is
        // what the badge and the button are about; the header is the sentence, and the sentence
        // owes the held count.
        // ...and a failed check has not looked. The footer and the tooltip say when something last did.
        countPhrase = actionable > 0 ? i18np("1 update", "%1 updates", actionable)
            : heldTotal > 0
                ? (stale ? i18np("Last check failed · %1 held", "Last check failed · %1 held", heldTotal)
                         : i18np("Up to date · %1 held", "Up to date · %1 held", heldTotal))
            : userUnchecked
                ? (stale ? i18n("Last check failed · apps for you only not checked")
                         : i18n("Up to date · apps for you only not checked"))
            : stale ? i18n("Last check failed") : i18n("Up to date");
    }

    // --- a transaction that is already staged and armed ------------------------------------------
    // Derived HERE, above the header, because it changes what the header may say: while a stage is
    // armed the pending count is a true number saying a false thing. Nine of the returned fields
    // depend on it.
    //
    // heldDnf is walked out of the items collectItems already built rather than re-read from the
    // state: those rows are what the popup is SHOWING as held, and a banner whose warning
    // disagreed with the Held group under it would contradict itself in one glance.
    // What kind of machine this is, and what else is in dnf5's one transaction slot. Both are read
    // HERE, above the staged banner, because that banner depends on the second of them.
    //
    // Strictly `=== true`: absent in every state file written before this existed, and it takes the
    // primary button off the screen, so nothing unexpected may switch it on.
    var imageBased = usable && state.image_based === true;
    var foldersPausedMessage = usable && !imageBased && typeof state.unsafe_folder === "string"
        && state.unsafe_folder !== "" ? i18n("A system folder has unsafe permissions, so Kempt has paused updates. Check Installation shows how to fix it.") : "";

    // Guarded the same way, and both halves or neither: "a Fedora  upgrade" with a hole where the
    // number goes is worse than saying nothing at all.
    var relUp = (usable && state.release_upgrade && typeof state.release_upgrade === "object")
        ? state.release_upgrade : null;
    var relTo = (relUp && typeof relUp.to === "string") ? relUp.to : "";
    var relFrom = (relUp && typeof relUp.from === "string") ? relUp.from : "";
    var releaseUpgrade = (relTo !== "" && relFrom !== "");
    // WHICH of the three states it is in, and the sentence turns on it. `armed` is the only one a
    // restart installs; `downloaded` is where `dnf5 system-upgrade download` leaves one, and where
    // a box can sit for days; `stranded` is `ready` with the boot symlink gone, which a restart has
    // already walked past. Anything this file does not recognise - including a state file from a
    // CLI that published no state at all - reads as `downloaded`, the one that promises nothing.
    var REL_STATES = ["armed", "stranded", "incomplete", "downloaded", "foreign"];
    var relState = (releaseUpgrade && REL_STATES.indexOf(relUp.state) >= 0)
        ? relUp.state : "downloaded";
    // What a run started now would ACTUALLY do, which decides whether "updating now" is a thing
    // this box can do at all.
    var runSurface = resolveSurface(typeof opts.surface === "string" ? opts.surface : "");
    var stagesByDefault = (runSurface === "offline");
    var flatpakPending = usable && backendActionable(state, "flatpak") > 0;
    // Another updater holds the next restart. Taken from the CLI's word, like every other fact here;
    // anything that acts on it asks again there. No stage can install behind it, so the press is a
    // live run whatever the setting says, and the staging routes go.
    var restartHeld = usable && state.restart_holder === "other";
    var updateButton = updateButtonOf(
        restartHeld ? "popup" : runSurface,
        usable ? backendActionable(state, "dnf") : 0, flatpakPending);
    // Why Kempt cannot go ahead on this box, one cause at a time, worst first: a box it cannot
    // update at all, then a pause every button would end in, then the one route an upgrade closes.
    // An armed upgrade is said alongside the pause, because the next restart installs it either way.
    // A stored update Kempt cannot read. It sits with what stops Kempt, for the button that says why.
    var stageProblem = (usable && !releaseUpgrade && !imageBased) ? state.offline_stage_problem : "";
    var blockedMessage = imageBased ? i18n("This computer installs updates through Discover, not Kempt.")
        : stageProblem === "unknown" ? i18n("Kempt cannot tell what the next restart will do. Check Installation shows why.")
        : foldersPausedMessage !== "" && relState === "armed" ? i18n("A Fedora %1 upgrade installs on the next restart, and Kempt has paused other updates because a system folder has unsafe permissions. Check Installation shows how to fix it.", relTo)
        : foldersPausedMessage !== "" ? foldersPausedMessage
        : !releaseUpgrade ? ""
        : relState === "armed" ? i18n("A Fedora %1 upgrade installs on the next restart, so other updates cannot wait for that restart.", relTo)
        : i18n("A Fedora %1 upgrade waits for you to finish or remove it, so updates cannot wait for the next restart. Check Installation says how.", relTo);

    var heldDnf = false;
    for (var h = 0; h < counted.heldItems.length; h++) {
        if (counted.heldItems[h].backend === "dnf") { heldDnf = true; break; }
    }
    // A stored release upgrade means Kempt's own staged transaction is not the one dnf5 has: there
    // is ONE slot, and a transaction whose target release differs from the system's cannot be one
    // Kempt built. A current CLI stops publishing offline_staged in that state; this handles a file
    // an older one wrote, and it is what stops the popup showing both banners - the second of which
    // tells the reader to press a Discard button the first has just taken away.
    var stagedVariant = stagedVariantOf(
        (usable && !releaseUpgrade) ? state.offline_staged : null, heldDnf,
        usable ? backendActionable(state, "flatpak") : 0);
    var stagedMessage = stagedVariant.message;
    var staged = stagedMessage !== "";
    // A stage another updater's restart stands in front of. It borrows the
    // staged slot as a warning and offers none of its actions: no restart (the restart installs the
    // other update) and no discard (the CLI
    // refuses one, since dnf5 offline clean would cancel the other update too). An object is all
    // that is read: the sentence needs neither the count nor the stamp.
    var stageBlocked = usable && !releaseUpgrade && !staged && !imageBased
        && !!state.offline_stage_blocked && typeof state.offline_stage_blocked === "object"
        && !isArray(state.offline_stage_blocked);
    // A stage no restart will install now, said in the staged slot. It offers nothing of its own:
    // staging again is already on offer, and that is what the sentence says to use.
    var stageLostMessage = staged || stageBlocked ? ""
        : stageProblem === "lost" ? i18n("The updates you prepared will not install on the next restart, because something cancelled them. Use Install on Next Restart to prepare them again.")
        : stageProblem === "interrupted" ? i18n("A restart began installing your prepared updates and was interrupted, so they will not install on the next restart. Use Install on Next Restart to prepare them again.")
        : "";
    // The flip, in one boolean. Everything downstream reads THIS rather than re-testing the
    // variant, so "which banner is this" is decided in exactly one place.
    var stagedWarning = stagedVariant.type === "warning";

    // What to DO about a session-critical set, which is a different question from how big it is.
    // Silent while a transaction is already staged: this question IS the "Install on Next Restart"
    // offer, and offering it over an armed transaction invites a second staging of the same
    // updates. The status line still says what the set holds: those packages are still pending
    // until the restart runs.
    // isArray, not a duck-typed length check: a STRING has a numeric length and indexes into its
    // own characters, so `risky_pending: "kernel-core"` would walk out of here as "11
    // session-critical pending (c, e, k, l, ...)".
    // The recommendation is only printable where the route it recommends exists. Where it does not,
    // the status line alone states the risk and advises nothing.
    var noOfflineRoute = releaseUpgrade || imageBased || restartHeld;
    // ...and on a box Kempt cannot update AT ALL, the risk is not the widget's to raise: no button
    // it offers can act on it, dnf's view is not what installs there, and a second message under
    // the one saying so would be a count with nowhere to go. The release-upgrade case is the
    // opposite - the live button stays on screen, so the warning has to stay with it.
    var riskyIsMoot = imageBased;
    var riskyPending = usable && isArray(state.risky_pending) ? state.risky_pending : [];
    // What the question says. Where no route to the next restart exists there is nothing to choose,
    // and the status line still names what the set holds.
    var riskyMessage = (staged || noOfflineRoute) ? "" : riskyMessageOf(riskyPending);
    // Whether Update Now asks before it runs: a risky set, a route to the next restart, and a run
    // that would install it live with nobody asked. The offline surface already is the next restart.
    // Not while Kempt is blocked: no answer could start a run.
    var updateAsksFirst = riskyMessage !== "" && runSurface === "popup" && blockedMessage === "";
    var riskyChoice = opts.riskyChoiceOpen === true && updateAsksFirst && !updating;
    // Nothing of Kempt's staged behind that restart: the banner stands by itself. Not beside what
    // the release-upgrade and image-based messages already say about the same restart.
    var restartHeldBanner = restartHeld && !staged && !stageBlocked && !releaseUpgrade && !imageBased && stageLostMessage === "";
    // Update Now while it is held: its own question when system updates would run, none for
    // Flatpak alone, which touches nothing that updater prepared. None while updates are paused too:
    // nothing it warns about can happen, since the helper refuses the run.
    var updateAsksHeld = restartHeld && !imageBased && !staged && foldersPausedMessage === ""
        && backendActionable(state, "dnf") > 0;
    var heldChoice = opts.heldChoiceOpen === true && updateAsksHeld && !updating;

    // The mild Discover message. The CLI publishes discover_offer while the
    // notifier starts with the session and nobody has answered. It waits for the widget to read
    // the CLI's answered marker, which a state.json from before the answer does not reflect.
    var discoverOffer = usable && !imageBased && state.discover_offer === true && !updating
        && opts.discoverOfferAnswered !== true && opts.discoverAnswerKnown !== false;
    // Discover's setting, over the offer: it says the larger thing. Kept up once drawn, for as long
    // as this popup stays open (main.qml), since drawing it is what clears the CLI's flag.
    var discoverUnattended = usable && !imageBased && state.discover_unattended === true && !updating
        && opts.discoverWarningGone !== true
        && (state.discover_unattended_warn === true || opts.discoverWarningKept === true);
    // ...and closing the serious form does not bring up the mild one under it in the same open.
    if (discoverUnattended || opts.discoverWarningGone === true) discoverOffer = false;

    // Strictly the boolean, and only out of a state this build can read. In this schema `false`
    // means "nothing to say", NEVER "no restart needed": backends/dnf.sh's dnf_reboot_needed
    // answers false plus a warning whenever it could not work the verdict out - rc 1 with empty
    // stdout (a cold user cache, the DEFAULT on a fresh install) and every unexpected rc land
    // there. So a false is indistinguishable from "we could not tell", and nothing renders an
    // affirmative from it. docs/architecture.md states the same rule for every reader.
    // Derived up here rather than with the restart message below, because the panel tooltip reads
    // it too.
    var rebootNeeded = usable && state.reboot_needed === true;

    var security = securityOf(usable ? state : null);

    var tooltipMain, headerText;
    if (updating) {
        tooltipMain = i18n("Updating…");
        headerText = i18n("Updating…");
    } else if (noEngine) {
        // Names the state instead of quoting the shell: `sh: line 1: kempt: command not found` is
        // true, unreadable, and about a program the reader has never heard of.
        headerText = engineFault === "missing"
            ? i18n("Kempt's engine is not installed")
            : i18n("Kempt's engine will not run");
        // The header is the tooltip's title, and the sentence under it carries on from it rather
        // than repeating it.
        tooltipMain = headerText;
    } else if (iconState === "unknown") {
        tooltipMain = "Kempt";
        headerText = i18n("No update data yet");
    } else if (iconState === "error") {
        tooltipMain = (cliError !== "" || neverAnswered)
            ? i18n("Cannot check for updates") : i18n("Cannot read the update state");
        headerText = (cliError !== "" || neverAnswered)
            ? i18n("Kempt cannot check for updates")
            : i18n("Could not read the update state");
    } else if (staged) {
        // The one place the count gives way. Not a second line under it and not a badge emblem:
        // the header is the sentence a person reads first, and while a stage is armed the honest
        // answer to "where do I stand" is that the work is done and waiting for a restart.
        headerText = stagedHeaderOf(state.offline_staged);
        tooltipMain = headerText;
    } else {
        tooltipMain = countPhrase;
        // The kernel message of old in six words: what the set holds, before anything is pressed.
        headerText = actionable > 0 && !riskyIsMoot && riskyPending.length > 0
            ? statusLineOf(actionable, riskyPending) : countPhrase;
    }

    var lastSuccessText = usable ? formatStamp(state.last_success) : "";
    var staleReason = stale
        ? (typeof state.error === "string" && state.error !== "" ? state.error : i18n("the last check failed"))
        : "";

    // The one sentence an error state owes the user, in descending order of how much it knows.
    // A failed check is said in plain words, with the tool's own line kept as the detail.
    var problemText = "", problemDetail = "", problemNetwork = false, problemNoCache = false;
    var problemHint = "";
    if (iconState === "error") {
        var problemRaw = cliError !== "" ? cliError                  // we could not run the CLI
            : (neverAnswered ? staleReason : "");                    // it ran, and told us why not
        if (problemRaw !== "") {
            var problem = checkProblemOf(problemRaw, usable && !!state.backends
                && !!state.backends.dnf ? state.backends.dnf.refresh_error : undefined,
                usable ? state.refresh_skipped : undefined);
            problemText = problem.headline;
            problemDetail = problem.detail;
            problemNetwork = problem.network;
            problemNoCache = problem.noCache;
            problemHint = problem.hint;
        } else {
            problemText = i18n("the update state could not be read");      // it answered something else
        }
    }

    // The whole answer for a box with no working engine, assembled here so the popup binds one
    // string: what is true, then what to do about it. Empty in every other state, which is what
    // the popup gates on - and the same for the clipboard text and its button label, which only
    // exist while the message does.
    var engineFaultMessage = "", engineFaultCopyText = "", engineFaultActionLabel = "";
    if (engineFault === "missing") {
        engineFaultMessage = i18n("Nothing can check for updates yet.") + "\n" + i18n("To install the engine on Fedora, run:\nsudo dnf copr enable erez-c137/kempt\nsudo dnf install kempt-plasmoid\nFor other ways to install it, see github.com/erez-c137/kempt.");
        engineFaultCopyText = "sudo dnf copr enable erez-c137/kempt && sudo dnf install kempt-plasmoid";
        engineFaultActionLabel = i18n("Copy Commands");
    } else if (engineFault === "unrunnable") {
        engineFaultMessage = i18n("The engine is installed but cannot start, so nothing can check for updates.") + "\n" + i18n("Press Check Installation to find the problem.");
        engineFaultCopyText = "kempt doctor";
        engineFaultActionLabel = i18n("Copy Command");
    }
    // Check Installation only where kempt is there to run. A missing engine has no doctor.
    var engineFaultOffersDoctor = engineFault === "unrunnable";

    // Read only out of a state this build can read, like every optional key: a schema-1 reader
    // tolerates the key being absent (every file written before this existed) and being the wrong
    // type. formatDownload answers "" to both. Nothing while a stage is armed: its packages are
    // already downloaded, and "to download" beside them is false.
    var downloadText = usable && !staged ? formatDownload(state.download_bytes) : "";

    var subParts = [];
    // The fact, and only the fact. The install commands belong in the popup, where they can be
    // read and copied; two command lines under a panel hover is noise.
    if (engineFault === "missing") subParts.push(i18n("Nothing can check for updates yet."));
    else if (engineFault === "unrunnable") subParts.push(i18n("The engine is installed but cannot start, so nothing can check for updates."));
    else if (iconState === "unknown") subParts.push(i18n("no data until the first check finishes"));
    else if (iconState === "error") {
        // A short reason, never the tool's stderr: the popup has that in small print.
        subParts.push(problemNetwork ? i18n("Could not reach the update servers")
            : (problemDetail !== "" ? i18n("Open Kempt to see why") : problemText));
    }
    else {
        // What is pending, by name - the count says how many, this says what. Not while a stage
        // is armed: the header already says the work is done and waiting for a restart.
        var pendingNames = staged ? "" : pendingNamesOf(counted.sections, riskyPending);
        if (pendingNames !== "") subParts.push(pendingNames);
        // ...and how many of them fix a security advisory. Not while a stage is armed, like the
        // names: the work is done and waiting for a restart.
        if (!staged && security.count > 0) {
            subParts.push(i18np("1 security update", "%1 security updates", security.count));
        }
        // The Holds promise: a box whose only pending updates are held LOOKS up to date, and the
        // tooltip is where it still says the held ones exist.
        // Not when the tooltip title already says it ("Up to date · 10 held").
        if (heldTotal > 0 && (actionable > 0 || tooltipMain !== countPhrase)) subParts.push(i18np("%1 held", "%1 held", heldTotal));
        // Only with something to download AND something to press. On an up-to-date box the number
        // is zero or absent; next to a held-only list it would describe bytes no run will fetch.
        if (actionable > 0 && downloadText !== "") subParts.push(i18n("%1 to download", downloadText));
        // Staleness is a tooltip fact, not an icon alarm, so the tooltip carries BOTH halves: what
        // went wrong, and how old the numbers above it therefore are.
        if (stale) {
            subParts.push(staleSaidOf(state));
            subParts.push(everSucceeded
                ? i18n("Last successful check %1", relativeTime(state.last_success, opts.nowMs))
                : i18n("No successful check yet"));
        }
        if (userUnchecked) subParts.push(i18n("apps for you only not checked"));
        // A pending restart is the one fact needing an action from the person; without this line
        // it could only be found by opening the popup. Last, because it is about the machine
        // rather than about the counts above it.
        if (rebootNeeded) subParts.push(i18n("restart pending"));
    }

    // What the popup shows where the list would be, when there is no list to show.
    var emptyStateText = "";
    if (updating) emptyStateText = "";
    // Silent, and that silence keeps the popup from saying one thing twice: the engine-missing
    // message already carries the whole answer, and the placeholder's own sentence ("the first
    // check has not finished") would be a promise about a check that will never finish. The
    // placeholder hides itself on empty text.
    else if (noEngine) emptyStateText = "";
    else if (iconState === "unknown") emptyStateText = i18n("The first check has not finished.");
    else if (iconState === "error") emptyStateText = problemText;
    else if (nothingKnown) {
        emptyStateText = stale ? i18n("No updates found the last time Kempt could check.")
            : (userUnchecked ? i18n("Apps installed for you only could not be checked.") : i18n("Everything is up to date"));
    }

    // The one thing a stuck user can usefully be told to type - offered ONLY where the widget has
    // nothing else to show. NOT on calm staleness: keeping quiet about a repo that flapped is the
    // point of that state, and staleReason already names doctor when that is what is wrong. NOT
    // when there is no working engine either, which is the case that proves the rule: `kempt
    // doctor` is a kempt subcommand, so on the box where kempt is what is absent this would tell
    // the user to run the very thing they do not have. Those states carry their own message, which
    // says the right thing for each.
    // ...and not for a network failure or missing package lists either: nothing in the
    // installation is wrong, and doctor would say so.
    var remedyCommand = (!noEngine && (cliError !== "" || neverAnswered) && !problemNetwork
                         && !problemNoCache) ? "kempt doctor" : "";

    // --- the restart, and what the popup is allowed to say about it -----------------------------
    // `rebootNeeded` itself is derived above, next to the tooltip that reads it.
    var restartMessageVisible = rebootNeeded && !isTrue(opts.restartDismissed);

    // --- unused Flatpak runtimes ------------------------------------------------------------------
    var reclaim = usable ? state.reclaim : null;
    var reclaimMessage = reclaimMessageOf(reclaim);
    var reclaimDigest = reclaimMessage !== "" ? reclaim.digest : "";
    var reclaimLines = [];
    if (reclaimMessage !== "") {
        var reclaimRefs = arrayOf(reclaim.refs);
        for (var r = 0; r < reclaimRefs.length; r++) {
            var refLine = reclaimRefLineOf(reclaimRefs[r]);
            if (refLine !== "") reclaimLines.push(refLine);
        }
    }
    var reclaimShown = reclaimMessage !== "" && opts.reclaimDismissed !== reclaimDigest;

    // --- which messages actually fit ------------------------------------------------------------
    // Decided HERE and not in the popup, because the footer depends on the answer: a restart the
    // cap displaced has to reappear as "restart pending" on the status line, and a popup deciding
    // this by itself would leave logic.js unable to tell whether it had.
    // `reportShown` is the one input this file cannot derive - the post-run line and a failed press
    // are main.qml's own state, not the CLI's.
    // A Check for Updates whose fetch did not land. In the report's slot, until the next check,
    // whoever starts it. A report of something that happened takes the slot first.
    var fetchMissedMessage = usable && !updating && !noEngine
        ? fetchMissedOf(state, opts.refreshAskedMs, opts.refreshCheckStamp) : "";
    // --- a service that stopped starting after an update ---------------------------------------
    // Never in the count, the badge, the icon or its attention: the update count is about updates.
    var startup = startupOf(usable ? state : null);
    var startupFree = !updating && !noEngine;
    var startupWanted = startupFree && startup.entries.length > 0;

    // ...and while a blocked stage is up, a report saying the stage installs on the next restart
    // is the very promise that warning takes back, so it gives way the same way.
    var reportRun = opts.reportShown === true
        && !((staged || stageBlocked || restartHeldBanner) && opts.reportRepeatsStaged === true);
    var messageSlots = messageStack({
        engineFault: engineFaultMessage !== "",
        report: reportRun || fetchMissedMessage !== "",
        // Check Installation's result, or its busy line: main.qml's own state, like the report.
        // Never hidden with a report that repeats the staged message: it says something else.
        doctor: opts.doctorShown === true && !updating,
        // ...including `updating`, because a run hides the whole stack. Without it the popup's own
        // dismissal guard could not tell a run starting from the user closing the message.
        restart: restartMessageVisible && !updating,
        staged: staged || stageBlocked || restartHeldBanner || stageLostMessage !== "",
        // Above everything except a report of something that just happened: every message under it
        // presumes a box Kempt can update. On an image-based box the status line says nothing of the
        // set either (riskyIsMoot above): with no button on offer, the set has nowhere to go.
        blocked: blockedMessage !== "",
        question: riskyChoice || heldChoice,
        discover: discoverUnattended ? "serious" : (discoverOffer ? "mild" : false),
        // The same offer with the reason that matters while something is staged, and higher up.
        reclaim: reclaimShown && !updating,
        startup: startupWanted
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
        if (!everSucceeded) footerParts.push(i18n("No successful check yet"));
        else if (isRenderableStamp(state.last_success)) {
            footerParts.push(i18n("Checked %1", relativeTime(state.last_success, opts.nowMs)));
        }
        // ...and the staleness, beside the date it explains. Not an alarm - the counts above are
        // still the best known truth - with the CLI's reason one hover away on the retry button.
        // Only over a count: with nothing waiting the header says it already.
        if (stale && (actionable > 0 || headerText !== countPhrase)) footerParts.push(i18n("last check failed"));
        if (userUnchecked) footerParts.push(i18n("apps for you only not checked"));
        // ...and how old the metadata behind those counts is, which the dateline above cannot say.
        // The two are different clocks: the check ran four minutes ago, the metadata it answered
        // from may be a week old, and only this line can tell the person that.
        var metaAge = metadataAgeText(state.metadata_refreshed, opts.nowMs,
                                      refreshMissed(state, opts.refreshAskedMs) ? 60000 : undefined);
        if (metaAge !== "") footerParts.push(metaAge);
    } else if (noState) {
        // No state at all - the first seconds of a session, or a CLI that could not be run. There
        // has been no successful check as far as this widget knows, and saying so is true.
        footerParts.push(i18n("No successful check yet"));
    }
    // ...and the case with no branch: a state we HOLD and cannot read (a schema this build does
    // not know). It may well record a successful check; we cannot tell, and the header already
    // says the state could not be read.
    if (heldTotal > 0) footerParts.push(i18np("%1 held", "%1 held", heldTotal));
    // Beside Update Now, which is the question it answers: pressing this costs about this much.
    // Same two conditions as the tooltip, and the same silence when either fails.
    if (actionable > 0 && downloadText !== "") footerParts.push(downloadText);
    // ...and the restart, whenever the message is not carrying it - including one the CAP
    // displaced, which is what makes displacing it honest rather than merely quiet. With the
    // message dismissed for this session, this line is the only place it is said.
    if (rebootNeeded && !restartShown) footerParts.push(i18n("restart pending"));

    // What Check for Updates says out loud when it lands, in the words already on screen. ONE
    // sentence for both places that can speak it (the panel icon while the popup is closed, the
    // popup while it is open), so the two cannot drift apart.
    //   * the line at the top, which is the answer: "3 updates", "Up to date", or that
    //     the engine is missing or will not run.
    //   * a check that failed: which half failed and how old the counts are (staleAnswerOf). The
    //     counts at the top are the old ones, and reading them out as the answer would be the
    //     wrong news.
    //   * a check whose fetch did not happen (battery, metered, offline): the top line plus the age
    //     the footer gives, because "Up to date" from old lists is not what the person asked for.
    //   * a check that answered nothing over a state we hold: the report main.qml put on screen
    //     for it (opts.checkUnfinished), since the counts at the top did not change.
    var checkAnswerText = headerText;
    var checkUnfinished = typeof opts.checkUnfinished === "string" ? opts.checkUnfinished : "";
    if (!updating && !noEngine && checkUnfinished !== "") checkAnswerText = checkUnfinished;
    else if (!updating && !noEngine && usable) {
        if (stale) checkAnswerText = staleAnswerOf(state, opts.nowMs);
        // Two whole sentences joined here, with the period between them written in code. A language
        // with another full stop gets the Latin one. metadataAgeText's translator note says so too.
        else if (fetchMissedMessage !== "") checkAnswerText = headerText + ". " + fetchMissedMessage;
        else if (metaAge !== "" && refreshMissed(state, opts.refreshAskedMs)) {
            checkAnswerText = headerText + ". " + metaAge.charAt(0).toUpperCase() + metaAge.slice(1);
        }
    }

    return {
        iconState: iconState,
        badgeText: badgeText,
        badgeVisible: badgeText !== "",
        tooltipMain: tooltipMain,
        tooltipSub: subParts.join(DOT),
        headerText: headerText,
        rows: rowsOf(counted.sections, counted.heldItems),
        actionable: actionable,
        stale: stale,
        // "" when fine; otherwise the CLI's own error text, so the popup says what actually went
        // wrong instead of a generic apology.
        staleReason: staleReason,
        staleTip: stale ? staleSaidOf(state) : "",
        // The fact, then what to do about it, on two lines. Empty means there is nothing to say,
        // and that empty string is the popup's only gate - exactly how stagedMessage
        // already works. The other two follow it: the clipboard payload the button
        // copies, and the button's own label, which names how many commands that is.
        engineFaultMessage: engineFaultMessage,
        engineFaultCopyText: engineFaultCopyText,
        engineFaultActionLabel: engineFaultActionLabel,
        engineFaultOffersDoctor: engineFaultOffersDoctor,
        emptyStateText: emptyStateText,
        // The tool's own line under a plain emptyStateText, and whether it was a network failure.
        problemDetail: problemDetail,
        // The line under emptyStateText: what to do about it. Check Installation's when it is offered.
        problemHint: remedyCommand !== "" ? i18n("Check Installation can find out why.")
            : (problemNetwork || problemNoCache ? problemHint : ""),
        remedyCommand: remedyCommand,
        // The question Update Now asks, and which of the two it is: the other updater's has no
        // route to the next restart, so its one answer is to run now.
        questionMessage: riskyChoice ? riskyMessage : (heldChoice ? i18n("Updating now may stop another updater's prepared update from installing.") : ""),
        questionHeld: heldChoice,
        // Update Now opens the risky choice instead of running (main.qml, startUpdate).
        updateAsksFirst: updateAsksFirst,
        // Who holds the next restart, and what Update Now does about it (main.qml, startUpdate).
        restartHeld: restartHeld,
        updateAsksHeld: updateAsksHeld,
        heldLiveSurface: restartHeld ? "popup" : "",
        stagedMessage: stageBlocked ? i18n("Another updater has prepared your next restart, so these updates will not install then. Try again after that restart.")
            : restartHeldBanner ? i18n("Another updater has prepared your next restart, so restart when you are ready.")
            : stageLostMessage !== "" ? stageLostMessage : stagedMessage,
        // A Check for Updates whose fetch did not land, when the report's slot is free for it.
        reportFetchMessage: reportRun ? "" : fetchMissedMessage,
        // Why that message may offer Check Anyway: "battery", "metered", or "" for no button.
        fetchMissedAnyway: !reportRun && fetchMissedMessage !== "" ? anywayReasonOf(state.refresh_skipped) : "",
        // The same for the placeholder over lists never downloaded: only under the battery and
        // metered hints, so never beside Check Installation or fetching turned off. A refresh
        // error from before is only the detail there (checkProblemOf).
        problemAnyway: usable && problemNoCache && remedyCommand === ""
            && (problemHint === i18n("Plug in, then press Check for Updates.") || problemHint === i18n("Switch to an unmetered connection, then press Check for Updates."))
            ? anywayReasonOf(state.refresh_skipped) : "",
        // What the banner shows: the plain one gives way to the header's count.
        // "there is an armed transaction", for the surfaces that have to stand down rather than
        // say something about it. Update Now is hidden on this: pressing it over an armed stage
        // starts a second, live update of the same packages.
        stagedArmed: staged,
        // "positive" for the ordinary armed stage, "warning" once a hold has landed behind it. A
        // string rather than a boolean because the QML binds it to a Kirigami.MessageType, and a
        // third spelling is a plausible next state for this banner rather than an exotic one.
        stagedType: (stageBlocked || restartHeldBanner || stageLostMessage !== "") ? "warning" : stagedVariant.type,
        // The blocked stage above: in the staged slot, with no action of its own.
        // Never two Restart… buttons in one popup: the restart Warning already carries one
        // whenever it is on screen.
        // ...and never a Restart… on a warning variant at all, which is the stricter rule and the
        // reason the flip is worth anything: the person is looking at a sentence saying the next
        // restart will install the package they tried to keep out.
        // Over a restart another updater holds the stricter rule does not apply: restarting is the
        // one thing there is to do, and the sentence says so.
        stagedShowRestart: !restartMessageVisible
            && ((staged && !stagedWarning) || stageBlocked || restartHeldBanner),
        // ...and the way out: discard the staged update, and let the next restart install nothing.
        // Offered on BOTH banners: "install nothing at all" is an answer to either one, and on a
        // warning it is the first half of the remedy the sentence names.
        // Never where it would be refused: `kempt unstage` exits 5 while a Fedora release upgrade
        // is stored, and on an image-based box dnf is not how the machine updates at all.
        stagedShowDiscard: staged && !noOfflineRoute,
        // Whether the popup may OFFER to stage at all. The CLI refuses the press; this is what
        // stops it being offered, so nobody has to press a button to be told no.
        // Both refusals land here: on an image-based system `kempt update` aborts in pre-flight
        // whatever surface it was asked for, so staging is no more available than updating.
        offlineStageOffered: !noOfflineRoute,
        // Install on Next Restart in the widget's menus, for the box whose footer says Update Now.
        stageMenuOffered: !updating && !staged && !stageBlocked && !noOfflineRoute
            && !updateButton.stages && usable && backendActionable(state, "dnf") > 0,
        discoverMessage: discoverUnattended ? i18n("Discover is set to install updates by itself, so it can take over your next restart and stop Kempt's updates.") : (discoverOffer ? i18n("Discover also checks for updates, and that can cancel updates waiting for your next restart.") : ""),
        discoverSerious: discoverUnattended,
        blockedMessage: blockedMessage,
        // A warning for the one cause that needs fixing, and the button for every cause Kempt can
        // explain: doctor names the folder, and the upgrade's commands for the state it is in.
        blockedWarns: !imageBased && foldersPausedMessage !== "",
        blockedOffersDoctor: !imageBased && blockedMessage !== "",
        // ...and the same for Update Now, which is the primary button. HIDDEN rather than
        // disabled, exactly as it is for a box with nothing pending: there is no action to offer
        // here, and a greyed primary button with its explanation elsewhere is a puzzle.
        // ...and not on a box whose Update Now IS the staging that is refused: with the run surface
        // set to offline, pressing it runs exactly the command the CLI turns down. Hidden rather
        // than left to fail, on the same rule as everything else here.
        updateOffered: !imageBased && !(releaseUpgrade && stagesByDefault),
        // The footer button's words: the QML writes both literals for i18n and picks one with this.
        updateStages: updateButton.stages,
        stageTooltipNamesFlatpak: flatpakPending,
        // The stamp this banner was derived from, for main.qml's click-time re-verify. Consent is
        // given to a BANNER, and a banner describes ONE transaction: between render and click it
        // can be consumed by a restart, replaced or cleaned away. "" means there is nothing to compare, which the re-verify reads as "do not
        // act".
        stagedStagedAt: stagedVariant.stagedAt,
        restartMessageVisible: restartMessageVisible,
        // ...and whether that message may carry its own Restart button. Everywhere else it may: a
        // restart applies updates that are already installed. NOT while the staged banner is a
        // warning - in that state a restart installs the very package the warning says the person
        // tried to keep out.
        restartShowAction: restartShown && !stagedWarning,
        // Which messages the popup may draw, in order, and never more than two. The rule and its
        // reasons are messageStack above.
        messageSlots: messageSlots,
        // The reclaim offer: its line, one line per runtime for Show Runtimes, and the digest the
        // popup passes to `kempt reclaim --expect`.
        reclaimMessage: reclaimMessage,
        reclaimLines: reclaimLines,
        reclaimDigest: reclaimDigest,
        // The startup banner: one entry per service with its text and the command Copy Command
        // copies, a heading only when there are several, the quiet already-failing line, the
        // one-time recovered line, and the digest `kempt startup ack` takes. The digest is ""
        // unless the line is actually on screen, so a line the cap displaced is not acknowledged.
        startupEntries: startup.entries,
        startupTitle: startup.title,
        startupHeading: startup.heading,
        startupAlready: startup.already,
        startupAckDigest: startupFree ? startup.digest : "",
        footerText: footerParts.join(DOT),
        checkAnswerText: checkAnswerText,
        // Published rather than left inside the two strings above, so a future surface (a
        // notification, a `check --human` line) renders the same words instead of its own.
        // The relative time in footerText is the convenience; this is the truth, and people
        // compare the two. Empty rather than "never" when there has been no successful check: the
        // footer already says so in words.
        footerTooltip: everSucceeded ? lastSuccessText : ""
    };
}

// The node half of the double life. `module` does not exist in QML's JS engine, so this is a
// no-op there; typeof on an undeclared name is safe in every engine.
if (typeof module !== "undefined" && module.exports) {
    // Plasma's i18n, as English: the same substitution tests/qml/harness.py gives the probes.
    var i18nFill = function (text, args, from) {
        for (var a = from; a < args.length; a++) text = text.split("%" + (a - from + 1)).join(args[a]);
        return text;
    };
    global.i18n = function (text) { return i18nFill(text, arguments, 1); };
    global.i18np = function (one, many, n) { return i18nFill(n === 1 ? one : many, arguments, 2); };
    module.exports = {
        VERSION_UNKNOWN: VERSION_UNKNOWN,
        fromTextOf: fromTextOf,
        versionTextOf: versionTextOf,
        displayNameOf: displayNameOf,
        parseState: parseState,
        viewModel: viewModel,
        newestOf: newestOf,
        familiesOf: familiesOf,
        formatStamp: formatStamp,
        formatDownload: formatDownload,
        relativeTime: relativeTime,
        shouldRefreshOnOpen: shouldRefreshOnOpen,
        refreshMissed: refreshMissed,
        fetchMissedOf: fetchMissedOf,
        anywayReasonOf: anywayReasonOf,
        servedBeforePress: servedBeforePress,
        checkArgs: checkArgs,
        CHECK_BODY_MS: CHECK_BODY_MS,
        CHECK_TIMEOUT_MS: CHECK_TIMEOUT_MS,
        riskyMessageOf: riskyMessageOf,
        riskyFamiliesOf: riskyFamiliesOf,
        pendingNamesOf: pendingNamesOf,
        stagedMessageOf: stagedMessageOf,
        stagedVariantOf: stagedVariantOf,
        messageStack: messageStack,
        MESSAGE_CAP: MESSAGE_CAP,
        RECLAIM_MIN_BYTES: RECLAIM_MIN_BYTES,
        reclaimOffered: reclaimOffered,
        reclaimMessageOf: reclaimMessageOf,
        reclaimRefLineOf: reclaimRefLineOf,
        reclaimSaid: reclaimSaid,
        RECLAIM_TIMEOUT_MS: RECLAIM_TIMEOUT_MS,
        lastRunOf: lastRunOf,
        postRunLine: postRunLine,
        reportRepeatsStaged: reportRepeatsStaged,
        runFinishedSince: runFinishedSince,
        runStartMessage: runStartMessage,
        discardStagedMessage: discardStagedMessage,
        DOCTOR_TIMEOUT_MS: DOCTOR_TIMEOUT_MS,
        DOCTOR_SUMMARY_MAX: DOCTOR_SUMMARY_MAX,
        mentionsDoctor: mentionsDoctor,
        withoutDoctorPointer: withoutDoctorPointer,
        doctorOutcomeOf: doctorOutcomeOf,
        lastRunText: lastRunText,
        lastRunSubtitle: lastRunSubtitle,
        shellQuote: shellQuote,
        firstLineOf: firstLineOf,
        isExecutorTimeout: isExecutorTimeout,
        ANSWER_TIMEOUT_MS: ANSWER_TIMEOUT_MS,
        answerOutcomeOf: answerOutcomeOf,
        checkErrorOf: checkErrorOf,
        checkProblemOf: checkProblemOf,
        logTailOf: logTailOf,
        checkFailedOverOf: checkFailedOverOf,
        staleAnswerOf: staleAnswerOf,
        rowsOf: rowsOf,
        securityOf: securityOf,
        startupVerbArgs: startupVerbArgs,
        startupMutedOf: startupMutedOf,
        STARTUP_PAGE_ARGS: STARTUP_PAGE_ARGS,
        STARTUP_PAGE_TIMEOUT_MS: STARTUP_PAGE_TIMEOUT_MS,
        startupPageOutcomeOf: startupPageOutcomeOf,
        isTrue: isTrue,
        DEFAULT_SURFACE: DEFAULT_SURFACE,
        resolveSurface: resolveSurface,
        updateButtonOf: updateButtonOf,
        stageTooltipOf: stageTooltipOf,
        backendActionable: backendActionable,
        updatingLabelOf: updatingLabelOf,
        holdsOf: holdsOf,
        discoverSettingOf: discoverSettingOf,
        snapIconSize: snapIconSize,
        collectItems: collectItems,
        resolveReclaimSetting: resolveReclaimSetting,
        ICON_STEPS: ICON_STEPS,
        watchChange: watchChange,
        watchFieldsOf: watchFieldsOf,
        WATCH_FIELDS: WATCH_FIELDS,
        watcherCheckDue: watcherCheckDue,
        watcherQuietLeft: watcherQuietLeft,
        checkedSince: checkedSince,
        checkedAfterRun: checkedAfterRun,
        CHECK_QUIET_MS: CHECK_QUIET_MS
    };
}
