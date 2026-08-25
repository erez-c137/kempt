# Fixture provenance

Captured / written 2026-08-24 on this box (Fedora 44, dnf5 5.4, flatpak 1.18). The box was
fully up to date at capture time, so the dnf5/flatpak "pending updates" commands returned no
real output to capture live — see each entry below for how that was handled. Fixture files
themselves stay byte-faithful to real tool output (no in-band `# HAND-WRITTEN SAMPLE` marker
lines); this file is the source of truth for what's genuinely captured vs. hand-written.

## tests/fixtures/dnf-check-update.txt
**Hand-written.** `LC_ALL=C dnf5 --cacheonly check-update --quiet` returned empty (box fully
up to date, verified live 2026-08-24) — there was no real "pending update" output to capture.
6 rows hand-written in the documented `name.arch  evr  repo` format, using real package names
and real current installed EVRs from this box (bash, curl, git-core, tar, vim-minimal,
aajohan-comfortaa-fonts), each bumped to a plausible newer EVR. Guard rows added on top:
- `brandnew.x86_64` (EVR `1.0-1.fc44`) — a package name deliberately absent from
  rpm-installed.tsv, so a parser whose join-miss guard (e.g. `join -e '?'`) gets deleted fails
  instead of silently passing.
- `bash.i686` at EVR `5.3.9-4.fc44` — a multilib twin of `bash.x86_64` (`5.3.10-1.fc44`) at a
  **deliberately divergent** EVR, because that is what multilib lag actually looks like: the
  i686 build of a package routinely trails the x86_64 one by a build or a release. Two arches
  are ONE package as far as this CLI's report is concerned, so the pair must collapse to a
  single `bash` entry (contract: this file parses to **7 items**). The divergence is the point:
  identical EVRs would collapse for free at `sort -u`, which silently hides a parser that has
  no real collapse step. Only a pending-side `collapse_versions` merges divergent twins, and
  the merged entry carries both versions comma-joined in **ascending version order**
  (`5.3.9-4.fc44,5.3.10-1.fc44`) exactly like the installonly sets in snap-multiver-raw.tsv.
  This pair is also the ordering guard: lexically `5.3.10-1` sorts *before* `5.3.9-4`, so a
  producer that sorts by bytes instead of by version leaves the older build last, where every
  consumer reads the newest (`render_summary`'s `newest()`, the widget's `newestOf()`).
- An **obsoletes section** — the literal header line `Obsoleting Packages` followed by one row
  indented by four spaces (`    old-tool.x86_64`) carrying a normal EVR and repo in the usual
  columns. Format is dnf5's own: after the pending-update table it appends this header and
  lists obsoleted packages **indented**, so indentation at column 0 is the ONLY structural
  signal separating them from real update rows (their name/EVR/repo columns are otherwise
  indistinguishable). An obsoleted package is being REMOVED, not upgraded — reporting it as
  pending invents a phantom self-update (`old-tool: ? → 1.0-1.fc44`) for something the user is
  losing. The parser's `/^[^[:space:]]/` column-0 anchor kills the indented row and the
  `NF>=3` + EVR-shape guards kill the bare header; if either is deleted the item count goes
  to 8 and the test fails.

