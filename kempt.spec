Name:           kempt
Version:        0.1.4
# A hand build passes --define "kempt_local <stamp>" so two builds of DIFFERENT CONTENT cannot both
# call themselves 0.1.4-1: without it `rpm -q` cannot tell them apart and the only way to know which
# one is installed is to hash the files, which is how a pre-fix build sat on a machine looking
# identical to the fixed one. Undefined - every release, COPR and Koji build - this expands to
# exactly `1%%{?dist}`, so the released NEVR is untouched.
#
# The stamp goes in front as `0.`, Fedora's own pre-release convention, so a local build sorts BELOW
# the real thing: when the official package arrives it upgrades over the hand build by itself. A
# suffix would have sorted ABOVE it, leaving a scratch build pinned on the machine with dnf
# reporting nothing to do.
Release:        %{?kempt_local:0.%{kempt_local}.}1%{?dist}
Summary:        One-click system updates for Fedora, with holds and offline staging

# Every original file is MIT. The one CC0-1.0 file in the tree is the AppStream metainfo, whose
# metadata_license is CC0-1.0 by freedesktop convention - and since the widget moved to its own
# subpackage that file ships there, not here, which is why this tag is plain MIT and the combined
# one is on kempt-plasmoid. A package must not claim a license for content it does not contain.
License:        MIT
URL:            https://github.com/erez-c137/kempt
Source0:        %{url}/archive/v%{version}/%{name}-%{version}.tar.gz

BuildArch:      noarch

# Everything here is bash, QML and SVG. No compiler, no build step. Build-time tools are the two
# metainfo validators plus what the check-stage test suite needs (bash, jq, coreutils, flock).
#
# No .desktop file, deliberately: a Plasma applet is not a menu-launched application.
# plasmashell discovers the widget through plasmoid/metadata.json and it is added from Add
# Widgets; there is nothing for a .desktop file to launch, which is also why the metainfo is
# type="addon" with no <launchable>. So: no desktop-file-utils, no desktop-file-install.
#
# The check stage validates the metainfo twice. Fedora's AppData guidelines require
# `appstream-util validate-relax`, with libappstream-glib as a build dependency. appstreamcli is
# the reference implementation and the one the metainfo was written against, so it runs too.
# The metainfo has no <icon>, which is why both accept it: it describes an add-on that extends
# plasmashell, not an application, and appstream-util accepts a stock icon only from a fixed list
# of freedesktop names, which "kempt" is not.
BuildRequires:  appstream
BuildRequires:  libappstream-glib
# For the check stage only: the test suite's bash half needs these (the CLI needs them at
# runtime too, so they are also Requires below - the build root does not inherit those).
BuildRequires:  jq
BuildRequires:  util-linux-core

# No Requires on bash: rpm generates /usr/bin/bash from the shebangs, and every supported Fedora
# ships bash 5.
Requires:       jq
Requires:       dnf5
Requires:       polkit
Requires:       util-linux-core
# `dnf5 needs-restarting` is the WHOLE of the reboot answer, and it lives in dnf5-plugins, not in
# dnf5: `dnf5 -q repoquery --whatprovides "dnf5-command(needs-restarting)"` returns dnf5-plugins,
# and dnf5 itself only provides dnf5-command(offline). Without it reboot_needed is permanently
# false with a warning on stderr that no widget user will ever read, so a restart owed after a
# kernel update is simply never offered. The virtual provide, not the package name, so a future
# re-home of the subcommand does not break this.
Requires:       dnf5-command(needs-restarting)
# Optional backend: the CLI runs fine without it (include_flatpak simply reports disabled).
Recommends:     flatpak
# Both of these are weak on purpose. libnotify was declared nowhere, and konsole was only
# Suggested, which dnf does not install.
# notify-send is how every detached surface reports what it did; without it those runs finish
# silently. konsole is what the DEFAULT surface launches, so with it merely Suggested
# `kempt doctor` reported a FAIL on a fresh, correct install - the first command the docs tell a
# new user to run.
Recommends:     libnotify
Recommends:     konsole

# The widget package is described here, not named. rpmlint's dictionary does not know the second
# half of its name and reports it as a spelling error on this package and the source package.
%description
Kempt shows which dnf5 and Flatpak updates are pending with the version each
package moves from and to, counts only the updates you have not held, and
applies them in a terminal, in the background, or staged for the next restart.
The Plasma panel widget is a separate package, which dnf5 adds by default on a
system that has Plasma, so installing this package on a server or in a
container does not pull in the desktop.

