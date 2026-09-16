#!/usr/bin/env python3
"""Shared scaffolding for the QML probes in this directory.

These probes exist because the widget's QML cannot be reached any other way. The node tests in
tests/test_widget_logic.sh pin every DERIVATION (logic.js), and the compile gate in that file
proves every .qml parses - but neither one can answer "does pressing Apply write the right keys",
"does the watcher end a run at the right moment", or "does a hostile package name survive the trip
to a shell as one argument". Those need the real Qt 6 QML engine, running the real files, against
a real (stubbed) CLI on a real PATH. That is what this is.

What it is NOT: plasmoidviewer. Nothing is drawn, no Applet exists, and no assertion here says
anything about layout, spacing or how it looks. That stays a manual check before release.

Every probe is driven by safe_probe.py, one at a time, with a watchdog inside it - see the header
of that file for why that discipline is not optional.
"""
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# KEMPT_UI_DIR points this battery at a DIFFERENT copy of the widget than the checkout's. The
# release check uses it to run every probe against the files the RPM actually installed, under
# /usr/share/plasma/plasmoids/, which is a different directory from the one a developer edits and
# the one nothing had ever executed. Unset, it is the checkout, which is what a contributor wants.
UI = os.environ.get("KEMPT_UI_DIR") or os.path.join(REPO, "plasmoid", "contents", "ui")
FIXTURES = os.path.join(REPO, "tests", "fixtures")

# What the REAL CLI answers when nothing has been configured, from kempt_default() in
# lib/common.sh. One copy, because five probes had each written their own and every one of them
# answered `refresh_interval_min` with 15 while the shipped default is 60: the widget's timer
# arithmetic was being exercised against a number no user's box will ever produce, in five files
# at once, and a sixth probe copying its neighbour would have made it six.
CONFIG_DEFAULTS = {
    "include_flatpak": "true",
    "auto_accept": "true",
    "surface": "terminal",
    "refresh_interval_min": "60",
    "widget_icon_size": "auto",
    "restart_reminder": "true",
}


def config_arm(**overrides):
    """The `config` arm of a stub CLI, answering `get` with the real defaults.

    Each override is a shell snippet that PRINTS the answer, not a bare value: a probe that has to
    change a setting mid-run passes `auto_accept="cat /path/to/file"`, and one that only wants a
    different constant passes `surface="echo popup"`.

    An unknown key exits 2 rather than printing nothing under exit 0, because that is what the CLI
    does, and a stub that is more forgiving than the real thing is a stub that hides the caller
    that asks for a key the CLI does not have.
    """
    answers = dict((k, "echo %s" % v) for k, v in CONFIG_DEFAULTS.items())
    answers.update(overrides)
    cases = "".join("              %s) %s ;;\n" % (k, answers[k]) for k in sorted(answers))
    return ("  config)\n"
            "          if [[ \"$2\" == get ]]; then\n"
            "            case \"$3\" in\n"
            + cases
            + "              *) echo \"kempt: unknown setting: $3\" >&2; exit 2 ;;\n"
              "            esac\n"
              "            exit 0\n"
              "          fi\n"
              "          exit 0 ;;")

# The probes load the SHIPPED files straight out of the repo. No copies, on purpose: a probe
# directory holding its own copy of the widget is a probe that goes on passing after the widget
# changes, which is how the earlier version of this kit ended up testing a file that still said
# "upkeep" three commits after the project was renamed.

