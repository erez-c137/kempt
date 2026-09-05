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
| KDE Plasma 6 with `kpackagetool6` | Only for the panel widget. Missing, the installer says so and installs everything else; the CLI does not need it. |

The offline surface additionally needs a dnf5 that supports staged transactions. Check with:

```bash
dnf5 upgrade --help | grep -- --offline
```

## Installed from the package

This is the install the README leads with, and the one most people have:

```bash
sudo dnf copr enable erez-c137/kempt
sudo dnf install kempt-plasmoid
```

Two packages, and the one above brings the other:

| Package | What it is | Requires |
| --- | --- | --- |
| `kempt` | The CLI, the two root helpers, the polkit action, the man page and this documentation. A complete tool on its own - it needs nothing from a desktop, and on a server or in a container that is the point. | `dnf5`, `jq`, `polkit`, `util-linux-core`, `dnf5-command(needs-restarting)` |
| `kempt-plasmoid` | The panel widget and its icons. | `kempt` of the same version, `plasma-workspace` |

They are separate because `kempt` alone is 0.7 MB of bash and had no business requiring
`plasma-workspace`, which on a clean Fedora pulls 787 packages and 2.9 GB - a desktop, on a
machine that asked for an update tool. `kempt-plasmoid` also carries a `Supplements` on
`kempt` **and** `plasma-workspace` together, so a box that already runs Plasma picks the widget up
automatically when it installs or upgrades the CLI.

> **Upgrading from 0.1.1**, where one package carried everything: if the widget disappears from
> your panel after the upgrade, `sudo dnf install kempt-plasmoid` puts it back.

`dnf` keeps all of it in step from then on. Nothing in it is a symlink into your home directory and
nothing in it is yours to edit: the whole tree is root-owned. That is also why `kempt doctor`
compares nothing on a packaged box, where the checkout install has three `match checkout` lines.
There is no checkout for the installed copies to have drifted from.

### What the package installs

| Path | Owner | What it is |
| --- | --- | --- |
| `/usr/bin/kempt` | `root:root` | The command you type. It is a **symlink** to `/usr/share/kempt/bin/kempt`, because the CLI resolves its own tree with `readlink -f`: a real file here would send it looking for `/usr/lib/common.sh`. |
| `/usr/share/kempt/bin/`, `lib/`, `backends/` | `root:root` | The CLI, its library and the two backends. `lib/` and `backends/` are sourced and never executed, so the packaged copies ship without the shebang line the checkout keeps for shellcheck. |
| `/usr/share/kempt/VERSION` | `root:root` 0644 | What `kempt --version` and `kempt doctor`'s first line read. |
| `/usr/share/kempt/polkit/49-kempt.rules.in` | `root:root` 0644 | The template `kempt enable-passwordless` renders. Without it that command has nothing to render and fails on the day somebody runs it, not before. |
| `/usr/libexec/kempt-refresh` | `root:root` 0755 | Root helper: package metadata only, no authentication dialog. |
| `/usr/libexec/kempt-apply` | `root:root` 0755 | Root helper: the dnf upgrade verbs, one authentication per run. |
| `/usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy` | `root:root` 0644 | The two polkit actions. Their `exec.path` pins `/usr/libexec`, not the `/usr/local/libexec` a checkout install pins. |
| `/usr/share/plasma/plasmoids/io.github.erez_c137.kempt/` | `root:root` | The panel widget, in the system-wide plasmoid directory rather than yours. **From `kempt-plasmoid`.** |
| `/usr/share/icons/hicolor/*/apps/kempt.svg` | `root:root` 0644 | The same six-rung icon ladder described below, in the system icon theme. **From `kempt-plasmoid`.** |
| `/usr/share/man/man1/kempt.1` | `root:root` 0644 | `man kempt`, with no symlink to make. |
| `/usr/share/metainfo/io.github.erez_c137.kempt.metainfo.xml` | `root:root` 0644 | What a software centre reads. **From `kempt-plasmoid`.** |
| `/usr/share/doc/kempt/` | `root:root` | The README and the whole `docs/` tree, so the links in them resolve on the machine as well as on the forge. |
| `/etc/polkit-1/rules.d/49-kempt.rules` | `root:root` 0644 | Only after `kempt enable-passwordless`. It names one username, so it is the administrator's file and is **not** part of the package. |

