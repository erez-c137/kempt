# Kempt Documentation (Plan 1.5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship community-grade documentation for Kempt v1 - the full set a serious open-source Linux project is expected to have - so an outside user can install and use the tool, and an outside contributor can add a backend, without reading the source.

**Architecture:** Documentation is derived from three authoritative sources and must never contradict them: the code as built (repo, authoritative), the spec (`docs/specs/2026-08-24-kempt-design.md`), and the plan's POST-REVIEW notes (`docs/plans/2026-08-24-kempt-cli.md`). Where docs and code disagree, the code wins and the doc is wrong. Every command, config key, default, exit code, and JSON field documented here MUST be verified against the repo at writing time, not copied from memory.

**Execution timing:** After Plan 1 Task 14 (install.sh) completes and the CLI surface is frozen. The widget (Plan 2) will add its own docs section later; leave clearly-marked stubs where widget content will land, never invented content.

**House rules:** NO em dashes anywhere in these files (use a spaced hyphen " - " or rephrase; sweep with `grep -rn '—' <files>` before every commit). US English. Every shell example must be copy-paste runnable (verify each one). Concise beats complete: a reader finishing a page should know what to do next.

---

### Task D1: README overhaul

**Files:** Modify: `README.md`

The landing page. Structure (in order): project name + one-line pitch ("One-click system updates from the KDE Plasma panel. Fedora first; built to grow into a universal Linux updater."); badges (license only for now); a "Why" paragraph (the panel-icon-to-clean-summary story, holds, offline updates); Features list (live badge with actionable count, holds/skip-but-notify, four run surfaces incl. Fedora-recommended offline staging, clean old-to-new summaries, update history, scoped polkit privileges with optional passwordless); Status section (v1 CLI complete, Plasma widget in progress - be honest); Quick start (install.sh + `kempt check` + `kempt update`); pointer table to docs/; Contributing pointer; License. Screenshot placeholder comment where the widget screenshot will go (Plan 2).

- [ ] Write, verify every command shown actually runs, em-dash sweep, commit: `docs: community-grade README`

### Task D2: Install guide

**Files:** Create: `docs/install.md`

Requirements (Fedora 41+, dnf5, flatpak optional, jq, polkit - verify the actual minimums from code); what `install.sh` does step by step and WHAT LANDS WHERE (CLI symlink, two root helpers in /usr/local/libexec, policy in /usr/share/polkit-1/actions, the one pkexec prompt, the Discover-notifier opt-out and exactly what it changes and how to undo it); passwordless setup (`kempt enable-passwordless`, what the rules file grants and its active+local scoping, how to disable); full uninstall; verifying the install (`kempt check`).

- [ ] Write from install.sh as built + spec Privileges section, verify paths, commit: `docs: install guide`

### Task D3: Usage reference

**Files:** Create: `docs/usage.md`

Every subcommand with synopsis, behavior, examples, and EXIT CODES (the precise contracts: check exits 0 on backend failure/corrupt state, non-zero only on persistence failure after printing; update exit semantics; rc 2 usage errors; rc 3 missing jq). Sections: check (state JSON overview + pointer to architecture doc for schema), update (with --no-flatpak, --surface=), run (surface dispatch, auto_accept=false forces terminal), summary/history, hold/unhold/holds (the skip-but-notify semantics, backend:name format), config get/set, enable/disable-passwordless. A "Typical day" walkthrough tying it together.

- [ ] Write, verify every example against `bin/kempt` as built, commit: `docs: CLI usage reference`

### Task D4: Configuration reference

**Files:** Create: `docs/configuration.md`

Config file location + format; a table of every key with type, default (from `kempt_default` in code - verify), and effect (include_flatpak, auto_accept, surface, refresh_interval_min); accepted boolean spellings (is_true); the four run surfaces explained honestly incl. offline staging and the risky-transaction recommendation; holds file format; refresh cadence (cache-only checks vs the 3h metadata refresh, battery/metered skips); state/history/log file locations and retention.

- [ ] Write, cross-check every default against lib/common.sh, commit: `docs: configuration reference`

### Task D5: Architecture + "add a backend" guide

**Files:** Create: `docs/architecture.md`

