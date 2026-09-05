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

# --- the download figure: what "Update Now" is about to cost ------------------------------------
# "~", never "up to". The estimate is wrong in BOTH directions - dnf pulls in dependencies
# `--upgrades` never listed, flatpak transfers ostree deltas far smaller than the published size,
# and a transaction already staged offline is counted although it is on disk - so a word that
# implies a ceiling would be a false promise.
assert_eq "$(js 'L.formatDownload(140000000)')" "~140 MB" "a round figure loses its pointless decimal"
assert_eq "$(js 'L.formatDownload(1400000000)')" "~1.4 GB" "GB keeps the one decimal that means something"
assert_eq "$(js 'L.formatDownload(4765890)')" "~4.8 MB" "MB rounds to one decimal"
# SI, matching what both package managers report. 1 MB is 1000000 bytes, not 1048576: a MiB-based
# divisor would under-report every figure by 4.8% and disagree with dnf's own output.
assert_eq "$(js 'L.formatDownload(1000000)')" "~1 MB" "a megabyte is 1000000 bytes"
# Under a megabyte, say so in words. Nobody decides anything differently between 300 kB and
# 800 kB, and a precise-looking small number invites trust the estimate has not earned.
assert_eq "$(js 'L.formatDownload(999999)')" "< 1 MB" "just under a megabyte reads as < 1 MB"
assert_eq "$(js 'L.formatDownload(1)')" "< 1 MB" "and so does one byte"
# 999999999 rounds to 1000.0 MB, which is a gigabyte spelled the long way.
assert_eq "$(js 'L.formatDownload(999999999)')" "~1 GB" "the MB/GB boundary does not print 1000 MB"
# Absent is NOT zero, and every one of these renders nothing at all: no "unknown", no "0 MB", no
# dash. Same way the surfaces already degrade for reboot_needed.
assert_eq "$(js 'L.formatDownload(0)')" "" "zero bytes says nothing"
assert_eq "$(js 'L.formatDownload(undefined)')" "" "an absent key says nothing"
assert_eq "$(js 'L.formatDownload(null)')" "" "a null says nothing"
assert_eq "$(js 'L.formatDownload(-1)')" "" "a negative says nothing"
# The state file is JSON from another program, and a schema-1 reader has to tolerate a key of the
# wrong type. Tolerating it means ignoring it, never coercing it into a number.
assert_eq "$(js 'L.formatDownload("140000000")')" "" "a string is not a byte count"
assert_eq "$(js 'L.formatDownload(NaN)')" "" "NaN is not a byte count"
assert_eq "$(js 'L.formatDownload(Infinity)')" "" "neither is infinity"

# Where a person actually reads it: beside Update Now, and in the tooltip.
dl_state='{schema:1,status:"ok",actionable:3,held_total:0,last_check:"2026-08-24T23:59:00+03:00",last_success:"2026-08-24T23:59:00+03:00",backends:{},download_bytes:140000000}'
assert_eq "$(js "L.viewModel($dl_state,false).footerText.indexOf(\"~140 MB\") >= 0")" "true" \
  "the footer beside Update Now says what it will cost"
assert_eq "$(js "L.viewModel($dl_state,false).tooltipSub.indexOf(\"~140 MB to download\") >= 0")" "true" \
  "the tooltip spells out what the figure means"
assert_eq "$(js "L.viewModel($dl_state,false).downloadText")" "~140 MB" "the vm publishes the words once"
# Nothing actionable, nothing to download: on an up-to-date box the figure would be describing
# bytes no run is going to fetch, and next to a held-only list it would be describing a run the
# button will not offer.
noact='{schema:1,status:"ok",actionable:0,held_total:2,last_check:"2026-08-24T23:59:00+03:00",last_success:"2026-08-24T23:59:00+03:00",backends:{},download_bytes:140000000}'
assert_eq "$(js "L.viewModel($noact,false).footerText.indexOf(\"MB\") >= 0")" "false" \
  "no actionable updates, no figure in the footer"
assert_eq "$(js "L.viewModel($noact,false).tooltipSub.indexOf(\"download\") >= 0")" "false" \
  "...and none in the tooltip"
# A state written before this feature existed has no such key, and must render exactly as it did.
nokey='{schema:1,status:"ok",actionable:3,held_total:0,last_check:"2026-08-24T23:59:00+03:00",last_success:"2026-08-24T23:59:00+03:00",backends:{}}'
assert_eq "$(js "L.viewModel($nokey,false).downloadText")" "" "a state with no download_bytes shows nothing"
assert_eq "$(js "L.viewModel($nokey,false).footerText")" "$(js "L.viewModel($nokey,false).footerText")" \
  "...and its footer is unchanged"
# Every captured fixture predates the field, so this pins the no-regression claim to real files.
assert_eq "$(js 'V("live",false).downloadText')" "" "the captured live state renders no figure"
assert_eq "$(js 'V("held-only",false).downloadText')" "" "nor does the held-only one"

# --- updating wins over everything, and the pending count stays truthful while it runs ---
assert_eq "$(js 'L.viewModel(null,true).iconState')" "updating" "null state + updating => updating"
assert_eq "$(js 'V("live",true).iconState')" "updating" "updating overrides an updates-available state"
assert_eq "$(js 'V("live",true).badgeText')" "10" "the badge keeps the last known count while a run is in flight"
assert_eq "$(js 'V("live",true).headerText')" "Updating…" \
  "the popup header says what is happening, with a real ellipsis"

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
# ...offset included, because that is what formatStamp renders now: the absolute stamp is the
# exact truth under a relative line, and a wall-clock reading with no timezone can disagree with
# that line by hours.
ls_stale="$(jq -r .last_success "$FIXTURES/state-stale.json" \
  | sed -E 's/^(.{10})T(.{5}).*([+-][0-9]{2}):?([0-9]{2})$/\1 \2 \3:\4/')"
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
  "x - last successful check: 2020-01-01 10:30 +03:00" "the tooltip reads last_success, never last_check"

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

# --- the empty state: one sentence, said once ---------------------------------------------------
# No full stop. KDE's own placeholders do not carry one ("No paired devices" in KDE Connect,
# "No Vaults have been set up" in Vault), and hig-review.md P5 names the trailing dot as one of the
# tells that a widget was not written by KDE.
clean='L.viewModel({schema:1,status:"ok",actionable:0,held_total:0,backends:{}},false)'
assert_eq "$(js "$clean.emptyStateText")" "Everything is up to date" \
  "an up-to-date box says so in the placeholder, with no full stop"
assert_eq "$(js "$clean.emptyStateText")" "$(js 'L.COPY.everythingUpToDate')" \
  "...in the copy table's own words, not a second copy of them"
# The popup must never say the same thing twice in the same breath: the header already carries
# "Up to date", so the placeholder underneath has to be a DIFFERENT sentence (plan P3, "never both
# at once with the same words").
assert_eq "$(js "$clean.headerText === $clean.emptyStateText")" "false" \
  "the header and the placeholder never say the identical words"
assert_eq "$(js "$clean.headerText")" "Up to date" "...the header being the short one"
# A held-only box is the case where the placeholder would be an outright lie by omission: there IS
# something pending, it is just held. So the placeholder stays away and the Held group carries the
# truth instead. (This already fell out of nothingKnown; pinned here because nothing pinned it.)
assert_eq "$(js 'V("held-only",false).emptyStateText')" "" \
  "a held-only box shows no up-to-date placeholder - the Held group is the truth there"
assert_eq "$(js 'V("held-only",false).rows.length > 0')" "true" \
  "...and it has rows to show instead"

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

# --- the engine is not installed at all: the store-first first run ------------------------------
# A widget installed from the KDE Store arrives with no CLI behind it. The check then runs through
# `sh -c` against nothing, which answers rc 127, and the widget used to report the shell's own
# sentence - `sh: line 1: kempt: command not found` - over a "run kempt doctor" line that cannot
# work, because kempt is exactly what is missing. That is the first impression every store-first
# user gets. It is a SETUP STEP rather than a failure, and this is the view model saying so.
eng='L.viewModel(null,false,"",{engineMissing:true})'
assert_eq "$(js "$eng.engineMissingMessage")" \
  "$(js 'L.COPY.engineMissing + "\n" + L.COPY.engineMissingInstall')" \
  "the message is its own field: what is true, then what to type"
assert_eq "$(js "$eng.engineMissingMessage.indexOf(\"\\n\") > 0")" "true" "...on two lines"
assert_eq "$(js "$eng.iconState")" "unknown" \
  "a box that has not been set up yet is unknown, never error: nothing is broken"
assert_eq "$(js "$eng.badgeVisible")" "false" "...and it badges nothing"
assert_eq "$(js "$eng.headerText")" "Kempt's engine is not installed" "the header names what is missing"
assert_eq "$(js "$eng.headerText.indexOf(\"sh:\")")" "-1" "...and never quotes the shell at the user"
assert_eq "$(js "$eng.tooltipSub")" "$(js 'L.COPY.engineMissing')" \
  "the tooltip says the same thing, in the copy table's words"
assert_eq "$(js "$eng.tooltipSub.indexOf(\"command not found\")")" "-1" "...and quotes no shell either"
assert_eq "$(js "$eng.remedyCommand")" "" \
  "nothing is offered to type: kempt is the thing that is missing, so kempt doctor cannot run"
assert_eq "$(js "$eng.emptyStateText")" "" \
  "...and the placeholder stands down, because the message carries the whole answer"
# The two commands a Fedora user has to type, complete and verbatim. A half-quoted command line is
# worse than no command line: it fails in a way the reader has to debug.
assert_eq "$(js 'L.COPY.engineMissingInstall.indexOf("sudo dnf copr enable erez-c137/kempt") >= 0')" "true" \
  "the install line carries the copr command in full"
assert_eq "$(js 'L.COPY.engineMissingInstall.indexOf("sudo dnf install kempt") >= 0')" "true" \
  "...and the install command in full"
assert_eq "$(js 'L.COPY.engineMissingInstall.indexOf("github.com/erez-c137/kempt") >= 0')" "true" \
  "...and where everybody who is not on Fedora goes"
# The pasteable form behind the Copy Commands button: ONE line, chained with &&, so one paste in
# one terminal does the whole install. Pinned verbatim - a clipboard payload that fails somewhere
# is worse than retyping - and drift-guarded against the display string: both must name the same
# two commands, or the button copies something other than what the message shows.
assert_eq "$(js "$eng.engineMissingCopyText")" \
  "sudo dnf copr enable erez-c137/kempt && sudo dnf install kempt" \
  "the copy payload is the two commands, chained, verbatim"
assert_eq "$(js 'L.viewModel(null,false,"",{}).engineMissingCopyText')" "" \
  "no missing engine, nothing to copy"
assert_eq "$(js "$eng.engineMissingCopyText.split(\" && \").every(function (c) { return L.COPY.engineMissingInstall.indexOf(c) >= 0; })")" \
  "true" "every command the button copies is a command the message shows"
# Absent is not true: every existing caller passes no such option, and nothing changes for them.
assert_eq "$(js 'L.viewModel(null,false,"",{}).engineMissingMessage')" "" "an unstated option says nothing"
assert_eq "$(js 'L.viewModel(null,false,"").engineMissingMessage')" "" \
  "...and so does no options object at all"
assert_eq "$(js 'L.viewModel(null,false,"",{engineMissing:"true"}).engineMissingMessage')" "" \
  "...and only a real boolean turns it on: this message replaces the whole popup body"
assert_eq "$(js 'L.viewModel(null,false,"",{}).emptyStateText')" \
  "No update data yet. The first check has not finished." \
  "...leaving the ordinary first-load placeholder exactly as it was"
assert_eq "$(js 'V("live",false).engineMissingMessage')" "" "a box whose engine answers says nothing about one"

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
  '["dnf:vim-common","flatpak:org.gimp.GIMP"]' "holdsOf parses what the real kempt holds prints"

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

# --- riskyMessageOf: what a session-critical transaction is actually told to DO -----------------
# riskySummaryOf answers "how much of this is risky" and is unchanged (its assertions are above).
# This answers the next question, which is the one a person has: what do I do about it? A kernel
# in the set has one honest answer, and it is not "stage it offline" - it is that the running
# kernel stays running until you restart.
K='["kernel-core","kernel-modules"]'
KN='["kernel-core","akmod-nvidia"]'
assert_eq "$(js "L.riskyMessageOf($K)")" "This includes a kernel update. Restart when it finishes." \
  "a kernel in the set names the kernel"
assert_eq "$(js "L.riskyMessageOf($K)")" "$(js 'L.COPY.kernelRestart')" "...in the copy table's words"
assert_eq "$(js "L.riskyMessageOf($KN)")" \
  "This includes a kernel update and the NVIDIA driver. Restart when it finishes." \
  "a kernel plus the NVIDIA driver names both"
assert_eq "$(js "L.riskyMessageOf($KN)")" "$(js 'L.COPY.kernelNvidiaRestart')" "...in the copy table's words too"
# The two tests are shaped DIFFERENTLY on purpose, and this is what pins the difference.
# "kernel" is a FAMILY test: kernel-core, kernel-modules and kernel.x86_64 are one decision, which
# is precisely what familiesOf already exists to collapse (name up to the first - or .).
assert_eq "$(js 'L.riskyMessageOf(["kernel.x86_64"])')" "$(js 'L.COPY.kernelRestart')" \
  "an arch-suffixed kernel is the same family, so the same message"
assert_eq "$(js 'L.riskyMessageOf(["kernelcare"]).indexOf("kernel update")')" "-1" \
  "...while a package that merely STARTS with kernel is a different family and not a kernel update"