%package plasmoid
Summary:        Plasma 6 panel widget for Kempt
# The AppStream metainfo ships in this subpackage, and its metadata_license is CC0-1.0.
License:        MIT AND CC0-1.0
Requires:       %{name} = %{version}-%{release}
Requires:       plasma-workspace
Requires:       hicolor-icon-theme
# So a Plasma box that installs or upgrades the CLI gets the widget without having to know the
# subpackage exists, while a server or a container that has no Plasma gets neither it nor the
# 2.9 GiB of desktop it would drag in. The split is the whole reason this subpackage exists:
# `Requires: plasma-workspace` on the CLI turned `dnf install kempt` into 787 packages.
Supplements:    (%{name} = %{version}-%{release} and plasma-workspace)

%description plasmoid
The system tray widget: a badge with the number of updates you have not held,
a popup listing each one with the versions it moves between, and one button
that runs the update. It drives the kempt command, so the badge and the
transaction cannot disagree.

%prep
%autosetup

# The check stage runs the test suite, and the suite asserts the tree AS SHIPPED - the
# policy's helper paths above all - so keep an unmodified copy for it before the packaging
# rewrite below touches those files.
cp -a . ../%{name}-pristine

# The polkit action pins the helper path with an exec.path annotation, and the library must agree
# with it or pkexec refuses to run the helper. The dev installer uses /usr/local/libexec; a
# packaged build uses the FHS libexec dir. install.sh names the same path a third time, but it is
# not packaged - a checkout install is the only thing that runs it.
sed -i 's|/usr/local/libexec|%{_libexecdir}|g' \
    polkit/io.github.erez_c137.kempt.policy \
    lib/common.sh

%build
# Nothing to build.

%install
# Every file goes in with -p, and the trees with cp -a, so installed files keep the timestamps
# they have in the release tarball.
#
# The CLI resolves its own tree with readlink -f, so /usr/bin/kempt is a SYMLINK into the tree.
# A real file there would make ROOT=/usr and send it looking for /usr/lib/common.sh.
install -d %{buildroot}%{_datadir}/%{name}
cp -a bin lib backends %{buildroot}%{_datadir}/%{name}/
install -d %{buildroot}%{_bindir}
ln -s %{_datadir}/%{name}/bin/kempt %{buildroot}%{_bindir}/kempt

# Two files the CLI reads out of its own tree at runtime, and the tree is $ROOT here rather than a
# checkout. Verified by installing the package without them: `kempt --version` printed
# "kempt unknown", and `kempt doctor` reported the install as an incomplete checkout.
install -p -m 0644 VERSION %{buildroot}%{_datadir}/%{name}/VERSION
# `kempt enable-passwordless` renders this template into /etc/polkit-1/rules.d. Without it that
# command has nothing to render and fails on the day someone runs it, not before.
install -p -D -m 0644 polkit/49-kempt.rules.in \
    %{buildroot}%{_datadir}/%{name}/polkit/49-kempt.rules.in

