Name:           kempt
Version:        0.3.0
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
Summary:        System updates for Fedora, with holds and offline staging

# Every original file is MIT. The one CC0-1.0 file in the tree is the AppStream metainfo, whose
# metadata_license is CC0-1.0 by freedesktop convention - and since the widget moved to its own
# subpackage that file ships there, not here, which is why this tag is plain MIT and the combined
# one is on kempt-plasmoid. A package must not claim a license for content it does not contain.
License:        MIT
URL:            https://github.com/erez-c137/kempt
Source0:        %{url}/archive/v%{version}/%{name}-%{version}.tar.gz

BuildArch:      noarch

# Everything here is bash, QML and SVG. No compiler, no build step. Build-time tools are the two
# metainfo validators plus what the check-stage test suite needs (bash, jq, coreutils, flock,
# python3).
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
# The compile check of the Flatpak listing helper below, its tests in the suite, and the suite's
# prose check of the docs (tools/prose-check.py).
BuildRequires:  python3
BuildRequires:  gettext

# No Requires on bash: rpm generates /usr/bin/bash from the shebangs, and every supported Fedora
# ships bash 5.
Requires:       jq
Requires:       dnf5
Requires:       polkit
# The root helpers start dnf5 through systemd-run.
Requires:       /usr/bin/systemd-run
Requires:       util-linux-core
# The one rule for dnf's folders is a find, in the root helpers and in the CLI.
Requires:       findutils
# `dnf5 needs-restarting` is the WHOLE of the reboot answer, and it lives in dnf5-plugins, not in
# dnf5: `dnf5 -q repoquery --whatprovides "dnf5-command(needs-restarting)"` returns dnf5-plugins,
# and dnf5 itself only provides dnf5-command(offline). Without it reboot_needed is permanently
# false with a warning on stderr that no widget user will ever read, so a restart owed after a
# kernel update is simply never offered. The virtual provide, not the package name, so a future
# re-home of the subcommand does not break this.
Requires:       dnf5-command(needs-restarting)
# Optional backend: the CLI runs fine without it (include_flatpak simply reports disabled).
Recommends:     flatpak
# The Flatpak listing helper (libexec/kempt-flatpak-unused) reads the installation through
# libflatpak's GObject bindings; flatpak-libs carries the typelib, PyGObject is the other half.
# The flatpak command does not require flatpak-libs, so both are named here.
# python3 itself is always required: rpm reads the helper's shebang and adds /usr/bin/python3.
# The bindings come only with flatpak: without it there is nothing to list.
Requires:       (python3-gobject-base if flatpak)
Requires:       (flatpak-libs if flatpak)
# Weak on purpose. notify-send is how every detached run reports what it did; without it those
# runs finish silently.
Recommends:     libnotify
# Blocks a shutdown while rpm is changing packages, so a restart pressed during an update waits.
Recommends:     rpm-plugin-systemd-inhibit

# The widget package is described here, not named. rpmlint's dictionary does not know the second
# half of its name and reports it as a spelling error on this package and the source package.
%description
Kempt shows which dnf5 and Flatpak updates are pending with the version each
package moves from and to, counts only the updates you have not held, and
applies them in the panel widget, from a terminal, or staged for the next
restart.
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
a list of each one with the versions it moves between, and one button
that runs the update. It drives the kempt command, so the badge counts from
the same cache the update uses.

%prep
%autosetup

# The check stage runs the test suite, and the suite asserts the tree AS SHIPPED - the
# policy's helper paths above all - so keep an unmodified copy for it before the packaging
# rewrite below touches those files.
cp -a . ../%{name}-pristine

