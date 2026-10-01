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
- **0.1.6:** on Fedora 44 and later, Kempt reads dnf5's JSON output. The panel tooltip names
  what is pending, and an update runs one check afterwards instead of four.

## Now

- **The first outside users.** Their reports come before everything below.
- **New screenshots.** The ones in the README, the metainfo and the store listing predate three
  releases: they show no runtimes section, no way to take back a staged update and no offer to
  free space. The metainfo
  links them by tag, so new ones reach software centres with the release after they land. They
  will be 16:9, because software centres crop tall images badly.
- **Removing the dnf5 text parsers when Fedora 43 reaches end of life.** From then on every
  supported Fedora prints `check-update` and `needs-restarting` as JSON, which Kempt already reads.
- **Fedora's official repos.** The package passes the review tools. The next step is a review
  request, which needs a sponsor.

## Next: 0.1.7, reclaiming disk space

Built and on `main`, waiting for its release. [CHANGELOG.md](../CHANGELOG.md) lists it under
Unreleased.

Updating a Flatpak runtime installs the new version beside the old one, and the old one stays. A
machine with one app can end up with two copies of a runtime of a gigabyte or more.

- **`kempt reclaim`** lists the runtimes no installed app uses, estimates the space they take, and
  removes them when you agree.
- **The widget** offers the same when there is 100 MB or more to free.
- **The `reclaim` setting** is `ask` (the default), `automatic` or `off`. `automatic` removes them
  after each update. It acts as `ask` on an image-based system, and when more than one person may
  use the machine. `off` hides them.

These rules hold for every value:

- Kempt removes only what Flatpak itself calls unused, and only the list you were shown. If the
  list changed, nothing is removed.
- A runtime is offered once it has been unused for an hour, so one another tool is installing is
  left alone.
- Kempt never asks for a password. When removing needs an administrator, it says so and removes
  nothing.
- Extensions, such as a graphics driver or a translation, go last. Kempt lists again first and
  removes only those still unused, so one an app has just started using stays.
- Old kernels stay. dnf keeps the last few so you can boot the previous one if the new one fails,
  and it removes old ones on its own schedule.

## Then: 0.1.8, easier from the first update

0.1.8 is for people trying Kempt for the first time. A few things still assume you are at home in
a terminal. This release fixes the ones we know about. It is small, and planned soon after 0.1.7.

- **Updating without a terminal.** Today, **Update Now** opens a terminal window. When the update
  includes a new kernel or parts of the desktop, it asks you to type a letter to choose what
  happens. In 0.1.8, new installs update inside the popup. For kernel and desktop updates, the
  popup asks with two buttons: **Install on Next Restart** (recommended, because those parts are in
  use while you work) or **Install Now**. If you already use Kempt, you keep the terminal. The
  popup asks once whether you want to switch.
- **Fixes you can click.** When something goes wrong, the popup sometimes tells you to run a
  command such as `kempt doctor` in a terminal. In 0.1.8 these messages get a button, so you do
  not need to open a terminal. The command stays visible for anyone who prefers to type it.
- **A clear message when another updater is busy.** Only one program can install software at a
  time. When Discover or another tool is installing, Kempt waits and tries again. If it still
  cannot get in, system packages get a clear "busy" message, but Flatpak shows its own raw error.
  In 0.1.8 Flatpak gets the same clear message.
- **One update notifier, not two.** Discover, Plasma's software center, has its own update
  notifier. It counts updates differently, so you can see two icons with two different numbers.
  It can also keep Kempt waiting while it checks. Today only the install script offers to turn it
  off. In 0.1.8 the popup offers it, and can turn it back on.
- **For scripts.** Three small changes for people who run `kempt` from their own scripts:
  - `kempt check --strict` exits with an error when a check could not finish. Today a failed
    check still looks like success.
  - `kempt update` exits with its own code, 7, when another program is installing, so a script
    can wait and try again.
  - `kempt history --json` gives every past run as JSON. Today only the latest run is available
    that way.

After 0.1.8, feedback from new users decides what to improve next.

