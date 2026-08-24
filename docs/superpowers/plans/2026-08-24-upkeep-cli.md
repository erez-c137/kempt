# Upkeep CLI (Plan 1 of 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the complete `upkeep` CLI — check/update/holds/history/summary/config, dnf5 + flatpak backends, polkit root helpers, install script — fully working from a terminal on Fedora 44. (Plan 2 adds the Plasma widget on top; nothing here depends on it.)

**Architecture:** Bash CLI with pure parser functions (fixture-testable) separated from impure command wrappers (stub-overridable via env vars). Update reports come from before/after package-list snapshots (`tsv_diff_updates`), NOT from parsing dnf history — smaller parsing surface, locale-proof, portable. Two root helpers (one per polkit action): `upkeep-refresh` (no-dialog metadata check/refresh, so the badge reads the SAME root cache the update uses) and `upkeep-apply` (auth-gated upgrade verbs with strict arg validation).

**Tech Stack:** bash, jq (installed), dnf5 5.4, flatpak 1.18, polkit (pkexec), notify-send. Test harness: plain bash + fixtures (no bats dependency).

**Spec:** `docs/superpowers/specs/2026-08-24-upkeep-design.md` — read it before starting. The survey behind its decisions: `docs/research/2026-08-24-similar-tools-survey.md`.

**House rules for workers:**
- Repo root: `/mnt/dev_workspace/projects/upkeep`. All paths below are repo-relative.
- This is light work (no builds/vitest) — does not count against the G9-Mini heavy-job limit.
- `LC_ALL=C` on every command whose output gets parsed.
- Never run a REAL privileged update during implementation. Real `pkexec` runs happen only in Task 14's user-gated checklist. Everything else uses stubs/fixtures.
- Commit after every task (message format shown per task).

## File Structure

```
upkeep/
├── bin/upkeep                       # CLI entry: dispatch + cmd_* implementations
├── lib/common.sh                    # paths, config, holds, snapshots diff, state assembly, notify
├── backends/dnf.sh                  # dnf5: pure parsers + impure check/update/snapshot
├── backends/flatpak.sh              # flatpak: same shape
├── libexec/upkeep-refresh           # root helper: check | refresh   (polkit: allow_active=yes)
├── libexec/upkeep-apply             # root helper: dnf-upgrade | dnf-offline-stage | flatpak-update (auth_admin_keep)
├── polkit/org.erez.upkeep.policy    # both actions, exec.path-annotated
├── polkit/49-upkeep.rules.in        # passwordless template (@USER@ placeholder)
├── install.sh                       # --destdir staging for tests; real mode = symlink + one pkexec
├── README.md
└── tests/
    ├── lib.sh                       # assert helpers
    ├── run_tests.sh                 # runs all test_*.sh
    ├── fixtures/                    # captured real output (Task 2)
    └── test_*.sh                    # one per unit below
```

Runtime files (created by the CLI, never in repo): config `~/.config/upkeep/config`, holds `~/.config/upkeep/holds`, state `~/.local/state/upkeep/{state.json,history/,logs/,snapshots/,last_refresh,offline_staged.json,lock}`.

Env overrides (the testability seam — every impure call goes through these):
`UPKEEP_CONFIG_DIR`, `UPKEEP_STATE_DIR`, `UPKEEP_PKEXEC` (default `pkexec`, set empty in tests), `UPKEEP_REFRESH_HELPER` / `UPKEEP_APPLY_HELPER` (default `/usr/local/libexec/upkeep-{refresh,apply}`, point at stubs in tests), `UPKEEP_NOTIFY` (default `notify-send`).

---

### Task 1: Scaffolding + test harness

**Files:**
- Create: `.gitignore`, `tests/lib.sh`, `tests/run_tests.sh`, `README.md`

- [ ] **Step 1: Create .gitignore and README stub**

`.gitignore`:
```
*.tmp
tests/tmp/
```

`README.md`:
```markdown
# Upkeep

One-click system updates from the Plasma panel (Fedora/KDE first; universal Linux updater is the long-term goal).

- Spec: docs/superpowers/specs/2026-08-24-upkeep-design.md
- Prior-art survey: docs/research/2026-08-24-similar-tools-survey.md
- CLI: `bin/upkeep` — run `upkeep help`
- Tests: `tests/run_tests.sh`
```

- [ ] **Step 2: Write tests/lib.sh**

```bash
#!/usr/bin/env bash
# Test helpers. Source me. Each test file runs in its own sandbox HOME.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO_ROOT/tests/fixtures"
_fail=0

sandbox() {  # fresh dirs per test file; call first
  TESTTMP="$(mktemp -d "${TMPDIR:-/tmp}/upkeep-test.XXXXXX")"
  export UPKEEP_CONFIG_DIR="$TESTTMP/config"
  export UPKEEP_STATE_DIR="$TESTTMP/state"
  export UPKEEP_PKEXEC=""
  export UPKEEP_NOTIFY="true"   # /usr/bin/true — notifications are no-ops in tests
  trap 'rm -rf "$TESTTMP"' EXIT
}

assert_eq() {  # got expected label
  if [[ "$1" != "$2" ]]; then echo "FAIL: $3"; echo "  expected: $2"; echo "  got:      $1"; _fail=1
  else echo "ok: $3"; fi
}

assert_json_eq() {  # got expected label (order-insensitive keys)
  assert_eq "$(jq -Sc . <<<"$1")" "$(jq -Sc . <<<"$2")" "$3"
}

assert_exit() {  # expected_rc label -- cmd...
  local want="$1" label="$2"; shift 2; local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "$want" "$label"
}

finish() { exit $_fail; }
```

- [ ] **Step 3: Write tests/run_tests.sh**

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
rc=0
for t in test_*.sh; do
  echo "== $t"
  bash "$t" || rc=1
done
[[ $rc -eq 0 ]] && echo "ALL PASS" || echo "FAILURES"
exit $rc
```

- [ ] **Step 4: Make executable, run (expect: no test files yet, ALL PASS), commit**

Run: `chmod +x tests/run_tests.sh && tests/run_tests.sh`
Expected: `ALL PASS` (glob matches nothing — if the glob literal `test_*.sh` errors, that's fine too at this stage as long as the script exits 0; adjust with `shopt -s nullglob` at the top of run_tests.sh).

```bash
git add -A && git commit -m "chore: scaffolding + bash test harness"
```

POST-REVIEW NOTE: the harness was hardened in a follow-up commit after quality review — authoritative EXIT trap in `sandbox` (a test file that forgets `finish` still fails), sandboxed HOME/XDG dirs, UNSTUBBED-by-default helper seams, `--`-tolerant `assert_exit` with captured output, guarded `cd` + empty-suite failure in run_tests.sh. The repo's `tests/lib.sh` / `tests/run_tests.sh` are authoritative over the code blocks above; the public interface (`sandbox` / `assert_*` / `finish`) is unchanged, so later tasks' test templates work as written.

---

### Task 2: Capture fixtures from the live box

Read-only commands only. If any produces empty output right now (e.g. no flatpak updates pending), hand-write realistic sample lines in the documented format so parsers still get a non-empty test case. POST-REVIEW CONVENTION (supersedes the original in-band `# HAND-WRITTEN SAMPLE` markers): fixtures stay byte-faithful to real tool output — NO comment lines inside fixture files; provenance (captured vs hand-written, dates, per-row edge-case intent) lives in `tests/fixtures/MANIFEST.md`. Guard rows are mandatory: at least one pending dnf package absent from rpm-installed.tsv (`brandnew`), one `.i686` multilib duplicate of an existing row, one pending flatpak absent from flatpak-list.tsv (`com.example.NotInstalled`), and the installonly-duplication fixture `snap-multiver-raw.tsv` (kernel-core ×3, gpg-pubkey ×2). Capture rule learned the hard way: fixtures must go through the SAME code path production uses — the original capture used `sort -u` while production used plain `sort`, which made the installonly cross-product bug structurally invisible to the whole suite.

**Files:**
- Create: `tests/fixtures/dnf-check-update.txt`, `tests/fixtures/rpm-installed.tsv`, `tests/fixtures/flatpak-remote-ls.txt`, `tests/fixtures/flatpak-list.tsv`, `tests/fixtures/snap-before.tsv`, `tests/fixtures/snap-after.tsv`

- [ ] **Step 1: Capture dnf fixtures**

```bash
cd /mnt/dev_workspace/projects/upkeep
LC_ALL=C dnf5 --cacheonly check-update --quiet 2>/dev/null | head -30 > tests/fixtures/dnf-check-update.txt || true
LC_ALL=C rpm -qa --queryformat '%{NAME}\t%{EVR}\n' | sort > /tmp/rpm-all.tsv
# keep only the installed rows for names appearing in the check-update fixture, plus 3 extras:
awk '{n=$1; sub(/\.[^.]+$/,"",n); print n}' tests/fixtures/dnf-check-update.txt | sort -u > /tmp/names.txt
grep -F -f /tmp/names.txt /tmp/rpm-all.tsv > tests/fixtures/rpm-installed.tsv
head -3 /tmp/rpm-all.tsv >> tests/fixtures/rpm-installed.tsv
sort -u -o tests/fixtures/rpm-installed.tsv tests/fixtures/rpm-installed.tsv
```
Note: if `--cacheonly` fails because no root cache exists yet, run `LC_ALL=C dnf5 check-update --quiet | head -30` instead (user cache; fixture shape is identical). If output is empty (fully up to date), hand-write ~6 lines in the documented format `name.arch<spaces>evr<spaces>repo`, e.g. `vim-common.x86_64   2:9.1.1000-1.fc44   updates`, and matching rows in rpm-installed.tsv with older EVRs.

