# Security policy

Upkeep installs two small root helpers and a polkit action, so security reports are taken
seriously and handled privately.

## Supported versions

| Version | Supported |
| --- | --- |
| v1 (current development line) | Yes |
| Anything older | No |

There is no released version yet. Until there is, "supported" means the tip of the default
branch.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

- Once the repository is public, use GitHub's private vulnerability reporting on
  <https://github.com/erez-c137/upkeep>: the **Security** tab, then **Report a vulnerability**.
  That opens a private advisory visible only to the maintainer.
- Until then, contact the maintainer privately through GitHub ([@erez-c137](https://github.com/erez-c137)).

Please include:

- the commit you are on (`git rev-parse HEAD`),
- the exact command and arguments,
- whether `/etc/polkit-1/rules.d/49-upkeep.rules` is installed (passwordless mode changes the
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

1. `libexec/upkeep-apply` and `libexec/upkeep-refresh` - the only code that runs as root.
   Argument validation, the pinned `PATH` and `LC_ALL`, the Flatpak installed-set check.
2. `polkit/org.erez.upkeep.policy` - the two action definitions and their authorization levels.
3. `polkit/49-upkeep.rules.in` and `render_passwordless_rule` in `lib/common.sh` - the rendered
   rule, its self-check, and anything that could get an unverified rule past it.
4. The privileged block in `install.sh`.

Anything that lets an unprivileged user run an unintended command as root, widen the polkit
grant beyond `org.erez.upkeep.apply` for an active local session, or get an arbitrary argument
into a root helper is in scope.

Out of scope:

- Attacks that require root to begin with.
- The fact that the git checkout is user-writable and the CLI runs out of it. That is the
  documented symlink-install model; see
  [docs/security.md](docs/security.md#accepted-limitations).
- Denial of service by holding the package-manager lock. Any tool on the box can do that, and
  Upkeep already retries and then reports it.
- Findings from a modified working tree, unless the modification is the point.

The full model, including what passwordless mode grants and the limitations already accepted,
is documented in [docs/security.md](docs/security.md).
