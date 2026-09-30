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

    def get_name(self):
        return self._d["ref"].split("/")[1]

    def load_metadata(self, cancellable):
        # From $FAKE_FLATPAK_METADATA, a JSON object of ref -> metadata keyfile text. A ref not in it
        # has no metadata file, which the real call reports as an error.
        path = os.environ.get("FAKE_FLATPAK_METADATA")
        table = {}
        if path:
            with open(path) as f:
                table = json.load(f)
        if self._d["ref"] not in table:
            raise RuntimeError("No such file: metadata")
        return _Bytes(table[self._d["ref"]].encode())


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


class _Bytes:
    def __init__(self, data):
        self._data = data

    def get_data(self):
        return self._data


class _KeyFile:
    """Only what the helper uses: load_from_bytes, get_groups, which PyGObject returns as
    (groups, length), and get_string, which raises for a missing group or key."""

    def __init__(self):
        self._groups = []
        self._keys = {}

    def load_from_bytes(self, data, flags):
        for line in data.get_data().decode().splitlines():
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                self._groups.append(line[1:-1])
                self._keys.setdefault(line[1:-1], {})
            elif line and not line.startswith("#") and "=" not in line:
                raise RuntimeError("Key file contains line that is not a key-value pair")
            elif line and not line.startswith("#") and self._groups:
                k, v = line.split("=", 1)
                self._keys[self._groups[-1]][k.strip()] = v.strip()
        return True

    def get_groups(self):
        return (list(self._groups), len(self._groups))

    def get_string(self, group, key):
        try:
            return self._keys[group][key]
        except KeyError:
            raise RuntimeError("Key file does not have key") from None


class _KeyFileFlags:
    NONE = 0


class GLib:
    Bytes = _Bytes
    KeyFile = _KeyFile
    KeyFileFlags = _KeyFileFlags