- [ ] **Step 2: Capture flatpak fixtures**

```bash
LC_ALL=C flatpak remote-ls --updates --app --columns=application,version 2>/dev/null > tests/fixtures/flatpak-remote-ls.txt || true
LC_ALL=C flatpak list --app --columns=application,version | sort > tests/fixtures/flatpak-list.tsv
```
Columns are TAB-separated. If remote-ls is empty, hand-write 2 lines using app ids from flatpak-list.tsv with bumped versions (`# HAND-WRITTEN SAMPLE` first line).

- [ ] **Step 3: Build snapshot-diff fixtures (hand-made, deterministic)**

`tests/fixtures/snap-before.tsv`:
```
bash	5.2.37-1.fc44
kernel-core	6.15.3-200.fc44
vim-common	2:9.1.900-1.fc44
zsh	5.9-11.fc44
```
`tests/fixtures/snap-after.tsv`:
```
bash	5.2.37-1.fc44
kernel-core	6.15.4-200.fc44
newpkg	1.0-1.fc44
vim-common	2:9.1.1000-1.fc44
```
(Fields TAB-separated. `zsh` removed, `newpkg` added, two upgraded, `bash` unchanged.)

- [ ] **Step 4: Sanity-check and commit**

Run: `wc -l tests/fixtures/*` — every file non-empty except possibly the two "may be empty on this box" capture files (which then have `-sample`-style hand-written content instead per Step 1/2 notes).

```bash
git add -A && git commit -m "test: capture dnf/flatpak fixtures from live box"
```

---

### Task 3: lib/common.sh — paths, dirs, config

**Files:**
- Create: `lib/common.sh`
- Test: `tests/test_config.sh`

- [ ] **Step 1: Write the failing test**

`tests/test_config.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
upkeep_init_dirs

assert_eq "$(config_get surface terminal)" "terminal" "default when unset"
config_set surface background
assert_eq "$(config_get surface terminal)" "background" "reads set value"
config_set surface offline
assert_eq "$(config_get surface terminal)" "offline" "overwrite same key"
assert_eq "$(grep -c '^surface=' "$UPKEEP_CONFIG_DIR/config")" "1" "no duplicate keys"
config_set include_flatpak false
assert_eq "$(config_get include_flatpak true)" "false" "second key independent"
assert_eq "$(config_get refresh_interval_min 60)" "60" "default numeric"
finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_config.sh`
Expected: FAIL — `lib/common.sh: No such file or directory`

- [ ] **Step 3: Write lib/common.sh**

```bash
#!/usr/bin/env bash
# Upkeep shared library. Pure helpers + path setup. Sourced by bin/upkeep, backends, tests.
set -euo pipefail
export LC_ALL=C

UPKEEP_CONFIG_DIR="${UPKEEP_CONFIG_DIR:-$HOME/.config/upkeep}"
UPKEEP_STATE_DIR="${UPKEEP_STATE_DIR:-$HOME/.local/state/upkeep}"
UPKEEP_PKEXEC="${UPKEEP_PKEXEC-pkexec}"
UPKEEP_REFRESH_HELPER="${UPKEEP_REFRESH_HELPER:-/usr/local/libexec/upkeep-refresh}"
UPKEEP_APPLY_HELPER="${UPKEEP_APPLY_HELPER:-/usr/local/libexec/upkeep-apply}"
UPKEEP_NOTIFY="${UPKEEP_NOTIFY:-notify-send}"

CONFIG_FILE="$UPKEEP_CONFIG_DIR/config"
HOLDS_FILE="$UPKEEP_CONFIG_DIR/holds"
STATE_FILE="$UPKEEP_STATE_DIR/state.json"
HIST_DIR="$UPKEEP_STATE_DIR/history"
LOG_DIR="$UPKEEP_STATE_DIR/logs"
SNAP_DIR="$UPKEEP_STATE_DIR/snapshots"
LAST_REFRESH_FILE="$UPKEEP_STATE_DIR/last_refresh"
OFFLINE_MARKER="$UPKEEP_STATE_DIR/offline_staged.json"
LOCK_FILE="$UPKEEP_STATE_DIR/lock"

upkeep_init_dirs() { mkdir -p "$UPKEEP_CONFIG_DIR" "$HIST_DIR" "$LOG_DIR" "$SNAP_DIR"; }

config_get() {  # key default
  local v
  v="$(grep -s "^$1=" "$CONFIG_FILE" | tail -1 | cut -d= -f2- || true)"
  printf '%s\n' "${v:-$2}"
}

config_set() {  # key value
  upkeep_init_dirs
  touch "$CONFIG_FILE"
  grep -v "^$1=" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

priv_refresh() { ${UPKEEP_PKEXEC:+$UPKEEP_PKEXEC} "$UPKEEP_REFRESH_HELPER" "$@"; }
priv_apply()   { ${UPKEEP_PKEXEC:+$UPKEEP_PKEXEC} "$UPKEEP_APPLY_HELPER" "$@"; }
notify()       { "$UPKEEP_NOTIFY" "$@" >/dev/null 2>&1 || true; }
now_iso()      { date -Is; }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_config.sh` → all `ok:` lines, exit 0. Then `tests/run_tests.sh` → ALL PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: common lib — paths, config get/set, priv wrappers"
```

---

### Task 4: Holds

**Files:**
- Modify: `lib/common.sh` (append)
- Test: `tests/test_holds.sh`

- [ ] **Step 1: Write the failing test**

`tests/test_holds.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
upkeep_init_dirs

hold_add dnf vim-common
hold_add flatpak org.gimp.GIMP
hold_add dnf vim-common                      # idempotent
assert_eq "$(holds_all | wc -l)" "2" "no duplicate holds"
assert_eq "$(holds_for dnf)" "vim-common" "dnf holds listed"
assert_eq "$(holds_for flatpak)" "org.gimp.GIMP" "flatpak holds listed"
hold_remove dnf vim-common
assert_eq "$(holds_for dnf | wc -l)" "0" "unhold removes"
assert_eq "$(holds_for flatpak)" "org.gimp.GIMP" "unhold is scoped to backend"
hold_remove dnf never-held                   # removing absent = ok, exit 0
assert_exit 0 "unhold absent is not an error" -- true
finish
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/test_holds.sh` → FAIL `hold_add: command not found`

- [ ] **Step 3: Append to lib/common.sh**

```bash
# --- holds: one "backend:name" per line ---
holds_all() { cat "$HOLDS_FILE" 2>/dev/null || true; }
holds_for() { holds_all | grep "^$1:" | cut -d: -f2- || true; }
hold_add() {  # backend name
  upkeep_init_dirs; touch "$HOLDS_FILE"
  grep -qxF "$1:$2" "$HOLDS_FILE" || printf '%s:%s\n' "$1" "$2" >> "$HOLDS_FILE"
}
hold_remove() {  # backend name
  [[ -f "$HOLDS_FILE" ]] || return 0
  grep -vxF "$1:$2" "$HOLDS_FILE" > "$HOLDS_FILE.tmp" || true
  mv "$HOLDS_FILE.tmp" "$HOLDS_FILE"
}
mark_held() {  # backend; stdin: JSON [{name,from,to}] → adds held:bool
  local holds_json
  holds_json="$(holds_for "$1" | jq -Rn '[inputs]')"
  # .name must be bound BEFORE entering the $holds pipeline — inside it, index()'s input is $holds
  jq --argjson holds "$holds_json" '[.[] | .name as $n | . + {held: (($holds | index($n)) != null)}]'
}
```

- [ ] **Step 4: Run both test files** — `tests/run_tests.sh` → ALL PASS

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: holds add/remove/list + mark_held"`

---

### Task 5: Snapshot diff (the report engine)

**Files:**
- Modify: `lib/common.sh` (append)
- Test: `tests/test_diff.sh`

- [ ] **Step 1: Write the failing test**

`tests/test_diff.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"

got="$(tsv_diff_updates "$FIXTURES/snap-before.tsv" "$FIXTURES/snap-after.tsv")"
expected='{
  "updated":[{"name":"kernel-core","from":"6.15.3-200.fc44","to":"6.15.4-200.fc44"},
             {"name":"vim-common","from":"2:9.1.900-1.fc44","to":"2:9.1.1000-1.fc44"}],
  "added":[{"name":"newpkg","to":"1.0-1.fc44"}],
  "removed":[{"name":"zsh","from":"5.9-11.fc44"}]
}'
assert_json_eq "$got" "$expected" "diff finds updated/added/removed, skips unchanged"

got2="$(tsv_diff_updates "$FIXTURES/snap-before.tsv" "$FIXTURES/snap-before.tsv")"
assert_json_eq "$got2" '{"updated":[],"added":[],"removed":[]}' "identical snapshots → empty"
finish
```

- [ ] **Step 2: Run to verify it fails** — FAIL `tsv_diff_updates: command not found`