# lib/ and backends/ are SOURCED, never executed. rpmlint rejects a 0644 file carrying a shebang,
# and 0755 would advertise an entry point that does nothing when you run it. The shebang stays in
# the checkout, where shellcheck and editors read the dialect off it; the installed copy is a
# library and says so.
# Globbed, not listed by name: a THIRD backend added to backends/ would otherwise keep its
# shebang, install 0644 with it, and rpmlint would reject the package - after the contributor
# followed docs/architecture.md, which says the backend table is everything they need to touch.
sed -i '1{/^#!/d}' %{buildroot}%{_datadir}/%{name}/lib/common.sh \
                   %{buildroot}%{_datadir}/%{name}/backends/*.sh

# Root helpers. Mode 0755, owned by root: the polkit action execs these and nothing else.
install -p -D -m 0755 libexec/kempt-refresh %{buildroot}%{_libexecdir}/kempt-refresh
install -p -D -m 0755 libexec/kempt-apply   %{buildroot}%{_libexecdir}/kempt-apply

# polkit action only. The passwordless RULE is generated per user by `kempt enable-passwordless`
# into /etc/polkit-1/rules.d, names a specific username, and is the admin's file. Not packaged.
install -p -D -m 0644 polkit/io.github.erez_c137.kempt.policy \
    %{buildroot}%{_datadir}/polkit-1/actions/io.github.erez_c137.kempt.policy

# The plasmoid, in the KPackage layout: metadata.json at the root next to contents/.
install -d %{buildroot}%{_datadir}/plasma/plasmoids/io.github.erez_c137.kempt
cp -a plasmoid/metadata.json plasmoid/contents \
    %{buildroot}%{_datadir}/plasma/plasmoids/io.github.erez_c137.kempt/

# The icon ladder, same six rungs install.sh puts into the user's hicolor theme. No icon-cache
# scriptlet: hicolor-icon-theme's own file triggers fire for any package touching that tree.
for pair in scalable:kempt.svg 64x64:kempt-48.svg 48x48:kempt-48.svg \
            32x32:kempt-32.svg 22x22:kempt-22.svg 16x16:kempt-16.svg; do
    install -p -D -m 0644 "plasmoid/contents/icons/${pair#*:}" \
        "%{buildroot}%{_datadir}/icons/hicolor/${pair%%:*}/apps/kempt.svg"
done

install -p -D -m 0644 docs/man/kempt.1 %{buildroot}%{_mandir}/man1/kempt.1
install -p -D -m 0644 io.github.erez_c137.kempt.metainfo.xml \
    %{buildroot}%{_metainfodir}/io.github.erez_c137.kempt.metainfo.xml

# %%doc ships only what someone using the installed package reads, file by file:
# - README.md: what Kempt is and where everything else is.
# - CHANGELOG.md: what each release changed.
# - SECURITY.md: how to report a vulnerability.
# - docs/usage.md, configuration.md, install.md and security.md: the user guides.
# - docs/architecture.md: it holds the state JSON schema, the CLI's public interface, and usage.md
#   and configuration.md send readers to it.
# - docs/images: the two screenshots README and configuration.md show.
# Left out, because they are about working on Kempt rather than using it:
# - CONTRIBUTING.md and AGENTS.md: development setup and conventions for a checkout.
# - CODE_OF_CONDUCT.md: rules for the project's issues and pull requests, which live on the forge.
# - docs/RELEASING.md: the maintainer's release procedure.
# - docs/ROADMAP.md: plans, which an installed copy would keep long after they change.
# - docs/images/kempt-tray-icon.png: no document shows it.
# - docs/man: the man page is installed above, where `man kempt` finds it.
# docs/ stays a directory so README's links keep their paths. 9 of its 16 relative link targets
# resolve on an installed system. The other 7 are the files left out above plus LICENSE, which
# %%license installs; all of them resolve on the forge.
# Pruned here and not in %%prep, because the man page above is installed out of docs/ and %%doc
# reads the tree as it stands at the end of this section.
rm -rf docs/man docs/RELEASING.md docs/ROADMAP.md docs/images/kempt-tray-icon.png

%check
bash -n bin/kempt lib/common.sh backends/*.sh libexec/*
# The bash half of the test suite, in full, against the pristine copy - the suite asserts
# the tree as shipped, not the tree as packaged. It needs only bash, jq and coreutils by
# design - every impure command goes through an environment seam - and the node/PySide6
# halves skip loudly without failing when those tools are absent (they test the widget,
# which a build root cannot display anyway). A build root that cannot pass the suite must
# not ship.
(cd ../%{name}-pristine && tests/run_tests.sh)
# Both validators run without network access: every URL in the metainfo is a github.com link that
# a build host must not be asked to fetch. Structure is what they check. validate-relax is the run
# Fedora's AppData guidelines require.
appstream-util validate-relax --nonet \
    %{buildroot}%{_metainfodir}/io.github.erez_c137.kempt.metainfo.xml
appstreamcli validate --no-net --explain \
    %{buildroot}%{_metainfodir}/io.github.erez_c137.kempt.metainfo.xml

# The one thing the suite above CANNOT check, because it runs against the pristine copy: the
# packaging rewrite in %%prep. If that sed ever misses a file, pkexec has no action for the path
# the CLI asks it to run, every privileged call falls back to an authentication dialog, and
# background checks time out - a failure nobody sees until the package is on someone's machine.
# So: assert the four paths, in the buildroot, as installed.
for f in %{buildroot}%{_libexecdir}/kempt-refresh %{buildroot}%{_libexecdir}/kempt-apply; do
    test -x "$f" || { echo "packaging check: missing helper $f" >&2; exit 1; }
done
grep -q '<annotate key="org.freedesktop.policykit.exec.path">%{_libexecdir}/kempt-refresh</annotate>' \
    %{buildroot}%{_datadir}/polkit-1/actions/io.github.erez_c137.kempt.policy
grep -q '<annotate key="org.freedesktop.policykit.exec.path">%{_libexecdir}/kempt-apply</annotate>' \
    %{buildroot}%{_datadir}/polkit-1/actions/io.github.erez_c137.kempt.policy
grep -q 'KEMPT_REFRESH_HELPER_PATH:-%{_libexecdir}/kempt-refresh' \
    %{buildroot}%{_datadir}/%{name}/lib/common.sh
grep -q 'KEMPT_APPLY_HELPER_PATH:-%{_libexecdir}/kempt-apply' \
    %{buildroot}%{_datadir}/%{name}/lib/common.sh
! grep -rq '/usr/local/libexec' %{buildroot}%{_datadir}/%{name}/lib/common.sh \
    %{buildroot}%{_datadir}/polkit-1/actions/io.github.erez_c137.kempt.policy

%files
%license LICENSE
# The user-facing documents chosen at the end of %%install, with docs/ kept as a directory so
# README's links to it resolve here the way they resolve on the forge.
%doc README.md CHANGELOG.md SECURITY.md docs
%{_bindir}/kempt
%{_datadir}/%{name}/
%{_libexecdir}/kempt-refresh
%{_libexecdir}/kempt-apply
%{_datadir}/polkit-1/actions/io.github.erez_c137.kempt.policy
%{_mandir}/man1/kempt.1*

%files plasmoid
%license LICENSE
%{_datadir}/plasma/plasmoids/io.github.erez_c137.kempt/
%{_datadir}/icons/hicolor/*/apps/kempt.svg
%{_metainfodir}/io.github.erez_c137.kempt.metainfo.xml

