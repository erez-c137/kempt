# Using Kempt

Every command is `kempt <subcommand>`. `kempt help` prints the same list.

```
check [--refresh]     refresh pending-updates state (JSON to stdout). --refresh fetches package
                      metadata now, ignoring the 3-hour interval but never the battery or
                      metered-connection rules
update                run the update now (options from config; --no-flatpak, --surface=X override)
run [--print-command] launch update per configured surface (what the widget calls)
summary [N]           human summary of the last (or Nth-last) run
summary --json        the newest run's history entry, verbatim JSON (nothing if no runs yet,
                      or if the newest entry is damaged)
history               list past runs
log [-n N]            recent events: what Kempt did, when, and from where (default 30)
doctor                check this install: helpers, polkit action, tools, config, state
hold dnf:<pkg> | flatpak:<app.id>     skip in updates, still notify
unhold <same>         remove a hold
holds [--exclude-args]  list holds; --exclude-args prints the dnf ones as dnf5 --exclude=
                      arguments, on one line, to reuse by hand
unstage               discard the staged offline update; the next restart installs nothing
config get|set        read/write settings
enable-passwordless | disable-passwordless
--version | version | -V   print the version and exit
help | --help | -h    print this list
```

## Exit codes

Every command uses the same codes:

| Code | Meaning |
| --- | --- |
| 0 | Success. This includes answering "abort" at the risky-transaction prompt, and a `check` whose backend failed (the failure is recorded in the state). |
| 1 | The run failed (a backend returned non-zero), `doctor` found a problem, or a command could not take the writers' lock. |
| 2 | Usage error: unknown command, option or argument. |
| 3 | Cannot start: `jq` is missing, or another `kempt update` is running. |
| 4 | No terminal emulator, when updates run in a terminal window. |
| 5 | Stopped before changing anything: `update` on an image-based Fedora; `update --surface=offline` or `unstage` while a Fedora release upgrade is stored; or `run` when the terminal window it launched never opened. |

`kempt config set`, `kempt hold` and `kempt unhold` each rewrite a file in your config directory.
They take a lock at `~/.local/state/kempt/writer.lock` while they do it, so two at once cannot
lose a write. The wait is usually milliseconds. If the lock is still held after 30 seconds, the
command writes nothing, says so on stderr and exits 1. Commands that only read take no lock.

## check

```
kempt check [--refresh]
```

Asks every enabled backend what is pending, writes `~/.local/state/kempt/state.json`, and prints
the same JSON. `--refresh` is the only option.

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

A few fields worth knowing:

- **`from`** is `?` when the update would install a new package. Packages with several versions
  installed at once, such as `kernel-core`, list them comma-joined, oldest first.
- **`reboot_needed`** says whether a restart is owed now. It clears once you restart. Treat
  `true` as "say so" and `false` as "nothing to say", because the check also answers `false` when
  it could not tell.
- **`download_bytes`** is the estimated download, per item (`size_bytes`), per backend and in
  total. The widget shows the total next to **Update Now**. A total appears only when every
  non-held item has a size. A missing total means "unknown", which is different from zero.
- **`metadata_refreshed`** is when package metadata was last fetched. It differs from
  `last_check`, because a check answers from the local cache.

