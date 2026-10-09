#!/usr/bin/env bash
# Kempt shared library. Pure helpers + path setup. Sourced by bin/kempt, backends, tests.
set -euo pipefail
# C.UTF-8, not C: byte-identical collation for sort/join (verified) while leaving UTF-8 bytes
# intact in logs and package summaries instead of mangling them.
export LC_ALL=C.UTF-8

# Package/app name shape, doing two different jobs on the two sides of the tree. For dnf names it
# MIRRORS the root helper's own validation, so a hold is rejected HERE, at hold time, and a bad
# name can never reach the privileged apply path. For flatpak app ids it mirrors nothing - the
# apply does not cross the privilege boundary (backends/flatpak.sh, KEMPT_FLATPAK_UPDATE_CMD) - so
# it is the ONLY validation those ids get, which is what makes the anchor on the first character
# load-bearing rather than tidy: it stops an id out of a remote's summary, such as
# `--installation=other`, from reaching flatpak as an OPTION instead of an app.
KEMPT_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._+-]*$'

# Test/power-user seam for the session-critical pattern. EMPTY means "use the risky_regex config
# key" (whose default lives in kempt_default) - the env var still wins when set.
KEMPT_RISKY_RE="${KEMPT_RISKY_RE:-}"

# Test/power-user seam for the boot session (see current_boot_id). EMPTY means "read procfs".
KEMPT_BOOT_ID="${KEMPT_BOOT_ID:-}"

# The checkout this code was loaded from - the library's own copy of the path bin/kempt computes
# for its `source` lines, so kempt_version needs no caller to hand it one. A seam so a test can
# point it at a tree with no VERSION file without moving the real one.
KEMPT_ROOT="${KEMPT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# WHICH seams arrived from the environment, recorded before the defaults below erase the
# difference. Three of them decide what actually runs as root; set on a real box they make
# `kempt update` a no-op that reports success, so `kempt doctor` reads this and refuses to certify
# a box whose update path has been pointed somewhere else. compgen -e, not the whole variable
# list: only an EXPORTED value can have come from outside this process.
# shellcheck disable=SC2034  # read by cmd_doctor in bin/kempt, which sources this through a runtime $ROOT
KEMPT_ENV_OVERRIDES="$(compgen -e 2>/dev/null | grep '^KEMPT_' | sort | tr '\n' ' ' || true)"

KEMPT_CONFIG_DIR="${KEMPT_CONFIG_DIR:-$HOME/.config/kempt}"
KEMPT_STATE_DIR="${KEMPT_STATE_DIR:-$HOME/.local/state/kempt}"
KEMPT_PKEXEC="${KEMPT_PKEXEC-pkexec}"
# The polkit-annotated helper paths. `exec.path` in polkit/io.github.erez_c137.kempt.policy pins these, so
# they are the only paths root ever runs; the seams below point elsewhere in tests, and `kempt
# doctor` compares the two because a root-ownership check on a test stub proves nothing about the
# install. Seams themselves so a test can point BOTH at one file and reach doctor's ownership
# branches. Nothing execs these; they are only ever compared against the helper seams.
KEMPT_REFRESH_HELPER_PATH="${KEMPT_REFRESH_HELPER_PATH:-/usr/local/libexec/kempt-refresh}"
KEMPT_APPLY_HELPER_PATH="${KEMPT_APPLY_HELPER_PATH:-/usr/local/libexec/kempt-apply}"
KEMPT_REFRESH_HELPER="${KEMPT_REFRESH_HELPER:-$KEMPT_REFRESH_HELPER_PATH}"
KEMPT_APPLY_HELPER="${KEMPT_APPLY_HELPER:-$KEMPT_APPLY_HELPER_PATH}"
# Where install.sh puts the two polkit actions. A seam so `kempt doctor` can be tested without
# writing to /usr/share.
KEMPT_POLICY_FILE="${KEMPT_POLICY_FILE:-/usr/share/polkit-1/actions/io.github.erez_c137.kempt.policy}"
# Where kpackagetool6 puts the panel widget for the current user - the same path install.sh names
# as PLASMOID_DIR. Nothing here installs or runs it; `kempt doctor` reads it, and asks two
# different questions of the one directory: in a checkout, whether the copy still matches the tree
# it came from; in a package, whether it exists at all, because there it is a store install
# shadowing the packaged widget. ONE variable for one directory - two would drift, and doctor would
# report on two different paths. The seam drives either question from a staged tree.
KEMPT_PLASMOID_DIR="${KEMPT_PLASMOID_DIR:-$HOME/.local/share/plasma/plasmoids/io.github.erez_c137.kempt}"
# Where the PACKAGE puts the widget, as opposed to the user-scope directory above. Read by doctor
# only, and only to tell a packaged install that the panel half is a separate package.
KEMPT_SYSTEM_PLASMOID_DIR="${KEMPT_SYSTEM_PLASMOID_DIR:-/usr/share/plasma/plasmoids/io.github.erez_c137.kempt}"
# The PATH the panel widget's own command line builds. plasmoid/contents/ui/main.qml runs the CLI
# as `PATH="$HOME/.local/bin:$PATH" KEMPT_VIA=widget kempt`, so ~/.local/bin wins for the widget
# alone - which is how a stale developer symlink there shadows a packaged /usr/bin/kempt for the
# panel only. `kempt doctor` resolves this lookup to say WHICH kempt the widget would run; it is
# the only reader, and nothing is ever executed from it. A seam because the suite runs on boxes
# whose own ~/.local/bin/kempt points at a different checkout than the one under test.
KEMPT_WIDGET_PATH="${KEMPT_WIDGET_PATH:-$HOME/.local/bin:$PATH}"
KEMPT_NOTIFY="${KEMPT_NOTIFY:-notify-send}"
# The terminal emulator the `terminal` surface launches. A seam, so a box without it fails
# loudly (exit 4) instead of `kempt run` silently doing nothing at all.
KEMPT_TERMINAL="${KEMPT_TERMINAL:-konsole}"

CONFIG_FILE="$KEMPT_CONFIG_DIR/config"
HOLDS_FILE="$KEMPT_CONFIG_DIR/holds"
STATE_FILE="$KEMPT_STATE_DIR/state.json"
HIST_DIR="$KEMPT_STATE_DIR/history"
LOG_DIR="$KEMPT_STATE_DIR/logs"
SNAP_DIR="$KEMPT_STATE_DIR/snapshots"
LAST_REFRESH_FILE="$KEMPT_STATE_DIR/last_refresh"
# When Kempt last SAID that it skipped a metadata refresh. Its own stamp and never
# $LAST_REFRESH_FILE: that one rate-limits the fetch, and folding the two together would let an
# announcement postpone a refresh, or a refresh silence the announcement.
REFRESH_SKIP_FILE="$KEMPT_STATE_DIR/last_refresh_skip"
# When the dnf half of a refresh last succeeded. $LAST_REFRESH_FILE is touched when EITHER half
# does, so it would date dnf's metadata by a Flatpak fetch. metadata_refreshed reads this one.
LAST_REFRESH_DNF_FILE="$KEMPT_STATE_DIR/last_refresh_dnf"
# Present while the latest dnf refresh that ran failed, holding one line of its error. A check
# publishes it as backends.dnf.refresh_error, so the widget can tell a failed fetch from one never
# tried, and a network failure from any other.
REFRESH_DNF_FAILED_FILE="$KEMPT_STATE_DIR/refresh_dnf_failed"
OFFLINE_MARKER="$KEMPT_STATE_DIR/offline_staged.json"
LOCK_FILE="$KEMPT_STATE_DIR/lock"
# The writers' lock (see writer_lock). In the STATE dir, never the config dir: the config
# directory holds the two files the user owns and may edit by hand, and architecture.md's "Where
# Kempt writes" promises Kempt puts nothing else there.
WRITER_LOCK_FILE="$KEMPT_STATE_DIR/writer.lock"
# The stage lock (see stage_lock): held while a stage is replacing dnf5's transaction and Kempt's
# marker has not caught up yet.
STAGE_LOCK_FILE="$KEMPT_STATE_DIR/stage.lock"
# Short locks, held for milliseconds on a descriptor bash picks: the state file's read-modify-write
# and the event log's append and trim. A lock that cannot be opened is skipped, never the write. Separate files, because a rename gives the guarded file a new inode.
STATE_LOCK_FILE="$KEMPT_STATE_DIR/state.lock"
# Set only by publish_staged_state, around its own write_state. Unset first, so a value in the
# environment can never make write_state skip the lock.
unset _KEMPT_STATE_LOCK_HELD; _KEMPT_STATE_LOCK_HELD=""
EVENTS_LOCK_FILE="$KEMPT_STATE_DIR/events.lock"
EVENTS_FILE="$KEMPT_STATE_DIR/events.log"
# Reclaiming disk space. The size cache saves a du over every installed Flatpak runtime on each
# check; it is keyed on the installed set, so any install, update or removal invalidates it. The
# outcome file is what the last removal did, carried into state.json by the next check, because
# write_state is the only door into state.json and a removal is not a check.
# shellcheck disable=SC2034  # read by backends/flatpak.sh, kept here with the other state files
RECLAIM_SIZES_FILE="$KEMPT_STATE_DIR/reclaim-sizes.json"
RECLAIM_LAST_FILE="$KEMPT_STATE_DIR/reclaim-last.json"
# The popup default for `surface` (surface_migrate). The first records that the migration ran; the
# second exists while the popup still owes an install it pinned to the terminal its one offer.
SURFACE_MIGRATED_FILE="$KEMPT_STATE_DIR/surface-migrated"
SURFACE_OFFER_FILE="$KEMPT_STATE_DIR/surface-offer"
# The security advisories already announced and already seen, for notify_security:
# {"notified": [ids], "acknowledged": [ids]}. Written under the writers' lock (see security_update).
SECURITY_SEEN_FILE="$KEMPT_STATE_DIR/security-seen.json"
# Stamp for the once-a-day `security check failed` line, removed when the query works again.
SECURITY_FAIL_FILE="$KEMPT_STATE_DIR/last_security_fail"
# What notify_security may add to a check, in seconds: the advisory query, each of the two waits for
# the writers' lock, and the notification. Kept small, because the widget's CHECK_BODY_MS counts
# them (a test there reads these three lines).
# shellcheck disable=SC2034  # read by backends/dnf.sh
SECURITY_QUERY_TIMEOUT=15
# shellcheck disable=SC2034  # read by cmd_check in bin/kempt, which sources this file
SECURITY_LOCK_WAIT=5
SECURITY_NOTIFY_TIMEOUT=5
# dnf5's own record of a staged offline transaction, and the other half of the marker above: the
# marker says Kempt staged something, this says whether the transaction is still there and whether
# it is armed. 0644 on Fedora, so an ordinary check READS it with no privileged call and can
# reconcile the two. Nothing here ever writes it; dnf5 owns it.
KEMPT_OFFLINE_TOML="${KEMPT_OFFLINE_TOML:-/usr/lib/sysimage/libdnf5/offline/offline-transaction-state.toml}"
# The staged transaction ITSELF, as dnf5 stores it: the resolved package set the next restart will
# install, resolver-added packages included. Root-owned 0644 in a 0755 directory, so an
# unprivileged `kempt check` or `kempt hold` can say whether a package is in there. READ, NEVER
# WRITTEN; dnf5 owns it, like the toml above.
# Read LIVE rather than snapshotted at stage time, and that is the point of it: a snapshot cannot
# see a transaction somebody else replaced, and a check-derived list cannot see the packages the
# resolver added. Only this file knows what is actually going to install.
KEMPT_OFFLINE_TXJSON="${KEMPT_OFFLINE_TXJSON:-/usr/lib/sysimage/libdnf5/offline/transaction.json}"
# The dnf5 that answers `history list` and `history info`, read as the user after a restart to tell
# which transaction ran (offline_history_attribution). Its own seam rather than KEMPT_DNF_CMD, which
# several test files point at a needs-restarting stub.
KEMPT_DNF_HISTORY_CMD="${KEMPT_DNF_HISTORY_CMD:-dnf5}"
# The other half of dnf5's arming, and the half that decides what a boot does: systemd's
# system-update-generator looks for THIS symlink and nothing else (systemd.offline-updates(7)).
# `dnf5 offline reboot` creates it; the toml above only says what the transaction thinks it is, and
# the two can disagree - a re-stage destroys the old transaction and leaves the symlink standing,
# which is a boot that detours into the offline updater and installs nothing. Any live dnf5
# transaction removes it too, leaving the toml at `ready`. Its presence is read with lstat, never
# a test of the target: the generator does not care whether the target resolves, so neither may
# we. Whose it is comes from its text (offline_link_state). A seam because a test cannot create
# /system-update.
KEMPT_OFFLINE_LINK="${KEMPT_OFFLINE_LINK:-/system-update}"
# Where dnf5 points that symlink: its offline data directory, the target `dnf5 offline reboot`
# writes (libdnf5's DEFAULT_DATADIR under the install root). PackageKit points the same symlink at
# its own prepared update instead, and then the next restart is PackageKit's, not dnf5's.
KEMPT_OFFLINE_DATADIR="${KEMPT_OFFLINE_DATADIR:-/usr/lib/sysimage/libdnf5/offline}"
# dnf5's system cache, which root writes on every refresh. `kempt doctor` only reads it, to find
# world-writable files left by a release whose root helpers kept the caller's umask.
KEMPT_DNF_CACHE_DIR="${KEMPT_DNF_CACHE_DIR:-/var/cache/libdnf5}"
# dnf5's system state, where the apply verbs write. Read by `kempt doctor` for the same reason.
KEMPT_DNF_SYSIMAGE_DIR="${KEMPT_DNF_SYSIMAGE_DIR:-/usr/lib/sysimage/libdnf5}"
# Every installed package as name-epoch:version-release.arch, epoch 0 written out. Read to tell
# whether a stored transaction's packages are already installed (offline_stage_satisfied).
KEMPT_RPM_QA_CMD="${KEMPT_RPM_QA_CMD:-}"
# dnf's main config, read for `installonlypkgs` only (offline_installonly_name). Read, never written.
KEMPT_DNF_CONF="${KEMPT_DNF_CONF:-/etc/dnf/dnf.conf}"
# The installed names that provide installonlypkg(kernel) or installonlypkg(kernel-module), one
# per line. Empty means the rpm query in offline_installonly_rpm_names.
KEMPT_RPM_INSTALLONLY_CMD="${KEMPT_RPM_INSTALLONLY_CMD:-}"
# Which of the two shutdown-inhibit plugins are installed, one name a line. Empty means the rpm query
# in doctor_inhibit_installed. Read by `kempt doctor` only.
KEMPT_RPM_INHIBIT_CMD="${KEMPT_RPM_INHIBIT_CMD:-}"
# libdnf5's config for its systemd-inhibit plugin. libdnf5 loads a plugin only through its config
# file, and runs it unless [main] sets enabled to false. Read, never written.
KEMPT_DNF_INHIBIT_CONF="${KEMPT_DNF_INHIBIT_CONF:-/etc/dnf/libdnf5-plugins/00-systemd-inhibit.conf}"
# What ostree-prepare-root writes into the initramfs-mounted /run of a booted ostree deployment:
# Silverblue, Kinoite, Bazzite, bootc images. ABSENT on ordinary Fedora even when rpm-ostree is
# installed, which is why it is this file and not the presence of a binary - the package resolves
# on a package-based box and says nothing about how that box updates.
KEMPT_OSTREE_MARKER="${KEMPT_OSTREE_MARKER:-/run/ostree-booted}"
# Who has an account here, read by reclaim_many_accounts to decide whether automatic removal of
# unused Flatpak runtimes can be trusted. getent rather than /etc/passwd, so systemd-homed accounts
# count too. Network directories (sssd, LDAP, AD) list nobody by default, so nsswitch.conf is read
# for them, and the home directories that hold Flatpak data are counted as a third signal.
KEMPT_GETENT_CMD="${KEMPT_GETENT_CMD:-getent passwd}"
KEMPT_NSSWITCH_FILE="${KEMPT_NSSWITCH_FILE:-/etc/nsswitch.conf}"
KEMPT_HOME_ROOTS="${KEMPT_HOME_ROOTS:-/home /var/home}"
# An sss or winbind source only counts when that service is set up. Upgraded machines keep an old
# authselect `passwd: sss files systemd` line with no sssd behind it. /etc/sssd is readable only by
# root and the sssd group, so for everyone else systemd, which checked for a config file as root
# when it tried to start sssd, answers instead.
KEMPT_SSSD_DIR="${KEMPT_SSSD_DIR:-/etc/sssd}"
KEMPT_SMB_CONF="${KEMPT_SMB_CONF:-/etc/samba/smb.conf}"
KEMPT_SYSTEMCTL_CMD="${KEMPT_SYSTEMCTL_CMD:-systemctl}"
# Asks polkit whether this process may remove Flatpak runtimes WITHOUT asking anyone, before an
# unattended removal starts (reclaim_remove). No --allow-user-interaction, so it can never raise a
# dialog itself.
KEMPT_PKCHECK="${KEMPT_PKCHECK:-pkcheck}"

