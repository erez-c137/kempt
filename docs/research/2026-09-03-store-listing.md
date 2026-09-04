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
| Gallery | 3 images since 2026-09-04: `docs/images/kempt-tray-popup.png`, `docs/images/kempt-settings.png`, the comb logo (managed in Edit Product step 1 Basics) |
| Homepage | <https://github.com/erez-c137/kempt> |
| Tags | `updater, fedora, dnf, flatpak, systemtray` (the store allows five; the category already says plasmoid/applet/plasma6, so no slot goes to those) |
| CC-BY credit | Empty - no third-party CC-BY assets; every icon and SVG in the package is original, MIT licensed |

## Summary (one line)

> Tidy updates for Fedora KDE - a tray badge, a truthful popup, one button.

## Description - the whole field, copy-paste as one block

Everything between the rules below is the complete description field. Select all, replace,
save - no surgical edits. (The closing scope sentence is NOT live on the store yet as of
2026-09-04; pasting this block is what ships it.)

---

Kempt is a system tray updater for Fedora KDE. The badge shows how many dnf and Flatpak updates are pending. The popup lists each one with the version it moves from and to and the size of the download, and one button applies them - live in a terminal, silently in the background, or staged so the next restart installs them. Hold any package to skip it while keeping it visible.

This widget is the front end for the kempt command-line tool and requires it. On Fedora, one package installs everything - the CLI, its helpers, and this widget:

sudo dnf copr enable erez-c137/kempt && sudo dnf install kempt

Everything the widget shows comes from the same commands it runs, so the count and the transaction cannot disagree. Failures are reported in words: a cancelled password prompt is reported as exactly that.

Fedora with Plasma 6 only, for now - any current release (43 to 45, and rawhide), on x86_64 and aarch64. Docs and source: https://github.com/erez-c137/kempt

---

Why the block is shaped like this: the store's renderer collapses single newlines into
spaces and eats angle brackets as HTML (both learned on the live form, 2026-09-04), so
commands go on ONE chained line inside blank-line paragraph breaks, and URLs go bare. Two
stacked command lines merge into one broken command.

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

## Shipping a new version to the store (the release-day routine)

Always the SAME product, edited in place - never a second product, never two active files.
Done once for 0.1.1 (2026-09-04); this is that run written down:

1. Get the new `kempt-X.Y.Z.plasmoid` from the GitHub release for the tag
   (RELEASING.md builds and attaches it; download that exact asset, do not rebuild by hand).
2. Open the product edit form: store.kde.org > your profile > Products > Kempt > Edit
   Product (the listing is https://store.kde.org/p/2370353/).
3. **Step 1, Basics:** type the new version into the version field by hand - it is free text
   and nothing checks it against `metadata.json`, so it comes from this doc's routine or it
   drifts. Paste the short per-release changelog text (two sentences, same register as the
   0.1.1 one below). Gallery images live in this step's drop area; they only change when a
   screenshot actually changed.
4. **Step 2, Files:** drop the new `.plasmoid` in the drop area, then archive the OLD file's
   row so exactly one file stays active. "Download lock for archived files" stays CHECKED -
   the widget is version-pinned to the CLI, so an old `.plasmoid` against a newer RPM is a
   guaranteed mismatch; old versions belong to the GitHub releases page, not the store.
5. Save. Get New Widgets and Discover pick the new file up from here; nothing else to do.
6. Mirror whatever was typed (version, changelog) back into this doc.

## 0.1.1 update (2026-09-04)

New file `kempt-0.1.1.plasmoid` uploaded (old file archived behind the download lock), version
field typed `0.1.1`, and this text pasted into the per-release changelog field:

> A widget installed before the CLI now walks you through installing the engine, with a Copy
> Commands button. kempt doctor catches a store copy shadowing the packaged widget.
