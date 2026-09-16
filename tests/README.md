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

A missing `node` or PySide6 does not fail the run. It prints a `skip:` line, and `run_tests.sh`
lists every skip at the end, because those two layers carry more than half of the assertions and a
green run without them means much less than it looks like.

## Writing a test file

Source `tests/lib.sh` and call `sandbox` first. It creates one throwaway directory, points `HOME`,
`KEMPT_CONFIG_DIR` and `KEMPT_STATE_DIR` inside it, neutralizes every environment seam, and
installs the EXIT trap that cleans up and sets the file's exit status. Never install your own EXIT
trap, and end the file with `finish`.

Use the assertions rather than hand-rolled `echo FAIL`: `assert_eq`, `assert_contains`,
`assert_not_contains`, `assert_json_eq`, `assert_exit`. They print what was expected, what arrived,
and the file and line the assertion was written on.

Label an assertion that only sets up the condition for the next one with `premise:`. It says that a
failure there means the scenario never happened, so the assertions after it prove nothing rather
than disagreeing with something.

## The QML probes

`tests/qml/probe_*.py` run the real Qt 6 QML engine over the shipped `.qml` files against a stubbed
`kempt` on a real `PATH`. `tests/test_widget_qml.sh` runs every file matching that glob, so a new
probe needs no list edited anywhere.

Run one on its own:

```bash
python3 tests/qml/safe_probe.py 120 python3 tests/qml/probe_popup.py
```

Never `python3 tests/qml/probe_popup.py`: without the supervisor there is no watchdog, no process
group to kill and no offscreen platform, so a wedged probe stays resident and a probe that builds a
window opens a real one on your desktop. The harness refuses that command and prints the one above.

Inside a probe, `p.stub(...)` writes the fake CLI, `p.calls_matching(...)` reads back what the
widget ran, and `p.clear_calls()` empties that log. Reset it before an action whose call count you
are about to assert, or you are counting every earlier scenario's calls as well.
