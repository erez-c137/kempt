# Configuring Upkeep

## The config file

`~/.config/upkeep/config`, plain `key=value`, one per line:

```
include_flatpak=true
auto_accept=true
surface=terminal
```

It is created the first time something writes to it and rewritten atomically, one line per key.
`upkeep config` is the supported way in and out, and the only way the Plasma widget will touch
it, so the CLI and the widget can never drift:

```bash
upkeep config get surface
upkeep config set surface offline
```

Hand-editing works too. If a key somehow appears twice, the last line wins.

## Keys

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `include_flatpak` | boolean | `true` | Include Flatpak apps in checks and updates. `upkeep update --no-flatpak` overrides it for one run. With it off, the `flatpak` backend reports `enabled: false` and contributes nothing to the counts. |
| `auto_accept` | boolean | `true` | Answer dnf5 and flatpak prompts automatically (`-y`). With it off, the run is forced onto the `terminal` surface with live output, because no other surface can answer a prompt. |
| `surface` | `terminal`, `popup`, `background`, `offline` | `terminal` | Where `upkeep run` sends the update. An unrecognized value logs a warning and falls back to `terminal`. |
| `refresh_interval_min` | integer (minutes) | `60` | How often the Plasma widget re-runs `upkeep check`. Stored here so the CLI and widget share one setting; the CLI itself schedules nothing. |
| `risky_regex` | POSIX extended regex | `^(kernel\|systemd\|glibc\|dbus\|mesa\|qt6\|kf6\|plasma-workspace\|kwin)` | Which package names count as session-critical, driving the offline recommendation and `risky_pending`. |

Unknown keys can be stored (any key matching `^[a-z][a-z0-9_]+$` is accepted) but nothing reads
them. `upkeep config get` on a key with no value and no built-in default prints an empty line.

`risky_regex` is matched against dnf package names only, and build or documentation tails are
always dropped afterwards, whatever the pattern says: names ending in `-devel`, `-headers`,
`-static`, `-tools`, `-doc` or containing `-macros` never count as session-critical, because the
running session never loads them. Without that rule an ordinary Qt update looked like a
168-package emergency.

### Booleans

A value counts as true when it is `true`, `1` or `yes`, in any capitalization. **Everything else
is false**, including `on`, `enabled` and `y`:

```bash
upkeep config set auto_accept on    # accepted, and means OFF
upkeep config set auto_accept true  # what you meant
```

## Run surfaces

All four run the same `upkeep update`; the surface only decides where the output goes and who
gets told when it finishes.

| Surface | What it does | Good for |
| --- | --- | --- |
| `terminal` (default) | `upkeep run` opens Konsole running the update, with live dnf and flatpak output, ending in the summary and a "press any key to close" prompt. | Watching it happen; the only surface that can answer prompts. |
| `popup` | Detached run writing to the log; the widget tails the log and shows the summary when it finishes. From a shell it behaves like a detached run with a notification at the end. | Staying in the panel. |
| `background` | Fully silent detached run, desktop notification with the counts when done. | Updating while you work. |
| `offline` | Stages the dnf transaction with `dnf5 upgrade --offline`. It applies during the next reboot; the next `upkeep check` after that reboot harvests the result. | Kernel, systemd, Qt/KDE: anything that can break a running desktop. |

The `terminal` surface needs a terminal emulator, `konsole` by default. Without one, `upkeep run`
exits 4 rather than silently launching nothing. Point `UPKEEP_TERMINAL` at another emulator that
supports `-e` if you do not use Konsole.

### Offline staging, honestly

This is Fedora's recommended path, and it is the one Upkeep recommends when session-critical
packages are pending, but it has moving parts worth knowing:

- Flatpak apps still update **live** in the same run. Flatpak has no offline mechanism.
- Staging writes a marker recording the current boot session. `upkeep check` harvests the result
  only once the boot session has actually changed, so a manual `dnf install` or a live Upkeep run
  before the reboot can never be mistaken for the staged transaction.