# "nvidia" is a SUBSTRING test, because the driver arrives under families that have nothing in
# common: akmod-nvidia is the "akmod" family, xorg-x11-drv-nvidia is "xorg", nvidia-settings is
# "nvidia". A family test would catch one of the three and miss the two that matter most.
for n in akmod-nvidia xorg-x11-drv-nvidia nvidia-settings NVIDIA-settings kmod-nvidia-open; do
  assert_eq "$(js "L.riskyMessageOf([\"kernel-core\",\"$n\"])")" "$(js 'L.COPY.kernelNvidiaRestart')" \
    "$n is the NVIDIA driver whatever family its name falls into"
done
# NVIDIA on its own is not a kernel update, and the message must not claim one. It falls back to
# the count-and-families phrase, which is what the popup showed before this existed.
assert_eq "$(js 'L.riskyMessageOf(["akmod-nvidia"])')" "1 session-critical pending (akmod)" \
  "the driver without a kernel gets the ordinary summary, not a kernel sentence"
assert_eq "$(js 'L.riskyMessageOf(["glibc","dbus"])')" "2 session-critical pending (dbus, glibc)" \
  "a risky set with no kernel in it keeps the summary phrase"
assert_eq "$(js 'L.riskyMessageOf([])')" "" "no risky set, no message"
assert_eq "$(js 'L.riskyMessageOf(undefined)')" "" "...and a missing one is not an error"
assert_eq "$(js 'L.riskyMessageOf(null)')" "" "...nor a null one"
assert_eq "$(js 'L.riskyMessageOf("kernel-core")')" "" "a string is not a list of names"

# The kernel lookup is UNCAPPED, and these are the assertions that keep it that way. Handing it
# RISKY_FAMILIES_SHOWN - the tidy-looking edit, since four is what the summary phrase shows -
# silently drops the kernel sentence whenever four families sort alphabetically before "kernel",
# which on a Fedora transaction is ordinary rather than exotic. Every other riskyMessageOf
# assertion here uses a one or two name set, so the cap would never bite in any of them, and even
# the captured risky-heavy fixture misses it by luck (its kernel sorts third). The two sets below
# put kernel FIFTH on purpose. This is the most safety-relevant sentence the popup has: the one
# telling somebody the kernel they are running is about to be replaced.
DEEP_K='["alsa-lib","atk","bash","dbus-broker","kernel-core","kernel-modules"]'
DEEP_KN='["akmod-nvidia-open","alsa-lib","atk","bash","kernel-core","kernel-modules"]'
assert_eq "$(js "L.familiesOf($DEEP_K, 0).shown.indexOf(\"kernel\")")" "4" \
  "set guard: kernel really is the FIFTH family here, past any cap of four"
assert_eq "$(js "L.riskyMessageOf($DEEP_K)")" "$(js 'L.COPY.kernelRestart')" \
  "a kernel that sorts fifth is still a kernel update"
assert_eq "$(js "L.familiesOf($DEEP_KN, 0).shown.indexOf(\"kernel\")")" "4" \
  "set guard: fifth here too, with the driver in the set"
assert_eq "$(js "L.riskyMessageOf($DEEP_KN)")" "$(js 'L.COPY.kernelNvidiaRestart')" \
  "...and the driver sentence survives the same sort order"


# --- timestamps: never show the user "Invalid Date" ---
# The OFFSET rides along, and that is not decoration. This stamp is the exact truth under a
# relative line ("Checked 4 min ago"), and people hover it precisely to compare the two. Rendered
# without its offset it is a wall-clock reading with no timezone, so a state written in one zone
# and read in another disagrees with the line above it by hours and neither number says why.
assert_eq "$(js 'L.formatStamp("2026-08-24T22:11:45+03:00")')" "2026-08-24 22:11 +03:00" \
  "an ISO stamp renders short, offset included"
assert_eq "$(js 'L.formatStamp("2026-08-24T22:11:45Z")')" "2026-08-24 22:11 +00:00" \
  "Z is an offset too, and renders in the same shape as every other one"
assert_eq "$(js 'L.formatStamp("2026-08-24T22:11:45+0530")')" "2026-08-24 22:11 +05:30" \
  "an offset written without its colon is still that offset"
assert_eq "$(js 'L.formatStamp("2026-08-24T22:11:45")')" "2026-08-24 22:11" \
  "...and a stamp with no offset gains nothing it did not say"
assert_eq "$(js 'L.formatStamp(null)')" "never" "a null last_success reads as never"
assert_eq "$(js 'L.formatStamp("")')" "never" "so does an empty one"
assert_eq "$(js 'L.formatStamp("not a date")')" "not a date" "an unparseable stamp is shown verbatim, never as Invalid Date"
assert_eq "$(js 'L.formatStamp("2020-01-01T00:00:00+00:00\n2021-01-01T00:00:00+00:00")')" "2020-01-01 00:00 +00:00" \
  "a multi-document state (the recorded corruption) cannot leak a newline into the tooltip"
assert_eq "$(js 'L.formatStamp("junk\nmore junk").indexOf("\n") >= 0')" "false" \
  "...and the verbatim fallback stays single-line too"

# --- relativeTime: "4 min ago", and the absolute stamp whenever it cannot be sure ---------------
# The popup's status line. Same defensive shape as formatStamp and for the same reasons: no Date
# PARSING anywhere (Date.UTC is pure arithmetic, with no locale and no local timezone in it), so
# it cannot print "Invalid Date", cannot shift a stamp into another timezone, and survives the
# recorded corruption where two state documents arrive newline-joined.
#
# The clock is passed in from the test, not read: `now` is an argument precisely so every bucket
# boundary below is an exact assertion rather than a race. T is 2026-08-26T12:00:00+03:00 as UTC
# milliseconds, and the stamps are written with the offsets a real state file carries.
T='Date.UTC(2026,7,26,9,0,0)'
ISO='"2026-08-26T12:00:00+03:00"'
STAMP="2026-08-26 12:00 +03:00"
MIN=60000; HOUR=3600000; DAY=86400000
assert_eq "$(js "L.relativeTime($ISO, $T)")" "just now" "the moment it happened is just now"
assert_eq "$(js "L.relativeTime($ISO, $T + $MIN - 1)")" "just now" "...right up to the last millisecond under a minute"
assert_eq "$(js "L.relativeTime($ISO, $T + $MIN)")" "1 min ago" "a minute exactly is 1 min ago, singular"
assert_eq "$(js "L.relativeTime($ISO, $T + 2 * $MIN - 1)")" "1 min ago" "...and stays singular until two"
assert_eq "$(js "L.relativeTime($ISO, $T + 2 * $MIN)")" "2 min ago" "two minutes is plural"
assert_eq "$(js "L.relativeTime($ISO, $T + 4 * $MIN + 30000)")" "4 min ago" "minutes round DOWN, never up"
assert_eq "$(js "L.relativeTime($ISO, $T + $HOUR - 1)")" "59 min ago" "the last minute before the hour is still minutes"
assert_eq "$(js "L.relativeTime($ISO, $T + $HOUR)")" "1 hour ago" "an hour exactly is 1 hour ago"
assert_eq "$(js "L.relativeTime($ISO, $T + 2 * $HOUR - 1)")" "1 hour ago" "...singular until two"
assert_eq "$(js "L.relativeTime($ISO, $T + 2 * $HOUR)")" "2 hours ago" "two hours is plural"
assert_eq "$(js "L.relativeTime($ISO, $T + $DAY - 1)")" "23 hours ago" "the last hour before a day is still hours"
assert_eq "$(js "L.relativeTime($ISO, $T + $DAY)")" "1 day ago" "a day exactly is 1 day ago"
assert_eq "$(js "L.relativeTime($ISO, $T + 2 * $DAY - 1)")" "1 day ago" "...singular until two"
assert_eq "$(js "L.relativeTime($ISO, $T + 2 * $DAY)")" "2 days ago" "two days is plural"
# A week is the last age a count of days still answers "when?" usefully. Past it the date itself
# is more use than the arithmetic, so it hands back to the absolute stamp.
assert_eq "$(js "L.relativeTime($ISO, $T + 7 * $DAY)")" "7 days ago" "seven days is the last relative answer"
assert_eq "$(js "L.relativeTime($ISO, $T + 8 * $DAY)")" "$STAMP" "beyond that, the absolute stamp"
assert_eq "$(js "L.relativeTime($ISO, $T + 400 * $DAY)")" "$STAMP" "...however far beyond"

# The offsets a real stamp can carry. now_iso writes +03:00 here, but a box in UTC writes Z and
# `date -Iseconds` on some systems writes +0300 with no colon, so all three are parsed - and the
# arithmetic must actually SUBTRACT the offset rather than ignore it, which is what the last two
# assertions prove (the same wall-clock time in three zones is three different instants).
assert_eq "$(js "L.relativeTime(\"2026-08-26T09:00:00Z\", $T)")" "just now" "a Z stamp is UTC"
assert_eq "$(js "L.relativeTime(\"2026-08-26T12:00:00+0300\", $T)")" "just now" "an offset without a colon parses too"
assert_eq "$(js "L.relativeTime(\"2026-08-26T05:00:00-04:00\", $T)")" "just now" "...and a negative offset"
assert_eq "$(js "L.relativeTime(\"2026-08-26T09:00:00.123456+00:00\", $T)")" "just now" "a fractional second is tolerated"
assert_eq "$(js "L.relativeTime(\"2026-08-26T12:00:00+00:00\", $T + $DAY)")" "21 hours ago" \
  "the offset is subtracted, not ignored: noon UTC is three hours later than noon +03:00"
# A stamp with no offset at all is read as UTC. It is the only Date-free reading available (local
# time would need the very Date parsing this function exists to avoid), and the CLI's now_iso
# always writes one, so this is a foreign-file case rather than an everyday one.
assert_eq "$(js "L.relativeTime(\"2026-08-26T09:00:00\", $T)")" "just now" "a stamp with no offset is read as UTC"

# Half-hour and quarter-hour zones. Not a curiosity: India, Iran, Nepal, Newfoundland, Adelaide
# and the Chatham Islands are all on one, and every offset asserted above happens to end in :00 -
# so arithmetic that read only the hours would pass all of them and then be exactly thirty
# minutes wrong, forever, for every user in those places. Worse than wrong, in the +05:30 case:
# the stamp reads as being in the FUTURE for half an hour after each check, which is the branch
# that shows no relative time at all. All three stamps below are the same instant as T.
assert_eq "$(js "L.relativeTime(\"2026-08-26T14:30:00+05:30\", $T)")" "just now" \
  "a half-hour zone is the same instant as any other: India's +05:30"
assert_eq "$(js "L.relativeTime(\"2026-08-26T14:30:00+05:30\", $T + 10 * $MIN)")" "10 min ago" \
  "...and ten minutes later it says ten, not a fallback to the absolute stamp"
assert_eq "$(js "L.relativeTime(\"2026-08-26T05:30:00-03:30\", $T)")" "just now" \
  "...a NEGATIVE half-hour zone too: Newfoundland's -03:30"
assert_eq "$(js "L.relativeTime(\"2026-08-26T05:30:00-03:30\", $T + 10 * $MIN)")" "10 min ago" \
  "...where reading only the hours would land thirty minutes EARLY rather than late"
assert_eq "$(js "L.relativeTime(\"2026-08-26T14:45:00+0545\", $T)")" "just now" \
  "...and a quarter-hour zone written without the colon: Nepal's +0545"
assert_eq "$(js "L.relativeTime(\"2026-08-26T14:45:00+0545\", $T + 45 * $MIN)")" "45 min ago" \
  "...counted from the right instant, not from a whole-hour approximation of it"

# ISO_STAMP_RE is anchored at BOTH ends, and the closing anchor is what makes "one strict shape"
# true rather than aspirational. Without it a stamp with anything after the offset parses as if
# the junk were not there, and the popup does arithmetic on a string it does not understand.
# Its own expected value rather than $STAMP: formatStamp appends the offset it can SEE on the end
# of the string, and this string does not end with one - the junk is after it. The date and time
# still render, which is the point (the fallback is never "Invalid Date").
assert_eq "$(js "L.relativeTime(\"2026-08-26T12:00:00+03:00 (cached)\", $T)")" "2026-08-26 12:00" \
  "trailing junk after the offset is not a timestamp, however parseable its prefix looks"

# The calendar guard inside stampMs, which the regex cannot do for it: the regex proves the digits
# are digits, and Date.UTC rolls month 13 into next January and day 0 back into last month without
# complaint. The clocks below are chosen to sit five minutes after the ROLLED instant, because
# that is the shape of the failure - not a visible error, a confident wrong number where the
# absolute stamp belonged.
assert_eq "$(js "L.relativeTime(\"2026-13-26T12:00:00+03:00\", Date.UTC(2027,0,26,9,5,0))")" \
  "2026-13-26 12:00 +03:00" "a thirteenth month is not a date, and must not become next January"
assert_eq "$(js "L.relativeTime(\"2026-08-00T12:00:00+03:00\", Date.UTC(2026,6,31,9,5,0))")" \
  "2026-08-00 12:00 +03:00" "...and a zeroth day is not one either, and must not become last July"

# Every way of not knowing falls back to the absolute stamp, which is formatStamp's own answer.
# "in -3 minutes" would be worse than a date, so a stamp from the future falls back too - and a
# clock that has been dragged backwards is exactly how that happens on a real desktop.
assert_eq "$(js "L.relativeTime($ISO, $T - 1)")" "$STAMP" "a stamp one millisecond in the future falls back"
assert_eq "$(js "L.relativeTime($ISO, $T - 5 * $DAY)")" "$STAMP" "...and one five days in the future"
assert_eq "$(js "L.relativeTime($ISO, undefined)")" "$STAMP" "no clock at all falls back to the stamp"
assert_eq "$(js "L.relativeTime($ISO, NaN)")" "$STAMP" "...so does a NaN clock"
assert_eq "$(js "L.relativeTime($ISO, Infinity)")" "$STAMP" "...and an infinite one"
assert_eq "$(js "L.relativeTime($ISO, \"1756200000000\")")" "$STAMP" "...and a clock handed over as text"
assert_eq "$(js "L.relativeTime(\"not a date\", $T)")" "not a date" "an unparseable stamp is shown verbatim, exactly as formatStamp shows it"
assert_eq "$(js "L.relativeTime(\"2026-08-26\", $T)")" "2026-08-26" "a date with no time is not a timestamp"
assert_eq "$(js "L.relativeTime(\"2026-08-26T12:00\", $T)")" "2026-08-26 12:00" "...and neither is one without seconds"
assert_eq "$(js "L.relativeTime(null, $T)")" "never" "a missing stamp reads as never, like everywhere else"
assert_eq "$(js "L.relativeTime(\"\", $T)")" "never" "so does an empty one"
assert_eq "$(js "L.relativeTime(undefined, undefined)")" "never" "neither argument usable is still not an error"
assert_eq "$(js "L.relativeTime(42, $T)")" "never" "a stamp that is not even a string is not a date"
# The recorded corruption: two state documents concatenated, so a per-document read hands us both.
# The first line is the stamp; the second must not leak into the popup, and must not make the
# whole thing unparseable either.
assert_eq "$(js "L.relativeTime(\"2026-08-26T12:00:00+03:00\n2026-08-27T12:00:00+03:00\", $T + 5 * $MIN)")" \
  "5 min ago" "a newline-joined pair of stamps is read as the first one"
assert_eq "$(js "L.relativeTime(\"junk\nmore junk\", $T).indexOf(\"\n\") >= 0")" "false" \
  "...and the verbatim fallback stays single-line"

# --- lastRunOf: what the last run DID, from `kempt summary --json` ------------------------------
# The entry below was captured from a real `kempt summary --json` on 2026-08-26, run in a sandbox
# through the same seams tests/test_update.sh uses (dnf-check fixture in, apply stub swapping the
# rpm snapshot). Two fields are edited to realistic values the fake run could not produce: the log
# path, and duration_sec, which was 0 because the stub does no work. Everything else - the field
# names, the nesting, the shapes of updated/added/removed - is exactly what cmd_update writes.
# Inline rather than in tests/fixtures/ because what is under test is the CLI's OUTPUT SHAPE, and
# keeping it here means the assertion and the bytes it describes are read together.
export RUN_JSON='{"timestamp":"2026-08-26T22:24:06+03:00","surface":"terminal","status":"ok","duration_sec":38,"reboot_needed":false,"log":"/home/u/.local/state/kempt/logs/20260826T222406.log","error":"","backends":{"dnf":{"updated":[{"name":"kernel-core","from":"6.15.3-200.fc44","to":"6.15.4-200.fc44"},{"name":"vim-common","from":"2:9.1.900-1.fc44","to":"2:9.1.1000-1.fc44"}],"added":[{"name":"newpkg","to":"1.0-1.fc44"}],"removed":[{"name":"zsh","from":"5.9-11.fc44"}],"status":"ok","skipped_held":[]},"flatpak":{"updated":[],"added":[],"removed":[],"status":"ok","skipped_held":[]}}}'
R='L.lastRunOf(process.env.RUN_JSON)'
assert_eq "$(js "$R.when")" "2026-08-26T22:24:06+03:00" "the run's own timestamp comes through verbatim"
assert_eq "$(js "$R.whenStamp")" "2026-08-26 22:24 +03:00" "...and its absolute stamp is formatStamp's"
assert_eq "$(js "$R.surface")" "terminal" "the surface the run used"
assert_eq "$(js "$R.status")" "ok" "the status it recorded"
assert_eq "$(js "$R.failed")" "false" "an ok run did not fail"
assert_eq "$(js "$R.durationSec")" "38" "how long it took"
assert_eq "$(js "$R.updatedCount")" "2" "two packages upgraded"
assert_eq "$(js "$R.addedCount")" "1" "one installed"
assert_eq "$(js "$R.removedCount")" "1" "one removed"
# A run that installed and removed changed the machine as much as one that upgraded, which is the
# same rule the CLI's own run_counts_phrase applies - a popup saying "0 packages" after a
# transaction that added two and removed one would be the front-end disagreeing with the CLI.
assert_eq "$(js "$R.changedCount")" "4" "changedCount counts everything the run changed, not just upgrades"
assert_eq "$(js "$R.items.length")" "2" "the expandable list is the UPGRADED packages"
assert_eq "$(js "$R.items[0].name")" "kernel-core" "...in the entry's own order"
assert_eq "$(js "$R.items[0].from")" "6.15.3-200.fc44" "...with the version it came from"
assert_eq "$(js "$R.items[0].to")" "6.15.4-200.fc44" "...and the one it went to"
assert_eq "$(js "$R.logPath")" "/home/u/.local/state/kempt/logs/20260826T222406.log" "the log Show Log opens"
assert_eq "$(js "$R.rebootNeeded")" "false" "and whether that run left a restart owed"
assert_eq "$(js "$R.error")" "" "a successful run has no error text"

# Nothing to report is NULL, never a fabricated empty run - the same rule the CLI itself follows
# (`kempt summary --json` with no history prints nothing at all under exit 0). A caller that
# rendered an empty object would put "Last update never" in the popup of a box that has simply
# never run one.
assert_eq "$(js 'L.lastRunOf("")')" "null" "no runs recorded: empty stdout is no last run"
assert_eq "$(js 'L.lastRunOf("   \n  ")')" "null" "...and so is whitespace"
assert_eq "$(js 'L.lastRunOf("not json at all")')" "null" "garbage is not a run"
assert_eq "$(js 'L.lastRunOf("{\"timestamp\":\"2026-08-26T22:24:06+03:00\",\"backends\":{\"dnf\":{\"upda")')" \
  "null" "a truncated entry is not a run either"
assert_eq "$(js 'L.lastRunOf("[1,2]")')" "null" "a JSON array is valid JSON and is not a run"
assert_eq "$(js 'L.lastRunOf("42")')" "null" "neither is a number"
assert_eq "$(js 'L.lastRunOf(null)')" "null" "a missing string is not an error"
assert_eq "$(js 'L.lastRunOf(undefined)')" "null" "nor no string at all"

# Every field tolerates absence, because a history entry can be older than this build (or damaged
# in a way that still parses). The one thing that must NOT be optimistic is `failed`: a status we
# cannot read is not a success.
BARE='L.lastRunOf("{\"timestamp\":\"2026-08-26T22:24:06+03:00\"}")'
assert_eq "$(js "$BARE === null")" "false" "an entry with only a timestamp is still an entry"
assert_eq "$(js "$BARE.failed")" "true" "...and a run with no status is NOT counted as a success"
assert_eq "$(js "$BARE.changedCount")" "0" "...it changed nothing we know of"
assert_eq "$(js "$BARE.items.length")" "0" "...listed nothing"
assert_eq "$(js "$BARE.logPath")" "" "...has no log to open"
# null, not 0: the entry does not SAY how long it took, and 0 is a real duration - the CLI writes
# it for any run that finished inside a second. Conflating the two put "in 0s" on the end of a
# sentence about a run whose duration was simply absent.
assert_eq "$(js "$BARE.durationSec === null")" "true" "...and names no duration at all, rather than zero"
assert_eq "$(js 'L.lastRunOf("{\"status\":\"ok\"}").backends')" "undefined" \
  "an entry missing backends entirely derives no backends key"
assert_eq "$(js 'L.lastRunOf("{\"status\":\"ok\"}").items.length')" "0" "...and no items"
assert_eq "$(js 'L.lastRunOf("{\"status\":\"ok\"}").changedCount')" "0" "...and no counts"
assert_eq "$(js 'L.lastRunOf("{\"status\":\"ok\"}").failed')" "false" "...while an ok status is still ok"
assert_eq "$(js 'L.lastRunOf("{\"status\":\"failed\",\"error\":\"boom\"}").failed')" "true" "a failed status fails"
assert_eq "$(js 'L.lastRunOf("{\"status\":\"partial\"}").failed')" "true" "so does anything that is not exactly ok"
# reboot_needed is a BOOLEAN in the schema. The string "true" is what a shell would produce if
# somebody built the entry with --arg instead of --argjson, and it must not read as a restart.
assert_eq "$(js 'L.lastRunOf("{\"status\":\"ok\",\"reboot_needed\":\"true\"}").rebootNeeded')" "false" \
  "the string \"true\" is not the boolean true"
assert_eq "$(js 'L.lastRunOf("{\"status\":\"ok\",\"reboot_needed\":1}").rebootNeeded')" "false" "nor is 1"
assert_eq "$(js 'L.lastRunOf("{\"status\":\"ok\",\"reboot_needed\":true}").rebootNeeded')" "true" "the boolean is"

# Backend order, and a backend this build has never heard of. Same rule as backendKeys: the two we
# know first, then whatever the CLI grew since - never silently dropped.
export MIXED_JSON='{"status":"ok","backends":{"apt":{"updated":[{"name":"z","from":"1","to":"2"}]},"flatpak":{"updated":[{"name":"f","from":"1","to":"2"}]},"dnf":{"updated":[{"name":"d","from":"1","to":"2"}]}}}'
assert_eq "$(js 'L.lastRunOf(process.env.MIXED_JSON).items.map(function (i) { return i.name; })')" \
  '["d","f","z"]' "items come out dnf, flatpak, then any backend this build does not know"
assert_eq "$(js 'L.lastRunOf(process.env.MIXED_JSON).updatedCount')" "3" "...and all of them are counted"
# The comma-joined multilib/installonly set again: the expanded list has to render versions the
# way the popup rows and `kempt summary` do, or one screen contradicts the other two.
export MULTI_JSON='{"status":"ok","backends":{"dnf":{"updated":[{"name":"kernel","from":"6.15.1,6.15.3","to":"6.15.3,6.15.4"},{"name":"nameless"}]}}}'
assert_eq "$(js 'L.lastRunOf(process.env.MULTI_JSON).items[0].from')" "6.15.3" \
  "a comma-joined set renders its newest, exactly like every other version in the widget"
assert_eq "$(js 'L.lastRunOf(process.env.MULTI_JSON).items[0].to')" "6.15.4" "...on both sides"
assert_eq "$(js 'L.lastRunOf(process.env.MULTI_JSON).items[1].from')" "?" \
  "an item with no versions keeps the not-installed marker rather than rendering undefined"
assert_eq "$(js 'L.lastRunOf(process.env.MULTI_JSON).items[1].name')" "nameless" "...and keeps its name"

# --- postRunLine: the transient line that replaces the CLI's ISO summary header -----------------
# The old popup pasted `kempt summary`'s first line in here, which is an ISO timestamp: true, and
# no answer to "what just happened?". These are.
assert_eq "$(js 'L.postRunLine(null)')" "" "no run, no line"
assert_eq "$(js 'L.postRunLine(undefined)')" "" "...and no argument is not an error"
assert_eq "$(js "L.postRunLine($R)")" "Updated 4 packages in 38s" "a real run says what it changed and how long it took"
assert_eq "$(js 'L.postRunLine(L.lastRunOf("{\"status\":\"ok\",\"duration_sec\":38,\"backends\":{\"dnf\":{\"updated\":[{\"name\":\"a\"}]}}}"))')" \
  "Updated 1 package in 38s" "one package is singular"
