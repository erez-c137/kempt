# Fixture provenance

Captured / written 2026-08-24 on this box (Fedora 44, dnf5 5.4, flatpak 1.18). The box was
fully up to date at capture time, so the dnf5/flatpak "pending updates" commands returned no
real output to capture live - see each entry below for how that was handled. Fixture files
themselves stay byte-faithful to real tool output (no in-band `# HAND-WRITTEN SAMPLE` marker
lines); this file is the source of truth for what's genuinely captured vs. hand-written.

## tests/fixtures/dnf-check-update.txt
**Hand-written.** `LC_ALL=C dnf5 --cacheonly check-update --quiet` returned empty (box fully
up to date, verified live 2026-08-24) - there was no real "pending update" output to capture.
6 rows hand-written in the documented `name.arch  evr  repo` format, using real package names
and real current installed EVRs from this box (bash, curl, git-core, tar, vim-minimal,
aajohan-comfortaa-fonts), each bumped to a plausible newer EVR. Guard rows added on top:
- `brandnew.x86_64` (EVR `1.0-1.fc44`) - a package name deliberately absent from
  rpm-installed.tsv, so a parser whose join-miss guard (e.g. `join -e '?'`) gets deleted fails
  instead of silently passing.
- `bash.i686` at EVR `5.3.9-4.fc44` - a multilib twin of `bash.x86_64` (`5.3.10-1.fc44`) at a
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
- An **obsoletes section** - the literal header line `Obsoleting Packages` followed by one row
  indented by four spaces (`    old-tool.x86_64`) carrying a normal EVR and repo in the usual
  columns. Format is dnf5's own: after the pending-update table it appends this header and
  lists obsoleted packages **indented**, so indentation at column 0 is the ONLY structural
  signal separating them from real update rows (their name/EVR/repo columns are otherwise
  indistinguishable). An obsoleted package is being REMOVED, not upgraded - reporting it as
  pending invents a phantom self-update (`old-tool: ? → 1.0-1.fc44`) for something the user is
  losing. The parser's `/^[^[:space:]]/` column-0 anchor kills the indented row and the
  `NF>=3` + EVR-shape guards kill the bare header; if either is deleted the item count goes
  to 8 and the test fails.

