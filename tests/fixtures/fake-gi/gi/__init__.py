# A stand-in for PyGObject, so tests/test_reclaim.sh can run libexec/kempt-flatpak-unused on a box
# with no libflatpak and no system installation. It serves the refs in $FAKE_FLATPAK_JSON, which has
# the helper's own output shape, and their metadata from $FAKE_FLATPAK_METADATA. It records every
# Installation constructor that was called in $FAKE_FLATPAK_CALLS, so the test can prove the helper
# never opens the user installation.


def require_version(namespace, version):
    if namespace != "Flatpak" or version != "1.0":
        raise ValueError("unexpected typelib %s %s" % (namespace, version))
