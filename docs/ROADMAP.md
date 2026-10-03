# Roadmap

Where Kempt is going, in order. There are no dates: each stage ships when it is ready.

## Shipped: 0.1.x

Public since 2026-09-03, on GitHub, in COPR (Fedora 43 to 45 and rawhide, x86_64 and aarch64) and
on the KDE Store. [CHANGELOG.md](../CHANGELOG.md) has the details.

- **0.1.0:** the command-line tool, the widget and its settings page.
- **0.1.2:** separate `kempt` and `kempt-plasmoid` packages.
- **0.1.3:** the package passes the checks a Fedora package review runs.
- **0.1.4:** Flatpak runtimes are listed, and `kempt unstage` takes back a staged update.
- **0.1.5:** a run reports only its own dnf transaction.
- **0.1.6:** Kempt reads dnf5's JSON output on Fedora 44 and later.
- **0.1.7:** `kempt reclaim` frees the space unused Flatpak runtimes take.
- **0.1.8:** updates run in the widget, with no terminal needed.

## Now

- **The first outside users.** Their reports come before everything below.
- **Removing the dnf5 text parsers when Fedora 43 reaches end of life.** From then on every
  supported Fedora prints `check-update` and `needs-restarting` as JSON, which Kempt already reads.
- **Fedora's official repos.** The package passes the review tools. The next step is a review
  request, which needs a sponsor.

## 0.2: updates that take care of themselves

Today Kempt tells you updates are waiting, and you start each one yourself. 0.2 can do it for you,
safely. It also shows more about what an update changes.

- **Automatic updates, installed when you restart.** Kempt asks once: "Install updates
  automatically the next time you restart?" Answer **Yes** or **No, ask me first**. With yes,
  Kempt downloads system updates in the background. They install during your next restart, before
  the desktop starts. System packages stay unchanged while you work, which is what makes this
  safe. Flatpak apps update in the same run. You still decide when to restart. Kempt reminds you
  when updates have waited a few days.
  - **No password each time.** Automatic updates get their own, narrower permission. It can only
    download packages from your enabled repositories and set them up for the restart. So it can
    work without a password, once its effect on what runs as root has been checked. Installing
    right away and cancelling a prepared update keep today's password rule.
  - **It stays out of your way.** It runs only while you are logged in, on mains power, and on a
    connection not marked as metered. That covers the download as well as the check.
  - **It keeps up with changes.** If something else changes the system, Kempt prepares the update
    again. It does nothing while a Fedora release upgrade is waiting. On a machine that more than
    one person may use, it stays off.
- **A safe restart with NVIDIA.** With RPM Fusion's NVIDIA driver, a restart soon after a kernel
  update can leave you without your usual graphics. The driver is still being built for the new
  kernel. After an update that installs right away, Kempt checks the driver is ready before it
  suggests a restart.
- **A notification when updates arrive.** Today only the badge on the tray icon changes. 0.2 can
  also show a notification, which you can turn off.
- **Which updates are security fixes.** 0.2 shows how many system updates fix security problems,
  where Fedora publishes that. Each package can link to its advisory and its changelog.
- **What changed since the last boot.** Kempt keeps a record of every run. 0.2 uses it to show
  what changed since you last started the computer.
- **More control from the command line.**
  - `kempt update --security` installs only security fixes.
  - `kempt update --dry-run` shows what dnf would do and changes nothing. It needs no password.
  - A new state field tells "no restart needed" apart from "could not tell". Today `reboot_needed`
    is `false` for both.

## 0.3: a second distribution

Kempt runs only on Fedora today. Work on a second distribution starts once automatic updates work
well on Fedora.

