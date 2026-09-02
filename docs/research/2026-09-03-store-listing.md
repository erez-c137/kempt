# KDE Store listing, paste-ready

The store form fields for the Kempt widget upload, written once so the upload is copying, not
composing. Where: <https://store.kde.org/product/add>. Everything below is free text the store
never validates - the version field in particular is typed by hand and nothing checks it against
`metadata.json`, so it comes from here or it drifts.

| Field | Value |
| --- | --- |
| Category | **Plasma 6 Applets** (706); path: Linux/Unix Desktops > Desktop Extensions > KDE Plasma Extensions > Plasma 6 Extensions > Plasma 6 Applets |
| Product name | Kempt |
| Version | 0.1.0 |
| License | MIT (dropdown) |
| File | `kempt-0.1.0.plasmoid` from <https://github.com/erez-c137/kempt/releases/tag/v0.1.0> |
| Screenshot | `docs/images/kempt-tray-popup.png` (upload the file itself) |
| Homepage | <https://github.com/erez-c137/kempt> |

## Summary (one line)

> Tidy updates for Fedora KDE - a tray badge, a truthful popup, one button.

## Description

> Kempt is a system tray updater for Fedora KDE. The badge shows how many dnf and Flatpak
> updates are pending. The popup lists each one with the version it moves from and to and the
> size of the download, and one button applies them - live in a terminal, silently in the
> background, or staged so the next restart installs them. Hold any package to skip it while
> keeping it visible.
>
> This widget is the front end for the `kempt` command-line tool and requires it. Install both
> from <https://github.com/erez-c137/kempt> (COPR package coming; the checkout installer works
> today). Fedora with Plasma 6 only, for now.
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
