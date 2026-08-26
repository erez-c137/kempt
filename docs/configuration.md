# Configuring Kempt

## The config file

`~/.config/kempt/config`, plain `key=value`, one per line:

```
include_flatpak=true
auto_accept=true
surface=terminal
```

It is created the first time something writes to it and rewritten atomically, one line per key.
`kempt config` is the supported way in and out, and the only way the Plasma widget touches it -
its settings page keeps no copy of any value - so the CLI and the widget can never drift:

```bash
kempt config get surface
kempt config set surface offline
```

Hand-editing works too. If a key somehow appears twice, the last line wins.

A change made anywhere reaches the panel within 30 seconds: the widget notices settings by
watching this file's timestamp, and it looks every 30 seconds. That is true in both directions -
`kempt config set` in a terminal and the widget's own settings page write the same file the same
way.

## Keys

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `include_flatpak` | boolean | `true` | Include Flatpak apps in checks and updates. `kempt update --no-flatpak` overrides it for one run. With it off, the `flatpak` backend reports `enabled: false` and contributes nothing to the counts. |
| `auto_accept` | boolean | `true` | Answer dnf5 and flatpak prompts automatically (`-y`). With it off, the run is forced onto the `terminal` surface with live output, because no other surface can answer a prompt. |
| `surface` | `terminal`, `popup`, `background`, `offline` | `terminal` | Where `kempt run` sends the update. An unrecognized value logs a warning and falls back to `terminal`. |
| `refresh_interval_min` | integer (minutes) | `60` | How often the Plasma widget re-runs `kempt check`. Stored here so the CLI and widget share one setting; the CLI itself schedules nothing. The widget clamps what it reads to 1..1440 minutes; its settings page offers 15 upwards, and lowers its own floor to meet a smaller value you set from the CLI rather than silently raising it. |
| `widget_icon_size` | `auto`, `small`, `medium`, `large` | `auto` | How big the Plasma widget draws its panel icon. `auto` matches what the system tray draws at your panel's thickness (22 px on anything from a 22 px panel to a 47 px one, which covers the usual ones); the named sizes are 16, 22 and 32 px, except that `large` is never smaller than `auto` (on a thick or HiDPI panel `auto` climbs to 48 or 64 px and `large` follows it). A size the panel cannot fit falls back to `auto`, which is what makes the system tray's own slot win when the widget lives inside it. Like `refresh_interval_min`, this is stored here so the widget and the CLI share one place; the CLI itself has no icons. Validated by the **widget**, not by `kempt config set`: an unrecognized value means `auto` and is not an error. |
| `restart_reminder` | boolean | `true` | Whether the Plasma widget's popup offers to restart when a restart is owed. On, the popup shows a message saying updates are installed and waiting for a restart, with a **Restart…** button that opens KDE's own restart prompt; closing that message hides it until the next Plasma session. Off, there is no message and no button - the popup's status line still ends `restart pending`, because the fact is not the reminder. **Nothing ever restarts on its own either way**, whichever way this is set. Stored here so the widget and the CLI share one place, like `refresh_interval_min`; the CLI itself shows no popup. |
| `risky_regex` | POSIX extended regex | `^(kernel\|systemd\|glibc\|dbus\|mesa\|qt6\|kf6\|plasma-workspace\|kwin)` | Which package names count as session-critical, driving the offline recommendation and `risky_pending`. |

Unknown keys can be stored (any key matching `^[a-z][a-z0-9_]+$` is accepted) but nothing reads
them. `kempt config get` on a key with no value and no built-in default prints an empty line.

`risky_regex` is matched against dnf package names only, and build or documentation tails are
always dropped afterwards, whatever the pattern says: names ending in `-devel`, `-headers`,
`-static`, `-tools`, `-doc` or containing `-macros` never count as session-critical, because the
running session never loads them. Without that rule an ordinary Qt update looked like a
168-package emergency.

### Booleans

A value counts as true when it is `true`, `1` or `yes`, in any capitalization. **Everything else
is false**, including `on`, `enabled` and `y`:

```bash
kempt config set auto_accept on    # accepted, and means OFF
kempt config set auto_accept true  # what you meant
```

## Run surfaces

All four run the same `kempt update`; the surface only decides where the output goes and who
gets told when it finishes.

| Surface | What it does | Good for |
| --- | --- | --- |
| `terminal` (default) | `kempt run` opens Konsole running the update, with live dnf and flatpak output, ending in the summary and a "press any key to close" prompt. | Watching it happen; the only surface that can answer prompts. |
| `popup` | Detached run writing to the log; the widget tails the log and shows the summary when it finishes. From a shell it behaves like a detached run with a notification at the end. | Staying in the panel. |
| `background` | Fully silent detached run, desktop notification with the counts when done. | Updating while you work. |
| `offline` | Stages the dnf transaction with `dnf5 upgrade --offline`. It applies during the next reboot; the next `kempt check` after that reboot harvests the result. | Kernel, systemd, Qt/KDE: anything that can break a running desktop. |