- **openSUSE first ([#3](https://github.com/erez-c137/kempt/issues/3)).** It uses rpm, like
  Fedora, and zypper's output is easy to read. It also keeps locked packages visible, the way Kempt
  shows holds. Kempt will tell Tumbleweed (`zypper dup`) apart from Leap. openSUSE cannot install
  updates during a restart, so Kempt will not offer that there.
- **Then Arch ([#2](https://github.com/erez-c137/kempt/issues/2)), then Debian and Ubuntu
  ([#1](https://github.com/erez-c137/kempt/issues/1)).** Several Arch-based distributions ship
  Plasma by default. Debian and Ubuntu need a design decision first. Their names for packages of
  other architectures, such as `libc6:i386`, do not fit the way Kempt names holds.
- **What already works everywhere.** Flatpak updates, freeing disk space, holds and the history
  of runs.
- **Groundwork, for contributors.** Today a new package manager means changes all through the tool
  ([architecture.md](architecture.md#adding-a-backend-for-your-distro) lists them). In 0.3, each
  package manager becomes one file. It says how to detect it, what to call it, how to apply its
  updates and when it needs a restart. Installing during a restart moves into the Fedora file.
  Two settings, `disable` and `only`, choose which package managers Kempt checks. Scripts that
  read the state file keep working unchanged.

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

- **A choice of panel icon:** the icon theme's own update icons, the Kempt comb, or any icon name.
- **Translations.** The QML wraps its text in `i18n()`, but there is no translation domain,
  catalogue or extraction step yet. Some widget sentences are also built from parts in `logic.js`,
  which translators cannot reorder. Both get fixed together. Until then Kempt is English only.
- **Everyday words.** "System" and "Apps" in the widget in place of "dnf" and "flatpak", with the
  full package list one click away.
- **Update later.** "Tonight" or "only on Wi-Fi". Automatic staging may make it unnecessary.
- **Holds with patterns** such as `kernel*`, with a warning when a pattern matches most of the list.
- **A restart reminder that stays dismissed.** Closing it hides it until Plasma restarts. Kempt
  would store the dismissal against the boot ID, as offline staging does.
- **Fedora's official repos, after COPR.** Then `dnf install kempt` works with no COPR step. The
  widget could then offer a real install button through PackageKit, which installs only from
  enabled repos. Until then, the widget offers **Copy Commands**.
- **Fedora Atomic (Silverblue, Kinoite, Bazzite, bootc images).** Kempt detects these and refuses
  to update them. Support is planned. Updates there are image deployments, so they need their own
  backend, built on `rpm-ostree status --json`. The first step is read-only: `kempt check` reports
  the pending deployment next to the Flatpak list, and `update` keeps refusing. Holds are an open
  question, because you cannot hold one package out of an image built elsewhere.

## 2.0

- **Update insights.** Advice for this machine, built only from sourced data. That means advisory
  severity, and which updates affect your hardware, such as "mesa: affects your AMD GPU". It also
  covers what an update does to the running session, and optional Fedora Bodhi feedback.
- **Standalone tools.** A `tools` backend for programs installed as a single downloaded binary.
  Kempt reads the installed version, checks one upstream feed, and supports holds and summaries.
  Anything a project, lockfile, language runtime or version manager owns is left to that tool.
- **Per-version holds** that skip one bad release and clear themselves on the next.
- **Optional `dnf versionlock` support**, so a plain `dnf upgrade` respects a hold too. It changes
  system-wide settings, so it always asks for a password.
- **An Install on Next Restart action in the notification.**
- **Per-backend settings** (`disable`, `only`, `ignore_failures`), in the style of topgrade.

## Later

- Other desktops, through a StatusNotifierItem tray app on the same command-line tool.
- Firmware through fwupd, possibly. Firmware fails differently from packages, so it waits until the
  distribution backends are proven.
- **dnf5daemon as an optional backend**, for live progress in the widget. Fedora KDE does not
  install it by default. It cannot say whether a restart is needed or which packages are held. Its
  permissions are also broader than the one-user rule Kempt installs. This moves up if people ask
  for progress, or if Fedora installs dnf5daemon by default.
- Replacing the deprecated `Plasma5Support.DataSource` when KDE ships its successor. One QML file
  uses it.
- Whatever the first outside users ask for most.
