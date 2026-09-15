# Changelog

All notable changes to Kempt are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.3] - 2026-09-15

### Upgrading from 0.1.2

**Nothing to do: `sudo dnf upgrade`.** Your settings, holds, history and any staged update stay as
they were. If you turned on passwordless mode, it keeps working: the rule it installed is unchanged,
so there is no need to turn it off and on again.

### Changed

- **The software center entry no longer names an icon.** The AppStream metadata in the widget
  package pointed at a stock icon called `kempt`, which `appstream-util validate-relax` does not
  accept, and Fedora's packaging guidelines require that validator to pass. The entry describes an
  add-on to Plasma, not an application, so it now has no icon of its own, and the package build
  checks the file with both `appstream-util` and `appstreamcli`. The widget's icon in the panel and
  in Add Widgets is unchanged.
- **`/usr/share/doc/kempt` holds only documentation for people using Kempt.** The README, this
  changelog, `SECURITY.md` and the user guides in `docs/` still ship, at the same paths, so their
  links to each other work. Files about working on Kempt itself (`CONTRIBUTING.md`, `AGENTS.md`,
  `CODE_OF_CONDUCT.md`, the release procedure and the roadmap) are on GitHub only.
- **For packagers:** the `kempt` package no longer declares `bash >= 4.4`, because rpm already
  records the dependency on `/usr/bin/bash` and every supported Fedora ships bash 5. Installed files
  keep the timestamps they have in the release tarball.

### Fixed

- **A downloaded Fedora release upgrade can no longer be cancelled, discarded or started through
  Kempt's root helper.** `kempt update` already refused to stage updates over a stored release
  upgrade, but that check lived in the command line, which runs as you. For a few minutes after you
  authenticate an update, or at any time with passwordless mode on, another program running as you
  could call the root helper directly and replace, delete or arm the upgrade without a prompt. The
  helper now reads dnf5's stored transaction itself and refuses all three with exit 3 when it holds
  a release upgrade, or when the file cannot be read. `kempt update` reports the refusal, points at
  `kempt doctor`, and never suggests `sudo dnf5 offline clean`, which would delete the download.
- **`kempt enable-passwordless` installs exactly the rule it checked.** The rule used to be written
  to a temporary file you own, checked, and then copied by root once the password prompt was
  answered, so another program running as you could change it while the dialog was open. The
  checked rule now goes to root through a pipe, with no file in between.
- **The passwordless rule can only be installed at `/etc/polkit-1/rules.d/49-kempt.rules`.** The
  destination check accepted some other paths, such as a home directory, and could be raced by
  swapping a directory for a symbolic link after the check. The path is now fixed in every real run
  of `enable-passwordless` and `disable-passwordless`. `KEMPT_RULES_DST` is only a test setting, and
  it is refused whenever pkexec or root is involved.
- **The root helpers ignore shell start-up settings from whoever starts them.** They run bash in
  privileged mode, so `BASH_ENV` and similar variables are never read, even if a helper is started
  some way other than through pkexec.

## [0.1.2] - 2026-09-15

### Upgrading from 0.1.1

**Nothing to do: `sudo dnf upgrade`.** The panel widget and the command line are now two packages,
`kempt-plasmoid` and `kempt`. On a machine running Plasma, the upgrade installs the widget package
together with the new command line in the same transaction. This was checked end to end on a
Fedora 44 machine with 0.1.1 from the COPR: afterwards it had both packages, the widget in place,
and `kempt doctor: all checks passed`.

If you have turned off dnf's weak dependencies (`install_weak_deps=False`), the widget package is
not installed automatically. Run `sudo dnf install kempt-plasmoid` once.

The upgrade installs a few more packages than 0.1.1 asked for. `dnf5-plugins` provides
`dnf5 needs-restarting`, and without it the restart reminder never appears. `libnotify` and
`konsole` are now recommended instead of suggested: `libnotify` is how a background run reports what
it did, and `konsole` is what the default surface opens.

Nothing else changes. Your settings, holds, history and any staged update stay as they were.

### Added

- **Kempt now warns you if you hold a package after an offline update was already staged.** For
  example: you stage an offline update, then run `kempt hold dnf:kernel-core`. Before, the restart
  installed the kernel anyway and nothing told you. dnf5 built and stored that transaction before
  the hold existed, and it cannot edit a stored one, so the hold only applies from the next update
  Kempt builds. The command now says this on stderr and offers two fixes:
  `kempt update --surface=offline` builds the staged update again with your current holds, and
  `sudo dnf5 offline clean` removes it. The hold is saved either way and the command still exits 0.
  It warns, but never blocks and never asks a question. `kempt unhold` does the same in reverse,
  for a package the staged update was built without.
