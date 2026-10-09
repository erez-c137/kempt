#!/usr/bin/env bash
# Every sentence Kempt shows a person follows the writing rules in CONTRIBUTING.md. This file
# collects that text and fails on what the rules ban: an em or en dash, a " - " aside, the word
# "popup", and the code words surface, harvest, seam, arm and backend.
#
# Three sources, each read the way the program itself reads it:
#   1. the widget's copy table and the sentences the view model assembles, from logic.js under node;
#   2. every i18n()/i18nc() literal in the .qml files;
#   3. the CLI's failure reasons, notifications, warnings and `kempt doctor` rows.
source "$(dirname "$0")/lib.sh"; sandbox
UI="$REPO_ROOT/plasmoid/contents/ui"
TEXT="$TESTTMP/onscreen.tsv"   # source<TAB>text, one line per string

# --- 1. logic.js -------------------------------------------------------------------------------
if command -v node >/dev/null 2>&1; then
  node -e '
    const fs = require("fs");
    const L = require(process.argv[1]);
    const out = [];
    const add = (src, s) => { if (typeof s === "string" && s !== "") out.push(src + "\t" + s.replace(/\n/g, " ")); };
    for (const [k, v] of Object.entries(L.COPY)) add("COPY." + k, v);
    // The sentences the view model builds out of the copy, for every state fixture, idle and
    // updating, plus the no-data state.
    const FIELDS = ["tooltipMain", "tooltipSub", "headerText", "emptyStateText", "riskySummary",
      "riskyMessage", "stagedMessage", "releaseUpgradeMessage", "imageBasedMessage", "footerText",
      "footerTooltip", "reclaimMessage", "engineFaultMessage"];
    const states = [["null", null]];
    for (const f of fs.readdirSync(process.argv[2]).filter((f) => /^state-.*\.json$/.test(f)))
      states.push([f, L.parseState(fs.readFileSync(process.argv[2] + "/" + f, "utf8"))]);
    for (const [name, st] of states)
      for (const u of [false, true]) {
        const vm = L.viewModel(st, u);
        for (const k of FIELDS) add("viewModel(" + name + (u ? ", updating" : "") + ")." + k, vm[k]);
      }
    // The sentences built from a finished run or a command'"'"'s answer, which the state fixtures
    // never reach. A builder that throws on one of these inputs is skipped, not fatal: this test
    // checks words, test_widget_logic.sh checks behavior.
    const addAny = (src, v) => {
      if (typeof v === "string") add(src, v);
      else if (v && typeof v === "object")
        for (const [k, s] of Object.entries(v)) if (typeof s === "string") add(src + "." + k, s);
    };
    const tryAdd = (src, fn) => { try { addAny(src, fn()); } catch (e) { /* see above */ } };
    const at = "2026-10-01T10:00:00Z", now = Date.parse(at) + 3600 * 1000;
    const pkg = (n) => ({ name: n, from: "1.0-1", to: "1.1-1" });
    const RUNS = {
      success: { status: "ok", surface: "terminal", timestamp: at, duration_sec: 95,
                 backends: { dnf: { updated: [pkg("bash"), pkg("kernel")], added: [pkg("x")], removed: [] },
                             flatpak: { updated: [pkg("org.example.App")] } }, reboot_needed: true },
      failed: { status: "failed", surface: "background", timestamp: at, duration_sec: 12,
                error: "dnf could not reach the mirror\nsecond line", backends: {} },
      staged: { status: "ok", surface: "offline", timestamp: at, duration_sec: 40,
                backends: { dnf: { updated: [pkg("bash")] } }, reboot_needed: true },
      held: { status: "ok", surface: "offline", timestamp: at, staged_nothing: "held", backends: {} },
      nothing: { status: "ok", surface: "offline", timestamp: at, staged_nothing: "nothing_pending", backends: {} },
      reclaimed: { status: "ok", surface: "terminal", timestamp: at, duration_sec: 30,
                   backends: { flatpak: { updated: [pkg("org.example.App")],
                     reclaimed: { status: "removed", refs: ["a", "b"], bytes: 300000000, in_use: ["c"] } } } },
    };
    for (const [name, json] of Object.entries(RUNS)) {
      const run = L.lastRunOf(JSON.stringify(json));
      tryAdd("postRunLine(" + name + ")", () => L.postRunLine(run));
      tryAdd("lastRunText(" + name + ")", () => L.lastRunText(run, now));
      tryAdd("lastRunSubtitle(" + name + ")", () => L.lastRunSubtitle(run, ""));
    }
    tryAdd("doctorOutcomeOf(1, one FAIL)", () => L.doctorOutcomeOf(1, "FAIL  the helper is missing\n", ""));
    for (const rc of [0, 1, 3, 5, 75, 124]) {
      tryAdd("runStartMessage(" + rc + ")", () => L.runStartMessage(rc, "", ""));
      tryAdd("discardStagedMessage(" + rc + ")", () => L.discardStagedMessage(rc, "", ""));
      tryAdd("doctorOutcomeOf(" + rc + ")", () => L.doctorOutcomeOf(rc, "", ""));
      for (const result of ["removed", "needs_auth", "partial", "failed"]) {
        const last = { at: at, result: result, bytes: 300000000, refs: result === "partial" ? null : ["a"], in_use: ["c"] };
        tryAdd("reclaimOutcomeOf(" + rc + ", " + result + ")",
          () => L.reclaimOutcomeOf(rc, "", "", last, Date.parse(at)));
      }
    }
    process.stdout.write(out.join("\n") + "\n");
  ' "$UI/logic.js" "$FIXTURES" > "$TEXT"
  assert_eq "$(grep -c '^postRunLine(failed)' "$TEXT")" "1" "the sentences built from a run are collected"
  assert_eq "$(grep -c '^COPY\.' "$TEXT")" "$(node -e 'console.log(Object.keys(require(process.argv[1]).COPY).length)' "$UI/logic.js")" \
    "every entry in the copy table is collected"
