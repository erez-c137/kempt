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
assert_eq "$(KEMPT_REFRESH_ECHO=1 bash "$RH" check)" "dnf5 --cacheonly check-update --quiet" \
  "refresh helper: check builds exact command"
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
assert_exit 2 "apply: ...with app ids too"   env KEMPT_APPLY_ECHO=1 bash "$AH" flatpak-update -y org.gimp.GIMP
# KEMPT_APPLY_ECHO=1 makes the helper print the final command instead of exec'ing it (test seam)
got="$(KEMPT_APPLY_ECHO=1 bash "$AH" dnf-upgrade -y --exclude=vim-common --exclude=kernel-core)"
assert_eq "$got" "dnf5 upgrade -y --exclude=vim-common --exclude=kernel-core" "dnf-upgrade builds exact command"
got2="$(KEMPT_APPLY_ECHO=1 bash "$AH" dnf-offline-stage -y)"
assert_eq "$got2" "dnf5 upgrade --offline -y" "offline stage builds exact command"
# The two flatpak command-shape assertions that used to sit here now live in tests/test_flatpak.sh,
# against flatpak_apply and its own seam: that is where the command is built now.

# The LC_ALL=C.UTF-8 pin precedes validation on purpose: under a UTF-8 locale glibc widens
# [A-Za-z] to accented letters, so a caller's locale must not be able to widen what the ROOT
# helper accepts. ECHO is set as a second guard: if the pin ever regressed, this asserts loudly
# instead of reaching a real dnf5. Probe first - on a box without en_US.UTF-8 the range does not
# widen and the assertion would pass for the wrong reason.
if LC_ALL=en_US.UTF-8 bash -c '[[ "é" =~ ^[A-Za-z]$ ]]' 2>/dev/null; then
  assert_exit 2 "apply: caller locale cannot widen the name pattern" \
    env LC_ALL=en_US.UTF-8 KEMPT_APPLY_ECHO=1 bash "$AH" dnf-upgrade '--exclude=évil'
else
  echo "ok: SKIPPED locale probe (en_US.UTF-8 unavailable)"
fi

# Root-helper hardening: absolute interpreter + pinned, EXPORTED PATH. Exported matters: without
# it, children spawned under a cleared environment fall back to a default that puts /usr/local/bin
# first - for RPM scriptlets running as root, that is a writable-by-admin dir ahead of /usr/bin.
for h in "$RH" "$AH"; do
  head -1 "$h" | grep -qx '#!/bin/bash' && echo "ok: absolute shebang ($(basename "$h"))" \
    || { echo "FAIL: shebang ($(basename "$h"))"; _fail=1; }
  grep -qx 'export PATH=/usr/sbin:/usr/bin:/sbin:/bin' "$h" && echo "ok: exported pinned PATH ($(basename "$h"))" \
    || { echo "FAIL: PATH ($(basename "$h"))"; _fail=1; }
done

# No flatpak command may survive in root-owned code. The verb rejection above proves the case is
# gone; this proves nothing privileged still shells out to flatpak by another name.
# Comment lines are stripped first, exactly as render_passwordless_rule's self-check does it: the
# helper's header comment SAYS the word flatpak (to explain why the verb left), and a check that
# read comments would call that a violation.
grep -v '^[[:space:]]*#' "$AH" | grep -qi 'flatpak' \
  && { echo "FAIL: a flatpak command is back inside the root helper"; _fail=1; } \
  || echo "ok: the root helper runs no flatpak command at all"
# The --system scope contract moved with it: all four flatpak commands are built in
# backends/flatpak.sh now, and tests/test_flatpak.sh asserts their scope on the live variables.
finish