assert_eq "$(js 'L.postRunLine(L.lastRunOf("{\"status\":\"ok\",\"duration_sec\":9}"))')" \
  "No package changes" "a run that changed nothing says so, rather than \"0 packages\""
# A duration that is not a number is not a duration. `duration_sec` arrives as whatever the entry
# holds - an older build, a hand-edited file, a half-written one - and anything non-numeric used to
# come out as 0, so the popup put "in 0s" on the end of a run it had no timing for. Zero itself is
# a real answer and stays: the CLI records it for any run that finished inside a second.
assert_eq "$(js 'L.postRunLine(L.lastRunOf("{\"status\":\"ok\",\"duration_sec\":\"38\",\"backends\":{\"dnf\":{\"updated\":[{\"name\":\"a\"}]}}}"))')" \
  "Updated 1 package" "a duration that arrived as text is left out, not read as zero seconds"
assert_eq "$(js 'L.postRunLine(L.lastRunOf("{\"status\":\"ok\",\"backends\":{\"dnf\":{\"updated\":[{\"name\":\"a\"}]}}}"))')" \
  "Updated 1 package" "...and so is one that is not there at all"
assert_eq "$(js 'L.postRunLine(L.lastRunOf("{\"status\":\"ok\",\"duration_sec\":null,\"backends\":{\"dnf\":{\"updated\":[{\"name\":\"a\"}]}}}"))')" \
  "Updated 1 package" "...or explicitly null"
assert_eq "$(js 'L.postRunLine(L.lastRunOf("{\"status\":\"ok\",\"duration_sec\":0,\"backends\":{\"dnf\":{\"updated\":[{\"name\":\"a\"}]}}}"))')" \
  "Updated 1 package in 0s" "a run that really did take under a second still says so"
# A failed run's first stderr line, which is the CLI's own worked-out reason (run_failure_reason),
# not a generic apology. Multi-line, because that reason can arrive with a log tail behind it.
assert_eq "$(js 'L.postRunLine(L.lastRunOf("{\"status\":\"failed\",\"error\":\"authentication declined or cancelled\"}"))')" \
  "Update failed: authentication declined or cancelled" "a failure names the reason"
assert_eq "$(js 'L.postRunLine(L.lastRunOf("{\"status\":\"failed\",\"error\":\"first line\\nsecond line\"}"))')" \
  "Update failed: first line" "...its FIRST line only, never a paragraph in a panel"
assert_eq "$(js 'L.postRunLine(L.lastRunOf("{\"status\":\"failed\",\"error\":\"\"}"))')" \
  "Update failed" "a failure with nothing to say still says it failed"
assert_eq "$(js 'L.postRunLine(L.lastRunOf("{\"status\":\"failed\"}"))')" \
  "Update failed" "...and so does one with no error field at all"
# Failure wins over the counts. A run that upgraded four packages and then failed is a failed run,
# and saying "Updated 4 packages" about it would be the popup's worst possible lie.
assert_eq "$(js 'L.postRunLine(L.lastRunOf("{\"status\":\"failed\",\"error\":\"dnf exited 1\",\"duration_sec\":38,\"backends\":{\"dnf\":{\"updated\":[{\"name\":\"a\"},{\"name\":\"b\"}]}}}"))')" \
  "Update failed: dnf exited 1" "a partial transaction that failed is reported as failed"
# The offline STAGING run: its entry has empty package lists BY CONSTRUCTION - nothing changes
# until the restart - so the count sentences would call it "No package changes". True about the
# rpm set, and no answer at all to what the person just did. Exact match on "offline": the
# harvest writes "offline (applied on reboot)" and its counts are real changes.
assert_eq "$(js 'L.postRunLine(L.lastRunOf("{\"status\":\"ok\",\"surface\":\"offline\",\"duration_sec\":28}"))')" \
  "Updates are staged - they install on the next restart" "a staging run reports the staging, not the zero rpm delta"
assert_eq "$(js 'L.postRunLine(L.lastRunOf("{\"status\":\"failed\",\"surface\":\"offline\",\"error\":\"staged but could not arm the restart install\"}"))')" \
  "Update failed: staged but could not arm the restart install" "a FAILED staging run is a failure, never a promise"
assert_eq "$(js 'L.postRunLine(L.lastRunOf("{\"status\":\"ok\",\"surface\":\"offline (applied on reboot)\",\"duration_sec\":0,\"backends\":{\"dnf\":{\"updated\":[{\"name\":\"a\"},{\"name\":\"b\"}]}}}"))')" \
  "Updated 2 packages in 0s" "the harvest entry is not a staging run - its counts render"

# --- runFinishedSince: is this entry the run we just watched? -----------------------------------
# The belt-and-braces half of the same fix `kempt summary --json` carries on the CLI side. The
# transient line is the one sentence in this popup that makes a claim about ONE run - the one the
# user just started - so the entry that backs it has to be from after we started watching.
# Second resolution on both sides: the CLI stamps an entry with `date -Iseconds`, so a fast run
# can legitimately carry a stamp that rounds below the millisecond clock the widget noted.
# Named so it cannot collide with the $T the shouldRefreshOnOpen block below sets up for itself.
RUNMS='Date.UTC(2026,7,26,19,24,6)'   # the captured run's stamp, 2026-08-26T22:24:06+03:00, in UTC ms
assert_eq "$(js "L.runFinishedSince($R, $RUNMS - 60000)")" "true" \
  "an entry stamped after the run started is the run that just finished"
assert_eq "$(js "L.runFinishedSince($R, $RUNMS)")" "true" \
  "...and one stamped in the very second it started still counts"
assert_eq "$(js "L.runFinishedSince($R, $RUNMS + 900)")" "true" \
  "...including a sub-second later, because the stamp has no sub-seconds to compare"
assert_eq "$(js "L.runFinishedSince($R, $RUNMS + 60000)")" "false" \
  "an entry OLDER than the moment the run started is a different run"
assert_eq "$(js "L.runFinishedSince(null, $RUNMS)")" "false" "no entry is not the run that finished"
assert_eq "$(js "L.runFinishedSince(L.lastRunOf('{\"status\":\"ok\"}'), $RUNMS)")" "false" \
  "an entry with no timestamp cannot be placed in time, so it is not claimed as this run"
assert_eq "$(js "L.runFinishedSince(L.lastRunOf('{\"status\":\"ok\",\"timestamp\":\"not a date\"}'), $RUNMS)")" "false" \
  "...and neither is one whose stamp cannot be read"
# No moment to compare against is not a reason to withhold the line: a widget that never saw the
# run start has no opinion, and the CLI-side guard is the primary one either way.
assert_eq "$(js "L.runFinishedSince($R, 0)")" "true" "with no start moment recorded, the question does not apply"
assert_eq "$(js "L.runFinishedSince($R, undefined)")" "true" "...and no argument is not an error"

# --- lastRunText: the persistent row's title ---------------------------------------------------
# The separator is U+00B7 with spaces, the same middle dot the footer uses.
W='Date.UTC(2026,7,26,19,24,6)'   # 2026-08-26T22:24:06+03:00, the captured run, in UTC ms
assert_eq "$(js "L.lastRunText($R, $W + 18 * $MIN)")" "Last update 18 min ago · 4 packages" \
  "the last run, in the words the plan drew"
assert_eq "$(js "L.lastRunText($R, $W + 3 * $DAY)")" "Last update 3 days ago · 4 packages" \
  "...however long ago it was"
assert_eq "$(js "L.lastRunText($R, undefined)")" "Last update 2026-08-26 22:24 +03:00 · 4 packages" \
  "...falling back to the absolute stamp when the clock is unusable, like relativeTime everywhere"
assert_eq "$(js "L.lastRunText(L.lastRunOf('{\"status\":\"ok\",\"timestamp\":\"2026-08-26T22:24:06+03:00\",\"backends\":{\"dnf\":{\"updated\":[{\"name\":\"a\"}]}}}'), $W + $MIN)")" \
  "Last update 1 min ago · 1 package" "one package is singular here too"
assert_eq "$(js "L.lastRunText(L.lastRunOf('{\"status\":\"ok\",\"timestamp\":\"2026-08-26T22:24:06+03:00\"}'), $W + $MIN)")" \
  "Last update 1 min ago · no package changes" "a run that changed nothing says so in words"
# The staging run's row, between the stage and the restart that applies it. Same reasoning as
# postRunLine's branch: zero changes is true and misleading. A FAILED staging run staged
# nothing, and its row must not say otherwise.
assert_eq "$(js "L.lastRunText(L.lastRunOf('{\"status\":\"ok\",\"surface\":\"offline\",\"timestamp\":\"2026-08-26T22:24:06+03:00\"}'), $W + $MIN)")" \
  "Last update 1 min ago · staged for restart" "a staging run's row says the changes are deferred, not absent"
assert_eq "$(js "L.lastRunText(L.lastRunOf('{\"status\":\"failed\",\"surface\":\"offline\",\"timestamp\":\"2026-08-26T22:24:06+03:00\"}'), $W + $MIN)")" \
  "Last update 1 min ago · no package changes" "a failed staging run falls back to the counts, which are honestly zero"
# An entry this file cannot DATE gets no row at all. "Last update never · 1 package" was the
# shape of that bug: relativeTime answers "never" for a missing or empty stamp, and the sentence
# went on to describe a run in the same breath as denying there was one. The counts are still in
# the entry and the popup still holds it - what is missing is the one thing this line is FOR,
# which is when it happened.
assert_eq "$(js "L.lastRunText(L.lastRunOf('{\"status\":\"ok\",\"backends\":{\"dnf\":{\"updated\":[{\"name\":\"a\"}]}}}'), $W)")" \
  "" "an entry with no timestamp gets no Last update row, never \"Last update never\""
assert_eq "$(js "L.lastRunText(L.lastRunOf('{\"status\":\"ok\",\"timestamp\":\"\",\"backends\":{\"dnf\":{\"updated\":[{\"name\":\"a\"}]}}}'), $W)")" \
  "" "...and neither does one whose stamp is empty"
assert_eq "$(js "L.lastRunText(L.lastRunOf('{\"status\":\"ok\",\"timestamp\":\"not a date\",\"backends\":{\"dnf\":{\"updated\":[{\"name\":\"a\"}]}}}'), $W)")" \
  "" "...nor one whose stamp cannot be read, which would paste it into the sentence verbatim"
assert_eq "$(js "L.lastRunText(null, $W)")" "" "no run, no row"
assert_eq "$(js "L.lastRunText(undefined, $W)")" "" "...and no argument is not an error"
# "no package changes" is not this file's wording to pick: it is the CLI's, emitted verbatim by
# KEMPT_JQ_COUNTS in lib/common.sh, and the popup is echoing the terminal. That is the exact
# run_counts_phrase bug class this project already carries a scar from - two renderers holding
# the same fact and drifting apart - so it is pinned in both directions here rather than by two
# separate literals that a maintainer would helpfully update together.
NOCHANGE="$(js 'L.COPY.noPackageChanges.charAt(0).toLowerCase() + L.COPY.noPackageChanges.substring(1)')"
assert_eq "$NOCHANGE" "no package changes" "the copy table says the CLI's phrase, capitalised"
assert_eq "$(grep -c 'then "no package changes" else' "$REPO_ROOT/lib/common.sh")" "1" \
  "...and lib/common.sh still emits that phrase, so there is one wording to echo"
assert_eq "$(js "L.lastRunText(L.lastRunOf('{\"status\":\"ok\",\"timestamp\":\"2026-08-26T22:24:06+03:00\"}'), $W + $MIN)")" \
  "Last update 1 min ago · $NOCHANGE" \
  "...and the row's lowercase form is those same words: rewording one of the two fails here"

# --- shouldRefreshOnOpen: the popup asks for fresh counts when the ones it has are old ----------
# The rule is "the smaller of the configured interval and five minutes". Five is a CEILING, not an
# alternative: somebody who set the interval to an hour still opened the popup to look at the
# counts, and counts an hour old are not what they came for. Somebody who set it to two minutes
# gets two.
S='L.shouldRefreshOnOpen'
FRESH='"2026-08-26T12:00:00+03:00"'   # = T in UTC ms, defined with the relativeTime tests above
assert_eq "$(js "$S($FRESH, 60, $T + 5 * $MIN - 1)")" "false" "just under five minutes is fresh enough"
assert_eq "$(js "$S($FRESH, 60, $T + 5 * $MIN)")" "false" "exactly five minutes is not yet OLDER than five"
assert_eq "$(js "$S($FRESH, 60, $T + 5 * $MIN + 1)")" "true" "a millisecond past it, ask again"
assert_eq "$(js "$S($FRESH, 60, $T + $HOUR)")" "true" "...and an hour later, certainly"
assert_eq "$(js "$S($FRESH, 2, $T + 2 * $MIN)")" "false" "a two-minute interval is not stale at two minutes"
assert_eq "$(js "$S($FRESH, 2, $T + 2 * $MIN + 1)")" "true" "...and is one millisecond later"
assert_eq "$(js "$S($FRESH, 2, $T + 4 * $MIN)")" "true" "a smaller interval wins over the five-minute ceiling"
assert_eq "$(js "$S($FRESH, 1440, $T + 6 * $MIN)")" "true" "...and the ceiling wins over a huge one"
# The widget reads config values back as the TEXT `kempt config get` printed, so a numeric string
# is the ORDINARY shape of this argument, not an edge case - it has to be honoured, or every box
# would silently get the ceiling.
assert_eq "$(js "$S($FRESH, \"2\", $T + 3 * $MIN)")" "true" "an interval that arrives as text is still an interval"
assert_eq "$(js "$S($FRESH, 2, $T + 3 * $MIN)")" "true" "...answering exactly as the number does"
# An interval we cannot use at all is not a reason to invent one: fall back to the ceiling. Three
# minutes tells the two apart - stale under a 2-minute interval, fresh under the 5-minute ceiling.
for bad in 0 -5 NaN Infinity '"abc"' '""' undefined null; do
  assert_eq "$(js "$S($FRESH, $bad, $T + 3 * $MIN)")" "false" "interval $bad falls back to the ceiling: three minutes is fresh"
  assert_eq "$(js "$S($FRESH, $bad, $T + 6 * $MIN)")" "true" "...and six is not"
