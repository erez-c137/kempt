# Security policy

**Nothing Kempt installs is setuid, and every escalation goes through polkit.** The two root
helpers are `root:root` 0755 and are launched by `pkexec` against two action ids; nothing else in
the tree ever runs as root. Neither `install.sh` nor `kempt.spec` sets any mode other than 0755 and
0644, so no Kempt file can gain privilege on its own. Security reports are taken seriously and
handled privately.

## Supported versions

| Version | Supported |
| --- | --- |
| 0.1.x | Yes (the newest 0.1.z) |
| Anything older | No |

Security fixes ship as a new patch release and a COPR rebuild, so the fix reaches a packaged user
through `dnf upgrade` like any other update; see [docs/RELEASING.md](docs/RELEASING.md).

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

- Use GitHub's private vulnerability reporting on
  <https://github.com/erez-c137/kempt>: the **Security** tab, then **Report a vulnerability**.
  That opens a private advisory visible only to the maintainer.

Please include:

- the commit you are on (`git rev-parse HEAD`),
- the exact command and arguments,
- whether `/etc/polkit-1/rules.d/49-kempt.rules` is installed (passwordless mode changes the
  threat model),
- what you expected and what happened.

A working reproduction against the test suite is the most useful thing you can send.

## What we will do

This is a small, single-maintainer project, so the promise is honest rather than corporate:

- Acknowledgement within **7 days**.
- An assessment, and a fix or a plan, within **30 days** of confirming the report.
- Credit in the changelog and the advisory unless you would rather stay anonymous.

## Scope

The interesting attack surface, in the order it is worth your time:

1. `libexec/kempt-apply` and `libexec/kempt-refresh` - the only code that runs as root.
   Argument validation, the pinned `PATH` and `LC_ALL`, the Flatpak installed-set check.
2. `polkit/io.github.erez_c137.kempt.policy` - the two action definitions and their authorization levels.
3. `polkit/49-kempt.rules.in` and `render_passwordless_rule` in `lib/common.sh` - the rendered
   rule, its self-check, and anything that could get an unverified rule past it.
4. The privileged block in `install.sh`.
5. The panel widget's command building (`shellQuote` in `plasmoid/contents/ui/logic.js`, and its
   callers). The widget runs as you and never as root, but it turns package names out of the
   CLI's JSON into shell command lines, so a value that reaches a shell unquoted would run as
   your user from inside `plasmashell`.

Anything that lets an unprivileged user run an unintended command as root, widen the polkit
grant beyond `io.github.erez_c137.kempt.apply` for an active local session, get an arbitrary
argument into a root helper, or get an unquoted value onto a command line from the widget is in
scope.

Out of scope:

- Attacks that require root to begin with.
- The fact that the git checkout is user-writable and the CLI runs out of it. That is the
  documented symlink-install model; see
  [docs/security.md](docs/security.md#accepted-limitations).
- Denial of service by holding the package-manager lock. Any tool on the box can do that, and
  Kempt already retries and then reports it.
- Findings from a modified working tree, unless the modification is the point.

The full model, including what passwordless mode grants and the limitations already accepted,
is documented in [docs/security.md](docs/security.md).
