# Architecture

Upkeep is two layers with a deliberately boring boundary between them.

```
  Plasma panel widget (QML)          thin: no package-manager knowledge at all
        |  upkeep check / run / config          (Plan 2, not written yet)
        v
  upkeep CLI (bash)                  all the logic
   |-- lib/common.sh                 config, holds, snapshots, diff, state, locking
   |-- backends/dnf.sh               pure parsers + check/snapshot
   |-- backends/flatpak.sh           same shape
   |  (privilege boundary: one pkexec per polkit action)
   v
  libexec/upkeep-refresh  (root)     metadata only, no dialog
  libexec/upkeep-apply    (root)     the upgrade verbs, one auth per run
```

The rule that shapes everything: **the badge count must come from the same command path that
performs the update**. A front end that disagrees with the CLI is the defining complaint about
every tool in this space, so `upkeep check` reads the root metadata cache the update itself will
use, applies the same holds, and runs the same backends.

## Repo layout

| Path | Role |
| --- | --- |
| `bin/upkeep` | Command dispatch and every `cmd_*` implementation |
| `lib/common.sh` | Shared library: paths, config, holds, snapshot diff, state assembly, locks, summary rendering |
| `backends/dnf.sh`, `backends/flatpak.sh` | One file per package manager |
| `libexec/upkeep-refresh`, `libexec/upkeep-apply` | The only code that runs as root |
| `polkit/` | The two action definitions plus the passwordless rule template |
| `install.sh` | Symlink install, staged install (`--destdir`), uninstall |
| `tests/` | Fixture-driven bash test suite, no framework dependency |

## The backend contract

A backend is one file that answers two questions, both on stdout, both with an explicit exit
status:

| Function | Input | Output |
| --- | --- | --- |
| `<backend>_check` | none (it queries the world through overridable command variables) | items JSON: `[{"name": "...", "from": "...", "to": "..."}]`. Empty is `[]` with exit 0. Non-zero means the check failed. |
| `<backend>_snapshot` | none | TSV, `name<TAB>version`, sorted by name, **exactly one row per name** |

Anything a backend parses lives in a pure function that takes stdin plus an installed-lookup
file, so it can be tested against a recorded fixture with no package manager present:
`dnf_parse_check_update`, `flatpak_parse_remote_ls`.

Two things the spec lists as backend responsibilities are deliberately **not** per-backend in the
build:

- **update** is `libexec/upkeep-apply` plus the wiring in `cmd_update`, because applying updates
  is the privileged half and must stay in one audited place.
- **report** is `tsv_diff_updates` in `lib/common.sh`, shared by every backend.

### Why reports come from snapshots, not from history output

`upkeep update` takes a `<backend>_snapshot` before the run and another after it, and diffs them.
It does not parse `dnf5 history info` or flatpak's transaction output. That choice buys three
things: the parsing surface stays one small function instead of one per tool, the result is
locale-proof (no human-readable output is parsed at all), and a new backend gets reporting for
free by implementing a snapshot rather than another parser.

The diff classifies every name into `updated` (present in both, different version), `added`
(after only) and `removed` (before only). Version comparison is forced to string comparison,
because awk compares numeric-looking fields numerically and a real `1.1` to `1.10` bump would
otherwise compare equal and vanish from the report.

### One row per name, and the installonly story

Fedora keeps several versions of *installonly* packages installed at once: `kernel-core` and
friends, plus `gpg-pubkey`. A raw `rpm -qa` listing therefore repeats names, and `join` on
duplicate names produces a **cross product**. Measured on a real box: a self-diff of the
installed package list, where nothing had changed at all, produced 192 phantom "updated" rows.

So the contract has two halves and both are load-bearing:

- Every producer pipes through `collapse_versions`, giving one row per name with the versions
  comma-joined in input order (`6.15.4-200.fc44,6.15.3-200.fc44`).
- `tsv_diff_updates` **refuses** duplicate-name input with exit 65 instead of emitting fiction.

The same collapse runs on the pending side, where the problem is multilib rather than installonly:
`bash.x86_64` and `bash.i686` routinely sit at different releases, and they are one package as far
as a user is concerned. Human-facing output shows the newest version of a comma-joined set; the
JSON keeps the whole set.

## State JSON schema v1

`~/.local/state/upkeep/state.json` is a **public interface**. The widget parses it blind, and so
can anything else. It is frozen: fields may be added, nothing may change meaning or type without
bumping `schema`.

