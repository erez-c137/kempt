# Upkeep — one-click system updates from the Plasma panel

**Date:** 2026-08-24
**Status:** Approved design (v1)
**Target:** Fedora 44, KDE Plasma 6.7, dnf5 5.4, Flatpak 1.18 — Erez's G9-Mini first. Portability to other distros/DEs is a design constraint (clean boundaries), not a v1 feature.
**Long-term vision:** grow into a universal Linux updater utility (multi-distro backends, any DE, other users). v1 decisions must not close that door. Prior-art survey (gems to borrow, mistakes to avoid) lives in `docs/research/`.

## Goal

A live icon on the Plasma panel that knows when dnf or flatpak updates are pending (badge with count). Clicking it opens a popup listing exactly what's pending; **Update Now** runs the update and ends with a clean summary: each package `old → new`, flatpaks updated, duration, reboot-needed flag. Options (scope, auto-accept, run surface, refresh interval, passwordless) live in the widget's settings page.

Context on this box: the weekly Sunday job auto-updates CLIs only and dnf-automatic is REPORT-only, so Upkeep is the on-demand "update the box now" button.

## Architecture: two layers, clean boundary

### Layer 1 — `upkeep` CLI (bash)

All real logic. The plasmoid contains zero package-manager knowledge.

Subcommands:

- `upkeep check` — queries pending updates from all enabled backends, writes state JSON, prints it. Exit 0 always (errors recorded in state, see Error handling).
- `upkeep update` — runs the update per config (or flag overrides `--no-flatpak`, `--surface=...`), captures before/after, writes a history entry, emits the human summary.
- `upkeep summary [N]` — renders the last (or Nth-last) run's summary as clean text.
- `upkeep history` — lists past runs (date, counts, status).
- `upkeep config get <key>` / `upkeep config set <key> <value>` — the ONLY way anything (including the widget) reads/writes settings.
- `upkeep enable-passwordless` / `upkeep disable-passwordless` — installs/removes the polkit rules file (itself via one pkexec prompt).

Files:

- Config: `~/.config/upkeep/config` (simple `key=value`). Single source of truth; the plasmoid settings page is a view over it via `upkeep config`.
- State: `~/.local/state/upkeep/state.json` — pending counts + package lists per backend, last-check timestamp, last-check status.
- History: `~/.local/state/upkeep/history/<ISO-timestamp>.json` — one file per update run.
- Logs: `~/.local/state/upkeep/logs/<ISO-timestamp>.log` — full raw output per run.

Config keys (v1): `include_flatpak` (default `true`), `auto_accept` (default `true`), `surface` (`terminal`|`popup`|`background`, default `terminal`), `refresh_interval_min` (default `60`).

### Layer 2 — Plasma 6 plasmoid (QML)

Thin. Package id `org.erez.upkeep` (rename before any public release).