The community on-ramp. Two-layer design (CLI owns all logic, widget is thin); the backends contract (check/update/report, snapshot-diff reporting and WHY - locale-proof, portable, small parsing surface); the one-row-per-name collapse contract and the installonly story; state JSON schema v1 field-by-field (this is the widget API - copy the frozen schema from the spec and verify against `assemble_state`); privileged boundary overview (pointer to security doc); **"Adding a backend for your distro"** walkthrough: the exact functions to implement (parse/check/snapshot), the fixture + MANIFEST workflow, the test harness conventions, apt/pacman as worked hypotheticals; the dnf5 `--json` v2 note.

- [ ] Write, verify schema + contracts against code, commit: `docs: architecture and backend-author guide`

### Task D6: Security model doc + SECURITY.md

**Files:** Create: `docs/security.md`, `SECURITY.md`

`docs/security.md`: why two polkit actions (auth_admin_keep caches per action id); what each action allows and its auth level; the helper validation model (validate-before-exec, NAME_RE, no arbitrary args, the locale pin and why it is load-bearing, pinned PATH); what passwordless actually grants and its scoping (active+local, single action) and how the rule is rendered safely; what pkexec sanitizes; known accepted limitations (per-app flatpak validation query, echo seam unreachable in production). Source material: spec Privileges section + the WP5 review findings encoded in code comments.
`SECURITY.md` (root): supported versions (v1), how to report (GitHub private vulnerability reporting once public; email placeholder until then), response expectation, scope (the root helpers + polkit files are the interesting surface).

- [ ] Write both, technical claims verified against libexec/* and polkit/* as built, commit: `docs: security model + reporting policy`

### Task D7: CONTRIBUTING + CODE_OF_CONDUCT

**Files:** Create: `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`

CONTRIBUTING: dev setup (clone, no build step, `tests/run_tests.sh`); the test harness rules that reviews enforce (sandbox first, never install your own EXIT trap, stub the seams, fixtures byte-faithful with provenance in MANIFEST.md, guard rows required, tests must be proven to bind - fail against the defect); TDD expectation; shell conventions (set -euo pipefail, explicit status returns from backends, validate-before-exec in anything privileged); how to propose a backend (pointer to architecture doc); commit style; "run the em-dash sweep on docs".
CODE_OF_CONDUCT: Contributor Covenant v2.1, standard text, contact placeholder. Superseded 2026-08-26 by a short custom document - see Task P6 in `docs/plans/2026-08-26-kempt-popup.md`. (This line records what was written then; it is not a claim about the current policy.)

- [ ] Write, commit: `docs: contributing guide + code of conduct`

### Task D8: CHANGELOG + man page

**Files:** Create: `CHANGELOG.md`, `docs/man/kempt.1`

CHANGELOG: Keep a Changelog format, `[Unreleased]` seeded with a human summary of v1 (features, not commits). Man page: hand-written troff, standard sections (NAME, SYNOPSIS, DESCRIPTION, COMMANDS, CONFIGURATION pointer, FILES, EXIT STATUS, SEE ALSO); verify it renders with `man -l docs/man/kempt.1`; add a line to install.sh staging it to the standard man path (coordinate with Task 14's installed file list; keep --destdir support).

- [ ] Write both, render-check the man page, commit: `docs: changelog + man page`

### Task D9: Docs QA gate (run as its own review pass)

A dedicated reviewer verifies, against the repo: every documented command/flag/key/default/exit code exists and matches (`grep` the code, run the examples); every file the install guide says lands somewhere matches install.sh; state schema matches `assemble_state` byte-for-field; no em dashes (`grep -rn '—'` over all new files = zero hits); no TODO/TBD/placeholder except the two marked widget stubs; internal links resolve. Fix everything found; re-check.

- [ ] QA pass clean, commit fixes: `docs: QA pass`

---

## Acceptance (whole plan)

An outsider on a fresh Fedora box can: understand what Kempt is from README alone, install it with docs/install.md, use every feature from docs/usage.md + the man page, and understand exactly what runs as root from docs/security.md. A contributor can add a backend using docs/architecture.md + CONTRIBUTING.md without asking questions the docs should have answered.
