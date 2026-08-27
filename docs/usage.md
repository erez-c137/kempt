# Using Kempt

Every command is `kempt <subcommand>`. `kempt help` prints the same list.

```
check                 refresh pending-updates state (JSON to stdout)
update                run the update now (options from config; --no-flatpak, --surface=X override)
run [--dry-run]       launch update per configured surface (what the widget calls)
summary [N]           human summary of the last (or Nth-last) run
summary --json        the newest run's history entry, verbatim JSON (nothing if no runs yet,
                      or if that entry is damaged)
history               list past runs
log [-n N]            recent events: what Kempt did, when, and from where (default 30)
doctor                check this install: helpers, polkit action, tools, config, state
hold dnf:<pkg> | flatpak:<app.id>     skip in updates, still notify
unhold <same>         remove a hold
holds                 list holds
config get|set        read/write settings
enable-passwordless | disable-passwordless
```

## Exit codes

One contract, every subcommand:

| Code | Meaning |
| --- | --- |
| 0 | Success. Includes declining at the risky-transaction prompt, and includes `check` when a backend failed (the failure is recorded in the state, not in the exit code). |
| 1 | The run itself failed (a backend returned non-zero), or `doctor` found at least one problem. |
| 2 | Usage error: unknown command, option or argument. |
| 3 | Cannot start: `jq` is missing, or another `kempt update` already holds the lock. |
| 4 | Launcher missing: no terminal emulator for the `terminal` surface. |
| 5 | Aborted during pre-flight. Nothing was changed. |

## check

```
kempt check
```

Queries every enabled backend, writes `~/.local/state/kempt/state.json`, and prints the same
JSON to stdout. Takes no arguments; anything else exits 2.

```bash
kempt check | jq '{status, actionable, held_total}'
```

```json
{
  "status": "ok",
  "actionable": 9,
  "held_total": 1
}
```

A readable pending list:

```bash
kempt check | jq -r '.backends.dnf.items[] | "\(.name)  \(.from) -> \(.to)"'
```

```
curl  8.18.0-8.fc44 -> 8.18.0-9.fc44
git-core  2.55.0-1.fc44 -> 2.55.1-1.fc44
vim-minimal  2:9.2.967-1.fc44 -> 2:9.2.1000-1.fc44
```

`from` is `?` when the pending package is not installed yet (a new dependency), and versions are
comma-joined for packages that keep several versions installed at once, such as `kernel-core`.
Comma-joined sets are ordered oldest to newest, so a reader that wants to show one version takes
the last element.
Every check also records `reboot_needed`, whether a restart is owed **right now** - a fresh,
cache-only, local-only question, not a memory of the last run - so it clears itself once you have
restarted and it notices a `sudo dnf5 upgrade` you ran by hand. Read it as a one-way signal:
`true` means say so, `false` means there is nothing to say and never "no restart needed", because
the underlying check answers `false` both when it is sure and when it could not tell.

A check also prices what it found, from metadata already on disk - no depsolve, no network, no
transaction. Each item gains `size_bytes`, each backend a `download_bytes`, and the state a
top-level `download_bytes`, which is what the widget shows next to Update Now. All three are
optional: a backend publishes a total only when **every** non-held item in it has a size, because
a total over the priced ones would look authoritative and be quietly short. Absent means not
known - never zero.

