# Changelog

All notable changes to Kempt are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project will follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) from its first
release.

## [Unreleased]

## [0.1.1] - 2026-09-04

### Changed

- **Kempt is installable.** The COPR repository is live and green, so the README leads with
  `sudo dnf copr enable erez-c137/kempt && sudo dnf install kempt` and the checkout install
  becomes the development path. Verified the way a stranger would hit it: both commands in a
  clean Fedora 44 container, ending at `kempt 0.1.0`.

### Fixed

- **A widget installed from the KDE Store now says what to do next.** The store carries the
  plasmoid and nothing else, so the first check on a store install ran against no CLI at all -
  and the popup quoted the shell straight back at the user, `sh: line 1: kempt: command not
  found`, over a `kempt doctor` line that could not possibly work, because `kempt` was the thing
  that was missing. That was the first impression of Kempt for anyone who found the widget
  before the package. The widget now reads the exit code rather than the message (127 for a
  command that is not there, 126 for one that is there and cannot be run), treats it as a setup
  step and not a failure - the panel icon stays dim, no warning emblem, no invented count - and
  shows the two commands that install the engine, plus where to go on a system that is not
  Fedora. A **Copy Commands** button puts them on the clipboard as one chained line, because an
  InlineMessage's text cannot be selected and a retyped command fails somewhere the reader then
  has to debug. This is the ceiling for a COPR-distributed package: the one-click install the
  PackageKit session API offers can only draw from repos already enabled, which is exactly what
  a COPR is not - official Fedora packaging (on the roadmap) is what raises it.
- **`kempt doctor` catches the store copy that shadows a packaged widget.** `kpackagetool6`
  installs the widget into your home directory, the RPM installs it into `/usr/share`, and
  Plasma prefers yours. So a widget installed from the store before the package went on being
  the one Plasma loaded, and every package update after that landed in a directory nothing
  reads: silently, permanently, and with the old copy still rendering perfectly. On a packaged
  install doctor now fails on a user copy, says what it costs, and prints the two commands that
  clear it. `docs/install.md` covers the store-first order end to end, including what the widget
  shows before the engine is there.

## [0.1.0] - 2026-09-03

The first working version of Kempt: the complete command-line tool, its root helpers, its
installer and its documentation, and the Plasma panel widget that sits on top of them.

### Added

- **One command that knows what is pending.** `kempt check` queries dnf5 and Flatpak and writes
  a documented JSON state file (schema v1) listing every pending item, the version installed and
  the version it would move to. It reads the same root metadata cache the update itself uses, so
  the count and the update cannot disagree.
- **A check that answers offline.** Both backends read local caches only, and every network fetch
  happens in one step that runs at most every three hours, on mains power, over an unmetered
  connection. On a train, behind a captive portal or on battery, `kempt check` still says what is
  pending instead of reporting the Flatpak side stale. The Flatpak half of that fetch runs as you,
  with no privilege escalation of any kind.
- **A version you can quote in a bug report.** `kempt --version` (also `kempt version` and
  `kempt -V`) prints the release, and `kempt doctor` opens with it and the checkout it came from.
  One `VERSION` file is the source of truth: the panel widget is pinned to it by the test suite,
  so the CLI and the widget cannot report different releases of the same install.
- **How big the download is, next to the button that starts it.** The popup footer reads
  `Checked 4 min ago · ~140 MB` and the tooltip says `~140 MB to download`, so pressing Update
  Now on a metered link is an informed decision. The figure comes from metadata already on disk -
  no dependency resolution, no network, nothing on popup open - and it is honest about being an
  estimate: it says `~`, never "up to", it excludes held packages, it omits dependencies dnf will
  pull in, and it over-counts Flatpak, which transfers less than it advertises. When the number
  is not known the surfaces show nothing at all rather than `0 MB`.
- **Holds that skip but still notify.** `kempt hold dnf:kernel-core` keeps a package out of
  every Kempt run while it stays visible as pending, out of the actionable count, and named in
  each run's `Held (skipped)` line.
- **Four run surfaces.** Terminal with live output, in-popup, silent background, and offline
  staging, which downloads the transaction and arms it so the next restart of any kind installs
  it, the way Fedora recommends. The staged result is harvested into normal history after that
  restart, gated on the boot session so no other package change can be mistaken for it. While a
  transaction is staged the popup says so in one green line instead of offering to stage it
  again; a live update discards a stage it has invalidated rather than leaving a doomed
  transaction armed; and `kempt doctor` names a stage that can never install, with the command
  that clears it.
