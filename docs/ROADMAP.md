# Roadmap

Where Kempt is going, in order. Dates are deliberately absent - each stage ships when it
meets the bar of the one before it.

## Shipped - v0.1.x, public since 2026-09-03

Everything the v1 design specified is built, live-gated on real hardware, and released - on
GitHub, in COPR (Fedora 43 to 45 and rawhide, x86_64 and aarch64) and on the KDE Store:

- **The CLI**, code-complete, documented and audited: `check` and its state file, `update` across
  four surfaces, holds, history, snapshot-based summaries, `kempt log`, `kempt doctor`, the two
  root helpers and their two polkit actions.
- **The Plasma widget**: a system-tray entry by default, a badge that is the CLI's own actionable
  count and never a guess, per-row pins, and a settings page that is a front-end to `kempt config`
  with **durable writes** - Plasma's OK button destroys the page and SIGKILLs whatever it is still
  running, so every write that page dispatches now outlives the dialog closing.
- **An icon of its own**: the comb glyph, application icon plus 16px and 22px symbolics, installed
  into the user's hicolor theme so **Add Widgets** shows it.
- **The popup redesign** (Plan 3): header, message stack, list and footer; the restart reminder
  and its **Restart…** button, which opens KDE's own prompt and nothing else; the Last update row
  fed by `kempt summary --json`; a re-check on open when the numbers are stale; and Update Now
  hidden rather than greyed out when there is nothing to run.
- **A version, and one place it is written down.** `kempt --version` prints it, `kempt doctor`
  opens with it, and the widget's `metadata.json` is pinned to the same `VERSION` file by the test
  suite - so "which build is this?" has an answer in a bug report, and the two halves of the
  project cannot claim to be different releases of it.
- **The download size next to the button that starts it.** Shipped in 0.1.0. The popup footer
  reads `Checked 4 min ago · ~140 MB`, from metadata already on disk: about 1.4 s (dnf) and 0.12 s
  (flatpak) inside `kempt check`, with no depsolve, no network and no transaction, which is what
  keeps it away from dnfdragora's re-index-on-open and Discover's resolved-transaction stalls. It
  is an **estimate with error in both directions** (flatpak ships ostree deltas, dnf pulls
  dependencies `--upgrades` never lists), so it says `~` and never "up to", and it is dropped
  entirely rather than guessed when any item's size is unknown.
- **One network boundary, both backends.** Checks are read-only against local caches on the dnf
  and the Flatpak side alike, and every fetch happens in `maybe_refresh_metadata` - once every
  three hours, on mains power, on an unmetered link. A check on a train answers from what is
  already on disk instead of failing the whole Flatpak backend.

Every release gate - the live engine checklist, the widget's morning visual gate on real
hardware, the merge, and the public flip with CI - passed between 2026-09-02 and 2026-09-04.

**0.1.2** is mostly fixes, plus one addition: a warning when you hold a package after an update is
already staged for the next restart.

- **The command line and the widget are two packages**, `kempt` and `kempt-plasmoid`, so
  installing the command line no longer brings a desktop with it.
- **Computers far behind on updates work again.** A check stopped working at 925 pending updates
  and an update run at about 1,200 packages, because the package list was passed to a program as
  a single argument, which Linux limits to 128 KiB.
- **Kempt stops before doing the wrong thing** on an image-based Fedora (Silverblue, Kinoite,
  bootc), and when a Fedora release upgrade is already downloaded, which staging updates would
  cancel.
- **A staged update that can no longer install is reported,** in each of the three ways that can
  happen, and Kempt always keeps a record of an update it has staged.

**0.1.3** tightens what runs as root and gets the package ready for Fedora's review.

- **A downloaded Fedora release upgrade is protected by the root helper itself,** not only by the
  command line, so nothing running as the user can cancel, discard or start it without a prompt.
- **Passwordless mode installs exactly the rule it checked,** and only at its one fixed path.
- **The package passes the checks a Fedora reviewer runs:** the metainfo validator Fedora requires,
  rpmlint with no errors, and documentation limited to what someone using Kempt reads.

## Now

- **First contact.** The announcement wave, and treating every early report as the gift it
  is - what the first outside users hit outranks everything below.
- **0.1.5, ready to release.** Everything in it is built and on `main`. A finished run no longer
  offers to stage what it has just staged - the one bug an outside user would have hit on the very
  first staged update they made. A live run says which dnf transaction it was, so its summary
  reports that transaction's packages rather than everything that moved on the machine while it ran.
  Each part of a run has a heading, Flatpak end-of-life notices name the app that is affected and
  say whether anything needs doing, and `kempt doctor` says when Discover's update notifier also
  starts with the session. What it waits on is the screenshots below.
