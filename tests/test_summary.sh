#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
KEMPT="$REPO_ROOT/bin/kempt"
kempt_init_dirs

# Before anything has run, both readers must answer calmly instead of erroring at a user (or at
# the widget, which shells out to them).
assert_exit 0 "summary with no runs exits clean" "$KEMPT" summary
assert_eq "$("$KEMPT" summary)" "no update runs recorded yet" "empty history says so in words"
assert_eq "$("$KEMPT" history)" "" "empty history lists nothing"
# --json's "no data" answer is EMPTY stdout under exit 0, never a fabricated empty run - the same
# rule the state file lays down for `kempt check`. Only the human mode says it in words.
assert_exit 0 "summary --json with no runs exits clean" "$KEMPT" summary --json
assert_eq "$("$KEMPT" summary --json)" "" "no runs recorded: --json prints nothing at all"

cat > "$HIST_DIR/20260824T120000.json" <<'EOF'
{"timestamp":"2026-08-24T12:00:00+03:00","surface":"terminal","status":"ok","duration_sec":192,
 "reboot_needed":true,"log":"/tmp/x.log",
 "backends":{
  "dnf":{"status":"ok","skipped_held":["vim-common"],
    "updated":[{"name":"kernel-core","from":"6.15.3","to":"6.15.4"}],
    "added":[],"removed":[]},
  "flatpak":{"status":"ok","skipped_held":[],
    "updated":[{"name":"org.gimp.GIMP","from":"2.10","to":"2.11"}],
    "added":[],"removed":[]}}}
EOF

s="$(render_summary "$HIST_DIR/20260824T120000.json")"
grep -q 'kernel-core 6.15.3 → 6.15.4' <<<"$s" && echo "ok: dnf line" || { echo "FAIL: dnf line"; _fail=1; }
grep -q 'org.gimp.GIMP 2.10 → 2.11' <<<"$s" && echo "ok: flatpak line" || { echo "FAIL: fp line"; _fail=1; }
grep -q 'Held (skipped): vim-common' <<<"$s" && echo "ok: held surfaced" || { echo "FAIL: held"; _fail=1; }
grep -q 'Reboot: needed' <<<"$s" && echo "ok: reboot line" || { echo "FAIL: reboot"; _fail=1; }
assert_eq "$("$KEMPT" summary | grep -c 'kernel-core')" "1" "kempt summary reads latest"
assert_eq "$("$KEMPT" history | wc -l)" "1" "history lists one run"
assert_eq "$("$KEMPT" history)" "2026-08-24T12:00:00+03:00  terminal  ok  2 updated" \
  "history row shape: timestamp, surface, status, what the run changed"

# --- beyond the plan: the shapes cmd_update actually writes ---

# A failed run has to say so, name the log, and mark WHICH backend failed.
cat > "$HIST_DIR/20260824T130000.json" <<'EOF'
{"timestamp":"2026-08-24T13:00:00+03:00","surface":"background","status":"failed","duration_sec":7,
 "reboot_needed":false,"log":"/tmp/y.log",
 "backends":{
  "dnf":{"status":"failed","skipped_held":[],"updated":[],"added":[],"removed":[]},
  "flatpak":{"status":"skipped","skipped_held":[],"updated":[],"added":[],"removed":[]}}}
EOF
f="$(render_summary "$HIST_DIR/20260824T130000.json")"
grep -q 'FAILED - see /tmp/y.log' <<<"$f" && echo "ok: failure names the log" || { echo "FAIL: failure log line"; _fail=1; }
grep -q 'System (dnf): 0 updated \[failed\]' <<<"$f" && echo "ok: failing backend is marked" || { echo "FAIL: backend status marker"; _fail=1; }
grep -q 'Apps (flatpak): 0 updated \[skipped\]' <<<"$f" && echo "ok: skipped backend is marked" || { echo "FAIL: skipped marker"; _fail=1; }
grep -q 'Held' <<<"$f" && { echo "FAIL: empty held list printed a line"; _fail=1; } || echo "ok: no held line when nothing is held"
grep -q 'Reboot: not needed' <<<"$f" && echo "ok: no-reboot line" || { echo "FAIL: no-reboot line"; _fail=1; }

# Installonly sets (kernel*, gpg-pubkey) legitimately carry SEVERAL versions comma-joined - the
# JSON keeps all of them, the human reads newest → newest instead of a wall of commas.
cat > "$HIST_DIR/20260824T140000.json" <<'EOF'
{"timestamp":"2026-08-24T14:00:00+03:00","surface":"offline (applied on reboot)","status":"ok","duration_sec":0,
 "reboot_needed":false,"log":"",
 "backends":{
  "dnf":{"status":"ok","skipped_held":[],
    "updated":[{"name":"kernel-core","from":"6.15.1-200.fc44,6.15.2-200.fc44","to":"6.15.2-200.fc44,6.15.4-200.fc44"}],
    "added":[],"removed":[]},
  "flatpak":{"status":"skipped","skipped_held":[],"updated":[],"added":[],"removed":[]}}}