# i18n/i18np/i18nc/i18ndc, which plasmashell puts in every plasmoid's JS scope and a bare
# QQmlEngine does not. The difference is not cosmetic: a `text: i18n("Update Now")` binding that
# throws leaves the button's text EMPTY, and configGeneral.qml's surface Repeater builds its model
# out of object literals whose labels are i18n() calls - so the whole model evaluates to undefined
# and the Repeater ends up with NO DELEGATES AT ALL. An earlier version of these probes was
# inspecting a settings page with no radio buttons in it and reporting success. This shim is
# fidelity, not convenience: it makes the probe's scope the scope the widget actually runs in.
_I18N_SHIM = """(function () {
  function sub(s, args, from) {
    for (var i = from; i < args.length; i++) s = s.replace('%' + (i - from + 1), args[i]);
    return s;
  }
  this.i18n   = function () { return sub(String(arguments[0]), arguments, 1); };
  this.i18np  = function () { return sub(String(arguments[2] === 1 ? arguments[0] : arguments[1]),
                                         arguments, 2); };
  this.i18nc  = function () { return sub(String(arguments[1]), arguments, 2); };
  this.i18ndc = function () { return sub(String(arguments[2]), arguments, 3); };
})"""


class ProbeExpressionError(RuntimeError):
    """A QML expression a probe evaluated did not run at all."""


def have_pyside():
    """Is PySide6 USABLE, which is not the same question as whether it imports.

    Two changes from the obvious version, both of which decide whether a run reports honestly.
    The import is `PySide6.QtQuick`, the module the probes actually need, because a bare
    `import PySide6` succeeds against an installation whose Qt bindings are half upgraded. And
    the catch is Exception, not ImportError: a broken installation raises ImportError only if it
    is lucky, and anything else escaping here ends the probe with a traceback rather than with
    the loud skip that tells the reader the widget's QML went unexecuted.
    """
    try:
        import PySide6.QtQuick  # noqa: F401
        return True
    except Exception:
        return False


