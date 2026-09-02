# Offline updates must actually install on restart

Status: DONE (2026-09-02). Branch `feat/offline-arming` off `build/cli-v1` (853f250).

## The bug (proven live, 2026-09-01/02)

"Install on Next Restart" stages the transaction and stops. `dnf5 upgrade --offline` only
downloads and stores it (`status = "download-complete"` in
`/usr/lib/sysimage/libdnf5/offline/offline-transaction-state.toml`). Nothing applies it at boot
until `dnf5 offline reboot` ARMS it: flips status to `"ready"` and creates the `/system-update`
symlink that systemd's system-update-generator looks for. Kempt never arms, so a staged update
never installs - on any number of reboots.

Founder's box, 2026-09-01: staged 61 packages at 10:31, saw nothing change, staged again at
10:36, gave up and ran the terminal surface at 10:36:42 (applied all 61 live), rebooted 10:39.
The stale unarmed stage is still sitting in `/usr/lib/sysimage/libdnf5/offline/` and Kempt's
`offline_staged.json` marker is stuck forever: the live run rebased its baseline, so the
post-reboot harvest sees "nothing changed since" and keeps waiting for an apply that can never
come.

Container proof (podman, `registry.fedoraproject.org/fedora:44`, 2026-09-02):

```
dnf5 install --offline -y tree            → status = "download-complete", no /system-update
DNF_SYSTEM_UPGRADE_NO_REBOOT=1 dnf5 offline reboot -y
                                          → rc=0, status = "ready",
                                            /system-update -> /usr/lib/sysimage/libdnf5/offline,
                                            no reboot attempted
dnf5 offline clean -y                     → symlink removed, offline dir emptied
```

`DNF_SYSTEM_UPGRADE_NO_REBOOT` is documented in dnf5-offline(8): "If set, the system won't be
rebooted or powered off by DNF5 when the normal work flow would do so." That is the supported
arm-without-reboot path.

## Design decisions (settled, do not relitigate)

- **Arm at stage time**, not at restart-click. The button says "Install on Next Restart": once
  pressed, ANY restart (button, K-menu, terminal `reboot`) installs. One pkexec flow covers
  stage+arm (`auth_admin_keep` holds the authorization for the arm call made seconds later).
- **A live dnf run supersedes a pending stage.** A staged transaction records an
  `rpmdb_cookie`; any rpmdb change invalidates it and `dnf5 offline _execute` will refuse it at
  boot (an ARMED stale stage = a failed offline-update boot attempt). So after a live run that
  changed the rpm set, drop the stage (`dnf-offline-clean`) instead of keeping it. A run that
  did not touch rpmdb (flatpak-only delta) leaves the stage valid and pending.
- **Third-party rpm changes** (user runs `dnf install foo` themselves while a stage is armed)
  are NOT chased: dnf5 refuses the stale transaction at boot and the cleanup service boots the
  system normally. Document, accept.
- The staged set still shows as pending in `kempt check` (repoquery still sees the packages) -
  correct and unchanged. The popup gets a staged message on top instead of pretending they are
  gone.

## Tasks (TDD; run `tests/run_tests.sh` and commit after EACH task)

### T1 - kempt-apply: two argument-less verbs
- `dnf-offline-arm` → `run env DNF_SYSTEM_UPGRADE_NO_REBOOT=1 dnf5 offline reboot -y`
  (via `env` so `KEMPT_APPLY_ECHO=1` prints the env var too and the test pins it).
- `dnf-offline-clean` → `run dnf5 offline clean -y`.
- Both REJECT any extra argument (exit 2, like the existing validation posture). Update the
  usage line.
- Tests (echo mode, alongside the existing helper tests in `tests/test_helpers.sh` or wherever
  kempt-apply echo tests live): exact command line for each verb; extra arg → exit 2.

### T2 - cmd_run offline path: stage, then arm
- After a successful `dnf-offline-stage`, immediately `priv_apply dnf-offline-arm` through the
  same `apply_with_retry` logging.
- Arm failure → the run FAILS: `status=failed`, reason wording like
  `staged but could not arm the restart install`; best-effort
  `priv_apply dnf-offline-clean` to unwind (its own failure is a warning, never fatal);
  do NOT write the offline marker; the existing failure notification/event paths carry it.
- Arm success → write the marker as today PLUS `staged: <N>` (the same actionable count the
  `offline staged N` event line already uses) and `armed: true`.
