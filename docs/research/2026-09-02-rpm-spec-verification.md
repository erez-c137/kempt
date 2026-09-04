# kempt.spec, verified end to end in a container

**Date:** 2026-09-02
**Status:** executed. Every command and output below was run, not drafted.
**Supersedes:** the unverified 2026-08-27 spec draft from the maintainer's packaging notes,
which had never been parsed by anything. `kempt.spec` at the repo root is now the real file, and
this note is what it was checked against.

**Where:** a throwaway `podman` container built from `registry.fedoraproject.org/fedora:44` with
`rpm-build`, `rpmlint`, `rpmdevtools` and `appstream` added. No rpm tooling was installed on the
host, and nothing was installed onto the host at any point. The source was
`git archive --format=tar.gz --prefix=kempt-0.1.0/ -o kempt-0.1.0.tar.gz HEAD` taken from the
worktree, copied into the container.

Toolchain: rpm 6.0.2, rpmlint 2.8.0, appstreamcli from Fedora 44's `appstream`, dnf5 5.4.3.0.

---

## 1. What the draft got wrong

Five things, all found by running it.

1. **`Version: 1.0.0`.** The tree's `VERSION` says `0.1.0`, and the version is now enforced by
   `tests/test_version.sh`. Corrected.

2. **`%check` used `appstream-util validate-relax --nonet`, and it fails this package.**
   libappstream-glib's validator checks stock icon names against a hardcoded list of freedesktop
   standard names, so it rejects an icon the package itself installs at six sizes:

   ```
   /.../io.github.erez_c137.kempt.metainfo.xml: FAILED:
   • tag-invalid           : stock icon is not valid [kempt]
   ```

   `appstreamcli` - the reference implementation, and the one the metainfo was written against -
   accepts the same file with no findings at all. `%check` now uses it, and `BuildRequires` is
   `appstream` rather than `libappstream-glib`. The legacy tool still says the same thing about
   the installed file; it is the tool that is wrong, not the metadata.

3. **`VERSION` was not packaged, and `kempt --version` printed `kempt unknown`.** The CLI reads
   `$ROOT/VERSION`, and in a packaged install `$ROOT` is `/usr/share/kempt`, not a checkout. The
   draft's `%install` copied only `bin lib backends`. This is the bug the smoke test existed to
   find.

4. **`polkit/49-kempt.rules.in` was not packaged either.** `kempt enable-passwordless` renders
   that template into `/etc/polkit-1/rules.d/49-kempt.rules`. Without it the command has nothing
   to render, and it fails on the day someone runs it rather than at install time. `kempt doctor`
   named it first: `FAIL checkout incomplete: missing polkit/49-kempt.rules.in`.

5. **`%{_metainfodir}` is fine to use.** The draft spelled out `%{_datadir}/metainfo` because
   `rpm --eval` returned the literal on a box with no rpm-build. It is defined as soon as
   rpm-build is present, which is the only place a spec is ever evaluated:
   `rpm --eval '%{_metainfodir}'` -> `/usr/share/metainfo`.

Also removed: `BuildRequires: desktop-file-utils`. Kempt ships no `.desktop` file.

## 2. rpmlint

`rpmlint kempt.spec` on the first pass:

```
kempt.spec:13: W: macro-in-comment %check
kempt.spec:39: W: macro-in-comment %{_libexecdir}
```

Real - rpm expands macros inside spec comments. Both comments were reworded to name the thing
in prose instead. Fixed.

`rpmlint` on the first built RPM:

```
kempt.noarch: E: non-executable-script /usr/share/kempt/backends/dnf.sh 644 /usr/bin/env bash
kempt.noarch: E: non-executable-script /usr/share/kempt/backends/flatpak.sh 644 /usr/bin/env bash
kempt.noarch: E: non-executable-script /usr/share/kempt/lib/common.sh 644 /usr/bin/env bash
kempt.noarch: E: description-line-too-long ... (x3)
```

Both real, both fixed:

- `description-line-too-long`: the `%description` was rewrapped to 80 columns.
- `non-executable-script`: those three files are **sourced, never executed**. Making them 0755
  would advertise an entry point that does nothing. `%install` strips the shebang from the
  installed copies instead. The checkout keeps its shebangs, where shellcheck and editors read
  the dialect off them.