- [ ] **Step 3: Append to lib/common.sh**

```bash
# --- snapshot diff: before/after TSV (name\tversion, sorted by name) → report JSON ---
tsv_diff_updates() {  # before_file after_file
  {
    join -t "$(printf '\t')" "$1" "$2" | awk -F'\t' '$2"" != $3"" {print "U\t"$1"\t"$2"\t"$3}'
    join -t "$(printf '\t')" -v2 "$1" "$2" | awk -F'\t' '{print "A\t"$1"\t\t"$2}'
    join -t "$(printf '\t')" -v1 "$1" "$2" | awk -F'\t' '{print "R\t"$1"\t"$2"\t"}'
  } | jq -Rn '
    [inputs | split("\t")] |
    { updated: [.[] | select(.[0]=="U") | {name:.[1], from:.[2], to:.[3]}],
      added:   [.[] | select(.[0]=="A") | {name:.[1], to:.[3]}],
      removed: [.[] | select(.[0]=="R") | {name:.[1], from:.[2]}] }'
}
```
The `$2"" != $3""` concatenation forces STRING comparison — without it awk compares numeric-looking versions numerically, so `1.1` vs `1.10` compare equal and a real upgrade vanishes from the report (live hazard on flatpak versions, which lack rpm's `-release` suffix).

- [ ] **Step 4: Run tests** — `tests/run_tests.sh` → ALL PASS
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: tsv_diff_updates snapshot report engine"`

POST-REVIEW NOTE (Tasks 3-5 as built): the repo's `lib/common.sh` is authoritative and goes beyond the blocks above after quality review — `LC_ALL=C.UTF-8`; `atomic_write` + read-then-write in `config_set`/`hold_remove` (a truncating partial write can no longer silently destroy config or holds); key/value validation in `config_set` and `UPKEEP_NAME_RE` validation in `hold_add` (a hold the root helper would later reject is refused at hold time); `config_get` warns on an unreadable config; `collapse_versions` establishes the ONE-row-per-name snapshot contract (Fedora installonly packages ship multiple installed versions — uncollapsed, `join` cross-products them into phantom update rows) and `tsv_diff_updates` rejects duplicate-name input with exit 65. Fixture `snap-multiver-raw.tsv` + tests cover all of it.

---

### Task 6: dnf backend

**Files:**
- Create: `backends/dnf.sh`
- Test: `tests/test_dnf.sh`

- [ ] **Step 1: Write the failing test**

`tests/test_dnf.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/backends/dnf.sh"

# Pure parser: fixture lines + installed lookup → items JSON
# Fixture contract (tests/fixtures/MANIFEST.md): 8 data lines parse to exactly 7 items —
# the bash.i686/bash.x86_64 multilib pair collapses; brandnew is absent from rpm-installed.tsv.
out="$(dnf_parse_check_update "$FIXTURES/rpm-installed.tsv" < "$FIXTURES/dnf-check-update.txt")"
assert_eq "$(jq 'length' <<<"$out")" "7" "8 fixture lines → 7 items (multilib pair collapses)"
assert_eq "$(jq -r '.[0] | has("name") and has("from") and has("to")' <<<"$out")" "true" "item shape"
assert_eq "$(jq -r '[.[].name] | any(test("\\.(x86_64|noarch|i686)$"))' <<<"$out")" "false" "arch suffix stripped"
assert_eq "$(jq -r '[.[].name] | map(select(. == "bash")) | length' <<<"$out")" "1" "bash appears once despite two arches"
assert_eq "$(jq -r '.[] | select(.name == "brandnew") | .from' <<<"$out")" "?" "not-installed package falls back to ?"
assert_eq "$(jq -r '[.[] | select(.name != "brandnew") | .from] | any(. == "?" or . == "")' <<<"$out")" "false" "installed packages resolve real from-versions"

# Impure check with stubbed helper: exit 100 + fixture on stdout
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == "check" ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub"
export UPKEEP_REFRESH_HELPER="$TESTTMP/refresh-stub"
export UPKEEP_DNF_INSTALLED_CMD="cat $FIXTURES/rpm-installed.tsv"
got="$(dnf_check)"
assert_eq "$(jq 'length' <<<"$got")" "7" "dnf_check wires helper→parser"

# Helper failure (exit 1, not 100) → dnf_check exits non-zero
cat > "$TESTTMP/refresh-stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
assert_exit 1 "dnf_check propagates failure" dnf_check
finish
```

- [ ] **Step 2: Run to verify it fails** — FAIL `backends/dnf.sh: No such file`

- [ ] **Step 3: Write backends/dnf.sh**

```bash
#!/usr/bin/env bash
# dnf5 backend. Pure parsers take stdin/files; impure funcs go through priv_* / overridable cmds.
# Requires lib/common.sh sourced first.

UPKEEP_DNF_INSTALLED_CMD="${UPKEEP_DNF_INSTALLED_CMD:-}"

dnf_installed_lookup() {  # → sorted TSV, ONE row per name, EVRs comma-joined (installonly pkgs — kernel*, gpg-pubkey — install multiple versions; without collapse_versions, join cross-products them into phantom updates)
  { if [[ -n "$UPKEEP_DNF_INSTALLED_CMD" ]]; then $UPKEEP_DNF_INSTALLED_CMD
    else rpm -qa --queryformat '%{NAME}\t%{EVR}\n' | sort; fi; } | collapse_versions
}

dnf_parse_check_update() {  # $1=installed TSV; stdin=dnf5 check-update lines → JSON [{name,from,to}]
  awk 'NF>=3 && $1 ~ /\.[A-Za-z0-9_]+$/ && $1 !~ /^#/ { n=$1; sub(/\.[^.]+$/, "", n); print n "\t" $2 }' \
  | sort -u \
  | join -t "$(printf '\t')" -a1 -e '?' -o '1.1,2.2,1.2' - "$1" \
  | jq -Rn '[inputs | split("\t") | {name:.[0], from:.[1], to:.[2]}]'
}

dnf_check() {  # → items JSON on stdout; exit 1 on helper failure
  local out rc=0 lookup
  out="$(priv_refresh check)" || rc=$?
  if [[ $rc -ne 0 && $rc -ne 100 ]]; then return 1; fi
  lookup="$(mktemp)"; dnf_installed_lookup > "$lookup"
  dnf_parse_check_update "$lookup" <<<"$out"
  rm -f "$lookup"
}

dnf_snapshot() { dnf_installed_lookup; }   # → TSV to stdout

dnf_reboot_needed() {  # → prints true|false
  local rc=0
  dnf5 needs-restarting -r >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 1 ]] && echo true || echo false
}
```

- [ ] **Step 4: Run tests** — `tests/run_tests.sh` → ALL PASS. If an assertion fails, fix the PARSER against the fixture's documented contract in tests/fixtures/MANIFEST.md (e.g. "Obsoleting packages" section headers must be excluded by the awk filter). Never weaken a test to make it pass.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: dnf backend — check parser + stub-driven check"`

---

### Task 7: flatpak backend

**Files:**
- Create: `backends/flatpak.sh`
- Test: `tests/test_flatpak.sh`

- [ ] **Step 1: Write the failing test**

`tests/test_flatpak.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/backends/flatpak.sh"

# Fixture contract (MANIFEST.md): 3 pending apps; com.example.NotInstalled is absent from flatpak-list.tsv.
out="$(flatpak_parse_remote_ls "$FIXTURES/flatpak-list.tsv" < "$FIXTURES/flatpak-remote-ls.txt")"
assert_eq "$(jq 'length' <<<"$out")" "3" "three pending flatpaks"
assert_eq "$(jq -r '.[0] | has("name") and has("from") and has("to")' <<<"$out")" "true" "item shape"
assert_eq "$(jq -r '.[] | select(.name == "com.example.NotInstalled") | .from' <<<"$out")" "?" "not-installed app falls back to ?"

export UPKEEP_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export UPKEEP_FLATPAK_LIST_CMD="cat $FIXTURES/flatpak-list.tsv"
got="$(flatpak_check)"
assert_eq "$(jq 'length' <<<"$got")" "3" "flatpak_check wires cmds→parser"

export UPKEEP_FLATPAK_REMOTE_CMD="false"
assert_exit 1 "flatpak_check propagates failure" flatpak_check
finish
```

- [ ] **Step 2: Run to verify it fails** — FAIL `backends/flatpak.sh: No such file`

- [ ] **Step 3: Write backends/flatpak.sh**

```bash
#!/usr/bin/env bash
# flatpak backend. Same contract as dnf.sh. Requires lib/common.sh sourced first.

UPKEEP_FLATPAK_REMOTE_CMD="${UPKEEP_FLATPAK_REMOTE_CMD:-flatpak remote-ls --updates --app --columns=application,version}"
UPKEEP_FLATPAK_LIST_CMD="${UPKEEP_FLATPAK_LIST_CMD:-flatpak list --app --columns=application,version}"

flatpak_parse_remote_ls() {  # $1=installed TSV (sorted); stdin=remote-ls lines → JSON [{name,from,to}]
  grep -vE '^(#|$)' \
  | sort -u \
  | join -t "$(printf '\t')" -a1 -e '?' -o '1.1,2.2,1.2' - "$1" \
  | jq -Rn '[inputs | split("\t") | {name:.[0], from:.[1], to:(.[2] // "?")}]'
}

flatpak_check() {  # → items JSON; exit 1 on failure
  local out lookup
  out="$($UPKEEP_FLATPAK_REMOTE_CMD)" || return 1
  lookup="$(mktemp)"; $UPKEEP_FLATPAK_LIST_CMD | sort | collapse_versions > "$lookup"
  flatpak_parse_remote_ls "$lookup" <<<"$out"
  rm -f "$lookup"
}

flatpak_snapshot() { $UPKEEP_FLATPAK_LIST_CMD | sort | collapse_versions; }   # same one-row-per-name contract as dnf
```
Note: remote-ls with `--columns=application,version` may emit an empty version column for some apps, and pending apps can be missing from the installed lookup — GNU join's `-a1 -e '?'` flags are the guard that fills those fields (jq's `//` does NOT catch empty strings, so don't "simplify" the join flags away as redundant). If the fixture shows a different column separator than TAB, fix the fixture capture (the `--columns` form IS tab-separated), not the parser.

- [ ] **Step 4: Run tests** — `tests/run_tests.sh` → ALL PASS
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: flatpak backend — pending parser + stub-driven check"`

---

### Task 8: State assembly + `upkeep check`

**Files:**
- Create: `bin/upkeep` (dispatcher + cmd_check; later tasks append commands)
- Modify: `lib/common.sh` (append assemble_state, refresh gating)
- Test: `tests/test_check.sh`

- [ ] **Step 1: Write the failing test**

`tests/test_check.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
UPKEEP="$REPO_ROOT/bin/upkeep"

# stubs: dnf helper serves fixture; flatpak served via cmd overrides
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
case "\$1" in
  check) cat "$FIXTURES/dnf-check-update.txt"; exit 100 ;;
  refresh) echo refreshed >> "$TESTTMP/refresh-calls"; exit 0 ;;
esac
STUB
chmod +x "$TESTTMP/refresh-stub"
export UPKEEP_REFRESH_HELPER="$TESTTMP/refresh-stub"
export UPKEEP_DNF_INSTALLED_CMD="cat $FIXTURES/rpm-installed.tsv"
export UPKEEP_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export UPKEEP_FLATPAK_LIST_CMD="cat $FIXTURES/flatpak-list.tsv"
export UPKEEP_SKIP_REFRESH=1   # deterministic: no metadata refresh attempts in tests

# Fixture contracts (tests/fixtures/MANIFEST.md): dnf parses to 7 items, flatpak to 3.
n_dnf=7
n_fp=3

state="$("$UPKEEP" check)"
assert_eq "$(jq -r .status <<<"$state")" "ok" "status ok"
assert_eq "$(jq '.backends.dnf.items | length' <<<"$state")" "$n_dnf" "dnf items in state"
assert_eq "$(jq '.backends.flatpak.items | length' <<<"$state")" "$n_fp" "flatpak items in state"
assert_eq "$(jq .actionable <<<"$state")" "$((n_dnf + n_fp))" "actionable = all when no holds"
assert_eq "$(jq -Sc . "$UPKEEP_STATE_DIR/state.json")" "$(jq -Sc . <<<"$state")" "state persisted atomically"

# holds: hold the first pending dnf package → actionable drops by 1, held_total=1
first="$(jq -r '.backends.dnf.items[0].name' <<<"$state")"
"$UPKEEP" hold "dnf:$first"
state2="$("$UPKEEP" check)"
assert_eq "$(jq .held_total <<<"$state2")" "1" "held_total counts the hold"
assert_eq "$(jq .actionable <<<"$state2")" "$((n_dnf + n_fp - 1))" "badge count excludes held"

# include_flatpak=false → flatpak absent
"$UPKEEP" config set include_flatpak false
state3="$("$UPKEEP" check)"
assert_eq "$(jq '.backends.flatpak.items | length' <<<"$state3")" "0" "flatpak disabled"

# dnf failure → stale, previous counts kept
cat > "$TESTTMP/refresh-stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
state4="$("$UPKEEP" check)"
assert_eq "$(jq -r .status <<<"$state4")" "stale" "check failure → stale"
assert_eq "$(jq '.backends.dnf.items | length' <<<"$state4")" "$(jq '.backends.dnf.items | length' <<<"$state2")" "stale keeps previous dnf items"
finish
```

- [ ] **Step 2: Run to verify it fails** — FAIL `bin/upkeep: No such file`

- [ ] **Step 3: Append to lib/common.sh**

```bash
# --- state assembly ---
assemble_state() {  # $1 dnf items JSON (held-marked), $2 flatpak items JSON, $3 status, $4 error
  jq -n --argjson dnf "$1" --argjson fp "$2" --arg status "$3" --arg error "$4" --arg now "$(now_iso)" '
    def wrap: {count: ([.[] | select(.held|not)] | length),
               held:  ([.[] | select(.held)] | length),
               items: .};
    {last_check: $now, status: $status, error: $error,
     backends: {dnf: ($dnf | wrap), flatpak: ($fp | wrap)},
     actionable: (($dnf + $fp) | [.[] | select(.held|not)] | length),
     held_total: (($dnf + $fp) | [.[] | select(.held)] | length)}'
}

state_prev_items() {  # backend → previous items JSON or []
  jq ".backends.$1.items // []" "$STATE_FILE" 2>/dev/null || echo '[]'
}

write_state() {  # stdin: state JSON; atomic
  cat > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

maybe_refresh_metadata() {  # ≤ every 3h, AC power, unmetered; never blocks check on failure
  [[ -n "${UPKEEP_SKIP_REFRESH:-}" ]] && return 0
  local last=0 now; now="$(date +%s)"
  [[ -f "$LAST_REFRESH_FILE" ]] && last="$(stat -c %Y "$LAST_REFRESH_FILE")"
  (( now - last < 10800 )) && return 0
  on_battery && return 0
  metered_connection && return 0
  priv_refresh refresh >/dev/null 2>&1 && touch "$LAST_REFRESH_FILE" || true
}

on_battery() {
  local ps
  for ps in /sys/class/power_supply/BAT*/status; do
    [[ -e "$ps" ]] && grep -q Discharging "$ps" && return 0
  done
  return 1
}

metered_connection() {
  busctl get-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager \
    org.freedesktop.NetworkManager Metered 2>/dev/null | grep -qE ' (1|3)$'
}
```

- [ ] **Step 4: Write bin/upkeep**

```bash
#!/usr/bin/env bash
# Upkeep — one-click system updates. See docs/superpowers/specs/2026-08-24-upkeep-design.md
set -euo pipefail
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT="$(dirname "$(dirname "$SELF")")"
source "$ROOT/lib/common.sh"
source "$ROOT/backends/dnf.sh"
source "$ROOT/backends/flatpak.sh"

cmd_check() {
  upkeep_init_dirs
  maybe_refresh_metadata
  local status="ok" error="" dnf_items fp_items
  if dnf_items="$(dnf_check)"; then :; else
    status="stale"; error="dnf check failed"; dnf_items="$(state_prev_items dnf)"
  fi
  if [[ "$(config_get include_flatpak true)" == "true" ]]; then
    if fp_items="$(flatpak_check)"; then :; else
      status="stale"; error="${error:+$error; }flatpak check failed"; fp_items="$(state_prev_items flatpak)"
    fi
  else
    fp_items='[]'
  fi
  dnf_items="$(mark_held dnf <<<"$dnf_items")"
  fp_items="$(mark_held flatpak <<<"$fp_items")"
  local state
  state="$(assemble_state "$dnf_items" "$fp_items" "$status" "$error")"
  printf '%s\n' "$state" | write_state
  printf '%s\n' "$state"
}

cmd_config() {
  case "${1:-}" in
    get) [[ -n "${2:-}" ]] || { echo "usage: upkeep config get <key> [default]" >&2; exit 2; }
         config_get "$2" "${3-}" ;;
    set) [[ -n "${2:-}" && -n "${3+x}" ]] || { echo "usage: upkeep config set <key> <value>" >&2; exit 2; }
         config_set "$2" "$3" ;;
    *) echo "usage: upkeep config get <key> [default] | set <key> <value>" >&2; exit 2 ;;
  esac
}

# a missing colon must not silently hold a package named after the backend ("upkeep hold dnf")
cmd_hold() {
  [[ "${1:-}" == *:* ]] || { echo "use dnf:<pkg> or flatpak:<app.id>" >&2; exit 2; }
  local b="${1%%:*}" n="${1#*:}"
  [[ "$b" == dnf || "$b" == flatpak ]] || { echo "use dnf:<pkg> or flatpak:<app.id>" >&2; exit 2; }
  hold_add "$b" "$n"
}
cmd_unhold() {
  [[ "${1:-}" == *:* ]] || { echo "use dnf:<pkg> or flatpak:<app.id>" >&2; exit 2; }
  local b="${1%%:*}" n="${1#*:}"
  hold_remove "$b" "$n"
}
cmd_holds()  { holds_all; }

usage() {
  cat <<'EOF'
usage: upkeep <command>
  check                 refresh pending-updates state (JSON to stdout)
  update                run the update now (options from config; --no-flatpak, --surface=X override)
  run                   launch update per configured surface (what the widget calls)
  summary [N]           human summary of the last (or Nth-last) run
  history               list past runs
  hold dnf:<pkg> | flatpak:<app.id>     skip in updates, still notify
  unhold <same>         remove a hold
  holds                 list holds
  config get|set        read/write settings
  enable-passwordless | disable-passwordless
EOF
}

case "${1:-help}" in
  check)   shift; cmd_check "$@" ;;
  config)  shift; cmd_config "$@" ;;
  hold)    shift; cmd_hold "$@" ;;
  unhold)  shift; cmd_unhold "$@" ;;
  holds)   shift; cmd_holds "$@" ;;
  help|--help|-h) usage ;;
  *) usage; exit 2 ;;
esac
```
`chmod +x bin/upkeep`.

- [ ] **Step 5: Run tests** — `tests/run_tests.sh` → ALL PASS
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: upkeep check — state assembly, holds-aware counts, stale fallback"`

---

### Task 9: Root helpers with validated args

Validation logic is testable WITHOUT root: bad args must exit 2 before any privileged command runs.

**Files:**
- Create: `libexec/upkeep-refresh`, `libexec/upkeep-apply`
- Test: `tests/test_helpers.sh`

- [ ] **Step 1: Write the failing test**

`tests/test_helpers.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
RH="$REPO_ROOT/libexec/upkeep-refresh"
AH="$REPO_ROOT/libexec/upkeep-apply"

assert_exit 2 "refresh: no verb"        bash "$RH"
assert_exit 2 "refresh: bad verb"       bash "$RH" nuke
assert_exit 2 "apply: no verb"          bash "$AH"
assert_exit 2 "apply: bad verb"         bash "$AH" rm-rf
assert_exit 2 "apply: injection via exclude" bash "$AH" dnf-upgrade '--exclude=foo;rm -rf /'
assert_exit 2 "apply: option smuggling"      bash "$AH" dnf-upgrade '--installroot=/'
assert_exit 2 "apply: bad flatpak id"        bash "$AH" flatpak-update -y 'evil;id'
# UPKEEP_APPLY_ECHO=1 makes the helper print the final command instead of exec'ing it (test seam)
got="$(UPKEEP_APPLY_ECHO=1 bash "$AH" dnf-upgrade -y --exclude=vim-common --exclude=kernel-core)"
assert_eq "$got" "dnf5 upgrade -y --exclude=vim-common --exclude=kernel-core" "dnf-upgrade builds exact command"
got2="$(UPKEEP_APPLY_ECHO=1 bash "$AH" dnf-offline-stage -y)"
assert_eq "$got2" "dnf5 upgrade --offline -y" "offline stage builds exact command"
got3="$(UPKEEP_APPLY_ECHO=1 bash "$AH" flatpak-update -y)"
assert_eq "$got3" "flatpak update --system --noninteractive -y" "flatpak all-apps command"
finish
```

- [ ] **Step 2: Run to verify it fails** — FAIL: helper files missing

- [ ] **Step 3: Write libexec/upkeep-refresh**

```bash
#!/usr/bin/env bash
# Upkeep root helper — metadata only. polkit action org.erez.upkeep.refresh (allow_active=yes).
set -euo pipefail
export LC_ALL=C.UTF-8
case "${1:-}" in
  check)   exec dnf5 --cacheonly check-update --quiet ;;   # exit 100 = updates pending
  refresh) exec dnf5 makecache --refresh ;;
  *) echo "usage: upkeep-refresh check|refresh" >&2; exit 2 ;;
esac
```

- [ ] **Step 4: Write libexec/upkeep-apply**

```bash
#!/usr/bin/env bash
# Upkeep root helper — upgrade verbs. polkit action org.erez.upkeep.apply (auth_admin_keep).
# SECURITY: every argument is validated; anything unexpected exits 2 before any privileged command.
set -euo pipefail
export LC_ALL=C.UTF-8
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._+-]*$'

run() {  # test seam: UPKEEP_APPLY_ECHO=1 prints instead of exec
  if [[ -n "${UPKEEP_APPLY_ECHO:-}" ]]; then echo "$*"; else exec "$@"; fi
}

verb="${1:-}"; shift || true
case "$verb" in
  dnf-upgrade|dnf-offline-stage)
    assume=(); excludes=()
    for a in "$@"; do
      case "$a" in
        -y) assume=(-y) ;;
        --exclude=*) n="${a#--exclude=}"
           [[ "$n" =~ $NAME_RE ]] || { echo "invalid exclude: $n" >&2; exit 2; }
           excludes+=("--exclude=$n") ;;
        *) echo "invalid arg: $a" >&2; exit 2 ;;
      esac
    done
    offline=(); [[ "$verb" == dnf-offline-stage ]] && offline=(--offline)
    run dnf5 upgrade "${offline[@]}" "${assume[@]}" "${excludes[@]}"
    ;;
  flatpak-update)
    assume=(); ids=()
    for a in "$@"; do
      case "$a" in
        -y) assume=(-y) ;;
        -*) echo "invalid arg: $a" >&2; exit 2 ;;
        *) [[ "$a" =~ $NAME_RE ]] || { echo "invalid app id: $a" >&2; exit 2; }
           ids+=("$a") ;;
      esac
    done
    if [[ ${#ids[@]} -eq 0 ]]; then
      run flatpak update --system --noninteractive "${assume[@]}"
    else
      # per-app so holds can be skipped; validate each id against the installed system set
      installed="$(flatpak list --system --app --columns=application 2>/dev/null || true)"
      for id in "${ids[@]}"; do
        grep -qxF "$id" <<<"$installed" || { echo "not installed: $id" >&2; exit 2; }
      done
      rc=0
      for id in "${ids[@]}"; do
        if [[ -n "${UPKEEP_APPLY_ECHO:-}" ]]; then echo "flatpak update --system --noninteractive ${assume[*]} $id"
        else flatpak update --system --noninteractive "${assume[@]}" "$id" || rc=1; fi
      done
      exit $rc
    fi
    ;;
  *) echo "usage: upkeep-apply dnf-upgrade|dnf-offline-stage|flatpak-update [args]" >&2; exit 2 ;;
esac
```
Note: bash `"${empty[@]}"` under `set -u` is safe on bash ≥ 4.4 (Fedora 44 has 5.x). The word-spacing in the ECHO output must match the test exactly — if a test fails only on double spaces, fix the run/echo line (e.g. `echo "$@"` semantics), not the test.

- [ ] **Step 5: `chmod +x libexec/*`; run tests** — `tests/run_tests.sh` → ALL PASS
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: root helpers with strict arg validation (testable unprivileged)"`

---

### Task 10: polkit files + passwordless toggle

**Files:**
- Create: `polkit/org.erez.upkeep.policy`, `polkit/49-upkeep.rules.in`
- Modify: `bin/upkeep` (add enable/disable-passwordless)
- Test: `tests/test_polkit.sh`

- [ ] **Step 1: Write the failing test**

`tests/test_polkit.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
POL="$REPO_ROOT/polkit/org.erez.upkeep.policy"
RULES_IN="$REPO_ROOT/polkit/49-upkeep.rules.in"

if command -v xmllint >/dev/null; then
  if xmllint --noout "$POL"; then echo "ok: policy XML well-formed"
  else echo "FAIL: policy XML malformed"; _fail=1; fi
else echo "ok: xmllint unavailable, skipped"; fi
assert_eq "$(grep -c '<action id=' "$POL")" "2" "two actions defined"
grep -q 'org.erez.upkeep.refresh' "$POL" && echo "ok: refresh action present" || { echo "FAIL: refresh action"; _fail=1; }
grep -q 'org.erez.upkeep.apply' "$POL" && echo "ok: apply action present" || { echo "FAIL: apply action"; _fail=1; }
grep -q '<allow_active>yes</allow_active>' "$POL" && echo "ok: refresh is no-dialog" || { echo "FAIL: allow_active"; _fail=1; }
grep -q 'auth_admin_keep' "$POL" && echo "ok: apply is auth_admin_keep" || { echo "FAIL: auth_admin_keep"; _fail=1; }
grep -q '/usr/local/libexec/upkeep-refresh' "$POL" && echo "ok: refresh path annotated" || { echo "FAIL: refresh path"; _fail=1; }
grep -q '/usr/local/libexec/upkeep-apply' "$POL" && echo "ok: apply path annotated" || { echo "FAIL: apply path"; _fail=1; }
grep -q '@USER@' "$RULES_IN" && echo "ok: rules template has placeholder" || { echo "FAIL: placeholder"; _fail=1; }
grep -q 'org.erez.upkeep.apply' "$RULES_IN" && echo "ok: rules scoped to apply action only" || { echo "FAIL: rules scope"; _fail=1; }
grep -q 'org.erez.upkeep.refresh' "$RULES_IN" && { echo "FAIL: rules must NOT touch refresh"; _fail=1; } || echo "ok: refresh not in rules"
finish
```

- [ ] **Step 2: Run to verify it fails** — FAIL: files missing

- [ ] **Step 3: Write polkit/org.erez.upkeep.policy**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1.0/policyconfig.dtd">
<policyconfig>
  <vendor>Upkeep</vendor>

  <action id="org.erez.upkeep.refresh">
    <description>Refresh package metadata</description>
    <message>Upkeep wants to refresh package metadata</message>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>no</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/libexec/upkeep-refresh</annotate>
  </action>

  <action id="org.erez.upkeep.apply">
    <description>Apply system updates</description>
    <message>Upkeep wants to update the system</message>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>no</allow_inactive>
      <allow_active>auth_admin_keep</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/libexec/upkeep-apply</annotate>
  </action>
</policyconfig>
```

- [ ] **Step 4: Write polkit/49-upkeep.rules.in**

```javascript
// Upkeep passwordless updates for @USER@ — installed/removed by `upkeep enable/disable-passwordless`.
// Scoped to the apply action ONLY (refresh is already no-dialog by policy).
polkit.addRule(function(action, subject) {
    if (action.id == "org.erez.upkeep.apply" &&
        subject.user == "@USER@" && subject.active && subject.local) {
        return polkit.Result.YES;
    }
});
```

- [ ] **Step 5: Add to bin/upkeep** (new cmd functions + two case arms `enable-passwordless) cmd_enable_passwordless ;;` / `disable-passwordless) cmd_disable_passwordless ;;`)

```bash
RULES_DST="/etc/polkit-1/rules.d/49-upkeep.rules"