# The polkit action pins the helper path with an exec.path annotation, and the library must agree
# with it or pkexec refuses to run the helper. The tree says /usr/local/libexec; a packaged build
# uses the FHS libexec dir.
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
# "kempt unknown".
install -p -m 0644 VERSION %{buildroot}%{_datadir}/%{name}/VERSION
# lib/ and backends/ are SOURCED, never executed. rpmlint rejects a 0644 file carrying a shebang,
# and 0755 would advertise an entry point that does nothing when you run it. The shebang stays in
# the checkout, where shellcheck and editors read the dialect off it; the installed copy is a
# library and says so.
# Globbed, not listed by name: a THIRD backend added to backends/ would otherwise keep its
# shebang, install 0644 with it, and rpmlint would reject the package - after the contributor
# followed docs/architecture.md, which says the backend table is everything they need to touch.
sed -i '1{/^#!/d}' %{buildroot}%{_datadir}/%{name}/lib/common.sh \
                   %{buildroot}%{_datadir}/%{name}/backends/*.sh

# The Flatpak listing helper runs as the desktop user, never through pkexec, so it is not a root
# helper and does not go in %%{_libexecdir} beside them: it stays in Kempt's own tree, where the
# CLI finds it through $ROOT. Outside lib/ and backends/, whose shebangs the sed above strips,
# because this one is executed.
install -p -D -m 0755 libexec/kempt-flatpak-unused \
    %{buildroot}%{_datadir}/%{name}/libexec/kempt-flatpak-unused

# Root helpers. Mode 0755, owned by root: the polkit action execs these and nothing else.
install -p -D -m 0755 libexec/kempt-refresh %{buildroot}%{_libexecdir}/kempt-refresh
install -p -D -m 0755 libexec/kempt-apply   %{buildroot}%{_libexecdir}/kempt-apply

# polkit action and the fixed rule. The rule is the package's, so an upgrade or removal carries it.
install -p -D -m 0644 polkit/io.github.erez_c137.kempt.policy \
    %{buildroot}%{_datadir}/polkit-1/actions/io.github.erez_c137.kempt.policy
install -p -D -m 0644 polkit/49-kempt.rules \
    %{buildroot}%{_datadir}/polkit-1/rules.d/49-kempt.rules

# The plasmoid, in the KPackage layout: metadata.json at the root next to contents/.
install -d %{buildroot}%{_datadir}/plasma/plasmoids/io.github.erez_c137.kempt
cp -a plasmoid/metadata.json plasmoid/contents \
    %{buildroot}%{_datadir}/plasma/plasmoids/io.github.erez_c137.kempt/
sh Messages.sh install %{buildroot}%{_datadir}/plasma/plasmoids/io.github.erez_c137.kempt

# The icon ladder, six rungs in the hicolor theme. No icon-cache
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
# - docs/usage.md, widget.md, configuration.md, install.md and security.md: the user guides.
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
# docs/ stays a directory so README's links keep their paths. 11 of its 18 relative link targets
# resolve on an installed system. The other 7 are the files left out above plus LICENSE, which
# %%license installs; all of them resolve on the forge.
# Pruned here and not in %%prep, because the man page above is installed out of docs/ and %%doc
# reads the tree as it stands at the end of this section.
rm -rf docs/man docs/RELEASING.md docs/ROADMAP.md docs/images/kempt-tray-icon.png

%check
bash -n bin/kempt lib/common.sh backends/*.sh libexec/kempt-refresh libexec/kempt-apply
# compile() rather than py_compile, which would leave a __pycache__ in the tree.
python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' libexec/kempt-flatpak-unused
# The bash half of the test suite, in full, against the pristine copy - the suite asserts
# the tree as shipped, not the tree as packaged. It needs bash, jq, coreutils and python3, the
# last for the docs' prose check. Every impure command goes through an environment seam. The
# node/PySide6 halves skip loudly without failing when those tools are absent (they test the widget,
# which a build root cannot display anyway). A build root that cannot pass the suite must
# not ship.
(cd ../%{name}-pristine && KEMPT_TEST_JOBS=1 tests/run_tests.sh)
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
for f in %{buildroot}%{_libexecdir}/kempt-refresh %{buildroot}%{_libexecdir}/kempt-apply \
         %{buildroot}%{_datadir}/%{name}/libexec/kempt-flatpak-unused; do
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

%triggerun -- kempt < 0.3.0
# Up to 0.2.0, `kempt enable-passwordless` wrote this file. The packaged rule replaces it, and a rule
# left here would keep granting whoever it named. It goes once, on the upgrade from such a version,
# and only if it is word for word one of the two forms that command wrote, whatever user it named.
# Anything else in this path is an admin's own override of the packaged rule, and stays.
f=/etc/polkit-1/rules.d/49-kempt.rules
[ -f "$f" ] && [ ! -L "$f" ] || exit 0
case "$(sed -E -e 's|^(// Kempt passwordless updates for )[a-z_][a-z0-9._-]* - |\1@USER@ - |' \
    -e 's|(subject\.user == ")[a-z_][a-z0-9._-]*(")|\1@USER@\2|' "$f" | sha256sum)" in
  3c98df529de172d8086c38974eb7fa2b59e57f0ead00746c41c5f319cda1353d*|7bc8a303352743f7241bb52a715f38fd4d7b37e635241fc434f2271c9694ae7f*) rm -f "$f" ;;
esac
exit 0

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
%{_datadir}/polkit-1/rules.d/49-kempt.rules
%{_mandir}/man1/kempt.1*

%files plasmoid
%license LICENSE
%{_datadir}/plasma/plasmoids/io.github.erez_c137.kempt/
%{_datadir}/icons/hicolor/*/apps/kempt.svg
%{_metainfodir}/io.github.erez_c137.kempt.metainfo.xml

