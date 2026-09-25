# Releasing Kempt

How to cut a release, in order. Every step has been run for each release since 0.1.2. The spec has
built two packages, `kempt` and `kempt-plasmoid`, since 0.1.2, and step 4 checks the upgrade across
that split on every release.

## Kempt never updates itself

Kempt has no self-update code. The package manager already handles signatures, rollback and
dependencies, and gives the administrator one place to audit. So Kempt ships as a package and
shows up in its own list like any other update. Only checkout installs upgrade by hand (step 10).

## The release

1. **Bump `VERSION`.** It is the source of truth, and three other files repeat it.

   ```bash
   printf '0.2.0\n' > VERSION
   tests/test_version.sh          # names every file that does not agree yet
   ```

   Update these, then run the test again until it passes:

   - `KPlugin.Version` in `plasmoid/metadata.json`.
   - `<release version=` in `io.github.erez_c137.kempt.metainfo.xml`, with the release date in
     `date=`, newest first.
   - The two `<screenshot>` URLs in the same file. They name the new tag
     (`.../kempt/v0.2.0/docs/images/...`), not `main`, so a software centre shows the screenshots
     of this release.
   - `Version:` in `kempt.spec`.

   By hand, because no test checks them: a new dated entry in the spec's `%changelog`, and the
   supported-versions table in `SECURITY.md` if this release changes it.

2. **Move the CHANGELOG and the roadmap.** Rename `## [Unreleased]` to
   `## [0.2.0] - YYYY-MM-DD` and add a new empty `## [Unreleased]` above it. Then move what shipped
   from the plan sections of `docs/ROADMAP.md` into **Shipped**.

3. **Run the full suite** and check it ends with `ALL PASS`. Never release over a known failure.

   ```bash
   tests/run_tests.sh
   ```

4. **Run the release check.** The suite tests the code; this tests the packages.

   ```bash
   tests/release/run-release-check.sh
   ```

   It takes several minutes and needs podman and the network. It builds the packages from your tree
   and installs them in a fresh Fedora container. Then it checks that:

   - the widget lands where Plasma looks, and the installed QML runs;
   - `doctor`, `holds`, `config` and an unknown command give a new user sensible answers;
   - the package has the man page and user guides, and no maintainer documents;
   - an upgrade from the last release keeps the widget;
   - `dnf remove` leaves nothing behind except the user's settings.

   It reads `VERSION`, so nothing needs editing per release. It runs only inside its container.

5. **Commit the bump on its own.**

   ```bash
   git commit -am 'chore: release 0.2.0'
   ```

6. **Tag it**, annotated, with a plain message and no trailers.

   ```bash
   git tag -a v0.2.0 -m 'Kempt 0.2.0'
   git push origin main
   git push origin v0.2.0
   ```

7. **Create the GitHub release.** Write short notes for people who use Kempt; the CHANGELOG is the
   full record. Order: how to upgrade, how to install fresh, what's new, what's fixed, notes for
   packagers, then a link to the CHANGELOG at the tag. One or two sentences per item.

   ```bash
   gh release create v0.2.0 --title 'Kempt 0.2.0' --notes-file notes.md
   ```

   Attach the widget archive from step 9, so the release page and the store serve the same file.
   Build it before this step, or add it later with `gh release upload`.

## Packaging

8. **Build in COPR from the tag.** COPR reads `kempt.spec` from the repository root. Point the
   package at the new tag, then build:

   ```bash
   copr-cli edit-package-scm erez-c137/kempt --name kempt --type git --method rpkg \
     --clone-url https://github.com/erez-c137/kempt.git --spec kempt.spec --commit v0.2.0
   copr-cli build-package erez-c137/kempt --name kempt
   ```

   It builds for Fedora 43, 44, 45 and rawhide, on x86_64 and aarch64. There is no push webhook:
   `Version:` is fixed in the spec, so a rebuild on push would change the files under an unchanged
   version, and dnf would offer nobody the upgrade.

   If a build fails, read the log before blaming COPR. The spec has broken a build before: a test
   called `ps`, which the minimal buildroot does not have.

   `rpmlint` reports no errors and two known warnings: `package-with-huge-docs` on `kempt` and
   `no-documentation` on `kempt-plasmoid`. A `setlocale` warning can also appear, depending on the
   build shell's locale. Read anything else.

   To reproduce the source tarball locally:

   ```bash
   git archive --format=tar.gz --prefix=kempt-0.2.0/ -o kempt-0.2.0.tar.gz v0.2.0
   ```

   The build is done when the README's install commands work in a clean Fedora container:

   ```bash
   sudo dnf copr enable erez-c137/kempt
   sudo dnf install kempt-plasmoid
   ```

   `kempt-plasmoid` must install, and bring `kempt` of the same version with it.

9. **Upload the widget to the KDE Store**, for people not on an RPM distribution. The archive is a
   zip with `metadata.json` at the root, next to `contents/`:

   ```bash
   # zip -r only adds, so start from an empty archive or deleted files still ship.
   rm -f kempt-0.2.0.plasmoid
   ( cd plasmoid && zip -r ../kempt-0.2.0.plasmoid metadata.json contents )

   unzip -l kempt-0.2.0.plasmoid | head -5   # metadata.json is at the root
   # Every file is in the archive. No output means a pass.
   diff <( unzip -Z1 kempt-0.2.0.plasmoid | grep -v '/$' | sort ) \
        <( cd plasmoid && find . -type f | sed 's|^\./||' | sort )
   ```

   Add the archive as a new file on the existing product, <https://store.kde.org/p/2370353/>
   (**Plasma 6 Applets**). Do not use <https://store.kde.org/product/add>: it creates a second product with no
   downloads or comments, and products cannot be merged. Type the version by hand to match
   `VERSION`, and paste the same notes as the GitHub release.

   A store install has no `kempt` command behind it. Before uploading, unpack the archive on a
   machine without the command-line tool and check the popup says *"Kempt's engine is not
   installed"*.

10. **Checkout installs upgrade by hand.** The command is a symlink into the checkout; the rest are
    copies.

    ```bash
    git pull && ./install.sh && plasmashell --replace     # or log out and back in
    kempt doctor                                          # every copy matches the checkout
    ```

    The `helpers:`, `policy:` and `widget:` lines at the end of `kempt doctor` compare each
    installed copy with the checkout. `DIFFER` means a pull that was never installed. See
    [usage](usage.md#doctor).
