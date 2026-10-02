# Using the Kempt widget

The Kempt widget sits in your panel, counts the updates waiting for you and installs them when you
press **Update Now**. This page covers everything it shows and every button. You never need a
terminal to use it. The commands behind it are in [usage.md](usage.md).

## Where it lives: the system tray, or the panel itself

You can use the widget in either place, or both.

**In the system tray** (the default). Kempt appears beside the volume and network icons. The first
time, it may need a plasmashell restart or a new login. To hide it or move it behind the arrow:

> Right-click the tray > **Configure System Tray...** > **Entries** > find **Kempt**.

**On the panel.** Use this to place it somewhere specific, or make it larger:

> Right-click the panel > **Add Widgets...** > search for **Kempt** > drag it onto the panel.

Using both gives you two Kempt icons, so you probably want to turn one off.

The package installs the widget for everyone. A checkout install puts a copy in
`~/.local/share/plasma/plasmoids/`, so after changing anything under `plasmoid/`, run
`./install.sh` again.

## What the panel icon means

| Icon | State | What it tells you |
|---|---|---|
| Update icon with a count badge | Updates pending | The count is what an update would change now. Held packages are left out. The tooltip names the first three, kernel and other session-critical packages first. |
| Plain update icon, no badge | Up to date | Nothing to do. The tooltip still shows how many packages are held. |
| Same as before, badge kept | Last check failed | The counts are from the last check that worked. The tooltip gives the reason and the time of that check. |
| Warning emblem | Error | Kempt could not run, or could not read its state. The tooltip names the problem and points at `kempt doctor`. |
| Spinner | Updating | A run started from the widget is in progress. |
| Dimmed, no badge | No data yet | The first check has not answered yet. If another check was running, as is common right after login, it asks again a few times about ten seconds apart. |

The badge counts up to `999`, then shows `999+`. On a panel thinner than 22 px, or with **Small**
chosen, there is no badge. The icon still changes, and the tooltip has the count.

