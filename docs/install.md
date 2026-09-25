# Installing Kempt

## Requirements

Verified on Fedora 44: dnf5 5.4.3, flatpak 1.18.1, KDE Plasma 6.7.4, bash 5.3, jq 1.8.

| Needed | Why |
| --- | --- |
| Fedora with `dnf5` | The backend runs `dnf5 check-update`, `makecache`, `upgrade` and `needs-restarting`. Fedora 41 was the first release to ship dnf5 as the default `dnf`. |
| A package-based Fedora, for now | Silverblue, Kinoite, Bazzite and bootc images ship dnf5 too, so Kempt installs and its checks pass. But dnf cannot write `/usr` there, so `kempt update` refuses in pre-flight (exit 5) and names `rpm-ostree upgrade`, or `bootc upgrade` on a bootc image. Everything that only reads works: `kempt check`, holds, the event log and `kempt doctor`. Support for those images is planned; see [the roadmap](ROADMAP.md). |
| `rpm` | The before/after snapshots behind the summary come from `rpm -qa`. |
| `jq` | Every state and history file is JSON. Without it, every command exits 3. `sudo dnf install jq` |
| `polkit` (`pkexec`) | The two root helpers are launched through polkit actions. Present on any Plasma install. |
| bash 4+, coreutils, GNU awk/grep/sed/join/sort, `flock` | The CLI is bash and the parsers are GNU text tools. All are in a base Fedora install. |
| `flatpak` | Only when `include_flatpak` is on (the default). On a machine without Flatpak, run `kempt config set include_flatpak false`. |
| `notify-send` (libnotify) | Desktop notifications from the detached surfaces. If it is missing, notifications are skipped. |
| `konsole` | Only for the `terminal` surface. For another emulator, set `KEMPT_TERMINAL` in your environment. |
| KDE Plasma 6 with `kpackagetool6` | Only for the panel widget. If it is missing, the installer says so and installs everything else. |

The offline surface also needs a dnf5 that supports staged transactions. Check with:

```bash
dnf5 upgrade --help | grep -- --offline
```

## Installed from the package

Most people install this way:

```bash
sudo dnf copr enable erez-c137/kempt
sudo dnf install kempt-plasmoid
```

That installs two packages, because `kempt-plasmoid` requires `kempt`:

| Package | What it is | Requires |
| --- | --- | --- |
| `kempt` | The CLI, the two root helpers, the polkit actions, the man page and this documentation. It needs no desktop, but it needs an active local session: polkit refuses both Kempt actions over SSH. Without the widget nothing checks on a schedule, so the CLI alone checks only when you run it. | `dnf5`, `jq`, `polkit`, `util-linux-core`, `dnf5-command(needs-restarting)` |
| `kempt-plasmoid` | The panel widget and its icons. | `kempt` of the same version, `plasma-workspace`, `hicolor-icon-theme` |

The CLI is a separate package so that it does not pull in a desktop. `kempt-plasmoid` also
`Supplements` `kempt` and `plasma-workspace` together. On a machine that already runs Plasma, dnf
adds the widget when it installs or upgrades the CLI.

> **Upgrading from 0.1.1**, where one package carried everything: run `sudo dnf upgrade`. On a
> machine running Plasma, dnf installs `kempt-plasmoid` in the same transaction, so the panel is
> untouched. With weak dependencies switched off (`install_weak_deps=False`), run
> `sudo dnf install kempt-plasmoid` once.

From then on, `dnf` keeps everything in step. The whole tree is root-owned, and nothing in it is
a symlink into your home directory.

### What the package installs

