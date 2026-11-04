#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
# kempt-apply picks --pty when stdin is a terminal; every exact-command assertion below is the
# non-terminal case, whoever runs the suite. The terminal case has its own test.
exec </dev/null
RH="$REPO_ROOT/libexec/kempt-refresh"
AH="$REPO_ROOT/libexec/kempt-apply"
# What every dnf5 command is wrapped in: systemd starts it as a fresh service with these properties
# and this environment, and every dnf5 argument comes after `--`. sd [properties] dnf5-args... prints
# the command line the ECHO seams print. KEMPT_SYSTEMD_RUN is the stand-in tests/lib.sh writes.
# Each verb runs under one fixed unit name, so a second run cannot start while the first is going
# and the helper can ask systemd about its own run. unit_for reads the verb from dnf5's arguments.
SD_BASE="--pipe --wait --quiet --unit=@UNIT@ --expand-environment=no -p UMask=0022 -p LimitCORE=0 --setenv=PATH=/usr/sbin:/usr/bin:/sbin:/bin --setenv=LC_ALL=C.UTF-8 --setenv=HOME=/root"
unit_for() {  # dnf5-args... → the unit the helper runs them under
  case "$*" in
    "--cacheonly check-update"*) echo kempt-refresh-check.service ;;
    "makecache --refresh")       echo kempt-refresh-refresh.service ;;
    "upgrade --offline"*)        echo kempt-apply-dnf-offline-stage.service ;;
    upgrade*)                    echo kempt-apply-dnf-upgrade.service ;;
    "offline reboot -y")         echo kempt-apply-dnf-offline-arm.service ;;
    "offline clean -y")          echo kempt-apply-dnf-offline-clean.service ;;
    *)                           echo "no-unit-for-$*" ;;
  esac
}
sd() { local props="$1"; shift; echo "$KEMPT_SYSTEMD_RUN ${SD_BASE/@UNIT@/$(unit_for "$@")}${props:+ $props} -- /usr/bin/dnf5 $*"; }

# ECHO=1 on the rejection cases too (belt and braces): if an arg guard is ever removed, the
# assertion fails loudly instead of the test reaching a real dnf5 invocation.
assert_exit 2 "refresh: no verb"        env KEMPT_REFRESH_ECHO=1 bash "$RH"
assert_exit 2 "refresh: bad verb"       env KEMPT_REFRESH_ECHO=1 bash "$RH" nuke
# Extra args are never forwarded to dnf5, so they must be REFUSED rather than silently dropped -
# `kempt-refresh check --installroot=/foo` must not look like it honoured the flag.
assert_exit 2 "refresh: extra args rejected"  bash "$RH" check --installroot=/foo
assert_exit 2 "refresh: trailing empty arg rejected" bash "$RH" refresh ''
# KEMPT_REFRESH_ECHO mirrors apply's seam: print the final command instead of exec'ing it.
assert_eq "$(KEMPT_DNF5_VERSION=5.2.18.0 KEMPT_REFRESH_ECHO=1 bash "$RH" check)" "$(sd '' --cacheonly check-update --quiet)" \
  "refresh helper: check builds exact command"
# dnf5 5.4.0 added --json to check-update. The verb, its polkit action and its one argument stay
# the same; only the output format follows the installed dnf5.
assert_eq "$(KEMPT_DNF5_VERSION=5.4.0.0 KEMPT_REFRESH_ECHO=1 bash "$RH" check)" \
  "$(sd '' --cacheonly check-update --quiet --json)" "refresh helper: check asks for JSON from dnf5 5.4.0"
assert_eq "$(KEMPT_DNF5_VERSION=5.10.0.0 KEMPT_REFRESH_ECHO=1 bash "$RH" check)" \
  "$(sd '' --cacheonly check-update --quiet --json)" "...compared as versions, so 5.10 is newer than 5.4"
assert_eq "$(KEMPT_DNF5_VERSION=5.3.9.0 KEMPT_REFRESH_ECHO=1 bash "$RH" check)" \
  "$(sd '' --cacheonly check-update --quiet)" "...and text before it"
# The time limit is inside the helper, as root: the CLI's `timeout` wraps pkexec and cannot signal a
# root dnf5. The exact string pins the fixed 120 s and the 10 s before SIGKILL, as unit properties.
assert_eq "$(KEMPT_REFRESH_ECHO=1 bash "$RH" refresh)" "$(sd '-p RuntimeMaxSec=120 -p TimeoutStopSec=10' makecache --refresh)" \
  "refresh helper: refresh builds exact command, bounded as root"
assert_exit 2 "apply: no verb"          bash "$AH"
assert_exit 2 "apply: bad verb"         bash "$AH" rm-rf
assert_exit 2 "apply: injection via exclude" bash "$AH" dnf-upgrade '--exclude=foo;rm -rf /'
assert_exit 2 "apply: option smuggling"      bash "$AH" dnf-upgrade '--installroot=/'
# The flatpak verb is GONE from the root helper: `flatpak update` needs no password of its own in
# an active local session, so it runs as the user from backends/flatpak.sh instead. The verb must
# be refused like any other unknown one - a stray caller (an old widget, a script, a shell history
# line) must not quietly reach a privileged flatpak. ECHO=1 is the belt-and-braces: if the verb
# ever came back, this asserts loudly instead of the assertion passing on a real flatpak failure.
assert_exit 2 "apply: the flatpak verb is gone from the root helper" \
  env KEMPT_APPLY_ECHO=1 bash "$AH" flatpak-update -y
# The USAGE LINE, not just the exit code, and that is the whole point of this assertion. Exit 2
# alone does not discriminate: the old THREE-verb helper also exited 2 for this argument list,
# because it re-checked app ids against the installed set and this box does not have that app. Its
# verdict was therefore a function of which flatpaks happened to be installed on the machine
# running the suite - in a suite whose contract is that it needs no flatpak at all. A usage line
# can only name two verbs when there are two, so this one fails against the old helper for the
# right reason instead of passing against it for the wrong one.
fp_verb_out="$(KEMPT_APPLY_ECHO=1 bash "$AH" flatpak-update -y org.gimp.GIMP 2>&1 || true)"
assert_eq "$fp_verb_out" \
  "usage: kempt-apply dnf-upgrade [args]|dnf-offline-stage [args]|dnf-offline-arm|dnf-offline-clean" \
  "apply: ...and says so with a usage line naming only the dnf verbs"
# KEMPT_APPLY_ECHO=1 makes the helper print the final command instead of exec'ing it (test seam)
got="$(KEMPT_APPLY_ECHO=1 bash "$AH" dnf-upgrade -y --exclude=vim-common --exclude=kernel-core)"
assert_eq "$got" "$(sd '' upgrade -y --exclude=vim-common --exclude=kernel-core)" "dnf-upgrade builds exact command"
got2="$(KEMPT_APPLY_ECHO=1 bash "$AH" dnf-offline-stage -y)"
assert_eq "$got2" "$(sd '' upgrade --offline -y)" "offline stage builds exact command"
# Staging is only half the job: `dnf5 upgrade --offline` leaves the transaction at
# status="download-complete", which no boot ever applies. `dnf5 offline reboot` is what flips it to
# "ready" and creates the /system-update symlink systemd's generator looks for - and it reboots
# immediately unless DNF_SYSTEM_UPGRADE_NO_REBOOT is set (dnf5-offline(8)). Kempt arms and lets the
# person choose when, so the env var is load-bearing, not decoration: without it this verb reboots
# the box out from under whoever pressed a button labelled "Install on Next Restart". It is set
# on the unit with --setenv, since a unit's environment is its own; that also puts it on the command
# line the ECHO seam prints, so this assertion can pin the reboot guard.
got3="$(KEMPT_APPLY_ECHO=1 bash "$AH" dnf-offline-arm)"
assert_eq "$got3" "$(sd --setenv=DNF_SYSTEM_UPGRADE_NO_REBOOT=1 offline reboot -y)" \
  "offline arm builds exact command, with the no-reboot guard"
got4="$(KEMPT_APPLY_ECHO=1 bash "$AH" dnf-offline-clean)"
assert_eq "$got4" "$(sd '' offline clean -y)" "offline clean builds exact command"
# Neither verb takes an argument, so neither may SILENTLY DROP one. dnf5's offline subcommands
# accept flags of their own (--installroot, --releasever); accepting-and-ignoring would let a
# caller believe a scope was honoured when the root helper had thrown it away.
assert_exit 2 "apply: arm takes no arguments" \
  env KEMPT_APPLY_ECHO=1 bash "$AH" dnf-offline-arm -y
assert_exit 2 "apply: clean takes no arguments" \
  env KEMPT_APPLY_ECHO=1 bash "$AH" dnf-offline-clean --installroot=/
# The two flatpak command-shape assertions that used to sit here now live in tests/test_flatpak.sh,
# against flatpak_apply and its own seam: that is where the command is built now.

