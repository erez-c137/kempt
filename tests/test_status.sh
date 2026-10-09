#!/usr/bin/env bash
# kempt status: what it prints for each kind of state, that it only reads, and that its header and
# numbers agree with what the widget derives from the same file (logic.js, under node).
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
KEMPT="$REPO_ROOT/bin/kempt"
LOGIC="$REPO_ROOT/plasmoid/contents/ui/logic.js"

# The program under test is this tree's, and the state it reads is the sandbox's. A status that
# fell through to an installed kempt, or to the real state directory, would pass for the wrong
# reason.
assert_eq "$([[ "$REPO_ROOT" == /* && -x "$KEMPT" && -f "$REPO_ROOT/tests/test_status.sh" ]] && echo yes)" "yes" \
  "the kempt under test is this tree's bin/kempt"
assert_eq "$([[ "$KEMPT_STATE_DIR" == "$TESTTMP"/* && "$HOME" == "$TESTTMP"/* ]] && echo yes)" "yes" \
  "state and HOME are the sandbox's"
mkdir -p "$KEMPT_STATE_DIR" "$HIST_DIR"

# One clock for every case: two days after the fixtures' last_success.
NOW="$(date -d 2026-08-27T10:59:25+03:00 +%s)"
export KEMPT_NOW="$NOW"

