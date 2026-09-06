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
OFFLINE_MARKER="$KEMPT_STATE_DIR/offline_staged.json"
LOCK_FILE="$KEMPT_STATE_DIR/lock"
# The writers' lock (see writer_lock). In the STATE dir, never the config dir: the config
# directory holds the two files the user owns and may edit by hand, and architecture.md's "Where
# Kempt writes" promises Kempt puts nothing else there.
WRITER_LOCK_FILE="$KEMPT_STATE_DIR/writer.lock"
EVENTS_FILE="$KEMPT_STATE_DIR/events.log"
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
# The other half of dnf5's arming, and the half that decides what a boot does: systemd's
# system-update-generator looks for THIS symlink and nothing else (systemd.offline-updates(7)).
# `dnf5 offline reboot` creates it; the toml above only says what the transaction thinks it is, and
# the two can disagree - a re-stage destroys the old transaction and leaves the symlink standing,
# which is a boot that detours into the offline updater and installs nothing. Read by `kempt
# doctor` alone, with lstat and never a test of the target: the generator does not care whether the
# target resolves, so neither may we. A seam because a test cannot create /system-update.
KEMPT_OFFLINE_LINK="${KEMPT_OFFLINE_LINK:-/system-update}"

kempt_init_dirs() {
  mkdir -p "$KEMPT_CONFIG_DIR" "$HIST_DIR" "$LOG_DIR" "$SNAP_DIR"
  # Sweep aged orphan tmps: a crash between mktemp and mv leaks .atomic.XXXXXX forever. +60min so
  # a tmp belonging to a live concurrent writer is never eligible. maxdepth 2, not 1: atomic_write
  # puts its temp NEXT TO the destination, and the offline baseline it rewrites lives in snapshots/.
  # A && B || C with `true` as C is not a disguised if-then-else: the sweep is best-effort and BOTH
  # a missing state dir and a failed find must land on rc 0.
  # shellcheck disable=SC2015
  [[ -d "$KEMPT_STATE_DIR" ]] && find "$KEMPT_STATE_DIR" -maxdepth 2 -name '.atomic.*' -mmin +60 -delete 2>/dev/null || true
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
# never blocks: a short line appended with >> is written atomically by the kernel, so overlapping
# writers interleave whole lines and no lock is needed. A state directory that cannot be written
# simply gets no events.
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
    # settings, and whichever command happens to log first is the one that creates it.
    if [[ ! -e "$EVENTS_FILE" ]]; then
      : > "$EVENTS_FILE" || return 0
      chmod 600 "$EVENTS_FILE" || true
    fi
    printf '%s %s %s\n' "$(now_iso)" "$via" "$1" >> "$EVENTS_FILE" || return 0
    # Retention, checked on write because there is no timer to check it on. Keeping the last 2000
    # of 2500 means the rewrite runs once every 500 events rather than on every append, and it goes
    # through atomic_write so a reader (`kempt log`, `kempt doctor`) never sees a half-rewritten
    # file - mktemp's 0600 temp carries the mode across the replace. A count rather than an age on
    # purpose: it is a bound a human can reason about without knowing how busy the box has been.
    local n
    n="$(wc -l < "$EVENTS_FILE")" || return 0
    if (( n > 2500 )); then
      tail -n 2000 "$EVENTS_FILE" | atomic_write "$EVENTS_FILE" || return 0
    fi
  } 2>/dev/null || true
  return 0
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
  awk -F'\t' '
    $1 != prev { if (prev != "") print prev "\t" vals; prev = $1; vals = $2; next }
    { vals = vals "," $2 }
    END { if (prev != "") print prev "\t" vals }'
}