# --- the helper protects a stored Fedora release upgrade on its own ------------------------------
# The CLI refuses to stage over one, but the CLI runs as the user, and a process inside polkit's
# retention window (or under passwordless mode) can call this helper directly. So the three offline
# verbs read dnf5's transaction-state file as root and refuse with exit 3 when a release upgrade is
# stored. ECHO stays set throughout: a guard that stopped working prints a command here instead of
# running one.
REFUSED_RC=3
relup_line() { printf 'kempt-apply: refusing %s: a Fedora release upgrade (44 -> 45) is stored\n' "$1"; }
unread_line() { printf 'kempt-apply: refusing %s: the stored offline transaction cannot be read, so it may be a Fedora release upgrade\n' "$1"; }
declare -A offline_cmd=(
  [dnf-offline-stage]="$(sd '' upgrade --offline -y)"
  [dnf-offline-arm]="$(sd --setenv=DNF_SYSTEM_UPGRADE_NO_REBOOT=1 offline reboot -y)"
  [dnf-offline-clean]="$(sd '' offline clean -y)"
)
offline_args() { [[ "$1" == dnf-offline-stage ]] && echo -y; return 0; }
printf 'this is not a transaction-state file\n' > "$TESTTMP/garbage.toml"
# Both keys present but one is not a release version: read as "cannot be read", never as a match.
sed 's/^target_releasever = .*/target_releasever = "45\\n"/' "$FIXTURES/offline-release-upgrade.toml" > "$TESTTMP/odd-value.toml"
for v in dnf-offline-stage dnf-offline-arm dnf-offline-clean; do
  # shellcheck disable=SC2046 # offline_args prints zero or one word
  assert_exit "$REFUSED_RC" "$v is refused over a stored release upgrade" -- \
    env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$FIXTURES/offline-release-upgrade.toml" bash "$AH" "$v" $(offline_args "$v")
  assert_eq "$(cat "$TESTTMP/last_output")" "$(relup_line "$v")" "...and says what is stored, running nothing"
  # Downloaded and never armed is where a release upgrade spends most of its life.
  # shellcheck disable=SC2046
  assert_exit "$REFUSED_RC" "$v is refused over a release upgrade that is downloaded but not armed" -- \
    env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$FIXTURES/offline-release-upgrade-downloaded.toml" bash "$AH" "$v" $(offline_args "$v")
  # shellcheck disable=SC2046
  assert_exit 0 "$v is allowed over an ordinary offline update" -- \
    env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" bash "$AH" "$v" $(offline_args "$v")
  assert_eq "$(cat "$TESTTMP/last_output")" "${offline_cmd[$v]}" "...and builds its usual command"
  # shellcheck disable=SC2046
  assert_exit 0 "$v is allowed when nothing is stored" -- \
    env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$TESTTMP/no-such-state.toml" bash "$AH" "$v" $(offline_args "$v")
  assert_eq "$(cat "$TESTTMP/last_output")" "${offline_cmd[$v]}" "...and builds its usual command"
  # Fail closed: a file that is there but says nothing usable may be a release upgrade.
  # shellcheck disable=SC2046
  assert_exit "$REFUSED_RC" "$v is refused when the stored state is not a transaction-state file" -- \
    env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$TESTTMP/garbage.toml" bash "$AH" "$v" $(offline_args "$v")
  assert_eq "$(cat "$TESTTMP/last_output")" "$(unread_line "$v")" "...and says it could not read it"
  # shellcheck disable=SC2046
  assert_exit "$REFUSED_RC" "$v is refused when a release version has an unexpected shape" -- \
    env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$TESTTMP/odd-value.toml" bash "$AH" "$v" $(offline_args "$v")
done
# Unreadable, which only a non-root run can arrange with chmod. As root the mode would not stop the
# read, and the seam is ignored anyway.
if [[ $EUID -ne 0 ]]; then
  cp "$FIXTURES/offline-ready.toml" "$TESTTMP/unreadable.toml"; chmod 000 "$TESTTMP/unreadable.toml"
  assert_exit "$REFUSED_RC" "an unreadable transaction-state file is refused, not taken as absent" -- \
    env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$TESTTMP/unreadable.toml" bash "$AH" dnf-offline-clean
  assert_eq "$(cat "$TESTTMP/last_output")" "$(unread_line dnf-offline-clean)" "...with the cannot-be-read line"
  chmod 600 "$TESTTMP/unreadable.toml"
else
  skip "unreadable transaction-state case - the suite is running as root"
fi
# Argument validation still comes first, so a bad argument is exit 2 whatever is stored.
assert_exit 2 "a bad argument is exit 2 even over a stored release upgrade" -- \
  env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$FIXTURES/offline-release-upgrade.toml" bash "$AH" dnf-offline-arm --poweroff
# A live upgrade does not touch the stored transaction, so it is not refused.
assert_exit 0 "dnf-upgrade is not refused over a stored release upgrade" -- \
  env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$FIXTURES/offline-release-upgrade.toml" bash "$AH" dnf-upgrade -y
assert_eq "$(cat "$TESTTMP/last_output")" "$(sd '' upgrade -y)" "...and builds its usual command"

# --- clean leaves another updater's /system-update alone -----------------------------------------
# PackageKit (Discover) points /system-update at its own prepared update. dnf5's clean would delete
# that link and cancel its install, so the clean refuses, as root, unless the path is absent or
# dnf5's link. Arm and stage go ahead: dnf5 creates the link only when the path is absent.
foreign_line() { printf 'kempt-apply: refusing %s: another updater has prepared the next restart (%s is not dnf5'"'"'s)\n' "$1" "$2"; }
FL="$TESTTMP/fl"; mkdir -p "$FL/offline" "$FL/pk-prepared" "$FL/alias-parent"
ln -sfn "$FL/pk-prepared" "$FL/foreign-link"
ln -sfn "$FL/gone" "$FL/dangling-link"
: > "$FL/regular-file"
ln -sfn offline "$FL/relative-link"                       # relative, from the link's own directory
ln -sfn "$FL/offline/" "$FL/slash-link"                   # the same text with a trailing slash
ln -sfn "$FL/offline" "$FL/alias-parent/offline-alias"
ln -sfn "$FL/alias-parent/offline-alias" "$FL/equivalent-link"   # another path to the same directory
for v in dnf-offline-clean; do
  for l in foreign-link dangling-link regular-file; do
    assert_exit "$REFUSED_RC" "$v is refused behind $l at /system-update" -- \
      env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" \
        KEMPT_OFFLINE_LINK="$FL/$l" KEMPT_OFFLINE_DATADIR="$FL/offline" bash "$AH" "$v"
    assert_eq "$(cat "$TESTTMP/last_output")" "$(foreign_line "$v" "$FL/$l")" "...and says why, running nothing"
  done
done
for v in dnf-offline-arm dnf-offline-clean; do
  for l in no-such-link relative-link slash-link equivalent-link; do
    assert_exit 0 "$v goes ahead when /system-update is ${l/no-such-link/absent}" -- \
      env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" \
        KEMPT_OFFLINE_LINK="$FL/$l" KEMPT_OFFLINE_DATADIR="$FL/offline" bash "$AH" "$v"
    assert_eq "$(cat "$TESTTMP/last_output")" "${offline_cmd[$v]}" "...and builds its usual command"
  done
done
for l in foreign-link dangling-link regular-file; do
  assert_exit 0 "the arm goes ahead behind $l, since dnf5 leaves an existing link alone" -- \
    env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" \
      KEMPT_OFFLINE_LINK="$FL/$l" KEMPT_OFFLINE_DATADIR="$FL/offline" bash "$AH" dnf-offline-arm
  assert_eq "$(cat "$TESTTMP/last_output")" "${offline_cmd[dnf-offline-arm]}" "...and builds its usual command"
done
assert_exit 0 "the stage is not refused behind another updater's link" -- \
  env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" \
    KEMPT_OFFLINE_LINK="$FL/foreign-link" KEMPT_OFFLINE_DATADIR="$FL/offline" bash "$AH" dnf-offline-stage -y
# The CLI's reading of the same refusal, so its messages name the right cause.
assert_eq "$(KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" KEMPT_OFFLINE_LINK="$FL/foreign-link" \
  KEMPT_OFFLINE_DATADIR="$FL/offline" bash -c 'source "$1/lib/common.sh"; apply_refusal_reason' _ "$REPO_ROOT")" \
  "another updater has prepared the next restart" "the CLI names another updater's restart as the reason"
assert_eq "$(KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" KEMPT_OFFLINE_LINK="$FL/regular-file" \
  KEMPT_OFFLINE_DATADIR="$FL/offline" bash -c 'source "$1/lib/common.sh"; apply_refusal_reason' _ "$REPO_ROOT")" \
  "another updater has prepared the next restart" "...also when the path is not a link at all"

# --- the verbs refuse while other users can change dnf5's folders ---------------------------------
# tests/test_apply_parents.sh has the rules, as root in a namespace. Here is what a plain run shows:
# the suite does not run as root, so everything it makes stands in for a folder another user owns.
unsafe_line() { printf 'kempt-apply: Updates paused for safety: users other than root can change %s. Run kempt doctor for the fix.\n' "$1"; }
UD="$TESTTMP/unsafe"
declare -A verb_cmd=(
  [dnf-upgrade]="$(sd '' upgrade -y)"
  [dnf-offline-stage]="${offline_cmd[dnf-offline-stage]}"
  [dnf-offline-arm]="${offline_cmd[dnf-offline-arm]}"
  [dnf-offline-clean]="${offline_cmd[dnf-offline-clean]}"
)
verb_args() { [[ "$1" == dnf-upgrade || "$1" == dnf-offline-stage ]] && echo -y; return 0; }
unsafe_case() {  # var setup label → each verb against a fresh folder at $UD made by setup
  local var="$1" setup="$2" label="$3" v
  for v in dnf-upgrade dnf-offline-stage dnf-offline-arm dnf-offline-clean; do
    rm -rf "$UD"; mkdir -p "$UD"; (cd "$UD" && eval "$setup")
    # shellcheck disable=SC2046 # verb_args prints nothing or one word
    assert_exit "$REFUSED_RC" "$v is refused when $label" -- \
      env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" "$var=$UD" bash "$AH" "$v" $(verb_args "$v")
    assert_eq "$(cat "$TESTTMP/last_output")" "$(unsafe_line "$UD")" "...and says which folder, and where the fix is"
  done
  rm -rf "$UD"
}
if [[ $EUID -ne 0 ]]; then
  unsafe_case KEMPT_DNF_SYSIMAGE_DIR 'mkdir offline' "the state folder is not root's"
  unsafe_case KEMPT_DNF_OFFLINE_PKG_DIR 'mkdir packages' "the staged-package folder is not root's"
