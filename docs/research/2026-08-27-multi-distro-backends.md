# Multi-distro backends: what a second package manager actually costs

**Date:** 2026-08-27
**Status:** research only. Nothing here is implemented. Groundwork for the roadmap's v2 items
"Backend registry", "apt and pacman backends" and "flatpak user-scope support"
(`docs/ROADMAP.md`), against the contract in
[`docs/architecture.md`](../architecture.md#the-backend-contract).
**Method:** commands were verified against upstream man pages and docs, or executed on this box
(Fedora 44, dnf5 5.4.3.0, flatpak 1.18.1, snapd 2.76, polkit 127, coreutils sort). This box runs
none of apt, pacman, zypper, rpm-ostree or bootc, so those rest on upstream documentation.
Anything not confirmed from an authoritative source is marked **UNVERIFIED** in place.

---

## 1. The five questions, per package manager

Kempt asks every package manager the same five questions, and the backend contract only works
because the answers stay separable:

1. **List pending updates without touching the network** (dnf5's `--cacheonly`).
2. **Refresh metadata** (a separate, privileged, battery-and-metered-aware step).
3. **Apply**, interactively and non-interactively.
4. **Is a reboot owed?**
5. **How does a hold work**, and does a held package still show up in the list?

Question 5 has a Kempt-specific twist. Kempt's holds are *its own*: `~/.config/kempt/holds` holds
`backend:name` lines, the badge counts only non-held items, and held items still appear in the
popup with the version they are waiting on. No system config is touched. So for every package
manager below, the question is not only "what is the native hold" but "does the native hold make
the item **invisible** to the list command" - because if it does, Kempt's skip-but-notify promise
cannot be built on it, and Kempt's own layer stays the right answer.

### apt (Debian, Ubuntu, Kubuntu, KDE neon)

| Question | Command | Source |
| --- | --- | --- |
| List, no network | `apt-get -s dist-upgrade`, or `apt list --upgradable` | [apt-get(8)](https://manpages.debian.org/bookworm/apt/apt-get.8.en.html): `-s` = "perform a simulation of events that would occur based on the current system state but do not actually change the system". Neither command calls `update`, so both read `/var/lib/apt/lists` only. Ubuntu's own `/usr/lib/update-notifier/apt-check` does the same thing in Python: it opens `apt_pkg.Cache(...)` and never calls `Cache.update()`. |
| Refresh | `apt-get update`, **root** (it writes `/var/lib/apt/lists`) | apt-get(8). No documented non-root route. |
| Apply, interactive | `apt-get upgrade` (never removes) or `apt-get dist-upgrade` / `full-upgrade` (may remove) | apt-get(8) |
| Apply, non-interactive | `DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade` | `-y` from apt-get(8); the frontend from [debconf(7)](https://manpages.debian.org/bookworm/debconf-doc/debconf.7.en.html) ("never interacts with you at all, and makes the default answers be used for all questions"); `--force-confdef` / `--force-confold` from [dpkg(1)](https://manpages.debian.org/bookworm/dpkg/dpkg.1.en.html) |
| Reboot needed | `/var/run/reboot-required`, with the causing packages in `/var/run/reboot-required.pkgs` | written by `update-notifier-common` (its file list ships `/usr/share/update-notifier/notify-reboot-required` and `/etc/kernel/postinst.d/update-notifier`). `needrestart -b` is the richer alternative: `NEEDRESTART-KSTA:` 0 unknown, 1 no pending upgrade, 2 ABI-compatible upgrade pending, 3 version upgrade pending. |
| Hold | `apt-mark hold` / `unhold` / `showhold` | [apt-mark(8)](https://manpages.debian.org/bookworm/apt/apt-mark.8.en.html): a hold "will prevent the package from being automatically installed, upgraded or removed" |

Both forms carry the from and to version on one line, so no second command is needed:

```
libc6/jammy-updates 2.35-0ubuntu3.6 amd64 [upgradable from: 2.35-0ubuntu3.4]
```
```
Inst base-files [10.3+deb10u4] (10.3+deb10u13 Debian:10.13/oldstable [amd64])
```

Three warnings, in descending order of how much they should change the plan:

- **apt(8) says its own output is not a contract.** Verbatim: apt is "meant to be pleasant for end
  users and does not need to be backward-compatible like apt-get(8)/apt-cache(8)", so "its output
  may change between versions" and "scripts should prefer apt-get/apt-cache". The worked sketch in
  `docs/architecture.md` parses `apt list --upgradable`. It should parse the `Inst` lines from
  `apt-get -s dist-upgrade` instead. There is no JSON or XML mode.
- **There is no exit-code signal at all.** apt-get(8) documents only "returns zero on normal
  operation, decimal 100 on error". Nothing corresponds to dnf5's rc 100 = updates pending, and a
  no-op upgrade still exits 0. The backend must decide "nothing pending" from stdout, never from
  the exit status.
- **Whether a held package still appears in `apt list --upgradable` is UNVERIFIED.** No man page
  states it. The best-effort answer is yes (dpkg's hold selection state is separate from the
  policy engine that computes candidate versions, and `apt-get upgrade` reports them as "kept
  back" rather than hiding them), which would suit Kempt's skip-but-notify model well. This is
  exactly the sort of claim that needs a live golden-file check, not a citation.

### pacman (Arch, and the KDE-heavy derivatives: Manjaro, EndeavourOS, CachyOS, Garuda)

| Question | Command | Source |
| --- | --- | --- |
| List, no network | `pacman -Qu` | [pacman(8)](https://man.archlinux.org/man/pacman.8): `-u` "Restrict or filter output to packages that are out-of-date on the local system". It reads the local database plus whatever sync databases are already on disk, and performs no network access itself. |
| Refresh | **not** `pacman -Sy`. Sync into a throwaway database under `fakeroot`, needing **no root** (see below) | [checkupdates.sh.in](https://raw.githubusercontent.com/archlinux/pacman-contrib/master/src/checkupdates.sh.in) |
| Apply, interactive | `pacman -Syu` | pacman(8) |
| Apply, non-interactive | `pacman -Syu --noconfirm` | pacman(8): "Bypass any and all 'Are you sure?' messages. It's not a good idea to do this unless you want to run pacman from a script." |
| Reboot needed | no standard mechanism exists | compare the running kernel against the installed one (`uname -r` vs `pacman -Q linux`), which is what the community tools do |
| Hold | `IgnorePkg` / `IgnoreGroup` in `/etc/pacman.conf`, or `--ignore <pkg>` per run | [pacman.conf(5)](https://man.archlinux.org/man/pacman.conf.5): "Instructs pacman to ignore any upgrades for this package when performing a `--sysupgrade`" |

The output is the smallest parsing job of any candidate, and it needs **no installed lookup at
all** because both versions are already on the line:

```
linux 6.9.1.arch1-1 -> 6.9.3.arch1-1
firefox 126.0-1 -> 127.0-1
```

**The refresh is the interesting part, and it is a gift.** `checkupdates` from `pacman-contrib`
symlinks the real local database into `${TMPDIR:-/tmp}/checkup-db-$USER/`, runs
`fakeroot -- pacman -Sy --dbpath "$CHECKUPDATES_DB"`, then lists with
`pacman -Qu --dbpath "$CHECKUPDATES_DB"`. Apdatifier does the same thing in its own `sync_dbs()`.
That gives Kempt a refresh step that needs **no root helper and no polkit action**, and that
cannot cause the breakage a bare `pacman -Sy` invites. Note that `checkupdates` itself is
therefore **not** the cache-only list: it syncs. `pacman -Qu` against the already-synced private
database is. `checkupdates -n` / `--nosync` skips the sync if something else keeps that database
fresh, which is exactly the shape `maybe_refresh_metadata` wants.

Two traps:

- **Partial upgrades are unsupported on Arch.** `pacman -Sy` alone, followed by installing or
  upgrading individual packages, can pull in newer shared libraries that break already-installed
  packages. **UNVERIFIED via direct fetch** (wiki.archlinux.org blocked every automated fetch this
  session), but the substance is corroborated across forum threads quoting the wiki, and it is
  the entire reason the throwaway-database pattern exists.
- **The exit code is the "zero pending is success" trap.** pacman(8) documents **no exit-code
  table at all**. `checkupdates(8)` documents its own exit code for "no updates available", which
  means at least one tool in this chain signals the empty case with a non-zero status. Kempt's
  contract rule is that zero pending must be success, so the pacman backend needs an explicit,
  tested rc mapping. **Probe this on a live Arch box before writing the backend**; getting it
  wrong turns an up-to-date machine into a permanently `stale` one, silently.

**Hold visibility is the best of the three.** `pacman.conf(5)` scopes `IgnorePkg` to
`--sysupgrade` only, not to `-Qu`, so an ignored package still shows in the list. Corroborated by
a pacman patch proposing to hide ignored packages from `-Qu` that was never merged
([BBS 108581](https://bbs.archlinux.org/viewtopic.php?id=108581)) and by
[paru#78](https://github.com/Morganamilo/paru/issues/78), where the AUR helper had to add its own
IgnorePkg filtering because pacman's `-Qu` does not do it. Skip-but-notify is pacman's default
behaviour.

### zypper (openSUSE Leap and Tumbleweed)

| Question | Command | Source |
| --- | --- | --- |
| List, no network | `zypper --no-refresh list-updates` (and `--no-refresh list-patches`) | [zypper(8)](https://manpages.opensuse.org/Tumbleweed/zypper/zypper.8.en.html): `--no-refresh` = "Do not auto-refresh repositories (ignore the auto-refresh setting)." |
| Refresh | `zypper refresh` (`ref`), root in practice | zypper(8). The cache lives in root-owned `/var/cache/zypp`; the man page does not state the root requirement in words, so **UNVERIFIED as an explicit sentence**, though `ZYPPER_EXIT_ERR_PRIVILEGES` exists for exactly this class of failure. |
| Apply, interactive | `zypper update` (`up`), or `zypper dup` on Tumbleweed | zypper(8) |
| Apply, non-interactive | `zypper --non-interactive update` / `zypper -n dup` | zypper(8) |
| Reboot needed | `zypper needs-restarting -r` (`--reboothint`), or the file `/run/reboot-needed` | [needs-restarting.1.txt](https://raw.githubusercontent.com/openSUSE/zypper/master/doc/needs-restarting.1.txt): "Only report whether a full reboot is required (returns 1) or not (returns 0)." `/run/reboot-needed` is written by [zypp-boot-plugin](https://raw.githubusercontent.com/openSUSE/zypp-boot-plugin/master/README.md) after each install or update, holding `reboot`, `kexec` or `soft-reboot`. |
| Hold | `zypper addlock` / `removelock` / `locks`, state in `/etc/zypp/locks` | zypper(8): a locked package is "forbidden to change their installed status" |

Both versions arrive in one table row, so again no second command is needed:

```
S | Repository         | Name         | Current Version | Available Version | Arch
--+--------------------+--------------+-----------------+-------------------+-------
v | SLES12-SP3-Updates | bash         | 4.3-82.1        | 4.3-83.5.2        | x86_64
```

Four things make zypper the friendliest port target of the three:

- **A documented exit-code table**, taken from zypper's own
  [`src/main.h`](https://raw.githubusercontent.com/openSUSE/zypper/master/src/main.h). The
  informational block is the part Kempt cares about: `100` update needed, `101` security update
  needed, `102` reboot needed after install or upgrade, `103` restart of the package manager
  itself needed, `106` some repos skipped due to refresh errors, `107` an rpm `%post` script
  failed. `zypper patch-check` returning **100 when updates exist and 0 when none** is a genuine
  equivalent of dnf5's `check-update` signal, which neither apt nor pacman has. Codes `0` to `8`
  are the error block; `7` is `ZYPPER_EXIT_ZYPP_LOCKED`, which maps directly onto the foreign-lock
  retry that `apply_with_retry` already implements for dnf5.
- **`--xmlout` is a real machine-readable mode** with a published schema (`xmlout.rnc`). It is the
  only candidate here that offers one, and it retires the whole text-parsing bug class the way
  `dnf5 check-update --json` is planned to for dnf. A zypper backend should use it from day one
  rather than parsing the table above.
- **The rpm database is the same one.** `dnf_installed_lookup`'s
  `rpm -qa --queryformat '%{NAME}\t%{EVR}\n'` works verbatim, with the same EVR shape, the same
  installonly and multilib duplicate-name behaviour, and the same epoch caveat. The snapshot half
  of the backend costs nothing.
- **Locked packages stay visible.** `zypper search` marks them with an `l` in the status column
  rather than hiding them, and locked packages are reported as skipped during `update` / `dup`.
  **Best-effort corroborated, not quoted for `list-updates` specifically** - another golden-file
  candidate.

Two gotchas worth writing into the backend as comments:

- **`--no-refresh` is a global option and must come before the subcommand.** `zypper --no-refresh
  lu` is cache-only; `zypper lu --no-refresh` is not what you meant. Without it, a repository with
  `autorefresh=1` makes `list-updates` hit the network, which is precisely the behaviour Kempt
  must not have on a check.
- **Tumbleweed needs `dup`, not `update`.** `update` "will not update packages which would require
  change of package vendor", while `dist-upgrade` "applies the state of (specified) repositories
  onto the system... removes packages that are no longer in the repositories... handles package
  splits and renames". A rolling snapshot is not a superset of the previous one, so `list-updates`
  under-reports on Tumbleweed. The backend needs to know which of the two openSUSE it is on, which
  is `ID=opensuse-tumbleweed` versus `ID=opensuse-leap` in `/etc/os-release`.



### flatpak, and the `--user` gap

This is the one backend Kempt already ships, and the one with a documented v1 limitation:
`docs/security.md` says "Flatpak is system scope only in v1, so a per-user app is never counted
and never updated". Closing that is cheaper and more valuable than any new distro.

| Question | Answer | Verified |
| --- | --- | --- |
| List, no network | `flatpak remote-ls --cached --updates --app --columns=application,version` | `man flatpak-remote-ls` on this box: `--cached` = "Prefer to use locally cached information if possible, even though it may be out of date." Ran in 1.7s wall / 1.4s user, consistent with local-only work. |
| Refresh metadata | `flatpak update --appstream [REMOTE]` | `man flatpak-update`: "Update appstream for REMOTE, or all remotes if no remote is specified." This is flatpak's `makecache`. |
| Apply | `flatpak update --system -y --noninteractive` / `flatpak update --user -y --noninteractive` | `man flatpak-update`. `-y/--assumeyes` answers questions; `--noninteractive` suppresses output and prompts. Nothing to do = exit 0 with "Nothing to update." |
| Reboot needed | n/a. A flatpak cannot owe a reboot. | - |
| Hold | `flatpak mask PATTERN` / `flatpak mask --remove PATTERN`, scoped with `--user` / `--system` | Present in flatpak 1.18.1 on this box: "Mask out updates and automatic installation". `flatpak pin` is a different thing (it stops automatic *removal* of unused runtimes, apps not included). |

**A live gap, not a v2 one.** `backends/flatpak.sh` ships
`flatpak remote-ls --updates --system --app --columns=application,version`, with **no
`--cached`**. So Kempt's dnf check is cache-only by construction (`kempt-refresh check` runs
`dnf5 --cacheonly check-update`) while its flatpak check is free to go to the network on every
single check, including from the background timer, on battery, and on a metered connection that
`maybe_refresh_metadata` deliberately refuses to refresh over. Two of the survey's own findings
are about exactly this failure mode: Apdatifier
[#2](https://github.com/exequtic/apdatifier/issues/2) "Loading forever" and
[#70](https://github.com/exequtic/apdatifier/issues/70) "Stuck at checking for flatpak updates".
The v1 fixture manifest records the same symptom from the other side: the flatpak capture is
hand-written because the real command "failed live twice (Flathub summary fetch timed out, ~2 min
each)". Adding `--cached` to the list command, and a `flatpak update --appstream` arm to
`maybe_refresh_metadata`, restores the same refresh-then-list separation dnf already has. This is
worth doing before any new backend.

**Scope defaults, from the man pages on this box:** `flatpak update` with no scope flag "updates
any matching refs in the standard system-wide installation and the per-user one"; `flatpak list`
with no flag shows "both per-user and system-wide installations". `backends/flatpak.sh` pins
`--system` on purpose, because `libexec/kempt-apply` validates ids against
`flatpak list --system` and an unscoped check would badge an app the apply path then refuses.

**The clean way to add user scope, verified on this box:** `flatpak list` has an `installation`
column, so one command tags scope in-band and no second query is needed.

```
$ flatpak list --columns=application,version,installation
net.mkiol.SpeechNote                    4.8.4       system
org.freedesktop.Platform.GL.default     26.1.8      system
org.freedesktop.Platform.GL.default     26.1.8      system
org.freedesktop.Platform.VAAPI.Intel                system
org.freedesktop.Platform.openh264       2.5.1       system
```

Two things in that real capture are load-bearing and neither is hypothetical:
`org.freedesktop.Platform.GL.default` **appears twice at the same version** (two arches), which is
exactly the duplicate-name case `collapse_versions` exists for; and
`org.freedesktop.Platform.VAAPI.Intel` has an **empty version column**, which is why
`join -a1 -e '?'` is not redundant with jq's `//`.

**The privileged half is where `--user` really bites.** `libexec/kempt-apply flatpak-update` runs
as root under `pkexec`. Under pkexec `HOME` is root's, so `flatpak update --user` there would
target *root's* per-user installation, not the invoking user's. A user-scope update must run as
the user, with no helper and no pkexec at all.

> **Superseded 2026-08-27, later the same day.** The `flatpak-update` verb no longer exists: the
> system-scope apply moved out of the root helper and into `backends/flatpak.sh`, where it runs
> as the user. What that does to the paragraph above is remove its premise while confirming its
> conclusion - the `--user` path now needs no new privilege story at all, because the `--system`
> one stopped having one. See `docs/security.md`.

And it turns out system scope has the same shape of problem in the other direction. Verified by
reading `/usr/share/polkit-1/actions/org.freedesktop.Flatpak.policy` on this box:

| flatpak action | `allow_active` |
| --- | --- |
| `org.freedesktop.Flatpak.app-update` | **yes** (no password) |
| `org.freedesktop.Flatpak.runtime-update` | **yes** |
| `org.freedesktop.Flatpak.app-install` | `auth_admin_keep` |
| `org.freedesktop.Flatpak.app-uninstall` | `auth_admin_keep` |

Flatpak asks for **no password** to update an already-installed system app, on the stated
reasoning that the commit is signed. Kempt routes that same operation through
`io.github.erez_c137.kempt.apply`, which is `auth_admin_keep`. So a **flatpak-only** Kempt run
asks for an admin password that plain `flatpak update` would not. That is defensible (one action,
one audit surface) but it is a real usability cost and it should be a deliberate decision rather
than an accident of the two-action design.

### rpm-ostree and bootc (Silverblue, Kinoite), briefly

Kinoite is the KDE atomic desktop, so this matters more to a KDE-targeted tool than its install
base suggests. It is also the case that **does not fit the contract**, and pretending otherwise is
the mistake to avoid.

- `rpm-ostree upgrade --check` reports without deploying, but it **hits the network** (it checks
  the remote ostree ref, and refreshes RPM repo metadata if layered packages exist). There is no
  `-C` equivalent. `rpm-ostree upgrade --preview` downloads `/usr/share/rpm` to compute a
  package-level diff, so it also hits the network.
- `--unchanged-exit-77` makes "already up to date" exit 77. **UNVERIFIED edge case:**
  [rpm-ostree#382](https://github.com/coreos/rpm-ostree/issues/382) reports `--check` returning 77
  when an upgrade is already staged. Probe before hard-coding on it.
- `rpm-ostree status --json` is local and carries a `deployments` array; each entry has `booted`
  and `staged` booleans. **"An update is staged and a reboot is owed" is a `staged: true`
  deployment**, which is a far better reboot signal than anything dnf5 offers.
- The apply model is reboot-to-apply, always. `rpm-ostree apply-live` exists but by default only
  allows package *additions* and restarts no systemd units, so it is a hotfix path, not the
  update flow.
- **Fedora ships a polkit override for atomic desktops**
  ([Changes/UnprivilegedUpdatesAtomicDesktops](https://fedoraproject.org/wiki/Changes/UnprivilegedUpdatesAtomicDesktops))
  granting password-less `org.projectatomic.rpmostree1.upgrade` and `.repo-refresh` to an active
  local user, explicitly to match dnf on package-mode Fedora. So on Kinoite, Kempt would need
  **no root helper at all** for the system backend.
- **bootc has no polkit layer**: it requires root for every operation including read-only
  `bootc status` ([bootc#409](https://github.com/bootc-dev/bootc/issues/409), open). Fedora's
  direction is that new client-side development goes to bootc rather than rpm-ostree
  ([Changes/DNFAndBootcInImageModeFedora](https://fedoraproject.org/wiki/Changes/DNFAndBootcInImageModeFedora)),
  so this gap is on the path, not off it.

**Recommendation:** model image-mode as a *different backend shape*, not as a TSV producer. The
unit of update is an image, not a package; `from`/`to` are commit or image digests; "apply" always
means "stage and reboot". Bending it into `name<TAB>from<TAB>to` produces a list nobody asked for
and a badge count that means nothing.

### snap, briefly

- `snap refresh --list` shows "the new versions of snaps that would be updated with the next
  refresh" (local `--help`). It **contacts the store**; there is no cache-only mode. Its columns
  are `Name Version Rev Publisher Notes` and it shows only the **incoming** version, so the
  installed one comes from a separate `snap list`.
- `snap refresh` has no `-y`: snapd is a daemon and the operation is asynchronous, not a
  confirm-prompt model. `snap changes` shows the operation history, not a pending list.
- Holds are native and expressive: `snap refresh --hold=24h <snap>`, `--hold` or `--hold=forever`
  for indefinite, `--unhold`. Naming a snap holds both auto-refresh and manual refresh; omitting
  the name holds auto-refresh only.
- **The disqualifying property:** snapd auto-refreshes on its own schedule, four times a day by
  default, and a running app can defer its own refresh for up to 14 days. A Kempt "pending"
  list therefore races a daemon Kempt does not control, and the badge would flap for reasons the
  user cannot see. If snap is ever added it should be **read-only reporting**, never a
  controllable apply.
- Reboot: snapd's reboot path is specific to Ubuntu Core refreshing `core`/`kernel`/`gadget`
  snaps. On a Fedora or Debian desktop the kernel belongs to dnf/apt, so there is nothing here for
  Kempt to detect. Do not build it.

---

## 2. What breaks Kempt's current contract

Ordered by how expensive it is to fix, not by how likely it is to bite.

**1. `assemble_state`'s positional signature is the one non-additive edit.** Items arrive as `$1`
dnf and `$2` flatpak and the jq body writes `backends: {dnf, flatpak}` literally. A third backend
changes the parameter list and therefore every caller. `docs/architecture.md` already names this
as the single non-additive entry in its thirteen-place table, and `docs/ROADMAP.md` already makes
the registry a prerequisite for apt and pacman. Both are right. Everything else on this list is
cheaper.

**2. The root helpers hard-code dnf5 and flatpak verbs, and one of them does the *listing*.**
`libexec/kempt-refresh` has exactly two verbs, `check` -> `dnf5 --cacheonly check-update --quiet`
and `refresh` -> `dnf5 makecache --refresh`. That the **check** runs as root is not incidental:
dnf5 keeps a per-user cache, so a non-root check would read a cold `~/.cache/libdnf5` while
`kempt-refresh` fills root's `/var/cache/libdnf5`. apt, pacman and zypper all keep a single
shared metadata store instead, so on those distros **listing needs no privilege at all** and the
`check` verb should simply not exist for them. That is a simplification, not a port: fewer
privileged paths, not more.

`libexec/kempt-apply` has three verbs (`dnf-upgrade`, `dnf-offline-stage`, `flatpak-update`).
Each new backend adds a verb to root-owned code, which `CONTRIBUTING.md` correctly says is an
issue-first change.

> **Superseded 2026-08-27, later the same day.** Two verbs now, both dnf. Flatpak's apply left
> root-owned code entirely, which is the counter-example this section did not have when it was
> written: a backend whose package manager needs no root to update needs no verb either.

**3. `NAME_RE` rejects names two of the three candidate ecosystems actually use.** Both
`lib/common.sh` and `libexec/kempt-apply` pin `^[A-Za-z0-9][A-Za-z0-9._+-]*$`. That covers Debian
and Arch package names, but it rejects:
- **apt multiarch qualifiers**, `libc6:i386`. Worse, the hold token is `backend:name` split on the
  first colon, so `kempt hold apt:libc6:i386` parses to name `libc6:i386` and is then rejected
  with exit 2. The hold vocabulary itself needs a decision before apt lands.
- **anything with a slash**: flatpak refs (`app/org.gimp.GIMP/x86_64/stable`), `flatpak mask`
  glob patterns, apt's `pkg/suite` pinning syntax.

**4. `dnf_reboot_needed` is called unconditionally from both `cmd_check` and `cmd_update`.** On a
box with no dnf5 the command errors, the function warns on stderr and answers `false`, and
`false` throughout Kempt means "nothing to say". So a non-Fedora box would report "no reboot
needed" forever and print a warning on every single check. `docs/architecture.md` already flags
this as "the one part of this contract that is still honestly dnf-shaped". The per-distro
replacements are all cheap: `/var/run/reboot-required` on Debian/Ubuntu, `zypper
needs-rebooting` on openSUSE, a running-kernel-versus-installed-kernel comparison on Arch, a
`staged: true` deployment on rpm-ostree.

**5. Epochs, and one asymmetry between the pending and installed sides.** `sort_name_version`
uses `sort -k2,2V`, whose honest limit is documented: it reads a leading `1:` as an ordinary
number. Verified on this box:

```
$ printf 'a\t1:2.0-1\na\t9.0-1\n' | sort -t $'\t' -k1,1 -k2,2V
a	1:2.0-1
a	9.0-1
```

`1:2.0-1` is newer and sorts first, so `collapse_versions` puts the older build last, where every
consumer reads the newest. This is **not** a dnf-only problem: apt, pacman and zypper all use the
same `epoch:version-release` shape. Good news, also verified: `sort -V` handles Debian's `~`
prerelease rule correctly (`1.0~beta` < `1.0~rc1` < `1.0`), so that half needs nothing.

The asymmetry: `dnf_parse_check_update` sorts the **pending** side with `sort_name_version -u`,
but `dnf_installed_lookup` sorts the **installed** side without `-u`. `collapse_versions`
comma-joins every repeated row unconditionally, so two identical rows produce `libc6
2.36-9,2.36-9`. On Fedora that is rare, because multilib twins usually differ. On Debian,
multiarch twins are routinely at the *same* version, so a real apt backend would render a
doubled version string in the popup for every multiarch package unless the installed lookup
dedupes too.

**6. `tsv_diff_updates` compares version strings, and two ecosystems have no usable version
string.** Flatpak's `version` column is frequently empty (verified above) and the real identity is
the commit hash; Apdatifier works around exactly this by displaying "latest commit" when the
installed and remote versions match. Snap's `version` is an upstream string with no ordering and
`rev` is the real identity. Any snapshot for those should carry the commit or revision, not the
human version, or the diff silently misses updates.

**7. `risky_regex` is Fedora vocabulary.** The default is
`^(kernel|systemd|glibc|dbus|mesa|qt6|kf6|plasma-workspace|kwin)`. On Debian the same set is
`libc6`, `libsystemd0`, `libdbus-1-3`, `libgl1-mesa-dri`, `libqt6*`, `libkf6*`. The session-safety
feature that routes risky transactions to the offline surface is therefore inert on every
non-Fedora box until the default becomes per-backend.

**8. The exit-code convention does not survive the port unexamined.** `dnf_check` treats
rc 100 as success because `dnf5 check-update` returns 100 when updates exist. The contract rule in
`docs/architecture.md` is blunt and correct: "**zero pending is success**, not failure. It is the
common case; a backend that exits non-zero when nothing is pending turns an up-to-date box into a
permanent `stale` state." Two of the three candidates give no signal at all: apt-get documents
only "zero on normal operation, decimal 100 on error", and pacman documents no exit-code table
whatsoever, while `checkupdates(8)` in pacman's own ecosystem does document a non-zero code for
"no updates available". zypper is the exception, with a full documented table (section 1). So
every backend needs its own explicit, tested rc mapping rather than inheriting dnf's, and for two
of them "nothing pending" has to be read off stdout instead of the exit status.

**9. `cmd_hold` / `cmd_unhold` carry a literal whitelist**
(`[[ "$b" == dnf || "$b" == flatpak ]]`), and `bin/kempt` mentions `dnf` or `flatpak` literally
70 times. That is the registry's real justification, in one number.

---

## 3. Distro detection, and a backend registry sketch

### Detection is two questions, not one

The instinct is "which distro is this", and it is the wrong first question. A single Fedora box
can carry dnf5, flatpak system scope, flatpak user scope and snapd simultaneously, and a Kinoite
box swaps the system backend while keeping the rest. So:

- **`/etc/os-release` picks the *system* backend.** Read `ID` first, fall back to `ID_LIKE`.
  Per [os-release(5)](https://man7.org/linux/man-pages/man5/os-release.5.html), `ID_LIKE` is "a
  space-separated list of operating system identifiers in the same syntax as the `ID=` setting",
  listed "in order of how closely the local operating system relates to the listed ones, starting
  with the closest", and "build scripts and similar should check this variable if they need to
  identify the local operating system and the value of `ID=` is not recognized". The spec's own
  examples: `ID=ubuntu` implies `ID_LIKE=debian`; `ID=centos` implies `ID_LIKE="rhel fedora"`.
  Also per the spec, `/etc/os-release` takes precedence over `/usr/lib/os-release`.
- **Binary presence enables the *app* backends**, and gates everything. This is topgrade's
  `require()` probe and survey lesson 5: a missing tool is a **skip**, not an error, and the popup
  must say so ("Flatpak: skipped, not installed") rather than showing fewer rows.

| Signal | Backend |
| --- | --- |
| `ID=fedora` / `ID_LIKE` contains `fedora` or `rhel`, and `/run/ostree-booted` absent | `dnf` |
| `/run/ostree-booted` present, or `VARIANT_ID` in `silverblue`, `kinoite`, `sericea`, `onyx` | `rpm-ostree` (later `bootc`) |
| `ID=debian`/`ubuntu`, or `ID_LIKE` contains `debian` | `apt` |
| `ID=arch`, or `ID_LIKE` contains `arch` | `pacman` |
| `ID` starts `opensuse`, or `ID_LIKE` contains `suse` | `zypper` |
| `command -v flatpak` | `flatpak` (system and user scope) |
| `command -v snap` and snapd active | `snap`, read-only |

Verified on this box: `/etc/os-release` has `ID=fedora`, no `ID_LIKE`, and `/run/ostree-booted`
does not exist, so the table resolves to `dnf` + `flatpak`. **UNVERIFIED:** that
`/run/ostree-booted` is the canonical atomic-desktop marker; it is widely used but was not
confirmed against an ostree man page for this doc. topgrade instead switches on os-release's
`VARIANT` field
([src/steps/os/linux.rs](https://github.com/topgrade-rs/topgrade/blob/main/src/steps/os/linux.rs),
`match_fedora_variant`, matching `Silverblue | Kinoite | Sericea | Onyx | IoT Edition | Sway
Atomic | CoreOS`), which is a second signal worth combining rather than choosing between.

### The registry

Today a backend is named literally in thirteen places. A registry makes "one file per package
manager" literally true. The shape that does it with the least new machinery:

```bash
# backends/<name>.sh declares, by naming convention, no framework:
#   <name>_detect          0 if this backend applies on this box (os-release + command -v)
#   <name>_check           items JSON            [required, unchanged]
#   <name>_snapshot        TSV name<TAB>version  [required, unchanged]
#   <name>_label           "System (dnf)"        [new: kills render_summary's literals]
#   <name>_apply_verb      "dnf-upgrade"         [new: kills cmd_update's literals]
#   <name>_reboot_needed   true|false            [new, optional: replaces the dnf-shaped global]
#   <name>_privileged      yes|no                [new: does apply go through kempt-apply at all?]

# bin/kempt
for f in "$ROOT"/backends/*.sh; do source "$f"; done
KEMPT_BACKENDS=()
for b in $(kempt_backend_names); do
  "${b}_detect" || continue
  is_true "$(config_get "include_$b")" || continue
  KEMPT_BACKENDS+=("$b")
done
```

The single change that unlocks it is `assemble_state`'s signature. Replace the positional
`$1 dnf, $2 flatpak` with **one JSON object** keyed by backend name:

```bash
# before: assemble_state "$dnf_items" "$fp_items" "$status" ...
# after:  assemble_state "$items_by_backend" "$status" ...
#   where $items_by_backend is {"dnf": [...], "flatpak": [...], "apt": [...]}
#   and the jq body becomes:  backends: ($items | map_values(wrap(true)))
```

That is additive to the state schema (schema stays 1, readers already iterate `.backends[]` for
totals) and it makes `render_summary`, `harvest_offline` and `cmd_update` generic in the same
stroke. `kempt_default` still needs an `include_<name>` default per backend, and that one is a
genuine trap worth repeating from `docs/architecture.md`: miss it and `config_get` answers the
empty string, `is_true` reads that as false, and the backend is **silently off forever** while
the wiring looks correct.

`<name>_privileged` is the entry that pays for itself immediately. flatpak user scope, and
rpm-ostree on Kinoite under Fedora's unprivileged-updates policy, both apply **without a root
helper**. Without that flag, the registry would force every backend through `pkexec` and ask for
passwords nobody's package manager asks for.

---

## 4. What to borrow, and what to avoid, from the two closest tools

### Apdatifier (Plasma 6 applet, Arch-first)

Source read for this doc:
[`package/contents/tools/sh/utils`](https://github.com/exequtic/apdatifier/blob/main/package/contents/tools/sh/utils)
and
[`package/contents/tools/tools.js`](https://github.com/exequtic/apdatifier/blob/main/package/contents/tools/tools.js).

**Borrow: the throwaway-database sync.** `sync_dbs()` creates a private db path, symlinks the real
`local` database into it, then runs `fakeroot -- pacman -Sy --disable-sandbox-filesystem --dbpath
"$dbPath" --logfile /dev/null`. The check then runs `pacman -Qu --dbpath "${cfg.dbPath}"`. This
is the single best idea in the whole prior-art survey for Kempt's purposes: it separates refresh
from list exactly the way Kempt needs, it never mutates the real sync database (so it cannot
cause the partial-upgrade breakage a bare `pacman -Sy` invites), and **it needs no root at all**.
It is the same mechanism `checkupdates` from `pacman-contrib` uses.

**Borrow: the honest treatment of a missing version.** `makeFlatpakList` correlates
`flatpak remote-ls --app --updates --show-details` against `flatpak list
--columns=name,version,active` and, when the old and new version strings are equal, displays
"latest commit" rather than a meaningless `4.8.4 -> 4.8.4`. Kempt's `from: "?"` fallback is the
same instinct; the commit hash is the missing half.

**Borrow: the refresh verb.** Apdatifier's flatpak check runs `flatpak update --appstream` first,
then lists. That is the flatpak analogue of `dnf5 makecache --refresh`, and Kempt's
`maybe_refresh_metadata` has no flatpak arm today.

**Avoid: per-package shelling out.** `apd-upgrade` records before/after with `pacman -Q $pkg` in a
loop, one subprocess per package. Kempt's whole-snapshot diff is cheaper and locale-proof, and
`docs/architecture.md` already explains why it beats parsing history output. Keep it.

**Avoid the bug, not the tool:**
[#149](https://github.com/exequtic/apdatifier/issues/149), "v2.9.5 lists **all** system packages
as pending update", is a parser regression that turned the widget into a liar. It is the exact
failure mode Kempt's mandatory guard rows exist to catch, and it is the argument for making
contributed fixtures non-optional (section 5).

### topgrade (the universal-updater reference)

Source read for this doc:
[`src/steps/os/linux.rs`](https://github.com/topgrade-rs/topgrade/blob/main/src/steps/os/linux.rs).

**Borrow: the detection ladder.** A `Distribution` enum, `/etc/os-release` parsed for `ID`,
`NAME`, `VARIANT` and `ID_LIKE`, `ID` matched first, `ID_LIKE` split on spaces as the fallback
(`debian`, `ubuntu`, `centos`, `suse`, `arch`, `alpine`, `fedora`), plus the Fedora `VARIANT`
match that routes Silverblue/Kinoite to an immutable-specific path. That is section 3's table,
already shipped and battle-tested.

**Borrow: the "the package manager already does this" check.** `run_needrestart()` looks for
`/usr/share/libalpm/hooks/needrestart.hook`, `/etc/pacman.d/hooks/needrestart.hook` and
`/etc/apt/apt.conf.d/99needrestart` and **skips its own step** if the distro will run needrestart
itself. Kempt should adopt the same instinct for reboot detection rather than duplicating what
apt already tells the user.

**Borrow the nouns, as the roadmap already plans:** `disable` / `only` / `ignore_failures` /
`show_skipped`. [topgrade#1472](https://github.com/topgrade-rs/topgrade/issues/1472) is a live
warning about what an organically-grown flat config costs later.

**Avoid: fusing refresh into apply.** topgrade's openSUSE path runs `zypper refresh` and then
`zypper dist-upgrade` inside one step, and its Debian path runs `apt update` then `dist-upgrade`.
Kempt separates them deliberately: metadata refresh is a low-privilege background step that is
skipped on battery and on metered connections, and folding it into the apply would lose all of
that.

**Avoid: `dist-upgrade` / `full-upgrade` as the default.** topgrade defaults Debian to
`dist-upgrade`, which is allowed to **remove** packages. Kempt's report does classify removals,
but a panel widget whose one-click "Update Now" quietly removes packages is the Discover complaint
restated. Default to plain `upgrade`; make `dist-upgrade` an explicit config key with the
consequence spelled out.

**Avoid: `sudo_loop` and `pre_sudo`.** They exist because topgrade uses `sudo` and a long
multi-step run outlives the credential cache
([topgrade#1025](https://github.com/topgrade-rs/topgrade/issues/1025) is the same class of bug on
Windows). Kempt's two-action polkit model with `auth_admin_keep` already solves this properly.
Do not import the workaround.

---

## 5. Which backend first, and how to test one without the distro

### Ranked

**0. flatpak `--user` scope.** Not a new distro at all, which is the point. It closes a documented
v1 limitation, needs **zero new privileged code** (user scope must *not* go through the root
helper), the one extra column it needs already exists and was verified on this box, and it is
fully testable here today. Everything below is speculative until someone contributes a fixture;
this is not. It should carry two companions in the same file: `--cached` on the list command and a
flatpak arm in `maybe_refresh_metadata`, which together stop the flatpak check reaching the
network on a battery-powered, metered box (section 1).

**1. zypper (openSUSE).** The cheapest real distro. It is the same rpm database, so
`dnf_installed_lookup` is reusable **verbatim** and the snapshot half costs nothing; the EVR
shape, the installonly story and the epoch caveat are all identical, meaning the existing
`collapse_versions` reasoning transfers without re-derivation. openSUSE Tumbleweed ships Plasma as
a first-class desktop, so the KDE relevance is real even though the install base is the smallest
of the three. `docs/architecture.md`'s worked sketch already says openSUSE can reuse dnf's
snapshot; that instinct is right and it is why this goes first.

**2. pacman (Arch and its derivatives).** The largest KDE-enthusiast base of the three: Manjaro,
EndeavourOS, CachyOS and Garuda all ship Plasma by default. The parser is the smallest of any
candidate, and the refresh needs **no root**, using Apdatifier's verified throwaway-db pattern.
The risks are specific and known rather than diffuse: the rc convention (section 1), the
`-Sy`-without-`-u` partial-upgrade footgun that the throwaway db exists to avoid, and a hard
decision to keep the AUR out of scope, since an AUR helper builds from source as the user and has
nothing to do with Kempt's privileged model.

**3. apt (Debian, Ubuntu, Kubuntu, KDE neon).** The largest absolute install base and the worst
parse surface, which is why it goes last rather than first. `apt` itself warns that it has no
stable CLI interface, the output is locale-shaped in a way `LC_ALL` only partly tames, multiarch
puts duplicate names in the installed lookup at *identical* versions (section 2, item 5), and
`NAME_RE` plus the `backend:name` hold vocabulary both reject `libc6:i386` today. It is worth
doing, and it should be the backend written *after* the registry lands, not the one that forces
it into existence under deadline.

**4. rpm-ostree / bootc.** High KDE relevance through Kinoite, but a different backend shape
(section 1), and bootc still has no polkit layer. Worth a design spike before any code.

**5. snap.** Read-only reporting at most, for the reason in section 1. Not a backend.

### Fixture-capture protocol

This box runs Fedora and is a production machine; it will never run four distros. The parsers are
pure functions over stdin plus a lookup file, so they are testable anywhere, but only against real
output. So fixtures have to be **contributed**, and the protocol has to make a contributed fixture
as trustworthy as a captured one.

1. **Ship the capture script, do not ask for a paste.** A `tests/fixtures/capture-<backend>.sh`
   committed in-tree, which a contributor runs on the real distro. It must invoke **the exact
   production command string** (the `KEMPT_<BACKEND>_*_CMD` default, not a paraphrase) and pin
   `LC_ALL=C.UTF-8`. `CONTRIBUTING.md` already carries the reason in scar-tissue form: an early
   dnf capture used `sort -u` where production used plain `sort`, and that one-word difference hid
   an entire bug class from the whole suite.
2. **Emit the provenance stanza with the fixture.** The script should print a ready-to-paste
   `MANIFEST.md` entry carrying, at minimum: `ID` and `VERSION_ID` from `/etc/os-release`, the
   tool's `--version`, the date, the exact command line, and whether the box had real pending
   updates at capture time. Today's manifest records "captured or hand-written, when, from what";
   contributed fixtures need three more fields, because a parser pinned to apt 2.6's columns must
   fail **loudly** when apt 3.0 changes them, and only a recorded tool version makes that
   diagnosable.
3. **Guard rows stay mandatory, and hand-extension stays legal.** A real box is usually in the
   wrong state: this box was fully up to date when the dnf fixtures were captured, so
   `dnf-check-update.txt` is hand-written from real package names and real installed EVRs, and
   says so. The protocol should expect the same: capture the real *shape*, then hand-add the three
   mandatory guards (a pending package absent from the installed lookup, a duplicate name at a
   **divergent** version, and whatever headers or indented sections the tool emits), and record in
   `MANIFEST.md` exactly which rows were added and what each one guards.
4. **Containers are the second source, not the first.** `podman` 5.8.4 is installed on this box,
   so `podman run --rm docker.io/library/debian:trixie sh -c 'apt-get update -qq && apt list
   --upgradable'` would produce genuine apt output here. Two caveats keep it secondary: a
   container image is not a real desktop (no held packages, no multiarch, no session-critical
   packages, so the interesting rows are exactly the ones it lacks), and an image pull plus an
   `apt-get update` is a slow, network-bound job. Use it to sanity-check a parser, never as the
   fixture of record.
5. **Draw the line where the suite already draws it.** The parser half is testable with no
   package manager present at all, and the CI job proves it: the suite passes under a stripped
   `PATH` with dnf5, flatpak, rpm and pkexec all unreachable. The **apply** half is not, and never
   will be. It is live verification done by hand on a real machine, exactly as the v1 release
   gate was. A backend pull request should therefore be mergeable on fixtures and tests alone,
   with the live checklist run by whoever actually has the distro, and the state of that
   checklist recorded in the pull request rather than assumed.
