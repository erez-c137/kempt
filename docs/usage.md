# Kempt commands

This page lists every `kempt` command with its options, output and exit codes. The panel widget,
covered in [widget.md](widget.md), runs these same commands, so the two always agree. Which button
runs which command is in [its table](widget.md#what-each-button-runs).

| Command | What it does |
| --- | --- |
| [`kempt check`](#check) | Finds what is pending, saves it and prints it as JSON |
| [`kempt update`](#update) | Installs the updates now, in this terminal, or stages them for the next restart |
| [`kempt run`](#run) | Starts an update where your settings say and returns at once |
| [`kempt unstage`](#unstage) | Discards the update staged for the next restart |
| [`kempt reclaim`](#reclaim) | Removes the Flatpak runtimes no installed app uses |
| [`kempt status`](#status) | Says what the last check found, in words |
| [`kempt summary`, `kempt history`](#summary-and-history) | Shows one past run, or lists them all |
| [`kempt log`](#log) | Shows what Kempt did, when, and whether the widget did it |
| [`kempt doctor`](#doctor) | Checks this install and names anything broken |
| [`kempt hold`, `unhold`, `holds`](#hold-unhold-holds) | Skips a package in updates, stops skipping it, or lists what is held |
| [`kempt config`](#config) | Reads or changes a setting |
| [`kempt discover-notifier`](#discover-notifier) | Turns Discover's own update notifier off or back on |
| [`kempt --version`](#--version) | Prints the version |
| `kempt help`, `--help`, `-h` | Prints the list of commands with a line each. `help <command>` or `<command> --help` gives one command's usage. |

## A typical day

```bash
# Morning: what is waiting?
kempt status

# Never update this one:
kempt hold dnf:nvidia-driver

# Kernel or Qt in the list? Stage it, then restart when convenient:
kempt update --surface=offline

# After the restart, a check records the result in history:
kempt check >/dev/null
kempt summary

# Or, with nothing risky pending:
kempt update
```

## Exit codes

Most commands use these codes. Each command's section lists its own cases.

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Something failed. |
| 2 | Usage error: unknown command, option or argument. |
| 3 | Cannot start: `jq` is missing, or another `kempt update` is running. |
| 5 | Stopped before changing anything. |
| 6 | `reclaim` and `startup`: what you were shown changed. |
| 7 | `update` only: another program held the package lock. |
| 8 | Run as root. Run Kempt as your own user, and it asks for a password when it needs one. |

**The writers' lock.** `kempt config set`, `kempt hold`, `kempt unhold` and `kempt discover-notifier
off|on|keep` each rewrite a file in your home directory. They take a lock at
`~/.local/state/kempt/writer.lock` while they do it, so two at once cannot lose a write. After 30
seconds of waiting the command gives up, writes nothing, says so on stderr and exits 1. Commands
that only read take no lock.

## check

```
kempt check [--refresh] [--anyway] [--coalesce] [--strict]
```

Asks every enabled backend what is pending, writes `~/.local/state/kempt/state.json`, and prints
the same JSON. A readable pending list:

```bash
kempt check | jq -r '.backends.dnf.items[] | "\(.name)  \(.from) -> \(.to)"'
```

```
curl  8.18.0-8.fc44 -> 8.18.0-9.fc44
git-core  2.55.0-1.fc44 -> 2.55.1-1.fc44
vim-minimal  2:9.2.967-1.fc44 -> 2:9.2.1000-1.fc44
```

| Option | Effect |
| --- | --- |
| `--refresh` | Fetches package metadata now instead of waiting out the 3-hour interval. On battery or a metered connection it still skips the fetch. dnf and Flatpak each give up after 2 minutes. |
| `--anyway` | Fetches now, even on battery or a metered connection. Implies `--refresh` and applies to this check only. The event log says `refresh anyway`. |
| `--coalesce` | Reuses the answer of a check this one waited for, when that check succeeded and finished in a later second. Nothing is queried or written, and the event log says `check shared`. `--refresh` turns it off. |
| `--strict` | Exits 1 when the answer is not current (see the exit table). Use it in scripts. |

The widget passes `--coalesce` for its timer, its file watcher, its startup check and when you
open it, so two widgets cost one check. **Check for Updates**, **Not Updating? Check Again** and a
hold always run a check of their own.

**Where the answer comes from.** A check answers from the local dnf and Flatpak caches. It
refreshes them at most once every 3 hours, which is the only network use, and skips that on battery
or a metered connection. On a fresh install the first check refreshes before it asks, and a backend
that cannot reports `stale` until a refresh succeeds. Old metadata shows in the widget's footer, in
`kempt doctor`, and in the event log, which records a skipped refresh once a day. To fetch anyway,
run `kempt check --anyway` or press **Check Anyway** in the widget.

A check also records a staged update once the restart has installed it, and clears Kempt's record
of a stage that has gone.

Fields worth knowing:

- **`from`** is `?` for a new package. Packages with several versions installed, such as
  `kernel-core`, list them comma-joined, oldest first.
- **`reboot_needed`** says whether a restart is owed now, and clears once you restart. Read `false`
  as "nothing to say", because it is also `false` when the check could not tell.
- **`download_bytes`** is the estimated download, per item (`size_bytes`), per backend and in
  total. A total appears only when every item that is not held has a size. No total means
  "unknown", not zero.
- **`metadata_refreshed`** is when dnf metadata was last fetched, which differs from `last_check`.

The full schema is in [architecture.md](architecture.md#state-json-schema-v1).

When a backend fails (network down, repo unavailable), `status` is `"stale"`, `error` holds the
message, and the previous item lists are kept. A missing root helper reads
`root helper not installed. Reinstall it with: sudo dnf reinstall kempt (see: kempt doctor)`.
A missing or corrupt state file starts from an
empty list. **Empty output with exit 0 means "no data, keep what you had"**, never
zero updates.

| Exit | When |
| --- | --- |
| 0 | The state was printed. Without `--strict`, this includes a failed backend, and the previous state printed because another check held the lock for 60 seconds or a Kempt update was running. |
| 1 | The new state could not be saved. With `--strict`, also a failed backend (`status` `"stale"`), Flatpak apps installed for you only that could not be listed (`status` `"ok"`, `.backends.flatpak.scopes.user` `"failed"`), or a served previous state. The state is printed first either way. |
| 2 | Unknown option. |

## update

```
kempt update [--no-flatpak] [--surface=widget|offline] [--risky-ok] [--answered]
```

Runs the update now, in this process. Flags override the config file for this run.

```bash
kempt update                      # everything, per config
kempt update --no-flatpak         # this run: system packages only
kempt update --surface=offline    # stage it; installs on the next restart
```

| Option | Effect |
| --- | --- |
| `--no-flatpak` | Updates system packages only. |
| `--surface=` | How this run installs, as **Run updates in** in the widget's settings: `widget` (**In this widget**) or `offline` (**On the next restart**). An unknown value logs a warning and uses `widget`. |
| `--risky-ok` | Sends no notification about session-critical packages from a run that cannot ask. The widget passes it after **Install Now**. |
| `--answered` | Says a person already chose, so `auto_accept=false` with no terminal does not refuse. `kempt run` passes it. |

Typed at a terminal, a run shows live output. With `auto_accept=false`, dnf5 also asks you there.
With `auto_accept=false` and no terminal, such as a script, it refuses with exit 5 and changes
nothing. A press in the widget is the answer, and `kempt run` says so with `--answered`.

What happens, in order:

1. **Risky-transaction check** (skipped for `offline`). If the update touches packages your running
   session depends on, a terminal run asks first:

   ```
     Heads up: 13 session-critical packages are pending.
     Installing these while the desktop is running can break the session until you restart:

         graphics drivers (mesa)          6 packages
         the desktop toolkit (qt6)        4 packages
         the Linux kernel (kernel-core)
         the core system library (glibc)
         the window manager (kwin)

     Staging installs them during your next restart, when nothing is using them.

         [s]  stage for the next restart  (recommended)
         [u]  update now, live
         [a]  abort  (default)

     Your choice [s/u/a]:
   ```

   Up to eight families are listed, then `... and N more`. **Enter, Ctrl-D or a second unknown
   answer abort**, with exit 0 and nothing changed. A run that cannot ask sends a notification naming the
   families and carries on. `kempt check` publishes the same list as `risky_pending`.
2. **Lock.** A second update exits 3. The prompt comes first, so an unanswered prompt blocks
   nothing.
3. **Snapshots** of the installed packages and Flatpak apps. If the packages or the system apps
   cannot be read, the run exits 5. If just the apps installed for you cannot be read, the run
   goes on without them and reports them failed.
4. **dnf**, through the root helper, with `-y` when `auto_accept` is on and one `--exclude=` per
   dnf hold. If another program holds the package lock, Kempt tries 3 times, 10 seconds apart, and
   names the likely holder.
5. **Flatpak**, unless turned off: the system apps, then the apps installed for you only, as you.
   With Flatpak holds, each pending app that is not held is updated on its own, and a hold covers
   the app in both places. If one of the two fails, the other still runs. A busy Flatpak lock gets
   the same 3 tries.
6. **Report.** Kempt compares the snapshots, writes a history entry and a log, and prints the
   summary, which marks a failed backend with its status in brackets. A run outside a terminal
   also sends a notification.

Kempt reads dnf5's history before and after the upgrade. When one new transaction matches its
command, its id goes into the history entry as `transaction_id` (for `dnf5 history info`), and the
run reports only that transaction's packages. A system-wide `flatpak update` also updates runtimes,
which the summary does not list.

**On an image-based Fedora, `update` stops.** Silverblue, Kinoite, Bazzite and bootc images update
as a whole image, so every run exits 5 and says to use Discover or `rpm-ostree upgrade`
(`bootc upgrade` on a bootc image). Support is planned. Kempt detects them by
`/run/ostree-booted`. `kempt doctor` reports it on its second line, and the widget hides
**Update Now**.

**Shutdown waits while packages install.** Fedora blocks shutdown and sleep during the install
step, and KDE's logout screen does not say why. Stopping during the download is safe. `kempt
doctor` checks it.

| Exit | When |
| --- | --- |
| 0 | Every backend succeeded, or you aborted at the prompt. |
| 1 | A backend failed, including the root helper refusing a folder that turned unsafe during the run. |
| 2 | Unknown option. |
| 3 | Another update is running, including another user's. Kempt says so before it checks anything. |
| 5 | Nothing changed: `auto_accept=false` with no terminal and no press, an image-based Fedora, installed packages or apps that could not be read, `--surface=offline` while a Fedora release upgrade is stored or another updater holds the next restart, a run with no terminal and no `--risky-ok` that finds system updates behind that updater, or a dnf folder Kempt can see is unsafe. |
| 7 | The only failure was a lock another program, such as PackageKit or Discover, held through all three tries. Try again in a few minutes. A busy lock while rebuilding a staged update exits 1. |

### Installing on the next restart

`--surface=offline`, the widget's **Install on Next Restart**, downloads the whole update, stores it
and tells the system to install it during the next restart. Nothing is installed while you work.
Both steps share one password prompt, so **any** restart installs it: the widget's **Restart…**, the
K menu, or `reboot` days later. Kempt never restarts the machine itself.

A check runs just before staging, and its count is the one the widget and the event log report. If
it fails, Kempt stages anyway with the previous count. Flatpak has no restart install, so an
staging run still updates Flatpak apps live. Until the restart, the staged packages still show as
pending, and the widget stops offering to stage them again. The CLI says:

```
61 updates are staged and install on the next restart
```

The widget puts the count in its header and says `They install when you restart.`

**When staging fails.** If the update was stored but could not be set up for the restart, Kempt
discards it. The run fails with `the updates were downloaded, but could not be set to install on the
next restart`. Staging again replaces the previous staged update. If that fails:

- Before anything was replaced, the previous one still installs. The run fails with
  `could not replace the prepared updates. The previous one is unchanged and still installs on the
  next restart`.
- After the previous one was gone, the run fails with `the previous staged update was discarded
  and could not be rebuilt`, and Kempt cleans up so the restart installs nothing. If that cleanup
  fails too, the notification says to run `sudo dnf5 offline clean`.

**When a Fedora release upgrade is stored, `--surface=offline` stops** with exit 5, because dnf5
keeps one stored transaction and staging would cancel the upgrade. The message names the way out:
restart, `sudo dnf5 system-upgrade reboot`, `sudo dnf5 offline log`, or `sudo dnf5 offline clean`.
Live updates still work, and the risky-transaction prompt offers only `[u]` and `[a]`.

**When other users can change dnf's folders, the update stops,** with exit 5 and nothing changed,
Flatpak included, before any password prompt. The message names the folder, and `kempt doctor` has
the fix. With no system updates waiting, a live run still updates Flatpak.

**When another updater holds the next restart, `--surface=offline` stops too,** with exit 5 and
nothing changed, Flatpak included, because a quiet fall to a live run
could cancel what that updater prepared. A live run with no terminal and no `--risky-ok` stops the
same way. The widget asks first and passes the flag. With no system updates waiting, both carry on.
To update anyway, use `kempt update --surface=widget` in a terminal, unless other users can also change dnf's
folders: then the message names the folder, and `kempt doctor` has the fix. While the restart is held, the
risky-transaction prompt offers only `[u]` and `[a]`.

**When the staged update will not install.** A restart may have skipped it, or a dnf command of
your own removed the restart trigger. The next check tells you once:

```
Your prepared updates can no longer install on a restart. To prepare your updates again, run kempt update --surface=offline. To remove them, run sudo dnf5 offline clean.
```

Kempt says nothing if your dnf command installed every staged update.

**A live update replaces the stage.** A staged update is built against the installed packages, so
when a live `kempt update` changes any rpm, Kempt discards the stage, which could only fail at boot.
A Flatpak-only run leaves it alone.

**Other tools.** If `dnf-automatic`, GNOME Software or a terminal `dnf5 upgrade` changes packages
while an update is staged, Kempt leaves the stage alone and records it once. If something replaces
the staged update, the next check tells you once. After the restart, Kempt reports only its own
transaction from dnf5's history. If that did not run, the history entry and the notification say
`restart (staged update did not run)`. If another updater installed the staged packages or newer
ones, the history shows `staged update (installed by another updater)`. If only some of them
moved to a newer version, the history shows `staged update (partly installed outside Kempt)` with
those packages at the versions on the box. A downgrade, or a package the stage would only remove, does
not count. If Kempt cannot tell, it adds no history entry and the normal list shows
what is pending.

**A restart that stops part way.** A package's script can fail during the restart, and dnf5 then
stops with the earlier packages installed. Kempt says how many of the updates it staged went in, and
the history shows a failed run, `staged update (restart did not finish)`, with those packages at the
versions on the box. The normal list shows what is still waiting. If none went in, or Kempt cannot
tell, the notification says it did not finish, and there is no history entry.

### A snapshot before every update

Kempt has no snapshot setting, because dnf5's actions plugin can run a command before every
transaction, whether Kempt started it or you ran `dnf5` yourself.

```bash
sudo dnf install libdnf5-plugin-actions
```

Then put one line in `/etc/dnf/libdnf5-plugins/actions.d/snapshot.actions`. For snapper, once it
has a config for `/`:

```
pre_transaction::::/usr/bin/snapper create --description before-update --cleanup-algorithm number
```

For Timeshift:

```
pre_transaction::::/usr/bin/timeshift --create --comments before-update --scripted
```

A failed snapshot is only logged, and the update goes ahead. To make it an error instead, put
`raise_error=1` in the fourth field. `man libdnf5-actions` has the full format.

## run

```
kempt run [--print-command] [--surface=widget|offline] [--risky-ok]
```

Starts `kempt update` the way your settings say, in the background, then returns at once. In a
terminal, `kempt update` is simpler.

```bash
kempt run --print-command
```

```
detached: kempt update (surface=widget)
```

| Option | Effect |
| --- | --- |
| `--print-command` | Prints the launch command and starts nothing. |
| `--surface=` | Runs this one update the other way, whatever the setting says. |
| `--risky-ok` | Passed on to an update that runs outside a terminal. A terminal run still asks. |

**Exit 0 means the update started.** `state.json` and `kempt history` have the result.

| Exit | When |
| --- | --- |
| 0 | The update started. |
| 2 | Unknown option or `--surface=` value. |
| 3 | Another update is running. Nothing is launched. |

## unstage

```
kempt unstage
```

Undoes `kempt update --surface=offline`, so the next restart installs nothing.

```
Discarded the updates waiting for the next restart. That restart installs nothing.
```

It asks for your password once, or, with nothing staged, says so without asking. Kempt clears its
record of the stage only once dnf5 confirms the transaction is gone.

| Exit | When |
| --- | --- |
| 0 | Discarded, or nothing was staged. |
| 1 | The root helper failed, or dnf5 still has the transaction. Kempt keeps its record. |
| 2 | Any argument. |
| 3 | Another update is running. |
| 5 | Nothing changes: a Fedora release upgrade is stored and discarding would cancel it, another updater has prepared the next restart and discarding would cancel that too, or the root helper refused. |

## reclaim

```
kempt reclaim [--list] [-y] [--expect=DIGEST]
```

Removes the Flatpak runtimes no installed app uses. They pile up as apps move to newer runtimes, and
each can take hundreds of megabytes. Only system runtimes are removed, never ones installed for you
only.

```
No installed app uses these Flatpak runtimes:
  runtime/org.freedesktop.Platform.GL.default/x86_64/24.08
  runtime/org.freedesktop.Platform.GL.default/x86_64/24.08extra
  runtime/org.kde.Platform/x86_64/5.15-23.08 (no longer supported)
Removing them frees about 1.5 GB.
Remove them? [y/N]
```

| Option | Effect |
| --- | --- |
| `--list` | Shows the list and stops. It works with `reclaim=off` too. |
| `-y`, `--yes` | Removes without asking. |
| `--expect=DIGEST` | Removes only if the list is still the set with this digest, the `reclaim.digest` from `kempt check` (16 lowercase hex characters). |

What it removes:

- **Only what Flatpak calls unused.** An extension another installed runtime still uses stays. The
  size is an estimate.
- **Only after an hour** unused, counted from the first check that lists it, so one another tool is
  installing is left alone. If no check has run yet, `kempt reclaim` runs one and says to try again
  in an hour.
- **Runtimes first, then their extensions**, such as translations (`.Locale`) and graphics drivers
  (`.GL`). Kempt lists again between the two, so an app you install meanwhile keeps both. If
  Flatpak removes one of its extensions anyway, Kempt says so, and `flatpak update` puts it back.
- **Never a pinned runtime.** To keep one Kempt lists, pin it:
  `flatpak pin runtime/org.kde.Platform/x86_64/5.15-23.08`.

It never asks for a password. Removing needs an administrator (on Fedora, a member of the `wheel`
group) logged in at the desktop, so over the network nothing is removed.

A removal writes an event line and no history entry.

| Exit | When |
| --- | --- |
| 0 | Removed, nothing to remove, or you answered no. |
| 1 | Flatpak could not list or remove the runtimes. If it stopped part-way, Kempt says how much it freed, or, when the list afterwards could not be read, that the removal may be partial: run `kempt reclaim --list`. |
| 2 | Unknown option, or a digest that is not 16 lowercase hex characters. |
| 3 | Another update is running. |
| 5 | Nothing removed: run as root with `KEMPT_ALLOW_ROOT=1` set or under sudo or pkexec, Flatpak is off or missing, `reclaim=off`, removing needs an administrator (or polkit refused Flatpak's helper), or there is no `-y` and no terminal to ask at. |
| 6 | Nothing removed: the list is not the set you were shown, or part of it became unused less than an hour ago. On first use, with no check on record, every runtime is new. |

## startup

```
kempt startup [--json]
kempt startup --all [--json]
kempt startup mute|unmute <unit> [--user]
```

Lists the services that stopped starting after a Kempt update, with the command that shows why.
Kempt only looks: it never starts, stops or enables a unit.

```
Not starting since an update:
  Bluetooth service (bluetooth.service), since 20 Oct
    systemctl status bluetooth.service
```

Kempt notes what is failing when an update starts, and compares after the update and the
next restart. Services already failing stay quiet. With no Kempt update since the last restart,
nothing is compared. Each new set gets one notification, and so does a recovery.

`mute` is for a service that stopped starting. It hides it, and its recovery, until it
runs. `--user` means a session service. `--json` prints the `startup` block of `kempt check`.

`--all` shows everything that starts or runs on its own: what didn't start this boot, what
changed since the last update, what starts with the computer and what runs on a schedule.
Empty parts and removed services are left out. Log lines of system services need
membership of `wheel`, `adm` or `systemd-journal`. `--json` prints [this shape](architecture.md#startup-report-json).
The widget shows the same list on its Startup report.

```
Didn't start this boot:
  Bluetooth service
    Its log says: No Bluetooth adapter found
    To see why: systemctl status bluetooth.service

Runs on a schedule:
  Timers
    Discard unused blocks (fstrim.timer): last run 19 Oct 01:25, next 26 Oct 00:22
  Cron
    backup.sh: every day at 23:55 (your crontab)
    These jobs do not run while crond is stopped.
```

| Exit | When |
| --- | --- |
| 0 | Listed, muted or unmuted. |
| 1 | The state directory could not be written. |
| 2 | Unknown option, or an invalid or unknown unit. |
| 6 | `mute`: the unit is running. `ack`: the recovered list changed. |

## status

```
kempt status [--list] [--json]
```

Says what the last check found: updates waiting with their first few names, held, security, staged,
and a restart owed. The footer says when the check ran, the age of the lists and the last update.
When another updater has prepared the next restart, a line says that restart belongs to it.

```
10 updates

System (dnf): 7 updates for kernel-core, bash, curl, tar, and 3 more
Apps (flatpak): 3 updates for org.gimp.GIMP, net.mkiol.SpeechNote and org.mozilla.firefox

Checked 2 hours ago · update info 2 days old
Last update 3 days ago · 41 updated
```

| Line | What it means |
| --- | --- |
| `... · package lists could not be downloaded` (footer) | The last download failed. The counts come from older lists. |
| `Package lists have never been downloaded: <reason>` (under the header) | No check has answered yet. The reason is the download error's first line. |

It never runs a check, takes no lock and writes nothing, so it answers during a check or
update. During an update, reclaim or unstage, it says Kempt is changing the system.
`kempt check` refreshes what it reads.

`--list` lists every update with both versions in place of the sections. It marks rows `held`,
`security` or `for you only`. `--list --json` prints what `--json` prints.

`--json` prints the saved state, the same document `kempt check` prints. With no state it prints
nothing and exits 1, otherwise 0.

Without `--json`, exit 1 means no state, an unreadable state, or a failed last check.

## summary and history

```
kempt summary [N]
kempt summary --json
kempt history [--json]
```

`summary` shows one run as text. `N` counts back from the newest: `1` (the default) is the last
run. Past the oldest, it shows the oldest and says so on stderr.

```bash
kempt summary
```

```
Kempt - 2026-08-24T21:05:11+03:00 (widget, 74s) ✓
System (dnf): 2 updated, +1 installed
  curl 8.18.0-8.fc44 → 8.18.0-9.fc44
  kernel-core 6.15.3-200.fc44 → 6.15.4-200.fc44
Apps (flatpak): 1 updated
  net.mkiol.SpeechNote 4.8.4 → 4.8.5
Held (skipped): vim-common
Restart needed
```

Holds that kept packages back add:

```
9 pending packages did not move because of holds
```

An update staged adds:

```
Staged: 61 updates install on the next restart
```

It comes from the current state, so `--json` leaves it out. Scripts read `offline_staged` from
`kempt check`.

With no runs, `summary` prints `no update runs recorded yet`. A damaged entry is skipped with a
warning, and the one before it is shown.

`summary --json` prints the newest run's history entry, for the widget. It takes no `N`. **With no
runs, or a damaged newest entry, it prints nothing**, names the damaged entry on stderr, and shows
no older run in its place.

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

`history` lists past runs, newest first: time, how it ran, status, and what changed, in the
notifications' wording. A failed run shows its reason in brackets.

```bash
kempt history
```

```
2026-08-24T21:05:11+03:00  widget  ok  3 updated, +1 installed
2026-08-23T09:41:02+03:00  restart (staged update installed)  ok  41 updated
2026-08-22T23:10:37+03:00  offline  ok  staged 41 updates for a restart
2026-08-22T18:12:55+03:00  widget  failed  no package changes  (authentication cancelled)
```

`history --json` prints every run as one JSON array of `summary --json` entries, newest first, or
`[]`. A damaged entry is left out and named on stderr. The format is in
[architecture.md](architecture.md#history-entries).

```bash
kempt history --json | jq -r '.[] | select(.status == "failed") | "\(.timestamp)  \(.error)"'
```

| Exit | When |
| --- | --- |
| 0 | Always, including no runs and damaged entries. |
| 2 | `N` is not a positive whole number, `--json` with `N`, or an unknown option. |

## log

```
kempt log [-n N] [--raw]
```

One line per thing Kempt did, newest last. `-n` sets how many (default 30).

```bash
kempt log -n 4
```

```
2026-08-26T20:58:11+03:00 cli Checked: 7 updates to install, 1 held
2026-08-26T21:10:55+03:00 widget Setting include_flatpak changed to true (was false)
2026-08-26T21:11:02+03:00 widget Update started in the widget
2026-08-26T21:14:40+03:00 widget Update finished: 7 updated, restart needed
```

`via` is `widget` or `cli` (a terminal, script or timer). `--raw` prints the stored words below.

| Exit | When |
| --- | --- |
| 0 | Always. |
| 2 | `-n` without a positive whole number, or an unknown option. |

The file is `~/.local/state/kempt/events.log`, mode 0600, trimmed to the last 2000 lines past 2500.
Its wording is fixed, so you can search it:

| Line | Written when |
| --- | --- |
| `config set <key>=<value> (was <old>)` | A setting changed. `(was unset)` when it had none. |
| `hold <backend>:<name>` / `unhold <backend>:<name>` | A hold was added or removed. |
| `check ok actionable=<n> held=<n>` | A check succeeded, with the counts the badge shows next. |
| `startup failed after the update: <units>` | Services that started before a Kempt update stopped starting after it. `after the last restart` when another tool changed packages since. Needs `notify_startup`. |
| `startup recovered: <units>` | Services Kempt announced are running again. |
| `startup muted <scope>:<unit>` / `startup unmuted <scope>:<unit>` | `kempt startup mute` or `unmute` ran. |
| `notification shown: <text>` / `notification not shown (<reason>): <text>` | Kempt sent a desktop notification, and whether it reached the desktop. The reason is `no desktop session`, `timed out`, `notify-send is missing` or `notify-send failed, exit <n>`. "Shown" means it reached the desktop, not that you read it. |
| `check stale <reason>` | A check failed, for example `dnf check failed: no authentication agent is running to ask for the password`. |
| `check skipped (a Kempt update is running)` | The root helper would not query dnf while a Kempt update or check ran, so the check printed the previous state. A refresh refused the same way is not recorded as failed. |
| `check shared last_check=<time>` | A `--coalesce` check took the answer of the check stamped `<time>`. It changes no counts. |
| `refresh ok` / `refresh failed` | The dnf metadata refresh ran. |
| `refresh flatpak ok` / `refresh flatpak failed` | The Flatpak refresh ran in the same step, while `include_flatpak` is on. Either can fail alone. |
| `refresh skipped (<reason>)` | Skipped on battery or a metered connection. At most once a day. |
| `refresh anyway (on battery)` / `refresh anyway (the connection is metered)` | `--anyway` or **Check Anyway** fetched past that rule. Every time. |
| `run start surface=<surface>` | A run is about to change the system. |
| `run did not start: <reason>` | A run stopped before changing anything: the exit-5 cases of `update` and `run`. |
| `run done rc=0 updated=<n> reboot=needed\|no` | A run finished. |
| `run failed rc=<n>: <reason>` | A run failed. The reason is the first log line that names the failure. |
| `dnf outcome read from history (transaction <id> <status>, helper rc=<n>)` | The root helper and dnf5's history disagreed about the run's transaction. The history's status decides. |
| `offline staged <n>` | An update was staged for the next restart. |
| `offline restage` / `offline restage failed (previous stage intact)` | A new stage replaced the previous one, or failed and left it in place. The first names the holds that prompted it. |
| `offline stage dropped (superseded by live update)` | A live update changed packages and discarded the stage. |
| `offline stage cannot install (...) - announced\|not announced` | The staged update can no longer install on a restart. `not announced` when the notification did not show, and the next check tries again. Once shown, it is not sent again. |
| `offline stage replaced outside Kempt (<what differs>) - announced\|not announced` | The staged update is no longer the one Kempt made. `not announced` as above. |
| `offline stage did not finish on the restart (...) - announced\|not announced` | dnf5 stopped during the restart, and nothing of the stage can be shown to have changed. Once shown, it is not sent again. |
| `offline stage partly installed on a restart that did not finish (<counts>)` | dnf5 stopped during the restart with some staged packages changed. The history entry says `offline (restart did not finish)`. |
| `offline stage partly installed outside Kempt (<counts>)` | Some of the staged packages changed outside Kempt and the rest did not. The history entry says `offline (partly installed outside Kempt)`. |
| `offline stage partly installed outside Kempt, after it was announced as lost` | The same, after you were told the stage could no longer install. No history or second notification. |
| `offline stage result unknown` | The restart moved packages and Kempt could not tell how much of the stage arrived. It claims nothing, and the normal list shows what is pending. |
| `offline stage installed by another updater (<counts>)` | Another updater installed the staged packages, or newer ones, on the restart or before it. The history entry says `offline (installed by another updater)`. |
| `offline stage left in place (another updater has prepared the next restart)` | Nothing was left to stage, and the old stage was kept, because removing it would cancel the other updater's restart update. |
| `offline marker cleared\|dropped\|kept (<why>)` | Kempt's record of a stage was removed, or kept because a newer stage arrived during a check. |
| `harvest applied (<counts>)` | After a restart, the staged update had installed. |
| `harvest found the staged transaction did not run (<counts>)` | After a restart, a different transaction had run. The history entry says `restart (staged update did not run)`. |
| `harvest skipped snapshot failed` / `harvest cleared stale marker` | The other two outcomes after a restart. |
| `harvest deferred: packages moved outside Kempt while the stage is still armed` | Another tool changed packages while an update was staged. |
| `harvest entry not written (state directory unwritable?)` / `history entry not written (state directory unwritable?)` | The history entry could not be saved. The run itself is unaffected. |
| `harvest log not written (state directory unwritable?)` | The log for a restart install could not be saved, so that run has no **Show Log**. |
| `unstage discarded the staged update` | `kempt unstage` removed the staged update. |
| `unstage refused (<what is stored>)` / `unstage refused by the root helper` | A Fedora release upgrade is stored, so `kempt unstage` changed nothing. |
| `unstage refused (another updater has prepared the next restart)` | Discarding would also cancel the other updater's restart update. Run it again after the restart. |
| `unstage found nothing staged` | Nothing was staged. |
| `unstage cleared a marker with no transaction under it` | The stage was already gone, so only Kempt's record was removed. |
| `unstage failed rc=<n>` | The staged update could not be discarded. |
| `unstage left a transaction behind (status <status>)` | dnf5 still has a stored transaction, so Kempt kept its record. |
| `reclaim removed <n> runtimes (<bytes> bytes) rc=<n>` | Unused runtimes were removed, by `kempt reclaim` or after an update. `, not all of them: <error>`: Flatpak stopped part-way. `, in use: <id>//<branch>`: extensions an app uses were removed; `flatpak update` puts them back. |
| `reclaim found nothing to remove` | Nothing was unused after an update. |
| `reclaim changed (<why>), nothing removed` | The list was not the set agreed to (`digest`), part of it was unused for less than an hour (`unstable`), or it held a runtime installed during the update (`new`). |
| `reclaim needs authorization, nothing removed` | Removing needed an administrator (see [reclaim](#reclaim)). |
| `reclaim failed rc=<n>: <error>` / `reclaim failed (flatpak did not answer)` | Flatpak could not remove the runtimes, or could not list them. `<error>` is Flatpak's own line, if any. `<n>` is `?` when the list could not be read. `, what was removed is unknown`: Flatpak failed and the list afterwards could not be read. |
| `reclaim refused (running as root)` / `reclaim refused (reclaim=off)` | `kempt reclaim` ran as root, or with `reclaim=off`. |
| `discover-notifier off` / `discover-notifier on` / `discover-notifier keep` | Discover's notifier was turned off or on for this user, or kept when the widget's offer was answered. |

### Which question, which file

| What you want to know | Where to look |
| --- | --- |
| What happened, when, and whether it came from the widget | `kempt log` |
| What the package manager printed during a run | The run log, `~/.local/state/kempt/logs/<stamp>.log`, named by `kempt summary` for a failed run and by each history entry's `log`. For a restart install, it is Kempt's own record of what changed, and says so at the top. |
| One run in detail: versions, counts, held items, duration | `~/.local/state/kempt/history/<stamp>.json`, listed by `kempt history` |
| What is pending now | `~/.local/state/kempt/state.json`, written by `kempt check` |
| Widget errors, such as a settings page that will not load | `journalctl --user -b \| grep -i kempt`, and the error shown on the settings page |

A run that fails at the password prompt gives one of four reasons everywhere it reports. The run
log keeps pkexec's own wording.

| Kempt says | What happened |
| --- | --- |
| `authentication cancelled` | The password dialog was closed. |
| `not authorized: the password was refused, or this session cannot authorize (over SSH or switched away)` | A wrong password, or a remote or inactive session. pkexec reports both the same way. |
| `no authentication agent is running to ask for the password` | Nothing on the desktop could ask for the password. |
| `cannot reach polkit (no system bus or polkit service), so nothing can be authorized` | pkexec could not reach polkit, for example in a container or with `polkit.service` stopped. |

## doctor

```
kempt doctor
```

Checks this install, one line per check. Use it when the widget says it cannot check, or shows
counts you do not trust. A missing root helper makes every dnf check fail, so the system package
count never changes.

A healthy report:

```
info  kempt 0.1.x (/usr/share/kempt)
ok    root helper (refresh): /usr/libexec/kempt-refresh (root:root 0755)
ok    root helper (apply): /usr/libexec/kempt-apply (root:root 0755)
ok    polkit action: /usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy
ok    polkit exec.path (refresh): /usr/libexec/kempt-refresh
ok    polkit exec.path (apply): /usr/libexec/kempt-apply
ok    flatpak: /usr/bin/flatpak
ok    Discover's update notifier: turned off for this user (/home/you/.config/autostart/org.kde.discover.notifier.desktop)
ok    package lists: refreshed 2026-08-26T20:58:03+03:00
ok    config file: /home/you/.config/kempt/config (2 settings)
ok    state dir writable: /home/you/.local/state/kempt
info  version: kempt 0.1.x (checkout a1b2c3d clean)
ok    helpers: match checkout
ok    policy: match checkout
ok    widget: match checkout
ok    widget engine: /home/you/src/kempt/bin/kempt

Recent events (kempt log):
  2026-08-26T21:14:40+03:00 widget Update finished: 7 updated, restart needed

kempt doctor: all checks passed
```

Lines are `ok`, `info`, `WARN` or `FAIL`. Only `FAIL` counts as a problem, and the last line counts
problems and warnings. The last five events follow.

| Exit | When |
| --- | --- |
| 0 | No line is `FAIL`. |
| 1 | At least one line is `FAIL`. |

What a `FAIL` means:

| Check | FAIL means |
| --- | --- |
| The system uses dnf (second line) | An image-based Fedora, where `kempt update` stops (exit 5). Use Discover or `rpm-ostree upgrade`. |
| Both root helpers exist at the expected paths, `root:root` 0755 | The package is damaged, or the helpers were replaced. Checks stay `stale`, updates cannot run. |
| The polkit action file is installed | Background checks cannot authorize. |
| Each polkit `exec.path` names the helper this CLI uses | Every privileged step asks for a password, and background checks time out after 120 s. The line names the fix. `info` when the policy cannot be read. |
| `flatpak` is present (a `WARN` row only when `include_flatpak=true` is set by hand) | Kempt skips Flatpak. Otherwise `info`. |
| Every config line is `key=value` with a valid key | That line is ignored, so the setting never applies. |
| The state directory is writable | No state, history or logs. |
| `widget engine:` (last) names this `kempt` | A leftover `~/.local/bin/kempt` shadows the installed one, because the panel puts `~/.local/bin` first on its `PATH`. `info` when the widget finds none. |
| A staged update is ready for the restart, or absent | It was downloaded but will never install. Run `sudo dnf5 offline clean`. |
| `/system-update` is absent, or points at a ready update | The next restart starts the offline updater and installs nothing. Run `sudo dnf5 offline clean`. |

The **Discover's update notifier** row appears only when the notifier is installed. It is `ok`
when off for you, and `info` when it starts with your session, naming
[`kempt discover-notifier off`](#discover-notifier) and the widget's
**Turn Off Discover's Notifier**. A second row says when Discover
installs updates on restart by itself. Its update then replaces yours, so the row is `WARN` when
Kempt installs on the next restart.

The dnf rows fail when other users can change dnf's folders or one above them. Each gives the fix.

| Line | What it means |
| --- | --- |
| `WARN  package lists: the last download failed (<reason>) ...` | Checks answer from older lists, offline for example. |
| `WARN  last check failed: <reason> ...` | The counts Kempt shows are from an earlier check, or there are none yet. dnf's no-cache error reads as in `kempt status`. |

### The staged transaction

Doctor compares Kempt's record of a staged update with what dnf5 has stored. It prints nothing
when neither exists.

| Line | What it means |
| --- | --- |
| `info  staged update: 61 packages install on the next restart` | Normal. |
| `FAIL  staged update did not finish: dnf5 started it on a restart and stopped before the end ...` | No restart runs it again. Run `sudo dnf5 offline clean` and stage again. |
| `FAIL  prepared updates can never install: the transaction was downloaded but never set to install ...` | Never set up for the restart. Run `sudo dnf5 offline clean` and stage again. |
| `FAIL  prepared updates can never install: dnf5 says "ready" but /system-update is gone ...` | A restart already skipped it, and no later restart will install it. |
| `FAIL  the stored Fedora release upgrade can never install: ...` | The same, for a release upgrade. `sudo dnf5 system-upgrade reboot` sets it up again. |
| `info  staged update: the transaction is gone, ...` | The next check clears Kempt's leftover record. |
| `info  an offline transaction is staged outside Kempt ...` | Something else staged it. `dnf5 offline status` describes it. |
| `info  dnf5 still keeps an offline transaction whose updates are already installed ...` | Another updater installed the same updates. It will not run. `kempt unstage` removes it. |
| `info  dnf5 still keeps what is left of a staged update that was only partly installed ...` | It will not run again, and a later stage replaces it. `kempt unstage` removes it. If another updater holds the next restart, restart first. |
| `WARN  staged update: another updater has prepared the next restart ...` | The update Kempt staged will not install on that restart. |
| `WARN  another updater has prepared the next restart: /system-update points to ...` | Normal while Discover's notifier has an update ready. Kempt will not stage until you have restarted. `is not dnf5's` in place of `points to` means a plain file. |
| `info  a Fedora release upgrade (44 -> 45) is prepared outside Kempt and installs on the next restart ...` | A release upgrade is ready. `sudo dnf5 offline clean` removes it. `kempt update --surface=offline` stops while it is there. |
| `info  a Fedora release upgrade (44 -> 45) has been downloaded outside Kempt but not started ...` | No restart installs it yet. `sudo dnf5 system-upgrade reboot` starts it, `sudo dnf5 offline clean` drops it. |
| `info  a Fedora release upgrade (44 -> 45) is stored outside Kempt and was set to install, but the restart marker /system-update is not in place ...` | A restart already skipped it. See the FAIL row above. |
| `info  a Fedora release upgrade (44 -> 45) is stored outside Kempt and did not finish ...` | `sudo dnf5 offline log` says why. |
| `info  staged update: Kempt has a marker for a transaction that is no longer stored ...` | A release upgrade replaced Kempt's staged update. The next check clears the record. |
| `FAIL  boot symlink is live over a transaction that is not set to install ...` | The next restart starts the offline updater and installs nothing. |
| `FAIL  boot symlink is live with nothing prepared behind it ...` | The same, with nothing stored at all. |
| `info  staged update: it installs kernel-core on the next restart despite the hold ...` | A hold added after staging. Rebuild with `kempt update --surface=offline`, or remove it with `sudo dnf5 offline clean`. |
| `info  staged update: it may still install held packages on the next restart ...` | The same, when Kempt cannot read the staged update's contents and you hold a dnf package. |
| `FAIL  staged update is not the one Kempt built ...` | Something replaced it. The line lists up to four differences each way (`+` only in dnf5's, `-` only in Kempt's). |
| `info  staged update: the marker cannot be read ...` | Kempt's record is damaged. It is left in place. |

### The install lines

`version:` names the release, plus, in a git checkout, the commit and `clean` or `dirty`. Quote it
in bug reports.

A packaged install prints `install: packaged` in place of `helpers:`, `policy:` and `widget:`, and
no commit on `version:`, because the package manager keeps those files in step. Its sample is in
[install.md](install.md#verify-it), and [RELEASING.md](RELEASING.md) has the details. It fails if a
widget copy in your home directory shadows the packaged one.

## hold, unhold, holds

```
kempt hold   dnf:<package> | flatpak:<app.id>
kempt unhold dnf:<package> | flatpak:<app.id>
kempt holds
```

A hold means **skip it, but keep telling me about it**. Held items stay in the state with
`"held": true`, count toward `held_total` rather than `actionable`, and each run lists them as
`Held (skipped): ...`.

```bash
kempt hold dnf:kernel-core
kempt hold flatpak:org.gimp.GIMP
kempt holds
```

```
dnf:kernel-core
flatpak:org.gimp.GIMP
```

The `dnf:` or `flatpak:` prefix is required, and names are checked when you add them.

**Flatpak runtimes cannot be held.** Kempt refuses and writes nothing:

```
org.kde.Platform is a Flatpak runtime, and runtimes cannot be held: apps share them, so holding one breaks the next app that needs it. Hold the app instead.
```

A runtime hold already in your holds file is ignored. Remove it with `kempt unhold flatpak:<id>`.

**Holds are Kempt's own list**, which a `sudo dnf5 upgrade` of your own ignores. Add
`--exclude=<package>` to that command for each one.

| Exit | When |
| --- | --- |
| 0 | Done, including a hold added twice, one removed that was not there, and a warning about a staged update. |
| 1 | The writers' lock was busy. |
| 2 | No `dnf:` or `flatpak:` prefix (`use dnf:<pkg> or flatpak:<app.id>`), an invalid name, a Flatpak runtime, or an unknown option. Nothing was written. |

### Holding a package that is already staged

A hold applies from the **next** update Kempt builds. dnf5 cannot change a stored update, so a
staged one still installs the package. The hold is recorded anyway, with a warning on stderr:

```
The staged update still contains kernel-core and installs it on the next restart.
When ready: kempt update --surface=offline (rebuilds it with your holds) or sudo dnf5 offline clean (removes it).
```

Rebuilding may ask for your password. After `sudo dnf5 offline clean`, the next restart installs
nothing.

If Kempt cannot read what the staged update contains, it warns anyway:

```
The staged update was built before this hold and may still install kernel-core on the next restart. Rebuilding applies all current holds.
When ready: kempt update --surface=offline (rebuilds it with your holds) or sudo dnf5 offline clean (removes it).
```

`kempt unhold` warns the other way, when the staged update was built without the package:

```
The staged update was built without kernel-core, so the next restart will not install it. Rebuild when ready: kempt update --surface=offline.
```

After that restart, the hold works as usual. The widget shows the same warning on its
[ready message](widget.md#when-updates-are-ready).

## config

```
kempt config get <key> [default]
kempt config set <key> <value>
```

Reads or writes a setting, as the widget's settings do. With no value stored, `get` returns your
`default` argument, or the built-in default for a known key. Every key is in
[configuration.md](configuration.md).

```bash
kempt config get surface           # popup, on a new install
kempt config set surface offline
kempt config get refresh_interval_min   # 60
```

`set` warns on stderr about an unknown key or a value the key does not accept, but stores it, so a
newer widget can use keys this version does not know:

```
warning: 'bogus' is not a value surface accepts. Accepted: widget, offline
```

Setting `surface` also answers the widget's one-time offer to run updates in the widget.

| Exit | When |
| --- | --- |
| 0 | Read or written, including a warning about an unknown key or value. |
| 1 | The writers' lock was busy. |
| 2 | A key that does not match `^[a-z][a-z0-9_]+$`, a value longer than one line, or a missing argument. |

## --version

```bash
kempt --version        # kempt 0.1.x
kempt version          # the same
kempt -V               # the same
```

The number comes from the `VERSION` file, or reads `kempt unknown` without it. For a bug report,
`kempt doctor` is better: it also says where the version was read from.

## discover-notifier

```
kempt discover-notifier off
kempt discover-notifier on
kempt discover-notifier keep
kempt discover-notifier status [--json]
kempt discover-notifier seen
```

Discover's update notifier counts updates on its own schedule, so its number can differ from
Kempt's, and its background work can make a Kempt run wait. These commands change it for you alone,
without a password. When it is not installed, `off`, `on` and `keep` say so and change nothing.

**`off`** writes `~/.config/autostart/org.kde.discover.notifier.desktop` with `Hidden=true`, so the
notifier stops starting at login, and stops the running one. A file of your own there moves to a
name ending in `.before-kempt`, and Kempt prints where. A symlink stays a symlink. Kempt keeps one
such copy and never overwrites it.

**`on`** removes Kempt's file and puts yours back. If you edited Kempt's file, your version moves to
a name ending in `.kempt-edited`, and Kempt prints where. Then it starts the notifier and says so
once it runs. If Discover's own setting for automatic updates is still on, `on` says those resume
too, and the widget warns about them again.

**`keep`** changes nothing, and records that you answered the widget's offer.

**`status`** says whether the notifier is installed, on, turned off by Kempt, and running, and
whether automatic updates are on in Discover's settings. `--json` prints `installed`, `enabled`,
`running`, `by_kempt` and `unattended`, plus `entry` when the file keeping it off is not Kempt's.

**`seen`** records that the widget has shown its warning about Discover's automatic updates, and
changes nothing else. The widget runs it.

| Exit | When |
| --- | --- |
| 0 | Done, or nothing needed doing. |
| 1 | Nothing changed: `off` found a `.before-kempt` copy already there, `on` found a file of your own keeping the notifier off, the path is a directory, a broken symlink or a file Kempt cannot read, or the writers' lock was busy. |
| 2 | An unknown subcommand or option. |
