# Architecture

Kempt is two layers with a deliberately boring boundary between them.

```
  Plasma panel widget (QML)          thin: no package-manager knowledge at all
   |-- contents/ui/logic.js          every derivation rule, in engine-agnostic JS
   |-- contents/ui/Executor.qml      the only place the widget starts a process
   |  kempt check / run / hold / config  (it shells out; there is no other path)
   v
  kempt CLI (bash)                  all the logic
   |-- lib/common.sh                 config, holds, snapshots, diff, state, locking
   |-- backends/dnf.sh               pure parsers + check/snapshot
   |-- backends/flatpak.sh           same shape
   |  (privilege boundary: one pkexec per polkit action)
   v
  libexec/kempt-refresh  (root)     metadata only, no dialog
  libexec/kempt-apply    (root)     the upgrade verbs, one auth per run
```

The rule that shapes everything: **the badge count must come from the same command path that
performs the update**. A front end that disagrees with the CLI is the defining complaint about
every tool in this space, so `kempt check` reads the root metadata cache the update itself will
use, applies the same holds, and runs the same backends.

## Repo layout

| Path | Role |
| --- | --- |
| `bin/kempt` | Command dispatch and every `cmd_*` implementation |
| `lib/common.sh` | Shared library: paths, config, holds, snapshot diff, state assembly, locks, summary rendering |
| `backends/dnf.sh`, `backends/flatpak.sh` | One file per package manager |
| `libexec/kempt-refresh`, `libexec/kempt-apply` | The only code that runs as root |
| `polkit/` | The two action definitions plus the passwordless rule template |
| `plasmoid/` | The Plasma 6 panel widget: a client of the CLI with no package-manager knowledge |
| `plasmoid/contents/ui/logic.js` | The widget's whole derivation layer, in engine-agnostic JS so node can test it |
| `install.sh` | Symlink install, staged install (`--destdir`), uninstall |
| `tests/` | Fixture-driven bash test suite, no framework dependency |
| `tests/qml/` | PySide6 probes that execute the real QML against a stubbed CLI (see below) |

## The backend contract

A backend is one file that answers two questions, both on stdout, both with an explicit exit
status:

| Function | Input | Output |
| --- | --- | --- |
| `<backend>_check` | none (it queries the world through overridable command variables) | items JSON: `[{"name": "...", "from": "...", "to": "..."}]`. Empty is `[]` with exit 0. Non-zero means the check failed. |
| `<backend>_snapshot` | none | TSV, `name<TAB>version`, sorted by name, **exactly one row per name** |

Anything a backend parses lives in a pure function that takes stdin plus an installed-lookup
file, so it can be tested against a recorded fixture with no package manager present:
`dnf_parse_check_update`, `flatpak_parse_remote_ls`. Two required functions plus that parser is
the whole per-backend contract: three functions in one file.

One more function exists and is deliberately **not** per-backend: `dnf_reboot_needed`, in
`backends/dnf.sh`. `cmd_update` calls it unconditionally at the end of every run, whatever
backends took part, because "does this machine need a reboot" is a property of the machine and
not of one package manager. On a box without dnf5 it degrades rather than failing the run:
`dnf5 -C needs-restarting` errors, the function warns on stderr and answers `false`. That is the
one part of this contract that is still honestly dnf-shaped; a per-backend reboot verdict is v2
work, and a new backend does not implement one today.

Two things the spec lists as backend responsibilities are deliberately **not** per-backend in the
build:

- **update** is `libexec/kempt-apply` plus the wiring in `cmd_update`, because applying updates
  is the privileged half and must stay in one audited place.
- **report** is `tsv_diff_updates` in `lib/common.sh`, shared by every backend.

### Why reports come from snapshots, not from history output

`kempt update` takes a `<backend>_snapshot` before the run and another after it, and diffs them.
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

- Every producer pipes through `sort_name_version | collapse_versions`, giving one row per name
  with the versions **comma-joined in ascending version order**
  (`6.15.3-200.fc44,6.15.4-200.fc44`).
- `tsv_diff_updates` **refuses** duplicate-name input with exit 65 instead of emitting fiction.

