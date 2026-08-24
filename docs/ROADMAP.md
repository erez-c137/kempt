# Roadmap

Where Upkeep is going, in order. Dates are deliberately absent - each stage ships when it
meets the bar of the one before it. Deferred-item details live in the spec's v2 section
(`docs/specs/2026-08-24-upkeep-design.md`); this page is the ordered view.

## Now - finish v1.0 (the product as designed)

The CLI is code-complete, documented, and audited. Remaining, in order:

1. **Live verification on real hardware** (founder-gated): the 11-item checklist in
   `docs/plans/2026-08-24-upkeep-cli.md` - real install, real update, the interactive
   auto-accept-off path, offline staging across a reboot, the declined-auth uninstall.
2. **Merge `build/cli-v1` to `main`** once the checklist passes.
3. **The Plasma widget (Plan 2)** - the actual point of the project: panel icon with a
   truthful badge, popup with pending/held lists and per-row pin toggles, settings page
   over `upkeep config`, event-driven refresh watching the rpm/flatpak databases (the
   stale-badge killer), offline recommendation surfaced with one click. Builds against
   the frozen state schema v1; adds the `kpackagetool6` step to install.sh and the real
   screenshot to the README.

## v1.x - ready for other people

- **Name decision** - "Upkeep" is a placeholder; settle it before anything is public.
- **History hygiene for going public** - rewrite the six plan-prescribed commit subjects
  that carry em dashes (or accept them); final sweep of the repo.
- **Flip the GitHub repo public** - also the moment CI becomes free: add a GitHub Actions
  workflow (shellcheck + the 12-file suite) on the public runners.
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
- **Backend registry** - today adding a backend touches ten call sites (listed in
  `docs/architecture.md`, and one of them changes `assemble_state`'s signature); a registry
  makes "one file per package manager" literally true. Prerequisite for:
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
