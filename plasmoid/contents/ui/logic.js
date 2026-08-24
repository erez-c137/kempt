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
// Same number the CLI's notification uses (bin/upkeep).
var RISKY_FAMILIES_SHOWN = 4;

// Highest number the panel badge spells out; above this it reads "99+".
var BADGE_MAX = 99;

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
// because a popup that renders a version differently from `upkeep summary` is the front-end
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
                backend: key   // half of the `upkeep hold <backend>:<name>` argument
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

// viewModel(state, updating) -> everything the QML layer binds to. Called on every state change;
// the QML side holds no derived state of its own.
//
// iconState is decided in this order, and the order is the contract:
//   updating   - we started a run; it wins over whatever the last check said
//   unknown    - no state at all (first load, or every check so far returned nothing)
//   error      - we have an object, but it is not schema v1: say so, never render it as 0
//   stale      - the last check failed; the counts below are the last known good ones
//   updates    - actionable > 0
//   uptodate   - actionable == 0 (held items do not count: spec, Holds semantics)
function viewModel(state, updating) {
    updating = !!updating;
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

    var iconState;
    if (updating) iconState = "updating";
    else if (state === null || state === undefined) iconState = "unknown";
    else if (!usable) iconState = "error";
    else if (stale) iconState = "stale";
    else if (actionable > 0) iconState = "updates";
    else iconState = "uptodate";

    // No count, no badge. This is rule 1 of the state schema in one line: "no data" must never
    // reach the panel as a confident zero.
    // Capped at "99+" because a four-digit badge stops being a badge and starts being a layout
    // problem in a panel. It stays truthful - "more than 99" is a fact - and the exact number is
    // one hover away in the tooltip, which is never capped.
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
        tooltipMain = "Upkeep";
        headerText = "No update data yet";
    } else if (iconState === "error") {
        tooltipMain = "Upkeep";
        headerText = "Could not read the update state";
    } else {
        tooltipMain = countPhrase;
        headerText = countPhrase;
    }

    var lastSuccessText = usable ? formatStamp(state.last_success) : "";

    var subParts = [];
    if (iconState === "unknown") subParts.push("no data yet - the first check has not finished");
    else if (iconState === "error") subParts.push("the update state could not be read");
    else {
        // The Holds promise: a box whose only pending updates are held LOOKS up to date, and the
        // tooltip is where it still says the held ones exist.
        if (heldTotal > 0) subParts.push(heldTotal + " held");
        if (stale) subParts.push("last successful check: " + lastSuccessText);
    }

    return {
        iconState: iconState,
        badgeText: badgeText,
        badgeVisible: badgeText !== "",
        tooltipMain: tooltipMain,
        tooltipSub: subParts.join(" - "),
        headerText: headerText,
        sections: counted.sections,
        heldItems: counted.heldItems,
        actionable: actionable,
        heldTotal: heldTotal,
        stale: stale,
        // "" when fine; otherwise the CLI's own error text, so the popup's stale banner says what
        // actually went wrong instead of a generic apology.
        staleReason: stale
            ? (typeof state.error === "string" && state.error !== "" ? state.error : "the last check failed")
            : "",
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
        formatStamp: formatStamp
    };
}
