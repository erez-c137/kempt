# Security model

Kempt updates your system, so some of it necessarily runs as root. This document says exactly
which parts, what they are allowed to do, and what the optional passwordless mode gives away.

To report a vulnerability, see [SECURITY.md](../SECURITY.md).

## What runs as root

Two files, and nothing else:

- `/usr/local/libexec/kempt-refresh` - package metadata only.
- `/usr/local/libexec/kempt-apply` - the upgrade verbs.

Both are `root:root` 0755 **copies**, installed once by `install.sh`. The CLI itself, its
library and the backends never run as root. That split matters because the CLI is a symlink into
a user-writable git checkout: editing the repo changes what your user runs, and can never change
what root runs. Replacing the privileged half requires root already.

## Two polkit actions, on purpose

polkit's `auth_admin_keep` caches an authorization **per action id**, not per argument. A single
action covering both "refresh metadata" (cheap, frequent, runs from a background timer) and
"upgrade the system" (dangerous) would mean that authorizing one silently authorizes the other
for the whole cache window. So there are two, each bound by `exec.path` to exactly one helper:

| Action | Helper | Verbs | Policy for an active local session |
| --- | --- | --- | --- |
| `io.github.erez_c137.kempt.refresh` | `kempt-refresh` | `check`, `refresh` | `yes` - no dialog |
| `io.github.erez_c137.kempt.apply` | `kempt-apply` | `dnf-upgrade`, `dnf-offline-stage`, `flatpak-update` | `auth_admin_keep` - one dialog per run |

Both actions set `allow_any=no` and `allow_inactive=no`: nothing is granted to a remote or
inactive session.

The no-dialog refresh action is the same pattern PackageKit uses for its own metadata refresh,
and it is what makes the badge trustworthy: the check reads the **root** metadata cache that the
update will use, instead of a separate user cache that can disagree. All it can do is
`dnf5 --cacheonly check-update --quiet` and `dnf5 makecache --refresh`.

Refresh calls carry a 120 second timeout, because they run from background checks and a surprise
authentication dialog would otherwise hang forever with nobody there to answer it. Apply calls
are deliberately untimed: waiting for a human to authenticate is the legitimate flow there.

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
| `flatpak-update` | `-y`, app ids | Each id must match the same pattern **and** appear in `flatpak list --system --app` |

So `--exclude=foo;rm -rf /` and `--installroot=/` are rejected outright, and an app id that is
not installed on the system is refused rather than handed to flatpak. The asymmetry is
deliberate: a bogus dnf exclude is harmless by construction, while a bogus app id is not, so ids
get the second check.

Two more layers sit in front of that:

- The CLI validates hold names with the same regular expression at `kempt hold` time, so a name
  the helper would later reject is rejected while a human is still watching.
- The CLI pre-filters Flatpak ids against the installed set before calling the helper, which
  makes the helper's own installed-set check a backstop that should never fire in a normal run.

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
passwordless mode) a process running as you can upgrade the system, stage an offline transaction,
or update system Flatpak apps, without asking you. It cannot install a package of its choosing,
pass an arbitrary flag, run an arbitrary command, or reach anything outside those three verbs.
That is the bound. It is a real one, and it is smaller than "sudo", but it is not "nothing".

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

- **The Flatpak installed-set query inside `kempt-apply` is not overridable.** Making it a test
  seam would put an injectable command inside a root helper. The price is that this one path
  cannot be tested without a live Flatpak installation, and that price is accepted.
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