EOF
# ...and "newest" means the LAST element, which is only true because the producers sort version
# sets ascending. 1.9 vs 1.10 is the pair where a lexical sort gets it backwards, so this is the
# consumer half of that contract: given an ascending set, the human sees the newest build.
cat > "$TESTTMP/vset-entry.json" <<'EOF'
{"timestamp":"2026-08-24T17:00:00+03:00","surface":"terminal","status":"ok","duration_sec":3,
 "reboot_needed":false,"log":"/tmp/v.log",
 "backends":{
  "dnf":{"status":"ok","skipped_held":[],
    "updated":[{"name":"pkg","from":"1.8,1.9","to":"1.9,1.10"}],
    "added":[],"removed":[]},
  "flatpak":{"status":"skipped","skipped_held":[],"updated":[],"added":[],"removed":[]}}}
EOF
vs="$(render_summary "$TESTTMP/vset-entry.json")"
grep -q 'pkg 1.9 → 1.10' <<<"$vs" && echo "ok: an ascending set renders newest → newest" \
  || { echo "FAIL: version-set display - got: $vs"; _fail=1; }

m="$(render_summary "$HIST_DIR/20260824T140000.json")"
grep -q 'kernel-core 6.15.2-200.fc44 → 6.15.4-200.fc44' <<<"$m" && echo "ok: installonly set renders newest → newest" \
  || { echo "FAIL: newest() display - got: $m"; _fail=1; }
grep -q '6.15.1' <<<"$m" && { echo "FAIL: superseded version leaked into the human summary"; _fail=1; } \
  || echo "ok: superseded versions stay in the JSON, out of the summary"

# summary reads the LATEST run; `summary N` walks back; history is newest-first.
assert_eq "$("$KEMPT" summary | head -1 | grep -c '14:00:00')" "1" "summary defaults to the latest run"
assert_eq "$("$KEMPT" summary 2 | head -1 | grep -c '13:00:00')" "1" "summary N walks back"
assert_eq "$("$KEMPT" history | wc -l)" "3" "history lists every run"
assert_eq "$("$KEMPT" history | head -1 | cut -d' ' -f1)" "2026-08-24T14:00:00+03:00" "history is newest first"
assert_exit 2 "summary rejects a non-numeric N" "$KEMPT" summary abc

# --- summary --json: the last run as data ------------------------------------------------------
# The popup needs what the last run did, and re-deriving it from the human text would be a second,
# lossier copy of render_summary's rules living in the widget. So --json hands over the entry.
newest="$(ls -1 "$HIST_DIR"/*.json | sort -r | head -1)"
"$KEMPT" summary --json > "$TESTTMP/sj.json"
assert_exit 0 "summary --json exits 0 with runs recorded" "$KEMPT" summary --json
assert_eq "$(jq -r .timestamp "$TESTTMP/sj.json")" "2026-08-24T14:00:00+03:00" \
  "--json serves the NEWEST run, the same one plain summary defaults to"
# Byte-identical, not merely equivalent: it prints the file rather than re-rendering it, so a
# reader gets exactly what the run recorded - including any field this build has never heard of.
assert_eq "$(cmp -s "$TESTTMP/sj.json" "$newest" && echo same || echo differs)" "same" \
  "--json output is the history entry itself, byte for byte"
# N would have to mean something --json does not offer, and an ignored argument would hand a
# reader the WRONG run under exit 0. Both orders, because either one is somebody being reasonable.
assert_exit 2 "--json takes no N" "$KEMPT" summary --json 2
assert_exit 2 "...in either order" "$KEMPT" summary 2 --json
# ...and the human command is untouched by any of it.
hs="$("$KEMPT" summary)"
assert_eq "$(grep -c 'System (dnf)' <<<"$hs")" "1" "plain kempt summary still renders the human text"
assert_eq "$(jq -e . <<<"$hs" >/dev/null 2>&1 && echo json || echo text)" "text" \
  "...which is text, and was never quietly turned into JSON"
assert_eq "$("$KEMPT" summary 2 | head -1 | grep -c '13:00:00')" "1" "...and summary N still walks back"

# A run that installed and removed packages changed the system as much as one that upgraded them.
cat > "$TESTTMP/ar-entry.json" <<'EOF'
{"timestamp":"2026-08-24T16:00:00+03:00","surface":"background","status":"ok","duration_sec":9,
 "reboot_needed":false,"log":"/tmp/a.log",
 "backends":{
  "dnf":{"status":"ok","skipped_held":[],"updated":[],
    "added":[{"name":"newpkg","to":"1.0"},{"name":"other","to":"2.0"}],
    "removed":[{"name":"zsh","from":"5.9"}]},
  "flatpak":{"status":"skipped","skipped_held":[],"updated":[],"added":[],"removed":[]}}}
