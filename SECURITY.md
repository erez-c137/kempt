# Security policy

Report security problems privately, not in a public issue.

## Reporting a vulnerability

On <https://github.com/erez-c137/kempt>, open the **Security** tab and choose
**Report a vulnerability**. Only the project can see the report.

Include:

- the commit you are on (`git rev-parse HEAD`);
- the exact command and arguments;
- whether `/etc/polkit-1/rules.d/49-kempt.rules` is installed, because passwordless mode changes
  what is exposed;
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
| 0.1.x | Yes (the newest 0.1.z) |
| Anything older | No |

## What runs as root

Nothing Kempt installs is setuid. Two helper scripts run as root, through `pkexec` and two polkit
actions. The only other root commands are behind their own password prompts: the `install` and
`rm` in `kempt enable-passwordless` and `kempt disable-passwordless`, and one `pkexec bash -c` in
`install.sh`. Every installed file is mode 0755 or 0644.

## Scope

Where to look, most important first:

1. `libexec/kempt-apply` and `libexec/kempt-refresh`, the only code that runs as root. Look at
   argument checks, the pinned `PATH` and `LC_ALL`, bash's privileged mode, and the refusal to
   touch a downloaded Fedora release upgrade.
2. `polkit/io.github.erez_c137.kempt.policy`: the two actions and who may use them.
3. `polkit/49-kempt.rules.in` and `render_passwordless_rule` in `lib/common.sh`: the passwordless
   rule and the check that verifies it.
4. The root part of `install.sh`.
5. How the widget builds commands: `shellQuote` in `plasmoid/contents/ui/logic.js` and its callers.
   The widget runs as you, but it puts package names into shell commands.

In scope:

- running an unintended command as root;
- widening the polkit grant beyond `io.github.erez_c137.kempt.apply` for an active local session;
- passing an unexpected argument to a root helper;
- getting an unquoted value into a command the widget runs.

Out of scope:

- attacks that need root to begin with;
- the checkout being writable by its owner, which a checkout install depends on (see
  [accepted limitations](docs/security.md#accepted-limitations));
- holding the package manager's lock, which any program can do (Kempt retries, then reports it);
- problems that exist only in a modified checkout, unless the modification is the point.

The full security model is in [docs/security.md](docs/security.md).
