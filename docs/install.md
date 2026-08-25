# Installing Kempt

## Requirements

Verified on Fedora 44: dnf5 5.4.3, flatpak 1.18.1, KDE Plasma 6.7.4, bash 5.3, jq 1.8.

| Needed | Why |
| --- | --- |
| Fedora with `dnf5` | The backend runs `dnf5 check-update`, `makecache`, `upgrade` and `needs-restarting`. Fedora 41 was the first release to ship dnf5 as the default `dnf`. |
| `rpm` | The before/after snapshots that produce the summary come from `rpm -qa`. |
| `jq` | Every state and history file is JSON. Without it, every command exits 3. `sudo dnf install jq` |
| `polkit` (`pkexec`) | The two root helpers are launched through polkit actions. Present on any Plasma install. |
| bash 4+, coreutils, GNU awk/grep/sed/join/sort, `flock` | The CLI is bash and the parsers are GNU text tools. All are part of a base Fedora install. |
| `flatpak` | Only when `include_flatpak` is on (the default). Turn it off with `kempt config set include_flatpak false` on a box without Flatpak. |
| `notify-send` (libnotify) | Desktop notifications from the detached surfaces. Missing, notifications are simply skipped. |
| `konsole` | Only for the `terminal` surface. Any other emulator works: set `KEMPT_TERMINAL` in your environment. |

The offline surface additionally needs a dnf5 that supports staged transactions. Check with:

```bash
dnf5 upgrade --help | grep -- --offline
```

## Install

```bash
git clone https://github.com/erez-c137/kempt.git
cd kempt
./install.sh
```

The installer does four things, in this order:

1. **Symlinks the CLI and its man page.** `~/.local/bin/kempt` points at `bin/kempt` inside the
   checkout, and `~/.local/share/man/man1/kempt.1` at the man page, so `man kempt` works
   without root.
2. **Asks for authentication once** (a single `pkexec`) and, as root, copies the two helpers and
   the polkit action out of the repo.
3. **Tells you the checkout is load-bearing.** The CLI, its library, the backends and the
   passwordless rules template all resolve inside the repo directory. Moving or deleting it
   breaks `kempt`. Only the root-owned files are copies.
4. **Offers to disable Discover's notifier** (see below). It is an offer, never silent.

### What lands where

| Path | Owner | Installed by |
| --- | --- | --- |
| `~/.local/bin/kempt` | you | `install.sh` (symlink into the checkout) |
| `~/.local/share/man/man1/kempt.1` | you | `install.sh` (symlink into the checkout), so `man kempt` works |
| `/usr/local/libexec/kempt-refresh` | `root:root` 0755 | the one `pkexec` |
| `/usr/local/libexec/kempt-apply` | `root:root` 0755 | the one `pkexec` |
| `/usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy` | `root:root` 0644 | the one `pkexec` |
| `~/.config/autostart/org.kde.discover.notifier.desktop` | you | only if you accept the notifier opt-out |
| `/etc/polkit-1/rules.d/49-kempt.rules` | `root:root` 0644 | only after `kempt enable-passwordless` |