- The harvested entry appears in `upkeep history` with the surface
  `offline (applied on reboot)`, and a notification announces it.
- Accepted caveat: once the machine has rebooted, the harvest diffs the package set against the
  snapshot taken at staging time, so if other tools changed packages in that window their changes
  are included. What it reports is truthful, it is just not guaranteed to be only the staged
  transaction.

## Holds

`~/.config/upkeep/holds`, one entry per line, `backend:name`:

```
dnf:kernel-core
flatpak:org.gimp.GIMP
```

Managed with `upkeep hold`, `upkeep unhold` and `upkeep holds` (see
[usage.md](usage.md#hold-unhold-holds)). dnf holds become one `--exclude=<name>` per run; Flatpak
holds turn the run into per-app updates so the held app can be skipped. Nothing system-wide is
touched: a manual `sudo dnf5 upgrade` ignores this file entirely.

## Refresh cadence

Two different clocks, deliberately:

- **Checking** is cheap. It reads the root metadata cache and downloads nothing.
  `refresh_interval_min` (default 60) is how often the widget repeats it.
- **Refreshing metadata** is not cheap, so `upkeep check` triggers a real
  `dnf5 makecache --refresh` at most once every 3 hours (dnf's own default cadence), and skips it
  entirely on battery power or on a connection NetworkManager reports as metered. The timestamp
  of the last successful refresh is `~/.local/state/upkeep/last_refresh`; delete it to force a
  refresh on the next check, or set `UPKEEP_SKIP_REFRESH=1` to suppress refreshing altogether.

Upkeep never re-downloads metadata faster than dnf itself would.

## Files and retention

| Path | What |
| --- | --- |
| `~/.config/upkeep/config` | Settings |
| `~/.config/upkeep/holds` | Holds, one `backend:name` per line |
| `~/.local/state/upkeep/state.json` | Latest check result (schema v1, the widget's API) |
| `~/.local/state/upkeep/history/<timestamp>.json` | One entry per run |
| `~/.local/state/upkeep/logs/<timestamp>.log` | Full raw output of that run |
| `~/.local/state/upkeep/snapshots/` | Before/after package lists used to produce the summary |
| `~/.local/state/upkeep/last_refresh` | Timestamp marker for the 3-hour metadata gate |
| `~/.local/state/upkeep/offline_staged.json` | Marker for a staged transaction awaiting a reboot |
| `~/.local/state/upkeep/lock`, `check.lock` | `flock` files serializing updates and checks |

File names use a compact timestamp (`20260824T210511`); the `timestamp` field inside each history
entry is a full ISO 8601 string with the offset.

Retention is automatic and best effort, swept whenever the CLI initializes its directories:

- **History: the newest 50 entries** are kept.
- **Logs: deleted after 60 days.** The history entry that names a log outlives the log itself.

Nothing else prunes these directories, so back them up if a run's raw log matters to you.

## Environment overrides

Useful for one-off runs and for boxes that are not stock Fedora KDE. Config keys stay the
supported user-facing surface; these are for scripts, tests and power users.

| Variable | Default | Effect |
| --- | --- | --- |
| `UPKEEP_TERMINAL` | `konsole` | Terminal emulator for the `terminal` surface. |
| `UPKEEP_RISKY_RE` | (empty) | Overrides `risky_regex` for this invocation. |
| `UPKEEP_NOTIFY` | `notify-send` | Notification command. |
| `UPKEEP_RETRY_DELAY` | `10` | Seconds between retries when another tool holds the package lock. |
| `UPKEEP_SKIP_REFRESH` | (unset) | Any value disables the metadata refresh. |
| `UPKEEP_CONFIG_DIR`, `UPKEEP_STATE_DIR` | `~/.config/upkeep`, `~/.local/state/upkeep` | Move config and state, for example to test against a scratch directory. |

The full set, including the seams the test suite uses to stub privileged commands, is listed in
[architecture.md](architecture.md#environment-seams).