- Tests (pkexec-stub recording pattern from `tests/test_update.sh`): offline run records
  stage THEN arm; stub that fails the arm verb → clean recorded, marker absent, rc=1,
  reason in the event line.

### T3 - live run supersedes a pending stage
- In the non-offline branch of cmd_run, after the dnf apply: if the marker exists AND
  `dnf_status == ok` AND `dnf-before.tsv` differs from `dnf-after.tsv` (rpmdb moved → the
  staged cookie is dead): `priv_apply dnf-offline-clean`; on success remove the marker and its
  `pre_snapshot` copy and `log_event "offline stage dropped (superseded by live update)"`; on
  failure keep the marker and warn (doctor's stale check, T6, will surface it).
- Keep the existing rebase block for the no-rpm-delta case (flatpak-only run: stage still
  valid). REWRITE the big comment at the top of that region (currently "A PENDING offline
  stage has to survive a live run") to describe the real lifecycle: stage+arm → any reboot
  applies → harvested; a live rpm change kills the stage, so it is dropped, not kept.
- Tests: live run with marker + rpm delta → clean called, marker gone, event logged; live run
  with marker + no rpm delta → marker survives, no clean call.

### T4 - check-time reconciliation + `offline_staged` in state.json
- New seam `KEMPT_OFFLINE_TOML`, default
  `/usr/lib/sysimage/libdnf5/offline/offline-transaction-state.toml` (world-readable 0644 on
  Fedora - verified). Helper `offline_system_status()` → `ready` / `download-complete` /
  `absent` / the raw status string; parse with grep/sed (`^status = "..."`), no toml parser;
  unreadable or missing file → `absent`.
- harvest_offline grows reconciliation (it owns the marker lifecycle):
  - marker + toml ABSENT + same boot as marker → stage vanished without a boot (manual
    `dnf5 offline clean`, or a supersede whose marker removal failed) → clear marker,
    `log_event "offline marker cleared (stage gone)"`.
  - marker + toml ABSENT + different boot + snapshots EQUAL → today this hits the
    "cmp equal → still pending" dead end forever; with the toml gone there is nothing left to
    wait for → clear marker, same event. (Toml PRESENT + cmp equal stays "still pending".)
  - The existing applied-harvest path is unchanged (boot differs + snapshot differs).
- assemble_state: new optional `offline_staged` object -
  `{staged_at, count, armed: true}` - present ONLY when the marker exists AND toml status is
  `ready`. Additive key, schema stays 1, absent otherwise (including the unarmed-stale case).
  `count` from the marker's `staged` field; a legacy marker without it → `count: null`.
- `kempt summary`: when present, one line: `Staged: N updates install on the next restart`
  (count null → `Staged: updates install on the next restart`). `summary --json` flows the key
  automatically via state.json - add an assertion anyway.
- Tests: toml fixtures via the seam; matrix over marker × toml status for state key
  presence/shape; harvest reconciliation branches; summary lines.

### T5 - widget: staged message, no double-stage
- logic.js viewModel additions:
  - `stagedMessage`: `"N updates are staged - they install on the next restart"` (count null →
    `"Updates are staged - they install on the next restart"`); empty string when not staged
    or state unusable. COPY table entries; sentence case, no em dashes (spaced hyphen).
  - `stagedShowRestart`: staged && NOT restartMessageVisible (never two Restart… buttons in
    one popup; the restart Warning's own button already covers the both-true case).
  - While staged: `riskyMessage` returns "" (the stage offer must not render - that is the
    exact double-press the founder hit).
- FullRepresentation.qml: one new `Kirigami.InlineMessage`, `Kirigami.MessageType.Positive`,
  between restartMessage and riskyMessage; text `vm.stagedMessage`; visible on non-empty (same
  pattern as riskyMessage); `actions` carries a `Restart…` `Kirigami.Action` (triggers
  `popup.plasmoidItem.promptRestart()`) only when `vm.stagedShowRestart` - follow the
  conditional-action pattern already used in this file. Mind the Accessible.* conventions the
  other messages follow.
- Tests: node tests for the viewModel matrix (staged only / staged+reboot-needed /
  staged+risky / count null / unusable state); extend the popup probe fixture set with a
  staged state and assert the message renders and riskyMessage does not.

### T6 - doctor: staged/stale visibility
- Reading marker + toml (same seam):
  - marker + toml `ready` → `ok`/info line: staged update pending, N packages install on the
    next restart.
  - marker + toml `download-complete` → WARN: this stage was created before Kempt armed
    restarts and can never install - `sudo dnf5 offline clean` clears it. (This is the
    founder's box today; the wording must contain that exact command.)
  - toml present + NO marker → info: an offline transaction is staged outside Kempt
    (`dnf5 offline status`).
- Tests: doctor fixtures for the three rows.

### T7 - docs, man, changelog
- `docs/usage.md`: offline surface = stage + arm; any restart installs; a live update
  supersedes a pending stage; what the popup shows.
- `docs/architecture.md`: offline lifecycle: staged→armed→applied on boot→harvested;
  supersede; reconciliation; the marker/toml split (who owns what).
- `docs/security.md`: the two new argument-less verbs under the same
  `io.github.erez_c137.kempt.apply` polkit action; why arm is safe (execs dnf5 only, no
  arguments accepted).
- man page: offline surface behavior + doctor lines.
- CHANGELOG: the headline is the bug - staged updates never installed on restart; then the
  staged-state visibility, the supersede rule, doctor's stale detection. Update suite counts
  to MEASURED numbers only.
- Tick the boxes in this file.

## Constraints
- Comment style of the repo: constraints and reasons the code can't show, never narration.
- No AI attribution of any kind in commit messages.
- Suite must be green after every task; `tests/run_tests.sh` is the runner.
- No pkexec/root calls in tests; the sandbox pattern (`KEMPT_PKEXEC=""` + stubs) covers
  everything. The real-system proof is founder-gated and listed in the release gate, but the
  dnf5 semantics are already container-proven above.
- After merge, `./install.sh` must be re-run (kempt-apply changed) - doctor's install-skew
  check will say so on its own; note it in the changelog entry.

## Task checklist
- [x] T1 kempt-apply verbs
- [x] T2 stage-then-arm
- [x] T3 live-run supersede
- [x] T4 reconciliation + state key
- [x] T5 widget staged message
- [x] T6 doctor rows
- [x] T7 docs + changelog

## What actually shipped, where it differs from the plan above

- The offline path lives in `cmd_update`, not `cmd_run` (`cmd_run` is the launcher that starts it).
- **T3 gained a third condition the plan did not state: the stage must still be PENDING.** The
  plan's supersede rule was marker + `dnf_status == ok` + rpm delta, which would also have fired on
  a marker whose transaction had ALREADY applied at a restart and was still waiting to be
  harvested - throwing away the one history entry that reports what that restart installed. The
  supersede therefore sits inside the existing "still pending" branch (the marker's baseline still
  matches the world this run started from). "Supersedes a PENDING stage" is what the design
  decision says; an already-applied stage is not pending.
- **T4: `summary --json` does NOT carry `offline_staged`,** contrary to the plan's note. That
  command prints one run's HISTORY ENTRY verbatim; it never reads state.json. A staged transaction
  belongs to the box rather than to any past run, so the key flows through `kempt check` /
  state.json, which is what the widget reads. Asserted in that direction instead.
- **T6 uses `FAIL`, not a new `WARN` level.** Doctor's line vocabulary is `ok` / `info` / `FAIL`
  and only `FAIL` moves the exit code. An unarmed stage is a real defect with an exact remedy, so
  a report ending "all checks passed" above it would contradict itself. A fourth level would have
  been a grammar change the plan did not ask for.
- **T6 has a fourth row the plan did not list:** marker present, transaction absent. Without it
  doctor is silent about a marker it can see is orphaned. It is `info`, not `FAIL` - the next
  check clears it and there is nothing for anyone to do.
- `tests/lib.sh` PINS `KEMPT_OFFLINE_TOML` at a `ready` fixture rather than poisoning it like the
  other seams. Unset, the suite would read the real `/usr/lib/sysimage/libdnf5/offline/` of
  whatever box runs it; pointed at nothing, "no transaction" is the answer, and a marker with no
  transaction is exactly the case the check CLEARS - which would have deleted the marker out from
  under every staging test in `test_update.sh`.
- The two toml fixtures are a live capture of the founder's own stuck stage (2026-09-02) plus a
  one-line edit of it. Provenance in `tests/fixtures/MANIFEST.md`.

## Not fixed, noticed while here

- `"1 updates are staged"` and `Staged: 1 updates install on the next restart` do not read well.
  The strings are the plan's, and the CLI and the widget say the same thing; pluralization is a
  wider job (`logic.js` says the widget has no message-format layer and that building one is its
  own release), so it was left alone rather than fixed in one of the two places.
