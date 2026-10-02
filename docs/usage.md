# Kempt commands

Most people use Kempt through its panel widget, which [widget.md](widget.md) covers. This page is
the reference for every `kempt` command: what it does, its options, its output and its exit codes.
The widget runs these same commands, so anything you do here shows up there too.

| Command | What it does |
| --- | --- |
| [`kempt check`](#check) | Finds what is pending, saves it and prints it as JSON |
| [`kempt update`](#update) | Installs the updates now, in this terminal, or stages them for the next restart |
| [`kempt run`](#run) | Starts an update where your settings say and returns at once. **Update Now** runs it. |
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
| `kempt help`, `--help`, `-h` | Prints the list of commands with a line each |

## A typical day

```bash
# Morning: what is waiting?
kempt check | jq '{actionable, held_total, risky: (.risky_pending | length)}'

# Something you never want updated automatically:
kempt hold dnf:nvidia-driver

# Kernel and Qt in the list? Stage it instead of rewriting a running desktop:
kempt update --surface=offline
# ... reboot when convenient; the transaction applies during boot ...

# After the reboot, the check records the result in history:
kempt check >/dev/null
kempt summary

# Or, on an ordinary day with nothing risky pending:
kempt update
```

## Exit codes

Every command uses the same codes. Each command's section lists the ones it uses.

| Code | Meaning |
| --- | --- |
| 0 | Success. This includes answering "abort" at the risky-transaction prompt, and a `check` without `--strict` whose backend failed (the state records the failure). |
| 1 | Something failed: a backend during `update`, a `check --strict` whose answer is not current, a problem `doctor` found, Flatpak during `reclaim` (even after removing some runtimes), or a command that could not take the writers' lock. |
| 2 | Usage error: unknown command, option or argument. |
| 3 | Cannot start: `jq` is missing, or another `kempt update` is running. |
| 4 | No terminal emulator, when updates run in a terminal window. |
| 5 | Stopped before changing anything: `update` on an image-based Fedora or with unreadable package lists; `update --surface=offline` or `unstage` while a Fedora release upgrade is stored; `run` when its terminal window never opened; `reclaim` when it may not remove anything. |
| 6 | `reclaim` only: the runtimes it would remove are not the set you were shown, or part of it became unused less than an hour ago. Nothing was removed. |
| 7 | `update` only: another program, such as PackageKit or Discover, held the dnf or Flatpak lock through all three tries. Try again in a few minutes. |

**The writers' lock.** `kempt config set`, `kempt hold`, `kempt unhold` and
`kempt discover-notifier off|on|keep` each rewrite a file in your home directory. They take a lock
at `~/.local/state/kempt/writer.lock` while they do it, so two at once cannot lose a write. The wait
is usually milliseconds. If the lock is still held after 30 seconds, the command writes nothing,
says so on stderr and exits 1. Commands that only read take no lock.

## check

```
kempt check [--refresh] [--coalesce] [--strict]
```

Asks every enabled backend what is pending, writes `~/.local/state/kempt/state.json`, and prints
the same JSON.

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

| Option | Effect |
| --- | --- |
| `--refresh` | Fetches package metadata now, ignoring the 3-hour interval. On battery or a metered connection it still skips the fetch, and the event log records that. The widget's **Check for Updates** passes it. Each part of the fetch, dnf and Flatpak, gives up after 2 minutes. |
| `--coalesce` | For checks nobody asked for by hand. If this check waits for another one, and that one succeeds after this one was asked for, its state is the answer. See below. |
| `--strict` | Exits 1 when the answer is not current: a backend failed, the apps for you only could not be listed, or the previous state was served. It prints the state first, as usual. Use it in scripts. |

**Where the answer comes from.** A check answers from the local dnf and Flatpak caches. Before
asking, it refreshes them at most once every 3 hours, and skips that on battery or a metered
connection. That refresh is the only part of a check that uses the network. On a fresh install the
cache is empty, so the first check refreshes before it asks. If it cannot, that backend reports
`stale` until a refresh succeeds. Old metadata shows in three places. The popup's footer says
`metadata N days old` after 24 hours. `kempt doctor` has a row for it. The event log records a
skipped refresh once a day.

**`--coalesce` in detail.** Only one check runs at a time, so a check may wait for another. With
`--coalesce`, a later check that succeeded answers for this one. Its state is printed as it is.
Nothing is queried or written, and the event log says `check shared`. "Later" means a later second,
because `last_check` has whole seconds. A check stamped in the same second runs a check of its own.
`--refresh` turns `--coalesce` off. The widget passes `--coalesce` for its timer, its file watcher,
the popup opening and its startup check, so two widgets cost one check. **Check for Updates**,
**Check again** and a hold always run a check of their own.

A check also records a staged update once the restart has installed it, and clears Kempt's record
of a stage that has gone.

Fields worth knowing:

- **`from`** is `?` when the update would install a new package. Packages with several versions
  installed at once, such as `kernel-core`, list them comma-joined, oldest first.
- **`reboot_needed`** says whether a restart is owed now. It clears once you restart. Treat `true`
  as "say so" and `false` as "nothing to say", because the check also answers `false` when it could
  not tell.
- **`download_bytes`** is the estimated download, per item (`size_bytes`), per backend and in
  total. A total appears only when every item that is not held has a size. A missing total means
  "unknown", which is different from zero.
- **`metadata_refreshed`** is when dnf metadata was last fetched. It differs from `last_check`,
  because a check answers from the local cache.

The full schema is in [architecture.md](architecture.md#state-json-schema-v1).

When something goes wrong, the output says so:

- **A backend fails** (network down, repo unavailable): `status` is `"stale"`, `error` holds the
  message, and the previous item lists are kept. When a root helper is missing, `error` says
  `root helper not installed - run ./install.sh (see: kempt doctor)`.
- **The state file is missing or corrupt:** the check starts from an empty list.
- **Another check holds the lock** for 60 seconds: the previous state is printed.
- **With `--coalesce`, another check answered:** its state is printed and `state.json` is not
  rewritten. Only a state whose `status` is `"ok"` is taken.

**Empty output with exit 0 means "no data, keep what you had".** It never means zero updates.

| Exit | When |
| --- | --- |
| 0 | The state was printed. Without `--strict`, this includes a failed backend and a served previous state. |
| 1 | The new state could not be saved. It is still printed first. With `--strict`, also a failed backend, apps for you only that could not be listed, or a served previous state. |
| 2 | Unknown option. |

With `--strict`, the state tells the exit-1 cases apart. `status` `"stale"` means a backend failed.
`status` `"ok"` with `.backends.flatpak.scopes.user` `"failed"` means the apps for you only could
not be listed. Anything else means the state could not be saved.

## update

```
kempt update [--no-flatpak] [--surface=terminal|popup|background|offline] [--risky-ok]
```

Runs the update now, in this process. Options come from the config file, and the flags override
them for this run.

```bash
kempt update                      # everything, per config
kempt update --no-flatpak         # this run: system packages only
kempt update --surface=offline    # stage it; applies on the next reboot
```

| Option | Effect |
| --- | --- |
| `--no-flatpak` | Updates system packages only, for this run. |
| `--surface=` | Where this run happens. An unknown value logs a warning and uses `terminal`. |
| `--risky-ok` | Leaves out the notification about session-critical packages for a run that cannot ask. The popup passes it after you choose **Install Now**. |

The `--surface=` values match **Run updates in** in the widget's settings:

| `--surface=` | Setting |
| --- | --- |
| `terminal` | **Terminal window** |
| `popup` | **In this widget** |
| `background` | **In the background** |
| `offline` | **On next reboot (offline)**, and the popup's **Install on Next Restart** |

With `auto_accept=false`, every run uses the terminal with live output, because only a terminal can
answer dnf's prompt.

What happens, in order:

1. **Risky-transaction check** (skipped for `offline`). If the update touches packages the running
   desktop depends on, a terminal run asks first:

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

   Up to eight families are listed, with `... and N more` below them. `s` stages the update for
   the next restart, `u` updates now and `a` aborts. **Enter, Ctrl-D or a second unknown answer all
   abort**, with exit 0 and nothing changed. A run that cannot ask sends a notification naming the
   families and carries on. `kempt check` publishes the same list as `risky_pending`.
2. **Lock.** A second update at the same time exits 3. The prompt comes before the lock, so an
   unanswered prompt blocks nothing.
3. **Snapshots** of the installed packages. If one cannot be read, the run exits 5 having changed
   nothing.
4. **dnf**, through the root helper, with `-y` when `auto_accept` is on and one `--exclude=` per
   dnf hold. If another program holds the package lock (PackageKit, Discover), Kempt tries 3 times,
   10 seconds apart, and names the likely holder.
5. **Flatpak**, unless turned off: the system apps, then the apps installed for you only, as you.
   With Flatpak holds, each pending app that is not held is updated on its own, and a hold covers
   the app in both places. If one of the two fails, the other still runs, and the summary says
   which failed. A busy Flatpak lock gets the same 3 tries.
6. **Report.** Kempt compares the snapshots, writes a history entry and a log, prints the summary,
   and sends a notification when the run was not in a terminal. The summary marks a failed backend
   with its status in brackets.

Kempt reads dnf5's history before and after the upgrade. When one new transaction matches the
command it ran, its id goes into the history entry as `transaction_id`, for `dnf5 history info`.
The run reports that transaction's package list, so packages another tool installed at the same
time are left out. A system-wide `flatpak update` also updates runtimes, and the summary lists
apps, so a run can change more than it lists.

**On an image-based Fedora, `update` stops.** Silverblue, Kinoite, Bazzite and bootc images update
as a whole image. Every run exits 5 having changed nothing, and says to use Discover or
`rpm-ostree upgrade` (`bootc upgrade` on a bootc image). Support for these images is planned.
Kempt detects them by the file `/run/ostree-booted`. `kempt doctor` reports it on its second line,
and the widget hides **Update Now**.

| Exit | When |
| --- | --- |
| 0 | Every backend succeeded, or you aborted at the prompt. |
| 1 | A backend failed. |
| 2 | Unknown option. |
| 3 | Another update is running. |
| 5 | Nothing changed: an image-based Fedora, unreadable package snapshots, or `--surface=offline` while a Fedora release upgrade is stored. |
| 7 | The only failure was a lock another program held through all three tries. |

### Installing on the next restart

`--surface=offline`, the popup's **Install on Next Restart**, downloads the whole update and stores
it. Nothing is installed while you work. It then tells the system to install it during the next
restart. Both steps happen under one password prompt, so **any** restart installs it: the popup's
**Restart…**, the K menu, or `reboot` a few days later. Kempt never restarts the machine itself.

A check runs just before staging, and its count is the one the popup and the event log report. If
that check fails, Kempt stages anyway and uses the previous count. Flatpak has no restart install,
so an offline run still updates Flatpak apps live.

Until the restart, the staged packages still show as pending, and the popup stops offering to stage
them again. It says:

```
61 updates are staged - they install on the next restart
```

**When staging fails.** If the update was stored but could not be set up for the restart, Kempt
discards it and the run fails with `staged but could not arm the restart install`. Staging again
replaces the previous staged update, and a failure leaves one of two results:

- The download failed before anything was replaced. The previous staged update still installs. The
  run fails with `could not rebuild the staged update - the previous one is unchanged and still
  installs on the next restart`.
- The previous one was already gone. The run fails with `the previous staged update was discarded
  and could not be rebuilt`, and Kempt cleans up so the restart installs nothing. If that cleanup
  fails too, the notification tells you to run `sudo dnf5 offline clean`.

**When a Fedora release upgrade is stored, `--surface=offline` stops** with exit 5. dnf5 keeps one
stored transaction, so staging would cancel the release upgrade. The message names the way out for
the state the upgrade is in: restart, `sudo dnf5 system-upgrade reboot`, `sudo dnf5 offline log`,
or `sudo dnf5 offline clean`. The risky-transaction prompt then offers only `[u]` and `[a]`. Live
updates still work.

**When the staged update will not install.** A restart may have skipped it. Or you installed
something with dnf yourself while it waited, which removes the restart trigger while dnf5 still
calls the stored update `ready`. Either way, the next check tells you once:

```
Your staged update can no longer install on a restart. Re-stage it, or run sudo dnf5 offline clean.
```

To fix it, stage again (`kempt update --surface=offline`) or clear it.

**A live update replaces the stage.** A staged update is built against the installed packages.
When a live `kempt update` changes any rpm, Kempt discards the stage, because it could only fail at
boot. A Flatpak-only run leaves it alone.

**Other tools.** If `dnf-automatic`, GNOME Software or a terminal `dnf5 upgrade` changes packages
while an update is staged, Kempt leaves the stage in place and records it once. If something
replaces the staged update outside Kempt, the next check tells you once. After the restart, Kempt
finds its transaction in dnf5's history and reports only that. If it did not run, the history
entry and the notification say `restart (staged update did not run)`.

### A snapshot before every update

dnf5 can take a snapshot before each transaction, so Kempt has no snapshot setting of its own. Its
actions plugin runs a command before every transaction, whether Kempt started it or you ran `dnf5`
in a terminal.

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
kempt run [--print-command] [--surface=terminal|popup|background|offline] [--risky-ok]
```

Starts `kempt update` where your settings say, then returns at once. **Update Now** runs it. In a
terminal you can run `kempt update` directly.

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
| `--surface=` | Runs this one update somewhere else, whatever the setting says. **Install on Next Restart** runs `kempt run --surface=offline`. An unknown value exits 2. |
| `--risky-ok` | Passed on to an update that runs outside a terminal. The popup adds it when you choose **Install Now** for session-critical updates. A terminal run still asks. |

With `auto_accept=false`, a stage opens in a terminal so dnf5 can ask first, and any other surface
becomes a live update in a terminal.

**Exit 0 means the update started.** Read `state.json` or `kempt history` for the result. When the
terminal window closes, it runs a check, whether the update finished, failed or was aborted, or the
window was closed early. That check is what ends the widget's updating state. The window's shell
exits with the update's status.

| Exit | When |
| --- | --- |
| 0 | The update started. |
| 2 | Unknown option or `--surface=` value. |
| 3 | Another update is already running. Nothing is launched. |
| 4 | The terminal emulator is missing. `--print-command` checks this too. |
| 5 | The terminal window never opened, for example over SSH with no display. `run` waits up to five seconds for it. The event log says `run did not start: <reason>`, and a window that opens later starts nothing. |

## unstage

```
kempt unstage
```

Discards the staged update, so the next restart installs nothing. It undoes
`kempt update --surface=offline`. The popup's **Discard Staged Update** runs it.

```
Discarded the staged update. The next restart installs nothing.
```

It asks for your password once. With nothing staged, it says so and exits 0 without asking. Kempt
clears its own record of the stage only once dnf5 confirms the transaction is gone.

| Exit | When |
| --- | --- |
| 0 | Discarded, or nothing was staged. |
| 1 | dnf5 still has the transaction. Kempt keeps its record. |
| 2 | Any argument. |
| 3 | Another update is running. |
| 5 | A Fedora release upgrade is stored. Discarding would cancel it, so nothing changes. |

## reclaim

```
kempt reclaim [--list] [-y] [--expect=DIGEST]
```

Removes the Flatpak runtimes no installed app uses. They pile up as apps move to newer runtimes, and
each can take hundreds of megabytes. Only system runtimes are removed. Kempt leaves the ones
installed for you only alone.

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
| `--expect=DIGEST` | Removes only if the list is still the set with this digest, the 16-character `reclaim.digest` from `kempt check`. The widget's **Free Up Space** uses it. |

What it removes:

- **Only what Flatpak calls unused.** Kempt removes the runtimes on Flatpak's list and nothing else.
  An extension another installed runtime still uses stays. The size is an estimate.
- **Only after an hour.** A runtime must have been unused for an hour, so one another tool is
  installing is left alone. The hour starts at the first check that lists it. If no check has run
  yet, `kempt reclaim` runs one and says to try again in an hour.
- **Runtimes first, then their extensions**, such as translations (`.Locale`) and graphics drivers
  (`.GL`). Kempt lists again between the two, so an app you install meanwhile keeps its runtime and
  its extensions. If Flatpak removes one of that app's extensions anyway, Kempt says so. Run
  `flatpak update` to put it back.
- **Never a pinned runtime.** To keep one Kempt lists, pin it:
  `flatpak pin runtime/org.kde.Platform/x86_64/5.15-23.08`.

It never asks for a password. Removing needs an administrator (on Fedora, a member of the `wheel`
group) logged in at the desktop. Over the network, or from an account that is not an administrator,
nothing is removed. Run `kempt reclaim` from an administrator's desktop session instead. Run it as
yourself, too. As root or with `sudo`, Flatpak cannot see your own apps, so Kempt removes nothing.

With `reclaim=automatic` (see [configuration](configuration.md#keys)), a successful update removes
the offered set for you, and its summary says how much was freed. In a terminal, the update prints
the outcome under the **Unused Flatpak runtimes** heading. A removal writes an event line and no
history entry.

| Exit | When |
| --- | --- |
| 0 | Removed, nothing to remove, or you answered no. |
| 1 | Flatpak could not list or remove the runtimes. If it stopped part-way, Kempt says how much it freed. If the list afterwards could not be read, it says the removal may be partial: run `kempt reclaim --list`. |
| 2 | Unknown option, or a digest that is not 16 hex characters. |
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
run, `2` the one before. If you ask for more runs than exist, it shows the oldest and says so on
stderr.

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

When holds kept packages back, a line says what they cost:

```
9 pending packages did not move because of holds
```

With an update staged, one more line says what the next restart will do:

```
Staged: 61 updates install on the next restart
```

That line comes from the current state, so `--json` leaves it out. Scripts read `offline_staged`
from `kempt check`.

With no runs recorded, `summary` prints `no update runs recorded yet`. A damaged entry is skipped
with a warning, and the one before it is shown.

`summary --json` prints the newest run's history entry and nothing else. The widget reads it. It
takes no `N`. **If there are no runs, or the newest entry is damaged, it prints nothing.** A damaged
entry is named on stderr, and no older run is shown in its place.

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

`history` lists past runs, newest first: time, how it ran, status, and what changed. The last
column uses the same wording as the notifications. A failed run shows its reason in brackets.

```bash
kempt history
```

```
2026-08-24T21:05:11+03:00  terminal  ok  3 updated, +1 installed
2026-08-23T09:41:02+03:00  offline (applied on reboot)  ok  41 updated
2026-08-22T18:12:55+03:00  background  failed  no package changes  (authentication cancelled)
```

`history --json` prints every run as one JSON array, newest first. Each element is the entry
`summary --json` prints for that run. With no runs it prints `[]`. A damaged entry is left out and
named on stderr. The format is in [architecture.md](architecture.md#history-entries).

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

Each line is `<timestamp> <via> <what happened>`. `via` is `widget` for the Plasma widget and `cli`
for anything else, such as a terminal, a script or a timer.

| Exit | When |
| --- | --- |
| 0 | Always, including an empty log. |
| 2 | `-n` without a positive whole number, or an unknown option. |

The file is `~/.local/state/kempt/events.log`, mode 0600. Past 2500 lines it is trimmed to the last
2000. The wording is fixed, so you can search it:

| Line | Written when |
| --- | --- |
| `config set <key>=<value> (was <old>)` | A setting changed. `(was unset)` when it had no value. |
| `hold <backend>:<name>` / `unhold <backend>:<name>` | A hold was added or removed. |
| `check ok actionable=<n> held=<n>` | A check succeeded. The numbers are what the badge shows next. |
| `check stale <reason>` | A check failed, for example `dnf check failed: no authentication agent is running to ask for the password`. |
| `check shared last_check=<time>` | A `--coalesce` check took the answer of the check stamped `<time>` and asked nothing itself. Not a check: it changes no counts. |
| `refresh ok` / `refresh failed` | The dnf metadata refresh ran (at most every three hours, on mains power and an unmetered connection). |
| `refresh flatpak ok` / `refresh flatpak failed` | The Flatpak metadata refresh ran, in the same step. Only while `include_flatpak` is on. Either can fail without stopping the other. |
| `refresh skipped (<reason>)` | A refresh was skipped on battery or a metered connection. At most once a day. |
| `run start surface=<surface>` | A run is about to change the system. |
| `run did not start: <reason>` | A run stopped before changing anything: an image-based system, a stored Fedora release upgrade, unreadable package lists, or a terminal window that never opened. Exit 5. |
| `run done rc=0 updated=<n> reboot=needed\|no` | A run finished. |
| `run failed rc=<n>: <reason>` | A run failed, with the first log line that names the failure. |
| `offline staged <n>` | An update was staged for the next restart. |
| `offline restage` / `offline restage failed (previous stage intact)` | A new stage replaced the previous one, or failed and left it in place. The first names the holds that prompted it. |
| `offline stage dropped (superseded by live update)` | A live update changed packages, so the staged update was discarded. |
| `offline stage cannot install (...) - announced` | The staged update can no longer install on a restart. Said once. |
| `offline stage replaced outside Kempt (<what differs>) - announced` | The staged update is no longer the one Kempt made. Said once. |
| `offline marker cleared\|dropped\|kept (<why>)` | Kempt's record of a staged update was removed, or kept because a newer stage arrived during a check. |
| `harvest applied (<counts>)` | After a restart, the staged update had installed and went into history. |
| `harvest found the staged transaction did not run (<counts>)` | After a restart, a different transaction had run. The history entry says `restart (staged update did not run)`. |
| `harvest skipped snapshot failed` / `harvest cleared stale marker` | The other two outcomes after a restart. |
| `harvest deferred: packages moved outside Kempt while the stage is still armed` | Another tool changed packages while an update was staged. Said once. |
| `harvest entry not written (state directory unwritable?)` / `history entry not written (state directory unwritable?)` | The history entry could not be saved. The run itself is unaffected. |
| `harvest log not written (state directory unwritable?)` | The log for a restart install could not be saved, so the popup shows no **Show Log** for that run. |
| `unstage discarded the staged update` | `kempt unstage` removed the staged update. |
| `unstage refused (<what is stored>)` / `unstage refused by the root helper` | `kempt unstage` changed nothing, because a Fedora release upgrade is stored. Exit 5. |
| `unstage found nothing staged` | Nothing was staged. |
| `unstage cleared a marker with no transaction under it` | The staged update was already gone, so only Kempt's record was removed. |
| `unstage failed rc=<n>` | The staged update could not be discarded. |
| `unstage left a transaction behind (status <status>)` | dnf5 still reports a stored transaction, so Kempt kept its record. |
| `reclaim removed <n> runtimes (<bytes> bytes) rc=<n>` | Unused runtimes were removed, by `kempt reclaim` or after an update. `, not all of them: <error>`: Flatpak stopped part-way. `, in use: <id>//<branch>`: extensions an app uses were removed; `flatpak update` puts them back. |
| `reclaim found nothing to remove` | Nothing was unused when the removal after an update ran. |
| `reclaim changed (<why>), nothing removed` | The list was not the set agreed to (`digest`), part of it was unused for less than an hour (`unstable`), or it held a runtime installed during the update (`new`). |
| `reclaim needs authorization, nothing removed` | Removing them needed an administrator (see [reclaim](#reclaim)), so nothing was removed. |
| `reclaim failed rc=<n>: <error>` / `reclaim failed (flatpak did not answer)` | Flatpak could not remove the runtimes, or could not list them. `<error>` is Flatpak's own line, if any. `<n>` is `?` when the list could not be read. `, what was removed is unknown`: Flatpak failed and the list afterwards could not be read. |
| `reclaim refused (running as root)` / `reclaim refused (reclaim=off)` | `kempt reclaim` removed nothing, because it ran as root or the setting is off. Exit 5. |
| `passwordless enable rc=<n>` / `passwordless disable rc=<n>` | `enable-passwordless` or `disable-passwordless` finished. |
| `discover-notifier off` / `discover-notifier on` / `discover-notifier keep` | Discover's update notifier was turned off, or back on, for this user, or kept as it was when the widget's offer was answered. |

### Which question, which file

| What you want to know | Where to look |
| --- | --- |
| What happened, when, and whether it came from the widget | `kempt log` |
| What the package manager printed during a run | The run log, `~/.local/state/kempt/logs/<stamp>.log`. `kempt summary` prints its path for a failed run, and each history entry has it in `log`. For an update installed during a restart, the log is Kempt's own record of what changed, and says so at the top. |
| One run in detail: versions, counts, held items, duration | `~/.local/state/kempt/history/<stamp>.json`, listed by `kempt history` |
| What is pending now | `~/.local/state/kempt/state.json`, written by `kempt check` |
| Widget errors, such as a settings page that will not load | `journalctl --user -b \| grep -i kempt`, and the error shown on the settings page |

When a run fails at the password prompt, the summary, history, event log and notification give one
of four reasons. The run log keeps pkexec's own wording.

| Kempt says | What happened |
| --- | --- |
| `authentication cancelled` | The password dialog was closed. |
| `not authorized - the password was refused, or this session cannot authorize (over SSH or switched away)` | The password was wrong, or the session cannot authorize at all: a remote session, or one that is not the active one. pkexec reports both the same way. |
| `no authentication agent is running to ask for the password` | Nothing on the desktop could ask for the password. |
| `cannot reach polkit (no system bus or polkit service), so nothing can be authorized` | pkexec could not reach polkit, for example in a container or with `polkit.service` stopped. |

## doctor

```
kempt doctor
```

Checks this install and prints one line per check. Use it when the widget shows nothing pending and
you are unsure why: a missing root helper makes `kempt check` report zero updates with exit 0.

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

Lines are `ok`, `info` or `FAIL`. Only `FAIL` changes the exit code. Every check runs, so one pass
shows every problem. The last five events follow the checks, for context.

A packaged install prints `install: packaged` in place of the `helpers:`, `policy:` and `widget:`
lines, and no commit on the `version:` line. That sample is in [install.md](install.md#verify-it).

| Exit | When |
| --- | --- |
| 0 | Every check passed. `info` lines do not count. |
| 1 | At least one line is `FAIL`. |

What each check means when it fails:

| Check | FAIL means |
| --- | --- |
| The system uses dnf (second line) | This is an image-based Fedora. Use Discover or `rpm-ostree upgrade`; `kempt update` stops here (exit 5). |
| Both root helpers exist at the expected paths, `root:root` 0755 | `install.sh` has not run, or the helpers were replaced. Checks stay `stale` and updates cannot run. |
| The polkit action file is installed | Background checks cannot authorize. |
| Each polkit `exec.path` names the helper this CLI uses | Every privileged step asks for a password, and background checks time out after 120 s. Usually a package installed over a checkout install, or the reverse. The line names both fixes. `info` when the policy cannot be read. |
| `jq` is present | Always passes when doctor runs; without `jq` every command exits 3. |
| The terminal emulator (`$KEMPT_TERMINAL`) is present | `kempt run` exits 4. `info` when updates do not run in a terminal. |
| `flatpak` is present | Every check reports Flatpak stale. `info` when `include_flatpak=false`. |
| Kempt can list unused Flatpak runtimes | `kempt reclaim` and the widget cannot offer to free space. When `flatpak-libs` or `python3-gobject-base` is missing, the line fails and says to install them. Any other listing error is an info line with Flatpak's reason. Runs only when Flatpak is on and `reclaim` is not `off`. |
| Every config line is `key=value` with a valid key | That line is ignored, so the setting never applies. |
| The state directory is writable | No state, history or logs. |
| The checkout still has `lib/`, `backends/` and the passwordless rules template | The checkout is damaged. |
| The installed helpers, polkit action and widget match the checkout | You pulled without re-running `./install.sh`, so root still runs the old helpers. |
| The `kempt` the widget runs is this one | A leftover `~/.local/bin/kempt` shadows the installed one for the panel. `info` when the widget finds no `kempt` at all. |
| A staged update is ready for the restart, or absent | It was downloaded but will never install. Run `sudo dnf5 offline clean`. |
| `/system-update` is absent, or points at a ready update | The next restart starts the offline updater and installs nothing. Run `sudo dnf5 offline clean`. |

The **Discover's update notifier** row appears only when Discover's notifier is installed. It is
`ok` when the notifier is turned off for you, and `info` when it starts with your session. The two
tools can show different counts, and Discover's background work can make a Kempt run wait. The line
names `kempt discover-notifier off` and the widget's **Turn Off Discover's Notifier** button.
`./install.sh` offers the same. See [discover-notifier](#discover-notifier).

### The staged transaction

Doctor compares Kempt's record of a staged update with what dnf5 has stored. It prints nothing here
when neither exists.

| Line | What it means |
| --- | --- |
| `info  staged update: 61 packages install on the next restart` | Normal. |
| `FAIL  staged update can never install: the transaction was downloaded but never armed ...` | It was never set up for the restart. Run `sudo dnf5 offline clean` and stage again. |
| `FAIL  staged update can never install: dnf5 says "ready" but /system-update is gone ...` | A restart already skipped it, and no later restart will install it. |
| `FAIL  the stored Fedora release upgrade can never install: ...` | The same, for a release upgrade. `sudo dnf5 system-upgrade reboot` sets it up again. |
| `info  staged update: the transaction is gone, ...` | Kempt's record outlived the update. The next check clears it. |
| `info  an offline transaction is staged outside Kempt ...` | Something else staged it. `dnf5 offline status` describes it. |
| `info  a Fedora release upgrade (44 -> 45) is staged outside Kempt and installs on the next restart ...` | A release upgrade is ready. `kempt update --surface=offline` stops while it is there. |
| `info  a Fedora release upgrade (44 -> 45) has been downloaded outside Kempt but not started ...` | No restart installs it yet. `sudo dnf5 system-upgrade reboot` starts it, `sudo dnf5 offline clean` drops it. |
| `info  a Fedora release upgrade (44 -> 45) is stored outside Kempt and was armed, but the restart marker /system-update is not in place ...` | A restart already skipped it. See the FAIL row above. |
| `info  a Fedora release upgrade (44 -> 45) is stored outside Kempt and did not finish ...` | `sudo dnf5 offline log` says what happened. |
| `info  staged update: Kempt has a marker for a transaction that is no longer stored ...` | A release upgrade replaced Kempt's staged update. The next check clears the record. |
| `FAIL  boot symlink is live over a transaction that is not armed ...` | The next restart starts the offline updater and installs nothing. |
| `FAIL  boot symlink is live with nothing staged behind it ...` | The same, with nothing stored at all. |
| `info  staged update: it installs kernel-core on the next restart despite the hold ...` | You held the package after staging. Rebuild with `kempt update --surface=offline`, or remove it with `sudo dnf5 offline clean`. |
| `info  staged update: it may still install held packages on the next restart ...` | The same, when Kempt cannot read what the staged update contains and you hold a dnf package. |
| `FAIL  staged update is not the one Kempt built ...` | Something replaced it. The line lists up to four differences each way (`+` only in dnf5's, `-` only in Kempt's). |
| `info  staged update: the marker cannot be read ...` | Kempt's record is damaged. It is left in place. |

### The install lines

`version:` names the release. In a git checkout it adds the commit and whether the tree is `clean`
or `dirty`. Quote this line in bug reports.

`helpers:`, `policy:` and `widget:` compare the installed copies with the checkout. In a checkout
install, `git pull` updates the CLI at once, but the root helpers, polkit action and widget change
only when `./install.sh` runs. `DIFFER` is a `FAIL` and names the fix. `not installed` is `info`.

A packaged install prints `install: packaged` and compares nothing, because the package manager
keeps those files in step. See [docs/RELEASING.md](RELEASING.md). It fails if a widget copy in your
home directory shadows the packaged one.

`widget engine:` comes last on both kinds of install. The panel puts `~/.local/bin` first on its
`PATH`, so it may run a different `kempt` from the one that printed this report. This line names
the one it runs.

## hold, unhold, holds

```
kempt hold   dnf:<package> | flatpak:<app.id>
kempt unhold dnf:<package> | flatpak:<app.id>
kempt holds [--exclude-args]
```

A hold means **skip it, but keep telling me about it**. Kempt skips held items in every run. They
still appear in the state with `"held": true` and count toward `held_total`, not `actionable`. Each
run lists them as `Held (skipped): ...`.

```bash
kempt hold dnf:kernel-core
kempt hold flatpak:org.gimp.GIMP
kempt holds
```

```
dnf:kernel-core
flatpak:org.gimp.GIMP
```

The `dnf:` or `flatpak:` prefix is required. Names are checked when you add them. Adding a hold
twice, or removing one that is not there, succeeds.

**Flatpak runtimes cannot be held.** Apps share them, so holding one would stop the apps that need
it. Kempt refuses and writes nothing:

```
org.kde.Platform is a Flatpak runtime, and runtimes cannot be held: apps share them, so holding one breaks the next app that needs it. Hold the app instead.
```

A runtime hold already in your holds file is ignored. Remove it with `kempt unhold flatpak:<id>`.

**Holds are Kempt's own list.** A `sudo dnf5 upgrade` you run yourself ignores them. To pass them
on, `--exclude-args` prints the dnf holds as one line of dnf5 arguments. With none it prints an
empty line.

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
| 1 | The writers' lock was busy for 30 seconds. Nothing was written. |
| 2 | No `dnf:` or `flatpak:` prefix (`use dnf:<pkg> or flatpak:<app.id>`), an invalid name, a Flatpak runtime, or an unknown option. Nothing was written. |

### Holding a package that is already staged

A hold applies from the **next** update Kempt builds. dnf5 cannot change an update it has already
stored, so if one is staged, the next restart still installs the package. The hold is recorded
anyway, and the command prints a warning on stderr and exits 0:

```
The staged update still contains kernel-core and installs it on the next restart.
When ready: kempt update --surface=offline (rebuilds it with your holds) or sudo dnf5 offline clean (removes it).
```

`kempt update --surface=offline` rebuilds the staged update with your holds, and asks for your
password. `sudo dnf5 offline clean` removes the staged update, so the next restart installs nothing.

If Kempt cannot read what the staged update contains, it warns anyway:

```
The staged update was built before this hold and may still install kernel-core on the next restart. Rebuilding applies all current holds.
When ready: kempt update --surface=offline (rebuilds it with your holds) or sudo dnf5 offline clean (removes it).
```

`kempt unhold` warns the other way, when the staged update was built without the package:

```
The staged update was built without kernel-core - the next restart will not install it. Rebuild when ready: kempt update --surface=offline.
```

Once the restart installs the staged update, the hold works as usual. The widget shows the same
warning on its staged banner (see [widget.md](widget.md#the-staged-banner)).

## config

```
kempt config get <key> [default]
kempt config set <key> <value>
```

Reads or writes a setting. The widget's settings use the same command. `get` returns the built-in
default for a known key, or your `default` argument if you give one. Every key is described in
[configuration.md](configuration.md).

```bash
kempt config get surface           # terminal
kempt config set surface offline
kempt config get refresh_interval_min   # 60
```

`set` warns on stderr about a key it does not know, or a value a key does not accept. It still
stores it and exits 0, so a newer widget can use keys this version does not know:

```
warning: 'bogus' is not a value surface accepts. Accepted: terminal, popup, background, offline
```

Setting `surface` also answers the widget's one-time offer to run updates in the widget.

| Exit | When |
| --- | --- |
| 0 | Read or written, including a warning about an unknown key or value. |
| 1 | The writers' lock was busy for 30 seconds. Nothing was written. |
| 2 | A key that does not match `^[a-z][a-z0-9_]+$`, a value longer than one line, or a missing argument. |

## --version

```bash
kempt --version        # kempt 0.1.x
kempt version          # the same
kempt -V               # the same
```

The number comes from the `VERSION` file. Without that file it prints `kempt unknown` and keeps
working. For a bug report, `kempt doctor` is more useful: it opens with the version and where it
was read from.

## enable-passwordless, disable-passwordless

```
kempt enable-passwordless
kempt disable-passwordless
```

Adds or removes a polkit rule that lets your active local session install updates without a
password. It covers dnf. Flatpak app updates never ask. Each command asks for your password once,
to write to `/etc/polkit-1`. Neither takes arguments. Disabling when it was never enabled succeeds.
What the rule grants is in [security.md](security.md#passwordless-mode). The widget's
**Allow without password…** and **Require a password…** run these.

| Exit | When |
| --- | --- |
| 0 | Done, or there was nothing to disable. |
| 1 | `enable-passwordless` could not install the rule, for example because the password dialog was cancelled. |
| 2 | `enable-passwordless` could not build a valid rule for your user name. |
| other | `disable-passwordless` passes on pkexec's own code when the rule could not be removed, such as 126 for a cancelled dialog. |

## discover-notifier

```
kempt discover-notifier off
kempt discover-notifier on
kempt discover-notifier keep
kempt discover-notifier status [--json]
```

Discover's update notifier counts updates on its own schedule, so its number can differ from
Kempt's. These commands change it for you alone and never ask for a password. When Discover's
notifier is not installed, `off`, `on` and `keep` say so and change nothing.

**`off`** writes `~/.config/autostart/org.kde.discover.notifier.desktop` with `Hidden=true`, so
the notifier stops starting at login. It also stops the running one. If you had your own file
there, Kempt moves it to a name ending in `.before-kempt` and prints where. A symlink stays a
symlink. Kempt keeps one such copy and never overwrites it. When the notifier is already off, by
any file, `off` changes nothing and says so.

**`on`** removes the file Kempt wrote and puts yours back as it was. If you edited Kempt's file,
your version moves to a name ending in `.kempt-edited`, and Kempt prints where. Then it starts the
notifier for this session and says so once it runs.

**`keep`** changes nothing, and records that you answered the widget's offer. The widget's
**Keep Discover's Notifier** runs it.

**`status`** says whether the notifier is installed, on, turned off by Kempt, and running. `--json`
prints one object with `installed`, `enabled`, `running` and `by_kempt`, plus `entry` when the
file that keeps it off is not Kempt's.

A file that `./install.sh` wrote before 0.1.8 counts as your own. Delete it to turn the notifier
back on.

| Exit | When |
| --- | --- |
| 0 | Done, or nothing needed doing. |
| 1 | Nothing changed: `off` found a `.before-kempt` copy already there, `on` found a file of your own keeping the notifier off, the file's path is a directory or a symlink to nothing, or the writers' lock was busy. |
| 2 | An unknown subcommand or option. |