else
  skip "folders that are not root's - the suite is running as root"
fi
# Missing folders are safe: dnf5 creates them root-only. The sandbox points all three at such paths.
for v in dnf-upgrade dnf-offline-stage dnf-offline-arm dnf-offline-clean; do
  # shellcheck disable=SC2046
  assert_exit 0 "$v goes ahead when no folder exists" -- \
    env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" bash "$AH" "$v" $(verb_args "$v")
  assert_eq "$(cat "$TESTTMP/last_output")" "${verb_cmd[$v]}" "...and builds its usual command"
done
# Argument validation still comes first.
assert_exit 2 "a bad argument is exit 2 even with an unsafe folder" -- \
  env KEMPT_APPLY_ECHO=1 KEMPT_DNF_SYSIMAGE_DIR="$TESTTMP" bash "$AH" dnf-upgrade --installroot=/

# --- umask and limits: what pkexec passes on from the caller never reaches root's dnf5 ------------
# dnf5 gets its umask and limits from the unit systemd starts it in (UMask=0022 and LimitCORE=0 are
# pinned above, and the rest are systemd's defaults), so nothing of the caller's reaches it. The
# helper's own shell still resets the umask and turns core files off, as a second layer for the two
# root processes that do run in the caller's context: this shell and systemd-run. Sourced, so they
# can be read back after its ECHO line, with the caller at umask 000 and core files on.
hard_c="$(ulimit -H -c)"
for h in "$AH" "$RH"; do
  verb=dnf-offline-clean; [[ "$h" == "$RH" ]] && verb=refresh
  # shellcheck disable=SC2016 # expanded by the inner bash
  got="$(env KEMPT_APPLY_ECHO=1 KEMPT_REFRESH_ECHO=1 KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" bash -c '
    umask 000; ulimit -S -c "$2"
    source "$1" "$3" >/dev/null
    echo "$(umask) $(ulimit -c)"' _ "$h" "$hard_c" "$verb")"
  assert_eq "$got" "0022 0" "$(basename "$h"): its own shell has umask 022 and no core files, whatever the caller set"
  # ...and first: nothing runs before the umask is set.
  assert_eq "$(grep -vE '^[[:space:]]*(#|$)' "$h" | head -1)" "umask 022" "$(basename "$h"): the umask is its first command"
done
# The same through a real file, written by a child of that shell.
mkdir -p "$TESTTMP/umask-probe"
# shellcheck disable=SC2016 # expanded by the inner bash
got_mode="$(env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" bash -c '
  umask 000; source "$1" dnf-offline-clean >/dev/null; mkdir "$2/d"; : > "$2/f"; stat -c "%a" "$2/d" "$2/f" | tr "\n" " "' \
  _ "$AH" "$TESTTMP/umask-probe")"
assert_eq "$got_mode" "755 644 " "a directory and a file made under the helper are 755 and 644 after the caller's umask 000"