## tests/fixtures/rpm-installed.tsv
**Captured-live**, 2026-08-24, via
`LC_ALL=C rpm -qa --queryformat '%{NAME}\t%{EVR}\n' | sort` against this box's real installed
package database, filtered to the names referenced above plus 3 extra real rows for realism
(per the plan's Task 2 Step 1 command). Every EVR in this file is a genuine currently-installed
version — nothing here is invented. `brandnew` was deliberately NOT added (see guard row
above — that's the point of the guard).

**Scope note (v1 decision):** Kempt v1 handles **system-scope flatpaks only**, so the backend's
real commands carry `--system` (`flatpak remote-ls --updates --system --app …` and
`flatpak list --system --app …`). These fixtures were captured without `--system` on a box where
the one installed app is system-scope, so their content is identical either way; the flag is a
cross-boundary contract with `libexec/kempt-apply`, which validates app ids against
`flatpak list --system`. A per-user app must therefore never appear in a check result. Re-capture
with `--system` if this box ever gains per-user apps.

## tests/fixtures/flatpak-remote-ls.txt
**Hand-written.** `LC_ALL=C flatpak remote-ls --updates --app --columns=application,version`
failed live twice (Flathub summary fetch timed out, ~2 min each, 2026-08-24) — there was no
real pending-update output to capture even setting the network issue aside (only one flatpak
app is installed on this box). 3 rows hand-written, TAB-separated:
- `net.mkiol.SpeechNote` — the one real app installed on this box — bumped from its real
  installed 4.8.4 to a plausible 4.8.5.
- `org.gimp.GIMP` — bumped from an invented-installed 3.0.2 to 3.0.4 — added purely for 2-app
  parser coverage. GIMP is not installed on this box (see flatpak-list.tsv note below).
- `com.example.NotInstalled` at version 9.9 — deliberately absent from flatpak-list.tsv, the
  same missing-from-installed guard as `brandnew.x86_64` above.

## tests/fixtures/flatpak-list.tsv
**Mixed.** Base row (`net.mkiol.SpeechNote  4.8.4`) is captured-live, 2026-08-24, via
`LC_ALL=C flatpak list --app --columns=application,version | sort` — the only flatpak app
actually installed on this box. One row added on top, hand-written: `org.gimp.GIMP  3.0.2` —
invented (GIMP is not installed here); added so flatpak-remote-ls.txt's GIMP entry has a
matching older-version row to join against, exercising the 2-app case. `com.example.NotInstalled`
was deliberately NOT added here (see guard row above — that's the point of the guard).

## tests/fixtures/snap-multiver-raw.tsv
**Hand-written**, 2026-08-24, but modeled directly on this box's real installonly duplication
(measured live: `rpm -qa` returns 2516 rows for only 2492 distinct names — `gpg-pubkey` ×13 and
six `kernel*` families ×3 each). Fedora keeps several versions of *installonly* packages
installed at once, so a raw `name\tEVR` snapshot legitimately repeats names.

That raw shape is POISON for `join`: duplicate names on both sides produce a CROSS PRODUCT, and
a self-diff of this box's real package list yielded **192 phantom "updated" rows** — a report
claiming 192 upgrades where nothing changed at all. Hence the two-part contract this fixture
guards:
- Producers (snapshot/lookup functions) pipe through `collapse_versions`, giving ONE row per
  name with the versions comma-joined in input order.
- `tsv_diff_updates` REJECTS duplicate-name input outright (exit 65) rather than silently
  emitting fiction.

6 rows: `gpg-pubkey` ×2 (short hex-ish keyids, the real format), `kernel-core` ×3 (consecutive
kernel builds, the everyday case), and `zsh` ×1 as a single-version control that must survive
collapsing untouched. Deliberately kept in RAW (uncollapsed) form — that is the entire point.

## tests/fixtures/snap-before.tsv / tests/fixtures/snap-after.tsv
**Hand-written**, per the plan's literal Task 2 Step 3 content — not live-captured; these exist
purely to give `tsv_diff_updates` a deterministic before/after pair. No comment-marker line:
both files are consumed directly by `join`, which requires every line to be a real TSV data
row, so a leading `#` line would break the diff instead of being skipped. Encodes: one
unchanged package (bash), two upgraded (kernel-core, vim-common), one removed (zsh), one added
(newpkg).

## tests/fixtures/state-*.json (widget: `kempt check` state schema v1)

The plasmoid parses `kempt check` stdout and nothing else, so its tests are fed real CLI output
rather than JSON somebody typed by hand. Seven of the ten were **captured live on 2026-08-25**
by running `bin/kempt check` in a stub sandbox built exactly the way `tests/test_check.sh`
builds one: a throwaway `HOME`, `KEMPT_CONFIG_DIR`/`KEMPT_STATE_DIR` under a tmpdir,
`KEMPT_PKEXEC=""`, `KEMPT_SKIP_REFRESH=1`, a `KEMPT_REFRESH_HELPER` stub that cats
`dnf-check-update.txt` and exits 100, and `KEMPT_DNF_INSTALLED_CMD` /
`KEMPT_FLATPAK_REMOTE_CMD` / `KEMPT_FLATPAK_LIST_CMD` pointed at the fixtures above. Each one
got a fresh config/state pair, so no fixture inherits another's holds or history. The files are
byte-faithful `kempt check` stdout (jq's own formatting, trailing newline included) - re-capture
by re-running the CLI the same way, never by editing the JSON.

**Re-captured 2026-08-25**, after the Upkeep to Kempt rename. A sed sweep over a byte-faithful
capture is exactly the hand-editing the rule above forbids, so all seven were produced again
through the renamed CLI by the same recipe. Only `state-broken.json` carries the product name
in its bytes (its `error` string names `kempt doctor`); the other six came back byte-identical
to their pre-rename selves apart from the capture timestamps, which is the evidence that the
rename moved names and nothing else.

Contract of the captured set (`dnf-check-update.txt` parses to 7 items, the flatpak fixtures to
3, so 10 pending in total):

- **state-live.json** - captured. The everyday case: both backends enabled, nothing held,
  `actionable: 10`, `status: "ok"`, `risky_pending: []`. Carries two guards the widget needs:
  `bash` arrives as a comma-joined multilib set (`5.3.9-4.fc44,5.3.10-1.fc44`) so the popup's
  version rendering has something to collapse, and `brandnew` / `com.example.NotInstalled` carry
  `from: "?"`.

  All seven captured files postdate `fix: version-sort collapsed sets so last always means
  newest` (654546e): the original six were **re-captured against it**, and state-broken.json was
  first captured after it. That commit made collapsed sets ascending, so the last element is now
  genuinely the newest - which is what both `render_summary`'s `newest()` and the widget's
  `newestOf()` take. Captured before it, this fixture's `bash` set read
  `5.3.10-1.fc44,5.3.9-4.fc44` and the widget faithfully rendered the OLDER build, agreeing with
  the CLI while both were wrong. Re-capture rather than edit if these ever drift again.
- **state-held-only.json** - captured, after holding all 7 dnf and all 3 flatpak names:
  `actionable: 0`, `held_total: 10`. This is the state that must still look up to date in the
  panel while the tooltip says "10 held" (spec, Holds semantics).
- **state-flatpak-disabled.json** - captured with `include_flatpak=false`:
  `backends.flatpak.enabled: false` with an empty item list. Note the CLI empties a disabled
  backend, so this file alone cannot prove the widget honours the `enabled` flag - the test pairs
  it with an inline state that keeps items under a disabled backend.
- **state-stale.json** - captured: one successful check, a 61-second pause, then a refresh helper
  that exits 1. `status: "stale"`, the previous 10 items and counts preserved, `error: "dnf check
  failed"`. The pause is the point: `last_success` (10:59) and `last_check` (11:00)
  land in different minutes, so a widget that showed the last ATTEMPT where it promised the last
  SUCCESS fails the test instead of passing by coincidence.
- **state-never.json** - captured: the FIRST check on a fresh box fails (no network, no previous
  state). `status: "stale"`, `last_success: null`, dnf items empty while flatpak still answers.
  The "never" branch of the stale tooltip, and the case where a reader that trusts `new Date()`
  would print "Invalid Date" at the user.
- **state-risky-heavy.json** - captured, with a hand-written 20-row `check-update` input in the
  documented `name.arch  evr  repo` format: kernel-core, kernel-modules, kernel-modules-core,
  systemd, systemd-libs, systemd-udev, glibc, glibc-common, dbus, dbus-broker, mesa-dri-drivers,
  mesa-libGL, mesa-vulkan-drivers, qt6-qtbase, qt6-qtdeclarative, kf6-kio, kf6-kcoreaddons,
  plasma-workspace, kwin-common, kwin-x11, all at EVR `9.9.9-1.fc44`. Real Fedora package names
  from the session-critical families, all pending at once - a Qt or KDE bump genuinely looks like
  this. The CLI flags all 20 in `risky_pending`; they reduce to 9 families (dbus, glibc, kernel,
  kf6, kwin, mesa, plasma, qt6, systemd), which is what makes this fixture exercise the ", ..."
  tail on the offline recommendation rather than just the four-family happy path.
- **state-broken.json** - captured, on a box where `install.sh` has never run: the refresh helper
  path does not exist and `include_flatpak=false` leaves nothing else that can answer. Result:
  `status: "stale"`, `last_success: null`, zero items in either backend, and the CLI's own
  diagnosis in `error` - "dnf check failed: root helper not installed - run ./install.sh (see:
  kempt doctor)". Recipe: a fresh config/state pair, `KEMPT_REFRESH_HELPER` pointed at a
  nonexistent path, `kempt config set include_flatpak false`, then `kempt check`.

  This fixture exists because of a specific near-miss. "Stale" was made deliberately calm - last
  known counts, no alarm icon - which is right for a repo that flapped once. Applied to THIS
  state, where nothing has ever been known, the same rule rendered a clean "Up to date" on a box
  that cannot check for updates at all. state-never.json does not catch it: there the flatpak
  backend still answers, so items exist. The distinction the widget now draws - has it ever
  succeeded, does it know anything - is only testable against a capture that has neither.

- **state-schema-v0.json** - **derived**, `jq 'del(.risky_pending)'` over state-live.json,
  re-derived with it at every re-capture so the two always share a timestamp. Stands
  in for a state file written before Task 13.5 added that additive key: schema-1 readers must
  tolerate its absence, and there is no way to make today's CLI emit one.
- **state-empty.json** (zero bytes) and **state-garbage.json** (a truncated document,
  `{"schema": 1, "last_check": "2026-08-2`) - **hand-written**, because no CLI can produce them:
  the first is the "empty stdout, exit 0" case the state schema defines as "no data, keep the
  last known state" (never "zero updates"), and the second is what a write killed halfway leaves
  behind. Both must parse to null and neither may throw.
