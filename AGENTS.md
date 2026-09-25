# Working on Kempt

A short map for new contributors: what you need in the first two minutes, and four rules that
catch people out. `CONTRIBUTING.md` is the full guide.

## What it is

A Fedora KDE update tool in two halves that share one file:

- **The CLI** (`bin/kempt`, `lib/common.sh`, `backends/*.sh`) does the work and writes
  `~/.local/state/kempt/state.json`.
- **The widget** (`plasmoid/`) runs `kempt` commands and shows that file. It works out nothing the
  CLI could tell it.

Anything that needs root goes through one of two small scripts in `libexec/`, through polkit.
Nothing is setuid, and the CLI never runs as root.

## The map

| Path | What it is |
| --- | --- |
| `bin/kempt` | Every subcommand: `cmd_check`, `cmd_update`, `cmd_doctor` and the rest. |
| `lib/common.sh` | State, config, holds, locks, the staged-update marker and the `KEMPT_*` seams. |
| `backends/dnf.sh`, `backends/flatpak.sh` | One file per package manager. `docs/architecture.md` explains how to add one. |
| `libexec/kempt-refresh`, `libexec/kempt-apply` | The only code that runs as root. Start here for a security review. |
| `plasmoid/contents/ui/logic.js` | Turns the state file into what the widget shows. It has no Qt and no I/O, so Node can run it in the tests. |
| `plasmoid/contents/ui/*.qml` | The widget itself, mostly bindings to `logic.js`. |
| `tests/` | About 4,000 assertions in plain bash, QML probes in `tests/qml/`, a container test in `tests/live/`, and the release check in `tests/release/`, which tests the built packages. |
| `docs/` | User and design docs. Read `architecture.md` first. |

## Four rules that catch people out

**1. Never run an update while testing.** `kempt update`, `kempt run`, `pkexec` and the helpers in
`libexec/` change the machine you are on. Use a container, or replace every seam in the same
environment. Set `KEMPT_PKEXEC=` to empty. Point `KEMPT_APPLY_HELPER`, `KEMPT_REFRESH_HELPER`,
`KEMPT_TERMINAL` and `KEMPT_NOTIFY` at scripts that only log their arguments. Point
`KEMPT_CONFIG_DIR` and `KEMPT_STATE_DIR` at temporary directories. `tests/lib.sh` builds this
sandbox for you: source it and call `sandbox`.

**2. Seams are how tests replace commands.** Every outside command the CLI runs goes through a
`KEMPT_*` variable. `docs/architecture.md` lists them all. `tests/test_docs.sh` reads the list from
the code, so a new seam without a row in that table fails the suite.

**3. `tests/live/offline-gate.sh` breaks dnf5 inside a container.** It hides `/usr/bin/dnf5`,
empties dnf5's package cache and points every repository at a dead address, and it refuses to run
anywhere else. Start it with `tests/live/run-offline-gate.sh`, which builds the container, runs the
gate and removes the container. Any change to staged updates needs a passing run, because only a
container can test them against real dnf5.

**4. Run the Qt probes through their supervisor.** `tests/qml/` runs the real QML engine. Run it
with `tests/test_widget_qml.sh`, never by hand. Its watchdog stops a probe that hangs. Without it,
stuck probes pile up until the machine runs out of memory.

## Running things

```bash
tests/run_tests.sh                  # the whole bash suite; lists what it skipped at the end
bash tests/test_doctor.sh           # one file (they are mode 0644, so run them with bash)
tests/live/run-offline-gate.sh      # the container test, several minutes, needs podman
bash -n bin/kempt lib/common.sh     # what CI lints, plus shellcheck
```

A skip is not a pass. Without Node or PySide6 the widget tests are skipped, and the summary says
so. CI runs them in a Fedora container, so a green badge means the widget was tested.

## Writing

Everything here is read by someone, from comments and commit messages to the text Kempt shows.
`CONTRIBUTING.md` has the rules under "Writing". The short version: write what the reader needs
first, in short sentences, using the words on screen. Public files name nobody and say nothing
about how the work was made.
