# Kempt

One-click system updates for Fedora: a finished CLI, and a KDE Plasma panel widget over the same engine. Built to grow into a universal Linux updater.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

![Kempt in the Plasma system tray, popup open](docs/images/kempt-tray-popup.png)

*Kempt as a system-tray entry on Plasma 6, with the popup open on a fully updated box. The
tray icon follows your icon theme (this one is kora).*

> **This screenshot predates the popup redesign and is owed a retake.** The popup it shows
> has a row of buttons under the heading; today it has a message area, a list and a footer,
> and the primary button is gone entirely in the up-to-date state pictured here.

## Why

Keeping a Fedora desktop current means remembering to run `dnf5 upgrade`, remembering that
Flatpak apps are a separate command, and then reading a wall of transaction output to find out
what actually changed. Discover's notifier nags about it, disagrees with what the CLI reports,
and holds the dnf5 lock in the background while it does.

Kempt replaces that with one command. It knows what is pending because it asks the same root
metadata cache the update itself will use, so the pending count and the update never disagree.
`kempt update` ends with a short summary: every package `old -> new`, apps updated, how long it
took, whether you need to reboot. Packages you never want touched can be **held** - still
counted, still shown, never updated. And when the pending transaction touches session-critical
packages (kernel, systemd, mesa, Qt/KDE), Kempt recommends Fedora's own answer: stage the
transaction and let it apply during the next reboot, instead of rewriting a running desktop
underneath itself.

The panel widget is the same thing with an icon in front of it. It carries no package-manager
logic at all: the badge is the number `kempt check` just wrote, and its Update Now button is
`kempt run`. That is why the count on the panel and the count in the terminal cannot drift
apart - there is only one engine, and the widget is a client of it. See **Status** for where that
half stands today.

## Features

- **Live pending count.** `kempt check` writes a small JSON state file with everything pending,
  per backend, with the versions you have and the versions you would get.
- **Holds: skip but still notify.** `kempt hold dnf:kernel-core` keeps a package off every
  Kempt run and still reports that an update is waiting. The badge counts only actionable
  (non-held) items, and every run prints `Held (skipped): ...` so a hold is never forgotten.
- **Four run surfaces.** Terminal (live output), in-popup (detached, tails the log), background
  (silent, notifies on completion), and offline staging - the path Fedora recommends, where the
  transaction is applied during the next reboot and harvested into normal history afterwards.
- **Clean summaries.** Old to new versions, grouped System (dnf) and Apps (flatpak), plus
  installs, removals, held items and a reboot verdict. Same renderer for the terminal, the
  notification and the widget popup.
- **Update history.** Every run is a JSON entry plus a full raw log, kept and pruned for you.
- **An event log that answers "did that land?"** `kempt log` prints one line per thing Kempt did,
  each marked `widget` or `cli`: settings changed and what they replaced, holds, checks and their
  counts, runs and how they ended. A run refused at the authentication dialog says
  `authentication declined or cancelled` rather than quoting pkexec at you.
- **Scoped root privileges.** Two polkit actions, two small root helpers that validate every
  argument before running anything. Metadata refresh needs no dialog; applying updates asks
  once per run. Optional passwordless mode is a single polkit rule for the apply action,
  scoped to your active local session - not blanket sudo.
- **A panel widget that says what it knows.** The badge is the actionable count `kempt check`
  just wrote, no data reads as "no data" rather than zero, and a check that failed keeps the last
  known numbers with the reason in the tooltip instead of raising an alarm. The popup lists what
  is pending and what is held, dates its own numbers ("Checked 4 min ago"), shows what the last
  run installed, updates in one click, and pins packages in place from any row. It offers exactly
  one primary action and does not offer it when there is nothing to run.
- **It says when a restart is owed, and never performs one.** Every check records whether the
  running system is still ignoring packages you have already installed. When it is, the popup says
  so and offers a button that opens KDE's own restart prompt - the cancellable one, with your
  applications given their usual chance to object. Kempt itself never restarts anything, with any
  setting. And if you never press it, the updates are still applied: they are on disk, and the
  restart is only what makes the running system pick them up.
- **A checkup that says what is wrong.** `kempt doctor` reports the helpers, the polkit action,
  your tools, your config file and your state directory, one line per check, because everything
  else here degrades quietly rather than crashing.

## Status

- **CLI (v1): complete.** Every command below works from a terminal on Fedora 44 and is covered
  by the test suite in `tests/` (18 files, 2174 assertions, and it needs neither dnf nor flatpak
  nor root to run). This is the whole engine, and it is the half that is finished.
- **Plasma widget: landed.** A thin QML client over `kempt check`, `kempt run`, `kempt hold`,
  `kempt summary --json` and `kempt config`, with no package management of its own: a panel icon
  whose badge is the real actionable count, and a popup that carries the pending and held lists,
  a message for each thing that needs saying (a restart owed, a session-critical transaction with
  its one-click **Install on Next Restart**, a check that failed and why), what the last run
  installed, a status line dating the counts, and one primary action - hidden rather than greyed
  out when there is nothing to run. Its settings page is a front-end to `kempt config` rather than
  a second copy of it. `./install.sh` installs it and it appears in the system tray by default;
  adding it to a panel directly is still supported. Everything documented here works from a
  terminal whether or not it is there.
- Not yet packaged. Installation is a symlink from a git checkout (see below).

## Quick start

```bash
git clone https://github.com/erez-c137/kempt.git
cd kempt
./install.sh          # one pkexec prompt: root helpers + polkit action, then the panel widget
kempt --version       # which build is this
kempt doctor          # verify the install: helpers, polkit action, tools, config, state
kempt check           # what is pending, as JSON
kempt update          # run it now, ending with a summary
```

`install.sh` symlinks `bin/kempt` into `~/.local/bin`, so **keep the checkout where it is** -
the CLI runs out of it. Only the root helpers and the polkit action are copied out of the repo.
If `kempt` is not found right afterwards, `~/.local/bin` was not on your `PATH` when this shell
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
| [docs/RELEASING.md](docs/RELEASING.md) | Cutting a release, and why Kempt never updates itself |
| [docs/man/kempt.1](docs/man/kempt.1) | Man page: `man kempt` once installed, or `man -l docs/man/kempt.1` from the checkout |
| [CHANGELOG.md](CHANGELOG.md) | Release notes |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Dev setup, the test-harness rules reviews enforce, shell and docs conventions |
| [SECURITY.md](SECURITY.md) | How to report a vulnerability privately, and what is in scope |
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) | A short conduct policy: be respectful, stay on topic, and how to report a problem |

Design and background: [the design spec](docs/specs/2026-08-24-kempt-design.md) and the
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