cmd_enable_passwordless() {
  local tmp; tmp="$(mktemp)"
  sed "s/@USER@/$USER/" "$ROOT/polkit/49-upkeep.rules.in" > "$tmp"
  # dash (not colon-dash) on purpose: empty UPKEEP_PKEXEC means "no wrapper" (test sandbox),
  # matching priv_refresh/priv_apply — colon-dash would run REAL pkexec inside tests.
  ${UPKEEP_PKEXEC-pkexec} install -m 0644 -o root -g root "$tmp" "$RULES_DST"
  rm -f "$tmp"
  echo "Passwordless updates ENABLED for $USER ($RULES_DST)"
}

cmd_disable_passwordless() {
  ${UPKEEP_PKEXEC-pkexec} rm -f "$RULES_DST"
  echo "Passwordless updates disabled"
}
```

- [ ] **Step 6: Run tests** — `tests/run_tests.sh` → ALL PASS
- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat: polkit actions (split refresh/apply) + passwordless toggle"`

---

### Task 11: `upkeep update` — lock, retry, snapshots, history, notify

**Files:**
- Modify: `bin/upkeep` (cmd_update + helpers), `lib/common.sh` (lock)
- Test: `tests/test_update.sh`

- [ ] **Step 1: Write the failing test**

`tests/test_update.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
UPKEEP="$REPO_ROOT/bin/upkeep"

# Fake world: apply-stub "upgrades" by swapping which snapshot the installed-cmd serves.
export WORLD="$TESTTMP/world"; mkdir -p "$WORLD"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
cp "$FIXTURES/flatpak-list.tsv" "$WORLD/fp.tsv"
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
case "\$1" in
  dnf-upgrade)     cp "$FIXTURES/snap-after.tsv" "$WORLD/rpm.tsv" ;;
  dnf-offline-stage) touch "$WORLD/staged" ;;
  flatpak-update)  : ;;   # no flatpak changes in this fake world
esac
exit 0
STUB
chmod +x "$TESTTMP/apply-stub"
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub"
cat > "$TESTTMP/notify-stub" <<STUB
#!/usr/bin/env bash
echo "NOTIFY \$@" >> "$WORLD/notifications"
STUB
chmod +x "$TESTTMP/notify-stub"
export UPKEEP_APPLY_HELPER="$TESTTMP/apply-stub"
export UPKEEP_REFRESH_HELPER="$TESTTMP/refresh-stub"
export UPKEEP_NOTIFY="$TESTTMP/notify-stub"
export UPKEEP_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
export UPKEEP_FLATPAK_REMOTE_CMD="cat $FIXTURES/flatpak-remote-ls.txt"
export UPKEEP_FLATPAK_LIST_CMD="cat $WORLD/fp.tsv"
export UPKEEP_SKIP_REFRESH=1
export UPKEEP_REBOOT_CMD="false"   # false → exit 1 → reboot_needed=true

"$UPKEEP" config set surface background
"$UPKEEP" hold dnf:vim-common

out="$("$UPKEEP" update)"
hist="$(ls "$UPKEEP_STATE_DIR/history/" | tail -1)"
h="$UPKEEP_STATE_DIR/history/$hist"
assert_eq "$(jq -r .status "$h")" "ok" "history status ok"
assert_eq "$(jq '.backends.dnf.updated | length' "$h")" "2" "dnf updated from snapshot diff"
assert_eq "$(jq -r '.backends.dnf.skipped_held[0]' "$h")" "vim-common" "held pkg recorded as skipped"
assert_eq "$(jq -r .reboot_needed "$h")" "true" "reboot flag captured"
grep -q -- '--exclude=vim-common' "$WORLD/apply-calls" && echo "ok: hold became --exclude" || { echo "FAIL: exclude"; _fail=1; }
grep -q 'flatpak-update' "$WORLD/apply-calls" && echo "ok: flatpak ran" || { echo "FAIL: flatpak"; _fail=1; }
grep -q NOTIFY "$WORLD/notifications" && echo "ok: non-terminal surface notified" || { echo "FAIL: notify"; _fail=1; }

# second update while lock held → refuses
mkdir -p "$UPKEEP_STATE_DIR"; echo 99999999 > "$UPKEEP_STATE_DIR/lock"
assert_exit 3 "concurrent update refused" "$UPKEEP" update
rm -f "$UPKEEP_STATE_DIR/lock"

# helper failure with lock-ish stderr → retried then fails cleanly
cat > "$TESTTMP/apply-stub" <<'STUB'
#!/usr/bin/env bash
echo "cannot open lock file: held by another process" >&2; exit 1
STUB
export UPKEEP_RETRY_DELAY=0
assert_exit 1 "busy rpm lock eventually fails" "$UPKEEP" update
assert_eq "$(grep -c 'retrying' "$(ls -t "$UPKEEP_STATE_DIR"/logs/* | head -1)")" "2" "two retries logged"
finish
```

