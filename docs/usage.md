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
| [`kempt summary`, `kempt history`](#summary-and-history) | Shows one past run, or lists them all |
| [`kempt log`](#log) | Shows what Kempt did, when, and whether the widget did it |
| [`kempt doctor`](#doctor) | Checks this install and names anything broken |
| [`kempt hold`, `unhold`, `holds`](#hold-unhold-holds) | Skips a package in updates, stops skipping it, or lists what is held |
| [`kempt config`](#config) | Reads or changes a setting |
| [`kempt enable-passwordless`, `disable-passwordless`](#enable-passwordless-disable-passwordless) | Lets your session install updates without a password, or stops it |
| [`kempt discover-notifier`](#discover-notifier) | Turns Discover's own update notifier off or back on |
| [`kempt --version`](#--version) | Prints the version |
| `kempt help`, `--help`, `-h` | Prints the list of commands with a line each. `kempt help <command>` or `kempt <command> --help` prints one command's usage. |

## A typical day

```bash
# Morning: what is waiting?
kempt check | jq '{actionable, held_total, risky: (.risky_pending | length)}'

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
| 4 | No terminal emulator. |
| 5 | Stopped before changing anything. |
| 6 | `reclaim` only: the list changed. Nothing was removed. |
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
open it, so two widgets cost one check. **Check for Updates**, **Not Updating? Check for Updates** and a
hold always run a check of their own.

**Where the answer comes from.** A check answers from the local dnf and Flatpak caches. It
refreshes them at most once every 3 hours, which is the only network use, and skips that on battery
or a metered connection. On a fresh install the first check refreshes before it asks, and a backend
that cannot reports `stale` until a refresh succeeds. Old metadata shows in the widget's footer, in
`kempt doctor`, and in the event log, which records a skipped refresh once a day. To fetch anyway,
run `kempt check --anyway` or press **Download Anyway** in the widget.

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
On a checkout, it says `Run ./install.sh` instead. A missing or corrupt state file starts from an
empty list. **Empty output with exit 0 means "no data, keep what you had"**, never
zero updates.

| Exit | When |
| --- | --- |
| 0 | The state was printed. Without `--strict`, this includes a failed backend, and the previous state printed because another check held the lock for 60 seconds. |
| 1 | The new state could not be saved. With `--strict`, also a failed backend (`status` `"stale"`), per-user Flatpak apps that could not be listed (`status` `"ok"`, `.backends.flatpak.scopes.user` `"failed"`), or a served previous state. The state is printed first either way. |
| 2 | Unknown option. |

## update

```
kempt update [--no-flatpak] [--surface=terminal|widget|background|offline] [--risky-ok]
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
| `--surface=` | Where this run happens, as **Run updates in** in the widget's settings: `terminal` (**Terminal window**), `widget` (**In this widget**), `background` (**In the background**) or `offline` (**On the next restart**). An unknown value logs a warning and uses `terminal`. |
| `--risky-ok` | Sends no notification about session-critical packages from a run that cannot ask. The widget passes it after **Install Now**. |

With `auto_accept=false`, every run uses a terminal with live output, because only a terminal can
answer dnf's prompt. `kempt run` then stages in a terminal too, and turns every other `--surface=`
value into a live update there.

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

| Exit | When |
| --- | --- |
| 0 | Every backend succeeded, or you aborted at the prompt. |
| 1 | A backend failed. |
| 2 | Unknown option. |
| 3 | Another update is running. |
| 5 | Nothing changed: an image-based Fedora, installed packages or apps that could not be read, or `--surface=offline` while a Fedora release upgrade is stored. |
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
discards it. The run fails with `the updates were staged, but could not be set to install on the
next restart`. Staging again replaces the previous staged update. If that fails:

- Before anything was replaced, the previous one still installs. The run fails with
  `could not rebuild the staged update. The previous one is unchanged and still installs on the
  next restart`.
- After the previous one was gone, the run fails with `the previous staged update was discarded
  and could not be rebuilt`, and Kempt cleans up so the restart installs nothing. If that cleanup
  fails too, the notification says to run `sudo dnf5 offline clean`.

**When a Fedora release upgrade is stored, `--surface=offline` stops** with exit 5, because dnf5
keeps one stored transaction and staging would cancel the upgrade. The message names the way out:
restart, `sudo dnf5 system-upgrade reboot`, `sudo dnf5 offline log`, or `sudo dnf5 offline clean`.
Live updates still work, and the risky-transaction prompt offers only `[u]` and `[a]`.

**When the staged update will not install.** A restart may have skipped it, or a dnf install of
your own while it waited removed the restart trigger, though dnf5 still calls it `ready`. The next
check tells you once:

```
Your staged update can no longer install on a restart. To stage your updates again, run kempt update --surface=offline. To remove the staged update, run sudo dnf5 offline clean.
```

**A live update replaces the stage.** A staged update is built against the installed packages, so
when a live `kempt update` changes any rpm, Kempt discards the stage, which could only fail at boot.
A Flatpak-only run leaves it alone.

**Other tools.** If `dnf-automatic`, GNOME Software or a terminal `dnf5 upgrade` changes packages
while an update is staged, Kempt leaves the stage alone and records it once. If something replaces
the staged update, the next check tells you once. After the restart, Kempt reports only its own
transaction from dnf5's history. If that did not run, the history entry and the notification say
`restart (staged update did not run)`. If another updater installed the staged packages or newer
ones, the history shows `staged update (installed by another updater)`.

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
kempt run [--print-command] [--surface=terminal|widget|background|offline] [--risky-ok]
```

Starts `kempt update` where your settings say, then returns at once. In a terminal, `kempt update`
is simpler.

```bash
kempt run --print-command
```

```
terminal: konsole -e kempt update
```

With `surface=background`:

```
detached: kempt update (surface=background)
```

| Option | Effect |
| --- | --- |
| `--print-command` | Prints the launch command and starts nothing. `--dry-run` is an older name for it. |
| `--surface=` | Runs this one update somewhere else, whatever the setting says. |
| `--risky-ok` | Passed on to an update that runs outside a terminal. A terminal run still asks. |

**Exit 0 means the update started.** `state.json` and `kempt history` have the result. However the
terminal window closes, even early, it runs a check, which ends the widget's updating state. The
window's shell exits with the update's status.

| Exit | When |
| --- | --- |
| 0 | The update started. |
| 2 | Unknown option or `--surface=` value. |
| 3 | Another update is running. Nothing is launched. |
| 4 | The terminal emulator is missing. `--print-command` checks this too. |
| 5 | The terminal window did not open within five seconds, for example over SSH with no display. The event log says `run did not start: <reason>`, and a window that opens later starts nothing. |

## unstage

```
kempt unstage
```

Undoes `kempt update --surface=offline`, so the next restart installs nothing.

```
Discarded the staged update. The next restart installs nothing.
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
group) logged in at the desktop. Over the network, or from an account that is not an administrator,
nothing is removed. Run it as yourself, too: as root or with `sudo`, Flatpak cannot see your own
apps, so Kempt removes nothing.

With `reclaim=automatic` (see [configuration](configuration.md#keys)), a successful update removes
the offered set, and its summary says how much was freed, under **Unused Flatpak runtimes** in a
terminal. A removal writes an event line and no history entry.

| Exit | When |
| --- | --- |
| 0 | Removed, nothing to remove, or you answered no. |
| 1 | Flatpak could not list or remove the runtimes. If it stopped part-way, Kempt says how much it freed, or, when the list afterwards could not be read, that the removal may be partial: run `kempt reclaim --list`. |
| 2 | Unknown option, or a digest that is not 16 lowercase hex characters. |
| 3 | Another update is running. |
| 5 | Nothing removed: run as root, Flatpak is off or missing, `reclaim=off`, removing needs an administrator (or polkit refused Flatpak's helper), or there is no `-y` and no terminal to ask at. |
| 6 | Nothing removed: the list is not the set you were shown, or part of it became unused less than an hour ago. On first use, with no check on record, every runtime is new. |

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
Kempt - 2026-08-24T21:05:11+03:00 (terminal, 74s) ✓
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
2026-08-24T21:05:11+03:00  terminal  ok  3 updated, +1 installed
2026-08-23T09:41:02+03:00  restart (staged update installed)  ok  41 updated
2026-08-22T23:10:37+03:00  offline  ok  41 updates staged for the next restart
2026-08-22T18:12:55+03:00  background  failed  no package changes  (authentication cancelled)
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
kempt log [-n N]
```

One line per thing Kempt did, newest last. `-n` sets how many lines to show (default 30). With
nothing recorded it prints `No events recorded yet.`

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

Each line is `<timestamp> <via> <what happened>`, where `via` is `widget` or `cli` (a terminal, a
script or a timer).

| Exit | When |
| --- | --- |
| 0 | Always, including an empty log. |
| 2 | `-n` without a positive whole number, or an unknown option. |

The file is `~/.local/state/kempt/events.log`, mode 0600, trimmed to the last 2000 lines past 2500.
The wording is fixed, so you can search it:

| Line | Written when |
| --- | --- |
| `config set <key>=<value> (was <old>)` | A setting changed. `(was unset)` when it had none. |
| `hold <backend>:<name>` / `unhold <backend>:<name>` | A hold was added or removed. |
| `check ok actionable=<n> held=<n>` | A check succeeded, with the counts the badge shows next. |
| `check stale <reason>` | A check failed, for example `dnf check failed: no authentication agent is running to ask for the password`. |
| `check shared last_check=<time>` | A `--coalesce` check took the answer of the check stamped `<time>`. It changes no counts. |
| `refresh ok` / `refresh failed` | The dnf metadata refresh ran. |
| `refresh flatpak ok` / `refresh flatpak failed` | The Flatpak refresh ran in the same step, while `include_flatpak` is on. Either can fail alone. |
| `refresh skipped (<reason>)` | Skipped on battery or a metered connection. At most once a day. |
| `refresh anyway (on battery)` / `refresh anyway (the connection is metered)` | `--anyway` or **Download Anyway** fetched past that rule. Every time. |
| `run start surface=<surface>` | A run is about to change the system. |
| `run did not start: <reason>` | A run stopped before changing anything: the exit-5 cases of `update` and `run`. |
| `run done rc=0 updated=<n> reboot=needed\|no` | A run finished. |
| `run failed rc=<n>: <reason>` | A run failed. The reason is the first log line that names the failure. |
| `offline staged <n>` | An update was staged for the next restart. |
| `offline restage` / `offline restage failed (previous stage intact)` | A new stage replaced the previous one, or failed and left it in place. The first names the holds that prompted it. |
| `offline stage dropped (superseded by live update)` | A live update changed packages and discarded the stage. |
| `offline stage cannot install (...) - announced` | The staged update can no longer install on a restart. |
| `offline stage replaced outside Kempt (<what differs>) - announced` | The staged update is no longer the one Kempt made. |
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
| `passwordless enable rc=<n>` / `passwordless disable rc=<n>` | `enable-passwordless` or `disable-passwordless` finished. |
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

On a checkout install:

```
info  kempt 0.1.x (/home/you/src/kempt)
ok    root helper (refresh): /usr/local/libexec/kempt-refresh (root:root 0755)
ok    root helper (apply): /usr/local/libexec/kempt-apply (root:root 0755)
ok    polkit action: /usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy
ok    polkit exec.path (refresh): /usr/local/libexec/kempt-refresh
ok    polkit exec.path (apply): /usr/local/libexec/kempt-apply
ok    jq: /usr/bin/jq (jq-1.8.1)
ok    terminal emulator: /usr/bin/konsole
ok    flatpak: /usr/bin/flatpak
ok    dnf: /usr/bin/dnf5
ok    unused Flatpak runtimes: Kempt can list them
ok    Discover's update notifier: turned off for this user (/home/you/.config/autostart/org.kde.discover.notifier.desktop)
ok    package metadata: refreshed 2026-08-26T20:58:03+03:00
ok    config file: /home/you/.config/kempt/config (2 settings)
ok    state dir writable: /home/you/.local/state/kempt
ok    checkout intact: /home/you/src/kempt
info  version: kempt 0.1.x (checkout a1b2c3d clean)
ok    helpers: match checkout
ok    policy: match checkout
ok    widget: match checkout
ok    widget engine: /home/you/src/kempt/bin/kempt

Recent events (kempt log):
  2026-08-26T21:10:55+03:00 widget config set auto_accept=true (was false)
  2026-08-26T21:11:02+03:00 widget run start surface=background
  2026-08-26T21:14:40+03:00 widget run done rc=0 updated=7 reboot=needed

kempt doctor: all checks passed
```

Lines are `ok`, `info`, `WARN` or `FAIL`. Only `FAIL` counts as a problem, and the last line counts
problems and warnings. One pass shows every problem. The last five events follow.

| Exit | When |
| --- | --- |
| 0 | No line is `FAIL`. |
| 1 | At least one line is `FAIL`. |

What a `FAIL` means:

| Check | FAIL means |
| --- | --- |
| The system uses dnf (second line) | An image-based Fedora, where `kempt update` stops (exit 5). Use Discover or `rpm-ostree upgrade`. |
| Both root helpers exist at the expected paths, `root:root` 0755 | `install.sh` has not run, or the helpers were replaced. Checks stay `stale`, updates cannot run. |
| The polkit action file is installed | Background checks cannot authorize. |
| Each polkit `exec.path` names the helper this CLI uses | Every privileged step asks for a password, and background checks time out after 120 s. Usually a package over a checkout install, or the reverse; the line names both fixes. `info` when the policy cannot be read. |
| `jq` is present | Always passes when doctor runs; without `jq` every command exits 3. |
| The terminal emulator (`$KEMPT_TERMINAL`) is present | `kempt run` exits 4. `info` when updates do not run in a terminal. |
| `flatpak` is present | Every check reports Flatpak stale. `info` when `include_flatpak=false`. |
| Kempt can list unused Flatpak runtimes (only when Flatpak is on and `reclaim` is not `off`) | Nothing can offer to free space. It fails when `flatpak-libs` or `python3-gobject-base` is missing, and says to install them. Other listing errors are `info`, with Flatpak's reason. |
| Every config line is `key=value` with a valid key | That line is ignored, so the setting never applies. |
| The state directory is writable | No state, history or logs. |
| The checkout still has `lib/`, `backends/` and the passwordless rules template | The checkout is damaged. |
| `helpers:`, `policy:`, `widget:` match the checkout | `DIFFER`: you pulled without re-running `./install.sh`, so root still runs the old helpers. `git pull` updates only the CLI. The line names the fix. `not installed` is `info`. |
| `widget engine:` (last on both kinds of install) names this `kempt` | A leftover `~/.local/bin/kempt` shadows the installed one, because the panel puts `~/.local/bin` first on its `PATH`. `info` when the widget finds none. |
| A staged update is ready for the restart, or absent | It was downloaded but will never install. Run `sudo dnf5 offline clean`. |
| `/system-update` is absent, or points at a ready update | The next restart starts the offline updater and installs nothing. Run `sudo dnf5 offline clean`. |

The **Discover's update notifier** row appears only when that notifier is installed. It is `ok`
when the notifier is off for you, and `info` when it starts with your session, naming
[`kempt discover-notifier off`](#discover-notifier) and the widget's
**Turn Off Discover's Notifier**. `./install.sh` offers the same. A second row says when Discover
installs updates on restart by itself. Its update then replaces yours, so the row is `WARN` when
Kempt installs on the next restart.

### The staged transaction

Doctor compares Kempt's record of a staged update with what dnf5 has stored, and prints nothing
here when neither exists.

| Line | What it means |
| --- | --- |
| `info  staged update: 61 packages install on the next restart` | Normal. |
| `FAIL  staged update can never install: the transaction was downloaded but never set to install ...` | Never set up for the restart. Run `sudo dnf5 offline clean` and stage again. |
| `FAIL  staged update can never install: dnf5 says "ready" but /system-update is gone ...` | A restart already skipped it, and no later restart will install it. |
| `FAIL  the stored Fedora release upgrade can never install: ...` | The same, for a release upgrade. `sudo dnf5 system-upgrade reboot` sets it up again. |
| `info  staged update: the transaction is gone, ...` | The next check clears Kempt's leftover record. |
| `info  an offline transaction is staged outside Kempt ...` | Something else staged it. `dnf5 offline status` describes it. |
| `info  dnf5 still keeps an offline transaction whose updates are already installed ...` | Another updater installed the same updates. It will not run. `kempt unstage` removes it. |
| `info  staged update: another updater has prepared the next restart ...` | The next restart installs that update, not Kempt's. |
| `info  another updater has prepared the next restart: /system-update points to ...` | Normal while Discover's notifier has an update ready. |
| `info  a Fedora release upgrade (44 -> 45) is staged outside Kempt and installs on the next restart ...` | A release upgrade is ready. `kempt update --surface=offline` stops while it is there. |
| `info  a Fedora release upgrade (44 -> 45) has been downloaded outside Kempt but not started ...` | No restart installs it yet. `sudo dnf5 system-upgrade reboot` starts it, `sudo dnf5 offline clean` drops it. |
| `info  a Fedora release upgrade (44 -> 45) is stored outside Kempt and was set to install, but the restart marker /system-update is not in place ...` | A restart already skipped it. See the FAIL row above. |
| `info  a Fedora release upgrade (44 -> 45) is stored outside Kempt and did not finish ...` | `sudo dnf5 offline log` says why. |
| `info  staged update: Kempt has a marker for a transaction that is no longer stored ...` | A release upgrade replaced Kempt's staged update. The next check clears the record. |
| `FAIL  boot symlink is live over a transaction that is not set to install ...` | The next restart starts the offline updater and installs nothing. |
| `FAIL  boot symlink is live with nothing staged behind it ...` | The same, with nothing stored at all. |
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
kempt holds [--exclude-args]
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

**Holds are Kempt's own list**, which a `sudo dnf5 upgrade` of your own ignores. `--exclude-args`
prints the dnf holds as one line of dnf5 arguments (an empty line with none):

```bash
kempt holds --exclude-args
```

```
--exclude=kernel-core --exclude=vim-common
```

```bash
sudo dnf5 upgrade $(kempt holds --exclude-args)
```

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
[staged banner](widget.md#the-staged-banner).

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
warning: 'bogus' is not a value surface accepts. Accepted: terminal, widget, background, offline
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

## enable-passwordless, disable-passwordless

```
kempt enable-passwordless
kempt disable-passwordless
```

Adds or removes a polkit rule that lets your active local session install updates without a
password. It covers dnf. Flatpak app updates never ask. Each command asks for your password once,
to write to `/etc/polkit-1`. Disabling when it was never enabled succeeds.
What the rule grants is in [security.md](security.md#passwordless-mode).

| Exit | When |
| --- | --- |
| 0 | Done, or there was nothing to disable. |
| 1 | `enable-passwordless` could not install the rule, for example because the password dialog was cancelled. |
| 2 | Any argument. Also `enable-passwordless` when it cannot build a valid rule for your user name. |
| other | `disable-passwordless` could not remove the rule, and passes on pkexec's code: 126 when the password dialog was dismissed, 127 when authorization was refused or failed. |

## discover-notifier

```
kempt discover-notifier off
kempt discover-notifier on
kempt discover-notifier keep
kempt discover-notifier status [--json]
```

Discover's update notifier counts updates on its own schedule, so its number can differ from
Kempt's, and its background work can make a Kempt run wait. These commands change it for you alone,
without a password. When it is not installed, `off`, `on` and `keep` say so and change nothing.

**`off`** writes `~/.config/autostart/org.kde.discover.notifier.desktop` with `Hidden=true`, so the
notifier stops starting at login, and stops the running one. A file of your own there moves to a
name ending in `.before-kempt`, and Kempt prints where. A symlink stays a symlink. Kempt keeps one
such copy and never overwrites it. When the notifier is already off, `off` says so and changes
nothing.

**`on`** removes Kempt's file and puts yours back. If you edited Kempt's file, your version moves to
a name ending in `.kempt-edited`, and Kempt prints where. Then it starts the notifier and says so
once it runs.

**`keep`** changes nothing, and records that you answered the widget's offer.

**`status`** says whether the notifier is installed, on, turned off by Kempt, and running. `--json`
prints `installed`, `enabled`, `running` and `by_kempt`, plus `entry` when the file keeping it off
is not Kempt's.

A file that `./install.sh` wrote before 0.1.8 counts as Kempt's while Discover's own startup file
is unchanged, so `on` removes it. Once Discover's file changes, it counts as your own. Delete it to
turn the notifier back on.

| Exit | When |
| --- | --- |
| 0 | Done, or nothing needed doing. |
| 1 | Nothing changed: `off` found a `.before-kempt` copy already there, `on` found a file of your own keeping the notifier off, the path is a directory, a broken symlink or a file Kempt cannot read, or the writers' lock was busy. |
| 2 | An unknown subcommand or option. |