After both fixes:

```
1 packages and 0 specfiles checked; 0 errors, 0 warnings, 11 filtered, 0 badness
rpmlint(rpm) rc=0
```

The SRPM is clean too apart from one waived line:

```
kempt.spec: W: specfile-warning sh: warning: setlocale: LC_ALL: cannot change locale
                                  (en_US.UTF-8): No such file or directory
```

**Waived: environment, not package.** The Fedora container image ships no `en_US.UTF-8` locale.
It says nothing about the spec.

## 3. The build

```
$ rpmbuild -ba ~/rpmbuild/SPECS/kempt.spec
...
+ bash -n bin/kempt lib/common.sh backends/dnf.sh backends/flatpak.sh \
      libexec/kempt-apply libexec/kempt-refresh
+ appstreamcli validate --no-net --explain .../usr/share/metainfo/io.github.erez_c137.kempt.metainfo.xml
Wrote: /root/rpmbuild/SRPMS/kempt-0.1.0-1.fc44.src.rpm
Wrote: /root/rpmbuild/RPMS/noarch/kempt-0.1.0-1.fc44.noarch.rpm
rpmbuild rc=0
```

165 KB noarch RPM.

**Worth knowing:** rpm's `brp-mangle-shebangs` rewrites shebangs on the executables, so the
packaged CLI is not byte-identical to the checkout's:

```
mangling shebang in /usr/share/kempt/bin/kempt from /usr/bin/env bash to #!/usr/bin/bash
mangling shebang in /usr/libexec/kempt-refresh from /bin/bash to #!/usr/bin/bash
mangling shebang in /usr/libexec/kempt-apply from /bin/bash to #!/usr/bin/bash
```

That is Fedora policy and it is correct on Fedora. It matters only because `kempt doctor`
compares installed copies against a checkout, and section 5 below is what that does here.

## 4. Dependencies

Every `Requires:` resolves on a clean Fedora 44. Depsolved from the built RPM, nothing downloaded:

```
$ dnf install -y --assumeno ~/rpmbuild/RPMS/noarch/kempt-0.1.0-1.fc44.noarch.rpm
Transaction Summary:
 Installing:       721 packages
Total size of inbound packages is 715 MiB.
```

721 packages because `Requires: plasma-workspace` pulls the Plasma desktop, which is the honest
cost of a panel widget. That closure has no bearing on file layout or CLI behaviour, so the smoke
below installed the RPM with `rpm -Uvh --nodeps` plus a real `jq`, rather than downloading 715 MiB
of desktop into a throwaway container.

## 5. The smoke, on the installed package

```
$ rpm -Uvh --nodeps kempt-0.1.0-1.fc44.noarch.rpm
```

**1. The version a bug report will quote.**

```
$ /usr/bin/kempt --version
kempt 0.1.0
```

**2. The symlink, and the `readlink -f` mechanism from section 3.1 of the packaging research.**

```
$ ls -l /usr/bin/kempt
lrwxrwxrwx. 1 root root 26 /usr/bin/kempt -> /usr/share/kempt/bin/kempt

$ SELF="$(readlink -f /usr/bin/kempt)"; ROOT="$(dirname "$(dirname "$SELF")")"
SELF=/usr/share/kempt/bin/kempt
ROOT=/usr/share/kempt
present: /usr/share/kempt/lib/common.sh
present: /usr/share/kempt/backends/dnf.sh
present: /usr/share/kempt/backends/flatpak.sh
```

A real file at `/usr/bin/kempt` would have given `ROOT=/usr` and sent it looking for
`/usr/lib/common.sh`. The symlink is load-bearing, and it works.

**3. The libexec rewrite, read out of the INSTALLED files rather than trusted from `%prep`.**

