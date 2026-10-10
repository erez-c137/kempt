#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
RH="$REPO_ROOT/libexec/kempt-refresh"
AH="$REPO_ROOT/libexec/kempt-apply"
# What every dnf5 command is wrapped in: systemd starts it as a fresh service with these properties
# and this environment, and every dnf5 argument comes after `--`. sd [properties] dnf5-args... prints
# the command line the ECHO seams print. KEMPT_SYSTEMD_RUN is the stand-in tests/lib.sh writes.
SD_BASE="--pipe --wait --quiet --collect -p UMask=0022 -p LimitCORE=0 --setenv=PATH=/usr/sbin:/usr/bin:/sbin:/bin --setenv=LC_ALL=C.UTF-8"
sd() { local props="$1"; shift; echo "$KEMPT_SYSTEMD_RUN $SD_BASE${props:+ $props} -- /usr/bin/dnf5 $*"; }

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
# ...and the security doc must not call that harmless. The file stays, but the package set moves
# under it: dnf5 drops a stored ordinary offline update after a live transaction, and a release
# upgrade built against the old package set is not known to survive one. A claim that the live
# upgrade "leaves the stored transaction alone" tells a reader the unguarded verb costs nothing.
SEC_DOC="$REPO_ROOT/docs/security.md"
grep -qiE 'leaves the stored transaction alone' "$SEC_DOC" \
  && { echo "FAIL: docs/security.md says a live upgrade leaves a stored release upgrade alone"; _fail=1; } \
  || echo "ok: docs/security.md does not call the unguarded live upgrade harmless"
grep -qF 'A live upgrade is not refused' "$SEC_DOC" \
  && echo "ok: docs/security.md names the live upgrade as outside the stored-transaction guard" \
  || { echo "FAIL: docs/security.md does not say the live upgrade is unguarded"; _fail=1; }

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

# As root the path is fixed, and KEMPT_OFFLINE_TOML must change nothing. Run for real, without
# sudo: an unprivileged user namespace makes EUID 0, and a private mount namespace puts a fixture
# directory over /usr/lib/sysimage/libdnf5 for this one process. Nothing outside the namespace sees
# the mount, and ECHO keeps dnf5 from running.
LIBDNF5=/usr/lib/sysimage/libdnf5
mkdir -p "$TESTTMP/ns-relup/offline" "$TESTTMP/ns-empty"
cp "$FIXTURES/offline-release-upgrade.toml" "$TESTTMP/ns-relup/offline/offline-transaction-state.toml"
as_ns_root() {  # bind-dir verb [env...] → runs the helper as EUID 0 over that directory
  local dir="$1" verb="$2"; shift 2
  timeout 20 unshare --map-root-user --mount bash -c '
    d="$1" h="$2" v="$3"; shift 3
    mount --bind "$d" '"$LIBDNF5"' || exit 99
    [[ $EUID -eq 0 ]] || exit 98
    exec env KEMPT_APPLY_ECHO=1 "$@" bash "$h" "$v"' _ "$dir" "$AH" "$verb" "$@"
}
if [[ $EUID -ne 0 && -d "$LIBDNF5" ]] && command -v unshare >/dev/null \
   && timeout 20 unshare --map-root-user --mount bash -c 'mount --bind "$1" '"$LIBDNF5" _ "$TESTTMP/ns-empty" 2>/dev/null; then
  assert_exit "$REFUSED_RC" "as root, the real path decides: a stored release upgrade is refused even with the seam at an ordinary update" -- \
    as_ns_root "$TESTTMP/ns-relup" dnf-offline-arm KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml"
  assert_eq "$(cat "$TESTTMP/last_output")" "$(relup_line dnf-offline-arm)" "...refused by what the real path holds"
  assert_exit 0 "as root, the seam cannot invent a release upgrade either" -- \
    as_ns_root "$TESTTMP/ns-empty" dnf-offline-clean KEMPT_OFFLINE_TOML="$FIXTURES/offline-release-upgrade.toml"
  assert_eq "$(cat "$TESTTMP/last_output")" "$(KEMPT_SYSTEMD_RUN=/usr/bin/systemd-run sd '' offline clean -y)" \
    "...the real path is empty, so the verb goes ahead, through the real systemd-run"
  # The systemd seams change nothing as root either. The sandbox points them at the stand-in and a
  # directory that exists; here the booted one points nowhere. Root reads only the real paths, so
  # the answer is the box's own: go ahead where systemd runs, exit 4 where it does not.
  if [[ -d /run/systemd/system && -x /usr/bin/systemd-run ]]; then
    assert_exit 0 "as root, the systemd seams are ignored: the real systemd-run, though the seam says systemd is absent" -- \
      as_ns_root "$TESTTMP/ns-empty" dnf-offline-clean KEMPT_SYSTEMD_BOOTED="$TESTTMP/no-such-dir"
    assert_eq "$(cat "$TESTTMP/last_output")" "$(KEMPT_SYSTEMD_RUN=/usr/bin/systemd-run sd '' offline clean -y)" "...and its fixed path"
  else
    assert_exit 4 "as root, the systemd seams are ignored: no systemd here, though the seams point at a stand-in" -- \
      as_ns_root "$TESTTMP/ns-empty" dnf-offline-clean
  fi
  if [[ ! -e /system-update && ! -L /system-update ]]; then
    assert_exit 0 "as root, the link seam cannot invent another updater's restart" -- \
      as_ns_root "$TESTTMP/ns-empty" dnf-offline-clean KEMPT_OFFLINE_LINK="$FL/foreign-link" KEMPT_OFFLINE_DATADIR="$FL/offline"
  else
    skip "root link-seam test: this box has a /system-update of its own"
  fi
