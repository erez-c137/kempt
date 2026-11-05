# Changelog

All notable changes to Kempt are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Kempt reads what will happen on a restart from the machine, and keeps no record of its own.** The toml, `/system-update`, `dnf5 history` and rpm answer everything, without root. This ends the reports that came from Kempt's record disagreeing with dnf5. When PackageKit cancels prepared updates, which Discover's notifier can do at any refresh, you are told once, and preparing them again downloads nothing. Deleting the state folder costs at most one repeat notification, and an armed stage stays on screen. A stored update in a format this build does not know reads as "cannot tell", never as ready.
- **A `wheel` user at the computer now updates with no password, and nobody can update over SSH.** Anyone else at the computer is asked for an administrator's password. This is one fixed rule in the package, with no setting. To be asked, take your account out of `wheel`.
- **The two programs that run as root went from 1,078 lines to 170.** dnf5 still runs as a service that the system starts, so nothing about your terminal, memory score or scheduling reaches it and a stuck or dead reader cannot stop it, but a watchdog no longer follows it. The service records how dnf5 ended and the helper reads that record, so a package step that restarts the message bus cannot give a false result. Output is live, the exit status is the real one, and it keeps going when the terminal closes or you log out. [security.md](docs/security.md) says what it resets.
- **`kempt update` at a terminal with `auto_accept=false` shows what dnf5 would do, then asks.** dnf5 no longer has the terminal, so Kempt asks the question itself: `Go ahead with this? [y/N]:`. Nothing starts before you answer. The list of updates prints a second time when you say yes.
- **Ctrl-C during an update says what really happens.** It stops the terminal watching, and the update carries on to the end. Pressing it does not stop dnf5, as in 0.2.0. Kempt records `stopped watching` and no result, so `dnf5 history list` shows how the update ended. A second `kempt update` while the first still runs says so and starts nothing.
- **Check Installation's full report can be read from the keyboard.** Tab reaches it, the arrow keys and Page Up and Down move a caret, and a screen reader gets its name.
- **A kernel, NVIDIA driver or desktop update now says so on the status line.** The message that used to sit in the widget before you pressed anything is gone. The status line reads "23 updates available, including a new kernel", and Update Now asks its question only when pressed. That question and the one about another updater's restart now share one message.
- **One message says why Kempt cannot go ahead:** an image-based Fedora, a system folder with unsafe permissions, or a stored Fedora release upgrade. It shows one cause at a time. The commands for a release upgrade moved to **Check Installation**, whose full report now gives them for every state.
- **One message about Discover**, in two sentences. When Discover is set to install updates by itself, it is a warning right under what is waiting for the restart. Otherwise it is a calm note low in the stack. It has one button, **Turn Off Discover's Update Checks**, and a close button that replaces **Keep Discover's Notifier**.
- **The note about a check that got no fresh lists moved into the report**, in shorter words. It goes at the next check and has no close button of its own. The footer always gives the lists' age.
- **A service that failed reads "Bluetooth failed to start after the update."** With several, the heading names two of them. The widget no longer says when a service is running again: the warning going away is the news, and the desktop notification still says so.
- **The widget says "ready", not "staged", and "System" and "Apps", not dnf and flatpak.** The message reads "5 updates are ready and install on the next restart." with **Discard Updates**, and the header says the same. What discarding costs is on the button's tooltip. `kempt status` shares the header and restart sentences. The command line keeps the rest of its wording.
- **Shorter sentences:** "Restart to finish updating.", "Updated 12 packages in 34 s.", "No packages changed." and "The update failed: the reason." **Not Updating? Check Again** replaces the longer button.
- **Show Log appears only after a run that failed**, on the report and on the Last update row.
- **An armed Fedora release upgrade stays on screen beside a folder problem.** The message says the next restart installs the upgrade and that other updates are paused for the folder.
- **Check Installation under an upgrade message says how to finish or remove the upgrade**, in the words of its report, instead of only finding no problems. The message now reads "A Fedora 45 upgrade installs on the next restart, so other updates cannot wait for that restart." or "A Fedora 45 upgrade waits for you to finish or remove it, so updates cannot wait for the next restart. Check Installation says how."
- **Update Now no longer asks about a risky update while updates are paused**, because no answer could start a run.
- **`kempt config set surface terminal` says what it stored**, one line, because that value now means the widget.
- **A cancelled update is announced at a check that can show the notification.** Someone with no desktop session at the check that found it hears at the next one, instead of never.
- **The warning about a hold behind prepared updates is shorter:** "You held firefox after these updates were prepared, so it still installs. Discard them and install again to skip it." The download cost of discarding is in the button's tooltip.
- **One message when services fail, and a Startup Report you can read from the keyboard.** The main view says "Bluetooth failed to start after the update." or "3 services failed to start after the update, including Bluetooth and plasma-foo.service." with one **Startup Report** button. The report lists each failed service with **Copy Command** and **Mute Until It Starts**, over the text of `kempt startup --all`.
- **Failures and notifications about updates waiting for the next restart say downloaded, prepared or ready**, not staged, and the widget draws them without "See: kempt doctor" beside its **Check Installation** button. `kempt summary` and other terminal text keep the word for now.
- Shorter widget sentences. The count goes in the header and the sentence under it says when: "They install the next time you restart." The header no longer says "available". The kernel recommendation reads "The next restart is the safest time to install a new kernel.", it names only parts with a plain name, and a failed check no longer says "just now" or repeats "last check failed" in the footer.
- One word for each thing in the widget. The other updater's stage is always "prepared", the footer says "update info 3 days old", the buttons are **Check Anyway** and **Discard Updates**, and tooltips no longer name dnf or flatpak. A failed check's tooltip says which half failed in the popup's words rather than quoting the tool's error.
- The widget page describes the messages as they now read, with the list numbered in order.