```
$ grep -n 'exec.path' /usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy
15: <annotate key="org.freedesktop.policykit.exec.path">/usr/libexec/kempt-refresh</annotate>
26: <annotate key="org.freedesktop.policykit.exec.path">/usr/libexec/kempt-apply</annotate>

$ grep -n 'HELPER_PATH=' /usr/share/kempt/lib/common.sh
40:KEMPT_REFRESH_HELPER_PATH="${KEMPT_REFRESH_HELPER_PATH:-/usr/libexec/kempt-refresh}"
41:KEMPT_APPLY_HELPER_PATH="${KEMPT_APPLY_HELPER_PATH:-/usr/libexec/kempt-apply}"

$ ls -l /usr/libexec/kempt-refresh /usr/libexec/kempt-apply
-rwxr-xr-x. 1 root root 1161 /usr/libexec/kempt-refresh
-rwxr-xr-x. 1 root root 2938 /usr/libexec/kempt-apply
```

All four annotations and defaults agree, and the helpers are root:root 0755 where they point.
Sweeping every non-`%doc` file the package owns for a surviving `/usr/local/libexec` finds none.

The `%doc` copies do still name it - `security.md` and `usage.md` describe the checkout install,
which really does use `/usr/local/libexec`. Correct there, but see "left open" below.

**4. `kempt doctor` in a packaged install.**

```
info  kempt 0.1.0 (/usr/share/kempt)
ok    root helper (refresh): /usr/libexec/kempt-refresh (root:root 0755)
ok    root helper (apply): /usr/libexec/kempt-apply (root:root 0755)
ok    polkit action: /usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy
ok    jq: /usr/bin/jq (jq-1.8.1)
FAIL  terminal emulator 'konsole' not found - ...
FAIL  flatpak command 'flatpak' not found - ...
ok    dnf: /usr/bin/dnf5
ok    config file: none yet, built-in defaults apply
ok    state dir writable: /root/.local/state/kempt (created on first use)
ok    checkout intact: /usr/share/kempt
info  version: kempt 0.1.0
info  install: packaged - the package manager keeps these files in step
kempt doctor: 2 problems found            (rc=1)
```

Runs, and exits without crashing. **How the checkout-comparison section behaves, recorded and not
redesigned:**

- doctor already knows the difference. It prints `install: packaged - the package manager keeps
  these files in step`, and the `helpers:` / `policy:` / `widget:` DIFFER comparisons that a
  checkout install gets are not attempted at all. Nothing false is claimed, which is the thing
  that mattered.
- The one line that still speaks checkout is `checkout intact: $ROOT`, and it passes only because
  the spec now ships `polkit/49-kempt.rules.in`. It is really a "the tree the CLI runs from is
  complete" check, and it is correct in a packaged install for the same reason it is in a
  checkout - the wording is just inherited.
- The two `FAIL` lines are the container, not the package: `konsole` is `Suggests` and `flatpak`
  is `Recommends`, and both are installed by default on a real Fedora box. rc 1 here is doctor
  reporting a bare container honestly.
- doctor never notices the mangled shebang, because it compares nothing in this mode. Worth
  knowing before anyone teaches it to compare a packaged install against anything.

**5. The rest of the payload.** All present: the metainfo at `/usr/share/metainfo/`, the plasmoid
as `metadata.json` + `contents/` under `/usr/share/plasma/plasmoids/io.github.erez_c137.kempt/`,
six icon rungs in hicolor, `kempt.1.gz`, `VERSION`, and the rules template. The installed metainfo
validates:

```
$ appstreamcli validate --no-net /usr/share/metainfo/io.github.erez_c137.kempt.metainfo.xml
✔ Validation was successful.
```

## 6. Left open, deliberately

- **COPR is still unverified.** Section 3.4 of the packaging research is read from upstream docs,
  not executed. Nothing here proves the SCM source method or the webhook, and a private repo
  cannot be cloned by COPR anyway.
- **The `%doc` copies describe the checkout install.** Someone who installs the RPM and reads
  `/usr/share/doc/kempt/security.md` sees `/usr/local/libexec` paths that are not their install's.
  Not fixed here: rewriting the docs to speak both installs is a documentation decision, not a
  packaging one.
- **`Source0` points at a GitHub archive URL that 404s** while the repo is private. rpmbuild never
  fetches it - the tarball is placed in `SOURCES` by hand, or by COPR from the tag - so it does
  not block the build. It has to resolve before COPR runs.