# --- the one way root's dnf5 starts: systemd-run, and nothing else ---------------------------------
# pkexec hands the helper far more of the caller than its environment: umask, limits, ignored
# signals, the working directory, nice, CPU affinity, the cgroup. Bash cannot undo all of that
# (an ignored signal stays ignored across exec), so the helper does not try. It validates, reads,
# and starts systemd-run as a child it watches (run_watched),
# and systemd starts dnf5 as a fresh service that inherits none of it.
# That only holds while the helper's own shell runs nothing else and writes nothing. This reads the
# helper's code (comments out, continued lines joined) and prints each line that breaks the shape:
#   - dnf5 named anywhere but as systemd-run's command, the rpm version read, or an error message
#   - more than one exec, or one that is not the ECHO seam's `exec "$@"`
#   - run called anywhere but on the one systemd-run line, with its fixed properties
#   - a redirection other than to stderr or /dev/null, or a command that writes or starts another
#   - run_watched, claim_unit or watch_unit other than exactly the text below. They are the one
#     place the shell makes pipes, starts cats, asks systemctl and sends signals, so they are read
#     as a whole and then set aside for the checks above.
#   - a unit name other than a literal from the fixed table
# The three as the check reads them: comments out, word for word. A change to them in the helpers
# must be made here too, on purpose.
VETTED="$(cat <<'EOF'
run_watched() {
  local out err out_pid="" err_pid="" sd_pid wd wd_pid wd_live=1 who r rc=0 woke=0 stopped=0 sig=0 verdict="" pause
  local -a ids
  claim_unit
  if [[ "$2" == --pipe ]]; then
    exec {out}> >(cat)
    out_pid=$!
    exec {err}> >(cat >&2 {out}>&-)
    err_pid=$!
    { trap - INT QUIT; exec "$@"; } </dev/null >&"$out" 2>&"$err" {out}>&- {err}>&- &
    sd_pid=$!
    exec {out}>&- {err}>&-
  else
    { trap - INT QUIT; exec "$@"; } <&0 &
    sd_pid=$!
  fi
  exec {wd}< <(watch_unit </dev/null)
  wd_pid=$!
  ids=("$sd_pid" "$wd_pid")
  trap 'woke=1 stopped=1 sig=15; kill -s TERM "$sd_pid" 2>/dev/null || :' TERM
  trap 'woke=1 stopped=1 sig=2; kill -s INT "$sd_pid" 2>/dev/null || :' INT
  trap 'woke=1 stopped=1 sig=1; kill -s HUP "$sd_pid" 2>/dev/null || :' HUP
  while :; do
    woke=0 r=0 who=""
    wait -n -p who "${ids[@]}" || r=$?
    if [[ "${who:-}" == "$sd_pid" ]]; then rc=$r; break; fi
    if [[ -n "${who:-}" ]]; then
      wd_live=0
      ids=("$sd_pid")
      read -r -u "$wd" verdict || verdict=""
      if (( stopped )); then verdict=""; fi
      if [[ "$verdict" == "rc "* || "$verdict" == unknown ]]; then break; fi
      verdict=""
      continue
    fi
    (( woke )) || { rc=$r; break; }
  done
  if (( rc == 127 && stopped )); then rc=$(( 128 + sig )); fi
  trap - TERM INT HUP
  if [[ -n "$verdict" ]]; then
    kill -s TERM "$sd_pid" 2>/dev/null || :
    exec {pause}<> <(:)
    { read -r -t "$POLL" -u "$pause" _ || :; } &
    ids=("$sd_pid" "$!")
    exec {pause}<&-
    who=""
    wait -n -p who "${ids[@]}" || :
    if [[ "${who:-}" == "$sd_pid" ]]; then kill "${ids[1]}" 2>/dev/null || :
    else kill -s KILL "$sd_pid" 2>/dev/null || :; fi
    wait "${ids[@]}" 2>/dev/null || :
    if [[ "$verdict" =~ ^rc\ ([0-9]{1,3})$ ]]; then
      rc="${BASH_REMATCH[1]}"
      echo "$ME: systemd-run stopped reporting after dnf5 finished, so its exit status ($rc) was read from systemd." >&2
    else
      rc=1
      echo "$ME: systemd-run stopped reporting after dnf5 finished, and systemd no longer has its result." >&2
    fi
    if [[ -n "$out_pid" ]]; then
      exec {pause}<> <(:)
      read -r -t "$POLL" -u "$pause" _ || :
      exec {pause}<&-
      stopped=1
    fi
  elif (( wd_live )); then
    kill -s TERM "$wd_pid" 2>/dev/null || :
    wait "$wd_pid" || :
  fi
  exec {wd}<&-
  if [[ -n "$out_pid" ]]; then
    if (( stopped )); then kill "$out_pid" "$err_pid" 2>/dev/null || :; fi
    wait "$out_pid" "$err_pid" || :
  fi
  return "$rc"
}
claim_unit() {
  local u
  for u in "$UNIT" "${UPDATE_UNITS[@]}"; do
    case "$("$SYSTEMCTL" show --no-pager -p ActiveState --value -- "$u" 2>/dev/null || :)" in
      active|activating|deactivating|reloading|refreshing)
        if [[ "$u" == "$UNIT" ]]; then
          echo "$ME: dnf5 was not started, because the one Kempt started earlier is still running. Nothing changed." >&2
        else
          echo "$ME: dnf5 was not started, because a Kempt update is running. Nothing changed." >&2
        fi
        exit "$BUSY" ;;
    esac
  done
  "$SYSTEMCTL" reset-failed --no-pager -- "$UNIT" 2>/dev/null || :
}
watch_unit() {
  local pause k v load active result code status inv mine="" seen=0 ended=0 polls=0 early=0
  exec {pause}<> <(:)
  while :; do
    if (( ! seen && early < FIRST_READS )); then
      early=$(( early + 1 ))
      read -r -t "$FIRST" -u "$pause" _ || :
    else
      read -r -t "$POLL" -u "$pause" _ || :
    fi
    load="" active="" result="" code="" status="" inv=""
    while IFS='=' read -r k v; do
      case "$k" in
        LoadState) load="$v" ;;
        ActiveState) active="$v" ;;
        Result) result="$v" ;;
        ExecMainCode) code="$v" ;;
        ExecMainStatus) status="$v" ;;
        InvocationID) inv="$v" ;;
      esac
    done < <("$SYSTEMCTL" show --no-pager -p LoadState,ActiveState,Result,ExecMainCode,ExecMainStatus,InvocationID -- "$UNIT" 2>/dev/null || :)
    [[ -n "$load" && -n "$active" ]] || continue
    case "$active" in
      active|activating|deactivating|reloading|refreshing)
        if [[ -z "$inv" ]]; then :
        elif (( ! seen )); then seen=1 mine="$inv"
        elif [[ "$inv" != "$mine" ]]; then echo unknown; return 0; fi
        ended=0 polls=$(( polls + 1 ))
        if (( polls == LONG_RUN )); then
          echo "$ME: dnf5 has been running for 15 minutes. Kempt will not interrupt it. Keep the computer on." >&2
        fi
        continue ;;
    esac
    (( seen )) || continue
    [[ -n "$inv" || "$load" == not-found ]] || continue
    ended=$(( ended + 1 ))
    (( ended >= GRACE )) || continue
    if [[ "$load" == not-found ]]; then echo "rc 0"
    elif [[ "$inv" != "$mine" ]]; then echo unknown
    elif [[ "$code" == 1 && "$status" =~ ^(0|[1-9][0-9]?|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$ ]]; then echo "rc $status"
    elif [[ "$code" == 2 || "$code" == 3 ]]; then echo "rc 255"
    elif [[ "$result" == success ]]; then echo "rc 0"
    else echo unknown; fi
    return 0
  done
}
EOF
)"
root_shape_violations() {  # helper file → one line per violation, then "read to the end"
  local code
  code="$(grep -vE '^[[:space:]]*#' "$1" | sed -E 's/[[:space:]]+#.*$//' | sed -e ':a' -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta')"
  local f vetted=""
  for f in run_watched claim_unit watch_unit; do
    vetted+="$(sed -n "/^$f() {\$/,/^}\$/p" <<<"$code")"$'\n'
    code="$(sed "/^$f() {\$/,/^}\$/d" <<<"$code")"
  done
  [[ "${vetted%$'\n'}" == "$VETTED" ]] \
    || echo "vetted function other than the vetted text: the pipes, cats, systemctl calls and signals are not the ones checked"
  local sdline='^[[:space:]]*run "\$SYSTEMD_RUN" (--pipe|"\$io") --wait --quiet --unit="\$UNIT" --expand-environment=no -p UMask=0022 -p LimitCORE=0 .*-- /usr/bin/dnf5 "\$@"$'
  grep -wE 'dnf5' <<<"$code" \
    | grep -vE -e "$sdline" -e "rpm -q --qf '%\{VERSION\}' dnf5 2>/dev/null" -e '^[[:space:]]*echo "(kempt-(apply|refresh)|\$ME): [^"]*" >&2$' \
    | sed 's/^/dnf5 outside systemd-run: /' || true
  local execs; execs="$(grep -wE 'exec' <<<"$code" || true)"
  [[ -z "$execs" ]] || printf 'exec outside the vetted functions: %s\n' "${execs//$'\n'/ | }"
  local runs; runs="$(grep -E '(^|[;&|)]|then|else|do)[[:space:]]*run[[:space:]]' <<<"$code" || true)"
  [[ "$(grep -c . <<<"$runs")" == 1 ]] && grep -qE "$sdline" <<<"$runs" \
    || printf 'run called other than on the systemd-run line: %s\n' "${runs//$'\n'/ | }"
  # (( a >= b )) compares; it cannot write. Nothing else with a > in it is let off.
  sed -E 's/\(\( [^()]* \)\)//g; s/[0-9]*>&[0-9]//g; s/[0-9]*>[[:space:]]*\/dev\/null//g; s/ -> / /g' <<<"$code" | grep -E '>' \
    | sed 's/^/writes a file: /' || true
  grep -E '(^|[^A-Za-z0-9_-])(touch|mkdir|cp|mv|rm|ln|install|chmod|chown|chgrp|truncate|dd|tee|mktemp|mkfifo|timeout|env|nohup|setsid|nice|systemctl|pkexec|sudo|runuser|flatpak)([[:space:]]|$)|sed -i|[^&>]&([^&>]|$)' <<<"$(sed -E 's/\(\( [^()]* \)\)//g' <<<"$code")" \
    | grep -vxE '[[:space:]]*SYSTEMCTL=/usr/bin/systemctl' | sed 's/^/writes or starts another command: /' || true
  # The unit name: UNIT is empty, or one literal per verb from the table, never built from input.
  grep -E '(^|[^A-Za-z0-9_])UNIT=' <<<"$code" \
    | grep -vxE '[[:space:]]*UNIT=""|[[:space:]]*([a-z-]+)\) UNIT=kempt-(apply|refresh)-\1\.service ;;' \
    | sed 's/^/unit name other than the fixed table: /' || true
  # The units whose run makes this helper busy: literal names from kempt-apply's table, never built.
  grep -E 'UPDATE_UNITS' <<<"$code" \
    | grep -vxE 'UPDATE_UNITS=\(( ?kempt-apply-dnf-(upgrade|offline-stage|offline-arm|offline-clean)\.service)*\)' \
    | sed 's/^/busy units other than the fixed list: /' || true
  # Allowlist, not denylist: every call of run_dnf5 hands systemd-run only literal unit settings
  # from a fixed list. A caller-chosen -p or --setenv is a root command (ExecStartPre=, LD_PRELOAD=).
  grep -oE '(^|[^A-Za-z0-9_])run_dnf5[[:space:]][^;]*' <<<"$code" | sed -E 's/^.*run_dnf5[[:space:]]+//' \
    | grep -vE '^((-p (RuntimeMaxSec|TimeoutStopSec)=[0-9]+|--setenv=DNF_SYSTEM_UPGRADE_NO_REBOOT=1) )*-- [^$]*(\$\{(offline|assume|excludes)\[@\]\}"?[^$]*)*$' \
    | sed 's/^/unit settings other than the fixed list: /' || true
  # Command position only: after a line start, ; & | ( { or a shell keyword. A variable as the command
  # ("$D" args) is caught too: root's commands are named, never looked up from a variable.
  grep -E '(^|[;&|({]|then|else|do)[[:space:]]*(eval|source|\.|rpm|kill|pkill|killall|bash|sh|/usr/bin/systemd-run|systemd-run|"\$[^"]*")([[:space:]]|$)' <(sed -E 's/\[\[[^]]*(\][^]][^]]*)*\]\]//g' <<<"$code") \
    | grep -vE -e "$sdline" -e "rpm -q --qf '%\{VERSION\}' dnf5 2>/dev/null" -e '^[[:space:]]*SYSTEMD_RUN=' -e '\$\("\$(FIND|GETFACL)" -' \
    | sed 's/^/runs code other than through systemd-run: /' || true
  # Those two read-only checks are the one exception, so their names are pinned: the fixed name, or
  # the seam inside the block that real root never enters.
  grep -E '(^|[^A-Za-z0-9_])(FIND|GETFACL)=' <<<"$code" \
    | grep -vxE 'FIND=find|GETFACL=getfacl|  FIND="\$\{KEMPT_FIND:-\$FIND\}"|  GETFACL="\$\{KEMPT_GETFACL:-\$GETFACL\}"' \
    | sed 's/^/check tool other than the fixed name: /' || true
  # The one choice the shell makes about systemd-run itself: a pty for a terminal, else pipes.
  grep -E '(^|[^A-Za-z0-9_])io=' <<<"$code" | grep -vxE '[[:space:]]*local io=--pipe|[[:space:]]*\[\[ -t 0 \]\] && io=--pty' \
    | sed 's/^/systemd-run mode other than pipe or pty: /' || true
  echo "read to the end"   # so a check that died partway can never pass as an empty answer
}
for h in "$RH" "$AH"; do
  assert_eq "$(root_shape_violations "$h")" "read to the end" "$(basename "$h"): dnf5 starts only through systemd-run, and the shell before it writes nothing"
done
# The check can fail. Each of these is one line a future edit could plausibly add.
mutant() { sed "$1" "$AH" > "$TESTTMP/mutant"; root_shape_violations "$TESTTMP/mutant"; }
assert_exit 0 "...it catches dnf5 run straight from the shell" -- \
  grep -q 'dnf5 outside systemd-run' <(mutant 's|^    run_dnf5 -- offline clean -y$|    run dnf5 offline clean -y|')
assert_exit 0 "...it catches an exec" -- \
  grep -q 'exec outside' <(mutant 's|^set -euo pipefail$|set -euo pipefail; exec 3>/dev/null|')
assert_exit 0 "...it catches a write before the exec" -- \
  grep -q 'writes a file' <(mutant 's|^set -euo pipefail$|set -euo pipefail; echo x > /var/tmp/x|')
assert_exit 0 "...it catches another command started as root" -- \
  grep -q 'starts another' <(mutant 's|^set -euo pipefail$|set -euo pipefail; mkdir -p /var/tmp/x|')
assert_exit 0 "...it catches the time limit going back to timeout" -- \
  grep -q 'starts another' <(sed 's|run_dnf5 -p RuntimeMaxSec=120 -p TimeoutStopSec=10 -- makecache --refresh|run /usr/bin/timeout -k 10 120 dnf5 makecache --refresh|' "$RH" \
    > "$TESTTMP/mutant-r"; root_shape_violations "$TESTTMP/mutant-r")

assert_exit 0 "...it catches a caller's argument forwarded as a unit property" -- \
  grep -q 'unit settings other than' <(mutant 's|^    run_dnf5 -- upgrade "\${offline\[@\]}"|    run_dnf5 "$@" -- upgrade "${offline[@]}"|')
assert_exit 0 "...it catches an ExecStartPre= smuggled in as a property" -- \
  grep -q 'unit settings other than' <(mutant 's|^    run_dnf5 -- offline clean -y$|    run_dnf5 -p ExecStartPre=/bin/true -- offline clean -y|')
# Any position, not only after ; & | or a keyword: a brace group or a subshell is a call too.
assert_exit 0 "...it catches a property smuggled in from a brace group" -- \
  grep -q 'unit settings other than' <(mutant 's|^    run_dnf5 -- offline clean -y$|    { run_dnf5 "$@" -- offline clean -y; }|')
