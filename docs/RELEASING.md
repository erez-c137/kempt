# Releasing Kempt

The procedure for cutting a release, in the order it is run.

**What has been run.** Steps 1 to 9 have all been run, for 0.1.0 and 0.1.1. `kempt.spec` is
committed at the repo root and has been built, installed and smoke-tested in a Fedora 44
container, and the AppStream metainfo is committed next to it. Step 8's zip commands were run
against this tree. COPR is live: `erez-c137/kempt` builds for fedora-43, fedora-44, fedora-45 and
rawhide, on x86_64 and aarch64, and both releases reached users through it.

**What that history does not cover.** From 0.1.2 the spec builds TWO binary packages, `kempt` and
`kempt-plasmoid`, and 0.1.0 and 0.1.1 built one. Everything a split can break is therefore
unproven by the paragraph above: that an existing install upgrades and keeps its widget, that a
machine with weak dependencies turned off is told what it has to do by hand, and that the install
command the README prints resolves at all. Step 7 ends with the check for the last of those.

## Kempt never updates itself

There is no self-update code in Kempt and there will not be. An updater that updates itself has to
solve, badly and alone, the problem the system's package manager already solves well: signature
checks, a transaction that can be rolled back, a rebuild when a dependency moves, and one place
the administrator can audit. So Kempt ships as a package, and a packaged Kempt is updated by the
package manager it drives. It appears in its own list, in its own popup, next to everything else
that is pending, and `sudo dnf upgrade` or one press of **Update Now** takes it. The only install
that needs a human procedure is a checkout install, and step 9 is that procedure.

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

   Nothing checks **SECURITY.md's supported-versions table** either, and it is the page a Fedora
   reviewer opens second. If this release changes which versions are covered, say so there in the
   same commit: somebody on a packaged release has to be able to tell whether they still are.

2. **Move the CHANGELOG, and the roadmap with it.** Rename the `## [Unreleased]` heading to
   `## [0.2.0] - YYYY-MM-DD` using the release date, and open a fresh empty `## [Unreleased]`
   above it. Nothing else in that file changes: the entries were written as the work landed.

   Then move whatever this release shipped out of `docs/ROADMAP.md`'s plan sections and into its
   **Shipped** section, in that section's style. Nothing checks this either, and the failure mode
   is a roadmap presenting a built feature as an unbuilt plan to everyone who reads the page.

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

   Attach the widget archive as a release asset, so the release page and the store listing serve
   the same file. It is built by the first block of step 8, which is the one place the numbered
   order does not run straight through: build it now, before cutting the release, or come back and
   attach it afterwards with `gh release upload`. (The AppStream metainfo points at no archive -
   it carries no `<artifact>` element - so nothing there needs the file to exist.)

## Packaging

7. **COPR build from the tag.** `kempt.spec` is committed at the repo root, which is exactly where
   COPR's SCM source method looks for it. Before trusting a COPR failure, know what already
   passed: the spec builds, installs and smokes clean on Fedora 44, and both the 0.1.0 and the
   0.1.1 releases went through this exact procedure end to end (project created, rpkg SCM builds
   green across fedora-43, fedora-44, fedora-45 and rawhide on x86_64 and aarch64,
   `dnf copr enable` + `dnf install kempt` verified in a clean container).

   `rpmlint` is not silent on this package and does not need to be. Judge it by the KIND of
   finding, never by the count or the percentage - both move with the build root. What it says
   here: a spelling complaint about the word `plasmoid`, a locale warning from the build shell,
   a documentation-share warning on a package that is deliberately mostly documentation, and
   `no-documentation` on the widget subpackage, which ships none. Anything outside that set is
   new and worth reading.
   That history is a reason to look at COPR, the chroot and the tag first - it is NOT a reason to
   assume the spec is innocent. It was not, once: the 0.1.2 suite grew a call to `ps`, which is in
   neither `BuildRequires` nor Fedora's minimal buildroot, and `%check` failed every build until
   the call went away. Read the log before deciding which half is at fault.

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
   sudo dnf install kempt-plasmoid
   ```

   Run exactly that, in a clean Fedora container, before calling the build done. It is the command
   the repository's front page tells people to run, and between a docs change landing on `main`
   and this build finishing, it is a command that does not work - `kempt-plasmoid` did not exist
   in the repo until this build put it there. `dnf install kempt-plasmoid` must succeed and bring
   `kempt` of the same version with it. Until it does, the front page is describing a package the
   repository does not serve.

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

   Kempt already has a store product, <https://store.kde.org/p/2370353/>, under **Plasma 6
   Applets** (category 706). Add this release as a new file on THAT product. Do not use
   <https://store.kde.org/product/add>: that form creates a second product, and a second product
   starts at zero downloads with none of the first one's comments, while both stay listed and
   neither is obviously the real one. There is no merge afterwards.

   The store is a content CMS, not a packaging pipeline: the version and the changelog are
   free-text fields typed in by hand. Type the same version as `VERSION`, and paste the same
   CHANGELOG section as the GitHub release. Nothing checks that agreement for you.

   What a store user gets is the widget ALONE, with no `kempt` command behind it. That is a
   supported state and the widget is built for it - it says the engine is not installed and offers
   the commands that install it - so check it stayed true before uploading: the first run of an
   unpacked copy on a box with no CLI must say *"Kempt's engine is not installed"*, not a blank
   popup and not the "will not run" message, which is for an engine that is present.

9. **Checkout installs upgrade by hand**, and always will: they are developer installs, the CLI is
   a symlink into the git tree and the rest are copies.

   ```bash
   git pull && ./install.sh && plasmashell --replace     # or log out and back in
   kempt doctor                                          # every copy matches the checkout
   ```

   `kempt doctor` ends with `helpers:`, `policy:` and `widget:` lines that compare each installed
   copy against the checkout. A `DIFFER` line is a pull that was never installed, which is exactly
   the drift this step exists to prevent. See [docs/usage.md](usage.md#doctor).
