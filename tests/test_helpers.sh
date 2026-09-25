#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
RH="$REPO_ROOT/libexec/kempt-refresh"
AH="$REPO_ROOT/libexec/kempt-apply"

# ECHO=1 on the rejection cases too (belt and braces): if an arg guard is ever removed, the
# assertion fails loudly instead of the test reaching a real dnf5 invocation.
assert_exit 2 "refresh: no verb"        env KEMPT_REFRESH_ECHO=1 bash "$RH"
assert_exit 2 "refresh: bad verb"       env KEMPT_REFRESH_ECHO=1 bash "$RH" nuke
# Extra args are never forwarded to dnf5, so they must be REFUSED rather than silently dropped -
# `kempt-refresh check --installroot=/foo` must not look like it honoured the flag.
assert_exit 2 "refresh: extra args rejected"  bash "$RH" check --installroot=/foo
assert_exit 2 "refresh: trailing empty arg rejected" bash "$RH" refresh ''
# KEMPT_REFRESH_ECHO mirrors apply's seam: print the final command instead of exec'ing it.
assert_eq "$(KEMPT_DNF5_VERSION=5.2.18.0 KEMPT_REFRESH_ECHO=1 bash "$RH" check)" "dnf5 --cacheonly check-update --quiet" \
  "refresh helper: check builds exact command"
# dnf5 5.4.0 added --json to check-update. The verb, its polkit action and its one argument stay
# the same; only the output format follows the installed dnf5.
assert_eq "$(KEMPT_DNF5_VERSION=5.4.0.0 KEMPT_REFRESH_ECHO=1 bash "$RH" check)" \
  "dnf5 --cacheonly check-update --quiet --json" "refresh helper: check asks for JSON from dnf5 5.4.0"
assert_eq "$(KEMPT_DNF5_VERSION=5.10.0.0 KEMPT_REFRESH_ECHO=1 bash "$RH" check)" \
  "dnf5 --cacheonly check-update --quiet --json" "...compared as versions, so 5.10 is newer than 5.4"
assert_eq "$(KEMPT_DNF5_VERSION=5.3.9.0 KEMPT_REFRESH_ECHO=1 bash "$RH" check)" \
  "dnf5 --cacheonly check-update --quiet" "...and text before it"
assert_eq "$(KEMPT_REFRESH_ECHO=1 bash "$RH" refresh)" "dnf5 makecache --refresh" \
  "refresh helper: refresh builds exact command"
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
assert_eq "$got" "dnf5 upgrade -y --exclude=vim-common --exclude=kernel-core" "dnf-upgrade builds exact command"
got2="$(KEMPT_APPLY_ECHO=1 bash "$AH" dnf-offline-stage -y)"
assert_eq "$got2" "dnf5 upgrade --offline -y" "offline stage builds exact command"
# Staging is only half the job: `dnf5 upgrade --offline` leaves the transaction at
# status="download-complete", which no boot ever applies. `dnf5 offline reboot` is what flips it to
# "ready" and creates the /system-update symlink systemd's generator looks for - and it reboots
# immediately unless DNF_SYSTEM_UPGRADE_NO_REBOOT is set (dnf5-offline(8)). Kempt arms and lets the
# person choose when, so the env var is load-bearing, not decoration: without it this verb reboots
# the box out from under whoever pressed a button labelled "Install on Next Restart". It is set
# through `env` rather than a shell assignment so the ECHO seam can print it and this assertion can
# pin it - a prefix assignment would vanish from "$*" and leave the reboot guard unverifiable.
got3="$(KEMPT_APPLY_ECHO=1 bash "$AH" dnf-offline-arm)"
assert_eq "$got3" "env DNF_SYSTEM_UPGRADE_NO_REBOOT=1 dnf5 offline reboot -y" \
  "offline arm builds exact command, with the no-reboot guard"
got4="$(KEMPT_APPLY_ECHO=1 bash "$AH" dnf-offline-clean)"
assert_eq "$got4" "dnf5 offline clean -y" "offline clean builds exact command"
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
  [dnf-offline-stage]="dnf5 upgrade --offline -y"
  [dnf-offline-arm]="env DNF_SYSTEM_UPGRADE_NO_REBOOT=1 dnf5 offline reboot -y"
  [dnf-offline-clean]="dnf5 offline clean -y"
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
assert_eq "$(cat "$TESTTMP/last_output")" "dnf5 upgrade -y" "...and builds its usual command"

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
  assert_eq "$(cat "$TESTTMP/last_output")" "dnf5 offline clean -y" "...the real path is empty, so the verb goes ahead"
else
  skip "root-path seam test - needs unprivileged user and mount namespaces and $LIBDNF5"
fi

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
