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
  the merged entry carries both versions comma-joined (`5.3.10-1.fc44,5.3.9-4.fc44`, sorted
  order) exactly like the installonly sets in snap-multiver-raw.tsv.
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

**Scope note (v1 decision):** Upkeep v1 handles **system-scope flatpaks only**, so the backend's
real commands carry `--system` (`flatpak remote-ls --updates --system --app …` and
`flatpak list --system --app …`). These fixtures were captured without `--system` on a box where
the one installed app is system-scope, so their content is identical either way; the flag is a
cross-boundary contract with `libexec/upkeep-apply`, which validates app ids against
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
