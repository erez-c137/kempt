# Getting Kempt into the official Fedora repos - the plan

Process verified against the live Fedora docs on 2026-09-04 (Package Review Process, last
content update 2026-08-24, and How to Get Sponsored into the Packager Group). Where this doc
and those pages disagree, the pages win - re-check them when a stage actually starts.

## What it buys, concretely

- `sudo dnf install kempt` with no COPR step. One command, and the more trusted one.
- A real one-click install from the KDE Store becomes honest. The PackageKit session API
  (`InstallPackageNames` - the "install missing thing" dialog Discover and GNOME use) can
  only draw from repos that are already enabled. Today the widget's Copy Commands button is
  the truthful ceiling; a package in Fedora proper lifts it.
- Discover and GNOME Software list Kempt like any other Fedora package, with our metainfo.
- The trust question ("random COPR from a solo dev?") gets the strongest possible answer:
  the spec passed a formal Fedora review and the package is built on Fedora infrastructure.

## Where we start from (assets already in hand)

- **The spec is already review-shaped.** `Source0` is the GitHub tag tarball
  (`%{url}/archive/v%{version}/...`), License is SPDX `MIT`, rpmlint runs 0 errors 0
  warnings, noarch, no daemons, no scriptlets beyond hicolor file triggers, `%check` runs
  appstreamcli validate. rpkg is only how COPR builds it; the spec never depended on it.
- **The name is free.** `dnf5 repoquery kempt` against the official repos returns nothing
  (checked 2026-09-04).
- **COPR is the proving ground and the hosting.** The review process wants the spec and SRPM
  at plain-https URLs and explicitly suggests COPR for exactly that; our builds already
  produce SRPMs at stable result URLs, green on 8 chroots.
- **FAS account exists** (erez-c137, used for COPR).
- Metainfo validates fully, a man page ships, docs/security.md answers the questions a
  reviewer will actually ask.

## The path, in stages

### Stage 0 - pre-flight (no gatekeepers, can start any time)

1. **Bugzilla account tied to the FAS email.** The docs warn in bold terms: a review request
   filed from an account not tied to your FAS email gets closed INVALID. With more than one
   email address in play, check this before filing, not after.
2. Run the `fedora-review` tool (packaged in Fedora) locally against our own SRPM and fix
   everything it flags. It is the same tool reviewers run; walking in clean shortens the
   review by weeks.
3. Read the Packaging Guidelines sections that touch us specifically: polkit
   policies/rules, AppData/metainfo, icon handling and file triggers, and the review
   guidelines MUST/SHOULD lists.
4. `licensecheck` over the tree; every file should already be clean MIT, but a reviewer
   will run it, so we run it first.

### Stage 1 - file the review request

1. Spec + SRPM URLs from the COPR build results (stable, plain https).
2. File the review request in Red Hat Bugzilla (product Fedora, component Package Review)
   from the FAS-tied account: package name, a one-paragraph description (the metainfo
   summary is the right register), spec URL, SRPM URL, and a link to a successful COPR
   build as proof it builds.
3. Mark the bug as blocking **FE-NEEDSPONSOR** - we are not in the packager group yet.
4. Do NOT mark the Whiteboard `Trivial`. The package qualifies on most counts (builds, no
   daemons, clean rpmlint, simple macros), but a polkit policy plus two root helpers is
   security-relevant surface, and claiming triviality for it would be exactly the kind of
   overclaim Kempt exists to avoid. Say that in the ticket; reviewers notice.

### Stage 2 - get reviewed, get sponsored (the long pole)

A reviewer can be any packager; a sponsor must come on top of that if the reviewer is not
one. Four routes, worked in parallel:

1. **Review swaps.** The Package Review Swaps category on Fedora Discussion: offer to review
   someone else's package in exchange. We cannot formally review yet (not in the packager
   group) but thorough informal review comments on open requests are explicitly named by the
   docs as how you demonstrate competence to a sponsor.
2. **The sponsors page.** Sponsors are searchable by domain of interest and language;
   shell/packaging/KDE-adjacent sponsors are the right filter. Direct, polite, with the
   review ticket and the repo in the first message.
3. **The KDE SIG angle.** A tray updater for the Fedora KDE spin is squarely their
   territory, and the announcement wave (r/fedora post, KDE Discuss thread) is part of this
   stage whether we label it that or not - packagers read those rooms. If a packager shows
   up interested in the announcement threads, the review ticket is the link to hand them.
