# Using the Kempt widget

The Kempt widget sits in your system tray, counts the updates waiting for you and installs them
when you press **Update Now**. For everyday updates, you do not need a terminal.

## Where it lives: the system tray, or the panel itself

**In the system tray** (the default). Kempt appears beside the volume and network icons. The first
time, it may need a plasmashell restart or a new login. To hide it or move it behind the arrow:

> Right-click the tray > **Configure System Tray…** > **Entries** > find **Kempt**.

**On the panel.** Use this to place it somewhere specific, or make it larger:

> Right-click the panel > **Add Widgets…** > search for **Kempt** > drag it onto the panel.

Using both gives you two icons.

## What the panel icon means

| Icon | State | What it tells you |
|---|---|---|
| Update icon with a count badge | Updates pending | What an update would change now, held packages left out. The tooltip names the first three, session-critical ones such as the kernel first. |
| Plain update icon, no badge | Up to date | Nothing to do. The tooltip still counts held packages. |
| Same as before, badge kept | Last check failed | The counts are from the last check that worked. The tooltip gives the reason and that check's time. |
| Warning emblem | Error | Kempt could not run, or could not read its state. The tooltip names the problem. The widget offers **Check Installation**, unless the update servers could not be reached or the package lists are missing. |
| Spinner | Updating | A run started from the widget is in progress. |
| Dimmed, no badge | No data yet | The first check has not answered. If another check was running, as is common right after login, it asks again a few times, about ten seconds apart. |

The badge counts up to `999`, then shows `999+`. On a panel thinner than 22 px there is no badge, but the icon still changes and the tooltip has the count.

The icon sizes itself to match the system tray: 22 px on panels from 22 to 47 px thick, and 48 or
64 px on a thick or HiDPI panel.

## Inside the widget

Click the icon. Here, two updates are pending, a restart is owed and you hold `kernel-core`, so the
update leaves the kernel out:

```
 2 updates                                           [refresh] [gear]   <- header
 --------------------------------------------------------------------
 (!) Restart to finish updating.          [Restart…]      [x]   <- messages

 System                                                                <- the list
   nodejs                                                     [🔓]
   2:24.19.0-1nodesource → 2:24.20.0-1nodesource
 Apps
   org.mozilla.firefox                                        [🔓]
   140 → 141
 Held
 Kempt skips these. Other updaters still see them.
   kernel-core                                                [🔒]
   Held  6.15.1 → 6.15.3

 Last update 18 min ago · 4 packages                            [v]
 --------------------------------------------------------------------
 Checked 4 min ago · 1 held · ~140 MB              [ Update Now ]      <- footer
```

### Header

The header reads one of:

- `3 updates`. The count has no cap. A risky set adds what it holds: `3 updates, including a new kernel`.
- `Last check failed` when a check failed and nothing is waiting.
- `Up to date`, `Up to date · 2 held` when every pending update is held, or
  `Up to date · apps for you only not checked` when the apps installed for you alone could not be
  listed.