kempt_default() {  # key → default ("" if unknown)
  case "$1" in
    include_flatpak|auto_accept) echo true ;;
    surface) echo terminal ;;
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
    # mid-transaction (spec §Run surfaces), so Kempt recommends the offline path first.
    risky_regex) echo '^(kernel|systemd|glibc|dbus|mesa|qt6|kf6|plasma-workspace|kwin)' ;;
    *) echo "" ;;
  esac
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
# INVARIANT: config_set, hold_add and hold_remove hold this across the WHOLE read-modify-write.
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
# Nesting is ruled out by construction rather than handled: the only callers are cmd_config,
# cmd_hold and cmd_unhold, one write per command, and nothing on the privileged or checking paths
# calls a writer. Re-entering would be quiet rather than loud - `exec 7>>` on a held fd CLOSES it
# first, dropping the outer lock unnoticed. If a writer ever has to call another one, pass the open
# descriptor down; do not re-open it.
#
# `>>` and not `>`: the `>` form truncates on open, so a process that merely ATTEMPTS the lock would
# erase a live holder's file first (same reasoning as acquire_lock's note). kempt_init_dirs first,
# also like acquire_lock: a box where the state directory cannot be created fails there, not here.
writer_lock() {
  kempt_init_dirs
  exec 7>>"$WRITER_LOCK_FILE"
  # -w rather than -n: these writes are ~10ms apiece, so an overlap is a wait of that length and
  # refusing would turn it into a lost write instead. 30s is far past any honest queue - reaching
  # it means a holder is wedged, and writing anyway would put the lost-write bug straight back.
  # rc 1, and the caller reports it: a lock we could not take is not a write that failed.
  flock -w 30 7 || {
    echo "kempt: could not take the writers' lock at $WRITER_LOCK_FILE after 30s" >&2
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
  if [[ -e "$CONFIG_FILE" && ! -r "$CONFIG_FILE" ]]; then
    echo "warning: $CONFIG_FILE exists but is unreadable - using default for $1" >&2
  fi
  local v
  v="$(grep -s "^$1=" "$CONFIG_FILE" | tail -1 | cut -d= -f2- || true)"
  printf '%s\n' "${v:-${2:-$(kempt_default "$1")}}"
}

config_set() {  # key value
  [[ "$1" =~ ^[a-z][a-z0-9_]+$ ]] || { echo "invalid config key: $1" >&2; return 2; }
  [[ "$2" == *$'\n'* ]] && { echo "config value must be single-line" >&2; return 2; }
  kempt_init_dirs
  touch "$CONFIG_FILE"
  # The read below decides what the write puts back, so the two are one critical section: a second
  # writer that reads between them writes this key straight back out. Held to the rename and no
  # further - see writer_lock.
  writer_lock || return 1
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
# How long a metadata refresh may take before the check gives up and reports stale. The wait that
# actually happens is a polkit dialog nobody is at: a background check cannot answer one, so it
# sits here for the full two minutes. A seam only so the suite can reach that branch - hardcoded,
# no test could drive it without waiting two minutes, and it had none.
KEMPT_REFRESH_TIMEOUT="${KEMPT_REFRESH_TIMEOUT:-120}"
priv_refresh() { timeout "$KEMPT_REFRESH_TIMEOUT" ${KEMPT_PKEXEC:+$KEMPT_PKEXEC} "$KEMPT_REFRESH_HELPER" "$@" 9>&-; }
priv_apply()   { ${KEMPT_PKEXEC:+$KEMPT_PKEXEC} "$KEMPT_APPLY_HELPER" "$@" 9>&-; }

# The tail of a captured stderr file, flattened to one line for a JSON string or a warning, in one
# place because all three callers need the same pipeline. The trailing `sed` is not cosmetic:
# `tr '\n' ' '` turns the file's final newline into a SPACE, and command substitution strips
# newlines but not spaces, so without it every error ends in one - inside state.json's `error`,
# for every reader to render.
stderr_tail() {  # file → last <=200 bytes, newlines to spaces, no trailing space
  tail -c 200 "$1" | tr '\n' ' ' | sed 's/ *$//'
}

# A stderr tail from a privileged call, turned into something a human can act on. `timeout` reports
# a MISSING helper as "timeout: failed to run command '<path>': No such file or directory", which
# reads as "the update check timed out" and sends the reader hunting a network problem they do not
# have; the real cause is that install.sh has never run. Anything else passes through untouched.
explain_helper_error() {  # stderr-tail → the tail, the missing-helper message, or the declined-auth one
  local t="$1" h
  if [[ "$t" == *"No such file"* ]]; then
    for h in "$KEMPT_REFRESH_HELPER" "$KEMPT_APPLY_HELPER"; do
      if [[ "$t" == *"$h"* || "$t" == *"${h##*/}"* ]]; then
        printf '%s\n' "root helper not installed - run ./install.sh (see: kempt doctor)"
        return 0
      fi
    done
  fi
  # The missing-helper rewrite goes first because it is the more specific claim - it matches a
  # helper path in the text. Everything else goes through the one mapping below.
  friendly_error "$t"
}

# The ONE place a refused authentication becomes words a human is meant to read, used by every
# surface that renders a failure reason: state.json's `error`, the run summary, the notification,
# `kempt history` and the event log. pkexec's own wording - "Error executing command as another
# user: Not authorized" - reads as a broken installation, when what happened is that the person at
# the keyboard closed the dialog. The raw text is never lost; it stays in the run log.
# Three markers, all pkexec's: polkit's refusal, a dismissed dialog, and the prefix it wraps both in.
KEMPT_AUTH_DECLINED='authentication declined or cancelled'
friendly_error() {  # raw text → the same text, or the declined-auth sentence
  case "$1" in
    *"Not authorized"*|*dismissed*|*"Error executing command as another user"*)
      printf '%s\n' "$KEMPT_AUTH_DECLINED" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Why a run failed, in one line, for the four places that render it - "see <log>" is not an answer
# when the log is four hundred lines of dnf progress. The first line that NAMES a failure, not the
# first line: a package manager's log opens with repository chatter, and reporting "Updating
# repositories" as the reason is worse than silence. Nothing matched → the last non-empty line,
# where a terse failure lands. Indentation stripped and capped at 120 characters, because this ends
# up in a notification body.
run_failure_reason() {  # log-file → one line, possibly empty
  local line=""
  [[ -r "$1" ]] || { printf '\n'; return 0; }
  line="$(grep -m1 -iE 'error|fail|not authorized|dismissed|cannot|denied|refused' "$1" || true)"
  [[ -n "$line" ]] || line="$(grep -v '^[[:space:]]*$' "$1" | tail -1 || true)"
  line="${line#"${line%%[![:space:]]*}"}"
  line="$(friendly_error "$line")"
  printf '%s\n' "${line:0:120}"
}
notify()       { "$KEMPT_NOTIFY" "$@" >/dev/null 2>&1 || true; }
now_iso()      { date -Is; }

# --- passwordless polkit rule rendering ---
# Split out of bin/kempt so the render and its self-check are unit-testable without touching
# /etc: the ONLY thing this file's caller then does is hand the result to install(1).
render_passwordless_rule() {  # template_file out_file → 0, or 2 with nothing written
  local tmpl="$1" out="$2" u
  # $(id -un), never $USER: a crafted USER env var used to be sed-injected into the render and
  # could drop the scope clause. id -un is kernel truth, awk -v never interprets it, and the
  # guard below also keeps the name clear of gsub's replacement metachars (& and backslash).
  u="$(id -un)"
  [[ "$u" =~ ^[a-z_][a-z0-9._-]*$ ]] || {
    echo "unexpected username: $u - install the rules file manually; see polkit/49-kempt.rules.in" >&2
    return 2; }
  awk -v u="$u" '{gsub(/@USER@/, u); print}' "$tmpl" > "$out" || { rm -f "$out"; return 2; }
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
  code="$(grep -v '^[[:space:]]*//' "$out" | tr '\n' ' ' | tr -s '[:space:]' ' ')"
  code="${code# }"; code="${code% }"
  expected='polkit.addRule(function(action, subject) {'
  expected+=' if (action.id == "io.github.erez_c137.kempt.apply" &&'
  expected+=" subject.user == \"$u\" && subject.active && subject.local) {"
  expected+=' return polkit.Result.YES; } });'
  if [[ "$code" != "$expected" ]]; then
    echo "rendered rule is not the rule this command installs - refusing" >&2
    rm -f "$out"; return 2
  fi
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
  # `.name as $n` is load-bearing: jq evaluates the argument of index() against index()'s own
  # input ($holds, an array), so an inline `index(.name)` dies with "Cannot index array".
  jq --argjson holds "$holds_json" '[.[] | .name as $n | . + {held: (($holds | index($n)) != null)}]'
}

# stdin: items JSON (AFTER mark_held) → one session-critical name per line.
# Held packages are excluded on purpose: the user already declined that one, so recommending a
# whole different update strategy because of it would be nagging about a decision already made.
# Second stage drops build/doc tails: kernel-devel, qt6-qtbase-devel, kf6-*-doc and friends are
# never loaded by the running session, so they cannot break it - counting them turns an ordinary Qt
# bump into a hundred-package "session-critical" scare.
# `|| true`: grep exits 1 when it selects nothing, and "nothing risky" is the common, happy case.
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
  {
    # `$2"" != $3""` forces STRING comparison: awk compares two numeric-looking fields
    # numerically, which makes a real 1.1 → 1.10 bump compare equal and vanish from the report.
    join -t "$(printf '\t')" "$1" "$2" | awk -F'\t' '$2"" != $3"" {print "U\t"$1"\t"$2"\t"$3}'
    join -t "$(printf '\t')" -v2 "$1" "$2" | awk -F'\t' '{print "A\t"$1"\t\t"$2}'
    join -t "$(printf '\t')" -v1 "$1" "$2" | awk -F'\t' '{print "R\t"$1"\t"$2"\t"}'
  } | jq -Rn '
    [inputs | split("\t")] |
    { updated: [.[] | select(.[0]=="U") | {name:.[1], from:.[2], to:.[3]}],
      added:   [.[] | select(.[0]=="A") | {name:.[1], to:.[3]}],
      removed: [.[] | select(.[0]=="R") | {name:.[1], from:.[2]}] }'
}

# --- download sizes ---
# Joined by NAME, never by name+version: an item's `to` can be a comma-joined EVR list when
# multilib twins diverge ("5.3.9-4.fc44,5.3.10-1.fc44"), so it is not a usable key, and dnf_sizes
# has already folded its side to one row per name. Name is the only key both sides agree on.
# An item with no row keeps NO size_bytes key at all - not a zero. "Absent" has to stay
# distinguishable from "free", because absent is what suppresses the figure downstream.
attach_sizes() {  # $1 = sizes TSV; stdin: items JSON (after mark_held) → items + optional size_bytes
  jq --rawfile tsv "$1" '
    ($tsv | split("\n") | map(select(length>0) | split("\t"))
          | map({key: .[0], value: (.[1] | tonumber)}) | from_entries) as $sz
    | map(. + (if $sz[.name] != null then {size_bytes: $sz[.name]} else {} end))'
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
assemble_state() {  # $1 dnf items, $2 fp items, $3 status, $4 error, $5 fp_enabled(true|false), $6 prev last_success ISO or "", $7 risky_pending JSON array (optional), $8 reboot_needed true|false (optional), $9 dnf download bytes or "" (optional), $10 flatpak download bytes or "" (optional), $11 offline_staged JSON object or "" (optional)
  jq -n --argjson dnf "$1" --argjson fp "$2" --arg status "$3" --arg error "$4" \
        --argjson fpe "$5" --arg pls "$6" --argjson risky "${7:-[]}" \
        --argjson reboot "${8:-false}" --arg dnfb "${9:-}" --arg fpb "${10:-}" \
        --argjson offst "${11:-null}" \
        --arg now "$(now_iso)" '
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
    {schema: 1, last_check: $now,
     last_success: (if $status == "ok" then $now elif $pls == "" then null else $pls end),
     status: $status, error: $error,
     backends: {dnf: ($dnf | wrap(true; $dnfb)), flatpak: ($fp | wrap($fpe; $fpb))},
     actionable: (($dnf + $fp) | [.[] | select(.held|not)] | length),
     held_total: (($dnf + $fp) | [.[] | select(.held)] | length),
     risky_pending: $risky,
     reboot_needed: $reboot}
    + total + staged'
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

write_state() { atomic_write "$STATE_FILE"; }   # per-process mktemp: overlapping checks (timer + event watch + post-run) must never collide

maybe_refresh_metadata() {  # ≤ every 3h, AC power, unmetered; never blocks check on failure
  [[ -n "${KEMPT_SKIP_REFRESH:-}" ]] && return 0
  local last=0 now; now="$(date +%s)"
  # `|| echo 0` covers the TOCTOU gap: the file can vanish between the -f test and the stat
  # (state dir cleanup, another process), and a bare failing stat escapes errexit here.
  [[ -f "$LAST_REFRESH_FILE" ]] && last="$(stat -c %Y "$LAST_REFRESH_FILE" || echo 0)"
  (( now - last < 10800 )) && return 0
  on_battery && return 0
  metered_connection && return 0
  # ONE gate, two arms. Both backends are refresh-then-read-cache, so both fetch here and neither
  # carries its own interval, power or metering rule - a second gate would be a second policy to
  # keep in step with this one. `ok` records whether ANY fetch landed; see the stamp at the bottom.
  local ok=0
  # Logged as its own step, because a failure here is invisible everywhere else: the check that
  # follows carries on against the cached metadata and reports status "ok", so a box whose metadata
  # has not refreshed for a week looks exactly like one that is up to date. The two skipped paths
  # above emit nothing - nothing was attempted. Stderr stays discarded: this is a background
  # best-effort step, and the consequence a user can act on is reported by the next check.
  if priv_refresh refresh >/dev/null 2>&1; then
    ok=1
    log_event "refresh ok"
  else
    log_event "refresh failed"
  fi
  # Gated on include_flatpak: fetching flathub's summary for a backend the user switched off is
  # network nobody asked for, on the one code path whose entire job is to be careful with it. The
  # arm runs independently of dnf's verdict - they fail for unrelated reasons (a declined
  # authentication against an unreachable remote), so one failing must not cancel the other. And it
  # stays unprivileged: flatpak_refresh runs as this user, never through priv_refresh, so the
  # no-dialog polkit action remains dnf-only.
  if is_true "$(config_get include_flatpak)"; then
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
  if (( ok )); then
    touch "$LAST_REFRESH_FILE" || true
  fi
  return 0
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
offline_system_status() {  # → ready | absent | dnf5's own status word
  [[ -r "$KEMPT_OFFLINE_TOML" ]] || { printf 'absent\n'; return 0; }
  local s
  s="$(sed -n 's/^[[:space:]]*status[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
       "$KEMPT_OFFLINE_TOML" 2>/dev/null | head -1 || true)"
  printf '%s\n' "${s:-absent}"
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
  out="$(jq -r -n '
      def basename($n):
        ($n | sub("\\.[^.]*$"; "") | split("-")) as $p
        | if ($p | length) < 3 then "" else ($p[0:-2] | join("-")) end;
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
offline_staged_state() {  # → {staged_at, count, armed, holds_conflict, names_source} JSON, or nothing
  local marker
  marker="$(offline_marker_read)"
  [[ -n "$marker" ]] || return 0
  [[ "$(offline_system_status)" == ready ]] || return 0
  # A marker the harvest has DEMOTED describes a stage that cannot install, whatever dnf5's status
  # still says - a `ready` transaction whose /system-update symlink is gone is exactly that, and
  # the status gate above cannot see it. Publishing it anyway would re-make, on every check, the
  # promise reconcile_detour_stage exists to withdraw.
  # `.armed == false` and never `.armed // true`: jq's alternative operator treats false as empty.
  jq -e '.armed == false' <<<"$marker" >/dev/null 2>&1 && return 0
  local names="" names_source=none
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
    # printf '%s' rather than a here-string on both sides: <<< appends a newline, and an empty list
    # would arrive at jq as one empty-string element.
    local names_json holds_json
    names_json="$(printf '%s' "$names" | jq -Rn '[inputs]')"
    holds_json="$(holds_for dnf | jq -Rn '[inputs]')"
    # `. as $x` first, for the index() trap mark_held carries the note about.
    conflict="$(jq -cn --argjson n "$names_json" --argjson h "$holds_json" \
                  '[$n[] | . as $x | select($h | index($x))] | unique')"
  fi
  # count: markers written before the field existed carry no number, and null is the honest answer.
  # Every reader drops the figure from its sentence rather than inventing one.
  jq -c --argjson conflict "$conflict" --arg nsrc "$names_source" \
    '{staged_at: (.staged_at // null), count: (.staged // null), armed: true,
      holds_conflict: $conflict, names_source: $nsrc}' <<<"$marker"
}

# The unhold mirror's predicate: was this armed stage built WITHOUT the package the user has just
# released? It needs its own recorded answer, because the transaction can never supply one - a
# package absent from it was either excluded at stage time or simply had no update, and those look
# identical from the inside. `staged_excluded` is that answer, written when the stage was made.
# The legacy fallback, for a marker written before the field existed: warn only when the package is
# pending RIGHT NOW, since a package with no update to miss cannot have been missed.
offline_stage_built_without() {  # name → 0 when an armed stage left it out
  local marker
  marker="$(offline_marker_read)"
  [[ -n "$marker" ]] || return 1
  [[ "$(offline_system_status)" == ready ]] || return 1
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
# Copy lives here rather than at the call site for the reason KEMPT_AUTH_DECLINED does: more than
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
  printf 'The staged update was built without %s - the next restart will not install it. Rebuild when ready: kempt update --surface=offline.\n' "$1"
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
'

# One-line count of what a run actually changed. Shared by cmd_update's notification and the
# offline harvest's: a transaction that only installs or removes packages must never be
# announced as "0 packages" by one surface and correctly by the other.
run_counts_phrase() {  # history-json-file → "N updated, +N installed, -N removed" | "no package changes"
  jq -r "$KEMPT_JQ_COUNTS"'
    def tot(k): [.backends[] | .[k] | length] | add // 0;
    counts_phrase(tot("updated"); tot("added"); tot("removed"); false)' "$1"
}

# What the next restart will install, in one line, or nothing. Deliberately NOT part of
# render_summary: that renders one history entry, and a staged transaction is not something a past
# run did - it is something the box is about to do. Read from the state the last check wrote, the
# only place the marker and dnf5's status have already been reconciled.
# The count can legitimately be unknown (a marker written before the field existed), and the
# sentence drops the figure rather than printing "null" or guessing a number.
staged_summary_line() {  # → one line, or nothing
  local s
  # The "staged:" prefix is what separates "no staged transaction" from "a staged transaction with
  # no count": both would otherwise reach the caller as an empty string.
  s="$(jq -r -n '[inputs][0].offline_staged? // empty
                 | select(type == "object")
                 | "staged:" + ((.count // "") | tostring)' "$STATE_FILE" 2>/dev/null || true)"
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
  jq -r "$KEMPT_JQ_COUNTS"'
    def newest(v): v | split(",") | last;   # installonly sets stay truthful in JSON; humans see newest → newest
    def lines(b): b.updated | map("  " + .name + " " + newest(.from) + " → " + newest(.to)) | join("\n");
    def heldline: [.backends[].skipped_held[]] | if length == 0 then empty
                  else "Held (skipped): " + join(", ") end;
    # a transaction that installs or removes packages changed the system just as much as one
    # that upgrades them: counting only .updated under-reports what actually happened.
    # counts_phrase (KEMPT_JQ_COUNTS) is the shared definition; `true` keeps the update count on
    # the line even at zero, which is what a per-backend line has always printed.
    def counts(b): counts_phrase(b.updated|length; b.added|length; b.removed|length; true);
    # `.error // ""`: entries written before the field existed have no .error at all, and a
    # summary of an old run must still render rather than printing "null".
    "Kempt - " + .timestamp + " (" + .surface + ", " + (.duration_sec|tostring) + "s) "
      + (if .status == "ok" then "✓"
         else "FAILED - see " + .log
              + (if (.error // "") != "" then " (" + .error + ")" else "" end) end),
    "System (dnf): " + counts(.backends.dnf)
      + (if .backends.dnf.status != "ok" then " [" + .backends.dnf.status + "]" else "" end),
    (if (.backends.dnf.updated|length) > 0 then lines(.backends.dnf) else empty end),
    "Apps (flatpak): " + counts(.backends.flatpak)
      + (if .backends.flatpak.status != "ok" then " [" + .backends.flatpak.status + "]" else "" end),
    (if (.backends.flatpak.updated|length) > 0 then lines(.backends.flatpak) else empty end),
    heldline,
    # ONLY when a restart is owed. `false` here does not mean "no restart needed" - it also means
    # the check could not work the answer out, which it reports the same way, and the state
    # schema says in as many words that no affirmative line may be rendered from it. "Reboot: not
    # needed" was this file telling the reader something Kempt does not know.
    (if .reboot_needed then "Reboot: needed" else empty end)
  ' "$1"
}
