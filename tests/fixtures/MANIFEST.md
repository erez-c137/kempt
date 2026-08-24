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
aajohan-comfortaa-fonts), each bumped to a plausible newer EVR. 2 guard rows added on top:
- `brandnew.x86_64` (EVR `1.0-1.fc44`) — a package name deliberately absent from
  rpm-installed.tsv, so a parser whose join-miss guard (e.g. `join -e '?'`) gets deleted fails
  instead of silently passing.
- `bash.i686` — a duplicate of the existing `bash.x86_64` row (same EVR, same repo, only the
  arch differs) — a multilib-collapse case: two arches of the same source package. Collapsing
  the pair into a single `bash` entry is the CORRECT behavior (contract: these 8 data lines
  parse to 7 items, not 8), so this row catches a parser that FAILS to collapse multilib twins
  and double-counts `bash`.

## tests/fixtures/rpm-installed.tsv
**Captured-live**, 2026-08-24, via
`LC_ALL=C rpm -qa --queryformat '%{NAME}\t%{EVR}\n' | sort` against this box's real installed
package database, filtered to the names referenced above plus 3 extra real rows for realism
(per the plan's Task 2 Step 1 command). Every EVR in this file is a genuine currently-installed
version — nothing here is invented. `brandnew` was deliberately NOT added (see guard row
above — that's the point of the guard).

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

## tests/fixtures/snap-before.tsv / tests/fixtures/snap-after.tsv
**Hand-written**, per the plan's literal Task 2 Step 3 content — not live-captured; these exist
purely to give `tsv_diff_updates` a deterministic before/after pair. No comment-marker line:
both files are consumed directly by `join`, which requires every line to be a real TSV data
row, so a leading `#` line would break the diff instead of being skipped. Encodes: one
unchanged package (bash), two upgraded (kernel-core, vim-common), one removed (zsh), one added
(newpkg).