- **A recommendation, never a veto, for risky transactions.** When a pending update touches
  session-critical packages, an interactive run offers to update live, stage it for the next
  reboot, or abort, and defaults to abort. Detached runs send a heads-up notification and
  proceed. The same list is published to the state file as `risky_pending`.
- **Summaries built from before-and-after package snapshots**, not from parsing transaction
  output: old to new versions, installs, removals, held items, duration and a reboot verdict,
  rendered by one renderer for the terminal, the notifications and the widget alike.
- **History and logs.** One JSON entry and one raw log per run, pruned automatically: the newest
  50 entries are kept and logs are dropped after 60 days.
- **An event log, and `kempt log` to read it.** One line per thing Kempt did - a setting changed
  and what it replaced, a hold added or removed, a check and its counts, a metadata refresh, a
  run starting and how it ended, a transaction staged, a staged transaction harvested after the
  reboot, a passwordless grant attempted - each stamped `widget` or `cli` so a change made in the
  panel is distinguishable from one typed in a terminal. The per-run logs say what the package
  manager printed and the history says what a run changed; nothing said whether the thing you
  just did actually happened, which is the question people actually ask. Mode 0600, self-pruning
  past 2500 lines, and the last five lines are appended to `kempt doctor`.
- **A refused authentication says so.** When a run or a check fails because the authentication
  dialog was declined or closed, the summary, the notification, `kempt history`, the state file
  and the event log all say `authentication declined or cancelled` instead of pkexec's
  "Error executing command as another user: Not authorized", which reads as a broken install.
  The raw wording is kept in the run log, which is evidence rather than a summary. Failed runs
  now carry their reason in the history entry, so a summary explains the failure instead of
  pointing at a log file.
- **Scoped root privileges.** Two polkit actions and two argument-validating root helpers, so a
  cheap metadata refresh can never share a cached authorization with a system upgrade. Optional
  passwordless mode is a single rule for a single action, limited to an active local session.
- **No password for a Flatpak-only update.** Updating Flatpak apps needs no root: Flatpak's own
  policy grants a system app update to an active local session without asking. Kempt used to send
  it through the root helper anyway, so a run with nothing but app updates in it raised an
  authentication dialog that plain `flatpak update` never raises. It now runs as you. Two cases
  can still ask: an update that has to install a brand new runtime, and a run started over SSH
  rather than at the machine. `kempt-apply` is dnf's alone, and refuses the old verb.
- **An installer that explains itself.** `install.sh` does one authentication prompt, says
  exactly what it put where, stages unprivileged with `--destdir`, reverses itself with
  `--uninstall`, and offers (never assumes) disabling Discover's notifier, which otherwise
  duplicates notifications and holds the dnf5 lock.
- **`kempt doctor`, a checkup that says what is wrong.** One line per check for the two root
  helpers, the polkit action, `jq`, the terminal emulator, flatpak, the config file's syntax, a
  writable state directory and an intact checkout; exit 1 if anything failed. It exists because
  everything else degrades instead of crashing: with the root helpers missing, `check` exits 0
  with a stale state and nothing pending, which reads as "up to date".
- **A pull you forgot to install cannot hide.** `kempt doctor` ends with the commit the checkout
  is on, and with `helpers:`, `policy:` and `widget:` lines comparing each installed copy against
  it. A checkout install is only half live: the CLI is a symlink, so `git pull` moves it at once,
  while the root helpers, the polkit action and the widget package are copies that change only
  when `./install.sh` runs. `DIFFER` names that gap and the command that closes it. An install
  that did not come from a checkout prints `install: packaged` and compares nothing, because the
  package manager keeps those files in step. The procedure that goes with it is
  [docs/RELEASING.md](docs/RELEASING.md), which also says why Kempt has no self-update code and
  never will: a packaged Kempt is updated by the package manager it manages, and shows up in its
  own popup like anything else that is pending.