```json
{
  "schema": 1,
  "last_check": "2026-08-24T22:11:45+03:00",
  "last_success": "2026-08-24T22:11:45+03:00",
  "status": "ok",
  "error": "",
  "backends": {
    "dnf": {
      "enabled": true,
      "actionable": 7,
      "held": 0,
      "items": [
        { "name": "curl", "from": "8.18.0-8.fc44", "to": "8.18.0-9.fc44", "held": false }
      ]
    },
    "flatpak": {
      "enabled": true,
      "actionable": 3,
      "held": 0,
      "items": [
        { "name": "net.mkiol.SpeechNote", "from": "4.8.4", "to": "4.8.5", "held": false }
      ]
    }
  },
  "actionable": 10,
  "held_total": 0,
  "risky_pending": []
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `schema` | integer | Always `1` for this format. |
| `last_check` | ISO 8601 with offset | When this check ran, successful or not. |
| `last_success` | ISO 8601, or `null` | When a check last succeeded. `null` until the first success; kept at its old value while `status` is `stale`. |
| `status` | `"ok"` or `"stale"` | `stale` means at least one backend failed and its previous items were reused. |
| `error` | string | Empty when fine; otherwise the backend failure messages, joined with `"; "`. |
| `backends.<name>.enabled` | boolean | False when the backend is switched off in config (`include_flatpak=false`). |
| `backends.<name>.actionable` | integer | Pending, not held, in this backend. |
| `backends.<name>.held` | integer | Pending and held, in this backend. |
| `backends.<name>.items[]` | array | `name`, `from` (installed version, `?` when not installed), `to` (pending version), `held` (boolean). |
| `actionable` | integer | The badge number: non-held pending items across all backends. |
| `held_total` | integer | Held pending items across all backends. |
| `risky_pending` | array of strings | dnf package names matching `risky_regex`, excluding held ones and excluding build or documentation tails (`-devel`, `-doc` and friends). Additive key: readers must tolerate its absence in files written by older builds. |

Two rules for anything that reads this file:

1. **Empty stdout from `upkeep check` with exit 0 means "no data, keep the last known state"**,
   never "zero updates". It happens when another check holds the lock and there is no valid
   previous state to serve.
2. `status: "stale"` is not an error state to alarm the user with. The counts are still the best
   known truth; surface the staleness in a tooltip, not a warning icon.

A new backend adds a key under `backends` and stays schema 1: existing readers ignore what they
do not know, and the totals keep working.

## The privileged boundary

Two root helpers, one per polkit action, because polkit's `auth_admin_keep` caches per action id
and a cheap verb must never share an action with a dangerous one:

- `upkeep-refresh` (`org.erez.upkeep.refresh`, no dialog): `check` and `refresh`, metadata only.
- `upkeep-apply` (`org.erez.upkeep.apply`, one auth per run): `dnf-upgrade`,
  `dnf-offline-stage`, `flatpak-update`.

Both validate every argument before running anything, accept no free-form arguments at all, and
pin `PATH` and `LC_ALL`. The full model, including what passwordless mode grants, is in
[security.md](security.md).

## Adding a backend for your distro

This is the most valuable contribution anyone can make, and the contract is small on purpose:
one new file, one new verb in the apply helper, fixtures, and tests.

### 1. Write `backends/<name>.sh`

Two required functions plus the pure parser they share. Model it on `backends/flatpak.sh`, which
is the shorter of the two shipped backends.

```bash
#!/usr/bin/env bash
# apt backend SKETCH. Requires lib/common.sh sourced first.

# Every impure command goes through a variable, so a test can replace it with `cat fixture`.
UPKEEP_APT_PENDING_CMD="${UPKEEP_APT_PENDING_CMD:-apt list --upgradable}"
UPKEEP_APT_INSTALLED_CMD="${UPKEEP_APT_INSTALLED_CMD:-}"

apt_installed_lookup() {  # -> sorted TSV, one row per name
  { if [[ -n "$UPKEEP_APT_INSTALLED_CMD" ]]; then $UPKEEP_APT_INSTALLED_CMD
    else dpkg-query -W -f '${Package}\t${Version}\n' | sort; fi; } | collapse_versions
}

# stdin: "bash/noble 5.2-2ubuntu2 amd64 [upgradable from: 5.2-1ubuntu1]"
apt_parse_pending() {  # $1 = installed TSV -> items JSON
  awk -F'[/ ]' '/upgradable from:/ { print $1 "\t" $3 }' \
  | sort -u | collapse_versions \
  | join -t "$(printf '\t')" -a1 -e '?' -o '1.1,2.2,1.2' - "$1" \
  | jq -Rn '[inputs | split("\t") | {name:.[0], from:.[1], to:.[2]}]'
}