assert_exit 0 "...it catches a property smuggled in from a subshell" -- \
  grep -q 'unit settings other than' <(mutant 's|^    run_dnf5 -- offline clean -y$|    ( run_dnf5 -p ExecStartPre=/bin/true -- offline clean -y )|')
assert_exit 0 "...it catches systemd-run called without run" -- \
  grep -q 'runs code other than' <(mutant 's|^set -euo pipefail$|set -euo pipefail; "$SYSTEMD_RUN" --wait -- /usr/bin/rpm -e foo 2>/dev/null|')
assert_exit 0 "...it catches eval" -- \
  grep -q 'runs code other than' <(mutant 's|^set -euo pipefail$|set -euo pipefail; eval "${X:-:}"|')
assert_exit 0 "...it catches a sourced file" -- \
  grep -q 'runs code other than' <(mutant 's|^set -euo pipefail$|set -euo pipefail; . /etc/kempt/root.conf 2>/dev/null|')
assert_exit 0 "...it catches rpm run straight from the shell" -- \
  grep -q 'runs code other than' <(mutant 's|^set -euo pipefail$|set -euo pipefail; rpm --rebuilddb 2>/dev/null|')

assert_exit 0 "...it catches run_watched handing systemd-run this shell's own stdout again" -- \
  grep -q 'vetted function other than' <(mutant 's|exec "\$@"; } </dev/null >&"\$out" 2>&"\$err"|exec "$@"; } </dev/null 2>\&"$err"|')
assert_exit 0 "...it catches a write smuggled into run_watched" -- \
  grep -q 'vetted function other than' <(mutant 's|^    out_pid=\$!$|    out_pid=$!; echo "$out_pid" > /run/x|')
assert_exit 0 "...and still catches a write anywhere else" -- \
  grep -q 'writes a file' <(mutant 's|^set -euo pipefail$|set -euo pipefail; exec {o}> /var/tmp/x|')
assert_exit 0 "...it catches the caller's argument in a unit name" -- \
  grep -q 'unit name other than' <(mutant 's|^  dnf-upgrade) UNIT=kempt-apply-dnf-upgrade.service ;;$|  dnf-upgrade) UNIT="kempt-apply-$1.service" ;;|')
assert_exit 0 "...it catches a systemctl stop smuggled into the watch" -- \
  grep -q 'vetted function other than' <(mutant 's|^    (( seen )) \|\| continue$|    (( seen )) \|\| "$SYSTEMCTL" stop -- "$UNIT"|')
assert_exit 0 "...it catches the watch's last resort aimed at something other than systemd-run" -- \
  grep -q 'vetted function other than' <(mutant 's|kill -s KILL "\$sd_pid"|kill -s KILL -1|')
assert_exit 0 "...it catches systemctl run outside the vetted functions" -- \
  grep -q 'starts another' <(mutant 's|^set -euo pipefail$|set -euo pipefail; systemctl stop kempt-apply-dnf-upgrade.service|')
rmutant() { sed "$1" "$RH" > "$TESTTMP/mutant-r"; root_shape_violations "$TESTTMP/mutant-r"; }
assert_exit 0 "...it catches the caller's argument in the busy units" -- \
  grep -q 'busy units other than' <(rmutant 's|^UPDATE_UNITS=(kempt-apply-dnf-upgrade.service |UPDATE_UNITS=("$1" kempt-apply-dnf-upgrade.service |')
assert_exit 0 "...it catches a unit added to the busy units later" -- \
  grep -q 'busy units other than' <(rmutant 's|^set -euo pipefail$|set -euo pipefail; UPDATE_UNITS+=(sshd.service)|')
assert_exit 0 "...it catches a unit that is not Kempt's in the busy units" -- \
  grep -q 'busy units other than' <(rmutant 's|kempt-apply-dnf-offline-clean.service)$|kempt-apply-dnf-offline-clean.service sshd.service)|')
# The busy units in kempt-refresh are exactly the units in kempt-apply's table, and kempt-apply has none.
assert_eq "$(grep -E '^UPDATE_UNITS=' "$RH" | tr -d '()' | sed 's/^UPDATE_UNITS=//' | tr ' ' '\n' | sort)" \
  "$(grep -oE 'UNIT=kempt-apply-[a-z-]+\.service' "$AH" | sed 's/^UNIT=//' | sort)" \
  "kempt-refresh's busy units are kempt-apply's four units, word for word"
assert_eq "$(grep -E '^UPDATE_UNITS=' "$AH")" "UPDATE_UNITS=()" "kempt-apply waits on no other unit"
for h in "$RH" "$AH"; do
  for f in run_watched claim_unit watch_unit; do
    assert_eq "$(sed -n "/^$f() {/,/^}/p" "$h" | grep -vE '^[[:space:]]*#')" \
      "$(sed -n "/^$f() {/,/^}/p" "$AH" | grep -vE '^[[:space:]]*#')" "$(basename "$h"): $f is the same in both helpers"
  done
done

# A terminal on stdin gets --pty, so Ctrl-C reaches dnf5 instead of detaching it (see run_dnf5).
if command -v python3 >/dev/null; then
  # shellcheck disable=SC2016
  pty_out="$(env KEMPT_APPLY_ECHO=1 KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" \
    python3 -c 'import pty,sys; pty.spawn(sys.argv[1:])' bash "$AH" dnf-offline-clean | tr -d '\r')"
  assert_eq "$pty_out" "$(sd '' offline clean -y | sed 's/ --pipe / --pty /')" "kempt-apply: a terminal on stdin gets --pty, with the same properties"
else
  skip "pty selection test - needs python3"
fi

# What systemd-run is handed, one argument per line, from the stand-in tests/lib.sh writes. No ECHO
# here: the helper really runs it.
# shellcheck disable=SC2086 # SD_BASE and the properties are split into words on purpose
want_argv() { local props="$1"; shift; printf '%s\n' ${SD_BASE/@UNIT@/$(unit_for "$@")} $props -- /usr/bin/dnf5 "$@"; }
SDARGV="$TESTTMP/systemd-run.argv"
assert_exit 0 "refresh check runs systemd-run" -- env KEMPT_DNF5_VERSION=5.2.18.0 bash "$RH" check
assert_eq "$(cat "$SDARGV")" "$(want_argv '' --cacheonly check-update --quiet)" "...with the fixed properties, then -- and dnf5's arguments"
assert_exit 0 "refresh check on dnf5 5.4 runs systemd-run" -- env KEMPT_DNF5_VERSION=5.4.0 bash "$RH" check
assert_eq "$(cat "$SDARGV")" "$(want_argv '' --cacheonly check-update --quiet --json)" "...asking for JSON"
assert_exit 0 "refresh runs systemd-run" -- bash "$RH" refresh
assert_eq "$(cat "$SDARGV")" "$(want_argv '-p RuntimeMaxSec=120 -p TimeoutStopSec=10' makecache --refresh)" "...bounded by the unit, not by timeout"
assert_exit 0 "dnf-upgrade runs systemd-run" -- bash "$AH" dnf-upgrade -y --exclude=vim-common --exclude=kernel-core
assert_eq "$(cat "$SDARGV")" "$(want_argv '' upgrade -y --exclude=vim-common --exclude=kernel-core)" "...every exclude after the --, where systemd-run cannot read it as an option"
for v in dnf-offline-stage dnf-offline-arm dnf-offline-clean; do
  rm -f "$SDARGV"
  # shellcheck disable=SC2046
  assert_exit 0 "$v runs systemd-run" -- env KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" bash "$AH" "$v" $(offline_args "$v")
  case "$v" in
    dnf-offline-stage) want="$(want_argv '' upgrade --offline -y)" ;;
    dnf-offline-arm)   want="$(want_argv --setenv=DNF_SYSTEM_UPGRADE_NO_REBOOT=1 offline reboot -y)" ;;
    *)                 want="$(want_argv '' offline clean -y)" ;;
  esac
  assert_eq "$(cat "$SDARGV")" "$want" "...$v hands it exactly this"
done
# In pipe mode systemd-run is the shell's child (run_watched), and the shell's exit status is
# systemd-run's, which is dnf5's.
# shellcheck disable=SC2016 # expanded by the inner bash
bash -c 'echo "$$" > "$2"; exec bash "$1" refresh' _ "$RH" "$TESTTMP/helper.pid"
assert_eq "$(cat "/proc/$(cat "$TESTTMP/helper.pid")/stat" 2>/dev/null || echo gone)" "gone" "the helper is gone once systemd-run has finished"
assert_exit 100 "dnf5's 100 from check-update comes back through the helper" -- env KEMPT_TEST_SDRUN_RC=100 bash "$RH" check
assert_exit 1 "...and a failed refresh's 1" -- env KEMPT_TEST_SDRUN_RC=1 bash "$RH" refresh
assert_exit 1 "...and a failed upgrade's 1" -- env KEMPT_TEST_SDRUN_RC=1 bash "$AH" dnf-upgrade -y
assert_exit 255 "...and systemd-run's own 255 for a dnf5 killed by a signal" -- env KEMPT_TEST_SDRUN_RC=255 bash "$AH" dnf-offline-clean