- [ ] **Step 2: Run to verify it fails** — FAIL: `update` hits the usage arm (exit 2)

- [ ] **Step 3: Append lock helpers to lib/common.sh**

```bash
# --- update lock (our own concurrency; foreign rpm lock handled by retry in cmd_update) ---
acquire_lock() {
  upkeep_init_dirs
  if [[ -f "$LOCK_FILE" ]] && kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then return 1; fi
  [[ -f "$LOCK_FILE" ]] && echo "note: clearing stale upkeep lock" >&2
  echo $$ > "$LOCK_FILE"
}
release_lock() { rm -f "$LOCK_FILE"; }
```
(A lockfile whose PID is dead is stale and gets cleared — the 8-days-frozen restic lock lesson.)

- [ ] **Step 4: Add cmd_update to bin/upkeep** (+ case arm `update) shift; cmd_update "$@" ;;`)

```bash
UPKEEP_REBOOT_CMD="${UPKEEP_REBOOT_CMD:-dnf5 needs-restarting -r}"
UPKEEP_RETRY_DELAY="${UPKEEP_RETRY_DELAY:-10}"

apply_with_retry() {  # log_file verb args... ; retries on foreign package-lock errors
  local log="$1"; shift
  local attempt rc
  for attempt in 1 2 3; do
    rc=0
    priv_apply "$@" >>"$log" 2>&1 || rc=$?
    [[ $rc -eq 0 ]] && return 0
    if tail -n 20 "$log" | grep -qiE 'lock|another (process|application)'; then
      echo "Package system busy (PackageKit/Discover?) — retrying in ${UPKEEP_RETRY_DELAY}s ($attempt/3)" | tee -a "$log" >&2
      sleep "$UPKEEP_RETRY_DELAY"
    else
      return $rc
    fi
  done
  return $rc
}

cmd_update() {
  local surface include_fp="" 
  surface="$(config_get surface terminal)"
  for a in "$@"; do case "$a" in
    --no-flatpak) include_fp=false ;;
    --surface=*) surface="${a#--surface=}" ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac; done
  [[ -z "$include_fp" ]] && include_fp="$(config_get include_flatpak true)"
  local auto; auto="$(config_get auto_accept true)"

  acquire_lock || { echo "another upkeep update is running" >&2; exit 3; }
  trap release_lock EXIT

  upkeep_init_dirs
  local ts start log status="ok" reboot=false
  ts="$(date +%Y%m%dT%H%M%S)"; start="$(date +%s)"
  log="$LOG_DIR/$ts.log"

  # snapshots (before)
  dnf_snapshot > "$SNAP_DIR/dnf-before.tsv"
  [[ "$include_fp" == "true" ]] && flatpak_snapshot > "$SNAP_DIR/fp-before.tsv"

  # dnf
  local yflag=() excl=() dnf_status="ok"
  [[ "$auto" == "true" ]] && yflag=(-y)
  local held_dnf; held_dnf="$(holds_for dnf)"
  while IFS= read -r h; do [[ -n "$h" ]] && excl+=("--exclude=$h"); done <<<"$held_dnf"
  if [[ "$surface" == "offline" ]]; then
    apply_with_retry "$log" dnf-offline-stage "${yflag[@]}" "${excl[@]}" || { dnf_status="failed"; status="failed"; }
  else
    apply_with_retry "$log" dnf-upgrade "${yflag[@]}" "${excl[@]}" || { dnf_status="failed"; status="failed"; }
  fi

  # flatpak (live even when dnf staged offline — flatpak has no offline mechanism)
  local fp_status="skipped"
  if [[ "$include_fp" == "true" ]]; then
    fp_status="ok"
    local held_fp ids=()
    held_fp="$(holds_for flatpak)"
    if [[ -n "$held_fp" ]]; then
      # holds exist → per-app updates of every pending, non-held app
      while IFS= read -r id; do
        [[ -n "$id" ]] && ! grep -qxF "$id" <<<"$held_fp" && ids+=("$id")
      done < <(flatpak_check 2>/dev/null | jq -r '.[].name')
      if [[ ${#ids[@]} -gt 0 ]]; then
        apply_with_retry "$log" flatpak-update "${yflag[@]}" "${ids[@]}" || { fp_status="failed"; status="failed"; }
      fi
    else
      apply_with_retry "$log" flatpak-update "${yflag[@]}" || { fp_status="failed"; status="failed"; }
    fi
  fi

  # snapshots (after) + reports
  # Reports must never crash cmd_update after the system already changed — degrade to empty + warning.
  dnf_snapshot > "$SNAP_DIR/dnf-after.tsv"
  local empty_report='{"updated":[],"added":[],"removed":[]}'
  local dnf_report fp_report="$empty_report"
  dnf_report="$(tsv_diff_updates "$SNAP_DIR/dnf-before.tsv" "$SNAP_DIR/dnf-after.tsv")" \
    || { dnf_report="$empty_report"; echo "warning: dnf report diff failed - summary incomplete, see snapshots in $SNAP_DIR" | tee -a "$log" >&2; }
  if [[ "$include_fp" == "true" ]]; then
    flatpak_snapshot > "$SNAP_DIR/fp-after.tsv"
    fp_report="$(tsv_diff_updates "$SNAP_DIR/fp-before.tsv" "$SNAP_DIR/fp-after.tsv")" \
      || { fp_report="$empty_report"; echo "warning: flatpak report diff failed - summary incomplete" | tee -a "$log" >&2; }
  fi
  local rrc=0
  $UPKEEP_REBOOT_CMD >/dev/null 2>&1 || rrc=$?
  [[ $rrc -eq 1 ]] && reboot=true

  # offline staging marker (harvested by cmd_check after reboot — Task 12)
  if [[ "$surface" == "offline" && "$dnf_status" == "ok" ]]; then
    # marker owns its snapshot copy — a later update run overwrites dnf-before.tsv
    cp "$SNAP_DIR/dnf-before.tsv" "$SNAP_DIR/offline-pre-$ts.tsv"
    jq -n --arg ts "$(now_iso)" --arg snap "$SNAP_DIR/offline-pre-$ts.tsv" \
      '{staged_at:$ts, pre_snapshot:$snap}' > "$OFFLINE_MARKER"
  fi

  # history entry
  local held_dnf_json held_fp_json hist="$HIST_DIR/$ts.json"
  held_dnf_json="$(holds_for dnf | jq -Rn '[inputs]')"
  held_fp_json="$(holds_for flatpak | jq -Rn '[inputs]')"
  jq -n --arg ts "$(now_iso)" --arg surface "$surface" --arg status "$status" \
        --arg log "$log" --argjson dur "$(( $(date +%s) - start ))" \
        --argjson reboot "$reboot" \
        --argjson dnf "$dnf_report" --arg dnf_status "$dnf_status" --argjson dnf_held "$held_dnf_json" \
        --argjson fp "$fp_report" --arg fp_status "$fp_status" --argjson fp_held "$held_fp_json" '
    {timestamp:$ts, surface:$surface, status:$status, duration_sec:$dur,
     reboot_needed:$reboot, log:$log,
     backends: {
       dnf:     ($dnf | . + {status:$dnf_status, skipped_held:$dnf_held}),
       flatpak: ($fp  | . + {status:$fp_status,  skipped_held:$fp_held}) }}' > "$hist"

  # tell the human
  render_summary "$hist"
  if [[ "$surface" != "terminal" ]]; then
    local n; n="$(jq '[.backends[].updated | length] | add' "$hist")"
    if [[ "$surface" == "offline" ]]; then
      notify "Upkeep" "Updates staged — they apply on the next reboot"
    elif [[ "$status" == "ok" ]]; then
      notify "Upkeep" "$n packages updated$([[ "$reboot" == "true" ]] && echo ', reboot needed')"
    else
      notify "Upkeep" "Update FAILED — see $log"
    fi
  fi
  [[ "$status" == "ok" ]]
}
```
Also add a temporary `render_summary() { jq -r .status "$1"; }` stub to lib/common.sh — Task 12 replaces it (its test will force the real one).

