# Releasing Kempt

The procedure for cutting a release, in the order a maintainer runs it. The research behind the
packaging steps is
[docs/research/2026-08-27-packaging-and-listing.md](research/2026-08-27-packaging-and-listing.md),
and what was actually executed against this tree is
[docs/research/2026-09-02-rpm-spec-verification.md](research/2026-09-02-rpm-spec-verification.md).

**What exists and what does not.** `kempt.spec` is committed at the repo root and has been built,
linted, installed and smoke-tested in a Fedora 44 container, and the AppStream metainfo is
committed next to it. Step 8's zip commands were run against this tree. What has **never** been
run is COPR itself: step 7 is still read from upstream documentation, and the repo has to be
public before an SCM-tracked COPR package can clone it at all.

## Kempt never updates itself

There is no self-update code in Kempt and there will not be. An updater that updates itself has to
solve, badly and alone, the problem the system's package manager already solves well: signature
checks, a transaction that can be rolled back, a rebuild when a dependency moves, and one place
the administrator can audit. So Kempt ships as a package, and a packaged Kempt is updated by the
package manager it drives. It appears in its own list, in its own popup, next to everything else
that is pending, and `sudo dnf upgrade` or one press of **Update Now** takes it. The only install
that needs a human procedure is the developer's checkout install, and step 9 is that procedure.

## The release

1. **Bump `VERSION`.** It is the source of truth, and three other files restate it.

   ```bash
   printf '0.2.0\n' > VERSION
   tests/test_version.sh          # names every file that does not agree yet
   ```

   Then bring the other three into line and re-run that file until it is silent:

   - `KPlugin.Version` in `plasmoid/metadata.json`
   - `<release version=` in `io.github.erez_c137.kempt.metainfo.xml`, whose `date=` is the release
     date, newest release first
   - `Version:` in `kempt.spec`

   The test is what keeps the CLI, the widget, the software centre and `rpm -q` from reporting
   four different releases of one install. It does not check the spec's `%changelog`, which needs
   a new dated entry of its own, or the git tag in step 5 - those are on you.

2. **Move the CHANGELOG.** Rename the `## [Unreleased]` heading to `## [0.2.0] - YYYY-MM-DD`
   using the release date, and open a fresh empty `## [Unreleased]` above it. Nothing else in the
   file changes: the entries were written as the work landed.

   Release notes copy: see the voice guides, owed. The CHANGELOG is the maintainer's record and
   ships as it is; announcement text and public release notes are a separate pass that needs the
   founder's voice guides first.

3. **Run the full suite**, serially, and read the count.

   ```bash
   tests/run_tests.sh
   ```

   `ALL PASS` and nothing else. A release is not cut over a known failure.

4. **Commit the bump on its own**, so the diff that says what the release is stays readable.

   ```bash
   git commit -am 'chore: release 0.2.0'
   ```

5. **Tag it**, annotated, with a plain message. No trailers, no generated sign-offs.

   ```bash
   git tag -a v0.2.0 -m 'Kempt 0.2.0'
   git push origin main
   git push origin v0.2.0
   ```

6. **Cut the GitHub release**, with the CHANGELOG's own section as the body.

   ```bash
   awk '/^## \[0.2.0\]/{f=1;next} f&&/^## \[/{exit} f' CHANGELOG.md > /tmp/notes.md
   gh release create v0.2.0 --title 'Kempt 0.2.0' --notes-file /tmp/notes.md
   ```

   Attach the widget archive built in step 8 as a release asset, so the store listing and the
   AppStream metainfo can point at the same file the release page serves.

## Packaging

7. **COPR build from the tag.** `kempt.spec` is committed at the repo root, which is exactly where
   COPR's SCM source method looks for it. Before trusting a COPR failure, know what already
   passed: the spec builds, lints to zero rpmlint findings, installs and smokes clean on Fedora 44
   ([the verification note](research/2026-09-02-rpm-spec-verification.md)), and the 0.1.0 release
   went through this exact procedure end to end (project created, rpkg SCM build green on
   fedora-44 and rawhide, `dnf copr enable` + `dnf install kempt` verified in a clean container).
   A red COPR build is therefore about COPR, the chroot or the tag, not about the spec.

   The project (`erez-c137/kempt`) and its one package exist; a release is two commands - point
   the package at the new tag, then build it:

   ```bash
   copr-cli edit-package-scm erez-c137/kempt --name kempt --type git --method rpkg \
     --clone-url https://github.com/erez-c137/kempt.git --spec kempt.spec --commit v0.2.0
   copr-cli build-package erez-c137/kempt --name kempt
   ```

   Deliberately NO push webhook: the spec's `Version:` is static, so a push-triggered rebuild
   produces the same NVR from different source - dnf offers nobody an upgrade and the repo just
   quietly swaps the bits under one version. Webhook-rebuild is set `off` on the package;
   releases are explicit or they are not releases.

   Rebuild the tarball the way the verification did, if you need to reproduce a build locally:

   ```bash
   git archive --format=tar.gz --prefix=kempt-0.2.0/ -o kempt-0.2.0.tar.gz v0.2.0
   ```

   Consumers then get the release the ordinary way, which is the whole point:

   ```bash
   sudo dnf copr enable erez-c137/kempt
   sudo dnf install kempt
   ```

8. **KDE Store upload of the widget**, for people who are not on an RPM distro. The archive is a
   plain zip of the KPackage layout, `metadata.json` at the root next to `contents/`:

   ```bash
   # zip -r ADDS to an existing archive and never removes from one. Rebuild over yesterday's
   # file after deleting a QML file and the deleted file still ships. Start from nothing.
   rm -f kempt-0.2.0.plasmoid
   ( cd plasmoid && zip -r ../kempt-0.2.0.plasmoid metadata.json contents )

   unzip -l kempt-0.2.0.plasmoid | head -5   # sanity: metadata.json sits at the root
   # ...and the whole tree is in there, not just the first screenful. Silence is a pass.
   diff <( unzip -Z1 kempt-0.2.0.plasmoid | grep -v '/$' | sort ) \
        <( cd plasmoid && find . -type f | sed 's|^\./||' | sort )
   ```

   The archive lands in the repo root and is a build artifact, not a source file: `.gitignore`
   carries `*.plasmoid` so a release-day `git add -A` cannot swallow it.

   Upload it at <https://store.kde.org/product/add> under **Plasma 6 Applets** (category 706).
   The store is a content CMS, not a packaging pipeline: the version and the changelog are
   free-text fields you type in by hand. Type the same version as `VERSION`, and paste the same
   CHANGELOG section as the GitHub release. Nothing checks that agreement for you.

9. **Checkout installs upgrade by hand**, and always will: they are developer installs, the CLI is
   a symlink into the git tree and the rest are copies.

   ```bash
   git pull && ./install.sh && plasmashell --replace     # or log out and back in
   kempt doctor                                          # every copy matches the checkout
   ```

   `kempt doctor` ends with `helpers:`, `policy:` and `widget:` lines that compare each installed
   copy against the checkout. A `DIFFER` line is a pull that was never installed, which is exactly
   the drift this step exists to prevent. See [docs/usage.md](usage.md#doctor).