apt_check() {    # -> items JSON; explicit non-zero on failure
  local out lookup prc=0
  out="$($UPKEEP_APT_PENDING_CMD)" || return 1
  lookup="$(mktemp)"; apt_installed_lookup > "$lookup" || { rm -f "$lookup"; return 1; }
  apt_parse_pending "$lookup" <<<"$out" || prc=$?
  rm -f "$lookup"
  return $prc
}

apt_snapshot() { apt_installed_lookup; }
```

Rules that reviews will hold you to:

- **Return status explicitly.** `if x="$(fn)"` disables errexit inside the whole callee, so a
  backend that relies on `set -e` to propagate failure silently reports success. Every shipped
  backend returns its status by hand for exactly this reason.
- **Zero pending is success**, not failure. It is the common case; a backend that exits non-zero
  when nothing is pending turns an up-to-date box into a permanent `stale` state.
- **Capture the parser's status before cleanup.** An `rm -f` after the parse returns 0 and will
  mask the parser's failure as an empty, entirely plausible "nothing pending" result.
- **Collapse, always.** Even where duplicates cannot happen today, `tsv_diff_updates` rejects
  duplicate names, so the contract is one row per name.
- **Do not add locale handling.** `lib/common.sh` pins `LC_ALL=C.UTF-8` for everything.
- **Guard the not-installed case.** A pending package with no installed row must come out as
  `from: "?"`, never as an empty string. GNU `join -a1 -e '?' -o ...` is what does that; jq's
  `//` does not catch empty strings.

### 2. Add a verb to `libexec/upkeep-apply`

The apply helper runs as root, so a new verb is a security change. Follow the existing shape:
match the verb, validate every argument against a strict pattern before building the command,
reject everything else with exit 2, and never pass a caller-supplied string through unvalidated.

```bash
  apt-upgrade)
    assume=()
    for a in "$@"; do
      case "$a" in
        -y) assume=(-y) ;;
        *) echo "invalid arg: $a" >&2; exit 2 ;;
      esac
    done
    run apt-get "${assume[@]}" upgrade
    ;;
```

Holds become whatever your package manager's exclude mechanism is. Whatever it is, validate every
name against `NAME_RE` before it reaches a command line, the way the `dnf-upgrade` verb does with
`--exclude=`, and reject the whole invocation rather than dropping a bad argument quietly.

Then wire the verb into `cmd_update` in `bin/upkeep` next to the existing `apply_with_retry`
calls, and add the backend to `cmd_check` and `assemble_state`.

### 3. Record fixtures

Fixtures are byte-faithful captures of real tool output. They carry **no comment lines**;
provenance lives in [`tests/fixtures/MANIFEST.md`](../tests/fixtures/MANIFEST.md), which says for
every file whether it was captured or hand-written, when, and what each deliberate oddity guards.

Capture through the same code path production uses. The original dnf capture used `sort -u`
while production used plain `sort`, which made the installonly cross-product bug structurally
invisible to the entire suite.

Guard rows are mandatory, not decorative. Every shipped fixture contains at least:

- a pending package that is **absent** from the installed lookup, so deleting the join guard
  fails a test instead of silently passing,
- a duplicate name at a **divergent** version, so the collapse step is actually exercised
  (identical versions collapse for free at `sort -u` and prove nothing),
- whatever section headers or indented rows the real tool emits, so the filters that drop them
  stay honest.

### 4. Write tests that bind

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/backends/apt.sh"

out="$(apt_parse_pending "$FIXTURES/dpkg-installed.tsv" < "$FIXTURES/apt-upgradable.txt")"
assert_eq "$(jq 'length' <<<"$out")" "3" "fixture parses to 3 items"
assert_eq "$(jq -r '.[] | select(.name == "newthing") | .from' <<<"$out")" "?" \
          "a pending package with no installed row falls back to ?"