- **A panel widget that tells the truth.** A Plasma 6 applet whose badge is the CLI's own
  actionable count and never a guess: no data reads as "no data", not as zero, and a failed check
  keeps the last known numbers with the reason in the tooltip instead of raising an alarm about a
  repo that flapped once. The popup lists what is pending and what is held, updates in one click,
  offers the offline staging recommendation where you can act on it, and pins packages in place.
  Its settings page is a front-end to `kempt config` with no second copy of any setting, so the
  panel and the terminal can never disagree; a change made either way reaches the other within 30
  seconds. The widget shells out to the CLI for everything and contains no package-manager
  knowledge of its own; every command it runs goes through one component with a hard timeout, so
  a slow `dnf` can never freeze the panel. `install.sh` installs and removes it, and where it
  lives stays your decision.
- **One check per run, not three.** The widget watches the package databases and its own state
  file every 30 seconds, so a `dnf upgrade` typed in a terminal reaches the panel without being
  asked. It no longer reacts to its own wake: an update rewrites the package database all the way
  through the transaction and the state file on the way out, which used to leave three
  `widget check ok` lines in `kempt log` inside 40 seconds, two of them describing nothing. For a
  minute after a check finishes the watcher stays quiet. Refresh, the scheduled check, opening the
  popup and a settings change are all exempt.
- **It sits in the system tray, next to everything else that watches your machine.** Kempt
  declares itself a tray entry under *System Services* and is enabled there by default, so
  installing it is all it takes - no dragging it onto a panel, and inside the tray it is exactly
  the size of its neighbours. Adding it to a panel directly still works and is still supported;
  the tray is simply where an update notifier belongs.
- **A panel icon sized to match its neighbours.** Standalone on a panel, the icon is drawn at the
  size the system tray uses for that panel thickness - 22 px on every ordinary panel, Plasma's
  44 px default included - rather than filling its cell, which made it stand a head taller than
  every tray icon beside it. `widget_icon_size` (Automatic, Small, Medium, Large, also on the
  settings page) overrides that where the judgement is wrong; a size the panel cannot fit falls
  back to Automatic, so inside the tray the tray's own slot always wins, and Large is never smaller
  than Automatic. The count badge is drawn against the icon rather than the cell, so it stays
  legible and stays where the glyph is - and below the 22 px step it is left off rather than drawn
  at a size nothing can be read at, with the tooltip carrying the exact count.
- **An icon of its own.** A comb glyph: the application icon plus 22px and 16px symbolics ship
  inside the widget package, and `install.sh` also puts the application icon into the user's
  hicolor theme, which is what makes **Add Widgets** show it (a package-local icon name does not
  resolve from the theme) - followed by the standard `org.kde.KIconLoader.iconChanged` signal,
  because a plasmashell that started before that directory existed will otherwise go on drawing
  the placeholder until you log out. The panel states themselves stay on the desktop's own update icons for
  now, deliberately, so Kempt looks like the rest of Plasma; the symbolics are there for the icon
  choice on the roadmap.
- **A popup that answers the first question in the first second.** It is three parts now and they
  never move: a header carrying the pending count, a content area carrying every message that
  applies and then the list, and a footer with the dateline on the left and the one button that
  acts on the right. What that fixes, in the order a person meets it. **Update Now disappears when
  there is nothing to run** instead of sitting there greyed out, because an up-to-date box has no
  run to start and a disabled primary button is an offer being refused rather than an offer never
  made. **The status line dates the counts** - `Checked 4 min ago`, ticking while the popup is
  open, with the exact stamp on hover, `· 1 held` when anything is held, and `No successful check
  yet` on a box whose every check so far has failed, which is not the same thing as one that has
  never checked. **Version strings are never truncated**: they wrap onto a second line, because
  `2:24.19.0-1nodesource` is the line people compare between two machines and the tail is the half
  that differs; a package name too long for its row elides instead. **What the last run did is on
  screen** as `Last update 18 min ago · 4 packages`, expanding to the packages that run actually
  installed with a **Show Log** beside them - taken from that run's own history entry through the
  new `kempt summary --json`, so the popup and `kempt summary` cannot tell two stories about one
  run. Right after a run, a transient line says `Updated 4 packages in 2s`, `No package changes`
  or `Update failed: <the reason>`; it replaces what used to be pasted there, which was the first
  line of `kempt summary` - an ISO timestamp, true and no answer at all to "what just happened?".
  **Opening the popup re-checks** when the last successful check is older than the smaller of your
  interval and five minutes, without blocking and without starting a second check alongside one
  already running. Every message that used to be stacked in the toolbar is an inline message in
  the content area, the offline recommendation among them, renamed **Install on Next Restart**
  after what it does to you rather than after the dnf5 flag that implements it. **Check for
  Updates** is also a contextual action, so it is in the system tray's *More actions* menu and the
  icon's right-click menu, not only on the popup's own refresh button.
