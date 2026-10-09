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

The core rule: **the badge count comes from the same command path that performs the update**.
`kempt check` reads the root metadata cache the update will use, with the same holds and backends.

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
| `libexec/kempt-flatpak-unused` | Lists the Flatpak runtimes no installed app uses. Runs as the user |
| `polkit/` | The two action definitions plus the passwordless rule template |
| `plasmoid/` | The Plasma 6 panel widget: a client of the CLI with no package-manager knowledge |
| `plasmoid/contents/ui/logic.js` | The widget's whole derivation layer, in engine-agnostic JS so node can test it |
| `install.sh` | Symlink install, staged install (`--destdir`), uninstall |
| `tests/` | Fixture-driven bash test suite, no framework dependency |
| `tests/qml/` | PySide6 probes that execute the real QML against a stubbed CLI (see below) |

`libexec/kempt-flatpak-unused` is the one Python file. It calls libflatpak's `list_unused_refs()`
through PyGObject, the same call `flatpak uninstall --unused` makes. How Kempt removes what it
lists is in [security.md](security.md#two-polkit-actions). The file is executed, so it stays out of
`lib/` and `backends/`, whose shebangs the package strips. It runs as the user, so the package
installs it in `/usr/share/kempt/libexec/` and leaves `%{_libexecdir}` to the two root helpers.

## The backend contract

A backend is one file with two functions. Both answer on stdout, with an explicit exit status:

| Function | Input | Output |
| --- | --- | --- |
| `<backend>_check` | Optionally, a path to write a sizes TSV to | items JSON: `[{"name": "...", "from": "...", "to": "..."}]`. Empty is `[]` with exit 0. Non-zero means the check failed. |
| `<backend>_snapshot` | none | TSV, `name<TAB>version`, sorted by name, **one row per name** |

- The sizes TSV is `name<TAB>bytes`. `flatpak_check` takes the path and `cmd_check` passes it. dnf
  publishes its sizes from a separate `dnf_sizes`. A backend that produces no sizes publishes no
  `download_bytes`.
- Everything else a check queries goes through overridable command variables.
- Parsing lives in a pure function that takes stdin plus an installed-lookup file
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

Kempt's own files live under `~/.config/kempt` and `~/.local/state/kempt`. Both can be redirected
(see [Environment seams](#environment-seams)). The full list, with modes and retention, is in
[configuration.md](configuration.md#files-and-retention). Apart from short-lived temp files in
`$TMPDIR`, Kempt writes outside them in three places:

- `kempt discover-notifier off` and `on` write to `~/.config/autostart`. `off` writes Kempt's
  entry and keeps any earlier one as `*.before-kempt`. `on` removes Kempt's entry, moves an edited
  one aside as `*.kempt-edited`, and puts the earlier one back.
- `kempt enable-passwordless` writes `/etc/polkit-1/rules.d/49-kempt.rules` as root.
- `install.sh` installs Kempt itself.

Rules for the state directory:

- **Readers take no lock.** `atomic_write` renames a temp file into place, so a reader sees the
  whole old file or the whole new one. The temp sits next to its destination.
- **`kempt_init_dirs` sweeps leftovers** after 60 minutes: temps, `reclaim-out.*` copies and
  `run-start.*` tokens.
- **`log_event` never fails a command.** It always returns 0 and waits at most 5 seconds for its lock. Its `via` column is
  `widget` when `KEMPT_VIA=widget`, which the widget sets on every command, and `cli` otherwise.
- **An update applied on a restart gets a log Kempt writes itself**, from the snapshot diff.
  Kempt was not running, so there was no output to capture.

Six files in the state directory are `flock` targets:

| Lock | Serialises | Notes |
| --- | --- | --- |
| `lock` | Runs | |
| `check.lock` | Checks | See `--coalesce` below. |
| `stage.lock` | A stage, from asking dnf5 for a transaction until the marker is written | A check that finds it held skips the [replaced-transaction test](#which-transaction-ran). |
| `writer.lock` | `kempt config set`, `kempt hold` and `kempt unhold` | Each rewrites a whole config file. It lives in the state directory because the config directory is the user's. |
| `state.lock` | Each write to `state.json`, and a run's read and write of `offline_staged` | Held for milliseconds. A run takes it instead of `check.lock`, so it publishes a stage without waiting for a check. |
| `events.lock` | Appends to `events.log` and its trim | Held for milliseconds. After 5 seconds the line is appended and the trim waits. |

[usage.md](usage.md#check) says when `--coalesce` lets one check answer for another.

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
| `last_success` | ISO 8601, or `null` | When a check last succeeded. `null` until the first success. Kept at its old value while `status` is `stale`. |
| `status` | `"ok"` or `"stale"` | `stale` means at least one backend failed and its previous items were reused. |
| `error` | string | Empty when fine. Otherwise the backend failure messages, joined with `"; "`. Each ends with at most 200 bytes of the tool's output, redacted as for `refresh_error`. |
| `backends.<name>.enabled` | boolean | False when the backend is switched off in config (`include_flatpak=false`). |
| `backends.<name>.actionable` | integer | Pending, not held, in this backend. |
| `backends.<name>.held` | integer | Pending and held, in this backend. |
| `backends.<name>.items[]` | array | `name`, `from` (installed version, `?` when not installed), `to` (pending version), `held` (boolean). Several versions of one package are comma-joined in **ascending** order. Readers that show one version take the last. |
| `backends.<name>.items[].kind` | string, optional | Only `flatpak` writes it, and only as `"runtime"`. Absent means an app or a dnf package. Additive. |
| `backends.<name>.items[].scope` | string, optional | Only `flatpak` writes it, and only as `"user"`: the per-user installation. Absent means the system one. Two items can share a `name` and differ here. Holds apply by id, to both. Additive. |
| `backends.<name>.items[].branch` | string, optional | The Flatpak branch, on every runtime. **A runtime's identity is its `name` and `branch` together.** Anything that keys items by name must key on the pair where this is present. Additive. |
| `backends.<name>.items[].size_bytes` | integer, optional | Bytes this item would download, summed over every architecture of that name. **Absent means unknown, never zero.** Additive. |
| `backends.flatpak.scopes` | object, optional | Only when a per-user installation exists: `{system, user}`, each `"ok"` or `"failed"`. See [below](#flatpak-scopes). Additive. |
| `backends.dnf.refresh_error` | string, optional | Present while the latest dnf metadata refresh that ran failed: one line of its error, at most 200 bytes. URL credentials, queries, fragments and token-shaped path parts are removed, and your home directory is written as `~`. When dnf printed nothing it says how the refresh ended, such as `dnf makecache timed out`. Absent once a refresh works. Additive. |
| `backends.<name>.download_bytes` | integer, optional | Bytes this backend would download. Written **only when every non-held item has a `size_bytes`**. Additive. |
| `actionable` | integer | The badge number: non-held pending items across all backends. |
| `held_total` | integer | Held pending items across all backends. |
| `risky_pending` | array of strings | dnf names matching `risky_regex`, except held ones and build or documentation packages (`-devel`, `-doc` and similar). Additive. |
| `download_bytes` | integer, optional | The sum of the per-backend keys. Omitted if any **enabled** backend omitted its own. Additive. |
| `reboot_needed` | boolean | Whether a restart is owed **now**, asked on every check. `false` means **nothing to say**, because a check that could not tell also answers `false`. Render no "no restart needed" line from it. Additive. |
| `metadata_refreshed` | ISO 8601 with offset, optional | When dnf's metadata was last **fetched**. See [below](#metadata_refreshed). Additive. |
| `refresh_skipped` | string, optional | `"battery"` or `"metered"` when this check's metadata fetch was due and did not run for that reason, `"off"` whenever `KEMPT_SKIP_REFRESH` turns fetching off. Absent otherwise. Additive. |
| `offline_staged` | object, optional | A staged update that will install on the next restart. See [below](#offline_staged). Additive. |
| `offline_stage_blocked` | object, optional | `staged_at` and `count` of a stage Kempt made that will **not** install on the next restart, because another updater has prepared it. Absent otherwise. Additive. |
| `image_based` | `true`, optional | Present **only** on an image-based Fedora (Silverblue, Kinoite, Bazzite, a bootc image), detected by `/run/ostree-booted`. `kempt update` aborts there in pre-flight with exit 5. Never `false`. Additive. |
| `reclaim` | object, optional | The Flatpak runtimes no installed app uses. See [below](#reclaim). Additive. |
| `release_upgrade` | object, optional | A stored Fedora release upgrade. See [below](#release_upgrade). Absent, never `null`, when there is none. Additive. |
| `discover_offer` | `true`, optional | The widget may offer to turn off Discover's notifier. See [below](#the-two-offers). Never `false`. Additive. |
| `surface_offer` | `true`, optional | The widget may offer to run updates in the widget. See [below](#the-two-offers). Never `false`. Additive. |

Two rules for anything that reads this file:

1. **Empty stdout from `kempt check` with exit 0 means "no data, keep the last known state"**,
   never "zero updates". It happens when another check holds the lock and there is no valid
   previous state to serve.
2. `status: "stale"` is not an alarm. The counts are still the best known. Show the staleness in a
   tooltip, not as a warning icon.

A new backend adds a key under `backends` and stays schema 1. Readers ignore keys they do not
know, and the totals keep working.

### Download sizes

The download figure is **an estimate**, so show it with "~" and never as "up to".

- It excludes held items.
- It omits new dependencies, because only a depsolve knows them, and a depsolve can block on the
  rpm lock.
- It ignores Flatpak static deltas and already-staged downloads, which over-count.
- It reads the system cache, `/var/cache/libdnf5`, which holds the metadata the check used.
- A disabled backend does not suppress the top-level `download_bytes`.

### Flatpak scopes

A per-user failure leaves the system items and the check's `status` alone. It keeps the previous
check's per-user items, and the widget says the apps for you only could not be checked.

### `metadata_refreshed`

- It reads `$LAST_REFRESH_DNF_FILE` and nothing else. `$LAST_REFRESH_FILE` also moves when only the
  Flatpak fetch worked, so it never dates dnf's metadata.
- It is absent until a dnf fetch has worked. `kempt doctor` then says no dnf refresh is recorded
  yet when fetches have run, and never refreshed when none has.
- A check answers from the cache, so this can be much older than `last_check`.
- The widget's footer shows `metadata N days old` past 24 hours. When a **Check for Updates**
  press got no fetch, a message gives the age and why: `refresh_skipped`, else
  `backends.dnf.refresh_error` (`Logic.fetchMissedOf`). It shows only while the state on screen is
  the one that press was answered with, so the next check takes it away. The footer shows the age
  instead while that message is closed or crowded out (`Logic.refreshMissed`).

### `offline_staged`

Present **only** while Kempt staged a transaction **and** dnf5 reports it armed: `status = "ready"`
**and** the `/system-update` symlink in place. Absence means not armed.

| Key | Type | Meaning |
| --- | --- | --- |
| `staged_at` | ISO 8601 | When it was staged. |
| `count` | integer or `null` | How many updates. `null` in a marker from before the count was recorded. |
| `armed` | `true` | Always `true`. |
| `holds_conflict` | array of strings | dnf packages in the staged transaction **and** held now. A restart installs them despite the hold. Sorted, unique, dnf only. Read it with `names_source`. Additive. |
| `names_source` | `"transaction"`, `"marker"` or `"none"` | What an **empty** `holds_conflict` means. Additive. |

- `transaction`: dnf5's stored transaction was read live, and empty means no conflict.
- `marker`: that read failed and the marker's transaction-derived list was used. Empty still means
  no conflict.
- `none`: there was no transaction-derived list, and empty means **cannot tell**.

A run also writes this key (`publish_staged_state()`), and touches nothing else. A read that fails
leaves the key as it was.

### `release_upgrade`

Present **only** while dnf5 has a Fedora release upgrade stored: `system_releasever` differs from
`target_releasever` in dnf5's state file. `from` and `to` are strings. `state` is always present:

| `state` | dnf5 status |
| --- | --- |
| `downloaded` | `download-complete` |
| `armed` | `ready` and the `/system-update` symlink, so the next restart installs it |
| `foreign` | `ready`, but the symlink points to another updater's prepared update, so the next restart installs that instead |
| `stranded` | `ready` with the symlink gone, so no restart runs it |
| `incomplete` | `download-incomplete`, `transaction-incomplete` or an unknown status |

dnf5 keeps one stored transaction for both kinds, so staging would cancel the release upgrade.
Kempt refuses to stage, and a reader should stop offering it.

### `reclaim`

Present only when Flatpak is installed and enabled, `reclaim` is not `off`, and the check did not
run as root.

| Key | Meaning |
| --- | --- |
| `mode` | `ask` or `automatic`: the mode Kempt acts on. It is `ask` whatever the setting on an image-based system, or when more than one person may use the machine ([configuration](configuration.md#unused-flatpak-runtimes) lists the signals). |
| `refs[]` | Every unused ref: `ref`, `commit`, `since` (UTC, when first seen unused with this commit) and `eol` (flatpak's end-of-life reason, or `null`). |
| `offerable_bytes` | The estimated size of the offered list. `null` when unknown or nothing is offered yet. |
| `digest` | Names the offered set, and is what `kempt reclaim --expect` takes. `""` when nothing is offered. |
| `status` | `ok`, `unknown_size`, `needs_auth` or `failed`. |
| `last` | The last removal, from `reclaim-last.json`. |

The list is offered whole, and only once every ref on it has been unused for an hour. Until then
`offerable_bytes` is `null` and `digest` is `""`. `failed` with an empty `refs` means this check
could not list the unused runtimes. Otherwise `needs_auth` and `failed` are carried from the last
removal while the same set is on offer.

| `last` key | Meaning |
| --- | --- |
| `at`, `via`, `bytes`, `digest` | When, from where, how much, and which set. |
| `result` | `removed`, `nothing`, `changed`, `needs_auth` or `failed`. |
| `refs` | With `removed`, what did go. With `failed`, `null`: anything from none to all of the set may be gone. |
| `error` | When a removal failed: Flatpak's error line, at most 200 characters, or `Flatpak did not answer when asked what is unused`. |
| `partial` | `true` when Flatpak failed after the removal began. `error` says why the rest stayed. |
| `skipped` | `true` when the extensions were never tried: the first pass succeeded and Flatpak refused nothing, but the list between the passes could not be read. They keep their `since`, so no new hour's wait. The widget says so with `reclaimSkipped` in `logic.js`. |
| `in_use` | Only when non-empty: as `id//branch`, the extensions Flatpak removed although it printed that an app uses them. It counts only apps installed after the list taken just before that pass. |

### The two offers

| Key | Present while | Gone when |
| --- | --- | --- |
| `discover_offer` | Discover's update notifier starts with the session, and the state file `discover-offer-answered` does not exist | `kempt discover-notifier off`, `on` or `keep` writes that file |
| `surface_offer` | The upgrade to 0.1.8 kept this install on the terminal (state file `surface-offer`), and `surface` is still `terminal` | `surface` is set in any way, or a check finds another surface |

`discover-entry-written` holds the bytes Kempt last wrote to the autostart entry. `on` removes the
entry only while it still matches.

## History entries

Each run's history entry is the second **public interface**. Two commands print it:

- `kempt summary --json` prints the newest entry, or nothing.
- `kempt history --json` prints every readable entry as one JSON array, newest first, or `[]`.

Both carry every field the run wrote. Fields may be added. A field that changes meaning or type is
a breaking change. Every field except `status` may be absent in an older entry, so a reader must
tolerate absence.

| Field | Type | Meaning |
| --- | --- | --- |
| `timestamp`, `surface`, `status`, `log`, `error` | string | When, how it ran, the outcome, the log path and the failure reason. |
| `duration_sec` | number | Always on a live or staging run. On a harvest it is dnf5's recorded time for that transaction, and absent when dnf5's history did not name one. |
| `reboot_needed` | boolean | Whether a restart was owed when that run finished. The state file's `reboot_needed` is a different fact: whether one is owed now. |
| `backends.<name>.updated`, `.added`, `.removed` | arrays of `{name, from, to}` | String values. A flatpak item from the per-user installation adds `scope: "user"`. |
| `backends.<name>.status` | string | The backend's outcome. |
| `backends.<name>.skipped_held` | array of strings | Held names the run left out. |
| `transaction_id` | number, optional | On a live run or a harvest, when dnf5's history named the transaction. |
| `staged` | number, optional | On a staging run that staged updates: how many. Never 0. |
| `stage_blocked` | `true`, optional | On a staging run whose stage worked while another updater held `/system-update`, so it does not install at the next restart. |
| `staged_nothing` | string, optional | On a staging run that staged nothing: `"held"` or `"nothing_pending"`. The widget treats any other value as an ordinary stage. |
| `backends.flatpak.scopes` | object, optional | On a live run, only when a per-user installation exists: `{system, user}`, each `"ok"` or `"failed"`. `status` is still the overall outcome. A per-user set that cannot be listed before or after the run records `user` as failed and fails the run. |
| `backends.flatpak.eol` | array, optional | On a live run: one `{id, branch, kind, apps, reason}` per end-of-life ref (see `flatpak_eol_notices`). Only `kempt summary` shows it so far. |
| `backends.flatpak.reclaimed` | object, optional | When `reclaim=automatic` tried a removal after the run: `{refs, bytes, status}`, plus `partial` and `in_use` as in `reclaim.last`. `status` takes `reclaim.last.result` values. Shown only when `removed`. |

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
privileged calls inside one authentication:

1. `dnf-offline-stage` (`dnf5 upgrade --offline`) downloads the transaction.
2. `dnf-offline-arm` (`env DNF_SYSTEM_UPGRADE_NO_REBOOT=1 dnf5 offline reboot -y`) arms it by
   creating `/system-update`, the symlink systemd looks for at boot. Without
   `DNF_SYSTEM_UPGRADE_NO_REBOOT`, arming reboots at once.

An unarmed transaction stays at `download-complete`, and no restart installs it. If the arm fails,
the stage is discarded with `dnf-offline-clean`, no marker is written, and the run fails.

**Rebuilding.** dnf5 replaces the stored transaction as soon as a new stage gets far enough, so a
failed rebuild can lose the old one. `cmd_update` reads dnf5's status after a failed stage:

1. **Old transaction still `ready`.** Nothing is cleaned, the marker stays, and the run fails.
2. **Old transaction gone or unarmed, or the arm failed, and cleanup succeeded.** The marker and
   its snapshot copy are removed, and the failure says what was lost.
3. **Cleanup failed too.** The marker is kept, and the notification carries the command that
   fixes it.

**The marker's fields:**

| Field | Meaning |
| --- | --- |
| `version` | The marker format. Set when the marker is created and carried forward unchanged. |
| `staged_at`, `boot_id` | When, and in which boot session. |
| `staged` | How many updates, published as `count`. |
| `pre_snapshot` | The snapshot copy of the package set it was staged against. |
| `staged_names` | What the transaction installs. Absent when unknown: `[]` would claim it installs nothing. |
| `staged_names_source` | `transaction`, `check` or `none`. A list from a check may confirm a hold conflict but never deny one, because a check cannot see resolver-added packages. |
| `staged_excluded` | The held packages left out. |
| `rpmdb_cookie`, `cmd_line` | dnf5's identity for the transaction ([below](#which-transaction-ran)). |
| `armed` | `true` when written. `false` once a restart proved the transaction cannot install. |
| `set_moved` | The package set changed under a stage still armed. |
| `replaced` | dnf5 holds a different transaction. |

- **Every field is additive.** Every reader must work with a marker from an older build.
- **The last three flags** also record that the event was announced, so it is announced once.
- **Names pass `KEMPT_NAME_RE`** as they are written, and one bad name drops the whole list.
- **A marker that will not parse is skipped, never cleared.** `offline_marker_read` returns nothing
  for an empty, unparsable or over-1 MB file. Clearing needs a marker that parses over a
  transaction dnf5 says has gone.
- **Writes are atomic and mode 0600** (`write_offline_marker`).

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
| yes, with an identity | present, and not the transaction the marker records | - | any | - | **Replaced.** Announced once and flagged `replaced`, never cleared here. The rows below still apply, and what then runs is never reported as this stage |
| yes | ready / any non-absent | - | same as staged | - | Still pending. Nothing happens |
| yes | absent | - | same as staged | - | The transaction was thrown away. Clear the marker, `offline marker cleared (stage gone)` |
| yes | absent | - | different | unchanged | The transaction was thrown away. Clear the marker |
| yes | ready | present | different | unchanged | Still pending: the restart has not run it yet |
| yes | ready | **gone** | different | unchanged | **Detour boot.** systemd removes the symlink once `system-update.target` is reached, so this boot walked past the transaction. Announce once, set `armed: false`, never clear |
| yes | present, not `ready` | - | different | unchanged | **Detour boot.** Same three rules |
| yes | `ready` | gone or another updater's | different | unchanged, with every staged change already on the box | **Installed before the restart.** Marker cleared, `offline stage installed by another updater (before the restart)`. Nothing to report, because the restart changed nothing |
| yes | present, not `ready` | - | different | unchanged, with every staged change already on the box | **Installed before the restart.** Same as the row above |
| yes | `ready` | gone or another updater's | different | changed, with every staged change on the box | **Installed by another updater.** One history entry with surface `offline (installed by another updater)`, narrowed to the staged packages. Announced once, marker cleared |
| yes | present, not `ready` | - | different | changed, with every staged change on the box | **Installed by another updater.** Same as the row above |
| yes | `ready`, or present and not `ready` | gone or another updater's, or any | different | changed, with any staged change missing | **Detour boot.** Same three rules |
| yes | absent | - | different | changed | **Harvested**: one history entry, diffed against the marker's snapshot copy, then attributed through dnf5's history ([below](#which-transaction-ran)). Surface `offline (applied on reboot)`, or `restart (staged update did not run)` when the history shows it did not |
| yes | present (any status) | - | different | changed | **Not harvested.** Something else moved the package set. Recorded once as `harvest deferred`, and the marker stays |

A harvest needs two gates. The boot must have changed, because a live run also moves the package
set. And dnf5's transaction must be gone, because applying one removes the toml,
`transaction.json` and `/system-update`. While any remain, a moved package set means another tool
moved it. A harvest consumes the marker and sweeps the snapshot copy.

**Detour boots.** After a new boot with the package set unchanged, a transaction that is present
but unarmed can never install. Announce it once (`armed: false` records that). Never clear the
marker, because `kempt doctor` needs it to say the stage can never install. Never apply this to a
same-boot `download-complete`, which is a stage still being written.

`offline_staged_state` publishes nothing unless dnf5 says `ready`, so the staged banner disappears
as soon as the transaction stops being armed.

**Another updater.** Discover's notifier, through PackageKit, can point `/system-update` at its
own prepared update, leaving dnf5's state at `ready`. A stage behind that symlink is not armed. The
check publishes `offline_stage_blocked` in place of `offline_staged`
(`offline_stage_blocked_state()`). The restart often installs the same packages.
`offline_stage_satisfied()` tells: each staged package must be installed at its staged version or
newer, and each staged removal gone. An old kernel that is still installed does not block it.
`kempt unstage` refuses while that symlink stands, because `dnf5 offline clean` would remove it
and cancel the other update. A superseding live run, an empty stage or a failed stage drops only
Kempt's marker there. A stage that works there is recorded with `stage_blocked`.

### Which transaction ran

A new boot and a vanished transaction prove that *a* transaction applied. To know it was Kempt's,
a stage records two values from dnf5's toml. `rpmdb_cookie` is a hash of the rpm database it was
built against, and `cmd_line` is the command that built it.

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
goes. All three must hold: the stage is still pending (its baseline matches this run's start), dnf
succeeded, and the rpm set moved. So a Flatpak-only run leaves the stage alone. After rpm changes
by other tools, dnf5 refuses the stale transaction at boot and the system boots normally.

## The network boundary

**Every check reads a local cache, and every fetch happens in one place, under one policy.** A
laptop offline can still answer "what is pending?".

| Command | May reach the network |
| --- | --- |
| `dnf5 --cacheonly check-update --quiet [--json]` (`kempt-refresh check`) | No |
| `dnf5 -C --disablerepo='*' needs-restarting [--json]` (`dnf_reboot_needed`) | No |
| `flatpak remote-ls --updates --system --app --cached ...` (`flatpak_check`) | No |
| `flatpak remote-ls --updates --system --runtime --cached ...` (`flatpak_check`) | No |
| `flatpak list --system --app ...` (`flatpak_snapshot`) | No |
| `flatpak list --system --runtime ...` (`flatpak_snapshot`, `flatpak_id_is_runtime`) | No |
| `dnf5 --setopt=cachedir=/var/cache/libdnf5 -C repoquery --upgrades --latest-limit 1` (`dnf_sizes`) | No |
| `dnf5 makecache --refresh` (`kempt-refresh refresh`) | **Yes** |
| `flatpak remote-ls --updates --system --app ...`, no `--cached` (`flatpak_refresh`) | **Yes** |
| `kempt-apply`'s upgrade verbs, and `flatpak update --system` (`flatpak_apply`) | **Yes**, that is what a run is |

Each flatpak command has a `--user` twin for apps installed with `flatpak install --user`. It runs
only when that installation exists, with the same answer in this table.

Both fetches run from `maybe_refresh_metadata` in `lib/common.sh`, under the policy in
[configuration.md](configuration.md#refresh-cadence). A fetch never fails the check that follows.
One `$LAST_REFRESH_FILE` stamps both, written when either succeeded. `kempt check --refresh`
overrides the interval only.

- The dnf fetch goes through the root helper (`priv_refresh`), because it fills root's cache,
  which the update uses.
- The flatpak fetch runs as the user. One fetch serves the app and runtime queries.
- Each fetch logs its own result, and one failing does not stop the other.
- The event log records a skip at most once a day, through `$REFRESH_SKIP_FILE`.
- A cache nothing has filled makes the backend report `stale`. The first check fills it, because
  a box with no `$LAST_REFRESH_FILE` passes the interval gate.

## The privileged boundary

There are two root helpers, one per polkit action, because polkit's `auth_admin_keep` caches per
action. A cheap verb must never share an action with a dangerous one.

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
| `tailExecutor` | `main.qml` | `tail -n 25` of the run log, every 2s while the widget shows it | The queue is first in, first out. Behind a two-minute check, tails would pile up ahead of every button press. |
| `promptExecutor` | `main.qml` | the restart prompt, and nothing else | `dbus-send` takes milliseconds. Behind a check it would sit unsent with nothing on screen. |
| `cfgExecutor` | `configGeneral.qml` | the settings page's reads and writes | The config dialog lives in its own object tree and cannot reach `main.qml`. It must also open while a check runs. |
| `pwExecutor` | `configGeneral.qml` | `enable-passwordless` and `disable-passwordless`, and nothing else | Those two wait on a password dialog, and the page's other work must not wait behind them. |

The rule: a fast, periodic caller must not share a queue with a slow, occasional one. Add another
instance rather than making the queue clever.

**Rebuild Staged Update runs the same command as Install on Next Restart**
(`kempt update --surface=offline`, detached with `setsid`), so there is one staging path to
secure. A rebuild destroys the old transaction at once, and the widget can sit open for an hour. So
`rebuildStaged()` in `main.qml` first rereads `state.json`. It goes ahead only if the banner's
stage (`vm.stagedStagedAt`) is still published and still raises a warning. Otherwise it redraws
the banner and says the staged update changed. During a run it does nothing, like `stageOffline`.

When the 30-second watcher sees `state.json` change after a run, `adoptState()` takes the file at
once. The run has already published the armed stage, and a stale **Update Now** would discard it.

### What the message stack says to a screen reader

Kirigami gives an `InlineMessage` **no accessible name**, so every message in the widget sets
`Accessible.name: text`. That announces nothing without focus. So every announcement in the widget
goes through `announce(sentence, assertive)` in `FullRepresentation.qml`. It calls
`Accessible.announce` (Qt 6.8 and later) and emits `announced(string)`, which tests listen to.
`CompactRepresentation.qml` has its own `announce(sentence)` of the same shape, always polite, for
the panel icon.

| What | Politeness | Why |
| --- | --- | --- |
| `Holding X` / `No longer holding X` | Polite | The outcome of the person's own press. |
| A hold that failed | Assertive | The row now carries an error and the padlock is live again. |
| The staged banner, when its words change while it is visible | Assertive | The machine is saying that what it promised has changed. |
| The post-run line and a failed press | Assertive | The answer the person was waiting for, and the widget may not have focus. |
| The question before session-critical updates | Polite | It answers the click on **Update Now**. It starts `Nothing is installed yet.` and ends with `Install on the next restart, or now?` |
| The Check for Updates answer, `vm.checkAnswerText` | Polite | The person asked. The widget says it while open, the panel icon while closed. |
| The footer, when the box goes stale | Polite | Keyed on the *reason*, so the 30-second clock tick that rewrites "Checked 4 min ago" is silent. Silent while a Check for Updates answer is being said, since that answer carries the same failure. |

Each announcing message keeps a `spoken` string so one change is announced once, and clears it
when hidden. The **Rebuild Staged Update** tooltip names its costs, and `Accessible.description`
is bound to it, because the polkit dialog takes focus at once.

### Where the widget's last-run line comes from

The `Last update 18 min ago · 4 packages` row and the line shown after a run both come from
**`kempt summary --json`**. `Logic.lastRunOf` in `logic.js` parses it into `main.qml`'s `lastRun`.
The widget never parses the human `kempt summary`. The entry's fields are under
[History entries](#history-entries). The widget's use of `in_use` is in `Logic.lastRunSubtitle`.

- **Empty stdout under exit 0 means "no last run"**, and `lastRunOf` answers `null`.
- **It is the newest entry or nothing.** Unlike the human mode, `--json` does not walk back past a
  damaged entry. The post-run line also needs an entry stamped at or after `enterUpdating()` ran
  (`Logic.runFinishedSince`).
- **Every field tolerates absence**, because entries outlive the build that wrote them. The
  exception is `status`: unreadable counts as failed.
- **While the post-run line is up, the persistent row is hidden.**

### Where the widget lives

Three settings put Kempt in the system tray, and each fails silently when wrong:

- `"X-Plasma-NotificationAreaCategory": "SystemServices"` at the **top level** of
  `plasmoid/metadata.json`, outside `KPlugin`. Plasma 6.7's tray reads this key only there.
- `"X-Plasma-NotificationArea": "true"`, also top level. Plasma 6.7 ignores it, but shipped
  tray applets still carry it, so Kempt does too.
- `Plasmoid.status = ActiveStatus` in `main.qml`. Without it the tray hides the entry on "Auto".
  It is assigned in `Component.onCompleted`, because the QML probes cannot satisfy a binding.

`KPlugin.EnabledByDefault: true` makes it appear unasked. The compact representation's
`Layout.minimumWidth/Height` follow the shell's `DefaultCompactRepresentation.qml`.
`Logic.resolveIconSize` falls back to automatic when a chosen size does not fit the tray cell.

### Why the widget is testable at all

`logic.js` holds every derivation (badge, icon state, tooltip, widget rows, watcher comparison,
icon size) in engine-agnostic JavaScript, which node runs in `tests/test_widget_logic.sh`. The
remaining QML is bindings, which the probes in `tests/qml/` execute against a stubbed `kempt`.
[tests/README.md](../tests/README.md) says how to run both.

## Adding a backend for your distro

A backend is one new file, one new verb in the apply helper if it needs root, fixtures, tests, and
the wiring listed in step 2b.

### 1. Write `backends/<name>.sh`

Two required functions plus the pure parser they share. Model it on `backends/dnf.sh`, the shorter
of the two shipped backends.

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
- **Capture the parser's status before cleanup.** An `rm -f` after the parse returns 0, and a
  failed parse then looks like "nothing pending".
- **Collapse, always, behind `sort_name_version`.** `tsv_diff_updates` rejects repeated names. Put
  the shared sort where every branch of the function passes through it, because consumers read the
  last version in a set as the newest.
- **Add no locale handling.** `lib/common.sh` pins `LC_ALL=C.UTF-8` for everything.
- **Guard the not-installed case.** A pending package with no installed row must come out as
  `from: "?"`, never an empty string. GNU `join -a1 -e '?' -o ...` does that. jq's `//` does not
  catch empty strings.
- **Sizes are optional, and partial sizes are worse than none.** If the metadata has download
  sizes, emit `name<TAB>bytes`, as `flatpak_check` and `dnf_sizes` do. `cmd_check` then prices the
  backend. A backend with no sizes is fine. A total that covers only some items is wrong.
- **A network fetch belongs in `maybe_refresh_metadata`, not in your check.** Add a
  `<backend>_refresh` and another arm to that gate, as `flatpak_refresh` does. It then follows the
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
| `maybe_refresh_metadata` (`lib/common.sh`) | `include_flatpak` and `flatpak_refresh`, by name | Its own arm and enable gate, if the backend needs a network fetch. Without it the backend answers from whatever its cache holds. |
| `assemble_state` (`lib/common.sh`) | Items arrive **positionally** (`$1` dnf, `$2` flatpak), and the jq body writes `backends: {dnf, flatpak}` | A **signature change**, so every caller changes. This is the one edit here that is not additive. |
| `cmd_update` | Before and after snapshots, the `apply_with_retry` runner and its arguments, per-backend status, held lists, and the history entry's `backends` object | The same set again, plus a runner: the verb from step 2 behind `priv_apply`, or the backend's own apply function. |
| `dnf_reboot_needed` in `cmd_update` and `cmd_check` | Called whatever backends ran | Nothing today. If dnf ever gets an `include_<name>` gate, these calls go behind it. |
| `render_summary` (`lib/common.sh`) | `.backends.dnf` and `.backends.flatpak` by name, with the labels "System (dnf)" and "Apps (flatpak)" | A new line, or a rewrite over `.backends \| to_entries`. |
| `harvest_offline` | Writes a history entry with both backend keys hardcoded | The new key. |
| `cmd_hold` / `cmd_unhold` | `[[ "$b" == dnf \|\| "$b" == flatpak ]]`, and the message that names both | The whitelist. Without it, `kempt hold apt:foo` exits 2. |
| `cmd_doctor` | The per-tool checks (flatpak's command and dnf's, each read from its own seam) and the checkout file list | A tool check, so a missing package manager is reported instead of showing as a permanently stale backend. |
| `kempt_default` and `KEMPT_CONFIG_KEYS` (`lib/common.sh`) | `include_flatpak` (and `auto_accept`) default to `true`, and both are known keys | A default for `include_<name>`, or the backend is off wherever the config file never names it. The key in `KEMPT_CONFIG_KEYS`, so `config set` does not warn. |
| `docs/architecture.md`, `docs/configuration.md` | The state schema example and the `include_flatpak` key | A schema entry (additive, still schema 1) and an enable key with the same meaning. |
| **Optional:** `cmd_update`'s option loop and `usage` (`bin/kempt`) | `--no-flatpak`, and its line in `usage` | A `--no-<name>` override and its usage line. Without it the backend can be switched off only in config. |
| `SECTION_TITLES` and `BACKEND_ORDER` (`plasmoid/contents/ui/logic.js`) | `{dnf: "System (dnf)", flatpak: "Apps (flatpak)"}`, and the order the widget lists them in | A title and a place in the order. Without them the section heading reads `apt`. |
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

[tests/README.md](../tests/README.md#writing-a-test-file) explains `sandbox` and the assertions.
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
destructive paths without running them. "Stubbed" below means `tests/lib.sh` points the seam at a
missing path, unless the row says otherwise.

| Variable | Default | Used for |
| --- | --- | --- |
| `KEMPT_ROOT` | the directory above `lib/common.sh` | Where the CLI reads `VERSION`, `backends/` and the rules template. `kempt doctor` calls it a checkout when `install.sh` is in it. With no `VERSION`, `kempt --version` answers `kempt unknown` |
| `KEMPT_ALLOW_ROOT` | unset | `1` lets every command run as root. Unset, only help, the version and `discover-notifier status` do, and the rest exit 8. `tests/lib.sh` sets it only when the suite itself runs as root |
| `KEMPT_CONFIG_DIR`, `KEMPT_STATE_DIR` | `~/.config/kempt`, `~/.local/state/kempt` | Redirect config and state |
| `KEMPT_PKEXEC` | `pkexec` | Set empty to call a helper directly (tests) |
| `KEMPT_REFRESH_HELPER`, `KEMPT_APPLY_HELPER` | the matching `*_HELPER_PATH` | Point at stub helpers |
| `KEMPT_REFRESH_HELPER_PATH`, `KEMPT_APPLY_HELPER_PATH` | `/usr/local/libexec/kempt-{refresh,apply}` | The paths polkit's `exec.path` pins. `kempt doctor` checks root:root 0755 only when the helper seam equals this one. Compared, never run |
| `KEMPT_DNF_CMD`, `KEMPT_DNF_INSTALLED_CMD` | `dnf5`, (rpm query) | Replace the dnf commands |
| `KEMPT_DNF_SIZES_CMD` | (empty, so the `dnf_sizes` query in [the network boundary](#the-network-boundary)) | The download-size query, apart from `KEMPT_DNF_CMD`, which tests point at a `needs-restarting` stub. Stubbed |
| `KEMPT_DNF_SYSTEM_CACHE` | `/var/cache/libdnf5` | The cache `dnf_sizes` reads, so sizes come from the check's metadata. When unreadable, the query drops the `--setopt`. Point it at a missing directory to test that |
| `KEMPT_FLATPAK_REMOTE_CMD`, `KEMPT_FLATPAK_LIST_CMD` | `flatpak remote-ls --cached/list --system --app ...` | Replace the flatpak commands. The remote query is cache-only (see [the network boundary](#the-network-boundary)) |
| `KEMPT_FLATPAK_REMOTE_RUNTIME_CMD`, `KEMPT_FLATPAK_LIST_RUNTIME_CMD` | the two queries above with `--runtime` in place of `--app`, and `branch` added to the columns | The runtime queries. `tests/lib.sh` pins both at `true` (no runtimes), because a missing path would fail every flatpak check |
| `KEMPT_FLATPAK_SNAP_CMD`, `KEMPT_FLATPAK_SNAP_RUNTIME_CMD` | the two list queries above with `active` added to the columns | The run's before and after snapshots. Many runtimes have no useful version, so the deployed commit is included. `tests/lib.sh` pins both at `true` |
| `KEMPT_FLATPAK_APP_RUNTIME_CMD`, `KEMPT_FLATPAK_INFO_CMD` | `flatpak list --system --app --columns=application,name,runtime`, `flatpak info --system` | The end-of-life lookups, run only after an end-of-life notice. A failure loses the note, not the run. `tests/lib.sh` pins both at `true` |
| `KEMPT_FLATPAK_REFRESH_CMD` | the app remote query **minus** `--cached` | The flatpak half of `maybe_refresh_metadata`. Runs as the user, never through `pkexec`. Stubbed, so no test fetches from flathub |
| `KEMPT_FLATPAK_UPDATE_CMD` | `flatpak update --system` | The flatpak apply (`flatpak_apply`), run as the user. Stubbed, so the suite cannot update the host |
| `KEMPT_FLATPAK_USER_DIR` | `$FLATPAK_USER_DIR`, else `$XDG_DATA_HOME/flatpak`, else `~/.local/share/flatpak` | The per-user installation, used only when `repo/config` exists. Skipped as root, under `sudo` or under `pkexec`. A failed per-user read drops only the per-user side. Stubbed |
| `KEMPT_FLATPAK_USER_SKIP` | (empty) | Any value makes the rest of a run leave the per-user installation alone. `kempt update` sets it when that set could not be read before the run |
| `KEMPT_FLATPAK_USER_REMOTE_CMD`, `KEMPT_FLATPAK_USER_LIST_CMD`, `KEMPT_FLATPAK_USER_REMOTE_RUNTIME_CMD`, `KEMPT_FLATPAK_USER_LIST_RUNTIME_CMD`, `KEMPT_FLATPAK_USER_SNAP_CMD`, `KEMPT_FLATPAK_USER_SNAP_RUNTIME_CMD`, `KEMPT_FLATPAK_USER_APP_RUNTIME_CMD`, `KEMPT_FLATPAK_USER_INFO_CMD` | each system command above with `--user` in place of `--system` | The per-user queries, run as the user. `tests/lib.sh` pins them at `true` |
| `KEMPT_FLATPAK_USER_REFRESH_CMD`, `KEMPT_FLATPAK_USER_UPDATE_CMD` | the user remote query minus `--cached`, `flatpak update --user` | The per-user fetch and apply, run as the user. The apply runs after the system one. Stubbed |
| `KEMPT_FLATPAK_UNUSED_CMD` | `libexec/kempt-flatpak-unused` in `KEMPT_ROOT` | Lists unused Flatpak refs as JSON, run as the user. Stubbed |
| `KEMPT_DU_CMD` | `du` | Sizes the unused runtimes in one `du -sb` call, used directories first, so shared files are not counted. Stubbed |
| `KEMPT_FLATPAK_UNINSTALL_CMD` | `flatpak uninstall --system --no-related --noninteractive` | The removal, run as the user once per pass, with the offered refs appended. Its first word also tells whether Flatpak is installed, so the stub turns the feature off |
| `KEMPT_PKCHECK` | `pkcheck` | Asks polkit, without a dialog, whether this process may remove runtimes. A no, no answer in time, or no `pkcheck` means no removal. Stubbed |
| `KEMPT_RECLAIM_PKCHECK_TIMEOUT` | `10` | Seconds that question may take. No answer in time is a no. A value outside 1 to 10 is 10, since the widget's wait is sized on it |
| `KEMPT_GETENT_CMD` | `getent passwd` | Counts local login accounts, under a 5-second limit. More than one, or a failed lookup, makes `reclaim=automatic` act as `ask`. Stubbed |
| `KEMPT_NSSWITCH_FILE`, `KEMPT_HOME_ROOTS` | `/etc/nsswitch.conf`, `/home /var/home` | The other two account signals: a network source (`sss`, `ldap`, `winbind`, `nis`) on the `passwd` line, and Flatpak data in more than one home. Either makes `reclaim=automatic` act as `ask`. Stubbed |
| `KEMPT_SSSD_DIR`, `KEMPT_SMB_CONF`, `KEMPT_SYSTEMCTL_CMD` | `/etc/sssd`, `/etc/samba/smb.conf`, `systemctl` | Whether `sss` or `winbind` on that line counts. `sss` counts with an sssd `[domain/...]` section. If `/etc/sssd` is unreadable, it counts unless systemd says sssd is down and found no config. `winbind` counts with `security = ads` or `domain`. Any unreadable config counts. `ldap` and `nis` count from the line alone. Stubbed |
| `KEMPT_NOTIFY`, `KEMPT_TERMINAL` | `notify-send`, `konsole` | Notifications and the terminal surface |
| `KEMPT_RISKY_RE`, `KEMPT_BOOT_ID` | (empty) | Override the session-critical pattern and the boot session |
| `KEMPT_SKIP_REFRESH`, `KEMPT_RETRY_DELAY` | (unset), `10` | Deterministic checks and fast retry tests |
| `KEMPT_VIA` | (unset) | The event log's `via` column: `widget` when set to that, `cli` otherwise. Read only by `log_event` |
| `KEMPT_ASSUME_TTY`, `KEMPT_LIVE_OUTPUT` | (unset) | Drive the interactive prompt path from a script |
| `KEMPT_RULES_DST` | (unset, so `/etc/polkit-1/rules.d/49-kempt.rules`) | Passwordless rule destination, for tests. Honoured only when `KEMPT_PKEXEC` is empty and the CLI is not root, and it must be an absolute `*.rules` path. Set in a pkexec or root run, it is refused with exit 2 |
| `KEMPT_POLICY_FILE` | `/usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy` | Where `kempt doctor` reads each action's `exec.path`, to compare with the helper path the CLI uses |
| `KEMPT_PLASMOID_DIR` | `~/.local/share/plasma/plasmoids/io.github.erez_c137.kempt` | The user's copy of the widget, read by `kempt doctor`. A checkout install diffs it against `plasmoid/`. On a packaged install it is a FAIL, because Plasma prefers a user copy over `/usr/share` |
| `KEMPT_UI_DIR` | the checkout's `plasmoid/contents/ui` | Which copy of the QML the probes under `tests/qml/` run. The release check points it at the packaged copy. Read by the test harness only |
| `KEMPT_REFRESH_TIMEOUT` | `120` | Seconds the Flatpak fetch, or an authentication dialog nobody answers, may take before the check gives up on it. `kempt-refresh` stops `dnf5 makecache` itself after 120 seconds, a limit fixed in the helper |
| `KEMPT_CHECK_LOCK_WAIT` | `60` | Seconds a check waits for `check.lock` before serving the previous state instead |
| `KEMPT_RUN_START_WAIT` | `5` | Seconds `kempt run` waits for the terminal window to start the update before it reports that it did not start (exit 5). A launcher that exits with an error is reported at once |
| `KEMPT_CLOSING_CHECK_MARK` | unset | Set by the terminal window around `kempt update`. The update creates this file after its closing check, so the window does not check a second time |
| `KEMPT_SYSTEM_PLASMOID_DIR` | `/usr/share/plasma/plasmoids/io.github.erez_c137.kempt` | Where the package puts the widget. Read only by `kempt doctor` on a packaged install, to say whether `kempt-plasmoid` is missing. Stubbed |
| `KEMPT_WIDGET_PATH` | `~/.local/bin:$PATH` | The `PATH` the widget's command line builds. `kempt doctor` resolves `kempt` through it to report which CLI the widget would run. Never executed. `tests/lib.sh` points it at a directory with no `kempt` |
| `KEMPT_OFFLINE_TOML` | `/usr/lib/sysimage/libdnf5/offline/offline-transaction-state.toml` | dnf5's record of a staged transaction. Never written. `tests/lib.sh` pins it at a `ready` fixture. `kempt-apply` honours this variable only when not root |
| `KEMPT_OFFLINE_TXJSON` | `/usr/lib/sysimage/libdnf5/offline/transaction.json` | dnf5's stored transaction, the package set a restart will install. Read live, never written. `tests/lib.sh` pins it at a recorded transaction. Point it at anything unparsable to test the fallback |
| `KEMPT_DNF_HISTORY_CMD` | `dnf5` | Answers `history list --json` and `history info <id> --json`, run as the user to find [which transaction ran](#which-transaction-ran). Stubbed, so tests take the "cannot tell" branch |
| `KEMPT_XDG_AUTOSTART_DIR` | `/etc/xdg/autostart` | Where `kempt doctor`, `kempt check` and `kempt discover-notifier` look for Discover's update notifier. Never written. Stubbed |
| `KEMPT_DISCOVER_PGREP`, `KEMPT_DISCOVER_PKILL` | `pgrep`, `pkill` | How `kempt discover-notifier` finds and stops this user's running notifier. `tests/lib.sh` points both at `false` |
| `KEMPT_DISCOVER_START` | `kstart` | What `kempt discover-notifier on` starts the notifier with, as `--application org.kde.discover.notifier`, detached. `on` waits up to `KEMPT_DISCOVER_START_POLLS` tenths of a second (default 30) for pgrep to find it. Stubbed |
| `KEMPT_DISCOVER_BIN` | `/usr/libexec/DiscoverNotifier` | Started directly, detached, when there is no `kstart` or it started nothing. Also the start of the command line pgrep and pkill match. Stubbed |
| `KEMPT_DISCOVER_UPDATES_CONF` | `~/.config/PlasmaDiscoverUpdates` | Discover's update settings. `kempt doctor` reads `UseUnattendedUpdates` under `[Global]` as text. Never written. `tests/lib.sh` points it at a missing file |
| `KEMPT_DISCOVER_UPDATES_SYSCONF` | `/etc/xdg/PlasmaDiscoverUpdates` | The system default for the same setting. The user's file overrides it unless a `[$i]` marker locks the key, `[Global]` or the whole file. Never written. `tests/lib.sh` points it at a missing file |
| `KEMPT_OSTREE_MARKER` | `/run/ostree-booted` | Marks an image-based system. Read by `kempt update` (aborts in pre-flight), `kempt check` (publishes `image_based`) and `kempt doctor`. Stubbed |
| `KEMPT_OFFLINE_LINK` | `/system-update` | The symlink `dnf5 offline reboot` creates. Never written or followed: its presence and its text decide whether it is dnf5's. Stubbed |
| `KEMPT_OFFLINE_DATADIR` | `/usr/lib/sysimage/libdnf5/offline` | Where dnf5 points `/system-update`. A symlink pointing anywhere else is another updater's, so dnf5's transaction is not armed. `libexec/kempt-apply` reads this and `KEMPT_OFFLINE_LINK` only when not root. `tests/lib.sh` points it at the test directory |
| `KEMPT_DNF_CACHE_DIR` | `/var/cache/libdnf5` | dnf5's system cache. `kempt doctor` warns when a file in it is world-writable. `tests/lib.sh` points it at a path that does not exist |
| `KEMPT_DNF_SYSIMAGE_DIR` | `/usr/lib/sysimage/libdnf5` | dnf5's system state. Checked by `kempt doctor` like the cache. `tests/lib.sh` points it at a path that does not exist |
| `KEMPT_DNF_CONF` | `/etc/dnf/dnf.conf` | Read for `installonlypkgs`, so an old kernel that is still installed does not count against a stage another updater installed. Points at a missing file in the tests |
| `KEMPT_RPM_INSTALLONLY_CMD` | (unset: `rpm -q --whatprovides` for `installonlypkg(kernel)` and `installonlypkg(kernel-module)`) | Lists the installed installonly names, kmod and akmod builds included. With no names, a fixed list of kernel families stands in. Stubbed |
| `KEMPT_RPM_QA_CMD` | (unset: `rpm -qa` with an epoch-always query format) | Lists installed packages as `name-epoch:version-release.arch`, to tell whether every staged package is installed. Stubbed |
| `KEMPT_APPLY_ECHO`, `KEMPT_REFRESH_ECHO` | (unset) | Root helpers print the final command instead of running it |
| `KEMPT_DNF5_VERSION` | (the installed `dnf5` package's version) | Whether dnf5 is asked for JSON: `check-update --json` from 5.4.0, `needs-restarting --json` from 5.4.1. `tests/lib.sh` pins Fedora 43's 5.2.18.0 |
| `KEMPT_KPACKAGETOOL` | `kpackagetool6` | The tool `install.sh` installs and removes the widget with. It goes through the same `run` seam as the privileged commands, so `KEMPT_INSTALL_ECHO` prints it |
| `KEMPT_DBUS_SEND` | `dbus-send` | The `org.kde.KIconLoader.iconChanged` signal `install.sh` sends so plasmashell reloads icons. Best effort. `tests/lib.sh` points it at `true` |
| `KEMPT_INSTALL_ECHO` | (unset) | `install.sh` prints its privileged commands instead of running them. `=fail` also makes them report failure. Unprivileged symlinks are still created, so use a scratch `HOME` for a fully inert dry run. The notifier question's `kempt discover-notifier off` is printed too |
| `KEMPT_INSTALL_CONFIG_HOME` | (unset) | With `KEMPT_INSTALL_ECHO`, the directory the notifier commands run in. Their autostart entry, config and state stay inside it. Without it, the question's command is printed |

`KEMPT_APPLY_ECHO`, `KEMPT_REFRESH_ECHO` and `KEMPT_DNF5_VERSION` are for tests only. They cannot reach a real
privileged run, because pkexec clears the caller's environment. `KEMPT_INSTALL_ECHO` runs on the
user's side and can only stop `install.sh` from running privileged commands.

## Known v1 decisions

- **dnf5's output is read as JSON where dnf5 prints it** (from 5.4.0 for `check-update`, 5.4.1 for
  `needs-restarting`). The text parsers go when Fedora 43 reaches end of life. The parser tells the
  formats apart by content, so a helper and a CLI of different versions still agree.
- **Flatpak covers both installations.** Every flatpak command names `--system` or `--user`, and
  each system command has a user twin. Per-user rows are keyed `user:<id>` in the snapshot and size
  lists, since a Flatpak id cannot hold a colon. Reclaim stays system only.
- **Flatpak needs no Kempt polkit action.** flatpak's own policy grants `app-update` and
  `runtime-update` to an active local session. The exceptions are in
  [security.md](security.md#accepted-limitations).
- **Flatpak runtimes are counted, and cannot be held** (exit 2). Apps share runtimes, so a held one
  breaks the next app that needs it.
- **The package build rewrites two files.** pkexec matches the helper by the path the polkit
  action pins. So `kempt.spec`'s `%prep` replaces `/usr/local/libexec` with the FHS libexec
  directory in `polkit/io.github.erez_c137.kempt.policy` and `lib/common.sh`. Its check stage runs
  the suite on a pristine copy.