**Panel icon size**, under **Configure Kempt…**, offers **Automatic**, **Small** (16 px),
**Medium** (22 px) and **Large** (32 px). **Automatic** matches the system tray. That is 22 px on
panels from 22 to 47 px high, which covers Plasma's default panel, and 48 or 64 px on very thick
or HiDPI panels. **Large** is never smaller than **Automatic**. Inside the system tray, the tray
sets the size. The setting is `widget_icon_size` in [configuration.md](configuration.md#keys).

## The popup

Click the icon. The popup has a **header** that says where you stand, a **content area**, and a
**footer** with the main button.

With updates pending, a restart owed and a kernel in the update:

```
 3 updates available                                 [refresh] [gear]   <- header: the count,
 --------------------------------------------------------------------     Refresh, settings
 (!) Restart to apply installed updates          [Restart…]      [x]   <- at most TWO messages,
 (i) This update includes a kernel. The safest way is to                   in priority order
     install it on the next restart, so nothing changes
     under the running desktop.
                                        [Install on Next Restart]

 System (dnf)                                                          <- the pending list,
   nodejs                                                     [🔓]       grouped by backend
   2:24.19.0-1nodesource → 2:24.20.0-1nodesource
 Apps (flatpak)
   org.mozilla.firefox                                        [🔓]
   140 → 141
 Held                                                                  <- held items stay
 Held packages are skipped by Kempt only.                                 visible, out of
   kernel-core                                                [🔒]       the running
   Held  6.15.1 → 6.15.3

 Last update 18 min ago · 4 packages                            [v]    <- expands to what
 --------------------------------------------------------------------     that run installed
 Checked 4 min ago · 1 held · ~140 MB              [ Update Now ]      <- footer: the dateline,
                                                                          the cost, and the
                                                                          one action
```

### Header

The header reads one of:

- `3 updates available`. The count has no cap.
- `Up to date`, or `Up to date · 2 held` when every pending update is held, or
  `Up to date · apps for you only not checked` when the apps installed for you alone could not be
  listed.
- `23 updates staged for the next restart`, while an update is staged.
- `Updating…`
- `No update data yet`, before the first check answers.
- `Kempt's engine is not installed`, when the widget is installed without the command-line program
  (see [install.md](install.md#installing-from-the-kde-store-first)).
- `Kempt's engine will not run`, when the program is there and cannot start.
- `Kempt cannot check for updates`, when running the program failed or no check has ever
  succeeded.
- `Could not read the update state`, when this widget cannot read the state file. Usually the
  widget is older than the program.

**Check for Updates**, the circular arrow, fetches fresh package lists, then checks. The fetch can
take a minute or more. On battery or a metered connection it checks without fetching. After a
failed check, its tooltip gives the reason, such as `dnf check failed: repo 'updates' unavailable`.
While a check or update runs, it is greyed out with a spinner beside it. It is also in the icon's
right-click menu and the tray's **More actions** menu.

The **gear** opens **Configure Kempt…**, the same as the right-click menu. Inside the system tray,
the tray's own heading has the arrow and the gear, so the popup hides its copies.

### Messages

Messages appear only when they apply, and **at most two show at once**. When more apply, the ones
lower in this list are left out. If that hides the restart message, the footer says
`restart pending` in its place.

1. **The engine is missing or will not run.** *"Nothing can check for updates yet."*, with the
   install commands and **Copy Commands**. Or *"Kempt's engine is installed but will not run, so
   nothing can check for updates."*, with **Check Installation** and **Copy Command**. Either one
   shows alone. See [install.md](install.md#installing-from-the-kde-store-first).
2. **What just happened:** `Updated 4 packages in 2s`, `No package changes`, or
   `Update failed: <the reason>`. For a button press that failed, it shows what Kempt said.
   **Show Log** is on it when a *run* recorded a log file, which every run does, including installs
   during a restart. If that log could not be saved, there is no button. When the message tells you
   to run `kempt doctor`, it adds **Check Installation**. The message goes when you close the popup
   or the next check starts.
3. **This system updates with rpm-ostree**, on an image-based Fedora such as Kinoite. It points at
   Discover or `rpm-ostree upgrade` (`bootc upgrade` on a bootc image). **Update Now** is hidden.
4. **A Fedora release upgrade is stored.** It says what state the upgrade is in and what to do.
   The upgrade may install on the next restart, or be downloaded but not started. A restart may
   have skipped it, or it may not have finished.
5. **What the next restart will install**, when an update is staged. See
   [The staged banner](#the-staged-banner). **Update Now** is hidden while it shows.
6. **Restart to apply installed updates**, with **Restart…** and a close button. See
   [About the restart](#about-the-restart).
7. **"This update includes a kernel. The safest way is to install it on the next restart, so
   nothing changes under the running desktop."** Another version also names the NVIDIA driver.
   Without a kernel, it names the desktop packages in the update: `This update touches 20 packages
   the running desktop depends on (dbus, glibc, kf6, mesa, ...). The safest way is to install them
   on the next restart.` Its button is **Install on Next Restart**. It is hidden while an update is
   staged. After **Update Now**, when updates run outside a terminal, the same message asks first:
   it moves to the top and adds **Install Now**. **Install on Next Restart** has the keyboard focus.
8. **"Updates can now run in this widget instead of a terminal window."** It shows once, on an
   install that kept the terminal when it upgraded to 0.1.8. **Use This Widget** switches
   **Run updates in** to **In this widget**. **Keep the Terminal Window** keeps your setting and
   hides the message for good. See
   [configuration.md](configuration.md#upgrading-from-an-older-kempt).
9. **"Discover, Plasma's software center, also shows update notifications. Its count can differ
   from Kempt's, and its checks can make an update wait."** It shows once, while Discover's notifier
   is installed and starts with your session. It waits until message 8 is answered. **Turn Off
   Discover's Notifier** turns it off for you. **Keep Discover's Notifier** changes nothing. Either
   answer hides the message for good, after a restart too. Settings can turn the notifier back on.
10. **"~1.5 GB can be freed. No installed app uses these Flatpak runtimes."** It shows when there
    is at least 100 MB to free, or an amount Kempt could not measure. **Show What** lists the
    runtimes, and **Free Up Space** removes them. It removes only the list you saw. If the list
    changed, nothing is removed and the popup says so. It never asks for a password. When removing
    needs an administrator, the popup says so and nothing is removed. When
    **Unused Flatpak runtimes** is **Remove after updates**, the message adds *"Kempt removes them
    after the next update."* and the button reads **Free Up Space Now**. Closing the message hides
    it until the list changes or Plasma restarts.

**Check Installation** checks Kempt's own files and settings. It never asks for a password. A
message under the one you pressed says *"Checking Kempt's installation…"*, then quotes the first
problem it found, or says it found none. **Show Full Report** shows the whole report, which you
can select and copy. **Copy Command** copies `kempt doctor`, the command that makes the report.
This message shows even when two others are up. It goes when you close it, close the popup, or a
check or an update starts. You can close it before the check finishes.

A failed check shows in the footer as `last check failed`, with the reason in the
**Check for Updates** tooltip. A failed hold shows in the row you pressed.

### The staged banner

**Install on Next Restart** stages an update: it downloads it now and installs it during the next
restart. Usually the banner is green and says what the next restart will do. It has its own
**Restart…** button when the restart message is not showing one:

```
 (=) 61 updates are staged - they install on the next restart   [Restart…]
```

If you hold a package that is already in the staged update, the banner turns into a warning. That
update was stored before the hold, and there is no way to edit a stored one. So the restart would
still install the package:

```
 (!) You held kernel-core after the next-restart install was prepared, so it
     still installs. Rebuild it to skip kernel-core, or stop holding kernel-core
     to keep the current plan. Rebuilding asks for authorization; if it fails,
     nothing stays staged.                          [Rebuild Staged Update]
```

With several held packages it names the first and counts the rest:
`You held kernel-core and 2 more after the next-restart install was prepared, so they still
install. Rebuild it to skip them, or stop holding them to keep the current plan.`

When Kempt cannot read what the staged update contains and you hold dnf packages, the banner says
`may`:

```
 (!) You added holds after the next-restart install was prepared, so it may
     still install held packages. Rebuild it to apply your holds. Rebuilding
     asks for authorization; if it fails, nothing stays staged.
                                                    [Rebuild Staged Update]
```

The warning has no **Restart…** button, and neither does the restart message while it shows,
because a restart would install the package you held. With nothing held, the banner stays green.
Flatpak holds never cause a warning, because only system packages are staged.

**Rebuild Staged Update** builds the staged update again with your current holds. Its tooltip:

> Builds the staged update again with your current holds. Asks for authorization; if the rebuild
> fails, the current staged update is removed.

dnf5 deletes the old staged update before it builds the new one. So a failed rebuild
removes the current staged update, and the restart installs nothing. A rebuild reuses the packages
already downloaded. If the staged update changed after the banner was drawn, nothing runs and the
popup says `The staged update changed since this was offered. Nothing was rebuilt; check the
banner above.`

**Discard Staged Update** is on every staged banner. It removes the staged update, so the next
restart installs nothing and the banner goes. Its tooltip:

> Removes the update waiting for the next restart, so the restart installs nothing. Asks for
> authorization, and deletes the packages it downloaded, so staging again downloads them again.

The popup reports the result in the same words as the command behind it. If the staged update
changed after the banner was drawn, nothing is discarded and the popup says so. While a Fedora
release upgrade is stored, the button is not there.

### The list

Updates are grouped under **System (dnf)**, **Apps (flatpak)**, **Flatpak runtimes** and **Held**.
Each row shows the package and its old and new versions. Long version lines wrap and long names are
shortened. A package the update would add shows `new → 1.0-1.fc44`. An app installed for you alone
is marked **For you only**.

Runtimes are listed because Flatpak updates them along with the apps. A runtime row shows its
branch, and has no version line when Flatpak publishes none. It has no padlock, because apps share
runtimes and a runtime cannot be held.

**The padlock** at the end of a row holds the package, or stops holding it. The icon shows the
current state:

- **🔓 open**: the package will be updated. The button reads *Hold nodejs at
  2:24.19.0-1nodesource* and *Kempt skips it on every update until you stop holding it.*
- **🔒 closed**: the package is held. The button reads *Stop holding nodejs* and *Kempt offers its
  update again.*

For a package the update would add, the padlock reads *Skip installing brandnew*. A held row says
**Held** before its version. Under the **Held** heading: *Held packages are skipped by Kempt only.*
A `sudo dnf upgrade` in a terminal ignores Kempt's holds.

When you press a padlock, it turns into a spinner and the other padlocks wait. The row moves to its
new group after the next check, and keyboard focus follows it. A screen reader hears *Holding
nodejs* or *No longer holding nodejs*. If the hold fails, the reason appears in that row until your
next press or the next check.

**Last update 18 min ago · 4 packages** shows what the previous run installed. Expand it for the
package list and **Show Log**. When a failed run's reason says to run `kempt doctor`, it also has
**Check Installation**. It takes at most a third of the popup and scrolls within that.

### Footer

`Checked 4 min ago` counts up while the popup is open. Hover it for the full time. Before any check
succeeds it reads `No successful check yet`. It can add:

- ` · last check failed`, with the reason in the **Check for Updates** tooltip.
- ` · apps for you only not checked`, when the apps installed for you alone could not be listed.
- ` · metadata 2 days old`, after 24 hours, or sooner when **Check for Updates** could not fetch.
- ` · 1 held`
- ` · ~140 MB`, the estimated download, when known and there is something to update.
- ` · restart pending`, when a restart is owed and its message is not showing.

The size is an estimate. It leaves out new dependencies and overstates Flatpak, which downloads
only the changes. Below a megabyte it reads `< 1 MB`. Held items are not counted.

**Update Now** installs the updates wherever **Run updates in** says. After a press it shows a
spinner until Kempt answers, so one press starts one run. It is hidden when there is nothing to
update, and while an update is staged. When the update includes a kernel, systemd or other desktop
packages, and runs outside a terminal, it asks first, with **Install on Next Restart** or
**Install Now** (message 7 above). In a terminal, the terminal asks instead.

### While an update runs

The popup shows where the update is running:

- `Updating in a terminal window…`
- `Updating in the background…`
- `Updating…`, with the live log below, for **In this widget**
- `Preparing the install for the next restart…`, when staging.

With confirmation on, runs always use a terminal, and **Install on Next Restart** always stages, so
this can differ from your settings.

You can close the popup while an update runs. If a run cannot start, the popup shows Kempt's
message and its fix. If the popup keeps saying it is updating after the run has ended, press
**Not updating? Check again**.

The updating state ends when the run writes its new state. A terminal run always does this as the
window closes. If a run dies without writing it, the widget gives up after three hours and checks
again.

### When the popup checks

**Opening the popup checks** when the last successful check is older than five minutes, or than
your check interval if that is shorter. If no check has ever succeeded, it checks on every open.
The counts on screen stay until the answer arrives.

If a check is already running, the popup's request is *remembered* and one more check runs when it
finishes. Opening the popup many times still adds only one.

The widget also watches the package databases, its state file and the config file every 30
seconds. A `dnf upgrade` in a terminal, a Discover run or another Kempt run shows up without you
asking. For a minute after a check, the widget ignores changes that check itself made.

### When nothing is pending

```
 Up to date                                          [refresh] [gear]
 --------------------------------------------------------------------
 (!) Restart to apply installed updates          [Restart…]      [x]   <- still shown: you can
                                                                          owe a restart with
                (icon)                                                    nothing pending
        Everything is up to date

 Last update 18 min ago · 4 packages                            [v]
 --------------------------------------------------------------------
 Checked 4 min ago                                                     <- no Update Now at all
```

If every pending update is held, the **Held** group shows in place of `Everything is up to date`.
When a check could not run Kempt at all, the list says so in the same place, with
**Check Installation** under it.

### About the restart

**Restart…** opens KDE's restart prompt, which lets your apps save and which you can cancel. Kempt
never restarts the machine itself. If the prompt cannot open, the message says why.

The updates are already installed, whether or not you restart. Programs that were running, and the
kernel, keep using the old versions until they restart. A staged update is the other way round: it
installs during the restart.

The **x** hides the message until you next log in to Plasma. To turn it off for good, see
**Restart reminders** below.

## Settings

Right-click the widget > **Configure Kempt…**, or press the gear in the popup. Every setting is
also in [configuration.md](configuration.md), and a change made in a terminal shows up here too.

- **Apply and OK.** Both save. **Apply** keeps the dialog open, **OK** closes it. Closing with
  unsaved changes asks first.
- **Changes reach the panel within 30 seconds**, because the widget checks the config file every
  30 seconds.

**Run updates in** is greyed out when *"Apply updates without asking for confirmation"* is off,
because only a terminal window can ask. Your choice comes back when you turn that option on
again.

**Restart reminders** (`restart_reminder`) controls the restart message and its **Restart…** button.
It is on by default. With it off, the footer still says `restart pending`. Kempt never restarts on
its own either way.

**Unused Flatpak runtimes** (`reclaim`) is **Ask me first** (the default), **Remove after updates**
or **Never**. It is greyed out when Flatpak is not installed or Flatpak apps are left out of
updates.

**Password prompts** has **Allow without password…** and **Require a password…**. Each opens its
own password dialog and shows the result under the buttons. The page cannot show which is active,
because only root can read the polkit rules. What the first one allows is in
[security.md](security.md#passwordless-mode).

**Discover** shows only when Discover's update notifier is installed. It says whether the notifier
is on, with **Turn Off Discover's Notifier**, or turned off by Kempt, with **Turn On Discover's
Notifier**. The button acts at once, without **Apply**. When a startup file of your own keeps the
notifier off, the row names that file and says to delete it, and has no button.

**Held** lists your holds, each with a button to stop holding it.

## What each button runs

Each button runs a Kempt command, so the widget and a terminal always agree. The commands are in
[usage.md](usage.md).

| Button | Command |
| --- | --- |
| **Check for Updates** | `kempt check --refresh` |
| **Update Now** | `kempt run` |
| **Install Now** | `kempt run --risky-ok` |
| **Install on Next Restart**, **Rebuild Staged Update** | `kempt run --surface=offline` |
| **Discard Staged Update** | `kempt unstage` |
| The padlock | `kempt hold` or `kempt unhold` |
| **Check Installation** | `kempt doctor` |
| **Free Up Space** | `kempt reclaim -y --expect=<digest>` |
| **Turn Off Discover's Notifier**, **Turn On Discover's Notifier**, **Keep Discover's Notifier** | `kempt discover-notifier off`, `on`, `keep` |
| **Allow without password…**, **Require a password…** | `kempt enable-passwordless`, `kempt disable-passwordless` |
| Every setting | `kempt config set` |

The badge and the popup's own checks run `kempt check --coalesce`.
