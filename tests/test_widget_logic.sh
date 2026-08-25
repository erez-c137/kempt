#!/usr/bin/env bash
# The widget's tests. Two halves, because the widget is deliberately two halves:
#
#   1. plasmoid/contents/ui/logic.js is engine-agnostic JavaScript on purpose - the plasmoid loads
#      it with `import "logic.js" as Logic`, and this file loads the SAME file with node. Every
#      rule the panel shows a human (badge number, icon state, tooltip, popup sections) is pinned
#      here rather than in QML, where no test could reach it.
#   2. the QML around it is compile-checked against the system Qt 6 (see the bottom of the file).
#
# Both halves skip LOUDLY rather than failing when their tool is missing: neither node nor PySide6
# is a dependency of Kempt itself.
source "$(dirname "$0")/lib.sh"; sandbox
LOGIC="$REPO_ROOT/plasmoid/contents/ui/logic.js"

# Half 2, defined up here because the node half below can skip out early and this must run either
# way. There is no qmllint on this box (it ships in qt6-qtdeclarative-devel, which is not
# installed), but PySide6 is present and links against the SAME Qt 6 the desktop runs on.
# Compiling each .qml with QQmlComponent resolves every import and every property assignment -
# a typo'd property or a module that does not exist fails here instead of in somebody's panel.
# Nothing is instantiated, so this needs no Applet, no display and no plasmashell. It does NOT
# check layout, bindings at runtime or anything visual: that is the founder's visual gate.
qml_check() {
  if ! python3 -c 'import PySide6' >/dev/null 2>&1; then
    echo "ok: SKIPPED - PySide6 is absent, so the .qml files were NOT compile-checked in this run"
    return 0
  fi
  local out="$TESTTMP/qmlcheck.txt" want rc=0
  want="$(find "$REPO_ROOT/plasmoid" -name '*.qml' | wc -l)"
  # `|| rc=$?` is load-bearing: lib.sh sets errexit, so without it a failing compile kills this
  # function on the spot - before the count assertion and before the error dump below. The file
  # then exits non-zero having printed no FAIL line at all, and the diagnostics go with TESTTMP
  # when the trap removes it. A gate that fails invisibly is barely a gate.
  QT_QPA_PLATFORM=offscreen python3 - "$REPO_ROOT/plasmoid" > "$out" 2>&1 <<'PY' || rc=$?
import glob, os, sys
from PySide6.QtCore import QUrl
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlEngine, QQmlComponent

app = QGuiApplication(sys.argv[:1])
engine = QQmlEngine()
for p in ("/usr/lib64/qt6/qml", "/usr/lib/qt6/qml"):
    if os.path.isdir(p):
        engine.addImportPath(p)
rc = 0
for f in sorted(glob.glob(os.path.join(sys.argv[1], "**", "*.qml"), recursive=True)):
    comp = QQmlComponent(engine, QUrl.fromLocalFile(f))
    errs = comp.errors()
    name = os.path.relpath(f, sys.argv[1])
    if errs:
        rc = 1
        print(f"ERR {name}")
        for e in errs:
            print(f"      line {e.line()}:{e.column()}  {e.description()}")
    else:
        print(f"OK {name}")
sys.exit(rc)
PY
  # The count guards the vacuous pass: a probe that found no files would otherwise "succeed".
  assert_eq "$(grep -c '^OK ' "$out")" "$want" "every .qml in the package compiles against the system Qt 6"
  [[ $rc -eq 0 ]] || { echo "FAIL: QML compile errors"; sed 's/^/    /' "$out"; _fail=1; }
  [[ "$want" -gt 0 ]] || { echo "FAIL: no .qml files were checked at all"; _fail=1; }
}

