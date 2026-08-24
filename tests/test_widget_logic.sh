#!/usr/bin/env bash
# plasmoid/contents/ui/logic.js is engine-agnostic JavaScript on purpose: the plasmoid loads it
# with `import "logic.js" as Logic`, and this file loads the SAME file with node. Everything the
# widget derives from the CLI's state JSON - the badge number, the icon state, the tooltip, the
# popup sections - is therefore pinned by a test that runs in the ordinary suite, on a box where
# no QML engine can be started at all.
source "$(dirname "$0")/lib.sh"; sandbox
LOGIC="$REPO_ROOT/plasmoid/contents/ui/logic.js"

# node is not a dependency of Upkeep itself, so its absence must not fail the suite - but it must
# be LOUD, because a silent skip here means the widget's whole derivation layer went unverified.
if ! command -v node >/dev/null 2>&1; then
  echo "ok: SKIPPED - node is not installed, so logic.js was NOT verified in this run"
  echo "    (install nodejs and re-run: these are the only tests the widget's derivation layer has)"
  finish
fi

# js <expression> -> its value on stdout (strings raw, everything else as JSON).
# In scope: L = logic.js's exports, S(name) = parseState of tests/fixtures/state-<name>.json,
# V(name, updating) = the view model derived from that fixture.
js() {
  node -e '
    const fs = require("fs");
    const L = require(process.argv[1]);
    const raw = (n) => fs.readFileSync(process.argv[2] + "/state-" + n + ".json", "utf8");
    const S = (n) => L.parseState(raw(n));
    const V = (n, u) => L.viewModel(S(n), !!u);
    const out = eval(process.argv[3]);
    process.stdout.write(out === undefined ? "undefined" : (typeof out === "string" ? out : JSON.stringify(out)));
  ' "$LOGIC" "$FIXTURES" "$1"
}

# --- parseState: the empty-stdout contract (architecture.md, state schema rule 1) ---
# "Empty stdout with exit 0 means no data, keep the last known state" - NEVER "zero updates".
# parseState answers null for everything unusable; main.qml keeps its previous state on null.
assert_eq "$(js 'S("empty")')" "null" "an empty state file parses to null, not to an empty state"
assert_eq "$(js 'L.parseState("   \n\t  ")')" "null" "whitespace-only stdout parses to null"
assert_eq "$(js 'S("garbage")')" "null" "a truncated/garbage state parses to null instead of throwing"
assert_eq "$(js 'L.parseState(undefined)')" "null" "a missing string parses to null (QML can hand us undefined)"
assert_eq "$(js 'L.parseState("42")')" "null" "valid JSON that is not an object is not a state"
assert_eq "$(js 'L.parseState("[1,2]")')" "null" "a JSON array is not a state either"
assert_eq "$(js 'S("live").schema')" "1" "a real captured check parses to schema 1"
assert_eq "$(js 'S("live").actionable')" "10" "...and carries the CLI's own actionable count"

# --- the unknown state: no data must never render as zero updates ---
assert_eq "$(js 'L.viewModel(null,false).iconState')" "unknown" "null state + not updating => unknown"
assert_eq "$(js 'L.viewModel(null,false).badgeText')" "" "unknown state shows NO badge text"
assert_eq "$(js 'L.viewModel(null,false).badgeVisible')" "false" "unknown state hides the badge"
assert_eq "$(js 'L.viewModel(null,false).tooltipSub.indexOf("no data yet") >= 0')" "true" "unknown tooltip says there is no data yet"
assert_eq "$(js 'L.viewModel(null,false).headerText.indexOf("0 update") >= 0')" "false" "unknown state never claims zero updates"
assert_eq "$(js 'L.viewModel(null,false).lastSuccessText')" "" "unknown state has no last-success text to show"

# --- updating wins over everything, and the pending count stays truthful while it runs ---
assert_eq "$(js 'L.viewModel(null,true).iconState')" "updating" "null state + updating => updating"
assert_eq "$(js 'V("live",true).iconState')" "updating" "updating overrides an updates-available state"
assert_eq "$(js 'V("live",true).badgeText')" "10" "the badge keeps the last known count while a run is in flight"
assert_eq "$(js 'V("live",true).headerText')" "Updating..." "the popup header says what is happening"