done
# Nothing known at all: ask. A box that has never had a successful check is exactly the box whose
# counts are worth refreshing, and there is no age to compare.
assert_eq "$(js "$S(\"\", 60, $T)")" "true" "no stamp at all means ask"
assert_eq "$(js "$S(null, 60, $T)")" "true" "...and so does a missing one"
assert_eq "$(js "$S(\"never\", 60, $T)")" "true" "...and an unparseable one"
assert_eq "$(js "$S(\"2026-08-26\", 60, $T)")" "true" "...a date with no time is not a stamp either"
# The same three not-a-stamp shapes relativeTime pins, at the other reader of stampMs. The
# failure here is quieter and worse than a wrong relative time: a stamp that reads as being in
# the FUTURE is not stale, so the popup simply stops auto-refreshing on open and never says why.
assert_eq "$(js "$S(\"2026-08-26T12:00:00+03:00 (cached)\", 60, $T)")" "true" \
  "...nor is a stamp with junk after its offset, so there is no age to be fresh"
assert_eq "$(js "$S(\"2026-13-26T12:00:00+03:00\", 60, $T)")" "true" \
  "...nor a month that does not exist, whatever Date.UTC would roll it into"
assert_eq "$(js "$S(\"2026-08-00T12:00:00+03:00\", 60, $T)")" "true" "...nor a zeroth day"
# Half-hour zones through this reader too. A +05:30 box whose offset were read as five whole
# hours would see every fresh check as half an hour in the future and refuse to refresh on open
# for that whole half hour, on every single check.
assert_eq "$(js "$S(\"2026-08-26T14:30:00+05:30\", 60, $T + 4 * $MIN)")" "false" \
  "four minutes after a +05:30 check is fresh"
assert_eq "$(js "$S(\"2026-08-26T14:30:00+05:30\", 60, $T + 10 * $MIN)")" "true" \
  "...and ten minutes after it is past the ceiling, so the popup asks"
assert_eq "$(js "$S(\"2026-08-26T05:30:00-03:30\", 60, $T + 10 * $MIN)")" "true" \
  "a -03:30 check is read from the same instant"
assert_eq "$(js "$S(\"2026-08-26T14:45:00+0545\", 60, $T + 10 * $MIN)")" "true" \
  "...and so is a +0545 one"
# ...but never fire a command off a clock we cannot read. An unusable `now` is a caller bug, and
# the answer to a caller bug is not to start running package-manager commands on every popup open.
# That rule is checked FIRST, which is why a missing stamp does not override it.
assert_eq "$(js "$S($FRESH, 60, undefined)")" "false" "an unusable clock never fires a check"
assert_eq "$(js "$S($FRESH, 60, NaN)")" "false" "...NaN included"
assert_eq "$(js "$S($FRESH, 60, \"1756200000000\")")" "false" "...and a clock handed over as text"
assert_eq "$(js "$S(\"\", 60, undefined)")" "false" "no stamp AND no clock still does not fire"
# A last_success in the future is a clock that moved, not a check that is due.
assert_eq "$(js "$S($FRESH, 60, $T - 1)")" "false" "a stamp from the future is not stale"
assert_eq "$(js "$S($FRESH, 60, $T - 5 * $DAY)")" "false" "...however far into it"

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

