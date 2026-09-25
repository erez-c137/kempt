# Contributing to Kempt

The most useful contribution is a backend for another package manager. Open an issue before you
start one, because a backend usually needs a new verb in the root helper (see
[Adding a backend](#adding-a-backend)). The next most useful is a test that fails against a bug
nobody has noticed yet. That needs no issue: send the pull request.

Follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report security problems through
[SECURITY.md](SECURITY.md), not a public issue.

[AGENTS.md](AGENTS.md) is the two-minute version of this file.

## Dev setup

There is no build step ([why](docs/architecture.md#why-bash)). Clone and test:

```bash
git clone https://github.com/erez-c137/kempt.git
cd kempt
tests/run_tests.sh
```

You need bash 4+, `jq`, `flock` (util-linux) and GNU coreutils. You do not need dnf, Flatpak, polkit
or root: every outside command goes through an
[environment seam](docs/architecture.md#environment-seams), and the suite stubs them all.

Two optional tools add the widget's tests, which are more than half the suite. `node` runs the
tests of `logic.js`. `python3` with PySide6 (`python3-pyside6`) runs the probes that load the real
QML. The suite prints a warning when either is missing.

| Command | What it tests | Needs |
| --- | --- | --- |
| `tests/run_tests.sh` | the code: backends, parsers, renderers and the widget's logic | bash and jq |
| `tests/live/run-offline-gate.sh` | the offline update against a real dnf5, including a broken one | podman, network |
| `tests/release/run-release-check.sh` | the packages: a fresh install, the installed QML, an upgrade from the last release, and a clean removal | podman, network |

The last two run only inside a throwaway container. Run the release check before tagging: it is
step 4 of [docs/RELEASING.md](docs/RELEASING.md).

Before you commit, syntax-check and lint. CI runs the same two commands:

```bash
bash -n bin/kempt lib/common.sh backends/*.sh libexec/* install.sh
shellcheck -x -s bash --source-path="$PWD" --source-path="$PWD/lib" --source-path="$PWD/backends" \
  bin/kempt lib/common.sh backends/*.sh libexec/* install.sh
```

Install ShellCheck with `sudo dnf install ShellCheck`. The `--source-path` entries let it follow
`bin/kempt`'s `source` lines. Fix every finding, or disable it on one line with a comment that says
why. There are no file-wide suppressions.

**Never run a real privileged update while developing.** Use the seams, or stage the install into a
directory with no `pkexec` and no prompts:

```bash
./install.sh --destdir /tmp/stage
./install.sh --destdir /tmp/stage --uninstall
```

## Tests come first, and they have to bind

Write the failing test first and check it fails for the right reason. Then make it pass.

Then prove the test binds: break the code it covers, see it go red, and put the code back. A test
that passes against the bug it is named after gives false confidence.

### Harness rules

`tests/lib.sh` is small. Reviews enforce these rules:

- **Call `sandbox` first.** It points `HOME`, `KEMPT_CONFIG_DIR` and `KEMPT_STATE_DIR` into a
  temp directory, resets every seam, and sets the trap that cleans up.
- **Never set your own EXIT trap.** It replaces the harness's, and a file that forgets `finish`
  then passes silently.
- **Stub the seams you use.** Unstubbed helper seams point at `UNSTUBBED-*` paths, so a missed
  stub fails loudly.
- **Use the assertions:** `assert_eq`, `assert_json_eq`, `assert_exit`. End with `finish`.
- **Every test file runs on its own** (`bash tests/test_foo.sh`) as well as through
  `tests/run_tests.sh`.

### Fixtures

- **Fixtures are exact captures of real output.** No comments, no markers, no tidying. Several
  parsers depend on the exact whitespace.
- **Record each one in [`tests/fixtures/MANIFEST.md`](tests/fixtures/MANIFEST.md)** in the same
  commit: captured or hand-written, when, from what, and what each odd row guards.
- **Capture through the command production runs**, with the same flags and the same sorting.
- **Include guard rows.** These rows fail a test if a guard is removed. Examples: a pending
  package missing from the installed list, a duplicate name at two versions, the tool's headers.

More on the test layers is in [tests/README.md](tests/README.md).

## Working on the widget

The widget lives in `plasmoid/`. `./install.sh` copies it, so run it again after every change. A
running Plasma keeps the old copy until `plasmashell --replace` or a new login.

- **Rules go in `logic.js`, bindings go in QML.** Everything the widget decides lives in
  `plasmoid/contents/ui/logic.js`, so node can test it. Keep it plain, old-style JavaScript: no Qt,
  no `i18n`, no files, no network. A decision made in a QML binding cannot be tested.
- **Quote anything that came from outside.** Package names go back out on a command line through
  `Logic.shellQuote`, always. See [docs/security.md](docs/security.md#the-panel-widget).
- **Only `Executor.qml` starts processes.** Don't put a fast periodic caller on the same queue as a
  slow one. Another Executor instance is simpler than a smarter queue.
- **Settings belong to `kempt config`.** `contents/config/main.xml` declares no keys, so there is
  only one copy of each value.
- **A new string goes in three places.** The text in the `COPY` table in `logic.js`. The same text
  as an `i18n("...")` literal in the QML, so translators see it. Its type in
  `tests/qml/probe_popup.py`.

The probes need `python3-pyside6` and the Plasma and Kirigami QML modules, which a Plasma 6
desktop already has. Run one through its supervisor:

```bash
python3 tests/qml/safe_probe.py 120 python3 tests/qml/probe_popup.py
```

The supervisor adds the timeout, the process group and the offscreen platform, and a probe refuses
to run without it. `tests/test_widget_qml.sh` runs the probes one at a time and checks that none is
left running. If that check fails, stop and fix it before running anything else: stuck Qt
processes pile up fast.

Inside a probe, call `p.clear_calls()` before an action whose calls you count. Label an assertion
that only sets up the next one with `premise:`, so its failure reads as "the setup failed".

## Shell conventions

- `set -euo pipefail` at the top of every script.
- **Backends return their status by hand.** `if x="$(fn)"` turns off errexit for the whole of
  `fn`, so a failure that relied on `set -e` would report success.
- **Privileged code checks before it runs.** The root helpers accept a fixed list of verbs and
  pattern-checked arguments, build the command themselves, and exit 2 on anything else. A new verb
  follows that shape.
- **Don't add locale handling.** `lib/common.sh` sets `LC_ALL=C.UTF-8`, and the root helpers set it
  again ([why](docs/security.md#the-locale-pin-is-load-bearing)).
- **Write shared files atomically** with `atomic_write`. The widget reads state files on a timer.
- **Watch `ls` under pipefail.** It exits 2 on an empty directory, which is normal on a fresh
  install.
- **Comments say why.** When a guard is not obviously needed, name the bug it prevents.

## Adding a backend

Start with [the walkthrough](docs/architecture.md#adding-a-backend-for-your-distro). It covers the
two functions to write, how updates get applied, fixtures, and sketches for apt, pacman and zypper.

Open an issue before a pull request. Say which package manager it is and whether installing
needs root. Most do, which means a new verb in `libexec/kempt-apply`. Flatpak is the exception: it
asks polkit for itself, so `backends/flatpak.sh` applies updates with no helper verb. Every backend
also changes `assemble_state`. The review is mostly about the root helper and the state file.

## Writing

Docs, comments, commit messages, issues and the widget's text all follow these rules.

1. Know who reads it. Put what they need first.
2. One idea per sentence. Aim for about 15 words.
3. Say what something does, not what it is not.
4. No asides in brackets or dashes. No em dashes: use " - " or rephrase.
5. No self-praise (`robust`, `carefully`, `deliberately`).
6. State the rule. The story of how it came about goes in the commit.
7. Use the words the reader sees on screen.
8. Say each thing once, in one place, and link to it.
9. Cut what the reader does not need.
10. Check every command, setting, default and exit code against the code. When a doc and the code
    disagree, fix the doc. Run every example before you commit it.

Address the reader as "you" and the program as "Kempt". Spelling is British (*behaviour*,
*cancelled*), except text copied from Plasma. Commands, paths and keys go in backticks, and
on-screen labels in **bold**.

### What never goes in a public file

Everyone who reads this repository has only this repository. So, in docs and in code comments:

- **No names, and nobody in the third person.** Write "the check runs first", not who decided it.
- **Nothing about how the work was made.** No review names, finding numbers, task codes or tool
  names.
- **No links to private notes.** If a fact from them matters, write the fact here.
- **No email addresses**, except in `kempt.spec`'s `%changelog`, `SECURITY.md` and
  `CODE_OF_CONDUCT.md`.
- **Nothing personal in screenshots.** Check the package names and everything else in the frame.

`tests/test_docs.sh` checks what a search can find. To check for em dashes yourself:

```bash
grep -rnP '\x{2014}' *.md docs/*.md docs/man/   # expect no output
```

## Bumping the version

`VERSION` is the only file that holds the version. `kempt --version` and `kempt doctor` read it.
After editing it, run `tests/test_version.sh`, which names each file that does not agree yet
(`plasmoid/metadata.json`, the metainfo's newest `<release>`, and `kempt.spec`'s `Version:`):

```bash
printf '0.2.0\n' > VERSION
tests/test_version.sh
```

The git tag and the spec's dated `%changelog` entry are done by hand. Bump in a commit of its own.
The full order is in [docs/RELEASING.md](docs/RELEASING.md#the-release).

### Building an RPM by hand

```bash
tools/build-local.sh          # runs the suite, builds, installs, reloads the widget
```

A hand build is named as a preview of the next release, so you can tell which commit is installed:

```
kempt-0.1.5~dev.4-0.git1a2b3c4.20260922T193500.1.fc44     rpm -q kempt
kempt 0.1.5~dev.4+git1a2b3c4                               kempt --version, the widget
```

- **0.1.5** is the next release: the patch after the newest tag, or `VERSION` once it has been
  bumped past the tag.
- **dev.4** is the number of commits since that tag. `.dirty` means there were uncommitted
  changes.
- **The tilde** makes `0.1.5~dev.4` sort below `0.1.5`, so the real release replaces the hand build.

The script works on a copy and never edits the checkout. `--print-name` prints the name and stops;
`--no-install` builds into `~/rpmbuild/RPMS/noarch` and stops.

To use `rpmbuild` directly, always pass a stamp, or the build looks identical to the release:

```bash
rpmbuild --define "kempt_local $(date +%Y%m%dT%H%M%S)" -ba kempt.spec
```

After installing a hand build any other way, clear Plasma's QML cache, or the panel keeps showing the
previous build (`tools/build-local.sh` does this for you):

```bash
rm -rf ~/.cache/plasmashell/qmlcache && systemctl --user restart plasma-plasmashell
```

The cache is keyed on file timestamps, and rpm sets them from the spec's newest `%changelog` date.
Two builds of the same version therefore look identical to Plasma. Releases are not affected,
because each one has a new `%changelog` date.

## Commits and pull requests

One commit per change. Present tense, with a type prefix, like the existing log:

```
feat: flatpak backend - pending parser + stub-driven check
fix: an update that already changed the system always writes its history entry
docs: install guide
```

Add a scope when it helps: `fix(doctor):`, `fix(widget):`, `docs(changelog):`. Use `test:` for
test-only changes and `style:` for formatting. No trailers or sign-offs.

A pull request says what changed, why, and how you checked it. Paste the test output. For a parser
change, name the fixture that proves it. For a change to anything that runs as root, say what an
attacker can and cannot do now.