| Path | Owner | What it is |
| --- | --- | --- |
| `/usr/bin/kempt` | `root:root` | The command you type. A **symlink** to `/usr/share/kempt/bin/kempt`, because the CLI finds its own tree with `readlink -f`. |
| `/usr/share/kempt/bin/`, `lib/`, `backends/` | `root:root` | The CLI, its library and the two backends. |
| `/usr/share/kempt/VERSION` | `root:root` 0644 | What `kempt --version` and the first line of `kempt doctor` read. |
| `/usr/share/kempt/polkit/49-kempt.rules.in` | `root:root` 0644 | The template `kempt enable-passwordless` renders. |
| `/usr/libexec/kempt-refresh` | `root:root` 0755 | Root helper: package metadata only, no authentication dialog. |
| `/usr/libexec/kempt-apply` | `root:root` 0755 | Root helper: the dnf upgrade verbs, one authentication per run. |
| `/usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy` | `root:root` 0644 | The two polkit actions. Their `exec.path` pins `/usr/libexec`. |
| `/usr/share/plasma/plasmoids/io.github.erez_c137.kempt/` | `root:root` | The panel widget. **From `kempt-plasmoid`.** |
| `/usr/share/icons/hicolor/*/apps/kempt.svg` | `root:root` 0644 | The icon at each size. **From `kempt-plasmoid`.** |
| `/usr/share/man/man1/kempt.1` | `root:root` 0644 | `man kempt`. |
| `/usr/share/metainfo/io.github.erez_c137.kempt.metainfo.xml` | `root:root` 0644 | What a software centre reads. **From `kempt-plasmoid`.** |
| `/usr/share/doc/kempt/` | `root:root` | The README, the changelog, `SECURITY.md` and the user guides in `docs/`, at the same relative paths so their links work. |
| `/etc/polkit-1/rules.d/49-kempt.rules` | `root:root` 0644 | Only after `kempt enable-passwordless`. It names one user, so it is not part of the package. |

