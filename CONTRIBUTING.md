# Contributing to Upkeep

The most useful contribution is a backend for another distribution. The second most useful is a
test that fails against a bug nobody had noticed yet. Both are welcome, and neither needs
permission first.

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Security
problems go through [SECURITY.md](SECURITY.md), never a public issue.

## Dev setup

There is no build step. Clone it and run it.

```bash
git clone https://github.com/erez-c137/upkeep.git
cd upkeep
tests/run_tests.sh
```

You need bash 4+, `jq` and GNU coreutils. You do **not** need dnf, flatpak, polkit or root to
work on Upkeep: every impure command goes through an environment seam, and the suite stubs all of
them. See [docs/architecture.md](docs/architecture.md#environment-seams) for the full list.

Syntax-check everything before you commit:

```bash
bash -n bin/upkeep lib/common.sh backends/*.sh libexec/* install.sh
```

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

- **Call `sandbox` first, before anything else.** It creates a throwaway `HOME`, points
  `UPKEEP_CONFIG_DIR` and `UPKEEP_STATE_DIR` inside it, clears every seam variable, and installs
  the EXIT trap that cleans up and gives the file a meaningful exit status.
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
functions to implement, the new verb in the apply helper, the fixture and MANIFEST workflow, and
worked sketches for apt, pacman and zypper.

Changes to the state schema, the exit-code contract or the root helpers are worth an issue before
a pull request. A new backend file is not: just send it.

## Docs

Documentation is a first-class deliverable here, and it is held to the same standard as code:

- **Every command, key, default and exit code must be verified against the code**, not
  remembered. Where a doc and the code disagree, the code is right and the doc is a bug.
- **Every shell example must be copy-paste runnable.** Run it before you commit it.
- **No em dashes in documentation or user-facing copy.** Use a spaced hyphen or rephrase. Sweep
  before every commit:

  ```bash
  grep -rnP '\x{2014}' README.md docs/ *.md   # U+2014 EM DASH; expect no output
  ```

- Concise beats complete. A reader who finishes a page should know what to do next.

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