## 0.2: updates on their own, and more control

- **Automatic updates, staged for the next restart.** One question, asked when this arrives:
  "Install updates automatically the next time you restart?" **Yes** or **No, ask me first**.
  With yes, Kempt downloads and stages updates on its own, and they install the next time you
  restart. System packages do not change under the running desktop. Flatpak apps are updated in
  the same run. The restart stays your choice, and Kempt reminds you when staged updates have
  waited a few days.
  - Staging gets its own permission. It can only download packages from repositories you already
    use and queue them for the restart, so it is designed to be allowed without a password, once
    its effect on what runs as root is reviewed. Installing now and taking a stage back keep
    today's rule: they ask for a password unless passwordless updates are on.
  - It runs only while you are logged in. It waits for mains power and a network that is not
    marked as metered, for the download as well as the check.
  - It re-stages when something else changed the system, skips quietly while a release upgrade
    is waiting, and stays off when more than one person may use the machine.
- **Safe to restart.** After an update that installs now, Kempt checks that the NVIDIA driver
  from RPM Fusion is built for the new kernel before it suggests a restart.
- **A notification when updates arrive**, which can be turned off. Today only the badge changes.
- **Is it safe?** The system group says how many updates are security fixes, when Fedora's
  advisory data covers them. Each row can show its advisory and a link to the changelog.
- **What changed since the last boot**, from the history Kempt already keeps, for when something
  stops working after an update.
- **More control.**
  - `kempt update --security` installs security fixes only.
  - `kempt update --dry-run` shows the transaction dnf would run, and changes nothing. It needs
    no password.
  - The state file says when Kempt could not tell whether a restart is needed, in a new field.

## 0.3: a second distribution

Kempt goes deep on Fedora before it goes wide. A second distribution starts once automatic
updates work well there.

- **A backend registry.** Today a new backend touches every row of the wiring table in
  [architecture.md](architecture.md#adding-a-backend-for-your-distro). With a registry, each
  package manager declares how it is detected, labelled and applied, and when it needs a restart.
  A new backend becomes one file plus its tests. The state file stays at schema v1.
- **Offline updates move behind the backend.** Staging an update for the next restart is
  dnf5-specific and spread through the tool, not kept in the dnf backend. It moves there first,
  so a distribution without offline updates simply does not offer staging. Flatpak, reclaiming
  space, holds and history already work the same on any distribution.
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
- **Everyday words.** "System" and "Apps" in the popup, not "dnf" and "flatpak", with the full
  package list one click away.
- **Update later.** "Tonight" or "only on Wi-Fi", for people who now close the popup to put an
  update off. Automatic staging may make it unnecessary.
- **Per-user Flatpak apps.** Kempt handles the system installation only, so per-user apps are
  neither counted nor updated. It would be off for existing installs, so their counts do not jump.
- **Holds with patterns** such as `kernel*`, with a warning when a pattern matches most of the list.
- **A restart reminder that stays dismissed.** Closing it now hides it until Plasma restarts. To
  remember it longer, Kempt would store the dismissal against the boot ID, as offline staging
  does.
- **Announcing results to screen readers.** Every control has an accessible name, but
  **Refresh**, **Update Now** and the padlock do not announce what happened.
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
  means advisory severity, and which updates affect your hardware (for example
  "mesa: affects your AMD GPU", or an NVIDIA driver rebuild on next boot). It also covers what an
  update does to the running session, and optional Fedora Bodhi feedback.
- **Standalone tools.** A `tools` backend for programs installed as a single downloaded binary,
  which nothing else keeps track of. Kempt reads the installed version, checks one upstream feed,
  and supports holds and summaries as for any backend. Anything owned by a project, lockfile,
  language runtime or version manager is reported as owned by that tool and left alone.
- **Per-version holds** that skip one bad release and clear themselves on the next. Optional
  `dnf versionlock` support, so a plain `dnf upgrade` respects a hold too. It changes system-wide
  settings, so it always asks for a password. An **Install on Next Restart** action in the
  notification.
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