EOF
ar="$(render_summary "$TESTTMP/ar-entry.json")"
grep -q 'System (dnf): 0 updated, +2 installed, -1 removed' <<<"$ar" \
  && echo "ok: installs and removals are counted" || { echo "FAIL: add/remove counts - got: $ar"; _fail=1; }
grep -q 'Apps (flatpak): 0 updated \[skipped\]' <<<"$ar" \
  && echo "ok: an empty backend line stays clean" || { echo "FAIL: empty backend line"; _fail=1; }

# asking for a run further back than the history goes shows the oldest - and says it did
crc=0
cout="$("$KEMPT" summary 99 2>"$TESTTMP/clamperr")" || crc=$?
assert_eq "$crc" "0" "summary N past the end still succeeds"
grep -q 'only 3 run(s) recorded' "$TESTTMP/clamperr" \
  && echo "ok: clamping says so on stderr" || { echo "FAIL: no clamp note"; _fail=1; }
grep -q '12:00:00' <<<"$cout" && echo "ok: clamped to the oldest run" || { echo "FAIL: clamp target"; _fail=1; }

# ...and so does `kempt history`, which used to count .updated ALONE - printing "0 updated" for
# the very run whose summary, rendered by the same command a moment earlier, says
# "+2 installed, -1 removed". One entry, two renderers, two different truths.
cp "$TESTTMP/ar-entry.json" "$HIST_DIR/20260824T160000.json"
# No `| head -1`: history writes row by row, so head closing the pipe early races the writer into
# SIGPIPE (141) and kills the whole test file under pipefail.
hist_out="$("$KEMPT" history)"
hrow="${hist_out%%$'\n'*}"
assert_eq "$hrow" "2026-08-24T16:00:00+03:00  background  ok  +2 installed, -1 removed" \
  "a history row counts installs and removals, not just upgrades"
grep -q '0 updated' <<<"$hrow" \
  && { echo "FAIL: history says '0 updated' for a run that changed 3 packages"; _fail=1; } \
  || echo "ok: no phantom '0 updated' on an install/remove-only run"
# and a run that really changed nothing says so in words, the same phrase the notification uses
assert_eq "$("$KEMPT" history | grep '13:00:00')" \
  "2026-08-24T13:00:00+03:00  background  failed  no package changes" \
  "a run that changed nothing says so"

