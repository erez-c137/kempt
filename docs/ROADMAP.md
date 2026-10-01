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

The release also fixes one problem:

- **Per-user Flatpak apps** were missed, so Kempt said everything was up to date while they had
  updates. Kempt now checks and updates them with the system ones and marks them **For you only**.
  It is on for everyone, so counts rise for people with per-user apps.

## Then: 0.1.8, easier from the first update

0.1.8 is for people trying Kempt for the first time. A few things still assume you are at home in
a terminal. This release fixes the ones we know about. It is small, and planned soon after 0.1.7.

- **Updating without a terminal.** Today, **Update Now** opens a terminal window. When the update
  includes a new kernel or parts of the desktop, it asks you to type a letter to choose what
  happens. In 0.1.8, new installs update inside the popup. For kernel and desktop updates, the
  popup asks with two buttons: **Install on Next Restart** or **Install Now**. Installing on the
  next restart is recommended, because those parts are in use while you work. If you already use Kempt, you keep the terminal. The
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
  It can also keep Kempt waiting while it checks. Today only installing from source offers to turn
  it off. In 0.1.8 the popup offers it, and can turn it back on.
- **For scripts.** Three small changes for people who run `kempt` from their own scripts:
  - `kempt check --strict` exits with an error when a check could not finish. Today a failed
    check still looks like success.
  - `kempt update` exits with its own code, 7, when another program is installing, so a script
    can wait and try again.
  - `kempt history --json` gives every past run as JSON. Today only the latest run is available
    as JSON, through `kempt summary --json`.

After 0.1.8, feedback from new users decides what to improve next.

## 0.2: updates that take care of themselves

Today Kempt tells you updates are waiting, but you still start each one yourself. Many people
would rather not think about it. 0.2 lets Kempt do it for you, safely. It also shows more about
what an update changes.

- **Automatic updates, installed when you restart.** When 0.2 arrives, Kempt asks one question:
  "Install updates automatically the next time you restart?" Answer **Yes** or **No, ask me
  first**. With yes, Kempt downloads system updates in the background and sets them to install
  during your next restart, before the desktop starts. System packages do not change while you work,
  which is what makes this safe to do automatically. Flatpak apps update in the same run, as
  they do today. You still decide when to restart, and Kempt reminds you when updates have waited
  a few days.
  - **No password each time.** Today, installing updates asks for your password unless you turned
    that off. Automatic updates get their own, narrower permission. It can only download packages
    from repositories you already use and set them up for the restart. Because that is all it can
    do, it is designed to work without a password, once its effect on what runs as administrator
    has been checked. Installing right away and cancelling a prepared update keep today's rule:
    they ask for a password unless you turned passwords off.
  - **It stays out of your way.** It runs only while you are logged in, on mains power, and on a
    network that is not marked as metered, for the download as well as the check. It does not drain your battery or use a data plan you
    have marked as metered.
  - **It keeps up with changes.** If something else changes the system in the meantime, Kempt
    prepares the update again. While a Fedora release upgrade is waiting, it does nothing. On a machine
    that more than one person may use, it stays off.
- **A safe restart with NVIDIA.** With NVIDIA's driver from RPM Fusion, restarting too soon after
  a kernel update can leave you without your usual graphics, because the driver is still being
  built for the new kernel. After an update that installs right away, Kempt checks the driver is
  ready before it suggests a restart.
- **A notification when updates arrive.** Today only the badge on the tray icon changes, which is
  easy to miss. 0.2 can also show a notification. You can turn it off.
- **Which updates are security fixes.** Today the list shows package names and versions, which
  does not tell you whether an update matters. 0.2 shows how many system updates fix security
  problems, where Fedora publishes that information. Each package can link to its advisory and its
  changelog.
- **What changed since the last boot.** When something stops working after an update, the first
  question is what changed. Kempt already keeps a record of every run. 0.2 uses it to show what
  changed since you last started the computer.
- **More control from the command line.**
  - `kempt update --security` installs only security fixes.
  - `kempt update --dry-run` shows exactly what dnf would do, and changes nothing. It needs no
    password.
  - Today the state file says no restart is needed both when none is needed and when Kempt could
    not tell. A new field tells the two apart.

## 0.3: a second distribution

Kempt runs only on Fedora today. Other distributions are planned, but Fedora comes first: work on
a second distribution starts once automatic updates work well there.

- **openSUSE first ([#3](https://github.com/erez-c137/kempt/issues/3)).** It is the closest to
  Fedora. It uses rpm, like Fedora, and its package manager, zypper, gives output Kempt can
  read reliably. It also keeps locked packages visible, the way Kempt shows holds. Kempt will tell
  Tumbleweed, which updates with `zypper dup`, apart from Leap. openSUSE has no way to install
  updates during a restart, so Kempt will not offer that there.
- **Then Arch ([#2](https://github.com/erez-c137/kempt/issues/2)), then Debian and Ubuntu
  ([#1](https://github.com/erez-c137/kempt/issues/1)).** Several Arch-based distributions ship
  Plasma by default. Debian and Ubuntu need a design decision first: their package names for other
  architectures, such as `libc6:i386`, do not fit the way Kempt names holds today.
- **What already works everywhere.** Flatpak updates, freeing disk space, holds and the history
  of runs work the same on any distribution.
- **Groundwork, for contributors.** Today, adding a package manager means changes all through the
  tool ([architecture.md](architecture.md#adding-a-backend-for-your-distro) lists them). In 0.3,
  each package manager becomes one file that says how to detect it, what to call it, how to apply
  its updates and when it needs a restart. Installing during a restart moves into the Fedora file,
  so other distributions simply leave it out. Two settings, `disable` and `only`, choose which
  package managers Kempt checks. They arrive while there are only two, so they are simple to get
  right. Scripts that read Kempt's state file keep working unchanged.

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
