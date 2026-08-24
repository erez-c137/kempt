# Security model

Upkeep updates your system, so some of it necessarily runs as root. This document says exactly
which parts, what they are allowed to do, and what the optional passwordless mode gives away.

To report a vulnerability, see [SECURITY.md](../SECURITY.md).

## What runs as root

Two files, and nothing else:

- `/usr/local/libexec/upkeep-refresh` - package metadata only.
- `/usr/local/libexec/upkeep-apply` - the upgrade verbs.

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
| `org.erez.upkeep.refresh` | `upkeep-refresh` | `check`, `refresh` | `yes` - no dialog |
| `org.erez.upkeep.apply` | `upkeep-apply` | `dnf-upgrade`, `dnf-offline-stage`, `flatpak-update` | `auth_admin_keep` - one dialog per run |

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

`upkeep-refresh` takes exactly one argument, `check` or `refresh`. Extra arguments are refused
rather than ignored, so a caller cannot believe it passed something that was silently dropped.

`upkeep-apply` accepts:

| Verb | Accepted arguments | Validation |
| --- | --- | --- |
| `dnf-upgrade`, `dnf-offline-stage` | `-y`, `--exclude=<name>` | `<name>` must match `^[A-Za-z0-9][A-Za-z0-9._+-]*$` |
| `flatpak-update` | `-y`, app ids | Each id must match the same pattern **and** appear in `flatpak list --system --app` |

So `--exclude=foo;rm -rf /` and `--installroot=/` are rejected outright, and an app id that is
not installed on the system is refused rather than handed to flatpak. The asymmetry is
deliberate: a bogus dnf exclude is harmless by construction, while a bogus app id is not, so ids
get the second check.

Two more layers sit in front of that:

- The CLI validates hold names with the same regular expression at `upkeep hold` time, so a name
  the helper would later reject is rejected while a human is still watching.
- The CLI pre-filters Flatpak ids against the installed set before calling the helper, which
  makes the helper's own installed-set check a backstop that should never fire in a normal run.

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

## What pkexec sanitizes

pkexec does not pass the caller's environment through. It resets to a minimal, sanitized set, so
a hostile `PATH`, `LD_PRELOAD` or `IFS` cannot ride into the privileged process. One useful
consequence: the `UPKEEP_APPLY_ECHO` and `UPKEEP_REFRESH_ECHO` test seams inside the helpers
cannot be triggered from outside a test harness, because the variable never survives the
transition. They only ever print a command line instead of running it.

## Passwordless mode

`upkeep enable-passwordless` installs one polkit rule at
`/etc/polkit-1/rules.d/49-upkeep.rules`:

```javascript
polkit.addRule(function(action, subject) {
    if (action.id == "org.erez.upkeep.apply" &&
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
- The destination is pinned before use, because that path is handed to a root `install(1)`. It
  must be an absolute path ending in `.rules`, and either inside `/etc/polkit-1/rules.d/` (the
  one directory polkit reads) or outside `/etc` entirely (which is what the test seam uses). A
  `.rules` file anywhere else under `/etc` is refused: that would only ever plant a root-owned
  file in another tool's configuration directory. The comparison runs on the `realpath -m` form,
  so `..` cannot walk a destination out of the directory it claims to be in.
- Installation is a single `pkexec install -m 0644 -o root -g root`.

`upkeep disable-passwordless` removes the file. It reports "not enabled" only when it can
actually search the directory: the real `/etc/polkit-1/rules.d` is 0750 `root:polkitd`, where an
unprivileged existence test answers "absent" for a file that is really there. Claiming "not
enabled" in that case would leave a live grant in place, so the removal goes ahead instead.

## Accepted limitations

Recorded here rather than quietly fixed later:

- **The Flatpak installed-set query inside `upkeep-apply` is not overridable.** Making it a test
  seam would put an injectable command inside a root helper. The price is that this one path
  cannot be tested without a live Flatpak installation, and that price is accepted.
- **The `*_ECHO` seams live in root-owned code.** They are unreachable through pkexec (see
  above) and they only print, but they are there.
- **The checkout is load-bearing.** Anyone who can write to your Upkeep checkout controls what
  your user runs, including the passwordless rules template that `enable-passwordless` renders
  before handing the result to root. Keep the checkout in your own home or workspace, never
  somewhere group- or world-writable. Root-owned files are unaffected either way.
- **Flatpak is system scope only** in v1, so a per-user app is never counted and never updated.
- **Holds are not a system-wide lock.** They are Upkeep's own exclusion list; a manual
  `sudo dnf5 upgrade` ignores them.
- **`install.sh` runs one `pkexec bash -c`**, with every repo path passed as a positional
  argument rather than interpolated into the script text, so a checkout path containing a quote
  cannot break or inject into the root command.