# --- reboot_needed: the additive key, now that it has a reader -------------------------------
# state-reboot-needed.json is state-live.json plus that one key, which makes the pair a controlled
# experiment: the key must move the restart surfaces and NOTHING else. Compared with those two
# fields removed, inside ONE node process, because a whole-object comparison is the only form that
# catches a key quietly changing something far from where it was added.
STRIP='function (v) { delete v.rebootNeeded; delete v.restartMessageVisible; return JSON.stringify(v); }'
assert_eq "$(js "($STRIP)(V(\"reboot-needed\",false)) === ($STRIP)(V(\"live\",false))")" \
  "true" "the additive key moves the restart surfaces and leaves the rest of the view model alone"
# ...and the pinned surfaces by name too, so a failure above says WHICH one moved.
for _prop in badgeText badgeVisible iconState tooltipMain tooltipSub headerText actionable heldTotal; do
  assert_eq "$(js "V(\"reboot-needed\",false).$_prop")" "$(js "V(\"live\",false).$_prop")" \
    "reboot_needed does not disturb $_prop"
done
assert_eq "$(js 'V("reboot-needed",false).rows.length')" "$(js 'V("live",false).rows.length')" \
  "reboot_needed does not disturb the row count"
# The fixture must really carry the key, or every assertion above passes vacuously.
assert_eq "$(jq -r '.reboot_needed' "$FIXTURES/state-reboot-needed.json")" "true" \
  "fixture guard: state-reboot-needed.json really does carry the key"
assert_eq "$(js 'V("reboot-needed",false).rebootNeeded')" "true" \
  "...and the popup now reads it: a restart really is owed on that box"
assert_eq "$(js 'V("live",false).rebootNeeded')" "false" \
  "...while the same state without the key owes nothing"

# --- the fourth argument: an OPTIONS object, and three-argument callers keep working -----------
# viewModel(state, updating, cliError) is what main.qml and every assertion above call. The popup's
# new surfaces need three more facts - the clock, and the two halves of the restart reminder - and
# they arrive in ONE optional object rather than as three more positional arguments, so a caller
# that wants only the clock does not have to know what comes after it.
LIVE3='L.viewModel(S("live"),false,"")'
assert_eq "$(js "JSON.stringify($LIVE3) === JSON.stringify(L.viewModel(S(\"live\"),false,\"\",{}))")" "true" \
  "a three-argument call is exactly a call with an empty options object"
assert_eq "$(js "JSON.stringify($LIVE3) === JSON.stringify(L.viewModel(S(\"live\"),false,\"\",undefined))")" "true" \
  "...and so is one that passes undefined"
assert_eq "$(js "JSON.stringify($LIVE3) === JSON.stringify(L.viewModel(S(\"live\"),false,\"\",\"nonsense\"))")" "true" \
  "...and options that are not an object at all fall back to the defaults rather than throwing"
assert_eq "$(js "JSON.stringify($LIVE3) === JSON.stringify(L.viewModel(S(\"live\"),false,\"\",null))")" "true" \
  "...null included"

# One schema-v1 state with a known last_success, plus whatever the case under test adds, so every
# assertion below differs from its neighbour in exactly one thing.
#   st  <extra state fields> <held_total>                  -> the state literal
#   vm  <opts literal> <extra state fields> <held_total> <property>  -> that state through viewModel
# Options come first because they are what most of these assertions vary; all four are positional
# and all four are given, so nothing here depends on remembering a default.
st() { echo "{schema:1,status:\"ok\",actionable:0,held_total:${2:-0},last_success:\"2026-08-26T12:00:00+03:00\",backends:{}${1:-}}"; }
vm() { js "L.viewModel($(st "${2:-}" "${3:-0}"),false,\"\",${1:-{\}}).$4"; }

# --- vm.rebootNeeded: strictly the boolean ------------------------------------------------------
# `false` in this schema means "nothing to say", NEVER "no restart needed". backends/dnf.sh's
# dnf_reboot_needed answers false plus a warning whenever the command could not work the verdict
# out at all - rc 1 with an empty stdout (a cold user cache, which is the default on a fresh
# install) and any unexpected rc both land there - so a false is indistinguishable from "we could
# not tell", and nothing may render an affirmative from it. Same rule as the state schema table in
# docs/architecture.md.
assert_eq "$(vm '{}' ',reboot_needed:true' 0 'rebootNeeded')" "true" "the boolean true means a restart is owed"
assert_eq "$(vm '{}' ',reboot_needed:false' 0 'rebootNeeded')" "false" "the boolean false says nothing"
assert_eq "$(vm '{}' '' 0 'rebootNeeded')" "false" "an absent key says nothing either"
assert_eq "$(vm '{}' ',reboot_needed:null' 0 'rebootNeeded')" "false" "...nor does null"
assert_eq "$(vm '{}' ',reboot_needed:"true"' 0 'rebootNeeded')" "false" \
  "the STRING \"true\" is not the boolean, and must not raise a restart message"
assert_eq "$(vm '{}' ',reboot_needed:1' 0 'rebootNeeded')" "false" "neither is 1"
assert_eq "$(vm '{}' ',reboot_needed:"yes"' 0 'rebootNeeded')" "false" "nor yes"
# A state this build cannot read is not a state to take a restart claim from either: the same
# reason the badge refuses a future schema, applied to the one key that would still parse.
assert_eq "$(js 'L.viewModel({schema:2,status:"ok",actionable:0,held_total:0,backends:{},reboot_needed:true},false).rebootNeeded')" \
  "false" "a schema this build does not know contributes no restart claim"

# --- the restart message, and founder amendment A1 ----------------------------------------------
# On: the message shows, and the footer does NOT repeat it - one fact, one place on the screen.
# Off, or dismissed for this session: no message, and the footer picks the fact up instead, because
# a popup that hides a pending restart is lying to the person looking at it.
RB=',reboot_needed:true'
assert_eq "$(vm '{}' "$RB" 0 'restartMessageVisible')" "true" "reminder on: the message shows"
assert_eq "$(vm '{restartReminder:false}' "$RB" 0 'restartMessageVisible')" "false" "reminder off: no message"
assert_eq "$(vm '{restartDismissed:true}' "$RB" 0 'restartMessageVisible')" "false" \
  "dismissed this session: no message"
assert_eq "$(vm '{}' '' 0 'restartMessageVisible')" "false" "no restart owed: nothing to show"
assert_eq "$(vm '{restartReminder:true,restartDismissed:true}' "$RB" 0 'restartMessageVisible')" "false" \
  "a dismissal beats the setting for this session"
# The reminder arrives from `kempt config get`, which prints TEXT. "false" is what the widget will
# actually be holding, and reading it as truthy would leave the message on for somebody who turned
# it off - the exact bug is_true/isTrue exist to prevent.
assert_eq "$(vm '{restartReminder:"false"}' "$RB" 0 'restartMessageVisible')" "false" \
  "the setting is read the way the CLI writes it, as text"
assert_eq "$(vm '{restartReminder:"true"}' "$RB" 0 'restartMessageVisible')" "true" "...in both directions"
assert_eq "$(vm '{restartReminder:"nonsense"}' "$RB" 0 'restartMessageVisible')" "false" \
  "...and anything that is not a yes is a no, exactly like the CLI's is_true"
# Absent is not false. A missing option means the caller did not say, and the CLI's default for
# restart_reminder is true - so an unstated reminder is ON, or the widget would ship with the
# setting silently inverted.
assert_eq "$(vm '{restartReminder:undefined}' "$RB" 0 'restartMessageVisible')" "true" \
  "an unstated reminder follows the CLI's default, which is on"

# --- the count and the list under it are one answer ---------------------------------------------
# The CLI's own totals used to win outright, on the reasoning that the badge should come from the
# command path that performs the update. They are computed from the same items the widget walks
# (lib/common.sh: `[.[] | select(.held|not)] | length`), so they can only disagree when something
# is wrong - a half-written state, an older build, a backend key this widget skips. Whatever the
# cause, the ROWS are what the person is looking at, so the sentence above them has to describe
# those rows. "Up to date" over a list of pending updates is the worst thing this popup can say.
DIVERGENT='{schema:1,status:"ok",actionable:0,held_total:0,backends:{dnf:{enabled:true,items:[{name:"a"},{name:"b"}]}}}'
assert_eq "$(js "L.viewModel($DIVERGENT,false).actionable")" "2" \
  "a state whose total says 0 over two pending rows is counted from the rows"
assert_eq "$(js "L.viewModel($DIVERGENT,false).iconState")" "updates" \
  "...so the panel cannot say up to date over a list of pending updates"
assert_eq "$(js "L.viewModel($DIVERGENT,false).headerText")" "2 updates available" \
  "...and the header agrees with the list beneath it"
OVERCOUNT='{schema:1,status:"ok",actionable:9,held_total:0,backends:{dnf:{enabled:true,items:[{name:"a"},{name:"b"}]}}}'
assert_eq "$(js "L.viewModel($OVERCOUNT,false).actionable")" "2" \
  "...and it works the other way too: nine claimed, two listed, two shown"
HELD_DIVERGENT='{schema:1,status:"ok",actionable:0,held_total:0,backends:{dnf:{enabled:true,items:[{name:"a",held:true}]}}}'
assert_eq "$(js "L.viewModel($HELD_DIVERGENT,false).heldTotal")" "1" \
  "the held count comes from the held rows for the same reason"
# ...and the totals are still the answer when there is nothing to walk. A state that carries counts
# and no items at all is not a disagreement, it is a state with no list - and reading it as zero
# would be the confident-zero mistake rule 1 of the schema exists to prevent.
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:7,held_total:2,backends:{}},false).actionable')" "7" \
  "a state with counts and no items keeps its counts"
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:7,held_total:2,backends:{}},false).heldTotal')" "2" \
  "...both of them"

# --- vm.footerText: the status line -------------------------------------------------------------
# "Checked ..." is derived from last_success, NOT last_check: the counts on screen are as of the
# last check that actually told us something, and a failed check has the stale message to explain
# itself. Pinning that here because the two keys differ only on a bad day, which is the day it
# would matter.
NOW='Date.UTC(2026,7,26,9,4,0)'   # four minutes after the fixture's last_success
assert_eq "$(vm "{nowMs:$NOW}" '' 0 'footerText')" "Checked 4 min ago" "the plain case is one fact"
assert_eq "$(vm "{nowMs:$NOW}" '' 2 'footerText')" "Checked 4 min ago · 2 held" \
  "held items are named in the footer, never as \"held back\""
assert_eq "$(vm "{nowMs:$NOW}" '' 1 'footerText')" "Checked 4 min ago · 1 held" "...singular or not, one word"
assert_eq "$(js "L.viewModel({schema:1,status:\"stale\",error:\"x\",actionable:1,held_total:0,last_check:\"2026-08-26T23:00:00+03:00\",last_success:\"2026-08-26T12:00:00+03:00\",backends:{}},false,\"\",{nowMs:$NOW + 60000}).footerText")" \
  "Checked 5 min ago" "the footer reads last_success, never the newer last_check"
assert_eq "$(js "L.viewModel({schema:1,status:\"ok\",actionable:0,held_total:0,backends:{}},false,\"\",{nowMs:$NOW}).footerText")" \
  "No successful check yet" "a box with no successful check says so rather than inventing an age"
assert_eq "$(js "L.viewModel(null,false,\"\",{nowMs:$NOW}).footerText")" "No successful check yet" \
  "...and so does a popup with no state at all"
# ...and the same line for a box that HAS checked, repeatedly, and never once succeeded. That is
# a different fact from never having checked, and the fallback used to claim the wrong one of the
# two inside the very block that draws the last_success / last_check distinction. It is not a
# hypothetical box either: a fresh install behind a broken repo or with the root helpers missing
# looks exactly like this, and it is the box most likely to have the popup open.
FAILED_ALWAYS='{schema:1,status:"stale",error:"repository metadata unavailable",actionable:0,held_total:0,last_check:"2026-08-26T12:00:00+03:00",last_success:"",backends:{}}'
assert_eq "$(js "L.viewModel($FAILED_ALWAYS,false,\"\",{nowMs:$NOW}).footerText")" \
  "No successful check yet" "a box that has checked and never succeeded says exactly that"
assert_eq "$(js "L.viewModel($FAILED_ALWAYS,false,\"\",{nowMs:$NOW}).headerText")" \
  "Kempt cannot check for updates" "...while the header says what is actually wrong with it"
# ...and this is the state that settles the wording, because here the header does NOT carry the
# fact. Stale, counts known, last_success still empty: the header shows a count phrase, so
# "the header says what is wrong" is no defence for a footer line that is false on its own.
# Its total matches its two rows: a state that disagreed with its own list would be measuring the
# rule above rather than the one this block is about (see "the count and the list under it are one
# answer" further down).
STALE_NO_SUCCESS='{schema:1,status:"stale",error:"repo flapped",actionable:2,held_total:0,last_check:"2026-08-26T12:00:00+03:00",last_success:"",backends:{dnf:{enabled:true,items:[{name:"a"},{name:"b"}]}}}'
assert_eq "$(js "L.viewModel($STALE_NO_SUCCESS,false,\"\",{nowMs:$NOW}).headerText")" "2 updates available" \
  "a stale state with known counts heads the popup with a count, not with a warning"
assert_eq "$(js "L.viewModel($STALE_NO_SUCCESS,false,\"\",{nowMs:$NOW}).footerText")" \
  "No successful check yet" "...so the footer beneath it has to be true standing alone"
assert_eq "$(vm '{}' '' 0 'footerText')" "Checked 2026-08-26 12:00 +03:00" \
  "with no clock the footer falls back to the absolute stamp, like relativeTime everywhere else"

# ...but a state this build cannot READ is a different thing from a box with no state, and the
# footer used to say the same sentence about both. A schema this widget does not know may well
# record a successful check - we simply cannot tell - so "No successful check yet" over it is a
# claim with nothing behind it. Silence is the honest answer; the header already says the state
# cannot be read.
UNREADABLE='{schema:2,status:"ok",actionable:5,held_total:0,last_success:"2026-08-26T12:00:00+03:00",backends:{}}'
assert_eq "$(js "L.viewModel($UNREADABLE,false,\"\",{nowMs:$NOW}).footerText")" "" \
  "a state this build cannot read says nothing in the footer rather than claiming no check"
assert_eq "$(js "L.viewModel($UNREADABLE,false,\"\",{nowMs:$NOW}).headerText")" \
  "Could not read the update state" "...while the header is the line that says what is wrong"

# ...and the other half: a stamp that is present and unreadable. relativeTime hands back anything
# it cannot parse verbatim, which is right for a tooltip and wrong in a sentence - "Checked not a
# date" is worse than saying nothing. The raw text stays available on hover.
UNDATED='{schema:1,status:"ok",actionable:0,held_total:2,last_success:"not a date",backends:{}}'
assert_eq "$(js "L.viewModel($UNDATED,false,\"\",{nowMs:$NOW}).footerText")" "2 held" \
  "an unreadable stamp is left out of the footer, and what IS known still gets said"
assert_eq "$(js "L.viewModel($UNDATED,false,\"\",{nowMs:$NOW}).footerTooltip")" "not a date" \
  "...with the raw stamp still one hover away, which is where a verbatim value belongs"

# A1, all three cases, explicitly. `restart pending` appears when the fact is true and the MESSAGE
# is not carrying it - never both at once, and never neither.
assert_eq "$(vm "{nowMs:$NOW}" "$RB" 1 'footerText')" "Checked 4 min ago · 1 held" \
  "reminder ON: the message carries the restart, so the footer does not repeat it"
assert_eq "$(vm "{nowMs:$NOW,restartReminder:false}" "$RB" 1 'footerText')" \
  "Checked 4 min ago · 1 held · restart pending" \
  "reminder OFF: no message, so the footer carries the fact - the popup never hides it"
assert_eq "$(vm "{nowMs:$NOW,restartDismissed:true}" "$RB" 1 'footerText')" \
  "Checked 4 min ago · 1 held · restart pending" \
  "reminder on but DISMISSED this session: the fact stays, the nagging goes"
assert_eq "$(vm "{nowMs:$NOW,restartReminder:false}" '' 1 'footerText')" "Checked 4 min ago · 1 held" \
  "...and with no restart owed, switching the reminder off adds nothing at all"
assert_eq "$(vm "{nowMs:$NOW,restartReminder:false}" "$RB" 1 'footerText')" \
  "$(js "L.viewModel($(st "$RB" 1),false,\"\",{nowMs:$NOW,restartReminder:false}).footerText")" \
  "the footer is built once and read the same way twice"

# --- vm.footerTooltip: the exact stamp under the convenient one ---------------------------------
# The relative time is the convenience; the stamp is the truth, and people compare the two.
assert_eq "$(vm "{nowMs:$NOW}" '' 0 'footerTooltip')" "2026-08-26 12:00 +03:00" "the tooltip is the absolute stamp"
assert_eq "$(vm "{nowMs:$NOW}" '' 0 'footerTooltip')" "$(vm "{nowMs:$NOW}" '' 0 'lastSuccessText')" \
  "...the same one the tooltip and the stale banner already use"
assert_eq "$(js "L.viewModel({schema:1,status:\"ok\",actionable:0,held_total:0,backends:{}},false,\"\",{nowMs:$NOW}).footerTooltip")" \
  "" "no successful check, no stamp to show - never the word never in a tooltip with no context"
assert_eq "$(js "L.viewModel(null,false,\"\",{nowMs:$NOW}).footerTooltip")" "" "...and nothing at all with no state"

# --- vm.riskyMessage: the message the offline recommendation actually shows ----------------------
# riskySummary is unchanged and still exported: its own assertions above pin it, and the QML that
# reads it today keeps working.
assert_eq "$(js 'V("risky-heavy",false).riskyMessage')" "$(js 'L.COPY.kernelRestart')" \
  "a captured risky transaction with kernel-core in it names the kernel"
assert_eq "$(js 'V("risky-heavy",false).riskySummary.indexOf("session-critical pending") >= 0')" "true" \
  "...while riskySummary keeps its own, unchanged phrasing"
assert_eq "$(js 'V("live",false).riskyMessage')" "" "an everyday transaction raises no message"
assert_eq "$(js 'V("schema-v0",false).riskyMessage')" "" \
  "a state written before risky_pending existed raises none either"
assert_eq "$(js 'L.viewModel(null,false).riskyMessage')" "" "and neither does no state at all"

# ...and the two answers in this one returned object have to agree about what a list IS.
# risky_pending arriving as a STRING is not a list of one name: a duck-typed length check accepts
# it and iterates its CHARACTERS into fake families, so "kernel-core" used to come back as
# "11 session-critical pending (c, e, k, l, ...)" beside a riskyMessage of "" - one popup
# contradicting itself in a single glance. Same for anything else that merely has a length.
RPS='{schema:1,status:"ok",actionable:1,held_total:0,backends:{},risky_pending:"kernel-core"}'
RPO='{schema:1,status:"ok",actionable:1,held_total:0,backends:{},risky_pending:{length:3}}'
assert_eq "$(js "L.viewModel($RPS,false).riskySummary")" "" "a string risky_pending is not a list of names"
assert_eq "$(js "L.viewModel($RPS,false).riskyMessage")" "" "...and the message already refused it"
assert_eq "$(js "L.viewModel($RPO,false).riskySummary")" "" \
  "...nor is an object that merely carries a length"
# The array path is untouched: riskySummaryOf itself is unchanged, only its caller's guard.
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:1,held_total:0,backends:{},risky_pending:["kernel-core","glibc"]},false).riskySummary')" \
  "2 session-critical pending (glibc, kernel)" "a genuine array still derives the summary it always did"

# --- vm.stagedMessage / vm.stagedShowRestart: a transaction that is already waiting --------------
# The state key exists only when the CLI has reconciled its own marker against dnf5's status and
# found an ARMED transaction (lib/common.sh, offline_staged_state), so the widget does not
# re-derive that judgement - it renders it or it says nothing.
STG=',offline_staged:{staged_at:"2026-09-02T10:31:00+03:00",count:61,armed:true}'
STGN=',offline_staged:{staged_at:"x",count:null,armed:true}'
assert_eq "$(vm '{}' "$STG" 0 'stagedMessage')" \
  "61 updates are staged - they install on the next restart" \
  "a staged transaction says how many updates the restart will install"
assert_eq "$(vm '{}' "$STGN" 0 'stagedMessage')" \
  "Updates are staged - they install on the next restart" \
  "an unknown count drops the number rather than the sentence"
# ONE update is a whole different sentence, not the plural one with a 1 in it. Same rule the rest
# of this file already follows for minutes, hours, days, packages and the header's own count.
assert_eq "$(vm '{}' ',offline_staged:{staged_at:"x",count:1,armed:true}' 0 'stagedMessage')" \
  "1 update is staged - it installs on the next restart" \
  "a single staged update reads as one, verb and pronoun included"
assert_eq "$(vm '{}' ',offline_staged:{staged_at:"x",count:2,armed:true}' 0 'stagedMessage')" \
  "2 updates are staged - they install on the next restart" \
  "...and two is back to the plural"
# Zero is not a sentence anybody should ever read, but the count comes from another program and
# the singular branch must not be the one that catches it.
assert_eq "$(vm '{}' ',offline_staged:{staged_at:"x",count:0,armed:true}' 0 'stagedMessage')" \
  "0 updates are staged - they install on the next restart" \
  "...and zero takes the plural, not the singular"
assert_eq "$(vm '{}' ',offline_staged:{staged_at:"x",armed:true}' 0 'stagedMessage')" \
  "$(js 'L.COPY.stagedUnknownCount')" "...and a key that never carried a count reads the same"
assert_eq "$(vm '{}' '' 0 'stagedMessage')" "" "nothing staged, nothing said"
assert_eq "$(js 'L.viewModel(null,false).stagedMessage')" "" "...and no state at all says nothing either"
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:0,held_total:0,backends:{},offline_staged:"yes"},false).stagedMessage')" \
  "" "a key of the wrong type is ignored, not rendered"
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:0,held_total:0,backends:{},offline_staged:61},false).stagedMessage')" \
  "" "...a number included"

# Never TWO Restart… buttons in one popup. The restart Warning already carries one whenever it is
# on screen, and the staged message is a second place the same action would appear - which is the
# shape the founder hit from the other direction: two buttons for one outcome, pressed twice.
assert_eq "$(vm '{}' "$STG" 0 'stagedShowRestart')" "true" \
  "a staged transaction with no restart message offers the restart itself"
assert_eq "$(vm '{}' "$STG,reboot_needed:true" 0 'stagedShowRestart')" "false" \
  "...and stands down when the restart message is already offering it"
assert_eq "$(vm '{restartReminder:false}' "$STG,reboot_needed:true" 0 'stagedShowRestart')" "true" \
  "...and takes it back when that message is switched off"
assert_eq "$(vm '{restartDismissed:true}' "$STG,reboot_needed:true" 0 'stagedShowRestart')" "true" \
  "...or dismissed for this session"
assert_eq "$(vm '{}' '' 0 'stagedShowRestart')" "false" "nothing staged offers no restart"

# THE DOUBLE-PRESS. With a transaction already staged, offering "Install on Next Restart" again is
# an invitation to stage a second one - which is exactly what happened on 2026-09-01: staged at
# 10:31, nothing appeared to change, staged again at 10:36. riskyMessage is the whole content of
# that offer, so silencing it is what takes the button off the screen.
RISKY=',risky_pending:["kernel-core","kernel-modules"]'
assert_eq "$(vm '{}' "$RISKY" 0 'riskyMessage')" "$(js 'L.COPY.kernelRestart')" \
  "premise: a session-critical transaction does raise the offer"
assert_eq "$(vm '{}' "$RISKY$STG" 0 'riskyMessage')" "" \
  "...and never while a transaction is already staged"
# The count keeps telling the truth: those packages ARE still pending until the restart runs, and
# the staged message is what explains why nothing is being offered about them.
assert_eq "$(vm '{}' "$RISKY$STG" 0 'riskySummary')" \
  "$(vm '{}' "$RISKY" 0 'riskySummary')" \
  "...while the count of what is pending is unchanged, because it is still true"

# --- the staged banner FLIPS when a hold lands behind it (spec 4.4) -----------------------------
# The trap this closes, in the user's own order: stage 83 updates with a kernel among them, read
# something worrying, press the pin on kernel-core - and restart into the kernel you just tried to
# keep out. dnf5 built that transaction before the hold existed and offers no way to edit a stored
# one (spec G4), so the hold is real and so is the install. Nothing lied; the popup was the last
# surface that could have said so and it was showing a green checkmark with a live Restart… button.
#
# So the banner does not GAIN a line, it CHANGES TYPE. A second sentence under a Positive message
# is the contradiction one level down (spec, UX finding 1): the reassurance and the warning would
# be the same message, and the reassurance is the half with the button on it.
#
# Built whole rather than through st(), because the generic variant below needs a HELD dnf item in
# `backends` and st() hands out an empty backends object.
stg() {  # <offline_staged literal> <backends literal>
  echo "{schema:1,status:\"ok\",actionable:0,held_total:0,last_success:\"2026-08-26T12:00:00+03:00\",backends:$2,offline_staged:$1}"
}
sv() { js "L.viewModel($(stg "$1" "$2"),false,\"\",{}).$3"; }

NOBK='{}'
# One held dnf package, exactly as collectItems sees it: backends.<name>.items[] with held true.
HELDDNF='{dnf:{enabled:true,items:[{name:"kernel-core",from:"6.15.1",to:"6.15.3",held:true}]}}'
PENDDNF='{dnf:{enabled:true,items:[{name:"bash",from:"5.2.32-1",to:"5.2.37-1",held:false}]}}'
HELDFP='{flatpak:{enabled:true,items:[{name:"org.gimp.GIMP",from:"2.10",to:"3.0",held:true}]}}'

ARMED='{staged_at:"2026-09-02T10:31:00+03:00",count:61,armed:true}'
CONF1='{staged_at:"2026-09-02T10:31:00+03:00",count:61,armed:true,holds_conflict:["kernel-core"],names_source:"transaction"}'
CONF3='{staged_at:"2026-09-02T10:31:00+03:00",count:61,armed:true,holds_conflict:["kernel-core","kernel-modules","systemd"],names_source:"transaction"}'
GENERIC='{staged_at:"2026-09-02T10:31:00+03:00",count:61,armed:true,holds_conflict:[],names_source:"none"}'

# The plain armed stage is EXACTLY what it was. This is the regression pin for the whole change:
# every assertion above about stagedMessage still describes the common case, and the new fields
# say "nothing to warn about" rather than being absent.
assert_eq "$(sv "$ARMED" "$NOBK" 'stagedType')" "positive" \
  "an armed stage with no hold behind it is the Positive banner it always was"
assert_eq "$(sv "$ARMED" "$NOBK" 'stagedMessage')" \
  "61 updates are staged - they install on the next restart" \
  "...saying the same sentence, word for word"
assert_eq "$(sv "$ARMED" "$NOBK" 'stagedShowRestart')" "true" "...still offering the restart"
assert_eq "$(sv "$ARMED" "$NOBK" 'stagedShowRebuild')" "false" "...and offering no rebuild"
assert_eq "$(sv "$ARMED" "$NOBK" 'stagedConflictNames')" "[]" "...with no names to warn about"
assert_eq "$(sv "$ARMED" "$NOBK" 'stagedStagedAt')" "2026-09-02T10:31:00+03:00" \
  "...and publishing the stamp the click-time re-verify compares against"

# ONE name. "your hold", singular, and "still installs" - the noun, the possessive and the verb all
# move together, the same rule stagedOne already follows. Copy is spec section 7 verbatim.
assert_eq "$(sv "$CONF1" "$NOBK" 'stagedType')" "warning" \
  "a hold on a package the staged update contains flips the banner to a warning"
assert_eq "$(sv "$CONF1" "$NOBK" 'stagedMessage')" \
  "Staged before your hold - kernel-core still installs on the next restart." \
  "...naming the package, and what the next restart will do with it"
assert_eq "$(sv "$CONF1" "$NOBK" 'stagedShowRestart')" "false" \
  "...and the Restart… button goes away: offering it here is offering the thing they feared"
assert_eq "$(sv "$CONF1" "$NOBK" 'stagedShowRebuild')" "true" \
  "...replaced by the one action that changes the outcome"
assert_eq "$(sv "$CONF1" "$NOBK" 'stagedRebuildTooltip')" \
  "$(js 'L.COPY.stagedRebuildTooltip')" \
  "...whose tooltip discloses the authorization and the discard cost before it is pressed"
assert_eq "$(sv "$CONF1" "$NOBK" 'stagedConflictNames')" '["kernel-core"]' \
  "...and the names are published, for the probes and for anything that has to say them again"

# THREE names: first name, then "and N more". Not familiesOf - that collapses kernel-core and
# kernel-modules into one decision, which is right for "what is risky about this transaction" and
# wrong here, where the person is owed the count of packages their holds did not stop.
assert_eq "$(sv "$CONF3" "$NOBK" 'stagedMessage')" \
  "Staged before your holds - kernel-core and 2 more still install on the next restart." \
  "three held packages read as the first one and a count, with every word moved to the plural"
assert_eq "$(sv "$CONF3" "$NOBK" 'stagedType')" "warning" "...still a warning"
assert_eq "$(sv "$CONF3" "$NOBK" 'stagedConflictNames')" \
  '["kernel-core","kernel-modules","systemd"]' "...and all three are published, not just the named one"
# Two is the boundary the singular must not catch: one other package is "and 1 more", not a second
# whole sentence, and it is still the plural everywhere else.
assert_eq "$(sv '{staged_at:"x",count:2,armed:true,holds_conflict:["glibc","systemd"],names_source:"transaction"}' "$NOBK" 'stagedMessage')" \
  "Staged before your holds - glibc and 1 more still install on the next restart." \
  "...and two is the plural with a 1 in it, not the singular"

# names_source "none" means the staged package list could not be read AT ALL - an older stage, or a
# dnf5 record this build does not recognise. An empty holds_conflict there is "cannot tell", never
# "no conflict", so a box that is holding something dnf still gets warned - vaguely, and honestly.
# The spec's suppression rule in one assertion: names may confirm a conflict, never deny one.
assert_eq "$(sv "$GENERIC" "$HELDDNF" 'stagedType')" "warning" \
  "an unreadable staged list over a held dnf package warns rather than reassuring"
assert_eq "$(sv "$GENERIC" "$HELDDNF" 'stagedMessage')" \
  "Staged before your holds - it may still install held packages on the next restart." \
  "...saying may, because that is what is known"
assert_eq "$(sv "$GENERIC" "$HELDDNF" 'stagedShowRebuild')" "true" \
  "...and offering the same rebuild, which applies every current hold whatever the list said"
assert_eq "$(sv "$GENERIC" "$HELDDNF" 'stagedShowRestart')" "false" "...with no restart offered"
assert_eq "$(sv "$GENERIC" "$HELDDNF" 'stagedConflictNames')" "[]" \
  "...and no names invented to fill the sentence"

# ...and with nothing held there is nothing to be vague ABOUT. An unreadable list is not a reason
# to worry a box that is holding nothing.
assert_eq "$(sv "$GENERIC" "$NOBK" 'stagedType')" "positive" \
  "an unreadable staged list with nothing held at all stays the plain armed banner"
assert_eq "$(sv "$GENERIC" "$PENDDNF" 'stagedType')" "positive" \
  "...and a pending, unheld package is not a hold either"
# Flatpak holds can never conflict: the offline surface stages dnf and only dnf (spec, UX finding
# 2), so a held GIMP behind an unreadable dnf list is not a reason to warn about anything.
assert_eq "$(sv "$GENERIC" "$HELDFP" 'stagedType')" "positive" \
  "a held flatpak is not a conflict: the offline surface stages dnf only"

# --- the state file is another program's JSON, and a schema-1 reader tolerates the wrong type ---
# Tolerating means IGNORING, exactly as the isArray note in viewModel already argues for
# risky_pending: a string has a length and indexes into its own CHARACTERS, so a duck-typed check
# would warn about a package called "k". Everything malformed falls back to the banner that was
# there before these fields existed, and nothing throws.
assert_eq "$(sv '{staged_at:"x",count:2,armed:true,holds_conflict:"kernel-core",names_source:"transaction"}' "$NOBK" 'stagedType')" \
  "positive" "a STRING holds_conflict is not a list of one name"
assert_eq "$(sv '{staged_at:"x",count:2,armed:true,holds_conflict:{length:2},names_source:"transaction"}' "$NOBK" 'stagedType')" \
  "positive" "...nor is an object that merely carries a length"
assert_eq "$(sv '{staged_at:"x",count:2,armed:true,holds_conflict:[1,2],names_source:"transaction"}' "$NOBK" 'stagedType')" \
  "positive" "...nor a list of numbers, which have no package name in them"
assert_eq "$(sv '{staged_at:"x",count:2,armed:true,holds_conflict:["kernel-core",null],names_source:"transaction"}' "$NOBK" 'stagedType')" \
  "positive" "...nor a list with a hole in it"
assert_eq "$(sv '{staged_at:"x",count:2,armed:true,holds_conflict:[""],names_source:"transaction"}' "$NOBK" 'stagedType')" \
  "positive" "...nor an empty name, which would render a sentence with a gap where the package goes"
assert_eq "$(sv '{staged_at:"x",count:2,armed:true,holds_conflict:[],names_source:"transaction"}' "$NOBK" 'stagedType')" \
  "positive" "a list that was READ and is empty is the good news it looks like"
# The older CLI, which is the ordinary case rather than the exotic one: the widget is an installed
# COPY and the CLI is a symlink into the checkout, so a widget newer than its engine is normal.
# Neither field present means neither judgement is available, and the banner is today's.
assert_eq "$(sv "$ARMED" "$HELDDNF" 'stagedType')" "positive" \
  "a stage from a CLI that never published these fields renders as it always did"
assert_eq "$(sv '{staged_at:"x",count:2,armed:true,names_source:"none"}' "$HELDDNF" 'stagedType')" \
  "warning" "...while names_source alone is enough for the generic warning, since it IS the verdict"
# names_source missing but names PRESENT is the one malformed shape that must still warn. The
# spec's rule is that names may confirm a conflict and may never deny one, and a reader that
# demanded a well-formed names_source before believing a list of names would be denying one.
assert_eq "$(sv '{staged_at:"x",count:2,armed:true,holds_conflict:["kernel-core"]}' "$NOBK" 'stagedType')" \
  "warning" "names without a names_source still confirm the conflict they name"
assert_eq "$(sv '{staged_at:"x",count:2,armed:true,holds_conflict:["kernel-core"],names_source:7}' "$NOBK" 'stagedType')" \
  "warning" "...and a names_source of the wrong type does not un-name them"
# Nothing staged at all: every one of these fields has to have an answer anyway, because a QML
# binding to an undefined property is a blank in the panel rather than an error anyone sees.
assert_eq "$(js 'L.viewModel(null,false).stagedType')" "positive" "no state at all is not a warning"
assert_eq "$(js 'L.viewModel(null,false).stagedShowRebuild')" "false" "...and offers no rebuild"
assert_eq "$(js 'L.viewModel(null,false).stagedConflictNames')" "[]" "...and names nothing"
assert_eq "$(js 'L.viewModel(null,false).stagedStagedAt')" "" "...and has no stamp to re-verify against"
assert_eq "$(vm '{}' '' 0 'stagedType')" "positive" "an ordinary state with nothing staged is not a warning either"
assert_eq "$(vm '{}' '' 0 'stagedShowRebuild')" "false" "...and offers no rebuild"
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:0,held_total:0,backends:{},offline_staged:"yes"},false).stagedType')" \
  "positive" "an offline_staged of the wrong type raises no warning to go with the message it raises no"