# --- the everyday case ---
assert_eq "$(js 'V("live",false).iconState')" "updates" "pending updates => updates"
assert_eq "$(js 'V("live",false).badgeText')" "10" "the badge is the CLI's actionable count, verbatim"
assert_eq "$(js 'V("live",false).badgeVisible')" "true" "...and it is shown"
assert_eq "$(js 'V("live",false).headerText')" "10 updates available" "header names the count"
assert_eq "$(js 'V("live",false).staleReason')" "" "a healthy check has no stale reason"
assert_eq "$(js 'V("live",false).riskySummary')" "" "an everyday transaction raises no offline recommendation"
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:1,held_total:0,backends:{}},false).headerText')" \
  "1 update available" "one update is singular"
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:0,held_total:0,backends:{}},false).iconState')" \
  "uptodate" "nothing pending => up to date"
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:0,held_total:0,backends:{}},false).badgeVisible')" \
  "false" "up to date shows no badge"

# --- holds: the spec's promise that a held-only box looks up to date but still says so ---
assert_eq "$(js 'V("held-only",false).iconState')" "uptodate" "held-only pending => the up-to-date icon"
assert_eq "$(js 'V("held-only",false).badgeVisible')" "false" "held items are not badged"
assert_eq "$(js 'V("held-only",false).tooltipSub.indexOf("10 held") >= 0')" "true" "...but the tooltip notes N held"
assert_eq "$(js 'V("held-only",false).heldItems.length')" "10" "every held item is listed for the Held section"
assert_eq "$(js 'V("held-only",false).sections.length')" "0" "a held-only state renders no pending sections"
assert_eq "$(js 'V("live",false).heldItems.length')" "0" "nothing held => an empty Held list"
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:0,held_total:2,backends:{}},false).headerText')" \
  "Up to date" "the header stays up to date when only held items are pending"

# --- stale: last known counts stay on the badge, the staleness goes in the tooltip ---
# Expected values are derived from the fixture, so a re-capture cannot silently drift the test;
# the guard assertion below keeps that derivation from going vacuous.
ls_stale="$(jq -r .last_success "$FIXTURES/state-stale.json" | sed -E 's/^(.{10})T(.{5}).*/\1 \2/')"
assert_eq "$(jq -r '.last_success != .last_check' "$FIXTURES/state-stale.json")" "true" \
  "fixture guard: the stale capture's last_success is EARLIER than its last_check"
assert_eq "$(js 'V("stale",false).iconState')" "stale" "a failed check => stale"
assert_eq "$(js 'V("stale",false).badgeText')" "10" "stale keeps the LAST KNOWN count on the badge"
assert_eq "$(js 'V("stale",false).tooltipSub')" "last successful check: $ls_stale" \
  "the stale tooltip carries the last SUCCESSFUL check, not the last attempt"
assert_eq "$(js 'V("stale",false).lastSuccessText')" "$ls_stale" "lastSuccessText is the formatted last success"
assert_eq "$(js 'V("stale",false).staleReason')" "dnf check failed" "the stale reason is the CLI's own error text"
assert_eq "$(js 'V("never",false).tooltipSub')" "last successful check: never" \
  "a box that has never had a successful check says never, not Invalid Date"
assert_eq "$(js 'V("never",false).lastSuccessText')" "never" "...and lastSuccessText says never too"
assert_eq "$(js 'L.viewModel({schema:1,status:"stale",error:"",actionable:1,held_total:0,backends:{}},false).staleReason')" \
  "the last check failed" "a stale state with no error text still explains itself"
# Belt and braces on the same rule: stamps render to the minute, so a fixture whose two stamps
# fall in the same minute would let last_check pass for last_success. These two cannot.
assert_eq "$(js 'L.viewModel({schema:1,status:"stale",error:"x",actionable:1,held_total:0,last_check:"2026-08-24T23:59:00+03:00",last_success:"2020-01-01T10:30:00+03:00",backends:{}},false).tooltipSub')" \
  "last successful check: 2020-01-01 10:30" "the tooltip reads last_success, never last_check"