- **The road into the official Fedora repos**: a strict self-review against the packaging
  guidelines is done and its findings shipped in 0.1.3. The review tooling passes on the release;
  the review request is next, and it needs a sponsor.

## Next - 0.1.5

The work is done; this is the last thing between it and a release.

- **Re-capture the screenshots.** The two in the README, the metainfo and the store listing were
  taken on 4 September, before three releases. They show a popup with no Flatpak runtimes section
  and no way to discard a staged update, which is no longer what Kempt looks like. The metainfo
  already promises this re-capture, and asks for 16:9 while it happens, because software centres
  crop tall images badly. Needs a real desktop, so it waits for a session with one in front of it.

## 0.1.6 - reclaiming disk space

Held back from 0.1.5 deliberately, and not because it is blocked - it is not, any more. It is a new
setting, a new prompt and an action that removes things, and that deserves a release of its own
rather than a corner of one carrying five unrelated changes. The alternative was holding finished
work, including a bug an outside user would meet on their first staged update, behind a feature
measured in sessions.

- **Reclaiming the disk space updates leave behind.** Updating a Flatpak runtime does not replace the
  old one. It deploys the new version beside it, and the old copy stays until something removes it,
  so crossing a runtime series can leave two copies of a gigabyte-sized runtime on a machine with a
  single app installed. The command that clears it, `flatpak uninstall --unused`, is in no update
  tool's flow, and somebody who has never heard of a runtime will never type it. That is exactly the
  kind of maintenance step Kempt exists to take off people's hands.

  **One setting, three answers**, so the same feature suits somebody who never wants to think about
  it and somebody who wants to decide every time: `ask` when there is something worth reclaiming,
  showing the number and what makes it up (the default); `automatic`, for people who would rather it
  simply happened; and `off`. Nothing is ever removed until that choice has been made, once in the
  setting or there and then in the prompt. People who want finer control can name what is included;
  people who do not, never see that.

  **Updating does not leave old versions behind, with one exception, and that exception is the point.**
  Neither rpm nor flatpak hoards previous versions on disk: what accumulates is a download cache,
  which nobody needs, and Flatpak runtimes that no installed app requires any more. Both are safe to
  clear and both are what this feature is for. **Old kernels are the exception and Kempt leaves them
  alone.** dnf keeps the last few on purpose: a kernel that will not boot is exactly when you need the
  previous one, and reclaiming a few hundred megabytes is not worth a machine that cannot start. dnf
  already retires them on its own schedule and that is the right place for it.

  Two rules hold whatever the setting says: never anything an installed app depends on, and never
  Kempt's own opinion about what is unused - only what the package manager itself calls unused.

  One obstacle, smaller than it looked. There is still no `--dry-run`, and `flatpak list` has no
  `--unused` (checked against 1.18.2). Upstream has already been asked - flatpak/flatpak#5185, open
  since November 2022, labelled `help wanted` - and `libflatpak` already exposes the call such a
  listing would wrap (`flatpak_installation_list_unused_refs()`), so what is missing is plumbing,
  not a decision. A second request would only duplicate it; implementing that one is an option of
  its own, and a better use of the ask.

  What flatpak does have is an answer to the same question, and it is upstream's own. Run
  `flatpak uninstall --unused` with stdin or stdout not a terminal and it prints the whole table of
  what it would remove - with the pinned runtimes it would keep, and which installed apps use each
  runtime - and then answers `n` itself. That is not a behaviour to be discovered by experiment: it
  is unconditional in `flatpak_yes_no_prompt()` (`app/flatpak-tty-utils.c`), which returns no before
  any default is consulted, and it is in the 1.18.2 that ships today. So the list comes from flatpak
  itself, which is what the rule above requires, and nothing has to be estimated.

  One rule keeps that safe, and it is short enough to hold: **the probe never passes `-y` or
  `--noninteractive`**. `--noninteractive` implies `--assumeyes`
  (`app/flatpak-builtins-uninstall.c`), and those two flags are the only things that turn the
  listing into a removal.

## 0.2 - a second distribution

- **One file per package manager, for real.** Adding a backend today touches every row of the wiring
  table in `docs/architecture.md`, and following that table exactly still leaves gaps. A backend
  registry makes each package manager declare how it is detected, how it is labelled, how it applies
  and how it knows a restart is owed, so a new one is a file and its tests. The state file stays
  schema v1: backends are already keyed by name.
