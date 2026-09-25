# The test suite

Four layers, all runnable from a clean checkout with no package manager, no polkit, no desktop
and no root.

| What | Where | Needs |
| --- | --- | --- |
| The CLI and the root helpers | `tests/test_*.sh` | bash 4+, `jq`, coreutils |
| The widget's derivations | `tests/test_widget_logic.sh` | `node` |
| The widget's QML, executed | `tests/test_widget_qml.sh` plus `tests/qml/` | `python3-pyside6`, and the Plasma and Kirigami QML modules the widget imports |
| The offline lifecycle against real dnf5 | `tests/live/` | podman, network, several minutes |

```bash
tests/run_tests.sh            # everything above except tests/live
bash tests/test_doctor.sh     # one file (they are mode 0644, so invoke with bash)
```

Without `node` or PySide6 the run still passes, but prints a `skip:` line, and `run_tests.sh`
lists every skip at the end. Those two layers hold more than half of the assertions.

## Writing a test file

Source `tests/lib.sh` and call `sandbox` first. It points `HOME`, `KEMPT_CONFIG_DIR` and
`KEMPT_STATE_DIR` into a throwaway directory, resets every environment seam, and sets the EXIT trap
that cleans up. Never set your own EXIT trap, and end the file with `finish`.

Use the assertions: `assert_eq`, `assert_contains`, `assert_not_contains`, `assert_json_eq`,
`assert_exit`. They print what was expected, what arrived, and the file and line.

Label an assertion that only sets up the next one with `premise:`. A failure there means the
scenario never happened.

**Use `awk 'NR==1'`, not `head`.** `head` closes the pipe early, the command before it gets
SIGPIPE, and under `pipefail` and `errexit` the file exits 141 with no `FAIL` line. It happens only
some of the time, so it can pass every time you run it by hand. For `head -c`, count with `wc -c`
instead.

## The QML probes

`tests/qml/probe_*.py` run the real Qt 6 QML engine over the shipped `.qml` files against a stubbed
`kempt` on a real `PATH`. `tests/test_widget_qml.sh` runs every file matching that glob, so a new
probe needs no list edited anywhere.

Run one on its own:

```bash
python3 tests/qml/safe_probe.py 120 python3 tests/qml/probe_popup.py
```

A probe refuses to run without the supervisor, which adds the timeout, a process group to kill,
and the offscreen platform. Without them a stuck probe keeps running and windows open on your
desktop.

Inside a probe, `p.stub(...)` writes the fake CLI, `p.calls_matching(...)` reads back what the
widget ran, and `p.clear_calls()` empties that log. Clear it before an action whose calls you count,
or earlier scenarios' calls are counted too.