# --- versions: the widget renders exactly what the CLI's summary renders (lib/common.sh
# `def newest(v): v | split(",") | last`), so a comma-joined multilib/installonly set can never
# make the popup and the terminal disagree.
assert_eq "$(js 'L.newestOf("a,b,c")')" "c" "a comma set renders its last element"
assert_eq "$(js 'L.newestOf("8.18.0-9.fc44")')" "8.18.0-9.fc44" "a plain version renders itself"
assert_eq "$(js 'L.newestOf("?")')" "?" "the not-installed marker survives"
assert_eq "$(js 'L.newestOf(null)')" "?" "a missing version renders as the not-installed marker"
assert_eq "$(js 'L.newestOf("")')" "?" "...and so does an empty one"
bash_to="$(jq -r '.backends.dnf.items[] | select(.name=="bash") | .to' "$FIXTURES/state-live.json")"
assert_eq "$(jq -r '.backends.dnf.items[] | select(.name=="bash") | .to | contains(",")' "$FIXTURES/state-live.json")" \
  "true" "fixture guard: the captured bash entry really is a comma-joined multilib set"
assert_eq "$(js 'V("live",false).sections[0].items.filter(i => i.name === "bash")[0].to')" \
  "$(cut -d, -f2 <<<"$bash_to")" "a multilib set is rendered the CLI's way in the popup row"
assert_eq "$(js 'V("live",false).sections[0].items.filter(i => i.name === "brandnew")[0].from')" \
  "?" "a package that is not installed yet keeps its ? on the from side"

# --- sections: grouping, the disabled backend, and forward compatibility ---
assert_eq "$(js 'V("live",false).sections.map(s => s.title)')" '["System (dnf)","Apps (flatpak)"]' \
  "pending updates group as System / Apps, dnf first"
assert_eq "$(js 'V("live",false).sections[0].items[0].backend')" "dnf" \
  "every row carries its backend, which is half of the hold/unhold argument"
assert_eq "$(js 'V("flatpak-disabled",false).sections.map(s => s.title)')" '["System (dnf)"]' \
  "a disabled backend renders no section at all, not an empty one"
assert_eq "$(js 'V("flatpak-disabled",false).badgeText')" "7" "a disabled backend contributes nothing to the badge"
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:0,held_total:1,backends:{flatpak:{enabled:false,items:[{name:"x",from:"1",to:"2",held:true}]}}},false).heldItems.length')" \
  "0" "a disabled backend contributes no held items either"
# The captured fixture cannot tell "skipped because disabled" from "skipped because empty" - the
# CLI empties a disabled backend's items. Only leftover items prove the enabled flag is honoured.
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:0,held_total:0,backends:{flatpak:{enabled:false,items:[{name:"x",from:"1",to:"2",held:false}]}}},false).sections.length')" \
  "0" "a disabled backend with leftover items STILL renders no section"
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:1,held_total:0,backends:{apt:{enabled:true,items:[{name:"x",from:"1",to:"2",held:false}]}}},false).sections.map(s => s.title)')" \
  '["apt"]' "a future backend key gets its own section instead of being dropped (architecture: readers ignore what they do not know)"
assert_eq "$(js 'V("held-only",false).heldItems[0].backend')" "dnf" \
  "held rows carry their backend too (the unhold argument)"

# --- risky transaction: the widget's summary must match what the CLI itself says ---
# Expected string built with the CLI's own pipeline (bin/upkeep: families are the prefix up to the
# first - or ., sort -u, first four, then ", ...").
risky_names="$(jq -r '.risky_pending[]' "$FIXTURES/state-risky-heavy.json")"
n_risky="$(grep -c '' <<<"$risky_names")"
fams="$(sed 's/[-.].*//' <<<"$risky_names" | sort -u)"
n_fams="$(grep -c '' <<<"$fams")"
shown="$(head -4 <<<"$fams" | paste -sd, - | sed 's/,/, /g')"
more=""; if (( n_fams > 4 )); then more=", ..."; fi
expect_risky="$n_risky session-critical pending ($shown$more)"
assert_eq "$n_risky" "20" "fixture guard: the risky capture really carries 20 session-critical names"
assert_eq "$(js 'V("risky-heavy",false).riskySummary')" "$expect_risky" \
  "the offline recommendation names the count and the first four families, exactly like the CLI"