else
  skip "root-path seam test - needs unprivileged user and mount namespaces and $LIBDNF5"
fi

# --- the one way root's dnf5 starts: systemd-run, and nothing else ---------------------------------
# pkexec hands the helper far more of the caller than its environment: umask, limits, ignored
# signals, the working directory, nice, CPU affinity, the cgroup. Bash cannot undo all of that
# (an ignored signal stays ignored across exec), so the helper does not try. It validates, reads,
# and execs systemd-run, and systemd starts dnf5 as a fresh service that inherits none of it.
# That only holds while the helper's own shell runs nothing else and writes nothing. This reads the
# helper's code (comments out, continued lines joined) and prints each line that breaks the shape:
#   - dnf5 named anywhere but as systemd-run's command, the rpm version read, or an error message
#   - more than one exec, or one that is not the ECHO seam's `exec "$@"`
#   - run called anywhere but on the one systemd-run line, with its fixed properties
#   - a redirection other than to stderr or /dev/null, or a command that writes or starts another
root_shape_violations() {  # helper file → one line per violation, then "read to the end"
  local code
  code="$(grep -vE '^[[:space:]]*#' "$1" | sed -E 's/[[:space:]]+#.*$//' | sed -e ':a' -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta')"
  local sdline='^[[:space:]]*run "\$SYSTEMD_RUN" --pipe --wait --quiet --collect -p UMask=0022 -p LimitCORE=0 .*-- /usr/bin/dnf5 "\$@"$'
  grep -wE 'dnf5' <<<"$code" \
    | grep -vE -e "$sdline" -e "rpm -q --qf '%\{VERSION\}' dnf5 2>/dev/null" -e '^[[:space:]]*echo "kempt-(apply|refresh): [^"]*" >&2$' \
    | sed 's/^/dnf5 outside systemd-run: /' || true
  local execs; execs="$(grep -wE 'exec' <<<"$code" || true)"
  [[ "$(grep -c . <<<"$execs")" == 1 && "$execs" =~ else\ exec\ \"\$@\"\;\ fi$ ]] \
    || printf 'exec other than the seam'"'"'s: %s\n' "${execs//$'\n'/ | }"
  local runs; runs="$(grep -E '(^|[;&|)]|then|else|do)[[:space:]]*run[[:space:]]' <<<"$code" || true)"
  [[ "$(grep -c . <<<"$runs")" == 1 ]] && grep -qE "$sdline" <<<"$runs" \
    || printf 'run called other than on the systemd-run line: %s\n' "${runs//$'\n'/ | }"
  sed -E 's/[0-9]*>&[0-9]//g; s/[0-9]*>[[:space:]]*\/dev\/null//g; s/ -> / /g' <<<"$code" | grep -E '>' \
    | sed 's/^/writes a file: /' || true
  grep -E '(^|[^A-Za-z0-9_-])(touch|mkdir|cp|mv|rm|ln|install|chmod|chown|chgrp|truncate|dd|tee|mktemp|mkfifo|timeout|env|nohup|setsid|nice|systemctl|pkexec|sudo|runuser|flatpak)([[:space:]]|$)|sed -i|[^&>]&([^&>]|$)' <<<"$code" \
    | sed 's/^/writes or starts another command: /' || true
  echo "read to the end"   # so a check that died partway can never pass as an empty answer
}
for h in "$RH" "$AH"; do
  assert_eq "$(root_shape_violations "$h")" "read to the end" "$(basename "$h"): dnf5 starts only through systemd-run, and the shell before it writes nothing"
done
# The check can fail. Each of these is one line a future edit could plausibly add.
mutant() { sed "$1" "$AH" > "$TESTTMP/mutant"; root_shape_violations "$TESTTMP/mutant"; }
assert_exit 0 "...it catches dnf5 run straight from the shell" -- \
  grep -q 'dnf5 outside systemd-run' <(mutant 's|^    run_dnf5 -- offline clean -y$|    run dnf5 offline clean -y|')
assert_exit 0 "...it catches a second exec" -- \
  grep -q 'exec other than' <(mutant 's|^set -euo pipefail$|set -euo pipefail; exec 3>/dev/null|')
assert_exit 0 "...it catches a write before the exec" -- \
  grep -q 'writes a file' <(mutant 's|^set -euo pipefail$|set -euo pipefail; echo x > /var/tmp/x|')
assert_exit 0 "...it catches another command started as root" -- \
  grep -q 'starts another' <(mutant 's|^set -euo pipefail$|set -euo pipefail; mkdir -p /var/tmp/x|')
assert_exit 0 "...it catches the time limit going back to timeout" -- \
  grep -q 'starts another' <(sed 's|run_dnf5 -p RuntimeMaxSec=120 -p TimeoutStopSec=10 -- makecache --refresh|run /usr/bin/timeout -k 10 120 dnf5 makecache --refresh|' "$RH" \
    > "$TESTTMP/mutant-r"; root_shape_violations "$TESTTMP/mutant-r")

# What systemd-run is handed, one argument per line, from the stand-in tests/lib.sh writes. No ECHO
# here: the helper really execs it.
# shellcheck disable=SC2086 # SD_BASE and the properties are split into words on purpose
want_argv() { local props="$1"; shift; printf '%s\n' $SD_BASE $props -- /usr/bin/dnf5 "$@"; }
SDARGV="$TESTTMP/systemd-run.argv"
assert_exit 0 "refresh check execs systemd-run" -- env KEMPT_DNF5_VERSION=5.2.18.0 bash "$RH" check
assert_eq "$(cat "$SDARGV")" "$(want_argv '' --cacheonly check-update --quiet)" "...with the fixed properties, then -- and dnf5's arguments"
assert_exit 0 "refresh check on dnf5 5.4 execs systemd-run" -- env KEMPT_DNF5_VERSION=5.4.0 bash "$RH" check
assert_eq "$(cat "$SDARGV")" "$(want_argv '' --cacheonly check-update --quiet --json)" "...asking for JSON"
assert_exit 0 "refresh execs systemd-run" -- bash "$RH" refresh
assert_eq "$(cat "$SDARGV")" "$(want_argv '-p RuntimeMaxSec=120 -p TimeoutStopSec=10' makecache --refresh)" "...bounded by the unit, not by timeout"
assert_exit 0 "dnf-upgrade execs systemd-run" -- bash "$AH" dnf-upgrade -y --exclude=vim-common --exclude=kernel-core
assert_eq "$(cat "$SDARGV")" "$(want_argv '' upgrade -y --exclude=vim-common --exclude=kernel-core)" "...every exclude after the --, where systemd-run cannot read it as an option"
for v in dnf-offline-stage dnf-offline-arm dnf-offline-clean; do
  rm -f "$SDARGV"
  # shellcheck disable=SC2046
  assert_exit 0 "$v execs systemd-run" -- env KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" bash "$AH" "$v" $(offline_args "$v")
  case "$v" in
    dnf-offline-stage) want="$(want_argv '' upgrade --offline -y)" ;;
    dnf-offline-arm)   want="$(want_argv --setenv=DNF_SYSTEM_UPGRADE_NO_REBOOT=1 offline reboot -y)" ;;
    *)                 want="$(want_argv '' offline clean -y)" ;;
  esac
  assert_eq "$(cat "$SDARGV")" "$want" "...$v hands it exactly this"