**The last element of a comma-joined set is the newest, and consumers rely on it.**
`render_summary`'s `newest()` and the widget's `newestOf()` both take the last element, so the
ordering is a contract, not a coincidence. It is why the sort is version-aware rather than
lexical: `5.3.10-1` sorts before `5.3.9-4` byte by byte, which would leave the *older* build
last. `sort_name_version` in `lib/common.sh` is the single definition; its first key stays plain
byte order because `join` and `tsv_diff_updates` require the name field in exactly that order.

Its honest limit is rpm epochs: `sort -V` reads a leading `1:` as an ordinary number, so a set
that **mixes** epochs can be ordered wrongly (`1:2.0-1` sorts before `9.0-1` although the epoch
makes it newer). Sets that share an epoch are exact, and multilib twins and installonly kernel
sets always do, which is every set this code actually produces today.

The same collapse runs on the pending side, where the problem is multilib rather than installonly:
`bash.x86_64` and `bash.i686` routinely sit at different releases, and they are one package as far
as a user is concerned. Human-facing output shows the newest version of a comma-joined set; the
JSON keeps the whole set.

## Where Kempt writes

Everything lives under `~/.config/kempt` and `~/.local/state/kempt` (both redirectable, see
[Environment seams](#environment-seams)). Nothing is written anywhere else by an unprivileged
command, and nothing is written outside these two trees by a privileged one either.

| Path | What it is | Who prunes it |
| --- | --- | --- |
| `~/.config/kempt/config` | `key=value` settings, one per line, the only place a setting is stored | Nothing; it is yours |
| `~/.config/kempt/holds` | One `backend:name` per line | Nothing; it is yours |
| `~/.local/state/kempt/state.json` | What is pending right now, schema v1, a public interface | Rewritten by every check |
| `~/.local/state/kempt/history/<stamp>.json` | One entry per run: versions, counts, held items, duration, reboot verdict, and the reason when it failed | Newest 50 kept, on every `kempt_init_dirs` |
| `~/.local/state/kempt/logs/<stamp>.log` | Raw package-manager output for one run. Evidence, never rewritten or summarised | Dropped after 60 days |
| `~/.local/state/kempt/events.log` | The event log: one line per thing Kempt did, `<ISO timestamp> <via> <text>`, mode 0600 | Past 2500 lines, rewritten to the last 2000 |
| `~/.local/state/kempt/snapshots/*.tsv` | Before and after package sets, which is what run summaries are diffed from | Overwritten per run; the offline baseline is swept when harvested |
| `~/.local/state/kempt/offline_staged.json` | The marker for a transaction waiting on a reboot | Consumed by the harvest |
| `~/.local/state/kempt/{lock,check.lock,last_refresh}` | flock targets and the refresh timestamp | Never; they are empty files |

The event log is the newest of these and the one that answers a different kind of question. The
other files describe **state** and **runs**; nothing recorded that a setting was changed, a
package was held, or a check happened at all, so "did the change I just made land?" had no answer
anywhere on the box. `log_event` in `lib/common.sh` writes it, `kempt log` reads it, and it is
best-effort by contract: it returns 0 whatever happens, never blocks, and a state directory that
cannot be written simply gets no events rather than an error on every command.

The `via` column comes from `KEMPT_VIA`, which the widget sets to `widget` on every command it
runs (see [The widget's one command path](#the-widgets-one-command-path)). Anything else is
`cli`. It is read in exactly one place - `log_event` - and changes nothing else about how the
CLI behaves.

## State JSON schema v1

`~/.local/state/kempt/state.json` is a **public interface**. The widget parses it blind, and so
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
| `backends.<name>.items[]` | array | `name`, `from` (installed version, `?` when not installed), `to` (pending version), `held` (boolean). A package that keeps several versions (installonly sets, multilib twins) carries them comma-joined in **ascending** order, so the last element is the newest. Readers that show one version take the last. |
| `actionable` | integer | The badge number: non-held pending items across all backends. |
| `held_total` | integer | Held pending items across all backends. |
| `risky_pending` | array of strings | dnf package names matching `risky_regex`, excluding held ones and excluding build or documentation tails (`-devel`, `-doc` and friends). Additive key: readers must tolerate its absence in files written by older builds. |

Two rules for anything that reads this file:

1. **Empty stdout from `kempt check` with exit 0 means "no data, keep the last known state"**,
   never "zero updates". It happens when another check holds the lock and there is no valid
   previous state to serve.
2. `status: "stale"` is not an error state to alarm the user with. The counts are still the best
   known truth; surface the staleness in a tooltip, not a warning icon.

A new backend adds a key under `backends` and stays schema 1: existing readers ignore what they
do not know, and the totals keep working.

## The privileged boundary

Two root helpers, one per polkit action, because polkit's `auth_admin_keep` caches per action id
and a cheap verb must never share an action with a dangerous one:

- `kempt-refresh` (`io.github.erez_c137.kempt.refresh`, no dialog): `check` and `refresh`, metadata only.
- `kempt-apply` (`io.github.erez_c137.kempt.apply`, one auth per run): `dnf-upgrade`,
  `dnf-offline-stage`, `flatpak-update`.

Both validate every argument before running anything, accept no free-form arguments at all, and
pin `PATH` and `LC_ALL`. The full model, including what passwordless mode grants, is in
[security.md](security.md).

## The widget's one command path

Everything the widget runs - every check, every hold, every `config get`, the log tail, the
watcher's `stat` - goes through `Executor.qml`. It wraps the executable data engine
(`Plasma5Support.DataSource`, a deprecated shim KDE plans to drop) behind a queue that is
serialized, always asynchronous, and hard-timed-out per call. That isolation is the point: the
eventual swap when KDE removes the shim is a one-file change, and nothing anywhere else in the
widget is allowed to start a process.

Every command it builds is prefixed `PATH="$HOME/.local/bin:$PATH" KEMPT_VIA=widget kempt`. The
PATH assignment is there because plasmashell does not reliably inherit a login shell's one and
`install.sh` puts the CLI in `~/.local/bin`; `KEMPT_VIA` is read by `log_event` and by nothing
else, and is what makes `kempt log` able to say a change came from the panel.

**The settings page's writes are durable, and that is not cosmetic.** Plasma runs its OK button
as `applyAction.trigger(); configDialog.close()`, and the close destroys the page, its Executor
and the DataSource behind it - which deletes the KProcess, whose destructor SIGKILLs the `sh`
still running the command. A 10 ms `kempt config set` against a teardown two event-loop hops away
is a race, and it was lost in practice. So every write that page dispatches goes through
`page.durable()`, which appends `& wait $!`: the work forks into a background job the SIGKILL
never reaches, while `wait $!` still returns the job's real exit status so the page's error
handling is unchanged. It is applied to writes only, and never to `main.qml`'s executor, whose
timeout has to be able to kill a wedged `kempt check` outright.

**ONE component, three instances.** The file is one; the queues are deliberately not.

| Instance | Lives in | Carries | Why it is separate |
| --- | --- | --- | --- |
| `executor` | `main.qml` | checks, holds, `run`, `summary`, config reads, the watcher poll | The actions. A `kempt check` can take two minutes. |
| `tailExecutor` | `main.qml` | `tail -n 25` of the run log, every 2s while the popup shows it | The queue is strictly FIFO, so a 2-second tail sharing it with a 120-second check would put ~60 tails ahead of every button press and the Refresh button would look dead for two minutes. |
| `cfgExecutor` | `configGeneral.qml` | the settings page's reads and writes | The config dialog is built by the shell in its own object tree and cannot reach `main.qml` at all. Even if it could, a settings dialog that takes two minutes to populate because a check is running is a broken dialog. |

The rule that follows: a new caller that is *fast and periodic* must not share a queue with one
that is *slow and occasional*. Adding a fourth instance is cheaper than making the queue clever.

### Where the widget lives, and the two lines that decide it

Three facts in `plasmoid/metadata.json` and `main.qml` put Kempt in the system tray, and each one
fails silently on its own:

- `"X-Plasma-NotificationAreaCategory": "SystemServices"`, **top level**, not inside `KPlugin`.
  This is the key the tray actually reads: verified on Plasma 6.7.4, the system tray applet
  (`/usr/lib64/qt6/plugins/plasma/applets/org.kde.plasma.systemtray.so`) contains this string and
  the category names beside it, builds its Entries list by listing every `Plasma/Applet` package
  and keeping the ones that declare a category. Inside `KPlugin` the key parses fine, means
  nothing, and the widget simply never appears in the tray.
- `"X-Plasma-NotificationArea": "true"`, also top level. The older boolean. That same binary does
  **not** reference it any more, so on 6.7 the category alone is what counts - but every shipped
  tray applet still carries both (`/usr/share/plasma/plasmoids/org.kde.plasma.vault`,
  `.../org.kde.kdeconnect`), so Kempt does too rather than betting on one Plasma version.
- `Plasmoid.status = ActiveStatus`, set from `main.qml`. The tray reads nothing else to decide
  whether an entry on "Auto" is shown or tucked behind the expander arrow, and an applet that
  never sets a status is *below* passive. Without it the widget installs into the tray, shows as
  enabled, and appears to do nothing at all. It is assigned in `Component.onCompleted` rather than
  declared as a binding on purpose: `Plasmoid` is an attached object backed by a real applet, and
  a declarative assignment makes creating it a precondition of creating `main.qml`, which no QML
  probe can satisfy. The value never changes, so one assignment is equivalent.

`KPlugin.EnabledByDefault: true` is what makes it appear without being asked for - the tray reads
it through `KPluginMetaData::isEnabledByDefault()` when it meets a plugin it has not seen before.

Inside the tray, the containment hands each entry a square cell at its own icon size, so the
compact representation must not ask for more: its `Layout.minimumWidth/Height` are the shell's
own `DefaultCompactRepresentation.qml` rule (the panel's thickness in the direction it is not
thick), and `Logic.resolveIconSize` falls back to automatic whenever a chosen size does not fit
the cell. Both are what keeps a Kempt entry from shoving the rest of somebody's tray sideways.

### Why the widget is testable at all

A plasmoid cannot be executed in a bash suite, so the widget is split so that almost none of it
needs to be:

- `logic.js` holds every derivation - badge number, icon state, tooltip, popup rows, the watcher
  comparison, the icon-size snap - in engine-agnostic JavaScript with a CommonJS guard at the
  bottom. `tests/test_widget_logic.sh` loads that same file with node and pins every rule.
- The QML that remains is bindings. `tests/test_widget_logic.sh` compiles every `.qml` against
  the system Qt 6 (via PySide6's `QQmlComponent`), and `tests/test_widget_qml.sh` runs four
  probes that instantiate the real files against a stubbed `kempt` on a real `PATH` - the settings
  page's apply path, the popup's actions, the state machine, the executor.
- Both halves skip LOUDLY rather than failing when node or PySide6 is absent; neither is a
  dependency of Kempt itself.

The whole suite is 17 files and 1310 assertions, 693 of them in the two widget files, and it runs
green with no package manager, no polkit and no desktop present.

The probes are run strictly one at a time under `tests/qml/safe_probe.py`, which puts each in its
own process group and SIGKILLs the group on timeout, with a second watchdog armed inside the
probe process itself. That is not ceremony: a PySide6 process wedged in Qt teardown never reaches
a SIGTERM handler, and an earlier version of this kit with no working timeout reached ~2,200
resident Qt processes in one afternoon and OOM-killed the box. `tests/test_widget_qml.sh` asserts
the process count afterwards.

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
KEMPT_APT_PENDING_CMD="${KEMPT_APT_PENDING_CMD:-apt list --upgradable}"
KEMPT_APT_INSTALLED_CMD="${KEMPT_APT_INSTALLED_CMD:-}"

apt_installed_lookup() {  # -> sorted TSV, one row per name, versions ascending
  # Both branches share the sort tail on purpose: a seam that bypasses it lets a stub feed
  # collapse_versions rows in any order, and the suite can never see what the real path produces.
  { if [[ -n "$KEMPT_APT_INSTALLED_CMD" ]]; then $KEMPT_APT_INSTALLED_CMD
    else dpkg-query -W -f '${Package}\t${Version}\n'; fi; } | sort_name_version | collapse_versions
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
  out="$($KEMPT_APT_PENDING_CMD)" || return 1
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
- **Collapse, always, behind `sort_name_version`.** Even where duplicates cannot happen today,
  `tsv_diff_updates` rejects duplicate names, so the contract is one row per name. Use the shared
  sort rather than a plain one, and put it where **every** branch of the function flows through
  it: a comma-joined set has to come out ascending, because every consumer reads its last element
  as the newest version.
- **Do not add locale handling.** `lib/common.sh` pins `LC_ALL=C.UTF-8` for everything.
- **Guard the not-installed case.** A pending package with no installed row must come out as
  `from: "?"`, never as an empty string. GNU `join -a1 -e '?' -o ...` is what does that; jq's
  `//` does not catch empty strings.

### 2. Add a verb to `libexec/kempt-apply`

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

### 2b. Wire it in: every place that names a backend

There is no registry and no discovery. Backends are named literally, in more places than the
sketch above suggests, and a missed one fails quietly rather than loudly. The complete list is
**twelve places, one of them optional**, so nobody has to find it by grep:

| Where | What it names today | What a third backend needs |
| --- | --- | --- |
| `bin/kempt`, the `source` lines at the top | `backends/dnf.sh`, `backends/flatpak.sh` | One more `source` line. Nothing loads a backend file by discovery. |
| `cmd_check` | `dnf_check` / `flatpak_check`, `mark_held`, `state_prev_items`, the `include_flatpak` gate | A call pair, its own enable gate, and its own previous-items fallback for the stale path. |
| `assemble_state` (`lib/common.sh`) | Items arrive **positionally** (`$1` dnf, `$2` flatpak) and the jq body writes `backends: {dnf, flatpak}` | A **signature change**: adding a backend changes the function's parameter list and therefore every caller. This is the one edit here that is not additive. |
| `cmd_update` | Before and after snapshots, the apply verb, per-backend status, held lists, and the history entry's `backends` object | The same set again, plus the new apply verb from step 2. |
| `dnf_reboot_needed` in `cmd_update` | Called unconditionally, whatever backends ran | Nothing, today. It answers for the machine, and degrades to `false` where dnf5 is absent. |
| `render_summary` (`lib/common.sh`) | `.backends.dnf` and `.backends.flatpak` by name, with the labels "System (dnf)" and "Apps (flatpak)" | A new line, or a rewrite over `.backends | to_entries` that would make the renderer generic for good. |
| `harvest_offline` | Writes a history entry with both backend keys hardcoded | The new key, or that entry is missing a backend the readers expect. |
| `cmd_hold` / `cmd_unhold` | `[[ "$b" == dnf \|\| "$b" == flatpak ]]`, and the message that names both | The whitelist. Without it, `kempt hold apt:foo` exits 2 while the backend works fine. |
| `cmd_doctor` | The per-tool check (flatpak's command, from its seam) and the checkout file list | A tool check, so a missing package manager is reported rather than showing up as a permanently stale backend. |
| `kempt_default` (`lib/common.sh`) | `include_flatpak` (and `auto_accept`) default to `true` | A default for `include_<name>`. Miss it and `config_get include_<name>` answers the **empty string**, `is_true` reads that as false, and the backend is silently OFF on every box whose config file has never named it. Nothing warns: the check simply reports the backend disabled, forever, and the enable gate above looks correctly wired. |
| `docs/architecture.md`, `docs/configuration.md` | The state schema example and the `include_flatpak` key | A schema entry (additive, still schema 1) and an enable key with the same semantics. |
| **Optional:** `cmd_update`'s option loop and `usage` (`bin/kempt`) | `--no-flatpak`, and the line in `usage` that documents it | A `--no-<name>` override and its usage line. Skip it and the backend can still be switched off, but only in config: `kempt update --no-<name>` exits 2 as an unknown option. This is the one entry here a working backend can do without. |

What is already generic and needs nothing: the totals in `assemble_state`'s `wrap`,
`run_counts_phrase`, and the held-items line in `render_summary`. All three iterate
`.backends[]` and pick up a new backend for free, which is why the ones that do not are worth
listing.

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
discussion first, a pull request second. A backend touches all three, so it starts there too: a
new apply verb in root-owned code, a new key under `backends`, and a changed `assemble_state`
signature. Fixtures, parsers and tests are just files.

## Environment seams

Every impure call in the CLI goes through a variable, which is how the suite tests privileged and
destructive paths without ever running them.

| Variable | Default | Used for |
| --- | --- | --- |
| `KEMPT_CONFIG_DIR`, `KEMPT_STATE_DIR` | `~/.config/kempt`, `~/.local/state/kempt` | Redirect config and state |
| `KEMPT_PKEXEC` | `pkexec` | Set empty to call a helper directly (tests) |
| `KEMPT_REFRESH_HELPER`, `KEMPT_APPLY_HELPER` | `/usr/local/libexec/kempt-{refresh,apply}` | Point at stub helpers |
| `KEMPT_REFRESH_HELPER_PATH`, `KEMPT_APPLY_HELPER_PATH` | `/usr/local/libexec/kempt-{refresh,apply}` | The paths polkit's `exec.path` pins. `kempt doctor` checks root:root 0755 **only** when the helper seam equals this one, so a test reaches the ownership branches by setting both to the same file. Nothing execs these; they are compared, never run |
| `KEMPT_DNF_CMD`, `KEMPT_DNF_INSTALLED_CMD` | `dnf5`, (rpm query) | Replace the dnf commands |
| `KEMPT_FLATPAK_REMOTE_CMD`, `KEMPT_FLATPAK_LIST_CMD` | `flatpak remote-ls/list --system --app ...` | Replace the flatpak commands |
| `KEMPT_NOTIFY`, `KEMPT_TERMINAL` | `notify-send`, `konsole` | Notifications and the terminal surface |
| `KEMPT_RISKY_RE`, `KEMPT_BOOT_ID` | (empty) | Override the session-critical pattern and the boot session |
| `KEMPT_SKIP_REFRESH`, `KEMPT_RETRY_DELAY` | (unset), `10` | Deterministic checks and fast retry tests |
| `KEMPT_VIA` | (unset) | The event log's `via` column: `widget` when set to exactly that, `cli` otherwise. The widget sets it on every command it runs. Read by `log_event` and by nothing else, so it can never change what a command does |
| `KEMPT_ASSUME_TTY`, `KEMPT_LIVE_OUTPUT` | (unset) | Drive the interactive prompt path from a script |
| `KEMPT_RULES_DST` | `/etc/polkit-1/rules.d/49-kempt.rules` | Passwordless rule destination. Pinned: an absolute `*.rules` path, either in `/etc/polkit-1/rules.d/` (the admin one of polkit's four rules directories) or outside every system prefix - `/etc`, `/run`, `/usr`, `/var`, `/boot`, `/opt` - which is what the test seam uses |
| `KEMPT_POLICY_FILE` | `/usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy` | Where `kempt doctor` looks for the installed polkit actions |
| `KEMPT_APPLY_ECHO`, `KEMPT_REFRESH_ECHO` | (unset) | Root helpers print the final command instead of running it |
| `KEMPT_KPACKAGETOOL` | `kpackagetool6` | The tool `install.sh` installs and removes the panel widget with. Point it at a stub to exercise the widget arm without touching a live plasmashell - it goes through the same `run` seam as the privileged commands, so `KEMPT_INSTALL_ECHO` prints it rather than running it |
| `KEMPT_INSTALL_ECHO`, `KEMPT_AUTOSTART_SRC` | (unset), the system autostart entry | `install.sh` prints its privileged commands instead of running them; `=fail` also makes them report failure. The seam covers privileged commands ONLY - the unprivileged symlinks (CLI, man page) are still created for real, so run it under a scratch `HOME` if you want a fully inert dry run |

The `*_ECHO` seams exist for tests only. The two that live in root-owned code,
`KEMPT_APPLY_ECHO` and `KEMPT_REFRESH_ECHO`, are unreachable in a real privileged run: pkexec
sanitizes the environment, so a variable set by the caller never arrives inside the root helper.
`KEMPT_INSTALL_ECHO` runs on the user's side of the boundary, and all it can do is stop
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