%changelog
* Sat Sep 19 2026 Erez <erez.c137@protonmail.com> - 0.1.4-1
- Flatpak runtimes are counted and listed, so the badge matches what an
  update really changes. They cannot be held: apps share them.
- kempt unstage discards a staged update, from the command line or from the
  panel, and refuses while a Fedora release upgrade is stored.
- A restart reports the transaction Kempt staged, named from dnf5's own
  history, or says plainly that a different one ran.
- The popup says how old the package metadata behind its counts is, and
  kempt check --refresh fetches now.
- An authorization that was refused without a dialog no longer reads as a
  cancelled prompt, and a terminal that never opened is reported.

* Tue Sep 15 2026 Erez <erez.c137@protonmail.com> - 0.1.3-1
- The root helper refuses to stage over, arm or discard a stored Fedora
  release upgrade itself, instead of relying on the command line's check.
- enable-passwordless pipes the checked rule to root and installs it only at
  /etc/polkit-1/rules.d/49-kempt.rules.
- The root helpers run bash in privileged mode.
- The metainfo passes appstream-util validate-relax, which the build now
  runs, and names no stock icon.
- Only user documentation is installed, the versioned bash requirement is
  gone, and installed files keep their timestamps.

* Tue Sep 15 2026 Erez <erez.c137@protonmail.com> - 0.1.2-1
- The panel widget moves to its own subpackage, kempt-plasmoid, so the command
  line no longer requires plasma-workspace. On a machine running Plasma the
  widget is installed alongside it as before, unless dnf's weak dependencies are
  turned off - then install kempt-plasmoid once.
- Declares dnf5-command(needs-restarting), without which the restart reminder
  was permanently silent, and recommends libnotify and konsole.
- A hold added after an offline update was staged is reported rather than
  silently ignored, in the command line and in the popup.
- Three states in which a staged update had quietly stopped being real are now
  detected and announced.
- Ships the documentation tree, so the README's links resolve once installed.
- A machine a long way behind now updates: the pending list was handed to a
  program as one command-line argument, so a check died at 925 pending updates
  and a run at about 1,200 packages, both reported by the panel as a missing
  installation.
- Refuses to stage updates over a stored Fedora release upgrade, which dnf5
  would otherwise cancel, and says so in the popup and in kempt doctor.
- Refuses to update an image-based Fedora (Silverblue, Kinoite, Bazzite, bootc),
  where rpm-ostree or bootc rather than dnf is what updates the system, instead
  of resolving a transaction that cannot install. Checking, holds, the event log
  and kempt doctor still work there.
- A staged update can no longer arm the machine with no record of itself.
- A lost package lock reads as a busy package system rather than as dnf's own
  line about a lock file.
- The panel says "installed but will not run" for an engine that will not start,
  instead of telling the user to install a package they already have.

* Fri Sep 04 2026 Erez <erez.c137@protonmail.com> - 0.1.1-1
- The widget guides a store-first install instead of quoting the shell; doctor
  catches a user-scope widget copy shadowing the packaged one.

* Wed Sep 02 2026 Erez <erez.c137@protonmail.com> - 0.1.0-1
- First release.