# node is not a dependency of Kempt itself, so its absence must not fail the suite - but it must
# be LOUD, because a silent skip here means the widget's whole derivation layer went unverified.
if ! command -v node >/dev/null 2>&1; then
  echo "ok: SKIPPED - node is not installed, so logic.js was NOT verified in this run"
  echo "    (install nodejs and re-run: these are the only tests the widget's derivation layer has)"
  qml_check
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
# The cap is 999, not 99: a Fedora box left alone for a few weeks routinely has two or three
# hundred updates pending, so a 99 cap would be vague in the ORDINARY case - and an exactly right
# badge is the whole pitch. The tooltip and the popup header are never capped at all.
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:100,held_total:0,backends:{}},false).badgeText')" \
  "100" "a three-digit count - the common few-weeks-behind case - is spelled out exactly"
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:347,held_total:0,backends:{}},false).badgeText')" \
  "347" "...and so is a big one"
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:999,held_total:0,backends:{}},false).badgeText')" \
  "999" "999 is still an exact number"
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:1000,held_total:0,backends:{}},false).badgeText')" \
  "999+" "above 999 the badge caps"
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:1247,held_total:0,backends:{}},false).badgeText')" \
  "999+" "...however far above"
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:1247,held_total:0,backends:{}},false).tooltipMain')" \
  "1247 updates available" "...while the tooltip still gives the exact number"

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
assert_eq "$(js 'V("stale",false).tooltipSub')" "dnf check failed - last successful check: $ls_stale" \
  "the stale tooltip carries BOTH what went wrong and the last SUCCESSFUL check"
assert_eq "$(js 'V("stale",false).tooltipSub.indexOf(V("stale",false).staleReason) >= 0')" "true" \
  "...and the reason it carries is the CLI's own staleReason, verbatim"
assert_eq "$(js 'V("stale",false).lastSuccessText')" "$ls_stale" "lastSuccessText is the formatted last success"
assert_eq "$(js 'V("stale",false).staleReason')" "dnf check failed" "the stale reason is the CLI's own error text"
assert_eq "$(js 'V("never",false).tooltipSub.indexOf("last successful check: never") >= 0')" "true" \
  "a box that has never had a successful check says never, not Invalid Date"
assert_eq "$(js 'V("never",false).lastSuccessText')" "never" "...and lastSuccessText says never too"
assert_eq "$(js 'L.viewModel({schema:1,status:"stale",error:"",actionable:1,held_total:0,backends:{}},false).staleReason')" \
  "the last check failed" "a stale state with no error text still explains itself"
# Belt and braces on the same rule: stamps render to the minute, so a fixture whose two stamps
# fall in the same minute would let last_check pass for last_success. These two cannot.
assert_eq "$(js 'L.viewModel({schema:1,status:"stale",error:"x",actionable:1,held_total:0,last_check:"2026-08-24T23:59:00+03:00",last_success:"2020-01-01T10:30:00+03:00",backends:{}},false).tooltipSub')" \
  "x - last successful check: 2020-01-01 10:30" "the tooltip reads last_success, never last_check"

# --- stale is CALM: last-known contents, explained in the tooltip, never an alarm --------------
# A repo that flapped is not a broken machine. The panel keeps rendering whatever the last good
# check found; only a state we genuinely cannot read earns the warning treatment.
assert_eq "$(js 'V("stale",false).iconState')" "stale" "a failed check is its own state, not an error"
assert_eq "$(js 'V("stale",false).badgeVisible')" "true" "a stale state still shows its last known count"
assert_eq "$(js 'V("stale",false).cliError')" "" "the CLI answered, so there is no CLI error"
assert_eq "$(js 'V("stale",false).emptyStateText')" "" "...and there are rows to show, so no empty state"
# Calm-stale needs something to BE calm about. A box that once succeeded and now flaps keeps its
# last known "nothing pending"; the boundary below is what separates that from knowing nothing.
calm_empty='L.viewModel({schema:1,status:"stale",error:"repo flap",last_success:"2026-08-20T10:00:00+03:00",actionable:0,held_total:0,backends:{}},false)'
assert_eq "$(js "$calm_empty.iconState")" "stale" "a flap after a real success stays calm"
assert_eq "$(js "$calm_empty.emptyStateText")" "No updates in the last known state." \
  "...and says the count is the LAST KNOWN one"

# --- the other family: never succeeded, nothing known. NOT calm. -------------------------------
# This is what a box looks like when install.sh never ran: the check cannot run at all, so there
# is no count, no history and nothing to be reassuring about. Rendering "Up to date" here - which
# a purely status-driven mapping would - is a clean lie, and the most damaging one this widget
# could tell. It belongs with the errors: emblem, honest words, and the command that diagnoses it.
assert_eq "$(jq -r '[.status, (.last_success|tostring), (.actionable|tostring), (.backends.dnf.items|length|tostring)] | join(",")' "$FIXTURES/state-broken.json")" \
  "stale,null,0,0" "fixture guard: the broken-install capture really is stale, never-succeeded and empty"
