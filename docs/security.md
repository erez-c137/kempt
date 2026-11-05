# Security model

Kempt updates your system, so some of it runs as root. This page lists what runs as root, what it
accepts and refuses, and who can start an update without a password.

To report a vulnerability, see [SECURITY.md](../SECURITY.md).

A fact about another program is marked **[run]** when it was seen on a real Fedora 44 with SELinux
enforcing, dnf5 5.4.6, polkit 127 and systemd 259, or **[source]** when it was read in that
program's code or manual. A claim marked **[reasoned]** was worked out and has not been run.

## What runs as root

Two helpers, reached through Kempt's own polkit actions, and nothing else:

- `kempt-refresh`: package metadata only.
- `kempt-apply`: the dnf upgrade verbs.

The helpers are `/usr/libexec/kempt-{refresh,apply}`. Each polkit action's `exec.path` pins the
path, and `kempt doctor` prints it. pkexec matches an action by that path alone. So they stay two
files: the one that runs with no dialog has no upgrade verb to reach.

A helper reads a test setting, `KEMPT_HELPER_ROOT` or `KEMPT_DNF5_VERSION`, only when it is not
root. pkexec always runs it as root, so a real run reads neither.

Both helpers are `root:root` 0755 and owned by the package. The CLI, its library and the backends
run as you, from a tree under `/usr/share/kempt` that is root-owned.

## Two polkit actions

polkit's `auth_admin_keep` caches an authorization **per action id**, whatever the arguments. With
one action for both metadata refresh and upgrades, authorizing one would authorize the other for
the whole cache window. So there are two, each bound by `exec.path` to one helper:

| Action | Helper | Verbs | Policy for an active local session |
| --- | --- | --- | --- |
| `io.github.erez_c137.kempt.refresh` | `kempt-refresh` | `check`, `refresh` | `yes`: no dialog |
| `io.github.erez_c137.kempt.apply` | `kempt-apply` | `dnf-upgrade`, `dnf-offline-stage`, `dnf-offline-arm`, `dnf-offline-clean` | `auth_admin_keep`: one dialog per run. [The fixed rule](#no-password-at-the-desk) answers yes for a `wheel` user |

Both actions set `allow_any=no` and `allow_inactive=no`, so polkit refuses a remote or inactive
session without a dialog. A check from an SSH session fails with `not authorized: the password was
refused, or this session cannot authorize (over SSH or switched away)` [run]. A switched-away session
fails the same way, unless another session of the same account is active. A program with
[no session of its own](#a-program-with-no-session-of-its-own) is judged by the account too, and that
section shows each case.

The no-dialog refresh lets the check read the **root** metadata cache that the update will use.
It can run only `dnf5 --cacheonly check-update --quiet` (with `--json` added on dnf5 5.4.0 and
later) and `dnf5 makecache --refresh`.

The CLI gives a check or refresh 120 seconds, because nobody is there to answer a dialog during a
background check. That limit runs as you, so it cannot stop dnf5 once it runs as root. For that,
`kempt-refresh` starts dnf5 as a service with `RuntimeMaxSec=120`, and systemd sends SIGTERM after
120 seconds and SIGKILL 10 seconds later. The numbers are fixed in the helper and never come from the
caller. A program in dnf5's place that never ended stopped at 120 seconds, and the helper exited with
137 [run]. Against a repository that stopped answering, a refresh ended at 120 seconds with exit 0
and "Metadata cache created", so a stuck fetch is not always reported as a failure [run]. A refresh that does fail goes
no further than a warning, and the check goes on with the cached metadata. Apply calls have no
timeout.

**The Flatpak metadata refresh runs as you**, with no `pkexec`, polkit action or root helper. It
fills your own `~/.cache/flatpak/system-cache/summaries/`, which is what the check reads. Kempt
leaves the root-owned `/var/lib/flatpak/appstream` cache alone.

**Applying Flatpak updates also runs as you.** `flatpak update --system` asks polkit for
`org.freedesktop.Flatpak.app-update` and `runtime-update`. Flatpak's own policy answers `yes` for
an active local session, with no password. Two cases can still ask for authentication; see
[Accepted limitations](#accepted-limitations). Apps installed with `flatpak install --user` live in
your home, so `flatpak update --user` needs no polkit at all. Kempt runs it after the system one.

**Removing unused Flatpak runtimes runs as you too.** `kempt reclaim` runs `flatpak uninstall --system --no-related --noninteractive`
with the refs you were shown, by name. `--no-related` stops Flatpak adding related refs.

Kempt lists the runtimes again just before, and removes nothing unless the list is still that set.
Flatpak refuses to remove a runtime an installed app uses, and Kempt never passes
`--force-remove`. Flatpak does remove an extension an app uses. So Kempt removes extensions in a
second pass, after listing again, and only those still unused.

Flatpak does the removal through its own system helper, which asks polkit for
`org.freedesktop.Flatpak.runtime-uninstall`. This gives you nothing you did not already have.
Fedora's Flatpak rule allows that action without a password for a member of `wheel` in an active
local session, and anyone can run the same `flatpak uninstall` by hand. Before the removal, Kempt
asks polkit with `pkcheck` and no dialog. If the answer is anything but yes, nothing is removed and
Kempt says removing needs an administrator. With `--noninteractive`, Flatpak never shows a polkit
dialog either. If polkit still refuses Flatpak's helper, the answer is the same.

Kempt refuses to remove as root, under `sudo` or under `pkexec`. Flatpak counts the calling user's
own apps as users of a system runtime. As root it would see root's apps instead of yours, and
could remove a runtime one of yours needs. For the same reason, Flatpak cannot see another
account's own apps, so a person agrees to each removal.

## Validate before exec

Neither helper forwards an argument it was given. Each parses its arguments, validates them, and
builds the command itself. Anything unexpected exits 2 **before** any privileged command runs.

`kempt-refresh` takes one argument, `check` or `refresh`. Extra arguments are refused.

`kempt-apply` accepts:

| Verb | Accepted arguments | Validation |
| --- | --- | --- |
| `dnf-upgrade`, `dnf-offline-stage` | `-y`, `--exclude=<name>` | `<name>` must match `^[A-Za-z0-9][A-Za-z0-9._+-]*$`. A version form fits it too, and dnf5 applies it: `--exclude=tVer-3-1.noarch` skipped the newest version and took an older one [run] |
| `dnf-offline-arm` | none | Any argument at all exits 2 |
| `dnf-offline-clean` | none | Any argument at all exits 2 |

So `--exclude=foo;rm -rf /` and `--installroot=/` are rejected. The two argument-free verbs each
build one fixed command with no caller input. They refuse any argument, because dnf5's offline
subcommands accept flags of their own (`--installroot`, `--releasever`). Silently dropping one
would let a caller believe it had been honoured.

The removed `flatpak-update` verb also exits 2, so an old caller cannot get a privileged flatpak.

`dnf-offline-arm` runs `dnf5 offline reboot -y` with `DNF_SYSTEM_UPGRADE_NO_REBOOT=1` set. It installs
nothing. It marks an already-downloaded transaction ready and creates `/system-update`, which
systemd's offline-update generator looks for at the next boot. Without the environment variable,
dnf5 would reboot the moment the transaction is armed.

`dnf-offline-clean` runs `dnf5 offline clean -y`, which discards a staged transaction. At worst it
throws away updates that were still waiting to install.

### How dnf5 starts

A helper validates its arguments and then asks PID 1 to run dnf5 as a transient system service, with
`systemd-run --collect --service-type=exec --unit=kempt-apply-<verb>`, or `kempt-refresh-<verb>`.
dnf5's parent is PID 1, so nothing about the caller reaches it. It has no terminal and no session,
and it runs in `system.slice` as `system_u:system_r:rpm_t:s0`, the domain it had in 0.2.0 [run].

These are the service's own and not the caller's: timers, the controlling terminal, the session, the
signal mask and ignored signals, the umask (0022), the working directory (`/`), open files, the
environment (`PATH`, `LC_ALL`, `HOME` and what systemd sets for any service), resource limits, OOM
score, nice value, scheduling class, I/O priority, CPU affinity, timer slack, personality, cgroup,
SELinux domain and mount namespace. These were replayed against real dnf5 with the update at a chosen
moment in a package script [run]:

| What a caller did before pkexec | What happened to dnf5 |
| --- | --- |
| Armed a real, virtual or CPU timer | Finished. A real timer ended only the caller |
| Sent Ctrl-C, Ctrl-\ or Ctrl-Z through a terminal it owns | Finished. On the first two the helper said so and left |
| Stopped reading a full pipe, closed it, or pointed output at `/dev/full` | Finished, and the rpm lock was free for the next update |
| Set `oom_score_adj=1000`, then used up the memory | Finished. Its score was 0, and the kernel killed the memory eater and the helper |
| Set scheduling class, I/O priority, CPU affinity, personality or limits | None of them reached dnf5 |

Closing the terminal during the download or the transaction, `loginctl terminate-user` from the
session and from a user scope, and root killing the helper outright all left dnf5 to finish [run].

dnf5's output goes to files in a folder only root can reach, made with `mktemp -d /run/kempt.XXXXXXXX`,
and two children of the helper copy those files to the caller. A stuck reader stops a copy and never
dnf5, though the helper stays until the reader goes. Output arrives as dnf5 writes it, a failed
`%pre` included [run]. Other accounts could not list, read or write the folder, make one of that name
beside it, or stop the service, and a `wheel` account over SSH could not either [run].

The unit name is fixed per verb, so a second run while one is going fails at once with nothing
started [run]. Other accounts could not take the name, and the caller's own user manager holding it
had no effect [run]. Root masking the name, or dnf5's binary being missing, is a refused start: the
helper exits 1 at once with systemd's sentence and removes the folder [run].

The service's last step writes how dnf5 ended into the folder, and deletes it. The helper holds that
file open, sees the folder go, and reads the answer from the file it still holds. It does not use
`systemd-run --wait`, which hears over the message bus: when a package's `%pre` re-executed a user
manager, `--wait` hung after dnf5 had finished, and when `%pre` restarted `dbus-broker`, `--wait`
returned 0 after a second while dnf5 ran on [run]. `tests/live/bus-check.sh` keeps both cases.

dnf5 that exited gives its own status. Anything else makes the helper exit 137: root killing dnf5, and
the kernel's OOM killer, both did so, with the folder gone [run]. The CLI then asks dnf5's history,
which settles it both ways. A transaction killed partway reported failed with the packages that had
really moved. One killed after the transaction, whose history read Ok, reported its packages as updated
with exit 0, and the event log says the answer came from history [run].

Ctrl-C stops the watching and not dnf5. The helper says that the update carries on and exits 130, the
CLI records `Stopped watching`, and the rpm lock stays held until dnf5 ends. A stop anybody can aim at
a chosen moment is what this design removes, so there is none. When the caller is gone, nothing
reports the result except dnf5's own history, and Kempt's history has no entry for that run [run].

These are the limits, stated and left as they are:

- **The last step cannot start.** With `/usr/bin/sh` gone when dnf5 ends, the folder stays with an
  empty record, and the helper waits until Ctrl-C, which leaves with the same words [run]. A later run
  is not blocked by it. Producing this took root moving the shell away, so the helper has no branch for
  it.
- **A power cut, or a helper killed before the service starts.** A folder stays in `/run` until the
  next restart, which clears `/run`. It blocks nothing, because each run makes its own [run].
- **Root deleting the folder mid-run.** The helper reports at once with no record, so the CLI can say
  an update failed that then finishes. dnf5's history has the truth [run].
- **`/run` full.** If it fills during a run, dnf5 still finished and reported 0 [run]. If it is full
  before a run, systemd refuses the service and nothing starts [run].
- **The mount namespace.** The helper reads folders in the caller's mount namespace, and dnf5 runs in
  PID 1's. A process with no extra rights cannot use that: pkexec refuses from a user namespace [run].
  `kempt doctor` reports a run outside PID 1's.

No SELinux denial appeared in any of these runs [run].

### The folders dnf5 installs from

One check guards these folders, and root makes it. `kempt-apply` exits 3 while anything under dnf's
state, staged packages or cache is not root's, or by its mode bits is writable by anyone other than
root and its group. An ACL entry that grants write passes. rpm checks only a digest after dnf5's signature check, which is why the cache counts. A link
is judged by its owner and never followed. `dnf-offline-clean` skips this check, because discarding
the stage is the fix, and it installs nothing.

Root checks when a step starts: a live update, a stage, an arm. Nothing checks at the restart that
installs a staged update, because Kempt does not run then. A folder changed after the arm reaches
root's dnf5 unchecked.

The CLI runs the same `find` as you, read-only. Root can read everything you can, so what you find
root refuses over too. `kempt update` stops on such a folder with exit 5, before any password prompt,
and `kempt check`, `kempt status` and the widget say updates are paused. Your reading can miss a
folder only root can read, or fail altogether, and then the helper decides alone. There is no
override.

`kempt doctor` has one row for this, and it gives the fix. Up to 0.1.7 the helpers kept the caller's
umask, which could leave world-writable files in these folders. The fix for dnf's state deletes a
file with a second hard link, since that file may belong to someone else. When the check itself cannot
run, the row says so and names the error.

`kempt-refresh` checks the cache the same way for both `check` and `refresh`, because root's dnf5
parses what is in it. That narrows the hole and does not close it: Fedora's own `dnf-makecache.timer`
has no such check [run], and any active local user can ask PackageKit for a refresh [run].

Kempt no longer walks the folders above these, reads ACL entries or looks for FUSE mounts, as root or
as you. A writable `/var/lib` or an ACL entry that grants write no longer stops an update, and doctor
does not report them. This is a real reduction on a misconfigured machine, and it takes root's own
act to make one. On such a machine a local user could plant a package and wait for any root dnf5
run, Kempt's or not [reasoned]. Whether one of those machines can be turned into an install through these
removed checks has not been tested.

The offline verbs share the apply action because they are one operation. `auth_admin_keep` lets
one dialog cover a stage and the arm that follows seconds later.

The CLI validates hold names with the same pattern at `kempt hold` time, so a bad name is rejected
before any helper sees it.

The Flatpak apply in `backends/flatpak.sh` runs as you and checks app ids against the same
pattern, because ids come from a **remote's** summary. The anchored first character stops a name
such as `--installation=other` reaching `flatpak` as an option. The ids are built from
`flatpak list --system` just before the call, with no second check against the installed set.

### The helper refuses to touch a stored Fedora release upgrade

dnf5 keeps one stored offline transaction, shared by an ordinary offline update and a
`dnf5 system-upgrade download`. All three offline verbs act on whichever is there: staging
replaces it, cleaning deletes it, and arming makes the next restart install it. So before
`dnf-offline-stage`, `dnf-offline-arm` or `dnf-offline-clean`, `kempt-apply` reads dnf5's
`/usr/lib/sysimage/libdnf5/offline/offline-transaction-state.toml` and compares
`system_releasever` with `target_releasever`:

| What is stored | Result |
| --- | --- |
| Nothing (no file) | The verb runs |
| An ordinary offline update (the two are equal) | The verb runs |
| A release upgrade (the two differ) | Exit 3 and one line on stderr, before any privileged command |
| A file that cannot be read, or has no usable release versions | Exit 3 and one line on stderr, before any privileged command |

The last row fails closed. The file and its directory are root-owned, so no unprivileged process
can put it in that state. Refusing leaves the transaction for `sudo dnf5 offline clean` to remove.
Going ahead could arm or delete a download of several gigabytes.

The CLI refuses the offline surface in pre-flight first. The helper's check covers callers that
skip the CLI, such as another process running as you inside the
[retention window](#the-retention-window). The helper parses the file itself, and as root the path
is fixed.

A live upgrade is not refused. `dnf-upgrade` skips this check, and `kempt update` also lets a live
run go ahead while a release upgrade is stored, so ordinary updates keep working while one waits.
That has a cost. dnf5's file stays in place, but the installed packages change under it. dnf5
drops a stored ordinary offline update after a live transaction. Whether it does the same to a
stored release upgrade is not confirmed, and a release upgrade built against the old package set
may fail when it starts. After a live upgrade, download the release upgrade again before
restarting into it.

When `kempt update` gets exit 3, it reports what is stored and runs no other offline verb to clean
up.

### The helper leaves another updater's restart alone

`dnf-offline-clean` also exits 3 while `/system-update` exists and is not a link to dnf5's
offline directory. That path then belongs to another updater, such as PackageKit for Discover,
and its update installs on the next restart. `dnf5 offline clean` would delete the link and cancel
that install [run]. `dnf-offline-stage` and `dnf-offline-arm` are not refused, because neither touches
the link: with another updater's link in place both exit 0 and it stays [run]. `kempt update` itself
stops before them [run]. A link that goes nowhere is refused too [run]. Only root can write to `/`, so
no user can change the answer. As root the path is fixed, as for the state file.

PackageKit deletes this link too. An audit watch caught `packagekitd` removing the link dnf5 had just
made, 0.32 seconds later [run]. So a stage can lose its link with nothing from Kempt involved, and a
clean that runs after that finds nothing to refuse.

## The retention window

`auth_admin_keep` gives one dialog, then a **brief period** in which the same check for the same
action and subject returns yes. polkit's documentation says "e.g. five minutes". Kempt cannot
choose or shorten that window.

For those minutes after you authenticate an update, **any process running as your user can invoke
`kempt-apply` again, with no prompt.** That includes processes you did not start. For a `wheel` user
[the fixed rule](#no-password-at-the-desk) makes this permanent, for that one action id.

polkit's manual says the retained authorization ignores what was passed:

> `polkit.Result.AUTH_ADMIN_KEEP` is returned, authorization checks for the same action
> identifier and subject will succeed (that is, return `polkit.Result.YES`) for the next brief
> period (e.g. five minutes) **even if the variables passed along with the check are different**.
>
> - polkit(8)

and pkexec's manual draws the conclusion:

> However, if an action is used for which the user can retain authorization (or if the user is
> implicitly authorized) this could be a security hole. Therefore, as a rule of thumb, programs
> for which the default required authorization is changed, should never implicitly trust user
> input (e.g. like any other well-written suid program).
>
> - pkexec(1), SECURITY NOTES

So the helpers' argument validation is the **only** thing between the retention window and a root
command line. Neither polkit nor pkexec checks arguments.

What remains is the four verbs. Inside the window, or at any time for a `wheel` user at the desk, a
process running as you can do these without asking you:

- upgrade the system from its configured repositories,
- leave chosen packages out of that upgrade, with `--exclude=<name>`,
- stage an ordinary offline update, with the same choice,
- arm a staged update so the next restart installs it,
- discard a staged update.

It cannot stage over, arm or discard a stored Fedora release upgrade, because all three offline
verbs refuse while one is stored. It can still run a live upgrade, which may leave that release
upgrade out of date (see
[above](#the-helper-refuses-to-touch-a-stored-fedora-release-upgrade)). It cannot install a
package of its choosing, pass an arbitrary flag or run an arbitrary command. That bound is
smaller than sudo, but it is more than nothing.

`--exclude` is how your holds reach dnf5, and the helper cannot tell a caller who typed a password
from one who did not, so it cannot refuse the flag to one of them. Used this way, it can keep a
security fix off the machine for as long as the process keeps doing it. A process running as you can
do the same by editing your holds. `--exclude` lasts one run: `kempt check` still lists the update, and
a later plain run installs it [run]. dnf5's history shows the excluded names in its command line, and
an account outside `wheel` read them there [run]. A run that ends in "Nothing to do" writes no history
row, but `/var/log/dnf5.log` has its arguments, and any account can read that file [run].

Updating Flatpak apps is outside that bound, because the helper has no Flatpak verb. Flatpak's own
policy grants it to an active local session with no password, with or without Kempt.

## What the event log contains

`~/.local/state/kempt/events.log` is created with mode **0600** by the first command that logs.
The retention rewrite goes through `atomic_write`, whose temporary file is also 0600, so the mode
survives every rewrite.

It records the names you hold or unhold, config keys with **their values**, each check's counts,
and run outcomes.

It holds no password, token, polkit cookie or other credential. Kempt handles none: polkit does
all authentication, and the CLI sees only an exit status. It copies no command output either. A
failed run adds one line, at most 120 characters, taken from its own log file. URL credentials,
queries and token-shaped path parts are removed from it first, and your home directory becomes `~`.

The settings line, `Setting <key> changed to <value> (was <old>)`, records values, so pasting `kempt log`
output into a bug report pastes your settings.

## What bounds a malicious update

Everything above controls *who* may start an upgrade and *what* may be said to the package
manager. **What gets installed** is bounded by these:

- **dnf5 verifies package signatures.** Fedora's repository definitions set `gpgcheck=1`, so every
  RPM in a transaction must be signed by a key in the rpm keyring, or the transaction fails. The
  repository configuration in `/etc/yum.repos.d` is root-owned, so adding a repository or turning
  `gpgcheck` off already requires root. Fedora sets `repo_gpgcheck=0`: the **packages** are
  verified, and the repository metadata is unsigned.
- **Flatpak verifies commits.** System remotes are ostree repositories with signed commits, and
  their configuration is root-owned too. Per-user remotes live in your home, and Kempt updates
  them as you, so a per-user remote reaches nothing outside your account.
- **Upgrades still run package scriptlets as root.** An RPM `%post` from any package in the
  transaction runs as root, as it does with `sudo dnf5 upgrade` typed by hand. Kempt adds no
  exposure here and removes none.

**Kempt controls who may ask for an upgrade and what may be said to the package manager. The
package manager and its signing keys control what lands on the disk.** If a machine's configured
repositories are untrustworthy, nothing in this document helps.

## The locale pin is load-bearing

Both helpers `export LC_ALL=C.UTF-8`. pkexec passes `LC_*` through, and under some UTF-8 locales
glibc widens character classes such as `[A-Za-z]`. The same validation regex could then accept
unintended characters. Pinning the locale makes `NAME_RE` match what it says. It also keeps parsed
command output stable.

## Pinned PATH

Both helpers `export PATH=/usr/sbin:/usr/bin:/sbin:/bin` and hand it to dnf5, so that
order also covers programs dnf5 starts; rpm sets its own PATH for scriptlets. This is an extra
layer: pkexec already sanitises the environment.

## The panel widget

The widget adds no privilege. It runs inside `plasmashell`, as you. Everything it does is a
`kempt` command: `check`, `run`, `hold`/`unhold`, `config get`/`set`, a `tail` of the run log and
a `stat` of the watched files. It calls no root helper or polkit action, and holds no credential.

The widget does build shell command lines. Package names arrive in `kempt check`'s JSON and go back
out as `kempt hold <backend>:<name>`. Every value from outside is wrapped in POSIX single quotes
(`shellQuote` in `logic.js`) before it reaches a command line: names, app ids and log paths,
without exception. Only shell expressions the widget wrote itself are unquoted, and they contain no
external data.

## What pkexec sanitises

pkexec resets the environment to a minimal, sanitised set. A hostile `PATH`, `LD_PRELOAD` or `IFS`
cannot reach the privileged process [run].

The helpers also protect themselves. Both start with `#!/usr/bin/bash -p`. In privileged mode, bash
skips `BASH_ENV` and `ENV`, and ignores `SHELLOPTS`, `BASHOPTS`, `CDPATH`, `GLOBIGNORE` and
exported functions. A helper started another way, such as `sudo -E`, still runs none of the
caller's code before its first line. The one setting that could change a decision,
`KEMPT_HELPER_ROOT`, is ignored whenever a helper runs as root.

## No password at the desk

The package installs one polkit rule, `/usr/share/polkit-1/rules.d/49-kempt.rules`. There is no
setting. To be asked for a password, take your account out of `wheel`.

```javascript
polkit.addRule(function(action, subject) {
    if (action.id == "io.github.erez_c137.kempt.apply" &&
        subject.active && subject.local && subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
```

The rule grants one action id. The refresh action needs no password, so it leaves that out. The
apply action is still limited to the helper's verbs and argument checks.

| Who | In a session at the computer, in front | Over SSH |
| --- | --- | --- |
| `wheel` | No password [run] | Refused, no prompt [run] |
| Not `wheel` | An administrator's password. A wrong one is refused [run] | Refused, no prompt [run] |

What it changes is duration. It makes the retention window permanent for a `wheel` user. That is the
trade: any process running as you can do what [the bound](#the-retention-window) lists, whenever
polkit counts it as active and local. Discover offers the same through PackageKit, whose
`system-update` action any active local user gets with no password [run].

Upgrading from 0.2.0 removes the rule its `kempt enable-passwordless` wrote in
`/etc/polkit-1/rules.d`, in the package's `%post`, so an account outside `wheel` that had turned it on
is asked again [run]. Removing the package removes the rule [run].

### A program with no session of its own

"Over SSH, refused" is true for a program in the SSH session. It is not true for a program that asks
your user manager to start it, which has no login session. polkit judges that process by your session
at the computer, so it reports `local=true` with no session at all. So this, typed over SSH, ran a real
update with no password [run]:

```bash
systemd-run --user --wait --pipe pkexec /usr/libexec/kempt-apply dnf-upgrade -y
```

polkit's "active" follows the account and not one session. While any session of yours is active, an
SSH login included, a program in your session at the computer reads as active even when that session is
switched away. This is what `io.github.erez_c137.kempt.apply` answered for a `wheel` user [run]:

| In front at the computer | Your SSH login open | Program in your session at the computer | Program with no session |
| --- | --- | --- | --- |
| Your session | No | Allowed | Allowed |
| Your session | Yes | Allowed | Allowed |
| Another user's session | No | Refused | Refused |
| Another user's session | Yes | Allowed | Allowed |

An account with no session at the computer gets nothing this way [run]. PackageKit's `system-update`
action needs no password in the same rows and asks for an administrator's password in the refused
ones, for any user at the computer [run].

So anyone who can run commands as you over SSH, while you are logged in at the computer, can reach
the same verbs. They can also already change your files and your holds.

## Accepted limitations

- **Running Flatpak as you still leaves one possible prompt.** `flatpak update` can pull in a
  runtime that is missing. Installing one is `runtime-install`, which is `auth_admin_keep` by
  default. Fedora ships `/usr/share/polkit-1/rules.d/org.freedesktop.Flatpak.rules`, which allows
  that for a `wheel` member in an active local session. On a distribution without that file, or
  for a user outside `wheel`, it can still raise one dialog.
- **`allow_active=yes` covers only an active local session.** Over SSH the check falls to
  `allow_inactive` / `allow_any`, both `auth_admin`. So the Flatpak half of a run over SSH must
  authenticate against Flatpak's own action. With a terminal, that is a prompt: `flatpak` links
  `libpolkit-agent-1` and registers its own text listener
  (`flatpak_polkit_agent_text_listener_new`), as `pkexec` does. Without a terminal, such as a cron
  job or a headless runner, the call is refused. Neither case is tested.
- **The tests' setting lives in root-owned code.** `KEMPT_HELPER_ROOT` is read only when a helper is
  not root. It is there, and a test fails if that condition goes.
- **The checkout is load-bearing for a developer.** Anyone who can write to your Kempt checkout
  controls what your user runs from it. Keep it in your own home or workspace. Root-owned files are
  unaffected.
- **Anyone at the computer can keep the package lists busy.** The no-dialog refresh is open to any
  active local user, as PackageKit's is [run]. Each check or refresh runs one at a time and ends
  within two minutes. A second one stops at once, and a refresh does not block an update, even with
  another process refreshing in a loop [run].
- **Two accounts' updates are kept apart by dnf5, not by Kempt.** A second update waits for the
  running transaction, and a check waits too. A check that runs out behind another account's long
  update says the check failed, and the update is unharmed [run]. An update or a clean started
  beside a download makes the later step fail with nothing installed [run].
- **Removing unused runtimes is system scope only.** Runtimes installed for you only are updated,
  and never removed.
- **Holds apply to Kempt only.** A manual `sudo dnf5 upgrade` ignores them.
- **Inside the retention window, an armed offline transaction can be replaced without a prompt.**
  `dnf-offline-stage` is covered by the window, and staging over a transaction replaces it. For a
  few minutes after you authenticate a stage, another process running as you can swap the
  transaction your next restart will install, with no dialog. The same bound applies. It can stage
  only what a Kempt run would stage, and the helper refuses to replace a stored Fedora release
  upgrade. Kempt keeps no copy to compare with, so it describes what dnf5 holds, and `kempt doctor`
  and the update list show it. A replacement cannot be detected as a replacement.
- **dnf5 publishes the staged package list to every account on the machine.** The stored
  transaction is `/usr/lib/sysimage/libdnf5/offline/transaction.json`, `root:root` mode 644 in a
  755 directory. It holds the full resolved NEVRA list, so any local user can read which packages
  the machine is about to install. This is dnf5's design, independent of Kempt, and it lets an
  unprivileged `kempt check` read a stage. Kempt keeps no second copy, but this one remains.