done
# exec, not a child: the process that ran the helper IS systemd-run, so the shell is gone and its
# exit status is systemd-run's, which is dnf5's.
# shellcheck disable=SC2016 # expanded by the inner bash
bash -c 'echo "$$" > "$2"; exec bash "$1" refresh' _ "$RH" "$TESTTMP/helper.pid"
assert_eq "$(cat "$TESTTMP/systemd-run.pid")" "$(cat "$TESTTMP/helper.pid")" "the helper execs systemd-run in its own process, leaving nothing behind it"
assert_exit 100 "dnf5's 100 from check-update comes back through the helper" -- env KEMPT_TEST_SDRUN_RC=100 bash "$RH" check
assert_exit 1 "...and a failed refresh's 1" -- env KEMPT_TEST_SDRUN_RC=1 bash "$RH" refresh
assert_exit 1 "...and a failed upgrade's 1" -- env KEMPT_TEST_SDRUN_RC=1 bash "$AH" dnf-upgrade -y
assert_exit 255 "...and systemd-run's own 255 for a dnf5 killed by a signal" -- env KEMPT_TEST_SDRUN_RC=255 bash "$AH" dnf-offline-clean

# Fail closed. Without systemd as PID 1 (a container, say) or without systemd-run, nothing runs and
# the helper exits 4, apart from 2 (bad arguments), 3 (refused) and dnf5's own statuses. It never
# runs dnf5 from its own shell instead. ECHO is set on purpose: the seam cannot hide the refusal.
nosd_line() { printf '%s: systemd is not running this system, or systemd-run is missing, so dnf5 was not started\n' "$1"; }
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
assert_exit "$REFUSED_RC" "a refusal is still exit 3 without systemd" -- \
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