assert_eq "$(js 'V("broken",false).iconState')" "error" "never succeeded and nothing known is an ERROR, not calm staleness"
assert_eq "$(js 'V("broken",false).headerText')" "Kempt cannot check for updates" "...the header says so plainly"
assert_eq "$(js 'V("broken",false).headerText.indexOf("Up to date")')" "-1" "...and never claims the box is up to date"
assert_eq "$(js 'V("broken",false).badgeVisible')" "false" "...it badges nothing"
assert_eq "$(js 'V("broken",false).emptyStateText.indexOf("root helper not installed") >= 0')" "true" \
  "...the popup shows the CLI's own diagnosis"
assert_eq "$(js 'V("broken",false).tooltipSub.indexOf("root helper not installed") >= 0')" "true" \
  "...so does the tooltip"
assert_eq "$(js 'V("broken",false).remedyCommand')" "kempt doctor" "...and it points at doctor"
assert_eq "$(js 'V("broken",false).staleReason.indexOf("root helper not installed") >= 0')" "true" \
  "...with staleReason still carrying the raw text for anyone who wants it"
# The boundary itself, from both sides: one known item is enough to make a stale state calm again,
# and a real last_success is enough on its own.
one_item='{dnf:{enabled:true,items:[{name:"curl",from:"1",to:"2",held:false}]}}'
assert_eq "$(js "L.viewModel({schema:1,status:\"stale\",error:\"x\",last_success:null,actionable:1,held_total:0,backends:$one_item},false).iconState")" \
  "stale" "knowing even one pending item makes a stale state calm again"
assert_eq "$(js 'L.viewModel({schema:1,status:"stale",error:"x",last_success:"2026-08-20T10:00:00+03:00",actionable:0,held_total:0,backends:{}},false).iconState')" \
  "stale" "and so does having ever succeeded"
assert_eq "$(js 'L.viewModel({schema:1,status:"stale",error:"x",last_success:"",actionable:0,held_total:0,backends:{}},false).iconState')" \
  "error" "an empty last_success counts as never, not as a success"

# --- a CLI we could not run at all: say what happened, and what to type ------------------------
# Distinct from the CLI reporting a problem (that arrives as staleReason). This is "kempt is not
# on PATH" / "it did not run" - the widget's own report, not the CLI's.
cli_err='L.viewModel(null,false,"kempt: command not found")'
assert_eq "$(js "$cli_err.iconState")" "error" "no state plus a failed CLI is an error, not merely unknown"
assert_eq "$(js "$cli_err.badgeVisible")" "false" "...and it badges nothing"
assert_eq "$(js "$cli_err.headerText")" "Kempt cannot check for updates" "the popup header names the problem"
assert_eq "$(js "$cli_err.emptyStateText")" "kempt: command not found" "the popup shows the CLI's own words"
assert_eq "$(js "$cli_err.tooltipSub")" "kempt: command not found" "...and so does the tooltip"
assert_eq "$(js "$cli_err.remedyCommand")" "kempt doctor" "...and points at the command that diagnoses it"
assert_eq "$(js 'L.viewModel(null,false,"").iconState')" "unknown" \
  "no state and no error is still just unknown - not every blank is a failure"
assert_eq "$(js 'L.viewModel(null,false,"").remedyCommand')" "" "...and unknown suggests nothing"
assert_eq "$(js 'L.viewModel(null,false,"line one\nline two").emptyStateText')" "line one" \
  "a multi-line stderr is reduced to its first line, not pasted into the panel whole"
# The CLI names `kempt doctor` itself when the root helpers are missing (lib/common.sh
# explain_helper_error). That text arrives in the state, so the remedy must be offered from there
# too - the CLI ran fine, it is the install that is broken.
# A box that HAS known counts and then loses its helpers: the counts stand, so this stays calm -
# but the remedy is still offered, because the CLI named it. (The other case, where the helpers
# were never there and nothing is known, is the error family tested further down.)
helper_missing='L.viewModel({schema:1,status:"stale",error:"dnf check failed: root helper not installed - run ./install.sh (see: kempt doctor)",last_success:"2026-08-20T10:00:00+03:00",actionable:1,held_total:0,backends:{dnf:{enabled:true,items:[{name:"curl",from:"1",to:"2",held:false}]}}},false)'
assert_eq "$(js "$helper_missing.iconState")" "stale" "a missing root helper stays calm while the counts still stand"
# ...and calm means QUIET. A "run kempt doctor" line under counts that are perfectly good is the
# exact noise calm-stale exists to avoid; the CLI's own text below still names doctor itself.
assert_eq "$(js "$helper_missing.remedyCommand")" "" "...offering no remedy line of its own"
assert_eq "$(js "$helper_missing.staleReason.indexOf(\"kempt doctor\") >= 0")" "true" \
  "...while still showing the CLI's own words, which name doctor"
assert_eq "$(js 'V("live",false).remedyCommand')" "" "a healthy box is told to run nothing"

# --- shellQuote: the widget's one injection surface --------------------------------------------
# Package names come out of the CLI's JSON and go into `kempt hold <backend>:<name>`, which the
# data engine hands to a shell. Everything state-derived is quoted; these pin the quoting itself,
# and the end-to-end proof through a real shell is further down.
assert_eq "$(js 'L.shellQuote("curl")')" "'curl'" "an ordinary name is wrapped in single quotes"
assert_eq "$(js 'L.shellQuote("evil; rm -rf ~")')" "'evil; rm -rf ~'" "a command separator is just text inside quotes"
assert_eq "$(js "L.shellQuote(\"it's\")")" "'it'\\''s'" "a single quote is closed, escaped and reopened"
bs='back\slash'
assert_eq "$(BS="$bs" js 'L.shellQuote(process.env.BS)')" "'$bs'" "a backslash needs no escaping inside single quotes"
assert_eq "$(js 'L.shellQuote("two\nlines")')" "$(printf "'two\nlines'")" "a newline stays inside the one word"
assert_eq "$(js 'L.shellQuote("")')" "''" "an empty string is still one argument"
assert_eq "$(js 'L.shellQuote(null)')" "''" "...and so is a missing one"
assert_eq "$(js 'L.shellQuote("$(whoami)")')" "'\$(whoami)'" "command substitution is inert inside single quotes"
assert_eq "$(js 'L.shellQuote("`id`")')" "'\`id\`'" "so are backticks"

# --- isTrue: the settings page must read a boolean the way the CLI writes one ------------------
# The page gets these back as the TEXT `kempt config get` printed. If the two disagreed about
# what counts as true, a user would switch something off and find it back on.
for t in true TRUE True 1 yes YES; do
  assert_eq "$(js "L.isTrue(\"$t\")")" "true" "isTrue accepts $t, like lib/common.sh's is_true"
done
for f in false FALSE 0 no "" "  " nonsense; do
  assert_eq "$(js "L.isTrue(\"$f\")")" "false" "isTrue rejects '$f'"
done
assert_eq "$(js 'L.isTrue(null)')" "false" "a missing value is not true"
assert_eq "$(js 'L.isTrue(true)')" "true" "an actual boolean survives"
assert_eq "$(js 'L.isTrue(" true ")')" "true" "surrounding whitespace does not change the answer"
# The real CLI is the reference, not my reading of it: same inputs, same verdicts.
source "$REPO_ROOT/lib/common.sh"
for t in true TRUE True 1 yes YES false FALSE 0 no nonsense; do
  cli=false; is_true "$t" && cli=true
  assert_eq "$(js "L.isTrue(\"$t\")")" "$cli" "isTrue agrees with the CLI's is_true about '$t'"
done

# --- effectiveSurfaceOf: what a run will ACTUALLY do, not what is merely stored ----------------
# cmd_run resolves the stored surface and then overrides it: with confirmation on, only a terminal
# can ask the question. A popup that trusted the stored value alone would open an in-widget log
# pane while a terminal window is what actually appeared.
assert_eq "$(js 'L.effectiveSurfaceOf("popup", true)')" "popup" "with confirmation off, the stored surface stands"
assert_eq "$(js 'L.effectiveSurfaceOf("popup", false)')" "terminal" "with confirmation on, popup collapses to terminal"
assert_eq "$(js 'L.effectiveSurfaceOf("background", false)')" "terminal" "...so does background"
assert_eq "$(js 'L.effectiveSurfaceOf("offline", false)')" "terminal" "...and offline"
assert_eq "$(js 'L.effectiveSurfaceOf("terminal", false)')" "terminal" "terminal is already terminal"
assert_eq "$(js 'L.effectiveSurfaceOf("nonsense", true)')" "terminal" "an unknown surface still falls back"
assert_eq "$(js 'L.effectiveSurfaceOf("popup", "false")')" "terminal" "the flag is read as the CLI writes it, as text"
assert_eq "$(js 'L.effectiveSurfaceOf("popup", "yes")')" "popup" "...including yes"
# The CLI is the reference: cmd_run does resolve_surface, then `is_true "$auto" || surface=terminal`.
for surf in terminal popup background offline nonsense; do
  for auto in true false; do
    want="$(bash -c "
      source '$REPO_ROOT/lib/common.sh'
      source /dev/stdin <<<\"\$(sed -n '/^resolve_surface/,/^}/p' '$REPO_ROOT/bin/kempt')\"
      s=\"\$(resolve_surface '$surf')\"; is_true '$auto' || s=terminal; printf '%s' \"\$s\"")"
    assert_eq "$(js "L.effectiveSurfaceOf(\"$surf\", \"$auto\")")" "$want" \
      "effectiveSurfaceOf agrees with cmd_run for surface=$surf auto_accept=$auto"
  done
