# Upkeep

One-click system updates from the KDE Plasma panel. Fedora first; built to grow into a universal Linux updater.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

<!-- SCREENSHOT PLACEHOLDER: Plasma panel icon with pending-count badge + open popup. Added with the widget (Plan 2). -->

## Why

Keeping a Fedora desktop current means remembering to run `dnf5 upgrade`, remembering that
Flatpak apps are a separate command, and then reading a wall of transaction output to find out
what actually changed. Discover's notifier nags about it, disagrees with what the CLI reports,
and holds the dnf5 lock in the background while it does.

Upkeep replaces that with one icon. It knows what is pending because it asks the same root
metadata cache the update itself will use, so the badge count and the update never disagree.
Click it, and the run ends with a short summary: every package `old -> new`, apps updated,
how long it took, whether you need to reboot. Packages you never want touched can be **held** -
still counted, still shown, never updated. And when the pending transaction touches
session-critical packages (kernel, systemd, mesa, Qt/KDE), Upkeep recommends Fedora's own
answer: stage the transaction and let it apply during the next reboot, instead of rewriting a
running desktop underneath itself.

## Features

- **Live pending count.** `upkeep check` writes a small JSON state file with everything pending,
  per backend, with the versions you have and the versions you would get.
- **Holds: skip but still notify.** `upkeep hold dnf:kernel-core` keeps a package off every
  Upkeep run and still reports that an update is waiting. The badge counts only actionable
  (non-held) items, and every run prints `Held (skipped): ...` so a hold is never forgotten.
- **Four run surfaces.** Terminal (live output), in-popup (detached, tails the log), background
  (silent, notifies on completion), and offline staging - the path Fedora recommends, where the
  transaction is applied during the next reboot and harvested into normal history afterwards.
- **Clean summaries.** Old to new versions, grouped System (dnf) and Apps (flatpak), plus
  installs, removals, held items and a reboot verdict. Same renderer for the terminal, the
  notification and the widget popup.
- **Update history.** Every run is a JSON entry plus a full raw log, kept and pruned for you.
- **Scoped root privileges.** Two polkit actions, two small root helpers that validate every
  argument before running anything. Metadata refresh needs no dialog; applying updates asks
  once per run. Optional passwordless mode is a single polkit rule for the apply action,
  scoped to your active local session - not blanket sudo.

## Status

- **CLI (v1): complete.** Every command below works from a terminal on Fedora 44 and is covered
  by the test suite in `tests/`.
- **Plasma widget: in progress.** The panel icon, popup and settings page are the next piece of
  work. The CLI is the whole engine; the widget will be a thin QML client over `upkeep check`,
  `upkeep run` and `upkeep config`.
- Not yet packaged. Installation is a symlink from a git checkout (see below).

## Quick start

```bash
git clone https://github.com/erez-c137/upkeep.git
cd upkeep
./install.sh          # one pkexec prompt: installs two root helpers + the polkit action
upkeep doctor         # verify the install: helpers, polkit action, tools, config, state
upkeep check          # what is pending, as JSON
upkeep update         # run it now, ending with a summary
```

`install.sh` symlinks `bin/upkeep` into `~/.local/bin`, so **keep the checkout where it is** -
the CLI runs out of it. Only the root helpers and the polkit action are copied out of the repo.
If `upkeep` is not found right afterwards, `~/.local/bin` was not on your `PATH` when this shell
started; log out and back in. Full detail, including the Discover-notifier opt-out and how to
undo everything, is in the [install guide](docs/install.md).

## Documentation

| Document | What is in it |
| --- | --- |
| [docs/install.md](docs/install.md) | Requirements, what the installer does, what lands where, passwordless setup, uninstall |
| [docs/usage.md](docs/usage.md) | Every subcommand, its options, its output and its exit codes, plus a typical day |
| [docs/configuration.md](docs/configuration.md) | Every config key with type and default, the run surfaces, holds, file locations, retention |
| [docs/architecture.md](docs/architecture.md) | How it is built, the state JSON schema, and how to add a backend for your distro |
| [docs/security.md](docs/security.md) | Exactly what runs as root, why, and what passwordless mode grants |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Where the project is going, in order |
| [docs/man/upkeep.1](docs/man/upkeep.1) | Man page: `man upkeep` once installed, or `man -l docs/man/upkeep.1` from the checkout |
| [CHANGELOG.md](CHANGELOG.md) | Release notes |

Design and background: [the design spec](docs/specs/2026-08-24-upkeep-design.md) and the
[prior-art survey](docs/research/2026-08-24-similar-tools-survey.md) that shaped it.

## Contributing

New backends (apt, pacman, zypper) are the most useful thing anyone can add, and the contract
is deliberately small: two required functions plus the pure parser they share, in one file.
Wiring one in also means a new verb in the root apply helper, which is a security change and
worth an issue first. Start with
[docs/architecture.md](docs/architecture.md#adding-a-backend-for-your-distro), then read
[CONTRIBUTING.md](CONTRIBUTING.md) for the dev setup and the test-harness rules that reviews
enforce. Security reports go through [SECURITY.md](SECURITY.md), not the public issue tracker.

## License

MIT - see [LICENSE](LICENSE).
