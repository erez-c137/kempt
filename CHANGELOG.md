# Changelog

All notable changes to Kempt are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project will follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) from its first
release.

## [Unreleased]

The first working version of Kempt: the complete command-line tool, its root helpers, its
installer and its documentation, and the Plasma panel widget that sits on top of them.

### Added

- **A panel widget that tells the truth.** A Plasma 6 applet whose badge is the CLI's own
  actionable count and never a guess: no data reads as "no data", not as zero, and a failed check
  keeps the last known numbers with the reason in the tooltip instead of raising an alarm about a
  repo that flapped once. The popup lists what is pending and what is held, updates in one click,
  offers the offline staging recommendation where you can act on it, and pins packages in place.
  Its settings page is a front-end to `kempt config` with no second copy of any setting, so the
  panel and the terminal can never disagree. The widget shells out to the CLI for everything and
  contains no package-manager knowledge of its own; every command it runs goes through one
  component with a hard timeout, so a slow `dnf` can never freeze the panel.

- **One command that knows what is pending.** `kempt check` queries dnf5 and Flatpak and writes
  a documented JSON state file (schema v1) listing every pending item, the version installed and
  the version it would move to. It reads the same root metadata cache the update itself uses, so
  the count and the update cannot disagree.
- **Holds that skip but still notify.** `kempt hold dnf:kernel-core` keeps a package out of
  every Kempt run while it stays visible as pending, out of the actionable count, and named in
  each run's `Held (skipped)` line.
- **Four run surfaces.** Terminal with live output, in-popup, silent background, and offline
  staging, which hands the transaction to the next reboot the way Fedora recommends. The staged
  result is harvested into normal history after that reboot, gated on the boot session so no
  other package change can be mistaken for it.
- **A recommendation, never a veto, for risky transactions.** When a pending update touches
  session-critical packages, an interactive run offers to update live, stage it for the next
  reboot, or abort, and defaults to abort. Detached runs send a heads-up notification and
  proceed. The same list is published to the state file as `risky_pending`.
- **Summaries built from before-and-after package snapshots**, not from parsing transaction
  output: old to new versions, installs, removals, held items, duration and a reboot verdict,
  rendered identically for the terminal, notifications and (later) the widget.
- **History and logs.** One JSON entry and one raw log per run, pruned automatically: the newest
  50 entries are kept and logs are dropped after 60 days.
- **Scoped root privileges.** Two polkit actions and two argument-validating root helpers, so a
  cheap metadata refresh can never share a cached authorization with a system upgrade. Optional
  passwordless mode is a single rule for a single action, limited to an active local session.
- **An installer that explains itself.** `install.sh` does one authentication prompt, says
  exactly what it put where, stages unprivileged with `--destdir`, reverses itself with
  `--uninstall`, and offers (never assumes) disabling Discover's notifier, which otherwise
  duplicates notifications and holds the dnf5 lock.
- **`kempt doctor`, a checkup that says what is wrong.** One line per check for the two root
  helpers, the polkit action, `jq`, the terminal emulator, flatpak, the config file's syntax, a
  writable state directory and an intact checkout; exit 1 if anything failed. It exists because
  everything else degrades instead of crashing: with the root helpers missing, `check` exits 0
  with a stale state and nothing pending, which reads as "up to date".
- **A man page**, installed into the user's man hierarchy: `man kempt`.
- **Documentation**: README, install guide, usage reference, configuration reference,
  architecture guide with a walkthrough for adding a backend, security model, contributing
  guide, security policy and code of conduct.
- **A test suite that needs none of the tools it drives.** Every impure call goes through an
  environment seam, so the parsers run against recorded fixtures and the privileged paths are
  tested without dnf, flatpak, polkit or root.

### Changed

- **Renamed from Upkeep to Kempt** (reverse-DNS id `io.github.erez_c137.kempt`), because two
  actively maintained Linux updaters are already called `upkeep` and a venture-funded
  maintenance-software company owns the word commercially, so the old name could never own a
  search result; the reasoning is in
  [docs/research/2026-08-25-brand-bakeoff.md](docs/research/2026-08-25-brand-bakeoff.md). The
  binary, the root helpers, the polkit actions, the config and state directories and the
  `KEMPT_*` environment seams all moved with it. Nothing was released under the old name.

### Notes and known limitations

- Fedora and dnf5 only for now. Adding another distribution is one new backend file, and the
  walkthrough for it is [docs/architecture.md](docs/architecture.md#adding-a-backend-for-your-distro).
- Flatpak support is system scope only. A system-wide `flatpak update` also updates runtimes,
  which the summary does not itemize, so a run can change slightly more than it reports.
- Installation is a symlink into the git checkout, which stays load-bearing. Proper packaging is
  future work.
- The dnf pending check parses text output. Migrating it to `dnf5 check-update --json` is the
  designated next upgrade for that backend.
- The Plasma widget is not built yet.
