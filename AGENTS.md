# Working on Kempt

A short map for whoever picks this up next, human or AI. `CONTRIBUTING.md` is the full guide and
this does not replace it; this is the orientation you want in the first two minutes, and the four
rules that will bite you if nobody tells you.

## What it is

A Fedora KDE update tool in two halves that talk through one file:

- **The CLI** (`bin/kempt`, `lib/common.sh`, `backends/*.sh`) does all the work and writes
  `~/.local/state/kempt/state.json`.
- **The widget** (`plasmoid/`) runs `kempt` commands and renders that file. It computes nothing
  the CLI could have told it.

Anything needing root goes through one of two small scripts in `libexec/`, reached through polkit.
Nothing is setuid and the CLI never runs as root.

## The map

| Path | What it is |
| --- | --- |
| `bin/kempt` | Every subcommand. `cmd_check`, `cmd_update`, `cmd_doctor` and friends. |
| `lib/common.sh` | State, config, holds, locks, the offline marker, the `KEMPT_*` seams. |
| `backends/dnf.sh`, `backends/flatpak.sh` | One file per package manager. Adding a third is documented end to end in `docs/architecture.md`. |
| `libexec/kempt-refresh`, `libexec/kempt-apply` | The only code that runs as root. Read these first if you are reviewing security. |
| `plasmoid/contents/ui/logic.js` | Pure derivation: state file in, view model out. No Qt, no I/O. Node runs it in the tests, which is why it must stay pure. |
| `plasmoid/contents/ui/*.qml` | The panel widget. Mostly bindings onto the view model above. |
| `tests/` | ~3,000 assertions of plain bash, plus QML probes under `tests/qml/` and a live container gate under `tests/live/`. |
| `docs/` | User and design documentation. `architecture.md` is the one to read. |
| `internal/` | Not shipped, gitignored: working notes, specs, review reports. |

## Four rules that will bite you

**1. Never run the update paths while testing.** `kempt update`, `kempt run`, `pkexec` and the
helpers in `libexec/` change the machine you are on. A review probe once ran a real `dnf5 upgrade`
here because a test stub executed the script it was handed. Before touching anything that can
reach them, either use a container or neutralise every seam in the same environment:
`KEMPT_PKEXEC=` empty, `KEMPT_APPLY_HELPER` / `KEMPT_REFRESH_HELPER` / `KEMPT_TERMINAL` /
`KEMPT_NOTIFY` at scripts that only log their arguments, and `KEMPT_CONFIG_DIR` / `KEMPT_STATE_DIR`
at temporary directories. `tests/lib.sh` already builds exactly that sandbox - source it and call
`sandbox`.

**2. The seams are the test boundary, and they are documented.** Every impure command in the CLI
goes through a `KEMPT_*` variable so a test can replace it. `docs/architecture.md` has a table of
all of them, and `tests/test_docs.sh` derives the list from the code, so adding a seam without a
row fails the suite. That is deliberate.

**3. `tests/live/offline-gate.sh` breaks the package manager on purpose** - it shadows
`/usr/bin/dnf5`, empties dnf5's package cache and points every repository at a dead address. It
refuses to run outside a throwaway container. Run it as `tests/live/run-offline-gate.sh`, which
builds the container, runs it inside, and removes it. Any change to the offline staged-update
lifecycle needs a green run of it, because a container is the only place that behaviour can be
exercised against real dnf5.

**4. Qt probes must be supervised.** `tests/qml/` runs the real QML engine. Run them through
`tests/test_widget_qml.sh` and never by hand: the watchdog, the process group and the leak census
live in `safe_probe.py`, and without them a wedged probe stays resident. One afternoon that reached
~2,200 Qt processes and OOM-killed unrelated services on the developer's machine.

## Running things

```bash
tests/run_tests.sh                  # the whole bash suite; says at the end what it SKIPPED
bash tests/test_doctor.sh           # one file (they are mode 0644, so invoke with bash)
tests/live/run-offline-gate.sh      # the live container gate, several minutes, needs podman
bash -n bin/kempt lib/common.sh     # what CI lints, plus shellcheck
```

A skip is not a pass. If node or PySide6 is missing, the widget's halves skip and the summary says
so; CI runs them in a Fedora container precisely so that a green badge means the widget was tested.

## Two conventions worth knowing before you write anything

**Comments carry constraints, not history.** A comment here should stop a correct-looking change
from being wrong: an invariant, an ordering that matters, why an odd construct is odd. What it
should not do is narrate how a bug was found - that is what `CHANGELOG.md` is for, and it is
thorough. If you find yourself writing "this used to", write the rule in the present tense instead.

**No em dashes in anything a user reads.** Spaced hyphens, or rewrite the sentence. This applies to
the README, the docs, the changelog, and every string the CLI or the widget prints.
