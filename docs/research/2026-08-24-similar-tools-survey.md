# Prior-art survey — panel update indicators, universal updaters, update managers

**Date:** 2026-08-24
**For:** Upkeep v1 design (`docs/specs/2026-08-24-kempt-design.md`)
**Method:** web research (project READMEs, source, GitHub issues, distro wikis, Fedora/KDE discussion threads). Signal over completeness.

---

## 1. Panel / tray update indicators

### 1.1 Apdatifier (Plasma 6 applet) — closest prior art

[github.com/exequtic/apdatifier](https://github.com/exequtic/apdatifier) · [KDE Store](https://store.kde.org/p/2135796/)

Arch-first Plasma widget tracking pacman + AUR + Plasma widgets + Flatpak + fwupd. Explicitly says it "should also work on non-Arch systems (for Plasma Widgets, Flatpak, Firmware)" — i.e. nobody has done the dnf side of this well.

**Architecture (same shape as ours):** QML plasmoid + a bash script doing the real work. Confirms the two-layer split is the proven pattern, not a novelty.

**Config keys worth stealing** (from `package/contents/config/main.xml`):

| Key | Default | Why it matters |
|---|---|---|
| `checkMode` | `interval` | interval / daily-at-HH:MM / weekly — not just "every N minutes" |
| `intervalMinutes` | **120** | note: *double* our spec's 60 |
| `checkConn` | false | verify connectivity before checking (avoids fake "error" state) |
| `respectMeteredConn` | false | skip checks on metered NM connections |
| `notifyUpdates` / `notifyNews` / `notifyErrors` / `notifySound` / `notifyPersistent` | — | notification classes are separately switchable |
| `counterMode` | `side` | badge placement; plus "hide icon when fewer than N updates" |
| `busyIndicator` | `spinner` | explicit checking-state affordance |
| `terminal` | "" | 13 terminals supported, user-chosen — nothing hardcoded |
| `preExec` / `postExec` | "" | user hooks around the upgrade |
| `tmuxSession` | false | run the upgrade in tmux so closing the window doesn't kill it |
| `sudoBin` | `sudo` | pluggable (`doas`, `run0`) |
| `idleInhibit` | false | **inhibit sleep/idle during the upgrade** |
| `rebootSystem` | false | offer reboot after |
| `restartCommand` | `systemctl --user restart plasma-plasmashell.service` | restart the shell after widget updates |
| `feedsEnabled` / `feedsFetchCount` | false / 3 | shows distro news alongside updates (Arch "manual intervention required" notices) |

**Gems:** metered-connection etiquette; idle-inhibit during upgrade; tmux-detached upgrades; pre/post hooks; separately-toggleable notification classes; distro-news feed next to the package list; optional deps degrade gracefully (`jq`, `fzf`, `tmux`, `fwupdmgr` all optional).

**Complaints / bugs (from the issue tracker):**
- [#179](https://github.com/exequtic/apdatifier/issues/179) *"Update list doesn't refresh after closing the terminal running the upgrade"* — badge kept showing stale counts until the next 120-min tick. **The single most common failure mode of this whole category.**
- [#34](https://github.com/exequtic/apdatifier/issues/34) "Widget causing Plasmashell to crash sometimes" — a badly-behaved plasmoid takes the whole shell down.
- [#149](https://github.com/exequtic/apdatifier/issues/149) "v2.9.5 lists **all** system packages as pending update" — a parser regression turned the widget into a liar.
- [#2](https://github.com/exequtic/apdatifier/issues/2) "Loading forever", [#70](https://github.com/exequtic/apdatifier/issues/70) "Stuck at checking for flatpak updates" — no timeout on backend calls.
- [#133](https://github.com/exequtic/apdatifier/issues/133) "Settings reset to default" — config persistence fragility.
- [#17](https://github.com/exequtic/apdatifier/issues/17) external repos not picked up — checker disagreed with the package manager.
- [#38](https://github.com/exequtic/apdatifier/issues/38) / [#42](https://github.com/exequtic/apdatifier/issues/42) icon/tray rendering breakage across Plasma versions.

### 1.2 Arch Linux Updates Indicator (GNOME Shell)

[codeberg.org/RaphaelRochet/arch-update](https://codeberg.org/RaphaelRochet/arch-update) · [extensions.gnome.org/extension/1010](https://extensions.gnome.org/extension/1010/archlinux-updates-indicator/)

- **Checks without root** by shelling out to pacman's `checkupdates`; optional count on the panel.
- Release notes brag about "**asynchronous checking — no more 1 second Shell freeze** during updates check". Sync shell-outs from a panel process are a known, felt bug.
- "Updates pending" menu item **expands** to the full list; notifications carry an **"Update Now" action button** (act from the notification, don't force a trip to the popup).
- **Check command and update command are both user-editable strings** → the same extension serves pacman, AUR helpers, and other distros. Cheap universality.
- Known issue: default update command hardcodes `gnome-terminal`, which GNOME 42+ no longer ships → "Command not found" on fresh installs. **Hardcoded terminal = guaranteed future breakage.**

**`checkupdates` itself is the model for a safe non-root check:** it syncs into a throwaway DB (`$TMPDIR/checkup-db-$USER/`) under `fakeroot`, never touching the real pacman sync DB or needing privileges ([source](https://github.com/kyrias/pacman-contrib/blob/master/src/checkupdates.sh.in)). Checking must never mutate system state.

### 1.3 plasma-discover-notifier (the incumbent on our box)

The thing Upkeep replaces. Universal complaint: it **starts at login, appears in no Autostart or Background Services list, and Discover offers no setting to turn it off** — users resort to chmod/mask hacks ([Manjaro forum](https://forum.manjaro.org/t/how-to-disable-discovernotifier-without-uninstalling-discover/65449), [KDE Discuss](https://discuss.kde.org/t/kde-6-plasma-how-to-disable-the-notification-service/31530), [Kubuntu forums](https://www.kubuntuforums.net/forum/archives/eol-releases/-18-04/post-installation-as/69984-how-to-disable-notification-of-available-updates)). Lesson: an updater that can't be cleanly switched off is malware-adjacent in users' eyes.

### 1.4 mintupdate's tray experience

Tray icon reflects state (up to date / updates available / error), classifies updates by type, and the whole thing is backed by a real app rather than a notifier stub. Its refresh design is covered in §3.1.

---

## 2. Universal / multi-source updater CLIs

### 2.1 topgrade — the reference design for our "universal" ambition

[github.com/topgrade-rs/topgrade](https://github.com/topgrade-rs/topgrade) · [DeepWiki: architecture](https://deepwiki.com/topgrade-rs/topgrade) · [config system](https://deepwiki.com/topgrade-rs/topgrade/3-configuration-system)

Rust CLI that detects every package manager on the box (~60+: apt, dnf, pacman, brew, flatpak, snap, npm, pip, cargo, fwupd, …) and runs them all in one pass.

**Architecture worth copying:**
- Everything is a **"step"**. Config/CLI args → orchestration engine → per-step execution through one shared command-execution abstraction.
- **`require()` availability probe before each step** — if the tool isn't installed, the step is *silently skipped* rather than failing. This is exactly how a universal Upkeep should treat `dnf5` on a Debian box.
- Config in one TOML (`~/.config/topgrade/topgrade.toml`), merged with CLI args by defined precedence.

**Config vocabulary (steal the nouns):**
- `disable = [...]` / `only = [...]` — negative and positive step selection.
- `first = [...]` / `last = [...]` — explicit ordering without a plugin system.
- `[pre_commands]` / `[post_commands]` / `[commands]` — user-defined steps as first-class citizens.
- `ignore_failures = [...]` — per-step "don't fail the run for this one".
- `auto_retry` (int) and `ask_retry` — retry policy is config, not code.
- `show_skipped` — **tell the user why a step didn't run** (silent skipping is otherwise indistinguishable from a bug).
- `display_time` — per-step timings in the summary.
- `notify_each_step`, `notify_end = "always" | "never" | "on_failure"`.
- `assume_yes`, `set_title`.
- Sudo: `pre_sudo` (run `sudo -v` up front), `sudo_loop` + `sudo_loop_interval = 240` (keep-alive), `sudo_command` (pluggable), `allow_root`.

**Complaints / weak spots:**
- Config structure is acknowledged as messy — [#1472 "Overhaul the config file structure"](https://github.com/topgrade-rs/topgrade/issues/1472) is one of the most-discussed open issues. Flat namespace grew organically. **Get the config shape right early.**
- [#1025](https://github.com/topgrade-rs/topgrade/issues/1025) Windows sudo doesn't cache credentials → **multiple auth prompts in one run**. Same class of problem as polkit prompt-per-backend.
- `sudo_loop` exists because a long multi-step run outlives a credential cache — a hack forced by using sudo instead of a privileged helper.
- General ecosystem grumble: pointing one command at pip/cargo/npm-installed packages "is a nightmare" — breadth without per-ecosystem judgement causes damage. Topgrade's own answer is "disable the steps you don't trust; no update tool replaces backups."
- Steps that hang (macOS system upgrade, [#546](https://github.com/topgrade-rs/topgrade/issues/546)) block the whole run.

### 2.2 uupd — Universal Blue Updater

[github.com/ublue-os/uupd](https://github.com/ublue-os/uupd) · [DeepWiki](https://deepwiki.com/ublue-os/uupd)

Go binary; the automatic updater in Bazzite, Bluefin and Aurora. Orchestrates bootc/rpm-ostree + flatpak + brew + distrobox. Modular: each backend independently enable/disable-able.

**The gem — hardware/readiness gates before it will run at all:**
- battery ≥ **20 %** (and AC-power awareness)
- CPU load < **50 %**
- memory use < **90 %**
- network throughput below a byte/s ceiling (~700 KB/s) — *don't update while the user is streaming/downloading*

Plus: systemd service + timer rather than a daemon; all output to the journal (`journalctl -exu uupd.service`); `sudo uupd` manual invocation with passwordless execution for wheel members. Docs frame it as "configuration-driven, safety and user control over aggressive automation."

Weak spot: discoverability/enablement is fiddly ([bluefin#3411](https://github.com/ublue-os/bluefin/issues/3411) "uupd is not being enabled") — an updater whose enablement state is invisible is a support burden.

---

## 3. Full update managers & infrastructure

### 3.1 mintupdate — the UX gold standard

[github.com/linuxmint/mintupdate](https://github.com/linuxmint/mintupdate) · [user guide](https://linuxmint-user-guide.readthedocs.io/en/latest/mintupdate.html) · [DeepWiki: security & permissions](https://deepwiki.com/linuxmint/mintupdate/8-security-and-permissions) · [DeepWiki: refresh lifecycle](https://deepwiki.com/linuxmint/mintupdate/2.2-refresh-and-update-detection-lifecycle)

**Why it's good:**

1. **Privilege architecture — split process, tiered escalation.** GUI runs unprivileged forever. Three tiers:
   - passwordless sudoers entries for *harmless* background work (APT cache refresh via `mint-refresh-cache`, dpkg lock detection via `dpkg_lock_check.sh`);
   - polkit `pkexec` for administrative operations;
   - dedicated polkit actions for high-risk operations, e.g. `com.linuxmint.updates.automation` → `/usr/bin/mintupdate-automation`, `auth_admin_keep`, **`allow_gui` explicitly disabled**; `com.linuxmint.mint-release-upgrade.upgrade` → `mint-release-upgrade-root`.
   Each privileged action is a **separate small root-owned script with its own action ID**, never a general-purpose root shell.

2. **Update classification.** Every update is typed *security / kernel / package / unstable(Romeo)* from its repo origin and section, and the list sorts security and kernel first. Users see risk, not an undifferentiated wall.

3. **Blacklisting, including per-version.** `blacklisted-packages` GSettings key + `/etc/mintupdate.blacklist`. Mint 19.2 added blacklisting a *specific version* — "skip this one bad update without permanently ignoring the package."

4. **History of Updates** as a first-class menu item (View → History of Updates).

5. **Refresh strategy that doesn't hammer the network:**
   - explicit **soft refresh** (read local cache) vs **hard refresh** (hit the network) distinction;
   - `APTCacheMonitor` watches `/var/cache/apt/pkgcache.bin` and `/var/lib/dpkg/status` in an async thread → **re-detects when something else changed packages**, instead of only polling on a timer;
   - **concurrent backend queries** (APT, Flatpak, Cinnamon Spices in parallel) to minimise latency;
   - detection delegated to a **separate process** (`checkAPT.py`) so the GUI thread never blocks.

6. **`mintupdate-cli`** — a documented CLI for scripts/cron, i.e. the GUI is not the only entry point. (Upkeep is CLI-first, which is strictly better.)

7. **Automation preferences**, including auto-removal of unneeded kernels — with the documented warning to **only enable automatic updates after Timeshift snapshots are configured**.

Complaints are mild and mostly about kernel management ergonomics ([#549](https://github.com/linuxmint/mintupdate/issues/549) blacklist a specific kernel version).

### 3.2 PackageKit + KDE Discover / GNOME Software — and the live-vs-offline story

**Fedora's position, in its own words** ([Fedora Magazine, "Restarting and Offline Updates"](https://fedoramagazine.org/offline-updates-and-fedora-35/)):

- "If a file being used by an application changes while the application is running then the application won't know about the change." Long-running processes keep references to the *old* libraries — so after a live update you may still be running the vulnerable code, and mismatched components can misbehave.
- Offline updates boot into a **minimal environment with networking down and other services stopped**, apply the transaction with nothing running against it, then reboot normally. Fedora has shipped this since **F18** and was the first distro to prioritise it.
- Blunt framing: live updates are "a roll of the dice" — usually nothing bad happens, and occasionally you get anything from an app crash to an unbootable system.

The dnf5 docs say the same, drier: the offline command exists to run transactions "in a minimal boot environment, **reducing interference with running processes**" ([dnf5 offline(8)](https://github.com/rpm-software-management/dnf5/blob/main/doc/commands/offline.8.rst)).

Real-world Fedora/KDE reports of live upgrades hurting a running session: [plasmashell unusable after a `dnf upgrade` on F40](https://discussion.fedoraproject.org/t/plasma-kde-on-f40-is-no-longer-usable-because-plasmashell-crashes/131342), [desktop crash *during* `dnf upgrade`](https://users.fedoraproject.narkive.com/MOqv6wB9/desktop-crash-during-a-dnf-upgrade-will-this-be-a-problem-now) (dnf.log had no completed transaction; `dnf history info last` claimed success — i.e. an inconsistent record of what happened), [Plasma broken by a live plasma-nm upgrade](https://bugzilla.redhat.com/show_bug.cgi?id=1333982). Community advice in those threads: prefer offline upgrades, or at minimum run the upgrade from a VT rather than inside the desktop session.

**dnf5 mechanics** ([offline.8](https://github.com/rpm-software-management/dnf5/blob/main/doc/commands/offline.8.rst)):
- `dnf5 upgrade --offline` (the old `offline-upgrade` verb is **gone** in dnf5 — see [Fedora Discussion](https://discussion.fedoraproject.org/t/is-offline-upgrade-option-removed-in-dnf5/84777)) stages the transaction under `/usr/lib/sysimage/libdnf5/offline`.
- `dnf5 offline reboot` applies it on next boot; `--poweroff` to shut down instead; `dnf5 offline status` / `dnf5 offline log` / `dnf5 offline clean`. `DNF_SYSTEM_UPGRADE_NO_REBOOT` suppresses the automatic reboot.
- This gives a *staged* mode with a clean status/log API — cheap to add to a backend contract.

**Discover / GNOME Software complaints:**
- Discover **immediate ("live") update mode has no progress at all** — "clicking 'Update All' simply freezes the window… you are just left waiting for the window to unfreeze," while the *offline* path does show package version changes and progress bars ([Fedora Discussion](https://discussion.fedoraproject.org/t/kde-discover-gui-for-offline-and-immediate-updates/193357)). Flatpak progress bars sit at 0 % then jump to done.
- Offline updates only apply via **"Reboot & Update" / "Shut down & Update"** — a plain shutdown silently discards the staged transaction, which surprises people ([thread](https://discussion.fedoraproject.org/t/question-regarding-offline-updates/162739)).
- Chronic "stuck at fetching updates" and stale PackageKit daemon locks needing `systemctl restart packagekit` ([thread](https://discussion.fedoraproject.org/t/discover-reports-updates-but-is-stuck-at-fetching-updates/194329)).
- **Discover shows updates dnf can't find** — front-end and CLI disagreeing about reality ([thread](https://discussion.fedoraproject.org/t/kde-discover-shows-updates-that-dnf-cannot-find/125719)); also PackageKit ignoring `dnf versionlock` ([PackageKit#677](https://github.com/PackageKit/PackageKit/issues/677)).
- GNOME Software's update UI shows only the major version, so a 48.0 → 48.1 point release is invisible in the UI, and pre-releases render as stable ([critique](https://medium.com/@fulalas/gnome-mess-is-not-an-accident-4e301032670c)).

**RPM transaction lock contention — new and important on F44:**
- Fedora 44 moved PackageKit to the **DNF5 backend**, and GNOME Software now talks to dnf5 directly ([Changes/PackageKit-DNF5](https://fedoraproject.org/wiki/Changes/PackageKit-DNF5)).
- **dnf5 does not wait for the rpm transaction lock. It fails immediately**: `Transaction failed: Failed to obtain rpm transaction lock. Another transaction is in progress.` ([dnf5#2435](https://github.com/rpm-software-management/dnf5/issues/2435), closed as dup of [#2186](https://github.com/rpm-software-management/dnf5/issues/2186) "Add --wait option…", **still open, no maintainer response**). dnf-3 used to wait and retry; dnf5 regressed this.
- The reported trigger is exactly our scenario: a desktop update daemon staging an offline transaction in the background while a CLI `dnf` runs.

### 3.3 dnf-automatic

Config lives in `/etc/dnf/automatic.conf` (per our box's notes, an override file). The dials that matter:
- `upgrade_type = default | security` — security-only is the conservative default advice.
- `download_updates` / `apply_updates` — the two-stage split. The widely recommended conservative posture is **`download_updates = yes`, `apply_updates = no`**: packages are cached locally so the eventual manual `dnf upgrade` is fast and offline-capable, but nothing installs itself.
- `[emitters] emit_via` — stdio / motd / email / command; notification transport is config, not code.
- Standard guidance: exclude kernel/DB/critical packages from automation, stagger schedules, monitor and alert on failures ([Linux Audit](https://linux-audit.com/automatic-security-updates-with-dnf/), [OSTechNix](https://ostechnix.com/apply-updates-automatically-with-dnf-automatic/)).

**Metadata refresh etiquette (`dnf makecache --timer`)** — the best documented example of "don't be rude with the network":
- respects `metadata_timer_sync` (**default 3 hours**) and exits immediately if it ran too recently;
- **does nothing at all on battery power**;
- if the first mirror fails, it gives up rather than walking the whole mirrorlist.
Caveat: it does **not** honour NetworkManager's "metered connection" flag ([dnf5 caching docs](https://dnf5.readthedocs.io/en/latest/misc/caching.7.html), [makecache docs](https://dnf5.readthedocs.io/en/latest/commands/makecache.8.html), [old battery-detection bug](https://bugzilla.redhat.com/show_bug.cgi?id=1498680)). Apdatifier's `respectMeteredConn` fills exactly that gap.

**Per-user cache:** dnf keeps **a separate cache per user**. Root uses `/var/cache/libdnf5` (the "system cache"); a non-root dnf5 uses `~/.cache/libdnf5` with the same structure. Documented consequence: "DNF and plugins will potentially deliver different results for different users," and a non-root user re-downloads metadata into their own cache unless given read access to the fresher system cache ([dnf5 caching(7)](https://dnf5.readthedocs.io/en/latest/misc/caching.7.html)).

### 3.4 dnfdragora — what to avoid

Fedora's default GUI package manager on non-GNOME/KDE spins, and near-universally disliked.

- **"Very slow and CPU heavy because it re-indexes and refreshes every time you open it"** ([Fedora Discussion](https://discussion.fedoraproject.org/t/why-dnfdragora-and-not-some-other-tool/70528)).
- Skewed unmovable window, empty right panel after selecting a category, random crash popups, minutes-long waits before it's usable ([F42 thread](https://discussion.fedoraproject.org/t/why-is-dragora-sooooo-slow-under-fedora-42-xfce/155537), [FedoraForum](https://forums.fedoraforum.org/showthread.php?327830-After-an-hour-strugging-with-dnfdragora-I-have-to-give-up)).
- Maintenance: issues sitting for months, almost no PRs. The maintainer's own framing on why it's still the default: **"no one is working on another tool."**
- Users' comparison points: "synaptic, being almost unchanged for like 20 years, has far superior usability"; YaST is fast; yumex was more practical.

**The lesson isn't "GUIs are bad" — it's that a cold-start full metadata re-index on every open is the single behaviour that destroys perceived quality.** Cache aggressively, refresh in the background, show something instantly.

---

## 4. Implications for Upkeep

### ADOPT

**v1 — cheap and high value**

1. **Post-run re-check must be event-driven, not timer-driven.** Apdatifier's #1 bug is a stale badge after a terminal upgrade closes. Our spec already says "after any run, trigger `upkeep check`" — make that fire on process exit *and* on a filesystem watch of `/var/lib/rpm` / `/var/lib/flatpak` (mintupdate's `APTCacheMonitor` pattern), so an update run from *any* source (plain `sudo dnf5 upgrade`, Discover) clears the badge.
2. **Never let a backend hang the widget.** Hard timeout on every backend `check`/`report` call, and async execution. (Apdatifier #2/#70 "loading forever"; arch-update's release note bragging about killing a 1-second shell freeze.)
3. **Network etiquette, copied from `makecache --timer`:** skip the refresh on battery; skip if the last successful check is newer than the metadata expiry; add Apdatifier's `respect_metered_conn` (dnf itself ignores NM metered flags, so this must live in Upkeep).
4. **Show "why nothing happened."** topgrade's `show_skipped` — the popup should say "Flatpak: skipped (not installed)" / "skipped (metered connection)", never just show fewer rows.
5. **Availability probe per backend** (topgrade's `require()`): a missing backend is *skipped*, not an error. This is the whole universality mechanism and it costs three lines in `backends/*.sh`.
6. **Classify updates, don't just count them.** mintupdate types every update (security / kernel / package). Even a v1 approximation — flag security advisories (`dnf5 updateinfo`), flag kernel/systemd/glibc/mesa/plasma-workspace — makes the popup informative rather than a wall of names.
7. **`idle_inhibit` during the update run** (Apdatifier) — nothing worse than the box suspending mid-transaction. Use `systemd-inhibit --what=idle:sleep:shutdown`.
8. **Reboot detection via `dnf5 needs-restarting --json`** — returns `{reboot_required: bool, packages: [...]}` machine-readable. But cross-check against the transaction's own package list: the hardcoded "important" set is `kernel, kernel-rt, glibc, linux-firmware, systemd, dbus, dbus-broker, dbus-daemon, microcode_ctl`, and it has known false negatives on kernel detection ([dnf5#2562](https://github.com/rpm-software-management/dnf5/issues/2562), [RHBZ 2137935](https://bugzilla.redhat.com/show_bug.cgi?id=2137935), [oakleys.org.uk fix note](https://www.oakleys.org.uk/blog/2025/10/fix_dnf_needsrestarting_not_detecting_updated_kernel)). Its service-restart list is documented as "quite aggressive."
9. **Never hardcode the terminal.** arch-update still breaks on `gnome-terminal`; Apdatifier supports 13 terminals via a config key. `surface=terminal` should resolve Konsole → `$TERMINAL` → `x-terminal-emulator` → ptyxis, and say so when it can't find one.
10. **Show exact `old → new` versions including point releases** (GNOME Software's failure). Full EVR, both sides. Already in the spec — keep it non-negotiable.
11. **A clean off switch.** Discover-notifier is hated because it can't be turned off. `install.sh --uninstall` must fully reverse (plasmoid, helper, polkit action *and* rules file), and the widget needs a visible "pause checking" toggle.
12. **Separate root-owned helper per action ID, `allow_gui` off** (mintupdate's `com.linuxmint.updates.automation` pattern). Our spec already does this. Also: log every privileged invocation.
13. **Log/status verbs from dnf5 offline:** `upkeep status` (is a transaction staged/pending reboot?) alongside `summary` / `history`.

**v2 — noted, not built now**

14. **topgrade's config vocabulary** for the universal port: `disable` / `only` / `first` / `last` / `ignore_failures` / `auto_retry` / `pre_commands` / `post_commands` / `notify_end = on_failure`. Adopt the *names* now even with two backends — [topgrade#1472](https://github.com/topgrade-rs/topgrade/issues/1472) is a live warning about what an organically-grown flat config costs later.
15. **uupd's readiness gates** for any future scheduled mode: battery ≥ 20 %, load < 50 %, memory < 90 %, network not saturated. (Not needed while Upkeep never installs on its own.)
16. **Per-version blacklist / hold** (mintupdate 19.2): skip one bad version without ignoring the package forever.
17. **Distro news surfacing** (Apdatifier feeds): Fedora Magazine / release-notes or `dnf5 updateinfo` severity next to the update list.
18. **Pre/post hooks** (`pre_exec` / `post_exec`) — the cheapest extensibility point there is; also how a user wires in a Timeshift/restic snapshot before updating (Mint's own advice: automatic updates only *after* snapshots are configured).

### AVOID

| Mistake | One-line reason |
|---|---|
| Full metadata re-index on every popup open | dnfdragora's defining flaw — "slow and CPU heavy because it re-indexes every time you open it." |
| Synchronous shell-outs from the QML/panel process | Freezes the panel; arch-update shipped an async rewrite specifically to fix it, Apdatifier #34 crashed plasmashell. |
| Refreshing the badge only on the interval timer | Apdatifier #179: badge stayed stale after the upgrade terminal closed — the most-reported bug in this category. |
| A "live update" surface with no progress output | Discover's immediate mode "just freezes the window" — the #1 Discover complaint. |
| Trusting your own parser without fixtures | Apdatifier #149 listed *every installed package* as pending after a parser regression. Spec's fixture tests are the mitigation — treat them as mandatory. |
| Hardcoding the terminal emulator | arch-update still breaks on GNOME 42+ because `gnome-terminal` isn't there. |
| Showing major version only / hiding point releases | GNOME Software makes 48.0 → 48.1 invisible; users can't tell what changed. |
| No way to disable/uninstall cleanly | The entire DiscoverNotifier grievance; users end up chmod-ing binaries. |
| `sudo` credential-cache keep-alive loops | topgrade needs `pre_sudo` + `sudo_loop` because it uses sudo; a polkit helper with one auth per run is strictly better — don't reinvent the loop. |
| Multiple auth prompts in one run | topgrade#1025 (UAC storm). One prompt per `upkeep update`, covering dnf *and* system flatpaks. |
| Silently skipping a backend | Indistinguishable from a bug; always report skip + reason. |
| Auto-applying updates with no snapshot story | Mint's own docs gate automation on Timeshift; "no update tool replaces backups" (topgrade). Spec already forbids auto-install — keep it. |
| Front-end disagreeing with the CLI | "Discover shows updates that dnf cannot find" destroys trust; Upkeep's counts must be derived from the same command that will run. |

### Findings that CHALLENGE the spec

> **C1 — Live `dnf5 upgrade` inside a running Plasma session is the risk Fedora explicitly engineered around, and the spec has no offline path at all.**
> The spec's three run surfaces (terminal / in-popup / background) are all *live* upgrades of the running desktop. Fedora has shipped offline updates since F18 precisely because "if a file being used by an application changes while the application is running then the application won't know about the change," and calls live updates "a roll of the dice" ([Fedora Magazine](https://fedoramagazine.org/offline-updates-and-fedora-35/)); dnf5's own docs say offline transactions exist to reduce "interference with running processes" ([offline.8](https://github.com/rpm-software-management/dnf5/blob/main/doc/commands/offline.8.rst)). There are concrete reports of plasmashell breaking from a live upgrade ([F40 thread](https://discussion.fedoraproject.org/t/plasma-kde-on-f40-is-no-longer-usable-because-plasmashell-crashes/131342), [RHBZ 1333982](https://bugzilla.redhat.com/show_bug.cgi?id=1333982)) and of a desktop crashing *mid-transaction* with dnf.log and `dnf history` disagreeing about whether it completed ([narkive thread](https://users.fedoraproject.narkive.com/MOqv6wB9/desktop-crash-during-a-dnf-upgrade-will-this-be-a-problem-now)).
> **Recommendation:** add a fourth surface — `surface=offline` — that runs `dnf5 upgrade --offline` + `dnf5 offline reboot`, with `dnf5 offline status`/`log` feeding the popup and history. Even if live stays the default (it's what Erez wants: one click, no reboot), Upkeep should **detect risky transactions** (plasma-workspace, kf6-*, qt6-*, mesa, kernel, systemd, glibc, dbus, xorg/wayland stack) and offer "these touch the running desktop — stage for reboot instead?" This is a v1-sized addition to `backends/dnf.sh` (one flag) and it's the single biggest safety gap in the design.

> **C2 — dnf5 fails instantly on a busy rpm lock, and our box runs the exact daemon that takes it.**
> `dnf5` does **not** wait/retry for the rpm transaction lock — it errors out with "Failed to obtain rpm transaction lock. Another transaction is in progress." ([dnf5#2435](https://github.com/rpm-software-management/dnf5/issues/2435)); the request for a `--wait` option ([#2186](https://github.com/rpm-software-management/dnf5/issues/2186)) is open and unanswered. Fedora 44 put PackageKit on the dnf5 backend ([Changes/PackageKit-DNF5](https://fedoraproject.org/wiki/Changes/PackageKit-DNF5)), so `plasma-discover-notifier` refreshing or staging an offline transaction in the background will make `upkeep update` fail at random.
> **Recommendation:** (a) the spec's "concurrent runs" section covers only *our own* lockfile — add **foreign-lock handling**: detect the failure, retry with backoff, and report "another package manager is busy (PackageKit/Discover)" rather than a raw dnf error; (b) promote "disable `plasma-discover-notifier`" from a nice-to-have follow-up (spec §Out of scope) to a **v1 install-time recommendation** — it's now a correctness issue, not just duplicate notifications.

> **C3 — a non-root `upkeep check` reads a *different* metadata cache than the privileged `upkeep update` will.**
> dnf keeps a separate cache per user: root uses `/var/cache/libdnf5`, a non-root dnf5 uses `~/.cache/libdnf5`, and the docs state plainly that "DNF and plugins will potentially deliver different results for different users" ([dnf5 caching(7)](https://dnf5.readthedocs.io/en/latest/misc/caching.7.html)). So the badge can disagree with what the update actually does, *and* the user-cache path re-downloads metadata that root already has. This is the mechanism behind "Discover shows updates that dnf cannot find."
> **Recommendation:** verify on the box which cache `dnf5 check-update` uses as erez, and either point `check` at the system cache (`--setopt=cachedir=/var/cache/libdnf5` where readable, or dnf's read-only system-cache access) or run `check` through the same privileged helper. Decide before writing the parser fixtures.

> **C4 — "flatpak as user" is wrong on Fedora; Flathub is a system-wide remote and updating it triggers polkit.**
> The spec says flatpak "runs as user (no privilege)". Fedora's Flathub/fedora remotes are `--system` installations, and `org.freedesktop.Flatpak.app-update` / `.modify-repo` require polkit auth ([policy file](https://github.com/flatpak/flatpak/blob/main/system-helper/org.freedesktop.Flatpak.policy.in), [flatpak#4838](https://github.com/flatpak/flatpak/issues/4838), [flatpak#6216](https://github.com/flatpak/flatpak/issues/6216)). In `surface=background` that means an unexplained auth dialog — or, with no agent reachable, a silent hang.
> **Recommendation:** detect `--user` vs `--system` installations, fold the system-flatpak authorization into the same single auth moment as dnf (or route it through `upkeep-apply`), and never assume flatpak is prompt-free.

> **C5 — `auth_admin_keep` caches per *action ID*, not per argument.**
> polkit docs warn that with `AUTH_ADMIN_KEEP`, "authorization checks for the same action identifier and subject will succeed for the next brief period **even if the variables passed along with the check are different**", and that rules whose result depends on such variables should not use `*_KEEP` ([polkit reference](https://www.freedesktop.org/software/polkit/docs/latest/polkit-apps.html)). Our `upkeep-apply` takes a verb set behind one action `org.erez.upkeep.apply` with `auth_admin_keep` — so authorizing `dnf-upgrade` also authorizes every other verb for ~5 minutes.
> **Recommendation:** keep the verb set genuinely tiny and equally-privileged (all of them ≈ "modify installed packages"), or split into one action ID per verb. Also keep `org.freedesktop.policykit.exec.allow_gui` unset (mintupdate explicitly disables GUI on its automation action), and note pkexec strips `$DISPLAY`/`$XAUTHORITY` by design.

> **C6 — the plasmoid's chosen execution mechanism is on a deprecation path.**
> `Plasma5Support.DataSource` with the executable engine is the compatibility shim for the old Data Engines; KDE states data engines are deprecated, moved into plasma5support, and "should be ported away from as it is planned to be eventually dropped" ([Porting Plasmoids to KF6](https://develop.kde.org/docs/plasma/widget/porting_kf6/), [Mart's Akademy post](https://notmart.org/blog/2023/07/akademy-2023-plasma-6-and-plasmoids/)).
> **Recommendation:** fine for v1, but isolate every invocation behind a single QML component (e.g. `UpkeepRunner.qml`) so swapping to a small C++/QML plugin or a D-Bus service later is a one-file change — matching the spec's own "clean boundaries for portability" constraint.

> **C7 — default `refresh_interval_min = 60` is more aggressive than Fedora's own metadata policy.**
> `metadata_timer_sync` defaults to **3 hours** and `makecache --timer` refuses to run on battery ([makecache docs](https://dnf5.readthedocs.io/en/latest/commands/makecache.8.html)); Apdatifier defaults to **120 minutes**.
> **Recommendation:** split the two operations — a **cheap cache-only check** can run every 30-60 min (it's just a solve against local metadata), but an actual **metadata refresh** should be ≥ the repo `metadata_expire`, skipped on battery and on metered links. Document which one the interval controls, or users will blame Upkeep for the bandwidth.

---

## Sources

Apdatifier: [repo](https://github.com/exequtic/apdatifier) · [README](https://github.com/exequtic/apdatifier/blob/main/README.md) · [config main.xml](https://github.com/exequtic/apdatifier/blob/main/package/contents/config/main.xml) · [issues](https://github.com/exequtic/apdatifier/issues) · [#179](https://github.com/exequtic/apdatifier/issues/179) · [#17](https://github.com/exequtic/apdatifier/issues/17)
arch-update (GNOME): [Codeberg](https://codeberg.org/RaphaelRochet/arch-update) · [extensions.gnome.org](https://extensions.gnome.org/extension/1010/archlinux-updates-indicator/) · [checkupdates source](https://github.com/kyrias/pacman-contrib/blob/master/src/checkupdates.sh.in)
topgrade: [repo](https://github.com/topgrade-rs/topgrade) · [DeepWiki architecture](https://deepwiki.com/topgrade-rs/topgrade) · [DeepWiki config](https://deepwiki.com/topgrade-rs/topgrade/3-configuration-system) · [#1472](https://github.com/topgrade-rs/topgrade/issues/1472) · [#1025](https://github.com/topgrade-rs/topgrade/issues/1025)
uupd: [repo](https://github.com/ublue-os/uupd) · [DeepWiki](https://deepwiki.com/ublue-os/uupd) · [bluefin#3411](https://github.com/ublue-os/bluefin/issues/3411)
mintupdate: [repo](https://github.com/linuxmint/mintupdate) · [security & permissions](https://deepwiki.com/linuxmint/mintupdate/8-security-and-permissions) · [refresh lifecycle](https://deepwiki.com/linuxmint/mintupdate/2.2-refresh-and-update-detection-lifecycle) · [user guide](https://linuxmint-user-guide.readthedocs.io/en/latest/mintupdate.html) · [#549](https://github.com/linuxmint/mintupdate/issues/549)
Fedora / dnf5: [Offline updates](https://fedoramagazine.org/offline-updates-and-fedora-35/) · [dnf5 offline(8)](https://github.com/rpm-software-management/dnf5/blob/main/doc/commands/offline.8.rst) · [dnf5 caching(7)](https://dnf5.readthedocs.io/en/latest/misc/caching.7.html) · [dnf5 makecache](https://dnf5.readthedocs.io/en/latest/commands/makecache.8.html) · [needs-restarting](https://dnf5.readthedocs.io/en/latest/dnf5_plugins/needs_restarting.8.html) · [dnf5#2186](https://github.com/rpm-software-management/dnf5/issues/2186) · [dnf5#2435](https://github.com/rpm-software-management/dnf5/issues/2435) · [dnf5#2562](https://github.com/rpm-software-management/dnf5/issues/2562) · [Changes/PackageKit-DNF5](https://fedoraproject.org/wiki/Changes/PackageKit-DNF5)
Discover / GNOME Software: [offline vs immediate](https://discussion.fedoraproject.org/t/kde-discover-gui-for-offline-and-immediate-updates/193357) · [stuck fetching](https://discussion.fedoraproject.org/t/discover-reports-updates-but-is-stuck-at-fetching-updates/194329) · [shows updates dnf can't find](https://discussion.fedoraproject.org/t/kde-discover-shows-updates-that-dnf-cannot-find/125719) · [DiscoverNotifier disable](https://forum.manjaro.org/t/how-to-disable-discovernotifier-without-uninstalling-discover/65449)
dnfdragora: [Why dnfdragora](https://discussion.fedoraproject.org/t/why-dnfdragora-and-not-some-other-tool/70528) · [F42 slowness](https://discussion.fedoraproject.org/t/why-is-dragora-sooooo-slow-under-fedora-42-xfce/155537)
polkit / flatpak: [Writing polkit applications](https://www.freedesktop.org/software/polkit/docs/latest/polkit-apps.html) · [pkexec(1)](https://www.freedesktop.org/software/polkit/docs/latest/pkexec.1.html) · [Arch polkit wiki](https://wiki.archlinux.org/title/Polkit) · [Flatpak policy](https://github.com/flatpak/flatpak/blob/main/system-helper/org.freedesktop.Flatpak.policy.in) · [flatpak#4838](https://github.com/flatpak/flatpak/issues/4838)
Plasma 6: [Porting Plasmoids to KF6](https://develop.kde.org/docs/plasma/widget/porting_kf6/) · [Akademy 2023 / Plasma 6 plasmoids](https://notmart.org/blog/2023/07/akademy-2023-plasma-6-and-plasmoids/)