else
  skip "node is not installed, so the widget's copy table was NOT checked in this run"
  : > "$TEXT"
fi

# --- 2. the .qml literals ----------------------------------------------------------------------
# The text argument of i18n() and i18nc(), with adjacent literals joined by + put back together,
# and the plain literals main.qml assigns to a message property. A // comment line is skipped.
python3 - "$UI" >> "$TEXT" <<'PY'
import glob, os, re, sys
lit = re.compile(r'\s*"((?:[^"\\]|\\.)*)"\s*')
def literals(src, pos):
    parts = []
    while True:
        m = lit.match(src, pos)
        if not m: return "".join(parts), pos
        parts.append(m.group(1)); pos = m.end()
        if src.startswith("+", pos): pos += 1
        else: return "".join(parts), pos
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.qml"))):
    src = open(f, encoding="utf-8").read()
    for m in re.finditer(r'\b(i18nc?)\s*\(', src):
        line_start = src.rfind("\n", 0, m.start()) + 1
        if "//" in src[line_start:m.start()]: continue
        text, pos = literals(src, m.end())
        if m.group(1) == "i18nc" and src.startswith(",", pos):
            text, pos = literals(src, pos + 1)
        if text:
            n = src.count("\n", 0, m.start()) + 1
            print(f"{os.path.basename(f)}:{n}\t{text}")
    for m in re.finditer(r'\b\w*[Mm]essage\s*=(?!=)', src):
        line_start = src.rfind("\n", 0, m.start()) + 1
        if "//" in src[line_start:m.start()]: continue
        text, _ = literals(src, m.end())
        if text:
            n = src.count("\n", 0, m.start()) + 1
            print(f"{os.path.basename(f)}:{n}\t{text}")
PY
assert_eq "$(grep -c '\.qml:' "$TEXT" | awk '{print ($1 > 50)}')" "1" "the .qml literals were collected"
assert_eq "$(grep -c 'stopped waiting for the update to report back' "$TEXT")" "1" "main.qml's own messages are collected"

# --- 3. the CLI ---------------------------------------------------------------------------------
# The first double-quoted argument of the calls that put a sentence in front of a person, and the
# sentences kept in variables. Shell expansions are blanked first: `$seam` and `${a#--surface=}`
# are code.
python3 - "$REPO_ROOT" >> "$TEXT" <<'PY'
import os, re, sys
CALLS = re.compile(r'(?:\b(?:notify\s+"Kempt"|preflight_abort|doctor_(?:ok|info|warn|fail)'
                   r'|log_warn\s+"\$log"|echo)\s+|\breason_override=)"((?:[^"\\]|\\.)*)"')
VARS = re.compile(r"^(KEMPT_AUTH_\w+|KEMPT_STAGED_RECIPE)='([^']*)'", re.M)
# KEMPT_BUSY_TRY_AGAIN="...", notify_tail="...", tail_advice="...": a sentence or its ending.
# KEMPT_CONFIG_KEYS is the list of config key names, typed as they are, so it is not text.
DQVARS = re.compile(r'(?:^|[\s;&(])((?:KEMPT_[A-Z_]+|\w+_(?:tail|advice)))="((?:[^"\\]|\\.)*)"')
PRINTF = re.compile(r"printf '([^']*\b[a-z]+ [a-z]+ [a-z]+[^']*)'")
def unexpand(s):
    out, i = [], 0
    while i < len(s):
        if s.startswith("$(", i) or s.startswith("${", i):
            close = ")" if s[i + 1] == "(" else "}"
            opn = s[i + 1]; depth = 0; j = i + 1
            while j < len(s):
                if s[j] == opn: depth += 1
                elif s[j] == close:
                    depth -= 1
                    if depth == 0: break
                j += 1
            out.append("X"); i = j + 1
        else:
            out.append(s[i]); i += 1
    return re.sub(r"\$[A-Za-z_][A-Za-z0-9_]*", "X", "".join(out))