kempt_init_dirs() {
  mkdir -p "$KEMPT_CONFIG_DIR" "$HIST_DIR" "$LOG_DIR" "$SNAP_DIR"
  # Sweep aged orphan tmps: a crash between mktemp and mv leaks .atomic.XXXXXX forever. +60min so
  # a tmp belonging to a live concurrent writer is never eligible. maxdepth 2, not 1: atomic_write
  # puts its temp NEXT TO the destination, and the offline baseline it rewrites lives in snapshots/.
  # A && B || C with `true` as C is not a disguised if-then-else: the sweep is best-effort and BOTH
  # a missing state dir and a failed find must land on rc 0.
  # shellcheck disable=SC2015
  [[ -d "$KEMPT_STATE_DIR" ]] && find "$KEMPT_STATE_DIR" -maxdepth 2 -name '.atomic.*' -mmin +60 -delete 2>/dev/null || true
  # The config dir collects them too: `hold`, `unhold` and `config set` write through atomic_write
  # there. maxdepth 1, because Kempt writes nothing below it. Created by the mkdir above.
  find "$KEMPT_CONFIG_DIR" -maxdepth 1 -name '.atomic.*' -mmin +60 -delete 2>/dev/null || true
  # ...and the run-start tokens, on the same rule and the same bound. `kempt run` drops one here and
  # the window it launches claims it by deleting it (wait_for_window), so a terminal that never
  # opens - or one that hangs for ever without running its script - leaves it behind, and nothing
  # else would ever remove it: one file per wedged launch, accumulating for good.
  # maxdepth 1, because that is where cmd_run's mktemp puts them. +60min for the temps' reason read
  # the other way round: `kempt run` waits SECONDS for a token to be claimed, so an hour is far past
  # any launch that is still legitimately waiting for its window.
  find "$KEMPT_STATE_DIR" -maxdepth 1 -name 'run-start.*' -mmin +60 -delete 2>/dev/null || true
  # ...and a removal's copy of flatpak's output (reclaim_remove), left by a kempt killed outright.
  # The removal is given ten minutes, so an hour is past any that is still running.
  find "$KEMPT_STATE_DIR" -maxdepth 1 -name 'reclaim-out.*' -mmin +60 -delete 2>/dev/null || true
  # Retention: nothing else ever deletes these, and the widget triggers a run on a timer - one
  # history entry plus one log per run, forever, on a box nobody tidies by hand. Keep the newest 50
  # entries and drop logs after 60 days (the logs are the failure evidence; the entry that names
  # them is what has to last). Both sweeps are best-effort: an unprunable state dir must never stop
  # an update. Process substitution, not a pipe: `ls` exits 2 on an empty history dir - the normal
  # state on a fresh install - and under pipefail that rc propagates out of every caller.
  local f
  # -t is MTIME order, and mtime order IS the retention rule. find has no equivalent short of
  # -printf '%T@ %p' plus a re-sort, which is more moving parts on a path that deletes files. The
  # glob is shell-expanded, so ls never parses a name.
  # shellcheck disable=SC2012
  while IFS= read -r f; do [[ -n "$f" ]] && rm -f "$f"; done \
    < <(ls -1t "$HIST_DIR"/*.json 2>/dev/null | tail -n +51 || true)
  find "$LOG_DIR" -name '*.log' -mtime +60 -delete 2>/dev/null || true
  return 0
}

# --- the event log ---
# The question the other three files cannot answer: logs/, history/ and state.json say what the
# package manager printed, what a run changed and what is pending, and nothing records that a
# setting was changed, a package held, or a check ran at all. One line per thing Kempt did,
# appended, read back with `kempt log`.
#
# Best-effort by construction, and that is a contract, not a shrug. It returns 0 whatever happens,
# because a log line is never worth changing the exit status of the command that emitted it, and it
# blocks for at most 5 seconds on events.lock. A state directory that cannot be written simply gets
# no events.
# --- the event log, in plain words ----------------------------------------------------------------
# events.log keeps its fixed vocabulary on disk: tests, scripts and the widget read it, and
# docs/usage.md lists every line. `kempt log` and doctor's last events show each line in plain words
# instead. A line this does not know is shown as written. Sets EVENT_PLAIN rather than printing, so
# a long log costs no subshell per line.
event_count_phrase() {  # n singular plural → "1 update" | "3 updates" | "? updates"
  if [[ "$1" == 1 ]]; then EVENT_COUNT="1 $2"; else EVENT_COUNT="$1 $3"; fi
}
event_where_phrase() {  # surface → where a run went, in the widget's settings words
  case "$1" in
    terminal) EVENT_WHERE="in a terminal window" ;;
    popup) EVENT_WHERE="in the widget" ;;
    background) EVENT_WHERE="in the background" ;;
    offline) EVENT_WHERE="to stage for the next restart" ;;
    *) EVENT_WHERE="somewhere Kempt does not know ($1)" ;;
  esac
}
event_plain() {  # event text → EVENT_PLAIN
  local t="$1" rest
  EVENT_PLAIN="$t"
  case "$t" in
    "check ok "*)
      if [[ "$t" =~ ^check\ ok\ actionable=([0-9]+|\?)\ held=([0-9]+|\?)$ ]]; then
        event_count_phrase "${BASH_REMATCH[1]}" "update to install" "updates to install"
        EVENT_PLAIN="Checked: $EVENT_COUNT"
        [[ "${BASH_REMATCH[2]}" == 0 ]] || EVENT_PLAIN+=", ${BASH_REMATCH[2]} held"
      fi ;;
    "check stale "*) EVENT_PLAIN="Check failed: ${t#check stale }" ;;
    "security notified count="*)
      if [[ "$t" =~ ^security\ notified\ count=([0-9]+|\?)$ ]]; then
        EVENT_PLAIN="Security update notice shown (${BASH_REMATCH[1]} pending)"
      fi ;;
    "security check failed") EVENT_PLAIN="Security advisories could not be listed" ;;
    "check shared last_check="*) EVENT_PLAIN="Check used the answer of the check at ${t#check shared last_check=}" ;;
    "refresh ok") EVENT_PLAIN="Package lists downloaded" ;;
    "refresh failed") EVENT_PLAIN="Package lists could not be downloaded" ;;
    "refresh flatpak ok") EVENT_PLAIN="Flatpak lists downloaded" ;;
    "refresh flatpak failed") EVENT_PLAIN="Flatpak lists could not be downloaded" ;;
    "refresh skipped "*) EVENT_PLAIN="Package lists not downloaded ${t#refresh skipped }" ;;
    "refresh anyway "*) EVENT_PLAIN="Downloading package lists anyway ${t#refresh anyway }" ;;
    "run start surface="*)
      event_where_phrase "${t#run start surface=}"; EVENT_PLAIN="Update started $EVENT_WHERE" ;;
    "run did not start: "*) EVENT_PLAIN="Update did not start: ${t#run did not start: }" ;;
    "run done "*)
      if [[ "$t" =~ ^run\ done\ rc=0\ updated=([0-9]+|\?)\ reboot=(needed|no)$ ]]; then
        EVENT_PLAIN="Update finished: ${BASH_REMATCH[1]} updated"
        if [[ "${BASH_REMATCH[2]}" == needed ]]; then EVENT_PLAIN+=", restart needed"; fi
      fi ;;
    "run failed rc="*)
      if [[ "$t" =~ ^run\ failed\ rc=([0-9]+):\ (.*)$ ]]; then
        EVENT_PLAIN="Update failed (exit code ${BASH_REMATCH[1]}): ${BASH_REMATCH[2]}"
      fi ;;
    "offline staged "*)
      rest="${t#offline staged }"
      if [[ "$rest" =~ ^([0-9]+|\?)(.*)$ ]]; then
        event_count_phrase "${BASH_REMATCH[1]}" "update" "updates"
        rest="${BASH_REMATCH[2]}"
        EVENT_PLAIN="$EVENT_COUNT staged for the next restart"
        if [[ "$rest" =~ ^\ \(NOT\ recorded:\ (.*)\)$ ]]; then
          EVENT_PLAIN+=", but not recorded, because ${BASH_REMATCH[1]}"
        else
          EVENT_PLAIN+="$rest"
        fi
      fi ;;
    "offline restage failed"*) EVENT_PLAIN="Rebuilding the staged update failed${t#offline restage failed}" ;;
    "offline restage"*) EVENT_PLAIN="Staged update rebuilt${t#offline restage}" ;;
    "offline stage found nothing to stage"*) EVENT_PLAIN="Nothing to stage${t#offline stage found nothing to stage}" ;;
    "offline stage installed by another updater"*)
      EVENT_PLAIN="Another updater installed the staged update${t#offline stage installed by another updater}" ;;
    "offline stage recorded without its package baseline"*)
      EVENT_PLAIN="Staged update recorded, but its result after the restart will not be reported" ;;
    "offline stage refused by the root helper") EVENT_PLAIN="Staging was refused by Kempt's system helper" ;;
    "offline stage "*) EVENT_PLAIN="Staged update ${t#offline stage }" ;;
    "offline marker "*) EVENT_PLAIN="Record of the staged update ${t#offline marker }" ;;
    "harvest applied"*) EVENT_PLAIN="Staged update installed on restart${t#harvest applied}" ;;
    "harvest found the staged transaction did not run"*)
      EVENT_PLAIN="After the restart: the staged update did not run${t#harvest found the staged transaction did not run}" ;;
    "harvest skipped snapshot failed")
      EVENT_PLAIN="After the restart: the installed packages could not be read, so the result was not recorded" ;;
    "harvest cleared stale marker") EVENT_PLAIN="After the restart: an old record of a staged update was cleared" ;;
    "harvest deferred: "*)
      EVENT_PLAIN="Restart result not recorded yet: packages changed outside Kempt while an update is staged" ;;
    "harvest entry not written"*) EVENT_PLAIN="Restart result not saved${t#harvest entry not written}" ;;
    "harvest log not written"*) EVENT_PLAIN="Restart log not saved${t#harvest log not written}" ;;
    "history entry not written"*) EVENT_PLAIN="Update history not saved${t#history entry not written}" ;;
    "unstage discarded the staged update") EVENT_PLAIN="Staged update discarded" ;;
    "unstage found nothing staged") EVENT_PLAIN="Discard: nothing was staged" ;;
    "unstage cleared a marker with no transaction under it")
      EVENT_PLAIN="Discard: the staged update was already gone, so its record was cleared" ;;
    "unstage refused by the root helper") EVENT_PLAIN="Discard was refused by Kempt's system helper" ;;
    "unstage refused"*) EVENT_PLAIN="Discard refused${t#unstage refused}" ;;
    "unstage failed rc="*) EVENT_PLAIN="Discard failed (exit code ${t#unstage failed rc=})" ;;
    "unstage left a transaction behind"*) EVENT_PLAIN="Discard left the staged update in place${t#unstage left a transaction behind}" ;;
    "reclaim removed "*)
      if [[ "$t" =~ ^reclaim\ removed\ ([0-9]+)\ runtimes\ \(([0-9]+|\?)\ bytes\)\ rc=([0-9]+|\?)(.*)$ ]]; then
        local rn="${BASH_REMATCH[1]}" rb="${BASH_REMATCH[2]}" rrc="${BASH_REMATCH[3]}" rtail="${BASH_REMATCH[4]}"
        event_count_phrase "$rn" "unused runtime" "unused runtimes"
        EVENT_PLAIN="Removed $EVENT_COUNT"
        if [[ "$rb" != "?" ]]; then EVENT_PLAIN+=", $(human_bytes "$rb" 2>/dev/null || echo "$rb bytes")"; fi
        [[ "$rrc" == 0 ]] || EVENT_PLAIN+=", Flatpak exit code $rrc"
        rtail="${rtail/, in use: /, including extensions an app uses: }"
        EVENT_PLAIN+="$rtail"
      fi ;;
    "reclaim found nothing to remove") EVENT_PLAIN="Unused runtimes: nothing to remove" ;;
    "reclaim changed (digest), nothing removed") EVENT_PLAIN="Unused runtimes: nothing removed, the list changed" ;;
    "reclaim changed (unstable), nothing removed")
      EVENT_PLAIN="Unused runtimes: nothing removed, some became unused less than an hour ago" ;;
    "reclaim changed (new), nothing removed")
      EVENT_PLAIN="Unused runtimes: nothing removed, one was installed during the update" ;;
    "reclaim needs authorization, nothing removed") EVENT_PLAIN="Unused runtimes: nothing removed, an administrator is needed" ;;
    "reclaim failed (flatpak did not answer)") EVENT_PLAIN="Unused runtimes: Flatpak did not answer" ;;
    "reclaim failed rc="*)
      if [[ "$t" =~ ^reclaim\ failed\ rc=([0-9]+|\?)(.*)$ ]]; then
        EVENT_PLAIN="Unused runtimes: removal failed (exit code ${BASH_REMATCH[1]})${BASH_REMATCH[2]}"
      fi ;;
    "reclaim refused (running as root)") EVENT_PLAIN="Unused runtimes: refused, Kempt ran as root" ;;
    "reclaim refused (reclaim=off)") EVENT_PLAIN="Unused runtimes: refused, the reclaim setting is off" ;;
    "passwordless enable rc=0") EVENT_PLAIN="Passwordless updates turned on" ;;
    "passwordless enable rc="*) EVENT_PLAIN="Passwordless updates not turned on (exit code ${t#passwordless enable rc=})" ;;
    "passwordless disable rc=0") EVENT_PLAIN="Passwordless updates turned off" ;;
    "passwordless disable rc="*) EVENT_PLAIN="Passwordless updates not turned off (exit code ${t#passwordless disable rc=})" ;;
    "discover-notifier off") EVENT_PLAIN="Discover's update notifier turned off" ;;
    "discover-notifier on") EVENT_PLAIN="Discover's update notifier turned on" ;;
    "discover-notifier keep") EVENT_PLAIN="Discover's update notifier kept as it is" ;;
    "config set "*)
      if [[ "$t" =~ ^config\ set\ ([a-z][a-z0-9_]+)=(.*)\ \(was\ (.*)\)$ ]]; then
        local k="${BASH_REMATCH[1]}" v="${BASH_REMATCH[2]}" o="${BASH_REMATCH[3]}"
        if [[ "$k" == surface ]]; then v="$(surface_word "$v")"; o="$(surface_word "$o")"; fi
        [[ "$o" != unset ]] || o="not set"
        EVENT_PLAIN="Setting $k changed to $v (was $o)"
      fi ;;
    "hold "*) EVENT_PLAIN="Held ${t#hold }" ;;
    "unhold "*) EVENT_PLAIN="No longer held: ${t#unhold }" ;;
  esac
  # A stage a live update made obsolete, in words.
  EVENT_PLAIN="${EVENT_PLAIN//(superseded by live update)/(a live update replaced it)}"
  EVENT_PLAIN="${EVENT_PLAIN//(superseded by live update, /(a live update replaced it, and }"
  # A notification the line records, in words.
  [[ "$EVENT_PLAIN" != *" - announced" ]] || EVENT_PLAIN="${EVENT_PLAIN% - announced}, and you were notified"
}

# Event lines from stdin, in plain words. A line that is not `<timestamp> <via> <text>` is printed
# as it is.
events_plain() {  # [prefix]; stdin: events.log lines
  local ts via text
  while IFS=' ' read -r ts via text; do
    if [[ -n "$text" ]]; then
      event_plain "$text"
      printf '%s%s %s %s\n' "${1:-}" "$ts" "$via" "$EVENT_PLAIN"
    else
      printf '%s%s\n' "${1:-}" "$ts${via:+ $via}"
    fi
  done
}

log_event() {  # text
  local via=cli
  # The widget prefixes every command it runs with KEMPT_VIA=widget (plasmoid main.qml and
  # configGeneral.qml); anything else - a terminal, a script, a timer - is `cli`. Two answers on
  # purpose: this exists to separate "I clicked that" from "something else did".
  [[ "${KEMPT_VIA:-}" == widget ]] && via=widget
  {
    # `|| return 0` is also what keeps errexit out of here: a function called on the left of ||
    # runs with errexit suspended, so a failing mkdir inside it can never take the caller down.
    kempt_init_dirs || return 0
    # 0600 from the moment the file exists. It names packages you hold and the values of your
    # settings, and whichever command happens to log first is the one that creates it. `>>` never
    # truncates, so two first writers cannot erase each other's line.
    [[ -e "$EVENTS_FILE" ]] || ( umask 077; : >> "$EVENTS_FILE" ) || return 0
    # The append and the trim share one lock, so a line written between the trim's read and its
    # rename cannot be lost. A lock that times out after 5 seconds still lets the line through, and
    # the trim waits for a later write. A lock that cannot be opened never will be, so it trims anyway.
    local locked=false lfd
    if { exec {lfd}>>"$EVENTS_LOCK_FILE"; } 2>/dev/null; then
      flock -w 5 "$lfd" && locked=true
    else
      lfd=""; locked=true
    fi
    log_event_write "$via" "$1" "$locked" || true
    if [[ -n "$lfd" ]]; then { exec {lfd}>&-; } 2>/dev/null || true; fi
  } 2>/dev/null || true
  return 0
}

log_event_write() {  # via text locked
  printf '%s %s %s\n' "$(now_iso)" "$1" "$2" >> "$EVENTS_FILE" || return 0
  # Retention, checked on write because there is no timer to check it on. Keeping the last 2000
  # of 2500 means the rewrite runs once every 500 events, and only under the lock. atomic_write keeps
  # a reader from seeing a half-written file, and its 0600 temp carries the mode across.
  local n
  n="$(wc -l < "$EVENTS_FILE")" || return 0
  if [[ "$3" == true ]] && (( n > 2500 )); then
    tail -n 2000 "$EVENTS_FILE" | atomic_write "$EVENTS_FILE" || return 0
  fi
}

# Byte-for-byte equality of two readable files, with coreutils alone. `cmp` is diffutils, which is
# NOT on a minimal Fedora image (a container, a server install): there it exits 127, which every
# caller reads as "the files differ" - harvesting an unchanged box as "applied, no package changes"
# and reporting every helper as drifted from the checkout. Two files that cannot be read are NOT
# equal either: a caller that could read neither has no grounds to say the package set did not
# move, so the unreadable case is its own status.
same_content() {  # file file → 0 equal, 1 different, 2 unreadable
  [[ -r "$1" && -r "$2" ]] || return 2
  [[ "$(sha256sum < "$1")" == "$(sha256sum < "$2")" ]]
}

atomic_write() {  # dest; stdin → dest atomically (same-dir tmp so mv stays atomic)
  local dest="$1" tmp
  tmp="$(mktemp -p "$(dirname "$dest")" .atomic.XXXXXX)"
  # sync before the rename: an atomic rename only guarantees you see the OLD or NEW name, not
  # that the new name's CONTENT reached disk. After an unclean shutdown that gap shows up as a
  # zero-length holds file - which silently un-holds every package the user pinned.
  if cat > "$tmp"; then sync "$tmp" 2>/dev/null || true; mv "$tmp" "$dest"; else rm -f "$tmp"; return 1; fi
}

# The ONE sort every producer of a collapsible TSV uses. Two keys, both load-bearing:
#   -k1,1   name, byte order. join(1) and tsv_diff_updates require the join field in exactly this
#           order, so the primary key must never become version-aware.
#   -k2,2V  version, VERSION-aware and ascending. Every consumer reads the last element of a
#           comma-joined set as the newest (render_summary's newest(), the widget's newestOf), and
#           only a version sort makes that true: lexically 5.3.10-1 sorts before 5.3.9-4 ("1"
#           before "9" at the third character), leaving the OLDER build last.
# Honest limit: `sort -V` does not understand rpm epochs. Sets sharing an epoch - the common case,
# and always true of multilib twins and installonly kernel sets - are exact. A set MIXING epochs
# can be ordered wrongly, because the leading "1:" compares as an ordinary number: `1:2.0-1` sorts
# before `9.0-1` although the epoch makes it newer. Getting that right needs rpm's own EVR
# comparison, which is not available in a pipeline.
sort_name_version() { sort -t "$(printf '\t')" -k1,1 -k2,2V "$@"; }

collapse_versions() {  # stdin: TSV from sort_name_version (names may repeat) → one row per name, versions comma-joined in ASCENDING version order (last = newest, and consumers rely on it)
  # An OPTIONAL third field rides through untouched in shape: it is the row's IDENTITY, for a
  # backend whose version string is not one. A Flatpak ref updates whenever its commit changes, and
  # most runtimes carry a date or nothing at all as their version, so version alone cannot answer
  # "did this move?" - see tsv_diff_updates. dnf sends two fields and is unaffected.
  awk -F'\t' '
    function flush() { if (prev != "") print prev "\t" vals (ids == "" ? "" : "\t" ids) }
    $1 != prev { flush(); prev = $1; vals = $2; ids = (NF >= 3 ? $3 : ""); next }
    { vals = vals "," $2; if (NF >= 3) ids = (ids == "" ? $3 : ids "," $3) }
    END { flush() }'
}

# Every setting this build knows, and the list `config set` warns against. It sits beside
# kempt_default because the two are twins: a key with a default belongs here, and a key here must
# have a default there, or `config get` answers with an empty string for a setting Kempt claims to
# know. Adding a backend or a widget setting means adding it in both places.
KEMPT_CONFIG_KEYS="include_flatpak auto_accept surface refresh_interval_min widget_icon_size restart_reminder risky_regex reclaim notify_security"

# The values a key with a FIXED set accepts: `surface` and `reclaim`. The booleans take anything and
# read it as false, which configuration.md documents in as many words ("auto_accept on" is its own
# worked example), and `widget_icon_size` is validated by the WIDGET, the half that can actually see
# the panel - a CLI that rejected a size would be a second opinion about a Plasma detail it cannot
# observe. A table, so a second enum is one line rather than a new branch.
config_enum_values() {  # key → accepted values, space separated, or nothing
  case "$1" in
    surface) printf '%s\n' "terminal popup background offline" ;;
    reclaim) printf '%s\n' "ask automatic off" ;;
  esac
}

# A surface as Kempt reads it: trimmed, lower-cased, and with `widget` read as `popup`. `widget` is
# the word the person sees, and `popup` is the value stored, which older widgets and scripts read.
surface_canon() {  # surface → canonical spelling (unknown values pass through, trimmed and lowered)
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  s="${s,,}"
  [[ "$s" != widget ]] || s=popup
  printf '%s\n' "$s"
}

# The word a person reads for a stored surface. Only `popup` differs.
surface_word() {  # surface → user-facing word
  if [[ "$1" == popup ]]; then printf 'widget\n'; else printf '%s\n' "$1"; fi
}

# What `config set` says when it did not recognise what was written. WARN, never refuse: an unknown
# key may be one a newer widget or a later Kempt reads, and a CLI that refused would be the thing
# that stopped it working. So the write goes through and the status stays 0; the only change is
# that a typo stops being silent. `surface bogus` used to sit in the config file doing nothing at
# all, with the person waiting for behaviour that was never going to arrive.
# Called from cmd_config and nowhere else, so config_set stays quiet for its internal callers.
config_warn_unknown() {  # key value
  local k="$1" v="$2" vals
  # A key config_set refuses gets its error alone, not a warning in front of it.
  [[ "$k" =~ ^[a-z][a-z0-9_]+$ ]] || return 0
  if [[ " $KEMPT_CONFIG_KEYS " != *" $k "* ]]; then
    echo "warning: unknown setting '$k'. Kempt does not read it. Known settings: ${KEMPT_CONFIG_KEYS// /, }" >&2
    return 0
  fi
  vals="$(config_enum_values "$k")"
  [[ -n "$vals" ]] || return 0
  [[ " $vals " == *" $v "* ]] && return 0
  # The accepted list in the words the person types: `widget` for the stored `popup`.
  [[ "$k" != surface ]] || vals="${vals/popup/widget}"
  echo "warning: '$v' is not a value $k accepts. Accepted: ${vals// /, }" >&2
}

kempt_default() {  # key → default ("" if unknown)
  case "$1" in
    include_flatpak|auto_accept) echo true ;;
    # Twinned with DEFAULT_SURFACE in the widget's logic.js. An install from before this default
    # keeps the terminal through surface_migrate.
    surface) echo popup ;;
    refresh_interval_min) echo 60 ;;
    # Panel-icon size for the Plasma widget: auto|small|medium|large. A widget setting kept here so
    # the widget and `kempt config` share one place; the CLI has no icons and never reads it. The
    # VALUE is deliberately not validated: the widget turns anything it does not recognise into
    # `auto` rather than refusing to draw, and a CLI that rejected values would be a second opinion
    # about a Plasma detail it cannot see.
    widget_icon_size) echo auto ;;
    # Whether the widget's popup offers to open KDE's restart prompt when a restart is owed -
    # another widget setting kept here so `kempt config` stays the one way in and out.
    # The DEFAULT is the whole point of the entry: the widget asks the CLI for the key and runs the
    # answer through is_true(), and a key with no default answers with the empty string, which
    # is_true reads as false. A missing entry here would not mean "no opinion" - it would silently
    # switch the reminder OFF on every box whose config file has never named it. Same failure mode
    # as a missing include_<backend> default (docs/architecture.md, the backend wiring table).
    restart_reminder) echo true ;;
    # session-critical families: a LIVE upgrade of these can break the running desktop
    # mid-transaction, so Kempt recommends the offline path first.
    risky_regex) echo '^(kernel|systemd|glibc|dbus|mesa|qt6|kf6|plasma-workspace|kwin)' ;;
    # What happens to the Flatpak runtimes no installed app uses: ask|automatic|off. See
    # reclaim_mode for how a value is read.
    reclaim) echo ask ;;
    # A desktop notification when pending system updates fix a security advisory. Off unless asked
    # for: the query costs a second per check, and a notification nobody asked for is noise.
    notify_security) echo false ;;
    *) echo "" ;;
  esac
}

# Runs updates in the popup by default without moving anyone who already uses Kempt. On the first
# run after that default arrived, an install that has run Kempt before (state.json, a history
# entry or a non-empty config file) and whose config names no surface gets surface=terminal, the default it had, and the
# popup offers the new one once. A config that names a surface is never touched, and a new install
# gets the default. SURFACE_MIGRATED_FILE says it ran. A write that fails is tried again on the
# next run, and nothing here may fail the command it runs in front of.
surface_migrate() {
  [[ -e "$SURFACE_MIGRATED_FILE" ]] && return 0
  # An unreadable config cannot say whether it names a surface. Next run.
  [[ -e "$CONFIG_FILE" && ! -r "$CONFIG_FILE" ]] && return 0
  # A config file with something in it counts too: an install that only ever changed a setting has
  # no state or history, and this runs before any command of this version can write the file.
  local used=""
  if [[ -e "$STATE_FILE" || -s "$CONFIG_FILE" ]] \
     || [[ -n "$(find "$HIST_DIR" -maxdepth 1 -name '*.json' -print -quit 2>/dev/null)" ]]; then
    used=1
  fi
  if [[ -n "$used" ]]; then
    # The check for a surface line and the write are one step under the writers' lock (rc 3: the
    # config already names one, which is the answer too). Any other failure is tried next run.
    local rc=0
    config_set surface terminal if-absent 2>/dev/null || rc=$?
    [[ $rc -eq 0 || $rc -eq 3 ]] || return 0
    [[ $rc -eq 0 ]] && { : > "$SURFACE_OFFER_FILE"; } 2>/dev/null
  fi
  { mkdir -p "$KEMPT_STATE_DIR" && : > "$SURFACE_MIGRATED_FILE"; } 2>/dev/null || true
}

# The offer, as state.json carries it: pending while the marker exists and updates still run in
# the terminal. A config edited by hand to another surface has answered it too, so the marker goes
# then, and editing back to the terminal does not bring the offer back.
surface_offer_pending() {  # → 0 when the popup should offer the popup default
  [[ -e "$SURFACE_OFFER_FILE" ]] || return 1
  local s
  s="$(config_get surface 2>/dev/null)" || return 1
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  [[ "${s,,}" == terminal ]] && return 0
  rm -f "$SURFACE_OFFER_FILE" 2>/dev/null
  return 1
}

# --- Discover's update notifier ---------------------------------------------------------------
# plasma-discover-notifier checks for updates on its own schedule, from PackageKit's cache, so its
# count can differ from Kempt's. `kempt discover-notifier` turns it off for this user with an XDG
# autostart entry in ~/.config/autostart: a user entry shadows the system one of the same name, and
# Hidden=true means it never starts. No root is needed for any of it.
KEMPT_XDG_AUTOSTART_DIR="${KEMPT_XDG_AUTOSTART_DIR:-/etc/xdg/autostart}"
KEMPT_DISCOVER_PGREP="${KEMPT_DISCOVER_PGREP:-pgrep}"
KEMPT_DISCOVER_PKILL="${KEMPT_DISCOVER_PKILL:-pkill}"
# What turning it back on starts it with. kstart --application launches the package's own
# application entry the way Plasma launches an app, in its own systemd scope. Without kstart, the
# binary itself, detached.
KEMPT_DISCOVER_START="${KEMPT_DISCOVER_START:-kstart}"
KEMPT_DISCOVER_BIN="${KEMPT_DISCOVER_BIN:-/usr/libexec/DiscoverNotifier}"
DISCOVER_ENTRY=org.kde.discover.notifier.desktop
DISCOVER_APP=org.kde.discover.notifier
# The line that marks the user entry as Kempt's, so `on` removes only a file Kempt wrote.
DISCOVER_MARK="X-Kempt-Override=true"
# The process, matched on its command line: the name is longer than the 15 characters pgrep sees.
# Anchored to the binary at the start, so `less /usr/libexec/DiscoverNotifier` is not it.
DISCOVER_PATTERN="^${KEMPT_DISCOVER_BIN}( |\$)"
# How long `on` waits for a started notifier to appear, in tenths of a second, before it tries the
# binary itself and then says it could not start it.
KEMPT_DISCOVER_START_POLLS="${KEMPT_DISCOVER_START_POLLS:-30}"
# Discover's own update settings. `UseUnattendedUpdates=true` under [Global] makes the notifier
# download updates and prepare them for the next restart by itself, through PackageKit.
KEMPT_DISCOVER_UPDATES_CONF="${KEMPT_DISCOVER_UPDATES_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/PlasmaDiscoverUpdates}"
# The administrator's defaults for the same setting, which the user's file overrides unless locked.
# A colon-separated list in XDG_CONFIG_DIRS order, most important first. Relative entries are skipped.
discover_sysconf_default() {
  local d out="" dirs
  IFS=: read -ra dirs <<<"${XDG_CONFIG_DIRS:-/etc/xdg}"
  for d in "${dirs[@]}"; do
    if [[ "$d" == /* ]]; then out+="${out:+:}${d%/}/PlasmaDiscoverUpdates"; fi
  done
  printf '%s\n' "${out:-/etc/xdg/PlasmaDiscoverUpdates}"
}
KEMPT_DISCOVER_UPDATES_SYSCONF="${KEMPT_DISCOVER_UPDATES_SYSCONF:-$(discover_sysconf_default)}"
# Exists once the person has answered the widget's offer either way, or used the command.
DISCOVER_ANSWERED_FILE="$KEMPT_STATE_DIR/discover-offer-answered"
# The bytes Kempt last wrote to the user entry. `on` removes the entry only while it still matches.
DISCOVER_WRITTEN_FILE="$KEMPT_STATE_DIR/discover-entry-written"

discover_sys_entry()  { printf '%s\n' "$KEMPT_XDG_AUTOSTART_DIR/$DISCOVER_ENTRY"; }
discover_user_entry() { printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/$DISCOVER_ENTRY"; }
# The person's own entry, kept while Kempt's replaces it, and put back by `on`. Beside the entry,
# where the person looks for it. Autostart reads only *.desktop files, so this one never starts.
discover_backup() { printf '%s.before-kempt\n' "$(discover_user_entry)"; }
# A free name beside the entry for a file Kempt moves aside: base, else base.1, base.2 ...
discover_free_name() {  # base
  local base="$1" n=1
  [[ -e "$base" || -L "$base" ]] || { printf '%s\n' "$base"; return; }
  while [[ -e "$base.$n" || -L "$base.$n" ]]; do n=$((n + 1)); done
  printf '%s\n' "$base.$n"
}

discover_installed() { [[ -f "$(discover_sys_entry)" ]]; }

# Whether an autostart entry starts in a Plasma session, by the XDG autostart rules: Hidden=true
# wins over everything, then OnlyShowIn and NotShowIn, whose lists Plasma matches as KDE.
discover_entry_starts() {  # file → 0 when it starts in Plasma
  local f="$1" only not
  grep -qiE '^[[:space:]]*Hidden[[:space:]]*=[[:space:]]*true' "$f" && return 1
  # `|| true`: grep exits 1 for an absent key, the common case, and errexit would stop here.
  only="$(grep -iE '^[[:space:]]*OnlyShowIn[[:space:]]*=' "$f" | head -1 || true)"
  not="$(grep -iE '^[[:space:]]*NotShowIn[[:space:]]*=' "$f" | head -1 || true)"
  [[ -n "$only" && "${only,,}" != *kde* ]] && return 1
  [[ -n "$not" && "${not,,}" == *kde* ]] && return 1
  return 0
}

# The entry that decides: the user's when there is one, else the system's. Empty when neither.
discover_effective_entry() {
  local user sys
  user="$(discover_user_entry)"; sys="$(discover_sys_entry)"
  if [[ -f "$user" ]]; then printf '%s\n' "$user"
  elif [[ -f "$sys" ]]; then printf '%s\n' "$sys"
  fi
}

discover_enabled() {
  discover_installed || return 1
  discover_entry_starts "$(discover_effective_entry)"
}

# → 0, and the path of the file that decided, when Discover is set to install updates by itself.
# Read as text, never with kreadconfig6, which may be absent. As in KConfig, the system files are
# read from least to most important and the user's file last, each overriding the one before. A
# `[$i]` marker on the key, on [Global] or before any group locks the value for every later file.
# True, on, yes and 1 count as true. A file that cannot be read counts as absent.
discover_unattended() {
  local f i dirs files=()
  IFS=: read -ra dirs <<<"$KEMPT_DISCOVER_UPDATES_SYSCONF"
  for (( i = ${#dirs[@]} - 1; i >= 0; i-- )); do
    f="${dirs[i]}"
    if [[ -n "$f" && -f "$f" && -r "$f" ]]; then files+=("$f"); fi
  done
  f="$KEMPT_DISCOVER_UPDATES_CONF"
  if [[ -f "$f" && -r "$f" ]]; then files+=("$f"); fi
  (( ${#files[@]} > 0 )) || return 1
  for f in "${files[@]}"; do
    printf '\001KEMPT-FILE %s\n' "$f"
    head -c 65536 "$f" 2>/dev/null
    printf '\n'
  done | awk '
    function locked(t) { return t ~ /\[\$[A-Za-z]*i[A-Za-z]*\]/ }
    # A lock seen in one file applies from the next file on.
    index($0, "\001KEMPT-FILE ") == 1 { if (pend) blocked = 1; pend = 0; cur = substr($0, 13); sec = ""; next }
    /^[[:space:]]*\[/ {
      s = $0; gsub(/[[:space:]]/, "", s); lk = locked(s); gsub(/\[\$[A-Za-z]+\]/, "", s)
      if (s != "") { sec = s; if (lk && s == "[Global]") pend = 1 }
      else if (lk && sec == "") pend = 1
      next
    }
    sec == "[Global]" && index($0, "=") > 0 && !blocked {
      k = substr($0, 1, index($0, "=") - 1); gsub(/[[:space:]]/, "", k); lk = locked(k)
      gsub(/\[\$[A-Za-z]+\]/, "", k)
      if (k != "UseUnattendedUpdates") next
      v = substr($0, index($0, "=") + 1); gsub(/[[:space:]]/, "", v)
      r = tolower(v); set = 1; f = cur
      if (lk) pend = 1
    }
    END {
      if (!set) exit 1
      if (r == "true" || r == "on" || r == "yes" || r == "1") { print f; exit 0 }
      exit 1
    }'
}

discover_running() {
  "$KEMPT_DISCOVER_PGREP" -u "$(id -u)" -f "$DISCOVER_PATTERN" >/dev/null 2>&1
}

# Whose the user entry is. Anything Kempt did not write byte for byte is the person's.
#   kempt     exactly what Kempt last wrote, or exactly what install.sh wrote before 0.1.8: the
#             three-line entry when there was no system entry to copy, else the system entry as
#             it is now, put through that installer's edit (discover_legacy_entry). `on` removes it.
#   edited    carries Kempt's mark but has changed since. `on` moves it aside and says where.
#   own       anything else, a symlink included.
#   none      no user entry.
#   notfile   a directory or anything else that is not a file or a symlink.
#   dangling  a symlink to nothing.
# Compared with same_content, never cmp: cmp is diffutils, which a minimal Fedora does not have,
# and a missing cmp would class Kempt's own file as the person's, so `on` would refuse.
discover_entry_kind() {
  local user
  user="$(discover_user_entry)"
  if [[ -L "$user" ]]; then
    if [[ -e "$user" ]]; then echo own; else echo dangling; fi
  elif [[ ! -e "$user" ]]; then echo none
  elif [[ ! -f "$user" ]]; then echo notfile
  elif [[ -f "$DISCOVER_WRITTEN_FILE" ]] && same_content "$user" "$DISCOVER_WRITTEN_FILE"; then echo kempt
  elif same_content "$user" <(printf '[Desktop Entry]\nType=Application\nName=Discover Notifier\nHidden=true\n'); then
    echo kempt
  elif [[ -r "$(discover_sys_entry)" ]] && same_content "$user" <(discover_legacy_entry); then
    echo kempt
  elif grep -qx "$DISCOVER_MARK" "$user"; then echo edited
  else echo own
  fi
}

# The bytes install.sh 0.1.7 wrote from the system entry, made from the system entry as it is now:
# every line starting `Hidden=` dropped, the trailing newlines stripped by its $(...), then one
# `Hidden=true`. Matched only while the system entry is unchanged since then, which is the only
# case where the file can be told apart from a copy the person hid.
discover_legacy_entry() {
  local body
  body="$(grep -v '^Hidden=' "$(discover_sys_entry)")" || true
  printf '%sHidden=true\n' "${body:+$body$'\n'}"
}

discover_entry_is_kempts() { case "$(discover_entry_kind)" in kempt|edited) return 0 ;; esac; return 1; }

# Refuses an entry path Kempt cannot read or replace safely. → 0 when it is fine.
discover_entry_usable() {  # kind
  local user
  user="$(discover_user_entry)"
  case "$1" in
    notfile)  echo "$user is not a file, so nothing changed." >&2; return 1 ;;
    dangling) echo "$user is a symlink to $(readlink "$user"), which does not exist, so nothing changed." >&2
              return 1 ;;
  esac
  # An entry that cannot be read cannot say whether it starts the notifier: grep's rc 2 would read
  # as "it starts", and off would then fail half way. Either entry, since off copies the system one.
  local f
  for f in "$user" "$(discover_sys_entry)"; do
    if [[ -e "$f" && ! -r "$f" ]]; then
      echo "Cannot read $f, so nothing changed." >&2
      return 1
    fi
  done
  return 0
}

# The offer, as state.json carries it: while the notifier starts with the session and nobody has
# answered yet.
discover_offer_pending() {
  [[ ! -e "$DISCOVER_ANSWERED_FILE" ]] && discover_enabled
}

discover_mark_answered() {
  { mkdir -p "$KEMPT_STATE_DIR" && : > "$DISCOVER_ANSWERED_FILE"; } 2>/dev/null || true
}

# Writes Kempt's entry from a seed: the seed's keys, with Hidden=true and the mark placed in the
# [Desktop Entry] group. Appending would put them in whatever group comes last.
discover_write_entry() {  # seed
  local seed="$1" user tmp
  user="$(discover_user_entry)"
  mkdir -p "$(dirname "$user")" || return 1
  tmp="$(mktemp "$user.XXXXXX")" || return 1
  if awk -v mark="$DISCOVER_MARK" '
       function put() { print "Hidden=true"; print mark; done = 1 }
       /^\[Desktop Entry\][[:space:]]*$/ { print; group = 1; put(); next }
       /^\[/ { group = 0 }
       group && (/^Hidden[[:space:]]*=/ || $0 == mark) { next }
       { print }
       END { if (!done) { print "[Desktop Entry]"; put() } }
     ' "$seed" > "$tmp" \
     && mkdir -p "$KEMPT_STATE_DIR" && cp "$tmp" "$DISCOVER_WRITTEN_FILE" \
     && mv -f "$tmp" "$user"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

discover_wait_running() {
  local i
  for ((i = 0; i < KEMPT_DISCOVER_START_POLLS; i++)); do
    discover_running && return 0
    sleep 0.1
  done
  return 1
}

# Starts the notifier for this session, detached so it outlives the command and the widget, and
# says whether it is running afterwards. setsid -f returns at once, so its status says nothing.
# Every lock descriptor is closed for the child (6 stage, 7 writers, 8 update, 9 check): bash sets
# no FD_CLOEXEC, and a flock lives as long as any descriptor to it, so a notifier started with fd 7
# open would hold the writers' lock for the whole session and every later `config set`, `hold` or
# `unhold` would wait 30 s and fail. Closing one that is not open is a no-op.
# The binary is started when discover_wait_running gives up after kstart, even when kstart's launch
# is only slow, so two can start.
# That is harmless: DiscoverNotifier registers its D-Bus name through KDBusService with Unique set
# (checked in plasma-discover-notifier 6.7.5), so whichever one finds the name taken exits at once.
discover_start() {
  if command -v "$KEMPT_DISCOVER_START" >/dev/null 2>&1; then
    setsid -f "$KEMPT_DISCOVER_START" --application "$DISCOVER_APP" </dev/null >/dev/null 2>&1 \
      6>&- 7>&- 8>&- 9>&-
    discover_wait_running && return 0
  fi
  if [[ -x "$KEMPT_DISCOVER_BIN" ]]; then
    setsid -f "$KEMPT_DISCOVER_BIN" </dev/null >/dev/null 2>&1 6>&- 7>&- 8>&- 9>&-
    discover_wait_running && return 0
  fi
  return 1
}

discover_stop_running() {
  if "$KEMPT_DISCOVER_PKILL" -u "$(id -u)" -f "$DISCOVER_PATTERN" >/dev/null 2>&1; then
    echo "Stopped the one that was running."
  fi
}

discover_notifier_off() {
  local user backup kind seed moved=""
  if ! discover_installed; then
    echo "Discover's update notifier is not installed. Nothing changed."
    return 0
  fi
  user="$(discover_user_entry)"; backup="$(discover_backup)"
  kind="$(discover_entry_kind)"
  discover_entry_usable "$kind" || return 1
  # An entry that already keeps it off, whoever wrote it, is left exactly as it is.
  if ! discover_enabled; then
    discover_mark_answered
    echo "Discover's update notifier is already off. Nothing changed."
    discover_stop_running
    return 0
  fi
  seed="$(discover_sys_entry)"
  if [[ $kind != none ]]; then
    # One copy of the person's own entry, never overwritten: a second one would lose the first.
    if [[ -e "$backup" || -L "$backup" ]]; then
      echo "A copy of your earlier autostart entry is already kept at $backup, so nothing changed. Move it away, then try again." >&2
      return 1
    fi
    # mv, not cp: a symlink stays a symlink, and every attribute comes back with it.
    mv "$user" "$backup" || { echo "could not keep a copy of $user, so nothing changed" >&2; return 1; }
    moved="$backup"; seed="$backup"
  fi
  if ! discover_write_entry "$seed"; then
    [[ -n "$moved" ]] && mv "$moved" "$user"
    echo "could not write $user, so nothing changed" >&2
    return 1
  fi
  discover_mark_answered
  log_event "discover-notifier off"
  echo "Discover's update notifier is off, and stays off when you log in again."
  [[ -n "$moved" ]] && echo "Your earlier entry is kept at $moved"
  discover_stop_running
  return 0
}

discover_notifier_on() {
  local user backup kind aside
  if ! discover_installed; then
    echo "Discover's update notifier is not installed. Nothing changed."
    return 0
  fi
  user="$(discover_user_entry)"; backup="$(discover_backup)"
  kind="$(discover_entry_kind)"
  discover_entry_usable "$kind" || return 1
  case "$kind" in
    kempt)
      rm -f "$user" || { echo "could not remove $user" >&2; return 1; }
      log_event "discover-notifier on" ;;
    edited)
      aside="$(discover_free_name "$user.kempt-edited")"
      mv "$user" "$aside" || { echo "could not move $user aside, so nothing changed" >&2; return 1; }
      echo "Kempt's entry had changed since Kempt wrote it. Your version is kept at $aside"
      log_event "discover-notifier on" ;;
  esac
  if [[ -e "$backup" || -L "$backup" ]]; then
    if [[ -e "$user" || -L "$user" ]]; then
      echo "Your earlier entry is still kept at $backup"
    else
      mv "$backup" "$user" || { echo "could not put back $user from $backup" >&2; return 1; }
      echo "Your earlier entry is back at $user"
    fi
  fi
  discover_mark_answered
  if ! discover_enabled; then
    echo "A startup file keeps Discover's notifier off: $(discover_effective_entry). Delete it, then run kempt discover-notifier on." >&2
    return 1
  fi
  echo "Discover's update notifier is on."
  # The writers' lock stays held until the notifier is up, so a concurrent off cannot slip in
  # between. discover_start closes it for the child, so the notifier never inherits it.
  discover_running && return 0
  if discover_start; then
    echo "Started it for this session."
  else
    echo "Could not start it now. It starts when you log in again."
  fi
  return 0
}

# The widget's Keep Discover's Notifier: records the answer and changes nothing else.
discover_notifier_keep() {
  if ! discover_installed; then
    echo "Discover's update notifier is not installed. Nothing changed."
    return 0
  fi
  discover_mark_answered
  log_event "discover-notifier keep"
  echo "Discover's update notifier stays as it is."
}

discover_notifier_status() {  # [--json]
  local installed=false enabled=false running=false by_kempt=false
  discover_installed && installed=true
  discover_enabled && enabled=true
  discover_running && running=true
  discover_entry_is_kempts && by_kempt=true
  if [[ "${1:-}" == --json ]]; then
    # Off by a file that is not Kempt's: which one, so Settings can say what to delete.
    local entry=""
    if [[ $installed == true && $enabled == false && $by_kempt == false ]]; then
      entry=",\"entry\":$(jq -Rn --arg p "$(discover_effective_entry)" '$p')"
    fi
    printf '{"installed":%s,"enabled":%s,"running":%s,"by_kempt":%s%s}\n' \
      "$installed" "$enabled" "$running" "$by_kempt" "$entry"
    return 0
  fi
  if [[ $installed == false ]]; then
    echo "Discover's update notifier: not installed"
    return 0
  fi
  if [[ $enabled == true ]]; then echo "Discover's update notifier: on"
  elif [[ $by_kempt == true ]]; then echo "Discover's update notifier: off (turned off by Kempt)"
  else echo "Discover's update notifier: off (by $(discover_effective_entry))"
  fi
  if [[ $running == true ]]; then echo "running: yes"; else echo "running: no"; fi
}

# The reclaim setting as the code acts on it. Anything that is not exactly `automatic` or `off`
# reads as `ask`: a typo must never turn into removing things without asking, and it must not
# silently hide space the person could free either. Case-folded like is_true, because the file is
# edited by hand.
reclaim_mode() {  # → ask | automatic | off
  local v
  v="$(config_get reclaim 2>/dev/null)" || v=""
  v="${v,,}"
  case "$v" in
    automatic|off) printf '%s\n' "$v" ;;
    *) echo ask ;;
  esac
}

# The desktop user, and only the desktop user, may list or remove unused runtimes. For the system
# installation libflatpak counts the CALLING user's own apps as users, so under sudo or pkexec it
# counts root's instead, and a system runtime that one of this person's --user apps needs would
# be listed as unused and removed. SUDO_UID and PKEXEC_UID are how an elevated shell announces
# itself when EUID alone does not (`sudo -u` back to a user keeps SUDO_UID).
reclaim_as_root() {  # → 0 when this process must not reclaim
  [[ $EUID -eq 0 || -n "${SUDO_UID:-}" || -n "${PKEXEC_UID:-}" ]]
}

# Whether more than one person may have apps here. libflatpak counts only the calling user's
# --user apps as users, so another person's app may need a runtime this listing calls unused, and
# automatic removal then behaves as ask. Any one signal is enough: more than one local login
# account (UID 1000 or above, except nobody; an empty shell means /bin/sh), a network account
# source in nsswitch.conf, or Flatpak data in more than one home. A lookup that fails or takes
# longer than 5 seconds counts as more than one, for the same reason.
reclaim_sssd_configured() {  # → 0 when sssd defines a domain, or it cannot tell
  local d="$KEMPT_SSSD_DIR" f out
  [[ -e "$d" ]] || return 1
  if [[ -r "$d" && -x "$d" ]]; then
    for f in "$d/sssd.conf" "$d"/conf.d/*.conf; do
      [[ -e "$f" ]] || continue
      [[ -r "$f" ]] || return 0
      grep -qE '^[[:space:]]*\[domain/' "$f" && return 0
    done
    return 1
  fi
  # shellcheck disable=SC2086  # the seam carries its own arguments
  out="$(timeout 5 $KEMPT_SYSTEMCTL_CMD show -p ActiveState -p ConditionResult \
           -p ConditionTimestampMonotonic sssd.service 2>/dev/null </dev/null 9>&-)" || return 0
  # Not running, and systemd found no config file when it last tried to start it.
  awk -F= '{ v[$1] = $2 } END { exit !(v["ActiveState"] != "active" && v["ConditionResult"] == "no" &&
            v["ConditionTimestampMonotonic"] ~ /^[1-9][0-9]*$/) }' <<<"$out" && return 1
  return 0
}

reclaim_winbind_configured() {  # → 0 when Samba joins a domain, or it cannot tell
  local f="$KEMPT_SMB_CONF"
  [[ -e "$f" ]] || return 1
  [[ -r "$f" ]] || return 0
  awk '{ sub(/[;#].*/, ""); line = tolower($0); gsub(/[[:space:]]/, "", line) }
       line ~ /^security=(ads|domain)$/ { f = 1 } END { exit !f }' "$f"
}

