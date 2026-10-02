# Using the Kempt widget

The Kempt widget sits in your panel, counts the updates waiting for you and installs them when you
press **Update Now**. This page covers everything it shows and every button. You never need a
terminal to use it.

## Where it lives: the system tray, or the panel itself

**In the system tray** (the default). Kempt appears beside the volume and network icons. The first
time, it may need a plasmashell restart or a new login. To hide it or move it behind the arrow:

> Right-click the tray > **Configure System Tray...** > **Entries** > find **Kempt**.

**On the panel.** Use this to place it somewhere specific, or make it larger:

> Right-click the panel > **Add Widgets...** > search for **Kempt** > drag it onto the panel.

Using both gives you two Kempt icons, so you probably want to turn one off.

## What the panel icon means

| Icon | State | What it tells you |
|---|---|---|
| Update icon with a count badge | Updates pending | What an update would change now, held packages left out. The tooltip names the first three, session-critical ones such as the kernel first. |
| Plain update icon, no badge | Up to date | Nothing to do. The tooltip still counts held packages. |
| Same as before, badge kept | Last check failed | The counts are from the last check that worked. The tooltip gives the reason and that check's time. |
| Warning emblem | Error | Kempt could not run, or could not read its state. The tooltip names the problem and points at `kempt doctor`. |
| Spinner | Updating | A run started from the widget is in progress. |
| Dimmed, no badge | No data yet | The first check has not answered. If another check was running, as is common right after login, it asks again a few times, about ten seconds apart. |

The badge counts up to `999`, then shows `999+`. On a panel thinner than 22 px, or with **Small**
chosen, there is no badge, but the icon still changes and the tooltip has the count.