assert_eq "$(js 'L.viewModel({schema:1,status:"ok",actionable:0,held_total:0,backends:{},offline_staged:"yes"},false).stagedStagedAt')" \
  "" "...and no stamp either"
# A stamp that is not a string is not a stamp. The re-verify compares this for EQUALITY against the
# state file at click time, so a number here would compare equal to a number there and spend the
# user's consent on a transaction they never saw.
assert_eq "$(sv '{staged_at:12345,count:2,armed:true}' "$NOBK" 'stagedStagedAt')" "" \
  "a staged_at that is not a string publishes nothing, so the re-verify can only refuse"

# The restart suppression is the WARNING's rule, not a new copy of the two-buttons rule. Both hold
# at once, and the warning's is the stricter of the two.
assert_eq "$(sv "$CONF1" "$NOBK" 'restartMessageVisible')" "false" \
  "premise: no restart message is on screen in this state"
assert_eq "$(sv "$ARMED" "$NOBK" 'stagedShowRestart')" "true" \
  "...so the positive banner does carry the button there"
assert_eq "$(sv "$CONF1" "$NOBK" 'stagedShowRestart')" "false" \
  "...and the warning stands it down anyway, which is the whole point of the flip"

# UX finding 10, pinned: riskyMessage stays silent under EVERY staged variant. The staged banner is
# what explains why "Install on Next Restart" is not being offered, and a warning variant is the
# state where a second offer to stage the same transaction would be worst.
RISKYPEND=',risky_pending:["kernel-core","kernel-modules"]'
sr() { js "L.viewModel({schema:1,status:\"ok\",actionable:0,held_total:0,backends:$2,offline_staged:$1$RISKYPEND},false,\"\",{}).riskyMessage"; }
assert_eq "$(js "L.viewModel({schema:1,status:\"ok\",actionable:0,held_total:0,backends:{}$RISKYPEND},false).riskyMessage")" \
  "$(js 'L.COPY.kernelRestart')" "premise: this transaction does raise the offline offer"
assert_eq "$(sr "$ARMED" "$NOBK")" "" "...silenced by the plain armed banner, as it already was"
assert_eq "$(sr "$CONF1" "$NOBK")" "" "...silenced by the conflict banner too"
assert_eq "$(sr "$CONF3" "$NOBK")" "" "...by the plural one"
assert_eq "$(sr "$GENERIC" "$HELDDNF")" "" "...and by the generic one"

# --- the group headers carry which group they are ------------------------------------------------
# The popup draws one extra line under the Held heading ("Held packages are skipped by Kempt only")
# and must not decide which heading that is by comparing its title against a literal - the title is
# a translated string. So the flag travels with the row.
assert_eq "$(js 'L.rowsOf([{title:"System (dnf)",backend:"dnf",items:[{name:"a",from:"1",to:"2",held:false,backend:"dnf"}]}],[{name:"b",from:"1",to:"2",held:true,backend:"dnf"}]).filter(function (r) { return r.kind === "header"; }).map(function (r) { return r.title + ":" + r.held; })')" \
  '["System (dnf):false","Held:true"]' \
  "the Held heading says it is the held one, and a backend section says it is not"
assert_eq "$(js 'V("held-only",false).rows[0].held')" "true" \
  "...on a real capture whose every pending update is held"

# --- the copy table -----------------------------------------------------------------------------
# One place where the wording is decided, so a change is one edit and a node test can pin it. The
# QML still writes each literal itself: i18n() extracts LITERALS, and i18n(someVariable) extracts
# nothing at all, so routing these through i18n() at runtime would ship an untranslatable widget.
assert_eq "$(js 'L.COPY.upToDate')" "Up to date" "copy: the header in the clean state"
assert_eq "$(js 'L.COPY.everythingUpToDate')" "Everything is up to date" "copy: the placeholder under it"
assert_eq "$(js 'L.COPY.restartMessage')" "Restart to apply installed updates" "copy: the restart message"
assert_eq "$(js 'L.COPY.restartAction')" "Restart…" "copy: the restart button"
assert_eq "$(js 'L.COPY.restartFailed')" "Could not open the restart prompt." \
  "copy: what a restart prompt that would not open says, in the message itself, never silently"
assert_eq "$(js 'L.COPY.checkForUpdates')" "Check for Updates" "copy: the refresh action"
assert_eq "$(js 'L.COPY.updateNow')" "Update Now" "copy: the primary action"
assert_eq "$(js 'L.COPY.installOnNextRestart')" "Install on Next Restart" "copy: the offline action"
assert_eq "$(js 'L.COPY.installOnNextRestartTooltip')" \
  "Applies the update during a restart, so nothing changes underneath your running desktop." \
  "copy: and what it does, which is the whole argument for choosing it"
assert_eq "$(js 'L.COPY.kernelRestart')" "This includes a kernel update. Restart when it finishes." \
  "copy: the kernel sentence"
assert_eq "$(js 'L.COPY.kernelNvidiaRestart')" \
  "This includes a kernel update and the NVIDIA driver. Restart when it finishes." \
  "copy: and the one that names the driver too"
assert_eq "$(js 'L.COPY.held')" "held" "copy: held, never \"held back\" - the CLI says Held and the command is kempt hold"
assert_eq "$(js 'L.COPY.restartPending')" "restart pending" "copy: the two-word fact in the footer"
assert_eq "$(js 'L.COPY.noSuccessfulCheckYet')" "No successful check yet" \
  "copy: a box with no successful check, which is not the same claim as a box that never checked"
assert_eq "$(js 'L.COPY.showLog')" "Show Log" "copy: the log action"
assert_eq "$(js 'L.COPY.noPackageChanges')" "No package changes" "copy: a run that changed nothing"
assert_eq "$(js 'L.COPY.updateFailed')" "Update failed" "copy: a run that failed"
assert_eq "$(js 'L.COPY.stagedOne')" "1 update is staged - it installs on the next restart" \
  "copy: the staged message for exactly one update"
assert_eq "$(js 'L.COPY.stagedUnknownCount')" "Updates are staged - they install on the next restart" \
  "copy: the staged message when the count is not known"
assert_eq "$(js 'L.COPY.stagedTail')" "are staged - they install on the next restart" \
  "copy: the tail the counted spelling shares with it"
assert_eq "$(js 'L.COPY.stagedConflictOne')" \
  "Staged before your hold - %1 still installs on the next restart." \
  "copy: the staged banner when one held package is in the transaction anyway"
assert_eq "$(js 'L.COPY.stagedConflictMore')" \
  "Staged before your holds - %1 and %2 more still install on the next restart." \
  "copy: ...and when there are more of them, named first and counted after"
assert_eq "$(js 'L.COPY.stagedConflictUnknown')" \
  "Staged before your holds - it may still install held packages on the next restart." \
  "copy: ...and when the staged list could not be read, which is a may and not a does"
assert_eq "$(js 'L.COPY.stagedRebuildAction')" "Rebuild Staged Update" \
  "copy: the one action a conflict banner offers"
assert_eq "$(js 'L.COPY.stagedRebuildTooltip')" \
  "Builds the staged update again with your current holds. Asks for authorization; if the rebuild fails, the current staged update is removed." \
  "copy: ...disclosing the authorization and the discard cost, which is what makes it consent"
assert_eq "$(js 'L.COPY.stagedChanged')" "The staged update changed - take another look." \
  "copy: what a rebuild that was clicked over a stage that had already moved says instead of acting"
# "re-downloads" is measurably false and must never appear: a replace-stage reuses dnf5's package
# cache (spec G8 - re-staging with an exclude transferred 0.0 B, ">>> Already downloaded"). And
# "unstage" is not the vocabulary either: the CLI's remedy REMOVES the staged update.
assert_eq "$(js 'Object.keys(L.COPY).filter(function (k) { return /re-?downloads?|unstage/i.test(L.COPY[k]); })')" \
  "[]" "no copy string claims a rebuild re-downloads anything, or calls removing it unstaging"
# --- the pin, restated (hostile panel, proposal 1 / decision D1) ---------------------------------
# The name carries the STATE, because a `checkable: false` button exposes no checked state to
# AT-SPI on Qt 6.11 and the alternative - the CheckBox role - would draw Breeze's sunken checked
# background on a control sitting directly under the tray's own checked Keep Open pin. Two pairs,
# because a package that is not installed yet has no current version to be held AT.
assert_eq "$(js 'L.COPY.holdAt')" "Hold %1 at %2" "copy: the pin on a pending row names the version"
assert_eq "$(js 'L.COPY.stopHolding')" "Stop holding %1" "copy: ...and on a held one, the way out"
assert_eq "$(js 'L.COPY.skipInstalling')" "Skip installing %1" \
  "copy: a package with no current version is SKIPPED, not held at a version it does not have"
assert_eq "$(js 'L.COPY.stopSkipping')" "Stop skipping %1" "copy: ...and its way out"
# The description is the CONSEQUENCE. QQC2 already hands `text` to AT-SPI as the accessible name,
# so a description bound to `text` was the same sentence spoken twice and the one slot that could
# explain the effect, wasted (a11y P4).
assert_eq "$(js 'L.COPY.holdConsequence')" \
  "Kempt skips it on every update until you stop holding it." \
  "copy: what holding a package actually does, per package and Kempt-only"
assert_eq "$(js 'L.COPY.heldConsequence')" "Kempt offers its update again." \
  "copy: ...and what stopping does"
assert_eq "$(js 'L.COPY.heldToken')" "Held" \
  "copy: the state as a word on the row, because an opacity dip is a contrast REDUCTION"
assert_eq "$(js 'L.COPY.heldKemptOnly')" "Held packages are skipped by Kempt only." \
  "copy: the one line the Held heading owes a dnf user who reads versionlock into it"
assert_eq "$(js 'L.COPY.versionRange')" "from %1 to %2" \
  "copy: the version line in words, because the arrow goes through a screen reader's character table"
# The two icon-only buttons in the header. Their descriptions used to be their own labels read back,
# which is the same gate failure the pin had: `text` is what makes an icon-only button speak, and
# the description is the slot for what pressing it does.
assert_eq "$(js 'L.COPY.checkForUpdatesDescription')" \
  "Asks dnf and flatpak what is pending now, instead of waiting for the timer." \
  "copy: what the refresh icon does, rather than its own name again"
assert_eq "$(js 'L.COPY.configureDescription')" \
  "Check interval, where updates run, restart reminders, and the packages you hold." \
  "copy: ...and what is behind the gear"

# The hold round trip's own three sentences. Two are ANNOUNCED rather than shown - the popup speaks
# them through Accessible.announce when a hold lands - and the third is reported in the row that
# failed rather than as a message at the top of the stack, where a failure used to land up to 300 px
# from the pin that caused it (hostile panel, HIG P6).
assert_eq "$(js 'L.COPY.holdAnnounce')" "Holding %1" \
  "copy: what the popup says out loud when a hold lands"
assert_eq "$(js 'L.COPY.unholdAnnounce')" "No longer holding %1" \
  "copy: ...and when one is lifted"
assert_eq "$(js 'L.COPY.holdFailed')" "Could not change the hold on %1." \
  "copy: a hold that failed, said in the row it failed on"
assert_eq "$(js 'L.COPY.configure')" "Configure Kempt…" "copy: the settings action"
assert_eq "$(js 'L.COPY.engineMissing')" \
  "Kempt's engine is not installed, so nothing can check for updates yet." \
  "copy: the store-first first run says what is missing"
assert_eq "$(js 'L.COPY.engineMissingInstall')" \
  "On Fedora: sudo dnf copr enable erez-c137/kempt, then sudo dnf install kempt. Other systems: github.com/erez-c137/kempt" \
  "copy: ...and the commands that fix it, complete enough to paste"
# Nothing empty, nothing that is not a string: an undefined COPY key reaches a QML binding as a
# blank label, which is a button with no words on it rather than an error anyone would see.
assert_eq "$(js 'Object.keys(L.COPY).filter(function (k) { return typeof L.COPY[k] !== "string" || L.COPY[k] === ""; })')" \
  "[]" "every entry in the copy table is a non-empty string"
# No em dashes, anywhere, ever: they read as machine-written English (project rule). Written as the
# escape rather than the character so that the repo-wide grep for em dashes stays empty - a test
# file that carries one to forbid it would trip the very check it exists to support.
assert_eq "$(js 'Object.keys(L.COPY).filter(function (k) { return L.COPY[k].indexOf("\u2014") >= 0; })')" \
  "[]" "no copy string contains an em dash (U+2014)"
# A real ellipsis, U+2026, on the two labels that open something else. hig-review.md P5 calls three
# ASCII dots the one typographic tell that a widget was not written by KDE.
for _k in restartAction configure; do
  assert_eq "$(js "L.COPY.$_k.charCodeAt(L.COPY.$_k.length - 1)")" "8230" \
    "copy: $_k ends in a real ellipsis (U+2026)"
  assert_eq "$(js "L.COPY.$_k.indexOf(\"...\")")" "-1" "copy: ...and not in three ASCII dots"
done
# KDE's own placeholders carry no full stop ("No paired devices", "No Vaults have been set up").
assert_eq "$(js 'L.COPY.everythingUpToDate.charAt(L.COPY.everythingUpToDate.length - 1)')" "e" \
  "copy: the placeholder has no trailing full stop"

# --- every branch returns the full view model shape: QML binds to these names, and an
# undefined property in a binding is a silent blank in the panel, not an error anyone sees.
keys='["actionable","badgeText","badgeVisible","cliError","downloadText","emptyStateText","engineMissingCopyText","engineMissingMessage","footerText","footerTooltip","headerText","heldItems","heldTotal","iconState","lastSuccessText","rebootNeeded","remedyCommand","restartMessageVisible","riskyMessage","riskySummary","rows","sections","stagedConflictNames","stagedMessage","stagedRebuildTooltip","stagedShowRebuild","stagedShowRestart","stagedStagedAt","stagedType","stale","staleReason","tooltipMain","tooltipSub"]'
for case in 'L.viewModel(null,false)' 'L.viewModel(null,true)' 'V("live",false)' 'V("live",true)' \
            'V("stale",false)' 'V("never",false)' 'V("held-only",false)' 'V("flatpak-disabled",false)' \
            'V("risky-heavy",false)' 'V("schema-v0",false)' 'V("empty",false)' 'V("garbage",false)' 'V("broken",false)' \
            'V("reboot-needed",false)' 'L.viewModel(null,false,"",{engineMissing:true})' \
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

# --- the panel icon's size: `auto`, and the setting that overrides it ---------------------------
# Two rules, and they answer different questions. snapIconSize is `auto` - how big should this be
# when nobody said - and resolveIconSize is the whole answer, including what the user asked for.
#
# The rungs are pinned to what the SYSTEM TRAY draws, not to "the largest that fits". That is the
# change: a 44px panel fits a 32px icon, so the widget asked for 32 and stood in a row of 22px tray
# entries looking like a mistake. The tray does not fill its cell either. Anything from a 22px
# panel to a 47px one now asks for 22, which is what the tray asks for across that whole range.
STEPS='[16,22,32,48,64]'
assert_eq "$(js "L.snapIconSize(16, $STEPS)")" "16" "a 16px panel asks for the hinted 16px icon"
assert_eq "$(js "L.snapIconSize(21, $STEPS)")" "16" "...and so does 21, one pixel below the next rung"
assert_eq "$(js "L.snapIconSize(22, $STEPS)")" "22" "22px is where the tray's own size takes over"
assert_eq "$(js "L.snapIconSize(24, $STEPS)")" "22" "...and 24 stays there"
assert_eq "$(js "L.snapIconSize(32, $STEPS)")" "22" "a 32px panel matches the tray at 22, it does not fill itself"
assert_eq "$(js "L.snapIconSize(36, $STEPS)")" "22" "...nor does 36, the ordinary panel"
assert_eq "$(js "L.snapIconSize(44, $STEPS)")" "22" "...nor 44, the Plasma default - THE bug this fixes"
assert_eq "$(js "L.snapIconSize(47, $STEPS)")" "22" "...right up to 47"
assert_eq "$(js "L.snapIconSize(48, $STEPS)")" "32" "48 is where a panel stops being an ordinary panel"
assert_eq "$(js "L.snapIconSize(64, $STEPS)")" "32" "...and 64 is still 32"
assert_eq "$(js "L.snapIconSize(95, $STEPS)")" "32" "...to the top of that rung"
assert_eq "$(js "L.snapIconSize(96, $STEPS)")" "48" "96 steps up to 48"
assert_eq "$(js "L.snapIconSize(191, $STEPS)")" "48" "...and holds it"
assert_eq "$(js "L.snapIconSize(192, $STEPS)")" "64" "192 reaches the largest step"
assert_eq "$(js "L.snapIconSize(2000, $STEPS)")" "64" "past it, it stops there rather than inventing a size"
# Below the smallest hinted size there is nothing to snap to, so a whole number of pixels is the
# best available answer - a fractional icon size is a Qt layout warning as well as a blurry icon.
assert_eq "$(js "L.snapIconSize(12, $STEPS)")" "12" "a cell below the smallest step gets whole pixels"
assert_eq "$(js "L.snapIconSize(12.7, $STEPS)")" "12" "...floored, never fractional"
assert_eq "$(js 'L.snapIconSize(40, [])')" "22" "an empty step list falls back to the built-in ladder, not to a stretched glyph"
assert_eq "$(js 'L.snapIconSize(44)')" "22" "...and so does calling it with no steps at all"
assert_eq "$(js "L.snapIconSize(0, $STEPS)")" "0" "a cell with no size asks for nothing"
assert_eq "$(js "L.snapIconSize(-5, $STEPS)")" "0" "...and neither does a negative one"
assert_eq "$(js "L.snapIconSize(undefined, $STEPS)")" "0" "a missing size is not an error"

# The named sizes are INDEXES into the theme's own step list, never literal pixel counts - a theme
# whose "small" is not 16 still gets its own hinted artwork rather than a number logic.js invented.
assert_eq "$(js 'L.resolveIconSize("small", 44)')" "16" "Small on an ordinary panel is the 16px step"
assert_eq "$(js 'L.resolveIconSize("medium", 44)')" "22" "Medium is 22, the same size the tray draws"
assert_eq "$(js 'L.resolveIconSize("large", 44)')" "32" "Large is 32 - what the widget used to do by accident"
assert_eq "$(js 'L.resolveIconSize("auto", 44)')" "22" "Automatic defers to the ladder"
assert_eq "$(js 'L.resolveIconSize("small", 44, [10,20,30,40,50])')" "10" \
  "a theme with its own steps supplies the pixels, not this file"
# A chosen size the cell cannot hold falls back to automatic rather than overflowing. This is what
# makes the system tray's cell win: the tray hands each entry a slot at ITS icon size, and an
# entry that drew 32px into a 22px slot would push every other tray icon around.
assert_eq "$(js 'L.resolveIconSize("large", 22)')" "22" "Large in a 22px tray slot gives way to the slot"
assert_eq "$(js 'L.resolveIconSize("medium", 16)')" "16" "...and Medium does the same in a 16px one"
assert_eq "$(js 'L.resolveIconSize("small", 22)')" "16" "a size that DOES fit is honoured, tray or panel"
assert_eq "$(js 'L.resolveIconSize("large", 0)')" "0" "before the panel has sized us, nothing is drawn"
# ...but a chosen size must never come out SMALLER than the one Automatic would have drawn, which
# is what `large` did on any cell the ladder had already climbed past. A 96px cell (a vertical dock,
# a HiDPI panel) autos to 48 while `large` names the 32px step, so picking Large made the icon
# smaller - the option contradicting its own label. Floored against auto; Small and Medium are not,
# because asking for less than Automatic is exactly what they are for.
assert_eq "$(js 'L.resolveIconSize("auto", 96)')" "48" "a 96px cell autos to the 48px step"
assert_eq "$(js 'L.resolveIconSize("large", 96)')" "48" "...and Large there is 48 too, never the 32 it names"
assert_eq "$(js 'L.resolveIconSize("auto", 192)')" "64" "a 192px cell autos to the largest step"
assert_eq "$(js 'L.resolveIconSize("large", 192)')" "64" "...and Large follows it up rather than dropping to 32"
assert_eq "$(js 'L.resolveIconSize("large", 96) >= L.resolveIconSize("auto", 96)')" "true" \
  "Large is never smaller than Automatic on a 96px cell"
assert_eq "$(js 'L.resolveIconSize("large", 192) >= L.resolveIconSize("auto", 192)')" "true" \
  "...nor on a 192px one"
assert_eq "$(js 'L.resolveIconSize("small", 96)')" "16" "Small on a big cell still means small"
assert_eq "$(js 'L.resolveIconSize("medium", 192)')" "22" "...and Medium still means the tray's own size"
assert_eq "$(js 'L.resolveIconSize("large", 64)')" "32" "the floor changes nothing where auto is already below it"
# The widget is the only validator this setting has: `kempt config set` stores whatever it is
# handed. Every unrecognised value means the same thing - decide it automatically, say nothing.
assert_eq "$(js 'L.resolveIconSize("bogus", 44)')" "22" "a value the widget does not know falls back to automatic"
assert_eq "$(js 'L.resolveIconSize("", 44)')" "22" "...and so does an empty answer from an older CLI"
assert_eq "$(js 'L.resolveIconSizeSetting("auto")')" "auto" "the four settings survive the validator"
assert_eq "$(js 'L.resolveIconSizeSetting("small")')" "small" "...small"
assert_eq "$(js 'L.resolveIconSizeSetting("medium")')" "medium" "...medium"
assert_eq "$(js 'L.resolveIconSizeSetting("large")')" "large" "...large"
assert_eq "$(js 'L.resolveIconSizeSetting("  LARGE  ")')" "large" "...case and whitespace and all"
assert_eq "$(js 'L.resolveIconSizeSetting("enormous")')" "auto" "an unknown value is auto"
assert_eq "$(js 'L.resolveIconSizeSetting("")')" "auto" "an empty value is auto"
assert_eq "$(js 'L.resolveIconSizeSetting(null)')" "auto" "a missing value is auto"
assert_eq "$(js 'L.resolveIconSizeSetting(undefined)')" "auto" "...and so is no value at all"
# Object.prototype keys are not settings. `toString` is a property of every object in JavaScript,
# so a naive `key in table` lookup answers yes for it - and the index it would then read is a
# function, which reaches Kirigami as an icon size.
assert_eq "$(js 'L.resolveIconSizeSetting("toString")')" "auto" "an inherited property name is not a setting"
assert_eq "$(js 'L.resolveIconSize("toString", 44)')" "22" "...and does not reach the icon as a size"

# --- the watcher stamp: WHICH path moved, not merely that one did -------------------------------
# main.qml polls four mtimes every 30 seconds: /var/lib/rpm, /var/lib/flatpak, our state file, our
# config file - in that order. Comparing the stamp as ONE string says only that something moved,
# and /var/lib/rpm moves continuously all the way through a dnf transaction. So a run of ours
# "finished" about thirty seconds after it started: the spinner stopped, a summary of the PREVIOUS
# run appeared, and a `kempt check` went off to queue for the dnf lock the transaction was holding.
# Only field 2 - our own state file, which the CLI rewrites on its way out of a run - ends a run.
assert_eq "$(js 'L.watchChange("1 2 3 4","1 2 3 4").any')" "false" \
  "an unchanged stamp is not a change"
assert_eq "$(js 'L.watchChange("1 2 3 4","9 2 3 4").state')" "false" \
  "the rpm database moving does NOT mean a run ended"
assert_eq "$(js 'L.watchChange("1 2 3 4","9 2 3 4").packages')" "true" \
  "...it is a package-database change, which is what it is"
assert_eq "$(js 'L.watchChange("1 2 3 4","1 9 3 4").state')" "false" \
  "...and neither does flatpak's"
assert_eq "$(js 'L.watchChange("1 2 3 4","1 2 9 4").state')" "true" \
  "our own state file moving DOES mean a run ended"
assert_eq "$(js 'L.watchChange("1 2 3 4","1 2 9 4").packages')" "false" \
  "...and it is not reported as a package change"
assert_eq "$(js 'L.watchChange("1 2 3 4","1 2 3 9").config')" "true" \
  "the config file moving is a config change - the settings page's only way in"
assert_eq "$(js 'L.watchChange("1 2 3 4","1 2 3 9").state')" "false" \
  "...and does not end a run either"
assert_eq "$(js 'L.watchChange("1 2 3 4","9 2 9 4").state')" "true" \
  "a transaction that ALSO wrote state.json still ends the run"
assert_eq "$(js 'L.watchChange("1 2 3 4","9 2 9 4").packages')" "true" \
  "...and still reports the package change alongside it"
# The padding in watchCmd is what makes those field numbers mean anything: `stat` prints NOTHING
# for a path that does not exist, so an unpadded stamp on a box with no flatpak has three fields
# and state.json is read in the flatpak column - every state write attributed to the package
# database, and every dnf write read as the end of a run.
assert_exit 0 "the watch command pads every path, so a missing one cannot shift the fields" -- \
  grep -q 'stat -c %Y .* || echo 0' "$REPO_ROOT/plasmoid/contents/ui/main.qml"
assert_exit 0 "...and the watcher compares those fields rather than the whole string" -- \
  grep -q 'Logic.watchChange(' "$REPO_ROOT/plasmoid/contents/ui/main.qml"
assert_eq "$(js 'L.watchChange("1 3 4","1 9 4").comparable')" "false" \
  "a stamp that is not four fields is not compared field-wise"
assert_eq "$(js 'L.watchChange("1 3 4","1 9 4").state')" "true" \
  "...it degrades to the old any-change answer instead of guessing which column is which"
assert_eq "$(js 'L.watchChange("","1 2 3 4").any')" "false" "no baseline is not a change"
assert_eq "$(js 'L.watchChange("1 2 3 4",undefined).any')" "false" "...and no answer is not one either"
assert_eq "$(js 'L.watchFieldsOf("  1   2  3 4  ").length')" "4" \
  "runs of whitespace between the mtimes do not invent fields"

# --- the quiet window after a check: a run's wake is not news -----------------------------------
# The same watcher, one step further on. A run rewrites /var/lib/rpm all the way through the
# transaction and then state.json on its way out, so the 30-second poll kept finding that footprint
# for a minute after the post-run check had already accounted for all of it. Measured on a real run
# (2026-08-28): three `widget check ok` lines at 00:36:53, 00:37:24 and 00:37:30 - each cache-only,
# and two of the three describing nothing that had changed since the first.
assert_eq "$(js 'L.CHECK_QUIET_MS')" "60000" "the quiet window is a minute"
assert_eq "$(js 'L.watcherCheckDue(1000000, 1000000 + 1000)')" "false" \
  "a watcher tick one second after a check is that check's own wake"
assert_eq "$(js 'L.watcherCheckDue(1000000, 1000000 + 59999)')" "false" \
  "...and so is one a millisecond inside the window"
assert_eq "$(js 'L.watcherCheckDue(1000000, 1000000 + 60000)')" "true" \
  "a tick at the window's edge is news again"
assert_eq "$(js 'L.watcherCheckDue(1000000, 1000000 + 600000)')" "true" \
  "...and long after it, obviously"
# Before any check has completed there is no footprint of ours for a change to be, so nothing is
# suppressed. This is the fresh-login case, where the widget has the most to learn and the least
# reason to sit quiet.
assert_eq "$(js 'L.watcherCheckDue(0, 1000000)')" "true" "with no check behind us, nothing is suppressed"
assert_eq "$(js 'L.watcherCheckDue(null, 1000000)')" "true" "...and neither is it on a missing stamp"
assert_eq "$(js 'L.watcherCheckDue(undefined, 1000000)')" "true" "...or no stamp at all"
# A clock that moved backwards - an NTP correction, a resume from suspend - must never silence the
# widget. The window is an optimisation; one that can suppress every check indefinitely is not.
assert_eq "$(js 'L.watcherCheckDue(2000000, 1000000)')" "true" \
  "a clock that moved backwards never suppresses a check"
assert_eq "$(js 'L.watcherCheckDue(NaN, 1000000)')" "true" "...nor does a stamp that is not a number"
assert_eq "$(js 'L.watcherCheckDue(1000000, NaN)')" "true" "...nor a now that is not one"
# Structural, because the rule is only worth anything where it is applied: main.qml must consult it
# on the watcher's path, and the config field must stay exempt - the settings page has no other way
# into that file, and docs/usage.md promises the panel catches up within 30 seconds.
assert_exit 0 "the watcher's check is gated on it" -- \
  grep -q 'Logic.watcherCheckDue(root.lastCheckFinished' "$REPO_ROOT/plasmoid/contents/ui/main.qml"
assert_exit 0 "...with a config change exempt, so a settings apply still lands within 30 seconds" -- \
  grep -q 'if (endedRun || delta.config' "$REPO_ROOT/plasmoid/contents/ui/main.qml"
# ...and the post-run check exempt with it, which is the one the window must never eat: a run that
# took twenty seconds after a popup-open check ends well inside the minute, and that is exactly
# when the counts on screen are most wrong. Read before leaveUpdating clears `updating`, or the
# test passes and the behaviour does not.
assert_exit 0 "...and the post-run check exempt, read before the run state is cleared" -- \
  grep -q 'var endedRun = delta.state && root.updating;' "$REPO_ROOT/plasmoid/contents/ui/main.qml"
assert_exit 0 "...and every completed check stamps the window it opens" -- \
  grep -q 'root.lastCheckFinished = Date.now();' "$REPO_ROOT/plasmoid/contents/ui/main.qml"

# --- the settings page's apply path -------------------------------------------------------------
# These are structural rather than behavioural - the page needs a real QML engine to drive, which
# the suite does not have. Each one pins a fix whose absence is silent: the page still opens, still
# looks right, and quietly does the wrong thing.
CFG="$REPO_ROOT/plasmoid/contents/ui/configGeneral.qml"
# A comment-stripped copy for the assertions below that say a thing must NOT be there. Each of
# those things is explained in a comment where it used to be - which is the point of the comment -
# and a grep that cannot tell an explanation from code would forbid explaining anything.
CFGCODE="$TESTTMP/configGeneral.code.qml"
sed 's://.*::' "$CFG" > "$CFGCODE"
# The dialog enables Apply on `cfg_<key>Changed`, `configurationChanged` or `unsavedChanges`, and
# this page has no cfg_ properties by design - so without the third hook Apply is permanently grey
# and closing the dialog discards everything without asking.
assert_exit 0 "the page declares the unsavedChanges property the config dialog reads" -- \
  grep -q '^ *property bool unsavedChanges' "$CFG"
assert_exit 0 "...and every control arms it through markChanged()" -- \
  grep -q 'function markChanged(' "$CFG"
for h in 'onToggled: page.markChanged("include_flatpak")' \
         'onToggled: page.markChanged("auto_accept")' \
         'page.markChanged("surface")' \
         'onValueModified: page.markChanged("refresh_interval_min")'; do
  grep -qF "$h" "$CFG" && echo "ok: a user change arms Apply: $h" \
    || { echo "FAIL: no handler arms Apply for: $h"; _fail=1; }
done
# Apply before the async reads land would write the page's own defaults over the stored settings.
assert_exit 0 "saveConfig refuses to write while the settings are still being read" -- \
  grep -q 'if (page.pendingReads > 0) return;' "$CFG"
assert_exit 0 "...and the controls are disabled until they land" -- \
  grep -q 'readonly property bool loading: pendingReads > 0' "$CFG"
# A read that failed leaves a control showing a default. Writing that over an unread stored value
# is the same bug by another route.
assert_exit 0 "a failed read is remembered, not just reported" -- \
  grep -q 'page.readFailed\[key\] = true;' "$CFG"
assert_exit 0 "...and an untouched key that was never read is not written" -- \
  grep -q 'if (page.readFailed\[key\] && !page.touched\[key\]) return;' "$CFG"
# `config set` is remembered as the stored value only once the CLI says it worked. Recorded before
# the call - as it was - a FAILED write is remembered as a success: the next Apply compares equal,
# writes nothing, and the setting silently stays as it was with no retry possible.
_set_ln="$(grep -n 'config set " + key' "$CFG" | head -1 | cut -d: -f1)"
_rec_ln="$(grep -n 'page.loaded\[key\] = value;' "$CFG" | head -1 | cut -d: -f1)"
_fail_ln="$(awk -v s="${_set_ln:-0}" 'NR > s && /if \(rc !== 0\) \{/ { print NR; exit }' "$CFG")"
if [[ -n "$_set_ln" && -n "$_rec_ln" && -n "$_fail_ln" && "$_rec_ln" -gt "$_fail_ln" ]]; then
  echo "ok: the stored value is recorded only after the CLI answered, past the failure branch"
else
  echo "FAIL: setIfChanged records the stored value before knowing the write worked"
  echo "    (config set line=${_set_ln:-none} rc-check=${_fail_ln:-none} record=${_rec_ln:-none})"
  _fail=1
fi
# The stored surface is a preference, not a run-time decision. Collapsing it to terminal here
# rewrote a setting the user never touched (bin/kempt's cmd_run applies the lock at run time).
assert_exit 1 "Apply stores the surface the user chose, lock or no lock" -- \
  grep -q 'surfacesLocked ? "terminal"' "$CFGCODE"
assert_exit 1 "...and switching confirmation on does not discard that choice" -- \
  grep -q 'onSurfacesLockedChanged' "$CFGCODE"

# --- no shadow settings ------------------------------------------------------------------------
# The settings page is a front-end to `kempt config` and nothing else. A KConfig entry here would
# be a second copy of a setting the CLI also owns, and the two would drift the first time somebody
# typed `kempt config set` in a terminal. The plasmoid must therefore declare NO keys at all.
XML="$REPO_ROOT/plasmoid/contents/config/main.xml"
assert_eq "$(grep -c '<entry' "$XML")" "0" "the plasmoid declares no KConfig entries of its own"
# The comment-stripped copy again: the page's header explains WHY it has no cfg_ properties (they
# are one of the three hooks the shell watches to enable Apply, and this page uses the third).
assert_eq "$(grep -c 'cfg_' "$CFGCODE")" "0" \
  "...and the settings page uses no cfg_ auto-binding, which would need them"
assert_exit 0 "the kcfg skeleton is still well-formed XML" -- python3 -c "
import xml.dom.minidom, sys; xml.dom.minidom.parse('$XML')"
# Every key the page writes is a key the CLI actually knows: a typo here would write a setting
# nothing ever reads, and the page would look like it worked.
#
# The list is READ OUT OF THE PAGE rather than repeated here. A hardcoded list only proves the
# keys somebody remembered to add to it, and the failure it is meant to catch - a new control
# writing a key the CLI has no default for - is exactly the case where nobody remembers.
PAGE_KEYS="$(grep -o 'setIfChanged("[a-z_]*"' "$REPO_ROOT/plasmoid/contents/ui/configGeneral.qml" \
             | cut -d'"' -f2 | sort -u)"
assert_eq "$(wc -l <<<"$PAGE_KEYS")" "6" "the settings page writes six settings"
for key in $PAGE_KEYS; do
  assert_eq "$(kempt_default "$key" | head -c 1 | wc -c)" "1" "the CLI has a default for $key, which the page writes"
done
# ...and every key it writes, it also READS - so the page opens on the stored value instead of on
# a QML default, and Apply has something real to compare against. A write-only key is how a
# settings page quietly replaces a setting the user made somewhere else.
for key in $PAGE_KEYS; do
  { grep -q "readKey(\"$key\"" "$REPO_ROOT/plasmoid/contents/ui/configGeneral.qml" \
    || grep -q "config get $key" "$REPO_ROOT/plasmoid/contents/ui/main.qml"; } \
    && echo "ok: $key is read back before it is written" \
    || { echo "FAIL: $key is written but never read"; _fail=1; }
done
# The panel icon's size is the one setting BOTH files need: the page writes it, and main.qml has
# to re-read it or the icon would not change until plasmashell restarted.
grep -q "config get widget_icon_size" "$REPO_ROOT/plasmoid/contents/ui/main.qml" \
  && echo "ok: the panel icon re-reads its own size setting" \
  || { echo "FAIL: main.qml never reads widget_icon_size"; _fail=1; }

# --- the system tray entry ----------------------------------------------------------------------
# What makes the widget offerable INSIDE the system tray rather than only as a standalone panel
# item. The tray builds its Entries list by listing every Plasma/Applet package and keeping the
# ones that declare a notification-area category; nothing else about the package changes.
META="$REPO_ROOT/plasmoid/metadata.json"
assert_exit 0 "the package metadata is still valid JSON" -- jq -e . "$META"
assert_eq "$(jq -r '.["X-Plasma-NotificationAreaCategory"] // ""' "$META")" "SystemServices" \
  "the widget declares itself a system-tray entry under System Services"
assert_eq "$(jq -r '.["X-Plasma-NotificationArea"] // ""' "$META")" "true" \
  "...and carries the older boolean too, which is what every shipped tray applet still does"
assert_eq "$(jq -r '.KPlugin.EnabledByDefault' "$META")" "true" \
  "...and is on by default there, so installing it is all a user has to do"
# Both keys are TOP-LEVEL. Inside KPlugin they parse fine, mean nothing, and the widget simply
# never appears in the tray - a failure with no error message anywhere.
assert_eq "$(jq -r '.KPlugin | has("X-Plasma-NotificationAreaCategory")' "$META")" "false" \
  "...declared at the top level, where the tray reads them, not inside KPlugin"
# Checked against what this box actually ships rather than against a remembered convention: if
# Plasma's own tray-capable widgets are installed here, ours must spell the key the way they do
# and pick a category one of them uses.
KDE_TRAY_META="$(grep -l 'X-Plasma-NotificationAreaCategory' /usr/share/plasma/plasmoids/*/metadata.json 2>/dev/null || true)"
if [[ -z "$KDE_TRAY_META" ]]; then
  echo "ok: SKIPPED - no Plasma tray applet on this box to compare the metadata convention against"
else
  # shellcheck disable=SC2086
  KDE_CATEGORIES="$(jq -r '.["X-Plasma-NotificationAreaCategory"]' $KDE_TRAY_META | sort -u)"
  grep -qx "$(jq -r '.["X-Plasma-NotificationAreaCategory"]' "$META")" <<<"$KDE_CATEGORIES" \
    && echo "ok: the category is one Plasma's own tray applets use on this box" \
    || { echo "FAIL: category not among $(tr '\n' ' ' <<<"$KDE_CATEGORIES")"; _fail=1; }
fi

# ui_grep <extended-regex> -> every line under plasmoid/ matching it, COMMENTS STRIPPED, prefixed
# `path:lineno:`. Comments come out first (`sed 's://.*::'`) because they are not user-facing and
# this project's comments talk about the very wordings these scans forbid.
ui_grep() {
  find "$REPO_ROOT/plasmoid" \( -name '*.qml' -o -name '*.js' \) -print0 \
  | while IFS= read -r -d "" f; do
      sed 's://.*::' "$f" | grep -nE "$1" | sed "s|^|${f#"$REPO_ROOT/"}:|"
    done
}

# --- one action, one sentence: unholding --------------------------------------------------------
# The popup's pin and the settings page's remove button do the same thing - `kempt unhold` on one
# package - and said it in two different sentences: "Stop holding %1" on the pin, "Stop holding %1
# back" on the page. Nothing is held BACK. A hold is the user's own decision to keep a package
# where it is, and the footer's held count is worded off the same rule ("1 held", never "held
# back"). Two spellings of one action is one too many, so both are pinned to the same literal.
assert_eq "$(ui_grep 'i18n\("Stop holding %1", ' | wc -l)" "2" \
  "the pin and the settings page say Stop holding in exactly the same words"
assert_eq "$(ui_grep 'holding [^"]*back|held back' | wc -l)" "0" \
  "...and nothing in the widget tells a person their packages are being held BACK"

