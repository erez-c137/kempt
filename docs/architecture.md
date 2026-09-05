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
   |-- backends/flatpak.sh           same shape - and it applies its own updates, as you
   |  (privilege boundary: one pkexec per polkit action - dnf only)
   v
  libexec/kempt-refresh  (root)     metadata only, no dialog
  libexec/kempt-apply    (root)     the dnf upgrade verbs, one auth per run
```

The rule that shapes everything: **the badge count must come from the same command path that
performs the update**. A front end that disagrees with the CLI is the defining complaint about
every tool in this space, so `kempt check` reads the root metadata cache the update itself will
use, applies the same holds, and runs the same backends.

## Why bash

The recurring question, answered once. The engine is bash on purpose, not by inertia:

- **The job is the shell's native job.** Everything Kempt does is run other CLIs - dnf5,
  flatpak, pkexec, notify-send - and parse what they print. In bash, the command Kempt runs
  is literally the command you would type; there is no binding layer where behavior can hide.
- **The privileged surface must be auditable in one sitting.** The two root helpers are short
  argument-validating scripts. Any sysadmin can read every line that will ever run as root
  before granting it, with no toolchain and no trust placed in a build.
- **Zero runtime dependencies, zero build step.** bash and jq are on every Fedora install
  already. A system updater with a heavy runtime is a thing that breaks when the system it
  updates does; a script can be read, patched and rerun in place on the machine it broke on.

The costs are just as real, and they are paid deliberately rather than denied:

- Bash at this scale needs discipline, so the discipline is structural: every impure command
  goes through an [environment seam](#environment-seams), the suite's assertions run with no
  package manager present, shellcheck gates CI, and the helpers validate their arguments.
- Parsing text output is fragile, so the parsers are pure functions tested against recorded
  fixtures, and the roadmap's `dnf5 check-update --json` migration retires that bug class by
  construction when it lands.
- If the project ever outgrows the shell, the boundary is already drawn: the widget speaks to
  a CLI contract and a state-file schema, not to bash. An engine in another language slots in
  behind both without the front end noticing.

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
not of one package manager. The command it runs is `dnf5 -C --disablerepo='*' needs-restarting`:
cache-only so it never touches the network or waits on stdin, and every repo disabled because the
answer is purely local (rpm install times against boot time) and needs no repo metadata at all.
Without the second flag, a box whose user cache has never been filled - the default, since
`kempt-refresh` fills root's cache - gets an error and exit 1 on every check, which by exit code
alone reads as "a restart is owed", forever. So "a restart is owed" requires the package list on
stdout as well; anything else warns on stderr and answers `false`, which throughout Kempt means
"nothing to say" rather than "no restart needed". On a box without dnf5 the same path degrades
rather than failing the run: the command errors and the function answers `false`. That is the
one part of this contract that is still honestly dnf-shaped; a per-backend reboot verdict is v2
work, and a new backend does not implement one today.

Two things the spec lists as backend responsibilities are deliberately **not** per-backend in the
build:

- **update** is `libexec/kempt-apply` plus the wiring in `cmd_update`, because applying dnf
  updates is the privileged half and must stay in one audited place. The Flatpak apply is the
  exception that proves the rule: it needs no root, so it stayed in its backend as
  `flatpak_apply` and never enters the helper at all.
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
| `~/.local/state/kempt/offline_staged.json` | Kempt's half of a staged transaction: when, how many, the boot and package set it was staged against, and which packages went in and were left out, mode 0600 | Consumed by the harvest, or cleared when the transaction under it has gone |
| `~/.local/state/kempt/{lock,check.lock,writer.lock,last_refresh}` | flock targets and the refresh timestamp | Never; they are empty files |

Three of those files are locks. `lock` and `check.lock` serialize runs and checks; `writer.lock`
serializes the three commands that rewrite the two files in the config directory - `kempt config
set`, `kempt hold` and `kempt unhold`. Each of them reads the whole file, changes one line and
writes it back, so without a lock two running together lose one of the two writes: measured on
the old code, 40 concurrent `config set` commands kept 4 keys and 40 `unhold` commands removed 4
holds. The lock lives in the state directory because the config directory is the user's. Readers
take no lock at all and must not start: `atomic_write` renames into place, so a reader already
sees the whole old file or the whole new one.

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
      "actionable": 7,
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
| `backends.<name>.items[].size_bytes` | integer, optional | Bytes this item would download, summed over every architecture of that name (multilib twins are both fetched). **Absent means not known, never zero.** Additive key: readers must tolerate its absence. |
| `backends.<name>.download_bytes` | integer, optional | Bytes this backend would download. Written **only when every non-held item in it has a `size_bytes`** - partial coverage omits the key rather than publishing a total that is quietly short. Additive key. |
| `download_bytes` | integer, optional | The sum of the per-backend keys, omitted if any **enabled** backend omitted its own. A backend switched off contributes nothing and does not suppress it. Additive key. |
| `reboot_needed` | boolean | Whether a restart is owed **right now**, asked fresh on every check (`dnf5 -C --disablerepo='*' needs-restarting`, local facts only). Not the same question as the `reboot_needed` in a history entry, which records whether one was owed when that run finished. Additive key: readers must tolerate its absence in files written by older builds. `false` means **nothing to say**, never "no restart needed" - render no affirmative line from it. The underlying check answers `false` whenever it could not work the answer out, and it has a failure mode that proves the point: on a cold user cache it exits 1 having printed nothing at all, which is a failure to compute a verdict rather than a verdict. |

| `offline_staged` | object, optional | Present **only** while an offline transaction is staged by Kempt **and** dnf5 reports it armed (`status = "ready"`). `staged_at` is when it was staged, `count` is how many updates it covers (`null` for a marker written before the count was recorded, never a guess), `armed` is always `true` - the key's absence is how "not armed" is expressed. A staged transaction whose status is anything else is a discrepancy for `kempt doctor`, not a pending install, and must never be published here. Additive key. |
| `offline_staged.holds_conflict` | array of strings | dnf package names that are in the staged transaction **and** currently held - the packages a restart will install despite the hold, because dnf5 built that transaction before the hold existed and offers no way to edit a stored one. Sorted, unique, dnf only (a flatpak hold cannot reach an offline transaction). Read it together with `names_source`: an empty array is only a claim when that field says so. Present only inside `offline_staged`; additive, and readers must tolerate its absence in files written by older builds. |
| `offline_staged.names_source` | `"transaction"`, `"marker"` or `"none"` | Which list `holds_conflict` was computed from, and therefore what an EMPTY list means. `transaction`: dnf5's own stored transaction was read live - empty means **no conflict**. `marker`: that read failed and the marker's own list was used, which was itself transaction-derived - empty still means no conflict. `none`: nothing may be denied - a marker written before names were recorded, or one whose names came only from a check, which cannot see the packages the resolver added. Under `none` an empty list means **cannot tell**, and a surface that renders it as "no conflict" is making a claim the data does not support. Present only inside `offline_staged`; additive. |

The download figure is **an estimate, and it is wrong in both directions.** State it with a "~"
and never with "up to", which would claim a ceiling it does not have:

- **It excludes held items.** Kempt passes `--exclude=` for them, so their bytes are never
  fetched - but it also means the figure is not "what is pending", it is "what a run would fetch".
- **It omits dependencies.** `dnf5 repoquery --upgrades` lists the packages being upgraded, not
  the new packages a real transaction would pull in alongside them. Only a depsolve knows those,
  and a depsolve is exactly what this feature refuses to run: it can block on the rpm transaction
  lock, which is the failure dnfdragora and Discover both inherit.
- **It ignores Flatpak static deltas.** Flatpak transfers ostree deltas, so the real download is
  routinely a fraction of the published `download-size`. This is the largest single over-count.
  A transaction Kempt has already staged offline is over-counted the same way: it is on disk, and
  repoquery still reports the full size.
- **It reads the system cache, `/var/cache/libdnf5`, not the user's.** The size has to come from
  the same metadata the check was answered from - `kempt check` lists the updates through the root
  helper against that cache, and nothing in Kempt ever fills `~/.cache/libdnf5` - because a user
  cache that has drifted returns no row for a package the check is reporting, and one missing row
  is what makes the coverage rule above drop the figure entirely. Where the system cache is
  unreadable the query falls back to whatever dnf5 gives the user, and partial coverage stays
  hidden exactly as it is anywhere else.

Two rules for anything that reads this file:

1. **Empty stdout from `kempt check` with exit 0 means "no data, keep the last known state"**,
   never "zero updates". It happens when another check holds the lock and there is no valid
   previous state to serve.
2. `status: "stale"` is not an error state to alarm the user with. The counts are still the best
   known truth; surface the staleness in a tooltip, not a warning icon.

A new backend adds a key under `backends` and stays schema 1: existing readers ignore what they
do not know, and the totals keep working.

## The offline transaction, end to end

The one flow in Kempt whose state lives in **two** files owned by two different programs, and the
one that was broken from the start because only half of it was being written.

**Staging.** `kempt update --surface=offline` runs a fresh check first, so the count it records is
the one that describes the transaction it is about to build rather than the last check's; a check
that cannot answer warns and the stage proceeds on the stale figure. Then two privileged calls
inside one authentication: `dnf-offline-stage` (`dnf5 upgrade --offline`) downloads the transaction, and
`dnf-offline-arm` (`env DNF_SYSTEM_UPGRADE_NO_REBOOT=1 dnf5 offline reboot -y`) arms it. Only the
second creates `/system-update`, and that symlink is the entire mechanism: systemd's
`system-update-generator` looks for it at boot and nothing else does. Staging without arming
leaves the transaction at `status = "download-complete"`, which installs on no restart, ever -
which is exactly what shipped first, and what the whole of this section exists to prevent
recurring. `DNF_SYSTEM_UPGRADE_NO_REBOOT` is the documented way to arm without rebooting
(dnf5-offline(8)); without it, arming reboots the box on the spot.

An arm that fails fails the run: the stage is discarded with `dnf-offline-clean` and **no marker
is written**. The marker is a promise, and there is nothing left to promise.

**A rebuild forfeits what it replaces.** Staging over an existing transaction is cancel-then-stage
in dnf5: the old transaction is destroyed as the new one BEGINS, not swapped for it at the end
(container-verified). So asking for a rebuild converts "the old staged update is still armed" from
an end state into a forfeited one, and every failure path has to land somewhere honest. There are
three end states, and the offline branch of `cmd_update` is written to reach one of them:

1. **New transaction armed, marker rewritten.** The ordinary case. `offline restage` records that
   there was an old one and which holds it conflicted with - a question that cannot be asked after
   the stage, because the transaction that contained the held package is gone.
2. **Nothing staged, marker cleared, the user told.** The stage or the arm failed and
   `dnf-offline-clean` succeeded. The run fails with a reason naming what was lost, and the marker
   and its snapshot copy go with the transaction they described: a marker outliving its transaction
   is a promise to the harvest, the doctor and the popup that no restart can keep.
3. **The cleanup failed too.** Reachable only through a double failure. The toml and the boot
   symlink now disagree and only root can settle it, so the command that settles it travels on the
   failure notification as well as on stderr - stderr is nobody's surface when the run came from a
   panel - and the marker is deliberately KEPT. Doctor's staged row and its boot-symlink row then
   say two different true things about the box and name the one remedy between them.

Whether a transaction existed before the attempt is read from two places, either of which is
enough: Kempt's marker, and dnf5's own status. The second is what covers a transaction Kempt did
not stage, which a re-stage destroys identically.

**The three files.**

| File | Owner | Says |
| --- | --- | --- |
| `~/.local/state/kempt/offline_staged.json` | Kempt | A stage was made: when, how many updates, the boot session, the package set it was staged against, and which packages went in and were left out |
| `/usr/lib/sysimage/libdnf5/offline/offline-transaction-state.toml` | dnf5 | Whether the transaction is still there, and whether it is armed (`status = "ready"`) |
| `/usr/lib/sysimage/libdnf5/offline/transaction.json` | dnf5 | What that transaction will actually install, by NEVRA, resolver-added packages included |

None is sufficient. The marker alone cannot tell "waiting for a restart" from "somebody ran
`dnf5 offline clean`". The toml alone cannot tell Kempt's transaction from anyone else's, and
carries no baseline to diff a harvest against. The stored transaction knows the package set exactly
and knows nothing about why a package is absent from it. `offline_system_status()`,
`offline_marker_read()`, `offline_txjson_names()` and `offline_staged_state()` in `lib/common.sh`
are the only readers.

**The marker's fields, and the rule for adding one.** The marker is `{staged_at, pre_snapshot,
boot_id, staged, armed}` plus, since the staged set was recorded, `staged_names`,
`staged_names_source` and `staged_excluded`. Every field is **additive**: a marker written by an
older build carries none of the newer ones, and every reader has to go on working against it - the
harvest, the doctor, the popup and the two hold commands all do. That is why a fact Kempt could not
establish is expressed by an ABSENT key rather than an empty one: no `staged_names` at all means
"nobody could find out", where `staged_names: []` would read as "the transaction installs nothing".
`staged_names_source` says where the list came from (`transaction`, `check`, or `none`), because a
list derived from a check is allowed to confirm a conflict and is never allowed to deny one.
`armed` is the one field a later run rewrites: reconciliation flips it to `false` when a restart
proved the transaction cannot install (below), and that flip is also the record that this was
already announced.
Every name is filtered through `KEMPT_NAME_RE` as it is written, and one name that fails drops the
whole list - one gate covers jq, the shell, QML and a terminal.

**Configuration changes never rewrite already-created operations: a hold applies from the next
transaction Kempt builds, and a transaction dnf5 has already stored is reported against, never
edited.** dnf5 offers no API to edit a stored transaction, so a hold added after a stage cannot
take the package out of it, and the restart installs it anyway. Policy state and transaction state
have different temporal scopes, and Kempt's answer is to say so rather than to pretend otherwise:
`kempt hold dnf:<name>` records the hold, exits 0, and then prints on stderr whether the armed
stage still contains that package, with the two commands that act on it - rebuild the stage with
your current holds, or remove it. It never prompts, never blocks and never escalates. `kempt
unhold` carries the mirror: the stage was built without this package, so the restart will not
install it. The predicate behind both is a set intersection of the staged names against the dnf
names currently held - never a timestamp comparison, which loses the in-flight-stage race whichever
way round it is written - and it is published in `state.json` as `offline_staged.holds_conflict` so
the widget, which can stat nothing, derives the same answer from the same evidence.

**A marker that will not parse is skipped, never cleared.** `update` and `check` hold different
locks, so a check can read the marker while a stage is writing it. Two things keep that harmless:
the write is atomic and mode 0600 (`write_offline_marker`), so the window holds the old marker
rather than half of the new one; and `offline_marker_read` refuses an empty, unparsable or
over-1 MB file, which every reader treats as "skip this check". Clearing is reserved for a marker
that **parses** over a transaction dnf5 says has gone. The distinction is not academic: a torn read
used to reach the stale-pointer branch below and delete the marker, so one badly timed check made
Kempt disown a transaction that was still going to install on the next restart.

**Applying.** Any restart runs it - the popup's button, the K menu, `reboot`. Kempt never
restarts anything itself.

**Harvesting.** The next `kempt check` reconciles, inside the check lock, before anything reads
the world (`harvest_offline`):

| Marker | dnf5 status | Boot | Package set | Outcome |
| --- | --- | --- | --- | --- |
| yes | ready / any non-absent | same as staged | - | Still pending. Nothing happens |
| yes | absent | same as staged | - | The transaction was thrown away. Clear the marker, `offline marker cleared (stage gone)` |
| yes | absent | different | unchanged | The transaction was thrown away. Clear the marker - this used to be a permanent dead end, waiting forever for an apply that had already been discarded |
| yes | ready | different | unchanged | Still pending: the restart declined the offline update, or it is queued for the next one |
| yes | present, not `ready` | different | unchanged | **Detour boot.** Announce once, demote the marker to `armed: false`, never clear |
| yes | any | different | changed | **Harvested**: one history entry, surface `offline (applied on reboot)`, diffed against the marker's own snapshot copy |

The boot session is the gate rather than the package set, because "the installed set moved" was
never evidence that the stage applied - a live run, or a manual `dnf install`, moves it too.

**Reconciling a detour boot.** A transaction that is present but not `ready`, across a boot that
changed, with the package set where the stage left it, has one reading: the boot symlink was
standing over a transaction nothing could apply, so the restart went into the offline updater,
installed nothing and came back. That transaction can never install on a later restart either -
only `dnf5 offline reboot` arms one, and nothing is going to run it by itself. Three rules hold
this branch together:

- **Announce once.** The notification and the event line are said exactly once, and the key is the
  marker itself: `armed: false` IS the record that it has been said. A box checking every ten
  minutes would otherwise repeat it 144 times a day about one dead transaction.
- **Never clear.** The marker is what lets `kempt doctor` say *staged update can never install*.
  Without it that row degrades into *an offline transaction is staged outside Kempt*, which
  misattributes Kempt's own stage to somebody else and drops the diagnosis. Clearing stays what it
  always was: for a marker over a transaction dnf5 says has GONE.
- **Never reclassify a same-boot stage.** `download-complete` in the boot that staged it is the
  legitimate transient of a stage still being written - `dnf5 upgrade --offline` sits there for the
  whole download - and a check that fired in that window and called it dead would announce a
  transaction about to be armed perfectly.

The reader that keeps this honest is `offline_staged_state`, which publishes nothing at all unless
dnf5 says `ready`: the popup's staged banner therefore disappears the moment the transaction stops
being armed, and the notification is what stops that disappearance from being the only thing that
happens.

**Superseding.** A staged transaction records the rpm database cookie it was built against, and
dnf5 refuses one whose cookie has moved. So a live `kempt update` that installs anything has
killed the stage, whether or not anyone notices, and an armed dead stage is a failed offline boot
waiting to happen. `cmd_update` therefore discards it (`dnf-offline-clean`), removes the marker
and its snapshot copy, and records `offline stage dropped (superseded by live update)`. Three
conditions gate that: the stage must still be **pending** (its baseline still matches the world
this run started from - an already-applied stage has a harvest owed and must not be dropped), dnf
must have **succeeded**, and the rpm set must actually have **moved**. A Flatpak-only run moves
nothing and leaves the stage alone.

Third-party rpm changes are not chased: dnf5 refuses the stale transaction at boot and the system
boots normally. Documented and accepted.

## The network boundary

The second boundary in Kempt, and the one a user feels first: a laptop on a train should still be
able to answer "what is pending?". So **every check is read-only against a local cache, and every
fetch happens in one place, under one policy.**

| Command | May reach the network |
| --- | --- |
| `dnf5 --cacheonly check-update --quiet` (`kempt-refresh check`) | No |
| `dnf5 -C --disablerepo='*' needs-restarting` (`dnf_reboot_needed`) | No |
| `flatpak remote-ls --updates --system --app --cached ...` (`flatpak_check`) | No |
| `flatpak list --system --app ...` (`flatpak_snapshot`) | No |
| `dnf5 --setopt=cachedir=/var/cache/libdnf5 -C repoquery --upgrades --latest-limit 1` (`dnf_sizes`) | No |
| `dnf5 makecache --refresh` (`kempt-refresh refresh`) | **Yes** |
| `flatpak remote-ls --updates --system --app ...`, no `--cached` (`flatpak_refresh`) | **Yes** |
| `kempt-apply`'s upgrade verbs, and `flatpak update --system` (`flatpak_apply`) | **Yes** - that is what a run is |

Both backends are therefore **refresh-then-read-cache**, and both refreshes are triggered from
`maybe_refresh_metadata` in `lib/common.sh`: at most once every three hours, only on mains power,
only on an unmetered connection, and never in a way that can fail the check that follows. One
interval, one `$LAST_REFRESH_FILE`, one power rule. The marker is stamped when **either** arm
succeeded, because its job is to rate-limit the network step - re-fetching a flatpak summary that
just arrived, because dnf's `makecache` failed, is the failure mode that rule prevents.

The two arms are otherwise independent. The dnf one goes through the root helper (`priv_refresh`)
because it fills root's cache, the one the update will use. The flatpak one runs **as the user**:
the system remote's summary, as an unprivileged user sees it, is cached under that user's own
`~/.cache/flatpak/system-cache/summaries/`, so there is nothing for root to do. Each logs its own
result (`refresh ok` / `refresh failed`, `refresh flatpak ok` / `refresh flatpak failed`), and one
failing never stops the other.

Which command does the Flatpak fetching was settled by measurement, not by the help text. Running
the remote query *without* `--cached` as an ordinary user rewrites
`~/.cache/flatpak/system-cache/summaries/` - the remote's `.idx`, its signature and a fresh
subsummary - in 2.0-2.4 s, and the `--cached` query then answers out of it with the network
blackholed. `flatpak update --appstream` is not the alternative it looks like: it fills the
root-owned `/var/lib/flatpak/appstream` tree, which is not what `--cached` reads, and writing
there needs a polkit action of its own. Measured 2026-08-27, flatpak 1.18.1 on Fedora 44.

What this costs: **a cache nothing has ever filled cannot answer.** `--cached` does not fall back
to the network - not even when the network is right there. With the cache emptied and flathub
reachable it still exits 1 in 40 ms with `No cached summary for remote 'flathub'`, so on a box
whose Flatpak summary has never been fetched the check fails and that backend reports `stale` with
the reason. `dnf5 --cacheonly` behaves identically, and the degrade path is the same one every
backend failure takes. It resolves itself, because `maybe_refresh_metadata` runs *before* the
checks and a box with no `$LAST_REFRESH_FILE` passes the interval gate on its very first check.
Adding a network fallback inside the check would undo the boundary entirely, so there is
deliberately none.

## The privileged boundary

Two root helpers, one per polkit action, because polkit's `auth_admin_keep` caches per action id
and a cheap verb must never share an action with a dangerous one:

- `kempt-refresh` (`io.github.erez_c137.kempt.refresh`, no dialog): `check` and `refresh`, metadata only.
- `kempt-apply` (`io.github.erez_c137.kempt.apply`, one auth per run): `dnf-upgrade`,
  `dnf-offline-stage`, `dnf-offline-arm` and `dnf-offline-clean`. The last two take no arguments
  at all. dnf only - `flatpak update` asks polkit for itself and is granted to an
  active local session with no password, so routing it through this action only added a dialog
  that plain `flatpak update` never raises. Both flatpak arms, the refresh and the apply, now run
  as the user.

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
| `promptExecutor` | `main.qml` | the restart prompt, and nothing else | `dbus-send` returns as soon as KDE has been ASKED to draw its confirmation screen: no lock, no package database, milliseconds. Behind a 120-second check it sat unsent with nothing on screen to say why, which is indistinguishable from a broken button. |
| `cfgExecutor` | `configGeneral.qml` | the settings page's reads and writes | The config dialog is built by the shell in its own object tree and cannot reach `main.qml` at all. Even if it could, a settings dialog that takes two minutes to populate because a check is running is a broken dialog. |

The rule that follows: a new caller that is *fast and periodic* must not share a queue with one
that is *slow and occasional*. Adding a fourth instance is cheaper than making the queue clever.

**Rebuild Staged Update runs the same command as Install on Next Restart**, and that is a design
constraint rather than a convenience. Both are `kempt update --surface=offline`, detached with
`setsid` and never waited on; one polkit action, one dialog, one verb the helper already knows. A
second staging path would have been a second privileged surface to review, and there is nothing
about a rebuild that a stage does not already do - dnf5 replaces a stored transaction by building
a new one.

What the rebuild adds is a **precondition re-verify at click time**. The action is offered by a
banner, and a banner describes one transaction; a popup can sit open for an hour, and in that time
the staged update it names can be applied by a restart, replaced by another stage, or removed by
hand. That matters more than an ordinary stale click because the re-stage is destructive at its
*start*: dnf5 destroys the stored transaction the moment a replacement begins, rather than
swapping at the end. Acting on a stale banner would therefore throw away a staged update the
person never agreed to lose. So `rebuildStaged()` in `main.qml`:

1. captures the `staged_at` the banner was derived from, synchronously, before anything can move
   it (`vm.stagedStagedAt`, published by `logic.js` from `offline_staged.staged_at`);
2. reads the current `state.json` through the executor - a `cat`, not another `kempt check`: the
   file is what `check` publishes, reading it takes no lock, and a check can run for two minutes
   between the click and the action it was meant to authorise;
3. re-derives a view model from those bytes and proceeds only if a staged update is still
   published, its `staged_at` is the one that was on screen, and it would still raise a warning;
4. otherwise runs nothing, assigns the freshly read state so the banner re-draws from the truth,
   and reports `The staged update changed - take another look.` where the press happened.

Consent given to one staged update is never spent on a different one. The same guard `stageOffline`
has applies first: while a run of ours is in flight, a rebuild does nothing at all.

### What the message stack says to a screen reader

Kirigami gives every `InlineMessage` the AlertMessage role and **no accessible name**, so a screen
reader announcing one reads out its icon - "Positive", "Warning" - and nothing about what happened.
Every message in the popup's stack therefore carries `Accessible.name: text`, including the two
that only ever report a failure: a message nobody can hear is a message that is not being shown.

That binding is load-bearing rather than tidy in one place particularly. The staged banner
*changes type* when a hold lands behind a staged update, and the whole point of the change is the
new sentence: for a person who cannot see the colour, a flip that arrived only as a palette change
would be no flip at all. The words are the message; the colour is a second channel for the people
who have it.

The **Rebuild Staged Update** action carries the same discipline one level down. Its tooltip
discloses the two costs - it asks for authorization, and a failed rebuild removes the current
staged update - and `Accessible.description` is bound to that same tooltip, because a polkit dialog
takes the focus the instant the button is pressed. A disclosure that has not been heard by then is
never heard.

### Where the popup's last-run line comes from

The persistent `Last update 18 min ago · 4 packages` row and the transient line the popup shows
right after a run are one fact with one source: **`kempt summary --json`**, parsed by
`Logic.lastRunOf` in `plasmoid/contents/ui/logic.js` and held by `main.qml` as `lastRun`. The CLI
serves the newest history entry byte for byte rather than re-rendering it, so what arrives is
exactly what `cmd_update` wrote: `{timestamp, surface, status, duration_sec, reboot_needed, log,
error, backends: {<name>: {updated, added, removed, status, skipped_held}}}`.

Never the human `kempt summary`. That is a rendering (`render_summary` in `lib/common.sh`) whose
first line is an ISO timestamp, and re-deriving counts from rendered text would put a second,
lossier copy of `render_summary`'s rules inside the widget for the two to drift apart in. The
popup used to paste that first line into its message area after a run - true, and no answer at all
to "what just happened?".

Four properties of that boundary are contracts, not incidentals:

- **Empty stdout under exit 0 means "no last run".** With no history recorded, `summary --json`
  prints nothing rather than an empty object, the same convention `kempt check` keeps for "no
  data". `lastRunOf` answers `null` for it, and every caller renders nothing - never a fabricated
  empty run, because a box that has never updated has not "updated 0 packages".
- **It is the newest entry or nothing - never the one underneath.** `kempt summary` (the human
  mode) walks back past a damaged entry, because a person asked to see the last run they can be
  shown. `--json` does not, because its caller asked about one specific run. A damaged newest
  entry therefore gets the same empty stdout under exit 0, with the warning still on stderr.
  Walking back here is what let the popup announce an older run's counts and duration as the run
  that had just finished, in words no reader could tell from the truth. `main.qml` carries the
  belt to that braces: the transient post-run line is only spoken for an entry stamped at or
  after the moment `enterUpdating()` ran (`Logic.runFinishedSince`), while the persistent
  `Last update` row - which claims nothing about *when* - keeps showing whatever entry there is.
- **Every field tolerates absence.** History entries outlive the build that wrote them (the newest
  50 are kept, and the widget is a COPY that a `git pull` leaves older than the CLI), so an entry
  missing a key this build expects is ordinary rather than corrupt. The one field that is not
  optimistic is `status`: a status that cannot be read counts as a failure, because the two
  mistakes do not cost the same.
- **The entry's `reboot_needed` is a fact about that run**, not about now. The state file's own
  `reboot_needed` is the live answer and the restart message is bound to that one. Rendering the
  history entry's would go on claiming a restart long after the user had performed one.

The display rule on top of it: while the transient post-run line is up, the persistent row is
hidden. One event, one line at a time.

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
  the system Qt 6 (via PySide6's `QQmlComponent`), and `tests/test_widget_qml.sh` runs five
  probes that instantiate the real files against a stubbed `kempt` on a real `PATH` - the settings
  page's apply path, the popup's actions, the state machine, the executor, and the keyboard.
  The last of those is the only one that builds a window: `activeFocus` is a property of a
  scene, so an item with no window never becomes the active focus item and has nowhere for a
  Tab key to be delivered. It uses an offscreen one, and the other four stay windowless on
  purpose, because every assertion in them was written under those conditions.
- Both halves skip LOUDLY rather than failing when node or PySide6 is absent; neither is a
  dependency of Kempt itself.

The suite runs green with no package manager, no polkit and no desktop present, and the two
widget halves carry more than half of its assertions. For the current count, run
`tests/run_tests.sh` - it prints the measured total, and a measured number is the only kind
this project quotes. (Exact totals used to live in this sentence; they drifted within weeks.)

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

### 2. Add a verb to `libexec/kempt-apply` (only if root is really needed)

First ask whether it is needed at all. Flatpak's apply lives in its backend, unprivileged, because
`flatpak update` asks polkit for itself and gets a yes in an active local session; a package
manager that does the same buys nothing by going through the helper and widens the privileged
surface for nothing.

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
**thirteen places, one of them optional**, so nobody has to find it by grep:

| Where | What it names today | What a third backend needs |
| --- | --- | --- |
| `bin/kempt`, the `source` lines at the top | `backends/dnf.sh`, `backends/flatpak.sh` | One more `source` line. Nothing loads a backend file by discovery. |
| `cmd_check` | `dnf_check` / `flatpak_check`, `mark_held`, `state_prev_items`, the `include_flatpak` gate | A call pair, its own enable gate, and its own previous-items fallback for the stale path. |
| `assemble_state` (`lib/common.sh`) | Items arrive **positionally** (`$1` dnf, `$2` flatpak) and the jq body writes `backends: {dnf, flatpak}` | A **signature change**: adding a backend changes the function's parameter list and therefore every caller. This is the one edit here that is not additive. |
| `cmd_update` | Before and after snapshots, the apply runner and its arguments (`apply_with_retry "$log" priv_apply dnf-upgrade ...` for dnf, `apply_with_retry "$log" flatpak_apply ...` for flatpak), per-backend status, held lists, and the history entry's `backends` object | The same set again, plus a runner: the verb from step 2 behind `priv_apply`, or the backend's own apply function when it needs no root. |
| `dnf_reboot_needed` in `cmd_update` | Called unconditionally, whatever backends ran | Nothing, today. It answers for the machine, and degrades to `false` where dnf5 is absent. |
| `dnf_reboot_needed` in `cmd_check` | Called unconditionally too, to write the state file's `reboot_needed` | Nothing, today, and for the same reason. There is no `include_dnf` key to gate it on: `assemble_state` hardcodes `dnf: ($dnf | wrap(true))`, so a gate would be a gate on a constant. **The rule:** the day dnf gains an `include_<name>` gate, this call goes behind it, next to the flatpak one. |
| `render_summary` (`lib/common.sh`) | `.backends.dnf` and `.backends.flatpak` by name, with the labels "System (dnf)" and "Apps (flatpak)" | A new line, or a rewrite over `.backends | to_entries` that would make the renderer generic for good. |
| `harvest_offline` | Writes a history entry with both backend keys hardcoded | The new key, or that entry is missing a backend the readers expect. |
| `cmd_hold` / `cmd_unhold` | `[[ "$b" == dnf \|\| "$b" == flatpak ]]`, and the message that names both | The whitelist. Without it, `kempt hold apt:foo` exits 2 while the backend works fine. |
| `cmd_doctor` | The per-tool checks (flatpak's command and dnf's, each read from its own seam) and the checkout file list | A tool check, so a missing package manager is reported rather than showing up as a permanently stale backend, or as a derived answer that silently stops being derived. |
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
| `KEMPT_DNF_SIZES_CMD` | (empty, so `dnf5 --setopt=cachedir=... -C repoquery --upgrades --latest-limit 1 ...`) | The download-size query. Its own seam rather than a reuse of `KEMPT_DNF_CMD`, which four test files already point at a `needs-restarting` stub. `tests/lib.sh` points it at a path that does not exist, so no test file runs a real repoquery |
| `KEMPT_DNF_SYSTEM_CACHE` | `/var/cache/libdnf5` | The dnf5 metadata cache `dnf_sizes` is pointed at, so a size comes from the same metadata the check did. Read, never run: when it is not readable the query drops the `--setopt` and falls back. Point it at a directory that does not exist to drive that branch |
| `KEMPT_FLATPAK_REMOTE_CMD`, `KEMPT_FLATPAK_LIST_CMD` | `flatpak remote-ls --cached/list --system --app ...` | Replace the flatpak commands. The remote query is cache-only; see [the network boundary](#the-network-boundary) |
| `KEMPT_FLATPAK_REFRESH_CMD` | the remote query **minus** `--cached` | The flatpak half of `maybe_refresh_metadata`, and the only flatpak command that reaches the network to *read*. Runs as the user, never through `pkexec`. `tests/lib.sh` points it at a path that does not exist, so no test file can fetch from flathub by accident |
| `KEMPT_FLATPAK_UPDATE_CMD` | `flatpak update --system` | The flatpak apply (`flatpak_apply`), which also runs as the user and never through `pkexec`. `tests/lib.sh` poisons it the same way, and for a louder reason: unstubbed, it would update the machine running the suite |
| `KEMPT_NOTIFY`, `KEMPT_TERMINAL` | `notify-send`, `konsole` | Notifications and the terminal surface |
| `KEMPT_RISKY_RE`, `KEMPT_BOOT_ID` | (empty) | Override the session-critical pattern and the boot session |
| `KEMPT_SKIP_REFRESH`, `KEMPT_RETRY_DELAY` | (unset), `10` | Deterministic checks and fast retry tests |
| `KEMPT_VIA` | (unset) | The event log's `via` column: `widget` when set to exactly that, `cli` otherwise. The widget sets it on every command it runs. Read by `log_event` and by nothing else, so it can never change what a command does |
| `KEMPT_ASSUME_TTY`, `KEMPT_LIVE_OUTPUT` | (unset) | Drive the interactive prompt path from a script |
| `KEMPT_RULES_DST` | `/etc/polkit-1/rules.d/49-kempt.rules` | Passwordless rule destination. Pinned: an absolute `*.rules` path, either in `/etc/polkit-1/rules.d/` (the admin one of polkit's four rules directories) or outside every system prefix - `/etc`, `/run`, `/usr`, `/var`, `/boot`, `/opt` - which is what the test seam uses |
| `KEMPT_POLICY_FILE` | `/usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy` | Where `kempt doctor` looks for the installed polkit actions. Doctor reads each action's `exec.path` annotation out of it and compares that with the helper path this CLI hands to pkexec |
| `KEMPT_WIDGET_PATH` | `~/.local/bin:$PATH` | The PATH order the panel widget's own command line builds (`plasmoid/contents/ui/main.qml`). `kempt doctor` resolves `kempt` through it to report which CLI the **widget** would run, against the one that printed the report. **Resolved, never executed.** `tests/lib.sh` pins it at a directory holding no `kempt`: unset, a suite run on any box that has Kempt installed would compare the tree under test against the developer's own `~/.local/bin/kempt` and report a split install every time |
| `KEMPT_OFFLINE_TOML` | `/usr/lib/sysimage/libdnf5/offline/offline-transaction-state.toml` | dnf5's own record of a staged transaction. **Read, never written** - it is dnf5's file, world-readable (0644 on Fedora), which is what lets an unprivileged check reconcile it against Kempt's marker. `tests/lib.sh` PINS this at a `ready` fixture rather than poisoning it: unset, every reconciliation branch in the suite would depend on whether the box running it happens to have a transaction staged |
| `KEMPT_OFFLINE_TXJSON` | `/usr/lib/sysimage/libdnf5/offline/transaction.json` | dnf5's stored transaction - the resolved package set a restart will install. **Read, never written**, and read LIVE rather than snapshotted: it is the only source that sees the packages the resolver added and a transaction something else replaced. `root:root` 0644 in a 0755 directory (verified in a container, 2026-09-05), which is what lets an unprivileged check reconcile a hold against it. `tests/lib.sh` PINS this at a recorded transaction rather than poisoning it, so the suite's default is the parsing path; pointing it at anything unparsable drives the degraded one |
| `KEMPT_OFFLINE_LINK` | `/system-update` | The symlink `dnf5 offline reboot` creates and systemd's `system-update-generator` looks for. **`lstat`ed, never resolved and never written** - it is what decides whether a boot detours into the offline updater, and `kempt doctor` is its only reader. `tests/lib.sh` points it at a path that does not exist, so the suite never reads the real one |
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
- **Flatpak is system scope only.** All four flatpak commands in `backends/flatpak.sh` (check,
  installed lookup, refresh, update) name `--system`, so check, refresh and apply always agree.
  The scope used to be checked a second time inside the root helper; the apply no longer crosses
  that boundary, so agreement is now this one file's job. Per-user apps need no privileges and
  are a possible future unprivileged path.
- **Both flatpak arms are unprivileged, and neither has a Kempt polkit action.** The refresh
  fills a cache in the user's own home, so root would buy nothing. The apply is granted to an
  active local session by the policy flatpak itself ships (`app-update` and `runtime-update` are
  `allow_active=yes`), so root only bought a dialog. That makes the whole flatpak side asymmetric
  with dnf on purpose: dnf escalates twice, flatpak not at all. Two cases can still authenticate
  and are written down in [security.md](security.md#accepted-limitations): a new runtime is an
  *install*, and `allow_active` means an active **local** session, not one over SSH.
- **`flatpak update` also updates runtimes**, but the pending list and the summary track apps, so
  a run can change more than it itemizes.
- **The install is a symlink into the checkout.** Proper packaging is the answer for shipping
  this to other people, and it is v2 work.
