# Packaging and listing for the public flip

**Date:** 2026-08-27
**Status:** research only. Nothing here is installed, packaged or published by this document.
**For:** the roadmap's v1.x items "Flip the GitHub repo public", "KDE Store listing" and
"RPM/COPR packaging" (`docs/ROADMAP.md`).
**Method:** every claim marked *verified* was executed or read on this box (Fedora 44, Plasma
6.7.4, kf6-kpackage 6.29.0, appstreamcli 1.1.3, dnf5 5.4.3.0, polkit 127) or read from an
upstream doc whose URL is cited. Anything else is marked **UNVERIFIED** in place.

---

## 0. What ships, and where each artifact goes

`install.sh` today is a *developer* install: the CLI is a **symlink into the checkout**, so the
git tree is load-bearing at runtime, and only the two root helpers plus the polkit action are
copied out. Packaging retires that. The table is the whole delta.

| Artifact | Dev install (`install.sh`) | Packaged install (RPM) |
| --- | --- | --- |
| CLI | symlink `~/.local/bin/kempt` -> checkout `bin/kempt` | `/usr/bin/kempt` -> `/usr/share/kempt/bin/kempt` (see §3.1) |
| `lib/`, `backends/` | read out of the checkout | `/usr/share/kempt/{lib,backends}` |
| Root helpers | `/usr/local/libexec/kempt-{refresh,apply}`, root:root 0755 | `/usr/libexec/kempt-{refresh,apply}`, root:root 0755 |
| polkit action | `/usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy` | same path, but `exec.path` rewritten (§3.2) |
| polkit rule (passwordless) | `/etc/polkit-1/rules.d/49-kempt.rules`, written by `kempt enable-passwordless` | **not shipped**; stays admin-generated in `/etc` (§3.2) |
| Plasmoid | copied by `kpackagetool6` into `~/.local/share/plasma/plasmoids/<id>/` | `/usr/share/plasma/plasmoids/io.github.erez_c137.kempt/` |
| Icons | six rungs into `~/.local/share/icons/hicolor/*/apps/kempt.svg` | `/usr/share/icons/hicolor/*/apps/kempt.svg` |
| Man page | symlink `~/.local/share/man/man1/kempt.1` | `/usr/share/man/man1/kempt.1.gz` |
| AppStream metainfo | **does not exist yet** | `/usr/share/metainfo/io.github.erez_c137.kempt.metainfo.xml` |

`install.sh --destdir <dir>` already stages every one of the rows above except the metainfo, so
it is a usable smoke test for the file list, but it stages into the **user** hierarchy
(`$DESTDIR$HOME/.local/...`), not into an FHS prefix. A spec cannot reuse it as-is.

---

## 1. AppStream metainfo for a Plasma applet

### 1.1 Component type: `addon`, verified locally

*Verified:* `type="addon"` with `<extends>org.kde.plasmashell</extends>` passes
`appstreamcli validate` cleanly. `type="desktop-application"` does not: it adds
`I: desktop-app-launchable-omitted`, because a desktop-application is expected to carry a
`<launchable type="desktop-id">`, and Kempt ships no `.desktop` file at all. An applet is an
add-on to plasmashell, and the validator agrees.