reclaim_many_accounts() {  # → 0 when more than one person may use this machine, or it cannot tell
  local out n
  # shellcheck disable=SC2086  # the seam carries its own arguments
  out="$(timeout 5 $KEMPT_GETENT_CMD 2>/dev/null </dev/null 9>&-)" || return 0
  n="$(awk -F: '$3 ~ /^[0-9]+$/ && $3 >= 1000 && $3 != 65534 && $7 !~ /(nologin|false)$/ { n++ }
               END { print n + 0 }' <<<"$out")" || return 0
  (( n > 1 )) && return 0
  local src
  if [[ -r "$KEMPT_NSSWITCH_FILE" ]]; then
    while IFS= read -r src; do
      case "$src" in
        sss) reclaim_sssd_configured && return 0 ;;
        winbind) reclaim_winbind_configured && return 0 ;;
        *) return 0 ;;
      esac
    done < <(awk '{ sub(/#.*/, "") } $1 == "passwd:" { for (i = 2; i <= NF; i++)
                    if ($i ~ /^(sss|ldap|winbind|nis)$/) print $i }' "$KEMPT_NSSWITCH_FILE")
  fi
  local root d
  n="$(for root in $KEMPT_HOME_ROOTS; do
         for d in "$root"/*/.local/share/flatpak; do [[ -d "$d" ]] && readlink -f "$d" || :; done
       done 2>/dev/null | sort -u | awk 'NF { n++ } END { print n + 0 }')" || n=0
  (( n > 1 ))
}

# The mode Kempt acts on, which is the setting except where automatic cannot be trusted: on an
# image-based system Kempt runs no updates, so there is no run to remove after, and with more than
# one human account the listing does not know about the others' apps. Both fall back to ask, so
# the space is still shown and a person decides.
reclaim_effective_mode() {  # → ask | automatic | off
  local mode
  mode="$(reclaim_mode)"
  if [[ "$mode" == automatic ]]; then
    if on_ostree; then mode=ask
    elif reclaim_many_accounts; then mode=ask
    fi
  fi
  printf '%s\n' "$mode"
}

# What a set of refs is called when a person agrees to remove it: 16 hex characters of the sha256
# of its sorted `ref commit` lines. The commit is part of it, so a runtime that updated between the
# check and the click is a different set. Empty input is the empty digest.
reclaim_digest() {  # stdin: ref<TAB>commit lines → digest, or nothing for an empty set
  local lines
  lines="$(awk -F'\t' 'NF >= 2 { print $1 " " $2 }' | sort -u)"
  [[ -n "$lines" ]] || return 0
  printf '%s\n' "$lines" | sha256sum | cut -c1-16
}

# Bytes as a person reads them, SI decimal like flatpak and Discover: "850 MB", "1.5 GB". Used for
# estimates only, so one decimal is all the precision there is.
human_bytes() {  # bytes → text
  awk -v b="$1" 'BEGIN {
    if (b >= 1e9) printf "%.1f GB\n", b / 1e9
    else if (b >= 1e6) printf "%d MB\n", b / 1e6 + 0.5
    else if (b >= 1e3) printf "%d kB\n", b / 1e3 + 0.5
    else printf "%d bytes\n", b }'
}

# The line of a command's output that says what went wrong: the last line starting with
# "error: Failed to" (flatpak's per-ref reason, which its closing "error: There were one or more
# errors" would hide), else the last starting with "error:", else the last non-empty one. One line,
# with terminal escapes (CSI, OSC, the C1 CSI) and control characters removed, and at most 200
# characters, cut on a character boundary, so it is safe in an event line, a JSON field or a sentence.
# The C1 CSI is taken as U+009B (bytes c2 9b), or as a lone 0x9b byte after ASCII: elsewhere 0x9b
# is part of a UTF-8 character.
error_line_of() {  # stdin: output → one line, empty when there was none
  local line
  line="$(LC_ALL=C sed -e 's/\x1b\][^\x07\x1b]*\(\x07\|\x1b\\\)\{0,1\}//g' \
                       -e 's/\x1b\[[0-?]*[ -/]*[@-~]//g' \
                       -e 's/\xc2\x9b[0-?]*[ -/]*[@-~]//g' \
                       -e 's/\(^\|[\x01-\x7f]\)\x9b[0-?]*[ -/]*[@-~]/\1/g' \
          | LC_ALL=C tr -d '\r' \
          | LC_ALL=C awk '{ sub(/[[:space:]]+$/, "") }
                          tolower($0) ~ /^error: failed to/ { f = $0 }
                          tolower($0) ~ /^error:/ { e = $0 }
                          NF { l = $0 }
                          END { print (f != "" ? f : (e != "" ? e : l)) }')" || line=""
  line="$(printf '%s' "$line" | LC_ALL=C tr -d '[:cntrl:]')" || line=""
  local LC_ALL=C.UTF-8   # the file exports it too; the cut below counts characters only under it
  printf '%s\n' "${line:0:200}"
}

# The last removal's outcome: {at, via, result, refs, bytes, digest}, plus error (flatpak's error
# line, from error_line_of) when there is one, and partial: true when flatpak failed after the
# removal began (refs is then what went, or null when that is unknown), skipped: true when the
# extensions were never tried because the list between the passes failed, and in_use (["id//branch"])
# when flatpak removed extensions it said an app installed since the last listing uses; or {} when
# there is none or the file is damaged. result is removed | nothing | changed | needs_auth | failed.
reclaim_last_read() {  # → one JSON object
  local out
  out="$(jq -c -n '[inputs][0] | select(type == "object")' "$RECLAIM_LAST_FILE" 2>/dev/null)" || out=""
  [[ -n "$out" ]] || out='{}'
  printf '%s\n' "$out"
}

# Best-effort, like every write after a system change: a lost outcome costs a sentence in the
# popup, never the removal's own exit status.
reclaim_last_write() {  # via result refs-json-or-null bytes-or-empty digest [error-line] [partial(1|"")] [in-use-json] [skipped(1|"")]
  kempt_init_dirs 2>/dev/null || return 0
  jq -cn --arg at "$(now_iso)" --arg via "$1" --arg result "$2" --slurpfile refs <(printf '%s\n' "$3") \
         --arg bytes "$4" --arg digest "$5" --arg error "${6:-}" --arg partial "${7:-}" --arg in_use "${8:-}" \
         --arg skipped "${9:-}" \
    '{at:$at, via:$via, result:$result, refs:$refs[0],
      bytes:(if $bytes == "" then null else ($bytes | tonumber) end), digest:$digest}
     + (if $error == "" then {} else {error: $error} end)
     + (if $partial == "" then {} else {partial: true} end)
     + (if $skipped == "" then {} else {skipped: true} end)
     + (if $in_use == "" then {} else {in_use: ($in_use | fromjson)} end)' 2>/dev/null \
    | atomic_write "$RECLAIM_LAST_FILE" 2>/dev/null || true
  return 0
}
is_true() { local v="${1,,}"; [[ "$v" == true || "$v" == 1 || "$v" == yes ]]; }

# ONE version string for the whole project, and VERSION is it: the git tag, the RPM `Version:`, the
# AppStream `<release version=>` and the widget's KPlugin.Version all have to agree, and nothing
# enforces that except a single place to read from. A plain file rather than a constant in
# bin/kempt so a spec file, a CI job or a packaging script can read it without parsing shell.
# Read lazily, never at source time: `kempt check` runs from a timer and has no use for a version.
# "unknown" rather than an error for a missing or empty file, because a version is a diagnostic: a
# build that cannot say what it is must still be able to update the machine. `head -1` and the
# whitespace strip keep a stray editor newline out of `kempt --version`.
kempt_version() {  # → the version string, or "unknown"
  local v
  v="$(head -1 "$KEMPT_ROOT/VERSION" 2>/dev/null || true)"
  v="${v//[[:space:]]/}"
  printf '%s\n' "${v:-unknown}"
}

# --- the user-file writers' lock ---------------------------------------------------------------
# INVARIANT: config_set, hold_add and hold_remove hold this across the WHOLE read-modify-write, and
# so do the security writers: cmd_check while it works out the `security` block and writes
# state.json, and cmd_security_ack while it patches both files.
# Readers (config_get, holds_all, holds_for) take no lock at all and must not start.
#
# Why it exists: all three writers read the file into a variable and write the whole file back
# through atomic_write. Atomic means a reader never sees a torn file; it does NOT stop two writers
# losing each other's work, because a writer that read before its neighbour's rename writes that
# neighbour's change back out. Unlocked, concurrent commands measurably lose about one write in ten
# (tests/test_config_concurrency.sh is that probe). The widget cannot race itself - its Executor
# runs one command at a time - but two terminals, a script looping `kempt hold`, or the CLI racing
# a widget write all can.
#
# fd 7, and the number is load-bearing: fd 8 is the update lock (acquire_lock) and fd 9 is
# cmd_check's check.lock, both of which can be held for a whole run and are inherited by children.
#
# Nesting is ruled out by construction rather than handled: the callers are cmd_config, cmd_hold,
# cmd_unhold, cmd_discover_notifier, cmd_security_ack and cmd_check's security step, each taking it
# once and releasing it before anything else could take it. cmd_hold and cmd_unhold release it
# before their closing check, which takes it again. Re-entering would be quiet rather than loud - `exec 7>>` on a held fd CLOSES it
# first, dropping the outer lock unnoticed. If a writer ever has to call another one, pass the open
# descriptor down; do not re-open it.
#
# `>>` and not `>`: the `>` form truncates on open, so a process that merely ATTEMPTS the lock would
# erase a live holder's file first (same reasoning as acquire_lock's note). kempt_init_dirs first,
# also like acquire_lock: a box where the state directory cannot be created fails there, not here.
writer_lock() {  # [seconds to wait, 30 by default]
  local wait="${1:-30}"
  kempt_init_dirs
  exec 7>>"$WRITER_LOCK_FILE"
  # -w rather than -n: these writes are ~10ms apiece, so an overlap is a wait of that length and
  # refusing would turn it into a lost write instead. 30s is far past any honest queue - reaching
  # it means a holder is wedged, and writing anyway would put the lost-write bug straight back.
  # rc 1, and the caller reports it: a lock we could not take is not a write that failed.
  flock -w "$wait" 7 || {
    echo "kempt: could not take the writers' lock at $WRITER_LOCK_FILE after ${wait}s" >&2
    exec 7>&-
    return 1
  }
}
# The close is wrapped in a group, and the braces are load-bearing: an `exec` with no command
# applies its redirections to the SHELL and keeps them. Written flat as `exec 7>&- 2>/dev/null`,
# releasing this lock also sends the process's own stderr to /dev/null for the rest of its life, so
# every warning after the first `kempt hold`, `unhold` or `config set` goes nowhere. The group's
# redirection is undone with the group; the fd close inside it is still permanent, which is the
# part that was wanted.
writer_unlock() { flock -u 7 2>/dev/null || true; { exec 7>&-; } 2>/dev/null || true; }

config_get() {  # key [default]; explicit default wins, else the kempt_default table
  # config_set's key rule, on the read side too: the key is matched against the file as a pattern,
  # so `s.*` would match the first line and print another setting's value.
  [[ "$1" =~ ^[a-z][a-z0-9_]+$ ]] || { echo "invalid config key: $1" >&2; return 2; }
  if [[ -e "$CONFIG_FILE" && ! -r "$CONFIG_FILE" ]]; then
    echo "warning: $CONFIG_FILE exists but is unreadable, so $1 uses its default" >&2
  fi
  local v
  v="$(grep -s "^$1=" "$CONFIG_FILE" | tail -1 | cut -d= -f2- || true)"
  printf '%s\n' "${v:-${2:-$(kempt_default "$1")}}"
}

config_set() {  # key value [if-absent]
  # With a third argument, the write happens only when the file has no line for the key, decided
  # inside the lock: rc 3 means a line was there and nothing was written. surface_migrate needs it,
  # because a `config set surface` landing between its own check and its write would be overwritten.
  [[ "$1" =~ ^[a-z][a-z0-9_]+$ ]] || { echo "invalid config key: $1" >&2; return 2; }
  [[ "$2" == *$'\n'* ]] && { echo "config value must be single-line" >&2; return 2; }
  kempt_init_dirs
  touch "$CONFIG_FILE"
  # The read below decides what the write puts back, so the two are one critical section: a second
  # writer that reads between them writes this key straight back out. Held to the rename and no
  # further - see writer_lock.
  writer_lock || return 1
  if [[ -n "${3:-}" ]] && grep -qs "^$1=" "$CONFIG_FILE"; then
    writer_unlock
    return 3
  fi
  # The outgoing value, read BEFORE anything is written: "(was false)" is what turns the event line
  # "auto_accept=true" into evidence that the click changed something. Same read config_get does,
  # and it shares config_get's one ambiguity - a stored empty value and an absent key are
  # indistinguishable, and both are reported as `unset`.
  local old
  old="$(grep -s "^$1=" "$CONFIG_FILE" | tail -1 | cut -d= -f2- || true)"
  # Read-then-write: grep completes into a variable BEFORE any write begins, so a failure
  # mid-pipeline can never leave a truncated config behind. rc 1 = "no other lines", allowed.
  local out rc=0
  out="$(grep -v "^$1=" "$CONFIG_FILE")" || rc=$?
  [[ $rc -le 1 ]] || { writer_unlock; return $rc; }
  rc=0
  printf '%s%s=%s\n' "${out:+$out$'\n'}" "$1" "$2" | atomic_write "$CONFIG_FILE" || rc=$?
  # Released before the event line: log_event writes a THIRD file (events.log, with its own
  # retention rewrite), and this lock is for the two user files only.
  writer_unlock
  # Only a write that happened is an event, and the caller's exit status is the WRITE's - never
  # log_event's, which is always 0, and never the lock's.
  [[ $rc -eq 0 ]] && log_event "config set $1=$2 (was ${old:-unset})"
  return $rc
}

# timeout: metadata refresh runs from background checks. Once polkit exists but before the
# action file is installed, pkexec falls back to an auth DIALOG - a background check would hang
# forever waiting on a password nobody is there to type. priv_apply stays untimed on purpose:
# there, interactive auth is the legitimate flow.
# `9>&-` on both: bash sets no FD_CLOEXEC, and a flock lives on the open file description, so it is
# held for as long as ANY descriptor referring to it stays open - a child's included. fd 9 is the
# CHECK lock (cmd_check), so a grandchild outliving the `timeout 120` above goes on holding it: the
# next `kempt check` blocks for the straggler's whole life, and past 60s every check after it
# serves stale state while saying nothing. harvest_offline runs inside that lock too.
# fd 8, the UPDATE lock, is left inherited on purpose - see acquire_lock.
# How long each arm of a metadata refresh (dnf, then Flatpak) may take before the check gives up on
# it. It holds for Flatpak and for a polkit dialog nobody answers, which a background check sits on
# for the full two minutes. It cannot stop dnf5 itself: once pkexec has started the helper, dnf5
# runs as root and SIGTERM from this user gets EPERM. So kempt-refresh bounds makecache itself,
# as root, with the same 120 s (`timeout -k 10 120`). Change one and change the other. The widget's
# CHECK_TIMEOUT_MS allows for both. A seam only so the suite can reach that branch - hardcoded,
# no test could drive it without waiting two minutes, and it had none.
KEMPT_REFRESH_TIMEOUT="${KEMPT_REFRESH_TIMEOUT:-120}"
priv_refresh() { timeout "$KEMPT_REFRESH_TIMEOUT" ${KEMPT_PKEXEC:+$KEMPT_PKEXEC} "$KEMPT_REFRESH_HELPER" "$@" 9>&-; }
priv_apply()   { ${KEMPT_PKEXEC:+$KEMPT_PKEXEC} "$KEMPT_APPLY_HELPER" "$@" 9>&-; }

# kempt-apply exits 3 when it refuses dnf-offline-stage, dnf-offline-arm or dnf-offline-clean because
# of what dnf5 has stored: a Fedora release upgrade, or a transaction-state file it cannot read. It
# also refuses clean while /system-update is there and is not dnf5's link. The
# helper decides that as root, on its own, so the CLI's pre-flight is not the only guard. Nothing ran
# and nothing changed when it does. A caller that sees this status must not unwind with another
# offline verb (the helper refuses that too, for the same reason) and must not advise
# `dnf5 offline clean`, which would delete exactly what the refusal protected.
# shellcheck disable=SC2034 # read by cmd_update in bin/kempt, which sources this file
KEMPT_APPLY_REFUSED=3
apply_refusal_reason() {  # → why the helper refused, as the user's side of the boundary sees it
  local relup
  if relup="$(offline_release_upgrade)"; then
    printf 'a Fedora release upgrade (%s) is stored\n' "$relup"
  elif [[ -e "$KEMPT_OFFLINE_LINK" || -L "$KEMPT_OFFLINE_LINK" ]] && [[ "$(offline_link_state)" != dnf5 ]]; then
    printf 'another updater has prepared the next restart\n'
  else
    printf 'the stored offline transaction could not be read\n'
  fi
}

# The one redactor for text a tool printed that Kempt then shows or keeps: state.json's errors, the
# notification, the history entry and the event log. A password may hold an unencoded "@", so a
# URL loses everything up to the LAST "@" before its host. It also loses its query, its #fragment
# and any path part shaped like a token (16 or more letters and digits with a digit among them, or
# a UUID). A bare user:password@ and any ?query outside a URL go too, and $HOME is written as ~.
# One line out, with no length cap: each caller cuts the result to its own limit.
redact_error_text() {  # stdin → one line
  LC_ALL=C awk '
    function path(p,   o, seg) {
      gsub(/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/, "***", p)
      o = ""
      while (match(p, /[A-Za-z0-9]+/)) {
        seg = substr(p, RSTART, RLENGTH)
        if (RLENGTH >= 16 && seg ~ /[0-9]/) seg = "***"
        o = o substr(p, 1, RSTART - 1) seg
        p = substr(p, RSTART + RLENGTH)
      }
      return o p
    }
    # A ":" before the first "@", ahead of any / ? #, marks userinfo whose password may hold those
    # characters, unless the text starts with "[" or is a dotted host or localhost with a port and a
    # path. Userinfo runs to the last "@": an "@" in the path after it costs the text before it,
    # never a password, since what follows a host can be any punctuation.
    function url(u,   at, pre, c, r, i, auth, rest, q, tail) {
      at = index(u, "@"); pre = (at ? substr(u, 1, at - 1) : "")
      c = index(pre, ":"); r = match(pre, /[\/?#]/) ? RSTART : 0
      if (pre ~ /^\[/ || (match(pre, /^[A-Za-z0-9.-]+:[0-9]+[\/?#]/) \
          && (substr(pre, 1, c - 1) ~ /\./ || substr(pre, 1, c - 1) == "localhost"))) c = 0
      if (at && c && (!r || c < r)) {
        for (i = length(u); i >= at; i--) if (substr(u, i, 1) == "@") { u = substr(u, i + 1); break }
      }
      if (match(u, /[\/?#]/)) { auth = substr(u, 1, RSTART - 1); rest = substr(u, RSTART) }
      else { auth = u; rest = "" }
      for (i = length(auth); i > 0; i--) if (substr(auth, i, 1) == "@") { auth = substr(auth, i + 1); break }
      tail = ""
      if (match(rest, /[?#]/)) {
        q = substr(rest, RSTART); rest = substr(rest, 1, RSTART - 1)
        tail = qtail(q)
      }
      return auth path(rest) tail
    }
    # What follows a removed query: only the closing quotes and brackets that end the word. Anything
    # else after a quote or a bracket is still part of the query, so it cannot leak.
    function qtail(q) { return match(q, /[]"\047()<>]+$/) ? substr(q, RSTART) : "" }
    # The input is capped at 8 KiB, ending on a whole word: the loops below are quadratic.
    BEGIN { cap = 8192 }
    { gsub(/\r/, ""); if (n <= cap) buf = (NR == 1 ? $0 : buf " " $0); n += length($0) + 1 }
    END {
      if (length(buf) > cap) { buf = substr(buf, 1, cap); sub(/[^ \t]*$/, "", buf) }
      s = buf; home = ENVIRON["HOME"]; sub(/\/+$/, "", home)
      if (home != "") {
        o = ""
        while ((i = index(s, home)) > 0) {
          c = substr(s, i + length(home), 1)
          if (c == "" || c !~ /[A-Za-z0-9._-]/) o = o substr(s, 1, i - 1) "~"
          else o = o substr(s, 1, i - 1 + length(home))
          s = substr(s, i + length(home))
        }
        s = o s
      }
      o = ""
      while (match(s, /[A-Za-z][A-Za-z0-9+.-]*:\/\//)) {
        o = o substr(s, 1, RSTART + RLENGTH - 1); s = substr(s, RSTART + RLENGTH)
        if (match(s, /[ \t]/)) { u = substr(s, 1, RSTART - 1); s = substr(s, RSTART) } else { u = s; s = "" }
        # URLs glued with a comma are taken one at a time.
        if (match(u, /,[A-Za-z][A-Za-z0-9+.-]*:\/\//)) { s = substr(u, RSTART) s; u = substr(u, 1, RSTART - 1) }
        o = o url(u)
      }
      s = o s
      gsub(/[^\/@ \t]+:[^\/ \t]*@/, "", s)
      o = ""
      while (match(s, /\?[^ \t]+/)) {
        q = substr(s, RSTART, RLENGTH); o = o substr(s, 1, RSTART - 1); s = substr(s, RSTART + RLENGTH)
        o = o qtail(q)
      }
      s = o s
      sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
      print s
    }'
}

# One line cut to at most N bytes, on a character boundary.
cap_bytes() {  # N; stdin → stdout
  LC_ALL=C cut -b1-"$1" | LC_ALL=C sed -E 's/([\xC0-\xDF]|[\xE0-\xEF][\x80-\xBF]?|[\xF0-\xF7][\x80-\xBF]{0,2})$//'
}

# The end of a captured stderr file as one redacted line of at most 200 bytes, for state.json or a
# warning. The redaction runs before the cut, so a cut can never land inside a credential. A cut
# that lands inside a word drops that word.
stderr_tail() {  # file → one line
  local n
  n="$(wc -c < "$1" 2>/dev/null)" || n=0
  tail -c 4096 "$1" 2>/dev/null \
    | { if (( n > 4096 )); then LC_ALL=C sed -E '1s/^[^[:space:]]*//'; else cat; fi; } \
    | redact_error_text \
    | LC_ALL=C awk '{
        s = $0
        if (length(s) > 200) {
          c = substr(s, length(s) - 200, 1); s = substr(s, length(s) - 199)
          if (c != " ") { i = index(s, " "); s = i ? substr(s, i + 1) : "" }
        }
        sub(/^ +/, "", s); sub(/ +$/, "", s); print s }'
}