done

# --- resolveSurface: unknown means terminal, exactly as bin/kempt decides ---------------------
for s in terminal popup background offline; do
  assert_eq "$(js "L.resolveSurface(\"$s\")")" "$s" "$s is a surface the CLI knows"
done
assert_eq "$(js 'L.resolveSurface("nonsense")')" "terminal" "an unknown surface falls back to terminal"
assert_eq "$(js 'L.resolveSurface("")')" "terminal" "so does an empty one"
assert_eq "$(js 'L.resolveSurface(null)')" "terminal" "and a missing one"
assert_eq "$(js 'L.resolveSurface(" POPUP ")')" "popup" "case and whitespace do not hide a real surface"
# Same reference check: the CLI's own resolve_surface is the authority.
for s in terminal popup background offline nonsense ""; do
  assert_eq "$(js "L.resolveSurface(\"$s\")")" "$(bash -c "source '$REPO_ROOT/lib/common.sh'; source /dev/stdin <<<\"\$(sed -n '/^resolve_surface/,/^}/p' '$REPO_ROOT/bin/kempt')\"; resolve_surface '$s'")" \
    "resolveSurface agrees with the CLI about '$s'"
done

# --- holdsOf: `kempt holds` prints raw backend:name lines -------------------------------------
assert_eq "$(js 'L.holdsOf("dnf:vim-common\nflatpak:org.gimp.GIMP").length')" "2" "one entry per line"
assert_eq "$(js 'L.holdsOf("dnf:vim-common")[0].backend')" "dnf" "the backend is the part before the colon"
assert_eq "$(js 'L.holdsOf("dnf:vim-common")[0].name')" "vim-common" "...and the name is the rest"
assert_eq "$(js 'L.holdsOf("dnf:vim-common")[0].id')" "dnf:vim-common" \
  "...with the whole line kept, because that is the argument unhold takes"
