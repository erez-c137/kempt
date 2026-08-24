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
- `upkeep run` — surface dispatcher: reads `surface` from config and launches `upkeep update` accordingly (Konsole window, detached, or offline staging). This is what the widget's Update Now button calls; humans can call `upkeep update` directly.
- `upkeep hold <name>` / `upkeep unhold <name>` / `upkeep holds` — manage the hold list (see Holds).
- `upkeep enable-passwordless` / `upkeep disable-passwordless` — installs/removes the polkit rules file (itself via one pkexec prompt).

Files:

- Config: `~/.config/upkeep/config` (simple `key=value`). Single source of truth; the plasmoid settings page is a view over it via `upkeep config`.
- Holds: `~/.config/upkeep/holds` — one entry per line, `dnf:<package-name>` or `flatpak:<app-id>`.
- State: `~/.local/state/upkeep/state.json` — schema v1 (frozen public interface for the widget): `{schema:1, last_check, last_success (null if never), status ok|stale, error, backends:{dnf|flatpak:{enabled, actionable, held, items:[{name,from,to,held}]}}, actionable, held_total, risky_pending:[name,…]}`. `risky_pending` (session-critical dnf packages pending and NOT held - see §Run surfaces) is an **additive** schema-1 key: readers must tolerate its absence in state files written before Task 13.5. `upkeep check` exits 0 on backend failures and corrupt state (recorded as stale, previous items kept); only a failure to PERSIST the state exits non-zero — after printing the fresh state to stdout, so the caller still gets the answer. One more caller rule: empty stdout with rc 0 (lock timeout with no valid previous state) means "no data — keep the last known state", never "zero updates".
- History: `~/.local/state/upkeep/history/<ISO-timestamp>.json` — one file per update run.
- Logs: `~/.local/state/upkeep/logs/<ISO-timestamp>.log` — full raw output per run.

Config keys (v1): `include_flatpak` (default `true`), `auto_accept` (default `true`), `surface` (`terminal`|`popup`|`background`|`offline`, default `terminal`), `refresh_interval_min` (default `60`), `risky_regex` (session-critical families, default `^(kernel|systemd|glibc|dbus|mesa|qt6|kf6|plasma-workspace|kwin)`; build/doc tails such as `-devel`, `-headers`, `-doc`, `-macros` are always excluded because the running session never loads them).

Exit codes (every command): `0` success, including a user who declines at the risky-transaction prompt; `1` the run itself failed; `2` usage error; `3` cannot start (jq missing, or another update holds the lock); `4` launcher missing (no terminal emulator for the terminal surface); `5` aborted during pre-flight, nothing changed.