## tests/fixtures/rpm-installed.tsv
**Captured-live**, 2026-08-24, via
`LC_ALL=C rpm -qa --queryformat '%{NAME}\t%{EVR}\n' | sort` against this box's real installed
package database, filtered to the names referenced above plus 3 extra real rows for realism
(per the plan's Task 2 Step 1 command). Every EVR in this file is a genuine currently-installed
version - nothing here is invented. `brandnew` was deliberately NOT added (see guard row
above - that's the point of the guard).

**Scope note (v1 decision):** Kempt v1 handles **system-scope flatpaks only**, so the backend's
real commands carry `--system` (`flatpak remote-ls --updates --system --app …` and
`flatpak list --system --app …`). These fixtures were captured without `--system` on a box where
the one installed app is system-scope, so their content is identical either way; the flag is a
contract between every command in `backends/flatpak.sh`, the update included, so an app the badge
counts is an app the run acts on. A per-user app must therefore never appear in a check result. Re-capture
with `--system` if this box ever gains per-user apps.

## tests/fixtures/flatpak-remote-ls.txt
**Hand-written.** `LC_ALL=C flatpak remote-ls --updates --app --columns=application,version`
failed live twice (Flathub summary fetch timed out, ~2 min each, 2026-08-24) - there was no
real pending-update output to capture even setting the network issue aside (only one flatpak
app is installed on this box). 3 rows hand-written, TAB-separated:
- `net.mkiol.SpeechNote` - the one real app installed on this box - bumped from its real
  installed 4.8.4 to a plausible 4.8.5.
- `org.gimp.GIMP` - bumped from an invented-installed 3.0.2 to 3.0.4 - added purely for 2-app
  parser coverage. GIMP is not installed on this box (see flatpak-list.tsv note below).
- `com.example.NotInstalled` at version 9.9 - deliberately absent from flatpak-list.tsv, the
  same missing-from-installed guard as `brandnew.x86_64` above.

## tests/fixtures/flatpak-list.tsv
**Mixed.** Base row (`net.mkiol.SpeechNote  4.8.4`) is captured-live, 2026-08-24, via
`LC_ALL=C flatpak list --app --columns=application,version | sort` - the only flatpak app
actually installed on this box. One row added on top, hand-written: `org.gimp.GIMP  3.0.2`  - 
invented (GIMP is not installed here); added so flatpak-remote-ls.txt's GIMP entry has a
matching older-version row to join against, exercising the 2-app case. `com.example.NotInstalled`
was deliberately NOT added here (see guard row above - that's the point of the guard).

## tests/fixtures/snap-multiver-raw.tsv
**Hand-written**, 2026-08-24, but modeled directly on this box's real installonly duplication
(measured live: `rpm -qa` returns 2516 rows for only 2492 distinct names - `gpg-pubkey` ×13 and
six `kernel*` families ×3 each). Fedora keeps several versions of *installonly* packages
installed at once, so a raw `name\tEVR` snapshot legitimately repeats names.

That raw shape is POISON for `join`: duplicate names on both sides produce a CROSS PRODUCT, and
a self-diff of this box's real package list yielded **192 phantom "updated" rows** - a report
claiming 192 upgrades where nothing changed at all. Hence the two-part contract this fixture
guards:
- Producers (snapshot/lookup functions) pipe through `collapse_versions`, giving ONE row per
  name with the versions comma-joined in input order.
- `tsv_diff_updates` REJECTS duplicate-name input outright (exit 65) rather than silently
  emitting fiction.

6 rows: `gpg-pubkey` ×2 (short hex-ish keyids, the real format), `kernel-core` ×3 (consecutive
kernel builds, the everyday case), and `zsh` ×1 as a single-version control that must survive
collapsing untouched. Deliberately kept in RAW (uncollapsed) form - that is the entire point.

## tests/fixtures/snap-before.tsv / tests/fixtures/snap-after.tsv
**Hand-written**, per the plan's literal Task 2 Step 3 content - not live-captured; these exist
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
- **state-reboot-needed.json** - **derived**, `jq '. + {reboot_needed: true}'` over
  state-live.json, so the two are identical field for field apart from that one key (and it lands
  in the position `assemble_state` really writes it, last). Derived rather than captured on
  purpose: the test it guards asserts that the whole view model comes out UNCHANGED, which only
  means anything if the pair differs by nothing else - a fresh capture would differ by its
  timestamps as well, and the assertion would have to be weakened to survive it. Re-derive it
  from state-live.json at every re-capture, the same way state-schema-v0.json is re-derived.

  It stands in for a state written by a build that records whether a restart is owed right now.
  Every CAPTURED fixture above predates that key, which is what proves the additive-key rule from
  the absence side: a state without it reads as "nothing to say" rather than as an error.

  The restart message ships now and consumes it, so the fixture's job is no longer to prove that
  nothing reads it. It is the state the restart assertions are driven from - `probe_popup.py`
  points the stubbed CLI at it to put the message on screen, then switches `restart_reminder`
  off, then closes the message, and checks each time that the fact moves into the footer's
  `restart pending` rather than disappearing. Paired with state-live.json it is also still the
  controlled experiment it was built as: `tests/test_widget_logic.sh` compares the two whole view
  models with `rebootNeeded` and `restartMessageVisible` deleted and requires them identical, so
  the key is held to moving the restart surfaces and nothing else.

- **state-empty.json** (zero bytes) and **state-garbage.json** (a truncated document,
  `{"schema": 1, "last_check": "2026-08-2`) - **hand-written**, because no CLI can produce them:
  the first is the "empty stdout, exit 0" case the state schema defines as "no data, keep the
  last known state" (never "zero updates"), and the second is what a write killed halfway leaves
  behind. Both must parse to null and neither may throw.

## tests/fixtures/run-last.json (widget: `kempt summary --json`, one history entry)

**Captured live 2026-08-26**, by running the real `bin/kempt update` and then
`bin/kempt summary --json` in a throwaway sandbox built the way `tests/test_update.sh` builds
one: a fresh `HOME`/`KEMPT_CONFIG_DIR`/`KEMPT_STATE_DIR` under a tmpdir, `KEMPT_PKEXEC=""`,
`KEMPT_SKIP_REFRESH=1`, a refresh helper that cats `dnf-check-update.txt` and exits 100, an
apply helper that "upgrades" by swapping `snap-before.tsv` for `snap-after.tsv`, and a
`KEMPT_DNF_CMD` stub in the rc-1-plus-a-package-list shape that means a restart is owed. Written
by `cmd_update` itself, so the field names, the nesting and the shapes of updated/added/removed
are the CLI's own, not a hand-made approximation of them - which is the entire point, since what
the popup consumes is that output and nothing else. Re-capture by re-running the CLI the same
way; never by editing the JSON.

What it carries, and why each part is in it:

- **2 updated, 1 added, 1 removed** (`kernel-core`, `vim-common`; `newpkg`; `zsh`). The counts
  differ from each other on purpose: a popup that counted only upgrades would announce
  "Updated 2 packages" after a transaction that also installed one and removed one, which is the
  front-end disagreeing with the CLI's own `run_counts_phrase`. The widget's contract is
  `changedCount == 4`.
- **`duration_sec: 2`** - real, not edited in. The apply stub sleeps, so the CLI measured a
  duration it could put in the entry; a stub that does no work records `0`, and a post-run line
  reading "in 0s" would have pinned nothing about the seconds ever arriving.
- **`reboot_needed: true`** - a fact about THAT RUN, which the widget must not render as a fact
  about now (the state file's own `reboot_needed` is the live answer). The fixture exists partly
  so that rule has something to be tested against.
- **A log path under `/tmp/kempt-capture.*`** that no longer exists. Deliberately left as
  captured: it is what a real entry's `log` field looks like, and nothing in the widget may
  assume a shape for it. `tests/qml/probe_popup.py` reads the path OUT of this file rather than
  repeating it, and hands it to a stubbed `xdg-open`.

Guards: `main.qml`'s `loadLastRun()` (the popup's Last update row and its post-run line come from
`kempt summary --json` through `Logic.lastRunOf`, never from the human `kempt summary`, whose
first line is an ISO timestamp), and `showLog()` passing a path from the CLI's JSON back to a
command line as exactly one argument.

### Three states with no file of their own

`tests/qml/probe_popup.py` builds three more situations in-process, from the captures above,
rather than adding files here. Recorded so their provenance is not lost with the sandbox they are
written into:

- **Up to date**, and **up to date with a restart owed** - `uptodate_from()` loads a named real
  capture (state-live.json and state-reboot-needed.json respectively), empties every backend's
  `items`, zeroes that backend's own `actionable` and `held` and the two top-level totals, and
  writes the result into the probe's sandbox. Derived
  rather than captured because the shape has to be the shipped document's shape: an up-to-date
  file written by hand would be free to drift away from what `assemble_state` actually emits, and
  the whole point of these two is that the popup's empty state and its restart message are being
  driven by a real state file with nothing left in it.
- **A run that failed** - the same file copies run-last.json and flips `status` to `failed` and
  `error` to a dnf5 message. Two fields, on the real captured entry, so the counts, the log path
  and the timestamps stay exactly as the CLI wrote them: what is under test is that a failure is
  reported as a failure whatever the counts say, and a hand-made failed entry could not show that
  because its counts would be invented too. The same trick with `log` emptied covers a history
  entry too old, or too damaged, to have a log to show.

## tests/fixtures/dnf-repoquery-sizes.tsv
**Hand-written in the captured format, with real sizes.** Format is the one `dnf_sizes` asks
for, `name<TAB>arch<TAB>evr<TAB>downloadsize`. The `downloadsize` values are the REAL figures this
box reported on 2026-08-27 via

```bash
dnf5 -C repoquery --qf $'%{name}\t%{arch}\t%{evr}\t%{downloadsize}\n' --latest-limit 1 \
  bash curl git-core tar vim-minimal aajohan-comfortaa-fonts glibc
```

The EVRs are the ones already in `dnf-check-update.txt`, so the two fixtures describe one
consistent pending set; the sizes are real, the EVRs they are paired with are that file's
hand-written bumps. Three deliberate properties:

- **`glibc` x86_64 2483277 + i686 2282613.** The live multilib pair on this box, and the only
  rows here with no matching item in `dnf-check-update.txt`. They exercise the per-name sum
  (4765890) on real data, and prove a size row for a package that is not pending is harmless.
- **`bash` on two arches**, matching that file's deliberately divergent multilib twin. The
  x86_64 size (1985877) is real; the i686 one (2019340) is HAND-WRITTEN, because this box's
  repos carry no `bash.i686` to capture. It is what makes the summed figure reach an actual
  item: bash's `size_bytes` is 4005217, not 1985877.
- **No row for `brandnew`**, which is pending in `dnf-check-update.txt`. That absence is what
  fires the coverage guard, so `backends.dnf.download_bytes` is omitted until it is held.

`%{download_size}` is NOT a tag: dnf5 echoes it back literally. The tags are `downloadsize` and
`installsize` (`dnf5 repoquery --querytags`), and tabs need `$'...'` quoting.

## tests/fixtures/flatpak-remote-ls-sizes.tsv
**Captured size strings on hand-written rows.** The app ids and versions match
`flatpak-remote-ls.txt` so both fixtures describe one pending set; the size column carries real
strings captured from flathub on 2026-08-27:

```bash
flatpak remote-ls flathub --system --app --cached --columns=application,version,download-size
```

The separator between number and unit is the point of this fixture, and it is **not the same for
every unit**. Verified with `cat -A` (`^I` is TAB, `M-BM- ` is the two bytes of U+00A0 NO-BREAK
SPACE):

```
net.mkiol.SpeechNote^I4.8.5^I1.2M-BM- GB$
org.gimp.GIMP^I3.0.4^I99.7M-BM- MB$
com.example.NotInstalled^I9.9^I847 bytes$
org.example.NoSize^I1.0^I$
org.example.Unknown^I2.0^I?$
```

kB, MB and GB use U+00A0; `bytes` uses an ORDINARY space. A fixture written with ordinary spaces
throughout would pass a parser that cannot read a single real flathub row, which is why
`tests/test_flatpak.sh` also asserts the file contains exactly two U+00A0 bytes. Units across all
3474 flathub apps on this box: 3106 MB, 331 kB, 34 GB, 3 bytes - SI decimal with a lowercase k,
matching `g_format_size`.

The last two rows are hand-written guards: an **empty** size column and a literal **`?`**, both of
which must yield no size row at all rather than a zero, so "not known" stays distinguishable from
"free".

## tests/fixtures/offline-download-complete.toml
**Captured live**, 2026-09-02, from `/usr/lib/sysimage/libdnf5/offline/offline-transaction-state.toml`
on this box - byte for byte, cookie and all. It is a real stuck stage: 61 packages
staged on 2026-09-01 by a Kempt build that downloaded them and never armed the transaction, so
`status` is still `download-complete`, `/system-update` was never created, and no number of
restarts could ever install it. That file is the bug this fixture exists to keep fixed.

Two structural details the parser depends on, and neither is a guess - they are what dnf5 wrote:
the table header is `[offline-transaction-state]` (not `[state]`), and the keys are written at
column 0, unindented. `status` is one key among eleven and is not the first, so a reader that took
the first quoted value in the file would answer `rpmdb_cookie`.

## tests/fixtures/offline-ready.toml
The same file with `status` set to `ready` - the one line `dnf5 offline reboot` changes when it
arms a transaction (verified in a Fedora 44 container, 2026-09-02: arming rewrites the status and
creates `/system-update`, and with `DNF_SYSTEM_UPGRADE_NO_REBOOT=1` it does not reboot). Nothing
else in the file moves, which is why this fixture is a one-line edit of the captured one rather
than a second capture.

This is also the suite's DEFAULT: `sandbox()` points `KEMPT_OFFLINE_TOML` here, so the world every
test runs in is "if a stage exists, it is armed". That is the world the offline tests in
`test_update.sh` assume - a marker they wrote means an install is genuinely pending - and pinning
it is what keeps them off the real `/usr/lib/sysimage/libdnf5/offline/` of whatever box runs the
suite, where a leftover stage (or none) would decide how the reconciliation branches behave.

## tests/fixtures/offline-transaction-full.json
**Captured live**, 2026-09-05, from `/usr/lib/sysimage/libdnf5/offline/transaction.json` in a
Fedora 44 container running dnf5 5.4.3.0 - byte for byte, package paths and all. Produced by
`dnf5 -y -q upgrade --offline ca-certificates librepo openldap` followed by
`DNF_SYSTEM_UPGRADE_NO_REBOOT=1 dnf5 -y -q offline reboot`, so the transaction it records is a
real armed stage rather than a hand-built one. The matching
`offline-transaction-state.toml` was captured alongside it (`status = "ready"`, the `cmd_line`
above recorded verbatim, `rpmdb_cookie` present) and is not shipped: nothing reads those keys, and
`offline-ready.toml` is already the suite's toml pin.

Three structural details the parser depends on, none of them guesses:

- **Every upgraded package appears twice.** The incoming build carries `"action":"Upgrade"` and a
  `package_path`; the outgoing one carries `"action":"Replaced"` and `"repo_id":"@System"` with no
  path. Reading both sides would report a package the transaction REMOVES as one it installs.
- **`ca-certificates` is a hyphenated name**, and it is the reason the name cannot be taken as
  "up to the first `-`". Every kernel package a user would think of holding has the same shape.
- **`"version":"1.0"`** is dnf5's own format stamp on the file, which is what the parser's
  1.x check reads. These fixtures happen to carry no epoch; `name-1:ver-rel.arch` is the shape the
  synthetic nevras in `tests/test_offline_txjson.sh` cover instead.

This is also the suite's DEFAULT: `sandbox()` points `KEMPT_OFFLINE_TXJSON` here, so the world every
test runs in is "the staged transaction contains ca-certificates, librepo and openldap". A test that
writes a marker and holds one of those three sees a conflict warning by design.

## tests/fixtures/offline-transaction-excluded.json
**Captured live**, same container and session, 2026-09-05: the same three packages re-staged as
`dnf5 -y -q upgrade --offline --exclude=librepo ca-certificates openldap` and armed the same way.
`librepo` is ABSENT from `rpms` - both its incoming and its outgoing entry - which is what a hold
does to a transaction Kempt builds, and it is the fixture that lets a test assert the difference
between "this package is in the staged set" and "this package is not" against real dnf5 output
rather than an edit of it. The `--exclude` is recorded in the matching toml's `cmd_line`, which is
how the re-stage is known to be the one described here.
