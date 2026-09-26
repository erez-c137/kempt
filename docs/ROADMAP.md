# Roadmap

Where Kempt is going, in order. There are no dates: each stage ships when it is ready.

## Shipped: 0.1.x

Public since 2026-09-03, on GitHub, in COPR (Fedora 43 to 45 and rawhide, x86_64 and aarch64) and
on the KDE Store. [CHANGELOG.md](../CHANGELOG.md) has the details.

- **0.1.0:** the command-line tool (`check`, `update` in four ways, holds, summaries, `kempt log`,
  `kempt doctor`, two root helpers), the widget with its settings page, the comb icon, and the
  download size in the popup footer.
- **0.1.2:** separate `kempt` and `kempt-plasmoid` packages. Machines far behind on updates work
  again. Kempt refuses to update image-based Fedora, and to stage over a downloaded
  release upgrade.
- **0.1.3:** the root helper protects a downloaded release upgrade itself, and the package passes
  the checks a Fedora package review runs.
- **0.1.4:** Flatpak runtimes are counted and listed, `kempt unstage` takes back a staged update,
  and the popup shows how old its data is.
- **0.1.5:** a finished run no longer offers to stage what it just staged. A run reports only its
  own dnf transaction. `kempt doctor` says when Discover's notifier also starts at login.

## Now

- **The first outside users.** Their reports come before everything below.
- **New screenshots.** The ones in the README, the metainfo and the store listing predate three
  releases: they show no runtimes section and no way to take back a staged update. The metainfo
  links them by tag, so new ones reach software centres with the release after they land. They
  will be 16:9, because software centres crop tall images badly.
- **Removing the dnf5 text parsers when Fedora 43 reaches end of life.** From then on every
  supported Fedora prints `check-update` and `needs-restarting` as JSON, which Kempt already reads.
- **Fedora's official repos.** The package passes the review tools. The next step is a review
  request, which needs a sponsor.

## 0.1.6: reclaiming disk space

Updating a Flatpak runtime installs the new version beside the old one, and the old one stays. A
machine with one app can end up with two copies of a runtime of a gigabyte or more.
`flatpak uninstall --unused` removes them, but no update tool runs it.

A new setting controls it:

| Value | What happens |
| --- | --- |
| `ask` (default) | When there is space to reclaim, Kempt shows how much and what, and asks. |
| `automatic` | Kempt removes it without asking. |
| `off` | Nothing is removed. |

Two rules hold for every value:

- Kempt removes only what the package manager itself calls unused, and nothing an installed app
  needs.
- Old kernels stay. dnf keeps the last few so you can boot the previous one if the new one fails,
  and it removes old ones on its own schedule.

To show the list, Kempt runs `flatpak uninstall --unused` with no terminal attached. Flatpak then
prints what it would remove and answers no by itself (`flatpak_yes_no_prompt()` in
`app/flatpak-tty-utils.c`, as of 1.18.2). The command never gets `-y` or `--noninteractive`,
because those turn the listing into a removal. A proper listing option is requested upstream in
flatpak/flatpak#5185.

## 0.2: a second distribution

