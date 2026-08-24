#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
UPKEEP="$REPO_ROOT/bin/upkeep"
upkeep_init_dirs

# Before anything has run, both readers must answer calmly instead of erroring at a user (or at
# the widget, which shells out to them).
assert_exit 0 "summary with no runs exits clean" "$UPKEEP" summary
assert_eq "$("$UPKEEP" summary)" "no update runs recorded yet" "empty history says so in words"
assert_eq "$("$UPKEEP" history)" "" "empty history lists nothing"

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
assert_eq "$("$UPKEEP" summary | grep -c 'kernel-core')" "1" "upkeep summary reads latest"
assert_eq "$("$UPKEEP" history | wc -l)" "1" "history lists one run"
row="$("$UPKEEP" history)"
if grep -q '2026-08-24' <<<"$row" && grep -q 'ok' <<<"$row" && grep -q '2 updated' <<<"$row"; then
  echo "ok: history row shape"
else echo "FAIL: history row shape — got: $row"; _fail=1; fi

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
grep -q 'FAILED — see /tmp/y.log' <<<"$f" && echo "ok: failure names the log" || { echo "FAIL: failure log line"; _fail=1; }
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
m="$(render_summary "$HIST_DIR/20260824T140000.json")"
grep -q 'kernel-core 6.15.2-200.fc44 → 6.15.4-200.fc44' <<<"$m" && echo "ok: installonly set renders newest → newest" \
  || { echo "FAIL: newest() display — got: $m"; _fail=1; }
grep -q '6.15.1' <<<"$m" && { echo "FAIL: superseded version leaked into the human summary"; _fail=1; } \
  || echo "ok: superseded versions stay in the JSON, out of the summary"

# summary reads the LATEST run; `summary N` walks back; history is newest-first.
assert_eq "$("$UPKEEP" summary | head -1 | grep -c '14:00:00')" "1" "summary defaults to the latest run"
assert_eq "$("$UPKEEP" summary 2 | head -1 | grep -c '13:00:00')" "1" "summary N walks back"
assert_eq "$("$UPKEEP" history | wc -l)" "3" "history lists every run"
assert_eq "$("$UPKEEP" history | head -1 | cut -d' ' -f1)" "2026-08-24T14:00:00+03:00" "history is newest first"
assert_exit 2 "summary rejects a non-numeric N" "$UPKEEP" summary abc
finish