Your settings and state are created on first use, in `~/.config/kempt/` (config, holds) and
`~/.local/state/kempt/` (state, history, logs, snapshots). See
[configuration.md](configuration.md#files-and-retention).

### The widget is already in your tray

**Do not also add it from Add Widgets.** Kempt is a system-tray entry under *System Services*,
enabled by default. The tray shows it the first time Plasma loads the plugin. It may take a
`plasmashell --replace` or a log-out to appear. Adding it from Add Widgets as well gives you two
Kempt icons. Both places, and how to turn either off, are in
[usage.md](usage.md#where-it-lives-the-system-tray-or-the-panel-itself).

### Verify it

```bash
kempt doctor
```

On a packaged machine that has not run anything yet, expect something like this. Some rows, such
as one about Discover's notifier, depend on what else is installed.

```
info  kempt 0.1.x (/usr/share/kempt)
ok    root helper (refresh): /usr/libexec/kempt-refresh (root:root 0755)
ok    root helper (apply): /usr/libexec/kempt-apply (root:root 0755)
ok    polkit action: /usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy
ok    polkit exec.path (refresh): /usr/libexec/kempt-refresh
ok    polkit exec.path (apply): /usr/libexec/kempt-apply
ok    jq: /usr/bin/jq (jq-1.8.1)
ok    terminal emulator: /usr/bin/konsole
ok    flatpak: /usr/bin/flatpak
ok    dnf: /usr/bin/dnf5
info  package metadata: never refreshed on this box - the next check on mains power and an unmetered connection fetches it
ok    config file: none yet, built-in defaults apply (/home/you/.config/kempt/config)
ok    state dir writable: /home/you/.local/state/kempt (created on first use)
ok    program files intact: /usr/share/kempt
info  version: kempt 0.1.x
info  install: packaged - the package manager keeps these files in step
ok    widget engine: /usr/share/kempt/bin/kempt

Recent events (kempt log):
  none

kempt doctor: all checks passed
```

Four rows differ from a checkout install:

- **`program files intact`** checks that `lib/`, `backends/` and the passwordless rules template
  are present under `/usr/share/kempt`. A checkout install names this row after the checkout.
- **`version:`** has no commit, because there is no `.git` to read one from.
- **`install: packaged`** means `install.sh` is absent from the tree. The package does not ship it.
- **`widget engine`** finds `kempt` on the widget's own `PATH` (`~/.local/bin` first) and compares
  it with the CLI that printed the report. A leftover `~/.local/bin/kempt` from an old checkout
  install would run in the panel instead. That is a `FAIL`, and it names both files.

Doctor also catches a widget installed from the KDE Store before the package; see
[Installing from the KDE Store first](#installing-from-the-kde-store-first).

### Removing the package

```bash
sudo dnf remove kempt
```

That removes every path in the table above except two. The passwordless rule is not part of the
package, so run `kempt disable-passwordless` first or delete the file by hand. Your
`~/.config/kempt/` and `~/.local/state/kempt/` stay, with your settings, holds and update history.

## From a checkout (developers)

```bash
git clone https://github.com/erez-c137/kempt.git
cd kempt
./install.sh
```

The installer does four things, in this order:

1. **Symlinks the CLI and its man page** into `~/.local/bin/kempt` and
   `~/.local/share/man/man1/kempt.1`, so `man kempt` works without root.
2. **Asks for authentication once** (one `pkexec`). As root, it copies the two helpers and the
   polkit action out of the repo.
3. **Installs the panel widget and its icons** with `kpackagetool6`, with no authentication. If
   you decline the dialog in step 2, this step is skipped, because the widget cannot work without
   the root helpers.
4. **Offers to disable Discover's notifier** (see below).

The CLI, its library, the backends and the passwordless rules template all run from the checkout.
Moving or deleting the checkout breaks `kempt`. Only the root-owned files and the widget are
copies.

### What lands where

| Path | Owner | Installed by |
| --- | --- | --- |
| `~/.local/bin/kempt` | you | `install.sh` (symlink into the checkout) |
| `~/.local/share/man/man1/kempt.1` | you | `install.sh` (symlink into the checkout) |
| `/usr/local/libexec/kempt-refresh` | `root:root` 0755 | the one `pkexec` |
| `/usr/local/libexec/kempt-apply` | `root:root` 0755 | the one `pkexec` |
| `/usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy` | `root:root` 0644 | the one `pkexec` |
| `~/.local/share/plasma/plasmoids/io.github.erez_c137.kempt/` | you | `install.sh` (a **copy**, via `kpackagetool6`) |
| `~/.local/share/icons/hicolor/{scalable,64x64,48x48,32x32,22x22,16x16}/apps/kempt.svg` | you | `install.sh`, so the icon resolves by name in Add Widgets |
| (no file) an `org.kde.KIconLoader.iconChanged` signal on your session bus | - | `install.sh`, so a running Plasma finds the new icon |
| `~/.config/autostart/org.kde.discover.notifier.desktop` | you | only if you accept the notifier opt-out |
| `/etc/polkit-1/rules.d/49-kempt.rules` | `root:root` 0644 | only after `kempt enable-passwordless` |

The widget is a copy, so re-run `./install.sh` after changing anything under `plasmoid/`.
Installing the widget does not put it on a panel: right-click the panel > **Add Widgets...** >
search for **Kempt**.

The icon goes into `~/.local/share/icons/hicolor/` because Add Widgets looks it up by name
through the icon theme. Each size directory gets a drawing made for that size. The installer then
sends this signal so a running Plasma rescans its icon directories:

```
dbus-send --session --type=signal /KIconLoader org.kde.KIconLoader.iconChanged int32:0
```

If Add Widgets still shows a placeholder icon, log out and back in. The installer prints that
too.

If `kpackagetool6` is missing, the widget is skipped with a note and everything else installs.

Nothing else is written at install time. Config and state directories are created on first use;
see [configuration.md](configuration.md#files-and-retention).

If `kempt` is not found afterwards, `~/.local/bin` is missing from your `PATH`. Fedora's default
shell profile adds it when the directory exists, so a fresh login usually fixes it:

```bash
command -v kempt    # expect: /home/<you>/.local/bin/kempt
```

### Installing from the KDE Store first

Plasma's **Get New Widgets** can install the widget from the
[KDE Store](https://store.kde.org/p/2370353/). That gives you the panel widget only, without the
engine it runs. Until the engine is installed, the popup says:

> Kempt's engine is not installed, so nothing can check for updates yet.
>
> On Fedora: sudo dnf copr enable erez-c137/kempt, then sudo dnf install kempt. Other systems: github.com/erez-c137/kempt

The panel icon stays dim, with no badge. Install the package and press the popup's refresh
button, or wait for the next scheduled check. If the CLI is installed but cannot run, the popup
shows a different message; run `kempt doctor`.

**Then remove the store copy.** The store installs into
`~/.local/share/plasma/plasmoids/io.github.erez_c137.kempt`, the package installs into
`/usr/share/plasma/plasmoids/`, and Plasma loads the copy in your home directory. The old copy
keeps working, so nothing looks wrong, but package updates never reach your panel.

```bash
kpackagetool6 -t Plasma/Applet -r io.github.erez_c137.kempt
plasmashell --replace
```

On a packaged install, `kempt doctor` FAILs when it finds a user copy and prints those two
commands. Removing the copy keeps the widget on your panel: the packaged copy takes its place when
the shell reloads.

If you install the package first, none of this applies.

### If the authentication prompt is declined

The installer exits 1 and says where it stopped: the CLI symlink is in place, but the root helpers
and the widget are not, so `kempt check` will not work yet. Re-run `./install.sh` when ready.

### The Discover-notifier opt-out

Fedora's `plasma-discover-notifier` duplicates Kempt's notifications. Its background PackageKit
work also takes the dnf5 lock at random moments, which makes Kempt runs fail. The installer asks:

```
Disable plasma-discover-notifier for this user? [Y/n]
```

Yes writes a user-level autostart override at
`~/.config/autostart/org.kde.discover.notifier.desktop`, a copy of the system entry with
`Hidden=true`, and stops any running `DiscoverNotifier`. Nothing system-wide changes. To undo it,
delete the file and log back in:

```bash
rm ~/.config/autostart/org.kde.discover.notifier.desktop
```

`n` or `no` leaves the notifier alone. With no terminal to read an answer from, the installer
leaves the notifier enabled and says so.

## Verify the install

For either kind of install, run this first:

```bash
kempt doctor
```

Expect `kempt doctor: all checks passed` and exit status 0. It prints one line per check, so a
failure names itself. It checks the root helpers, the polkit action and each `exec.path`, `jq`,
your terminal, flatpak, dnf, your config file, the state directory and the installed files. A
packaged install prints [a slightly different report](#verify-it). Full detail is in
[usage.md](usage.md#doctor).

Then check for updates:

```bash
kempt check | jq '{status, actionable, held_total}'
```

Expect `status: "ok"` and a count, with **no** authentication dialog. To compare with dnf, use
the dnf item count, because the total also includes Flatpak apps and excludes held items:

```bash
kempt check | jq '.backends.dnf.items | length'
dnf5 --cacheonly check-update --quiet | wc -l
```

Expect the same ballpark (dnf5 may print a header line, which `wc` counts). Kempt merges
multilib pairs such as `bash.x86_64` and `bash.i686` into one item and filters out obsoleted
packages. This `dnf5` command also reads your user cache, while
Kempt reads the root cache its update will use.

## Passwordless updates (optional)

By default, applying updates raises one KDE authentication dialog per run. To skip it:

```bash
kempt enable-passwordless     # one pkexec prompt to install the rule
```

This renders `polkit/49-kempt.rules.in` with your username, checks the result, and installs it at
`/etc/polkit-1/rules.d/49-kempt.rules`. The rule allows one polkit action,
`io.github.erez_c137.kempt.apply`, for your user, and only in an **active, local** session. It
grants nothing beyond the verbs the apply helper implements.

```bash
kempt disable-passwordless    # removes the rule; saying "not enabled" is not an error
```

The full grant is in [security.md](security.md#passwordless-mode).

## Updating Kempt

**From the package**, `sudo dnf upgrade` updates Kempt with everything else. Kempt lists itself in
its own popup while the update is pending. [RELEASING.md](RELEASING.md) says why there is no
self-update.

**From a checkout**, pull first:

```bash
cd /path/to/kempt && git pull
```

The CLI updates at once, because `~/.local/bin/kempt` points into the checkout. Re-run
`./install.sh` if the root helpers, the polkit action or the widget changed, because those are
copies.

The installer upgrades the widget in place and says so. Plasma keeps the QML it already loaded, so
run `plasmashell --replace` or log out and back in to see the new version. The installer does not
remove and re-install the widget, because that would take it off your panel.

Then `kempt doctor` confirms every copy matches the checkout:

```
info  version: kempt 0.1.x (checkout a1b2c3d clean)
ok    helpers: match checkout
ok    policy: match checkout
ok    widget: match checkout
```

A `DIFFER` line is a change you have pulled but not installed, and it names the command that
fixes it. A packaged install prints `install: packaged` instead of these three lines.

## Staged install (packagers and testers)

`--destdir` stages every file into a prefix, unprivileged, with no `pkexec` and no prompts:

```bash
./install.sh --destdir /tmp/stage
find /tmp/stage -type f -o -type l
./install.sh --destdir /tmp/stage --uninstall
```

The test suite uses this path. It is also the starting point for packaging.

## Uninstall

For the package, see [Removing the package](#removing-the-package). From a checkout:

```bash
./install.sh --uninstall
```

This removes the `~/.local/bin/kempt` and man-page symlinks, and the widget and its icons, with no
authentication. It then asks for authentication once to remove the two root helpers, the polkit
action and the passwordless rule if present. If you decline, it exits 1 and says what is left, so
a second run can finish.

These stay:

- `~/.config/kempt/` and `~/.local/state/kempt/`: your settings, holds and update history.
- `~/.config/autostart/org.kde.discover.notifier.desktop`: your choice about Discover's notifier.

To remove those too:

```bash
rm -rf ~/.config/kempt ~/.local/state/kempt
rm -f ~/.config/autostart/org.kde.discover.notifier.desktop
```
