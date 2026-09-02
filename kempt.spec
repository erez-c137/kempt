Name:           kempt
Version:        0.1.0
Release:        1%{?dist}
Summary:        One-click system updates from the Plasma panel

License:        MIT
URL:            https://github.com/erez-c137/kempt
Source0:        %{url}/archive/v%{version}/%{name}-%{version}.tar.gz

BuildArch:      noarch

# Everything here is bash, QML and SVG. No compiler, no build step. The only build-time tool is
# the metainfo validator; there is no .desktop file, so no desktop-file-utils.
#
# appstream, not libappstream-glib. Fedora's older guidance reaches for appstream-util, but its
# validator rejects any stock icon whose name is not in a hardcoded list of freedesktop standard
# names - verified here, it fails this package with "stock icon is not valid [kempt]" for an icon
# the package itself installs into hicolor at six sizes. appstreamcli is the reference
# implementation and the one the metainfo was authored against; it accepts the file with no
# findings at all.
BuildRequires:  appstream

Requires:       bash >= 4.4
Requires:       jq
Requires:       dnf5
Requires:       polkit
Requires:       util-linux-core
Requires:       hicolor-icon-theme
Requires:       plasma-workspace
# Optional backend: the CLI runs fine without it (include_flatpak simply reports disabled).
Recommends:     flatpak
# The `terminal` run surface launches this; the CLI exits 4 with a clear message without it.
Suggests:       konsole

%description
Kempt is a Plasma 6 panel widget and a bash command-line tool. It shows
which dnf5 and Flatpak updates are pending with the version each package
moves from and to, counts only the updates you have not held, and applies
them with one click. The badge and the update run through the same command
path, so the count and the transaction cannot disagree.

%prep
%autosetup

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
sed -i '1{/^#!/d}' %{buildroot}%{_datadir}/%{name}/lib/common.sh \
                   %{buildroot}%{_datadir}/%{name}/backends/dnf.sh \
                   %{buildroot}%{_datadir}/%{name}/backends/flatpak.sh

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

%check
bash -n bin/kempt lib/common.sh backends/*.sh libexec/*
# --no-net, deliberately: every URL in the metainfo is a github.com link that a build host must
# not be asked to fetch, and on a private repo they 404 anyway. Structure is what this checks.
appstreamcli validate --no-net --explain \
    %{buildroot}%{_metainfodir}/io.github.erez_c137.kempt.metainfo.xml

%files
%license LICENSE
%doc README.md CHANGELOG.md docs/usage.md docs/configuration.md docs/security.md
%{_bindir}/kempt
%{_datadir}/%{name}/
%attr(0755,root,root) %{_libexecdir}/kempt-refresh
%attr(0755,root,root) %{_libexecdir}/kempt-apply
%{_datadir}/polkit-1/actions/io.github.erez_c137.kempt.policy
%{_datadir}/plasma/plasmoids/io.github.erez_c137.kempt/
%{_datadir}/icons/hicolor/*/apps/kempt.svg
%{_metainfodir}/io.github.erez_c137.kempt.metainfo.xml
%{_mandir}/man1/kempt.1*

%changelog
* Wed Sep 02 2026 Erez <erez.c137@protonmail.com> - 0.1.0-1
- First release.