# A stderr tail from a privileged call, turned into something a human can act on. `timeout` reports
# a MISSING helper as "timeout: failed to run command '<path>': No such file or directory", which
# reads as "the update check timed out" and sends the reader hunting a network problem they do not
# have; the real cause is a helper that was never installed. Anything else passes through untouched.
# How to put Kempt's own files back. A checkout has install.sh, and a package does not ship it.
reinstall_hint() {  # [again] → the fix for this kind of install, as a sentence without a full stop
  if [[ -r "$KEMPT_ROOT/install.sh" ]]; then
    printf 'Run ./install.sh%s' "${1:+ $1}"
  else
    printf 'Reinstall it with: sudo dnf reinstall kempt'
  fi
}
explain_helper_error() {  # stderr-tail → the tail, the missing-helper message, or an authorization one
  local t="$1" h
  if [[ "$t" == *"No such file"* ]]; then
    for h in "$KEMPT_REFRESH_HELPER" "$KEMPT_APPLY_HELPER"; do
      if [[ "$t" == *"$h"* || "$t" == *"${h##*/}"* ]]; then
        printf '%s\n' "root helper not installed. $(reinstall_hint "") (see: kempt doctor)"
        return 0
      fi
    done
  fi
  # The missing-helper rewrite goes first because it is the more specific claim - it matches a
  # helper path in the text. Everything else goes through the one mapping below.
  friendly_error "$t"
}

# The ONE place a failed authorization becomes words a human is meant to read, used by every
# surface that renders a failure reason: state.json's `error`, the run summary, the notification,
# `kempt history` and the event log. The raw text is never lost; it stays in the run log.
#
# One sentence per thing pkexec can say, and never a claim pkexec's text cannot support:
# - "Request dismissed" (exit 126): the authentication agent reported a cancel, which is a closed
#   dialog.
# - "Not authorized" (exit 127): polkit said no. That is a password that was not accepted, AND a
#   refusal with no dialog at all: both actions set allow_any=no and allow_inactive=no, so an SSH
#   session or a switched-away session is refused without being asked. pkexec prints the same
#   text for both, so the sentence names both. It must never say the user closed a dialog.
# - "No authentication agent found", or pkexec failing to start its own terminal agent (exit 127):
#   a password was needed and nothing could ask for it.
# Anything else passes through untouched: a truthful raw message beats a friendly wrong one.
KEMPT_AUTH_CANCELLED='authentication cancelled'
KEMPT_AUTH_REFUSED='not authorized: the password was refused, or this session cannot authorize (over SSH or switched away)'
KEMPT_AUTH_NO_AGENT='no authentication agent is running to ask for the password'
# - "Error getting authority" (exit 127): pkexec could not reach polkit on the system bus at all,
#   so nothing was asked and nothing could have been authorized.
KEMPT_AUTH_UNREACHABLE='cannot reach polkit (no system bus or polkit service), so nothing can be authorized'
friendly_error() {  # raw text → the same text, or one of the KEMPT_AUTH_* sentences
  case "$1" in
    *"Error getting authority"*)
      printf '%s\n' "$KEMPT_AUTH_UNREACHABLE" ;;
    *"Request dismissed"*)
      printf '%s\n' "$KEMPT_AUTH_CANCELLED" ;;
    *"No authentication agent found"*|*"textual authentication agent"*|*"local authentication agent"*)
      printf '%s\n' "$KEMPT_AUTH_NO_AGENT" ;;
    *"Not authorized"*)
      printf '%s\n' "$KEMPT_AUTH_REFUSED" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Why a run failed, in one line, for the four places that render it - "see <log>" is not an answer
# when the log is four hundred lines of dnf progress. The first line that NAMES a failure, not the
# first line: a package manager's log opens with repository chatter, and reporting "Updating
# repositories" as the reason is worse than silence. Nothing matched → the last non-empty line,
# where a terse failure lands, skipping the `== ... ==` section headings Kempt writes itself (a
# heading is never the reason). Redacted, and capped at 120 characters, because this ends up in a
# notification body.
run_failure_reason() {  # log-file → one line, possibly empty
  local line=""
  [[ -r "$1" ]] || { printf '\n'; return 0; }
  line="$(grep -m1 -iE 'error|fail|not authorized|dismissed|cannot|denied|refused' "$1" || true)"
  [[ -n "$line" ]] || line="$(grep -vE '^[[:space:]]*$|^== .* ==$' "$1" | tail -1 || true)"
  line="${line#"${line%%[![:space:]]*}"}"
  line="$(friendly_error "$line" | redact_error_text)"
  printf '%s\n' "${line:0:120}"
}
notify()       { "$KEMPT_NOTIFY" "$@" >/dev/null 2>&1 || true; }
now_iso()      { date -Is; }

# --- the security notification (notify_security) ----------------------------------------------
# notify, saying whether it worked. A security advisory counts as announced only when a
# notification was delivered: one tried from a timer with no session bus is tried again by the
# next check that has one. Bounded, because a check is waiting on it.
session_bus_present() { [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" || -S "${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]]; }
notify_delivered() { session_bus_present || return 1; timeout "$SECURITY_NOTIFY_TIMEOUT" "$KEMPT_NOTIFY" "$@" >/dev/null 2>&1; }

# The seen file, always as {notified:[ids], acknowledged:[ids]}: missing, damaged or the wrong
# shape reads as empty, which at worst announces a set once more.
security_seen_read() {
  local s
  s="$(jq -c -n '[inputs][0] | if type == "object" then
          {notified: [(.notified // [])[]? | strings], acknowledged: [(.acknowledged // [])[]? | strings]}
        else error("not an object") end' "$SECURITY_SEEN_FILE" 2>/dev/null)" || s=""
  [[ "$s" == \{* ]] || s='{"notified":[],"acknowledged":[]}'
  printf '%s\n' "$s"
}

# What a set of advisories is called when the widget acknowledges it: 16 hex characters of the
# sha256 of the sorted ids, as reclaim_digest names a set of runtimes. Nothing for an empty set.
security_digest() {  # stdin: one id per line → digest, or nothing
  local lines
  lines="$(grep -v '^$' | sort -u)" || true
  [[ -n "$lines" ]] || return 0
  printf '%s\n' "$lines" | sha256sum | cut -c1-16
}

# The block a check publishes as state.json's `security`, and the seen file kept in step with it.
# The caller holds the writers' lock. $1 is dnf_security_parse's answer; $2 and $3 are true when a
# stage is armed and when an update is running, either of which means the panel does not ask.
# An id leaves the seen file only when its package is no longer pending at all (installed, or gone
# from the repositories): a set that shrinks because of a hold and grows back is not news.
# Nothing else bounds the two lists, and nothing must: an id still open that fell out of them would
# be announced again by every check. The ids to announce are read from every open advisory, not
# from the 200 the state publishes, so an id outside that window is announced once like any other.
# Prints the block on the first line and the ids to announce on the second (space separated, and
# empty when there is nothing new). rc≠0 leaves the seen file as it was. $4 false: the caller could
# not take the writers' lock, so the pruned seen file is not written.
security_update() {  # parsed armed busy [write]
  local seen out block fresh digest
  seen="$(security_seen_read)"
  out="$(jq -c --argjson s "$seen" --argjson armed "$2" --argjson busy "$3" '
    def keep($k): [.[] | select(IN($k[]))];
    . as $p
    | ($s.notified | keep($p.known)) as $n
    | ($s.acknowledged | keep($p.known)) as $a
    | {seen: {notified: $n, acknowledged: $a},
       fresh: [($p.open // $p.advisories)[] | select((IN($n[]) or IN($a[])) | not)],
       block: {count: ($p.packages | length), packages: $p.packages, advisories: $p.advisories,
               attention: (([$p.advisories[] | select(IN($a[]) | not)] | length) > 0
                           and ($armed | not) and ($busy | not))}}' <<<"$1" 2>/dev/null)" || return 1
  [[ "$out" == \{* ]] || return 1
  digest="$(jq -r '.block.advisories[]' <<<"$out" | security_digest)"
  block="$(jq -c --arg d "$digest" '.block + {digest: $d}' <<<"$out")" || return 1
  fresh="$(jq -r '.fresh | join(" ")' <<<"$out")" || return 1
  if [[ "${4:-true}" == true && "$(jq -c '.seen' <<<"$out")" != "$seen" ]] && security_seen_writable; then
    jq -c '.seen' <<<"$out" | atomic_write "$SECURITY_SEEN_FILE" 2>/dev/null || true
  fi
  printf '%s\n%s\n' "$block" "$fresh"
}

# Whether ANOTHER process holds the update lock: the probe cmd_run makes, and -E for the reason it
# gives. fd 8 open in this shell is cmd_update's own closing check, after its run, which is not an
# update running.
update_running_elsewhere() {
  [[ -e "$LOCK_FILE" ]] || return 1
  { true >&8; } 2>/dev/null && return 1
  local rc=0
  flock -n -E 75 "$LOCK_FILE" true 2>/dev/null || rc=$?
  [[ $rc -eq 75 ]]
}

# The seen file is a regular file or nothing yet. Anything else there (a directory, say) would take
# atomic_write's rename INTO it and read back as empty, so every check would announce again.
security_seen_writable() { [[ ! -e "$SECURITY_SEEN_FILE" || ( -f "$SECURITY_SEEN_FILE" && ! -L "$SECURITY_SEEN_FILE" ) ]]; }

# Adds ids to one list of the seen file, or with "drop" as $1 takes them back out of it. The caller
# holds the writers' lock. rc 0 only when the file reads back with the change in it, so a caller
# that announces only after a recorded add cannot announce the same ids at every check.
security_seen_add() {  # [drop] list(notified|acknowledged) id...
  local op=add
  [[ "$1" == drop ]] && { op=drop; shift; }
  local list="$1"; shift
  [[ $# -gt 0 ]] || return 0
  security_seen_writable || return 1
  security_seen_read \
    | jq -c --arg l "$list" --arg op "$op" '
        .[$l] = ((.[$l] - $ARGS.positional) + (if $op == "add" then $ARGS.positional else [] end))' \
         --args "$@" \
    | atomic_write "$SECURITY_SEEN_FILE" || return 1
  security_seen_read | jq -e --arg l "$list" --arg op "$op" '
      (.[$l] | map({key: ., value: true}) | from_entries) as $have
      | all($ARGS.positional[]; ($have[.] == true) == ($op == "add"))' --args "$@" >/dev/null 2>&1
}

# The `security check failed` line, at most once a day, as log_refresh_skip does for its own.
log_security_failure() {
  local last=0 now; now="$(date +%s)"
  [[ -f "$SECURITY_FAIL_FILE" ]] && last="$(stat -c %Y "$SECURITY_FAIL_FILE" 2>/dev/null || echo 0)"
  if (( now - last >= 0 && now - last < 86400 )); then return 0; fi
  touch "$SECURITY_FAIL_FILE" 2>/dev/null || true
  log_event "security check failed"
  return 0
}

# The notification's one sentence. The names are the pending items' own, already KEMPT_NAME_RE-clean.
security_notice() {  # stdin: one package name per line → the body
  local names n
  names="$(cat)"
  n="$(grep -c . <<<"$names" || true)"
  [[ "${n:-0}" -gt 0 ]] || return 0
  if [[ "$n" -eq 1 ]]; then
    printf 'A security update is waiting for %s.\n' "$names"
  else
    printf 'Security updates are waiting for %s.\n' "$(names_phrase <<<"$names")"
  fi
}

# --- passwordless polkit rule rendering ---
# Split out of bin/kempt so the render and its self-check are unit-testable without touching
# /etc: the ONLY thing this file's caller then does is hand the result to install(1).
# The rule is rendered, checked and printed from memory, never from a file. The caller pipes that
# output straight into root's install(1), so the bytes root installs are the bytes that were
# checked. A rendered file on disk would be the user's own file, and another process running as the
# user could rewrite it after the check while the authentication dialog waits.
render_passwordless_rule() {  # template_file → the verified rule on stdout, or 2 with nothing printed
  local tmpl="$1" u text
  # $(id -un), never $USER: a crafted USER env var used to be sed-injected into the render and
  # could drop the scope clause. id -un is kernel truth, awk -v never interprets it, and the
  # guard below also keeps the name clear of gsub's replacement metachars (& and backslash).
  u="$(id -un)"
  [[ "$u" =~ ^[a-z_][a-z0-9._-]*$ ]] || {
    echo "unexpected username: $u. Install the rules file manually; see polkit/49-kempt.rules.in" >&2
    return 2; }
  text="$(awk -v u="$u" '{gsub(/@USER@/, u); print}' "$tmpl")" || return 2
  # Printable ASCII, tab and newline only, checked before the comment strip below. That strip
  # splits lines on \n alone, but polkit's JavaScript parser also ends a line at \r, U+2028 and
  # U+2029, so `// note<CR>if (...) return polkit.Result.YES;` is one comment line to the check
  # and live code to polkit. Refusing every other control byte and all non-ASCII closes that class
  # instead of listing its members; the shipped template is plain ASCII.
  if LC_ALL=C grep -q $'[^\t -~]' <<<"$text"; then
    echo "rendered rule contains a control or non-ASCII character, so Kempt will not install it" >&2
    return 2
  fi
  # Self-check by EXACT MATCH against the rule this function is allowed to produce, never by
  # grepping for the clauses that ought to be in it. Greps catch subtraction and miss ADDITION: a
  # template carrying the scope clause, the action id and a single addRule block passes every such
  # test while also carrying, one line earlier inside that same block, an unconditional
  # `if (subject.user == "...") return polkit.Result.YES;` - passwordless root for every polkit
  # action, from any session, including over SSH. This is the one file Kempt can write that grants
  # root, so what reaches install(1) is the one string below or nothing.
  #
  # Comments are stripped and the rest is collapsed to a single whitespace-normalised line, so
  # reflowing or re-indenting the template is fine and changing a token is not. A deliberate
  # change to the rule means changing this string too - which is the review the file deserves.
  local code expected
  code="$(grep -v '^[[:space:]]*//' <<<"$text" | tr '\n' ' ' | tr -s '[:space:]' ' ')"
  code="${code# }"; code="${code% }"
  expected='polkit.addRule(function(action, subject) {'
  expected+=' if (action.id == "io.github.erez_c137.kempt.apply" &&'
  expected+=" subject.user == \"$u\" && subject.active && subject.local) {"
  expected+=' return polkit.Result.YES; } });'
  if [[ "$code" != "$expected" ]]; then
    echo "rendered rule is not the rule this command installs, so Kempt will not install it" >&2
    return 2
  fi
  printf '%s\n' "$text"
}

# --- holds: one "backend:name" per line ---
holds_all() { cat "$HOLDS_FILE" 2>/dev/null || true; }
holds_for() { holds_all | grep "^$1:" | cut -d: -f2- || true; }
hold_add() {  # backend name
  # BEFORE the lock, and it has to stay there: the rejection is the promise cmd_hold's exit status
  # carries (2, not 1), and a name that is refused writes nothing, so it needs no lock to refuse.
  [[ "$2" =~ $KEMPT_NAME_RE ]] || { echo "invalid hold name: $2" >&2; return 2; }
  kempt_init_dirs; touch "$HOLDS_FILE"
  # The append itself is safe unlocked - a short `>>` write lands whole - but the grep in front of
  # it is a check-then-act, and two writers can both read "not there" and both append.
  writer_lock || return 1
  local rc=0
  grep -qxF "$1:$2" "$HOLDS_FILE" || printf '%s:%s\n' "$1" "$2" >> "$HOLDS_FILE" || rc=$?
  writer_unlock
  return $rc
}
hold_remove() {  # backend name
  # Outside the lock on purpose: there is nothing to remove from a file that does not exist, and
  # taking the lock to find that out would make `kempt unhold` create a state directory on a box
  # that has never held anything.
  [[ -f "$HOLDS_FILE" ]] || return 0
  # The read-modify-write with the worst odds of the three: each writer drops ONE line from the
  # copy it read, so a writer that read early puts every line its neighbours removed back.
  writer_lock || return 1
  # Read-then-write, same reasoning as config_set: never truncate before the read succeeds.
  local out rc=0
  out="$(grep -vxF "$1:$2" "$HOLDS_FILE")" || rc=$?
  [[ $rc -le 1 ]] || { writer_unlock; return $rc; }
  rc=0
  printf '%s' "${out:+$out$'\n'}" | atomic_write "$HOLDS_FILE" || rc=$?
  writer_unlock
  return $rc
}
mark_held() {  # backend; stdin: JSON [{name,from,to}] → adds held:bool
  local holds_json
  holds_json="$(holds_for "$1" | jq -Rn '[inputs]')"
  # The items arrive on STDIN, which has no size limit; only the holds cross argv, and that list is
  # the user's own - written a package at a time by `kempt hold`, read back here. Nothing about the
  # size of the pending set can grow it, so it stays an argument.
  # `.name as $n` is load-bearing: jq evaluates the argument of index() against index()'s own
  # input ($holds, an array), so an inline `index(.name)` dies with "Cannot index array".
  # -c here and on every stage between the backend and the state file: these are intermediates
  # nobody reads by hand, and indentation is a third of the bytes at two thousand packages.
  jq -c --argjson holds "$holds_json" '[.[] | .name as $n | . + {held: (($holds | index($n)) != null)}]'
}

# stdin: items JSON (AFTER mark_held) → one session-critical name per line.
# Held packages are excluded on purpose: the user already declined that one, so recommending a
# whole different update strategy because of it would be nagging about a decision already made.
# Second stage drops build/doc tails: kernel-devel, qt6-qtbase-devel, kf6-*-doc and friends are
# never loaded by the running session, so they cannot break it - counting them turns an ordinary Qt
# bump into a hundred-package "session-critical" scare.
# `|| true`: grep exits 1 when it selects nothing, and "nothing risky" is the common, happy case.
# family_label <family> → a plain-language name for it, or "" when Kempt has nothing honest to say.
#
# "mesa" is a package name, not a word. The person being asked whether to update a graphics driver
# while the desktop is running cannot answer that question if the row does not say what the thing
# IS - and asking someone to make a safety decision in vocabulary they do not have is how a warning
# gets clicked through.
#
# Only the families Kempt itself ships in the DEFAULT risky_regex appear here. risky_regex is
# user-configurable (and KEMPT_RISKY_RE overrides it), so a label is never derived, guessed or
# pattern-matched from a name: an unknown family prints bare, which is honest, rather than wearing a
# description somebody invented for it. Keys are FAMILIES as families_of derives them - the name up
# to its first - or . - so plasma-workspace keys as "plasma" and kwin-x11 as "kwin".
family_label() {
  case "$1" in
    kernel)   echo "the Linux kernel" ;;
    systemd)  echo "the service manager" ;;
    glibc)    echo "the core system library" ;;
    dbus)     echo "the system message bus" ;;
    mesa)     echo "graphics drivers" ;;
    qt6)      echo "the desktop toolkit" ;;
    kf6)      echo "KDE framework libraries" ;;
    plasma)   echo "the Plasma desktop" ;;
    kwin)     echo "the window manager" ;;
    *)        echo "" ;;
  esac
}

risky_names() {
  local re="${KEMPT_RISKY_RE:-$(config_get risky_regex)}"
  jq -r '.[] | select(.held|not) | .name' \
    | grep -E "$re" \
    | grep -vE -- '-(devel|headers|static|tools|doc)($|-)|-macros' || true
}

# --- snapshot diff: before/after TSV, sorted by name with ONE row per name → report JSON ---
# Producers MUST pipe through collapse_versions first. Fedora keeps several versions of installonly
# packages (kernel* families, gpg-pubkey), so a raw rpm listing repeats names and join emits a CROSS
# PRODUCT: hundreds of phantom "updated" rows over a package set that did not move (the figures are
# in docs/architecture.md). The guard below refuses that input loudly instead of reporting fiction.
tsv_diff_updates() {  # before_file after_file
  local f
  for f in "$1" "$2"; do
    awk -F'\t' 'prev == $1 { exit 65 } { prev = $1 }' "$f" \
      || { echo "tsv_diff_updates: duplicate names in $f (run through collapse_versions)" >&2; return 65; }
  done
  # WHAT CHANGED and WHAT TO SHOW are two different questions, and answering both with the version
  # string made Kempt report "no package changes" after a run that really updated a Flatpak runtime:
  # the commit moved, the version did not, and the two snapshot rows were byte-identical. Measured on
  # a real box, 2026-09-19, log line "Updating runtime/org.gtk.Gtk3theme.Orchis-Dark/x86_64/3.22".
  #
  # So each row may carry a third field, its IDENTITY, and that is what decides whether it moved.
  # The report still carries the VERSIONS, because that is what a person reads. A file with two
  # fields is normalised to identity = version, which is exactly what dnf wants and what every
  # snapshot written by an older Kempt already is - no migration, and an old offline marker's stored
  # baseline still diffs correctly.
  local n1 n2 out rc=0
  n1="$(mktemp)"; n2="$(mktemp)"
  awk -F'\t' '{ id = (NF >= 3 && $3 != "") ? $3 : $2; print $1 "\t" $2 "\t" id }' "$1" > "$n1"
  awk -F'\t' '{ id = (NF >= 3 && $3 != "") ? $3 : $2; print $1 "\t" $2 "\t" id }' "$2" > "$n2"
  out="$({
    # `$3"" != $5""` forces STRING comparison: awk compares two numeric-looking fields
    # numerically, which makes a real 1.1 → 1.10 bump compare equal and vanish from the report.
    join -t "$(printf '\t')" -o '0,1.2,1.3,2.2,2.3' "$n1" "$n2" \
      | awk -F'\t' '$3"" != $5"" {print "U\t"$1"\t"$2"\t"$4}'
    join -t "$(printf '\t')" -v2 "$n1" "$n2" | awk -F'\t' '{print "A\t"$1"\t\t"$2}'
    join -t "$(printf '\t')" -v1 "$n1" "$n2" | awk -F'\t' '{print "R\t"$1"\t"$2"\t"}'
  } | jq -cRn '
    [inputs | split("\t")] |
    { updated: [.[] | select(.[0]=="U") | {name:.[1], from:.[2], to:.[3]}],
      added:   [.[] | select(.[0]=="A") | {name:.[1], to:.[3]}],
      removed: [.[] | select(.[0]=="R") | {name:.[1], from:.[2]}] }')" || rc=$?
  rm -f "$n1" "$n2"
  [[ $rc -eq 0 ]] || return $rc
  printf '%s\n' "$out"
}

