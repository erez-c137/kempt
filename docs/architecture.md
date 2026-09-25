# Architecture

This is the map for changing Kempt's code: the parts, the rules that must hold, the state file
format, the test seams, and how to add a backend.

```
  Plasma panel widget (QML)          thin: no package-manager knowledge at all
   |-- contents/ui/logic.js          every derivation rule, in engine-agnostic JS
   |-- contents/ui/Executor.qml      the only place the widget starts a process
   |  kempt check / run / hold / config  (it shells out; there is no other path)
   v
  kempt CLI (bash)                  all the logic
   |-- lib/common.sh                 config, holds, snapshots, diff, state, locking
   |-- backends/dnf.sh               pure parsers + check/snapshot
   |-- backends/flatpak.sh           same shape, and it applies its own updates, as you
   |  (privilege boundary: one pkexec per polkit action, dnf only)
   v
  libexec/kempt-refresh  (root)     metadata only, no dialog
  libexec/kempt-apply    (root)     the dnf upgrade verbs, one auth per run
```

One rule shapes the rest: **the badge count comes from the same command path that performs the
update**. `kempt check` reads the root metadata cache the update will use, with the same holds and
backends.

## Why bash

- **The job is running other CLIs** (dnf5, flatpak, pkexec, notify-send) and parsing what they
  print. In bash, the command Kempt runs is the command you would type.
- **The root code can be read in one sitting.** The two root helpers are short scripts, so a
  sysadmin can read every line that runs as root before granting it.
- **No runtime dependencies and no build step.** bash and jq are on every Fedora install.