# Split at the FIRST colon, like cmd_hold's \${1%%:*}: a name containing one still round-trips.
assert_eq "$(js 'L.holdsOf("flatpak:org.x:weird")[0].name')" "org.x:weird" "a colon in the name survives"
assert_eq "$(js 'L.holdsOf("")[0]')" "undefined" "no holds, no entries"
assert_eq "$(js 'L.holdsOf("\n  \n").length')" "0" "blank lines are skipped"
assert_eq "$(js 'L.holdsOf("garbage-no-colon\ndnf:ok").length')" "1" "a line that is not a pair is skipped"
assert_eq "$(js 'L.holdsOf("dnf:").length')" "0" "so is a backend with no name"
assert_eq "$(js 'L.holdsOf(null).length')" "0" "a missing string is not an error"
# End to end against the real CLI: what `kempt holds` actually prints is what this parses.
holds_out="$(KEMPT_CONFIG_DIR="$TESTTMP/hcfg" KEMPT_STATE_DIR="$TESTTMP/hstate" bash -c "
  '$REPO_ROOT/bin/kempt' hold dnf:vim-common >/dev/null
  '$REPO_ROOT/bin/kempt' hold flatpak:org.gimp.GIMP >/dev/null
  '$REPO_ROOT/bin/kempt' holds")"