- [ ] **Step 5: Run tests** — `tests/run_tests.sh` → ALL PASS
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: upkeep update — retry on foreign lock, snapshot reports, history, notify"`

---

### Task 12: Summary + history renderers + offline harvest

**Files:**
- Modify: `lib/common.sh` (real render_summary), `bin/upkeep` (cmd_summary, cmd_history, harvest in cmd_check)
- Test: `tests/test_summary.sh`

- [ ] **Step 1: Write the failing test**

`tests/test_summary.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
UPKEEP="$REPO_ROOT/bin/upkeep"
upkeep_init_dirs

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
finish
```

- [ ] **Step 2: Run to verify it fails** — FAIL: stub render_summary prints only "ok"

- [ ] **Step 3: Replace the render_summary stub in lib/common.sh**

```bash
render_summary() {  # history-json-file → human text
  jq -r '
    def newest(v): v | split(",") | last;   # installonly sets stay truthful in JSON; humans see newest → newest
    def lines(b): b.updated | map("  " + .name + " " + newest(.from) + " → " + newest(.to)) | join("\n");
    def heldline: [.backends[].skipped_held[]] | if length == 0 then empty
                  else "Held (skipped): " + join(", ") end;
    "Upkeep — " + .timestamp + " (" + .surface + ", " + (.duration_sec|tostring) + "s) "
      + (if .status == "ok" then "✓" else "FAILED — see " + .log end),
    "System (dnf): " + (.backends.dnf.updated|length|tostring) + " updated"
      + (if .backends.dnf.status != "ok" then " [" + .backends.dnf.status + "]" else "" end),
    (if (.backends.dnf.updated|length) > 0 then lines(.backends.dnf) else empty end),
    "Apps (flatpak): " + (.backends.flatpak.updated|length|tostring) + " updated"
      + (if .backends.flatpak.status != "ok" then " [" + .backends.flatpak.status + "]" else "" end),
    (if (.backends.flatpak.updated|length) > 0 then lines(.backends.flatpak) else empty end),
    heldline,
    "Reboot: " + (if .reboot_needed then "needed" else "not needed" end)
  ' "$1"
}
```