# --- a damaged history entry must not cost the user every other run ---
# Both readers are what the widget and the terminal shell out to, and a half-written entry (power
# loss mid-write, a full disk) is exactly what they will meet one day.
rm -f "$HIST_DIR"/*.json
printf '{"timestamp":"2026-08-24T15:00:00+03:00","surface":"term' > "$HIST_DIR/20260824T150000.json"  # truncated
: > "$HIST_DIR/20260824T160000.json"   # zero-byte: jq exits 0 with NO output, the nastier shape
cat > "$HIST_DIR/20260824T110000.json" <<'EOF'
{"timestamp":"2026-08-24T11:00:00+03:00","surface":"background","status":"ok","duration_sec":12,
 "reboot_needed":false,"log":"/tmp/z.log",
 "backends":{
  "dnf":{"status":"ok","skipped_held":[],"updated":[{"name":"curl","from":"8.17","to":"8.18"}],"added":[],"removed":[]},
  "flatpak":{"status":"skipped","skipped_held":[],"updated":[],"added":[],"removed":[]}}}
EOF
src=0
sout="$("$KEMPT" summary 2>"$TESTTMP/serr")" || src=$?
assert_eq "$src" "0" "corrupt newest entry does not fail the command"
grep -q 'curl 8.17 → 8.18' <<<"$sout" && echo "ok: summary falls back to the newest READABLE entry" \
  || { echo "FAIL: summary fallback - got: $sout"; _fail=1; }
assert_eq "$(grep -c 'corrupt history entry' "$TESTTMP/serr")" "2" "both damaged entries are named on stderr"
assert_eq "$("$KEMPT" history 2>/dev/null | wc -l)" "1" "history skips damaged rows and lists the rest"
assert_eq "$("$KEMPT" history 2>&1 >/dev/null | grep -c 'corrupt history entry')" "2" "history names the damaged entries too"

# --json must never hand a reader corrupt bytes under exit 0, so it validates before printing and
# walks back exactly like the human mode. The newest file here is the ZERO-BYTE one: a file with
# no JSON document in it at all. Each mode refuses it for its own reason, and neither reason is
# `jq .`'s exit code, which is 0 on such a file having printed nothing. --json refuses it on its
# guard's own answer (`[inputs] | length == 1` is false when there are no documents); the human
# branch refuses it on render_summary's OUTPUT, which is empty for exactly the same reason, and
# that is the one place in this command where an exit code genuinely is not enough.
jrc=0
"$KEMPT" summary --json > "$TESTTMP/fallback.json" 2>"$TESTTMP/jerr" || jrc=$?
assert_eq "$jrc" "0" "--json survives a corrupt newest entry"
assert_eq "$(jq -r .timestamp "$TESTTMP/fallback.json")" "2026-08-24T11:00:00+03:00" \
  "--json falls back to the newest READABLE entry"
assert_eq "$(grep -c 'corrupt history entry' "$TESTTMP/jerr")" "2" "...naming both damaged entries on stderr"

# every entry damaged → the same calm no-runs answer, still rc 0
rm -f "$HIST_DIR/20260824T110000.json"
arc=0
aout="$("$KEMPT" summary 2>/dev/null)" || arc=$?
assert_eq "$arc" "0" "all-corrupt history still exits 0"
assert_eq "$aout" "no update runs recorded yet" "all-corrupt history degrades to the no-runs message"
ajrc=0
ajout="$("$KEMPT" summary --json 2>/dev/null)" || ajrc=$?
assert_eq "$ajrc" "0" "all-corrupt history still exits 0 under --json"
assert_eq "$ajout" "" "...and prints nothing, rather than inventing an empty run"
# --- valid JSON that is not a history entry ----------------------------------------------------
# `jq -e .` looked like a validator and was not one. It accepts a MULTI-DOCUMENT file (and `cat`
# then hands the caller both documents, which is exactly the "one value per document" trap that
# state_prev_items and cmd_check's prev_ls already carry the [inputs] idiom for), and its -e test
# rejects only `null` and `false`, so an array, a number or a bare string all passed for "valid".
# The human path rejects every shape below on its own, because render_summary asks these files for
# fields they do not have. So the two modes disagreed about the same bytes, and the widget's
# JSON.parse was the thing that found out. Each shape is asserted on BOTH modes for that reason.
_good_entry='{"timestamp":"2026-08-24T11:00:00+03:00","surface":"background","status":"ok","duration_sec":12,
 "reboot_needed":false,"log":"/tmp/z.log",
 "backends":{
  "dnf":{"status":"ok","skipped_held":[],"updated":[{"name":"curl","from":"8.17","to":"8.18"}],"added":[],"removed":[]},
  "flatpak":{"status":"skipped","skipped_held":[],"updated":[],"added":[],"removed":[]}}}'

# newest-entry-bytes label → asserts both readers walk back to the readable entry underneath
assert_newest_rejected() {
  local bytes="$1" what="$2" rc=0 hrc=0 bad="$HIST_DIR/20260824T170000.json"
  rm -f "$HIST_DIR"/*.json
  printf '%s\n' "$_good_entry" > "$HIST_DIR/20260824T110000.json"
  printf '%s\n' "$bytes" > "$bad"
  "$KEMPT" summary --json > "$TESTTMP/shape.json" 2>"$TESTTMP/shape.err" || rc=$?
  assert_eq "$rc" "0" "$what: --json still exits 0"
  # the widget's JSON.parse, standing in: ONE document, or it throws. [inputs] counts documents,
  # which is the only thing a plain `jq .` on the output could never tell us.
  assert_eq "$(jq -e -n '[inputs] | length == 1' "$TESTTMP/shape.json" >/dev/null 2>&1 && echo one || echo "not-one")" \
    "one" "$what: --json emits exactly one JSON document"
  assert_eq "$(jq -r .timestamp "$TESTTMP/shape.json" 2>/dev/null)" "2026-08-24T11:00:00+03:00" \
    "$what: --json falls back to the newest READABLE entry"
  assert_eq "$(grep -c "corrupt history entry: $bad" "$TESTTMP/shape.err")" "1" \
    "$what: --json names the damaged entry on stderr"
  # parity: the human path already refused these, and refusing in only one mode is the bug
  "$KEMPT" summary >/dev/null 2>"$TESTTMP/shape.herr" || hrc=$?
  assert_eq "$hrc" "0" "$what: the human path still exits 0 too"
  assert_eq "$(grep -c "corrupt history entry: $bad" "$TESTTMP/shape.herr")" "1" \
    "$what: the human path refuses the same bytes"
}

# Two whole documents in one file: what an interleaved or resumed write leaves behind.
assert_newest_rejected "$_good_entry
{\"timestamp\":\"2026-08-24T17:30:00+03:00\"}" "multi-document entry"
assert_newest_rejected '[]'         "array entry"
assert_newest_rejected '42'         "bare number entry"
assert_newest_rejected '"a string"' "bare string entry"
finish