# --- pipe mode never hands systemd-run this shell's own stdin, stdout or stderr ---------------------
# --pipe passes systemd-run's fds to PID 1. Under SELinux PID 1 (init_t) may not write the caller's
# files, such as a mktemp file in /tmp (user_tmp_t), so systemd-run failed and dnf5 never ran. No
# SELinux here, so this stand-in reports what its fds are: /dev/null and two pipes, even when the
# helper's own stdin, stdout and stderr are regular files. It also checks that each stream still
# arrives whole and apart from the other, and that the exit status comes back.
FDSD="$TESTTMP/fd-systemd-run"; FDREP="$TESTTMP/fd-report"
cat > "$FDSD" <<'EOF'
#!/usr/bin/env bash
r="$KEMPT_TEST_FD_REPORT"
fds="$(for n in 0 1 2; do echo "fd$n $(readlink "/proc/$$/fd/$n" 2>&1)"; done 2>/dev/null)"
{ echo "$fds"; echo "parent $(tr '\0' ' ' < "/proc/$PPID/cmdline")"; grep '^SigIgn' "/proc/$$/status"; } > "$r"
echo "to stdout"; echo "to stderr" >&2
[[ -z "${KEMPT_TEST_FD_LINES:-}" ]] || { seq "$KEMPT_TEST_FD_LINES"; seq "$KEMPT_TEST_FD_LINES" >&2; }
if [[ -n "${KEMPT_TEST_FD_HANG:-}" ]]; then
  # Like dnf5 in its unit: something else still holds the pipes after systemd-run is gone.
  trap 'echo "got TERM" >> "$r"; exit 143' TERM
  trap 'echo "got INT" >> "$r"; exit 130' INT
  sleep 4 & echo ready >> "$r"; wait
fi
exit "${KEMPT_TEST_SDRUN_RC:-0}"
EOF
chmod +x "$FDSD"
echo "stdin of the caller" > "$TESTTMP/fd-stdin"
for h in "$RH" "$AH"; do
  verb=dnf-upgrade; [[ "$h" == "$RH" ]] && verb=check
  rc=0
  env KEMPT_SYSTEMD_RUN="$FDSD" KEMPT_TEST_FD_REPORT="$FDREP" KEMPT_TEST_SDRUN_RC=100 bash "$h" "$verb" \
    <"$TESTTMP/fd-stdin" >"$TESTTMP/fd-out" 2>"$TESTTMP/fd-err" || rc=$?
  n="$(basename "$h")"
  assert_eq "$(grep '^fd0 ' "$FDREP")" "fd0 /dev/null" "$n: in pipe mode systemd-run's stdin is /dev/null, not the caller's"
  assert_contains "$(grep '^fd1 ' "$FDREP")" "fd1 pipe:" "$n: ...its stdout is a pipe of the helper's, not the caller's file"
  assert_contains "$(grep '^fd2 ' "$FDREP")" "fd2 pipe:" "$n: ...and so is its stderr"
  assert_contains "$(grep '^parent ' "$FDREP")" "$h" "$n: ...started as the helper's own child"
  assert_eq "$(cat "$TESTTMP/fd-out")" "to stdout" "$n: ...and what it writes to stdout lands in the caller's stdout"
  assert_eq "$(cat "$TESTTMP/fd-err")" "to stderr" "$n: ...and stderr in the caller's stderr, kept apart"
  assert_eq "$rc" 100 "$n: ...with systemd-run's exit status"
  rc=0
  env KEMPT_SYSTEMD_RUN="$FDSD" KEMPT_TEST_FD_REPORT="$FDREP" KEMPT_TEST_FD_LINES=200000 bash "$h" "$verb" \
    >"$TESTTMP/fd-out" 2>"$TESTTMP/fd-err" || rc=$?
  assert_eq "$rc $(wc -l < "$TESTTMP/fd-out") $(tail -n1 "$TESTTMP/fd-out") $(wc -l < "$TESTTMP/fd-err") $(tail -n1 "$TESTTMP/fd-err")" \
    "0 200001 200000 200001 200000" "$n: a long output arrives whole on both streams before the helper exits"
done

# A TERM or INT to the helper reaches systemd-run, as it did when the helper exec'd it, and nothing
# the helper started outlives it, even while something else still holds the pipes. env
# --default-signal undoes the INT that a background job of this script would start out ignoring.
helper_kids() { cat "/proc/$1/task/$1/children" 2>/dev/null; }
if [[ -r /proc/self/task/$$/children ]] && env --default-signal=INT true 2>/dev/null; then
  for sig in TERM INT; do
    want=143; [[ $sig == INT ]] && want=130
    rm -f "$FDREP"
    env --default-signal=INT KEMPT_SYSTEMD_RUN="$FDSD" KEMPT_TEST_FD_REPORT="$FDREP" KEMPT_TEST_FD_HANG=1 \
      bash "$AH" dnf-upgrade -y >"$TESTTMP/fd-out" 2>"$TESTTMP/fd-err" &
    hp=$!
    for _ in $(seq 100); do grep -q '^ready$' "$FDREP" 2>/dev/null && break; sleep 0.05; done
    kids="$(helper_kids "$hp")"
    t0=$SECONDS
    kill -s "$sig" "$hp"
    rc=0; wait "$hp" || rc=$?
    assert_eq "$rc" "$want" "a $sig to the helper comes back as systemd-run's own status for it"
    assert_contains "$(cat "$FDREP")" "got $sig" "...because systemd-run got the $sig"
    assert_eq "$(( SECONDS - t0 < 3 ))" 1 "...and the helper did not wait for what still holds the pipes"
    left=""; for k in $kids; do [[ -e "/proc/$k" ]] && left+=" $k:$(cat "/proc/$k/comm" 2>/dev/null)"; done
    assert_eq "$(wc -w <<<"$kids") ${left:-none}" "4 none" "...and none of its four children (two cats, systemd-run, the watch on its unit) is left"
  done
else
  skip "helper signal test - needs /proc/PID/task/PID/children and env --default-signal"
fi

# A terminal on stdin goes to systemd-run itself, though it now runs as a child: a background
# command would otherwise get /dev/null, and dnf5's prompt could not read the answer.
if command -v python3 >/dev/null; then
  rm -f "$FDREP"
  env KEMPT_SYSTEMD_RUN="$FDSD" KEMPT_TEST_FD_REPORT="$FDREP" \
    python3 -c 'import pty,sys; pty.spawn(sys.argv[1:])' bash "$AH" dnf-offline-clean >/dev/null 2>&1 || true
  assert_contains "$(grep '^fd0 ' "$FDREP" 2>/dev/null)" "fd0 /dev/pts/" "with a terminal, systemd-run reads the terminal"
else
  skip "pty stdin test - needs python3"
fi

# --- systemd-run that stops reporting --------------------------------------------------------------
# systemd-run --wait learns that dnf5 finished from PID 1. When PID 1 drops its API bus connection
# (a package's setup step can make it do that), systemd-run keeps waiting with nothing left to tell
# it. So the helper asks systemctl about its own unit every few seconds. Once the unit has been seen
# running and then has ended while systemd-run still waits, the helper stops systemd-run (only the
# client), takes dnf5's result from systemd and says so. A unit that is still running is never
# stopped, however long it takes. The stand-in systemd-run below never returns on its own.
HANGSD="$TESTTMP/hang-systemd-run"; HANGREP="$TESTTMP/hang-report"
cat > "$HANGSD" <<'EOF'
#!/usr/bin/env bash
echo "$$" > "$KEMPT_TEST_HANG_REPORT.pid"
echo "dnf5 output"
echo ">>> Running %post scriptlet: demo-1.0"
sleep 60 & s=$!
trap 'kill "$s" 2>/dev/null; echo "got TERM" >> "$KEMPT_TEST_HANG_REPORT"; exit 143' TERM
wait
EOF
chmod +x "$HANGSD"
SDCALLS="$TESTTMP/systemd.calls"; SDSTATES="$TESTTMP/systemctl.states"
hang_run() {  # states... → runs dnf-upgrade over them; HRC, HOUT, HERR, HSECS
  rm -f "$HANGREP" "$HANGREP.pid" "$SDCALLS"
  printf '%s\n' "$@" > "$SDSTATES"
  local t0=$SECONDS
  HRC=0
  env KEMPT_SYSTEMD_RUN="$HANGSD" KEMPT_TEST_HANG_REPORT="$HANGREP" KEMPT_SYSTEMD_POLL=0.05 KEMPT_SYSTEMD_GRACE=2 \
    timeout 30 bash "$AH" dnf-upgrade -y >"$TESTTMP/hang-out" 2>"$TESTTMP/hang-err" || HRC=$?
  HSECS=$(( SECONDS - t0 )); HOUT="$(cat "$TESTTMP/hang-out")"; HERR="$(cat "$TESTTMP/hang-err")"
}
hang_run "loaded active 0 0 inv1" "loaded active 0 0 inv1" "not-found inactive 0 0 -"
assert_eq "$HRC" 0 "systemd-run never returns, the unit ran and is gone: the helper exits 0, dnf5's success"
assert_contains "$HERR" "so its exit status (0) was read from systemd" "...and says where the result came from"
assert_contains "$(cat "$HANGREP" 2>/dev/null)" "got TERM" "...after stopping systemd-run, the client"
assert_contains "$HOUT" "dnf5 output" "...with dnf5's output copied through"
assert_eq "$(( HSECS < 15 ))" 1 "...within seconds"
assert_eq "$(grep -cvE '^(systemctl (show|reset-failed) .*kempt-apply-dnf-upgrade\.service)$' "$SDCALLS")" 0 \
  "...and systemctl was only asked about its own unit, never told to stop anything"