# --- the rebuild action's words are the copy table's words --------------------------------------
# COPY is the SPECIFICATION and the QML repeats each literal, because i18n() extracts literals and
# i18n(someVariable) extracts nothing at all (see the copy table's own header). That duplication is
# deliberate and it is exactly the kind that drifts, so the two halves are tied together here: the
# label and the tooltip a person reads have to be character for character what the tests pinned.
# ui_grep is deliberately NOT the tool here: it walks logic.js too, and logic.js is where these
# literals are DECLARED - so it would answer "found it" for a QML file that never wrote them. The
# .qml files alone are the question.
for _lit in stagedRebuildAction stagedRebuildTooltip; do
  assert_eq "$(find "$REPO_ROOT/plasmoid" -name '*.qml' -exec grep -hoF "i18n(\"$(js "L.COPY.$_lit")\")" {} + | wc -l)" "1" \
    "the popup writes COPY.$_lit verbatim, as a literal a translator can extract"
done
# The tooltip is the accessible description as well, and that is the load-bearing half: a polkit
# dialog takes focus the moment the button is pressed, so a screen-reader user who has not heard
# the authorization and the discard cost by then hears them never (spec, UX finding 9).
assert_eq "$(ui_grep 'Accessible\.description: tooltip' | wc -l)" "1" \
  "...and the rebuild action says the same words to a screen reader as to a mouse"