Your settings and state are not installed by the package either. They are created on first use, in
the same two places a checkout install uses: `~/.config/kempt/` (config, holds) and
`~/.local/state/kempt/` (state, history, logs, snapshots). See
[configuration.md](configuration.md#files-and-retention).

### The widget is already in your tray

**Do not add it from Add Widgets as well.** `plasmoid/metadata.json` marks Kempt enabled by default
and declares it a system-tray entry under *System Services*, so the tray enables it on its own the
first time Plasma meets the plugin. It may take a `plasmashell --replace` or a log-out to appear.
Adding it from Add Widgets on top of that gives you two Kempt icons, which is legal and probably
not what you want. Both places, and how to turn either off, are in
[usage.md](usage.md#where-it-lives-the-system-tray-or-the-panel-itself).

### Verify it

```bash
kempt doctor
```

On a packaged box that has not run anything yet:

```
info  kempt 0.1.1 (/usr/share/kempt)
ok    root helper (refresh): /usr/libexec/kempt-refresh (root:root 0755)
ok    root helper (apply): /usr/libexec/kempt-apply (root:root 0755)
ok    polkit action: /usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy
ok    polkit exec.path (refresh): /usr/libexec/kempt-refresh
ok    polkit exec.path (apply): /usr/libexec/kempt-apply
ok    jq: /usr/bin/jq (jq-1.8.1)
ok    terminal emulator: /usr/bin/konsole
ok    flatpak: /usr/bin/flatpak
ok    dnf: /usr/bin/dnf5
ok    config file: none yet, built-in defaults apply (/home/you/.config/kempt/config)
ok    state dir writable: /home/you/.local/state/kempt (created on first use)
ok    checkout intact: /usr/share/kempt
info  version: kempt 0.1.1
info  install: packaged - the package manager keeps these files in step
ok    widget engine: /usr/share/kempt/bin/kempt

Recent events (kempt log):
  none

kempt doctor: all checks passed
```

Four of those lines read oddly until you know what they are asking:

- **`checkout intact`** is named for the developer install but checks whichever tree the CLI
  resolved. Here it is asking whether `lib/`, `backends/` and the passwordless rules template are
  all present under `/usr/share/kempt`.
- **`version:`** carries no commit on a packaged box. The checkout install appends
  `(checkout a1b2c3d clean)`; there is no `.git` under `/usr/share/kempt` to read one from.
- **`install: packaged`** is how doctor tells the two apart, and it decides it by the absence of
  `install.sh` in the tree - the one file a package deliberately does not ship.
- **`widget engine`** resolves `kempt` through the widget's own `PATH` (`~/.local/bin` first) and
  compares it with the CLI that printed the report. A leftover `~/.local/bin/kempt` from an older
  checkout install wins there and nowhere else, so the panel would run one Kempt while everything
  above describes another. That is a `FAIL`, and it names both files.

A widget installed from the KDE Store before the package is the other thing doctor catches here;
see [Installing from the KDE Store first](#installing-from-the-kde-store-first).

### Removing the package

```bash
sudo dnf remove kempt
```

That takes every path in the table above. Two things survive it deliberately: the passwordless
rule, which is not part of the package (remove it with `kempt disable-passwordless` first, or
delete the file by hand), and your own `~/.config/kempt/` and `~/.local/state/kempt/`, which hold
your settings, holds and update history.

## From a checkout (developers)

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
3. **Installs the panel widget and its icon** with `kpackagetool6`, needing no authentication at
   all. It comes after the root step deliberately: a widget installed against missing root
   helpers would sit in the panel showing its error state forever, so a declined authentication
   dialog skips it and says so.
4. **Offers to disable Discover's notifier** (see below). It is an offer, never silent.

It also tells you the checkout is load-bearing: the CLI, its library, the backends and the
passwordless rules template all resolve inside the repo directory, so moving or deleting it
breaks `kempt`. Only the root-owned files and the widget are copies.

### What lands where

| Path | Owner | Installed by |
| --- | --- | --- |
| `~/.local/bin/kempt` | you | `install.sh` (symlink into the checkout) |
| `~/.local/share/man/man1/kempt.1` | you | `install.sh` (symlink into the checkout), so `man kempt` works |
| `/usr/local/libexec/kempt-refresh` | `root:root` 0755 | the one `pkexec` |
| `/usr/local/libexec/kempt-apply` | `root:root` 0755 | the one `pkexec` |
| `/usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy` | `root:root` 0644 | the one `pkexec` |
| `~/.local/share/plasma/plasmoids/io.github.erez_c137.kempt/` | you | `install.sh` (a **copy**, via `kpackagetool6` - no authentication) |
| `~/.local/share/icons/hicolor/scalable/apps/kempt.svg` | you | `install.sh`, so the widget's icon resolves by name in Add Widgets (96 px and up) |
| `~/.local/share/icons/hicolor/64x64/apps/kempt.svg` | you | `install.sh` - same name, the drawing that survives 64 px |
| `~/.local/share/icons/hicolor/48x48/apps/kempt.svg` | you | `install.sh` - same drawing as 64x64 |
| `~/.local/share/icons/hicolor/32x32/apps/kempt.svg` | you | `install.sh` - the six-tooth drawing |
| `~/.local/share/icons/hicolor/22x22/apps/kempt.svg` | you | `install.sh` - hand-hinted on the 22 px grid |
| `~/.local/share/icons/hicolor/16x16/apps/kempt.svg` | you | `install.sh` - hand-hinted on the 16 px grid |
| (no file) a `org.kde.KIconLoader.iconChanged` signal on your session bus | - | `install.sh`, right after the icon, so a running Plasma notices it |
| `~/.config/autostart/org.kde.discover.notifier.desktop` | you | only if you accept the notifier opt-out |
| `/etc/polkit-1/rules.d/49-kempt.rules` | `root:root` 0644 | only after `kempt enable-passwordless` |

The panel widget is the one part of the install that is a **copy** rather than a symlink, because
that is what `kpackagetool6` does. So after changing anything under `plasmoid/`, re-run
`./install.sh` - the CLI follows the checkout, the widget does not. Installing the widget does not
put it on a panel: right-click the panel > **Add Widgets...** > search for **Kempt**.

The icon is installed outside the package on purpose. `metadata.json` asks for it by name
(`kempt`), and a name is resolved through the XDG icon theme, not through the package - measured
on Plasma 6.7, an icon that lives only inside the installed package does not resolve from its name
at all. The copies in `~/.local/share/icons/hicolor/` are the ones Add Widgets actually finds.

There are six of them because the icon is a **size ladder**, the way Breeze ships one: five
different drawings of the same comb, each hinted for the sizes it serves. The fine 17-tooth comb
reads beautifully at 128 px and turns to grey mush at 32, so smaller sizes get progressively
simpler drawings - 17 teeth, then 7, 6, 5, 5. The two smallest are drawn on the 22 px and 16 px
pixel grids themselves, because nothing drawn on the shared 256 unit grid lands on whole pixels
down there. All six are installed under the one name `kempt`, and the theme picks the
directory matching the requested size - a fixed-size directory always beats `scalable/`. Which
drawing serves which size, and the measurements behind each, are in
`docs/research/brand/README.md`.

Installing that file is not quite enough on its own, so `install.sh` also emits one D-Bus signal:

```
dbus-send --session --type=signal /KIconLoader org.kde.KIconLoader.iconChanged int32:0
```

plasmashell works out its icon theme's directory list **once, at startup**. If your session
started before `~/.local/share/icons/hicolor/` existed - which is the ordinary case the first time
you install Kempt - that directory is not in the list, and Add Widgets draws the unknown-icon
placeholder even though `kiconfinder6 kempt` finds the file perfectly in a fresh process. The
signal above is the standard broadcast that tells every running `KIconLoader` to look again; KDE's
own installers emit it for the same reason. It is best-effort: no session bus, or a shell that
ignores it, costs nothing, and **if the widget picker still shows a placeholder icon, log out and
back in.** The installer prints that line too.

The `hicolor` directory deliberately gets **no `index.theme`** of its own. hicolor is merged into
whatever icon theme is loaded rather than being selected on its own, so it needs no theme file -
and writing one would be Kempt describing a theme it does not own.

If `kpackagetool6` is missing (no Plasma, or a minimal install), the widget is skipped with a note
and everything else installs normally. The CLI is the product; the widget is a client of it.

Nothing else is written at install time. Config and state directories are created on first use:
`~/.config/kempt/` (config, holds) and `~/.local/state/kempt/` (state, history, logs,
snapshots). See [configuration.md](configuration.md#files-and-retention).

If `kempt` is not found afterwards, `~/.local/bin` is missing from your `PATH`. Fedora's
default shell profile adds it when the directory exists, so a fresh login usually fixes it:

```bash
command -v kempt    # expect: /home/<you>/.local/bin/kempt
```

### Installing from the KDE Store first

The widget is on the [KDE Store](https://store.kde.org/p/2370353/), so Plasma's **Get New
Widgets** browser can install it on its own. That is one file: the panel widget, and none of the
engine underneath it. A widget installed that way has nothing to ask, and it says so rather than
inventing a count:

> Kempt's engine is not installed, so nothing can check for updates yet.
>
> On Fedora: sudo dnf copr enable erez-c137/kempt, then sudo dnf install kempt. Other systems: github.com/erez-c137/kempt

It is a setup step and it is drawn as one: the panel icon stays dim, with no warning emblem and
no badge, and the popup offers nothing to press. Install the package, press the popup's refresh
button, and the widget fills in. (It also picks itself up on the next scheduled check, so doing
nothing works too, just more slowly.)

**Then remove the store copy.** This is the part that bites silently. `kpackagetool6` - which is
what the store browser uses - installs into
`~/.local/share/plasma/plasmoids/io.github.erez_c137.kempt`, the package installs into
`/usr/share/plasma/plasmoids/`, and **Plasma prefers the copy in your home directory**. So the
store copy goes on being the widget Plasma loads, and every `dnf upgrade` after it updates a
directory nothing reads. Nothing looks wrong: the old copy renders perfectly, forever.

```bash
kpackagetool6 -t Plasma/Applet -r io.github.erez_c137.kempt
plasmashell --replace
```

`kempt doctor` FAILs on this by name whenever it finds a user copy on a packaged install, and it
prints those two commands. Removing the copy does not take the widget off your panel: the panel
records the applet by its plugin id, so the packaged copy takes its place when the shell reloads.

The reverse order needs none of this. Install the package first and the widget arrives with it,
in `/usr/share`, with nothing in your home directory to shadow it.

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

Either kind of install, and this is the first command to run after either one:

```bash
kempt doctor
```

Expect `kempt doctor: all checks passed` and exit status 0. It checks the two root helpers at
the polkit-annotated paths (present, `root:root` 0755), the polkit action file and the `exec.path`
each action pins, `jq`, your terminal emulator, flatpak, dnf, your config file's syntax, a writable
state directory and an intact tree, and it prints one line per check so a failure names itself. Run
it first: if the authentication prompt was declined, or the checkout has since moved, this is the
command that says so. A packaged install prints [a slightly different report](#verify-it), because
it has no checkout to compare its copies against. Full detail in [usage.md](usage.md#doctor).

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

**From the package**, nothing here applies: `sudo dnf upgrade` takes Kempt along with everything
else, and Kempt lists itself in its own popup while it is pending. That is the whole procedure, and
[RELEASING.md](RELEASING.md) says why there is no self-update code behind it.

**From a checkout**, it is two steps, because only one of the installed pieces is a symlink:

```bash
cd /path/to/kempt && git pull
```

The CLI updates immediately, because `~/.local/bin/kempt` points into the checkout. Re-run
`./install.sh` if the root helpers or the polkit action changed - those are copies, and a stale
copy keeps running until it is replaced.

Re-running the installer upgrades the widget package in place, and it says so. Plasma keeps the
QML it already loaded, so run `plasmashell --replace` (or log out and back in) afterwards to see
the new version. The installer deliberately does **not** remove and re-install the package to
force that: removing it would take the widget off your panel and out of your tray with it.

Then `kempt doctor` confirms every copy matches the checkout:

```
info  version: kempt 0.1.1 (checkout a1b2c3d clean)
ok    helpers: match checkout
ok    policy: match checkout
ok    widget: match checkout
```

A `DIFFER` line there is the pull you have not installed yet, and it names the command that fixes
it. A packaged install has none of these three lines: it prints `install: packaged` instead,
because the package manager owns those copies and keeps them in step.

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

From the package, it is `sudo dnf remove kempt`; see
[Removing the package](#removing-the-package). From a checkout:

```bash
./install.sh --uninstall
```

Removes the `~/.local/bin/kempt` and man-page symlinks, removes the panel widget and its icon
(no authentication - `kpackagetool6 -r` plus one file), then asks for authentication once to
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
