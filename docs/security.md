# Security model

Kempt updates your system, so some of it runs as root. This page lists what runs as root, what it
accepts and refuses, and what passwordless mode grants.

To report a vulnerability, see [SECURITY.md](../SECURITY.md).

## What runs as root

Two helpers, reached through Kempt's own polkit actions:

- `kempt-refresh`: package metadata only.
- `kempt-apply`: the dnf upgrade verbs.

Two more commands run as root, only when you run them. Each raises its own `pkexec` prompt through
pkexec's generic authentication, outside Kempt's actions. `kempt enable-passwordless` runs
`install(1)` to write one polkit rule, and `kempt disable-passwordless` runs `rm -f` on that file.
Both are fixed to `/etc/polkit-1/rules.d/49-kempt.rules` (see
[Passwordless mode](#passwordless-mode)). A checkout install also runs one `pkexec bash -c` from
`install.sh` (see [Accepted limitations](#accepted-limitations)).

The helpers are `/usr/libexec/kempt-{refresh,apply}` from the package and
`/usr/local/libexec/...` from a checkout install. Each polkit action's `exec.path` pins the path
for that build, and `kempt doctor` prints it. pkexec matches an action by that path alone.

Either way, both helpers are `root:root` 0755 **copies**, installed once by `install.sh` or owned
by the package. The CLI, its library and the backends run as you.

On a checkout install, the CLI is a symlink into a git checkout you can write to. Editing the
checkout changes what your user runs, and cannot change what root runs. Replacing the root half
already requires root. On a packaged install, the whole tree under `/usr/share/kempt` is
root-owned.

## Two polkit actions

polkit's `auth_admin_keep` caches an authorization **per action id**, whatever the arguments. With
one action for both metadata refresh and upgrades, authorizing one would authorize the other for
the whole cache window. So there are two, each bound by `exec.path` to one helper:

| Action | Helper | Verbs | Policy for an active local session |
| --- | --- | --- | --- |
| `io.github.erez_c137.kempt.refresh` | `kempt-refresh` | `check`, `refresh` | `yes`: no dialog |
| `io.github.erez_c137.kempt.apply` | `kempt-apply` | `dnf-upgrade`, `dnf-offline-stage`, `dnf-offline-arm`, `dnf-offline-clean` | `auth_admin_keep`: one dialog per run |

Both actions set `allow_any=no` and `allow_inactive=no`, so polkit refuses a remote or inactive
session without a dialog. A check from an SSH session or a switched-away
session fails with `not authorized - the password was refused, or this session cannot authorize
(over SSH or switched away)`.

The no-dialog refresh lets the check read the **root** metadata cache that the update will use.
It can run only `dnf5 --cacheonly check-update --quiet` and `dnf5 makecache --refresh`.

Refresh calls time out after 120 seconds, because nobody is there to answer a dialog during a
background check. Apply calls have no timeout.

**The Flatpak metadata refresh runs as you**, with no `pkexec`, polkit action or root helper. It
fills your own `~/.cache/flatpak/system-cache/summaries/`, which is what the check reads. Kempt
leaves the root-owned `/var/lib/flatpak/appstream` cache alone.

**Applying Flatpak updates also runs as you.** `flatpak update --system` asks polkit for
`org.freedesktop.Flatpak.app-update` and `runtime-update`. Flatpak's own policy answers `yes` for
an active local session, with no password. Two cases can still ask for authentication; see
[Accepted limitations](#accepted-limitations).

## Validate before exec

Neither helper forwards an argument it was given. Each parses its arguments, validates them, and
builds the command itself. Anything unexpected exits 2 **before** any privileged command runs.

`kempt-refresh` takes one argument, `check` or `refresh`. Extra arguments are refused.

`kempt-apply` accepts:

| Verb | Accepted arguments | Validation |
| --- | --- | --- |
| `dnf-upgrade`, `dnf-offline-stage` | `-y`, `--exclude=<name>` | `<name>` must match `^[A-Za-z0-9][A-Za-z0-9._+-]*$` |
| `dnf-offline-arm` | none | Any argument at all exits 2 |
| `dnf-offline-clean` | none | Any argument at all exits 2 |

So `--exclude=foo;rm -rf /` and `--installroot=/` are rejected. The two argument-free verbs each
build one fixed command with no caller input. They refuse any argument, because dnf5's offline
subcommands accept flags of their own (`--installroot`, `--releasever`). Silently dropping one
would let a caller believe it had been honoured.

The removed `flatpak-update` verb also exits 2, so an old caller cannot get a privileged flatpak.

`dnf-offline-arm` runs `env DNF_SYSTEM_UPGRADE_NO_REBOOT=1 dnf5 offline reboot -y`. It installs
nothing. It marks an already-downloaded transaction ready and creates `/system-update`, which
systemd's offline-update generator looks for at the next boot. Without the environment variable,
dnf5 would reboot the moment the transaction is armed.

`dnf-offline-clean` runs `dnf5 offline clean -y`, which discards a staged transaction. At worst it
throws away updates that were still waiting to install.

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
[retention window](#the-retention-window). The helper parses the file itself, without sourcing
Kempt's library. When it runs as root, the path is fixed: the `KEMPT_OFFLINE_TOML` test setting is
honoured only for an unprivileged caller.

`dnf-upgrade` skips this check, because a live upgrade leaves the stored transaction alone. When
`kempt update` gets exit 3, it reports what is stored and runs no other offline verb to clean up.

## The retention window

`auth_admin_keep` gives one dialog, then a **brief period** in which the same check for the same
action and subject returns yes. polkit's documentation says "e.g. five minutes". Kempt cannot
choose or shorten that window.

For those minutes after you authenticate an update, **any process running as your user can invoke
`kempt-apply` again, with no prompt.** That includes processes you did not start. Passwordless mode
makes this permanent, which is why it is opt-in and scoped to one action id.

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

What remains is the four verbs. Inside the window, or under passwordless mode, a process running
as you can do these without asking you:

- upgrade the system from its configured repositories,
- stage an ordinary offline update,
- arm a staged update so the next restart installs it,
- discard a staged update.

It cannot stage over, arm or discard a stored Fedora release upgrade, because all three offline
verbs refuse while one is stored. It cannot install a package of its choosing, pass an arbitrary
flag or run an arbitrary command. That bound is smaller than sudo, but it is more than nothing.

Updating Flatpak apps is outside that bound, because the helper has no Flatpak verb. Flatpak's own
policy grants it to an active local session with no password, with or without Kempt.

## What the event log contains

`~/.local/state/kempt/events.log` is created with mode **0600** by the first command that logs.
The retention rewrite goes through `atomic_write`, whose temporary file is also 0600, so the mode
survives every rewrite.

It records the names you hold or unhold, config keys with **their values**, each check's counts,
run outcomes, and the exit status of each `enable-passwordless` or `disable-passwordless` run.

It holds no password, token, polkit cookie or other credential. Kempt handles none: polkit does
all authentication, and the CLI sees only an exit status. It copies no command output either. A
failed run adds one line, at most 120 characters, taken from its own log file.

The config line, `config set <key>=<value> (was <old>)`, records values, so pasting `kempt log`
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
  their configuration is root-owned too. Kempt updates only `--system` scope, so a per-user remote
  is outside what Kempt acts on.
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

Both helpers `export PATH=/usr/sbin:/usr/bin:/sbin:/bin`. It is exported, so the pinned lookup
order also applies to the children dnf5 starts, including rpm scriptlets running as root. This is
an extra layer: pkexec already sanitises the environment.

## The panel widget

The widget adds no privilege. It runs inside `plasmashell`, as you. Everything it does is a
`kempt` command: `check`, `run`, `hold`/`unhold`, `config get`/`set`, a `tail` of the run log and
a `stat` of the watched files. It calls no root helper or polkit action, and holds no credential.

The widget does build shell command lines. Package names arrive in `kempt check`'s JSON and go back
out as `kempt hold <backend>:<name>`. Every value from outside is wrapped in POSIX single quotes
(`shellQuote` in `logic.js`) before it reaches a command line: names, app ids and log paths,
without exception. Only shell expressions the widget wrote itself are unquoted, and they contain no
external data.

Two buttons on its settings page run `kempt enable-passwordless` and `kempt disable-passwordless`,
with the same `pkexec` dialog and checked rule. The widget has no other path into `/etc/polkit-1`.

## What pkexec sanitises

pkexec resets the environment to a minimal, sanitised set. A hostile `PATH`, `LD_PRELOAD` or `IFS`
cannot reach the privileged process. So the `KEMPT_APPLY_ECHO` and `KEMPT_REFRESH_ECHO` test
settings in the helpers cannot be triggered through pkexec. All they do is print a command line in
place of running it.

The helpers also protect themselves. Both start with `#!/usr/bin/bash -p`. In privileged mode, bash
skips `BASH_ENV` and `ENV`, and ignores `SHELLOPTS`, `BASHOPTS`, `CDPATH`, `GLOBIGNORE` and
exported functions. A helper started another way, such as `sudo -E`, still runs none of the
caller's code before its first line. The one setting that could change a decision,
`KEMPT_OFFLINE_TOML` in `kempt-apply`, is ignored whenever the helper runs as root.

## Passwordless mode

`kempt enable-passwordless` installs one polkit rule at
`/etc/polkit-1/rules.d/49-kempt.rules`:

```javascript
polkit.addRule(function(action, subject) {
    if (action.id == "io.github.erez_c137.kempt.apply" &&
        subject.user == "you" && subject.active && subject.local) {
        return polkit.Result.YES;
    }
});
```

It grants **one action id, to one user, only in a session that is both active and local.** An SSH
session, a switched-away session and any other user get nothing. The refresh action needs no
password, so the rule leaves it out. The apply action is still limited to the helper's verbs and
argument checks. The rule skips the dialog and keeps every check.

What it changes is duration. It makes the retention window permanent: any process running as you,
in your active local session, can apply updates while the rule is installed. That is the trade,
and why the command is separate, opt-in and one line to undo.

Rendering the rule is hardened against a template substitution that breaks it:

- The username comes from `id -un`. `$USER` is ignored, so a crafted `USER` variable cannot change
  it.
- The name must match `^[a-z_][a-z0-9._-]*$`, which also keeps substitution metacharacters out.
  Any other name aborts, with an instruction to install the file by hand.
- Substitution uses `awk -v`, which treats the value as plain text.
- **The rendered rule must equal the one rule this command may install.** Comment lines are
  stripped and the rest is collapsed to one whitespace-normalised line. That line is compared with
  a single string in `lib/common.sh`. Anything else, one token different or one clause more, writes
  nothing and exits 2.

  Equality catches additions. A rule with every required clause plus an unconditional
  `if (subject.user == "you") return polkit.Result.YES;` would grant passwordless root for every
  polkit action, from any session. This is the only file Kempt can write that grants root.
  Re-indenting the template is fine; changing what it says means changing the string in
  `lib/common.sh` too.
- **Root installs the bytes that were checked.** The rule is rendered and checked in memory, then
  piped to `pkexec install -m 0644 -o root -g root /dev/stdin`. No rendered file exists on disk
  for a process running as you to rewrite while the dialog waits. pkexec asks for the password
  through its agent or the terminal, separate from stdin.
- **The destination is fixed**, because it is handed to a root `install(1)` and a root `rm`.
  polkit reads **four** rules directories, in this order (polkit(8)):

  ```
  /etc/polkit-1/rules.d
  /run/polkit-1/rules.d
  /usr/local/share/polkit-1/rules.d
  /usr/share/polkit-1/rules.d
  ```

  Kempt uses one file in the administrator's directory: `/etc/polkit-1/rules.d/49-kempt.rules`.
  Every directory on that path is root-owned, so nothing running as you can swap one for a symlink
  between a check and the write. An allow-list of directories would fall short, because a check on
  a path you can write to can be defeated after it passes.

  The `KEMPT_RULES_DST` test setting changes the destination only when there is no pkexec wrapper
  and Kempt runs unprivileged. Then the install and removal run as you, and can write only what you
  could already write. In any other run the setting is refused with exit 2.

`kempt disable-passwordless` removes the file. It reports "not enabled" only when it can search
the directory. The real `/etc/polkit-1/rules.d` is 0750 `root:polkitd`, where an unprivileged
test reports a present file as absent. There it runs the removal anyway, so a live grant is never
left in place.

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
- **The `*_ECHO` settings live in root-owned code.** They are unreachable through pkexec and they
  only print, but they are there. So is `KEMPT_OFFLINE_TOML` in `kempt-apply`, which the helper
  ignores whenever it runs as root.
- **The rules destination has a test setting.** `KEMPT_RULES_DST` redirects `enable-passwordless`
  and `disable-passwordless`, only in an unprivileged run with no pkexec wrapper. There both
  commands run as you, so the setting cannot reach a root write.
- **The checkout is load-bearing.** Anyone who can write to your Kempt checkout controls what your
  user runs. That includes the passwordless rules template, which `enable-passwordless` renders
  before handing the result to root. Keep the checkout in your own home or workspace, and out of
  anywhere group- or world-writable. Root-owned files are unaffected.
- **Flatpak is system scope only** in v1, so a per-user app is neither counted nor updated.
- **Holds apply to Kempt only.** They are Kempt's own exclusion list; a manual
  `sudo dnf5 upgrade` ignores them.
- **`install.sh` runs one `pkexec bash -c`.** Every repo path is passed as a positional argument,
  outside the script text. A checkout path containing a quote cannot break or inject into the root
  command.
- **Inside the retention window, an armed offline transaction can be replaced without a prompt.**
  `dnf-offline-stage` is covered by the window, and staging over a transaction replaces it. For a
  few minutes after you authenticate a stage, another process running as you can swap the
  transaction your next restart will install, with no dialog. The same
  bound applies. It can stage only what a Kempt run would stage, and the helper refuses to replace
  a stored Fedora release upgrade. `kempt doctor` compares Kempt's marker with dnf5's stored
  transaction. When they disagree, it FAILs and lists the differences both ways. That detects a
  replacement afterwards; it cannot prevent one.
- **dnf5 publishes the staged package list to every account on the machine.** The stored
  transaction is `/usr/lib/sysimage/libdnf5/offline/transaction.json`, `root:root` mode 644 in a
  755 directory. It holds the full resolved NEVRA list, so any local user can read which packages
  the machine is about to install. This is dnf5's design, independent of Kempt, and it lets an
  unprivileged `kempt check` reconcile a stage. Kempt's own marker is 0600 and adds no second copy,
  but this one remains.