- **The widget's words can be translated.** Every sentence is whole in one `i18n()` call, with counts in `i18np`, so a translator can reorder it. `Messages.sh` writes the template in `po/`, and the package compiles any `po/<lang>.po` into the widget. No language is translated yet.
- **The settings picture says it is from 0.2.0.** It still shows settings that have since gone.
- **Free Up Space says how many runtimes went, not how much space.** The offer now says "Up to", because the measured size overstates what comes back on compressed btrfs, Fedora's default.

### Removed

- **`kempt log --raw` and the log's second set of words.** `events.log` now holds the sentences `kempt log` prints, so what you search is what you read. Lines from older versions print as stored. A script that searches the log for the old words, such as `run failed` or `check ok`, stops matching. A run's line drops where it ran, and the dnf history line drops the helper's exit code.
- **`kempt enable-passwordless`, `kempt disable-passwordless` and the widget's Password prompts row.** The fixed rule replaces them. Upgrading from before 0.3.0 removes the rule an earlier version generated in `/etc/polkit-1/rules.d`, once, and an account outside `wheel` that had turned it on is asked again. A file there that an earlier version did not generate stays, on that upgrade and every later one.
- **The root helpers' own checks of parent folders, ACL entries, FUSE mounts and the mount namespace, and their refusal on atomic Fedora.** The helpers keep a short check that the folders dnf5 installs from belong to root.
- **The same parent, ACL and FUSE checks in `kempt update`, `kempt check`, `kempt status` and `kempt doctor`.** Kempt now has one rule for dnf's folders, the root helper's, so it never refuses an update over something root allows. A writable folder above dnf's, an ACL entry or a FUSE mount another user made no longer stops an update, and doctor no longer reports them. Doctor's five dnf rows are now one, **dnf folders**, shown only when it fails, which keeps the fixes for what Kempt 0.1.7 and earlier left behind. A root-owned link in dnf's state or staged folder no longer counts. The package no longer needs `acl`, and now requires `findutils`. A discard root refused no longer blames the folders, since root's discard never checks them.
- **"dnf5 has been running for 15 minutes", and the plain sentence when a check meets another account's update.** A check that runs out behind another account's update now says the check failed. dnf5 waits for the running update, and the update is not harmed.
- **A message per failed service, and the Startup Report's folding lists.** The main view has one message however many services failed, so muting one starts from **Startup Report**. The report's **Show All** and **Hide**, its counts and its separate lists are gone, since the report now shows the CLI's text.
- **Startup time in the Startup Report and `kempt startup --all`.** `boot_time` is gone from `--json`, Kempt no longer runs `systemd-analyze`, and it no longer writes `boot-times.json`. An existing file there stays and nothing reads it, so you can delete it. `systemd-analyze` gives the same figures.
- **`install.sh`.** Kempt installs as a package. Developers use `tools/build-local.sh`, which builds the packages from a checkout. If you installed from a checkout, run `./install.sh --uninstall` from your current copy before you pull, then install the package. The `kempt doctor` rows that only applied to a checkout go too: `helpers:`, `policy:`, `widget:`, `install: packaged`, the commit line and `getfacl`, which the package requires.
- **Updating in a terminal window.** The `terminal` setting, the **Terminal window** choice in the widget's settings, the `KEMPT_TERMINAL` variable and `kempt run`'s exits 4 and 5 are gone. A saved `terminal` now reads as **In this widget**. To watch an update, type `kempt update` in a terminal: it always shows live output and asks before kernel, systemd or desktop updates.
- **Apply updates without asking for confirmation** in the widget's settings. Its only effect was to open a terminal window. `auto_accept=false` still makes `kempt update` at a terminal ask you first. A script with `auto_accept=false` and no terminal is refused with exit 5 and nothing changes. A press in the widget still runs.
- **Put It Back and `kempt restore-stage`.** When another program cancels a staged update, Kempt now
  tells you and the updates stay in the list. Stage them again with **Install on Next Restart** or
  `kempt update --surface=offline`. The packages are still downloaded, so this costs no new download.