- **Panel icon states:** up-to-date (plain icon), updates-available (badge with total pending count, dnf+flatpak), updating (spinner/activity), error (warning emblem), stale (tooltip notes last successful check time when the latest check failed).
- **Timer:** runs `upkeep check` every `refresh_interval_min`; also on plasmoid load.
- **Popup:** header "N updates available", scrollable pending list grouped System (dnf) / Apps (flatpak) with `name old → new`, buttons **Update Now** and **Refresh**, gear icon → standard plasmoid config dialog.
- **Config dialog pages:** checkboxes include-flatpaks and auto-accept; run-surface radio (Terminal/In-popup/Background); refresh interval; passwordless toggle. All values read/written through `upkeep config` — no plasmoid-local settings for these (avoids drift with CLI use). Auto-accept OFF forces surface=Terminal (the other surfaces can't prompt); the dialog disables the other radios in that case.
- Command execution from QML via the executable data engine (Plasma5Support.DataSource) or equivalent Plasma 6 mechanism.

### Backends contract

`backends/dnf.sh`, `backends/flatpak.sh`. Each implements three functions with a fixed contract:

- `check` → JSON fragment: count + list of `{name, from_version, to_version}`.
- `update` → performs the update (dnf via the privileged helper; flatpak as user), streams raw output to the log, exit code = success/failure.
- `report` → JSON fragment of what actually changed (dnf: parsed from `dnf5 history info last`; flatpak: parsed from update output), plus dnf's reboot-needed check (`dnf5 needs-restarting -r` or kernel/systemd heuristic).

This file boundary is the future port point (apt/pacman backend = one new file). No abstraction beyond the contract in v1.

Parsing notes: `dnf5 check-update` exits 100 when updates exist, 0 when none — treat both as success. Parsers must tolerate locale differences by pinning `LC_ALL=C` on all parsed commands.

## Privileges

- Root helper `upkeep-apply` (root-owned, installed to `/usr/local/libexec/`) is the only thing that runs privileged; it accepts a fixed small verb set (e.g. `dnf-upgrade`), no arbitrary args.
- Registered as a polkit action (`org.erez.upkeep.apply`), defaults `auth_admin_keep` → KDE auth dialog once per update run, works in all three surfaces.
- Passwordless toggle installs/removes a polkit `.rules` file returning YES for that one action for the active user — scoped, not blanket sudo.

## Run surfaces

- **Terminal (default):** opens Konsole running `upkeep update`; live dnf/flatpak output; ends with the clean summary and "press any key to close".
- **In-popup:** `upkeep update` runs detached writing to the log; the popup tails the log (compact progress) and shows the summary when done.
- **Background:** fully silent; desktop notification on completion with headline counts; clicking the widget shows the full summary in the popup.

All three surfaces run the same `upkeep update`; the surface only decides where output goes. After any run, the plasmoid triggers `upkeep check` to reset the badge.

## Summary & history

Per-run JSON: timestamp, duration, per-backend results (updated packages `old → new`), reboot-needed flag, exit status, log path. `upkeep summary` renders it as short human text (grouped, aligned, no wall of dnf noise). The popup's summary view and the background notification both come from this same renderer.

## Error handling

- **Check fails** (network down, repo flap — see G9-Mini's known GitHub/Cloudflare path flaps): keep the previous counts, mark state `stale` with the error message; icon shows stale hint in tooltip, no scary error state for transient check failures.
- **Update fails:** non-zero exit recorded in history entry; icon shows error state until next successful check; notification "Update failed — see log" with log path. Partial success (dnf ok, flatpak failed) is reported per-backend, not collapsed.
- **Concurrent runs:** lockfile in state dir; second `upkeep update` refuses with a clear message.

## Repo & install

- Repo: `/mnt/dev_workspace/projects/upkeep` (reachable via `~/my_projects/upkeep`); covered by restic.
- Layout: `bin/upkeep`, `backends/`, `libexec/upkeep-apply`, `plasmoid/` (QML package), `polkit/` (action + rules template), `install.sh`, `tests/`, `docs/`.
- `install.sh`: symlinks/copies CLI to `~/.local/bin`, installs plasmoid via `kpackagetool6 -t Plasma/Applet -i`, installs helper + polkit action via a single pkexec prompt. `install.sh --uninstall` reverses it.

## Testing

- Fixture-based tests for the parsers (recorded `dnf5 check-update`, `dnf5 history info`, `flatpak remote-ls --updates`, `flatpak update` outputs → expected JSON) — the fragile part gets the real tests.
- Smoke test: `upkeep check` end-to-end on the live box; `upkeep config` round-trip.
- Widget: `plasmoidviewer` + screenshots at phase gates (visual verification per house rule: screenshot + read the PNG).
- Counts as a light job on the G9-Mini heavy-job policy (no builds, no vitest).

## Out of scope for v1 (explicitly)

- Firmware updates (fwupd) — possible later menu item.
- Other distros/DEs, KDE Store publishing, packaging (RPM).
- Auto-updating on a schedule (the widget checks, never installs on its own).
- Disabling `plasma-discover-notifier` — manual follow-up for Erez once Upkeep proves itself, to avoid double notifications.