- **openSUSE first (#3).** zypper shares the rpm database Kempt already reads, has documented
  machine-readable output and exit codes, and keeps locked packages visible, which is how Kempt's
  holds already behave. Tumbleweed and Leap are told apart from `/etc/os-release`, because
  Tumbleweed updates with `zypper dup`. There is no offline staging there, so that surface is simply
  not offered, the way Flatpak already opts out of it.
- **Settings that name backends** (`disable`, `only`), adopted before the configuration grows around
  two backends rather than after.
- **Debian, Ubuntu (#1) and Arch (#2) come after the registry has proven itself.** apt needs
  decisions first: multiarch package names do not fit today's hold syntax.

## Before 1.0

1.0 is a promise that the public formats will not break and that the numbers are true. It ships when
all of these hold:

- No known way for the badge, a run, or the history to disagree with what the package manager
  actually did.
- The state file, the configuration keys, the exit codes and the history format are frozen and
  documented, shaped by at least two system package managers rather than one.
- What runs as root has been reviewed again at that release.
- People other than the author have used a release candidate, with no open report of lost data or a
  wrong count.

Being accepted into the official Fedora repos is not a condition, because that timeline belongs to
the review process. The package is kept review-clean at every release either way.

## v1.x - ready for other people

- **Panel icon choice.** The comb glyph now exists and ships: `plasmoid/contents/icons/` carries
  the app icon plus 16px and 22px symbolics, and `install.sh` puts the app icon into the user's
  hicolor theme, which is what makes **Add Widgets** show it. What it does *not* do yet is drive
  the panel: the compact representation still uses Breeze's `update-none` / `update-low` /
  `update-high`, deliberately, so Kempt looks like the rest of the desktop. The choice is a small
  curated set, never a free-for-all - (1) theme default (the icon theme's own update symbols,
  recolors with every color scheme; the right default for almost everyone), (2) the Kempt comb
  (symbolic, our identity), (3) a custom icon name via Plasma's standard icon picker for people
  who theme everything. Routed through `kempt config` (`widget_icon`, default `theme`) like every
  other setting; badge and state semantics never change with the icon.
  - When the comb option lands, the QML picks **`kempt-symbolic-16.svg` vs `kempt-symbolic.svg`
    by the snapped icon size** (`Logic.snapIconSize` already computes it: 16 gets the 16px
    artwork, everything larger gets the 22px one). `plasmoid/contents/icons/` is a FLAT directory
    and matches by file name only, so this is an explicit choice in the binding, not something
    the icon loader does. The alternative is installing the comb into a proper hicolor tree
    (`.../icons/hicolor/{16x16,22x22,scalable}/apps/`) and letting `QIcon::fromTheme` pick the
    size itself - more machinery, but it is the route the metadata icon already takes, since a
    package-local icon name does not resolve from the theme (measured on Plasma 6.7).
- **Translations. Kempt cannot be translated today, and it is worth being plain about that**,
  because the QML is full of `i18n()` calls (73 of them) and that looks like a tool which is
  ready for translators. It is not, for two separate reasons.

  The first is that there is no catalogue and no way to make one: no `.pot`, no `.po`, no
  extraction step, and no translation domain, so even the strings that ARE wrapped have nothing
  to be translated into. That half is ordinary work - a domain, `Messages.sh`, and extraction
  wired into the release.

  The second is the harder one. The popup's sentences are DERIVED rather than written: the counts,
  the footer dateline, the last-run row and the post-run line are all assembled in
  `plasmoid/contents/ui/logic.js`, which is plain JavaScript with no `i18n()` in it - the QML
  around it is wrapped, that file is not. Roughly fifteen to twenty sentences are built from parts
  and are therefore structurally untranslatable: word order is a language's business, and a
  sentence glued together in JavaScript has already decided it. Fixing that means giving logic.js
  a translation hook it can call in both of its worlds (a QML engine, and node under the tests),
  and turning the assembled phrases into whole `i18np()` sentences so a translator sees a sentence
  rather than fragments.

  Doing the first without the second would ship a half-translated popup, which reads worse than an
  English one. So they go together, and until they do the honest answer to "can I translate Kempt"
  is no.
- **A defer: "later", "tonight", "only on Wi-Fi".** Two of six user personas currently
  "handle" the popup by closing it, which is the worst outcome an updater can produce.
  One wants it because of what she is doing right now, the other because of what he is connected
  to right now.
- **A restart-reminder dismissal that survives the session.** Closing the restart message hides it
  for the rest of this plasmashell session and writes nothing down, because a dismissal on disk is
  a promise to remember it across a restart and a restart is precisely the event that clears the
  fact underneath it. Keeping that promise properly means storing the dismissal against the boot
  session, the way offline staging already gates its harvest on `current_boot_id`.
- **A spoken result after an action.** The keyboard-and-Orca persona gets no confirmation of
  anything today: Refresh, Update Now and the pin all act silently as far as a screen reader is
  concerned. Every icon-only control has an accessible name now (Refresh carries an explicit
  `Accessible.description`); what is missing is announcing the *outcome*, which is also what the
  sighted personas asked for in visual form.
- **Flatpak `--user` scope.** v1 is system scope only, and deliberately so: every flatpak command
  in `backends/flatpak.sh` names `--system`, so a per-user app surfaced by an unscoped check would
  be counted in the badge and then left untouched by the run. This got closer when the apply left
  the root helper: both flatpak arms run as you now, which is the only way a `--user` update could
  ever work at all. What is left is a scope decision - one setting, or both scopes every time -
  rather than a privilege problem.
- **Official Fedora repos, after COPR proves itself.** A Fedora package review (the spec already
  lints clean, which is the hard half of the opening position; the missing half is a sponsor).
  What it buys is concrete: `dnf install kempt` with no COPR step, and it makes a real one-click
  install honest - the PackageKit session API (`InstallPackageNames`, the Discover/GNOME
  "install missing thing" dialog) can only draw from repos that are already enabled, so a
  store-installed widget can only ever offer a working install button once the engine lives in
  Fedora proper. Until then the widget's Copy Commands button is the truthful ceiling.
  The route runs through a review request, a sponsorship, dist-git, and then the steady-state
  duties of a Fedora package.

- **Fedora Atomic (Silverblue, Kinoite, Bazzite, bootc images).** Half of this shipped in 0.1.2:
  Kempt detects those images and refuses to update them, rather than resolving a dnf transaction
  that resolves cleanly and then fails in the middle against a read-only `/usr`. The other half is
  a backend of their own, because rpm-ostree is a different update model and not a different
  command: a transaction there is an image deployment, and per-package holds do not map onto one.
  It gets built against `rpm-ostree status --json`, reporting beside the Flatpak half, which is
  the half of an Atomic desktop that dnf never owned and that already works.

  One thing has no answer yet, and it is not a porting problem: **holds do not map.** A package
  cannot be held out of an image that was built somewhere else, so the pin on every popup row is
  either absent there or lying, and deciding which is a design question rather than a backend.
  The sequence that avoids answering it too early is to make `kempt check` tell the truth on those
  images first - a pending deployment, the version it moves to, and the Flatpak list that already
  works - while `update` goes on refusing. That half is read-only and needs no new privilege.

## v2 - the differentiator release

- **Update Insights (flagship)**: per-update, per-THIS-machine warnings and
  recommendations from sourced facts only - dnf advisory/CVE classification with
  severity, a hardware-relevance map (lspci/lsmod: "mesa - affects your AMD GPU",
  kernel + akmod-nvidia = "driver rebuild on next boot"), session-impact detail, opt-in
  Fedora Bodhi karma. Never generated prose.
- **`dnf5 check-update --json`** migration - retires the text-parser bug class by
  construction.
- **apt and pacman backends** - the universal-updater vision becomes real, on the backend registry
  that 0.2 introduces.
- **Self-installed tools, narrowly and honestly.** A `tools` backend for programs a person
  downloaded for themselves as a single binary: the group nothing on a machine tracks, so nobody is
  ever told when they go stale. For those Kempt can tell the truth the way it means the word - the
  installed version read locally, the newest read from one upstream feed, a hold that works because
  holds are Kempt's own file, and an old-to-new report from the same before-and-after diff every
  other backend uses.

  **The refusal is the feature.** Anything a project, a lockfile, a language runtime or a version
  manager owns is reported as owned by something else and never touched. Kempt will not become "the
  one place you update everything", because every entry is a small contract with somebody else's
  release process, and a wrong entry produces a badge that lies.
- **Per-version holds** ("skip this one bad release, auto-clear on the next"),
  optional `dnf versionlock` integration, notification actions
  ("Install on Next Restart" from the toast itself). Flatpak user scope moved up to v1.x.
- **topgrade-style config vocabulary** (`disable`/`only`/`ignore_failures` per backend)
  adopted before the config grows organically.

## Beyond

- Other desktop environments via a StatusNotifierItem tray app sharing the same CLI.
- **Firmware via fwupd, maybe.** The one updater the popup does not count. It fits the model
  (fwupdmgr has a clean JSON-ish interface and its own staged-on-reboot semantics), but
  firmware failure modes are not package failure modes, so it earns its way in only after the
  distro backends prove the abstraction.
- Swap the deprecated `Plasma5Support.DataSource` executor when KDE ships the
  replacement (isolated in one QML file by design).
- Whatever the first outside users ask for loudest.