The `terminal` surface needs a terminal emulator, `konsole` by default. Without one, `kempt run`
exits 4 rather than silently launching nothing. Point `KEMPT_TERMINAL` at another emulator that
supports `-e` if you do not use Konsole.

### Offline staging, honestly

This is Fedora's recommended path, and it is the one Kempt recommends when session-critical
packages are pending, but it has moving parts worth knowing:

- Flatpak apps still update **live** in the same run. Flatpak has no offline mechanism.
- Staging writes a marker recording the current boot session. `kempt check` harvests the result
  only once the boot session has actually changed, so a manual `dnf install` or a live Kempt run
  before the reboot can never be mistaken for the staged transaction.
- The harvested entry appears in `kempt history` with the surface
  `offline (applied on reboot)`, and a notification announces it.
- Accepted caveat: once the machine has rebooted, the harvest diffs the package set against the
  snapshot taken at staging time, so if other tools changed packages in that window their changes
  are included. What it reports is truthful, it is just not guaranteed to be only the staged
  transaction.

## Holds

`~/.config/kempt/holds`, one entry per line, `backend:name`:

```
dnf:kernel-core
flatpak:org.gimp.GIMP
```

Managed with `kempt hold`, `kempt unhold` and `kempt holds` (see
[usage.md](usage.md#hold-unhold-holds)). dnf holds become one `--exclude=<name>` per run; Flatpak
holds turn the run into per-app updates so the held app can be skipped. Nothing system-wide is
touched: a manual `sudo dnf5 upgrade` ignores this file entirely.

## Refresh cadence

Two different clocks, deliberately:

- **Checking** is cheap. It reads the root metadata cache and downloads nothing.
  `refresh_interval_min` (default 60) is how often the widget repeats it.
- **Refreshing metadata** is not cheap, so `kempt check` triggers a real
  `dnf5 makecache --refresh` at most once every 3 hours (dnf's own default cadence), and skips it
  entirely on battery power or on a connection NetworkManager reports as metered. The timestamp
  of the last successful refresh is `~/.local/state/kempt/last_refresh`; delete it to force a
  refresh on the next check, or set `KEMPT_SKIP_REFRESH=1` to suppress refreshing altogether.

Kempt never re-downloads metadata faster than dnf itself would.

## Files and retention

| Path | What |
| --- | --- |
| `~/.config/kempt/config` | Settings |
| `~/.config/kempt/holds` | Holds, one `backend:name` per line |
| `~/.local/state/kempt/state.json` | Latest check result (schema v1, the widget's API) |
| `~/.local/state/kempt/history/<timestamp>.json` | One entry per run |
| `~/.local/state/kempt/logs/<timestamp>.log` | Full raw output of that run |
| `~/.local/state/kempt/events.log` | The event log: one line per thing Kempt did, mode 0600 (`kempt log`) |
| `~/.local/state/kempt/snapshots/` | Before/after package lists used to produce the summary |
| `~/.local/state/kempt/last_refresh` | Timestamp marker for the 3-hour metadata gate |
| `~/.local/state/kempt/offline_staged.json` | Marker for a staged transaction awaiting a reboot |
| `~/.local/state/kempt/lock`, `check.lock` | `flock` files serializing updates and checks |

File names use a compact timestamp (`20260824T210511`); the `timestamp` field inside each history
entry is a full ISO 8601 string with the offset.

Retention is automatic and best effort, swept whenever the CLI initializes its directories:

- **History: the newest 50 entries** are kept.
- **Logs: deleted after 60 days.** The history entry that names a log outlives the log itself.
- **The event log: past 2500 lines it is rewritten to the last 2000.** Checked on write rather
  than on a timer, so it happens once every 500 events. No date-based cutoff: an event log is
  only useful as far back as it reaches, and a line count is a bound you can reason about
  without knowing how busy the machine has been.

Nothing else prunes these directories, so back them up if a run's raw log matters to you.

## Environment overrides

Useful for one-off runs and for boxes that are not stock Fedora KDE. Config keys stay the
supported user-facing surface; these are for scripts, tests and power users.

| Variable | Default | Effect |
| --- | --- | --- |
| `KEMPT_TERMINAL` | `konsole` | Terminal emulator for the `terminal` surface. |
| `KEMPT_RISKY_RE` | (empty) | Overrides `risky_regex` for this invocation. |
| `KEMPT_NOTIFY` | `notify-send` | Notification command. |
| `KEMPT_RETRY_DELAY` | `10` | Seconds between retries when another tool holds the package lock. |
| `KEMPT_SKIP_REFRESH` | (unset) | Any value disables the metadata refresh. |
| `KEMPT_VIA` | (unset) | `widget` marks an event-log line as coming from the Plasma widget, which sets it on every command it runs. Anything else, including unset, is recorded as `cli`. Read by nothing except the event log. |
| `KEMPT_CONFIG_DIR`, `KEMPT_STATE_DIR` | `~/.config/kempt`, `~/.local/state/kempt` | Move config and state, for example to test against a scratch directory. |

The full set, including the seams the test suite uses to stub privileged commands, is listed in
[architecture.md](architecture.md#environment-seams).
