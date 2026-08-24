# Using Upkeep

Every command is `upkeep <subcommand>`. `upkeep help` prints the same list.

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
| 3 | Cannot start: `jq` is missing, or another `upkeep update` already holds the lock. |
| 4 | Launcher missing: no terminal emulator for the `terminal` surface. |
| 5 | Aborted during pre-flight. Nothing was changed. |

## check

```
upkeep check
```

Queries every enabled backend, writes `~/.local/state/upkeep/state.json`, and prints the same
JSON to stdout. Takes no arguments; anything else exits 2.

```bash
upkeep check | jq '{status, actionable, held_total}'
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
upkeep check | jq -r '.backends.dnf.items[] | "\(.name)  \(.from) -> \(.to)"'
```

```
curl  8.18.0-8.fc44 -> 8.18.0-9.fc44
git-core  2.55.0-1.fc44 -> 2.55.1-1.fc44
vim-minimal  2:9.2.967-1.fc44 -> 2:9.2.1000-1.fc44
```

`from` is `?` when the pending package is not installed yet (a new dependency), and versions are
comma-joined for packages that keep several versions installed at once, such as `kernel-core`.
The full field-by-field schema is in
[architecture.md](architecture.md#state-json-schema-v1).

`check` also does two things quietly, in the same lock: it harvests a staged offline
transaction once the machine has actually rebooted, and it refreshes package metadata at most
once every 3 hours, never on battery and never on a metered connection.

### The exit contract, precisely

`check` is built so a widget polling it every few minutes can never be misled:

- **Backend failure** (network down, repo flap): exit **0**, `status` becomes `"stale"`, `error`
  carries the message, and the previous item lists are kept so the badge does not drop to zero.
- **Corrupt or missing state file:** exit 0, degrades to an empty previous list, never a crash.
- **Failure to persist** the new state: the fresh state is printed to stdout **first**, then the
  command exits non-zero. The caller still gets the answer.
- **Lock held** by another check (60 second wait): the previous state is printed and the exit
  code is 0.

That last case is the one rule every caller must implement: **empty stdout with exit 0 means
"no data, keep the last known state", never "zero updates"**.

## update

```
upkeep update [--no-flatpak] [--surface=terminal|popup|background|offline]
```

Runs the update now, in this process. Options from the config file, overridden by the flags.
An unrecognized option exits 2. An unrecognized `--surface=` value logs a warning and falls back
to `terminal`.

```bash
upkeep update                      # everything, per config
upkeep update --no-flatpak         # this run: system packages only
upkeep update --surface=offline    # stage it; applies on the next reboot
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
   The same list is published as `risky_pending` by `upkeep check`, so the widget can offer
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
upkeep run [--dry-run]
```

The launcher: it reads the configured surface and starts `upkeep update` in the right place,
then returns immediately. This is what the widget's Update Now button calls; humans can call
`upkeep update` directly.

```bash
upkeep run --dry-run
```

```
terminal: konsole -e upkeep update
```

With `surface=background`:

```
detached: upkeep update (surface=background)
```

Exit 4 when the `terminal` surface is configured and the emulator is not installed. The check
happens before the dry run too, so `--dry-run` tells you about a missing launcher instead of
pretending it would work.

**A successful launch says nothing about the update's outcome.** `run` returns as soon as the
child is detached. Poll `state.json` or `upkeep history` for the result; never read `run`'s exit
code as "updated".

## summary and history

```
upkeep summary [N]
upkeep history
```

`summary` renders one run as human text. `N` counts back from the newest: `1` (the default) is
the last run, `2` the one before it. `N` must be a positive integer, or the command exits 2.
Asking for more runs than exist shows the oldest and says so on stderr.

```bash
upkeep summary
```

```
Upkeep - 2026-08-24T21:05:11+03:00 (terminal, 74s) ✓
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

`history` lists past runs, newest first: timestamp, surface, status, and how many packages the
run updated.

```bash
upkeep history
```

```
2026-08-24T21:05:11+03:00  terminal  ok  3 updated
2026-08-23T09:41:02+03:00  offline (applied on reboot)  ok  41 updated
2026-08-22T18:12:55+03:00  background  failed  0 updated
```

## doctor

```
upkeep doctor
```

Checks this installation and prints one line per check. Exits 0 when everything passes, 1 when
anything failed. Takes no arguments.

```bash
upkeep doctor
```

```
ok    root helper (refresh): /usr/local/libexec/upkeep-refresh (root:root 0755)
ok    root helper (apply): /usr/local/libexec/upkeep-apply (root:root 0755)
ok    polkit action: /usr/share/polkit-1/actions/org.erez.upkeep.policy
ok    jq: /usr/bin/jq (jq-1.8.1)
ok    terminal emulator: /usr/bin/konsole
ok    flatpak: /usr/bin/flatpak
ok    config file: /home/you/.config/upkeep/config (2 settings)
ok    state dir writable: /home/you/.local/state/upkeep
ok    checkout intact: /home/you/src/upkeep
upkeep doctor: all checks passed
```

It exists because of one specific trap. Every other command degrades instead of crashing, which
is right for a widget that polls on a timer but wrong for a human trying to find out what is
broken: with the root helpers missing, `upkeep check` **exits 0** with `status: "stale"` and zero
pending items, and a badge showing nothing pending is indistinguishable from an up-to-date
machine. `doctor` is the one command whose job is to say why the answer is empty.

What it checks, and what each failure means:

| Check | FAIL means |
| --- | --- |
| Both root helpers exist at the polkit-annotated paths, `root:root` 0755 | `install.sh` has not run, or the helpers were replaced. `check` will be permanently `stale`, `update` cannot run. |
| The polkit action file is installed | pkexec has no policy for the helpers and falls back to an authentication dialog, which a background check cannot answer. |
| `jq` is present | Nothing: without `jq` every command exits 3 before `doctor` can run, so this line only ever names which `jq` answered. |
| The terminal emulator (`$UPKEEP_TERMINAL`) is present | `upkeep run` exits 4 every time. Reported only when it would actually be launched: `surface=terminal`, or any surface with `auto_accept=false`. Otherwise it is an `info` line. |
| `flatpak` is present | Every check reports the Flatpak backend stale. An `info` line instead when `include_flatpak=false`. |
| Every config line is `key=value` with a valid key | The file is read with `grep "^key="`, so a malformed line is ignored forever and the setting the user wrote never applies. |
| The state directory is writable, or can be created | No state file, no history, no logs. |
| The checkout still holds `lib/`, `backends/` and the passwordless rules template | The CLI is a symlink into the checkout. A missing rules template only surfaces the day `enable-passwordless` is run. |

Lines are `ok`, `info` or `FAIL`. Only `FAIL` affects the exit code, and every check runs even
after one fails, so one pass shows every problem.

## hold, unhold, holds

```
upkeep hold   dnf:<package> | flatpak:<app.id>
upkeep unhold dnf:<package> | flatpak:<app.id>
upkeep holds
```

A hold means **skip it, but keep telling me about it**. Held items are excluded from every
Upkeep run, still appear in the state with `"held": true`, are counted in `held_total` rather
than `actionable`, and are listed at the end of each run as `Held (skipped): ...`.

```bash
upkeep hold dnf:kernel-core
upkeep hold flatpak:org.gimp.GIMP
upkeep holds
```

```
dnf:kernel-core
flatpak:org.gimp.GIMP
```

The `backend:name` prefix is required, and the backend must be `dnf` or `flatpak`; anything else
exits 2 with `use dnf:<pkg> or flatpak:<app.id>`. That guard exists so `upkeep hold dnf` cannot
silently hold a package called "dnf". Names are validated the same way the root helper validates
them, so a hold that would later be refused is refused now. Adding the same hold twice is a
no-op, and removing one that was never there succeeds.

Holds are **Upkeep's own list**, not a system-wide version lock. A manual `sudo dnf5 upgrade`
outside Upkeep ignores them.

## config

```
upkeep config get <key> [default]
upkeep config set <key> <value>
```

The only supported way to read or write settings, including for the widget. `get` falls back to
the built-in default for a known key, or to the explicit `default` argument if you pass one.

```bash
upkeep config get surface           # terminal
upkeep config set surface offline
upkeep config get refresh_interval_min   # 60
```

Keys must match `^[a-z][a-z0-9_]+$` and values must be single-line, or `set` exits 2. Every key,
its type, its default and its effect are in [configuration.md](configuration.md).

## enable-passwordless, disable-passwordless

```
upkeep enable-passwordless
upkeep disable-passwordless
```

Installs or removes a single polkit rule that lets your active local session apply updates
without the authentication dialog. Each takes one `pkexec` prompt to write to `/etc/polkit-1`,
and neither takes any arguments. Disabling something that was never enabled is not an error.
What exactly is granted is documented in [security.md](security.md#passwordless-mode).

## The Plasma widget

<!-- WIDGET STUB: replaced with the widget's own usage section when the Plasma applet ships (Plan 2). -->

The panel widget is not built yet. When it lands, it will be a thin client over the commands
above: `upkeep check` for the badge, `upkeep run` for the Update Now button, and `upkeep config`
for every setting in its dialog. Nothing in the widget will do package management of its own,
so anything documented here stays true from the panel.

## A typical day

```bash
# Morning: what is waiting?
upkeep check | jq '{actionable, held_total, risky: (.risky_pending | length)}'

# Something you never want updated automatically:
upkeep hold dnf:nvidia-driver

# Kernel and Qt in the list? Stage it instead of rewriting a running desktop:
upkeep update --surface=offline
# ... reboot when convenient; the transaction applies during boot ...

# After the reboot, the result is harvested into normal history:
upkeep check >/dev/null
upkeep summary

# Or, on an ordinary day with nothing risky pending:
upkeep update
```