4. **After `fedora-review +`:** if still unsponsored, raise an issue at packager-sponsors -
   that is the formal request point, and an approved review attached to it is the strongest
   possible case.

Honest expectation: weeks to months. The queue is long and sponsorship depends on a human
volunteering. Nothing else in the project gates on this stage; COPR remains the supported
install for as long as it takes.

### Stage 3 - repo, branches, builds (mechanical once approved)

1. Fedora dist-git now lives on Fedora Forge (Forgejo): generate an API token with
   read/write `issue` permission into `~/.config/rpkg/fedpkg.conf` (or
   `fedpkg set-distgit-token`).
2. `fedpkg request-repo kempt <review-bug-number>` - the bug must have `fedora-review +`
   and be assigned to the reviewer, or the request is auto-closed.
3. `fedpkg request-branch` for the current stable releases (rawhide comes by default).
4. `fedpkg clone`, import the SRPM, final check, `fedpkg build` (needs Fedora Kerberos set
   up) - once per branch via `fedpkg switch-branch` + `build`.
5. Bodhi updates for the release branches (`fedpkg update`); rawhide needs none.
6. Close the review ticket as NEXTRELEASE (or let Bodhi close it).

### Stage 4 - steady state (what being in Fedora costs)

- Every release: tag upstream, bump spec, build per branch, Bodhi update with notes. This
  layers onto docs/RELEASING.md as a step after the COPR one, not a replacement - COPR keeps
  serving old-release users and pre-Bodhi testing.
- Add the package to Upstream Release Monitoring (Anitya) so Fedora files a bug when a new
  tag appears, and enable Koschei for build-health monitoring.
- Bugs from Fedora users land in Red Hat Bugzilla, not GitHub - both need watching.
- Mass rebuilds are near-noise for a noarch bash package.
- The COPR-vs-Fedora repo overlap resolves itself by NVR: same version, dnf prefers
  whichever it saw with equal NVR; the clean end state is telling COPR users they can
  `dnf copr remove` once the Fedora package reaches their release.

## Review risks we walk in with, and the answers

| A reviewer will poke | The prepared answer |
| --- | --- |
| polkit policy + two root helpers | docs/security.md: separate actions for refresh vs apply, argument-validating helpers, auth_admin_keep, passwordless is opt-in, one rule, one action, active local session only |
| bash for privileged tooling | helpers are tiny and argument-validated; the CLI is the unprivileged orchestrator; 2400+ assertion suite; shellcheck-clean in CI |
| tree under /usr/share/kempt with a /usr/bin symlink | the CLI resolves its root via readlink -f; precedent exists and the layout is documented in the spec comments |
| widget + CLI in one package | they are version-pinned to each other by design; shipping them separately manufactures the mismatch kempt doctor exists to catch |
| plasmoid file placement | /usr/share/plasma/plasmoids is where Fedora's own packaged plasmoids live |
| stock icon in metainfo | %check already validates with appstreamcli (the reason it is not appstream-util is recorded in the spec) |

## After Fedora: other distros' repos, gated on backends

Repos follow backends, never the other way around - a package in a repo whose package
manager Kempt cannot drive would be an ornament.

- **AUR** (after the pacman backend, issue #2): anyone can publish to AUR the day the
  backend merges, including a community member; it needs no review process. Likeliest first.
- **Debian official** (after the apt backend, issue #1): ITP bug, a package on
  mentors.debian.net, and a Debian Developer sponsor. Slower than Fedora's process; the
  realistic path is a Debian-side volunteer, which is what issue #1 is for.
- **openSUSE** (after the zypper backend, issue #3): OBS devel project first (their COPR
  equivalent, low friction), Factory submit-request when proven.
- **Flathub: never, and on purpose.** A system updater needs root helpers, polkit policy
  and the host package manager; the flatpak sandbox exists to prevent exactly that. This is
  a design fact, not a gap - worth one line in any thread where it comes up.

## Next actions, in order

1. (Erez, 10 min) Confirm/create the Bugzilla account on the FAS email.
2. (Prep, delegable) Run fedora-review + licensecheck against the 0.1.1 SRPM, fix findings.
3. (Erez, 30 min) File the review bug with FE-NEEDSPONSOR; paste URLs from COPR.
4. (Ongoing, both) Sponsorship routes from Stage 2, announcement threads included.
5. Everything after that is gated on a human reviewer appearing - the plan resumes at
   Stage 3 the day the flag flips.
