# Contributing to Kempt

The most useful contribution is a backend for another distribution. It is also the one kind of
change that starts with an issue rather than a pull request, because a backend needs a new verb
in the root helper (see [Adding a backend](#adding-a-backend)). The second most useful is a test
that fails against a bug nobody had noticed yet, and that one needs no permission at all: send
it.

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Security
problems go through [SECURITY.md](SECURITY.md), never a public issue.

New here? [AGENTS.md](AGENTS.md) is the two-minute version: the map of the tree, and the four
rules that will bite you if nobody tells you first. This file is the long form.

## Dev setup

There is no build step - that is a design choice, argued in
[docs/architecture.md](docs/architecture.md#why-bash). Clone it and run it.

```bash
git clone https://github.com/erez-c137/kempt.git
cd kempt
tests/run_tests.sh
```

You need bash 4+, `jq`, `flock` (util-linux) and GNU coreutils. You do **not** need dnf, flatpak, polkit or root to
work on Kempt: every impure command goes through an environment seam, and the suite stubs all of
them. See [docs/architecture.md](docs/architecture.md#environment-seams) for the full list.

Two optional tools unlock the widget's coverage, and the suite says loudly when they are missing
rather than passing quietly: `node` runs the derivation tests over `logic.js`, and `python3` with
PySide6 (`python3-pyside6`) runs the probes that execute the real QML. Without them you still get
a green suite, minus the widget's entire derivation and probe coverage - more than half of the
suite's assertions.

Syntax-check everything before you commit:

```bash
bash -n bin/kempt lib/common.sh backends/*.sh libexec/* install.sh
```

Then lint it, because CI does and a first pull request should not go red on a tool nobody
mentioned. This is `.github/workflows/ci.yml`'s own command with `$GITHUB_WORKSPACE` replaced by
the checkout you are standing in:

```bash
shellcheck -x -s bash \
  --source-path="$PWD" \
  --source-path="$PWD/lib" \
  --source-path="$PWD/backends" \
  bin/kempt lib/common.sh backends/*.sh libexec/* install.sh
```

`sudo dnf install ShellCheck` if you do not have it. `-x` follows `source`, and the three
`--source-path` entries are what let it resolve `bin/kempt`'s runtime-computed `$ROOT`; without
them every sourced file comes back as an informational SC1091. Every finding gets a real fix or a
one-line `disable` naming the constraint - there are no file-level suppressions in this tree.

**Never run a real privileged update while developing.** Use the seams and the `--destdir` mode
of `install.sh`, which stages every file into a prefix with no `pkexec` and no prompts:

```bash
./install.sh --destdir /tmp/stage
./install.sh --destdir /tmp/stage --uninstall
```

## Test-driven, and the tests have to bind

Write the failing test first, watch it fail for the right reason, then make it pass. Reviews here
ask for the failure, not just the pass.

Then prove the test binds: break the code it claims to cover, confirm the test goes red, put the
code back. A test that still passes against the defect it is named after is worse than no test,
because it advertises coverage that does not exist. Several real bugs in this repo survived a
green suite for exactly that reason.

## Test harness rules

`tests/lib.sh` is small on purpose. These rules are what reviews enforce:

- **Call `sandbox` first, before anything else.** It creates one throwaway temp directory and
  points `HOME`, `KEMPT_CONFIG_DIR` and `KEMPT_STATE_DIR` at separate paths inside it, so no
  test can reach your real config or state. It also neutralizes every seam variable (unset, or
  pointed somewhere harmless) and installs the EXIT trap that cleans up and gives the file a
  meaningful exit status.
- **Never install your own EXIT trap.** It replaces the harness's, and a test file that then
  forgets `finish` silently passes.
- **Stub the seams you use.** The helper seams deliberately default to nonexistent
  `UNSTUBBED-*` paths, so a test that forgets to stub one fails loudly instead of reaching for
  the real system.
- **Use the assertions**: `assert_eq`, `assert_json_eq`, `assert_exit`, and end with `finish`.
- **A test file must be runnable on its own** (`bash tests/test_foo.sh`) as well as through
  `tests/run_tests.sh`, which fails when the suite matches no files at all.

### Fixtures

- Fixtures are **byte-faithful** captures of real tool output. No comment lines, no markers, no
  tidying. Several of the parsers are pinned to whitespace and column behavior that a "cleanup"
  would destroy.
- Provenance lives in [`tests/fixtures/MANIFEST.md`](tests/fixtures/MANIFEST.md), one entry per
  file: captured or hand-written, when, from what, and what each deliberate oddity guards. If you
  add a fixture, add its entry in the same commit.
- **Capture through the same code path production uses.** An early dnf capture used `sort -u`
  where production used plain `sort`, which hid an entire bug class (duplicate names
  cross-producing in `join`) from the whole suite.
- **Guard rows are mandatory.** Every fixture carries at least one row that fails the test when a
  guard is deleted: a pending package missing from the installed lookup, a duplicate name at a
  divergent version, and whatever headers or indented sections the real tool emits.

## Working on the widget

The plasmoid lives in `plasmoid/` and is installed as a **copy**, so re-run `./install.sh` after
every change to it (the CLI is a symlink and needs no such thing). There is no build step here
either.

- **Rules go in `logic.js`, bindings go in QML.** The badge number, the icon state, the tooltip,
  the popup rows, the watcher comparison: all of it is derived in `plasmoid/contents/ui/logic.js`,
  which must stay engine-agnostic JavaScript - no Qt, no `i18n`, no filesystem, no network, and
  old-school syntax that runs in whatever JS engine the installed Plasma ships. That is what lets
  `tests/test_widget_logic.sh` load the same file under node and pin every rule. A decision made
  in a QML binding is a decision no test can reach.
- **Quote everything that came from outside.** Package names arrive in the CLI's JSON and go back
  out on a command line, so they go through `Logic.shellQuote` with no exceptions. See
  [docs/security.md](docs/security.md#the-panel-widget).
- **Nothing starts a process except `Executor.qml`.** Add a caller to an existing queue only if it
  has a similar shape; a fast periodic caller must not share a queue with a slow occasional one.
  A fourth Executor instance is cheaper than a cleverer queue.
- **The QML probes run strictly one at a time.** `tests/test_widget_qml.sh` supervises each one
  through `tests/qml/safe_probe.py` and asserts afterwards that no probe process survived. That
  discipline is not ceremony: an earlier version with no working timeout left ~2,200 wedged Qt
  processes and OOM-killed the machine. If the process-count assertion ever fails, stop and fix
  it rather than re-running.
- **A setting the widget shows is a setting `kempt config` owns.** `contents/config/main.xml`
  declares no keys on purpose. Adding a KConfig entry would create a second copy of a value the
  CLI already owns, and the two would drift the first time somebody used a terminal.

## Shell conventions

- `set -euo pipefail` at the top of every script.
- **Backends return status explicitly.** `if x="$(fn)"` disables errexit inside the entire callee,
  so a function that relies on `set -e` to propagate a failure reports success instead. Return by
  hand.
- **Validate before exec in anything privileged.** The root helpers accept a fixed verb list and
  pattern-checked arguments, build the command themselves, and exit 2 on anything else. A new
  verb follows that shape or it does not merge.
- **Do not add locale handling.** `lib/common.sh` pins `LC_ALL=C.UTF-8` once, and the root
  helpers pin it again for a reason documented in
  [docs/security.md](docs/security.md#the-locale-pin-is-load-bearing).
- **Write files atomically** when a reader could see them half-written (`atomic_write`). The
  widget polls state files on a timer.
- **Watch pipefail around `ls`.** It exits 2 on an empty directory, which is the normal state on
  a fresh install; the repo uses process substitution or `|| true` where that matters.
- **Comments explain why, not what.** The house style is that every non-obvious guard names the
  bug it prevents, so nobody deletes it as redundant six months later. Keep that up.

## Adding a backend

Start with the walkthrough in
[docs/architecture.md](docs/architecture.md#adding-a-backend-for-your-distro). It covers the two
functions to implement, the apply path (a new verb in the helper, or an unprivileged one in the
backend), the fixture and MANIFEST workflow, and worked sketches for apt, pacman and zypper.

Changes to the state schema, the exit-code contract or the root helpers are worth an issue before
a pull request. A backend is usually one of those changes, whether or not it looks like one: most
package managers need root to install anything, which means a new verb in `libexec/kempt-apply`,
and adding a backend changes `assemble_state`'s signature either way. Flatpak is the exception
that shows the question is worth asking: `flatpak update` gets its own polkit yes in an active
local session, so it applies its own updates from `backends/flatpak.sh` with no helper verb at
all. So open an issue first, and say which package manager it is and whether its apply needs
root. The backend file itself is the easy part; the review is about the privileged half and the
state contract.

## Docs

Documentation is a first-class deliverable here, and it is held to the same standard as code:

- **Every command, key, default and exit code must be verified against the code**, not
  remembered. Where a doc and the code disagree, the code is right and the doc is a bug.
- **Every shell example must be copy-paste runnable.** Run it before you commit it.
- **No em dashes in documentation or user-facing copy.** Use a spaced hyphen or rephrase. Sweep
  the published docs before every commit:

  ```bash
  grep -rnP '\x{2014}' *.md docs/*.md docs/man/   # U+2014 EM DASH; expect no output
  ```

  `docs/plans/`, `docs/specs/` and `docs/research/` are working archives rather than published
  documentation, and are deliberately outside the sweep.

- Concise beats complete. A reader who finishes a page should know what to do next.

## Bumping the version

`VERSION` at the root of the checkout is the only place this project writes its version down.
`kempt --version` reads it and `kempt doctor` opens with it - so a bump is one edit to `VERSION`,
then `tests/test_version.sh`, which fails until `plasmoid/metadata.json`, the metainfo's newest
`<release>` and `kempt.spec`'s `Version:` all agree:

```bash
printf '0.2.0\n' > VERSION
tests/test_version.sh          # names every file that does not agree yet
```

The git tag is the one number left to a human, along with the spec's `%changelog`, which needs a
dated entry of its own. Which file to edit and in what order is step 1 of
[docs/RELEASING.md](docs/RELEASING.md#the-release); add the release's section to `CHANGELOG.md`,
and bump in its own commit, so the diff that says what the release is stays readable.

A bump is the first step of a release rather than the whole of one:
[docs/RELEASING.md](docs/RELEASING.md) is the numbered checklist for the rest, and it also says
why Kempt has no self-update code and never will.

## Commits and pull requests

One commit per logical change, present-tense subject, prefixed by type, matching what is already
in the log:

```
feat: flatpak backend - pending parser + stub-driven check
fix: an update that already changed the system always writes its history entry
docs: install guide
test: capture dnf/flatpak fixtures from live box
chore: scaffolding + bash test harness
```

`style:` for formatting-only changes. No trailers, no generated sign-offs, no "AI assisted"
footers.

A pull request should say what changed, why, and how you verified it. Paste the relevant test
output. If you changed a parser, say which fixture proves it. If you changed anything privileged,
say what an attacker can and cannot do now.