- **Rebuild Staged Update.** To apply new holds to a staged update, press **Discard Staged Update**
  and stage again. That deletes the download, so staging again downloads the packages again. In a
  terminal, `kempt update --surface=offline` still replaces the stage and reuses the download.
- **The widget's offer to update inside it, and keeping `terminal` on upgrade.** An install from before 0.1.8 whose config file names no `surface` now updates in the widget, with no offer first. To keep a terminal window, run `kempt config set surface terminal`.
- **Recognizing the Discover startup file that `install.sh` wrote before 0.1.8.** `kempt discover-notifier on` now treats that file as your own and leaves it. To turn the notifier back on, delete it from `~/.config/autostart`.
- **The `background` surface and In the background.** A run in the widget does the same work, so saved settings now read as **In this widget**. Keep your updates out of sight by leaving the widget closed: a finished run still sends a desktop notification.
- **Some `kempt doctor` rows.** jq, dnf, apps for you only, unused Flatpak runtimes, shutdown protection during installs, the program files check, the overridden privileged paths check with its rows for a helper set by an environment variable, and the network mount warning are gone. A missing tool or a refused update still gives its own reason when you hit it, and `kempt reclaim` lists the runtimes.
- **`kempt run --dry-run`.** It was an older name. Use `kempt run --print-command`.
- **`kempt holds --exclude-args`.** To honour holds in a `sudo dnf5 upgrade` of your own, add `--exclude=<package>` for each one that `kempt holds` lists.
- **The `KEMPT_DNF_SYSTEM_CACHE` and `KEMPT_FLATPAK_USER_SKIP` settings.** Point `KEMPT_DNF_CACHE_DIR` at the cache instead. Skipping the apps for you only is decided inside a run.
- **Kempt's record of a stage**, its package snapshots and `stage.lock`. A check removes what 0.2.0 left. Reports that needed them go too: "N of your staged updates", a stage replaced outside Kempt, updates another updater installed reported as yours, and a restart's "did not run" history row. Old `harvest` and `offline marker` lines in `kempt log` stay as written until they age out.
- **Flatpak end-of-life notes after a run.** `kempt summary` and the history no longer name the app behind flatpak's notice. flatpak's own line stays in the run log.
- **Security notifications and `notify_security`.** Kempt no longer sends a notification or animates the panel icon for security updates, and the setting is gone. The **Security** word on a package and the count stay, for everyone. Open the widget or run `kempt status` to see them.
- **`reclaim=automatic` and the `reclaim` setting.** Kempt no longer removes unused Flatpak runtimes after an update, and **Never** is gone from the settings. A saved value is ignored. Press **Free Up Space** in the widget, shown when at least 1 GB can be freed and until you close it, or run `kempt reclaim`.
- **`kempt reclaim`'s waiting hour, `--expect`, and its second pass for extensions.** Kempt reads the list just before removing and passes only the runtimes on both lists, by name. A runtime that goes unused is offered straight away. An app installed in the moment between that list and the removal can lose an extension, and `flatpak update` puts it back.
- **`kempt reclaim --list`, its "no longer supported" marker, and its refusal when `include_flatpak` is off.** Without `-y` it shows the list and asks: answer no to only look. The widget still makes no offer when Flatpak is off.
- **"What Flatpak can remove changed" and "needs an administrator".** When Flatpak refuses, Kempt shows Flatpak's reason, then what is still installed.
- **The warning about an extension in use, `reclaim-last.json` and `reclaim-sizes.json`.** The result comes from the list read after the removal, and the size is measured each time. A leftover file does nothing.
- **Panel icon size and restart reminder settings.** The icon always sizes itself to the panel, and the restart message always shows when a restart is owed. A saved `widget_icon_size` or `restart_reminder` is ignored. Close the message with its **X**, which lasts until Plasma restarts.
- **`security.attention`, `security.digest`, `security.advisories` in `kempt check` output.** Nothing read them. `security.count` and `security.packages` stay.
- **`reclaim.digest`, `offerable_bytes`, `status`, `last`, and each ref's `commit` and `since` in `kempt check` output.** `reclaim` is now `refs[]`, each with `ref`, and `bytes`.

