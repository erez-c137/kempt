# Roadmap

Where Kempt is going, in order. Dates are deliberately absent - each stage ships when it
meets the bar of the one before it. Deferred-item details live in the spec's v2 section
(`docs/specs/2026-08-24-kempt-design.md`); this page is the ordered view.

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
- **One network boundary, both backends.** Checks are read-only against local caches on the dnf
  and the Flatpak side alike, and every fetch happens in `maybe_refresh_metadata` - once every
  three hours, on mains power, on an unmetered link. A check on a train answers from what is
  already on disk instead of failing the whole Flatpak backend.

Every release gate - the live engine checklist, the widget's morning visual gate on real
hardware, the merge, and the public flip with CI - passed between 2026-09-02 and 2026-09-04.

## Now

- **First contact.** The announcement wave, and treating every early report as the gift it
  is - what the first outside users hit outranks everything below.
- **The road into the official Fedora repos**: self-review done, tool runs clean, review
  ticket next. The staged plan is
  [docs/plans/2026-09-04-official-fedora-packaging.md](plans/2026-09-04-official-fedora-packaging.md).

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
- **Translations.** The popup's sentences are DERIVED rather than written: the counts, the footer
  dateline, the last-run row and the post-run line are all assembled in
  `plasmoid/contents/ui/logic.js`, which is plain JavaScript with no `i18n()` in it - the QML
  around it is wrapped, that file is not. So a translated Kempt would still say "3 updates
  available" and "Checked 4 min ago" in English. Wrapping it means giving logic.js a translation
  hook it can call in both of its worlds (a QML engine, and node under the tests), and turning
  the phrases that are assembled from parts into whole i18np() sentences so a translator sees a
  sentence rather than fragments.
- **Download size next to Update Now.** "Is this 40 MB or 4 GB" is the one question the popup
  cannot answer today, and the only gap in the user panel that made a persona close the popup and
  do nothing. **Specced** in
  [docs/research/2026-08-27-download-size.md](research/2026-08-27-download-size.md): both backends
  already carry the number in metadata on disk, so it costs about 1.4 s (dnf) and 0.12 s (flatpak)
  inside `kempt check` with no depsolve, no network and no transaction - which is what keeps it
  away from dnfdragora's re-index-on-open and Discover's resolved-transaction stalls. It lands in
  the state file as optional additive keys, is rendered as one approximate figure next to the
  button, and is dropped entirely rather than guessed when any item's size is unknown. It is an
  **estimate with error in both directions** (flatpak ships ostree deltas, dnf pulls dependencies
  `--upgrades` never lists), so the wording must never imply a bound.
- **A defer: "later", "tonight", "only on Wi-Fi".** From the user panel: two of six personas
  currently "handle" the popup by closing it, which is the worst outcome an updater can produce.
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
  **The full staged plan - review request, sponsorship routes, dist-git mechanics, steady-state
  duties, and the other-distros ordering - is in
  [docs/plans/2026-09-04-official-fedora-packaging.md](plans/2026-09-04-official-fedora-packaging.md).**

## v2 - the differentiator release

- **Update Insights (flagship)**: per-update, per-THIS-machine warnings and
  recommendations from sourced facts only - dnf advisory/CVE classification with
  severity, a hardware-relevance map (lspci/lsmod: "mesa - affects your AMD GPU",
  kernel + akmod-nvidia = "driver rebuild on next boot"), session-impact detail, opt-in
  Fedora Bodhi karma. Never generated prose.
- **`dnf5 check-update --json`** migration - retires the text-parser bug class by
  construction.
- **Backend registry** - today adding a backend touches twelve call sites, one of them optional
  (listed in `docs/architecture.md`, and one of the eleven required ones changes
  `assemble_state`'s signature); a registry makes "one file per package manager" literally true.
  Prerequisite for:
- **apt and pacman backends** - the universal-updater vision becomes real.
- **Per-version holds** ("skip this one bad release, auto-clear on the next"),
  optional `dnf versionlock` integration, notification actions
  ("Install on Next Restart" from the toast itself). Flatpak user scope moved up to v1.x.
- **topgrade-style config vocabulary** (`disable`/`only`/`ignore_failures` per backend)
  adopted before the config grows organically.

## Beyond

- Other desktop environments via a StatusNotifierItem tray app sharing the same CLI.
- **Fedora Atomic (Silverblue, Kinoite, Bazzite) - honestly, not close.** rpm-ostree is a
  different update model, not a different command: transactions are image deployments, holds
  and per-package staging do not map, and pretending a dnf backend covers it would break the
  one promise Kempt makes. It gets built as its own backend against `rpm-ostree status
  --json` or not at all. Asked-for tracking welcome in an issue; no timeline.
- **Firmware via fwupd, maybe.** The one updater the popup does not count. It fits the model
  (fwupdmgr has a clean JSON-ish interface and its own staged-on-reboot semantics), but
  firmware failure modes are not package failure modes, so it earns its way in only after the
  distro backends prove the abstraction.
- Swap the deprecated `Plasma5Support.DataSource` executor when KDE ships the
  replacement (isolated in one QML file by design).
- Whatever the first outside users ask for loudest.
