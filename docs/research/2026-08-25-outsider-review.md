# Outsider review - a cold read of the repo

**Date:** 2026-08-25
**Stance:** the repo read cold, with no context from the build, by someone playing three readers
in turn: a new user who just cloned it, a would-be contributor looking for the seam to add a
backend, and a security auditor who does not take the security doc's word for anything.
**Status of this file:** condensed by the person who then implemented most of it. The ranked list
and the credibility list below are tight paraphrases, not a transcript. Dispositions and commit
subjects are facts; the wording is a summary.

Working archive, like everything else under `docs/research/`. It is here so a future maintainer
can see what a stranger tripped over, and what was deliberately left alone.

---

## The headline

Nothing in the repo was found to be dishonest. The docs match the code to an unusual degree, and
several claims that looked like marketing turned out to be literally true when checked against
the source. What the review found instead was a **consistent blind spot**: the CLI degrades
instead of crashing everywhere, which is right for a widget polling on a timer and wrong for a
human trying to find out why nothing works. The worst finding is a direct consequence of that.

## Top 10, ranked by what it costs a stranger

| # | Finding | Why it matters | Disposition |
| --- | --- | --- | --- |
| 1 | With the root helpers missing, `upkeep check` exits **0** with `status: "stale"` and zero pending items. On a fresh clone where `install.sh` was never run (or its auth prompt was declined), that is indistinguishable from "your machine is up to date". | The first command a new user runs lies to them, quietly, in the one situation most likely to be true on day one. | **Fixed tonight**: new `upkeep doctor` (`feat: upkeep doctor - say why an empty check is empty`) |
| 2 | The one clue `check` does give is wrong: `error: "dnf check failed: timeout: failed to run command '/usr/local/libexec/upkeep-refresh': No such file or directory"`. That is the `timeout` wrapper naming a missing file, but it reads as a network timeout. | Sends the reader hunting a repo or connectivity problem they do not have. | **Fixed tonight** (`fix: a missing root helper says so instead of reading as a timeout`) |
| 3 | `upkeep history` counted `.updated` alone, printing `0 updated` for a run whose own summary, from the same JSON entry, says `+2 installed, -1 removed`. `render_summary` states the opposite principle in a comment two functions away. | The code contradicting itself in front of the user is worse than either behaviour on its own. | **Fixed tonight** (`fix: history counts what a run changed, not only what it upgraded`) |
| 4 | `check_rules_dst` accepted any absolute `*.rules` path, so `UPKEEP_RULES_DST` could point a root `install(1)` at any directory under `/etc`, `..` included. | The seam is user-controlled and the consumer is root. Small hole, cheap fix, and the guard was already claiming to prevent exactly this. | **Fixed tonight** (`fix: pin the passwordless rule destination to polkit's own directory`) |
| 5 | `docs/security.md` never stated the `auth_admin_keep` residual: for polkit's retention window (its own docs say "e.g. five minutes"), any process running as the user can invoke the apply helper with no prompt. Nor did it say what bounds a hostile payload once an upgrade is authorized. | A security document that only lists its own defenses reads as marketing. The residual is defensible; hiding it is not. | **Fixed tonight** (`docs: the retention window, and what actually bounds an update`) |
| 6 | The backend-author guide named 3 call sites. There are 10, and the missed ones fail quietly: the `source` lines, `render_summary`'s hardcoded backend keys, `harvest_offline`, the hold/unhold whitelist. `assemble_state` takes items positionally, so a third backend is a **signature change**, which no document said. | "Adding a backend is one file" is the project's main contribution pitch. A contributor who believes it literally gets a half-wired backend that reports nothing. | **Fixed tonight** (`docs: the real backend wiring list...`) |
| 7 | `CONTRIBUTING.md` said root-helper changes need an issue first, and then said a new backend needs no permission, "just send it". A backend cannot work without a new verb in the root helper. | Two rules, one contradiction, and the contributor loses either way. | **Fixed tonight** (same commit as 6) |
| 8 | The README's "Why" sold a panel icon in the present tense ("Upkeep replaces that with one icon. Click it, and...") while Status, two screens down, said the widget was still being built. | The reader meets a promise and then a correction, which is exactly the credibility the rest of the docs work hard to earn. | **Fixed tonight** (`docs: README leads with the half that is finished`) |
| 9 | Three assertions in `tests/test_run.sh` depended on the machine having `konsole` installed: `cmd_run` checks `command -v "$UPKEEP_TERMINAL"` before printing its launch plan. On a stripped PATH the suite fails for reasons that have nothing to do with the code. | "Clone it and run the tests" is the contributor on-ramp, and a suite that fails on a clean machine burns the first five minutes of it. | **Fixed tonight** (`test: stub the terminal emulator so run tests do not depend on the box`) |
| 10 | The install is a symlink into a load-bearing git checkout. Move the directory and the tool breaks. It is documented in three places, which is the right handling for a developer install, and the wrong answer for a stranger. | This is the one finding whose fix is not a patch: it is packaging. | **Roadmap** (v1.x: RPM/COPR + KDE Store, already ordered in `docs/ROADMAP.md`) |