### Security

- **The no-dialog helper now refuses a package cache another user can change.** A check and a refresh both exit 3, as an update already did. `dnf-makecache.timer` is Fedora's and has no such check, so this narrows the hole and does not close it.
- **A second check or refresh started while one runs now stops at once**, and each one ends after two minutes, so a loop of them cannot keep the package lists locked. A refresh does not block an update.
- **[security.md](docs/security.md) now says what is true about SSH and a program with no session.** A program running as you with no session, started through `systemd-run --user` over SSH, counts as active and local if your account has a session at the computer and that session or another of yours, the SSH login included, is active. PackageKit has the same behaviour. It also adds `--exclude` to what such a program can do: it can leave chosen packages out of an update.
- **Kempt now stops updating when another user could change what is in dnf's folders.**
  The root helper checks owners and write access in dnf's state, staged packages and cache, and
  refuses to install, stage or set to install while any of them is unsafe. It also refuses when it
  cannot complete that check. Stock systems see no change, and `kempt doctor` gives the fix. A check
  finds the folder too, so `kempt status` and the widget say updates are paused before anyone presses
  Update Now. A refused update reports the helper's own reason.

### Fixed

- **A failed check no longer says "Up to date".** With nothing waiting, the widget and `kempt status`
  now say "Last check failed". The footer and the tooltip say how long ago the last good check was.
- **A failed update still reads as failed after the widget is reopened.** The Last update row now
  starts "Last update failed", with the reason under it.
- **The footer no longer cuts off "restart pending".** It takes a second line when it needs one.
- **A stored offline state that cannot be read is said plainly.** Kempt used to treat it as gone, which
  could claim that a restart had installed updates. The widget, `kempt status` and `kempt doctor` now
  say Kempt cannot tell what the next restart will do, and `kempt unstage` works when root can read it.
- **A restart that installed none of a staged update is now a failed run.** It gets a history entry,
  and `kempt status` stops saying the update is staged.
- **Discover's automatic updates get a plainer warning, higher up.** It sits right after the staged
  update message: "Discover is set to install updates by itself, so it can take over your next
  restart and stop Kempt's updates."