**Check cadence (survey C7):** `refresh_interval_min` governs cheap cache-only checks against the root metadata cache. An actual metadata refresh (the privileged `refresh` verb) runs at most every 3h (dnf's own `metadata_timer_sync` default) and is skipped on battery or metered connections. Checks never re-download metadata on their own faster than dnf itself would.

### Layer 2 — Plasma 6 plasmoid (QML)

Thin. Package id `org.erez.upkeep` (rename before any public release).

- **Panel icon states:** up-to-date (plain icon), updates-available (badge with total pending count, dnf+flatpak), updating (spinner/activity), error (warning emblem), stale (tooltip notes last successful check time when the latest check failed).
- **Timer:** runs `upkeep check` every `refresh_interval_min`; also on plasmoid load.
- **Event-driven refresh (survey gem, fixes Apdatifier's #1 bug — stale badge):** additionally watch `/var/lib/rpm` and `/var/lib/flatpak` for changes, so an update applied from ANY source (manual dnf, Discover, Upkeep itself) refreshes the count within seconds.
- **Popup:** header "N updates available", scrollable pending list grouped System (dnf) / Apps (flatpak) with `name old → new`, buttons **Update Now** and **Refresh**, gear icon → standard plasmoid config dialog. Each row has a pin toggle (hold/unhold); held items move to a separate "Held" section showing the waiting version.
- **Config dialog pages:** checkboxes include-flatpaks and auto-accept; run-surface radio (Terminal/In-popup/Background/Offline); refresh interval; passwordless toggle. All values read/written through `upkeep config` — no plasmoid-local settings for these (avoids drift with CLI use). Auto-accept OFF forces surface=Terminal (the other surfaces can't prompt); the dialog disables the other radios in that case.
- Command execution from QML is isolated in ONE component (`Executor.qml`) wrapping the executable data engine (`Plasma5Support.DataSource` — a deprecated shim KDE plans to drop, survey C6; isolating it makes the eventual swap a one-file change). Every invocation is async with a hard timeout — synchronous or unbounded shell-outs from the panel process have frozen/crashed plasmashell in comparable widgets (survey mistakes #2).

### Backends contract

`backends/dnf.sh`, `backends/flatpak.sh`. Each implements three functions with a fixed contract:

- `check` → JSON fragment: count + list of `{name, from, to}` (versions comma-joined for installonly packages that keep multiple versions installed).
- `update` → performs the update (dnf via the privileged helper; flatpak as user), streams raw output to the log, exit code = success/failure.
- `report` → JSON fragment of what actually changed (dnf: parsed from `dnf5 history info last`; flatpak: parsed from update output), plus dnf's reboot-needed check (`dnf5 needs-restarting -r` or kernel/systemd heuristic).

This file boundary is the future port point (apt/pacman backend = one new file). No abstraction beyond the contract in v1.

Parsing notes: `dnf5 check-update` exits 100 when updates exist, 0 when none — treat both as success. Parsers must tolerate locale differences by pinning `LC_ALL=C` on all parsed commands.

## Holds (don't update, still notify)

Users can flag packages/apps they do NOT want updated while still seeing that an update exists.

- **Scope:** upkeep-only. dnf holds become per-run `--exclude=<name>` args; flatpak holds are skipped by updating apps individually rather than `flatpak update` (all). No system config is touched — a manual `sudo dnf upgrade` outside Upkeep ignores holds. (System-wide `dnf versionlock` integration = possible later feature.)
- **Notification semantics:** the badge counts only actionable (non-held) updates. Held items with pending updates appear in the popup's "Held" section with the waiting version, and in the tooltip as "N held". If only held updates exist, the icon stays in the up-to-date state (tooltip still notes the held count).
- **`upkeep check`** marks each pending item `held: true/false` in state JSON; **`upkeep update`** excludes held items and lists them (summary line `Held (skipped): <names>`) so a hold is never silently forgotten.
- **UI:** pin toggle per row in the popup; the settings page lists current holds with remove buttons.

## Privileges

- Two root helpers (root-owned, installed to `/usr/local/libexec/`) are the only things that run privileged — one per polkit action, since pkexec maps an action to exactly one executable path: `upkeep-refresh` (verbs: `check` = cache-only check-update as root, `refresh` = dnf makecache) and `upkeep-apply` (verbs: `dnf-upgrade`, `dnf-offline-stage`, `flatpak-update`; `--exclude` args validated by strict pattern; flatpak app-id args by strict pattern AND against the installed system set — a bad dnf exclude is harmless by construction, a bad app id is refused). No arbitrary args.
- **Two polkit action IDs** (survey finding C5: `auth_admin_keep` caches per action ID, not per argument, so one action must never mix cheap and dangerous verbs):
  - `org.erez.upkeep.refresh` — metadata refresh only; `allow_active=yes` (no dialog; same pattern as PackageKit's system-sources-refresh). This keeps the badge reading the **root** metadata cache, so check and update always agree (survey C3: non-root dnf reads a different cache than root).
  - `org.erez.upkeep.apply` — the actual upgrade verbs (dnf + flatpak together, one auth moment; survey C4: Flathub is a system remote on Fedora, so flatpak updates need privileges too); defaults `auth_admin_keep` → KDE auth dialog once per run.
- Passwordless toggle installs/removes a polkit `.rules` file returning YES for `org.erez.upkeep.apply` for the active user — scoped, not blanket sudo.
- **Flatpak scope contract (v1): system installation only.** Both flatpak queries (`remote-ls --updates`, `list`) and the root helper's installed-set validation use `--system`, so check and apply agree; the CLI additionally pre-filters app ids against the installed set, making the helper's check a backstop that never fires in normal operation. User-scope flatpaks are out of v1 scope (they need no privileges and could be a future unprivileged path).

## Run surfaces

- **Terminal (default):** opens Konsole running `upkeep update`; live dnf/flatpak output; ends with the clean summary and "press any key to close".
- **In-popup:** `upkeep update` runs detached writing to the log; the popup tails the log (compact progress) and shows the summary when done.
- **Background:** fully silent; desktop notification on completion with headline counts; clicking the widget shows the full summary in the popup.

- **Offline:** stages the transaction with `dnf5 upgrade --offline`; it applies during the next reboot (with an optional "reboot now" button). The post-reboot `upkeep check` harvests the result into a normal history entry + notification. This is Fedora's officially recommended path — live updates of a running desktop are documented to occasionally break the session mid-transaction (survey C1).
  - **How the harvest works in v1 (implemented):** staging writes a marker (`offline_staged.json`) that owns its own copy of the pre-transaction package snapshot AND records the boot session it was staged in (`boot_id`, from `/proc/sys/kernel/random/boot_id`); the next `upkeep check` harvests only once the BOOT SESSION HAS CHANGED, then re-snapshots and diffs into a history entry with surface `offline (applied on reboot)`. Snapshot diff, not `dnf5 offline log`. Only a reboot can apply a staged transaction, so a pre-reboot rpm change of any kind (a live `upkeep update`, a manual `dnf install`) can no longer consume the marker or be reported as the staged result. A marker with no `boot_id` (staged by an older build) or an unreadable one falls back to the plain snapshot comparison. **Residual caveat:** once the boot HAS changed, the post-reboot diff covers everything that changed since staging, so it can include rpm changes made by other tools in that window — the diff it reports is still truthful, it just may not be only the staged transaction.

All surfaces run the same `upkeep update`; the surface only decides where output goes. After any run, the plasmoid triggers `upkeep check` to reset the badge.

**Risky-transaction detection:** if the pending transaction touches session-critical packages (kernel, systemd, glibc, dbus, mesa, qt6*/kf6*, plasma-workspace), Upkeep recommends the offline path before proceeding. CLI half (Plan 1, Task 13.5): `upkeep check` publishes `risky_pending` in the state JSON (additive schema-1 key; consumers tolerate absence); interactive terminal updates prompt [u]pdate live / [s]tage offline / [a]bort; detached surfaces get a heads-up notification and proceed. Widget half (Plan 2): one-click "stage offline instead" on that notification. Live surfaces stay available; the user always decides. Default surface remains `terminal` (live) — Erez's call to flip the default to `offline`.

## Summary & history

Per-run JSON: timestamp, duration, per-backend results (updated packages `old → new`), reboot-needed flag, exit status, log path. `upkeep summary` renders it as short human text (grouped, aligned, no wall of dnf noise). The popup's summary view and the background notification both come from this same renderer.

## Error handling

- **Check fails** (network down, repo flap — see G9-Mini's known GitHub/Cloudflare path flaps): keep the previous counts, mark state `stale` with the error message; icon shows stale hint in tooltip, no scary error state for transient check failures.
- **Update fails:** non-zero exit recorded in history entry; icon shows error state until next successful check; notification "Update failed — see log" with log path. Partial success (dnf ok, flatpak failed) is reported per-backend, not collapsed.
- **Concurrent runs:** `flock` on a lockfile in the state dir (the same mechanism `upkeep check` uses); a second `upkeep update` refuses with a clear message and exit 3. The kernel releases the lock when the holding process's fd closes, so a crashed or SIGKILLed run leaves nothing to clean up and no staleness heuristic is needed. The lock is taken AFTER the risky-transaction prompt: a recommendation left unanswered must never block the next scheduled run.
- **Foreign package-manager lock (survey C2):** dnf5 fails instantly when another process holds the rpm lock (no `--wait` exists), and PackageKit/Discover now sits on the dnf5 backend on Fedora 44. On a busy lock, retry a few times with a fixed delay, then fail with a human message naming the likely holder ("PackageKit/Discover is busy - try again in a minute").

## Repo & install

- Repo: `/mnt/dev_workspace/projects/upkeep` (reachable via `~/my_projects/upkeep`); covered by restic.
- Layout: `bin/upkeep`, `backends/`, `libexec/` (two root helpers), `plasmoid/` (QML package — Plan 2, not yet present), `polkit/` (action + rules template), `install.sh`, `tests/`, `docs/`.
- `install.sh`: symlinks/copies CLI to `~/.local/bin`, installs helpers + polkit action via a single pkexec prompt, and the man page. `install.sh --uninstall` reverses it. The plasmoid install step (`kpackagetool6 -t Plasma/Applet -i`) is Plan 2 — added when the widget exists.
- The symlink install makes the repo checkout LOAD-BEARING at runtime (bin/upkeep, lib/, backends/, and the passwordless rules template all resolve into it) — intentional for this box; only the root helpers + policy are copied out (root-owned, so editing the repo can never change what runs privileged). Proper packaging (RPM) is the v2 answer for other users.

## Testing

- Fixture-based tests for the parsers (recorded `dnf5 check-update`, `dnf5 history info`, `flatpak remote-ls --updates`, `flatpak update` outputs → expected JSON) — the fragile part gets the real tests.
- Smoke test: `upkeep check` end-to-end on the live box; `upkeep config` round-trip.
- Widget: `plasmoidviewer` + screenshots at phase gates (visual verification per house rule: screenshot + read the PNG).
- Counts as a light job on the G9-Mini heavy-job policy (no builds, no vitest).

## Documentation (first-class deliverable)

Community adoption is a stated goal, so documentation ships to the standard of a serious open-source project, not as an afterthought: a real README (features, install, quick start), user docs (install/usage/configuration references with every command, key, default, and exit code), an architecture doc whose centerpiece is "how to add a backend for your distro" (the community on-ramp), a security doc (the two-action polkit model, helper validation, passwordless scoping - this tool runs code as root and must explain itself), CONTRIBUTING (dev setup, test harness conventions, fixture rules), SECURITY.md reporting policy, CHANGELOG (Keep a Changelog), CODE_OF_CONDUCT, and a man page. Public-copy rules apply (no em dashes). Docs plan: `docs/plans/2026-08-24-upkeep-docs.md`, executed once the v1 CLI surface freezes.

## Design principle (from survey)

The badge count MUST come from the same command path that performs the update ("front-end disagreeing with the CLI destroys trust" — the defining DiscoverNotifier/Discover complaint). Same cache, same excludes, same backends.

## Out of scope for v1 (explicitly)

- Firmware updates (fwupd) — possible later menu item.
- Other distros/DEs, KDE Store publishing, packaging (RPM).
- Auto-updating on a schedule (the widget checks, never installs on its own).

`install.sh` OFFERS to disable `plasma-discover-notifier` (recommended, default yes): it duplicates notifications AND its background PackageKit activity holds the dnf5 lock at random, which would make Upkeep runs fail spuriously (survey C2). It never disables it silently.

## v2 candidates (from survey — recorded, not committed)

- **Update Insights (flagship candidate, Erez 2026-08-24):** per-update warnings and recommendations tailored to THIS machine, so users stop reading up elsewhere. Local-first signal sources, no LLM required: (1) `dnf5 updateinfo` advisory metadata → security classification with severity + CVE ("3 security fixes, 1 Important"), absorbing the mintupdate classification gem below; (2) a hardware-relevance map from lspci/lsmod inventory → "mesa: affects your AMD GPU", "linux-firmware: your wifi chip", kernel + akmod-nvidia detected → "driver rebuild on next boot, first boot slower"; (3) session-impact detail extending `risky_pending` from "careful" to "why, for you"; (4) opt-in Bodhi API karma for Fedora ("+12 positive reports" / "boot issues reported") — network, cached, never blocking. Delivery: additive `insights` fields on state items (schema precedent: risky_pending) + a per-item detail row in the widget popup; Plan 2 should leave that UI affordance. Philosophy guard: insights are sourced facts (advisory, inventory match, karma), never generated prose.
- Security/kernel classification of updates, security sorted first (mintupdate) — subsumed by Update Insights above.
- Per-version holds ("skip this one bad version", auto-clears on the next release) on top of v1's per-package holds.
- topgrade-style config vocabulary (`disable`/`only`/`ignore_failures` per backend) when more backends exist — adopt the nouns before config grows organically.
- Migrate the dnf check parser to `dnf5 check-update --json` (available since 5.4) — removes the text-parsing bug class (obsoletes sections, indentation, column drift, locale) by construction; v1's hardened text parser is fixture-pinned and stays.
- Pre/post-run hooks; user-selectable terminal emulator; idle-inhibit during runs (Apdatifier).
