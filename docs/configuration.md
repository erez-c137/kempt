# Configuring Kempt

![The widget's settings page: update sources, run surface, check interval, panel icon size, restart reminders and the password-prompt controls](images/kempt-settings.png)

*Every control on the widget's settings page is one of the keys below. A change made in either
place shows up in the other.*

## The config file

`~/.config/kempt/config`, plain `key=value`, one per line:

```
include_flatpak=true
auto_accept=true
surface=terminal
```

It is created the first time something writes to it. Use `kempt config` to read and write it. The
widget's settings page does the same and keeps no copy of its own:

```bash
kempt config get surface
kempt config set surface offline
```

You can also edit the file by hand. If a key appears twice, the last line wins.

The widget checks the file's timestamp every 30 seconds, so a change made anywhere reaches the
panel within 30 seconds.

## Keys

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `include_flatpak` | boolean | `true` | Include Flatpak apps **and runtimes** in checks and updates. `kempt update --no-flatpak` turns it off for one run. When off, the `flatpak` backend reports `enabled: false` and adds nothing to the counts. |
| `auto_accept` | boolean | `true` | Answer dnf5 and flatpak prompts automatically (`-y`). When off, the run always uses the `terminal` surface with live output, because no other surface can answer a prompt. |
| `surface` | `terminal`, `popup`, `background`, `offline` | `terminal` | Where `kempt run` sends the update. An unrecognised value logs a warning and falls back to `terminal`. |
| `refresh_interval_min` | integer (minutes) | `60` | How often the widget runs `kempt check`. The CLI itself schedules nothing. The widget clamps the value to 1..1440. Its settings page offers 15 and up, and lowers that floor to show a smaller value set from the CLI. |
| `widget_icon_size` | `auto`, `small`, `medium`, `large` | `auto` | The size of the widget's panel icon. `auto` matches the system tray: 22 px on panels from 22 to 47 px thick, and 48 or 64 px on a thick or HiDPI panel. `small`, `medium` and `large` are 16, 22 and 32 px, but `large` is never smaller than `auto`. A size the panel cannot fit falls back to `auto`, so inside the system tray the tray's size wins. The widget validates this key: an unrecognised value means `auto`. |
| `restart_reminder` | boolean | `true` | Whether the popup offers a restart when one is needed. When on, it shows a message with a **Restart…** button that opens KDE's restart prompt; closing the message hides it until the next Plasma session. When off, there is no message or button, but the status line still ends `restart pending`. Nothing restarts on its own either way. |
| `risky_regex` | POSIX extended regex | `^(kernel\|systemd\|glibc\|dbus\|mesa\|qt6\|kf6\|plasma-workspace\|kwin)` | Which package names count as session-critical. This drives the offline recommendation and `risky_pending`. |

You can store other keys too. Any key matching `^[a-z][a-z0-9_]+$` is accepted, but nothing reads
it. `kempt config get` on a key with no value and no default prints an empty line.

`kempt config set` warns when it does not recognise a key, or a value outside the set a key
accepts:

```bash
kempt config set surfce terminal
```

```
warning: unknown setting 'surfce' - Kempt does not read it. Known settings: include_flatpak, auto_accept, surface, refresh_interval_min, widget_icon_size, restart_reminder, risky_regex
```

```bash
kempt config set surface bogus
```

```
warning: 'bogus' is not a value surface accepts. Accepted: terminal, popup, background, offline
```

The warning goes to stderr. The value is still written and the command still exits 0, because a
newer widget or Kempt may read a key this version does not know. Booleans and `widget_icon_size`
get no warning. `kempt hold` and `kempt unhold` print nothing on success.

`risky_regex` is matched against dnf package names only. Build and documentation packages never
count as session-critical, whatever the pattern says: names with a `-devel`, `-headers`, `-static`,
`-tools` or `-doc` part, or containing `-macros`. The running session never loads them.

### Booleans

A value is true when it is `true`, `1` or `yes`, in any case. **Everything else is false**,
including `on`, `enabled` and `y`:

```bash
kempt config set auto_accept on    # accepted, and means OFF
kempt config set auto_accept true  # what you meant
```

## Run surfaces

All four run the same `kempt update`. The surface decides where the output goes and who is told
when it finishes.

| Surface | What it does | Good for |
| --- | --- | --- |
| `terminal` (default) | `kempt run` opens Konsole running the update, with live dnf and flatpak output, ending in the summary and a "press any key to close" prompt. | Watching it happen. The only surface that can answer prompts. |
| `popup` | Detached run writing to the log. The widget follows the log and shows the summary when it finishes. From a shell it behaves like a detached run with a notification at the end. | Staying in the panel. |
| `background` | Silent detached run, with a desktop notification and the counts when done. | Updating while you work. |
| `offline` | Stages the dnf transaction with `dnf5 upgrade --offline`. It installs during the next reboot, and the first `kempt check` after that reboot records the result. | Kernel, systemd, Qt/KDE: anything that can break a running desktop. |

The `terminal` surface needs a terminal emulator, `konsole` by default. Without one, `kempt run`
exits 4. To use another emulator that supports `-e`, set `KEMPT_TERMINAL`.

### Offline staging

Kempt recommends this path when session-critical packages are pending. Things to know:

- Flatpak apps still update **live** in the same run. Flatpak has no offline mechanism.
- Staging records the current boot session. `kempt check` records the result only after the boot
  session changes, so a manual `dnf install` or a live Kempt run before the reboot is never mistaken
  for the staged update.
- The result appears in `kempt history` as `offline (applied on reboot)`, with a notification.
- The report compares the package set with a snapshot taken at staging time. It then asks dnf5's
  history which transaction ran. If that was Kempt's, the report keeps only its packages. If the
  staged update did not run, the entry is `restart (staged update did not run)`. If the history
  cannot answer, the report shows the whole difference, including changes other tools made.

## Holds

`~/.config/kempt/holds`, one entry per line, `backend:name`:

```
dnf:kernel-core
flatpak:org.gimp.GIMP
```

Manage them with `kempt hold`, `kempt unhold` and `kempt holds` (see
[usage.md](usage.md#hold-unhold-holds)). Each dnf hold becomes an `--exclude=<name>`. Flatpak holds
make the run update apps one by one, skipping the held ones. Holds apply only to Kempt: a manual
`sudo dnf5 upgrade` ignores this file.

## Refresh cadence

Kempt runs two schedules:

- **Checking** reads the root metadata cache and downloads nothing. `refresh_interval_min`
  (default 60) sets how often the widget does it.
- **Refreshing metadata** downloads. `kempt check` runs `dnf5 makecache --refresh` at most once
  every 3 hours, dnf's own default. It skips the refresh on battery power, or on a connection
  NetworkManager reports as metered.

The time of the last successful refresh is in `~/.local/state/kempt/last_refresh`. Delete it to
force a refresh on the next check. Set `KEMPT_SKIP_REFRESH=1` to turn refreshing off.

`kempt check --refresh` fetches now, ignoring the 3-hour interval. It still skips the fetch on
battery or a metered connection.

Skipped refreshes stay visible. Every check writes `metadata_refreshed` to `state.json`. Once the
metadata is over 24 hours old, the popup's footer shows `metadata N days old`, and `kempt doctor`
reports it on its own row. A skipped refresh is also written to the event log, at most once a
day.

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
| `~/.local/state/kempt/last_refresh` | Timestamp of the last metadata refresh, for the 3-hour interval and `metadata_refreshed` |
| `~/.local/state/kempt/last_refresh_skip` | Timestamp for the once-a-day skipped-refresh line. Separate from `last_refresh`, so logging a skip never delays a fetch |
| `~/.local/state/kempt/offline_staged.json` | Marker for a staged update awaiting a reboot |
| `~/.local/state/kempt/run-start.*` | One token per `kempt run` launch, deleted by the window it starts. A window that never opens leaves one behind |
| `~/.local/state/kempt/lock`, `check.lock`, `writer.lock` | `flock` files. `lock` serialises updates and `check.lock` serialises checks. `writer.lock` serialises `config set`, `hold` and `unhold`, so two at once cannot lose a write to `config` or `holds` |

File names use a compact timestamp (`20260824T210511`). The `timestamp` field inside each history
entry is a full ISO 8601 string with the offset.

**Modes.** `events.log` and `offline_staged.json` are 0600 from the start, because they name your
holds and your settings' values. `state.json`, `config` and any file rewritten by a removal are
0600 too, because Kempt writes them through a `mktemp` file and a rename. `holds` is created by
`touch`, so it has your umask's mode until the first `kempt unhold` rewrites it.

Retention runs automatically whenever the CLI sets up its directories:

- **History:** the newest 50 entries are kept.
- **Logs:** deleted after 60 days. The history entry outlives its log.
- **The event log:** past 2500 lines, it is cut to the last 2000. This is checked on each write,
  so it happens once every 500 events.
- **Stray temporary files:** deleted after 60 minutes. These are interrupted writes (`.atomic.*`
  in the config and state directories) and run-start tokens from a window that never opened.

Nothing else prunes these directories, so back them up if a run's raw log matters to you.

## Environment overrides

For one-off runs, scripts, tests and machines that are not stock Fedora KDE. For everyday use,
prefer the config keys.

| Variable | Default | Effect |
| --- | --- | --- |
| `KEMPT_TERMINAL` | `konsole` | Terminal emulator for the `terminal` surface. |
| `KEMPT_RISKY_RE` | (empty) | Overrides `risky_regex` for this invocation. |
| `KEMPT_NOTIFY` | `notify-send` | Notification command. |
| `KEMPT_RETRY_DELAY` | `10` | Seconds between retries when another tool holds the package lock. |
| `KEMPT_SKIP_REFRESH` | (unset) | Any value disables the metadata refresh. |
| `KEMPT_VIA` | (unset) | `widget` marks an event-log line as coming from the Plasma widget, which sets it on every command it runs. Anything else, including unset, is recorded as `cli`. Read by nothing except the event log. |
| `KEMPT_CONFIG_DIR`, `KEMPT_STATE_DIR` | `~/.config/kempt`, `~/.local/state/kempt` | Move config and state, for example to test against a scratch directory. |

The full list, including the variables the test suite uses, is in
[architecture.md](architecture.md#environment-seams).