hang_run "loaded active 0 0 inv1" "loaded failed 1 1 inv1 exit-code"
assert_eq "$HRC" 1 "the unit failed with dnf5's exit status 1: the helper exits 1"
assert_contains "$HERR" "so its exit status (1) was read from systemd" "...read from systemd"
hang_run "loaded active 0 0 inv1" "loaded failed 1 100 inv1 exit-code"
assert_eq "$HRC" 100 "...and any other exit status as it is"
hang_run "loaded active 0 0 inv1" "loaded failed 2 9 inv1 signal"
assert_eq "$HRC" 255 "dnf5 killed by a signal: 255, as systemd-run reports it"
hang_run "loaded active 0 0 inv1" "loaded active 0 0 inv2"
assert_eq "$HRC" 1 "another run under the same name: this run's result is gone, so the helper exits 1"
assert_contains "$HERR" "systemd no longer has its result" "...and says it could not read it"
hang_run "loaded active 0 0 inv1" "loaded inactive 0 0 inv2"
assert_eq "$HRC" 1 "...the same when the unit systemd shows is another run that has ended too"
# systemd can answer with no InvocationID while it re-executes itself. A read like that names no
# run, so it is never taken as this run's, nor as another one.
hang_run "loaded active 0 0 -" "loaded active 0 0 inv1" "loaded active 0 0 inv1" "not-found inactive 0 0 -"
assert_eq "$HRC" 0 "a first read with no InvocationID is not this run's: the run is still judged by its own"
hang_run "loaded active 0 0 inv1" "loaded active 0 0 -" "loaded active 0 0 inv1" "not-found inactive 0 0 -"
assert_eq "$HRC" 0 "...and a later one is not another run's"
# ...nor an ended read: it is not counted towards the verdict, so it cannot turn this run's recorded
# result into "systemd no longer has it". A unit that is gone (not-found) has no InvocationID and
# still counts, or a successful run would never be judged.
hang_run "loaded active 0 0 inv1" "loaded inactive 0 0 -" "loaded inactive 0 0 -" "loaded failed 1 100 inv1 exit-code"
assert_eq "$HRC" 100 "an ended read with no InvocationID is skipped: the run's own result (100) is read once systemd names it"
assert_contains "$HERR" "so its exit status (100) was read from systemd" "...and the helper says it read it from systemd"

# A unit that ends a couple of seconds after it starts, before the first read at the usual interval,
# must still be seen running: the watch reads every second at first. And a systemd-run that ignores
# the TERM after the verdict is killed a poll interval later, the client only, so the helper returns.
# KEMPT_SYSTEMD_POLL=3 puts the usual first read after the unit has gone.
QUICKSC="$TESTTMP/quick-systemctl"; QUICKSD="$TESTTMP/quick-systemd-run"
cat > "$QUICKSC" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$TESTTMP/systemd.calls"
[[ "\$1" == show ]] || exit 0
[[ " \$* " == *" --value "* ]] && { echo inactive; exit 0; }
t0="\$(cat "$TESTTMP/quick.start" 2>/dev/null || echo 0)"
if (( \$(date +%s%N) - t0 < 2000000000 )); then
  printf 'LoadState=loaded\nActiveState=active\nResult=success\nExecMainCode=0\nExecMainStatus=0\nInvocationID=inv1\n'
else
  printf 'LoadState=not-found\nActiveState=inactive\nResult=success\nExecMainCode=0\nExecMainStatus=0\nInvocationID=\n'
fi
EOF
cat > "$QUICKSD" <<EOF
#!/usr/bin/env bash
date +%s%N > "$TESTTMP/quick.start"
echo "\$\$" > "$TESTTMP/quick.pid"
trap '' TERM
sleep 60 >/dev/null 2>&1 </dev/null & echo "\$!" > "$TESTTMP/quick.sleep"
wait
EOF
chmod +x "$QUICKSC" "$QUICKSD"
rm -f "$SDCALLS" "$TESTTMP/quick.start"
t0=$SECONDS; HRC=0
env KEMPT_SYSTEMD_RUN="$QUICKSD" KEMPT_SYSTEMD_SYSTEMCTL="$QUICKSC" KEMPT_SYSTEMD_POLL=3 \
  timeout 40 bash "$AH" dnf-upgrade -y >"$TESTTMP/hang-out" 2>"$TESTTMP/hang-err" || HRC=$?
HSECS=$(( SECONDS - t0 ))
assert_eq "$HRC" 0 "a unit that ends 2 s in, with systemd-run hung: judged from systemd, and the helper exits 0"
assert_eq "$(( HSECS < 25 ))" 1 "...returning on its own"
assert_exit 1 "...after killing the systemd-run that ignored TERM" -- kill -0 "$(cat "$TESTTMP/quick.pid" 2>/dev/null || echo 0)"
assert_eq "$(grep -cvE '^(systemctl (show|reset-failed) .*kempt-apply-dnf-upgrade\.service)$' "$SDCALLS")" 0 \
  "...and systemctl was never told to stop or kill anything"
kill -s KILL "$(cat "$TESTTMP/quick.sleep" 2>/dev/null || echo 0)" 2>/dev/null || true   # it ignores TERM, as its parent did

# Still running: the helper waits as long as it takes, says once after the long-run mark that it
# will not interrupt, and stops nothing. A unit never seen running is not judged either, since
# systemd-run may still be starting it. A TERM to the helper ends each case, as a closed terminal does.
for case in "loaded active 0 0 inv1|still running" "not-found inactive 0 0 -|never seen running"; do
  rm -f "$HANGREP" "$HANGREP.pid" "$SDCALLS"
  printf '%s\n' "${case%%|*}" > "$SDSTATES"
  env KEMPT_SYSTEMD_RUN="$HANGSD" KEMPT_TEST_HANG_REPORT="$HANGREP" KEMPT_SYSTEMD_POLL=0.05 KEMPT_SYSTEMD_GRACE=2 \
    KEMPT_SYSTEMD_LONG_RUN=3 bash "$AH" dnf-upgrade -y >"$TESTTMP/hang-out" 2>"$TESTTMP/hang-err" &
  hp=$!
  for _ in $(seq 100); do [[ "$(grep -c 'show --no-pager -p' "$SDCALLS" 2>/dev/null)" -ge 12 ]] && break; sleep 0.05; done
  assert_eq "$(( $(grep -c 'show --no-pager -p' "$SDCALLS" 2>/dev/null || echo 0) >= 12 ))" 1 \
    "${case#*|}: premise: the helper kept asking about its unit"
  assert_exit 0 "${case#*|}: systemd-run is still waiting, untouched" -- kill -0 "$(cat "$HANGREP.pid" 2>/dev/null || echo 0)"
  assert_eq "$(cat "$HANGREP" 2>/dev/null)" "" "${case#*|}: ...and was sent nothing"
  kill -s TERM "$hp"; wait "$hp" || true
  assert_eq "$(grep -cvE '^(systemctl (show|reset-failed) .*kempt-apply-dnf-upgrade\.service|systemd-run)$' "$SDCALLS")" 0 \
    "${case#*|}: ...and systemctl was never told to stop or kill anything"
done
assert_eq "$(grep -c 'dnf5 has been running for 15 minutes. Kempt will not interrupt it' "$TESTTMP/hang-err")" 0 \
  "never seen running: no long-run line"
printf '%s\n' "loaded active 0 0 inv1" > "$SDSTATES"; rm -f "$HANGREP" "$HANGREP.pid" "$SDCALLS"
env KEMPT_SYSTEMD_RUN="$HANGSD" KEMPT_TEST_HANG_REPORT="$HANGREP" KEMPT_SYSTEMD_POLL=0.05 KEMPT_SYSTEMD_LONG_RUN=3 \
  bash "$AH" dnf-upgrade -y >"$TESTTMP/hang-out" 2>"$TESTTMP/hang-err" &
hp=$!
for _ in $(seq 100); do [[ "$(grep -c 'show --no-pager -p' "$SDCALLS" 2>/dev/null)" -ge 12 ]] && break; sleep 0.05; done
kill -s TERM "$hp"; wait "$hp" || true
assert_eq "$(grep -c 'dnf5 has been running for 15 minutes. Kempt will not interrupt it. Keep the computer on.' "$TESTTMP/hang-err")" 1 \
  "a unit still running past the long-run mark: the run log says once that Kempt will not interrupt it"

# One run at a time per verb: a unit already running under the fixed name refuses the second run,
# which starts nothing and resets nothing. Otherwise reset-failed comes first, so a failed unit
# left by an earlier run cannot block the name, and then systemd-run.
rm -f "$SDCALLS"; echo active > "$TESTTMP/systemctl.claim"
assert_exit 5 "a run whose unit is still active refuses a second one, with exit 5" -- bash "$AH" dnf-upgrade -y
assert_contains "$(cat "$TESTTMP/last_output")" "kempt-apply: dnf5 was not started, because the one Kempt started earlier is still running. Nothing changed." "...and says why"
assert_eq "$(grep -cE 'systemd-run|reset-failed' "$SDCALLS")" 0 "...starting nothing and resetting nothing"
echo activating > "$TESTTMP/systemctl.claim"
assert_exit 5 "...the same while it is starting" -- bash "$RH" refresh
rm -f "$TESTTMP/systemctl.claim" "$SDSTATES"
# The refresh helper also refuses while any kempt-apply unit runs, whoever started it (another user,
# the widget): a check or refresh would only wait on dnf5's lock until that update ends. It asks
# about the four fixed names, starts nothing and resets nothing. kempt-apply asks about no other unit.
for u in kempt-apply-dnf-upgrade.service kempt-apply-dnf-offline-stage.service \
         kempt-apply-dnf-offline-arm.service kempt-apply-dnf-offline-clean.service; do
  for v in check refresh; do
    rm -f "$SDCALLS" "$TESTTMP"/systemctl.claim.*; echo active > "$TESTTMP/systemctl.claim.$u"
    assert_exit 5 "refresh $v while $u is active: exit 5" -- bash "$RH" "$v"
    assert_eq "$(cat "$TESTTMP/last_output")" \
      "kempt-refresh: dnf5 was not started, because a Kempt update is running. Nothing changed." "...and says a Kempt update is running"
    assert_eq "$(grep -cE 'systemd-run|reset-failed' "$SDCALLS")" 0 "...starting nothing and resetting nothing"
  done