**Panel icon size**, under **Configure Kempt…**, offers **Automatic** (the default), **Small**,
**Medium** and **Large**. The sizes are under `widget_icon_size` in
[configuration.md](configuration.md#keys).

## The popup

Click the icon. Here, updates are pending, a restart is owed and the update has a kernel:

```
 3 updates available                                 [refresh] [gear]   <- header
 --------------------------------------------------------------------
 (!) Restart to apply installed updates          [Restart…]      [x]   <- messages
 (i) This update includes a kernel. The safest way is to
     install it on the next restart, so nothing changes
     under the running desktop.
                                        [Install on Next Restart]

 System (dnf)                                                          <- the list
   nodejs                                                     [🔓]
   2:24.19.0-1nodesource → 2:24.20.0-1nodesource
 Apps (flatpak)
   org.mozilla.firefox                                        [🔓]
   140 → 141
 Held
 Held packages are skipped by Kempt only.
   kernel-core                                                [🔒]
   Held  6.15.1 → 6.15.3

 Last update 18 min ago · 4 packages                            [v]
 --------------------------------------------------------------------
 Checked 4 min ago · 1 held · ~140 MB              [ Update Now ]      <- footer
```

### Header

The header reads one of:

- `3 updates available`. The count has no cap.
- `Up to date`, `Up to date · 2 held` when every pending update is held, or
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
- `Could not read the update state`, usually because the widget is older than the program.

**Check for Updates**, the circular arrow, fetches fresh package lists, which can take a minute or
more, then checks. On battery or a metered connection it checks without fetching. After a failed
check, the footer adds `last check failed` and this button's tooltip gives the reason, such as
`dnf check failed: repo 'updates' unavailable`. While a check or update runs, it is greyed out with
a spinner. It is also in the icon's right-click menu and the tray's **More actions** menu.

The **gear** opens **Configure Kempt…**, the same as the right-click menu. Inside the system tray,
the tray's own heading has the arrow and the gear, so the popup hides its copies.

### Messages

Messages appear only when they apply, and **at most two show at once**, the ones lower in this list
left out. If that hides the restart message, the footer says `restart pending` instead.

1. **The engine is missing or will not run.** *"Nothing can check for updates yet."*, with the
   install commands and **Copy Commands**. Or *"Kempt's engine is installed but will not run, so
   nothing can check for updates."*, with **Check Installation** and **Copy Command**. Either one
   shows alone. See [install.md](install.md#installing-from-the-kde-store-first).
2. **What just happened:** `Updated 4 packages in 2s`, `No package changes`, or
   `Update failed: <the reason>`, or what Kempt said about a button press that failed.
   **Show Log** is on it when a *run* recorded a log file, as every run does, including installs
   during a restart, unless the log could not be saved. When the message tells you to run
   `kempt doctor`, it adds **Check Installation**. It goes when you close the popup or the next
   check starts.
3. **This system updates with rpm-ostree**, on an image-based Fedora such as Kinoite. It points at
   Discover or `rpm-ostree upgrade` (`bootc upgrade` on a bootc image). **Update Now** is hidden.
4. **A Fedora release upgrade is stored.** It says which state the upgrade is in. If it is
   staged, restart to install it. If it is downloaded but not started, or a restart skipped it,
   run `sudo dnf5 system-upgrade reboot` to install it, or `sudo dnf5 offline clean` to drop it.
   If it did not finish, the message says to run `sudo dnf5 offline log` to see why. While it is
   stored, Kempt will not stage updates, and **Update Now** still updates live.
5. **What the next restart will install**, when an update is staged. See
   [The staged banner](#the-staged-banner).
6. **Restart to apply installed updates**, with **Restart…** and a close button. See
   [About the restart](#about-the-restart).
7. **"This update includes a kernel. The safest way is to install it on the next restart, so
   nothing changes under the running desktop."** Another version also names the NVIDIA driver.
   Without a kernel, it names the desktop packages in the update: `This update touches 20 packages
   the running desktop depends on (dbus, glibc, kf6, mesa, ...). The safest way is to install them
   on the next restart.` Its button is **Install on Next Restart**. It is hidden while an update is
   staged. When you press **Update Now** and updates run outside a terminal, it asks first: it
   moves to the top, adds **Install Now**, and gives **Install on Next Restart** the keyboard focus.
   In a terminal, the terminal asks instead.
8. **"Updates can now run in this widget instead of a terminal window."** It shows once, on an
   install that kept the terminal when it upgraded to 0.1.8. **Use This Widget** switches
   **Run updates in** to **In this widget**. **Keep the Terminal Window** keeps your setting. Either
   hides the message for good ([more](configuration.md#upgrading-from-an-older-kempt)).
9. **"Discover, Plasma's software center, also shows update notifications. Its count can differ
   from Kempt's, and its checks can make an update wait."** It shows once, after message 8 is
   answered, while Discover's notifier starts with your session. **Turn Off Discover's Notifier**
   turns it off for you. **Keep Discover's Notifier** changes nothing. Either answer hides the
   message for good. Settings can turn the notifier back on.
10. **"~1.5 GB can be freed. No installed app uses these Flatpak runtimes."** It shows when there
    is at least 100 MB to free, or an amount Kempt could not measure. **Show What** lists the
    runtimes, and **Free Up Space** removes them, without a password. It removes only the list you
    saw. If the list changed, or removing needs an administrator, nothing is removed and the popup
    says so. When **Unused Flatpak runtimes** is **Remove after updates**, the message adds
    *"Kempt removes them after the next update."* and the button reads **Free Up Space Now**.
    Closing the message hides it until the list changes or Plasma restarts.

**Check Installation** checks Kempt's own files and settings, without a password. A message under
the one you pressed says *"Checking Kempt's installation…"*, then quotes the first problem it
found, or says it found none. **Show Full Report** shows the whole report, which you can select and
copy. **Copy Command** copies `kempt doctor`, the command that makes it. This message shows even
when two others are up. It goes when you close it (even mid-check), close the popup, or a check or
an update starts.

### The staged banner

**Install on Next Restart** downloads an update now and installs it during the next restart. The
banner is usually green, and has its own **Restart…** when the restart message is not showing one:

```
 (=) 61 updates are staged - they install on the next restart   [Restart…]
```

If you hold a package that is already in the staged update, the banner turns into a warning,
because there is no way to edit a stored update and the restart would still install it:

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

While the warning shows, neither it nor the restart message has **Restart…**, because a restart
would install the package you held. Flatpak holds never cause a warning: only system packages are
staged.

**Rebuild Staged Update** has this tooltip:

> Builds the staged update again with your current holds. Asks for authorization; if the rebuild
> fails, the current staged update is removed.

dnf5 deletes the old staged update before building the new one, so a failed rebuild
removes the current staged update, and the restart installs nothing. A rebuild reuses the
packages already downloaded. If the staged update changed after the banner was drawn, nothing runs
and the popup says `The staged update changed since this was offered. Nothing was rebuilt; check the
banner above.`

**Discard Staged Update** is on every staged banner, with this tooltip:

> Removes the update waiting for the next restart, so the restart installs nothing. Asks for
> authorization, and deletes the packages it downloaded, so staging again downloads them again.

The popup reports the result in the command's own words. If the staged update changed after the
banner was drawn, nothing is discarded and the popup says so. While a Fedora release upgrade is
stored, the button is not there.

### The list

Updates are grouped under **System (dnf)**, **Apps (flatpak)**, **Flatpak runtimes** and **Held**.
Each row shows the package with its old and new versions. Long version lines wrap and long names are
shortened. A package the update would add shows `new → 1.0-1.fc44`. An app installed for you alone
is marked **For you only**.

Runtimes are listed because Flatpak updates them with the apps. A runtime row shows its branch, a
version line only when Flatpak publishes one, and no padlock, because runtimes cannot be held.

**The padlock** at the end of a row holds the package, or stops holding it:

- **🔓 open**: the package will be updated. The button reads *Hold nodejs at
  2:24.19.0-1nodesource* and *Kempt skips it on every update until you stop holding it.*
- **🔒 closed**: the package is held. The button reads *Stop holding nodejs* and *Kempt offers its
  update again.*

For a package the update would add, the padlock reads *Skip installing brandnew*. A held row says
**Held** before its version. The **Held** heading says *Held packages are skipped by Kempt only.*,
because a `sudo dnf upgrade` in a terminal ignores them.

A pressed padlock turns into a spinner and the others wait. The row moves to its new group after the
next check, and keyboard focus follows it. A screen reader hears *Holding
nodejs* or *No longer holding nodejs*. If the hold fails, the reason appears in that row until your
next press or the next check.

**Last update 18 min ago · 4 packages** expands to the previous run's package list and
**Show Log**, plus **Check Installation** when a failed run's reason says to run `kempt doctor`. It
takes at most a third of the popup and scrolls within that.

### Footer

`Checked 4 min ago` counts up while the popup is open. Hover it for the full time. Before any check
succeeds it reads `No successful check yet`. It can add:

- ` · last check failed`.
- ` · apps for you only not checked`, when the apps installed for you alone could not be listed.
- ` · metadata 2 days old`, after 24 hours, or sooner when **Check for Updates** could not fetch.
- ` · 1 held`
- ` · ~140 MB`, the estimated download, when known and there is something to update.
- ` · restart pending`, when a restart is owed and its message is not showing.

The size leaves out new dependencies and held items, and overstates Flatpak, which downloads only
the changes. Below a megabyte it reads `< 1 MB`.

**Update Now** installs the updates wherever **Run updates in** says. After a press it shows a
spinner until Kempt answers, so one press starts one run. It is hidden when there is nothing to
update, and while an update is staged. When the update includes a kernel or other desktop packages,
it asks first (message 7 above).

### While an update runs

The popup says where the update is running:

- `Updating in a terminal window…`
- `Updating in the background…`
- `Updating…`, with the live log below, for **In this widget**
- `Preparing the install for the next restart…`, when staging.

You can close the popup meanwhile. If a run cannot start, the popup shows Kempt's message and its
fix. The updating state ends when the run writes its new state, which a terminal run always does
as the window closes. If it still says it is updating after the run has ended, press
**Not updating? Check again**. If a run dies without writing its state, the widget gives up after
three hours and checks again.

### When the popup checks

**Opening the popup checks** when the last successful check is older than five minutes, or than
your check interval if that is shorter, and on every open until a check succeeds. The counts on
screen stay until the answer arrives. If a check is already running,
the popup's request is *remembered* and one more check runs when it finishes, however many times
you open it.

The widget also checks the package databases, its state file and the config file every 30
seconds. A `dnf upgrade` in a terminal, a Discover run, another Kempt run or a settings change
shows up without you asking. For a minute after a check, the widget ignores changes that check
made.

### When nothing is pending

The list says `Everything is up to date` and the footer has no **Update Now**. The restart message
can still show, because a restart can be owed with nothing pending. In place of
`Everything is up to date`, the **Held** group shows when every pending update is held,
and `Apps installed for you only could not be checked.` when those apps could not be listed. When a
check could not run Kempt at all, it says so there, with **Check Installation** under it.

### About the restart

**Restart…** opens KDE's restart prompt, which lets your apps save and which you can cancel. If
the prompt cannot open, the message says why.

The updates are already installed. Running programs, and the kernel, keep the old versions until
they restart. A staged update is the other way round: it installs during the restart.

The **x** hides the message until you next log in to Plasma. **Restart reminders** below turns it
off for good.

## Settings

Right-click the widget > **Configure Kempt…**, or press the gear in the popup. Every setting is
also in [configuration.md](configuration.md).

**Apply** and **OK** both save. **Apply** keeps the dialog open, **OK** closes it. Closing with
unsaved changes asks first. A change reaches the panel at the widget's next look at the config
file (see [When the popup checks](#when-the-popup-checks)).

**Run updates in** is greyed out when *"Apply updates without asking for confirmation"* is off,
because only a terminal window can ask. Runs then use a terminal, and **Install on Next Restart**
still stages. Your choice comes back when you turn that option on again.

**Restart reminders** (`restart_reminder`, on by default) controls the restart message and its
**Restart…** button. With it off, the footer still says `restart pending`. Kempt never restarts on
its own either way.

**Unused Flatpak runtimes** (`reclaim`) is **Ask me first** (the default), **Remove after updates**
or **Never**. It is greyed out when Flatpak is not installed or Flatpak apps are left out of
updates.

**Password prompts** has **Allow without password…** and **Require a password…**. Each asks for
your password and shows the result under the buttons. Which is active cannot be shown, because only
root can read the polkit rules. What the first one allows is in
[security.md](security.md#passwordless-mode).

**Discover** shows only when Discover's update notifier is installed. It says whether the notifier
is on, with **Turn Off Discover's Notifier**, or turned off by Kempt, with
**Turn On Discover's Notifier**, which acts at once, without **Apply**. When a startup file of your
own keeps it off, the row names that file, says to delete it, and has no button.

**Held** lists your holds, each with a button to stop holding it.

## What each button runs

Each button runs a command described in [usage.md](usage.md).

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
