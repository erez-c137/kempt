import json
import os


def _record(what):
    path = os.environ.get("FAKE_FLATPAK_CALLS")
    if path:
        with open(path, "a") as f:
            f.write(what + "\n")


class _File:
    def __init__(self, path):
        self._path = path

    def get_path(self):
        return self._path


class _Ref:
    def __init__(self, d):
        self._d = d

    def format_ref(self):
        return self._d["ref"]

    def get_commit(self):
        return self._d["commit"]

    def get_deploy_dir(self):
        return self._d["deploy_dir"]

    def get_eol(self):
        return self._d.get("eol")


class _Installation:
    def __init__(self):
        with open(os.environ["FAKE_FLATPAK_JSON"]) as f:
            self._data = json.load(f)
        if os.environ.get("FAKE_FLATPAK_FAIL"):
            raise RuntimeError(os.environ["FAKE_FLATPAK_FAIL"])

    @staticmethod
    def new_system(cancellable):
        _record("new_system")
        return _Installation()

    @staticmethod
    def new_user(cancellable):
        _record("new_user")
        return _Installation()

    def get_path(self):
        return _File(self._data["installation"])

    def list_unused_refs(self, arch, cancellable):
        return [_Ref(d) for d in self._data["unused"]]

    def list_installed_refs(self, cancellable):
        # Unused first on purpose: the helper must take them out of "used" by name, not by position.
        return [_Ref(d) for d in self._data["unused"] + self._data["used"]]


class Flatpak:
    Installation = _Installation