# --- download sizes ---
# Joined by NAME, never by name+version: an item's `to` can be a comma-joined EVR list when
# multilib twins diverge ("5.3.9-4.fc44,5.3.10-1.fc44"), so it is not a usable key, and dnf_sizes
# has already folded its side to one row per name. Name is the only key both sides agree on.
# An item with no row keeps NO size_bytes key at all - not a zero. "Absent" has to stay
# distinguishable from "free", because absent is what suppresses the figure downstream.
attach_sizes() {  # $1 = sizes TSV; stdin: items JSON (after mark_held) → items + optional size_bytes
  jq -c --rawfile tsv "$1" '
    ($tsv | split("\n") | map(select(length>0) | split("\t"))
          | map({key: .[0], value: (.[1] | tonumber)}) | from_entries) as $sz
    # An item carrying a `branch` is keyed by name AND branch, because its name alone is not its
    # identity: a Flatpak runtime installed on two branches is two rows that update independently,
    # and joined by name they would both take whichever of the two size rows landed in the table.
    # An item without one keys by name exactly as before, so nothing that predates the key moves.
    # A per-user Flatpak item is keyed with the user: prefix its size row carries, so an id installed
    # in both installations takes its own size (backends/flatpak.sh, KEMPT_FLATPAK_USER_KEY).
    | def szkey: (if .scope == "user" then "user:" else "" end)
                 + (if (.branch // "") == "" then .name else .name + "/" + .branch end);
      map(. + (if $sz[szkey] != null then {size_bytes: $sz[szkey]} else {} end))'
}

# ALL or nothing, per backend: a total computed over the items that happen to have sizes looks
# authoritative and is quietly short by however much the unpriced ones weigh - the one failure mode
# a download estimate must not have, because the user cannot see what was left out. Held items are
# excluded because Kempt passes --exclude= for them and their bytes are never fetched; zero
# non-held items is honestly 0.
backend_download_bytes() {  # stdin: items JSON → bytes, or "" when coverage is incomplete
  jq -r '[.[] | select(.held | not)] as $a
         | [$a[] | select(has("size_bytes"))] as $k
         | if ($a | length) == ($k | length) then ($k | map(.size_bytes) | add // 0) else "" end'
}

# --- state assembly ---
# State schema v1 - FROZEN. This JSON is a public interface (the widget and any scripted reader
# consume it), so additive changes only; anything else bumps `schema`.
assemble_state() {  # $1 dnf items, $2 fp items, $3 status, $4 error, $5 fp_enabled(true|false), $6 prev last_success ISO or "", $7 risky_pending JSON array (optional), $8 reboot_needed true|false (optional), $9 dnf download bytes or "" (optional), $10 flatpak download bytes or "" (optional), $11 offline_staged JSON object or "" (optional), $12 release_upgrade JSON object or "" (optional), $13 image_based true or null (optional), $14 metadata_refreshed ISO or "" (optional)
  # The two item arrays arrive through FILES, never --argjson. Linux caps a SINGLE argv entry at
  # 128 KiB (MAX_ARG_STRLEN), and the pending list is the one input here with no bound: at 925
  # packages this exec failed, errexit killed the check before it printed or wrote anything, and
  # bash reported 126 - which the widget reads as "no engine", so a working install told the user
  # to reinstall a package they already had. A box far enough behind to need Kempt most is exactly
  # the box that reached it. Everything else here is a scalar or a small array and stays in argv.
  # --slurpfile, not --rawfile: it parses, so a malformed payload still fails as JSON rather than
  # arriving as a string. It wraps in an array, hence the [0] at the use sites.
  local _dnf_f _fp_f _out_f rc=0
  _dnf_f="$(mktemp)"; _fp_f="$(mktemp)"; _out_f="$(mktemp)"
  printf '%s' "$1" > "$_dnf_f"; printf '%s' "$2" > "$_fp_f"
  jq -n --slurpfile dnfa "$_dnf_f" --slurpfile fpa "$_fp_f" --arg status "$3" --arg error "$4" \
        --argjson fpe "$5" --arg pls "$6" --argjson risky "${7:-[]}" \
        --argjson reboot "${8:-false}" --arg dnfb "${9:-}" --arg fpb "${10:-}" \
        --argjson offst "${11:-null}" --argjson relup "${12:-null}" \
        --argjson img "${13:-null}" --arg mrf "${14:-}" \
        --arg now "$(now_iso)" '
    # The two item arrays arrive as one-element arrays because --slurpfile wraps what it reads.
    ($dnfa[0]) as $dnf | ($fpa[0]) as $fp |
    # b is the backend total as a STRING, "" meaning not known. Empty adds no key at all, which is
    # what a schema-1 reader that predates this feature is guaranteed to keep seeing.
    def wrap(e; b): {enabled: e,
                  actionable: ([.[] | select(.held|not)] | length),
                  held:       ([.[] | select(.held)] | length),
                  items: .}
                 + (if b == "" then {} else {download_bytes: (b | tonumber)} end);
    # The top-level figure exists only when every ENABLED backend produced one. A backend switched
    # off must not suppress it: its items are not going to be fetched either.
    def total: if $dnfb == "" then {}
               elif $fpe and $fpb == "" then {}
               else {download_bytes: (($dnfb | tonumber)
                                      + (if $fpe then ($fpb | tonumber) else 0 end))} end;
    # Absent, not null, when nothing is staged: the key existing at all is what every reader tests,
    # and a null would make "no staged transaction" and "a staged transaction we know nothing
    # about" the same shape.
    def staged: if $offst == null then {} else {offline_staged: $offst} end;
    # Absent when there is none, for the same reason as staged above. NOT part of offline_staged:
    # that key describes the transaction KEMPT staged, and a release upgrade is by definition one
    # it did not - the two can even be true at once for a moment, which is the state the refusal in
    # cmd_update and the marker-drop in reconcile_stage_after_live_run exist to end.
    def relupgrade: if $relup == null then {} else {release_upgrade: $relup} end;
    # true or absent, never false: this says "dnf is not how this machine updates", and a box where
    # it IS has nothing to declare. A reader that has never heard of the key behaves correctly on
    # every ordinary Fedora by doing nothing, which is what an additive key has to mean.
    def imagebased: if $img == null then {} else {image_based: $img} end;
    # When the metadata behind these counts was FETCHED, which is not when the check ran: a check
    # answers from the cache, so a fresh check over week-old metadata is exactly the state this
    # key exists to make visible. Absent when nothing has ever been fetched on this box - a
    # different fact from "old", and one a reader has to be able to word differently.
    def metadata: if $mrf == "" then {} else {metadata_refreshed: $mrf} end;
    {schema: 1, last_check: $now,
     last_success: (if $status == "ok" then $now elif $pls == "" then null else $pls end),
     status: $status, error: $error,
     backends: {dnf: ($dnf | wrap(true; $dnfb)), flatpak: ($fp | wrap($fpe; $fpb))},
     actionable: (($dnf + $fp) | [.[] | select(.held|not)] | length),
     held_total: (($dnf + $fp) | [.[] | select(.held)] | length),
     risky_pending: $risky,
     reboot_needed: $reboot}
    + total + staged + relupgrade + imagebased + metadata' > "$_out_f" || rc=$?
  # Removed on every path, and jq's status still reaches the caller unchanged: a failed assembly
  # must fail the check exactly as it did when the payload came through argv.
  rm -f "$_dnf_f" "$_fp_f"
  [[ $rc -eq 0 ]] || { rm -f "$_out_f"; return $rc; }
  cat "$_out_f"; rm -f "$_out_f"
}

# Must survive a corrupt state file: a truncated, garbage or wrong-shaped state.json reaching
# --argjson as invalid JSON kills the whole check with jq rc 2/5 - the one moment the fallback
# exists for. Every bad shape degrades to [].
state_prev_items() {  # backend → previous items array; [] for missing/corrupt/wrong-shaped state
  local out
  out="$(jq -c -n --arg b "$1" '[inputs][0].backends[$b].items? // []
                                 | if type=="array" then . else [] end' "$STATE_FILE" 2>/dev/null)"
  [[ "$out" == \[* ]] && printf '%s\n' "$out" || echo '[]'
}

# The one door into state.json, so the guard lives here rather than in cmd_check. Callers run
# `cmd_check || true`, which turns errexit off inside it: a failed assemble_state then arrives here
# as an empty string. Anything but exactly one JSON object keeps the previous state.
# atomic_write's per-process mktemp keeps overlapping checks (timer, event watch, post-run) apart.
write_state() {
  local doc
  doc="$(cat)"
  jq -e -n '[inputs] | length == 1 and (.[0] | type == "object")' <<<"$doc" >/dev/null 2>&1 || {
    echo "kempt: not writing $STATE_FILE: the new state is not a single JSON object, so the previous one stays" >&2
    return 1
  }
  # state.lock, so a write never lands inside publish_staged_state's read and write. That caller
  # already holds it and says so with _KEMPT_STATE_LOCK_HELD, a shell global never exported. A lock not taken in 10 seconds is skipped.
  # A lock file that cannot be opened is skipped, and the write still happens.
  if [[ "$_KEMPT_STATE_LOCK_HELD" == 1 ]]; then
    printf '%s\n' "$doc" | atomic_write "$STATE_FILE"
    return
  fi
  local lfd rc=0
  if { exec {lfd}>>"$STATE_LOCK_FILE"; } 2>/dev/null; then flock -w 10 "$lfd" || true; else lfd=""; fi
  printf '%s\n' "$doc" | atomic_write "$STATE_FILE" || rc=$?
  if [[ -n "$lfd" ]]; then { exec {lfd}>&-; } 2>/dev/null || true; fi
  return "$rc"
}

# When the metadata behind a check was last fetched, from the stamp the fetch leaves. Empty when
# nothing has ever been fetched on this box - a different thing from "old", and every surface that
# renders it says the two differently.
metadata_refreshed_iso() {  # → ISO 8601 with offset, or nothing
  local f; f="$(metadata_stamp_file)"
  [[ -f "$f" ]] || return 0
  date -Is -r "$f" 2>/dev/null || true
}

# The dnf stamp, and only that one. The shared stamp moves when a Flatpak fetch alone lands, so on
# a box whose dnf fetch never worked it would date dnf's metadata by Flatpak's. No dnf stamp means
# no date, and metadata_refreshed is then left out of the state.
metadata_stamp_file() {
  printf '%s\n' "$LAST_REFRESH_DNF_FILE"
}

# ...and its age in whole days, for the surfaces that put a number in a sentence. Nothing at all
# when there is no stamp, so a caller cannot mistake "never fetched" for "fetched today".
metadata_age_days() {  # → whole days, or nothing
  local at now f; f="$(metadata_stamp_file)"
  [[ -f "$f" ]] || return 0
  at="$(stat -c %Y "$f" 2>/dev/null)" || return 0
  now="$(date +%s)"
  # A stamp in the future is today, not a negative age - the same reading the interval gate gives
  # its own stamp, and "refreshed -1 days ago" is worse than a rounding error.
  (( now > at )) || { printf '0\n'; return 0; }
  printf '%s\n' "$(( (now - at) / 86400 ))"
}

# A skipped refresh, said ONCE A DAY. A laptop on battery skips every check it runs - every ten
# minutes, all day - so a line per skip would be 144 lines saying one thing, in the one file
# somebody greps to find out what Kempt has been doing. The fact worth recording is not that this
# check skipped; it is that this box has been skipping. Best-effort throughout, like log_event
# itself: a refresh that could not be announced must never change what the check does.
log_refresh_skip() {  # reason
  local last=0 now; now="$(date +%s)"
  [[ -f "$REFRESH_SKIP_FILE" ]] && last="$(stat -c %Y "$REFRESH_SKIP_FILE" 2>/dev/null || echo 0)"
  # A stamp in the future is due, for the reason the interval gate gives below.
  if (( now - last >= 0 && now - last < 86400 )); then return 0; fi
  kempt_init_dirs 2>/dev/null || true
  touch "$REFRESH_SKIP_FILE" 2>/dev/null || true
  log_event "refresh skipped ($1)"
  return 0
}

# Whether dnf5's system cache holds metadata for at least one repository the check can read.
# A cache directory you cannot read or enter counts as usable: it is there, only not yours to list.
dnf_cache_usable() {
  local f
  if [[ -d "$KEMPT_DNF_CACHE_DIR" && ( ! -r "$KEMPT_DNF_CACHE_DIR" || ! -x "$KEMPT_DNF_CACHE_DIR" ) ]]; then
    return 0
  fi
  for f in "$KEMPT_DNF_CACHE_DIR"/*/repodata/repomd.xml; do
    [[ -r "$f" ]] && return 0
  done
  return 1
}

maybe_refresh_metadata() {  # [force] [anyway] - ≤ every 3h, AC power, unmetered; never blocks check on failure
  # Why this check fetched nothing: battery or metered when a fetch was due, off when refreshing
  # is turned off, else empty. cmd_check publishes it as refresh_skipped, so the widget can tell a
  # skipped fetch from a failed one, and does not read an old failure marker as this check's.
  REFRESH_SKIPPED=""
  local force="${1:-}" anyway="${2:-}"
  # The off switch wins over --anyway too. Said on stderr, as the lock wait says it, so a typed
  # `kempt check --anyway` does not look as if it fetched.
  if [[ -n "${KEMPT_SKIP_REFRESH:-}" ]]; then
    REFRESH_SKIPPED=off
    [[ "$anyway" != anyway ]] \
      || echo "warning: nothing was downloaded; KEMPT_SKIP_REFRESH turns fetching off" >&2
    return 0
  fi
  local last=0 now; now="$(date +%s)"
  # `|| echo 0` covers the TOCTOU gap: the file can vanish between the -f test and the stat
  # (state dir cleanup, another process), and a bare failing stat escapes errexit here.
  [[ -f "$LAST_REFRESH_FILE" ]] && last="$(stat -c %Y "$LAST_REFRESH_FILE" || echo 0)"
  # A stamp in the future (a clock corrected backwards, a home restored onto a machine whose clock
  # is behind) is due, not recent: read as a refresh a moment ago it holds every refresh off until
  # the clock catches up. The stamp at the bottom rewrites it to now once a fetch lands.
  #
  # `kempt check --refresh` passes THIS gate and nothing below it. The interval is a courtesy to
  # the mirrors, and somebody standing at the machine asking for fresh metadata may overrule it.
  # The battery and metering rules below spend this person's power and data, so only `anyway`
  # passes them: `kempt check --anyway`, typed or pressed, for this one check. Nothing automatic
  # may pass it, and it is never exported, so cmd_check's internal callers cannot inherit it.
  # due_fp is the shared gate. dnf has one exception: while the latest dnf refresh failed and there
  # is no cache to check against (no dnf refresh ever worked, or the cache is gone), the dnf arm is
  # tried again once the failure is 15 minutes old (the marker's mtime; one in the future counts as
  # old). A Flatpak fetch beside it would otherwise hold dnf off for 3 hours, and a retry at every
  # check would fetch every repo every few minutes. With a cache, a failing one waits for the gate.
  local due_fp=1 due_dnf
  if [[ "$force" != force ]] && (( now - last >= 0 && now - last < 10800 )); then due_fp=0; fi
  due_dnf=$due_fp
  if (( ! due_fp )) && [[ -f "$REFRESH_DNF_FAILED_FILE" ]] \
     && { [[ ! -f "$LAST_REFRESH_DNF_FILE" ]] || ! dnf_cache_usable; }; then
    local failed_at
    failed_at="$(stat -c %Y "$REFRESH_DNF_FAILED_FILE" 2>/dev/null || echo 0)"
    if (( now - failed_at < 0 || now - failed_at >= 900 )); then due_dnf=1; fi
  fi
  (( due_fp || due_dnf )) || return 0
  # An override is logged every time, because each one spent power or data somebody asked to spend.
  if on_battery; then
    if [[ "$anyway" != anyway ]]; then REFRESH_SKIPPED=battery; log_refresh_skip "on battery"; return 0; fi
    log_event "refresh anyway (on battery)"
  fi
  if metered_connection; then
    # shellcheck disable=SC2034  # read by cmd_check in bin/kempt, which sources this file
    if [[ "$anyway" != anyway ]]; then REFRESH_SKIPPED=metered; log_refresh_skip "the connection is metered"; return 0; fi
    log_event "refresh anyway (the connection is metered)"
  fi
  # ONE gate, two arms. Both backends are refresh-then-read-cache, so both fetch here and neither
  # carries its own interval, power or metering rule - a second gate would be a second policy to
  # keep in step with this one. `ok` records whether ANY fetch landed; see the stamp at the bottom.
  local ok=0
  # Logged as its own step, because a failure here is invisible everywhere else: the check that
  # follows carries on against the cached metadata and reports status "ok", so a box whose metadata
  # has not refreshed for a week looks exactly like one that is up to date. The two skipped paths
  # above emit nothing - nothing was attempted. dnf's stderr is kept only as one redacted line in the
  # failure marker (see refresh_error_line), which the next check publishes beside its own result.
  local errf
  if (( due_dnf )); then
    errf="$(mktemp)"
    local rc=0
    priv_refresh refresh >/dev/null 2>"$errf" || rc=$?
    if (( rc == 0 )); then
      ok=1
      touch "$LAST_REFRESH_DNF_FILE" || true
      rm -f "$REFRESH_DNF_FAILED_FILE" || true
      log_event "refresh ok"
    else
      refresh_error_line "$errf" "$rc" > "$REFRESH_DNF_FAILED_FILE" 2>/dev/null || true
      log_event "refresh failed"
    fi
    rm -f "$errf"
  fi
  # Gated on include_flatpak: fetching flathub's summary for a backend the user switched off is
  # network nobody asked for, on the one code path whose entire job is to be careful with it. The
  # arm runs independently of dnf's verdict - they fail for unrelated reasons (a declined
  # authentication against an unreachable remote), so one failing must not cancel the other. And it
  # stays unprivileged: flatpak_refresh runs as this user, never through priv_refresh, so the
  # no-dialog polkit action remains dnf-only.
  if (( due_fp )) && is_true "$(config_get include_flatpak)"; then
    if flatpak_refresh; then
      ok=1
      log_event "refresh flatpak ok"
    else
      log_event "refresh flatpak failed"
    fi
  fi
  # Stamped when ANY arm succeeded, never per-arm and never only on a clean sweep. The marker
  # rate-limits the NETWORK step, so a flatpak summary just fetched must not be fetched again on
  # the next check merely because dnf's makecache failed - which would cost a box with one broken
  # repo a full re-fetch of everything every few minutes, forever.
  # A dnf retry outside the gate leaves the stamp alone, so it cannot postpone the next Flatpak fetch.
  if (( ok && due_fp )); then
    touch "$LAST_REFRESH_FILE" || true
  fi
  return 0
}

# One line of a failed dnf refresh, for state.json. The first line naming an error (librepo's
# "Curl error (6): ..." says what went wrong), else dnf5's first ">>> " status line (it carries an
# HTTP status), else the end of the output. Each goes through redact_error_text. A refresh that
# printed nothing is named by its exit status (124 is `timeout`). At most 200 bytes.
refresh_error_line() {  # stderr file, exit status → one line
  local line
  line="$(grep -m1 -i 'error' "$1" 2>/dev/null)" || line=""
  [[ -n "$line" ]] || line="$(grep -m1 '^>>> ' "$1" 2>/dev/null)" || line=""
  if [[ -n "$line" ]]; then
    line="$(printf '%s\n' "$line" | redact_error_text)"
  else
    line="$(stderr_tail "$1")"
  fi
  line="$(printf '%s\n' "$line" | sed -E 's/^[[:space:]>]+//; s/[[:space:]]+$//')"
  if [[ -z "$line" ]]; then
    if [[ "$2" == 124 ]]; then line="dnf makecache timed out"
    else line="dnf makecache exited with status $2"; fi
  fi
  printf '%s\n' "$line" | cap_bytes 200
}

on_battery() {
  local ps
  for ps in /sys/class/power_supply/BAT*/status; do
    [[ -e "$ps" ]] && grep -q Discharging "$ps" && return 0
  done
  return 1
}

metered_connection() {
  busctl get-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager \
    org.freedesktop.NetworkManager Metered 2>/dev/null | grep -qE ' (1|3)$'
}

# --- update lock (our own concurrency; foreign rpm lock handled by retry in cmd_update) ---
# flock on a held fd, the same mechanism cmd_check uses. A PID file needs a staleness heuristic and
# lies both ways: a SIGKILLed holder leaves a lock nobody owns, a recycled PID makes a dead lock
# look alive. The kernel releases this one when the fd closes, however the holder died.
#
# Scope, precisely: fd 8 is inherited, so the lock lives as long as the run OR ANY CHILD THAT STILL
# HOLDS THE FD - the terminal surface's `tee` in apply_with_retry holds it for the whole live-output
# run, and release_lock in the parent does not end it until tee exits. That is wanted (the update is
# not over until its output is), but "the lock is free" then answers a question about the whole
# process tree, not about one PID.
#
# If a PID or timestamp record is ever added to this file, open it with `exec 8<>"$LOCK_FILE"`,
# never `8>`: the `>` form TRUNCATES on open, so the next process to merely ATTEMPT the lock
# would erase the live holder's record before finding out it cannot have the lock.
acquire_lock() {
  kempt_init_dirs
  exec 8>"$LOCK_FILE"
  flock -n 8
}
release_lock() { flock -u 8 2>/dev/null || true; { exec 8>&-; } 2>/dev/null || true; }  # braces: see writer_unlock

# --- stage lock ------------------------------------------------------------------------------------
# fd 6 (7, 8 and 9 are taken, see writer_lock). `kempt update` holds it from the moment it asks dnf5
# to build an offline transaction until the marker describing that transaction is written. For that
# whole stretch dnf5's record and Kempt's marker disagree, because Kempt is in the middle of
# replacing one with the other - and a check comparing them then (reconcile_replaced_stage) would
# announce Kempt's own rebuild as somebody else's.
# Exclusive and WAITED for on the stage's side, shared and only TRIED on the check's: the check
# holds it for a few milliseconds, and a stage that refused instead of waiting would fail a click
# over nothing. Best-effort on both sides, because all it guards is an announcement: a stage that
# cannot take it stages anyway, and a check that cannot take it compares nothing this time.
# `>>`, never `>`, for acquire_lock's reason.
stage_lock()     { { exec 6>>"$STAGE_LOCK_FILE"; } 2>/dev/null || return 0; flock -w 30 6 2>/dev/null || true; }
stage_lock_try() {
  { exec 6>>"$STAGE_LOCK_FILE"; } 2>/dev/null || return 1
  flock -n -s 6 2>/dev/null && return 0
  { exec 6>&-; } 2>/dev/null || true
  return 1
}
stage_unlock()   { flock -u 6 2>/dev/null || true; { exec 6>&-; } 2>/dev/null || true; }

# The boot session. A staged transaction can only be applied by a REBOOT, so the marker records
# this and the harvest compares: same session means the stage is still pending, whatever else
# happened to the rpm database in the meantime. "unknown" (no procfs) degrades to the old
# snapshot-comparison behaviour rather than blocking the harvest forever.
current_boot_id() {
  [[ -n "$KEMPT_BOOT_ID" ]] && { printf '%s\n' "$KEMPT_BOOT_ID"; return 0; }
  cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown
}

# What dnf5 says about the staged transaction, in one word. Only `ready` (armed: /system-update
# exists and the next boot installs it) and `absent` are acted on, but anything else dnf5 writes
# passes through unflattened, so a status this build has never heard of reaches `kempt doctor` as
# itself instead of as a guess. `download-complete` is the one that matters: staged, downloaded,
# never armed, and indistinguishable from `ready` to anything that only looks at the marker.
# grep/sed, not a toml parser: the file is dnf5's, read and never written, and one quoted scalar
# does not justify a dependency. The line anchor keeps it honest - `status` is the ninth of eleven
# keys, and a reader taking the first quoted value would answer with the rpmdb cookie.
# One quoted string out of dnf5's transaction-state file. TOML, read with sed rather than a
# parser, because there is no TOML parser Kempt may depend on and the file is dnf5's own flat
# output rather than anything a person hand-writes: one table, one `key = "value"` per line.
offline_toml_value() {  # key → its value, or nothing; rc 1 if the file cannot be read
  [[ -r "$KEMPT_OFFLINE_TOML" ]] || return 1
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
    "$KEMPT_OFFLINE_TOML" 2>/dev/null | head -1
}

# A fingerprint of the stored transaction as it sits on disk: size, mtime to the nanosecond and
# content hash of both the toml and transaction.json. Both files are 0644 in a 0755 directory, so
# the user reads them with no privileged call. Nothing when the toml cannot be read, which callers
# treat as "cannot compare" and never as "unchanged".
# It exists for one question: did a `dnf5 upgrade --offline` that exited 0 store anything? With a
# transaction already stored and every pending update excluded, dnf5 prints "Nothing to do.",
# exits 0 and leaves the old transaction exactly as it was, files untouched, so the next restart
# installs all of it - the package just held included. A real stage rewrites both files, and the
# mtime catches a rewrite whose content happens to match.
offline_stored_fingerprint() {  # → one opaque line, or nothing
  [[ -r "$KEMPT_OFFLINE_TOML" ]] || return 0
  local f
  for f in "$KEMPT_OFFLINE_TOML" "$KEMPT_OFFLINE_TXJSON"; do
    if [[ -r "$f" ]]; then
      printf '%s %s ' "$(stat -c '%s %.9Y' "$f" 2>/dev/null)" "$(sha256sum < "$f" 2>/dev/null | cut -d' ' -f1)"
    else
      printf 'unreadable '
    fi
  done
  printf '\n'
}

# Is this an image-based Fedora, where rpm-ostree owns /usr and dnf is not how the system updates?
# It matters because NOTHING ELSE gives it away: Kinoite ships dnf5 and plasma-workspace, so both
# Kempt packages install cleanly, the widget appears, `dnf5 check-update` lists updates and
# `dnf5 upgrade` resolves a transaction rather than refusing. Every surface then describes a
# package-based machine that is not there.
on_ostree() { [[ -e "$KEMPT_OSTREE_MARKER" ]]; }

offline_system_status() {  # → ready | absent | dnf5's own status word
  local s
  s="$(offline_toml_value status)" || { printf 'absent\n'; return 0; }
  printf '%s\n' "${s:-absent}"
}

# Is the transaction dnf5 has stored a Fedora RELEASE upgrade rather than an ordinary offline
# update? They share ONE stored transaction and one set of commands - `dnf5 offline reboot` arms
# whichever is there - so this is the only thing that tells them apart, and getting it wrong is
# expensive in both directions: staging over a release upgrade destroys it, and refusing to stage
# over an ordinary transaction would break the rebuild that holds depend on.
#
# A COMPARISON, never a presence test. Both keys are in every state_version 2 file, and for an
# ordinary offline upgrade they are EQUAL - tests/fixtures/offline-ready.toml, captured from a real
# one, carries "44" in both. Measured against real dnf5 on Fedora 44:
#
#   dnf5 upgrade --offline               system_releasever = "44"  target_releasever = "44"
#   dnf5 system-upgrade download --releasever=45
#                                        system_releasever = "44"  target_releasever = "45"
offline_release_upgrade() {  # → 0 and prints "44 -> 45" when one is stored
  local from to
  from="$(offline_toml_value system_releasever)" || return 1
  to="$(offline_toml_value target_releasever)" || return 1
  [[ -n "$from" && -n "$to" && "$from" != "$to" ]] || return 1
  printf '%s -> %s\n' "$from" "$to"
}

# ...and whether that upgrade is ARMED, which is a different question and the one every SENTENCE
# about it turns on. `dnf5 system-upgrade download` leaves status "download-complete": the packages
# are on disk, /system-update does not exist, and no restart installs anything. Only
# `dnf5 system-upgrade reboot` writes "ready". A user can sit at download-complete for days, and it
# is where a release upgrade spends most of its life.
# The REFUSAL above deliberately does not ask this - staging over a downloaded transaction destroys
# it just as thoroughly as over an armed one - but "it installs on the next restart" is false here,
# and saying it sends somebody to restart a machine that will come back exactly as it was.
# FIVE states, and they are NOT dnf5's four status words rearranged. Arming is two things -
# `dnf5 offline reboot` writes the status AND creates /system-update - and systemd removes the
# symlink once system-update.target is reached - so one status word splits into three states, while
# every word meaning "did not finish" collapses into one. So:
#
#   downloaded  status `download-complete`: the packages are on disk and nothing has armed them.
#               Where `dnf5 system-upgrade download` leaves one, and where a box can sit for days.
#   armed       `ready` AND dnf5's symlink: the next restart installs it.
#   foreign     `ready`, and the symlink is another updater's: the next restart runs that instead.
#   stranded    `ready` and NO symlink: a restart has already walked past it, and no later one will
#               run it either - only re-arming can.
#   incomplete  any other word, including one this build has never seen: dnf5 recorded a
#               transaction that did not finish, and `dnf5 offline log` is what explains it.
#
# Collapsing any of them into another is how a sentence ends up disproving itself:
# "downloaded but not started (status ready)" says the opposite of the word it quotes, and
# "installs on the next restart" promises something no restart will do. offline_staged_state
# refuses to publish Kempt's OWN stage in the stranded state for the same reason.
# lstat, never resolved: system-update-generator does not resolve it either.
offline_release_upgrade_state() {  # → downloaded | armed | stranded | foreign | incomplete
  case "$(offline_system_status)" in
    # `foreign`: `ready`, with the symlink pointing at another updater's prepared update. That
    # restart is the other updater's, and dnf5 exits without running anything ("Another offline
    # transaction tool is running"). A reader that does not know the word treats it as downloaded,
    # which promises nothing.
    ready)
      case "$(offline_link_state)" in
        dnf5)  printf 'armed\n' ;;
        other) printf 'foreign\n' ;;
        *)     printf 'stranded\n' ;;
      esac ;;
    download-complete) printf 'downloaded\n' ;;
    # download-incomplete, transaction-incomplete, and any word a later dnf5 invents. NOT folded
    # into `downloaded`: "has been downloaded" quoting a status of `download-incomplete` says the
    # opposite of the word it quotes, and for a transaction that started and stopped half way
    # `dnf5 system-upgrade reboot` is the wrong advice as well as a false promise - dnf5 answers
    # "System is not ready for offline transaction" and points at `dnf5 offline log`.
    # The four words are dnf5 5.4.3's own (ready, download-complete, download-incomplete,
    # transaction-incomplete); an unknown fifth lands here, which promises nothing.
    *)                 printf 'incomplete\n' ;;
  esac
}

