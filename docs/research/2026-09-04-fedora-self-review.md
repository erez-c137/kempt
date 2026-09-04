# Fedora package self-review: kempt.spec vs the Review Guidelines

The official MUST and SHOULD lists (docs.fedoraproject.org, Packaging Guidelines: Review
Guidelines, fetched 2026-09-04), walked item by item against `kempt.spec` at 0.1.1 by us,
before any reviewer sees it. This document, updated with the P2 tool runs, becomes the first
comment on the review ticket. Verdicts: PASS (with evidence), N/A (with reason), PENDING
(waiting on the fedora-review/mock run), FINDING (something we change or decide first).

## MUST items

| # | Item | Verdict |
| --- | --- | --- |
| 1 | rpmlint on SRPM and all binary rpms, output posted | PENDING P2 - binary rpm already 0 errors 0 warnings (container run, 2026-09-03); SRPM run outstanding |
| 2 | Named per Naming Guidelines | PASS - lowercase, no separators needed, no collision (`dnf5 repoquery kempt` against official repos: empty, 2026-09-04) |
| 3 | Spec file named %{name}.spec | PASS - kempt.spec |
| 4 | Meets Packaging Guidelines generally | PENDING P2 - fedora-review automates the bulk; this table covers the named items |
| 5 | Fedora-approved license | PASS - MIT |
| 6 | License field matches actual license | PASS pending licensecheck sweep (P2); all code, QML and SVG authored in-repo under MIT |
| 7 | License text in %license | PASS - `%license LICENSE` |
| 8 | Spec in American English | PASS |
| 9 | Spec legible | PASS - every non-obvious choice carries its reason in a comment |
| 10 | Sources match upstream URL | PASS - Source0 is the GitHub tag archive URL in the blessed form; sha256 comparison is mechanical at review time |
| 11 | Builds on at least one primary arch | PASS - noarch; COPR green on 8 chroots incl. x86_64 and aarch64 (build 10949754); mock proof in P2 |
| 12 | ExcludeArch bugs | N/A - noarch, nothing excluded |
| 13 | All build deps in BuildRequires | PASS pending mock (P2 is the proof) - only `appstream` beyond the default buildroot; sed/coreutils/bash are default |
| 14 | Locales via %find_lang | N/A - no locale files shipped (translations are roadmap v1.x) |
| 15 | No bundled system libraries | PASS - nothing bundled |
| 16 | Relocatable justification | N/A - not relocatable, no Prefix |
| 17 | Owns all directories it creates | PASS with evidence - owns `%{_datadir}/kempt/` and the plasmoid dir; every parent it does not own is owned by a package it Requires: `/usr/share/plasma/plasmoids` by plasma-workspace (rpm -qf, 2026-09-04, co-owned with libplasma and plasma-desktop), `/usr/share/polkit-1/actions` by polkit, `/usr/share/metainfo` by filesystem, the hicolor tree by hicolor-icon-theme |
| 18 | No duplicate %files entries | PASS - the `%{_datadir}/%{name}/` glob is the only owner of that tree |
| 19 | File permissions proper | PASS - helpers 0755 root:root via %attr, sourced libraries 0644 with shebangs stripped (the spec explains why), symlinked /usr/bin/kempt |
| 20 | Consistent macro use | PASS |
| 21 | Contains code or permissible content | PASS |
| 22 | Large docs in -doc subpackage | PASS - five small markdown files, tens of KB; judgment call documented here |
| 23 | %doc must not affect runtime | PASS with evidence - `grep -rn "docs/" bin lib backends libexec` finds only comments; the CLI never reads a %doc file (verified 2026-09-04) |
| 24 | Static libs in -static | N/A |
| 25 | Devel files in -devel | N/A |
| 26 | -devel requires base, versioned | N/A |
| 27 | No .la archives | N/A |
| 28 | GUI app ships .desktop file, or a comment explains why not | FINDING F1 - see below |
| 29 | Does not own other packages' files/dirs | PASS - same evidence as item 17; only leaf files installed into shared trees |
| 30 | Valid UTF-8 filenames | PASS - all ASCII |
| 31 | No deps on deprecated packages | PASS with evidence - `dnf5 repoquery --whatprovides 'deprecated()'` intersected with our full Requires/Recommends/Suggests list: empty (2026-09-04) |

## SHOULD items

| # | Item | Verdict |
| --- | --- | --- |
| 1 | License text included upstream | PASS - LICENSE is in the repo |
| 2 | Builds in mock | PENDING P2 |
| 3 | Builds on all supported arches | PASS - noarch |
| 4 | Versioned symbols | N/A - no shared libraries |
| 5 | Functions as described | PASS - offline staging, harvest, doctor and the widget were live-gated end to end on real hardware (docs/plans checklist); reviewer re-tests |
| 6 | Scriptlets sane | PASS - there are none; icon cache updates ride hicolor-icon-theme's file triggers, and the spec says so |
| 7 | Subpackages require base, versioned | N/A today - but see FINDING F2 |
| 8 | pkgconfig placement | N/A |
| 9 | Man pages for binaries | PASS - kempt.1 ships; the two libexec helpers are pkexec-only internals, not user commands, so no page (judgment documented here) |

## Findings

**F1 (spec change before filing): the no-.desktop-file explanation must stand on its own.**
The guideline demands a comment explaining why a GUI package ships no .desktop file; our spec
mentions the absence only inside the BuildRequires rationale. Fix: a dedicated comment
stating the actual reason - a Plasma applet is not a menu-launched application; it is
discovered by plasmashell through metadata.json and added from Add Widgets; there is nothing
for a .desktop file to launch, which is also why the metainfo is type=addon with no
launchable. One comment block, no behavior change.

**F2 (decision to hold ready, not a preemptive change): the plasma-workspace pull-in.**
`Requires: plasma-workspace` on the base package means the CLI cannot install without the
Plasma stack. A reviewer may reasonably ask for a split: `kempt` (CLI, no desktop deps) plus
a `kempt-widget` subpackage carrying the plasmoid and the plasma-workspace requirement.
Version lockstep - the reason we ship one package - survives that shape fully: both come from
one SRPM and the subpackage requires `kempt = %{version}-%{release}` exactly; with the base
package adding `Recommends: kempt-widget`, a plain `dnf install kempt` still delivers both on
default configs. Position: we are genuinely open to this and arrive with the shape worked
out, but we do not churn the spec before a reviewer weighs in, because reviewers differ and
an unforced split has real costs too (two packages to explain everywhere the one is named).

**F3 (minor, note only): metainfo screenshot URLs point at the main branch**, so the images
a software center shows can drift ahead of the release it describes. Pinning them to the
release tag would be strictly more truthful; it adds a sed step to the release procedure.
Low priority; not a review blocker.

**F4 (investigate in P2): run the pure-parser test subset in %check.** The tarball carries
the whole test suite, and the parser tests need only bash and jq with fixtures from the
tree - no network, no root, no package manager. If a curated subset runs green in mock
(BuildRequires: jq added), %check goes from syntax-and-metadata to actually exercising the
code, which is a strong review signal. To verify: which test files are pure, their runtime,
and that none touches the network or assumes a writable HOME outside the build dir.

## Still owed before filing (the P2 run)

fedora-review against the 0.1.1 SRPM from COPR, rpmlint on the SRPM, licensecheck over the
tree, and the F4 feasibility check - then F1 (and F4 if adopted) ship as a normal patch
release, and the ticket opens with that release's URLs.
