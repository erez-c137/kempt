# Roadmap

Where Kempt is going, in order. Dates are deliberately absent - each stage ships when it
meets the bar of the one before it. Deferred-item details live in the spec's v2 section
(`docs/specs/2026-08-24-kempt-design.md`); this page is the ordered view.

## Now - finish v1.0 (the product as designed)

Both halves are built: the CLI is code-complete, documented and audited, and the Plasma widget
is written, installed by `install.sh` and covered by the suite. Everything left needs a human at
the keyboard, in this order:

1. **Live verification on real hardware** (founder-gated): the checklist in
   `docs/plans/2026-08-24-kempt-cli.md` - items 1 to 11 for the engine (real install, real
   update, the interactive auto-accept-off path, offline staging across a reboot, the
   declined-auth uninstall), then the morning visual gate W-1 to W-7 for the widget (add it to
   a panel, badge against `kempt check | jq .actionable`, popup and pin toggles against the
   JSON, Update Now end to end, the settings round-trip through Apply *and* OK). The engine
   items come first: until item 1 has run there is no CLI for the widget to be a client of.
2. **Merge `build/cli-v1` to `main`** once the checklist passes.
3. **The screenshot** (gate item W-6): Spectacle the panel badge plus the open popup, save it
   into `docs/`, and swap it for the placeholder comment in the README. It is the one thing on
   this page that nothing automated can produce.

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
- **History hygiene for going public** - the commit history is already clean (no subject or body
  carries an em dash). What is left is a decision about the working archives: `docs/plans`,
  `docs/specs` and `docs/research` are deliberately outside the published-docs standard, and
  going public means either publishing them as they are or moving them.
- **Flip the GitHub repo public** - also the moment CI becomes free. The workflow is already
  written and deliberately dormant (`.github/workflows/ci.yml`: shellcheck plus the 15-file
  suite, `workflow_dispatch` only, because Actions on a private repo costs money). Going public
  is a one-block edit of its `on:` trigger, plus triage of shellcheck's first real run.
- **Voice pass** on CHANGELOG / release notes / announcement posts using the founder's
  voice guides (owed - see memory reminder).
- **KDE Store listing** for the widget; **RPM/COPR packaging** for the CLI - packaging
  retires the load-bearing-checkout install and is the real on-ramp for strangers.

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
  optional `dnf versionlock` integration, flatpak user-scope support,
  notification actions ("stage offline" from the toast itself).
- **topgrade-style config vocabulary** (`disable`/`only`/`ignore_failures` per backend)
  adopted before the config grows organically.

## Beyond

- Other desktop environments via a StatusNotifierItem tray app sharing the same CLI.
- Swap the deprecated `Plasma5Support.DataSource` executor when KDE ships the
  replacement (isolated in one QML file by design).
- Whatever the first outside users ask for loudest.