- [ ] **Step 4: Add cmd_summary / cmd_history to bin/upkeep** (+ case arms)

```bash
cmd_summary() {  # [N] — 1 = latest (default)
  local n="${1:-1}" f
  f="$(ls -1 "$HIST_DIR"/*.json 2>/dev/null | sort | tail -n "$n" | head -1)"
  [[ -n "$f" ]] || { echo "no update runs recorded yet"; exit 0; }
  render_summary "$f"
}

cmd_history() {
  local f
  for f in $(ls -1 "$HIST_DIR"/*.json 2>/dev/null | sort -r); do
    jq -r '[.timestamp, .surface, .status,
            (([.backends[].updated | length] | add | tostring) + " updated")] | join("  ")' "$f"
  done
}
```

- [ ] **Step 5: Add offline harvest — call `harvest_offline` at the top of cmd_check, implement in bin/upkeep**

```bash
harvest_offline() {
  [[ -f "$OFFLINE_MARKER" ]] || return 0
  local pre now_snap
  pre="$(jq -r .pre_snapshot "$OFFLINE_MARKER")"
  now_snap="$(mktemp)"; dnf_snapshot > "$now_snap"
  if cmp -s "$pre" "$now_snap"; then rm -f "$now_snap"; return 0; fi   # not applied yet
  local ts report hist
  ts="$(date +%Y%m%dT%H%M%S)"
  report="$(tsv_diff_updates "$pre" "$now_snap")"
  hist="$HIST_DIR/$ts.json"
  jq -n --arg ts "$(now_iso)" --argjson dnf "$report" '
    {timestamp:$ts, surface:"offline (applied on reboot)", status:"ok", duration_sec:0,
     reboot_needed:false, log:"",
     backends:{dnf:($dnf + {status:"ok", skipped_held:[]}),
               flatpak:{updated:[],added:[],removed:[],status:"skipped",skipped_held:[]}}}' > "$hist"
  rm -f "$OFFLINE_MARKER" "$now_snap" "$pre"   # $pre is the marker-owned copy
  notify "Upkeep" "Staged updates were applied on reboot — $(jq '.backends.dnf.updated|length' "$hist") packages"
}
```
Caveat (documented in spec): ANY rpm change after staging trips the harvest — acceptable v1 behavior; the diff is still truthful.