done
rm -f "$SDCALLS"; echo deactivating > "$TESTTMP/systemctl.claim.kempt-apply-dnf-offline-arm.service"
assert_exit 5 "...the same while an update unit is stopping" -- bash "$RH" check
rm -f "$TESTTMP"/systemctl.claim.*
rm -f "$SDCALLS"; echo active > "$TESTTMP/systemctl.claim.kempt-refresh-check.service"
env KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" bash "$AH" dnf-offline-clean >/dev/null 2>&1 || true
assert_eq "$(grep -c 'kempt-refresh' "$SDCALLS")" 0 "kempt-apply never asks about the refresh helper's units"
rm -f "$TESTTMP"/systemctl.claim.*
for v in dnf-upgrade dnf-offline-stage dnf-offline-arm dnf-offline-clean check refresh; do
  rm -f "$SDCALLS"
  h="$AH"; case "$v" in check|refresh) h="$RH" ;; esac
  u="kempt-apply-$v.service"; case "$v" in check|refresh) u="kempt-refresh-$v.service" ;; esac
  # shellcheck disable=SC2046
  env KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" bash "$h" "$v" $(offline_args "$v") >/dev/null 2>&1 || true
  busy=""
  case "$v" in check|refresh)
    for b in kempt-apply-dnf-upgrade.service kempt-apply-dnf-offline-stage.service \
             kempt-apply-dnf-offline-arm.service kempt-apply-dnf-offline-clean.service; do
      busy+="systemctl show --no-pager -p ActiveState --value -- $b"$'\n'
    done ;;
  esac
  assert_eq "$(grep -v 'show --no-pager -p LoadState' "$SDCALLS")" \
    "$(printf 'systemctl show --no-pager -p ActiveState --value -- %s\n%ssystemctl reset-failed --no-pager -- %s\nsystemd-run' "$u" "$busy" "$u")" \
    "$v: asks whether $u${busy:+ and the four update units} is running, resets it, then starts systemd-run"
done

# The new settings, like the old ones, are read only inside the helpers' not-root block.
for h in "$RH" "$AH"; do
  assert_eq "$(awk '/^if (\[\[ \$EUID -ne 0 \]\]|\(\( SEAMS \)\)); then$/ { inb = 1; next } inb && /^fi$/ { inb = 0; next }
                    !inb && /KEMPT_SYSTEMD_/ && !/^[[:space:]]*#/' "$h")" "" \
    "$(basename "$h"): every KEMPT_SYSTEMD_ setting is honoured only when not root"
  assert_eq "$(awk '/^if (\[\[ \$EUID -ne 0 \]\]|\(\( SEAMS \)\)); then$/ { inb = 1; next } inb && /^fi$/ { inb = 0; next }
                    !inb && /(^|[^A-Za-z_])(POLL|FIRST|FIRST_READS|GRACE|LONG_RUN)=/' "$h")" \
    "$(printf 'POLL=5\nFIRST=1\nFIRST_READS=10\nGRACE=2\nLONG_RUN=180')" \
    "$(basename "$h"): as root the watch's timing is the fixed one"
done

# Fail closed. Without systemd as PID 1 (a container, say) or without systemd-run, nothing runs and
# the helper exits 4, apart from 2 (bad arguments), 3 (refused) and dnf5's own statuses. It never
# runs dnf5 from its own shell instead. ECHO is set on purpose: the seam cannot hide the refusal.
nosd_line() { printf '%s: dnf5 was not started, because systemd is not running this system (as in a container) or systemd-run is missing. Nothing changed.\n' "$1"; }
: > "$TESTTMP/not-executable"
for h in "$RH" "$AH"; do
  verb=dnf-upgrade; [[ "$h" == "$RH" ]] && verb=refresh
  for case in "KEMPT_SYSTEMD_RUN=$TESTTMP/no-such-systemd-run" "KEMPT_SYSTEMD_RUN=$TESTTMP/not-executable" \
              "KEMPT_SYSTEMD_BOOTED=$TESTTMP/no-such-dir"; do
    rm -f "$SDARGV"
    assert_exit 4 "$(basename "$h") $verb exits 4 with ${case%%=*} at ${case##*/}" -- env "$case" KEMPT_APPLY_ECHO=1 KEMPT_REFRESH_ECHO=1 bash "$h" "$verb"
    assert_eq "$(cat "$TESTTMP/last_output")" "$(nosd_line "$(basename "$h")")" "...says why"
    assert_exit 1 "...and started nothing" -- test -e "$SDARGV"
  done
done
assert_exit 2 "a bad argument is still exit 2 without systemd" -- env KEMPT_SYSTEMD_BOOTED="$TESTTMP/no-such-dir" bash "$AH" dnf-upgrade --installroot=/
assert_exit 2 "...for the refresh helper too" -- env KEMPT_SYSTEMD_BOOTED="$TESTTMP/no-such-dir" bash "$RH" check extra
: > "$TESTTMP/ostree-booted"
assert_exit "$REFUSED_RC" "an atomic system is still refused with exit 3 without systemd" -- \
  env KEMPT_SYSTEMD_BOOTED="$TESTTMP/no-such-dir" KEMPT_OSTREE_MARKER="$TESTTMP/ostree-booted" bash "$AH" dnf-offline-clean
assert_exit 4 "the folder checks and everything after them hear about systemd first" -- \
  env KEMPT_SYSTEMD_BOOTED="$TESTTMP/no-such-dir" KEMPT_OFFLINE_TOML="$FIXTURES/offline-release-upgrade.toml" bash "$AH" dnf-offline-clean

# The LC_ALL=C.UTF-8 pin precedes validation on purpose: under a UTF-8 locale glibc widens
# [A-Za-z] to accented letters, so a caller's locale must not be able to widen what the ROOT
# helper accepts. ECHO is set as a second guard: if the pin ever regressed, this asserts loudly
# instead of reaching a real dnf5. Probe first - on a box without en_US.UTF-8 the range does not
# widen and the assertion would pass for the wrong reason.
if LC_ALL=en_US.UTF-8 bash -c '[[ "é" =~ ^[A-Za-z]$ ]]' 2>/dev/null; then
  assert_exit 2 "apply: caller locale cannot widen the name pattern" \
    env LC_ALL=en_US.UTF-8 KEMPT_APPLY_ECHO=1 bash "$AH" dnf-upgrade '--exclude=évil'
else
  skip "locale probe - en_US.UTF-8 is not installed on this box"
fi

# Root-helper hardening: absolute interpreter in privileged mode + pinned, EXPORTED PATH. Exported
# matters: without it, children spawned under a cleared environment fall back to a default that puts
# /usr/local/bin first - for RPM scriptlets running as root, that is a writable-by-admin dir ahead of
# /usr/bin.
for h in "$RH" "$AH"; do
  head -1 "$h" | grep -qx '#!/usr/bin/bash -p' && echo "ok: absolute shebang in privileged mode ($(basename "$h"))" \
    || { echo "FAIL: shebang ($(basename "$h"))"; _fail=1; }
  grep -qx 'export PATH=/usr/sbin:/usr/bin:/sbin:/bin' "$h" && echo "ok: exported pinned PATH ($(basename "$h"))" \
    || { echo "FAIL: PATH ($(basename "$h"))"; _fail=1; }
done
# ...and -p is what the shebang is for: bash in privileged mode never reads BASH_ENV, so a caller
# that skipped pkexec's scrubbed environment still cannot run code before a helper's first line.
# Each helper is executed DIRECTLY, because only a direct exec reads the shebang; every other test
# here runs `bash "$h"`, which ignores it. ECHO is set, so an accepted verb prints and runs nothing.
printf 'touch "%s"\n' "$TESTTMP/bash-env-ran" > "$TESTTMP/bash-env.sh"
if [[ -x /usr/bin/bash && -x "$AH" && -x "$RH" ]]; then
  env BASH_ENV="$TESTTMP/bash-env.sh" KEMPT_APPLY_ECHO=1 "$AH" dnf-offline-clean >/dev/null 2>&1 || true
  env BASH_ENV="$TESTTMP/bash-env.sh" KEMPT_REFRESH_ECHO=1 "$RH" check >/dev/null 2>&1 || true
  assert_exit 1 "neither helper reads BASH_ENV when executed directly" -- test -e "$TESTTMP/bash-env-ran"
  # The control: a plain non-interactive bash does read the same file, so the probe above can fail.
  env BASH_ENV="$TESTTMP/bash-env.sh" bash -c true
  assert_exit 0 "...while a plain bash does read it, so that assertion can fail" -- test -e "$TESTTMP/bash-env-ran"
else
  skip "BASH_ENV probe - /usr/bin/bash or an executable helper is missing"
fi

# No flatpak command may survive in root-owned code. The verb rejection above proves the case is
# gone; this proves nothing privileged still shells out to flatpak by another name.
# BOTH helpers, like the shebang and PATH loop above it: the claim is about root-owned code, and
# kempt-refresh is root-owned code. Checking only kempt-apply would have left the other half of
# the sentence unverified for the sake of one word.
# Comment lines are stripped first, exactly as render_passwordless_rule's self-check does it: the
# apply helper's header comment SAYS the word flatpak (to explain why the verb left), and a check
# that read comments would call that a violation.
for h in "$RH" "$AH"; do
  grep -v '^[[:space:]]*#' "$h" | grep -qi 'flatpak' \
    && { echo "FAIL: a flatpak command is back inside $(basename "$h")"; _fail=1; } \
    || echo "ok: $(basename "$h") runs no flatpak command at all"
done
# The --system scope contract moved with it: all four flatpak commands are built in
# backends/flatpak.sh now, and tests/test_flatpak.sh asserts their scope on the live variables.
finish