The full field-by-field schema is in
[architecture.md](architecture.md#state-json-schema-v1).

`check` also does two things quietly, in the same lock: it harvests a staged offline
transaction once the machine has actually rebooted, and it refreshes package metadata at most
once every 3 hours, never on battery and never on a metered connection. The refresh covers both
backends - dnf's repo metadata and the Flatpak remote's summary - and it is the **only** part of
a check that reaches the network. The questions themselves are answered entirely from the local
caches, so a check on a train, behind a captive portal or on a metered link still tells you what
is pending.

The other side of that trade: **a cache that has never been filled cannot answer.** On a box
where the refresh has never run, the cache-only query fails and that backend reports `stale` with
the reason, exactly as it would for a repo that flapped. Both backends behave the same way here,
and the fix for both is the same - let a refresh run. A check does that itself before it asks
anything, so on a fresh install the first check refreshes first; if it did not (battery, metered
link, no network at the time), the next check on mains power will.

### The exit contract, precisely

`check` is built so a widget polling it every few minutes can never be misled:

- **Backend failure** (network down, repo flap): exit **0**, `status` becomes `"stale"`, `error`
  carries the message, and the previous item lists are kept so the badge does not drop to zero.
  One message is rewritten rather than passed through: a **missing root helper** surfaces from
  `timeout` as `failed to run command '...': No such file or directory`, which reads as a
  timed-out check, so `error` says `root helper not installed - run ./install.sh (see: kempt
  doctor)` instead. Every other backend message is verbatim.
- **Corrupt or missing state file:** exit 0, degrades to an empty previous list, never a crash.
- **Failure to persist** the new state: the fresh state is printed to stdout **first**, then the
  command exits non-zero. The caller still gets the answer.
- **Lock held** by another check (60 second wait): the previous state is printed and the exit
  code is 0.

That last case is the one rule every caller must implement: **empty stdout with exit 0 means
"no data, keep the last known state", never "zero updates"**.

## update

```
kempt update [--no-flatpak] [--surface=terminal|popup|background|offline]
```

Runs the update now, in this process. Options from the config file, overridden by the flags.
An unrecognized option exits 2. An unrecognized `--surface=` value logs a warning and falls back
to `terminal`.

```bash
kempt update                      # everything, per config
kempt update --no-flatpak         # this run: system packages only
kempt update --surface=offline    # stage it; applies on the next reboot
```

What happens, in order:

1. **Risky-transaction check** (skipped when the surface is already `offline`). If the pending
   transaction touches session-critical packages, an interactive terminal run prompts:

   ```
   Recommendation: this update touches 13 session-critical packages (a live upgrade can break the running desktop):
     dbus-broker
     glibc
     kernel-core
     kf6-kio
     kwin
     mesa-dri-drivers
     plasma-workspace
     qt6-qtbase
     ... and 5 more
   [u]pdate live / [s]tage offline / [a]bort (default: abort)
   ```

   One name per family is listed, up to eight, so a 40-package Qt bump cannot push the pending
   kernel out of sight. `u` proceeds live, `s` switches this run to offline staging, `a` aborts.
   **Enter, Ctrl-D or a second unrecognized answer all abort**, with exit 0 and nothing changed.
   Detached surfaces cannot prompt, so they send a notification naming the families and proceed.
   The same list is published as `risky_pending` by `kempt check`, so the widget can offer
   its one-click **Install on Next Restart** without re-deriving the rule.
2. **Lock.** A second concurrent update exits 3. The prompt above happens before the lock is
   taken, so an unanswered recommendation never blocks the next run.
3. **Pre-flight snapshots** of the installed package sets. If one cannot be read, the run aborts
   with exit 5 before changing anything.
4. **dnf**, through the root helper, with `-y` when `auto_accept` is on and one `--exclude=` per
   dnf hold. A foreign package lock (PackageKit, Discover) is tried up to 3 times, 10 seconds
   apart, with a message naming the likely holder.
5. **flatpak**, unless disabled. With no Flatpak holds this is one system-wide update; with
   holds it becomes a per-app update of every pending, non-held, installed app.
6. **Report.** After-snapshots are diffed against the before-snapshots, a history entry and a log
   are written, the summary is printed, and detached surfaces send a notification.

Exit 0 when every backend succeeded, 1 when one did not. Partial failure is reported per backend
rather than collapsed: the summary line for a failed backend carries its status in brackets.

`auto_accept=false` forces this run onto the `terminal` surface with live output, because none of
the other surfaces can answer dnf's prompt.

Known limitation: a system-wide `flatpak update` also updates runtimes, but the pending list and
the summary track apps. A run can therefore change more than the summary itemizes.

## run

```
kempt run [--dry-run]
```

The launcher: it reads the configured surface and starts `kempt update` in the right place,
then returns immediately. This is what the widget's Update Now button calls; humans can call
`kempt update` directly.

```bash
kempt run --dry-run
```

```
terminal: konsole -e kempt update
```

With `surface=background`:

```
detached: kempt update (surface=background)
```

Exit 4 when the `terminal` surface is configured and the emulator is not installed. The check
happens before the dry run too, so `--dry-run` tells you about a missing launcher instead of
pretending it would work.

**A successful launch says nothing about the update's outcome.** `run` returns as soon as the
child is detached. Poll `state.json` or `kempt history` for the result; never read `run`'s exit
code as "updated".

## summary and history

```
kempt summary [N]
kempt summary --json
kempt history
```

`summary` renders one run as human text. `N` counts back from the newest: `1` (the default) is
the last run, `2` the one before it. `N` must be a positive integer, or the command exits 2.
Asking for more runs than exist shows the oldest and says so on stderr.

```bash
kempt summary
```

```
Kempt - 2026-08-24T21:05:11+03:00 (terminal, 74s) ✓
System (dnf): 2 updated, +1 installed
  curl 8.18.0-8.fc44 → 8.18.0-9.fc44
  kernel-core 6.15.3-200.fc44 → 6.15.4-200.fc44
Apps (flatpak): 1 updated
  net.mkiol.SpeechNote 4.8.4 → 4.8.5
Held (skipped): vim-common
Reboot: needed
```

With no runs recorded, `summary` prints `no update runs recorded yet` and exits 0. A damaged
history entry is skipped with a warning on stderr and the next-newest is rendered instead.

`--json` prints the newest run's history entry verbatim and nothing else, which is what the
widget reads rather than parsing the human text back into numbers. The entry is validated first,
so a caller is never handed corrupt bytes under exit 0. It takes no `N`: `kempt summary --json 2`
is a usage error rather than a silently ignored argument.

Unlike the human mode above, `--json` does **not** fall back to the next-newest entry. It answers
one question - what did the last run do - and when that run's entry cannot be read, the answer is
that we do not know. It says so with empty stdout under exit 0, naming the damaged entry on
stderr. Serving the run underneath instead is how the widget came to announce an older run's
package count and duration as the run that had just finished. **With no runs recorded, or with
the newest entry damaged, it prints nothing and exits 0** - empty stdout means "no data", never
an empty run and never a different run.

```bash
kempt summary --json | jq '{timestamp, status, reboot_needed}'
```

```json
{
  "timestamp": "2026-08-24T21:05:11+03:00",
  "status": "ok",
  "reboot_needed": true
}
```

`history` lists past runs, newest first: timestamp, surface, status, and what the run changed.
That last column is the same phrase the notifications use, so a run that only installed or
removed packages is never listed as "0 updated", and a run that changed nothing says so. A failed
run also carries its reason in brackets, taken from its own log: the same sentence the summary,
the notification and `kempt log` give it.

```bash
kempt history
```

```
2026-08-24T21:05:11+03:00  terminal  ok  3 updated, +1 installed
2026-08-23T09:41:02+03:00  offline (applied on reboot)  ok  41 updated
2026-08-22T18:12:55+03:00  background  failed  no package changes  (authentication declined or cancelled)
```

## log

```
kempt log [-n N]
```

One line per thing Kempt did, newest last. `-n` chooses how many lines to show; the default is
30. With nothing recorded yet it prints `No events recorded yet.` on stdout and exits 0.

```bash
kempt log -n 6
```

```
2026-08-26T20:58:03+03:00 cli refresh ok
2026-08-26T20:58:11+03:00 cli check ok actionable=7 held=1
2026-08-26T21:10:55+03:00 widget config set auto_accept=true (was false)
2026-08-26T21:11:02+03:00 widget run start surface=background
2026-08-26T21:14:40+03:00 widget run done rc=0 updated=7 reboot=needed
2026-08-26T21:14:41+03:00 widget check ok actionable=0 held=1
```

Every line is `<timestamp> <via> <what happened>`. `via` is `widget` when the command came from
the Plasma widget and `cli` for everything else: a terminal, a script, a timer. That column is
most of the point of the file. It is what separates "the box I just ticked did that" from
"something else changed it while I was not looking".

The vocabulary is fixed, so the file is worth grepping:

| Line | Written when |
| --- | --- |
| `config set <key>=<value> (was <old>)` | A setting changed. `(was unset)` when the key had no stored value. |
| `hold <backend>:<name>` / `unhold <backend>:<name>` | A hold was added or removed. |
| `check ok actionable=<n> held=<n>` | A check succeeded. The numbers are the ones the badge is about to show. |
| `check stale <reason>` | A check failed. The reason names the backend, for example `dnf check failed: authentication declined or cancelled`. |
| `refresh ok` / `refresh failed` | The dnf metadata refresh ran. It runs at most every three hours, and only on mains power over an unmetered connection. |
| `refresh flatpak ok` / `refresh flatpak failed` | The Flatpak remote summary was fetched, on the same schedule and in the same step. Written only while `include_flatpak` is on. The two arms are recorded separately because they fail for unrelated reasons, and one failing never stops the other or the check that follows. |
| `run start surface=<surface>` | A run is about to change the system. Nothing is recorded for a run that aborted before that. |
| `run done rc=0 updated=<n> reboot=needed\|no` | A run finished cleanly. |
| `run failed rc=<n>: <reason>` | A run failed, with the first line of the log that names a failure. |
| `offline staged <n>` | A transaction was staged for the next reboot. `<n>` is what the last check said dnf had pending. |
| `harvest applied (<counts>)` | The check after a reboot found the staged transaction applied and wrote it into history. |
| `harvest skipped snapshot failed` / `harvest cleared stale marker` | The other two things a harvest can decide. |
| `passwordless enable\|disable rc=<n>` | `enable-passwordless` or `disable-passwordless` finished, with the status it ended on. |

The file is `~/.local/state/kempt/events.log`, mode 0600. Nothing else ever deletes from it, so
it prunes itself: past 2500 lines it is rewritten to the last 2000.

### Which question, which file

Kempt writes four things, and they answer different questions. Reaching for the wrong one is why
"why did that not work?" used to be hard to answer:

| What you want to know | Where to look |
| --- | --- |
| What happened, when, and whether it came from the widget | `kempt log` |
| What exactly the package manager printed during a run | the run log, `~/.local/state/kempt/logs/<stamp>.log`. `kempt summary` prints its path for a failed run, and every history entry carries it in `log`. |
| A machine-readable summary of one run: versions, counts, held items, duration | `~/.local/state/kempt/history/<stamp>.json`, listed by `kempt history` |
| What is pending right now | `~/.local/state/kempt/state.json`, rewritten by `kempt check` |
| Widget-side errors: QML warnings, a settings page that will not load | `journalctl --user -b | grep -i kempt` (plasmashell prints QML warnings there), plus the error label the settings page shows in place |

A run that failed because somebody closed the authentication dialog says
`authentication declined or cancelled` in all of the first four. The raw pkexec wording is kept
in the run log and nowhere else, because that file is evidence rather than a summary.

## doctor

```
kempt doctor
```

Checks this installation and prints one line per check. Exits 0 when everything passes, 1 when
anything failed. Takes no arguments.

```bash
kempt doctor
```

```
ok    root helper (refresh): /usr/local/libexec/kempt-refresh (root:root 0755)
ok    root helper (apply): /usr/local/libexec/kempt-apply (root:root 0755)
ok    polkit action: /usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy
ok    jq: /usr/bin/jq (jq-1.8.1)
ok    terminal emulator: /usr/bin/konsole
ok    flatpak: /usr/bin/flatpak
ok    config file: /home/you/.config/kempt/config (2 settings)
ok    state dir writable: /home/you/.local/state/kempt
ok    checkout intact: /home/you/src/kempt
info  version: kempt 0.1.0 (checkout a1b2c3d clean)
ok    helpers: match checkout
ok    policy: match checkout
ok    widget: match checkout

Recent events (kempt log):
  2026-08-26T21:10:55+03:00 widget config set auto_accept=true (was false)
  2026-08-26T21:11:02+03:00 widget run start surface=background
  2026-08-26T21:14:40+03:00 widget run done rc=0 updated=7 reboot=needed

kempt doctor: all checks passed
```

It exists because of one specific trap. Every other command degrades instead of crashing, which
is right for a widget that polls on a timer but wrong for a human trying to find out what is
broken: with the root helpers missing, `kempt check` **exits 0** with `status: "stale"` and zero
pending items, and a badge showing nothing pending is indistinguishable from an up-to-date
machine. `doctor` is the one command whose job is to say why the answer is empty.

What it checks, and what each failure means:

| Check | FAIL means |
| --- | --- |
| Both root helpers exist at the polkit-annotated paths, `root:root` 0755 | `install.sh` has not run, or the helpers were replaced. `check` will be permanently `stale`, `update` cannot run. |
| The polkit action file is installed | pkexec has no policy for the helpers and falls back to an authentication dialog, which a background check cannot answer. |
| `jq` is present | Nothing: without `jq` every command exits 3 before `doctor` can run, so this line only ever names which `jq` answered. |
| The terminal emulator (`$KEMPT_TERMINAL`) is present | `kempt run` exits 4 every time. Reported only when it would actually be launched: `surface=terminal`, or any surface with `auto_accept=false`. Otherwise it is an `info` line. |
| `flatpak` is present | Every check reports the Flatpak backend stale. An `info` line instead when `include_flatpak=false`. |
| Every config line is `key=value` with a valid key | The file is read with `grep "^key="`, so a malformed line is ignored forever and the setting the user wrote never applies. |
| The state directory is writable, or can be created | No state file, no history, no logs. |
| The checkout still holds `lib/`, `backends/` and the passwordless rules template | The CLI is a symlink into the checkout. A missing rules template only surfaces the day `enable-passwordless` is run. |
| The installed root helpers, polkit action and widget package still match the checkout | You pulled and did not re-run `./install.sh`. The CLI is a symlink so it moved with the pull; those three are copies, so root is still running the old helper. |

Lines are `ok`, `info` or `FAIL`. Only `FAIL` affects the exit code, and every check runs even
after one fails, so one pass shows every problem.

### The install lines

The last four lines are about the install itself rather than the machine.

`version:` names the release and, in a git checkout, the commit it was built from and whether the
tree is clean. It is the line worth quoting in a bug report: `0.1.0` covers many commits, and
`dirty` says local edits are in play. A tree with no git history, or a box with no `git`, prints
the release alone.

`helpers:`, `policy:` and `widget:` compare each installed copy against the checkout, byte for
byte. They exist because a checkout install is only half live: `~/.local/bin/kempt` is a symlink,
so `git pull` updates the CLI immediately, while the two root helpers, the polkit action and the
widget package are copies that only change when `./install.sh` runs. Before this, a pull without
an install left root running last week's helper with nothing anywhere saying so.

A `DIFFER` line is a `FAIL` and names the fix. `not installed` is an `info` instead: a missing
root helper is already a `FAIL` on its own line above, and the widget is optional. Nothing here
needs privileges to check, because the installed copies are world-readable.

An install that did not come from a checkout prints `install: packaged` and compares nothing.
There is nothing to drift: the package manager owns those files and keeps them in step, which is
the whole point of shipping Kempt as a package. See
[docs/RELEASING.md](RELEASING.md).

The last five events are printed after the checks, indented so nothing there can be mistaken for
a report line. They are not a check and never affect the exit code: the question that follows
"is this install sound?" is usually "then why did my change not take effect?", and the answer is
worth having in the same output.

## hold, unhold, holds

```
kempt hold   dnf:<package> | flatpak:<app.id>
kempt unhold dnf:<package> | flatpak:<app.id>
kempt holds
```

A hold means **skip it, but keep telling me about it**. Held items are excluded from every
Kempt run, still appear in the state with `"held": true`, are counted in `held_total` rather
than `actionable`, and are listed at the end of each run as `Held (skipped): ...`.

```bash
kempt hold dnf:kernel-core
kempt hold flatpak:org.gimp.GIMP
kempt holds
```

```
dnf:kernel-core
flatpak:org.gimp.GIMP
```

The `backend:name` prefix is required, and the backend must be `dnf` or `flatpak`; anything else
exits 2 with `use dnf:<pkg> or flatpak:<app.id>`. That guard exists so `kempt hold dnf` cannot
silently hold a package called "dnf". Names are validated the same way the root helper validates
them, so a hold that would later be refused is refused now. Adding the same hold twice is a
no-op, and removing one that was never there succeeds.

Holds are **Kempt's own list**, not a system-wide version lock. A manual `sudo dnf5 upgrade`
outside Kempt ignores them.

## config

```
kempt config get <key> [default]
kempt config set <key> <value>
```

The only supported way to read or write settings, including for the widget. `get` falls back to
the built-in default for a known key, or to the explicit `default` argument if you pass one.

```bash
kempt config get surface           # terminal
kempt config set surface offline
kempt config get refresh_interval_min   # 60
```

Keys must match `^[a-z][a-z0-9_]+$` and values must be single-line, or `set` exits 2. Every key,
its type, its default and its effect are in [configuration.md](configuration.md).

## --version

```bash
kempt --version        # kempt 0.1.0
kempt version          # the same, for the spelling people guess
kempt -V               # and the one they have in their fingers
```

The first thing any bug report needs. The number comes from the `VERSION` file at the root of the
checkout, which is the one place this project writes its version down: the Plasma widget's
`metadata.json` is pinned to it by the test suite, and a release's git tag, RPM `Version:` and
AppStream `<release>` are expected to agree with it too.

A checkout with no `VERSION` file prints `kempt unknown` and carries on. That is deliberate: a
version is a diagnostic, and a build that cannot say what it is must still be able to update your
machine. `kempt doctor` opens with the same version and the checkout it was read from, which is
why pasting a doctor report into an issue is worth more than pasting a version alone.

## enable-passwordless, disable-passwordless

```
kempt enable-passwordless
kempt disable-passwordless
```

Installs or removes a single polkit rule that lets your active local session apply updates
without the authentication dialog. It covers the dnf half, which is the only half that ever asks:
Flatpak app updates already run without a prompt. Each takes one `pkexec` prompt to write to
`/etc/polkit-1`, and neither takes any arguments. Disabling something that was never enabled is
not an error.
What exactly is granted is documented in [security.md](security.md#passwordless-mode).

## The Plasma widget

The widget is a thin client over the commands above and nothing else: `kempt check` for the
badge, `kempt run` for Update Now, `kempt hold`/`unhold` for the pins, `kempt config` for every
setting in its dialog. It contains no package-manager knowledge of its own, so everything on this
page stays true from the panel, and anything you do in a terminal shows up in the widget.

### Where it lives: the system tray, or the panel itself

`./install.sh` installs the widget for your user (no authentication - it is a copy into
`~/.local/share/plasma/plasmoids/`). There are two places it can then live, and you can use
either or both.

**In the system tray** (the default). Kempt declares itself a tray entry under *System Services*
and is enabled there out of the box, so after installing it appears in your tray alongside the
volume and network icons - no dragging required. It may take a plasmashell restart or a log-out
to show up the first time. The tray decides how big every entry is, so inside it Kempt is exactly
the size of its neighbours. To turn it off or move it behind the expander arrow:

> Right-click the tray > **Configure System Tray...** > **Entries** > find **Kempt**.

**As a standalone panel item.** Useful if you want it somewhere specific, or larger than a tray
icon:

> Right-click the panel > **Add Widgets...** > search for **Kempt** > drag it onto the panel.

Doing both gives you two Kempt icons, which is legal and probably not what you want - pick one
and disable the other.

If you changed anything under `plasmoid/`, re-run `./install.sh`: the CLI is a symlink and
follows the checkout, but the widget is a copy and does not.

### What the panel icon means

| Icon | State | What it is telling you |
|---|---|---|
| Update icon with a count badge | Updates pending | The number is the **actionable** count - what a run right now would actually change. Held packages are not in it. |
| Plain update icon, no badge | Up to date | Nothing to do. If you hold packages, the tooltip still says how many are held. |
| Same as its contents, badge kept | Stale check | The last check failed (a repo flapped, the network dropped), so the counts shown are the **last known good** ones. The tooltip carries the reason and when the last successful check was. A transient repo failure is not an alarm, so the icon does not become one. |
| Warning emblem | Error | Kempt itself could not run or could not read its state. The tooltip names the problem and points at `kempt doctor`. |
| Spinner | Updating | A run started from the widget is in flight. |
| Dimmed, no badge | No data yet | The first check has not answered. Deliberately not "up to date" - the widget never claims a number it does not have. If that check came back empty because another one already held the lock (common right after a login), the widget re-asks a few times about ten seconds apart instead of waiting for the next scheduled check. |

The badge spells the count out exactly up to `999`, then reads `999+`. A box left alone for a few
weeks routinely has two or three hundred updates pending, so a lower cap would be vague in the
ordinary case rather than the extreme one. The tooltip and the popup header are never capped.

Below the 22 px icon step - a very thin panel, or **Small** below - the badge is left off rather
than drawn at a size nothing can be read at. The icon still changes to say there is something
pending, and the tooltip carries the exact count.

### How big the icon is

By default the panel icon is drawn at the size the **system tray** uses for your panel: 22 px on
anything from a 22 px panel up to a 47 px one, which is every ordinary panel including Plasma's
default. That is deliberate - a standalone Kempt on a 44 px panel used to fill its cell at 32 px
and stood a head taller than every tray icon beside it.

If that judgement is wrong for your panel, **Configure Kempt… > Panel icon size** offers
**Automatic**, **Small** (16 px), **Medium** (22 px) and **Large** (32 px). Inside the system tray
the tray sets the space, so a size larger than it allows is ignored and the icon fits its slot.

**Large** is never smaller than **Automatic**: on a very thick or HiDPI panel Automatic climbs to
48 or 64 px, and Large follows it up rather than dropping back to 32. Small and Medium are left
alone - asking for less than Automatic is what they are for.

From a terminal it is the `widget_icon_size` setting:

```bash
kempt config set widget_icon_size large
```

Anything the widget does not recognize means **Automatic**. The setting is not validated when it
is stored - the widget is the only thing that reads it, and it would rather draw at a sensible
size than refuse to draw.

### The popup

Click the icon. The popup is three parts, and they never move: a **header** that says where you
stand, a **content area** that says everything else, and a **footer** with the one button that
acts on it.

With updates pending, on a box that also owes a restart and has a kernel in the transaction:

```
 3 updates available                                 [refresh] [gear]   <- header: the count,
 --------------------------------------------------------------------     Refresh, settings
 (!) Restart to apply installed updates          [Restart…]      [x]   <- one message per
 (!) This includes a kernel update. Restart when it finishes.              thing that needs
                                        [Install on Next Restart]         saying, in order
 (i) dnf check failed: repo 'updates' unavailable
     (last successful check: 2026-08-27 09:14 +03:00)

 System (dnf)                                                          <- the pending list,
   nodejs                                                     [pin]       grouped by backend
   2:24.19.0-1nodesource → 2:24.20.0-1nodesource
 Apps (flatpak)
   org.mozilla.firefox                                        [pin]
   140 → 141
 Held                                                                  <- held items stay
   kernel-core                                                [pin]       visible, out of
   6.15.1 → 6.15.3                                                        the running

 Last update 18 min ago · 4 packages                            [v]    <- expands to what
 --------------------------------------------------------------------     that run installed
 Checked 4 min ago · 1 held · ~140 MB              [ Update Now ]      <- footer: the dateline,
                                                                          the cost, and the
                                                                          one action
```

**The header** is one row: where you stand, then two buttons. The words are `3 updates
available`, or `Up to date`, `Updating…`, `No update data yet` before the first check has
answered, `Kempt cannot check for updates` when the CLI itself could not be run, or
`Could not read the update state` when the state file is there and this widget cannot read it -
which is what a Kempt older than its own CLI looks like, since the CLI is a symlink into the
checkout and the widget is an installed copy. It is never capped - the badge on the panel stops
at `999+` because a panel has no room, and the popup has plenty.

- **Refresh** (the circular arrow) re-checks now instead of waiting for the timer. Its tooltip
  and its accessible name are both *Check for Updates*. While a check or a run is in flight it
  greys out and a spinner appears beside it: it stays where it is rather than disappearing,
  because a control that leaves the screen takes the keyboard focus with it. The same entry is
  registered as a contextual action, so it is also in the system tray's **More actions** menu and
  in the icon's right-click menu. Inside the system tray the refresh icon lives in the tray's own
  heading row instead, next to the pin and the gear, so this one is hidden there and the spinner
  beside it is what tells you a check is running.
- **The gear** opens the same settings dialog as **Configure Kempt…** on the right-click menu.
  It is hidden inside the system tray, because the tray draws its own heading with a gear in it
  and two gears opening one dialog is one gear too many.

**The messages** appear only when they apply, always in this order:

1. **Restart to apply installed updates**, with a **Restart…** button. See *About the restart*
   below. It has a close button; the rest do not.
2. **"This includes a kernel update. Restart when it finishes."** (and a second sentence when the
   NVIDIA driver is in the set) when the transaction would rewrite things a running desktop is
   using. Its button is **Install on Next Restart**, which hands the whole transaction to the
   next reboot - the same recommendation `kempt check` publishes as `risky_pending`, and the same
   thing as `kempt update --surface=offline`. With no kernel in the set the message is the plain
   count instead: `20 session-critical pending (dbus, glibc, kf6, mesa, ...)`.
3. **The stale explanation**: what went wrong, and how old the counts under it therefore are.
   Information rather than a warning, because the counts are still the best known truth.
4. **What the run that just finished did**: `Updated 4 packages in 2s`, `No package changes`, or
   `Update failed: <the reason>` as an error. **Show Log** is on it when that run recorded a log
   file, which is every run Kempt performed; the entries harvested after an offline (on-reboot)
   update carry no log path, so they carry no button either rather than one that would open your
   home directory. It is transient - it clears when you close the popup or the next check starts,
   and the persistent **Last update** row stays out of the way while it is up. One event, one line
   at a time.
5. A button press that failed and has something to say.

**The list** is grouped **System (dnf)**, **Apps (flatpak)** and **Held**, each row showing the
package and the versions it is moving between. The version line is never truncated: it wraps onto
a second line instead, because `2:24.19.0-1nodesource` is the line you compare between two
machines and the tail is the half that differs. A name too long for the row elides instead. The
pin on each row holds or unholds that package - the same `kempt hold` as the CLI - and the row
moves between the pending list and the Held group on the next check.

**Last update 18 min ago · 4 packages** is what the previous run actually installed, read from
that run's own history entry (`kempt summary --json`). Expand it for the package list, with
**Show Log** for the raw output. It never grows past half the popup, so expanding it cannot
squeeze the pending list out of sight.

**The footer** dates the counts above it. `Checked 4 min ago` is relative and ticks while the
popup is open; hover it for the exact timestamp, offset included - the offset is there so the
two lines cannot silently disagree about which clock they are on. It gains ` · 1 held` when anything is held,
` · ~140 MB` when the download size is known and there is something to update, and
` · restart pending` when a restart is owed but the message above is not on screen. Before any
check has ever succeeded it reads `No successful check yet`, which is not the same thing as never
having checked.

The size sits next to **Update Now** because it answers the question that button raises: pressing
this costs about that much. It is an estimate and it says so with a `~` - never "up to", which
would claim a ceiling it does not have. It leaves out the packages dnf will pull in as new
dependencies, and it over-counts Flatpak, which transfers far less than the published figure
thanks to its own delta format. Under a megabyte it reads `< 1 MB` rather than a kilobyte figure
nobody acts on, and when the number is not known it says **nothing at all** rather than `0 MB`.
Held items are never counted: a hold is not going to be downloaded.

**Update Now** runs `kempt run`, which opens whatever surface you configured. With the surface
set to **In this widget**, the popup shows the run's live log while it works; on the other
surfaces the output goes where you chose and the popup says so. If a run cannot start, the
widget shows the CLI's own message, remedy included. You do not have to keep the popup open -
updates keep running if you close it.

**Opening the popup re-checks** when the last successful check is older than the smaller of your
check interval and five minutes. It never blocks the popup: the counts you already have stay on
screen and are replaced when the answer arrives.

If a check is already running, the popup's request is *remembered* and a fresh check runs the
moment that one finishes - one extra check, never a queue of them, however many times you open
and close the popup meanwhile. It is not dropped, and that is deliberate: the running check read
the system BEFORE whatever prompted this request, so treating its answer as good enough would
leave the counts stale until the next hourly check - the exact staleness the widget exists to
prevent.

On a box where no check has ever succeeded there is no stamp to be old, so the popup checks on
**every** open. That is the box whose counts are most worth going and getting: a fresh install
behind a broken repo, or one whose root helpers were never installed, has nothing to show and no
other way to find out it has started working.

**The widget also checks when something else changed the machine.** It looks at the package
databases, its own state file and the config file every 30 seconds, so a `dnf upgrade` typed in a
terminal, a Discover run or another Kempt run all reach the panel without you asking. What it does
not do is check again on its own wake: an update rewrites the package database all the way through
the transaction and the state file on its way out, so for a minute after a check finishes the
watcher stays quiet rather than re-checking a change that check already accounted for. Before that,
one run left three `widget check ok` lines in `kempt log` inside 40 seconds, two of them describing
nothing. Refresh, the scheduled check, opening the popup and a settings change are all exempt: the
quiet minute applies only to the watcher noticing itself.

With nothing to do, the same three parts say so and stop offering:

```
 Up to date                                          [refresh] [gear]
 --------------------------------------------------------------------
 (!) Restart to apply installed updates          [Restart…]      [x]   <- still shown: you can
                                                                          owe a restart with
                (icon)                                                    nothing pending
        Everything is up to date

 Last update 18 min ago · 4 packages                            [v]
 --------------------------------------------------------------------
 Checked 4 min ago                                                     <- no Update Now at all
```

**Update Now is gone here, not greyed out.** An up-to-date box has no run to start, so there is
no action to offer - a disabled primary button over "Everything is up to date" is an offer being
refused rather than an offer never made.

One exception, and it matters: if the only pending updates are **held**, the placeholder is not
shown. The Held group is on screen carrying the truth instead, so the popup never says
"everything is up to date" over the top of a list of things that are not.

**About the restart.** **Restart…** opens KDE's own restart prompt - the one that lets your
running applications object and save, and that you can cancel. Kempt never restarts anything
itself, in any state, with any setting. If the prompt cannot be opened, the reason is added to
the message rather than swallowed.

And the message is a fact about the running system, not a job waiting on you: **if you never
press it, the updates are still applied.** They are installed on disk already. What is still
running - the kernel, a library something opened before the upgrade - keeps using the old copy
until that thing restarts. Reboot when it suits you. (Offline staging is the other way round on
purpose: there the transaction is *held* for the next boot and applies during it. See
`--surface=offline` above.)

Closing the message with its **x** puts it away for the rest of this Plasma session and writes
nothing down. That is deliberate: a dismissal written to disk is a promise to remember it across
a restart, and a restart is the exact event that makes the fact underneath it go away. To turn
the reminder off for good, see **Restart reminders** below.

### Settings

Right-click the widget > **Configure Kempt…**. The gear in the popup's header opens the same
page, except in the system tray, where the tray draws its own heading with a gear in it and Kempt
does not add a second one underneath. Every control on that page reads and writes `kempt config` -
there is no second copy of any setting, so a value you set in a terminal shows up here and vice
versa.

Two things worth knowing:

- **Apply vs OK.** Both save. **Apply** writes your changes and leaves the dialog open;
  **OK** writes them and closes. If you close the dialog with unsaved changes, it asks first.
- **Changes reach the panel within 30 seconds.** The widget notices a settings change by watching
  the config file, and it looks every 30 seconds. So the badge or the check interval may take up
  to half a minute to catch up after you press Apply. Nothing is lost in the meantime.

**Run updates in** is greyed out when *"Apply updates without asking for confirmation"* is off,
because only a terminal window can ask you the question. Your choice is remembered - untick the
confirmation box and it comes straight back.

**Restart reminders** are the `restart_reminder` setting, on by default. When a restart is owed -
because updates have been installed that the running system is still ignoring - the popup shows a
message saying so and offers a button that opens KDE's own restart prompt. Closing that message
puts it away until the next Plasma session; nothing is written down. With the setting off there is
no message and no button, and the popup's status line still ends `restart pending`, because that is
a fact about your machine rather than a reminder. **Nothing ever restarts on its own either way.**

```bash
kempt config set restart_reminder false   # the fact stays, the nagging stops
```

**Password prompts** offers **Allow without password…** and **Require a password…**, which run
`kempt enable-passwordless` and `kempt disable-passwordless` for you (each raises its own
authentication dialog, and whatever the command said comes back under the buttons). The page never
claims which one is currently active. That is not an oversight: the polkit rules directory is
readable only by root, so a widget running as you genuinely cannot tell. Guessing about whether
your machine asks for a password is the wrong thing to guess about.

Holds you have set are listed at the bottom with a remove button each.

## A typical day

```bash
# Morning: what is waiting?
kempt check | jq '{actionable, held_total, risky: (.risky_pending | length)}'

# Something you never want updated automatically:
kempt hold dnf:nvidia-driver

# Kernel and Qt in the list? Stage it instead of rewriting a running desktop:
kempt update --surface=offline
# ... reboot when convenient; the transaction applies during boot ...

# After the reboot, the result is harvested into normal history:
kempt check >/dev/null
kempt summary

# Or, on an ordinary day with nothing risky pending:
kempt update
```
