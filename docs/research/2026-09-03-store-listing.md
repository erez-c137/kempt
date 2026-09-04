# KDE Store listing, paste-ready

**LIVE since 2026-09-04: <https://store.kde.org/p/2370353/>** - this document is now the
record of what was pasted and why; edit the listing there, then mirror the change here.

The store form fields for the Kempt widget upload, written once so the upload is copying, not
composing. Where: <https://store.kde.org/product/add>. Everything below is free text the store
never validates - the version field in particular is typed by hand and nothing checks it against
`metadata.json`, so it comes from here or it drifts.

| Field | Value |
| --- | --- |
| Category | **Plasma 6 Applets** (706); path: Linux/Unix Desktops > Desktop Extensions > KDE Plasma Extensions > Plasma 6 Extensions > Plasma 6 Applets |
| Product name | Kempt |
| Version | 0.1.1 |
| License | MIT (dropdown) |
| File | `kempt-0.1.1.plasmoid` from <https://github.com/erez-c137/kempt/releases/tag/v0.1.1> |
| Screenshot | `docs/images/kempt-tray-popup.png` (upload the file itself) |
| Homepage | <https://github.com/erez-c137/kempt> |
| Tags | `updater, fedora, dnf, flatpak, systemtray` (the store allows five; the category already says plasmoid/applet/plasma6, so no slot goes to those) |
| CC-BY credit | Empty - no third-party CC-BY assets; every icon and SVG in the package is original, MIT licensed |

## Summary (one line)

> Tidy updates for Fedora KDE - a tray badge, a truthful popup, one button.

## Description

> Kempt is a system tray updater for Fedora KDE. The badge shows how many dnf and Flatpak
> updates are pending. The popup lists each one with the version it moves from and to and the
> size of the download, and one button applies them - live in a terminal, silently in the
> background, or staged so the next restart installs them. Hold any package to skip it while
> keeping it visible.
>
> This widget is the front end for the kempt command-line tool and requires it. On Fedora, one
> package installs everything - the CLI, its helpers, and this widget:
>
>     sudo dnf copr enable erez-c137/kempt && sudo dnf install kempt
>
> Fedora with Plasma 6 only, for now. Docs and source: https://github.com/erez-c137/kempt

The store's renderer collapses single newlines into spaces and eats angle brackets as HTML
(both learned on the live form, 2026-09-04): commands go on ONE chained line inside blank-line
paragraph breaks, and URLs go bare. Two stacked command lines merge into one broken command.
>
> Everything the widget shows comes from the same commands it runs, so the count and the
> transaction cannot disagree. Failures are reported in words: a cancelled password prompt is
> reported as exactly that.

## Changelog (per-release free text)

> First release: the complete CLI (check, update, summary, history, holds, config, doctor,
> log), the Plasma 6 widget, dnf5 and Flatpak backends, scoped polkit actions with
> argument-validating root helpers, staged offline updates that genuinely install on the next
> restart, download sizes before you press the button, and an event log.

## Voice note

The register is the repo's own: plain, precise, no hype, no em dashes (spaced hyphen " - "),
and honest about limits (Fedora-only, CLI required). Future listing edits keep that. The
description leads with what the person sees (badge, popup, button), not with architecture.

## Form step 2 (Files)

- **Download lock for archived files: CHECKED.** When a new version is uploaded the store
  archives the old file; the lock stops people downloading it. The widget is version-pinned to
  the CLI, so a stale `.plasmoid` against a newer RPM is a guaranteed mismatch - old versions
  belong to the GitHub releases page, not the store.

## Files: exactly one

The `.plasmoid` is the only file the store carries. Plasma's Get New Widgets installs
unprivileged files into the user's home and nothing else - the CLI's root helpers and polkit
policy cannot travel that road, so a CLI tarball here would be a worse `git clone`. The store
listing's job is discoverability: the description carries the two dnf commands that install
everything properly, widget included.

## 0.1.1 update (2026-09-04)

New file `kempt-0.1.1.plasmoid` uploaded (old file archived behind the download lock), version
field typed `0.1.1`, and this text pasted into the per-release changelog field:

> A widget installed before the CLI now walks you through installing the engine, with a Copy
> Commands button. kempt doctor catches a store copy shadowing the packaged widget.