class Probe:
    """One QML engine, one sandboxed HOME, and the assertions run against them."""

    def __init__(self, name):
        # REFUSED unless safe_probe.py started this. `python3 tests/qml/probe_popup.py` is the
        # obvious command and it is the one that bypasses every protection here: no in-process
        # watchdog, so a wedged Qt process stays resident forever; no separate process group, so
        # nothing can kill the shells the QML spawned; and QT_QPA_PLATFORM unset, so a probe that
        # builds a window opens a REAL one on the desktop running it. That combination is what
        # reached ~2,200 resident Qt processes in one afternoon and OOM-killed this box, and the
        # only thing that had ever stood between the two was a paragraph in a docstring.
        # PROBE_WATCHDOG_SECS is set by safe_probe.py and by nothing else, so its absence is
        # exactly "nobody is supervising this".
        if not os.environ.get("PROBE_WATCHDOG_SECS"):
            here = os.path.dirname(os.path.abspath(__file__))
            print("REFUSING TO RUN: %s was started directly, so the watchdog, the process-group\n"
                  "kill and the offscreen platform are all absent.\n\n"
                  "Run it through the supervisor:\n"
                  "    python3 %s 120 python3 %s\n"
                  "or run the whole battery: tests/test_widget_qml.sh"
                  % (name, os.path.join(here, "safe_probe.py"),
                     os.path.abspath(sys.argv[0])))
            sys.exit(3)
        self.name = name
        self.fails = []
        self.sandbox = tempfile.mkdtemp(prefix="kempt-%s." % name)
        self.home = os.path.join(self.sandbox, "home")
        self.bindir = os.path.join(self.home, ".local", "bin")
        self.state = os.path.join(self.home, ".local", "state", "kempt")
        self.config = os.path.join(self.home, ".config", "kempt")
        os.makedirs(self.bindir)
        self.calls = os.path.join(self.sandbox, "calls")

        # The two commands that must never be the real ones, shadowed for EVERY probe rather than
        # in the four that remembered to. `dbus-send` opens KDE's logout prompt on a live session
        # and `xdg-open` opens a file in the user's editor, and the Executor hands every command
        # to /bin/sh with this process's environment - so a bin directory in front of PATH is the
        # whole seam. A probe that presses a Restart button is exactly the one that forgets, which
        # is how probe_a11y came to tab onto Restart, press Space, and resolve `dbus-send` to
        # /usr/bin/dbus-send. A probe that wants to RECORD either call writes its own recorder over
        # these afterwards; this is the floor, not the ceiling.
        os.environ["PATH"] = self.bindir + os.pathsep + os.environ.get("PATH", "")
        for _name in ("dbus-send", "xdg-open"):
            _shadow = os.path.join(self.bindir, _name)
            with open(_shadow, "w") as fh:
                fh.write("#!/usr/bin/env bash\nexit 0\n")
            os.chmod(_shadow, 0o755)

        os.environ["HOME"] = self.home
        # The suite's own sandbox() exports these, and main.qml's watched paths honour them
        # (${KEMPT_STATE_DIR:-$HOME/...}). Leaving them set would point the widget's watcher at
        # the shell test's directories instead of this probe's, so the probe would never see its
        # own state file move. Unset means the $HOME fallback runs, which is the real user's path.
        for var in ("KEMPT_STATE_DIR", "KEMPT_CONFIG_DIR"):
            os.environ.pop(var, None)

        from PySide6.QtGui import QGuiApplication
        from PySide6.QtQml import QQmlEngine

        self.app = QGuiApplication(sys.argv[:1])
        self.engine = QQmlEngine()
        for p in ("/usr/lib64/qt6/qml", "/usr/lib/qt6/qml"):
            if os.path.isdir(p):
                self.engine.addImportPath(p)
        self.engine.evaluate(_I18N_SHIM).call([self.engine.globalObject()])
        self.keep = []          # QQmlComponent/objects the engine must not collect mid-probe

    # --- the stubbed CLI ------------------------------------------------------------------------
    def stub(self, body):
        """Write $HOME/.local/bin/kempt. `body` is the case statement; the preamble logs the call.

        main.qml and configGeneral.qml both prefix their commands with
        PATH="$HOME/.local/bin:$PATH", so a stub here is what they find - the same mechanism that
        makes the widget work off a symlink install.
        """
        path = os.path.join(self.bindir, "kempt")
        with open(path, "w") as fh:
            fh.write("#!/usr/bin/env bash\n"
                     "printf '%s\\n' \"$*\" >> " + self.calls + "\n"
                     "printf '%s\\n' \"$#\" > " + self.sandbox + "/argc.\"$1\"\n"
                     "printf '%s\\n' \"$@\" > " + self.sandbox + "/argv.\"$1\"\n"
                     + body + "\n"
                     # The tail is the `*)` arm the case statements above do not write: a verb the
                     # stub does not know exits 2, the way the real CLI does. Ending in `exit 0`
                     # meant a probe could drive the widget into calling anything at all - a verb
                     # that had been renamed, a typo, a command removed two releases ago - and the
                     # widget would see a clean success and the probe would pass.
                     "printf 'kempt: unknown command: %s\\n' \"$1\" >&2\n"
                     "exit 2\n")
        os.chmod(path, 0o755)
        return path

    def calls_matching(self, prefix):
        if not os.path.exists(self.calls):
            return []
        return [l.rstrip("\n") for l in open(self.calls) if l.startswith(prefix)]

    def call_count(self, prefix):
        return len(self.calls_matching(prefix))

    def clear_calls(self):
        open(self.calls, "w").close()

    def argv(self, verb):
        p = os.path.join(self.sandbox, "argv." + verb)
        return open(p).read().split("\n")[:-1] if os.path.exists(p) else []

    def argc(self, verb):
        p = os.path.join(self.sandbox, "argc." + verb)
        return open(p).read().strip() if os.path.exists(p) else "0"

    # --- building QML --------------------------------------------------------------------------
    def create(self, qml_name, wait_ms=0):
        """Instantiate a shipped .qml by file name. Returns (object, evaluator)."""
        from PySide6.QtCore import QUrl
        from PySide6.QtQml import QQmlComponent, QQmlEngine

        comp = QQmlComponent(self.engine, QUrl.fromLocalFile(os.path.join(UI, qml_name)))
        if comp.errors():
            for e in comp.errors():
                print("COMPILE ERR:", e.description())
            sys.exit(2)
        obj = comp.create()
        if obj is None:
            print("FAIL: %s did not instantiate" % qml_name)
            self.fails.append(qml_name)
            return None, None
        # Objects a QQmlComponent creates default to JavaScript ownership; without this the engine
        # collects them mid-probe and every later expression reads from a destroyed object.
        QQmlEngine.setObjectOwnership(obj, QQmlEngine.CppOwnership)
        self.keep.append((comp, obj))
        if wait_ms:
            self.pump(wait_ms)
        return obj, self.evaluator(obj)

    def create_inline(self, source, name="probe-inline.qml"):
        """Instantiate a QML snippet written here rather than shipped. Returns (object, ev)."""
        from PySide6.QtCore import QUrl
        from PySide6.QtQml import QQmlComponent, QQmlEngine

        comp = QQmlComponent(self.engine)
        comp.setData(source if isinstance(source, bytes) else source.encode(),
                     QUrl.fromLocalFile(os.path.join(UI, name)))
        obj = comp.create()
        if obj is None:
            for e in comp.errors():
                print("  inline err:", e.description())
            sys.exit(2)
        QQmlEngine.setObjectOwnership(obj, QQmlEngine.CppOwnership)
        self.keep.append((comp, obj))
        return obj, self.evaluator(obj)

    def evaluator(self, obj):
        from PySide6.QtQml import QQmlExpression

        ctx = self.engine.contextForObject(obj)

        def ev(expr):
            e = QQmlExpression(ctx, obj, expr)
            v = e.evaluate()
            if e.hasError():
                # RAISED, not printed and carried on from. Returning None meant the next line
                # compared None against a number and died somewhere unrelated, or - the case that
                # actually costs something - compared None against None and PASSED, so a broken
                # expression read as the right answer. The error names the expression that failed.
                raise ProbeExpressionError("%s\n  in expression: %s"
                                           % (e.error().toString(), expr))
            if isinstance(v, tuple) and len(v) == 2 and isinstance(v[1], bool):
                return None if v[1] else v[0]
            return v

        return ev

    # --- driving the event loop ----------------------------------------------------------------
    def pump(self, ms):
        from PySide6.QtCore import QEventLoop, QTimer

        loop = QEventLoop()
        QTimer.singleShot(ms, loop.quit)
        loop.exec()

    def wait_for(self, ev, expr, want=True, timeout_ms=8000):
        """Poll an expression until it equals `want`. Returns whether it got there."""
        for _ in range(max(1, timeout_ms // 50)):
            if ev(expr) == want:
                return True
            self.pump(50)
        return ev(expr) == want

    def wait_idle(self, ev, *executors, **kw):
        """Wait until every named Executor has drained its queue.

        This replaces the fixed `pump(1500)` sleeps the first version of these probes used after
        every action. Those were both slow (they dominated a 23-second run) and unsound: 1500ms is
        a guess, and a guess that is too short fails intermittently on a loaded box. An Executor
        with nothing current and an empty queue has genuinely finished, so this is faster AND
        stricter. Note the queue is populated SYNCHRONOUSLY by run(), so an action that dispatched
        nothing reports idle immediately - which is exactly the right answer for the assertions
        that check nothing was written.
        """
        timeout_ms = kw.get("timeout_ms", 10000)
        names = executors or ("cfgExecutor",)
        cond = " && ".join("(%s.current === null && %s.queue.length === 0)" % (n, n)
                           for n in names)
        ok = self.wait_for(ev, cond, True, timeout_ms)
        self.pump(30)   # let the callback that finish() just fired settle its properties
        return ok

    # --- assertions ----------------------------------------------------------------------------
    def check(self, label, got, want):
        if got == want:
            print("ok: %s" % label)
        else:
            print("FAIL: %s\n  expected: %r\n  got:      %r" % (label, want, got))
            self.fails.append(label)

    def done(self):
        shutil.rmtree(self.sandbox, ignore_errors=True)
        print()
        print("FAILURES: %d" % len(self.fails))
        return 1 if self.fails else 0


def touch(path, when):
    subprocess.run(["touch", "-d", when, path], check=True)
