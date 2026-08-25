# Using Kempt

Every command is `kempt <subcommand>`. `kempt help` prints the same list.

```
check                 refresh pending-updates state (JSON to stdout)
update                run the update now (options from config; --no-flatpak, --surface=X override)
run [--dry-run]       launch update per configured surface (what the widget calls)
summary [N]           human summary of the last (or Nth-last) run
history               list past runs
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
The full field-by-field schema is in
[architecture.md](architecture.md#state-json-schema-v1).

`check` also does two things quietly, in the same lock: it harvests a staged offline
transaction once the machine has actually rebooted, and it refreshes package metadata at most
once every 3 hours, never on battery and never on a metered connection.

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
   "stage offline instead" without re-deriving the rule.
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

`history` lists past runs, newest first: timestamp, surface, status, and what the run changed.
That last column is the same phrase the notifications use, so a run that only installed or
removed packages is never listed as "0 updated", and a run that changed nothing says so.

```bash
kempt history
```

```
2026-08-24T21:05:11+03:00  terminal  ok  3 updated, +1 installed
2026-08-23T09:41:02+03:00  offline (applied on reboot)  ok  41 updated
2026-08-22T18:12:55+03:00  background  failed  no package changes
```

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

Lines are `ok`, `info` or `FAIL`. Only `FAIL` affects the exit code, and every check runs even
after one fails, so one pass shows every problem.

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

## enable-passwordless, disable-passwordless

```
kempt enable-passwordless
kempt disable-passwordless
```

Installs or removes a single polkit rule that lets your active local session apply updates
without the authentication dialog. Each takes one `pkexec` prompt to write to `/etc/polkit-1`,
and neither takes any arguments. Disabling something that was never enabled is not an error.
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

If that judgement is wrong for your panel, **Configure Kempt... > Panel icon size** offers
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

Click the icon. The header says how many updates are available; below it are the pending items
grouped **System (dnf)** and **Apps (flatpak)**, each showing `from -> to`, and a muted **Held**
group underneath.

- **Update Now** runs `kempt run`, which opens whatever surface you configured. It is greyed out
  when there is nothing actionable to run, and if a run cannot start, the widget shows the CLI's
  own message, including its remedy. With the surface set to **In this widget**, the popup shows
  the run's live log while it works; on the other surfaces the output goes where you chose, and
  the popup just says so.
- **Refresh** re-checks now instead of waiting for the timer.
- **The pin on each row** holds or unholds that package - the same `kempt hold` as the CLI. The
  row moves between the pending list and the Held group on the next refresh.
- **"N session-critical pending"** appears when the transaction would rewrite things a running
  desktop is using (the kernel, the graphics stack, Qt). Next to it, **Stage offline instead**
  hands the whole transaction to the next reboot. This is the same recommendation `kempt check`
  publishes as `risky_pending`.

You do not have to keep the popup open. Updates keep running if you close it.

### Settings

Right-click the widget > **Configure Kempt...**. Every control on that page reads and writes
`kempt config` - there is no second copy of any setting, so a value you set in a terminal shows
up here and vice versa.

Two things worth knowing:

- **Apply vs OK.** Both save. **Apply** writes your changes and leaves the dialog open;
  **OK** writes them and closes. If you close the dialog with unsaved changes, it asks first.
- **Changes reach the panel within 30 seconds.** The widget notices a settings change by watching
  the config file, and it looks every 30 seconds. So the badge or the check interval may take up
  to half a minute to catch up after you press Apply. Nothing is lost in the meantime.

**Run updates in** is greyed out when *"Apply updates without asking for confirmation"* is off,
because only a terminal window can ask you the question. Your choice is remembered - untick the
confirmation box and it comes straight back.

**Password prompts** offers **Allow without password...** and **Require a password...**, which run
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
