# Security model

Kempt updates your system, so some of it necessarily runs as root. This document says exactly
which parts, what they are allowed to do, and what the optional passwordless mode gives away.

To report a vulnerability, see [SECURITY.md](../SECURITY.md).

## What runs as root

Two files, and nothing else:

- `kempt-refresh` - package metadata only.
- `kempt-apply` - the dnf upgrade verbs.

They are `/usr/libexec/kempt-{refresh,apply}` from the package and `/usr/local/libexec/...` from a
checkout install. The polkit action's `exec.path` pins whichever this build uses, and `kempt doctor`
prints it: the two can never be reconciled at runtime, because pkexec matches an action by that
path and by nothing else.

Both are `root:root` 0755 **copies** either way, installed once by `install.sh` or owned by the
package. The CLI itself, its library and the backends never run as root.

On a checkout install, that split does a second job: the CLI is a symlink into a user-writable git
checkout, so editing the repo changes what your user runs and can never change what root runs.
Replacing the privileged half requires root already. A packaged install has no user-writable half
to reason about - the whole tree under `/usr/share/kempt` is root-owned.

## Two polkit actions, on purpose

polkit's `auth_admin_keep` caches an authorization **per action id**, not per argument. A single
action covering both "refresh metadata" (cheap, frequent, runs from a background timer) and
"upgrade the system" (dangerous) would mean that authorizing one silently authorizes the other
for the whole cache window. So there are two, each bound by `exec.path` to exactly one helper:

| Action | Helper | Verbs | Policy for an active local session |
| --- | --- | --- | --- |
| `io.github.erez_c137.kempt.refresh` | `kempt-refresh` | `check`, `refresh` | `yes` - no dialog |
| `io.github.erez_c137.kempt.apply` | `kempt-apply` | `dnf-upgrade`, `dnf-offline-stage`, `dnf-offline-arm`, `dnf-offline-clean` | `auth_admin_keep` - one dialog per run |

Both actions set `allow_any=no` and `allow_inactive=no`: nothing is granted to a remote or
inactive session.

The no-dialog refresh action is the same pattern PackageKit uses for its own metadata refresh,
and it is what makes the badge trustworthy: the check reads the **root** metadata cache that the
update will use, instead of a separate user cache that can disagree. All it can do is
`dnf5 --cacheonly check-update --quiet` and `dnf5 makecache --refresh`.

Refresh calls carry a 120 second timeout, because they run from background checks and a surprise
authentication dialog would otherwise hang forever with nobody there to answer it. Apply calls
are deliberately untimed: waiting for a human to authenticate is the legitimate flow there.

**The Flatpak metadata refresh is not on this table, and that is deliberate.** Kempt fetches the
Flatpak remote's summary in the same step as the dnf refresh, but it runs it **as you**: no
`pkexec`, no polkit action, no root helper. It does not need root, because the system remote's
summary as an unprivileged user sees it is cached in that user's own
`~/.cache/flatpak/system-cache/summaries/`. A root-owned Flatpak cache exists
(`/var/lib/flatpak/appstream`, written by `flatpak update --appstream`), and Kempt does not touch
it - it is not what the check reads, so filling it would mean a third privileged verb for no
benefit at all.