- **Kempt no longer offers to stage behind another updater's restart.** When another updater, such as
  Discover, has prepared the next restart, the widget says the restart belongs to it and offers
  **Restart…**. `kempt status` says so too, and `kempt doctor` warns. Install on Next Restart and the
  advice to stage go away until that restart is done.
- **`kempt update --surface=offline` refuses instead of updating live.** With system updates waiting and
  another updater holding the restart, it stops with exit 5 and changes nothing, Flatpak included, even
  with no terminal and `auto_accept` off. With nothing to stage it carries on.
- **A live run nobody was asked about stops too.** With no terminal and no `--risky-ok`, if its own
  check finds system updates while another updater holds the restart, it exits 5 and changes nothing.
  Flatpak apps alone still update.
- **Update Now asks first when it could cost the other updater its update.** It runs live, even when
  Kempt is set to install on the next restart, and with system updates waiting it first says that the
  update the other updater prepared may no longer install. Flatpak apps alone do not ask.
- **A restart that stops part way says so.** Kempt reads dnf5's history and rpm: a failed run with the
  versions that arrived when some did, "a package's script failed" when all did, and no count it cannot
  prove. A power cut reads as a restart that stopped, and how to prepare the updates again.
- **`kempt update` refuses unsafe folders before asking for a password.** It already knew, and it
  exited 1 after the prompt. It now exits 5 and changes nothing, Flatpak included. With no system
  updates waiting, a live run still updates Flatpak. A folder that turns unsafe during a run still
  exits 1.
- **A user's mount is called that.** `kempt status` and refusals now say a folder is on a mount made by
  a user other than root, as the root helper and `kempt doctor` do, and doctor no longer blames an old
  Kempt for it. While another updater holds the restart, `kempt status` no longer ends with a stage
  "for a restart".

### Added

- **A warning when Discover is set to install updates by itself,** since it can take over your next
  restart. It shows once, whatever Kempt's mode, with a button to turn off Discover's notifier. Turning
  the setting off and on again warns again. `kempt discover-notifier on` says automatic updates resume
  if the setting is still on, and `kempt discover-notifier status` shows the setting. An image-based
  Fedora gets neither this warning nor the offer to turn off the notifier.
- **Install on Next Restart in the widget's right-click and More actions menus.** It shows when
  system updates are waiting, nothing is staged and the main button says Update Now, so a lost or
  discarded stage always has a way back here.
- **The package recommends `rpm-plugin-systemd-inhibit`,** which holds off a shutdown while packages
  are changing.

## [0.2.0] - 2026-11-02

### Added

- **Staging warns when Discover's update check could cancel it.** While Discover's notifier is set to start,
  the staging notification says so, and the widget offers to turn the notifier off beside the staged
  update.
- **Put It Back restores staged updates that another program cancelled.** PackageKit removes the
  restart step of a staged update when it refreshes, which seems to come from Discover's notifier
  about once a day, so a later restart installed nothing. The updates stay downloaded. If no packages have
  changed since, the widget now offers **Put It Back**, and `kempt restore-stage` does the same.
- **Kempt's log says whether each notification reached you.** Every notification Kempt sends
  adds a line to `kempt log`: what it said, and whether it showed. When it did not, the line
  says why, for example no desktop session. A staged update that can no longer install no
  longer claims you were told when the notification did not show.
- **`kempt status --list` shows every update.** One line each with the current and new version,
  then the held ones, marked held. Security updates and apps installed for you only are marked
  too. It reads the last check, like `kempt status`, and lists the same updates as the widget.
- **Kempt says when a service stops starting after an update.** Each update notes which
  services were failing before it. If one that was starting fails after the update or the restart
  that installs it, you get one notification, such as "Bluetooth service didn't start after the
  update.", and another when it is running again (`kempt log` reads "Running again"). Services
  that were already failing stay quiet. `kempt startup` lists them with the command that shows
  why, `kempt startup mute` silences one until it starts, recovery included, and `kempt doctor`
  warns. Kempt only looks: it never starts or stops a service. Turn it off with
  `notify_startup=false`.