The costs are paid in structure. Every impure command goes through an
[environment seam](#environment-seams), and shellcheck gates CI. The parsers are pure functions
tested against recorded fixtures. The widget speaks only to the CLI and the state file, so another
engine could replace the bash one.

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

A backend is one file with two functions. Both answer on stdout, with an explicit exit status:

| Function | Input | Output |
| --- | --- | --- |
| `<backend>_check` | Optionally, a path to write a sizes TSV to (`name<TAB>bytes`). `flatpak_check` takes one and `cmd_check` passes it; dnf publishes its sizes from a separate `dnf_sizes`. Everything else it queries through overridable command variables. A backend that produces no sizes publishes no `download_bytes`. | items JSON: `[{"name": "...", "from": "...", "to": "..."}]`. Empty is `[]` with exit 0. Non-zero means the check failed. |
| `<backend>_snapshot` | none | TSV, `name<TAB>version`, sorted by name, **one row per name** |

Parsing lives in a pure function that takes stdin plus an installed-lookup file
(`dnf_parse_check_update`, `flatpak_parse_remote_ls`), so a test can feed it a fixture. The two
functions plus that parser are the required contract.

Three jobs sit outside the backends:

- **Apply** for dnf is `libexec/kempt-apply` plus the wiring in `cmd_update`, so root code stays
  in one place. Flatpak needs no root, so its apply is `flatpak_apply` in its backend.
- **Reports** come from `tsv_diff_updates` in `lib/common.sh`, shared by every backend.
- **The restart check** is `dnf_reboot_needed` in `backends/dnf.sh`. `cmd_update` and `cmd_check`
  call it whatever backends ran. It runs `dnf5 -C --disablerepo='*' needs-restarting`, offline and
  with no repo metadata. It answers `true` only when the command also prints the package list.
  Anything else, including a box without dnf5, warns and answers `false`.

### Reports come from snapshots

`kempt update` takes a `<backend>_snapshot` before the run and another after it, and diffs them.
It parses neither `dnf5 history info` nor flatpak's transaction output. So the result is
locale-proof, and a new backend gets reports by implementing a snapshot.

The diff sorts every name into `updated` (in both, different version), `added` (after only) and
`removed` (before only). Versions are compared as strings. awk compares numeric-looking fields as
numbers, so `1.1` and `1.10` would otherwise compare equal and vanish from the report.

### One row per name

Fedora keeps several versions of *installonly* packages (`kernel-core`, `gpg-pubkey`), and
multilib twins (`bash.x86_64`, `bash.i686`) can sit at different releases. Repeated names make
`join` produce a cross product of phantom updates. So:

- Every producer pipes through `sort_name_version | collapse_versions`. That gives one row per
  name, with the versions comma-joined in ascending order (`6.15.3-200.fc44,6.15.4-200.fc44`).
- `tsv_diff_updates` refuses input with repeated names and returns 65.

**The last element of a set is the newest, and consumers rely on it** (`render_summary`'s
`newest()`, the widget's `newestOf()`). So the sort is version-aware: byte order puts `5.3.10-1`
before `5.3.9-4`. `sort_name_version` in `lib/common.sh` is the only definition. Its first key
stays in byte order, because `join` needs it. It can misorder a set that mixes rpm epochs, which
installonly and multilib sets never do.

## Where Kempt writes

Everything lives under `~/.config/kempt` and `~/.local/state/kempt`. Both can be redirected (see
[Environment seams](#environment-seams)). No Kempt command writes outside these two trees, as the
user or as root.

| Path | What it is | Who prunes it |
| --- | --- | --- |
| `~/.config/kempt/config` | `key=value` settings, one per line, the only place a setting is stored | Nothing; it is yours |
| `~/.config/kempt/holds` | One `backend:name` per line | Nothing; it is yours |
| `~/.local/state/kempt/state.json` | What is pending right now, schema v1, a public interface | Rewritten by every check |
| `~/.local/state/kempt/history/<stamp>.json` | One entry per run: versions, counts, held items, duration, restart verdict, and the reason when it failed | Newest 50 kept, on every `kempt_init_dirs` |
| `~/.local/state/kempt/logs/<stamp>.log` | Raw package-manager output for one run. An update applied on a restart is the exception: dnf5 installed it while Kempt was not running, so the file is Kempt's own record from the snapshot diff, and says so | Dropped after 60 days |
| `~/.local/state/kempt/events.log` | The event log: one line per thing Kempt did, `<ISO timestamp> <via> <text>`, mode 0600 | Past 2500 lines, rewritten to the last 2000 |
| `~/.local/state/kempt/snapshots/*.tsv` | Before and after package sets, which run summaries are diffed from | Overwritten per run; the offline baseline is swept when harvested |
| `~/.local/state/kempt/offline_staged.json` | Kempt's record of a staged transaction (see [the marker](#the-offline-transaction-end-to-end)), mode 0600 | Consumed by the harvest, or cleared when the transaction under it has gone |
| `~/.local/state/kempt/{lock,check.lock,writer.lock,stage.lock,last_refresh,last_refresh_skip}` | flock targets, the refresh timestamp and the once-a-day skip stamp | Never; they are empty files |
| `~/.local/state/kempt/run-start.*` | One token per `kempt run` launch; the window it starts claims it by deleting it | Swept by `kempt_init_dirs` after 60 minutes |
| `~/.local/state/kempt/.atomic.*`, and the same name under `snapshots/` | `atomic_write`'s temp file, created next to its destination so the `mv` into place stays atomic | Swept by `kempt_init_dirs` once older than 60 minutes, so a live writer's temp is never swept |

Four of those files are locks:

- `lock` serialises runs, and `check.lock` serialises checks.
- `stage.lock` is held by a stage from the moment it asks dnf5 for a transaction until its marker
  is written. A check that finds it held skips the [replaced-transaction test](#which-transaction-ran).
- `writer.lock` serialises `kempt config set`, `kempt hold` and `kempt unhold`. Each reads a whole
  config file, changes one line and writes it back, so two at once would lose a write. It lives in
  the state directory because the config directory is the user's.

Readers take no lock. `atomic_write` renames into place, so a reader sees the whole old file or
the whole new one.

`log_event` in `lib/common.sh` writes the event log and `kempt log` reads it. It always returns 0
and never blocks, so no command fails because of it. Its `via` column is `widget` when
`KEMPT_VIA=widget`, which the widget sets on every command, and `cli` otherwise.

## State JSON schema v1

`~/.local/state/kempt/state.json` is a **public interface**. The widget parses it, and so can
anything else. It is frozen: fields may be added, but a field that changes meaning or type needs a
new `schema` number.

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
      "download_bytes": 11978084,
      "items": [
        { "name": "curl", "from": "8.18.0-8.fc44", "to": "8.18.0-9.fc44", "held": false,
          "size_bytes": 245706 }
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
  "risky_pending": [],
  "reboot_needed": false,
  "offline_staged": { "staged_at": "2026-09-02T10:31:00+03:00", "count": 61, "armed": true }
}
```

Every key marked "additive" may be absent from a file written by an older build, and readers must
cope with that.

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
| `backends.<name>.items[]` | array | `name`, `from` (installed version, `?` when not installed), `to` (pending version), `held` (boolean). A package with several versions (installonly sets, multilib twins) carries them comma-joined in **ascending** order. Readers that show one version take the last. |
| `backends.<name>.items[].kind` | string, optional | Only `flatpak` writes it, and only as `"runtime"`. Absent means the backend's ordinary item: a Flatpak app or a dnf package. Additive. |
| `backends.<name>.items[].branch` | string, optional | The Flatpak branch, on every item with `kind: "runtime"`. **A runtime's identity is its `name` and `branch` together.** The same runtime can be installed on two branches that update independently, so two items can share a `name`. Anything that keys items by name (a lookup, a size join, a diff) must key on the pair where this is present. Additive. |
| `actionable` | integer | The badge number: non-held pending items across all backends. |
| `held_total` | integer | Held pending items across all backends. |
| `risky_pending` | array of strings | dnf package names matching `risky_regex`, excluding held ones and build or documentation packages (`-devel`, `-doc` and similar). Additive. |
| `backends.<name>.items[].size_bytes` | integer, optional | Bytes this item would download, summed over every architecture of that name. **Absent means unknown, never zero.** Additive. |
| `backends.<name>.download_bytes` | integer, optional | Bytes this backend would download. Written **only when every non-held item has a `size_bytes`**. Additive. |
| `download_bytes` | integer, optional | The sum of the per-backend keys, omitted if any **enabled** backend omitted its own. A disabled backend does not suppress it. Additive. |
| `reboot_needed` | boolean | Whether a restart is owed **now**, asked fresh on every check. `false` means **nothing to say**: the check also answers `false` when it could not tell. Render no "no restart needed" line from it. The `reboot_needed` in a history entry is a different fact: whether one was owed when that run finished. Additive. |
| `metadata_refreshed` | ISO 8601 with offset, optional | When the package metadata behind these counts was last **fetched** (`$LAST_REFRESH_FILE`). A check answers from the cache, so this can be much older than `last_check`. Absent when nothing has ever been fetched. The widget's footer shows `metadata N days old` only past 24 hours. Additive. |
| `offline_staged` | object, optional | Present **only** while Kempt staged a transaction **and** dnf5 reports it armed (`status = "ready"`). `staged_at` is when; `count` is how many updates (`null` in a marker from before the count was recorded); `armed` is always `true`, and absence means not armed. Also written by a run (`publish_staged_state()`), which touches this key only. A read that fails leaves the key as it was. Additive. |
| `offline_staged.holds_conflict` | array of strings | dnf packages that are in the staged transaction **and** held now: a restart installs them despite the hold. Sorted, unique, dnf only. Read it with `names_source`. Additive. |
| `offline_staged.names_source` | `"transaction"`, `"marker"` or `"none"` | What an **empty** `holds_conflict` means. `transaction`: dnf5's stored transaction was read live, and empty means no conflict. `marker`: that read failed and the marker's transaction-derived list was used, and empty still means no conflict. `none`: there was no transaction-derived list, and empty means **cannot tell**. Additive. |
| `image_based` | `true`, optional | Present **only** on an image-based Fedora (Silverblue, Kinoite, Bazzite, a bootc image), detected by `/run/ostree-booted`. `kempt update` aborts there in pre-flight with exit 5, so a reader can stop offering the button. Never `false`. Additive. |
| `release_upgrade` | object, optional | Present **only** while dnf5 has a Fedora release upgrade stored, detected by `system_releasever` differing from `target_releasever` in dnf5's state file. `from` and `to` are strings. `state` is always present and is one of: `downloaded` (status `download-complete`); `armed` (`ready` and the `/system-update` symlink, so the next restart installs it); `stranded` (`ready` with the symlink gone, so no restart runs it); `incomplete` (`download-incomplete`, `transaction-incomplete` or an unknown status). dnf5 keeps one stored transaction for both kinds, so staging would cancel the release upgrade: Kempt refuses to, and a reader should stop offering it. Absent, never `null`, when there is none. Additive. |

The download figure is **an estimate**, so show it with "~" and never as "up to". It excludes held
items. It omits new dependencies, because only a depsolve knows them and a depsolve can block on
the rpm lock. It ignores Flatpak static deltas and already-staged downloads, which over-count. It
reads the system cache, `/var/cache/libdnf5`, which holds the metadata the check used.

Two rules for anything that reads this file:

1. **Empty stdout from `kempt check` with exit 0 means "no data, keep the last known state"**,
   never "zero updates". It happens when another check holds the lock and there is no valid
   previous state to serve.
2. `status: "stale"` is not an alarm. The counts are still the best known. Show the staleness in a
   tooltip, not as a warning icon.

A new backend adds a key under `backends` and stays schema 1. Readers ignore keys they do not
know, and the totals keep working.

## The offline transaction, end to end

A staged update is the one flow whose state lives in files owned by two programs.

| File | Owner | Says |
| --- | --- | --- |
| `~/.local/state/kempt/offline_staged.json` | Kempt | A stage was made: when, how many updates, the boot session, the package set it was staged against, which packages went in and were left out, and the identity dnf5 gave the transaction |
| `/usr/lib/sysimage/libdnf5/offline/offline-transaction-state.toml` | dnf5 | Whether the transaction is still there, whether it is armed (`status = "ready"`), and which transaction it is (`rpmdb_cookie`, `cmd_line`) |
| `/usr/lib/sysimage/libdnf5/offline/transaction.json` | dnf5 | What that transaction will install, by NEVRA, resolver-added packages included |

No one file is enough. The marker cannot tell a pending stage from one removed with
`dnf5 offline clean`. The toml cannot tell Kempt's transaction from anyone else's. The stored
transaction knows nothing about why a package is missing from it. The only readers are
`offline_system_status()`, `offline_marker_read()`, `offline_txjson_names()` and
`offline_staged_state()` in `lib/common.sh`.

**Staging.** `kempt update --surface=offline` asks dnf for a fresh count, then makes two
privileged calls inside one authentication. `dnf-offline-stage` (`dnf5 upgrade --offline`)
downloads the transaction. `dnf-offline-arm`
(`env DNF_SYSTEM_UPGRADE_NO_REBOOT=1 dnf5 offline reboot -y`) arms it by creating
`/system-update`, the symlink systemd looks for at boot. An unarmed transaction stays at
`download-complete` and no restart installs it. Without `DNF_SYSTEM_UPGRADE_NO_REBOOT`, arming
reboots at once. If the arm fails, the stage is discarded with `dnf-offline-clean`, no marker is
written, and the run fails.

**Rebuilding.** dnf5 replaces the stored transaction as soon as a new stage gets far enough, so a
failed rebuild can lose the old one. `cmd_update` reads dnf5's status after a failed stage:

1. **Old transaction still `ready`.** Nothing is cleaned, the marker stays, and the run fails.
2. **Old transaction gone or unarmed, or the arm failed, and cleanup succeeded.** The marker and
   its snapshot copy are removed, and the failure says what was lost.
3. **Cleanup failed too.** The marker is kept, and the notification carries the command that
   fixes it.

**The marker's fields** are `version`, `staged_at`, `pre_snapshot`, `boot_id`, `staged`, `armed`,
`staged_names`, `staged_names_source`, `staged_excluded`, `rpmdb_cookie` and `cmd_line`.

- **Every field is additive.** Every reader must work with a marker from an older build.
- **Unknown is an absent key.** `staged_names: []` would claim the transaction installs nothing.
- **`staged_names_source`** is `transaction`, `check` or `none`. A list from a check may confirm a
  hold conflict but never deny one, because a check cannot see resolver-added packages.
- **`version`** is set when a marker is created and carried forward unchanged.
- **Later runs add three flags**, each also recording that the event was announced once.
  `armed: false` means a restart proved the transaction cannot install. `set_moved` means the
  package set changed under a stage still armed. `replaced` means dnf5 holds a different
  transaction.
- **Names pass `KEMPT_NAME_RE`** as they are written, and one bad name drops the whole list.
- **A marker that will not parse is skipped, never cleared.** `offline_marker_read` returns nothing
  for an empty, unparsable or over-1 MB file. Clearing needs a marker that parses over a
  transaction dnf5 says has gone. Writes are atomic and mode 0600 (`write_offline_marker`).

**Holds after a stage.** dnf5 cannot edit a stored transaction, so a hold applies from the next
one. `kempt hold dnf:<name>` exits 0 and warns on stderr when the armed stage contains the
package, naming the commands to rebuild or remove it. `kempt unhold` warns about the reverse. The
test is a set intersection of staged and held names, never a time comparison, published as
`offline_staged.holds_conflict`.

**Discarding.** `kempt unstage` runs `dnf-offline-clean`, then clears the marker once
`offline_system_status` says `absent`. On every path the marker goes after the transaction, never
before. A stored Fedora release upgrade makes it refuse.

**Applying.** Any restart applies it. Kempt never restarts the machine.

**Harvesting.** The next `kempt check` reconciles inside the check lock, before anything else
reads the system (`harvest_offline`):

| Marker | dnf5 status | `/system-update` | Boot | Package set | Outcome |
| --- | --- | --- | --- | --- | --- |
| yes, with an identity | present, and not the transaction the marker records | - | any | - | **Replaced.** Announced once and flagged `replaced` on the marker, never cleared here. The rows below still apply, and what then runs is never reported as this stage |
| yes | ready / any non-absent | - | same as staged | - | Still pending. Nothing happens |
| yes | absent | - | same as staged | - | The transaction was thrown away. Clear the marker, `offline marker cleared (stage gone)` |
| yes | absent | - | different | unchanged | The transaction was thrown away. Clear the marker |
| yes | ready | present | different | unchanged | Still pending: the restart has not run it yet |
| yes | ready | **gone** | different | unchanged | **Detour boot.** systemd removes the symlink once `system-update.target` is reached, so this boot walked past the transaction. Announce once, set `armed: false`, never clear |
| yes | present, not `ready` | - | different | unchanged | **Detour boot.** Same three rules |
| yes | absent | - | different | changed | **Harvested**: one history entry, diffed against the marker's snapshot copy, then attributed through dnf5's history ([below](#which-transaction-ran)): surface `offline (applied on reboot)`, or `restart (staged update did not run)` when the history shows it did not |
| yes | present (any status) | - | different | changed | **Not harvested.** Something else moved the package set. Recorded once as `harvest deferred`, and the marker stays |

A harvest needs two gates. The boot must have changed, because a live run also moves the package
set. And dnf5's transaction must be gone, because applying one removes the toml,
`transaction.json` and `/system-update`. While any remain, a moved package set means another tool
moved it.

**Detour boots.** After a new boot with the package set unchanged, a transaction that is present
but unarmed can never install. Announce it once (`armed: false` records that). Never clear the
marker, because `kempt doctor` needs it to say the stage can never install. Never apply this to a
same-boot `download-complete`, which is a stage still being written.

`offline_staged_state` publishes nothing unless dnf5 says `ready`, so the staged banner disappears
as soon as the transaction stops being armed.

### Which transaction ran

A new boot and a vanished transaction prove that *a* transaction applied. To know it was Kempt's,
a stage records two values from dnf5's toml: `rpmdb_cookie` (a hash of the rpm database it was
built against) and `cmd_line` (the command that built it).

- **Before the restart**, every check compares the marker with the toml. A different cookie,
  command or package set means `replaced`. The cookie alone is not enough, because two stages with
  different `--exclude` flags can share one. The test is skipped while `stage.lock` is held, since
  a rebuild replaces dnf5's transaction before it rewrites the marker.
- **After the restart**, the harvest reads dnf5's history since the stage (`history list --json`,
  then `history info <id> --json`, as the user). The entry that began at the cookie
  (`rpmdb_version_begin`) and ran the command (`command_line`, from the list) is the stage. Its id
  becomes `transaction_id`, and the report keeps only the packages it touched. If the history
  answered in full and no entry matches, the surface is `restart (staged update did not run)`.

Anything unclear is **cannot tell**, and the harvest reports the whole snapshot diff. That covers an
older marker, an unknown history format, no entries, more than 20, or two candidates. The lookup
starts a day before `staged_at`, in case the clock was wrong early in boot.

**A live run** reads the highest history id before the apply (`dnf_history_max_id`). Afterwards it
takes the one newer entry that ran the helper's command (`dnf5 upgrade`, `-y`, one `--exclude=` per
hold). That gives `transaction_id` and the report. Two matches, or no answer, is cannot tell.

**Superseding.** dnf5 refuses a stage once the rpm database has moved. So a live `kempt update`
discards the stage (`dnf-offline-clean`), removes the marker and its snapshot copy, and logs
`offline stage dropped (superseded by live update)`. Over a stored release upgrade only the marker
goes. It happens only when the stage is still pending (its baseline matches this run's start), dnf
succeeded, and the rpm set moved. A Flatpak-only run leaves the stage alone. Rpm changes by other
tools are not tracked: dnf5 refuses the stale transaction at boot and the system boots normally.

## The network boundary

**Every check reads a local cache, and every fetch happens in one place, under one policy.** A
laptop offline can still answer "what is pending?".

| Command | May reach the network |
| --- | --- |
| `dnf5 --cacheonly check-update --quiet` (`kempt-refresh check`) | No |
| `dnf5 -C --disablerepo='*' needs-restarting` (`dnf_reboot_needed`) | No |
| `flatpak remote-ls --updates --system --app --cached ...` (`flatpak_check`) | No |
| `flatpak remote-ls --updates --system --runtime --cached ...` (`flatpak_check`) | No |
| `flatpak list --system --app ...` (`flatpak_snapshot`) | No |
| `flatpak list --system --runtime ...` (`flatpak_snapshot`, `flatpak_id_is_runtime`) | No |
| `dnf5 --setopt=cachedir=/var/cache/libdnf5 -C repoquery --upgrades --latest-limit 1` (`dnf_sizes`) | No |
| `dnf5 makecache --refresh` (`kempt-refresh refresh`) | **Yes** |
| `flatpak remote-ls --updates --system --app ...`, no `--cached` (`flatpak_refresh`) | **Yes** |
| `kempt-apply`'s upgrade verbs, and `flatpak update --system` (`flatpak_apply`) | **Yes**, that is what a run is |

Both fetches run from `maybe_refresh_metadata` in `lib/common.sh`: at most once every three
hours, only on mains power and an unmetered connection, and never failing the check that follows.
One `$LAST_REFRESH_FILE` stamps both, written when either succeeded. `kempt check --refresh`
overrides the interval only.

The dnf fetch goes through the root helper (`priv_refresh`), because it fills root's cache, which
the update uses. The flatpak fetch runs as the user. The runtime query reads the same summary
cache as the app query, so one fetch serves both. Each fetch logs its own result, and one failing
does not stop the other.

A skip is shown two ways. `metadata_refreshed` dates the cache in the footer and `kempt doctor`.
The event log records a skip at most once a day, through `$REFRESH_SKIP_FILE`.

A cache nothing has filled cannot answer, and the backend reports `stale`. The first check fixes
that, because a box with no `$LAST_REFRESH_FILE` passes the interval gate. Keep the network out of
the check.

## The privileged boundary

There are two root helpers, one per polkit action. polkit's `auth_admin_keep` caches per action,
so a cheap verb must never share an action with a dangerous one.

- `kempt-refresh` (`io.github.erez_c137.kempt.refresh`, no dialog): `check` and `refresh`,
  metadata only.
- `kempt-apply` (`io.github.erez_c137.kempt.apply`, one auth per run): `dnf-upgrade`,
  `dnf-offline-stage`, `dnf-offline-arm` and `dnf-offline-clean`. The last two take no arguments.
  It handles dnf only. `flatpak update` asks polkit for itself and runs as the user.

Both helpers validate every argument before running anything, accept no free-form arguments, and
pin `PATH` and `LC_ALL`. The full model, including what passwordless mode grants, is in
[security.md](security.md).

## The widget's one command path

Every process the widget starts goes through `Executor.qml`. It wraps the executable data engine
(`Plasma5Support.DataSource`, a shim KDE plans to drop) in a serialised, asynchronous queue with a
timeout per call. When the shim goes, only this file changes.

Every command starts with `PATH="$HOME/.local/bin:$PATH" KEMPT_VIA=widget kempt`, because
plasmashell may lack the login shell's `PATH`.

**Settings page writes go through `page.durable()`**, which appends `& wait $!`. Plasma's OK button
closes the dialog at once, and the close kills the page's running commands. The background job
survives that, and `wait $!` still returns its status. Use it for writes only: `main.qml`'s
executor must be able to kill a stuck `kempt check`.

**One component, one queue per kind of caller:**

| Instance | Lives in | Carries | Why it is separate |
| --- | --- | --- | --- |
| `executor` | `main.qml` | checks, holds, `run`, `summary`, config reads, the watcher poll | The actions. A `kempt check` can take two minutes. |
| `tailExecutor` | `main.qml` | `tail -n 25` of the run log, every 2s while the popup shows it | The queue is first in, first out. Behind a two-minute check, tails would pile up ahead of every button press. |
| `promptExecutor` | `main.qml` | the restart prompt, and nothing else | `dbus-send` takes milliseconds. Behind a check it would sit unsent with nothing on screen. |
| `cfgExecutor` | `configGeneral.qml` | the settings page's reads and writes | The config dialog lives in its own object tree and cannot reach `main.qml`. It must also open while a check runs. |
| `pwExecutor` | `configGeneral.qml` | `enable-passwordless` and `disable-passwordless`, and nothing else | Those two wait on a password dialog, and the page's other work must not wait behind them. |

The rule: a fast, periodic caller must not share a queue with a slow, occasional one. Add another
instance rather than making the queue clever.

**Rebuild Staged Update runs the same command as Install on Next Restart**
(`kempt update --surface=offline`, detached with `setsid`), so there is one staging path to
secure. A rebuild destroys the old transaction as soon as it starts, and a popup can sit open for
an hour. So `rebuildStaged()` in `main.qml` captures the banner's `staged_at`
(`vm.stagedStagedAt`), then reads `state.json` with `cat`. It proceeds only if the same stage is
still published and still raises a warning. Otherwise it redraws the banner and says the staged
update changed. During a run it does nothing, like `stageOffline`.

When the 30-second watcher sees `state.json` change after a run, `adoptState()` assigns that file
at once, without waiting for the next check. The run has already published the armed stage
(`publish_staged_state`). A popup still offering **Update Now** would start a live upgrade that
discards it.

### What the message stack says to a screen reader

Kirigami gives an `InlineMessage` **no accessible name**, so every message in the popup sets
`Accessible.name: text`. That alone announces nothing when the message lacks focus. So every
announcement goes through `announce(sentence, assertive)` in `FullRepresentation.qml`. It calls
`Accessible.announce` (Qt 6.8 and later) and emits `announced(string)`, which tests listen to.

| What | Politeness | Why |
| --- | --- | --- |
| `Holding X` / `No longer holding X` | Polite | The outcome of the person's own press. |
| A hold that failed | Assertive | The row now carries an error and the padlock is live again. |
| The staged banner, when its words change while it is visible | Assertive | The machine is saying that what it promised has changed. |
| The post-run line and a failed press | Assertive | The answer the person was waiting for, and the popup may not have focus. |
| The footer, when the box goes stale | Polite | Keyed on the *reason*, so the 30-second clock tick that rewrites "Checked 4 min ago" is silent. |

Each announcing message keeps a `spoken` string so one change is announced once, and clears it
when hidden. The **Rebuild Staged Update** tooltip names its costs, and `Accessible.description`
is bound to it, because the polkit dialog takes focus at once.

### Where the popup's last-run line comes from

The `Last update 18 min ago · 4 packages` row and the line shown after a run both come from
**`kempt summary --json`**, parsed by `Logic.lastRunOf` in `logic.js` into `main.qml`'s `lastRun`.
The widget never parses the human `kempt summary`. The CLI serves the newest history entry as
`cmd_update` wrote it:
`{timestamp, surface, status, duration_sec, reboot_needed, log, error, backends: {<name>: {updated, added, removed, status, skipped_held}}}`.

Optional keys on that entry:

- `transaction_id`, on a live run or a harvest, when dnf5's history named the transaction.
- `duration_sec` is always on a live or staging run. On a harvest it is dnf5's recorded time for
  that transaction, and absent when dnf5's history did not name one.
- `staged_nothing`, on a staging run that staged nothing: `"held"` or `"nothing_pending"`. The
  widget treats any other value as an ordinary stage.
- `eol` on a live run's flatpak backend: one `{id, branch, kind, apps, reason}` per end-of-life
  ref (see `flatpak_eol_notices`). Only `kempt summary` shows it so far.

Rules at this boundary:

- **Empty stdout under exit 0 means "no last run"**, and `lastRunOf` answers `null`.
- **It is the newest entry or nothing.** Unlike the human mode, `--json` does not walk back past a
  damaged entry. The post-run line also needs an entry stamped at or after `enterUpdating()` ran
  (`Logic.runFinishedSince`).
- **Every field tolerates absence**, because entries outlive the build that wrote them. The
  exception is `status`: unreadable counts as failed.
- **The entry's `reboot_needed` describes that run.** The restart message uses the state file's.

While the post-run line is up, the persistent row is hidden.

### Where the widget lives

Three settings put Kempt in the system tray, and each fails silently when wrong:

- `"X-Plasma-NotificationAreaCategory": "SystemServices"` at the **top level** of
  `plasmoid/metadata.json`, outside `KPlugin`. Plasma 6.7's tray reads this key only there.
- `"X-Plasma-NotificationArea": "true"`, also top level. Plasma 6.7 ignores it, but shipped
  tray applets still carry it, so Kempt does too.
- `Plasmoid.status = ActiveStatus` in `main.qml`. Without it the tray hides the entry on "Auto".
  It is assigned in `Component.onCompleted`, because the QML probes cannot satisfy a binding.

`KPlugin.EnabledByDefault: true` makes it appear unasked. The compact representation's
`Layout.minimumWidth/Height` follow the shell's `DefaultCompactRepresentation.qml`, and
`Logic.resolveIconSize` falls back to automatic when a chosen size does not fit the tray cell.

### Why the widget is testable at all

- `logic.js` holds every derivation (badge, icon state, tooltip, popup rows, watcher comparison,
  icon size) in engine-agnostic JavaScript. `tests/test_widget_logic.sh` loads it with node.
- The remaining QML is bindings. `tests/test_widget_logic.sh` compiles every `.qml` with PySide6's
  `QQmlComponent`. `tests/test_widget_qml.sh` runs each `tests/qml/probe_*.py` against a stubbed
  `kempt`. Only the two keyboard-focus probes build a window, an offscreen one.
- Both halves skip, loudly, when node or PySide6 is missing.

The suite needs no package manager, polkit or desktop. `tests/run_tests.sh` ends with `ALL PASS`
or `FAILURES`.

Run the probes only through `tests/test_widget_qml.sh`. It runs them one at a time under
`tests/qml/safe_probe.py`, which kills a probe's process group on timeout. Stuck Qt processes
ignore SIGTERM and pile up until the machine runs out of memory.

## Adding a backend for your distro

A backend is one new file, one new verb in the apply helper if it needs root, fixtures, tests, and
the wiring listed in step 2b.

### 1. Write `backends/<name>.sh`

Two required functions plus the pure parser they share. Model it on `backends/dnf.sh`, the shorter of
the two shipped backends.

```bash
#!/usr/bin/env bash
# apt backend SKETCH. Requires lib/common.sh sourced first.

# Every impure command goes through a variable, so a test can replace it with `cat fixture`.
KEMPT_APT_PENDING_CMD="${KEMPT_APT_PENDING_CMD:-apt list --upgradable}"
KEMPT_APT_INSTALLED_CMD="${KEMPT_APT_INSTALLED_CMD:-}"

apt_installed_lookup() {  # -> sorted TSV, one row per name, versions ascending
  # Both branches share the sort tail, so a stubbed command is sorted the same way as the real one.
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

Rules a review will hold you to:

- **Return status explicitly.** `if x="$(fn)"` disables errexit inside the whole callee, so a
  backend that relies on `set -e` reports success when it failed.
- **Zero pending is success.** A backend that exits non-zero when nothing is pending leaves an
  up-to-date box permanently `stale`.
- **Capture the parser's status before cleanup.** An `rm -f` after the parse returns 0, and a failed
  parse then looks like "nothing pending".
- **Collapse, always, behind `sort_name_version`.** `tsv_diff_updates` rejects repeated names. Put
  the shared sort where every branch of the function passes through it, because consumers read the
  last version in a set as the newest.
- **Add no locale handling.** `lib/common.sh` pins `LC_ALL=C.UTF-8` for everything.
- **Guard the not-installed case.** A pending package with no installed row must come out as
  `from: "?"`, never an empty string. GNU `join -a1 -e '?' -o ...` does that; jq's `//` does not
  catch empty strings.
- **Sizes are optional, and partial sizes are worse than none.** If the metadata a check reads has
  download sizes, emit `name<TAB>bytes` (as `flatpak_check` or `dnf_sizes` do) and `cmd_check`
  prices the backend. A backend with no sizes publishes no `download_bytes`, which is fine. A total
  that covers only some items is wrong.
- **A network fetch belongs in `maybe_refresh_metadata`, not in your check.** Add a
  `<backend>_refresh` and another arm to that gate, as `flatpak_refresh` does, so it follows the
  interval, power and metering rules.

### 2. Add a verb to `libexec/kempt-apply` (only if root is really needed)

Ask first whether it needs root. If your package manager asks polkit for itself, as
`flatpak update` does, apply it from the backend as the user.

The apply helper runs as root, so a new verb is a security change. Follow the existing shape:
match the verb, validate every argument against a strict pattern before building the command, and
reject anything else with exit 2.

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

Holds become your package manager's exclude mechanism. Validate every name against `NAME_RE`
before it reaches a command line, as the `dnf-upgrade` verb does with `--exclude=`. Reject the
whole invocation on one bad name.

### 2b. Wire it in: every place that names a backend

There is no registry or discovery. Backends are named in each place below, and a missed one fails
silently. This is the complete list for the CLI, the widget and the man page. Only the row marked
optional can be skipped.

| Where | What it names today | What a third backend needs |
| --- | --- | --- |
| `bin/kempt`, the `source` lines at the top | `backends/dnf.sh`, `backends/flatpak.sh` | One more `source` line. |
| `cmd_check` | `dnf_check` / `flatpak_check`, `mark_held`, `state_prev_items`, the `include_flatpak` gate | A call pair, its own enable gate, and its own previous-items fallback for the stale path. |
| `maybe_refresh_metadata` (`lib/common.sh`) | `include_flatpak` and `flatpak_refresh`, by name | Its own arm and enable gate, if the backend needs a network fetch before a check can answer. Without it the backend answers from whatever its cache holds, indefinitely. |
| `assemble_state` (`lib/common.sh`) | Items arrive **positionally** (`$1` dnf, `$2` flatpak) and the jq body writes `backends: {dnf, flatpak}` | A **signature change**, so every caller changes. This is the one edit here that is not additive. |
| `cmd_update` | Before and after snapshots, the apply runner and its arguments (`apply_with_retry "$log" priv_apply dnf-upgrade ...` for dnf, `apply_with_retry "$log" flatpak_apply ...` for flatpak), per-backend status, held lists, and the history entry's `backends` object | The same set again, plus a runner: the verb from step 2 behind `priv_apply`, or the backend's own apply function. |
| `dnf_reboot_needed` in `cmd_update` and `cmd_check` | Called whatever backends ran | Nothing today. There is no `include_dnf` key. If dnf ever gets an `include_<name>` gate, these calls go behind it. |
| `render_summary` (`lib/common.sh`) | `.backends.dnf` and `.backends.flatpak` by name, with the labels "System (dnf)" and "Apps (flatpak)" | A new line, or a rewrite over `.backends \| to_entries`. |
| `harvest_offline` | Writes a history entry with both backend keys hardcoded | The new key. |
| `cmd_hold` / `cmd_unhold` | `[[ "$b" == dnf \|\| "$b" == flatpak ]]`, and the message that names both | The whitelist. Without it, `kempt hold apt:foo` exits 2. |
| `cmd_doctor` | The per-tool checks (flatpak's command and dnf's, each read from its own seam) and the checkout file list | A tool check, so a missing package manager is reported instead of showing as a permanently stale backend. |
| `kempt_default` and `KEMPT_CONFIG_KEYS` (`lib/common.sh`) | `include_flatpak` (and `auto_accept`) default to `true`, and both are known keys | A default for `include_<name>`, and the key in `KEMPT_CONFIG_KEYS` so `config set` does not warn. Without the default `config_get include_<name>` answers the empty string, `is_true` reads that as false, and the backend is silently off wherever the config file never names it. |
| `docs/architecture.md`, `docs/configuration.md` | The state schema example and the `include_flatpak` key | A schema entry (additive, still schema 1) and an enable key with the same meaning. |
| **Optional:** `cmd_update`'s option loop and `usage` (`bin/kempt`) | `--no-flatpak`, and its line in `usage` | A `--no-<name>` override and its usage line. Without it the backend can be switched off only in config. |
| `SECTION_TITLES` and `BACKEND_ORDER` (`plasmoid/contents/ui/logic.js`) | `{dnf: "System (dnf)", flatpak: "Apps (flatpak)"}`, and the order the popup lists them in | A title and a place in the order. Without them the section heading reads `apt`. |
| `KIND_SECTION_TITLES` (`plasmoid/contents/ui/logic.js`) | `{flatpak: {runtime: "Flatpak runtimes"}}` | A title per `kind`, only if your backend writes `kind`. Without it the heading reads `<backend> <kind>`. |
| The watcher's package databases (`plasmoid/contents/ui/main.qml`) | `/var/lib/rpm/rpmdb.sqlite`, `/var/lib/rpm` and `/var/lib/flatpak`, checked every 30s | Your package database's path. Without it an update applied in a terminal shows only after the next timed check. |
| `docs/man/kempt.1` | `--no-flatpak` under `update`, and `flatpak(1)` in SEE ALSO | The option and the reference. |

**Packaging needs nothing.** `kempt.spec` ships `backends/` as a directory and strips shebangs from
`backends/*.sh` with a glob. Keep it a glob: a backend file listed by name is one the next backend
misses.

Already generic: the totals in `assemble_state`'s `wrap`, `run_counts_phrase`, and the held-items
line in `render_summary`. All three iterate `.backends[]`.

### 3. Record fixtures

Fixtures are byte-for-byte captures of real tool output, with **no comment lines**. Provenance
goes in [`tests/fixtures/MANIFEST.md`](../tests/fixtures/MANIFEST.md). Capture through the code
path production uses. Every fixture contains at least these guard rows:

- a pending package **absent** from the installed lookup, so deleting the join guard fails a test;
- a repeated name at a **different** version, so the collapse step is exercised (identical
  versions collapse at `sort -u` and prove nothing);
- the section headers or indented rows the real tool emits, so the filters that drop them are
  tested.

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

`sandbox` must be the first call. It creates a temp directory, points `HOME`, the config
directory and the state directory inside it, neutralises every seam, and installs the EXIT trap
that sets the file's exit status. Do not install your own EXIT trap over it.

Then **prove the test binds**: break the code it covers, watch it fail, and put the code back. A
test that passes against the defect it is named after is worse than none. `tests/run_tests.sh`
runs everything.

### 5. Worked sketches

Starting points, not shipped code.

| Distro | Pending | Installed snapshot | Apply verb |
| --- | --- | --- | --- |
| Debian/Ubuntu | `apt-get -s upgrade` (simulate) or `apt list --upgradable` | `dpkg-query -W -f='${Package}\t${Version}\n'` | `apt-get -y upgrade` |
| Arch | `checkupdates` (pacman-contrib) | `pacman -Q` | `pacman -Syu --noconfirm` |
| openSUSE | `zypper --quiet list-updates` | `rpm -qa --queryformat '%{NAME}\t%{EVR}\n'` | `zypper -n update` |

apt output depends heavily on the locale, so the `LC_ALL` pin matters more there. `checkupdates`
already prints `name old -> new` and needs no installed lookup. openSUSE can reuse `dnf.sh`'s
snapshot, since it is the same rpm database.

Open a discussion before a pull request for anything that changes the state schema, the exit codes
or the privileged helpers. A backend touches all three: a new root verb, a new key under
`backends`, and a changed `assemble_state` signature.

## Environment seams

Every impure call in the CLI goes through a variable. That is how the suite tests privileged and
destructive paths without running them.

| Variable | Default | Used for |
| --- | --- | --- |
| `KEMPT_ROOT` | the directory above `lib/common.sh` | The tree the CLI reads itself from: `VERSION`, `backends/` and the passwordless rules template. `kempt doctor` prints it, and tells a packaged install from a checkout by whether `install.sh` is in it. With no `VERSION`, `kempt --version` answers `kempt unknown` |
| `KEMPT_CONFIG_DIR`, `KEMPT_STATE_DIR` | `~/.config/kempt`, `~/.local/state/kempt` | Redirect config and state |
| `KEMPT_PKEXEC` | `pkexec` | Set empty to call a helper directly (tests) |
| `KEMPT_REFRESH_HELPER`, `KEMPT_APPLY_HELPER` | the matching `*_HELPER_PATH` | Point at stub helpers |
| `KEMPT_REFRESH_HELPER_PATH`, `KEMPT_APPLY_HELPER_PATH` | `/usr/local/libexec/kempt-{refresh,apply}` | The paths polkit's `exec.path` pins. `kempt doctor` checks root:root 0755 only when the helper seam equals this one. Compared, never run |
| `KEMPT_DNF_CMD`, `KEMPT_DNF_INSTALLED_CMD` | `dnf5`, (rpm query) | Replace the dnf commands |
| `KEMPT_DNF_SIZES_CMD` | (empty, so `dnf5 --setopt=cachedir=... -C repoquery --upgrades --latest-limit 1 ...`) | The download-size query. Separate from `KEMPT_DNF_CMD`, which tests point at a `needs-restarting` stub. `tests/lib.sh` points it at a missing path |
| `KEMPT_DNF_SYSTEM_CACHE` | `/var/cache/libdnf5` | The cache `dnf_sizes` reads, so sizes come from the check's metadata. When unreadable the query drops the `--setopt`. Point it at a missing directory to test that |
| `KEMPT_FLATPAK_REMOTE_CMD`, `KEMPT_FLATPAK_LIST_CMD` | `flatpak remote-ls --cached/list --system --app ...` | Replace the flatpak commands. The remote query is cache-only; see [the network boundary](#the-network-boundary) |
| `KEMPT_FLATPAK_REMOTE_RUNTIME_CMD`, `KEMPT_FLATPAK_LIST_RUNTIME_CMD` | the two queries above with `--runtime` in place of `--app`, and `branch` added to the columns | The runtime queries. flatpak filters by kind with a flag, so runtimes need their own command. `tests/lib.sh` pins both at `true` (a box with no runtimes); a missing path would fail every flatpak check |
| `KEMPT_FLATPAK_SNAP_CMD`, `KEMPT_FLATPAK_SNAP_RUNTIME_CMD` | the two list queries above with `active` added to the columns | The run's before and after snapshots. The deployed commit is included because many runtimes have no useful version, so version alone misses updates. `tests/lib.sh` pins both at `true`, so the suite never reads the host's flatpaks |
| `KEMPT_FLATPAK_APP_RUNTIME_CMD`, `KEMPT_FLATPAK_INFO_CMD` | `flatpak list --system --app --columns=application,name,runtime`, `flatpak info --system` | The end-of-life lookups, run only when `flatpak update` printed an end-of-life notice. A failure loses the note, not the run. `tests/lib.sh` pins both at `true` |
| `KEMPT_FLATPAK_REFRESH_CMD` | the app remote query **minus** `--cached` | The flatpak half of `maybe_refresh_metadata`. Runs as the user, never through `pkexec`. `tests/lib.sh` points it at a missing path, so no test fetches from flathub |
| `KEMPT_FLATPAK_UPDATE_CMD` | `flatpak update --system` | The flatpak apply (`flatpak_apply`), run as the user. `tests/lib.sh` points it at a missing path, so the suite cannot update the host |
| `KEMPT_NOTIFY`, `KEMPT_TERMINAL` | `notify-send`, `konsole` | Notifications and the terminal surface |
| `KEMPT_RISKY_RE`, `KEMPT_BOOT_ID` | (empty) | Override the session-critical pattern and the boot session |
| `KEMPT_SKIP_REFRESH`, `KEMPT_RETRY_DELAY` | (unset), `10` | Deterministic checks and fast retry tests |
| `KEMPT_VIA` | (unset) | The event log's `via` column: `widget` when set to that, `cli` otherwise. Read only by `log_event` |
| `KEMPT_ASSUME_TTY`, `KEMPT_LIVE_OUTPUT` | (unset) | Drive the interactive prompt path from a script |
| `KEMPT_RULES_DST` | (unset, so `/etc/polkit-1/rules.d/49-kempt.rules`) | Passwordless rule destination, for tests. Honoured only when `KEMPT_PKEXEC` is empty and the CLI is not root, and it must be an absolute `*.rules` path. Set in a pkexec or root run, it is refused with exit 2 |
| `KEMPT_POLICY_FILE` | `/usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy` | Where `kempt doctor` reads each action's `exec.path`, to compare with the helper path the CLI uses |
| `KEMPT_PLASMOID_DIR` | `~/.local/share/plasma/plasmoids/io.github.erez_c137.kempt` | The user's copy of the widget, read by `kempt doctor`. On a checkout install it is the install, and doctor diffs it against `plasmoid/`. On a packaged install its existence is a FAIL, because Plasma prefers a user copy over `/usr/share` |
| `KEMPT_UI_DIR` | the checkout's `plasmoid/contents/ui` | Which copy of the QML the probes under `tests/qml/` run. The release check points it at the packaged copy under `/usr/share/plasma/plasmoids/`. Read by the test harness only |
| `KEMPT_REFRESH_TIMEOUT` | `120` | Seconds a metadata refresh may take before the check gives up and reports stale. The long wait is an authentication dialog nobody answers |
| `KEMPT_CHECK_LOCK_WAIT` | `60` | Seconds a check waits for `check.lock` before serving the previous state instead |
| `KEMPT_RUN_START_WAIT` | `5` | Seconds `kempt run` waits for the terminal window to start the update before reporting that it did not start (exit 5). A launcher that exits with an error is reported at once |
| `KEMPT_SYSTEM_PLASMOID_DIR` | `/usr/share/plasma/plasmoids/io.github.erez_c137.kempt` | Where the package puts the widget. Read only by `kempt doctor` on a packaged install, to say whether `kempt-plasmoid` is missing. `tests/lib.sh` points it at a missing path |
| `KEMPT_WIDGET_PATH` | `~/.local/bin:$PATH` | The `PATH` the widget's command line builds. `kempt doctor` resolves `kempt` through it to report which CLI the widget would run. Resolved, never executed. `tests/lib.sh` points it at a directory with no `kempt` |
| `KEMPT_OFFLINE_TOML` | `/usr/lib/sysimage/libdnf5/offline/offline-transaction-state.toml` | dnf5's record of a staged transaction, world-readable. Read, never written. `tests/lib.sh` pins it at a `ready` fixture. `kempt-apply` reads it to refuse offline verbs over a release upgrade, and honours this variable only when not running as root |
| `KEMPT_OFFLINE_TXJSON` | `/usr/lib/sysimage/libdnf5/offline/transaction.json` | dnf5's stored transaction, the package set a restart will install. Read live, never written. `tests/lib.sh` pins it at a recorded transaction; point it at anything unparsable to test the fallback |
| `KEMPT_DNF_HISTORY_CMD` | `dnf5` | Answers `history list --json` and `history info <id> --json`, run as the user to find [which transaction ran](#which-transaction-ran). Read only. `tests/lib.sh` points it at a missing path, so tests take the "cannot tell" branch |
| `KEMPT_XDG_AUTOSTART_DIR` | `/etc/xdg/autostart` | Where `kempt doctor` looks for Discover's update notifier. Read, never written. `tests/lib.sh` points it at a missing path |
| `KEMPT_AUTOSTART_SRC` | `/etc/xdg/autostart/org.kde.discover.notifier.desktop` | The system entry `install.sh` copies when it writes the user's autostart override that hides Discover's notifier |
| `KEMPT_OSTREE_MARKER` | `/run/ostree-booted` | Its existence marks an image-based system. Read by `kempt update` (aborts in pre-flight), `kempt check` (publishes `image_based`) and `kempt doctor`. `tests/lib.sh` points it at a missing path |
| `KEMPT_OFFLINE_LINK` | `/system-update` | The symlink `dnf5 offline reboot` creates. `lstat`ed only, never resolved or written. `kempt doctor` is its only reader. `tests/lib.sh` points it at a missing path |
| `KEMPT_APPLY_ECHO`, `KEMPT_REFRESH_ECHO` | (unset) | Root helpers print the final command instead of running it |
| `KEMPT_KPACKAGETOOL` | `kpackagetool6` | The tool `install.sh` installs and removes the widget with. It goes through the same `run` seam as the privileged commands, so `KEMPT_INSTALL_ECHO` prints it |
| `KEMPT_DBUS_SEND` | `dbus-send` | The `org.kde.KIconLoader.iconChanged` signal `install.sh` sends so plasmashell reloads icons. Best effort. `tests/lib.sh` points it at `true` |
| `KEMPT_INSTALL_ECHO` | (unset) | `install.sh` prints its privileged commands instead of running them; `=fail` also makes them report failure. Unprivileged symlinks are still created, so use a scratch `HOME` for a fully inert dry run |

The `*_ECHO` seams are for tests only. `KEMPT_APPLY_ECHO` and `KEMPT_REFRESH_ECHO` cannot reach a
real privileged run, because pkexec clears the caller's environment. `KEMPT_INSTALL_ECHO` runs on
the user's side and can only stop `install.sh` from running privileged commands.

## Known v1 decisions

- **The dnf check parser reads text.** Moving to dnf5's `check-update --json` is planned for v2.
- **Flatpak is system scope only.** Every flatpak command in `backends/flatpak.sh` names
  `--system`, so check, refresh and apply agree.
- **Flatpak needs no Kempt polkit action.** flatpak's own policy grants `app-update` and
  `runtime-update` to an active local session. The exceptions are in
  [security.md](security.md#accepted-limitations).
- **Flatpak runtimes are counted, and cannot be held** (exit 2). Apps share runtimes, so a held one
  breaks the next app that needs it.
- **The package build rewrites two files.** pkexec matches the helper by the path the polkit
  action pins. So `kempt.spec`'s `%prep` replaces `/usr/local/libexec` with the FHS libexec
  directory in `polkit/io.github.erez_c137.kempt.policy` and `lib/common.sh`. Its check stage runs
  the suite on a pristine copy.