- **It says when a restart is owed, and it never performs one.** `kempt check` now records
  `reboot_needed` in the state file: whether a restart is owed **right now**, asked fresh on every
  check from local facts only (a cache-only, repo-less `needs-restarting`, no network and no
  prompt). That is a different question from the `reboot_needed` in a history entry, which records
  whether one was owed when a particular run finished - a history entry goes on claiming a restart
  long after you have performed one, and says nothing at all when the restart is owed because of a
  `sudo dnf5 upgrade` typed in a terminal. The live key clears itself and notices what Kempt did
  not do. The popup turns it into one message, **Restart to apply installed updates**, whose
  **Restart…** button opens KDE's own restart prompt - cancellable, with your applications given
  their usual chance to object. Kempt never restarts anything itself, in any state, with any
  setting, and if the prompt cannot be opened the reason is added to the message rather than
  swallowed. The message is shown in every state including up to date, because you can owe a
  restart with nothing pending. Closing it puts it away for the rest of that Plasma session and
  writes nothing down: a dismissal on disk is a promise to remember it across a restart, and a
  restart is exactly the event that clears the fact underneath it. New setting
  `restart_reminder` (default on, and on the settings page as **Remind me when a restart is
  needed**) turns the message and the button off; the status line still ends `· restart pending`,
  because that is a fact about your machine rather than a reminder. `kempt doctor` now names the
  command behind the verdict, since a permanently broken reboot check would otherwise look exactly
  like a permanently answered one.
- **A man page**, installed into the user's man hierarchy: `man kempt`.
- **Documentation**: README, install guide, usage reference, configuration reference,
  architecture guide with a walkthrough for adding a backend, security model, roadmap,
  contributing guide, security policy and code of conduct.
- **A test suite that needs none of the tools it drives.** 18 files and 2352 assertions: every
  impure call goes through an environment seam, so the parsers run against recorded fixtures and
  the privileged paths are tested without dnf, flatpak, polkit or root. The widget is covered
  twice over - every derivation rule under node, and the real QML executed against a stubbed CLI
  by supervised PySide6 probes.
- **The two files a packaged Kempt needs, both run rather than drafted.** An AppStream metainfo,
  so a software centre has a name, a summary, a screenshot and a release history to show instead
  of nothing; and `kempt.spec`, which was built, linted, installed and smoke-tested inside a
  Fedora 44 container before it was believed. A packaged install puts the tree under
  `/usr/share/kempt` with `/usr/bin/kempt` as a symlink into it, moves the root helpers to
  `/usr/libexec`, and `kempt doctor` says `install: packaged`. Building it that way found two
  bugs a first user would have hit: `kempt --version` printed `kempt unknown` because `VERSION`
  was not in the package, and `kempt enable-passwordless` had no rules template to render. The
  transcript is [docs/research/2026-09-02-rpm-spec-verification.md](docs/research/2026-09-02-rpm-spec-verification.md).
- **The version agreement now covers every file that states one.** `tests/test_version.sh` already
  pinned the widget's `KPlugin.Version` to `VERSION`; it pins the metainfo's newest release and
  `kempt.spec`'s `Version:` to it as well. A software centre cannot advertise a release the CLI
  does not report, and `rpm -q kempt` cannot disagree with the binary it installed. The git tag is
  the one number still left to a human, and `docs/RELEASING.md` step 1 says so.

### Notes and known limitations

- Fedora and dnf5 only for now. Adding another distribution is one new backend file, and the
  walkthrough for it is [docs/architecture.md](docs/architecture.md#adding-a-backend-for-your-distro).
- Flatpak support is system scope only. A system-wide `flatpak update` also updates runtimes,
  which the summary does not itemize, so a run can change slightly more than it reports.
- A checkout install is a symlink into the git tree, which stays load-bearing: keep the
  checkout where it is. The widget is the one exception: `kpackagetool6` copies it, so re-run
  `./install.sh` after changing `plasmoid/`. The RPM install has none of these properties - the
  package manager owns every file.
- Developed under the name Upkeep; renamed to Kempt before anything was released, because two
  maintained Linux updaters already answer to the old name.
- The dnf pending check parses text output. Migrating it to `dnf5 check-update --json` is the
  designated next upgrade for that backend.