- **The widget shows a service that stopped starting after an update.** A warning names it, with
  **Copy Command** for the command that shows why and **Mute Until It Starts**. Services already
  failing before the update are listed quietly. The panel count and icon never include this.
  Settings has a **Services** checkbox and lists muted services, each with **Stop Muting**.
- **`kempt startup --all` shows what starts and runs on its own.** It lists what didn't start
  this boot with its log line, what changed since the last update, and what starts with the
  computer, grouped by package. Then timers, cron and anacron, and startup time against the
  usual. `--json` is for scripts. Kempt only reads.
- **The widget shows the same list on a Startup report.** Choose **Startup Report** in the widget's
  right-click menu, or in **More actions** in the system tray, even during an update. There is
  nothing to turn on. The page reads when it opens or when you refresh it, lists failures and
  changes in full, counts the rest with **Show All**, and offers only **Copy Command**.
  In the system tray, **Check for Updates** moves into **More actions** too, so the widget now
  shows its own refresh button in its header there, as it already did on the desktop.

### Fixed

- **Screen readers now hear the whole widget.** Shift+Tab visits every control in reverse.
  Opening the list says how many updates are waiting, and each padlock says its version change.
  Banner buttons name their service, settings radios name their setting, and the Startup report
  reads out what it found.
- **An update no longer hangs when a package's setup step restarts the system's service
  manager.** Kempt kept waiting forever, and then reported the update as failed even when it had
  installed. It now notices the update has finished and reads the result from dnf's history. A
  setup step that runs long is never interrupted. After 15 minutes the log says so once, as
  information, never as a warning. If an update or check is already running, a new one changes
  nothing and says so at once, also when another user started it. A check while an update runs
  keeps the last answer instead of showing an error.
- **A staged update now says how many updates it holds.** When the check before staging found
  nothing new, but staging then found updates, the summary and `kempt log` said "Staged 0
  updates". The count now comes from the staged update itself.
- **Notifications show `&`, `<` and `>` as written.** Plasma read them as markup, so a service
  or package name with one could garble the message.
- **An update no longer stops when Kempt cannot tidy its history.** Kempt keeps the newest 50
  run records and removes older ones. If one of them could not be removed, the run stopped there.
  Tidying is now best effort, as intended.
- **A computer without Flatpak no longer fails every check.** Kempt checks and updates system
  packages only, and the widget shows no failed check. In the widget's settings, **Include Flatpak
  apps** is greyed out. `kempt doctor` warns only if you set `include_flatpak=true` yourself.
- **A staged update cancelled by a dnf command of your own is announced straight away.** dnf5
  keeps calling such a stage ready, so Kempt said nothing until after the next restart, which
  then installed nothing. The next check now says once that the staged update can no longer
  install; with the widget, that is within about a minute. If your dnf command installed every
  staged update, Kempt clears the stage and says nothing. `kempt log` now reads "it was cancelled
  outside Kempt" there, not the name of an internal file.
- **A past staging run no longer reads as still staged.** `kempt status`, `kempt history`,
  `kempt summary` and `kempt log` said "1 update staged for the next restart" about the last run,
  even after that update was installed or discarded. They now say what the run did: "staged 1
  update for a restart". The first line of `kempt status` still says whether anything is staged now.
- **The widget notices a staged update you remove or make yourself.** `sudo dnf5 offline clean`
  leaves the package database alone, so the widget kept saying the updates were staged until its
  next scheduled check. It now watches the staged update too, and checks within about a minute.

### Security

- **`kempt doctor` checks the folders above dnf's folders.** Another user who can change `/var/lib`,
  `/var/cache` or `/usr/lib/sysimage` could put their own folder in place of dnf's. Doctor now
  reports such a folder as a problem and prints the commands that fix it.

Releases before 0.2.0 are in the changelog at [the v0.2.0 tag](https://github.com/erez-c137/kempt/blob/v0.2.0/CHANGELOG.md).

[Unreleased]: https://github.com/erez-c137/kempt/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/erez-c137/kempt/compare/v0.1.9...v0.2.0