assert_eq "$(js 'V("schema-v0",false).riskySummary')" "" \
  "a state written before risky_pending existed derives no recommendation"
assert_eq "$(js 'V("schema-v0",false).badgeText')" "10" \
  "...and the missing additive key does not break anything else (schema-1 readers tolerate absence)"

# --- familiesOf: the shared derivation ---
assert_eq "$(js 'L.familiesOf(["kernel-core","kernel-modules","kernel.x86_64"],0).shown')" '["kernel"]' \
  "a family is the name up to the first - or ., and repeats collapse"
assert_eq "$(js 'L.familiesOf(["zsh","alsa"],0).shown')" '["alsa","zsh"]' "families come out sorted, like sort -u"
assert_eq "$(js 'L.familiesOf(["e","d","c","b","a"],4).shown')" '["a","b","c","d"]' "max caps the list"
assert_eq "$(js 'L.familiesOf(["e","d","c","b","a"],4).total')" "5" "...and total still counts them all"
assert_eq "$(js 'L.familiesOf(["e","d","c","b","a"],0).shown.length')" "5" "max 0 means no cap"
assert_eq "$(js 'L.familiesOf([],4).total')" "0" "no names, no families"
assert_eq "$(js 'L.familiesOf(undefined,4).total')" "0" "a missing list is not an error"

# --- timestamps: never show the user "Invalid Date" ---
assert_eq "$(js 'L.formatStamp("2026-08-24T22:11:45+03:00")')" "2026-08-24 22:11" "an ISO stamp renders short"
assert_eq "$(js 'L.formatStamp(null)')" "never" "a null last_success reads as never"
assert_eq "$(js 'L.formatStamp("")')" "never" "so does an empty one"
assert_eq "$(js 'L.formatStamp("not a date")')" "not a date" "an unparseable stamp is shown verbatim, never as Invalid Date"
assert_eq "$(js 'L.formatStamp("2020-01-01T00:00:00+00:00\n2021-01-01T00:00:00+00:00")')" "2020-01-01 00:00" \
  "a multi-document state (the recorded corruption) cannot leak a newline into the tooltip"
assert_eq "$(js 'L.formatStamp("junk\nmore junk").indexOf("\n") >= 0')" "false" \
  "...and the verbatim fallback stays single-line too"

# --- a state object that is not schema v1: say so, never invent a count ---
assert_eq "$(js 'L.viewModel({hello:"world"},false).iconState')" "error" "an unrecognisable state object => error"
assert_eq "$(js 'L.viewModel({hello:"world"},false).badgeVisible')" "false" "...and it badges nothing"
assert_eq "$(js 'L.viewModel({hello:"world"},false).sections.length')" "0" "...and lists nothing"

# --- every branch returns the full view model shape: QML binds to these names, and an
# undefined property in a binding is a silent blank in the panel, not an error anyone sees.
keys='["actionable","badgeText","badgeVisible","headerText","heldItems","heldTotal","iconState","lastSuccessText","riskySummary","sections","stale","staleReason","tooltipMain","tooltipSub"]'
for case in 'L.viewModel(null,false)' 'L.viewModel(null,true)' 'V("live",false)' 'V("live",true)' \
            'V("stale",false)' 'V("never",false)' 'V("held-only",false)' 'V("flatpak-disabled",false)' \
            'V("risky-heavy",false)' 'V("schema-v0",false)' 'V("empty",false)' 'V("garbage",false)' \
            'L.viewModel({hello:"world"},false)'; do
  assert_eq "$(js "Object.keys($case).sort()")" "$keys" "$case returns the whole view model"
done
finish