%changelog
* Sun Nov 08 2026 Erez <erez.c137@protonmail.com> - 0.3.0-1
- A smaller Kempt. Updating in a terminal window or in the background,
  install.sh, Put It Back, security notifications, automatic reclaim and
  four settings are gone, and the widget has fewer messages.
- A wheel user at the computer updates with no password, from one fixed
  polkit rule. Nobody can update over SSH. kempt enable-passwordless is gone,
  and the upgrade removes the rule it wrote.
- The root helpers went from 760 lines to 170. dnf5 runs as a system
  service, and Kempt reads restarts from dnf5 and rpm with no record of its
  own.
- The widget says ready instead of staged, and System and Apps instead of
  dnf and flatpak. kempt log prints plain sentences. A failed download names
  the package.

* Mon Nov 02 2026 Erez <erez.c137@protonmail.com> - 0.2.0-1
- Kempt says when a service stops starting after an update, in a notification
  and in the widget. kempt startup and the widget's Startup Report list what
  starts on its own. Kempt only reads.
- Put It Back restores a staged update whose restart step another program
  removed, and staging warns when Discover's update check could cancel it.
- kempt status --list shows every update. kempt log says whether each
  notification reached you.
- An update no longer hangs when a package's setup step restarts the system's
  service manager. Screen readers hear the whole widget.
- kempt doctor checks the folders above dnf's folders.

* Mon Oct 19 2026 Erez <erez.c137@protonmail.com> - 0.1.9-1
- The widget no longer misses a package change made by another program
  shortly after a check, an update or a stage. A dnf command that cancelled
  a staged update left the widget saying the updates were staged.
- kempt doctor warns when getfacl is missing.

* Mon Oct 19 2026 Erez <erez.c137@protonmail.com> - 0.1.8-1
- Security: systemd starts each root dnf run in a clean service with its own
  umask, so root's dnf files can no longer be left writable by other users.
  The helpers never discard another updater's prepared restart. kempt doctor
  checks dnf's cache, state and staged packages for files left open, and
  updates refuse to run while other users can change dnf's state.
- Error messages drop URL credentials, tokens and your home path.
- kempt and install.sh refuse to run as root (exit 8).
- New kempt status, per-command --help, and a plain-words kempt log.
- Updates run in the widget by default. Installs that used the terminal keep
  it, and the widget offers the switch once.
- Kernel, systemd and desktop updates ask first when run outside a terminal.
- The widget can check its own installation and turn off Discover's notifier.
- kempt update exits 7 when another program holds the package lock.
- New kempt check --strict and kempt history --json for scripts.
- Ships the widget guide, docs/widget.md.
