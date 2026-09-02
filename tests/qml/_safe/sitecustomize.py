"""In-process watchdog for every PySide6 probe in tests/qml.

Auto-imported by CPython at startup when this directory is on PYTHONPATH, so it arms INSIDE the
probe process - the probe self-terminates instead of depending on an outer `timeout`, which is the
distinction that matters: `timeout` sends SIGTERM, and a PySide6 process wedged inside Qt teardown
never reaches a signal handler. os._exit() is deliberate: it skips atexit and interpreter
finalization, which is exactly where a live QQmlEngine can deadlock and leave the process resident
forever.

  PROBE_WATCHDOG_SECS  hard ceiling on the whole probe (default 120)
  PROBE_EXIT_SECS      ceiling on teardown once the probe has decided its verdict (default 10)
"""
import atexit
import os
import threading

_LIMIT = float(os.environ.get("PROBE_WATCHDOG_SECS", "120"))
_EXIT = float(os.environ.get("PROBE_EXIT_SECS", "10"))


def _bomb(code, why):
    try:
        os.write(2, ("\n[watchdog] %s - self-terminating with %d\n" % (why, code)).encode())
    except Exception:
        pass
    os._exit(code)


_t = threading.Timer(_LIMIT, _bomb, args=(97, "probe ran past %gs" % _LIMIT))
_t.daemon = True
_t.start()


@atexit.register
def _arm_teardown_bomb():
    # The probe has printed its verdict and called sys.exit; from here only Qt destruction is left.
    # If that wedges, nothing else will ever kill this process, so give it a short leash.
    b = threading.Timer(_EXIT, _bomb, args=(98, "hung in Qt teardown past %gs" % _EXIT))
    b.daemon = True
    b.start()