root = sys.argv[1]
for rel in ("bin/kempt", "lib/common.sh", "backends/dnf.sh", "backends/flatpak.sh"):
    src = open(os.path.join(root, rel), encoding="utf-8").read()
    for n, line in enumerate(src.split("\n"), 1):
        if line.lstrip().startswith("#"): continue
        for m in CALLS.finditer(line):
            text = unexpand(m.group(1))
            if len(text.split()) >= 3: print(f"{rel}:{n}\t{text}")
        for m in DQVARS.finditer(line):
            if m.group(1) == "KEMPT_CONFIG_KEYS": continue
            text = unexpand(m.group(2))
            if len(text.split()) >= 3: print(f"{rel}:{n}\t{text}")
        for m in PRINTF.finditer(line):
            print(f"{rel}:{n}\t{unexpand(m.group(1))}")
    for m in VARS.finditer(src):
        print(f"{rel}:{m.group(1)}\t{m.group(2)}")
PY
assert_eq "$(grep -c '^bin/kempt:' "$TEXT" | awk '{print ($1 > 100)}')" "1" "the CLI's messages were collected"
assert_eq "$(grep -cE 'Try again in a few minutes|Restart when it finishes' "$TEXT")" "2" \
  "sentences kept in KEMPT_ variables and in *_tail/*_advice endings are collected"

# --- the allowlist ------------------------------------------------------------------------------
# Literal things a person types or reads back, removed before the check. One reason each.
#   --surface=...            a command-line option, spelled as it is typed
#   surface=VALUE            a config key and value, as `kempt config get` prints them
#   config set surface       a command to type
#   terminal, popup, ...     the values `--surface` accepts, listed in its own error
#   KEMPT_NAME               an environment variable's name
allow() {
  sed -E \
    -e 's/--surface(=[^ )]*)?//g' \
    -e 's/\bsurface=[^ )]*//g' \
    -e 's/kempt config set surface [a-z]+//g' \
    -e 's/use terminal, popup, background or offline//g' \
    -e 's/\bKEMPT_[A-Z_]+//g'
}

# --- the checks ---------------------------------------------------------------------------------
# Only the text is searched, after the allowlist; a hit is reported with where it came from.
CODE_WORDS='(?i)\b(surfaces?|harvest(s|ed|ing)?|seams?|(re-?)?arm(s|ed|ing)?|backends?)\b'
check() {  # label perl-regex [collection, default $TEXT]
  local tsv="${3:-$TEXT}" hits
  cut -f2- "$tsv" | allow > "$tsv.text-only"
  hits="$(grep -nP -- "$2" "$tsv.text-only" | cut -d: -f1 \
          | while read -r n; do sed -n "${n}p" "$tsv"; done | sort -u || true)"
  if [[ -z "$hits" ]]; then
    echo "ok: $1"
  else
    echo "FAIL: $1"; sed 's/^/    /' <<<"$hits"; _fail=1
  fi
}
DASHES='[\x{2013}\x{2014}]'
check "no on-screen string has an em or en dash" "$DASHES"
check "no on-screen string has a \" - \" aside" ' - '
check "no on-screen string says popup" '(?i)popup'
check "no on-screen string uses the code words surface, harvest, seam, arm or backend" "$CODE_WORDS"

# The checks above would pass on an empty collection, so prove each one can fail, through the
# same allowlist and the same check. The last canary line is allowed text and must not be a hit.
CANARY="$TESTTMP/canary.tsv"
printf 'c:1\tA \xe2\x80\x94 B\nc:2\tA \xe2\x80\x93 B\nc:3\tA - B\nc:4\tthe popup\nc:5\tthe Surface\nc:6\tre-arm it\nc:7\tan armchair\nc:8\tRun: kempt update --surface=offline (KEMPT_TERMINAL)\n' > "$CANARY"
hits_of() { (check canary "$1" "$CANARY") | grep -o '^    c:[0-9]*' | tr -d ' ' | paste -sd' '; }
assert_eq "$(hits_of "$DASHES")" "c:1 c:2" "the dash check finds an em dash and an en dash"
assert_eq "$(hits_of ' - ')" "c:3" "the aside check finds an aside"
assert_eq "$(hits_of '(?i)popup')" "c:4" "the popup check finds the word"
assert_eq "$(hits_of "$CODE_WORDS")" "c:5 c:6" \
  "the code-word check finds a whole code word in any case, not a longer word, and not allowed text"
finish
