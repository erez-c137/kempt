# Changelog

All notable changes to Kempt are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **A hold added after an offline update was staged is no longer a silent trap.** Stage an offline
  update, read something worrying about the kernel, run `kempt hold dnf:kernel-core`, and until now
  the restart installed it anyway and nothing said so. dnf5 built and stored that transaction before
  the hold existed and offers no way to edit a stored one, so the hold applies from the next update
  Kempt builds. The command now says exactly that on stderr and offers both remedies:
  `kempt update --surface=offline` to build the staged update again with your current holds, or
  `sudo dnf5 offline clean` to remove it. The hold is recorded either way and the command still
  exits 0: it warns, it never blocks, and it never asks a question. `kempt unhold` carries the
  mirror, for a package the staged update was built without.
- **The warning is honest about what it does not know.** Kempt reads the staged package list live
  from dnf5's own stored transaction (`/usr/lib/sysimage/libdnf5/offline/transaction.json`,
  world-readable by dnf5's design), so it sees the packages the resolver pulled in as well as the
  ones you asked for. Where that cannot be read, an older stage or a record this build does not
  recognise, it says "may still install" instead of staying quiet. It may be wrong by naming a
  package that is not in there; it is never allowed to be wrong by saying nothing about one that
  is. Flatpak holds are never involved: the offline surface stages dnf only.
- **The panel widget stops contradicting itself about a staged update you have held something in.**
  Stage an offline update, then pin `kernel-core` in the popup: the green "staged" banner used to
  stay put, with a live **Restart…** button, directly over the package you had just tried to keep
  out. It now turns into a warning written in your order of events, with both ways out and the cost
  of the button it offers: *You held kernel-core after the next-restart install was prepared, so it
  still installs. Rebuild it to skip kernel-core, or stop holding kernel-core to keep the current
  plan. Rebuilding asks for authorization; if it fails, nothing stays staged.* (With several:
  "kernel-core and 2 more".) Every restart button on screen stands down while that warning is up,
  the banner's own and the restart reminder's, because a restart there is the install you were
  trying to stop. One action is offered instead, **Rebuild Staged Update**, which runs the same
  command as **Install on Next Restart** with the same authorization prompt and no new command
  shape, and reuses dnf5's package cache rather than downloading again. Its tooltip is also its
  screen-reader description, so the cost is heard before the authorization dialog takes the focus,
  and the flip is carried by words rather than by colour. Where Kempt cannot read the staged list at
  all and you are holding dnf packages, the banner says the weaker true thing, that it may still
  install held packages, rather than the reassuring false one; with nothing held it stays green.
- **A click never spends stale consent.** A popup can sit open for an hour, and in that time a
  restart can apply the staged update or something can replace it. Pressing **Rebuild Staged
  Update** re-reads the state file first and acts only if the same staged update is still there and
  still conflicting; anything else runs nothing and says *The staged update changed since this was
  offered. Nothing was rebuilt; check the banner above.*
- **`kempt doctor` says when the staged update installs a package you have held.** The row leads
  with what happens, that it installs kernel-core on the next restart despite the hold, explains
  that the hold was recorded after the transaction was staged, and ends with both remedies. It is
  `info` and not a failure: the state is a legitimate one, and a report that fails on legitimate
  states teaches people to skip its failures.
- **`kempt doctor` fails when the staged update is not the one Kempt built.** It compares what
  Kempt recorded staging against dnf5's stored transaction and names what each side has that the
  other does not, up to four names each way. Anything running as you can replace an armed
  transaction inside polkit's retention window, and until now every Kempt surface would have gone
  on describing the set that was replaced.
- **`kempt doctor` reads the boot symlink `/system-update`, not just dnf5's transaction status.** A
  symlink left standing over a transaction that is not armed sends the next restart into the
  offline updater to install nothing; the report now says so and names `sudo dnf5 offline clean`,
  whether or not Kempt staged anything.
- **`kempt doctor` catches a split install, both halves of it.** It compares each polkit action's
  `exec.path` annotation with the helper path this CLI actually hands to pkexec: when the two
  disagree, a package installed over a checkout install or the reverse, pkexec has no matching
  action, so every privileged run falls back to an authentication dialog and a background check
  times out instead of answering. The report names both paths and the fix for each kind of install.
  It also names which `kempt` the panel widget would run: the widget looks in `~/.local/bin` first,
  so a leftover symlink there shadows a packaged `/usr/bin/kempt` for the panel and for nothing
  else, and the report you were reading described a different install from the one doing the work.
- **`state.json` carries the conflict for the widget.** `offline_staged` gains `holds_conflict`
  (the held packages the staged update will install anyway) and `names_source` (whether an empty
  list means "no conflict" or "cannot tell"). Both are additive, present only while a stage is
  armed, and readers must tolerate their absence.