# The same four states answer for ANY stored transaction, Kempt's own included, and `armed` is the
# only one a restart installs. Every reader that publishes a stage as pending asks this and never
# the status alone: any live dnf5 transaction, run in a terminal outside Kempt, removes
# /system-update and leaves the toml at `ready`, which is `stranded` - a stage no restart runs.
offline_armed() { [[ "$(offline_release_upgrade_state)" == armed ]]; }

# Whose the boot symlink is: none, dnf5's (it points at dnf5's offline directory), or another
# updater's. PackageKit replaces the symlink whenever it prepares an update, while dnf5 only
# creates one when none is there, so a dnf5 stage can be `ready` behind PackageKit's symlink.
# The text of the link decides, or the same file reached another way: dnf5's own check before it
# runs a transaction is std::filesystem::equivalent, which `-ef` mirrors.
offline_link_state() {  # → none | dnf5 | other
  [[ -L "$KEMPT_OFFLINE_LINK" ]] || { printf 'none\n'; return 0; }
  local t
  t="$(readlink "$KEMPT_OFFLINE_LINK" 2>/dev/null)" || t=""
  if [[ -n "$t" && "${t%/}" == "${KEMPT_OFFLINE_DATADIR%/}" ]] \
     || [[ "$KEMPT_OFFLINE_LINK" -ef "$KEMPT_OFFLINE_DATADIR" ]]; then
    printf 'dnf5\n'
  else
    printf 'other\n'
  fi
}