The spec agrees too. There is no `plasmoid` component type; the full list is
`desktop-application, console-application, web-application, service, addon, font, icon-theme,
codec, input-method, firmware, driver, localization, repository, operating-system, runtime`. For
an `addon`, the spec's own required set is **`<id>`, `<name>`, `<summary>`,
`<metadata_license>`, `<extends>`**, and its worked example
([metainfo-addon.xml](https://github.com/ximion/appstream/blob/main/docs/xml/metainfo-addon.xml))
is exactly this shape:

```xml
<component type="addon">
  <id>org.gnome.gedit_code_assistance</id>
  <extends>org.gnome.gedit</extends>
  ...
</component>
```

*Verified, and worth knowing:* **almost nobody ships one for a plasmoid.** On this Fedora 44 box a
grep of `/usr/share/metainfo/*.xml` for `<extends>org.kde.plasmashell` returns exactly one hit,
`org.kde.plasmashell.metainfo.xml` itself. Upstream is the same: KDE's own `kdeplasma-addons`
applets carry no metainfo, and the live Fedora rawhide spec for a real Plasma 6 applet,
[`applet-window-buttons`](https://src.fedoraproject.org/rpms/applet-window-buttons/blob/rawhide/f/applet-window-buttons.spec),
ships none either. Plasma discovers applets through KPackage's `metadata.json`, not through
AppStream. So the metainfo is **optional for the widget to work** and **what makes it look like a
real product in a software centre**. Write it because the listing needs it, not because Plasma
does. (A third-party plasmoid that does do it properly: Syncthing Tray ships
`io.github.martchus.syncthingplasmoid.metainfo.xml`.)

### 1.2 `kpackagetool6` generates a starting point (verified)

```
$ kpackagetool6 -t Plasma/Applet --appstream-metainfo plasmoid/
<?xml version="1.0" encoding="UTF-8"?>
<component>
    <id>io.github.erez_c137.kempt</id>
    <name>Kempt</name>
    <summary>One-click system updates with a truthful badge</summary>
    <url type="homepage">https://github.com/erez-c137/kempt</url>
    <developer id="kde.org">
        <name>Erez Avital</name>
    </developer>
    <icon type="stock">kempt</icon>
    <project_license>MIT</project_license>
    <metadata_license>CC0-1.0</metadata_license>
</component>
```

It reads `plasmoid/metadata.json` and gets id, name, summary, website, author, icon and license
right. It gets three things wrong or missing for a third-party project: it hardcodes
`<developer id="kde.org">` (Kempt is not a KDE project), it emits **no `type` attribute and no
`<extends>`**, and it has no releases, screenshots, categories, keywords, bugtracker or
content_rating. Treat it as a generator for the identity block and hand-write the rest.

### 1.3 The draft

Validated on this box with `appstreamcli validate --explain` (AppStream 1.1.3). The **only**
findings were four `url-not-reachable` / `screenshot-image-not-found` warnings, all of which are
the private repo 404ing. Every structural element below was accepted.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!-- SPDX-License-Identifier: CC0-1.0 -->
<component type="addon">
  <id>io.github.erez_c137.kempt</id>
  <extends>org.kde.plasmashell</extends>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>MIT</project_license>
  <name>Kempt</name>
  <summary>One-click system updates with a truthful badge</summary>
  <description>
    <p>
      Kempt is a Plasma 6 panel widget and a bash command-line tool that shows exactly which
      system updates are pending, counts only the ones you have not held, and applies them with
      one click from the panel.
    </p>
    <p>The badge and the update come from the same command path, so they cannot disagree.</p>
    <ul>
      <li>dnf5 and Flatpak updates, with the version each package moves from and to.</li>
      <li>Holds that skip a package but keep reporting it.</li>
      <li>Offline staging for updates that could disturb the running session.</li>
    </ul>
  </description>
  <developer id="io.github.erez_c137">
    <name>Erez Avital</name>
  </developer>
  <url type="homepage">https://github.com/erez-c137/kempt</url>
  <url type="bugtracker">https://github.com/erez-c137/kempt/issues</url>
  <url type="help">https://github.com/erez-c137/kempt/blob/main/docs/usage.md</url>
  <url type="vcs-browser">https://github.com/erez-c137/kempt</url>
  <icon type="stock">kempt</icon>
  <categories>
    <category>System</category>
  </categories>
  <keywords>
    <keyword>updates</keyword>
    <keyword>dnf</keyword>
    <keyword>flatpak</keyword>
    <keyword>plasma</keyword>
  </keywords>
  <screenshots>
    <screenshot type="default">
      <caption>The panel badge and the pending-updates popup</caption>
      <image type="source" width="1280" height="800">https://raw.githubusercontent.com/erez-c137/kempt/main/docs/images/kempt-tray-popup.png</image>
    </screenshot>
  </screenshots>
  <content_rating type="oars-1.1"/>
  <provides>
    <binary>kempt</binary>
  </provides>
  <releases>
    <release version="1.0.0" date="2026-08-27" type="stable">
      <url type="details">https://github.com/erez-c137/kempt/releases/tag/v1.0.0</url>
      <description><p>First public release.</p></description>
    </release>
  </releases>
</component>
```

Rules the validator actually enforced, in the order they bite:

- The **first `<description><p>`** must be 80 characters or longer, or you get
  `description-first-para-too-short` (verified: a 46-character opener triggered it, the paragraph
  above does not).
- **Screenshot images must be reachable remote URLs.** The validator fetches them. The spec is
  explicit: the `<image/>` value "is a direct HTTP/HTTPS URL to a screenshot uploaded to a public
  location on the web", PNG ideally, and at least one `<screenshot/>` must carry
  `type="default"`. A local path is not an option, so the image has to be committed and served
  publicly before the file can validate clean.
- `<developer id="...">` with a nested `<name>` is the current form and validated without
  complaint. `<developer_name>` is explicitly "deprecated and should not be used for new
  metadata".
- `<content_rating type="oars-1.1"/>` empty is accepted and is what a tool with no objectionable
  content wants. Use **1.1**, not the `oars-1.0` the older spec prose mentions; Flathub's
  [MetaInfo guidelines](https://docs.flathub.org/docs/for-app-authors/metainfo-guidelines) say so
  directly and it is what real files use.
- `<releases>` accepts `type` of `stable` / `development` / `snapshot` and an optional `urgency`
  of `low` / `medium` / `high` / `critical`. There is an external form
  (`<releases type="external" url="..."/>`) but it does **not** save you the file: the spec says a
  local copy "**must** be available locally, installed as a file into
  `/usr/share/metainfo/releases/%{cid}.releases.xml`". For a project with a hand-written CHANGELOG
  the inline form is simpler and there is no reason to use the external one.

**Blocker, verified:** the file cannot validate clean while the repo is private. All four
warnings are `url-not-reachable`. Metainfo validation is therefore *downstream* of the public
flip, not something to finish first.

**Screenshots need re-taking.** The two images in `docs/images/` are 372x59 and 486x531 pixels,
which are aspect ratios of roughly 6.3:1 and 0.9:1. The spec "suggest[s] ... 16:9 aspect ratio"
and its worked example is 1600x900. The 372x59 file is a tray crop, not a screenshot. The
roadmap's "The screenshot" item should produce one 16:9 capture at something like 1600x900 that
serves all three consumers at once: the README, the metainfo, and the store listing. Captions
should stay under about 100 characters, per the spec.

**UNVERIFIED:** the AppStream spec sets **no hard minimum pixel size** (only the 16:9 suggestion),
and no minimum could be confirmed for store.kde.org either. The re-capture argument above is
about aspect ratio and usefulness, not about clearing a documented floor.

---

## 2. store.kde.org listing for the plasmoid

### 2.1 What `kpackagetool6` can and cannot do (verified)

`kpackagetool6 --help` on Plasma 6.7.4 offers `--install`, `--upgrade`, `--remove`, `--list`,
`--list-types`, `--show`, `--hash`, `--packageroot`, `--global`, `--type`,
`--appstream-metainfo[-output]`. **There is no create/pack verb**, and the
[kpackagetool6(1)](https://manpages.debian.org/experimental/kpackagetool6/kpackagetool6.1.en.html)
man page confirms the same option list. `plasmapkg2`'s old "make me a package" role does not exist
here (`plasmapkg` -> `plasmapkg2` -> `kpackagetool5` -> `kpackagetool6`, each superseding the
last): the archive is built with plain `tar`/`zip`, and `kpackagetool6 -i` consumes either a
directory or an archive of the same layout. `--global` is the system-wide variant and installs
into `/usr/share/plasma/plasmoids/`, which is the same path the RPM writes to in §3.

That layout is the one already in the repo, and it is the one the store expects: `metadata.json`
at the **root** of the archive, next to `contents/`.

```
kempt-1.0.0.plasmoid          (a zip, or a .tar.gz; both are "a package" to KPackage)
├── metadata.json
└── contents/
    ├── config/{main.xml,config.qml}
    ├── icons/*.svg
    └── ui/*.qml
```

A `.plasmoid` file is a zip with that layout; nothing about the extension is magic.

### 2.2 `metadata.json` (the repo's real file, and what is missing)

Plasma 6 reads KPackage's JSON form. The shipped file already has the Plasma-6-specific keys
right (`X-Plasma-API-Minimum-Version: "6.0"`, `KPackageStructure: "Plasma/Applet"`, and the
notification-area hints). Two gaps matter for a listing:

- **No `BugReportUrl`.** It is a real, documented `KPlugin` key and it appears in the official
  Plasma 6 example at <https://develop.kde.org/docs/plasma/widget/setup/> right next to
  `Website`. The metainfo above has a bugtracker URL; `metadata.json` does not. Add it.
- **`KPlugin.Version` is `"0.1.0"`, and it is the ONLY version string in the entire repository.**
  Verified: `bin/kempt` has no `--version` subcommand, there are no git tags (`git tag` is
  empty, 144 commits), and `CHANGELOG.md` is still `[Unreleased]`. Publishing needs four numbers
  to agree: the git tag, the RPM `Version:`, the metainfo `<release version=...>` and
  `KPlugin.Version`. Pick one source of truth before the first tag, not after.

### 2.3 The store side

**Category:** *Plasma 6 Applets*, category id **706**
(<https://store.kde.org/browse?cat=706>), under *Plasma 6 Extensions* (705). The full path is
Linux/Unix Desktops > Desktop Extensions > KDE Plasma Extensions > Plasma 6 Extensions >
Plasma 6 Applets. Confirmed by two KDE Store moderators on the store's own community board
([one](https://forum.opendesktop.org/t/please-move-my-product-to-plasma-6-applets-category/21319),
[two](https://forum.opendesktop.org/t/what-is-the-correct-way-to-publish-a-plasmoid-widget-category/21255)).
The neighbouring category *Plasma 6 Monitoring* (710) is a plausible alternative given what Kempt
does; 706 is the safer default.

**Upload:** <https://store.kde.org/product/add>. The store is a generic Pling/OCS content CMS,
not a packaging pipeline, and that shapes everything about the workflow:

- You attach a file. Conventionally a `.plasmoid`, which is exactly the zip described in §2.1.
- Screenshots are uploaded on the form.
- License is a dropdown on the form.
- **Version and changelog are free-text form fields you fill in by hand, per release.** There is
  no evidence the store reads `KPlugin.Version` from the uploaded `metadata.json`, so the version
  agreement problem in §2.2 is a manual discipline, not something tooling enforces.
- There is a homepage field **and** a separate source-code field. The advice given to a real
  uploader was to put the GitHub link in source-code and use homepage for a project page.
  **UNVERIFIED:** whether a distinct bug-tracker field exists separately from those two.

**There is no official KDE guide for this.** Verified: the sidebar of
<https://develop.kde.org/docs/plasma/widget/> lists Setup, Porting to KF6, Testing, QML, Plasma's
QML API, Widget Properties, Configuration, Translations, Examples and C++ API, and **no
Publishing or Sharing page**. The practical references are the community threads above, Zren's
widget tutorial (<https://zren.github.io/kde/docs/widget/>), and Apdatifier's own listing at
<https://store.kde.org/p/2135796/> as the closest prior art to model against.

---

## 3. RPM spec for Fedora

### 3.1 The one code-level surprise: how the CLI finds its lib dir

`bin/kempt` resolves its own tree at runtime:

```bash
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT="$(dirname "$(dirname "$SELF")")"
source "$ROOT/lib/common.sh"
```

`readlink -f` follows symlinks, which is exactly why the dev symlink install works. It also means
a naive FHS install **breaks**: a real file at `/usr/bin/kempt` gives `ROOT=/usr` and the CLI
would look for `/usr/lib/common.sh` and `/usr/backends/dnf.sh`.

The fix needs **no code change at all**: ship the tree under `/usr/share/kempt/` and make
`/usr/bin/kempt` a symlink to `/usr/share/kempt/bin/kempt`. `readlink -f` resolves it, `ROOT`
becomes `/usr/share/kempt`, and `lib/` and `backends/` are found. That is the layout the `%files`
list below uses.

### 3.2 polkit: two directories, and only one of them is packaged

*Verified from `man polkit` on this box*, the rules search order is
`/etc/polkit-1/rules.d`, `/run/polkit-1/rules.d`, `/usr/local/share/polkit-1/rules.d`,
`/usr/share/polkit-1/rules.d`, processed in lexical order by basename with earlier directories
winning ties. So:

- The **action** file (`*.policy`) goes to `/usr/share/polkit-1/actions/` in both installs. No
  change.
- The **passwordless rule** is generated per-user by `kempt enable-passwordless` and belongs in
  `/etc/polkit-1/rules.d/49-kempt.rules`, where `bin/kempt` already writes it. An RPM must
  **not** ship it: it names a specific username, and `/etc` is the admin's directory. Leave it
  out of `%files` entirely.

The spec must rewrite one string. `/usr/local/libexec` is hardcoded in three places:
`polkit/io.github.erez_c137.kempt.policy` (both `exec.path` annotations), `lib/common.sh`
(`KEMPT_REFRESH_HELPER_PATH`, `KEMPT_APPLY_HELPER_PATH`), and `install.sh` (`LIBEXEC_DIR`). A
packaged build moves the helpers to `%{_libexecdir}` = `/usr/libexec`, so the first two must be
patched in `%prep`. If they drift apart, `pkexec` refuses to run the helper (the annotation is
what pins it) and `kempt doctor` reports the mismatch, which is the intended safety net.

### 3.3 The spec draft

**UNVERIFIED:** no rpm build tooling is installed on this box (`rpmspec`, `rpmbuild` and
`rpmlint` are all absent), so this draft has **not** been parsed or linted. Treat it as a
starting point to run through `rpmlint` on a build host.

```spec
Name:           kempt
Version:        1.0.0
Release:        1%{?dist}
Summary:        One-click system updates from the Plasma panel

License:        MIT
URL:            https://github.com/erez-c137/kempt
Source0:        %{url}/archive/v%{version}/%{name}-%{version}.tar.gz

BuildArch:      noarch

# Everything here is bash, QML and SVG. No compiler, no build step.
BuildRequires:  libappstream-glib
BuildRequires:  desktop-file-utils

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
Kempt is a Plasma 6 panel widget and a bash command-line tool. It shows which dnf5 and Flatpak
updates are pending with the version each package moves from and to, counts only the updates you
have not held, and applies them with one click. The badge and the update run through the same
command path, so the count and the transaction cannot disagree.

%prep
%autosetup

# The polkit action pins the helper path, and the library must agree with it. The dev installer
# uses /usr/local/libexec; a packaged build uses %{_libexecdir}.
sed -i 's|/usr/local/libexec|%{_libexecdir}|g' \
    polkit/io.github.erez_c137.kempt.policy \
    lib/common.sh

%build
# Nothing to build.

%install
# The CLI resolves its own tree with readlink -f, so /usr/bin/kempt is a SYMLINK into the tree.
install -d %{buildroot}%{_datadir}/%{name}
cp -a bin lib backends %{buildroot}%{_datadir}/%{name}/
install -d %{buildroot}%{_bindir}
ln -s %{_datadir}/%{name}/bin/kempt %{buildroot}%{_bindir}/kempt

# Root helpers. Mode 0755, owned by root: the polkit action execs these and nothing else.
install -D -m 0755 libexec/kempt-refresh %{buildroot}%{_libexecdir}/kempt-refresh
install -D -m 0755 libexec/kempt-apply   %{buildroot}%{_libexecdir}/kempt-apply

# polkit action only. The passwordless RULE is generated per user into /etc and is not packaged.
install -D -m 0644 polkit/io.github.erez_c137.kempt.policy \
    %{buildroot}%{_datadir}/polkit-1/actions/io.github.erez_c137.kempt.policy

# The plasmoid, in the KPackage layout: metadata.json at the root next to contents/.
install -d %{buildroot}%{_datadir}/plasma/plasmoids/io.github.erez_c137.kempt
cp -a plasmoid/metadata.json plasmoid/contents \
    %{buildroot}%{_datadir}/plasma/plasmoids/io.github.erez_c137.kempt/

# The icon ladder, same six rungs install.sh puts into the user's hicolor theme.
for pair in scalable:kempt.svg 64x64:kempt-48.svg 48x48:kempt-48.svg \
            32x32:kempt-32.svg 22x22:kempt-22.svg 16x16:kempt-16.svg; do
    install -D -m 0644 "plasmoid/contents/icons/${pair#*:}" \
        "%{buildroot}%{_datadir}/icons/hicolor/${pair%%:*}/apps/kempt.svg"
done

install -D -m 0644 docs/man/kempt.1 %{buildroot}%{_mandir}/man1/kempt.1
# %{_datadir}/metainfo, spelled out: %{_metainfodir} is not defined by base rpm on every host
# (verified: `rpm --eval` returns the literal on this box, which has no rpm-build installed).
install -D -m 0644 io.github.erez_c137.kempt.metainfo.xml \
    %{buildroot}%{_datadir}/metainfo/io.github.erez_c137.kempt.metainfo.xml

%check
bash -n bin/kempt lib/common.sh backends/*.sh libexec/*
appstream-util validate-relax --nonet \
    %{buildroot}%{_datadir}/metainfo/io.github.erez_c137.kempt.metainfo.xml

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
%{_datadir}/metainfo/io.github.erez_c137.kempt.metainfo.xml
%{_mandir}/man1/kempt.1*

%changelog
* Thu Aug 27 2026 Erez Avital <erez.avital@gmail.com> - 1.0.0-1
- First release.
```

Notes on the choices above:

- **`BuildArch: noarch` is right.** Bash, QML, SVG and XML only, no compiled artifact.
- **Dependency names verified installed on this box:** `dnf5` 5.4.3.0, `jq` 1.8.1, `polkit` 127,
  `flatpak` 1.18.1, `plasma-workspace` 6.7.4, `hicolor-icon-theme` 0.18.
  `/usr/share/plasma/plasmoids` is owned by `libplasma`, `plasma-desktop` and `plasma-workspace`,
  so requiring `plasma-workspace` covers the parent directory. `/usr/share/icons/hicolor` is
  owned by `hicolor-icon-theme`.
- **`flatpak` as `Recommends`, not `Requires`.** The flatpak backend is gated by the
  `include_flatpak` config key and the CLI reports the backend disabled rather than failing.
  A weak dependency is installed by default on Fedora but can be excluded, which is the right
  shape for an optional backend.
- **Man page compression is automatic**; `%{_mandir}/man1/kempt.1*` matches whether rpmbuild
  gzips it or not.
- **No icon-cache scriptlet, verified.** Fedora's own rawhide
  [`hicolor-icon-theme.spec`](https://src.fedoraproject.org/rpms/hicolor-icon-theme/blob/rawhide/f/hicolor-icon-theme.spec)
  carries `%transfiletriggerin -- %{_datadir}/icons/hicolor` and the matching
  `%transfiletriggerpostun`, both running `gtk-update-icon-cache --force`. Those triggers fire for
  **any** package that touches that tree, so Kempt needs no `%post`/`%postun` of its own. Dropping
  files under `%{_datadir}/icons/hicolor/<size>/apps/` is sufficient, and every size in Kempt's
  ladder (16, 22, 32, 48, 64, scalable) is in the directory list that spec ships.
- **`License: MIT` is the required form.** Fedora's
  [SPDX Licenses Phase 1](https://fedoraproject.org/wiki/Changes/SPDX_Licenses_Phase_1) change is
  explicit: "All new packages will need to use SPDX expression syntax in the License field." And
  `%license LICENSE` is the right macro for the license text, `%doc` for everything else; both of
  the real Fedora specs cited in this document do exactly that.
- **`Recommends: flatpak` follows the stated policy.** Fedora's weak-dependency rule is that
  `Requires` is for "required for the software to function correctly", while a package that
  "functions correctly but in diminished capacity" takes `Recommends` if the functionality should
  be on by default and `Suggests` otherwise. The flatpak backend is on by default
  (`include_flatpak` defaults to true) and its absence degrades rather than breaks, so
  `Recommends` is the correct tier and `Suggests: konsole` the correct one for the terminal
  surface.
- **`install.sh`'s Discover-notifier opt-out has no place in the RPM.** It edits a file in the
  user's `~/.config/autostart` and asks a question at a terminal. A package must not do either.
  The recommendation moves into the README and `kempt doctor`.

### 3.4 COPR

*Verified locally:* `dnf5 copr` is built into dnf5 5.4.3.0 on Fedora 44 with subcommands
`list`, `enable`, `disable`, `remove`, `debug`. No separate plugin package is installed. Since
Fedora 39 `/usr/bin/dnf` **is** dnf5, so `dnf copr enable` and `dnf5 copr enable` are both current
and the README can use either. The consumer-side instruction is:

```bash
sudo dnf copr enable erez-c137/kempt
sudo dnf install kempt
```

Publisher side, from the
[COPR user documentation](https://docs.copr.fedorainfracloud.org/user_documentation.html):

- **Use the SCM source method, not SRPM uploads.** Point the package at the repo's clone URL with
  the `.spec` committed in-tree. The docs are blunt about how little it needs: "The only required
  argument is Clone URL and if the target repository places the .spec file together with package
  sources in the root directory and you want to build from master HEAD, it will simply work."
- **Enable auto-rebuild and add the webhook.** Create the SCM package with auto-rebuild checked,
  then take the URL from the project's Settings > Integrations (form
  `https://copr.fedorainfracloud.org/webhooks/<forge>/<id>/<uuid>/`) and add it to the GitHub
  repo. A push then triggers a build.
- One-time setup: `copr-cli create kempt --chroot fedora-rawhide-x86_64` (plus whichever stable
  Fedora chroots you support), then `copr build-package erez-c137/kempt --name kempt`.

This is the item that most wants the repo public first: an SCM-tracked COPR package cloning a
private GitHub repo is a credentials problem nobody needs.

---

## 4. Flathub is not applicable

One line, because it is a one-line answer: Kempt's entire job is to drive the **host** package
manager as root through polkit, and Flathub's
[requirements](https://docs.flathub.org/docs/for-app-authors/requirements) rule that out in as
many words: "Applications that rely on host components or complicated post installation setups for
core functionality will not be accepted."

The two technical routes out of the sandbox are closed for the same reason. Flathub's
[linter rules](https://docs.flathub.org/docs/for-app-authors/linter) say of
`--talk-name=org.freedesktop.*` that "This exception is never granted", and narrow
`--talk-name=org.freedesktop.Flatpak.*` to "Flatpak clients or development apps". There is no XDG
portal for "run the host package manager". RPM and COPR are Kempt's distribution channel; Flathub
is not one, and no amount of manifest tuning changes that.

---

## 5. The GitHub public flip

1. **CI.** `.github/workflows/ci.yml` is dormant on purpose (`workflow_dispatch` only, because
   Actions on a private repo costs money). Its own header says the flip is a one-block edit of
   the `on:` trigger to `push: branches: [main]` + `pull_request:` + `workflow_dispatch:`.
   GitHub's own billing docs confirm the premise: "GitHub Actions usage is free for standard
   GitHub-hosted runners in public repositories, and for self-hosted runners." The flip and the CI
   enable are therefore the same decision.
2. **The shellcheck job has never run.** Its comment says so explicitly: shellcheck is not
   installed on the dev box and the first dispatch will also be its first execution across
   `bin/kempt lib/common.sh backends/*.sh libexec/* install.sh`. Budget a triage pass. Dispatch
   it manually **before** the repo is public so the first public CI run is green.
3. **Tags and releases.** Verified: `git tag` is empty at 144 commits. The metainfo's
   `<url type="details">` and the KDE Store changelog both want a release page, so the first
   thing after the merge to `main` is an annotated `v1.0.0` tag and a GitHub release whose body
   is the CHANGELOG section. Attach the plasmoid archive from §2.1 as a release asset so the
   store upload and the metainfo point at the same artifact.
4. **Screenshots.** Needed three times over: the README placeholder, the metainfo
   `<screenshots>`, and the store listing. Take them once, at a size that satisfies all three
   (see §1.3), and commit them so the raw.githubusercontent URL resolves.
5. **Repo furniture already in place:** LICENSE, README, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY.
   Missing: repo topics, a description, and a `kempt --version`.
6. **`kempt --version` should exist before the first release.** Verified absent from `usage()`.
   Every bug report against a packaged tool starts with a version number, and `kempt doctor`
   currently reports jq's version but not its own.

---

## 6. The short list, in order

1. Take the screenshots (blocks the README, the metainfo and the store listing).
2. Decide the version source of truth and add `kempt --version`.
3. Dispatch the dormant CI once and triage shellcheck.
4. Flip the repo public. The metainfo cannot validate clean before this.
5. Commit the metainfo, validate with `appstreamcli validate --explain`, expect zero warnings.
6. Tag `v1.0.0`, cut the release, attach the plasmoid archive.
7. Upload to store.kde.org.
8. RPM spec, then COPR, last: it is the only item that needs a build host this box does not have.
