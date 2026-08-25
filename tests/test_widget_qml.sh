#!/usr/bin/env bash
# The widget's QML, executed.
#
# tests/test_widget_logic.sh covers the two halves that do not need a running engine: every
# DERIVATION rule (logic.js, under node) and the fact that every .qml compiles. Neither can answer
# the questions that actually broke in review - does pressing Apply write the right keys, does the
# watcher end a run at the right moment, does a hostile package name reach the shell as ONE
# argument. Those need the real Qt 6 QML engine running the real files against a real CLI on a
# real PATH, which is what tests/qml/ does.
#
# PROCESS DISCIPLINE, and it is not decorative. An early version of these probes was run with no
# working timeout: a PySide6 process wedged in Qt teardown never reaches a SIGTERM handler, so
# every wedged probe stayed resident and every retry added more. One afternoon that reached ~2,200
# Qt processes and OOM-killed production on this box. Hence: strictly one probe at a time, each
# one supervised by tests/qml/safe_probe.py (own process group, SIGKILL, count guards) with the
# in-process watchdog from tests/qml/_safe/sitecustomize.py armed inside it, and a count assertion
# at the end of this file. If that assertion ever fails, stop and fix it - do not re-run.
source "$(dirname "$0")/lib.sh"; sandbox
QMLDIR="$REPO_ROOT/tests/qml"

# Seconds the in-probe watchdog allows before it self-terminates. The slowest probe runs in about
# nine; this is a ceiling for a wedged one, not a budget.
PROBE_WATCHDOG=120

# PySide6 is not a dependency of Kempt itself, so its absence must not fail the suite - but it must
# be LOUD, because a silent skip here means the widget's QML went unexecuted.
if ! python3 -c 'import PySide6' >/dev/null 2>&1; then
  echo "ok: SKIPPED - PySide6 is absent, so the widget's QML was NOT executed in this run"
  echo "    (install python3-pyside6 and re-run: these probes are the only tests that run the"
  echo "     real QML - the rest of the widget's coverage is logic.js under node)"
  finish
fi

pycount() { ps -eo args --no-headers | grep -c '^python3' || true; }

# Everything already on the box before we add to it. The probes are the only python3 this file
# starts, so anything above this at the end is ours and is a leak.
baseline="$(pycount)"

run_probe() {  # probe_name
  # Separate statements on purpose: bash expands every word of a `local` BEFORE it assigns any
  # of them, so `local probe="$1" out="$TESTTMP/$probe.out"` reads $probe while it is still unset -
  # which under `set -u` (lib.sh) is a hard error, not an empty string.
  local probe="$1"
  local out="$TESTTMP/$probe.out"
  local rc=0
  # SERIAL, always: one safe_probe at a time, and it does not return until its whole process
  # group is gone.
  python3 "$QMLDIR/safe_probe.py" "$PROBE_WATCHDOG" python3 "$QMLDIR/$probe.py" \
    >"$out" 2>&1 || rc=$?
  # The probe's assertions are this file's assertions: pass its own ok:/FAIL: lines straight
  # through so the suite output reads the same as every other test file.
  grep -E '^(ok|FAIL|  |COMPILE ERR)' "$out" || true
  if [[ $rc -ne 0 ]]; then
    echo "FAIL: $probe exited $rc"
    echo "  full output:"
    sed 's/^/    /' "$out"
    _fail=1
  fi
  # safe_probe's own verdict line carries the before/after count for this probe.
  grep -E '^--- safe_probe' "$out" | sed 's/^/  /' || true
}

echo "-- Executor.qml: the one place commands run"
run_probe probe_executor
echo "-- main.qml: state machine, watcher, panel icon geometry"
run_probe probe_state
echo "-- FullRepresentation.qml: popup actions, log tail, run-end watcher"
run_probe probe_popup
echo "-- configGeneral.qml: the settings page's apply path"
run_probe probe_settings

# Nothing may survive the battery. +2 is slack for an unrelated python3 that started while this
# ran (the box runs other things); anything more than that is a probe that did not die.
after="$(pycount)"
if [[ "$after" -le $((baseline + 2)) ]]; then
  echo "ok: no probe processes survived the battery (python3 $baseline -> $after)"
else
  echo "FAIL: probe processes leaked (python3 $baseline -> $after, ceiling $((baseline + 2)))"
  ps -eo pid,args --no-headers | grep '^ *[0-9]* python3' | sed 's/^/    /'
  _fail=1
fi

finish