assert_eq "$(HOLDS="$holds_out" js 'L.holdsOf(process.env.HOLDS).map(function (h) { return h.id; })')" \
  '["dnf:vim-common","flatpak:org.gimp.GIMP"]' "holdsOf parses what the real `kempt holds` prints"

# --- lastLinesOf: the result line under the passwordless buttons -------------------------------
assert_eq "$(js 'L.lastLinesOf("one\ntwo\nthree", 1)')" "three" "the last line is the verdict"
assert_eq "$(js 'L.lastLinesOf("one\ntwo\nthree", 2)')" "two three" "a short tail joins with a space"
assert_eq "$(js 'L.lastLinesOf("only", 2)')" "only" "fewer lines than asked for is fine"
assert_eq "$(js 'L.lastLinesOf("a\n\n\nb\n\n", 2)')" "a b" "blank lines do not count towards the tail"
assert_eq "$(js 'L.lastLinesOf("", 2)')" "" "nothing said, nothing shown"
assert_eq "$(js 'L.lastLinesOf(null, 2)')" "" "and a missing string is not an error"

# --- firstLineOf ------------------------------------------------------------------------------
assert_eq "$(js 'L.firstLineOf("  hello  \nworld")')" "hello" "the first line comes back trimmed"
assert_eq "$(js 'L.firstLineOf("\n\n  real line\nmore")')" "real line" "leading blank lines are skipped"
assert_eq "$(js 'L.firstLineOf("")')" "" "empty text has no first line"
assert_eq "$(js 'L.firstLineOf("   \n  ")')" "" "neither does whitespace"
assert_eq "$(js 'L.firstLineOf(null)')" "" "nor a missing string"

# --- rows: the popup's flat model --------------------------------------------------------------
# A ListView over a flat model creates delegates lazily, so 1200 pending updates cost what six do.
# --- backend routing: the half of every hold command that decides WHICH package manager --------
# A dnf hardcode here is invisible in the rendered popup and catastrophic in the command: pinning
# a Flatpak app would run `kempt hold dnf:org.gimp.GIMP`, holding nothing and reporting success.
assert_eq "$(js 'V("live",false).sections[1].items[0].backend')" "flatpak" \
  "a row in the Apps group carries the flatpak backend, not dnf"
assert_eq "$(js 'V("live",false).sections.map(function (s) { return s.items[0].backend; })')" \
  '["dnf","flatpak"]' "each group's rows carry that group's own backend"
assert_eq "$(js 'V("live",false).rows.filter(function (r) { return r.kind === "item"; }).map(function (r) { return r.backend; }).filter(function (b, i, a) { return a.indexOf(b) === i; }).sort()')" \
  '["dnf","flatpak"]' "...and the flat model keeps both backends, not one repeated"
assert_eq "$(js 'V("held-only",false).heldItems.map(function (h) { return h.backend; }).filter(function (b, i, a) { return a.indexOf(b) === i; }).sort()')" \
  '["dnf","flatpak"]' "held rows keep both backends too - unpinning must undo the right hold"
assert_eq "$(js 'V("held-only",false).rows.filter(function (r) { return r.kind === "item" && r.name.indexOf("org.") === 0; })[0].backend')" \
  "flatpak" "a held Flatpak app is still a flatpak hold, not a dnf one"

assert_eq "$(js 'V("live",false).rows[0].kind')" "header" "the list starts with a section header"
assert_eq "$(js 'V("live",false).rows[0].title')" "System (dnf)" "...naming the first group"
assert_eq "$(js 'V("live",false).rows[1].kind')" "item" "the group's items follow it"
assert_eq "$(js 'V("live",false).rows.length')" "12" "10 items plus 2 group headers"
assert_eq "$(js 'V("live",false).rows.filter(function (r) { return r.kind === "header"; }).map(function (r) { return r.title; })')" \
  '["System (dnf)","Apps (flatpak)"]' "one header per non-empty group, in order"