Nothing else is written at install time. Config and state directories are created on first use:
`~/.config/kempt/` (config, holds) and `~/.local/state/kempt/` (state, history, logs,
snapshots). See [configuration.md](configuration.md#files-and-retention).

If `kempt` is not found afterwards, `~/.local/bin` is missing from your `PATH`. Fedora's
default shell profile adds it when the directory exists, so a fresh login usually fixes it:

```bash
command -v kempt    # expect: /home/<you>/.local/bin/kempt
```

### If the authentication prompt is declined

The installer exits 1 and tells you exactly where it stopped: the CLI symlink is in place, the
root helpers are not, and `kempt check` will not work yet. Re-run `./install.sh` when ready.

### The Discover-notifier opt-out

Fedora's `plasma-discover-notifier` duplicates the notifications Kempt sends, and its
background PackageKit activity takes the dnf5 lock at unpredictable moments, which makes Kempt
runs fail spuriously. The installer therefore asks:

```
Disable plasma-discover-notifier for this user? [Y/n]
```

Accepting writes a **user-level** autostart override at
`~/.config/autostart/org.kde.discover.notifier.desktop` - a copy of the system entry with
`Hidden=true` - and kills any running `DiscoverNotifier` process. Nothing system-wide is
touched, and re-running the installer never accumulates duplicate lines.

To undo it, delete the override and log back in:

```bash
rm ~/.config/autostart/org.kde.discover.notifier.desktop
```

Answering `n` leaves the notifier alone. If the installer is run without a terminal to read an
answer from, it leaves the notifier **enabled** and says so, rather than taking silence for
consent.

## Verify the install

```bash
kempt doctor
```

Expect `kempt doctor: all checks passed` and exit status 0. It checks the two root helpers at
the polkit-annotated paths (present, `root:root` 0755), the polkit action file, `jq`, your
terminal emulator, flatpak, your config file's syntax, a writable state directory and an intact
checkout, and it prints one line per check so a failure names itself. Run it first: if the
authentication prompt was declined, or the checkout has since moved, this is the command that
says so. Full detail in [usage.md](usage.md#doctor).

Then the real answer:

```bash
kempt check | jq '{status, actionable, held_total}'
```

Expect `status: "ok"` and a count, with **no** authentication dialog: checking metadata is the
no-dialog polkit action. To sanity-check the number against dnf itself, compare the dnf item
count rather than the total (the total also includes Flatpak apps, and excludes anything held):

```bash
kempt check | jq '.backends.dnf.items | length'
dnf5 --cacheonly check-update --quiet | wc -l
```

Expect the same ballpark, not the same number. Multilib pairs such as `bash.x86_64` and
`bash.i686` collapse into one Kempt item, dnf5 also prints obsoleted packages that Kempt
filters out, and this command reads your user metadata cache while Kempt reads the root cache
its own update will use (that is the point of the no-dialog refresh action).

## Passwordless updates (optional)

By default, applying updates raises one KDE authentication dialog per run. To skip it:

```bash
kempt enable-passwordless     # one pkexec prompt to install the rule
```

That renders `polkit/49-kempt.rules.in` with your username, verifies the rendered result
before installing it, and places it at `/etc/polkit-1/rules.d/49-kempt.rules`. The rule returns
YES for exactly one polkit action, `io.github.erez_c137.kempt.apply`, for your user, and only when your
session is **active and local**. A remote or background session gets nothing. It is not sudo,
and it grants nothing beyond the two upgrade verbs the apply helper implements.

```bash
kempt disable-passwordless    # removes the rule; saying "not enabled" is not an error
```

The exact grant, and why it is safe to scope it this way, is in
[security.md](security.md#passwordless-mode).

## Updating Kempt

```bash
cd /path/to/kempt && git pull
```

The CLI updates immediately, because `~/.local/bin/kempt` points into the checkout. Re-run
`./install.sh` if the root helpers or the polkit action changed - those are copies, and a stale
copy keeps running until it is replaced.

## Staged install (packagers and testers)

`--destdir` stages every file into a prefix, unprivileged, with no `pkexec` and no prompts:

```bash
./install.sh --destdir /tmp/stage
find /tmp/stage -type f -o -type l
./install.sh --destdir /tmp/stage --uninstall
```

This is the path the test suite uses; it is also the starting point for real packaging, which
is the answer for distributing Kempt to other users (the symlink install is a developer install).

## Uninstall

```bash
./install.sh --uninstall
```

Removes the `~/.local/bin/kempt` and man-page symlinks, then asks for authentication once to
remove the two root helpers, the polkit action and the passwordless rule if present. Declining that prompt
exits 1 and names the half-removed state so you can finish with a second run.

Left behind on purpose:

- `~/.config/kempt/` and `~/.local/state/kempt/` - your settings, holds and update history.
- `~/.config/autostart/org.kde.discover.notifier.desktop` - your choice about Discover's
  notifier outlives Kempt.

To remove those too:

```bash
rm -rf ~/.config/kempt ~/.local/state/kempt
rm -f ~/.config/autostart/org.kde.discover.notifier.desktop
```
