# Security policy

Report security problems privately, not in a public issue.

## Reporting a vulnerability

On <https://github.com/erez-c137/kempt>, open the **Security** tab and choose
**Report a vulnerability**. Only the project can see the report.

Include:

- the first line of `kempt doctor`, which names the version;
- the exact command and arguments;
- whether your account is in the `wheel` group, because that decides who gets a password dialog;
- what you expected, and what happened.

A reproduction in the test suite is the most useful thing you can send.

## What happens next

Kempt is a small project with one maintainer.

- You get a reply within **7 days**.
- You get an assessment, and a fix or a plan, within **30 days** of the report being confirmed.
- You are credited in the changelog and the advisory, unless you prefer not to be.

Fixes ship as a patch release and a COPR rebuild, so they arrive through `dnf upgrade`.

## Supported versions

| Version | Supported |
| --- | --- |
| 0.2.x | Yes (the newest 0.2.z) |
| Anything older | No |

## What runs as root

Nothing Kempt installs is setuid. Two helper scripts run as root, through `pkexec` and two polkit
actions, and nothing else does. Every installed file is mode 0755 or 0644.

## Scope

Where to look, most important first:

1. `libexec/kempt-apply` and `libexec/kempt-refresh`, the only code that runs as root. Look at
   argument checks, the pinned `PATH` and `LC_ALL`, bash's privileged mode, and the refusal to
   touch a downloaded Fedora release upgrade.
2. `polkit/io.github.erez_c137.kempt.policy`: the two actions and who may use them.
3. `polkit/49-kempt.rules`: the fixed rule that lets a `wheel` user at the desk update with no
   password.
4. How the widget builds commands: `shellQuote` in `plasmoid/contents/ui/logic.js` and its callers.
   The widget runs as you, but it puts package names into shell commands.

In scope:

- running an unintended command as root;
- widening the polkit grant beyond `io.github.erez_c137.kempt.apply` for a `wheel` user in an active local session;
- passing an unexpected argument to a root helper;
- getting an unquoted value into a command the widget runs.

Out of scope:

- attacks that need root to begin with;
- holding the package manager's lock, which any program can do (Kempt retries, then reports it);
- problems that exist only in a modified checkout, unless the modification is the point.

The full security model is in [docs/security.md](docs/security.md).
