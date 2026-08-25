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
    var idx = ICON_SIZE_SETTINGS[resolveIconSizeSetting(setting)];
    if (idx < 0) return auto;
    var want = Number(list[idx]);
    if (!isFinite(want) || want <= 0) return auto;    // a step list too short to name it
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

// formatStamp(iso) -> "2026-08-24 22:11", or "never" when there is no stamp.
// Textual, not Date-based, on purpose: it cannot print "Invalid Date", it cannot shift a
// timestamp into another timezone, and it survives the recorded corruption where two state
// documents end up concatenated and a per-document read hands us both, newline-joined.
function formatStamp(iso) {
    if (typeof iso !== "string") return "never";
    var s = iso.split("\n")[0].trim();
    if (s === "") return "never";
    var m = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/.exec(s);
    return m ? m[1] + " " + m[2] : s;
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

// viewModel(state, updating, cliError) -> everything the QML layer binds to. Called on every
// state change; the QML side holds no derived state of its own.
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
function viewModel(state, updating, cliError) {
    updating = !!updating;
    cliError = firstLineOf(typeof cliError === "string" ? cliError : "");
    var usable = looksLikeState(state);
    var counted = collectItems(usable ? state : null);
    var stale = usable && state.status === "stale";

    // The CLI's own totals win when present: the badge must come from the same command path that
    // performs the update. The walk above is only a fallback for a state that omits them.
    var actionable = usable
        ? (typeof state.actionable === "number" ? state.actionable : counted.actionable)
        : null;
    var heldTotal = usable
        ? (typeof state.held_total === "number" ? state.held_total : counted.heldTotal)
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
        countPhrase = actionable === 0 ? "Up to date"
            : (actionable === 1 ? "1 update available" : actionable + " updates available");
    }

    var tooltipMain, headerText;
    if (updating) {
        tooltipMain = "Updating...";
        headerText = "Updating...";
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

    var subParts = [];
    if (iconState === "unknown") subParts.push("no data yet - the first check has not finished");
    else if (iconState === "error") subParts.push(problemText);
    else {
        // The Holds promise: a box whose only pending updates are held LOOKS up to date, and the
        // tooltip is where it still says the held ones exist.
        if (heldTotal > 0) subParts.push(heldTotal + " held");
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
        emptyStateText = stale ? "No updates in the last known state." : "Everything is up to date.";
    }

    // The one thing a stuck user can usefully be told to type - offered ONLY where the widget has
    // nothing else to show: a CLI it could not run, or a box that has never had a successful
    // check. Deliberately NOT offered on calm staleness. Keeping quiet about a repo that flapped
    // is the entire point of that state, and a "run kempt doctor" line under counts that are
    // perfectly good is exactly the noise it exists to avoid. The CLI's own words are still
    // shown there via staleReason, which names doctor itself when that is what is wrong.
    var remedyCommand = (cliError !== "" || neverAnswered) ? "kempt doctor" : "";

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
        riskySummary: riskySummaryOf(
            usable && state.risky_pending && typeof state.risky_pending.length === "number"
                ? state.risky_pending : []),
        lastSuccessText: lastSuccessText
    };
}

// The node half of the double life. `module` does not exist in QML's JS engine, so this is a
// no-op there; typeof on an undeclared name is safe in every engine.
if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        parseState: parseState,
        viewModel: viewModel,
        newestOf: newestOf,
        familiesOf: familiesOf,
        formatStamp: formatStamp,
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
        WATCH_FIELDS: WATCH_FIELDS
    };
}
