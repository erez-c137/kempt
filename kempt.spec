Name:           kempt
Version:        0.1.1
Release:        1%{?dist}
Summary:        One-click system updates for Fedora, with holds and offline staging

# MIT AND CC0-1.0: every original file is MIT; the one CC0-1.0 file the binary RPM ships is
# the AppStream metainfo, whose metadata_license is CC0-1.0 by freedesktop convention.
License:        MIT AND CC0-1.0
URL:            https://github.com/erez-c137/kempt
Source0:        %{url}/archive/v%{version}/%{name}-%{version}.tar.gz

BuildArch:      noarch

# Everything here is bash, QML and SVG. No compiler, no build step. Build-time tools are the
# metainfo validator plus what the check-stage test suite needs (bash, jq, coreutils, flock).
#
# No .desktop file, deliberately: a Plasma applet is not a menu-launched application.
# plasmashell discovers the widget through plasmoid/metadata.json and it is added from Add
# Widgets; there is nothing for a .desktop file to launch, which is also why the metainfo is
# type="addon" with no <launchable>. So: no desktop-file-utils, no desktop-file-install.
#
# appstream, not libappstream-glib. Fedora's older guidance reaches for appstream-util, but its
# validator rejects any stock icon whose name is not in a hardcoded list of freedesktop standard
# names - verified here, it fails this package with "stock icon is not valid [kempt]" for an icon
# the package itself installs into hicolor at six sizes. appstreamcli is the reference
# implementation and the one the metainfo was authored against; it accepts the file with no
# findings at all.
BuildRequires:  appstream
# For the check stage only: the test suite's bash half needs these (the CLI needs them at
# runtime too, so they are also Requires below - the build root does not inherit those).
BuildRequires:  jq
BuildRequires:  util-linux-core

Requires:       bash >= 4.4
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
# Both of these are weak on purpose and neither used to be declared at all.
# notify-send is how every detached surface reports what it did; without it those runs finish
# silently. konsole is what the DEFAULT surface launches, so with it only Suggested (which dnf
# does not install) `kempt doctor` reported a FAIL on a fresh, correct install - the first command
# the docs tell a new user to run.
Recommends:     libnotify
Recommends:     konsole

%description
Kempt shows which dnf5 and Flatpak updates are pending with the version each
package moves from and to, counts only the updates you have not held, and
applies them in a terminal, in the background, or staged for the next restart.
The panel widget is packaged separately as kempt-plasmoid, so this package
brings in nothing from the desktop.

%package plasmoid
Summary:        Plasma 6 panel widget for Kempt
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
# The CLI resolves its own tree with readlink -f, so /usr/bin/kempt is a SYMLINK into the tree.
# A real file there would make ROOT=/usr and send it looking for /usr/lib/common.sh.
install -d %{buildroot}%{_datadir}/%{name}
cp -a bin lib backends %{buildroot}%{_datadir}/%{name}/
install -d %{buildroot}%{_bindir}
ln -s %{_datadir}/%{name}/bin/kempt %{buildroot}%{_bindir}/kempt

# Two files the CLI reads out of its own tree at runtime, and the tree is $ROOT here rather than a
# checkout. Verified by installing the package without them: `kempt --version` printed
# "kempt unknown", and `kempt doctor` reported the install as an incomplete checkout.
install -m 0644 VERSION %{buildroot}%{_datadir}/%{name}/VERSION
# `kempt enable-passwordless` renders this template into /etc/polkit-1/rules.d. Without it that
# command has nothing to render and fails on the day someone runs it, not before.
install -D -m 0644 polkit/49-kempt.rules.in \
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
install -D -m 0755 libexec/kempt-refresh %{buildroot}%{_libexecdir}/kempt-refresh
install -D -m 0755 libexec/kempt-apply   %{buildroot}%{_libexecdir}/kempt-apply

# polkit action only. The passwordless RULE is generated per user by `kempt enable-passwordless`
# into /etc/polkit-1/rules.d, names a specific username, and is the admin's file. Not packaged.
install -D -m 0644 polkit/io.github.erez_c137.kempt.policy \
    %{buildroot}%{_datadir}/polkit-1/actions/io.github.erez_c137.kempt.policy

# The plasmoid, in the KPackage layout: metadata.json at the root next to contents/.
install -d %{buildroot}%{_datadir}/plasma/plasmoids/io.github.erez_c137.kempt
cp -a plasmoid/metadata.json plasmoid/contents \
    %{buildroot}%{_datadir}/plasma/plasmoids/io.github.erez_c137.kempt/

# The icon ladder, same six rungs install.sh puts into the user's hicolor theme. No icon-cache
# scriptlet: hicolor-icon-theme's own file triggers fire for any package touching that tree.
for pair in scalable:kempt.svg 64x64:kempt-48.svg 48x48:kempt-48.svg \
            32x32:kempt-32.svg 22x22:kempt-22.svg 16x16:kempt-16.svg; do
    install -D -m 0644 "plasmoid/contents/icons/${pair#*:}" \
        "%{buildroot}%{_datadir}/icons/hicolor/${pair%%:*}/apps/kempt.svg"
done

install -D -m 0644 docs/man/kempt.1 %{buildroot}%{_mandir}/man1/kempt.1
install -D -m 0644 io.github.erez_c137.kempt.metainfo.xml \
    %{buildroot}%{_metainfodir}/io.github.erez_c137.kempt.metainfo.xml

# %%doc ships docs/ whole, so README's relative links resolve on an installed system instead of
# being a table of dead ends: 15 of its 17 now do, against 1 before. The two that do not are
# LICENSE and docs/man/kempt.1, and both are files this package installs PROPERLY elsewhere -
# %%license and %%{_mandir} - so shipping a second copy under %%doc to satisfy a link would be the
# worse trade.
# The development half is pruned here rather than in %%prep because the man page above is
# installed OUT of docs/, and %%doc reads the tree as it stands at the end of this section: plans
# and most research notes are working papers.
rm -rf docs/man

%check
bash -n bin/kempt lib/common.sh backends/*.sh libexec/*
# The bash half of the test suite, in full, against the pristine copy - the suite asserts
# the tree as shipped, not the tree as packaged. It needs only bash, jq and coreutils by
# design - every impure command goes through an environment seam - and the node/PySide6
# halves skip loudly without failing when those tools are absent (they test the widget,
# which a build root cannot display anyway). A build root that cannot pass the suite must
# not ship.
(cd ../%{name}-pristine && tests/run_tests.sh)
# --no-net, deliberately: every URL in the metainfo is a github.com link that a build host must
# not be asked to fetch, and on a private repo they 404 anyway. Structure is what this checks.
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
# The whole set README links to, with docs/ kept as a directory so those links resolve here the
# way they resolve on the forge.
%doc README.md CHANGELOG.md CONTRIBUTING.md AGENTS.md SECURITY.md CODE_OF_CONDUCT.md docs
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
* Fri Sep 04 2026 Erez <erez.c137@protonmail.com> - 0.1.1-1
- The widget guides a store-first install instead of quoting the shell; doctor
  catches a user-scope widget copy shadowing the packaged one.

* Wed Sep 02 2026 Erez <erez.c137@protonmail.com> - 0.1.0-1
- First release.