finish
```

`sandbox` must be the first call: it creates one throwaway temp directory, points `HOME`, the
config directory and the state directory at separate paths inside it, neutralizes every seam,
and installs the EXIT trap that makes the file's exit status meaningful. Do not install your own
EXIT trap over it.

Then **prove the test binds**: break the code the test claims to cover, watch the test fail, put
it back. A test that passes against the defect it is named after is worse than no test.
`tests/run_tests.sh` runs everything.

### 5. Worked sketches

These are starting points, not shipped code. The shape is the point.

| Distro | Pending | Installed snapshot | Apply verb |
| --- | --- | --- | --- |
| Debian/Ubuntu | `apt-get -s upgrade` (simulate) or `apt list --upgradable` | `dpkg-query -W -f='${Package}\t${Version}\n'` | `apt-get -y upgrade` |
| Arch | `checkupdates` (pacman-contrib) | `pacman -Q` | `pacman -Syu --noconfirm` |
| openSUSE | `zypper --quiet list-updates` | `rpm -qa --queryformat '%{NAME}\t%{EVR}\n'` | `zypper -n update` |

Notes worth knowing before you start: apt output is heavily locale-dependent, so the `LC_ALL`
pin matters more there than it does on dnf; `checkupdates` already prints `name old -> new` and
needs no installed lookup at all, so its parser is the smallest of the three; and openSUSE can
reuse `dnf.sh`'s snapshot verbatim, since it is the same rpm database.

Anything that changes the state schema, the exit-code contract or the privileged helpers is a
discussion first, a pull request second. Everything else is just a new file.

## Environment seams

Every impure call in the CLI goes through a variable, which is how the suite tests privileged and
destructive paths without ever running them.

| Variable | Default | Used for |
| --- | --- | --- |
| `UPKEEP_CONFIG_DIR`, `UPKEEP_STATE_DIR` | `~/.config/upkeep`, `~/.local/state/upkeep` | Redirect config and state |
| `UPKEEP_PKEXEC` | `pkexec` | Set empty to call a helper directly (tests) |
| `UPKEEP_REFRESH_HELPER`, `UPKEEP_APPLY_HELPER` | `/usr/local/libexec/upkeep-{refresh,apply}` | Point at stub helpers |
| `UPKEEP_DNF_CMD`, `UPKEEP_DNF_INSTALLED_CMD` | `dnf5`, (rpm query) | Replace the dnf commands |
| `UPKEEP_FLATPAK_REMOTE_CMD`, `UPKEEP_FLATPAK_LIST_CMD` | `flatpak remote-ls/list --system --app ...` | Replace the flatpak commands |
| `UPKEEP_NOTIFY`, `UPKEEP_TERMINAL` | `notify-send`, `konsole` | Notifications and the terminal surface |
| `UPKEEP_RISKY_RE`, `UPKEEP_BOOT_ID` | (empty) | Override the session-critical pattern and the boot session |
| `UPKEEP_SKIP_REFRESH`, `UPKEEP_RETRY_DELAY` | (unset), `10` | Deterministic checks and fast retry tests |
| `UPKEEP_ASSUME_TTY`, `UPKEEP_LIVE_OUTPUT` | (unset) | Drive the interactive prompt path from a script |
| `UPKEEP_RULES_DST` | `/etc/polkit-1/rules.d/49-upkeep.rules` | Passwordless rule destination. Pinned: an absolute `*.rules` path, either in `/etc/polkit-1/rules.d/` or outside `/etc` altogether |
| `UPKEEP_POLICY_FILE` | `/usr/share/polkit-1/actions/org.erez.upkeep.policy` | Where `upkeep doctor` looks for the installed polkit actions |
| `UPKEEP_APPLY_ECHO`, `UPKEEP_REFRESH_ECHO` | (unset) | Root helpers print the final command instead of running it |
| `UPKEEP_INSTALL_ECHO`, `UPKEEP_AUTOSTART_SRC` | (unset), the system autostart entry | `install.sh` prints its privileged commands instead of running them; `=fail` also makes them report failure. The seam covers privileged commands ONLY - the unprivileged symlinks (CLI, man page) are still created for real, so run it under a scratch `HOME` if you want a fully inert dry run |

The `*_ECHO` seams exist for tests only. The two that live in root-owned code,
`UPKEEP_APPLY_ECHO` and `UPKEEP_REFRESH_ECHO`, are unreachable in a real privileged run: pkexec
sanitizes the environment, so a variable set by the caller never arrives inside the root helper.
`UPKEEP_INSTALL_ECHO` runs on the user's side of the boundary, and all it can do is stop
`install.sh` from running its privileged commands.

## Known v1 decisions

- **The dnf check parser is text, not JSON.** dnf5 5.4 supports `check-update --json`, which
  would remove the whole text-parsing bug class (obsoletes sections, indentation, column drift,
  locale) by construction. v1 keeps the hardened, fixture-pinned text parser rather than churn
  the fixture and test layer mid-build. Migrating that one verb is the designated v2 upgrade.
- **Flatpak is system scope only.** Both queries and the helper's validation use `--system`, so
  check and apply always agree. Per-user apps need no privileges and are a possible future
  unprivileged path.
- **`flatpak update` also updates runtimes**, but the pending list and the summary track apps, so
  a run can change more than it itemizes.
- **The install is a symlink into the checkout.** Proper packaging is the answer for shipping
  this to other people, and it is v2 work.