- **The build proves itself.** The RPM runs the full bash test suite in its check stage, on a
  pristine copy of the tree, so a build root that cannot pass the suite cannot ship the package;
  proven in a Fedora rawhide mock build. A live container gate (`tests/live/run-offline-gate.sh`)
  runs the offline lifecycle against real dnf5 with failures injected, on demand. A new docs test fails the suite on a markdown table broken
  in two and on an environment seam the code reads that the architecture doc does not list.
- **For readers and contributors:** a ["Why bash"](docs/architecture.md#why-bash) section in the
  architecture doc, the recurring question answered once with its costs included, linked from the
  README and CONTRIBUTING; issue forms (the bug report asks for `kempt doctor` output and how Kempt
  was installed), a pull request template, and dependabot watching the CI action pins.

### Changed

- **The panel widget's per-package pin is a padlock:** open on a package that is pending, closed on
  one you are holding. The pushpin it replaces is Plasma's own "Keep Open" icon, the pin in the
  system tray heading, in the calendar popup and in the folder-view popup, three shipped uses with
  one meaning, and Kempt drew a whole column of them directly underneath the tray's. The crossed-out
  version used for held rows draws its slash in the colour scheme's negative red, so the packages
  you had deliberately protected carried the popup's only red mark and read as cancelled. The
  padlock shows the state rather than the action, and the state is also in words: a **Held** token
  before the version, a button that says *Hold glibc at 2.41-3.fc44* or *Stop holding glibc*
  rather than "Hold glibc at its current version", and a line under the Held group saying that a
  hold is Kempt's list only, which `sudo dnf upgrade` does not know about. Held rows no longer dim,
  which was a contrast reduction applied to exactly the rows somebody chose to keep.
- **A staged update changes what the top of the popup says.** The header reads *23 updates staged
  for the next restart* instead of counting the same 23 as available, the panel tooltip says the
  same on hover, and **Update Now** is hidden while the stage is armed, since it was lit directly
  under a banner saying those updates were already waiting and pressing it started them again,
  live. The badge keeps the true count: those packages really are still pending until the restart
  runs.
- **The kernel notice is information, and says what its own button does.** *This update includes a
  kernel. The safest way is to install it on the next restart, so nothing changes under the running
  desktop.* It used to read "This includes a kernel update. Restart when it finishes." in amber,
  over a button offering the opposite path, before anything had started. **Install on Next
  Restart** takes the software-update icon; the reboot icon is **Restart…**'s alone, so two
  adjacent restart-shaped actions stop sharing a glyph.
- **The updating pane says where the run actually is:** *Updating in a terminal window…*,
  *Updating in the background…*, *Updating…*, or *Preparing the install for the next restart…*,
  instead of naming the configured surface in a word ("surface") that appears nowhere else a person
  can see. It carries **Not updating? Check again**, and keyboard focus moves to that button when
  the pane appears and back to a real control when it goes; it used to stay on the hidden
  **Update Now**.
- **A package that is not installed yet reads `new → 1.0-1.fc44`** in the list and in the last
  update's package list, instead of `? → 1.0-1.fc44`, which looked like the widget not knowing.
- **The number of updates a staged transaction carries is worked out by a check made just before
  staging,** instead of being copied out of the last check's `state.json`. It is the one thing
  anyone is ever told about a transaction they cannot open, and it used to be whatever figure
  happened to be lying around, written by another check against different metadata, possibly days
  earlier. A check that cannot answer warns and the stage goes ahead on the old number.
- **Two bounds of the offline path are written down** in
  [docs/security.md](docs/security.md#accepted-limitations) rather than left implicit: inside
  polkit's retention window a process running as you can replace the armed transaction without a
  prompt, and dnf5 stores the staged package list world-readable, so what a machine is about to
  install is public on that machine by dnf5's design.
- **The documentation describes the install most people actually have.** Every sentence that names
  a path, a verify step or an uninstall command says which kind of install it is about, and gives
  both where both exist: from the package the root helpers are in `/usr/libexec`, the CLI is
  `/usr/bin/kempt` (a symlink into `/usr/share/kempt`), the widget is under
  `/usr/share/plasma/plasmoids`, and it uninstalls with `sudo dnf remove kempt`; from a checkout
  those are `/usr/local/libexec`, `~/.local/bin/kempt`, `~/.local/share/plasma/plasmoids` and
  `./install.sh --uninstall`. The install guide gained the packaged install end to end, with a real
  `kempt doctor` report from a packaged box and the fact that the widget is already in your tray,
  so adding it from Add Widgets as well is what gives people two Kempt icons. SECURITY.md opens
  with the fact that nothing Kempt installs is setuid and every escalation goes through polkit, and
  says which versions are supported. The man page, the security doc and the release checklist
  caught up with the CLI and the COPR that exist.
- **The RPM License field is `MIT AND CC0-1.0`:** the packaged AppStream metainfo is CC0-1.0 by
  freedesktop convention, and the field now says so.
- **The roadmap opens with what shipped** instead of a finished to-do list, and gained honest
  entries for Fedora Atomic and fwupd. Working notes that were never the project's (posting drafts,
  store-ops records, outreach strategy) moved out of the repository entirely; what stays under
  `docs/plans/`, `docs/specs/` and `docs/research/` is the dated working archive CONTRIBUTING.md
  names as such.

### Fixed

- **Closing the update terminal, or answering its risky-transaction question with `abort`, no
  longer leaves the widget stuck on an empty updating pane for up to three hours.** Both of those
  exits used to end the run without writing anything down, and a new `state.json` is the only thing
  that takes the popup out of its updating state, so the package list, **Update Now** and
  **Refresh** all disappeared until a three-hour guard gave up. The terminal now re-checks on its
  way out on every exit path, including the window being closed under it, so the run ends when the
  terminal does. The exit status is still the update's.
- **Pressing a package's padlock no longer feels like a mistake.** Every pin in the list used to go
  inert on the press, and Qt takes keyboard focus away from a control the moment it is disabled, so
  30 ms after Space the keyboard was on an anonymous container with nothing to say. The row went on
  offering "Hold", and a second press really did send a second `kempt hold` to the CLI. Then the
  list snapped to the top, the row reappeared under **Held** below the fold, and nothing was said in
  any channel. Now only the *other* rows stand down; the one you pressed keeps its button, keeps the
  keyboard, shows a spinner in place of its padlock, and refuses a second press itself. When the
  follow-up check lands the keyboard follows that package into its new group, a mouse press leaves
  the list exactly where you left it, and the popup says *Holding kernel-core* out loud for a screen
  reader. A hold that fails is reported in its own row, under the version, instead of as a message
  at the top of the popup.
- **The popup shows at most two messages at once.** Five of them left the pending list 95 px tall at
  the default size, and at the minimum size pushed it off the popup entirely: they sit outside the
  scrolling area, so nothing scrolled and the list was simply gone. A failed check folds into the
  footer (`Checked 2 hours ago · last check failed`, with the reason in the Refresh button's
  tooltip), the post-run line and a failed button press share one slot, and anything the cap
  displaces shows nothing rather than stacking below the fold. A displaced restart is never lost:
  the footer says `restart pending` whenever its message is not the thing carrying it.
- **Update Now no longer starts two runs.** `kempt run` takes up to fifteen seconds to launch a
  surface and return, and a double press opened two terminal windows, both asking whether to update
  a running desktop. It now refuses with a spinner from the press until the CLI comes back.
- **The popup reaches a screen reader as it reaches the eye.** The **Held** group heading arrives
  as a heading with a name (Kirigami's own section header marks its label ignored), the header over
  a held-only list says *Up to date · 2 held* rather than *Up to date* over rows with waiting
  versions in them, the panel tooltip says `restart pending` when one is owed, and Enter activates
  the padlock, Update Now and Refresh, which previously answered only to Space.
- **The panel icon stops using Breeze's `update-high` for its own failures.** Plasma's own notifier
  uses that icon for security updates, so it promised security fixes and delivered "Kempt cannot
  check for updates"; the warning emblem it already draws carries the error instead.
- **The message you get when the terminal emulator is not installed says what to do** in the
  widget's words instead of a bare shell incantation: "Kempt could not find konsole. Install it, or
  run updates another way: kempt config set surface background (Settings > Run updates in > In the
  background)". `kempt doctor` quotes the same remedy. The exit status is still 4.
- **A failed rebuild no longer strands a partial stage behind a live boot symlink, and no longer
  discards a stage dnf5 kept.** Two things can happen when a re-stage fails, and the live container
  gate measured both against real dnf5. A download that cannot complete fails before dnf5 touches
  the previous transaction, which stays armed and installs on the next restart exactly as before:
  Kempt now leaves it alone, fails the run saying the previous one is unchanged, and keeps the
  conflict on screen so you can try again. A stage that dnf5 got far enough to store replaces the
  previous transaction first, so a failure after that leaves a partial stage nothing arms with the
  old boot symlink standing: the next restart went into the offline updater, installed nothing, and
  came back with no trace anywhere. Kempt now discards that partial stage, removes its marker, and
  fails the run saying the previous staged update was discarded. If that cleanup fails too, the
  marker is kept for `kempt doctor` and the notification carries `sudo dnf5 offline clean`, as it
  now does for a failed arm whose cleanup failed, where the command used to appear only on stderr,
  which nobody reads when the run was started from the panel.
- **A restart that could not install the staged update is announced instead of the banner just
  vanishing.** The popup's staged line disappears the moment the transaction stops being armed, and
  that used to be all that happened: no notification, no event, and a marker waiting forever for an
  apply that was never coming. The next check now says it once, "Your staged update can no longer
  install on a restart. Re-stage it, or run sudo dnf5 offline clean.", and demotes the marker rather
  than deleting it, so `kempt doctor` keeps the precise diagnosis instead of reporting the
  transaction as somebody else's.
- **A staged update is no longer disowned by a badly timed check.** The offline marker is written
  atomically and mode 0600 (it lists what the next restart installs, so it joins `state.json` and
  the event log as private), and a marker that reads back empty, unparsable or absurdly large is
  skipped by every reader instead of being deleted as a stage that has gone. `kempt doctor` reads
  the marker the same way and says when it cannot be read, instead of describing a pending install
  off a file it could not parse.
- **Settings and holds no longer lose each other when two commands write at once.** `kempt config
  set`, `kempt hold` and `kempt unhold` each read the whole file, changed their own line and wrote
  the file back, so two running together kept only the last one's change; measured on the old code,
  40 overlapping `config set` commands left 4 settings and 40 overlapping `unhold` commands removed
  4 holds. The widget runs its own commands one at a time, so the settings page could not trip this
  by itself; two terminals, a script, or the CLI racing the widget could. The three commands now
  take a lock across the read and the write; reading takes no lock.
- **Warnings no longer disappear after the first setting or hold a command writes.** Releasing that
  lock closed its file descriptor with a form of `exec` that also pointed the whole process's error
  output at nothing, permanently, so anything Kempt tried to tell you after a `kempt config set`,
  `kempt hold` or `kempt unhold` was written into the void, with nothing failing and nothing logged.
- **A box without diffutils no longer misreads its own staged update.** On a minimal Fedora image
  (a container, a server install) `cmp` is absent, and Kempt compared its package snapshots with
  `cmp -s`, taking a missing command's exit status for "the files differ": an unchanged box was
  harvested across a restart as "applied, no package changes" with its marker deleted, a live
  update over a staged one was not detected, and `kempt doctor` reported every helper as drifted
  from the checkout. Found by the new live container gate under `tests/live/`, which runs the
  whole offline lifecycle against real dnf5 in a throwaway container with failures injected at the
  stage, the cleanup and the arm. Comparisons now need only coreutils.
- **The test suite runs green from a release tarball,** not only a git checkout: the doctor version
  assertion no longer assumes git history, and the log test stubs its terminal emulator instead of
  leaning on the CI workflow's shim.
- **Something else updating your packages is no longer mistaken for your staged update
  installing.** If `dnf-automatic`, GNOME Software or a terminal `sudo dnf5 upgrade` changed
  anything between staging an offline update and the next boot, Kempt announced "Staged updates
  were applied on reboot", wrote a history entry naming the other tool's packages, and deleted its
  own record - while the staged transaction sat there, still armed, still going to install on the
  next restart, with every surface now silent about it. An applied offline transaction removes
  dnf5's stored transaction, its `transaction.json` and `/system-update`; while any of that is
  still present the update has not run, and Kempt now waits instead of claiming otherwise.
- **A staged update that can no longer install says so, instead of being promised forever.** Being
  armed is two things: dnf5's `ready` status and the `/system-update` symlink. Kempt read only the
  status, so a transaction whose symlink was gone was advertised as "installs on the next restart"
  after every restart, indefinitely, with `kempt doctor` reporting the box as healthy. It is now
  announced once, demoted, and given a doctor row that names the fix. **This is easy to hit:
  running `sudo dnf5 install <anything>` while an update is staged removes that symlink and leaves
  the status at `ready`** - dnf5's behaviour, documented nowhere, found by running the real thing.
  Re-stage with `kempt update --surface=offline`, or clear it with `sudo dnf5 offline clean`.
- **`kempt doctor` stops certifying a packaged install whose update path has been redirected.**
  Three lines in `~/.config/environment.d` pointing Kempt's helper seams at `/bin/true` made
  `kempt update` report "0 updated" having run nothing, the widget stay green, and doctor say "all
  checks passed" - a box silently no longer taking security updates, certified by its own
  diagnostic. A checkout install catches this by comparing files against the tree; a packaged one
  has no tree to compare, so it now names the override instead.
- **The check in front of passwordless updates tests the rendered rule for equality**, rather than
  looking for the clauses it ought to contain. Presence tests catch a rule that loses something and
  are blind to one that gains something: a template carrying the required scope clause, the correct
  action id and a single rule block, plus an unconditional grant inside that same block, passed
  every check and would have installed passwordless root for every polkit action from any session.
- **The panel widget is now its own package.** `kempt` is the command-line half, the root helpers
  and the polkit action; `kempt-plasmoid` is the widget and requires both. `sudo dnf install kempt`
  used to pull in `plasma-workspace` and with it 787 packages and 2.9 GB - a desktop, onto whatever
  asked for an update tool. A box already running Plasma still gets the widget automatically.
  **Upgrading from 0.1.1: if the widget disappears from your panel, `sudo dnf install
  kempt-plasmoid` puts it back.**
- **The package declares what it actually runs.** `dnf5 needs-restarting` lives in `dnf5-plugins`,
  not in `dnf5`, and without it the restart reminder was permanently silent - a restart owed after
  a kernel update was never offered. `notify-send` is how every background run reports what it did
  and was declared nowhere. `konsole` is what the default surface launches, and being merely
  suggested meant `kempt doctor` reported a failure on a fresh, correct install - the first command
  the documentation tells you to run. It passes now, checked from the installed package.
- **The README you get with the package is no longer a table of dead links,** and the page that
  explains what was installed and how to remove it is shipped at all: `/usr/share/doc/kempt/`
  carries the documentation tree, so 15 of its 17 links resolve on the machine, against 1 before.
- **A checkout under a path containing an apostrophe can run updates.** The terminal wrapper
  hand-quoted the path, so the quote closed early and **Update Now** opened a window that did
  nothing at all.
- **The test suite no longer needs `ps`**, which is in neither the package's build requirements nor
  Fedora's minimal build root, so every package build of 0.1.2 would have failed its own test
  stage. And a test that killed a slow writer killed only half of it: the survivor finished its
  write seconds later, into a sandbox that had already moved on - the source of both a stray error
  line in CI output and the intermittent failures that never reproduced afterwards.

## [0.1.1] - 2026-09-04

### Changed

- **Kempt is installable.** The COPR repository is live and green, so the README leads with
  `sudo dnf copr enable erez-c137/kempt && sudo dnf install kempt` and the checkout install
  becomes the development path. Verified the way a stranger would hit it: both commands in a
  clean Fedora 44 container, ending at `kempt 0.1.0`.

### Fixed

- **A widget installed from the KDE Store now says what to do next.** The store carries the
  plasmoid and nothing else, so the first check on a store install ran against no CLI at all -
  and the popup quoted the shell straight back at the user, `sh: line 1: kempt: command not
  found`, over a `kempt doctor` line that could not possibly work, because `kempt` was the thing
  that was missing. That was the first impression of Kempt for anyone who found the widget
  before the package. The widget now reads the exit code rather than the message (127 for a
  command that is not there, 126 for one that is there and cannot be run), treats it as a setup
  step and not a failure - the panel icon stays dim, no warning emblem, no invented count - and
  shows the two commands that install the engine, plus where to go on a system that is not
  Fedora. A **Copy Commands** button puts them on the clipboard as one chained line, because an
  InlineMessage's text cannot be selected and a retyped command fails somewhere the reader then
  has to debug. This is the ceiling for a COPR-distributed package: the one-click install the
  PackageKit session API offers can only draw from repos already enabled, which is exactly what
  a COPR is not - official Fedora packaging (on the roadmap) is what raises it.
- **`kempt doctor` catches the store copy that shadows a packaged widget.** `kpackagetool6`
  installs the widget into your home directory, the RPM installs it into `/usr/share`, and
  Plasma prefers yours. So a widget installed from the store before the package went on being
  the one Plasma loaded, and every package update after that landed in a directory nothing
  reads: silently, permanently, and with the old copy still rendering perfectly. On a packaged
  install doctor now fails on a user copy, says what it costs, and prints the two commands that
  clear it. `docs/install.md` covers the store-first order end to end, including what the widget
  shows before the engine is there.

## [0.1.0] - 2026-09-03

The first working version of Kempt: the complete command-line tool, its root helpers, its
installer and its documentation, and the Plasma panel widget that sits on top of them.

### Added

- **One command that knows what is pending.** `kempt check` queries dnf5 and Flatpak and writes
  a documented JSON state file (schema v1) listing every pending item, the version installed and
  the version it would move to. It reads the same root metadata cache the update itself uses, so
  the count and the update cannot disagree.
- **A check that answers offline.** Both backends read local caches only, and every network fetch
  happens in one step that runs at most every three hours, on mains power, over an unmetered
  connection. On a train, behind a captive portal or on battery, `kempt check` still says what is
  pending instead of reporting the Flatpak side stale. The Flatpak half of that fetch runs as you,
  with no privilege escalation of any kind.
- **A version you can quote in a bug report.** `kempt --version` (also `kempt version` and
  `kempt -V`) prints the release, and `kempt doctor` opens with it and the checkout it came from.
  One `VERSION` file is the source of truth: the panel widget is pinned to it by the test suite,
  so the CLI and the widget cannot report different releases of the same install.
- **How big the download is, next to the button that starts it.** The popup footer reads
  `Checked 4 min ago · ~140 MB` and the tooltip says `~140 MB to download`, so pressing Update
  Now on a metered link is an informed decision. The figure comes from metadata already on disk -
  no dependency resolution, no network, nothing on popup open - and it is honest about being an
  estimate: it says `~`, never "up to", it excludes held packages, it omits dependencies dnf will
  pull in, and it over-counts Flatpak, which transfers less than it advertises. When the number
  is not known the surfaces show nothing at all rather than `0 MB`.
- **Holds that skip but still notify.** `kempt hold dnf:kernel-core` keeps a package out of
  every Kempt run while it stays visible as pending, out of the actionable count, and named in
  each run's `Held (skipped)` line.
- **Four run surfaces.** Terminal with live output, in-popup, silent background, and offline
  staging, which downloads the transaction and arms it so the next restart of any kind installs
  it, the way Fedora recommends. The staged result is harvested into normal history after that
  restart, gated on the boot session so no other package change can be mistaken for it. While a
  transaction is staged the popup says so in one green line instead of offering to stage it
  again; a live update discards a stage it has invalidated rather than leaving a doomed
  transaction armed; and `kempt doctor` names a stage that can never install, with the command
  that clears it.
- **A recommendation, never a veto, for risky transactions.** When a pending update touches
  session-critical packages, an interactive run offers to update live, stage it for the next
  reboot, or abort, and defaults to abort. Detached runs send a heads-up notification and
  proceed. The same list is published to the state file as `risky_pending`.
- **Summaries built from before-and-after package snapshots**, not from parsing transaction
  output: old to new versions, installs, removals, held items, duration and a reboot verdict,
  rendered by one renderer for the terminal, the notifications and the widget alike.
- **History and logs.** One JSON entry and one raw log per run, pruned automatically: the newest
  50 entries are kept and logs are dropped after 60 days.
- **An event log, and `kempt log` to read it.** One line per thing Kempt did - a setting changed
  and what it replaced, a hold added or removed, a check and its counts, a metadata refresh, a
  run starting and how it ended, a transaction staged, a staged transaction harvested after the
  reboot, a passwordless grant attempted - each stamped `widget` or `cli` so a change made in the
  panel is distinguishable from one typed in a terminal. The per-run logs say what the package
  manager printed and the history says what a run changed; nothing said whether the thing you
  just did actually happened, which is the question people actually ask. Mode 0600, self-pruning
  past 2500 lines, and the last five lines are appended to `kempt doctor`.
- **A refused authentication says so.** When a run or a check fails because the authentication
  dialog was declined or closed, the summary, the notification, `kempt history`, the state file
  and the event log all say `authentication declined or cancelled` instead of pkexec's
  "Error executing command as another user: Not authorized", which reads as a broken install.
  The raw wording is kept in the run log, which is evidence rather than a summary. Failed runs
  now carry their reason in the history entry, so a summary explains the failure instead of
  pointing at a log file.
- **Scoped root privileges.** Two polkit actions and two argument-validating root helpers, so a
  cheap metadata refresh can never share a cached authorization with a system upgrade. Optional
  passwordless mode is a single rule for a single action, limited to an active local session.
- **No password for a Flatpak-only update.** Updating Flatpak apps needs no root: Flatpak's own
  policy grants a system app update to an active local session without asking. Kempt used to send
  it through the root helper anyway, so a run with nothing but app updates in it raised an
  authentication dialog that plain `flatpak update` never raises. It now runs as you. Two cases
  can still ask: an update that has to install a brand new runtime, and a run started over SSH
  rather than at the machine. `kempt-apply` is dnf's alone, and refuses the old verb.
- **An installer that explains itself.** `install.sh` does one authentication prompt, says
  exactly what it put where, stages unprivileged with `--destdir`, reverses itself with
  `--uninstall`, and offers (never assumes) disabling Discover's notifier, which otherwise
  duplicates notifications and holds the dnf5 lock.
- **`kempt doctor`, a checkup that says what is wrong.** One line per check for the two root
  helpers, the polkit action, `jq`, the terminal emulator, flatpak, the config file's syntax, a
  writable state directory and an intact checkout; exit 1 if anything failed. It exists because
  everything else degrades instead of crashing: with the root helpers missing, `check` exits 0
  with a stale state and nothing pending, which reads as "up to date".
- **A pull you forgot to install cannot hide.** `kempt doctor` ends with the commit the checkout
  is on, and with `helpers:`, `policy:` and `widget:` lines comparing each installed copy against
  it. A checkout install is only half live: the CLI is a symlink, so `git pull` moves it at once,
  while the root helpers, the polkit action and the widget package are copies that change only
  when `./install.sh` runs. `DIFFER` names that gap and the command that closes it. An install
  that did not come from a checkout prints `install: packaged` and compares nothing, because the
  package manager keeps those files in step. The procedure that goes with it is
  [docs/RELEASING.md](docs/RELEASING.md), which also says why Kempt has no self-update code and
  never will: a packaged Kempt is updated by the package manager it manages, and shows up in its
  own popup like anything else that is pending.
- **A panel widget that tells the truth.** A Plasma 6 applet whose badge is the CLI's own
  actionable count and never a guess: no data reads as "no data", not as zero, and a failed check
  keeps the last known numbers with the reason in the tooltip instead of raising an alarm about a
  repo that flapped once. The popup lists what is pending and what is held, updates in one click,
  offers the offline staging recommendation where you can act on it, and pins packages in place.
  Its settings page is a front-end to `kempt config` with no second copy of any setting, so the
  panel and the terminal can never disagree; a change made either way reaches the other within 30
  seconds. The widget shells out to the CLI for everything and contains no package-manager
  knowledge of its own; every command it runs goes through one component with a hard timeout, so
  a slow `dnf` can never freeze the panel. `install.sh` installs and removes it, and where it
  lives stays your decision.
- **One check per run, not three.** The widget watches the package databases and its own state
  file every 30 seconds, so a `dnf upgrade` typed in a terminal reaches the panel without being
  asked. It no longer reacts to its own wake: an update rewrites the package database all the way
  through the transaction and the state file on the way out, which used to leave three
  `widget check ok` lines in `kempt log` inside 40 seconds, two of them describing nothing. For a
  minute after a check finishes the watcher stays quiet. Refresh, the scheduled check, opening the
  popup and a settings change are all exempt.
- **It sits in the system tray, next to everything else that watches your machine.** Kempt
  declares itself a tray entry under *System Services* and is enabled there by default, so
  installing it is all it takes - no dragging it onto a panel, and inside the tray it is exactly
  the size of its neighbours. Adding it to a panel directly still works and is still supported;
  the tray is simply where an update notifier belongs.
- **A panel icon sized to match its neighbours.** Standalone on a panel, the icon is drawn at the
  size the system tray uses for that panel thickness - 22 px on every ordinary panel, Plasma's
  44 px default included - rather than filling its cell, which made it stand a head taller than
  every tray icon beside it. `widget_icon_size` (Automatic, Small, Medium, Large, also on the
  settings page) overrides that where the judgement is wrong; a size the panel cannot fit falls
  back to Automatic, so inside the tray the tray's own slot always wins, and Large is never smaller
  than Automatic. The count badge is drawn against the icon rather than the cell, so it stays
  legible and stays where the glyph is - and below the 22 px step it is left off rather than drawn
  at a size nothing can be read at, with the tooltip carrying the exact count.
- **An icon of its own.** A comb glyph: the application icon plus 22px and 16px symbolics ship
  inside the widget package, and `install.sh` also puts the application icon into the user's
  hicolor theme, which is what makes **Add Widgets** show it (a package-local icon name does not
  resolve from the theme) - followed by the standard `org.kde.KIconLoader.iconChanged` signal,
  because a plasmashell that started before that directory existed will otherwise go on drawing
  the placeholder until you log out. The panel states themselves stay on the desktop's own update icons for
  now, deliberately, so Kempt looks like the rest of Plasma; the symbolics are there for the icon
  choice on the roadmap.
- **A popup that answers the first question in the first second.** It is three parts now and they
  never move: a header carrying the pending count, a content area carrying every message that
  applies and then the list, and a footer with the dateline on the left and the one button that
  acts on the right. What that fixes, in the order a person meets it. **Update Now disappears when
  there is nothing to run** instead of sitting there greyed out, because an up-to-date box has no
  run to start and a disabled primary button is an offer being refused rather than an offer never
  made. **The status line dates the counts** - `Checked 4 min ago`, ticking while the popup is
  open, with the exact stamp on hover, `· 1 held` when anything is held, and `No successful check
  yet` on a box whose every check so far has failed, which is not the same thing as one that has
  never checked. **Version strings are never truncated**: they wrap onto a second line, because
  `2:24.19.0-1nodesource` is the line people compare between two machines and the tail is the half
  that differs; a package name too long for its row elides instead. **What the last run did is on
  screen** as `Last update 18 min ago · 4 packages`, expanding to the packages that run actually
  installed with a **Show Log** beside them - taken from that run's own history entry through the
  new `kempt summary --json`, so the popup and `kempt summary` cannot tell two stories about one
  run. Right after a run, a transient line says `Updated 4 packages in 2s`, `No package changes`
  or `Update failed: <the reason>`; it replaces what used to be pasted there, which was the first
  line of `kempt summary` - an ISO timestamp, true and no answer at all to "what just happened?".
  **Opening the popup re-checks** when the last successful check is older than the smaller of your
  interval and five minutes, without blocking and without starting a second check alongside one
  already running. Every message that used to be stacked in the toolbar is an inline message in
  the content area, the offline recommendation among them, renamed **Install on Next Restart**
  after what it does to you rather than after the dnf5 flag that implements it. **Check for
  Updates** is also a contextual action, so it is in the system tray's *More actions* menu and the
  icon's right-click menu, not only on the popup's own refresh button.
- **It says when a restart is owed, and it never performs one.** `kempt check` now records
  `reboot_needed` in the state file: whether a restart is owed **right now**, asked fresh on every
  check from local facts only (a cache-only, repo-less `needs-restarting`, no network and no
  prompt). That is a different question from the `reboot_needed` in a history entry, which records
  whether one was owed when a particular run finished - a history entry goes on claiming a restart
  long after you have performed one, and says nothing at all when the restart is owed because of a
  `sudo dnf5 upgrade` typed in a terminal. The live key clears itself and notices what Kempt did
  not do. The popup turns it into one message, **Restart to apply installed updates**, whose
  **Restart…** button opens KDE's own restart prompt - cancellable, with your applications given
  their usual chance to object. Kempt never restarts anything itself, in any state, with any
  setting, and if the prompt cannot be opened the reason is added to the message rather than
  swallowed. The message is shown in every state including up to date, because you can owe a
  restart with nothing pending. Closing it puts it away for the rest of that Plasma session and
  writes nothing down: a dismissal on disk is a promise to remember it across a restart, and a
  restart is exactly the event that clears the fact underneath it. New setting
  `restart_reminder` (default on, and on the settings page as **Remind me when a restart is
  needed**) turns the message and the button off; the status line still ends `· restart pending`,
  because that is a fact about your machine rather than a reminder. `kempt doctor` now names the
  command behind the verdict, since a permanently broken reboot check would otherwise look exactly
  like a permanently answered one.
- **A man page**, installed into the user's man hierarchy: `man kempt`.
- **Documentation**: README, install guide, usage reference, configuration reference,
  architecture guide with a walkthrough for adding a backend, security model, roadmap,
  contributing guide, security policy and code of conduct.
- **A test suite that needs none of the tools it drives.** 18 files and 2352 assertions: every
  impure call goes through an environment seam, so the parsers run against recorded fixtures and
  the privileged paths are tested without dnf, flatpak, polkit or root. The widget is covered
  twice over - every derivation rule under node, and the real QML executed against a stubbed CLI
  by supervised PySide6 probes.
- **The two files a packaged Kempt needs, both run rather than drafted.** An AppStream metainfo,
  so a software centre has a name, a summary, a screenshot and a release history to show instead
  of nothing; and `kempt.spec`, which was built, linted, installed and smoke-tested inside a
  Fedora 44 container before it was believed. A packaged install puts the tree under
  `/usr/share/kempt` with `/usr/bin/kempt` as a symlink into it, moves the root helpers to
  `/usr/libexec`, and `kempt doctor` says `install: packaged`. Building it that way found two
  bugs a first user would have hit: `kempt --version` printed `kempt unknown` because `VERSION`
  was not in the package, and `kempt enable-passwordless` had no rules template to render. The
  transcript is [docs/research/2026-09-02-rpm-spec-verification.md](docs/research/2026-09-02-rpm-spec-verification.md).
- **The version agreement now covers every file that states one.** `tests/test_version.sh` already
  pinned the widget's `KPlugin.Version` to `VERSION`; it pins the metainfo's newest release and
  `kempt.spec`'s `Version:` to it as well. A software centre cannot advertise a release the CLI
  does not report, and `rpm -q kempt` cannot disagree with the binary it installed. The git tag is
  the one number still left to a human, and `docs/RELEASING.md` step 1 says so.

### Notes and known limitations

- Fedora and dnf5 only for now. Adding another distribution is one new backend file, and the
  walkthrough for it is [docs/architecture.md](docs/architecture.md#adding-a-backend-for-your-distro).
- Flatpak support is system scope only. A system-wide `flatpak update` also updates runtimes,
  which the summary does not itemize, so a run can change slightly more than it reports.
- A checkout install is a symlink into the git tree, which stays load-bearing: keep the
  checkout where it is. The widget is the one exception: `kpackagetool6` copies it, so re-run
  `./install.sh` after changing `plasmoid/`. The RPM install has none of these properties - the
  package manager owns every file.
- Developed under the name Upkeep; renamed to Kempt before anything was released, because two
  maintained Linux updaters already answer to the old name.
- The dnf pending check parses text output. Migrating it to `dnf5 check-update --json` is the
  designated next upgrade for that backend.