## Raised and deliberately not changed

Recorded with the reason, because the next reviewer will raise them again.

- **`upkeep check` exits 0 when a backend fails.** Declined. This is the documented contract, and
  the reason is a polling widget: a non-zero exit would make every repo flap look like a broken
  tool, and the failure is carried in `status`, `error` and the preserved item lists instead. The
  fix for the human side of it was `doctor`, not a changed exit code.
- **The dnf check parser is text, not `dnf5 check-update --json`.** Roadmap (v2). Documented as a
  known v1 decision; migrating it retires a whole bug class by construction, but churns the
  fixture and test layer, which is not a thing to do at the end of a build.
- **`flatpak update` also updates runtimes, and the summary tracks apps.** Roadmap. Already
  documented as a known limitation in three places; a run can change more than it itemizes.
- **`jq` is a hard dependency and its absence exits 3 before anything else runs.** Accepted. Every
  state and history file is JSON; a bash reimplementation would be a bug farm.
- **The `*_ECHO` test seams live in root-owned code.** Accepted, and already in the security doc's
  own "Accepted limitations" list: they are unreachable through pkexec (which sanitizes the
  environment) and they only print.
- **The suite has no shellcheck gate.** Not run here: shellcheck is not installed on the build box.
  The CI workflow is the place for it, and CI is currently manual-trigger until the repo is public.

## Load-bearing for credibility - do not lose these

The review's closing note, condensed. These are the things that made a cold reader believe the
rest, and any one of them is easy to erode by accident.

1. **Comments that name the bug they prevent.** Not "what", but "this used to produce 192 phantom
   updated rows". A maintainer who does not know why a guard exists deletes it in six months.
2. **Tests that bind.** The convention of breaking the code, watching the test go red, and putting
   it back. Several bugs in this repo survived a green suite before that rule existed.
3. **Fixtures captured through the production code path**, with `MANIFEST.md` recording provenance
   and what each deliberate oddity guards. The `sort -u` capture that hid a whole bug class from
   the entire suite is the cautionary tale, and it is written down.
4. **Sections that admit what the tool does not do**: "Accepted limitations" in `security.md`,
   "Known v1 decisions" in `architecture.md`. They are the reason the rest of those documents get
   the benefit of the doubt.
5. **One exit-code contract, in a table, verified against the code** rather than remembered.
6. **The two polkit actions, and validate-before-exec in the helpers.** The split exists because
   `auth_admin_keep` caches per action id; the validation exists because pkexec explicitly does
   not check arguments. Both are reasoned, not cargo-culted.
7. **The state schema described as a public interface and frozen.** Additive changes only. It is
   what lets a widget, or anything else, be written against it without asking permission.
8. **A seam for every impure call**, so the suite tests privileged and destructive paths without
   ever running them, and so a contributor needs no dnf, flatpak, polkit or root.
9. **Degrade, never crash - with a counterweight.** The degradation is right, and `doctor` is what
   keeps it from becoming a lie. If a future command starts swallowing a failure, it owes the user
   a place to go and read about it.
10. **Plain commit messages that explain the why.** The log is part of the documentation here, and
    it reads like one.