assert_eq "$(js 'V("held-only",false).rows[0].title')" "Held" "a held-only box shows the Held group"
assert_eq "$(js 'V("held-only",false).rows.length')" "11" "...one header plus its ten rows"
assert_eq "$(js 'V("held-only",false).rows[1].held')" "true" "held rows are marked as held"
assert_eq "$(js 'L.viewModel(null,false).rows.length')" "0" "no data, no rows"
assert_eq "$(js 'V("flatpak-disabled",false).rows.filter(function (r) { return r.kind === "header"; }).length')" "1" \
  "a disabled backend contributes no header either"
# Held goes LAST, after everything actionable: the spec keeps held items visible but out of the way.
mixed='L.viewModel({schema:1,status:"ok",actionable:1,held_total:1,backends:{dnf:{enabled:true,items:[{name:"a",from:"1",to:"2",held:false},{name:"b",from:"1",to:"2",held:true}]}}},false)'
assert_eq "$(js "$mixed.rows.map(function (r) { return r.kind === \"header\" ? r.title : r.name; })")" \
  '["System (dnf)","a","Held","b"]' "held items sort below the actionable ones, under their own header"

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
# $NF, not -f2: the set size is a property of the box (a multilib pair here, three kernels
# elsewhere), and the rule under test is "the LAST one", not "the second one".
assert_eq "$(js 'V("live",false).sections[0].items.filter(i => i.name === "bash")[0].to')" \
  "$(awk -F, '{print $NF}' <<<"$bash_to")" "a multilib set is rendered the CLI's way in the popup row"
assert_eq "$(js 'V("live",false).sections[0].items.filter(i => i.name === "brandnew")[0].from')" \
  "?" "a package that is not installed yet keeps its ? on the from side"

# --- sections: grouping, the disabled backend, and forward compatibility ---
assert_eq "$(js 'V("live",false).sections.map(s => s.title)')" '["System (dnf)","Apps (flatpak)"]' \
  "pending updates group as System / Apps, dnf first"
assert_eq "$(js 'V("live",false).sections[0].items[0].backend')" "dnf" \
  "every row carries its backend, which is half of the hold/unhold argument"
# Row order is the CLI's, not something the widget re-sorts or reverses. The CLI hands items over
# sorted by name; a popup that showed them backwards would be a different list from `kempt check`.
assert_eq "$(js 'V("live",false).sections[0].items.map(function (i) { return i.name; })')" \
  "$(jq -c '[.backends.dnf.items[].name]' "$FIXTURES/state-live.json")" \
  "pending rows keep the CLI's own order"
assert_eq "$(js 'V("held-only",false).heldItems.map(function (i) { return i.name; }).slice(0,3)')" \
  "$(jq -c '[.backends.dnf.items[].name][0:3]' "$FIXTURES/state-held-only.json")" \
  "...and so do held rows"
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
# Expected string built with the CLI's own pipeline (bin/kempt: families are the prefix up to the
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
# Version skew between CLI and widget is NORMAL here, not exotic: install.sh symlinks the CLI into
# the checkout but COPIES the widget, so a `git pull` routinely leaves a new CLI talking to an old
# widget. A schema this build does not know must never be badged as if it were understood.
assert_eq "$(js 'L.viewModel({schema:2,status:"ok",actionable:5,held_total:0,backends:{}},false).iconState')" \
  "error" "a future schema is refused, not guessed at"
assert_eq "$(js 'L.viewModel({schema:2,status:"ok",actionable:5,held_total:0,backends:{}},false).badgeText')" \
  "" "...and it badges nothing at all"
assert_eq "$(js 'V("live",false).iconState')" "updates" "schema 1 is of course still read normally"
assert_eq "$(js 'L.viewModel({hello:"world"},false).badgeVisible')" "false" "...and it badges nothing"
assert_eq "$(js 'L.viewModel({hello:"world"},false).sections.length')" "0" "...and lists nothing"

# --- every branch returns the full view model shape: QML binds to these names, and an
# undefined property in a binding is a silent blank in the panel, not an error anyone sees.
keys='["actionable","badgeText","badgeVisible","cliError","emptyStateText","headerText","heldItems","heldTotal","iconState","lastSuccessText","remedyCommand","riskySummary","rows","sections","stale","staleReason","tooltipMain","tooltipSub"]'
for case in 'L.viewModel(null,false)' 'L.viewModel(null,true)' 'V("live",false)' 'V("live",true)' \
            'V("stale",false)' 'V("never",false)' 'V("held-only",false)' 'V("flatpak-disabled",false)' \
            'V("risky-heavy",false)' 'V("schema-v0",false)' 'V("empty",false)' 'V("garbage",false)' 'V("broken",false)' \
            'L.viewModel({hello:"world"},false)' 'L.viewModel(null,false,"boom")'; do
  assert_eq "$(js "Object.keys($case).sort()")" "$keys" "$case returns the whole view model"
done

# --- the injection proof, through a real shell -------------------------------------------------
# The data engine hands its command string to a shell, so quoting is the only thing between a
# package name and arbitrary code running as the user from inside plasmashell. Asserting the
# QUOTES look right proves nothing on its own; this runs the command the popup would build and
# checks what actually lands in argv.
cat > "$TESTTMP/argv-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$#" > "$TESTTMP/argc"
printf '%s\n' "\$@" > "$TESTTMP/argv"
STUB
chmod +x "$TESTTMP/argv-stub"
export HOSTILE="evil; touch $TESTTMP/PWNED"

# The canary FIRST. Without it a passing test below might only mean the attack never worked here.
sh -c "'$TESTTMP/argv-stub' dnf:$HOSTILE" >/dev/null 2>&1 || true
assert_exit 0 "canary: unquoted, the injected command really does run" -- test -e "$TESTTMP/PWNED"
rm -f "$TESTTMP/PWNED"

# ...and now the same name through shellQuote, exactly as main.qml builds a hold command.
q="$(js 'L.shellQuote("dnf:" + process.env.HOSTILE)')"
sh -c "'$TESTTMP/argv-stub' $q" >/dev/null 2>&1 || true
assert_exit 0 "quoted, the injected command does NOT run" -- test ! -e "$TESTTMP/PWNED"
assert_eq "$(cat "$TESTTMP/argc")" "1" "the hostile name arrives as exactly one argument"
assert_eq "$(cat "$TESTTMP/argv")" "dnf:$HOSTILE" "...carrying its characters verbatim, semicolon and all"

# The same, for the shapes a shell treats specially in other ways.
for evil in 'a$(touch '"$TESTTMP"'/PWNED)' 'a`touch '"$TESTTMP"'/PWNED`' 'a b c' "quote'inside" 'tilde~/x' '*'; do
  export EVIL="$evil"          # a separate export: `EVIL=x q=$(...)` is two assignments, and the
  q="$(js 'L.shellQuote(process.env.EVIL)')"   # command substitution would not see EVIL at all
  sh -c "'$TESTTMP/argv-stub' $q" >/dev/null 2>&1 || true
  assert_eq "$(cat "$TESTTMP/argc")" "1" "one argument for: $evil"
  assert_eq "$(cat "$TESTTMP/argv")" "$evil" "verbatim for: $evil"
done
unset EVIL
assert_exit 0 "none of those substitutions ran either" -- test ! -e "$TESTTMP/PWNED"
unset HOSTILE

# --- no shadow settings ------------------------------------------------------------------------
# The settings page is a front-end to `kempt config` and nothing else. A KConfig entry here would
# be a second copy of a setting the CLI also owns, and the two would drift the first time somebody
# typed `kempt config set` in a terminal. The plasmoid must therefore declare NO keys at all.
XML="$REPO_ROOT/plasmoid/contents/config/main.xml"
assert_eq "$(grep -c '<entry' "$XML")" "0" "the plasmoid declares no KConfig entries of its own"
assert_eq "$(grep -c 'cfg_' "$REPO_ROOT/plasmoid/contents/ui/configGeneral.qml")" "0" \
  "...and the settings page uses no cfg_ auto-binding, which would need them"
assert_exit 0 "the kcfg skeleton is still well-formed XML" -- python3 -c "
import xml.dom.minidom, sys; xml.dom.minidom.parse('$XML')"
# Every key the page writes is a key the CLI actually knows: a typo here would write a setting
# nothing ever reads, and the page would look like it worked.
for key in include_flatpak auto_accept surface refresh_interval_min; do
  grep -q "setIfChanged(\"$key\"" "$REPO_ROOT/plasmoid/contents/ui/configGeneral.qml" \
    && echo "ok: the page writes $key" || { echo "FAIL: the page never writes $key"; _fail=1; }
  assert_eq "$(kempt_default "$key" | head -c 1 | wc -c)" "1" "...and the CLI has a default for $key"
done

qml_check
finish