Add a harvest assertion to `tests/test_update.sh` (append before `finish`):
```bash
# offline harvest: stage marker + changed snapshot → history entry appears on next check
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
jq -n --arg snap "$FIXTURES/snap-before.tsv" '{staged_at:"x", pre_snapshot:$snap}' > "$UPKEEP_STATE_DIR/offline_staged.json"
cp "$FIXTURES/snap-after.tsv" "$WORLD/rpm.tsv"
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
"$UPKEEP" check >/dev/null
[[ ! -f "$UPKEEP_STATE_DIR/offline_staged.json" ]] && echo "ok: marker consumed" || { echo "FAIL: marker"; _fail=1; }
ls "$UPKEEP_STATE_DIR"/history/*.json >/dev/null 2>&1 && echo "ok: harvest wrote history" || { echo "FAIL: harvest"; _fail=1; }
```

- [ ] **Step 6: Run tests** — `tests/run_tests.sh` → ALL PASS
- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat: summary/history renderers + offline harvest on check"`

---

### Task 13: `upkeep run` — surface dispatcher

**Files:**
- Modify: `bin/upkeep` (cmd_run + case arm)
- Test: `tests/test_run.sh`

- [ ] **Step 1: Write the failing test**

`tests/test_run.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
UPKEEP="$REPO_ROOT/bin/upkeep"

# --dry-run prints the launch plan instead of spawning anything
"$UPKEEP" config set surface terminal
assert_eq "$("$UPKEEP" run --dry-run)" "terminal: konsole -e upkeep update" "terminal plan"
"$UPKEEP" config set surface background
assert_eq "$("$UPKEEP" run --dry-run)" "detached: upkeep update (surface=background)" "background plan"
"$UPKEEP" config set surface popup
assert_eq "$("$UPKEEP" run --dry-run)" "detached: upkeep update (surface=popup)" "popup plan"
"$UPKEEP" config set surface offline
assert_eq "$("$UPKEEP" run --dry-run)" "detached: upkeep update (surface=offline)" "offline plan"
# auto_accept=false forces terminal regardless of surface
"$UPKEEP" config set auto_accept false
assert_eq "$("$UPKEEP" run --dry-run)" "terminal: konsole -e upkeep update" "no-auto-accept forces terminal"
finish
```

- [ ] **Step 2: Run to verify it fails** — FAIL: `run` hits usage arm

- [ ] **Step 3: Add cmd_run to bin/upkeep** (+ case arm `run) shift; cmd_run "$@" ;;`)

```bash
cmd_run() {
  local dry="" surface auto
  [[ "${1:-}" == "--dry-run" ]] && dry=1
  surface="$(config_get surface terminal)"
  auto="$(config_get auto_accept true)"
  [[ "$auto" != "true" ]] && surface="terminal"   # only a terminal can prompt

  if [[ "$surface" == "terminal" ]]; then
    if [[ -n "$dry" ]]; then echo "terminal: konsole -e upkeep update"; return 0; fi
    setsid konsole -e bash -c \
      "'$SELF' update; ec=\$?; echo; read -rn1 -s -p 'Press any key to close…'; exit \$ec" \
      >/dev/null 2>&1 &
  else
    if [[ -n "$dry" ]]; then echo "detached: upkeep update (surface=$surface)"; return 0; fi
    setsid bash -c "'$SELF' update --surface=$surface" >/dev/null 2>&1 &
  fi
}
```

- [ ] **Step 4: Run tests** — `tests/run_tests.sh` → ALL PASS
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: upkeep run surface dispatcher (+ auto-accept forces terminal)"`

---

### Task 14: install.sh + live verification (USER-GATED at the end)

**Files:**
- Create: `install.sh`
- Test: `tests/test_install.sh`

- [ ] **Step 1: Write the failing test**

`tests/test_install.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
D="$TESTTMP/stage"
bash "$REPO_ROOT/install.sh" --destdir "$D" >/dev/null
[[ -x "$D/usr/local/libexec/upkeep-refresh" ]] && echo "ok: refresh helper staged" || { echo "FAIL: refresh helper"; _fail=1; }
[[ -x "$D/usr/local/libexec/upkeep-apply" ]] && echo "ok: apply helper staged" || { echo "FAIL: apply helper"; _fail=1; }
[[ -f "$D/usr/share/polkit-1/actions/org.erez.upkeep.policy" ]] && echo "ok: policy staged" || { echo "FAIL: policy"; _fail=1; }
[[ -L "$D$HOME/.local/bin/upkeep" ]] && echo "ok: CLI symlinked" || { echo "FAIL: symlink"; _fail=1; }
finish
```

- [ ] **Step 2: Run to verify it fails** — FAIL: install.sh missing

- [ ] **Step 3: Write install.sh**

```bash
#!/usr/bin/env bash
# Upkeep installer. --destdir <dir> stages everything unprivileged (for tests/packaging);
# real mode symlinks the CLI and installs helpers+policy with ONE pkexec prompt.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTDIR=""
UNINSTALL=""
for a in "$@"; do case "$a" in
  --destdir) : ;;                    # value read below
  --uninstall) UNINSTALL=1 ;;
esac; done
[[ "${1:-}" == "--destdir" ]] && DESTDIR="$2"

if [[ -n "$UNINSTALL" ]]; then
  rm -f "$HOME/.local/bin/upkeep"
  pkexec bash -c "rm -f /usr/local/libexec/upkeep-refresh /usr/local/libexec/upkeep-apply \
    /usr/share/polkit-1/actions/org.erez.upkeep.policy /etc/polkit-1/rules.d/49-upkeep.rules"
  echo "Upkeep uninstalled (config/state in ~/.config/upkeep, ~/.local/state/upkeep left in place)"
  exit 0
fi

if [[ -n "$DESTDIR" ]]; then
  install -D -m 755 "$ROOT/libexec/upkeep-refresh" "$DESTDIR/usr/local/libexec/upkeep-refresh"
  install -D -m 755 "$ROOT/libexec/upkeep-apply"   "$DESTDIR/usr/local/libexec/upkeep-apply"
  install -D -m 644 "$ROOT/polkit/org.erez.upkeep.policy" "$DESTDIR/usr/share/polkit-1/actions/org.erez.upkeep.policy"
  mkdir -p "$DESTDIR$HOME/.local/bin"
  ln -sf "$ROOT/bin/upkeep" "$DESTDIR$HOME/.local/bin/upkeep"
  echo "staged into $DESTDIR"
  exit 0
fi

mkdir -p "$HOME/.local/bin"
ln -sf "$ROOT/bin/upkeep" "$HOME/.local/bin/upkeep"
pkexec bash -c "install -m 755 -o root -g root '$ROOT/libexec/upkeep-refresh' '$ROOT/libexec/upkeep-apply' /usr/local/libexec/ \
  && install -m 644 -o root -g root '$ROOT/polkit/org.erez.upkeep.policy' /usr/share/polkit-1/actions/"
echo "Installed. Try: upkeep check"

# Recommended: stop Discover's notifier (duplicate nags + it holds the dnf5 lock at random — see spec)
read -rp "Disable plasma-discover-notifier for this user? [Y/n] " ans
if [[ "${ans,,}" != "n" ]]; then
  mkdir -p "$HOME/.config/autostart"
  cp /etc/xdg/autostart/org.kde.discover.notifier.desktop "$HOME/.config/autostart/" 2>/dev/null || true
  echo "Hidden=true" >> "$HOME/.config/autostart/org.kde.discover.notifier.desktop"
  pkill -f DiscoverNotifier 2>/dev/null || true
  echo "DiscoverNotifier disabled for $USER (delete ~/.config/autostart/org.kde.discover.notifier.desktop to undo)"
fi
```

- [ ] **Step 4: `chmod +x install.sh`; run tests** — `tests/run_tests.sh` → ALL PASS
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: install.sh with destdir staging, one-prompt root install, notifier opt-out"`

- [ ] **Step 6: LIVE VERIFICATION — STOP: requires Erez at the keyboard (pkexec auth + a real update run).**

Do NOT execute this step autonomously. Present this checklist to the user and walk through it together:
1. `./install.sh` → auth prompt once → installed.
2. `upkeep check` → real pending counts, no auth dialog (refresh action is allow_active=yes). Verify `jq .actionable ~/.local/state/upkeep/state.json` matches `dnf5 check-update` reality.
3. `upkeep hold dnf:<some pending pkg>` → `upkeep check` → actionable drops by one.
4. `upkeep update` in a terminal → ONE auth dialog → real run → summary shows old→new versions; held package in "Held (skipped)".
5. `upkeep summary` and `upkeep history` render the run.
6. `upkeep run` with surface=background → notification appears.
7. Check `dnf5 needs-restarting` agreement with the summary's Reboot line.

---

## Final self-review checklist (after all tasks)

- [ ] `tests/run_tests.sh` → ALL PASS, and `bash -n` every script (`bin/upkeep lib/common.sh backends/*.sh libexec/* install.sh`) → no syntax errors
- [ ] Spec coverage sweep against `docs/superpowers/specs/2026-08-24-upkeep-design.md`: every CLI subcommand listed there exists; holds semantics (skip + notify + summary line) all present; C2 (lock retry), C3 (root-cache check), C4 (flatpak via apply helper), C5 (split actions), C7 (3h/battery/metered gating) each traceable to code
- [ ] `git log` shows one commit per task minimum

Plan 2 (Plasma widget) is written after this plan completes and is reviewed against the CLI as actually built.