- **When Kempt cannot tell what is staged, the warning says so.** Kempt reads the staged package
  list directly from dnf5's stored transaction
  (`/usr/lib/sysimage/libdnf5/offline/transaction.json`, readable by all users by dnf5's design).
  This means it also sees packages pulled in as dependencies, not only the ones you asked for. If
  the file cannot be read, for example an older stage or a format this build does not recognise,
  the warning says "may still install" instead of saying nothing. It may name a package that is not
  in the transaction, but it will not leave out one that is. Flatpak holds are not affected, because
  the offline surface stages dnf packages only.
- **The panel widget no longer shows a "staged" banner that conflicts with your holds.** Before, if
  you staged an offline update and then pinned `kernel-core` in the popup, the green "staged" banner
  stayed, with a working **Restart…** button, right above the package you had just tried to keep
  out. It now becomes a warning that explains what happened, both ways to fix it, and what the
  offered button will do: *You held kernel-core after the next-restart install was prepared, so it
  still installs. Rebuild it to skip kernel-core, or stop holding kernel-core to keep the current
  plan. Rebuilding asks for authorization; if it fails, nothing stays staged.* (With several
  packages: "kernel-core and 2 more".)
  While this warning is shown, no restart button is offered, neither the banner's nor the restart
  reminder's, since restarting would install what you tried to hold. Instead there is one action,
  **Rebuild Staged Update**. It runs the same command as **Install on Next Restart**, with the same
  authorization prompt, and reuses dnf5's package cache instead of downloading again. Its tooltip is
  also its screen-reader description, so screen-reader users hear what it does before the
  authorization dialog takes focus. The change of state is shown in words, not only by colour.
  If Kempt cannot read the staged list at all and you hold dnf packages, the banner says it may
  still install held packages. With nothing held, it stays green.
- **Rebuild Staged Update checks again before it acts.** The popup can stay open for an hour, and in
  that time a restart may have applied the staged update, or something may have replaced it. When
  you press **Rebuild Staged Update**, Kempt reads the state file again. It only acts if the same
  staged update is still there and still conflicts with your holds. Otherwise it runs nothing and
  says *The staged update changed since this was offered. Nothing was rebuilt; check the banner
  above.*
- **`kempt doctor` tells you when the staged update will install a package you hold.** The line
  starts with the effect (it installs kernel-core on the next restart despite the hold), explains
  that the hold was added after the transaction was staged, and ends with both fixes. It is reported
  as `info`, not as a failure, because this is a valid state, and failures for valid states teach
  people to ignore failures.
- **`kempt doctor` fails when the staged update is not the one Kempt built.** It compares what Kempt
  recorded when staging with dnf5's stored transaction, and lists up to four package names each way
  that one side has and the other does not. Any process running as your user can replace a staged
  transaction during polkit's retention window. Before this change, every part of Kempt would still
  have described the original set.
- **`kempt doctor` now checks the boot symlink `/system-update`, not only dnf5's transaction
  status.** If that symlink is still there but the transaction is not armed, the next restart enters
  the offline updater and installs nothing. The report now says so and suggests `sudo dnf5 offline clean`,
  whether or not Kempt staged anything.
- **`kempt doctor` detects a mixed install, in both directions.** It compares each polkit action's
  `exec.path` annotation with the helper path the CLI passes to pkexec. They differ when a package
  was installed over a checkout install, or the other way round. In that case pkexec finds no
  matching action, so every privileged run shows an authentication dialog and a background check
  times out instead of answering. The report shows both paths and the fix for each kind of install.
  It also shows which `kempt` the panel widget will run. The widget looks in `~/.local/bin` first,
  so a leftover symlink there overrides a packaged `/usr/bin/kempt` for the panel only. Before, the
  report could describe a different install from the one the panel was actually using.
- **`state.json` now tells the widget about the conflict.** `offline_staged` gains `holds_conflict`
  (held packages the staged update will install anyway) and `names_source` (whether an empty list
  means "no conflict" or "cannot tell"). Both fields are additions, appear only while a stage is
  armed, and readers must handle them being absent.
- **The package build runs the tests.** The RPM runs the full bash test suite in its check stage, on
  a clean copy of the source tree, so the package cannot be built if the suite fails. This was
  confirmed in a Fedora rawhide mock build. A live container test
  (`tests/live/run-offline-gate.sh`) runs the offline update lifecycle against real dnf5 with
  injected failures, when run by hand. A new docs test fails the suite if a markdown table is split
  in two, or if the code reads an environment seam that the architecture doc does not list.
- **For readers and contributors:** a ["Why bash"](docs/architecture.md#why-bash) section in the
  architecture doc answers this common question once, including the costs, and is linked from the
  README and CONTRIBUTING. Also new: issue forms (the bug report asks for `kempt doctor` output and
  how Kempt was installed), a pull request template, and dependabot watching the CI action pins.
- **[AGENTS.md](AGENTS.md) is a two-minute introduction for a new maintainer**, human or AI. It
  covers what the two halves are, where things live, and four important rules: never run the update
  paths while testing; the environment seams are the test boundary, and the docs test enforces
  them; the live test deliberately breaks a package manager and refuses to run outside a container;
  and Qt probes must be supervised. Each rule comes from a problem that has already happened.
- **CI now tests the panel widget.** The widget tests need node and PySide6 plus the Plasma and
  Kirigami QML modules. The CI runner had none of these, so both test files were skipped, and the
  skip message looked like a pass. Until now, a green badge covered only the command line, not the
  panel. A Fedora container job now runs both and fails if a dependency is missing. The suite's
  summary also lists what a run did not cover, instead of just ending with "ALL PASS".
- **The "adding a backend" guide is now complete.** It said it was complete but only covered the
  CLI. It did not mention the popup's section titles or the panel's file watcher. A contributor who
  followed it exactly would get a heading reading `apt`, and a panel that did not notice changes
  from their backend.

### Changed

- **The panel widget is now a separate package: `kempt-plasmoid`.** `kempt` contains the command
  line, the root helpers and the polkit action. `kempt-plasmoid` contains the panel widget and needs
  both. Before, they were one package that required `plasma-workspace`, so `sudo dnf install kempt`
  on a machine without a desktop installed 787 packages and 2.9 GB to run 0.7 MB of shell. If you
  already have Kempt, see **Upgrading from 0.1.1** above.

- **The hold button on each package is now a padlock:** open for a pending package, closed for one
  you are holding. The old pushpin is Plasma's own "Keep Open" icon, used in the system tray
  heading, the calendar popup and the folder-view popup, always with that one meaning, and Kempt
  showed a whole column of them right below the tray's. On held rows the pin was crossed out with a
  slash in the colour scheme's negative red, so the packages you chose to protect had the only red
  mark in the popup and looked cancelled. The padlock shows the state instead of the action, and the
  state is also written out: a **Held** label before the version, a button that says *Hold glibc at
  2.41-3.fc44* or *Stop holding glibc* instead of "Hold glibc at its current version", and a line
  under the Held group explaining that a hold only exists in Kempt's list and `sudo dnf upgrade`
  does not know about it. Held rows are no longer dimmed, which had lowered the contrast of exactly
  the rows you chose to keep.
- **The top of the popup shows when updates are staged.** The header reads *23 updates staged for
  the next restart* instead of listing the same 23 as available, and the panel tooltip says the same.
  **Update Now** is hidden while the stage is armed. Before, it was active right below a banner
  saying those updates were already waiting, and pressing it started them again, live. The badge
  still shows the real count, because those packages are still pending until the restart.
- **The kernel notice is now informational and explains its button.** It reads: *This update
  includes a kernel. The safest way is to install it on the next restart, so nothing changes under
  the running desktop.* Before, it read "This includes a kernel update. Restart when it finishes." in
  amber, above a button that did the opposite, before anything had started. **Install on Next
  Restart** now uses the software-update icon, and only **Restart…** uses the reboot icon, so the
  two buttons next to each other no longer look the same.
- **The updating pane says how the update is running:** *Updating in a terminal window…*,
  *Updating in the background…*, *Updating…*, or *Preparing the install for the next restart…*.
  Before, it named the configured surface using the word "surface", which appears nowhere else in
  the interface. The pane has a **Not updating? Check again** button. Keyboard focus moves to it
  when the pane opens, and back to a visible control when the pane closes. Before, focus stayed on
  the hidden **Update Now**.
- **A package that is not installed yet shows `new → 1.0-1.fc44`** in the list and in the last
  update's package list. Before, it showed `? → 1.0-1.fc44`, which looked like the widget did not
  know.
- **The update count for a staged transaction now comes from a fresh check just before staging.**
  Before, it was copied from the last check's `state.json`. This count is the only thing you are
  told about a transaction you cannot open, and it could come from another check against different
  metadata, possibly days earlier. If the fresh check fails, Kempt warns and stages with the old
  number.
- **Two limits of the offline update path are now documented** in
  [docs/security.md](docs/security.md#accepted-limitations). First, during polkit's retention
  window, a process running as your user can replace the staged transaction without a prompt.
  Second, dnf5 stores the staged package list readable by all users, so anyone on that machine can
  see what it is about to install. This is dnf5's design.
- **The documentation now covers the packaged install, which most people use.** Every place that
  mentions a path, a verify step or an uninstall command says which kind of install it means, and
  gives both where both exist. From the package: root helpers are in `/usr/libexec`, the CLI is
  `/usr/bin/kempt` (a symlink into `/usr/share/kempt`), the widget is under
  `/usr/share/plasma/plasmoids`, and you uninstall with `sudo dnf remove kempt`. From a checkout:
  `/usr/local/libexec`, `~/.local/bin/kempt`, `~/.local/share/plasma/plasmoids` and
  `./install.sh --uninstall`. The install guide now covers the packaged install end to end, with a
  real `kempt doctor` report from a packaged machine. It also notes that the widget is already in
  your tray, so adding it again from Add Widgets gives you two Kempt icons. SECURITY.md now starts
  by stating that nothing Kempt installs is setuid and every privilege escalation goes through
  polkit, and it lists which versions are supported. The man page, the security doc and the release
  checklist are updated to match the current CLI and COPR.
- **The RPM License field is now `MIT AND CC0-1.0`.** The packaged AppStream metainfo is CC0-1.0 by
  freedesktop convention, and the field now reflects that.
- **The roadmap now starts with what has shipped** instead of a completed to-do list, and has new
  entries for Fedora Atomic and fwupd. Working notes that did not belong to the project (posting
  drafts, store-ops records, outreach strategy) were removed from the repository.

### Fixed

- **A machine that is far behind on updates can now update.** Linux limits a single command-line
  argument to 128 KiB, and Kempt passed the pending list to a program that way. `kempt check`
  failed at 925 pending updates, and an update run failed at about 1,200 updated packages. In
  both cases the panel said *"Kempt's engine is not installed"* about an install that was working.
  A fresh install from an ISO a few months old, or a laptop that was off for a season, can easily
  be in that range. Present in 0.1.0 and 0.1.1. In the worst case it happened after an update had
  finished: everything was installed, but there was no history entry, no summary, no
  notification, and the panel kept spinning for three hours.

- **An engine that is installed but will not start now says so.** The panel used to say
  *"Kempt's engine is not installed"* and show two commands to install it. The real cause is
  always something else, such as a file without its execute bit, a `noexec` mount or a missing
  interpreter. The message now describes the real state and points to `kempt doctor`. When there
  is no earlier state to fall back on, the panel icon shows a warning instead of dimming, which it
  still does on a machine where Kempt has not been set up yet.

- **What Kempt says about a stored Fedora release upgrade now matches what dnf5 will do with it.**
  A stored transaction can be in one of four states, and each affects whether a restart installs
  it: downloaded and not started, armed and waiting, armed but already skipped by a restart, or
  recorded by dnf5 as unfinished. Being armed means two things, dnf5's `ready` status and the
  `/system-update` symlink, so Kempt now reads both instead of the status word alone. Every screen
  names the current state and the fix for that state. It no longer promises a restart install that
  will not happen, or shows a status word that contradicts the sentence around it. A status word
  this build does not recognise makes no promise at all.

- **Staging updates no longer removes a staged Fedora release upgrade.** dnf5 keeps one stored
  transaction for both release upgrades and ordinary offline updates. Pressing **Install on Next
  Restart** while a release upgrade was waiting replaced it (dnf5 warns, then does it anyway when
  it is not asking questions). It also left `/system-update` in place, so the machine still
  restarted into an update, but not the one that was requested, and Kempt reported its own stage
  as a success. Downloading a release upgrade again can take gigabytes. Kempt now refuses before
  anything runs, the popup no longer offers the button, and `kempt doctor` says what is waiting
  and whether a restart will install it.

- **A staged update can no longer be armed without Kempt keeping a record of it.** Kempt writes a
  marker after arming a transaction, and by then the transaction cannot be undone. If the home
  folder was full, the run stopped at that point, and the next restart installed a transaction
  Kempt did not know about: no banner, no doctor line, no notification afterwards. Now nothing at
  that point can end the run. If part of the record cannot be saved, Kempt writes what it can,
  and the banner, the staged count and `kempt doctor` still work. If it cannot record the stage at
  all, the run still succeeds, and the notification says the update installs on the next restart
  and that Kempt will not be able to report the result.

- **When Discover, PackageKit or dnf-automatic holds the package lock, Kempt now says that.** The
  error used to show dnf's own line about a lock file, which looks like a broken installation. It
  now says another program is using the package system and to try again in a few minutes. Other
  failures still show their own reason.

- **Kempt now refuses to run on an image-based Fedora instead of giving wrong results.**
  Silverblue, Kinoite, Bazzite and bootc images update as a whole image, with `rpm-ostree upgrade`,
  or `bootc upgrade` on a bootc image. They still ship dnf5, so Kempt installed without errors, the
  widget appeared, `kempt doctor` reported all checks passed, and an update would have prepared a
  transaction and then failed partway through with a message about a read-only file system. Kempt
  now names the tool that machine updates with, on `kempt doctor`'s second line and in the popup,
  and removes **Update Now** from the screen. Support for these images is planned.

- **Closing the update terminal, or answering its risky-transaction question with `abort`, no
  longer leaves the widget on an empty updating pane for up to three hours.** Both of these ended
  the run without writing anything. Only a new `state.json` takes the popup out of its updating
  state, so the package list, **Update Now** and **Refresh** disappeared until a three-hour
  safety timeout ran out. The terminal now runs a new check on every way out, including when its
  window is closed, so the run ends when the terminal does. The exit status is still the
  update's.
- **Pressing a package's padlock now behaves as expected.** Every padlock in the list used to become
  disabled on the press. Qt moves keyboard focus away from a disabled control, so 30 ms after
  Space the keyboard focus was on an unnamed container. The row still offered "Hold", and a second
  press sent a second `kempt hold` to the CLI. The list then jumped to the top, the row moved under
  **Held** out of view, and nothing announced the change. Now only the *other* rows are disabled.
  The row you pressed keeps its button and keyboard focus, shows a spinner in place of its padlock,
  and ignores a second press. When the follow-up check finishes, keyboard focus follows the package
  into its new group, a mouse press leaves the list where it was, and the popup announces *Holding
  kernel-core* to screen readers. A failed hold is shown in its own row, under the version, instead
  of as a message at the top of the popup.
- **The popup shows at most two messages at once.** With five messages, the pending list was only
  95 px tall at the default size, and at the minimum size it was pushed out of the popup. The
  messages sit outside the scrolling area, so the list could not be scrolled back into view. A
  failed check now appears in the footer (`Checked 2 hours ago · last check failed`, with the
  reason in the Refresh button's tooltip). The after-run message and a failed button press share
  one slot, and any message over the limit is not shown instead of stacking out of view. A pending
  restart is always shown: the footer says `restart pending` whenever no message is showing it.
- **Update Now no longer starts two runs.** `kempt run` can take up to fifteen seconds to open a
  window and return, and a double press opened two terminal windows, both asking whether to update
  a running desktop. The button now shows a spinner and ignores presses until the CLI returns.
- **Screen readers now get the same information as the screen.** The **Held** group heading is now
  read as a heading with a name (Kirigami's own section header marks its label as ignored). The
  header over a list with only held packages says *Up to date · 2 held* instead of *Up to date*
  above rows that still have new versions waiting. The panel tooltip says `restart pending` when a
  restart is needed. Enter now activates the padlock, Update Now and Refresh, which used to respond
  only to Space.
- **The panel icon no longer uses Breeze's `update-high` icon for Kempt's own errors.** Plasma's
  own update notifier uses that icon for security updates, so it suggested security fixes when the
  real message was "Kempt cannot check for updates". The warning emblem Kempt already draws now
  shows the error instead.
- **The message shown when the terminal emulator is not installed now says what to do** in the
  widget's own terms instead of a bare shell command: "Kempt could not find konsole. Install it, or
  run updates another way: kempt config set surface background (Settings > Run updates in > In the
  background)". `kempt doctor` gives the same fix. The exit status is still 4.
- **A failed re-stage no longer leaves a partial stage behind an active boot symlink, and no longer
  throws away a stage dnf5 kept.** A failed re-stage can go two ways. If the download cannot
  finish, it fails before dnf5 touches the previous transaction, which stays armed and installs on
  the next restart as before. Kempt now leaves it alone, fails the run saying the previous update
  is unchanged, and keeps the conflict on screen so you can try again. If dnf5 got far enough to
  store the new stage, it has already replaced the previous transaction. A failure after that used
  to leave a partial stage that nothing arms, with the old boot symlink still in place: the next
  restart went into the offline updater, installed nothing, and left no record anywhere. Kempt now
  discards that partial stage, removes its marker, and fails the run saying the previous staged
  update was discarded. If that cleanup also fails, the marker is kept for `kempt doctor` and the
  notification includes `sudo dnf5 offline clean`. The same now applies when arming fails and its
  cleanup fails. Before, the command appeared only on stderr, which you do not see when the run was
  started from the panel.
- **When a restart could not install the staged update, Kempt now tells you instead of just
  removing the banner.** The popup's staged line disappears as soon as the transaction is no longer
  armed, and before, that was all: no notification, no event, and a marker left waiting for an
  install that would not happen. The next check now says it once, "Your staged update can no
  longer install on a restart. Re-stage it, or run sudo dnf5 offline clean.", and keeps its record
  of the stage, marked as no longer active, instead of deleting it, so `kempt doctor` can still give the exact cause instead of
  treating the transaction as one Kempt did not create.
- **A check at the wrong moment no longer makes Kempt forget a staged update.** The offline marker
  is now written atomically with mode 0600 (it lists what the next restart installs, so it is kept
  private like `state.json` and the event log). A marker that reads back empty, unreadable or
  unreasonably large is now skipped by everything that reads it, instead of being deleted as if
  the stage were gone. `kempt doctor` reads the marker the same way and says when it cannot read
  it, instead of describing a pending install from a file it could not parse.
- **Settings and holds are no longer lost when two commands write at the same time.** `kempt config
  set`, `kempt hold` and `kempt unhold` each read the whole file, changed their own line and wrote
  the file back, so when two ran together only the last change was kept. Before this fix, 40
  overlapping `config set` commands left 4 settings, and 40 overlapping `unhold` commands removed 4
  holds. The widget runs its commands one at a time, so the settings page could not cause this on
  its own. Two terminals, a script, or the CLI running alongside the widget could. The three
  commands now take a lock across the read and the write. Reading takes no lock.
- **Warnings are no longer lost after a command writes a setting or hold.** Releasing that lock
  closed its file descriptor with a form of `exec` that also sent the rest of the process's error
  output nowhere. Anything Kempt tried to tell you after a `kempt config set`, `kempt hold` or
  `kempt unhold` was discarded, with no error and no log entry.
- **A system without diffutils no longer misreads its own staged update.** On a minimal Fedora
  image (a container, a server install) `cmp` is missing. Kempt compared its package snapshots with
  `cmp -s` and took the missing command's exit status to mean "the files differ". As a result, an
  unchanged system was recorded after a restart as "applied, no package changes" and its marker was
  deleted, a live update over a staged one was not detected, and `kempt doctor` reported every
  helper as changed from the checkout. Comparisons now need only coreutils. A new live test under
  `tests/live/` runs the whole offline lifecycle against real dnf5 in a throwaway container, with
  failures injected at the stage, the cleanup and the arm.
- **The test suite now passes from a release tarball,** not only from a git checkout. The doctor
  version test no longer assumes git history, and the log test uses a stub terminal emulator
  instead of relying on the CI workflow's shim.
- **The panel now notices an update you ran in a terminal, which it never did on Fedora.** The
  widget checks a few paths every 30 seconds so that an update applied from anywhere shows up
  within seconds, and one of them was `/var/lib/rpm`. Fedora's rpm database is sqlite and is
  changed in place, so that directory's modification time does not change when packages are
  installed or removed. On a machine updated the same night, it showed as four months old. So this
  part of the refresh never triggered, and a `sudo dnf5 upgrade` typed in a terminal was not shown
  until the next scheduled check, up to an hour later. The widget now also watches the database
  file.
- **Closing the update window now ends the run, even when the check takes a while.** The recovery
  check that rewrites the state file, which is the only thing that takes the popup out of its
  updating pane, ran in the terminal's own process group. Closing the window sends that group a
  hangup, and the terminal emulator stops anything still in it moments later. A real check takes
  seconds because it asks dnf, so it was stopped partway, and the popup stayed on an empty updating
  pane until its three-hour timeout ran out. The check now runs in its own session, where closing
  the window does not affect it.
- **Holding every pending update and then staging is no longer reported as a failure.** When there
  is nothing to stage, dnf5 prints "Nothing to do", exits 0 and stores no transaction. Arming then
  failed with "No offline transaction is stored", and Kempt reported *Update FAILED (staged but
  could not arm the restart install)*, exit 1, blaming the arming step for a transaction that was
  never created. It now says *Nothing to stage - every pending update is held*, and the run
  succeeds. Nothing is armed, nothing is cleaned up, and no marker is written.
- **Another tool updating your packages is no longer mistaken for your staged update being
  installed.** If `dnf-automatic`, GNOME Software or a terminal `sudo dnf5 upgrade` changed
  anything between staging an offline update and the next boot, Kempt reported "Staged updates
  were applied on reboot", wrote a history entry listing the other tool's packages, and deleted its
  own record. The staged transaction was still armed and would still install on the next restart,
  but no screen mentioned it any more. An offline transaction that has been applied removes dnf5's
  stored transaction, its `transaction.json` and `/system-update`. Kempt now waits while any of
  these is still present, because that means the update has not run yet.
- **A staged update that can no longer install now says so, instead of being shown as pending after
  every restart.** Being armed means two things: dnf5's `ready` status and the `/system-update`
  symlink. Kempt read only the status, so a transaction whose symlink was gone was shown as
  "installs on the next restart" after every restart, with `kempt doctor` reporting the system as
  healthy. Kempt now announces it once, marks it as inactive, and `kempt doctor` shows a row with
  the fix. **This is easy to hit: running `sudo dnf5 install <anything>` while an update is staged
  removes that symlink and leaves the status at `ready`.** This is dnf5's behaviour and is not
  documented. Stage it again with `kempt update --surface=offline`, or clear it with `sudo dnf5
  offline clean`.
- **`kempt doctor` no longer passes a packaged install whose update path has been redirected.**
  Three lines in `~/.config/environment.d` pointing Kempt's helper seams at `/bin/true` made `kempt
  update` report "0 updated" without running anything, kept the widget green, and made doctor say
  "all checks passed", while the system was no longer getting security updates. A checkout install
  catches this by comparing files against the source tree. A packaged install has no tree to
  compare against, so doctor now names the override instead.
- **The check before enabling passwordless updates now requires the generated rule to match
  exactly**, instead of only checking that it contains the right parts. Checking for parts catches
  a rule that is missing something, but not one that has something extra. A template with the
  required scope clause, the correct action id and a single rule block, plus an unconditional grant
  inside that same block, passed every check and would have given passwordless root for every
  polkit action from any session.
- **The package now declares everything it runs.** `dnf5 needs-restarting` is in `dnf5-plugins`,
  not `dnf5`, and without it the restart reminder never appeared, so a restart needed after a
  kernel update was never offered. `notify-send` is how every background run reports what it did,
  and it was not declared at all. `konsole` is what the default update setting opens, and because it was
  only suggested, `kempt doctor` reported a failure on a fresh, correct install, and doctor is the
  first command the documentation tells you to run. It now passes, checked from the installed
  package.
- **The README included with the package no longer links to missing pages,** and the page that
  explains what was installed and how to remove it is now included. `/usr/share/doc/kempt/` contains
  the documentation tree, so 15 of its 17 links work on the machine, compared with 1 before.
- **A checkout in a path containing an apostrophe can now run updates.** The terminal wrapper
  quoted the path by hand, so the apostrophe ended the quote early, and **Update Now** opened a
  window that did nothing.
- **A check running at the same time no longer discards an update you just staged.** Clicking
  **Install on Next Restart** just as a background check was finishing showed "Updates staged - they
  install on the next restart" and then, a second later, a panel showing nothing staged. The
  transaction was still armed and would install on the next restart, but Kempt no longer knew
  about it. Two contradicting notifications arrived one after the other.
- **One slow helper no longer blocks every later check.** The check's lock was passed to the root
  helper and everything it started, so any process still running after a helper timed out kept
  holding the lock. The next check waited for that process, and after a minute every check showed
  an out-of-date result without saying so. After a restart, the handling of a staged update waits
  for the same lock, so it was held up too.
- **The test suite no longer needs `ps`.** `ps` is not in the package's build requirements or in
  Fedora's minimal build root, so every package build of 0.1.2 would have failed its test stage.
  Also, a test that stopped a slow writer stopped only part of it. The rest finished writing
  seconds later, into a test sandbox that had already moved on. This caused a stray error line in
  CI output and intermittent test failures.

## [0.1.1] - 2026-09-04

### Changed

- **You can install Kempt from a package repository.** The COPR repository is live and its builds
  pass. The README now starts with `sudo dnf copr enable erez-c137/kempt && sudo dnf install
  kempt`. Installing from a git checkout is now the development path. Both commands were tested in
  a clean Fedora 44 container and ended at `kempt 0.1.0`.

### Fixed

- **A widget installed from the KDE Store now tells you what to install next.** The store only
  carries the widget (plasmoid), not the `kempt` command it needs. Before this fix, the first check
  on a store install showed the raw shell error `sh: line 1: kempt: command not found`, above a
  suggestion to run `kempt doctor`, which could not work because `kempt` was the missing piece.
  For anyone who found the widget before the package, that was their first view of Kempt. Now the
  widget treats this as a setup step, not a failure. The panel icon stays dim, with no warning
  emblem and no made-up count. The popup shows the two commands that install the engine, and where
  to look if you are not on Fedora. A **Copy Commands** button copies them to the clipboard as one
  chained line, because the text of an InlineMessage cannot be selected and retyping a command
  invites mistakes. Technical detail: the widget reads the exit code instead of the message (127
  means the command is not there, 126 means it is there but cannot be run). This is as far as a
  COPR package can go. The one-click install offered by the PackageKit session API only works with
  repositories that are already enabled, and a COPR is not one of those. Official Fedora packaging
  (on the roadmap) would lift this limit.
- **`kempt doctor` finds a store copy of the widget that hides the packaged one.** `kpackagetool6`
  installs the widget into your home directory, the RPM installs it into `/usr/share`, and Plasma
  uses the one in your home directory. So if you installed the widget from the store before the
  package, Plasma kept loading that old copy. Every later package update went into a directory
  Plasma never read, and the old copy kept working normally, so nothing looked wrong. On a
  packaged install, doctor now fails when it finds a user copy, explains the effect, and prints the
  two commands that remove it. `docs/install.md` covers installing from the store first, from start
  to finish, including what the widget shows before the engine is installed.

## [0.1.0] - 2026-09-03

The first working version of Kempt: the complete command-line tool, its root helpers, its
installer and its documentation, and the Plasma panel widget that sits on top of them.

### Added

- **One command shows what is waiting to update.** `kempt check` asks dnf5 and Flatpak and writes
  a documented JSON state file (schema v1). It lists every pending item, the installed version and
  the new version. It reads the same root metadata cache the update itself uses, so the count and
  the update always match.
- **Checks work offline.** Both backends read only local caches. All network downloads happen in
  one step that runs at most every three hours, and only on mains power over an unmetered
  connection. On a train, behind a captive portal or on battery, `kempt check` still shows what is
  pending, instead of reporting the Flatpak side as stale. The Flatpak part of that download runs
  as you, with no privilege escalation of any kind.
- **A version number you can put in a bug report.** `kempt --version` (also `kempt version` and
  `kempt -V`) prints the release. `kempt doctor` starts with the release and the checkout it came
  from. A single `VERSION` file is the source of truth. The test suite ties the panel widget to it,
  so the command line and the widget always report the same release.
- **The download size is shown next to the Update button.** The popup footer reads
  `Checked 4 min ago · ~140 MB` and the tooltip says `~140 MB to download`, so you can decide
  before pressing Update Now on a metered connection. The number comes from metadata already on
  disk. It needs no dependency resolution and no network, and nothing runs when the popup opens.
  It is an estimate and says so: it shows `~`, never "up to". It leaves out held packages and the
  dependencies dnf will add, and it counts Flatpak high, because Flatpak downloads less than it
  lists. When the size is not known, nothing is shown, rather than `0 MB`.
- **Held packages are skipped but still shown.** `kempt hold dnf:kernel-core` keeps a package out
  of every Kempt run. It still appears as pending, is not included in the count of updates you can
  run, and is named in each run's `Held (skipped)` line.
- **Four ways to run an update.** In a terminal with live output, inside the popup, in the
  background without a window, and offline staging. Offline staging downloads the update and sets
  it up so the next restart of any kind installs it, which is the method Fedora recommends. After
  that restart, the result is added to the normal history. This is tied to the boot session, so no
  other package change can be mistaken for it. While an update is staged, the popup shows one
  green line saying so, instead of offering to stage it again. A live update removes a staged
  update that it has made out of date, rather than leaving one set up that would fail. `kempt
  doctor` points out a staged update that can never install, with the command that clears it.
- **Advice, not a block, for risky updates.** When a pending update touches packages your desktop
  session depends on, an interactive run offers three choices: update now, stage it for the next
  reboot, or abort. The default is abort. Runs without a terminal send a heads-up notification and
  go ahead. The same list is written to the state file as `risky_pending`.
- **Summaries are built by comparing package lists before and after**, not by reading the
  transaction output. They show old and new versions, installs, removals, held items, how long it
  took and whether a reboot is needed. One renderer produces them for the terminal, the
  notifications and the widget.
- **History and logs.** Each run gets one JSON entry and one raw log. Old ones are removed
  automatically: the newest 50 entries are kept, and logs are deleted after 60 days.
- **An event log, read with `kempt log`.** It has one line for each thing Kempt did. That includes
  a setting changed and its old value, a hold added or removed, a check and its counts, a metadata
  refresh, a run starting and how it ended, an update staged, a staged update recorded after the
  reboot, and an attempt to allow passwordless updates. Each line is marked `widget` or `cli`, so
  you can tell a change made in the panel from one typed in a terminal. The per-run logs show what
  the package manager printed, and the history shows what a run changed. The event log answers a
  different question: did the thing you just did actually happen. The file has mode 0600, trims
  itself past 2500 lines, and its last five lines are added to the end of `kempt doctor`.
- **A cancelled password prompt is reported clearly.** When a run or check fails because the
  authentication dialog was declined or closed, the summary, the notification, `kempt history`,
  the state file and the event log all say `authentication declined or cancelled`. Previously they
  showed pkexec's "Error executing command as another user: Not authorized", which looks like a
  broken install. The original wording is kept in the run log as a record. Failed runs now store
  their reason in the history entry, so the summary explains the failure instead of pointing to a
  log file.
- **Root access is limited to what each task needs.** There are two polkit actions and two root
  helpers that check their arguments. A quick metadata refresh never shares a cached
  authorization with a system upgrade. The optional passwordless mode is a single rule for a
  single action, and only for an active local session.
- **Updating only Flatpak apps needs no password.** Flatpak apps do not need root to update:
  Flatpak's own policy lets an active local session update system apps without asking. Kempt used
  to send these updates through the root helper anyway, so a run with only app updates showed a
  password dialog that plain `flatpak update` never shows. It now runs as you. Two cases can still
  ask for a password: an update that needs to install a new runtime, and a run started over SSH
  rather than at the machine. `kempt-apply` now handles dnf only, and refuses the old verb.
- **An installer that tells you what it does.** `install.sh` asks for authentication once and says
  exactly what it put where. It can stage files without root using `--destdir`, and undo itself
  with `--uninstall`. It offers to turn off Discover's update notifier, but never does so without
  asking. Left on, that notifier shows duplicate notifications and holds the dnf5 lock.
- **`kempt doctor`, a checkup that tells you what is wrong.** It prints one line per check: the two
  root helpers, the polkit action, `jq`, the terminal emulator, flatpak, the config file's syntax,
  a writable state directory and an intact checkout. It exits with 1 if anything failed. It is
  needed because the rest of Kempt keeps running when something is missing, instead of crashing.
  For example, with the root helpers missing, `check` exits 0 with an old state and nothing
  pending, which looks like "up to date".
- **An update you pulled but did not install is easy to spot.** `kempt doctor` ends with the commit
  the checkout is on, plus `helpers:`, `policy:` and `widget:` lines that compare each installed
  copy with it. On a checkout install, only part of Kempt updates with `git pull`. The command line
  is a symlink, so it changes right away. The root helpers, the polkit action and the widget
  package are copies that change only when `./install.sh` runs. `DIFFER` marks that gap and gives
  the command that fixes it. An install that did not come from a checkout prints
  `install: packaged` and compares nothing, because the package manager keeps those files in step.
  The matching procedure is in [docs/RELEASING.md](docs/RELEASING.md). It also explains why Kempt
  has no self-update code and will not get any: a packaged Kempt is updated by the package manager
  it manages, and appears in its own popup like any other pending update.
- **A panel widget that shows accurate information.** A Plasma 6 applet whose badge is the command
  line's own count of updates you can run, never a guess. Missing data is shown as "no data", not
  as zero. If a check fails, the widget keeps the last known numbers and puts the reason in the
  tooltip, instead of raising an alarm because a repository failed once. The popup lists pending
  and held items, updates in one click, offers offline staging where you can use it, and lets you
  hold packages. Its settings page is a front end for `kempt config` and keeps no separate copy of
  any setting, so the panel and the terminal always agree. A change made in one reaches the other
  within 30 seconds. The widget calls the command line for everything and has no package-manager
  logic of its own. Every command it runs goes through one component with a hard timeout, so a slow
  `dnf` cannot freeze the panel. `install.sh` installs and removes it, and you decide where it
  goes.
- **One check per update run, not three.** The widget looks at the package databases and its own
  state file every 30 seconds, so a `dnf upgrade` typed in a terminal shows up in the panel on its
  own. It no longer reacts to changes it caused itself. An update rewrites the package database
  throughout the transaction and the state file at the end. That used to produce three
  `widget check ok` lines in `kempt log` within 40 seconds, two of them about nothing. Now the
  watcher stays quiet for a minute after a check finishes. Refresh, the scheduled check, opening
  the popup and changing a setting are not affected by this pause.
- **It sits in the system tray with your other system monitors.** Kempt registers as a tray entry
  under *System Services* and is turned on there by default. Installing it is enough: no need to
  drag it onto a panel, and in the tray it is the same size as the icons next to it. You can still
  add it to a panel directly, and that is still supported. The tray is simply the natural place
  for an update notifier.
- **The panel icon matches the size of the icons around it.** When placed directly on a panel, the
  icon is drawn at the size the system tray uses for that panel height. That is 22 px on every
  ordinary panel, including Plasma's default 44 px panel. Before, it filled its whole cell and
  stood a head taller than the tray icons beside it. `widget_icon_size` (Automatic, Small, Medium,
  Large, also on the settings page) lets you override the size if the automatic choice looks wrong.
  If the panel cannot fit the chosen size, it falls back to Automatic. So inside the tray, the
  tray's own slot size always wins, and Large is never smaller than Automatic. The count badge is
  placed on the icon rather than the cell, so it stays readable and stays on the icon. Below the
  22 px size the badge is not drawn, since it would be too small to read, and the tooltip shows the
  exact count.
- **Its own icon.** The icon is a comb. The application icon and 22px and 16px symbolic icons ship
  inside the widget package. `install.sh` also copies the application icon into the user's hicolor
  theme, which is what lets **Add Widgets** show it (an icon name that exists only inside the
  package is not found through the theme). It then sends the standard
  `org.kde.KIconLoader.iconChanged` signal, because a plasmashell that started before that
  directory existed would otherwise keep showing the placeholder until you log out. For now the
  panel status icons still use the desktop's own update icons, on purpose, so Kempt looks like the
  rest of Plasma. The symbolic icons are there for the icon choice on the roadmap.
- **A popup that shows the most important answer straight away.** It has three fixed parts: a
  header with the pending count, a content area with any messages that apply followed by the list,
  and a footer with the date line on the left and the one action button on the right. The changes,
  in the order you meet them:
  **Update Now is hidden when there is nothing to update**, instead of showing greyed out. When
  everything is up to date there is no run to start, and a disabled main button looks like an
  offer being refused.
  **The status line shows when the counts were checked**: `Checked 4 min ago`, updating while the
  popup is open, with the exact time on hover. It adds `· 1 held` when anything is held. It shows
  `No successful check yet` when every check so far has failed, which is different from never
  having checked.
  **Version strings are never cut off.** They wrap onto a second line, because a version like
  `2:24.19.0-1nodesource` is what people compare between two machines, and the end is the part
  that differs. A package name too long for its row is shortened instead.
  **What the last run did is on screen** as `Last update 18 min ago · 4 packages`. It expands to
  the packages that run installed, with a **Show Log** button beside them. This comes from that
  run's own history entry through the new `kempt summary --json`, so the popup and
  `kempt summary` always agree about a run. Right after a run, a short-lived line says
  `Updated 4 packages in 2s`, `No package changes` or `Update failed: <the reason>`. Before, that
  spot showed the first line of `kempt summary`, which is an ISO timestamp and does not say what
  just happened.
  **Opening the popup starts a new check** when the last successful check is older than your check
  interval or five minutes, whichever is shorter. This does not block the popup and does not start
  a second check if one is already running.
  Every message that used to be stacked in the toolbar is now an inline message in the content
  area. That includes the offline recommendation, now named **Install on Next Restart** after what
  it does, rather than after the dnf5 flag behind it. **Check for Updates** is also a context
  action, so it appears in the system tray's *More actions* menu and the icon's right-click menu,
  not only on the popup's refresh button.
- **It tells you when a restart is needed, and never restarts on its own.** `kempt check` now
  writes `reboot_needed` to the state file. It says whether a restart is needed **right now**, and
  is worked out fresh on every check from local information only (a cache-only `needs-restarting`
  that uses no repositories, no network and no prompt). This is different from the
  `reboot_needed` in a history entry, which records whether a restart was needed when that run
  finished. A history entry keeps saying a restart is needed after you have restarted, and says
  nothing when the restart is needed because of a `sudo dnf5 upgrade` typed in a terminal. The new
  state file value clears itself, and also catches changes Kempt did not make. The popup shows it
  as one message, **Restart to apply installed updates**. Its **Restart…** button opens KDE's own
  restart prompt, which you can cancel and which gives your applications their usual chance to
  object. Kempt never restarts anything itself, in any state or with any setting. If the prompt
  cannot be opened, the reason is added to the message. The message appears in every state,
  including up to date, because a restart can be needed with nothing pending. Closing the message
  hides it for the rest of that Plasma session and saves nothing to disk. Saving it would mean
  remembering it across a restart, and a restart is exactly what clears the need. New setting
  `restart_reminder` (default on, shown on the settings page as **Remind me when a restart is
  needed**) turns off the message and the button. The status line still ends with
  `· restart pending`, because that is a fact about your machine, not a reminder. `kempt doctor`
  now names the command behind the restart check, so a restart check that always fails can be told
  apart from one that always gets an answer.
- **A man page**, installed into the user's man hierarchy: `man kempt`.
- **Documentation**: README, install guide, usage reference, configuration reference,
  architecture guide with a walkthrough for adding a backend, security model, roadmap,
  contributing guide, security policy and code of conduct.
- **A test suite that does not need the tools it tests.** 18 files and 2352 assertions. Every call
  that touches the system goes through an environment variable a test can point elsewhere (a
  "seam"), so the parsers run against
  recorded sample output, and the root-level paths are tested without dnf, flatpak, polkit or root.
  The widget is tested in two ways: every rule it uses to work out what to show is tested under
  node, and the real QML is run against a stand-in CLI by supervised PySide6 probes.
- **The two files needed to package Kempt, both tested for real.** An AppStream metainfo file, so
  a software centre can show a name, a summary, a screenshot and a release history. And
  `kempt.spec`, which was built, linted, installed and tested inside a Fedora 44 container. A
  packaged install puts the files under `/usr/share/kempt`, makes `/usr/bin/kempt` a symlink into
  that directory, moves the root helpers to `/usr/libexec`, and `kempt doctor` says
  `install: packaged`. Two bugs a first user would have hit were fixed along the way:
  `kempt --version` printed `kempt unknown` because `VERSION` was missing from the package, and
  `kempt enable-passwordless` had no rules template to fill in.
- **Every file that states a version now has to match.** `tests/test_version.sh` already tied the
  widget's `KPlugin.Version` to `VERSION`. It now also ties the metainfo's newest release and
  `kempt.spec`'s `Version:` to it. So a software centre cannot show a release the command line
  does not report, and `rpm -q kempt` cannot disagree with the program it installed. The git tag is
  the one version number still set by hand, and `docs/RELEASING.md` step 1 says so.

### Notes and known limitations

- Fedora and dnf5 only for now. Adding another distribution takes one new backend file, and the
  walkthrough is in [docs/architecture.md](docs/architecture.md#adding-a-backend-for-your-distro).
- Flatpak support covers system scope only. A system-wide `flatpak update` also updates runtimes,
  and the summary does not list those, so a run can change slightly more than it reports.
- A checkout install is a symlink into the git tree, and it depends on that tree, so keep the
  checkout where it is. The widget is the one exception: `kpackagetool6` copies it, so re-run
  `./install.sh` after changing `plasmoid/`. None of this applies to the RPM install, where the
  package manager owns every file.
- Developed under the name Upkeep and renamed to Kempt before any release, because two maintained
  Linux updaters already use that name.
- The dnf pending check reads text output. Moving it to `dnf5 check-update --json` is the planned
  next improvement for that backend.

[Unreleased]: https://github.com/erez-c137/kempt/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/erez-c137/kempt/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/erez-c137/kempt/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/erez-c137/kempt/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/erez-c137/kempt/releases/tag/v0.1.0