# rpm's version comparison (rpmvercmp in rpm's lib/rpmvercmp.c), for one version or release field.
# Written out here rather than asked of rpm: the tests run on boxes with no rpm at all, and this is
# the rule a newer build is told by. Segments are runs of digits or of letters, anything else
# separates them; digits beat letters, a longer number beats a shorter one, and `~` sorts before
# everything (1.0~rc1 is older than 1.0) while `^` sorts after the end (1.0^git1 is newer than 1.0
# and older than 1.0.1).
rpm_vercmp() {  # a b → prints -1, 0 or 1
  local LC_ALL=C   # byte order, as rpm's strcmp has it, and not the locale's
  local a="$1" b="$2" sa sb isnum
  if [[ "$a" == "$b" ]]; then printf '0\n'; return 0; fi
  while [[ -n "$a" || -n "$b" ]]; do
    while [[ -n "$a" && "${a:0:1}" != [[:alnum:]~^] ]]; do a="${a:1}"; done
    while [[ -n "$b" && "${b:0:1}" != [[:alnum:]~^] ]]; do b="${b:1}"; done
    if [[ "${a:0:1}" == "~" || "${b:0:1}" == "~" ]]; then
      if [[ "${a:0:1}" != "~" ]]; then printf '1\n'; return 0; fi
      if [[ "${b:0:1}" != "~" ]]; then printf -- '-1\n'; return 0; fi
      a="${a:1}"; b="${b:1}"; continue
    fi
    if [[ "${a:0:1}" == "^" || "${b:0:1}" == "^" ]]; then
      if [[ -z "$a" ]]; then printf -- '-1\n'; return 0; fi
      if [[ -z "$b" ]]; then printf '1\n'; return 0; fi
      if [[ "${a:0:1}" != "^" ]]; then printf '1\n'; return 0; fi
      if [[ "${b:0:1}" != "^" ]]; then printf -- '-1\n'; return 0; fi
      a="${a:1}"; b="${b:1}"; continue
    fi
    [[ -n "$a" && -n "$b" ]] || break
    if [[ "${a:0:1}" == [0-9] ]]; then
      isnum=1; sa="${a%%[^0-9]*}"; sb="${b%%[^0-9]*}"
    else
      isnum=0; sa="${a%%[^[:alpha:]]*}"; sb="${b%%[^[:alpha:]]*}"
    fi
    a="${a:${#sa}}"; b="${b:${#sb}}"
    # A run of digits against a run of letters: the digits are newer.
    if [[ -z "$sb" ]]; then
      if (( isnum )); then printf '1\n'; else printf -- '-1\n'; fi
      return 0
    fi
    if (( isnum )); then
      sa="${sa#"${sa%%[^0]*}"}"; sb="${sb#"${sb%%[^0]*}"}"   # leading zeros do not count
      if (( ${#sa} != ${#sb} )); then
        if (( ${#sa} > ${#sb} )); then printf '1\n'; else printf -- '-1\n'; fi
        return 0
      fi
    fi
    if [[ "$sa" != "$sb" ]]; then
      if [[ "$sa" < "$sb" ]]; then printf -- '-1\n'; else printf '1\n'; fi
      return 0
    fi
  done
  if [[ -z "$a" && -z "$b" ]]; then printf '0\n'
  elif [[ -n "$a" ]]; then printf '1\n'
  else printf -- '-1\n'; fi
}

# Two EVRs written `epoch:version-release`, the epoch always present: the epoch as a number, then
# the version, then the release, each by rpm_vercmp.
rpm_evrcmp() {  # e:v-r e:v-r → prints -1, 0 or 1
  local ea="${1%%:*}" eb="${2%%:*}" va="${1#*:}" vb="${2#*:}" ra rb c
  ra="${va##*-}"; rb="${vb##*-}"; va="${va%-*}"; vb="${vb%-*}"
  if (( 10#$ea != 10#$eb )); then
    if (( 10#$ea > 10#$eb )); then printf '1\n'; else printf -- '-1\n'; fi
    return 0
  fi
  c="$(rpm_vercmp "$va" "$vb")"
  if [[ "$c" != 0 ]]; then printf '%s\n' "$c"; return 0; fi
  rpm_vercmp "$ra" "$rb"
}

# Has the stored transaction already happened, by whatever means? Every package it installs must
# be installed at its staged version or a newer one, and every package it removes must be gone.
# This tells "another updater installed the same updates" apart from a stage that could not run:
# PackageKit can prepare the same packages and install them on the restart, leaving dnf5's state at
# `ready` for a transaction nothing will run. It prepares them when it gets round to it, often
# hours after Kempt staged, so a package with a newer build in between arrives newer.
# Compared per name and architecture (an installonly kernel matches when any installed build is
# the staged one or newer), with the epoch written out on both sides (transaction.json leaves out
# epoch 0), by rpm's own ordering (rpm_evrcmp).
#   Upgrade, Install   installed at the staged EVR or newer
#   Downgrade          installed at exactly the staged EVR: a newer one means it did not happen
#   Reinstall          installed at the staged EVR or newer, and proves nothing on its own
#   Remove             that exact build no longer installed, unless it is installonly
# Anything less is not satisfied: a partial install, a file that does not read, or a transaction
# with nothing in it that shows it ran (empty, or only reinstalls, which an untouched box passes).
# Whether a package name is one dnf keeps several builds of (installonly). dnf5's defaults are
# provides (installonlypkg(kernel), installonlypkg(kernel-module)), so rpm resolves them to the
# installed names, akmod and kmod builds included. When rpm names nothing, the kernel families
# below stand in. Plain names in the config's `installonlypkgs` are added either way.
offline_installonly_rpm_names() {  # → installed names providing installonlypkg(...), one per line
  local out
  if [[ -n "$KEMPT_RPM_INSTALLONLY_CMD" ]]; then
    # Unquoted for dnf_sizes' reason (backends/dnf.sh): a seam may carry its own arguments.
    # shellcheck disable=SC2086
    out="$($KEMPT_RPM_INSTALLONLY_CMD 2>/dev/null)" || true
  else
    # rc 1 when a provide has no package, with the names for the others still printed.
    out="$(rpm -q --qf '%{NAME}\n' --whatprovides 'installonlypkg(kernel)' 'installonlypkg(kernel-module)' \
      'installonlypkg(vm)' 'multiversion(kernel)' 2>/dev/null)" || true
  fi
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ $KEMPT_NAME_RE ]]; then printf '%s\n' "$line"; fi
  done <<<"$out" | sort -u
}

offline_installonly_name() {  # name → 0 when installonly
  # Asked once per process: a transaction can name many builds.
  if [[ -z "${_KEMPT_INSTALLONLY_RPM+x}" ]]; then
    _KEMPT_INSTALLONLY_RPM="$(offline_installonly_rpm_names)"
  fi
  if [[ -n "$_KEMPT_INSTALLONLY_RPM" ]]; then
    grep -qxF -- "$1" <<<"$_KEMPT_INSTALLONLY_RPM" && return 0
  else
    case "$1" in
      kernel|kernel-core|kernel-modules|kernel-modules-*|kernel-devel|kernel-devel-matched \
        |kernel-uki-virt|kernel-uki-virt-*|kernel-debug|kernel-debug-*|kernel-rt|kernel-rt-* \
        |kernel-64k|kernel-64k-*|kernel-16k|kernel-16k-*|kernel-PAE|kernel-PAE-*) return 0 ;;
    esac
  fi
  [[ -r "$KEMPT_DNF_CONF" ]] || return 1
  local line v tok
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*installonlypkgs[[:space:]]*=(.*)$ ]] || continue
    v="${BASH_REMATCH[1]//,/ }"
    for tok in $v; do
      [[ "$tok" =~ $KEMPT_NAME_RE && "$tok" == "$1" ]] && return 0
    done
  done < "$KEMPT_DNF_CONF"
  return 1
}

offline_stage_satisfied() {  # → 0 when the stored transaction's changes are all on the box
  [[ -r "$KEMPT_OFFLINE_TXJSON" ]] || return 1
  local sz want have line
  sz="$(stat -c %s "$KEMPT_OFFLINE_TXJSON" 2>/dev/null || echo 0)"
  (( sz > 0 && sz <= KEMPT_TXJSON_MAX_BYTES )) || return 1
  # The shape guards of offline_txjson_names: any surprise is an error, and then no answer.
  # One line per entry that matters: action, name.arch, epoch:version-release.
  want="$(jq -r -n '
      def norm($n):
        [ $n | capture("^(?<n>.+)-((?<e>[0-9]+):)?(?<v>[^-:]+)-(?<r>[^-:]+)\\.(?<a>[^.-]+)$") ]
        | if length != 1 then error("nevra") else .[0] end
        | "\(.n).\(.a)\t\(.e // "0"):\(.v)-\(.r)";
      ([inputs][0] // error("no document")) as $t
      | if ($t | type) != "object" then error("not an object") else . end
      | ($t.version // "1.0") as $v
      | if ($v | type) != "string" or ($v | startswith("1.") | not) then error("version") else . end
      | ($t.rpms) as $r
      | if ($r | type) != "array" then error("rpms") else . end
      | [ $r[]
          | if type != "object" then error("entry") else . end
          | if (.nevra | type) != "string" then error("nevra") else . end ] as $entries
      | $entries[]
      | select(.action as $a | ["Upgrade","Install","Downgrade","Reinstall","Remove"] | index($a) != null)
      | "\(.action)\t\(norm(.nevra))"' "$KEMPT_OFFLINE_TXJSON" 2>/dev/null)" || return 1
  [[ -n "$want" ]] || return 1
  if [[ -n "$KEMPT_RPM_QA_CMD" ]]; then
    # Unquoted for dnf_sizes' reason (backends/dnf.sh): a seam may carry its own arguments.
    # shellcheck disable=SC2086
    have="$($KEMPT_RPM_QA_CMD 2>/dev/null)" || return 1
  else
    have="$(rpm -qa --queryformat '%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null)" || return 1
  fi
  [[ -n "$have" ]] || return 1
  # Installed builds by name.arch, each `epoch:version-release`, newline-separated.
  local -A inst=()
  local n e vr a key
  local nevra_re='^(.+)-([0-9]+):([^-:]+-[^-:]+)\.([^.-]+)$'
  while IFS= read -r line; do
    [[ "$line" =~ $nevra_re ]] || continue
    n="${BASH_REMATCH[1]}"; e="${BASH_REMATCH[2]}"; vr="${BASH_REMATCH[3]}"; a="${BASH_REMATCH[4]}"
    inst["$n.$a"]+="$e:$vr"$'\n'
  done <<<"$have"
  local action evr got proof=false found c
  while IFS=$'\t' read -r action key evr; do
    found=false
    while IFS= read -r got; do
      [[ -n "$got" ]] || continue
      case "$action" in
        Downgrade|Remove) [[ "$got" == "$evr" ]] && { found=true; break; } ;;
        *) c="$(rpm_evrcmp "$got" "$evr")"; [[ "$c" != -1 ]] && { found=true; break; } ;;
      esac
    done <<<"${inst[$key]:-}"
    case "$action" in
      # dnf5 removes the oldest installonly build to stay within installonly_limit. Another
      # updater may keep it, which leaves the stage's upgrades installed and that build behind.
      # So a kept installonly build does not block, and proves nothing either.
      Remove) if [[ "$found" == false ]]; then proof=true
              elif ! offline_installonly_name "${key%.*}"; then return 1; fi ;;
      Reinstall) [[ "$found" == true ]] || return 1 ;;
      *) [[ "$found" == true ]] || return 1; proof=true ;;
    esac
  done <<<"$want"
  [[ "$proof" == true ]]
}

# offline_stage_satisfied, asked about the stage a marker records. It reads dnf5's stored
# transaction, and once a check has found that replaced, the stored one is somebody else's: its
# packages being installed says nothing about Kempt's stage.
offline_marker_stage_satisfied() {  # marker-json → 0 when the stage it records is installed
  jq -e '.replaced == true' <<<"$1" >/dev/null 2>&1 && return 1
  offline_stage_satisfied
}

# One gate for every package name Kempt writes down or prints, and it is KEMPT_NAME_RE - the same
# shape a hold is validated against and the root helper mirrors. Shared because the staged set can
# come from two places (dnf5's stored transaction, or the check made just before staging) and a name
# from either ends up in jq, in the shell, in QML and on a terminal.
# ALL or nothing, deliberately: a caller that dropped the one bad name would be left holding a list
# it could still use to say "this package is not in the transaction" - a denial made on evidence
# that has already proved untrustworthy.
# Empty stdin is vacuously valid; the callers, not this, decide whether an empty list may deny.
names_all_valid() {  # stdin: one name per line → 0 when every line passes KEMPT_NAME_RE
  local n
  # `|| [[ -n "$n" ]]`: read returns 1 on a final line with no newline after it, having already
  # filled $n. Without that arm the LAST name is never tested - the one position a gate must not
  # have a hole in.
  while IFS= read -r n || [[ -n "$n" ]]; do
    [[ "$n" =~ $KEMPT_NAME_RE ]] || return 1
  done
  return 0
}

# What the stored transaction will INSTALL, by name, sorted and deduplicated - or nothing at all.
#
# The one rule that shapes every branch below: a list from here is allowed to make Kempt stay
# SILENT about a held package, so anything short of a clean parse must produce no list rather than
# a short one. Hence rc 1 plus empty output for every surprise, and callers that fall back
# (`names="$(offline_txjson_names)" || ...`) rather than treating "" as "nothing staged".
#
# Actions: dnf5 records each upgraded package TWICE - the incoming build as `Upgrade`, the outgoing
# one as `Replaced`. Only the four actions that put a package on the disk are read; `Replaced`,
# `Remove` and `Removed` take one AWAY, and a user who held a package being removed is already
# getting what they asked for.
#
# The name is read out of the nevra from the RIGHT - drop `.arch`, then `-release`, then
# `-[epoch:]version` - because neither end is safe from the left: package names carry hyphens
# (ca-certificates, kernel-core, qt6-qtbase-common) and an epoch puts a `1:` inside the version
# field where a left-to-right reader would not expect one.
#
# The count jq emits ahead of the names is not decoration: a nevra carrying a newline would reach a
# line-based caller as two names, each passing the gate on its own; comparing the count against the
# lines received refuses that.
#
# Size cap: KEMPT_TXJSON_MAX_BYTES, its own and not the marker's, because this file is dnf5's and
# grows with the transaction - roughly 200 bytes per entry, two entries per upgraded package, so a
# 1 MB cap would refuse an ordinary 2,500-package update. 8 MB is past any transaction a desktop
# stages and still refuses a file that is not a record. Past it: no list, and Kempt warns
# generically instead of denying a conflict - the safe direction.
# The name out of a nevra, as a jq definition shared by the two readers of dnf5 package records:
# the stored transaction above and the transaction history below. dnf5 writes the epoch into one
# and not the other (`curl-0:8.18.0-10.fc44.x86_64` in history, no `0:` in transaction.json), which
# reading from the right does not care about.
# Single quotes on purpose: `$n` and `$p` are jq variables, and the shell must not expand them.
# shellcheck disable=SC2016
KEMPT_JQ_NEVRA_NAME='
  def basename($n):
    ($n | sub("\\.[^.]*$"; "") | split("-")) as $p
    | if ($p | length) < 3 then "" else ($p[0:-2] | join("-")) end;'
offline_txjson_names() {  # → sorted unique names, or nothing with a non-zero status
  [[ -r "$KEMPT_OFFLINE_TXJSON" ]] || return 1
  local sz
  sz="$(stat -c %s "$KEMPT_OFFLINE_TXJSON" 2>/dev/null || echo 0)"
  (( sz > 0 && sz <= KEMPT_TXJSON_MAX_BYTES )) || return 1
  local out
  # `error` for every surprise, so jq's own exit status carries the degradation out - one mechanism
  # instead of a shape check per branch on the shell side. `[inputs][0]` is the corrupt-tolerance
  # state_prev_items and offline_marker_read use: a multi-document or truncated file dies inside jq
  # rather than out here.
  out="$(jq -r -n "$KEMPT_JQ_NEVRA_NAME"'
      ([inputs][0] // error("no document")) as $t
      | if ($t | type) != "object" then error("not an object") else . end
      | ($t.version // "1.0") as $v
      | if ($v | type) != "string" or ($v | startswith("1.") | not) then error("version") else . end
      | ($t.rpms) as $r
      | if ($r | type) != "array" then error("rpms") else . end
      # Checked over the WHOLE array, not only the entries that survive the action filter: an entry
      # shaped differently from what we expect is a record we cannot claim to have read.
      | [ $r[]
          | if type != "object" then error("entry") else . end
          | if (.nevra | type) != "string" then error("nevra") else . end ] as $entries
      # `.action as $a` first, for the index() trap mark_held carries the note about.
      | [ $entries[]
          | select(.action as $a | ["Upgrade","Install","Downgrade","Reinstall"] | index($a) != null)
          | basename(.nevra) ]
      | unique
      | (length | tostring), .[]' "$KEMPT_OFFLINE_TXJSON" 2>/dev/null)" || return 1
  local n rest
  n="${out%%$'\n'*}"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  (( n == 0 )) && return 0
  rest="${out#*$'\n'}"
  [[ "$out" == *$'\n'* ]] || return 1
  [[ "$(grep -c '' <<<"$rest")" == "$n" ]] || return 1
  names_all_valid <<<"$rest" || return 1
  printf '%s\n' "$rest"
}

# --- transaction identity --------------------------------------------------------------------------
# WHICH dnf5 transaction a stage is. When dnf5 builds an offline transaction it writes two facts into
# its state toml: `rpmdb_cookie`, a hash of the rpm database the transaction was built against, and
# `cmd_line`, the command that built it. The marker records both. Before the restart they are
# compared with the toml as it is now; after the restart they are looked up in dnf5's transaction
# history, where the applied transaction carries the same command as `command_line` (in `history
# list`) and the cookie as `rpmdb_version_begin` (in `history info`). Verified against dnf5 5.4.3 in
# a Fedora 44 container: `dnf5 offline _execute`, the command the offline boot runs, recorded exactly
# that pair, and a stage on its own records no history entry at all.
#
# The format-stability rule holds for every read here. A value that is not the shape dnf5 writes
# today is not recorded and not compared, so a dnf5 that changes either format costs Kempt the
# identity and leaves the harvest doing what it did before the identity existed. It must never cost
# a wrong attribution.

# Kempt's own stage command is `dnf5 upgrade --offline -y --exclude=<name>...`, every name through
# KEMPT_NAME_RE. The charset is wider than that and still excludes a quote and a backslash, the two
# characters offline_toml_value cannot carry through intact.
KEMPT_CMD_LINE_RE='^[A-Za-z0-9._+=:/,@*-]+( [A-Za-z0-9._+=:/,@*-]+)*$'

# The identity dnf5 recorded for the transaction it holds now, as JSON with only the keys that read
# cleanly: `{}` when neither did. Absent rather than empty, like every marker field.
offline_toml_identity() {  # → {rpmdb_cookie?, cmd_line?}
  local cookie cmd
  cookie="$(offline_toml_value rpmdb_cookie)" || cookie=""
  cmd="$(offline_toml_value cmd_line)" || cmd=""
  [[ "$cookie" =~ ^[0-9a-f]{64}$ ]] || cookie=""
  if (( ${#cmd} > 4096 )) || [[ ! "$cmd" =~ $KEMPT_CMD_LINE_RE ]]; then cmd=""; fi
  jq -cn --arg c "$cookie" --arg l "$cmd" \
    '(if $c == "" then {} else {rpmdb_cookie: $c} end) + (if $l == "" then {} else {cmd_line: $l} end)'
}

# Before the restart: is the transaction dnf5 holds now a different one from the stage this marker
# records? Three differences, any one enough - another cookie (built against another rpm database),
# another command, or another package set - printed one per line, rc 0. rc 1 when there is none or
# nothing could be compared.
# Only a marker that recorded a cookie is asked at all, so a marker from an older build keeps exactly
# the behaviour it had. Each difference needs BOTH sides read: a value that could not be read is not
# a difference. The live command is compared raw, because a command Kempt did not write is allowed to
# be any shape and is a difference whatever shape it is. The package sets are compared only when the
# marker's list came from the transaction, for doctor_staged_drift_row's reason: a check-derived list
# disagrees with the stored transaction routinely and legitimately.
offline_stage_replaced() {  # marker-json → differences, one per line
  local mc ml lc ll names rec live_sorted diffs=""
  mc="$(jq -r '.rpmdb_cookie // empty | strings' <<<"$1" 2>/dev/null || true)"
  [[ "$mc" =~ ^[0-9a-f]{64}$ ]] || return 1
  ml="$(jq -r '.cmd_line // empty | strings' <<<"$1" 2>/dev/null || true)"
  lc="$(offline_toml_value rpmdb_cookie)" || return 1
  ll="$(offline_toml_value cmd_line)" || ll=""
  if [[ "$lc" =~ ^[0-9a-f]{64}$ && "$lc" != "$mc" ]]; then diffs+="rpmdb cookie"$'\n'; fi
  if [[ -n "$ml" && -n "$ll" && "$ll" != "$ml" ]]; then diffs+="command"$'\n'; fi
  if jq -e '(.staged_names_source? == "transaction") and ((.staged_names | type) == "array")' \
       <<<"$1" >/dev/null 2>&1 && names="$(offline_txjson_names)"; then
    rec="$(jq -r '.staged_names[] | strings' <<<"$1" 2>/dev/null | sed '/^$/d' | LC_ALL=C sort -u)"
    live_sorted="$(printf '%s\n' "$names" | sed '/^$/d' | LC_ALL=C sort -u)"
    if [[ "$live_sorted" != "$rec" ]]; then diffs+="packages"$'\n'; fi
  fi
  [[ -n "$diffs" ]] || return 1
  printf '%s' "$diffs"
}

# dnf5's transaction history, as it serves it to an unprivileged reader: the database is 0644, and
# `history list --json` and `history info <id> --json` both answer as an ordinary user with nothing
# on stderr (verified in the same container). `-C --disablerepo='*'`: the answer is local, and this
# runs inside a check that must never reach the network. `timeout`, for the same reason.
dnf_history_json() {  # list | info <id> → dnf5's JSON; non-zero when it did not answer
  # Unquoted for dnf_sizes' reason (backends/dnf.sh): a seam may carry its own arguments.
  # shellcheck disable=SC2086
  timeout 30 $KEMPT_DNF_HISTORY_CMD -C --disablerepo='*' history "$@" --json </dev/null 2>/dev/null
}

# Where dnf5's history stands right now: its highest id, or 0 for a history with nothing in it. The
# id is a counter dnf5 only ever raises, so a reading taken before a run and the list read after it
# are between them the window that run happened in. rc 1 when the list did not read in the shape
# this build knows, which is what makes a live run fall back to the snapshot diff it reported before
# any of this existed.
dnf_history_max_id() {  # → highest id; rc 1 = cannot tell
  local list out
  list="$(dnf_history_json list)" || return 1
  out="$(jq -r -n '
      ([inputs][0] // error("no document")) as $l
      | if ($l | type) != "array" then error("not an array") else . end
      | [ $l[]
          | if type != "object" then error("entry") else . end
          | if (.id | type) != "number" or (.id | floor) != .id or .id < 0
            then error("id") else .id end ]
      | max // 0' <<<"$list" 2>/dev/null)" || return 1
  [[ "$out" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$out"
}

# ONE history entry, read the way both lookups below need one: dnf5 asked for that id alone, the
# answer checked to BE that id, and its package list split into the two lists callers ask for -
# what it INSTALLED (the transaction's own set, comparable with a stage's staged_names) and what it
# TOUCHED (that set plus everything it replaced or removed). Printed as
#
#   <rpmdb_version_begin>
#   --installed
#   <names>
#   --touched
#   <names>
#
# The two section heads are lines no package name can be (KEMPT_NAME_RE refuses a leading "-"), and
# every name is checked against it before any of this comes back. rc 1 when dnf5 did not answer or
# answered in a shape this build does not know - so the caller cannot tell, which is the answer
# that costs precision and never truth.
history_entry_lists() {  # id → cookie, --installed, names, --touched, names
  local info res installed touched
  info="$(dnf_history_json info "$1")" || return 1
  res="$(jq -r -n --argjson id "$1" "$KEMPT_JQ_NEVRA_NAME"'
      ([inputs][0] // error("no document")) as $i
      | if ($i | type) != "array" or ($i | length) != 1 then error("shape") else . end
      | $i[0] as $e
      | if ($e | type) != "object" or $e.id != $id then error("id") else . end
      | if ($e.rpmdb_version_begin | type) != "string"
           or ($e.rpmdb_version_begin | test("^[0-9a-f]{64}$") | not) then error("cookie") else . end
      | if ($e.packages | type) != "array" then error("packages") else . end
      | [ $e.packages[]
          | if type != "object" or (.nevra | type) != "string" or (.action | type) != "string"
            then error("package") else . end ] as $p
      | $e.rpmdb_version_begin,
        "--installed",
        ([ $p[] | select(.action as $a | ["Upgrade","Install","Downgrade","Reinstall"] | index($a) != null)
                | basename(.nevra) ] | unique | .[]),
        "--touched",
        ([ $p[] | basename(.nevra) ] | unique | .[])' <<<"$info" 2>/dev/null)" || return 1
  [[ "$res" == *$'\n'--installed$'\n'* || "$res" == *$'\n'--installed ]] || return 1
  installed="$(sed -n '/^--installed$/,/^--touched$/p' <<<"$res" | sed '1d;$d')"
  touched="$(sed -n '/^--touched$/,$p' <<<"$res" | sed '1d')"
  printf '%s' "$installed" | names_all_valid || return 1
  printf '%s' "$touched" | names_all_valid || return 1
  printf '%s\n' "$res"
}

# How long dnf5 recorded transaction <id> taking, in whole seconds. rc 1 when the entry does not read
# as a span (no times, or an end before the start), so the caller leaves the duration out.
dnf_history_duration() {  # id → seconds; rc 1 = unknown
  local info
  info="$(dnf_history_json info "$1")" || return 1
  jq -e -r -n --argjson id "$1" '
      ([inputs][0] // error("no document")) as $i
      | if ($i | type) != "array" or ($i | length) != 1 then error("shape") else $i[0] end
      | if .id != $id then error("id") else . end
      | if (.start_time | type) != "number" or (.end_time | type) != "number"
           or .end_time < .start_time then error("times") else (.end_time - .start_time | floor) end
    ' <<<"$info" 2>/dev/null
}

# The same question for a LIVE run, where it is far simpler to ask: nothing has to survive a restart,
# so the identity is just the id the history stood at before the apply and the command Kempt ran.
#
#   <id>\n<names>  Exactly one entry arrived after that id running exactly that command. The lines
#                  after the id are every package name it touched.
#   rc 1           Cannot tell, and the run is then reported from its two snapshots, the way it was
#                  before this lookup existed.
#
# NO cookie here, and none is needed: the window is not a guess. dnf5 holds its own lock for the
# length of the transaction, so an entry that both arrived inside the window and ran Kempt's command
# is Kempt's - unless there are TWO of them, which is what an apply that was retried leaves behind.
# Then either answer is a guess about which attempt the report describes, and a guess is exactly
# what this is for avoiding. Same rule as the stage's: more than one candidate is cannot tell.
live_history_attribution() {  # before-id command-line → id, then names; rc 1 = cannot tell
  local before="$1" cmd="$2" list out n id res touched
  [[ "$before" =~ ^[0-9]+$ && -n "$cmd" ]] || return 1
  list="$(dnf_history_json list)" || return 1
  # Every entry shape-checked, not only the candidates, and the command compared in here: a list
  # with one entry dnf5 shaped differently is a list this build cannot claim to have read, and a
  # command line carrying a tab or a newline must never meet the line-based reader below.
  out="$(jq -r -n --argjson before "$before" --arg cmd "$cmd" '
      ([inputs][0] // error("no document")) as $l
      | if ($l | type) != "array" then error("not an array") else . end
      | [ $l[]
          | if type != "object" then error("entry") else . end
          # null is what dnf5 records for a transaction PackageKit ran: another command, never
          # the one Kempt ran. Any other type is a shape this build does not know.
          | if (.id | type) != "number" or (.id | floor) != .id or .id < 0
               or ((.command_line | type) as $c | $c != "string" and $c != "null")
            then error("fields") else . end
          | select(.id > $before and .command_line == $cmd) ]
      | (length | tostring), (.[] | .id | tostring)' <<<"$list" 2>/dev/null)" || return 1
  n="${out%%$'\n'*}"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  (( n == 1 )) || return 1
  id="${out#*$'\n'}"; id="${id%%$'\n'*}"
  [[ "$id" =~ ^[0-9]+$ ]] || return 1
  res="$(history_entry_lists "$id")" || return 1
  touched="$(sed -n '/^--touched$/,$p' <<<"$res" | sed '1d')"
  printf '%s\n%s\n' "$id" "$touched"
}

# After the restart: did the stage this marker records run, and which history entry is it?
#
#   applied <id>  Exactly one entry began at the recorded cookie and ran the recorded command. The
#                 lines after the verdict are every package name that entry touched.
#   did-not-run   The history answered in full and none of it can be the stage: nothing began at
#                 the cookie, or what did ran another command with another package set. Also the
#                 answer for a marker the check before the restart already found `replaced`.
#   rc 1          Cannot tell. The caller then does exactly what it did before identity existed.
#
# "did-not-run" is a claim, so it needs evidence, and three things are required before it is made.
# Every entry since the stage was read in a shape this build knows. dnf5 recorded at least one of
# them: the package set moved across the restart, so a history with nothing in it is not telling
# the whole story. And no entry is the one shape a dnf5 that recorded its commands differently
# would leave, an entry that began at the cookie with another command and the SAME packages the
# marker recorded - that one is cannot-tell, never evidence either way.
#
# The window opens a day before `staged_at`. The offline transaction runs early in boot, before the
# clock has been synced, and a real-time clock kept in local time (as on a machine that also boots
# Windows) can put it hours before the stage. The cookie is the identity; the window only keeps the
# lookup small, and past 20 entries it gives up rather than asking dnf5 twenty times.
offline_history_attribution() {  # marker-json → verdict, then names; rc 1 = cannot tell
  if jq -e '.replaced == true' <<<"$1" >/dev/null 2>&1; then printf 'did-not-run\n'; return 0; fi
  local cookie cmd at since list out n
  cookie="$(jq -r '.rpmdb_cookie // empty | strings' <<<"$1" 2>/dev/null || true)"
  cmd="$(jq -r '.cmd_line // empty | strings' <<<"$1" 2>/dev/null || true)"
  at="$(jq -r '.staged_at // empty | strings' <<<"$1" 2>/dev/null || true)"
  [[ "$cookie" =~ ^[0-9a-f]{64}$ && -n "$cmd" && -n "$at" ]] || return 1
  since="$(date -d "$at" +%s 2>/dev/null)" || return 1
  [[ "$since" =~ ^[0-9]+$ ]] || return 1
  list="$(dnf_history_json list)" || return 1
  # Every entry is shape-checked, not only the ones inside the window: a list with one entry dnf5
  # shaped differently is a list this build cannot claim to have read. The command comparison
  # happens in here so a command line carrying a tab or a newline never meets a line-based reader.
  out="$(jq -r -n --argjson since "$since" --arg cmd "$cmd" '
      ([inputs][0] // error("no document")) as $l
      | if ($l | type) != "array" then error("not an array") else . end
      | [ $l[]
          | if type != "object" then error("entry") else . end
          # A null command_line is a PackageKit transaction: another command, as above.
          | if (.id | type) != "number" or (.id | floor) != .id or .id < 0
               or (.start_time | type) != "number"
               or ((.command_line | type) as $c | $c != "string" and $c != "null")
            then error("fields") else . end
          | select(.start_time >= $since - 86400) ]
      | (length | tostring), (.[] | "\(.id) \(.command_line == $cmd)")' <<<"$list" 2>/dev/null)" || return 1
  n="${out%%$'\n'*}"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  (( n >= 1 && n <= 20 )) || return 1
  local recorded="" have_recorded=false
  if jq -e '(.staged_names_source? == "transaction") and ((.staged_names | type) == "array")' \
       <<<"$1" >/dev/null 2>&1; then
    recorded="$(jq -r '.staged_names[] | strings' <<<"$1" 2>/dev/null | sed '/^$/d' | LC_ALL=C sort -u)"
    have_recorded=true
  fi
  # The rows after the count, or none: `${out#*$'\n'}` on a count with nothing after it would hand
  # the loop the count itself as an entry.
  local rows=""
  if [[ "$out" == *$'\n'* ]]; then rows="${out#*$'\n'}"; fi
  local id same res installed touched applied="" applied_names="" other=0 seen=0
  while IFS=' ' read -r id same; do
    [[ -n "$id" ]] || continue
    [[ "$id" =~ ^[0-9]+$ && ( "$same" == true || "$same" == false ) ]] || return 1
    seen=$(( seen + 1 ))
    # One entry asked for, one entry back, and it has to be that entry (history_entry_lists). Its
    # first line is the rpm database it began at: another one, and this is not the stage.
    res="$(history_entry_lists "$id")" || return 1
    [[ "${res%%$'\n'*}" == "$cookie" ]] || continue
    installed="$(sed -n '/^--installed$/,/^--touched$/p' <<<"$res" | sed '1d;$d')"
    touched="$(sed -n '/^--touched$/,$p' <<<"$res" | sed '1d')"
    if [[ "$same" == true ]]; then
      [[ -z "$applied" ]] || return 1      # two candidates: cannot tell which ran
      applied="$id"; applied_names="$touched"
    elif [[ "$have_recorded" == true && "$installed" != "$recorded" ]]; then
      other=$(( other + 1 ))               # another transaction, from the same starting point
    else
      return 1                             # another command, and nothing to tell it apart by
    fi
  done <<<"$rows"
  (( seen == n )) || return 1
  if [[ -n "$applied" ]]; then
    # Two transactions began at the same cookie, so the first cannot have changed anything. Which of
    # them was the restart's is not something this can settle.
    (( other == 0 )) || return 1
    printf 'applied %s\n%s\n' "$applied" "$applied_names"
    return 0
  fi
  printf 'did-not-run\n'
}

# The marker's ONE write. It records what a restart is about to install, so it goes down the way
# state.json and events.log do: atomically, and private to the user.
# 0600 comes from atomic_write's temp - mktemp creates it 0600 and the rename carries that mode
# over whatever the old file had. A bare `>` redirect lands at the umask's 0644, which publishes a
# per-box inventory of pending updates to every account on the machine.
# Atomic matters as much as the mode, for a reason a single-writer file would not have: `update`
# and `check` take DIFFERENT locks, so a check can read this at any instant of a stage. A redirect
# truncates at open, making the whole write a window where the marker reads empty - and an empty
# marker reads as "the stage is gone".
write_offline_marker() { atomic_write "$OFFLINE_MARKER"; }

# KEMPT_MARKER_MAX_BYTES, two lines down: no marker Kempt writes is anywhere near a megabyte (the
# largest is a few hundred bytes), so past it the file is not a marker - it is whatever else ended
# up at that path, and a reader that parses it anyway will parse whatever it is handed.
# KEMPT_CHECK_LOCK_WAIT is how long a check waits for the check lock before serving the previous
# state instead. A seam only so the suite can reach that branch: at a fixed 60 the timeout path -
# the one that hands a reader the state file directly - costs a minute per test and goes uncovered.
KEMPT_CHECK_LOCK_WAIT="${KEMPT_CHECK_LOCK_WAIT:-60}"

# `kempt check --coalesce`: prints state.json and returns 0 when it is ONE object, status "ok", whose
# last_check is provably later than the epoch second in $1 (when the coalescing check was asked
# for). Anything else - no file, a corrupt or multi-document one, a stale status, a last_check not
# in Kempt's own ISO 8601 form - returns 1, and the caller runs a real check: the safe side.
# STRICTLY later, in whole seconds, because last_check has whole seconds and so does $1. A check
# stamped in the same second as the request may have been stamped BEFORE it, from a query that
# started even earlier; `>` on truncated seconds proves last_check came after the request, at the
# price of a redundant check when the two land in the same second. `>=` would serve an answer
# older than the question.
# A last_check more than a minute ahead of the clock is stale too. The clock was stepped back after
# that check (NTP, a dual-boot RTC in local time), and adopting it would freeze every coalesced
# check on that state until the clock caught up.
state_checked_since() {  # requested-epoch → state on stdout, or 1
  local doc at now
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  doc="$(jq -e -n '[inputs] | select(length == 1) | .[0]
                   | select(type == "object" and .status == "ok" and (.last_check | type) == "string")' \
           "$STATE_FILE" 2>/dev/null)" || return 1
  # Only the form `date -Is` writes. date -d also reads "now", "tomorrow" and bare dates, and none
  # of those is a check that ran.
  at="$(jq -r '.last_check' <<<"$doc")"
  [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$ ]] || return 1
  at="$(date -d "$at" +%s 2>/dev/null)" || return 1
  now="$(date +%s)"
  [[ "$at" =~ ^[0-9]+$ ]] && (( at > $1 && at <= now + 60 )) || return 1
  printf '%s\n' "$doc"
}

# The shape of the marker Kempt writes today: ONE integer, in place of a reader working the shape
# out from which of several optional fields happen to be present.
# Stamped where a marker is BORN (write_stage_marker) and nowhere else. The additive updates -
# `armed`, `replaced`, `set_moved` - carry forward whatever was already on the file, so a marker
# from an older build is never stamped with a version whose fields it does not actually have.
# EVERY READER MUST GO ON WORKING WITHOUT IT. A marker written before this field existed carries no
# version at all, and the per-field fallbacks are still what read those; this records the shape, it
# does not replace the checks.
# shellcheck disable=SC2034  # read by write_stage_marker in bin/kempt, which sources this file
KEMPT_MARKER_VERSION=1

KEMPT_MARKER_MAX_BYTES=1048576
# dnf5's stored transaction has its own cap, sized for a file that grows with the transaction -
# see offline_txjson_names.
KEMPT_TXJSON_MAX_BYTES=8388608

# Compare-and-swap on the stage's identity, for the two commands that BOTH write this file while
# holding DIFFERENT locks: the harvest runs under check.lock (fd 9), `kempt update` writes the
# marker under the update lock (fd 8), so neither waits for the other. A full package snapshot and
# diff sit between a harvest's read and its delete - 0.5 to 1.5s on a 2700-package box - and
# without this a stage landing inside that window is deleted by it: the user clicks "Install on
# Next Restart", is told the update is staged, and a second later the panel shows nothing staged
# over a transaction that is armed and will install. `staged_at` is the identity because it is what
# the widget's own click-time re-verify already compares.
offline_marker_still() {  # marker-json → 0 when the file still holds that same stage
  local now
  now="$(offline_marker_read)"
  [[ "$(jq -r '.staged_at // empty' <<<"$now" 2>/dev/null)" \
     == "$(jq -r '.staged_at // empty' <<<"$1" 2>/dev/null)" ]]
}

# The marker, read defensively, or nothing - and "nothing" means SKIP THIS CHECK, never "the stage
# is gone". A reader can arrive mid-write (write_offline_marker says why), so a marker that will
# not parse is evidence about the READ, not about the transaction, and treating it as a vanished
# stage is how Kempt disowns an armed transaction sitting there perfectly staged. Clearing needs
# the other evidence: a marker that parses, over a transaction dnf5 says is gone.
# `[inputs][0]` plus the type guard is state_prev_items' corrupt-tolerance.
offline_marker_read() {  # → the marker as one line of JSON, or nothing
  [[ -f "$OFFLINE_MARKER" ]] || return 0
  local sz
  sz="$(stat -c %s "$OFFLINE_MARKER" 2>/dev/null || echo 0)"
  (( sz > 0 && sz <= KEMPT_MARKER_MAX_BYTES )) || return 0
  jq -c -n '[inputs][0] | select(type == "object")' "$OFFLINE_MARKER" 2>/dev/null || true
}

# The staged transaction as state.json publishes it, or nothing at all. BOTH facts have to agree:
# the marker says Kempt staged something and how big it was, dnf5 says it is armed. A marker alone
# promises a restart that will install these updates, and a transaction that never armed installs
# on no restart while every surface goes on advertising it. So the key exists for `ready` and
# nothing else; an unarmed or vanished stage is a discrepancy for `kempt doctor`, not a pending
# install to publish.
#
# It also answers what a hold added AFTER a stage raises: which held packages are in there anyway.
# dnf5 cannot edit a stored transaction, so a hold applies from the NEXT one Kempt builds - correct,
# and invisible without this. The predicate is a set intersection and never a clock (staged names
# against dnf names currently held), which is order-free, restore-proof and immune to the
# in-flight-stage race a timestamp comparison loses whichever way round it is written. Flatpak
# holds never enter it: the offline surface stages dnf and nothing else.
#
# `names_source` is what keeps that answer honest: an empty `holds_conflict` means NO CONFLICT under
# `transaction` and `marker` (both transaction-derived) and CANNOT TELL under `none` (a legacy
# marker, or names from a check, which cannot see resolver-added packages). docs/architecture.md's
# state.json table is the full contract each value carries.
# $1, optional: a file of the dnf updates the check found pending and not held, one name a line.
# With it, and with the staged names readable, `not_staged` counts the pending ones the stage leaves
# out: updates published after the stage was built. Absent whenever either list is missing.
offline_staged_state() {  # [pending-names file] → {staged_at, count, armed, holds_conflict, names_source[, not_staged]} JSON, or nothing
  local marker
  marker="$(offline_marker_read)"
  [[ -n "$marker" ]] || return 0
  # Armed, not merely `ready`: a stranded stage (see offline_release_upgrade_state) is what a live
  # dnf5 transaction outside Kempt leaves behind in the SAME boot, where the harvest cannot demote
  # it yet, and publishing it put "staged" in the widget over a stage no restart installs.
  offline_armed || return 0
  # A marker the harvest has DEMOTED describes a stage that cannot install, whatever dnf5's status
  # and the symlink still say - a supersede whose clean failed leaves exactly that. Publishing it
  # anyway would re-make, on every check, the promise reconcile_detour_stage exists to withdraw.
  # `.armed == false` and never `.armed // true`: jq's alternative operator treats false as empty.
  jq -e '.armed == false' <<<"$marker" >/dev/null 2>&1 && return 0
  # ...and one recorded as REPLACED describes a stage that is no longer what dnf5 holds. The next
  # restart installs somebody else's transaction, so publishing Kempt's count would promise it.
  jq -e '.replaced == true' <<<"$marker" >/dev/null 2>&1 && return 0
  # A stored RELEASE upgrade is proof the transaction is not ours, whatever the marker says. dnf5
  # keeps one stored transaction; Kempt only ever runs `dnf5 upgrade --offline` at the releasever
  # the box is already on, so a transaction whose target differs from the system's cannot be one
  # Kempt built - it replaced ours as it was stored. Publishing the marker anyway tells the widget
  # that sixty-one packages install on the next restart when what installs is a whole new Fedora.
  # The marker is dropped by the next live run's reconcile; until then it simply says nothing.
  offline_release_upgrade >/dev/null && return 0
  local names="" names_source=none not_staged=""
  if names="$(offline_txjson_names)"; then
    names_source=transaction
  elif jq -e '(.staged_names_source? == "transaction") and ((.staged_names | type) == "array")' \
         <<<"$marker" >/dev/null 2>&1; then
    # Shape-tested before it is read: a marker claiming a transaction-derived list without one is
    # a marker that cannot deny anything, and `.staged_names[]?` alone would have said "no names"
    # in exactly the same words as a list that was genuinely empty.
    names="$(jq -r '.staged_names[] | select(type == "string")' <<<"$marker" 2>/dev/null || true)"
    names_source=marker
  fi
  local conflict='[]'
  if [[ "$names_source" != none ]]; then
    # Both lists reach jq as FILES. The names are a whole staged transaction, and a release
    # upgrade stages every package on the box: past roughly 6,800 names that list is larger than
    # the 128 KiB Linux allows a single argv entry, and this runs on EVERY check. Failing here
    # fails the check, so the widget would go blank on exactly the machine with the most staged.
    # printf '%s' rather than a here-string: <<< appends a newline, and an empty list would arrive
    # as one empty-string element - which is why both sides drop empty lines below.
    local names_f holds_f
    names_f="$(mktemp)"; holds_f="$(mktemp)"
    # Every step guarded, and every failure lands in the SAME place: names_source `none`. An empty
    # conflict list under `transaction` or `marker` is a finding - this file's contract three lines
    # up says so, and every reader relies on it to deny a conflict. Publishing `[]` because the
    # comparison could not be made would turn "nobody could tell" into "there is no conflict",
    # which is the one answer the data does not support. `none` is the value that means the first.
    # The two files are removed on every path, including the ones that give up early.
    if printf '%s' "$names" > "$names_f" 2>/dev/null \
       && holds_for dnf > "$holds_f" 2>/dev/null; then
      # `. as $x` first, for the index() trap mark_held carries the note about.
      conflict="$(jq -cn --rawfile n "$names_f" --rawfile h "$holds_f" '
                    def lines: split("\n") | map(select(length > 0));
                    ($h | lines) as $hl
                    | [($n | lines)[] | . as $x | select($hl | index($x))] | unique')" \
        || { conflict='[]'; names_source=none; }
      if [[ "$names_source" != none && -n "${1:-}" && -r "$1" ]]; then
        not_staged="$(jq -n --rawfile n "$names_f" --rawfile p "$1" '
                        def lines: split("\n") | map(select(length > 0));
                        ($n | lines) as $nl
                        | [($p | lines)[] | . as $x | select(($nl | index($x)) == null)]
                        | unique | length')" || not_staged=""
      fi
    else
      conflict='[]'; names_source=none
    fi
    rm -f "$names_f" "$holds_f"
  fi
  [[ "$not_staged" =~ ^[0-9]+$ ]] || not_staged=""
  # count: markers written before the field existed carry no number, and null is the honest answer.
  # Every reader drops the figure from its sentence rather than inventing one.
  jq -c --argjson conflict "$conflict" --arg nsrc "$names_source" --arg ns "$not_staged" \
    '{staged_at: (.staged_at // null), count: (.staged // null), armed: true,
      holds_conflict: $conflict, names_source: $nsrc}
     + (if $ns == "" then {} else {not_staged: ($ns | tonumber)} end)' <<<"$marker"
}

# Kempt's stage, when it is `ready` but another updater's symlink decides the next restart: that
# restart runs the other updater, and dnf5 exits without installing Kempt's stage. Published beside
# offline_staged rather than inside it, because a reader that predates this key reads the
# presence of offline_staged as "installs on the next restart". Same gates as offline_staged_state
# otherwise: a demoted marker, a stored release upgrade, or packages already installed (the stage
# is then done, not blocked) publish nothing. A replaced stage is never done that way.
offline_stage_blocked_state() {  # → {staged_at, count} JSON, or nothing
  local marker
  marker="$(offline_marker_read)"
  [[ -n "$marker" ]] || return 0
  [[ "$(offline_release_upgrade_state)" == foreign ]] || return 0
  jq -e '.armed == false' <<<"$marker" >/dev/null 2>&1 && return 0
  offline_release_upgrade >/dev/null && return 0
  offline_marker_stage_satisfied "$marker" && return 0
  jq -c '{staged_at: (.staged_at // null), count: (.staged // null)}' <<<"$marker"
}

# Put what the next restart will install into the state file NOW, without a check.
#
# THE PROBLEM IT EXISTS FOR: `offline_staged` is normally computed by a check, and cmd_update ends
# with one - but that check re-reads dnf, which takes tens of seconds on a real box (measured: 30s
# for 19 pending updates). Until it lands, the popup holds the finished run's report - "Updates are
# staged" - beside the pre-run banner still offering Install on Next Restart, under a header still
# counting those updates as merely available, with Update Now live underneath. Both buttons rebuild
# a transaction that is already downloaded and armed, and dnf5 destroys the stored one to do it.
# Staging is the one thing a run knows for certain the moment it finishes, so it says so itself and
# lets the slow check refresh everything else.
#
# ONLY `.offline_staged` is touched. last_check and last_success date a CHECK, and this is not one:
# moving them would put a fresh timestamp on counts nobody re-read.
#
# ...and it CLEARS as well as sets, which is the half a live run needs: reconcile_stage_after_live_run
# can discard a stage the run superseded, and a state file still promising it would have the popup
# offering a restart that installs nothing.
#
# Best-effort throughout, like log_event: a run's verdict must never turn on the state file. No
# state file at all means a box that has never checked, and there is nothing to keep consistent.
publish_staged_state() {
  [[ -f "$STATE_FILE" ]] || return 0
  local staged
  # Not a bare call: this runs under errexit on the far side of an update that has already
  # downloaded and armed a transaction, and a marker this cannot read is not a reason to end the
  # run there.
  #
  # ...and NOT `|| staged=""` either, which is what it used to be. offline_staged_state produces
  # nothing in two quite different ways: rc 0 with no output for every path where there is
  # genuinely no stage (no marker, not `ready`, demoted, a stored release upgrade that proves the
  # transaction is not ours), and non-zero when it could not work the answer out. Flattening the
  # second into the first published "nobody could tell" as "nothing is staged", and the else branch
  # below then DELETED a promise the machine is already armed to keep - after which every surface
  # offers to stage what is downloaded, or to upgrade live over it, which makes the CLI discard it
  # as superseded and throw the download away. Rule 1 of the schema, on the writing side: a reader
  # that learned nothing leaves what was there.
  staged="$(offline_staged_state "")" || return 0
  # state.lock rather than check.lock. The holder of check.lock is always a check that runs for
  # tens of seconds, and this exists to publish without that wait: tests/test_update.sh holds
  # check.lock for ten seconds and asserts a run publishes anyway. state.lock is held only for
  # this read and write and for each write_state, so a check's write cannot land between them.
  # The order is always check.lock, then state.lock, so the two cannot deadlock.
  #
  # `[inputs][0] | select(type == "object")`: the house guard for a state file that is corrupt or
  # holds more than one document (see cmd_check). select yields NOTHING on either, so `out` is
  # empty and the file is left exactly as it was for the check behind us to rewrite properly.
  # offline_stage_blocked travels with it: a stage just armed behind another updater's symlink
  # is published as what it is, not as nothing.
  local blocked lfd
  blocked="$(offline_stage_blocked_state)" || blocked=""
  if { exec {lfd}>>"$STATE_LOCK_FILE"; } 2>/dev/null; then flock -w 10 "$lfd" || true; else lfd=""; fi
  publish_staged_state_write "$staged" "$blocked" 2>/dev/null || true
  if [[ -n "$lfd" ]]; then { exec {lfd}>&-; } 2>/dev/null || true; fi
  return 0
}

# The read and write behind publish_staged_state, run while it holds state.lock.
publish_staged_state_write() {  # staged blocked
  local staged="$1" blocked="$2" out
  if [[ -n "$staged" ]]; then
    out="$(jq -c -n --argjson st "$staged" \
             '[inputs][0] | select(type == "object") | .offline_staged = $st | del(.offline_stage_blocked)' \
             "$STATE_FILE" 2>/dev/null)" || return 0
  elif [[ -n "$blocked" ]]; then
    out="$(jq -c -n --argjson b "$blocked" \
             '[inputs][0] | select(type == "object") | del(.offline_staged) | .offline_stage_blocked = $b' \
             "$STATE_FILE" 2>/dev/null)" || return 0
  else
    out="$(jq -c -n '[inputs][0] | select(type == "object") | del(.offline_staged) | del(.offline_stage_blocked)' \
             "$STATE_FILE" 2>/dev/null)" || return 0
  fi
  [[ -n "$out" ]] || return 0
  # ...and the write is best-effort like everything above it. This runs on the far side of a
  # transaction that is downloaded and armed, under a caller that reports the run's verdict: a
  # state directory that cannot be written is the same degrade the history entry beside it takes,
  # not a staged update reported as a failed run. Without this, the one case where the marker
  # cannot be written - where atomic_write is already failing - turned a successful stage into rc 1.
  _KEMPT_STATE_LOCK_HELD=1
  printf '%s\n' "$out" | write_state 2>/dev/null || true
  _KEMPT_STATE_LOCK_HELD=""
  return 0
}

# The unhold mirror's predicate: was this armed stage built WITHOUT the package the user has just
# released? It needs its own recorded answer, because the transaction can never supply one - a
# package absent from it was either excluded at stage time or simply had no update, and those look
# identical from the inside. `staged_excluded` is that answer, written when the stage was made.
# The legacy fallback, for a marker written before the field existed: warn only when the package is
# pending RIGHT NOW, since a package with no update to miss cannot have been missed.
offline_stage_built_without() {  # name → 0 when an armed stage left it out
  # The same proof of ownership offline_staged_state uses, for the same reason: dnf5 keeps ONE
  # stored transaction, Kempt only ever stages at the releasever the box is already on, so a stored
  # release upgrade means the transaction our marker describes is gone. Without this, `kempt unhold`
  # asserted a stage the check one command earlier had already stopped publishing, and pointed at a
  # rebuild that pre-flight refuses.
  offline_release_upgrade >/dev/null && return 1
  local marker
  marker="$(offline_marker_read)"
  [[ -n "$marker" ]] || return 1
  offline_armed || return 1
  # Same demote gate as offline_staged_state: a stage that can no longer install cannot have
  # missed anything the user is about to release.
  jq -e '.armed == false' <<<"$marker" >/dev/null 2>&1 && return 1
  if jq -e '(.staged_excluded | type) == "array"' <<<"$marker" >/dev/null 2>&1; then
    jq -e --arg n "$1" '.staged_excluded | index($n)' <<<"$marker" >/dev/null 2>&1
    return
  fi
  jq -e -n --arg n "$1" '[inputs][0].backends.dnf.items[]? | select(.name == $n)' \
    "$STATE_FILE" >/dev/null 2>&1
}

# --- what a hold over an armed stage says ---------------------------------------------------------
# Copy lives here rather than at the call site for the reason the KEMPT_AUTH_* sentences do: more than
# one surface renders it, and two copies of a sentence are two sentences that drift. The wording is
# deliberate - "The staged update" is doctor's existing noun, "on the next restart" is the promise
# the popup already makes in those words, and it "removes it", never "unstages".

# A set of package names as a human reads it, capped at four: a Qt or KDE bump legitimately puts
# dozens of names in a conflict set, and a sentence listing all of them is one nobody finishes.
names_phrase() {  # stdin: one name per line → "a" | "a and b" | "a, b and c" | "a, b, c, d, and N more"
  local -a all=() shown init
  local n
  # Same unterminated-last-line arm as names_all_valid: a caller that pipes `printf '%s'`
  # rather than a here-string hands over a list with no newline after the final name.
  while IFS= read -r n || [[ -n "$n" ]]; do [[ -n "$n" ]] && all+=("$n"); done
  local total=${#all[@]}
  (( total == 0 )) && return 0
  shown=("${all[@]:0:4}")
  if (( total > 4 )); then
    local joined; joined="$(printf '%s, ' "${shown[@]}")"
    printf '%s, and %d more\n' "${joined%, }" "$(( total - 4 ))"
    return 0
  fi
  if (( total == 1 )); then printf '%s\n' "${shown[0]}"; return 0; fi
  # The last name joins with "and" and no comma before it: "a, b and c", never "a, b, c".
  init=("${shown[@]:0:$(( total - 1 ))}")
  local head; head="$(printf '%s, ' "${init[@]}")"
  printf '%s and %s\n' "${head%, }" "${shown[-1]}"
}

# Both remedies, on every surface that warns: the frightened holder may want the stage GONE rather
# than rebuilt, and a warning that only offers the rebuild leaves them looking for the other half.
# shellcheck disable=SC2034  # read by cmd_hold in bin/kempt, which sources this through a runtime $ROOT
KEMPT_STAGED_RECIPE='When ready: kempt update --surface=offline (rebuilds it with your holds) or sudo dnf5 offline clean (removes it).'

hold_staged_warning() {  # stdin: the conflicting names → the sentence naming them
  local names total phrase
  names="$(cat)"
  total="$(printf '%s' "$names" | grep -c '' || true)"
  phrase="$(printf '%s' "$names" | names_phrase)"
  [[ -n "$phrase" ]] || return 0
  # The verb moves with the noun: "installs it" for one package, "installs them" for several.
  if [[ "$total" == 1 ]]; then
    printf 'The staged update still contains %s and installs it on the next restart.\n' "$phrase"
  else
    printf 'The staged update still contains %s and installs them on the next restart.\n' "$phrase"
  fi
}

# What is said when no list may be trusted: a legacy marker with no names, or one whose names came
# from a check. "may still install" is the whole difference from the sentence above: this warning
# may be wrong about a package that is not in the transaction, and must never be wrong by staying
# quiet about one that is.
hold_generic_warning() {  # name → the sentence
  printf 'The staged update was built before this hold and may still install %s on the next restart. Rebuilding applies all current holds.\n' "$1"
}

# The mirror, and the quieter one: an update missed rather than a feared one applied.
unhold_staged_warning() {  # name → the sentence
  printf 'The staged update was built without %s, so the next restart will not install it. Rebuild when ready: kempt update --surface=offline.\n' "$1"
}

# The ONE definition of "what a run changed" as a phrase, shared because two copies of this
# arithmetic drift: `kempt history` counting .updated alone prints "0 updated" for the very run
# whose summary says "+2 installed, -1 removed". A jq snippet in a variable is how one definition
# reaches both programs, since jq has no include path here.
# `always_updated` is their only real difference, and it is deliberate: a per-backend summary line
# always names its update count (a backend that did nothing still reads "0 updated"), while the
# whole-run phrase drops zero parts and degrades to "no package changes".
KEMPT_JQ_COUNTS='
  def counts_phrase(u; a; r; always_updated):
    [ (if u > 0 or always_updated then (u|tostring) + " updated"   else empty end),
      (if a > 0 then "+" + (a|tostring) + " installed" else empty end),
      (if r > 0 then "-" + (r|tostring) + " removed"   else empty end) ]
    | if length == 0 then "no package changes" else join(", ") end;
  # A staging run changes no package until the restart, so "no package changes" is true and
  # misleading. Keyed on the dnf half, not the run: a failed Flatpak half fails the run but leaves
  # the stage armed. Entries from older builds have no staged count or dnf status, and the phrase
  # then leaves the count out and reads the run status. A stage made while another updater holds
  # /system-update says it will not install then (stage_blocked).
  def stage_phrase:
    if .surface == "offline" and (.backends.dnf.status? // .status) == "ok"
       and (.staged_nothing // "") == "" then
      (if (.staged | type) == "number" and .staged > 0 then
         (.staged | tostring) + (if .staged == 1 then " update" else " updates" end)
       else "updates" end)
      + (if .stage_blocked == true then " staged, but another updater has prepared the next restart"
         else " staged for the next restart" end)
    else empty end;
  # How a run reads in kempt history and kempt summary. The stored surface of a harvested
  # restart keeps its old words, so scripts and old entries read the same. Only the display moves.
  # A run in the widget is stored as "popup" and shown as "widget".
  def surface_label:
    if .surface == "offline (applied on reboot)" then "restart (staged update installed)"
    elif .surface == "offline (installed by another updater)"
    then "staged update (installed by another updater)"
    elif .surface == "popup" then "widget"
    else .surface end;
'

# One-line count of what a run actually changed. Shared by cmd_update's notification and the
# offline harvest's: a transaction that only installs or removes packages must never be
# announced as "0 packages" by one surface and correctly by the other.
run_counts_phrase() {  # history-json-file → "N updated, +N installed, -N removed" | "no package changes"
  jq -r "$KEMPT_JQ_COUNTS"'
    def tot(k): [.backends[] | .[k] | length] | add // 0;
    counts_phrase(tot("updated"); tot("added"); tot("removed"); false)' "$1"
}

# The `kempt history` row's phrase. A staging run reads as what it staged, plus what Flatpak
# changed live in the same run.
history_phrase() {  # history-json-file → one phrase
  jq -r "$KEMPT_JQ_COUNTS"'
    def tot(k): [.backends[] | .[k] | length] | add // 0;
    def fp(k): .backends.flatpak[k]? // [] | length;
    [stage_phrase] as $st
    | if ($st | length) == 0 then counts_phrase(tot("updated"); tot("added"); tot("removed"); false)
      else $st[0] + (if fp("updated") + fp("added") + fp("removed") > 0
                     then ", Flatpak: " + counts_phrase(fp("updated"); fp("added"); fp("removed"); false)
                     else "" end) end' "$1"
}

# What the next restart will install, in one line, or nothing. Deliberately NOT part of
# render_summary: that renders one history entry, and a staged transaction is not something a past
# run did - it is something the box is about to do. Read from the state the last check wrote, the
# only place the marker and dnf5's status have already been reconciled.
# The count can legitimately be unknown (a marker written before the field existed), and the
# sentence drops the figure rather than printing "null" or guessing a number.
# The argument lets a caller that has already read the state hand over that same copy (kempt status
# passes /dev/stdin), so one command never answers from two different reads.
staged_summary_line() {  # [state file, the published one by default] → one line, or nothing
  local s
  # The "staged:" prefix is what separates "no staged transaction" from "a staged transaction with
  # no count": both would otherwise reach the caller as an empty string.
  s="$(jq -r -n '[inputs][0].offline_staged? // empty
                 | select(type == "object")
                 | "staged:" + ((.count // "") | tostring)' "${1:-$STATE_FILE}" 2>/dev/null || true)"
  [[ "$s" == staged:* ]] || return 0
  local n="${s#staged:}"
  # `== 1`, not `<= 1`: zero is plural in English ("0 updates install"). Same singular/plural rule
  # hold_staged_warning, the run summary and `kempt doctor` follow.
  if [[ "$n" == 1 ]]; then
    printf 'Staged: 1 update installs on the next restart\n'
  elif [[ "$n" =~ ^[0-9]+$ ]]; then
    printf 'Staged: %s updates install on the next restart\n' "$n"
  else
    printf 'Staged: updates install on the next restart\n'
  fi
}

# --- human summary of one history entry (same renderer for the terminal, the popup and the
# notification body: one truth, rendered once) ---
render_summary() {  # history-json-file → human text
  # The reclaim setting now, for the end-of-life hint: with reclaim=off, kempt reclaim refuses.
  jq -r --arg reclaim "$(reclaim_mode 2>/dev/null || echo ask)" "$KEMPT_JQ_COUNTS"'
    def newest(v): v | split(",") | last;   # installonly sets stay truthful in JSON; humans see newest → newest
    # NOT always an arrow. A Flatpak runtime can update without its version string moving - most
    # runtimes carry a date, or nothing, as their version, and the commit is what differs - so
    # "? → ?" and "2024-05-30 → 2024-05-30" were both real rows this renderer produced. Both say the
    # update is fictional. The widget already refused to draw the first of them; this is the same
    # rule on this side, so one update reads the same in the popup and in `kempt summary`.
    # The id and branch of a runtime are folded into one `id/branch` JOIN KEY, so that sort, join and
    # the snapshot diff have a single field to work on. It is not a name, and the popup never drew it
    # as one: it splits the fold and shows "org.kde.Platform 5.15-24.08". This renderer printed the
    # raw key, so one transaction was spelled two ways by one product. The LAST slash is always the
    # one Kempt added, because a flatpak app id cannot contain one, and a dnf package name has no
    # slash at all - so this is a no-op for every other row.
    # NO APOSTROPHES IN HERE: this jq program is a single-quoted bash string, and one closes it.
    def dispname: (. | split("/")) as $p
                  | if ($p | length) > 1 then (($p[0:-1] | join("/")) + " " + $p[-1]) else . end;
    def vtext(f; t): (newest(f)) as $f | (newest(t)) as $t
                     | if ($f == "?" and $t == "?") then ""
                       elif ($f == $t) then " " + $t + " (new build)"
                       else " " + $f + " → " + $t end;
    # A per-user Flatpak item says so, which also tells apart one id installed both ways.
    def scopetag: if .scope == "user" then " (for you only)" else "" end;
    def lines(b): b.updated | map("  " + (.name | dispname) + vtext(.from; .to) + scopetag) | join("\n");
    # ...and the packages that ARRIVED or LEFT, by name. The counts line has always said "+2
    # installed" without ever saying what they were, which is least forgivable on the one summary
    # somebody opens afterwards to find out what a restart did to their machine. Same indent as the
    # upgrade lines, with a sign so the three kinds cannot be misread for one another.
    def addlines(b): b.added | map("  + " + (.name | dispname) + (if (newest(.to)) == "?" then "" else " " + newest(.to) end) + scopetag) | join("\n");
    def rmlines(b): b.removed | map("  - " + (.name | dispname) + (if (newest(.from)) == "?" then "" else " " + newest(.from) end) + scopetag) | join("\n");
    # The held names, read ONCE and shared by the two lines below, so the list and the count can
    # never disagree about the same run. `?` and `// []` keep an entry written before the field
    # existed rendering, instead of dying on a missing key and printing nothing at all.
    def heldnames: [.backends[] | .skipped_held? // [] | .[]];
    def heldline: heldnames | if length == 0 then empty
                  else "Held (skipped): " + join(", ") end;
    # ...and what those holds COST this run. The line above names them; this answers the question
    # somebody actually asks afterwards, which is why the pending count did not drop as far as they
    # expected. No schema change: the names have always been in the entry, only the arithmetic is
    # new. Nothing at zero - a standing "0 pending packages did not move" on every clean run is
    # noise that teaches people to stop reading the summary.
    def shortfall: heldnames | length
                   | if . == 0 then empty
                     elif . == 1 then "1 pending package did not move because of holds"
                     else (tostring) + " pending packages did not move because of holds" end;
    # a transaction that installs or removes packages changed the system just as much as one
    # that upgrades them: counting only .updated under-reports what actually happened.
    # counts_phrase (KEMPT_JQ_COUNTS) is the shared definition; `true` keeps the update count on
    # the line even at zero, which is what a per-backend line has always printed.
    def counts(b): counts_phrase(b.updated|length; b.added|length; b.removed|length; true);
    # `.error // ""`: entries written before the field existed have no .error at all, and a
    # summary of an old run must still render rather than printing "null".
    # No duration is written when none was measured (a restart whose dnf5 record has no times).
    "Kempt - " + .timestamp + " (" + surface_label
      + (if (.duration_sec | type) == "number" then ", " + (.duration_sec|tostring) + "s" else "" end) + ") "
      + (if .status == "ok" then "✓"
         else "FAILED. See " + .log
              + (if (.error // "") != "" then " (" + .error + ")" else "" end) end),
    "System (dnf): " + (first(stage_phrase) // counts(.backends.dnf))
      + (if .backends.dnf.status != "ok" then " [" + .backends.dnf.status + "]" else "" end),
    (if (.backends.dnf.updated|length) > 0 then lines(.backends.dnf) else empty end),
    (if (.backends.dnf.added|length) > 0 then addlines(.backends.dnf) else empty end),
    (if (.backends.dnf.removed|length) > 0 then rmlines(.backends.dnf) else empty end),
    # `scopes` is there only when apps for you only were updated too. When one of the two
    # installations failed, the tag names it.
    def fpfailed: [(.backends.flatpak.scopes? // {}) | to_entries[] | select(.value == "failed") | .key]
                  | if length == 1 then (if .[0] == "user" then ": apps for you only" else ": system apps" end)
                    else "" end;
    "Apps (flatpak): " + counts(.backends.flatpak)
      + (if .backends.flatpak.status != "ok" then " [" + .backends.flatpak.status + fpfailed + "]" else "" end),
    (if (.backends.flatpak.updated|length) > 0 then lines(.backends.flatpak) else empty end),
    (if (.backends.flatpak.added|length) > 0 then addlines(.backends.flatpak) else empty end),
    (if (.backends.flatpak.removed|length) > 0 then rmlines(.backends.flatpak) else empty end),
    # What reclaim=automatic removed after this run. Only a removal gets a line: a set that changed
    # or needs an administrator is for the popup to say, once, not for every summary.
    def sizetext: if . >= 1e9 then ((. / 1e8 | round) / 10 | tostring | if test("[.]") then . else . + ".0" end) + " GB"
                  elif . >= 1e6 then (. / 1e6 | round | tostring) + " MB"
                  else (. / 1e3 | round | tostring) + " kB" end;
    (.backends.flatpak.reclaimed? // null
     | if type == "object" and .status == "removed" then
         ((.refs // []) | length) as $n
         | "Removed " + ($n | tostring) + " unused Flatpak " + (if $n == 1 then "runtime" else "runtimes" end)
         + (if (.bytes | type) == "number" and .bytes > 0 then ", freeing about " + (.bytes | sizetext) else "" end) + "."
       else empty end),
    heldline,
    shortfall,
    # Flatpak end-of-life notes, one per ref, saying which app is behind the notice and whether
    # anything needs doing. `// []` keeps entries written before the field existed rendering.
    # An unused one points at `kempt reclaim`, which shows what goes and asks, rather than at the
    # flatpak command that removes every unused runtime without a list. With reclaim=off that
    # command refuses, so the flatpak one is the hint again.
    # NO APOSTROPHES IN HERE either (see above).
    def names(a): if (a|length) == 1 then a[0]
                  else (a[0:-1] | join(", ")) + " and " + a[-1] end;
    def eolline: if .kind == "app" then
                   "Note: " + .apps[0] + " has reached end-of-life and gets no more updates"
                   + (if .reason != "" then " (" + .reason + ")" else "" end) + "."
                 elif (.apps|length) == 0 then
                   "Note: " + .id + (if .branch != "" then " " + .branch else "" end)
                   + " has reached end-of-life and no installed app uses it. "
                   + (if $reclaim == "off" then "To remove it once nothing needs it: flatpak uninstall --unused"
                      else "To remove it: kempt reclaim" end)
                 else
                   "Note: " + names(.apps) + (if (.apps|length) == 1 then " uses " else " use " end)
                   + .id + (if .branch != "" then " " + .branch else "" end)
                   + ", which has reached end-of-life and gets no more updates. Nothing to do now:"
                   + (if (.apps|length) == 1 then " when its developer moves it to a supported runtime, a normal update installs that."
                      else " when their developers move them to a supported runtime, a normal update installs that." end)
                 end;
    ((.backends.flatpak.eol? // [])[] | eolline),
    # ONLY when a restart is owed. `false` here does not mean "no restart needed" - it also means
    # the check could not work the answer out, which it reports the same way, and the state
    # schema says in as many words that no affirmative line may be rendered from it. "Reboot: not
    # needed" was this file telling the reader something Kempt does not know.
    (if .reboot_needed then "Restart needed" else empty end)
  ' "$1"
}

# --- kempt status: the widget's header, read from the published state ---------------------------
# The widget derives what it shows in plasmoid/contents/ui/logic.js, and a terminal over SSH has no
# JavaScript to run it with. So the few rules `kempt status` needs are ported here, and
# tests/test_status.sh holds the two copies together: for each fixture and a fixed clock, the header
# and the numbers must match what logic.js derives, and every string below that mirrors a COPY entry
# must equal it. Only those rules: the rest of status is this side's own wording.
# NO APOSTROPHES IN HERE: these jq programs are single-quoted bash strings, and one closes them.

# Time words, as logic.js says them (formatStamp, relativeTime, metadataAgeText). $now is in whole
# seconds, so the minute and hour buckets fall where the widget's millisecond ones do.
# shellcheck disable=SC2034,SC2016  # a jq program, read by cmd_status in bin/kempt
KEMPT_JQ_TIME='
  def line0: split("\n")[0] | sub("^\\s+"; "") | sub("\\s+$"; "");
  def fmt_stamp:
    if type != "string" then "never" else line0 as $s
    | if $s == "" then "never" else
        ([$s | capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})T(?<t>[0-9]{2}:[0-9]{2})")] | .[0]) as $m
        | if $m == null then $s else
            ([$s | capture("(?<z>Z|[+-][0-9]{2}:?[0-9]{2})$")] | .[0]) as $z
            | $m.d + " " + $m.t
              + (if $z == null then "" elif $z.z == "Z" then " +00:00"
                 else " " + $z.z[0:3] + ":" + $z.z[-2:] end)
          end
      end
    end;
  def renderable_stamp: type == "string" and (line0 | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}"));
  def stamp_s:
    if type != "string" then null else
      ([line0 | capture("^(?<y>[0-9]{4})-(?<mo>[0-9]{2})-(?<d>[0-9]{2})T(?<h>[0-9]{2}):(?<mi>[0-9]{2}):(?<s>[0-9]{2})(?:\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")]
       | .[0]) as $m
      | if $m == null then null else
          ($m.mo | tonumber) as $mo | ($m.d | tonumber) as $d | ($m.h | tonumber) as $h
          | ($m.mi | tonumber) as $mi | ($m.s | tonumber) as $sec
          | if $mo < 1 or $mo > 12 or $d < 1 or $d > 31 or $h > 23 or $mi > 59 or $sec > 60 then null
            else
              (if $m.z == null or $m.z == "Z" then 0
               else ($m.z[1:] | gsub(":"; "")) as $dg
                    | (($dg[0:2] | tonumber) * 60 + ($dg[2:] | tonumber)) * 60
                      * (if $m.z[0:1] == "-" then -1 else 1 end) end) as $off
              | ([($m.y | tonumber), $mo - 1, $d, $h, $mi, $sec, 0, 0] | mktime) - $off
            end
        end
    end;
  def rel_time($now):
    (stamp_s) as $at
    | if $at == null or ($now | type) != "number" then fmt_stamp else ($now - $at) as $age
      | if $age < 0 then fmt_stamp
        elif $age < 60 then "just now"
        elif $age < 3600 then ($age / 60 | floor) as $n | (if $n == 1 then "1 min ago" else "\($n) min ago" end)
        elif $age < 86400 then ($age / 3600 | floor) as $n | (if $n == 1 then "1 hour ago" else "\($n) hours ago" end)
        elif ($age / 86400 | floor) <= 7 then ($age / 86400 | floor) as $n
             | (if $n == 1 then "1 day ago" else "\($n) days ago" end)
        else fmt_stamp end
      end;
  def meta_age($now):
    (stamp_s) as $at
    | if $at == null or ($now | type) != "number" or ($now - $at) < 86400 then ""
      else (($now - $at) / 86400 | floor) as $n
           | "lists \($n) " + (if $n == 1 then "day old" else "days old" end) end;
'

# The status facts from one state document. Input: the document, or null when there is none.
# Output: records of TAG, a unit separator and a value, one per line, which cmd_status turns into
# lines (names_phrase and staged_summary_line are shell, so the joining happens there).
#   H header   P problem detail   S section title, US, count   N a name in that section
#   L held count   M a held name   C security count   G staged   R restart owed   F footer   X exit
# shellcheck disable=SC2034,SC2016  # a jq program, read by cmd_status in bin/kempt
KEMPT_JQ_STATUS='
  def status_copy: {
    upToDate: "Up to date",
    held: "held",
    userAppsUncheckedShort: "apps for you only not checked",
    stagedHeaderOne: "1 update staged for the next restart",
    stagedHeaderTail: "updates staged for the next restart",
    stagedHeaderUnknown: "Updates staged for the next restart",
    restartMessage: "Restart to apply installed updates",
    noSuccessfulCheckYet: "No successful check yet",
    lastCheckFailed: "last check failed"
  };
  def section_titles: {dnf: "System (dnf)", flatpak: "Apps (flatpak)"};
  def kind_titles: {flatpak: {runtime: "Flatpak runtimes"}};
  def dot: " · ";
  def truthy: . != null and . != false and . != 0 and . != "";
  def clean: tostring | gsub("[[:cntrl:]]"; " ");
  def first_line:
    if type == "string" then ([split("\n")[] | sub("^\\s+"; "") | sub("\\s+$"; "") | select(. != "")] | .[0] // "")
    else "" end;
  def usable_state:
    type == "object"
    and (if (.schema | type) == "number" and .schema != 1 then false
         else (.actionable | type) == "number" or ((.backends | type) == "object" or (.backends | type) == "array") end);
  def kind_of: if .kind == null then "" else (.kind | tostring) end;
  # A runtime is keyed id/branch; people read "id branch", as kempt summary prints it.
  def dispname: tostring | split("/") as $p
                | if ($p | length) > 1 then (($p[0:-1] | join("/")) + " " + $p[-1]) else . end;
  def ordered_unique: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
  # logic.js collectItems: the enabled backends in their order, each one pending section for
  # items with no kind and one per kind after it, and the held items apart.
  def collect:
    (if (.backends | type) == "object" then .backends else {} end) as $b
    | [("dnf", "flatpak") | select(. as $k | $b[$k] | truthy)] as $first
    | ($first + [$b | keys_unsorted[] | select(. as $k | ($first | any(.[]; . == $k)) | not)]) as $keys
    | [ $keys[] as $k | $b[$k] | select(type == "object" and .enabled != false)
        | (if (.items | type) == "array" then .items else [] end)
        | map(if type == "object" then . else {} end)
        | {key: $k, pending: map(select((.held | truthy) | not)), held: map(select(.held | truthy))} ] as $bs
    | { sections: [ $bs[] as $e
          | ( ($e.pending | map(select(kind_of == "")) | select(length > 0)
               | {title: (section_titles[$e.key] // $e.key), items: .}),
              ( $e.pending | map(kind_of) | map(select(. != "")) | ordered_unique | .[] as $kd
               | {title: ((kind_titles[$e.key] // {})[$kd] // ($e.key + " " + $kd)),
                  items: [$e.pending[] | select(kind_of == $kd)]} ) ) ],
        held: [$bs[].held[]] };
  def status_records($now):
    if . == null then
      "H\u001fNo update data yet", "F\u001f" + status_copy.noSuccessfulCheckYet, "X\u001f1"
    elif (usable_state | not) then
      "H\u001fCould not read the update state", "X\u001f1"
    else
      . as $s
      | collect as $c
      | (($c.sections | length) > 0 or ($c.held | length) > 0) as $walked
      | ([$c.sections[].items | length] | add // 0) as $counted
      | (if $walked then $counted elif ($s.actionable | type) == "number" then $s.actionable else $counted end) as $actionable
      | (if $walked then ($c.held | length) elif ($s.held_total | type) == "number" then $s.held_total
         else ($c.held | length) end) as $held_total
      | ($s.status == "stale") as $stale
      | (($s.last_success | type) == "string" and ($s.last_success | sub("^\\s+"; "") | sub("\\s+$"; "")) != "") as $ever
      | ($stale and ($ever | not) and ($walked | not)) as $never_answered
      | ((($s.backends | type) == "object") and (($s.backends.flatpak | type) == "object")
         and (($s.backends.flatpak.scopes | type) == "object") and $s.backends.flatpak.scopes.user == "failed") as $user_unchecked
      | ((($s.release_upgrade | type) == "object") and (($s.release_upgrade.to | type) == "string")
         and (($s.release_upgrade.from | type) == "string") and $s.release_upgrade.to != ""
         and $s.release_upgrade.from != "") as $release_upgrade
      | (($release_upgrade | not) and ($s.offline_staged | type) == "object") as $staged
      | (if $never_answered then "Kempt cannot check for updates"
         elif $staged then
           ($s.offline_staged.count) as $n
           | (if ($n | type) != "number" or $n < 0 then status_copy.stagedHeaderUnknown
              elif $n == 1 then status_copy.stagedHeaderOne
              else ($n | tostring) + " " + status_copy.stagedHeaderTail end)
         elif $actionable == 0 then
           (if $held_total > 0 then status_copy.upToDate + dot + ($held_total | tostring) + " " + status_copy.held
            elif $user_unchecked then status_copy.upToDate + dot + status_copy.userAppsUncheckedShort
            else status_copy.upToDate end)
         elif $actionable == 1 then "1 update available"
         else ($actionable | tostring) + " updates available" end) as $header
      | (if (($s.risky_pending | type) == "array") then [$s.risky_pending[] | tostring] else [] end) as $risky
      | "H\u001f" + ($header | clean),
        (if $never_answered then ($s.error | first_line | select(. != "") | "P\u001f" + (. | clean)) else empty end),
        ( $c.sections[]
          | "S\u001f" + (.title | clean) + "\u001f" + (.items | length | tostring),
            ( [.items[] | select(.name != null and .name != "") | .name | tostring]
              | (map(select(. as $n | $risky | any(.[]; . == $n))) + map(select(. as $n | $risky | any(.[]; . == $n) | not)))
              | .[] | "N\u001f" + (dispname | clean) ) ),
        (if $held_total > 0 then
           "L\u001f" + ($held_total | tostring),
           ($c.held[] | select(.name != null and .name != "") | "M\u001f" + (.name | dispname | clean))
         else empty end),
        ( ($s.security | if type == "object" and (.count | type) == "number" and .count >= 1
                         then "C\u001f" + (.count | floor | tostring) else empty end) ),
        (if $staged then "G\u001f1" else empty end),
        (if $s.reboot_needed == true then "R\u001f" + status_copy.restartMessage else empty end),
        ( [ (if ($ever | not) then status_copy.noSuccessfulCheckYet
             elif ($s.last_success | renderable_stamp) then "Checked " + ($s.last_success | rel_time($now))
             else empty end),
            (if $stale then status_copy.lastCheckFailed else empty end),
            (if $user_unchecked then status_copy.userAppsUncheckedShort else empty end),
            ($s.metadata_refreshed | meta_age($now) | select(. != "")) ]
          | "F\u001f" + (join(dot) | clean) ),
        "X\u001f" + (if $never_answered or $stale then "1" else "0" end)
    end;
'