The full schema is in [architecture.md](architecture.md#state-json-schema-v1).

**Where the answer comes from.** A check answers from the local dnf and Flatpak caches. Before
asking, it refreshes them at most once every 3 hours, and skips that on battery or on a metered
connection. That refresh is the only part of a check that uses the network. On a fresh install
the cache is empty, so the first check refreshes before it asks. If it cannot, that backend
reports `stale` until a refresh succeeds.

Old metadata shows up in three places. The popup's footer says `metadata N days old` after 24
hours, `kempt doctor` has a row for it, and a skipped refresh goes into the event log once a day.

**`--refresh`** fetches now, ignoring the 3-hour interval. On battery or a metered connection it
still skips the fetch, and the event log records it.

A check also records a staged update once the restart has installed it, and clears Kempt's
record of a stage that has gone.

### What a script can rely on

- **A backend fails** (network down, repo unavailable): exit 0, `status` is `"stale"`, `error`
  holds the message, and the previous item lists are kept. When a root helper is missing,
  `error` says `root helper not installed - run ./install.sh (see: kempt doctor)`.
- **The state file is missing or corrupt:** exit 0, and the check starts from an empty list.
- **The new state cannot be saved:** the state is printed first, then the command exits non-zero.
- **Another check holds the lock** for 60 seconds: the previous state is printed, exit 0.

**Empty output with exit 0 means "no data, keep what you had".** It never means zero updates.

## update

```
kempt update [--no-flatpak] [--surface=terminal|popup|background|offline]
```

Runs the update now, in this process. Options come from the config file, and the flags override
them for this run. An unknown option exits 2. An unknown `--surface=` value logs a warning and
uses `terminal`.

```bash
kempt update                      # everything, per config
kempt update --no-flatpak         # this run: system packages only
kempt update --surface=offline    # stage it; applies on the next reboot
```

The `--surface=` values match **Run updates in** in the settings:

| Value | Setting |
| --- | --- |
| `terminal` | **Terminal window** |
| `popup` | **In this widget** |
| `background` | **In the background** |
| `offline` | **On next reboot (offline)**, and the popup's **Install on Next Restart** |

With `auto_accept=false`, every run uses the terminal with live output, because only a terminal
can answer dnf's prompt.

What happens, in order:

1. **Risky-transaction check** (skipped for `offline`). If the update touches packages the
   running desktop depends on, a terminal run asks first:

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
   the next restart, `u` updates now and `a` aborts. **Enter, Ctrl-D or a second unknown answer
   all abort**, with exit 0 and nothing changed. A run that cannot ask sends a notification naming
   the families and carries on. `kempt check` publishes the same list as `risky_pending`.
2. **Lock.** A second update at the same time exits 3. The prompt comes before the lock, so an
   unanswered prompt blocks nothing.
3. **Snapshots** of the installed packages. If one cannot be read, the run exits 5 having changed
   nothing.
4. **dnf**, through the root helper, with `-y` when `auto_accept` is on and one `--exclude=` per
   dnf hold. If another program holds the package lock (PackageKit, Discover), Kempt tries 3
   times, 10 seconds apart, and names the likely holder.
5. **Flatpak**, unless turned off. With Flatpak holds, each pending app that is not held is
   updated on its own.
6. **Report.** Kempt compares the snapshots, writes a history entry and a log, prints the
   summary, and sends a notification when the run was not in a terminal.

Exit 0 when every backend succeeded, 1 when one failed. The summary marks a failed backend with
its status in brackets.

Kempt reads dnf5's history before and after the upgrade. When one new transaction matches the
command it ran, its id goes into the history as `transaction_id`, for `dnf5 history info`. Its
package list is what the run reports, so packages another tool installed at the same time are
left out.

A system-wide `flatpak update` also updates runtimes. The summary lists apps, so a run can change
more than it lists.

**On an image-based Fedora, `update` stops.** Silverblue, Kinoite, Bazzite and bootc images
update as a whole image. Every run exits 5 having changed nothing, and says to use Discover or
`rpm-ostree upgrade` (`bootc upgrade` on a bootc image). Support for these images is planned.
Kempt detects them by the file `/run/ostree-booted`. `kempt doctor` reports it on its second line,
and the widget hides **Update Now**.

### Installing on the next restart

`--surface=offline`, the popup's **Install on Next Restart**, downloads the whole update and
stores it. Nothing is installed while you work. It then tells the system to install it during the
next restart. Both steps happen under one password prompt, so **any** restart installs it: the
popup's **Restart…**, the K menu, or `reboot` a few days later. Kempt never restarts the machine
itself.

A check runs just before staging, and its count is the one the popup and the event log report. If
that check fails, Kempt stages anyway and uses the previous count.

Flatpak has no restart install, so an offline run still updates Flatpak apps live.

Until the restart, the staged packages still show as pending, and the popup says:

```
61 updates are staged - they install on the next restart
```

It also stops offering to stage them again.

**When staging fails.** If the update was stored but could not be set up for the restart, Kempt
discards it and the run fails with `staged but could not arm the restart install`. Staging again
replaces the previous staged update, and a failure leaves one of two results:

- The download failed before anything was replaced. The previous staged update is still there and
  still installs. The run fails with `could not rebuild the staged update - the previous one is
  unchanged and still installs on the next restart`.
- The previous one was already gone. The run fails with `the previous staged update was discarded
  and could not be rebuilt`, and Kempt cleans up so the restart installs nothing. If that cleanup
  fails too, the notification tells you to run `sudo dnf5 offline clean`.

**When a Fedora release upgrade is stored, `--surface=offline` stops** with exit 5. dnf5 keeps one
stored transaction, so staging would cancel the release upgrade. The message names the way out for
the state the upgrade is in: restart, `sudo dnf5 system-upgrade reboot`, `sudo dnf5 offline log`,
or `sudo dnf5 offline clean`. The risky-transaction prompt then offers only `[u]` and `[a]`. Live
updates still work.

**When the staged update will not install.** If a restart skipped it, or you installed anything
with dnf yourself while it waited, the next check tells you once:

```
Your staged update can no longer install on a restart. Re-stage it, or run sudo dnf5 offline clean.
```

Installing with dnf removes the restart trigger while dnf5 still calls the stored update `ready`.
To fix it, stage again (`kempt update --surface=offline`) or clear it.

**A live update replaces the stage.** A staged update is built against the installed packages. When
a live `kempt update` changes any rpm, Kempt discards the stage, because it could only fail at boot.
A Flatpak-only run leaves it alone.

**Other tools.** If `dnf-automatic`, GNOME Software or a terminal `dnf5 upgrade` changes packages
while an update is staged, Kempt leaves the stage in place and records it once. If someone
replaces the staged update outside Kempt, the next check tells you once. After the restart, Kempt
finds its transaction in dnf5's history and reports only that. If it did not run, the history entry
says `restart (staged update did not run)` and so does the notification.

### A snapshot before every update

Kempt has no snapshot setting of its own, because dnf5 can already take one. Its actions plugin
runs a command before each transaction, whether Kempt started it or you ran `dnf5` in a terminal.

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
kempt run [--print-command]
```

Starts `kempt update` where your settings say, then returns at once. This is what **Update Now**
calls. In a terminal you can run `kempt update` directly.

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

`--print-command` shows the launch command only. The old name `--dry-run` still works for now.

Exit codes:

- **3**: another update is already running. Nothing is launched.
- **4**: the terminal emulator is missing. `--print-command` checks this too.
- **5**: the terminal window never opened, for example over SSH with no display. `run` waits up to
  five seconds for it. The event log says `run did not start: <reason>`, and a window that opens
  later starts nothing.

**Exit 0 means the update started.** Read `state.json` or `kempt history` for the result.

When the terminal window closes, it runs a check, whether the update finished, failed, was aborted
or the window was closed early. That check is what returns the widget from its updating state. The
exit status is the update's.

## unstage

```
kempt unstage
```

Discards the staged update, so the next restart installs nothing. It undoes
`kempt update --surface=offline`.

```
Discarded the staged update. The next restart installs nothing.
```

It asks for your password once. With nothing staged, it says so and exits 0 without asking. The
popup's **Discard Staged Update** runs the same command; see [The popup](#the-popup).

With a Fedora release upgrade stored, it discards nothing and exits 5, because that would cancel
the upgrade. Another update running exits 3. Kempt clears its own record of the stage only once
dnf5 confirms the transaction is gone. If the transaction is still there, the command exits 1 and
keeps the record.

## summary and history

```
kempt summary [N]
kempt summary --json
kempt history
```

`summary` shows one run as text. `N` counts back from the newest: `1` (the default) is the last
run, `2` the one before. `N` must be a positive whole number, or the command exits 2. If you ask
for more runs than exist, it shows the oldest and says so on stderr.

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

When holds kept packages back, a second line says what they cost:

```
9 pending packages did not move because of holds
```

With an update staged, one more line says what the next restart will do:

```
Staged: 61 updates install on the next restart
```

That line comes from the current state, so `--json` leaves it out. Scripts read `offline_staged`
from `kempt check`.

With no runs recorded, `summary` prints `no update runs recorded yet` and exits 0. A damaged entry
is skipped with a warning, and the one before it is shown.

`--json` prints the newest run's history entry and nothing else. This is what the widget reads. It
takes no `N`. **If there are no runs, or the newest entry is damaged, it prints nothing and exits
0.** A damaged entry is named on stderr. No older run is shown in its place.

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

## log

```
kempt log [-n N]
```

One line per thing Kempt did, newest last. `-n` sets how many lines to show (default 30). With
nothing recorded it prints `No events recorded yet.` and exits 0.

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

Each line is `<timestamp> <via> <what happened>`. `via` is `widget` for the Plasma widget and
`cli` for anything else, such as a terminal, a script or a timer. It tells you whether a change
came from the widget or from somewhere else.

The wording is fixed, so you can search it:

| Line | Written when |
| --- | --- |
| `config set <key>=<value> (was <old>)` | A setting changed. `(was unset)` when it had no value. |
| `hold <backend>:<name>` / `unhold <backend>:<name>` | A hold was added or removed. |
| `check ok actionable=<n> held=<n>` | A check succeeded. The numbers are what the badge shows next. |
| `check stale <reason>` | A check failed, for example `dnf check failed: no authentication agent is running to ask for the password`. |
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
| `passwordless enable rc=<n>` / `passwordless disable rc=<n>` | `enable-passwordless` or `disable-passwordless` finished. |

The file is `~/.local/state/kempt/events.log`, mode 0600. Past 2500 lines it is trimmed to the
last 2000.

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

Checks this install and prints one line per check. Exits 0 when everything passes, 1 when anything
fails. Use it when the widget shows nothing pending and you are unsure why: a missing root helper
makes `kempt check` report zero updates with exit 0.

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

Lines are `ok`, `info` or `FAIL`. Only `FAIL` changes the exit code, and every check runs, so one
pass shows every problem. The last five events follow the checks. They are for context and are
not checks.

A packaged install prints `install: packaged` in place of the `helpers:`, `policy:` and `widget:`
lines, and no commit on the `version:` line. That sample is in
[install.md](install.md#verify-it).

The **Discover's update notifier** row appears only when Discover's notifier is installed. It is
`ok` when the notifier is turned off for you, and `info` when it starts with your session. The two
tools can show different counts, and Discover's background work can make a Kempt run wait. The
line says how to turn it off. `./install.sh` offers the same.

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
| Every config line is `key=value` with a valid key | That line is ignored, so the setting never applies. |
| The state directory is writable | No state, history or logs. |
| The checkout still has `lib/`, `backends/` and the passwordless rules template | The checkout is damaged. |
| The installed helpers, polkit action and widget match the checkout | You pulled without re-running `./install.sh`, so root still runs the old helpers. |
| The `kempt` the widget runs is this one | A leftover `~/.local/bin/kempt` shadows the installed one for the panel. `info` when the widget finds no `kempt` at all. |
| A staged update is ready for the restart, or absent | It was downloaded but will never install. Run `sudo dnf5 offline clean`. |
| `/system-update` is absent, or points at a ready update | The next restart starts the offline updater and installs nothing. Run `sudo dnf5 offline clean`. |

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
still appear in the state with `"held": true`, count toward `held_total` and not `actionable`, and
each run lists them as `Held (skipped): ...`.

```bash
kempt hold dnf:kernel-core
kempt hold flatpak:org.gimp.GIMP
kempt holds
```

```
dnf:kernel-core
flatpak:org.gimp.GIMP
```

The `dnf:` or `flatpak:` prefix is required. Without it the command exits 2 with
`use dnf:<pkg> or flatpak:<app.id>`. Names are checked when you add them. Adding a hold twice, or
removing one that is not there, succeeds.

Holds are Kempt's own list. A `sudo dnf5 upgrade` you run yourself ignores them. To pass them on,
`--exclude-args` prints the dnf holds as one line of dnf5 arguments:

```bash
kempt holds --exclude-args
```

```
--exclude=kernel-core --exclude=vim-common
```

```bash
sudo dnf5 upgrade $(kempt holds --exclude-args)
```

It prints dnf holds only. With none it prints an empty line and exits 0.

**Flatpak runtimes cannot be held.** Apps share them, so holding one would stop the apps that need
it. Kempt refuses and writes nothing:

```bash
kempt hold flatpak:org.kde.Platform
```

```
org.kde.Platform is a Flatpak runtime, and runtimes cannot be held: apps share them, so holding one breaks the next app that needs it. Hold the app instead.
```

Runtime rows in the popup have no padlock. A runtime hold already in your holds file is ignored.
Remove it with `kempt unhold flatpak:<id>`.

### Holding a package that is already staged

A hold applies from the **next** update Kempt builds. dnf5 cannot change an update it has already
stored, so if one is staged, the next restart still installs the package. The hold is recorded
anyway, and the command prints a warning on stderr and exits 0:

```bash
kempt hold dnf:kernel-core
```

```
The staged update still contains kernel-core and installs it on the next restart.
When ready: kempt update --surface=offline (rebuilds it with your holds) or sudo dnf5 offline clean (removes it).
```

`kempt update --surface=offline` rebuilds the staged update with your holds. It asks for your
password. `sudo dnf5 offline clean` removes the staged update, so the next restart installs
nothing.

If Kempt cannot read what the staged update contains, it warns anyway:

```
The staged update was built before this hold and may still install kernel-core on the next restart. Rebuilding applies all current holds.
When ready: kempt update --surface=offline (rebuilds it with your holds) or sudo dnf5 offline clean (removes it).
```

`kempt unhold` warns the other way, when the staged update was built without the package:

```
The staged update was built without kernel-core - the next restart will not install it. Rebuild when ready: kempt update --surface=offline.
```

Once the restart installs the staged update, the hold works as usual.

## config

```
kempt config get <key> [default]
kempt config set <key> <value>
```

Reads or writes a setting. The widget uses the same command. `get` returns the built-in default for
a known key, or your `default` argument if you give one.

```bash
kempt config get surface           # terminal
kempt config set surface offline
kempt config get refresh_interval_min   # 60
```

Keys must match `^[a-z][a-z0-9_]+$` and values must be one line, or `set` exits 2. Every key is
described in [configuration.md](configuration.md).

`set` warns on stderr about a key it does not know, or a value a key does not accept. It still
stores it and exits 0, so a newer widget can use keys this version does not know:

```
warning: 'bogus' is not a value surface accepts. Accepted: terminal, popup, background, offline
```

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
to write to `/etc/polkit-1`. Neither takes arguments. Disabling when it was never enabled
succeeds. What the rule grants is in [security.md](security.md#passwordless-mode).

## The Plasma widget

The widget runs the commands above: `kempt check` for the badge, `kempt run` for **Update Now**,
`kempt hold` and `kempt unhold` for the padlocks, and `kempt config` for its settings. Whatever
you do in a terminal shows up in the widget.

### Where it lives: the system tray, or the panel itself

`./install.sh` installs the widget for your user, into `~/.local/share/plasma/plasmoids/`. You
can use it in either place, or both.

**In the system tray** (the default). Kempt appears in the tray beside the volume and network
icons. The first time, it may need a plasmashell restart or a new login. To hide it or move it
behind the arrow:

> Right-click the tray > **Configure System Tray...** > **Entries** > find **Kempt**.

**On the panel.** Use this to place it somewhere specific, or make it larger:

> Right-click the panel > **Add Widgets...** > search for **Kempt** > drag it onto the panel.

Using both gives you two Kempt icons, so you probably want to turn one off.

After changing anything under `plasmoid/` in a checkout, re-run `./install.sh`. The widget is a
copy and does not follow the checkout.

### What the panel icon means

| Icon | State | What it tells you |
|---|---|---|
| Update icon with a count badge | Updates pending | The count is what an update would change now. Held packages are left out. The tooltip names the first three, kernel and other session-critical packages first. |
| Plain update icon, no badge | Up to date | Nothing to do. The tooltip still shows how many packages are held. |
| Same as before, badge kept | Last check failed | The counts are from the last check that worked. The tooltip gives the reason and the time of that check. |
| Warning emblem | Error | Kempt could not run, or could not read its state. The tooltip names the problem and points at `kempt doctor`. |
| Spinner | Updating | A run started from the widget is in progress. |
| Dimmed, no badge | No data yet | The first check has not answered yet. If another check was running, as is common right after login, it asks again a few times about ten seconds apart. |

The badge shows counts up to `999`, then `999+`. On a panel thinner than 22 px, or with **Small**
chosen, there is no badge. The icon still changes, and the tooltip has the count.

### How big the icon is

By default the icon matches the system tray: 22 px on panels from 22 to 47 px high, which covers
Plasma's default panel.

**Configure Kempt… > Panel icon size** offers **Automatic**, **Small** (16 px), **Medium** (22 px)
and **Large** (32 px). Inside the system tray, the tray sets the size. **Large** is never smaller
than **Automatic**, which reaches 48 or 64 px on very thick or HiDPI panels.

From a terminal:

```bash
kempt config set widget_icon_size large
```

Values are `auto`, `small`, `medium` and `large`. The widget treats anything else as **Automatic**.

### The popup

Click the icon. The popup has a **header** that says where you stand, a **content area**, and a
**footer** with the main button.

With updates pending, a restart owed and a kernel in the update:

```
 3 updates available                                 [refresh] [gear]   <- header: the count,
 --------------------------------------------------------------------     Refresh, settings
 (!) Restart to apply installed updates          [Restart…]      [x]   <- at most TWO messages,
 (i) This update includes a kernel. The safest way is to                   in priority order
     install it on the next restart, so nothing changes
     under the running desktop.
                                        [Install on Next Restart]

 System (dnf)                                                          <- the pending list,
   nodejs                                                     [🔓]       grouped by backend
   2:24.19.0-1nodesource → 2:24.20.0-1nodesource
 Apps (flatpak)
   org.mozilla.firefox                                        [🔓]
   140 → 141
 Held                                                                  <- held items stay
 Held packages are skipped by Kempt only.                                 visible, out of
   kernel-core                                                [🔒]       the running
   Held  6.15.1 → 6.15.3

 Last update 18 min ago · 4 packages                            [v]    <- expands to what
 --------------------------------------------------------------------     that run installed
 Checked 4 min ago · 1 held · ~140 MB              [ Update Now ]      <- footer: the dateline,
                                                                          the cost, and the
                                                                          one action
```

#### Header

The header reads one of:

- `3 updates available`
- `Up to date`, or `Up to date · 2 held` when every pending update is held
- `23 updates staged for the next restart` while an update is staged
- `Updating…`
- `No update data yet`, before the first check answers
- `Kempt's engine is not installed`, when the widget is installed without the CLI (see
  [install.md](install.md#installing-from-the-kde-store-first))
- `Kempt's engine will not run`, when the CLI is there and cannot start
- `Kempt cannot check for updates`, when running the CLI failed or no check has ever succeeded
- `Could not read the update state`, when the state file is there and this widget cannot read it,
  which usually means the widget is older than the CLI

The header count is never capped.

The **Check for Updates** button (a circular arrow) checks now. After a failed check, its tooltip
also gives the reason, such as `dnf check failed: repo 'updates' unavailable`. While a check or run
is in progress it is greyed out, with a spinner beside it. It is also in the icon's right-click menu
and the tray's **More actions** menu. Inside the system tray, the tray's own heading has this
button and the gear, so the popup hides its copies.

The **gear** opens **Configure Kempt…**, the same as the right-click menu.

#### Messages

Messages appear only when they apply, and **at most two show at once**. When more apply, the ones
lower in this list are left out. If that hides the restart message, the footer says
`restart pending` in its place.

1. **The engine is missing or broken.** *"Kempt's engine is not installed"*, with the install
   commands, or *"Kempt's engine is installed but will not run"*, pointing at `kempt doctor`.
   Either shows alone. See [install.md](install.md#installing-from-the-kde-store-first).
2. **What just happened:** `Updated 4 packages in 2s`, `No package changes`, or
   `Update failed: <the reason>`. For a button press that failed, it shows what the CLI said.
   **Show Log** is on it when a *run* recorded a log file, which every run does, including installs
   during a restart. If that log could not be saved, there is no button. The message goes when you
   close the popup or the next check starts.
3. **This system updates with rpm-ostree**, on an image-based Fedora. It points at Discover or
   `rpm-ostree upgrade` (`bootc upgrade` on a bootc image). **Update Now** is hidden.
4. **A Fedora release upgrade is stored.** It says whether the upgrade installs on the next restart,
   is downloaded but not started, was skipped by a restart, or did not finish, and what to do.
5. **What the next restart will install**, when an update is staged. See *The staged banner* below.
   **Update Now** is hidden while it shows.
6. **Restart to apply installed updates**, with **Restart…** and a close button. See *About the
   restart* below.
7. **"This update includes a kernel. The safest way is to install it on the next restart, so
   nothing changes under the running desktop."** A second version names the NVIDIA driver when it is
   in the update. Its button is **Install on Next Restart**, the same as
   `kempt update --surface=offline`. Without a kernel, it names what is in the update: `This update
   touches 20 packages the running desktop depends on (dbus, glibc, kf6, mesa, ...). The safest way
   is to install them on the next restart.` It is hidden while an update is staged.

A failed check shows in the footer as `last check failed`, with the reason in the **Check for
Updates** tooltip. A failed hold shows in the row you pressed.

#### The staged banner

Usually the banner is green and says what the next restart will do. It has its own **Restart…**
button when the restart message is not showing one:

```
 (=) 61 updates are staged - they install on the next restart   [Restart…]
```

If you hold a package that is already in the staged update, the banner turns into a warning. This
happens whether you use the padlock or `kempt hold`. dnf5 stored that update before the hold, and
there is no way to edit a stored one. So the restart would still install the package:

```
 (!) You held kernel-core after the next-restart install was prepared, so it
     still installs. Rebuild it to skip kernel-core, or stop holding kernel-core
     to keep the current plan. Rebuilding asks for authorization; if it fails,
     nothing stays staged.                          [Rebuild Staged Update]
```

With several held packages it names the first and counts the rest:
`You held kernel-core and 2 more after the next-restart install was prepared, so they still
install. Rebuild it to skip them, or stop holding them to keep the current plan.`

The warning has no **Restart…** button, and neither does the restart message while it shows,
because a restart would install the package you held. **Rebuild Staged Update** runs
`kempt update --surface=offline` and builds the staged update again with your current holds. Its
tooltip:

> Builds the staged update again with your current holds. Asks for authorization; if the rebuild
> fails, the current staged update is removed.

The rebuild asks for authorization, like **Install on Next Restart**. dnf5 deletes the old staged
update before it builds the new one. So a failed rebuild removes the current staged update, and the
restart installs nothing. It reuses the packages already downloaded.

If the staged update changed after the banner was drawn, nothing runs and the popup says
`The staged update changed since this was offered. Nothing was rebuilt; check the banner above.`

When Kempt cannot read what the staged update contains and you hold dnf packages, the banner says
`may`:

```
 (!) You added holds after the next-restart install was prepared, so it may
     still install held packages. Rebuild it to apply your holds. Rebuilding
     asks for authorization; if it fails, nothing stays staged.
                                                    [Rebuild Staged Update]
```

With nothing held, the banner stays green. Flatpak holds never cause a warning, because only dnf
updates are staged.

Every staged banner also has **Discard Staged Update**. It runs `kempt unstage`: the next restart
installs nothing and the banner goes. Its tooltip:

> Removes the update waiting for the next restart, so the restart installs nothing. Asks for
> authorization, and deletes the packages it downloaded, so staging again downloads them again.

The popup reports the result in the words `kempt unstage` uses. If the staged update changed after
the banner was drawn, nothing runs and the popup says so. With a Fedora release upgrade stored,
there is no **Discard Staged Update** button.

For the terminal side, see
[Holding a package that is already staged](#holding-a-package-that-is-already-staged).

#### The list

Updates are grouped under **System (dnf)**, **Apps (flatpak)**, **Flatpak runtimes** and **Held**.
Each row shows the package and its old and new versions. Long version lines wrap and long names are
shortened. A package the update would add shows `new → 1.0-1.fc44`.

Runtimes are listed because `flatpak update` updates them too. A runtime row shows its branch, and
has no version line when Flatpak publishes none. It has no padlock, because runtimes cannot be held
(see [hold, unhold, holds](#hold-unhold-holds)).

**The padlock** at the end of a row holds the package, or stops holding it. It runs `kempt hold`
or `kempt unhold`. The icon shows the current state:

- **🔓 open**: the package will be updated. The button reads *Hold nodejs at
  2:24.19.0-1nodesource* and *Kempt skips it on every update until you stop holding it.*
- **🔒 closed**: the package is held. The button reads *Stop holding nodejs* and *Kempt offers its
  update again.*

A held row says **Held** before its version. Under the **Held** heading: *Held packages are skipped
by Kempt only.* A `sudo dnf upgrade` in a terminal ignores Kempt's holds. For a package the update
would add, the padlock reads *Skip installing brandnew*.

When you press a padlock, it turns into a spinner and the other padlocks wait. The row moves to its
new group after the next check, and keyboard focus follows it. A screen reader hears *Holding
nodejs* or *No longer holding nodejs*. If the hold fails, the reason appears in that row until your
next press or the next check.

**Last update 18 min ago · 4 packages** shows what the previous run installed. Expand it for the
package list and **Show Log**. It takes at most a third of the popup and scrolls within that.

#### Footer

`Checked 4 min ago` counts up while the popup is open. Hover it for the full time. It can add:

- ` · last check failed`, with the reason in the **Check for Updates** tooltip
- ` · 1 held`
- ` · ~140 MB`, the estimated download, when known and there is something to update
- ` · restart pending`, when a restart is owed and its message is not showing

Before any check succeeds it reads `No successful check yet`.

The size is an estimate. It leaves out new dependencies and overstates Flatpak, which downloads
only the changes. Below a megabyte it reads `< 1 MB`. When unknown it is left out. Held items are
not counted.

**Update Now** runs `kempt run`, which updates wherever your settings say. After a press it shows a
spinner until the CLI answers, so one press starts one run. It is hidden when there is nothing to
update, and while an update is staged.

#### While an update runs

The popup shows where the update is running:

- `Updating in a terminal window…`
- `Updating in the background…`
- `Updating…`, with the live log below, for **In this widget**
- `Preparing the install for the next restart…` when staging

With confirmation on, runs always use a terminal, and **Install on Next Restart** always stages, so
this can differ from your settings.

If the popup keeps saying it is updating after the run has ended, press **Not updating? Check
again**. If a run cannot start, the popup shows the CLI's message and its fix. You can close the
popup while an update runs.

The updating state ends when the run writes a new `state.json`. A terminal run always does this as
the window closes (see [run](#run)). If a run dies without writing it, the widget gives up after
three hours and checks again.

#### When the popup checks

**Opening the popup checks** when the last successful check is older than five minutes, or than
your check interval if that is shorter. If no check has ever succeeded, it checks on every open.
The counts on screen stay until the answer arrives.

If a check is already running, the popup's request is *remembered* and one more check runs when it
finishes. Opening the popup many times still adds only one.

The widget also watches the package databases, its state file and the config file every 30
seconds. A `dnf upgrade` in a terminal, a Discover run or another Kempt run shows up without you
asking. For a minute after a check, the widget ignores changes that check itself made.

#### When nothing is pending

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

**Update Now** is hidden. If every pending update is held, the **Held** group shows in place of
`Everything is up to date`.

#### About the restart

**Restart…** opens KDE's restart prompt, which lets your apps save and which you can cancel. Kempt
never restarts the machine itself. If the prompt cannot open, the message says why.

The updates are already installed, whether or not you restart. Programs that were running, and the
kernel, keep using the old versions until they restart. A staged update is the other way round: it
installs during the restart.

The **x** hides the message until you next log in to Plasma. To turn it off for good, see
**Restart reminders** below.

### Settings

Right-click the widget > **Configure Kempt…**, or press the gear in the popup. Every setting is
stored through `kempt config`, so a change in a terminal shows up here too.

- **Apply and OK.** Both save. **Apply** keeps the dialog open, **OK** closes it. Closing with
  unsaved changes asks first.
- **Changes reach the panel within 30 seconds**, because the widget checks the config file every
  30 seconds.

**Run updates in** is greyed out when *"Apply updates without asking for confirmation"* is off,
because only a terminal window can ask. Your choice comes back when you turn confirmation off
again.

**Restart reminders** is the `restart_reminder` setting, on by default. It controls the restart
message and its **Restart…** button. With it off, the footer still says `restart pending`. Kempt
never restarts on its own either way.

```bash
kempt config set restart_reminder false   # the fact stays, the message goes
```

**Password prompts** has **Allow without password…** and **Require a password…**. They run
`kempt enable-passwordless` and `kempt disable-passwordless`, each with its own password dialog, and
show the result under the buttons. The page cannot show which is active, because only root can read
the polkit rules directory.

**Held** lists your holds, each with a button to stop holding it.

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