- **A backend registry.** Today a new backend touches every row of the wiring table in
  [architecture.md](architecture.md#adding-a-backend-for-your-distro). With a registry, each
  package manager declares how it is detected, labelled and applied, and when it needs a restart.
  A new backend becomes one file plus its tests. The state file stays at schema v1.
- **openSUSE first ([#3](https://github.com/erez-c137/kempt/issues/3)).** zypper uses the same rpm
  database, has machine-readable output, and keeps locked packages visible, as Kempt's holds do.
  Tumbleweed updates with `zypper dup`, so Kempt tells it apart from Leap. openSUSE has no offline
  updates, so staging is not offered there.
- **Settings that name backends** (`disable`, `only`), added while there are only two backends.
- **Arch ([#2](https://github.com/erez-c137/kempt/issues/2)) next, then Debian and Ubuntu
  ([#1](https://github.com/erez-c137/kempt/issues/1)).** Several Arch-based distributions ship
  Plasma by default. apt needs a design decision first: multiarch package names do not fit the
  current hold syntax.

## Before 1.0

1.0 promises that the public formats stay stable and the numbers are right. It ships when:

- There is no known way for the badge, a run or the history to disagree with what the package
  manager did.
- The state file, the settings, the exit codes and the history format are frozen and documented,
  and shaped by at least two system package managers.
- The code that runs as root has been reviewed again.
- Outside users have run a release candidate, with no open report of lost data or a wrong count.

Acceptance into Fedora's official repos is not a condition, because that timeline is Fedora's. The
package stays ready for review at every release.

## 1.x

- **A choice of panel icon.** Three options, through `kempt config` (`widget_icon`, default
  `theme`): the icon theme's own update icons, the Kempt comb, or any icon name. When the comb is
  used, the QML picks the 16px or 22px file from `Logic.snapIconSize`, because
  `plasmoid/contents/icons/` matches by file name only.
- **Translations.** The QML has 73 `i18n()` calls, but there is no translation domain, catalogue
  or extraction step yet. About 15 to 20 of the popup's sentences are also built from parts in
  `logic.js`, which translators cannot reorder. Both need fixing together: `logic.js` gets a
  translation hook that works in QML and under node, and each built sentence becomes a whole
  `i18np()` sentence. Until then Kempt is English only.
- **Update later.** Options such as "later", "tonight" or "only on Wi-Fi", for people who now close
  the popup to put an update off.
- **A restart reminder that stays dismissed.** Closing it now hides it until Plasma restarts. To
  remember it longer, Kempt would store the dismissal against the boot ID, as offline staging
  does.
- **Announcing results to screen readers.** Every control has an accessible name, but
  **Refresh**, **Update Now** and the padlock do not announce what happened.
- **Per-user Flatpak apps.** Kempt handles the system installation only. Every command in
  `backends/flatpak.sh` passes `--system`, so per-user apps are neither counted nor updated.
  Flatpak updates already run as you, so what is left is deciding how the setting works.
- **Fedora's official repos, after COPR.** Then `dnf install kempt` works with no COPR step. It
  also lets the widget offer a real install button through PackageKit, which can only install from
  repos that are already enabled. Until then, the widget offers **Copy Commands**.
- **Fedora Atomic (Silverblue, Kinoite, Bazzite, bootc images).** Kempt already detects these and
  refuses to update them. Updates there are image deployments, so they need their own backend,
  built on `rpm-ostree status --json`. The first step is read-only: `kempt check` reports the
  pending deployment and its version, next to the Flatpak list, while `update` keeps refusing.
  Holds are an open question, because you cannot hold one package out of an image built elsewhere.

## 2.0

- **Update insights.** Warnings and advice for this machine, built only from sourced data. That
  means dnf security advisories with severity, and which updates affect your hardware (for example
  "mesa: affects your AMD GPU", or an NVIDIA driver rebuild on next boot). It also covers what an
  update does to the running session, and optional Fedora Bodhi feedback.
- **Standalone tools.** A `tools` backend for programs installed as a single downloaded binary,
  which nothing else keeps track of. Kempt reads the installed version, checks one upstream feed,
  and supports holds and summaries as for any backend. Anything owned by a project, lockfile,
  language runtime or version manager is reported as owned by that tool and left alone.
- **Per-version holds** that skip one bad release and clear themselves on the next. Optional
  `dnf versionlock` support. An **Install on Next Restart** action in the notification.
- **Per-backend settings** (`disable`, `only`, `ignore_failures`), in the style of topgrade.

## Later

- Other desktops, through a StatusNotifierItem tray app on the same command-line tool.
- Firmware through fwupd, possibly. Firmware fails differently from packages, so it waits until the
  distribution backends are proven.
- **dnf5daemon as an optional backend**, for live download and install progress in the popup.
  Kempt runs dnf5 directly today, because dnf5daemon is not installed by default on Fedora KDE, it
  cannot say whether a restart is needed or which packages are held, and its permissions are
  broader than the one-user rule Kempt installs. This moves up if people ask for progress in the
  popup, or if Fedora starts installing dnf5daemon by default.
- Replacing the deprecated `Plasma5Support.DataSource` when KDE ships its successor. It is used in
  one QML file only.
- Whatever the first outside users ask for most.