put() { cp "$FIXTURES/state-$1.json" "$STATE_FILE"; }
status() { "$KEMPT" status 2>&1 || true; }  # the text; status_rc is the exit code
status_rc() { local rc=0; "$KEMPT" status "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

# --- the states ------------------------------------------------------------------------------------
rm -f "$STATE_FILE"
assert_eq "$(status)" "No update data yet

No successful check yet" "no state: says so"
assert_eq "$(status_rc)" "1" "no state exits 1"

put live
assert_eq "$(status)" "10 updates available

System (dnf): 7 updates for aajohan-comfortaa-fonts, bash, brandnew, curl, and 3 more
Apps (flatpak): 3 updates for com.example.NotInstalled, net.mkiol.SpeechNote and org.gimp.GIMP

Checked 2 days ago" "updates waiting: count, one line per section, the dateline"
assert_eq "$(status_rc)" "0" "updates waiting exits 0"

# A failed check over known counts is calm: the header is still the count, and the footer says the
# last check failed. Scripts still learn it from the exit code.
put stale
out="$(status)"
assert_eq "$(head -n 1 <<<"$out")" "10 updates available" "stale after a success: the header is the count"
assert_contains "$out" "Checked 1 day ago · last check failed" "stale: the footer says the last check failed"
assert_not_contains "$out" "dnf check failed" "stale: no problem detail under a calm header"
assert_eq "$(status_rc)" "1" "stale exits 1"

# Never answered: no successful check and nothing known. The detail is the first line of the error.
put broken
assert_eq "$(status)" "Kempt cannot check for updates
dnf check failed: root helper not installed. Run ./install.sh (see: kempt doctor)

No successful check yet · last check failed" "never answered: the problem and the first line of its reason"
assert_eq "$(status_rc)" "1" "never answered exits 1"
jq '.error = "first line\nsecond line"' "$FIXTURES/state-broken.json" > "$STATE_FILE"
assert_eq "$(status | sed -n 2p)" "first line" "the detail is the error's first line only"

put held-only
out="$(status)"
assert_eq "$(head -n 1 <<<"$out")" "Up to date · 10 held" "all held: up to date, with the held count"
assert_contains "$out" "Held: 10 (aajohan-comfortaa-fonts, bash, brandnew, curl, and 6 more)" "the held line names them"
assert_eq "$(status_rc)" "0" "all held exits 0"

put reboot-needed
assert_contains "$(status)" "Restart to apply installed updates" "a restart owed has its line"
put security
assert_contains "$(status)" "Security: 3 updates" "the security block's count"
jq '.security.count = 1' "$FIXTURES/state-security.json" > "$STATE_FILE"
assert_contains "$(status)" "Security: 1 update" "one security update is singular"
jq '.security.count = 0' "$FIXTURES/state-security.json" > "$STATE_FILE"
assert_not_contains "$(status)" "Security" "a zero count says nothing"

for f in garbage empty; do
  put "$f"
  assert_eq "$(status | head -n 1)" "No update data yet" "state-$f.json reads as no state"
  assert_eq "$(status_rc)" "1" "state-$f.json exits 1"
done
jq '.schema = 2' "$FIXTURES/state-live.json" > "$STATE_FILE"
assert_eq "$(status)" "Could not read the update state" "a schema this build does not know is unreadable"
assert_eq "$(status_rc)" "1" "an unreadable state exits 1"

# Staged: the header gives way to the stage, and the staged line says what the restart does.
jq '.offline_staged = {staged_at: "2026-08-27T10:00:00+03:00", count: 12, armed: true}
    | .reboot_needed = true' "$FIXTURES/state-live.json" > "$STATE_FILE"
out="$(status)"
assert_eq "$(head -n 1 <<<"$out")" "12 updates staged for the next restart" "staged: the staged header"
assert_contains "$out" "Staged: 12 updates install on the next restart" "staged: the staged line"
assert_contains "$out" "Restart to apply installed updates" "staged: the restart line"
assert_not_contains "$out" "System (dnf)" "staged: no pending sections under the staged header"
# Held, security and staged together: held stays, the security count goes, as in the widget.
jq '.offline_staged = {count: 12} | .security = {count: 2, packages: ["bash"]}
    | .backends.dnf.items[0].held = true' "$FIXTURES/state-live.json" > "$STATE_FILE"
out="$(status)"
assert_contains "$out" "Held: 1 (aajohan-comfortaa-fonts)" "staged: the held line stays"
assert_not_contains "$out" "Security" "staged: no security count"
assert_not_contains "$out" "updates for" "staged: no section names"
assert_contains "$out" "Staged: 12 updates install on the next restart" "staged: the staged line, with held and security"
jq '.offline_staged = {count: 1}' "$FIXTURES/state-live.json" > "$STATE_FILE"
assert_eq "$(status | head -n 1)" "1 update staged for the next restart" "one staged update is singular"
jq '.offline_staged = {}' "$FIXTURES/state-live.json" > "$STATE_FILE"
assert_eq "$(status | head -n 1)" "Updates staged for the next restart" "a stage with no count drops the figure"

# The apps for you only could not be listed, with nothing else pending.
jq '.backends.dnf.items = [] | .backends.flatpak.items = [] | .actionable = 0
    | .backends.flatpak.scopes = {system: "ok", user: "failed"}' "$FIXTURES/state-live.json" > "$STATE_FILE"
out="$(status)"
assert_eq "$(head -n 1 <<<"$out")" "Up to date · apps for you only not checked" "per-user apps unchecked: the header says so"
assert_contains "$out" "Checked 2 days ago · apps for you only not checked" "...and so does the footer"

# Old package lists: the metadata age joins the dateline past a day.
jq '.metadata_refreshed = "2026-08-24T09:00:00+03:00"' "$FIXTURES/state-live.json" > "$STATE_FILE"
assert_contains "$(status)" "Checked 2 days ago · metadata 3 days old" "the metadata age, past 24 hours"

# Runtimes get their own section, named as people read them.
jq '.backends.flatpak.items += [{name: "org.kde.Platform/6.9", from: "?", to: "?", held: false, kind: "runtime"}]
    | .actionable = 11' "$FIXTURES/state-live.json" > "$STATE_FILE"
assert_contains "$(status)" "Flatpak runtimes: 1 update for org.kde.Platform 6.9" "runtimes: their own section"

# Session-critical packages come first in their section's names.
jq '.risky_pending = ["vim-minimal"]' "$FIXTURES/state-live.json" > "$STATE_FILE"
assert_contains "$(status)" "System (dnf): 7 updates for vim-minimal, aajohan-comfortaa-fonts" "risky names first"

# --- the last run ----------------------------------------------------------------------------------
put live
cat > "$HIST_DIR/20260825T090000.json" <<'EOF'
{"timestamp":"2026-08-25T09:00:00+03:00","surface":"terminal","status":"ok","duration_sec":60,
 "reboot_needed":false,"log":"/tmp/x.log",
 "backends":{"dnf":{"status":"ok","skipped_held":[],
   "updated":[{"name":"curl","from":"1","to":"2"},{"name":"bash","from":"1","to":"2"}],
   "added":[{"name":"x","to":"1"}],"removed":[]},
  "flatpak":{"status":"ok","skipped_held":[],"updated":[],"added":[],"removed":[]}}}
EOF
assert_eq "$(status | tail -n 1)" "Last update 2 days ago · 2 updated, +1 installed" "the last run, in history's words"
cat > "$HIST_DIR/20260826T090000.json" <<'EOF'
{"timestamp":"2026-08-26T09:00:00+03:00","surface":"background","status":"failed","log":"/tmp/y.log",
 "backends":{"dnf":{"status":"failed","skipped_held":[],"updated":[],"added":[],"removed":[]},
  "flatpak":{"status":"ok","skipped_held":[],"updated":[],"added":[],"removed":[]}}}
EOF
assert_eq "$(status | tail -n 1)" "Last update 1 day ago · no package changes · failed" "a failed run says so"
echo '{not json' > "$HIST_DIR/20260827T090000.json"
assert_not_contains "$(status)" "Last update" "a damaged newest entry gets no line, not an older run"
rm -f "$HIST_DIR"/*.json

# --- --json ----------------------------------------------------------------------------------------
put live
assert_json_eq "$("$KEMPT" status --json)" "$(cat "$FIXTURES/state-live.json")" "--json prints the state"
assert_eq "$(status_rc --json)" "0" "--json with a state exits 0"
printf '%s\n%s\n' "$(jq -c . "$FIXTURES/state-live.json")" '{"other":1}' > "$STATE_FILE"
assert_json_eq "$("$KEMPT" status --json)" "$(cat "$FIXTURES/state-live.json")" "--json takes the first document"
rm -f "$STATE_FILE"
assert_eq "$("$KEMPT" status --json 2>&1)" "" "--json with no state prints nothing"
assert_eq "$(status_rc --json)" "1" "--json with no state exits 1"

# --- usage ------------------------------------------------------------------------------------------
assert_exit 2 "an unknown option is a usage error" "$KEMPT" status --bogus
assert_exit 2 "a stray argument after --json is a usage error" "$KEMPT" status --json extra
assert_contains "$("$KEMPT" status --help)" "status [--json]" "status --help prints the usage"

# --- an update running -----------------------------------------------------------------------------
# The update lock held by another process: status says so, and answers rather than waiting.
put live
: > "$LOCK_FILE"
exec 5>"$LOCK_FILE"; flock -n 5
rc=0; out="$(timeout 10 "$KEMPT" status 2>&1)" || rc=$?
exec 5>&-
assert_eq "$rc" "0" "status answers while the update lock is held"
assert_eq "$(sed -n 2p <<<"$out")" "Kempt is changing the system right now" "...and says Kempt is changing the system"
assert_not_contains "$(status)" "changing the system" "a free lock says nothing"

# --- read only -------------------------------------------------------------------------------------
# Nothing in the state or config directory changes: no file appears, none is rewritten.
snapshot() { { find "$KEMPT_STATE_DIR" "$KEMPT_CONFIG_DIR" -printf '%p %s %T@ %m\n' 2>/dev/null || true; } | LC_ALL=C sort; }
for state in stale x-staged; do
  if [[ "$state" == x-staged ]]; then jq '.offline_staged = {count: 2}' "$FIXTURES/state-live.json" > "$STATE_FILE"
  else put "$state"; fi
  cp "$FIXTURES/run-last.json" "$HIST_DIR/20260825T090000.json"
  before="$(snapshot)"
  assert_contains "$before" "$STATE_FILE" "the snapshot sees the state file ($state)"
  sleep 1   # a rewrite within the same second would keep its mtime
  "$KEMPT" status >/dev/null 2>&1 || true
  "$KEMPT" status --json >/dev/null 2>&1 || true
  assert_eq "$(snapshot)" "$before" "status writes nothing to the state or config directory ($state)"
done
assert_eq "$([[ -e "$KEMPT_CONFIG_DIR/config" ]] && echo written || echo none)" "none" "status writes no config"

# --- the words -------------------------------------------------------------------------------------
words=""
for f in live stale never held-only reboot-needed security broken risky-heavy flatpak-disabled; do
  put "$f"; words+="$(status)"$'\n'
done
assert_eq "$(grep -cE $'—|–| - |popup' <<<"$words" || true)" "0" "status text: no dashes as asides, no popup"

# --- parity with the widget ------------------------------------------------------------------------
# For each state and the fixed clock, the header, the sections and their counts, the held count and
# the security count must be what logic.js derives. The wording of the other lines is this side's
# own; the facts are not.
if ! command -v node >/dev/null 2>&1; then
  skip "node is absent, so status was NOT compared with the widget's logic"
  finish
fi
PAR="$TESTTMP/parity"; mkdir -p "$PAR"
for f in "$FIXTURES"/state-*.json; do cp "$f" "$PAR/"; done
L="$FIXTURES/state-live.json"
jq '.offline_staged = {count: 12}' "$L" > "$PAR/x-staged.json"
jq '.offline_staged = {count: 1}' "$L" > "$PAR/x-staged-one.json"
jq '.offline_staged = {}' "$L" > "$PAR/x-staged-nocount.json"
jq '.offline_staged = {count: 12} | .release_upgrade = {from: "44", to: "45", state: "downloaded"}' "$L" > "$PAR/x-staged-relup.json"
jq '.schema = 2' "$L" > "$PAR/x-schema2.json"
jq '{schema: 1, status: "ok"}' "$L" > "$PAR/x-no-shape.json"
jq '.backends.dnf.items = [] | .backends.flatpak.items = [] | .actionable = 0
    | .backends.flatpak.scopes = {user: "failed"}' "$L" > "$PAR/x-user-unchecked.json"
jq '.backends.dnf.items = [] | .backends.flatpak.items = [] | .actionable = 4 | .held_total = 2' "$L" > "$PAR/x-totals-only.json"
jq '.backends.dnf.items = [] | .backends.flatpak.items = [] | .actionable = 0 | .held_total = 3' "$L" > "$PAR/x-held-totals.json"
jq '.backends.dnf.items[0].held = true | .backends.flatpak.items[1].held = true' "$L" > "$PAR/x-some-held.json"
jq '.backends.flatpak.items += [{name: "org.kde.Platform/6.9", from: "1", to: "2", held: false, kind: "runtime"},
                                {name: "x.y.Ext/1", from: "1", to: "2", held: false, kind: "extension"}]' "$L" > "$PAR/x-kinds.json"
jq '.backends.flatpak.enabled = false' "$L" > "$PAR/x-fp-off.json"
jq '.backends.dnf.items = [.backends.dnf.items[0]]' "$L" > "$PAR/x-one.json"
jq '.security = {count: 2.7, packages: ["bash"]}' "$L" > "$PAR/x-security-frac.json"
jq '.status = "stale" | .last_success = "  "' "$FIXTURES/state-never.json" > "$PAR/x-never-blank.json"
# Each of these kills a mutant the fixtures above let live: held before per-user-unchecked in the
# up-to-date header, and a staged count of zero or of the wrong type.
jq '.backends.dnf.items = [{name: "bash", from: "1", to: "2", held: true}] | .backends.flatpak.items = []
    | .actionable = 0 | .backends.flatpak.scopes = {user: "failed"}' "$L" > "$PAR/x-held-user-unchecked.json"
jq '.offline_staged = {count: 0}' "$L" > "$PAR/x-staged-zero.json"
jq '.offline_staged = {count: "12"}' "$L" > "$PAR/x-staged-strcount.json"

bash_facts() {  # state file → {header, sections: [[title, count]], held, security}
  local doc
  doc="$(jq -c -n '[inputs][0] | select(type == "object")' "$1" 2>/dev/null)" || doc=""
  jq -r -n --argjson now "$NOW" "$KEMPT_JQ_TIME$KEMPT_JQ_STATUS"'[inputs][0] | status_records($now)' <<<"${doc:-null}" \
    | jq -R -s -c 'split("\n") | map(select(. != "") | split("\u001f")) as $r
                   | { header: ([$r[] | select(.[0] == "H") | .[1]] | .[0]),
                       sections: [$r[] | select(.[0] == "S") | [.[1], (.[2] | tonumber)]],
                       held: ([$r[] | select(.[0] == "L") | .[1] | tonumber] | .[0] // 0),
                       security: ([$r[] | select(.[0] == "C") | .[1] | tonumber] | .[0] // 0) }'
}
node_facts() {  # state file → the same, from logic.js
  node -e '
    const fs = require("fs"); const L = require(process.argv[1]);
    const st = L.parseState(fs.readFileSync(process.argv[2], "utf8"));
    const vm = L.viewModel(st, false, "", { nowMs: Number(process.argv[3]) * 1000 });
    const usable = vm.actionable !== null;  // null exactly when the state is not one it can read
    console.log(JSON.stringify({ header: vm.headerText,
      sections: usable ? vm.sections.map((s) => [s.title, s.items.length]) : [],
      held: usable ? vm.heldTotal : 0, security: vm.securityCount }));
  ' "$LOGIC" "$1" "$NOW"
}
for f in "$PAR"/*.json; do
  assert_json_eq "$(bash_facts "$f")" "$(node_facts "$f")" "parity with the widget: $(basename "$f")"
done
# ...and the header kempt status prints is the one compared above.
cp "$PAR/x-staged.json" "$STATE_FILE"
assert_eq "$(status | head -n 1)" "$(bash_facts "$PAR/x-staged.json" | jq -r .header)" "status prints the compared header"

# The time words, at every bucket edge.
ages="0 59 60 119 3599 3600 7199 86399 86400 172799 604800 691199 691200 -5"
got="$(for a in $ages; do
  jq -r -n --argjson now "$NOW" --arg at "$(date -d "@$(( NOW - a ))" -Iseconds)" "$KEMPT_JQ_TIME"'
    ($at | rel_time($now)) + "|" + ($at | meta_age($now))'
done)"
# shellcheck disable=SC2016  # JavaScript, not shell
want="$(node -e '
  const L = require(process.argv[1]); const now = Number(process.argv[2]);
  for (const a of process.argv[3].split(" ")) {
    const d = new Date((now - Number(a)) * 1000);
    // the same stamp `date -Iseconds` writes, in UTC
    const iso = d.toISOString().replace(/\.\d{3}Z$/, "+00:00");
    // The metadata age as the footer shows it: logic.js keeps the helper to itself.
    const vm = L.viewModel({ schema: 1, actionable: 0, status: "ok", last_success: iso,
                             metadata_refreshed: iso, backends: {} }, false, "", { nowMs: now * 1000 });
    // Matched by shape, not by its first word, so a rename of that word fails only on the bash side.
    const meta = vm.footerText.split(" \u00b7 ").filter((p) => /^\S+ \d+ days? old$/.test(p))[0] || "";
    console.log(L.relativeTime(iso, now * 1000) + "|" + meta);
  }' "$LOGIC" "$NOW" "$ages")"
# date -Iseconds writes local time; the stamps differ in zone only, and the absolute fallback
# prints the zone, so compare the relative words and the ages, which do not depend on it.
# shellcheck disable=SC2001  # one sed over many lines
assert_eq "$(sed 's/^[0-9-]* [0-9:]* [+-][0-9:]*|/STAMP|/' <<<"$got")" \
          "$(sed 's/^[0-9-]* [0-9:]* [+-][0-9:]*|/STAMP|/' <<<"$want")" "the time words match the widget's"
assert_eq "$(jq -r -n "$KEMPT_JQ_TIME"'"2026-08-25T10:59:25+0300", "2026-08-25T10:59Z", "nope", null | fmt_stamp')" \
  "$(node -e 'const L = require(process.argv[1]);
    for (const s of ["2026-08-25T10:59:25+0300", "2026-08-25T10:59Z", "nope", null]) console.log(L.formatStamp(s));' "$LOGIC")" \
  "stamps format as the widget formats them"

# Every string that mirrors a COPY entry is that entry.
assert_eq "$(jq -S -c -n "$KEMPT_JQ_STATUS"'status_copy')" \
  "$(node -e 'const L = require(process.argv[1]);
    const keys = JSON.parse(process.argv[2]); const o = {};
    for (const k of keys.sort()) o[k] = L.COPY[k];
    console.log(JSON.stringify(o));' "$LOGIC" "$(jq -c -n "$KEMPT_JQ_STATUS"'status_copy | keys')")" \
  "the strings status shares with the widget are the widget's COPY entries"

finish