- `23 updates ready for the next restart`, while updates are ready.
- `Updating…`
- `No update data yet`, before the first check answers.
- `Kempt's engine is not installed`, when the widget is installed without the command-line program
  (see [install.md](install.md#installing-from-the-kde-store-first)).
- `Kempt's engine will not run`, when the program is there and cannot start.
- `Kempt cannot check for updates`, when running the program failed or no check has ever
  succeeded. Below it are a headline and the raw error. The headline is `Kempt
  could not reach the update servers`, `The package lists have not been downloaded yet` or `The
  check failed`. Only the last offers **Check Installation**.
- `Could not read the update state`, usually because the widget is older than the program.

**Check for Updates**, the circular arrow, downloads fresh update info, then checks. On battery or
a metered connection it checks without fetching. After a failed check, a message says so
(message 2), the footer adds `last check failed` unless the header already says it, and this
button's tooltip says which half failed, such as `The check failed for System.` While a check or update runs, it is greyed out
with a spinner. A screen reader reads its answer, and the panel icon says it when the widget is
closed. It is also in the right-click and **More actions** menus.

The **gear** opens **Configure Kempt…**, the same as the right-click menu. Inside the system tray,
the tray's own heading has a gear and a **More actions** menu, so the widget hides its gear.

**Install on Next Restart** is in the right-click and **More actions** menus too, when system
updates are waiting, none are ready and the main button says **Update Now**. Another updater's
restart, a stored Fedora upgrade or an image-based system removes it.

### Messages

Messages appear only when they apply. **At most two show at once**, and the ones lower in this
list wait. If that hides the restart message, the footer says `restart pending` instead.

1. **The engine is missing or will not run.** *"Nothing can check for updates yet."*, with the
   install commands and **Copy Commands**. Or, under **Kempt's engine will not run**, *"The engine
   is installed but cannot start, so nothing can check for updates."*, with **Check Installation**
   and **Copy Command**. Either one shows alone. See
   [install.md](install.md#installing-from-the-kde-store-first).
2. **What just happened:** `Updated 4 packages in 2 s.`, `No packages changed.`,
   `The update failed: <the reason>.`, or why a button press failed. After an answer to message 8,
   it says what changed. After a failed **Check for Updates**, it says the counts are from the last
   check that worked. If the press got no fresh update info, it says why, until the next check. On
   battery or a metered connection it offers **Check Anyway**, which checks online once, now. If
   another check held the lock until the press gave up, it says `Another check was running. Press
   Check Anyway again.`

   **Show Log** opens the log of a run that failed. **Check Installation** appears when the
   message says to run `kempt doctor`. A run's summary goes when you close the widget or a check
   starts. A report that something worked also goes when a check starts. The note about a failed
   check goes when fresh counts arrive, or when you ask for a check. Other reports stay until your
   next press.
3. **Why Kempt cannot go ahead**, one cause at a time. On an image-based Fedora such as Kinoite, it
   says to use Discover, and **Update Now** is hidden. With a system folder other users can change,
   updates are paused. With a Fedora release upgrade stored, **Install on Next Restart** is off.
   With both, one sentence says the next restart installs the upgrade and updates are paused. The
   last two have **Check Installation**, which names the folder or gives the upgrade's commands.
4. **What the next restart will install**, when updates are ready. See
   [When updates are ready](#when-updates-are-ready).
5. **A service did not start after the update.** *"Bluetooth failed to start after the
   update."* Several services share one message with a count. **Startup Report** opens the report,
   where each has **Copy Command** and **Mute Until It Starts**, and services that were already
   failing are listed under them. When one runs again, a line says so once, ranked under the
   restart message. The panel count and icon never include this.
6. **Restart to finish updating.**, with **Restart…** and a close button. See
   [About the restart](#about-the-restart).
7. **"The next restart is the safest time to install a new kernel."** Another version also names
   the NVIDIA driver. Without a kernel, it names the parts of your desktop that would change: `The
   next restart is the safest time to change parts your desktop is using (the system message bus,
   the core system library).` Its button is **Install on Next Restart**. It is hidden while updates
   are ready. When you press **Update Now**, it asks first. The message moves to the top (below a
   Check Installation result) and adds **Install Now**. **Install on Next Restart** gets the
   keyboard focus, and a screen reader hears *"Nothing is installed yet."* first. While a Fedora
   release upgrade is stored, it does not ask, and **Update Now** updates live. While updates are
   paused, it does not ask either, because the run would be refused.
8. **"Discover also checks for updates, and that can cancel updates waiting for your next
   restart."** It shows while Discover's notifier starts with your session.
   **Turn Off Discover's Update Checks** turns it off for you. Closing the message changes nothing.
   Either answer hides the message for good. When Discover is set to install updates by itself, the
   same message says so as a warning, one time, right under what is waiting for the restart. An
   image-based Fedora, which is told to use Discover, gets neither. The **Discover** row in settings
   turns the checks back on.
9. **"~1.5 GB can be freed. No installed app uses these Flatpak runtimes."** It shows when there
   is at least 1 GB to free. **Show Runtimes** lists the runtimes, and **Free Up Space** removes
   them, without a password. It removes only the list you saw. If the list changed, or removing
   needs an administrator, nothing is removed and the widget says so. Closing it hides it until the
   list changes or Plasma restarts.

**Check Installation** checks Kempt's own files and settings without a password. A message under
the one you pressed says *"Checking Kempt's installation…"*, then quotes the first problem it found,
or says it found none. Under a stored Fedora upgrade, it quotes the upgrade's line instead, with
how to finish or remove it. **Show Full Report** shows the whole report, which you can select and copy.
**Copy Command** copies `kempt doctor`, the command that makes it. This message shows even when two
others are up. It goes when you close it, close the widget, ask for a check, or start an update.

### When updates are ready

**Install on Next Restart** downloads system updates now and installs them during the next
restart. Apps update now. The message is usually green, with its own **Restart…** when the
restart message has none:

```
 5 updates ready for the next restart                     <- header
 (=) They install the next time you restart.             [Restart…]
```

Updates that come out after that, and apps waiting to update, are not in it. The message then
adds `2 other updates wait until after that.`

A dnf command of your own, such as `sudo dnf install`, cancels updates that are ready. Within about a
minute the message goes. Kempt tells you once, at the first check that can show a notification, so
someone away from their desktop hears it when they are back. **Install on Next Restart** prepares them again.

If you hold a package that is already in those updates, the message turns into a warning,
because there is no way to edit them and the restart would still install it:

```
 (!) You held kernel-core after these updates were prepared, so it still
     installs. Discard them and install again to skip it.
                                                    [Discard Updates]
```

With several held packages it names the first and counts the rest:

```
 (!) You held kernel-core and 2 more after these updates were prepared, so
     they still install. Discard them and install again to skip them.
```

When Kempt cannot read what those updates contain and you hold system packages, the message says
`may`:

```
 (!) You added holds after these updates were prepared, so held packages may
     still install. Discard them and install again to apply your holds.
                                                    [Discard Updates]
```

While the warning shows, neither it nor the restart message has **Restart…**, because a restart
would install the package you held. App holds never cause a warning: only system packages wait for the
restart.

In a terminal, `kempt update --surface=offline` replaces those updates with your current holds and
reuses the download.

**Discard Updates** has this tooltip:

> Removes the updates waiting for the next restart, so the restart installs nothing. May ask for
> your password. It deletes the packages it downloaded, so installing again downloads them again.

If the updates changed after the message was drawn, nothing is discarded and the widget says so. While a Fedora release upgrade is stored, the button is not there.

If another updater has prepared the next restart, the message warns and offers **Restart…**:

```
 (!) Another updater has prepared your next restart, so these updates will not
     install then. Try again after that restart.
```

With nothing of Kempt's waiting, the message says `Another updater has prepared your next restart,
so restart when you are ready.` and **Install on Next Restart** is gone until you have restarted. **Update Now** runs live, even
when Kempt is set to install on the next restart. With system updates waiting it asks first:

> Updating now may stop another updater's prepared update from installing.

Flatpak apps alone do not ask. Nor does Update Now while updates are paused, because the run would
be refused.

If Discover is set to install updates by itself, a warning says it can take over your next restart
and stop Kempt's updates, with **Turn Off**. It shows once, whatever Kempt's mode, and comes back only
after the setting was turned off and on again, or after `kempt discover-notifier on`.

### The list

Updates are grouped under **System**, **Apps**, **Flatpak runtimes** and **Held**.
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
**Held** before its version. The **Held** heading says *Kempt skips these. Other updaters still see them.*,
because a `sudo dnf upgrade` in a terminal ignores holds.

A pressed padlock turns into a spinner and the others wait. The row moves to its new group after the
next check, and keyboard focus follows it. A screen reader hears *Holding
nodejs* or *No longer holding nodejs*. If the hold fails, the reason appears in that row until your
next press or the next check.

**Last update 18 min ago · 4 packages** expands to the previous run's package list. After a failure
its title says `Last update failed`, with the reason under it, and it offers **Show Log**, plus
**Check Installation** when the reason says to run `kempt doctor`. It takes at most a third of the widget and scrolls.

### Footer

`Checked 4 min ago` counts up while the widget is open. Hover it for the full time. Before any check
succeeds it reads `No successful check yet`. It can add:

- ` · last check failed`.
- ` · apps for you only not checked`, when the apps installed for you alone could not be listed.
- ` · update info 2 days old`, after 24 hours, or sooner when the message about a missed fetch is
  not showing.
- ` · 1 held`
- ` · ~140 MB`, the estimated download, when known, something is pending, and no updates are ready.
- ` · restart pending`, when a restart is owed and its message is not showing.

The size leaves out new dependencies and held items, and overstates Flatpak, which downloads only
the changes. Below a megabyte it reads `< 1 MB`.

**Update Now** runs updates wherever **Run updates in** says. With **On the next
restart** and system updates pending, it reads **Install on Next Restart**. A press shows a
spinner until Kempt answers. It hides when nothing is pending, updates are ready, or its question
is open. Kernel or desktop updates make it ask first (message 7), unless a release upgrade is
stored.

### While an update runs

The widget says what is happening:

- `Updating…`, with the live log below, for **In this widget**
- `Preparing updates for the next restart…`, while it does that.

You can close the widget meanwhile. If a run cannot start, the widget shows Kempt's message and fix. If it still says it is updating after the run has ended, press **Not Updating? Check Again**.
After three hours without word from a run, the widget checks again. The run may still be going.

### When the widget checks

**Opening the widget checks** when the last successful check is older than five minutes or your
check interval, whichever is shorter, and on every open until a check succeeds. The counts on
screen stay until the answer arrives. If a check is already running, one more runs when it
finishes, however often you open the widget.

Every 30 seconds (every 2 during an update) the widget also checks the package databases, the
updates that are ready, its state file and the config file. A `dnf upgrade` or `sudo dnf5 offline clean` in
a terminal, a Discover run, another Kempt run or a settings change shows up without you asking. For
a minute after a check, the widget ignores changes that check made. A change to the packages or the
waiting updates in that minute is checked when the minute is up.

### When nothing is pending

The list says `Everything is up to date` and the footer has no **Update Now**. The restart message
can still show, because a restart can be owed with nothing pending. In place of
`Everything is up to date`, the **Held** group shows when every pending update is held,
and `Apps installed for you only could not be checked.` when those apps could not be listed. When a
check could not run Kempt at all, it says so there, with **Check Installation** under it. When the
package lists were never downloaded because of battery or a metered connection, the hint says to
plug in or switch connections, and **Check Anyway** sits under the hint.

### About the restart

**Restart…** opens KDE's restart prompt, which lets your apps save and can be cancelled. If it
cannot open, the message says why.

The updates are already installed. Running programs and the kernel keep the old versions until
they restart. Updates that are ready are the other way round: they install during the restart.

The **x** hides the message until your next Plasma login.

### The Startup report

The Startup report opens from the message about a failed service, from **Startup Report** in the
widget's right-click menu, or from **More actions** inside the system tray. It reads when it opens
and when you press its arrow, never in the background, and changes nothing on the computer.

Services that failed after an update come first, each with **Copy Command** and **Mute Until It
Starts**. Below them is the text of `kempt startup --all`, in English, in an area you can read and
select from the keyboard: what failed this boot, what changed since the last update, what starts
with the computer and what runs on a schedule. Doctor's full report uses the same area. **Back** or Escape returns to the updates, or to a running update.

## Settings

Right-click the widget > **Configure Kempt…**, or press its gear. Every setting is
also in [configuration.md](configuration.md).

**Apply** saves and keeps the dialog open, **OK** saves and closes it. Closing with
unsaved changes asks first. A change reaches the panel at the widget's next look at the config
file (see [When the widget checks](#when-the-widget-checks)).

**Include Flatpak apps** (`include_flatpak`, on by default) checks and updates Flatpak apps and
runtimes. Without Flatpak, it is greyed out.

**Run updates in** (`surface`) is **In this widget** (the default) or **On the next restart**.

**Check every** (`refresh_interval_min`, 60 minutes by default) sets how often the widget checks.
The lowest value it offers is 15 minutes.

**Unused Flatpak runtimes** (`reclaim`) is **Ask me first** (the default) or **Never**. It is greyed
out without Flatpak, or when Flatpak apps are left out of updates.

**Password prompts** has **Allow without password…** and **Require a password…**. Each asks for
your password and shows the result under the buttons. Which is active cannot be shown: only
root can read the polkit rules. What the first one allows is in
[security.md](security.md#passwordless-mode).

**Discover** shows only when Discover's update notifier is installed. It says whether the notifier
is on, with **Turn Off Discover's Update Checks**, or turned off by Kempt, with
**Turn On Discover's Update Checks**, which acts at once, without **Apply**. When a startup file of your
own keeps it off, the row names that file, says to delete it, and has no button.

**Services** (`notify_startup`, on by default) shows the message about services that did not start
after an update. Kempt only looks: it never turns a service on or off.

**Held** lists your holds, each with a button to stop holding it. **Muted** lists muted services,
each with **Stop Muting**, and **Undo** right after.

## What each button runs

Each button runs a command described in [usage.md](usage.md).

| Button | Command |
| --- | --- |
| **Check for Updates** | `kempt check --refresh` |
| **Check Anyway** | `kempt check --anyway` |
| **Update Now** | `kempt run` |
| **Install Now** | `kempt run --risky-ok` |
| **Install on Next Restart** | `kempt run --surface=offline` |
| **Discard Updates** | `kempt unstage` |
| Drawing the warning about Discover's automatic updates | `kempt discover-notifier seen` |
| **Update Now**, while another updater holds the next restart | `kempt run --surface=<a live surface>`, after its own question when system updates are waiting |
| The padlock | `kempt hold` or `kempt unhold` |
| **Check Installation** | `kempt doctor` |
| **Free Up Space** | `kempt reclaim -y --expect=<digest>` |
| **Turn Off Discover's Update Checks**, **Turn On Discover's Update Checks**, closing the mild message | `kempt discover-notifier off`, `on`, `keep` |
| **Allow without password…**, **Require a password…** | `kempt enable-passwordless`, `kempt disable-passwordless` |
| **Copy Command** for a service, on the Startup report | Runs nothing. Copies `systemctl status <unit>`, with `--user` for a service in your session |
| **Mute Until It Starts**, **Stop Muting**, **Undo** | `kempt startup mute <unit>`, `kempt startup unmute <unit>`, `kempt startup mute <unit>` |
| Opening the widget while it says a service runs again | `kempt startup ack --expect=<digest>` |
| **Startup Report** in the menu and on the failed-service message, and the arrow on the Startup report | `kempt startup --all` |
| Every setting | `kempt config set` |

The widget's automatic checks run `kempt check --coalesce`.