# The flip has to arrive as WORDS, not as a colour: Kirigami gives every InlineMessage the
# AlertMessage role and no name, so without this a screen reader announces "Warning" and nothing
# about what happened. Every message in the stack carries it; this counts them rather than trusting
# the one that was added last.
#
# Bounded at both ends rather than counted over the whole file, and that is not tidiness: the
# header's own icon-only buttons spell their names out too (a probe measured an EMPTY accessible
# name on every button here when accessibility was active before construction), so a whole-file
# count would be satisfied by those and pass with a message carrying nothing. The stack is one
# contiguous run between the first InlineMessage and the list.
STACK="$TESTTMP/message-stack.qml"
awk '/Kirigami\.InlineMessage \{/ { f = 1 } /--- the list, and what stands in for it/ { f = 0 } f' \
  "$REPO_ROOT/plasmoid/contents/ui/FullRepresentation.qml" > "$STACK"
assert_eq "$([[ -s "$STACK" ]] && echo yes || echo no)" "yes" \
  "premise: the popup still has a message stack to scan"
assert_eq "$(grep -c 'Accessible.name: text' "$STACK")" "$(grep -c 'Kirigami.InlineMessage {' "$STACK")" \
  "every message in the popup's stack announces its own text to a screen reader"
# ...and the type is BOUND to the derived variant rather than declared. A hard-coded Positive here
# is the bug this whole change exists to remove, and it is one careless edit away.
assert_eq "$(grep -c 'popup.vm.stagedType === "warning"' "$REPO_ROOT/plasmoid/contents/ui/FullRepresentation.qml")" "1" \
  "...and the staged banner takes its type from the view model, never from a literal"

# --- no three ASCII dots anywhere a person can read ---------------------------------------------
# KDE's own convention, and the one typographic tell that a widget was not written by KDE
# (docs/research/2026-08-26-popup-panel/hig-review.md P5): an ellipsis is U+2026, not three
# periods. The popup already got this right on the configure button and wrong in four other
# places, which is exactly the shape a convention takes when nothing enforces it - so this is the
# enforcement rather than another round of finding them by eye.
#
# Comments are stripped by ui_grep above, because they are not user-facing and this project's
# comments are full of "...". The one allowed literal is logic.js's `", ..."`: it MIRRORS the
# CLI's notification text, which is plain ASCII by choice, and the two must not drift apart.
ELLIPSIS_ALLOW='? ", ..." :'
ellipsis_hits="$(ui_grep '\.\.\.' | grep -vF "$ELLIPSIS_ALLOW" || true)"
if [[ -z "$ellipsis_hits" ]]; then
  echo "ok: no three-dot ellipsis in any string the widget shows a person"
else
  echo "FAIL: three ASCII dots in a user-facing string - use U+2026"
  sed 's/^/    /' <<<"$ellipsis_hits"
  _fail=1
fi
# ...and the guard has to be able to SEE one, or it is a test that passes because it looks nowhere.
assert_eq "$(printf 'text: i18n("Wait...")\n' | sed 's://.*::' | grep -c '\.\.\.')" "1" \
  "the ellipsis scan finds three dots in a line it is given"

# --- docs/usage.md has to describe the widget that is here --------------------------------------
# Doc drift is not a documentation problem, it is a truth problem: the popup section is what a
# person reads INSTEAD of watching the code, so a sentence that was true of an earlier build is
# just a wrong answer with a nice tone. These tie the paragraphs the 2026-08-27 review found wrong
# back to the code that decides them.
USAGE="$REPO_ROOT/docs/usage.md"

# Every fixed header wording the view model can produce is DERIVED here rather than typed, so a
# reworded header fails this instead of quietly leaving the page describing the old words. (The
# count phrases - "3 updates available" - are built around a number and are shown by example.)
while IFS= read -r hw; do
  [[ -z "$hw" ]] && continue
  if grep -qF -- "$hw" "$USAGE"; then
    echo "ok: docs/usage.md names the header wording \"$hw\""
  else
    echo "FAIL: docs/usage.md never mentions the header wording \"$hw\""; _fail=1
  fi
done <<EOF
$(js 'L.viewModel({schema:1,status:"ok",actionable:0,held_total:0,backends:{}},false).headerText')
$(js 'L.viewModel(null,true).headerText')
$(js 'L.viewModel(null,false).headerText')
$(js 'L.viewModel(null,false,"kempt: command not found").headerText')
$(js 'L.viewModel(null,false,"",{engineMissing:true}).headerText')
$(js 'L.viewModel({schema:2,status:"ok",actionable:1,held_total:0,backends:{}},false).headerText')
EOF

# ...and docs/install.md is where a store-first user lands, so the sentence it promises them is
# the sentence the widget actually shows. Derived, not typed, for the same reason as the headers.
INSTALL_DOC="$REPO_ROOT/docs/install.md"
assert_eq "$(grep -cF "$(js 'L.COPY.engineMissing')" "$INSTALL_DOC")" "1" \
  "docs/install.md quotes the message a widget with no engine really shows"
assert_eq "$(grep -cF "$(js 'L.COPY.engineMissingInstall')" "$INSTALL_DOC")" "1" \
  "...and the install line under it, character for character"

# The coalescing sentence. main.qml's doCheck sets recheckPending and runs a SECOND full check
# when one is already in flight - deliberately, because the running check read the system before
# whatever prompted this request. The page used to say the opposite.
assert_eq "$(grep -c 'waits for that one rather than starting a second' "$USAGE")" "0" \
  "usage.md no longer claims the popup waits for a running check instead of asking again"
assert_eq "$(grep -c 'the popup.s request is \*remembered\*' "$USAGE")" "1" \
  "...it describes the coalescing the code actually does"

# Show Log is bound to the entry HAVING a log path (FullRepresentation.qml), and an offline
# harvest entry has none - so "each with Show Log" was a promise the popup does not keep.
assert_eq "$(grep -c 'each with \*\*Show Log\*\*' "$USAGE")" "0" \
  "usage.md no longer promises Show Log on every post-run message"
assert_eq "$(grep -c 'when that run recorded a log' "$USAGE")" "1" \
  "...it says when the button is there instead"
assert_eq "$(grep -c 'lastRun.logPath.length > 0' "$REPO_ROOT/plasmoid/contents/ui/FullRepresentation.qml")" "2" \
  "...and the QML really does bind both Show Log buttons to a log path being present"

# The staged banner has three spellings now, and the page has to describe the one a worried person
# will actually be looking at. Derived from the copy table rather than typed, so a reworded banner
# fails here instead of quietly leaving the page describing the old words. The two sentences with a
# package name in them are checked by their fixed halves: the name is the variable part.
for _lit in stagedChanged stagedConflictUnknown; do
  assert_eq "$(grep -cF "$(js "L.COPY.$_lit")" "$USAGE")" "1" \
    "docs/usage.md quotes COPY.$_lit as the popup really says it"
done
# Presence rather than a count for the button's own name: it is a LABEL, and a label belongs both
# in the prose and in the sketches of the banner it sits on. Counting it would make drawing the
# widget twice a test failure.
assert_eq "$(grep -qF "$(js 'L.COPY.stagedRebuildAction')" "$USAGE" && echo yes || echo no)" "yes" \
  "docs/usage.md calls the action by the name on the button"
assert_eq "$(grep -c 'Staged before your hold - ' "$USAGE")" "1" \
  "...the singular conflict banner too"
assert_eq "$(grep -c 'still install on the next restart\.' "$USAGE")" "1" \
  "...and the plural one"
# The tooltip is where the authorization and the discard cost are disclosed, so the page must carry
# both facts where a widget user will read them. Scoped to the popup section rather than the whole
# page: the CLI's own section already discloses the same two costs for `kempt update
# --surface=offline`, and a whole-file count would be satisfied by that one and pass with the popup
# section saying nothing at all.
POPUP_DOC="$TESTTMP/usage-popup.md"
awk '/^### The popup$/ { f = 1; next } /^### / { f = 0 } f' "$USAGE" > "$POPUP_DOC"
assert_eq "$([[ -s "$POPUP_DOC" ]] && echo yes || echo no)" "yes" \
  "premise: docs/usage.md still has a popup section to read"
assert_eq "$(grep -c 'asks for authorization' "$POPUP_DOC")" "1" \
  "the popup section says the rebuild asks for authorization"
assert_eq "$(grep -c 'removes the current staged update' "$POPUP_DOC")" "1" \
  "...and that a rebuild that fails removes the staged update it was replacing"
assert_eq "$(grep -c 'never edits a stored transaction\|cannot edit a stored transaction\|no way to edit a stored' "$POPUP_DOC")" "1" \
  "...and that the pin never reaches into a transaction dnf5 has already stored"
# The measured truth, kept out of the docs as firmly as out of the copy: a replace-stage reuses
# dnf5's package cache (spec G8), so nothing anywhere may promise a re-download.
assert_eq "$(grep -ciE 're-?downloads? the (staged|transaction)' "$USAGE" || true)" "0" \
  "...and nothing on the page claims a rebuild downloads it all again"

qml_check
finish