**Applying Flatpak updates does not escalate either, and that is the newer half of the answer.**
`flatpak update --system` asks polkit for `org.freedesktop.Flatpak.app-update` and
`runtime-update`, and the policy Flatpak itself ships answers `yes` for an active local session,
with no password. Kempt used to route the apply through `kempt-apply` anyway, which put it behind
that helper's `auth_admin_keep` action: a run with nothing but app updates in it then asked for a
password that plain `flatpak update` never asks for. It now runs as you, exactly as you would
type it. What that removes is the **guaranteed** prompt rather than every possible one; the two
cases that can still authenticate are recorded under [Accepted limitations](#accepted-limitations).

## Validate before exec

Neither helper forwards a caller-supplied argument. Each one parses what it was given, validates
it, and then builds the command itself. Anything unexpected exits 2 **before** any privileged
command runs.

`kempt-refresh` takes exactly one argument, `check` or `refresh`. Extra arguments are refused
rather than ignored, so a caller cannot believe it passed something that was silently dropped.

`kempt-apply` accepts:

| Verb | Accepted arguments | Validation |
| --- | --- | --- |
| `dnf-upgrade`, `dnf-offline-stage` | `-y`, `--exclude=<name>` | `<name>` must match `^[A-Za-z0-9][A-Za-z0-9._+-]*$` |
| `dnf-offline-arm` | none | Any argument at all exits 2 |
| `dnf-offline-clean` | none | Any argument at all exits 2 |

The two offline verbs are the smallest attack surface in the helper: each builds one fixed
command with no caller input in it whatsoever, so there is nothing to validate beyond refusing
arguments outright. Refusing rather than ignoring matters here too - dnf5's offline subcommands
accept flags of their own (`--installroot`, `--releasever`), and a helper that silently dropped
one would let a caller believe a scope had been honoured.

`dnf-offline-arm` runs `env DNF_SYSTEM_UPGRADE_NO_REBOOT=1 dnf5 offline reboot -y`. It applies
nothing and installs nothing: it marks an already-downloaded transaction ready and creates
`/system-update`, which is what systemd's offline-update generator looks for at the next boot.
The environment variable is not a nicety - without it, dnf5 reboots the machine the moment the
transaction is armed. `dnf-offline-clean` runs `dnf5 offline clean -y`, which discards a staged
transaction; the worst it can do is throw away updates that had not been installed yet.

They share the apply action rather than getting one of their own because they are part of the
same operation as the stage: `auth_admin_keep` is what lets one dialog cover a stage and the arm
made seconds later, and splitting them would mean two dialogs for one button press.

So `--exclude=foo;rm -rf /` and `--installroot=/` are rejected outright. So is `flatpak-update`:
that verb was removed when applying Flatpak updates stopped crossing the privilege boundary at
all, and an old caller that still asks for it gets exit 2 rather than a privileged flatpak.

The unprivileged Flatpak apply in `backends/flatpak.sh` validates app ids against the same
pattern, for a reason that outlives the boundary: ids arrive from a **remote's** summary, and the
pattern being anchored on its first character is what stops a name such as `--installation=other`
from reaching `flatpak` as an option. What it no longer does is re-check them against the
installed set. That check existed because a root helper must distrust its caller's argv; on this
side of the boundary the ids were built a few lines from the call, out of the same
`flatpak list --system` any re-check would have consulted.

One more layer sits in front of all of it: the CLI validates hold names with the same regular
expression at `kempt hold` time, so a name the helper would later reject is rejected while a
human is still watching.

## What the retention window actually means

`auth_admin_keep` is not "one dialog per run" in any enforceable sense. It is one dialog, and
then a **brief period** (polkit's own documentation says "e.g. five minutes") during which the
same authorization check for the same action and the same subject simply returns yes. Kempt
does not choose that window and cannot shorten it.

So the honest statement is: for a few minutes after you authenticate an update, **any process
running as your user can invoke `kempt-apply` again and it will run, with no prompt at all.**
Not just the run you authorized. Anything on your session, including something you did not
start. Passwordless mode is the same condition made permanent, which is the real reason it is
opt-in and scoped to one action id.

polkit's manual is explicit that the retained authorization ignores what was passed:

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

That is the authority the section above answers. Argument validation in the helpers is not
defense in depth against a threat that mostly cannot happen; it is the **only** thing standing
between the retention window and a root command line, because polkit will not check the arguments
for you and pkexec explicitly does not.

What is left after the validation is the verb list itself. Inside the window (or under
passwordless mode) a process running as you can upgrade the system or stage an offline
transaction, without asking you. It cannot install a package of its choosing, pass an arbitrary
flag, run an arbitrary command, or reach anything outside those two verbs. That is the bound. It
is a real one, and it is smaller than "sudo", but it is not "nothing".

Updating Flatpak apps is no longer inside that bound, because it is no longer inside the helper.
It is bounded by Flatpak's own policy instead, which grants it to an active local session with no
password whether Kempt is installed or not.

## What the event log contains

`~/.local/state/kempt/events.log` is created mode **0600** by whichever command logs first, and
the retention rewrite goes through `atomic_write`, whose temp file is 0600 too, so the mode
survives every replace.

What is in it: package and app names you hold or unhold, config keys and **their values**, the
pending and held counts each check produced, run outcomes, and the exit status of an
`enable-passwordless` or `disable-passwordless` attempt. In other words the same class of
information as the config file and the state file sitting beside it, in one place and with
timestamps.

What is never in it: a password, a token, a polkit cookie or any other credential. Kempt never
handles one - authentication is entirely polkit's, and the CLI only ever sees an exit status.
Nor does it capture command output: a failed run contributes one line, capped at 120 characters,
taken from its own log file; the log file itself is not copied.

The line most worth knowing about is the config one, `config set <key>=<value> (was <old>)`,
because it records values rather than just key names. That is deliberate - a log that said only
"a setting changed" would not answer the question it exists to answer - and it is why the file is
0600 rather than 0644. If you paste `kempt log` output into a bug report, it is your settings you
are pasting.

## What bounds a malicious update

Everything above is about *who* may start an upgrade and *what* may be said to the package
manager. None of it says anything about **what gets installed**, and an upgrade is by
construction root running code somebody else wrote. What bounds that is not Kempt:

- **dnf5 verifies package signatures.** Fedora's shipped repository definitions set
  `gpgcheck=1`, so every RPM in a transaction must be signed by a key in the rpm keyring or the
  transaction fails. The repository configuration that says so lives in `/etc/yum.repos.d`, which
  is root-owned: adding a repository, or turning `gpgcheck` off, already requires root. Worth
  knowing precisely: Fedora sets `repo_gpgcheck=0`, so it is the **packages** that are verified,
  not the repository metadata.
- **Flatpak verifies commits.** System remotes are ostree repositories whose commits are signed,
  and the remote configuration is root-owned the same way. Kempt only ever touches `--system`
  scope, so a per-user remote a user added for themselves is outside what the helper will act on.
- **Upgrade verbs still run vendor scriptlets as root.** An RPM `%post` from any package in the
  transaction runs as root, and Kempt has no say in that whatsoever. This is equally true of
  `sudo dnf5 upgrade` typed by hand; Kempt neither adds nor removes that exposure, and no amount
  of argument validation could.

The trust model, stated plainly: **Kempt controls who may ask for an upgrade and what may be
said to the package manager. The package manager and its signing keys control what actually
lands on the disk.** If the repositories configured on a machine are not trustworthy, nothing in
this document helps.

## The locale pin is load-bearing

Both helpers `export LC_ALL=C.UTF-8`. This is not cosmetic. pkexec passes `LC_*` through, and
glibc widens character classes such as `[A-Za-z]` under some UTF-8 locales, so the same
validation regex can accept characters you never intended to allow. Pinning the locale makes
`NAME_RE` mean exactly what it reads as, and it keeps parsed command output stable at the same
time.

## Pinned PATH

Both helpers `export PATH=/usr/sbin:/usr/bin:/sbin:/bin`. Exported, not merely set, so the pinned
lookup order also applies to the children dnf5 spawns - rpm scriptlets run as root too. This is
defense in depth: pkexec already sanitizes the environment.

## The panel widget

The widget adds no privilege of its own. It runs inside `plasmashell`, as you, and every single
thing it does is a `kempt` command: `check`, `run`, `hold`/`unhold`, `config get`/`set`, a `tail`
of the run log and a `stat` of the watched files. It never calls a root helper, never touches
polkit, and holds no credential. So the privileged boundary above is exactly the same one whether
you type the commands or click them.

What it does own is a shell command line, and that is a real surface: package names arrive from
`kempt check`'s JSON and go back out as `kempt hold <backend>:<name>`. Every value that came from
outside is wrapped in POSIX single quotes (`shellQuote` in `logic.js`) before it reaches a command
line - names, app ids, log paths, without exception and with no per-case judgement about which
values look safe. Only shell expressions the widget wrote itself are left unquoted, and those
contain no external data.

Two buttons on its settings page run `kempt enable-passwordless` and `kempt disable-passwordless`.
Those are the same commands documented below, with the same `pkexec` dialog and the same rendered,
self-checked rule: the widget is a launcher for them, not a second path into `/etc/polkit-1`.

## What pkexec sanitizes

pkexec does not pass the caller's environment through. It resets to a minimal, sanitized set, so
a hostile `PATH`, `LD_PRELOAD` or `IFS` cannot ride into the privileged process. One useful
consequence: the `KEMPT_APPLY_ECHO` and `KEMPT_REFRESH_ECHO` test seams inside the helpers
cannot be triggered from outside a test harness, because the variable never survives the
transition. They only ever print a command line instead of running it.

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

What it grants, exactly: **one action id, one user, and only in a session that is both active and
local.** An SSH session gets nothing. A switched-away session gets nothing. Another user gets
nothing. The refresh action is not mentioned because it never asked for a password anyway. And
everything the apply action can do is still bounded by the helper's verb list and its argument
validation, so this is a shortcut past the dialog, not a shortcut past the rules.

What it does change is duration: this is the retention window above, made permanent. Any process
running as you, in your active local session, can apply updates for as long as the rule is
installed. That is the trade, and it is why the command that installs it is separate, opt-in and
one line to undo.

The rendering path is hardened, because a rule file is a security boundary that a template
substitution could quietly break:

- The username comes from `id -un`, never `$USER`. A crafted `USER` environment variable used to
  be substituted into the render and could drop the scope clause entirely.
- The name must match `^[a-z_][a-z0-9._-]*$`. That also keeps it clear of substitution
  metacharacters. A name that does not match aborts with an instruction to install the file by
  hand.
- Substitution is `awk -v`, which never reinterprets the value as a pattern.
- **The rendered file is verified before it is installed.** Comment lines are stripped first, and
  what remains must contain the `subject.active && subject.local` scope test, must contain the
  exact action id, and must contain exactly one `polkit.addRule`. If any of those fail, nothing
  is written and the command exits 2. That catches the three ways a broken template turns into a
  broken grant: losing the scope test (grants to inactive and remote sessions), losing the action
  id (grants **every** polkit action), or gaining a second rule block that could say anything.
- The destination is pinned before use, because that path is handed to a root `install(1)`.
  polkit reads **four** rules directories, in this order (polkit(8)):

  ```
  /etc/polkit-1/rules.d
  /run/polkit-1/rules.d
  /usr/local/share/polkit-1/rules.d
  /usr/share/polkit-1/rules.d
  ```

  Kempt pins the administrator's one, `/etc/polkit-1/rules.d`, because the other three belong to
  the runtime and to packages. So the destination must be an absolute path ending in `.rules`,
  and either inside `/etc/polkit-1/rules.d/` or outside every system prefix (`/etc`, `/run`,
  `/usr`, `/var`, `/boot`, `/opt`) - the last case being what the test seam uses. Anything else
  is refused: it would only ever plant a root-owned file somewhere that reads it. Fencing `/etc`
  alone was not enough, and this is the bug that made the list explicit: it left the other three
  polkit directories open, including `/usr/share/polkit-1/rules.d/50-default.rules`, a file
  Fedora actually ships, as well as unrelated `.rules` consumers such as
  `/usr/lib/udev/rules.d/`. The comparison runs on the `realpath -m` form, so `..` cannot walk a
  destination out of the directory it claims to be in.
- Installation is a single `pkexec install -m 0644 -o root -g root`.

`kempt disable-passwordless` removes the file. It reports "not enabled" only when it can
actually search the directory: the real `/etc/polkit-1/rules.d` is 0750 `root:polkitd`, where an
unprivileged existence test answers "absent" for a file that is really there. Claiming "not
enabled" in that case would leave a live grant in place, so the removal goes ahead instead.

## Accepted limitations

Recorded here rather than quietly fixed later:

- **Dropping Kempt's Flatpak prompt does not drop every possible prompt.** `flatpak update` can
  pull in a runtime that is not installed yet, and installing one is `runtime-install`, which is
  `auth_admin_keep` by default. Fedora ships
  `/usr/share/polkit-1/rules.d/org.freedesktop.Flatpak.rules`, which answers yes to that for a
  `wheel` member in an active local session, so the case is silent here; on a distribution
  without such a file, or for a user outside `wheel`, it can still raise one dialog.
- **`allow_active=yes` means an active local session.** Over SSH the check falls to
  `allow_inactive` / `allow_any`, which are both `auth_admin`, so the Flatpak half of a run typed
  over SSH now has to authenticate against Flatpak's own action instead of Kempt's. That is a
  prompt rather than a refusal in an interactive session: `flatpak` links `libpolkit-agent-1` and
  registers its own text listener (`flatpak_polkit_agent_text_listener_new`), the same way
  `pkexec` does, so an SSH session with a terminal is asked. Without a terminal to ask on - a
  cron job, a headless runner - neither tool has anywhere to put the question, and the call is
  refused instead. Not tested here either way. The widget and the terminal surface are local
  desktop sessions, which is the path this is written for.
- **The `*_ECHO` seams live in root-owned code.** They are unreachable through pkexec (see
  above) and they only print, but they are there.
- **The rules destination has a test-seam escape hatch.** Any path outside the six system
  prefixes is accepted, a home directory included, because that is how the suite drives the
  real install path; no polkit rules directory is reachable that way, so it grants no policy
  escalation.
- **The checkout is load-bearing.** Anyone who can write to your Kempt checkout controls what
  your user runs, including the passwordless rules template that `enable-passwordless` renders
  before handing the result to root. Keep the checkout in your own home or workspace, never
  somewhere group- or world-writable. Root-owned files are unaffected either way.
- **Flatpak is system scope only** in v1, so a per-user app is never counted and never updated.
- **Holds are not a system-wide lock.** They are Kempt's own exclusion list; a manual
  `sudo dnf5 upgrade` ignores them.
- **`install.sh` runs one `pkexec bash -c`**, with every repo path passed as a positional
  argument rather than interpolated into the script text, so a checkout path containing a quote
  cannot break or inject into the root command.
- **Inside the retention window, an armed offline transaction can be replaced without a prompt.**
  `dnf-offline-stage` is one of the two verbs the window covers, and staging over an existing
  transaction is a replace: dnf5 destroys the old one and builds a new one. So for the few minutes
  after you authenticate a stage, another process running as you can swap the transaction your
  next restart will install, with no dialog to notice. This is the retention window described
  above rather than anything specific to the offline path, and the same bound applies: it can
  stage what a Kempt run would stage, not a package of its choosing. What limits it today is the
  window's own length, which Kempt does not set and cannot shorten. What is no longer invisible is
  the swap itself: `kempt doctor` now compares Kempt's marker against dnf5's stored transaction and
  FAILs with both directions of the difference when they disagree. That makes a replacement
  detectable after the fact; it does not prevent one.
- **dnf5 publishes the staged package list to every account on the box.** The stored transaction
  lives at `/usr/lib/sysimage/libdnf5/offline/transaction.json`, `root:root` mode 644 in a 755
  directory (verified in a container, 2026-09-05), and it carries the full resolved NEVRA list. So
  the set of packages a machine is about to install is readable by any local user, by dnf5's
  design and independently of Kempt: it is what lets an unprivileged `kempt check` reconcile a
  stage at all. Kempt's own marker is 0600 and adds no second copy, but it does not remove this
  one either.
