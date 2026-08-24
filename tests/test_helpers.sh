#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
RH="$REPO_ROOT/libexec/upkeep-refresh"
AH="$REPO_ROOT/libexec/upkeep-apply"

# ECHO=1 on the rejection cases too (belt and braces): if an arg guard is ever removed, the
# assertion fails loudly instead of the test reaching a real dnf5 invocation.
assert_exit 2 "refresh: no verb"        env UPKEEP_REFRESH_ECHO=1 bash "$RH"
assert_exit 2 "refresh: bad verb"       env UPKEEP_REFRESH_ECHO=1 bash "$RH" nuke
# Extra args are never forwarded to dnf5, so they must be REFUSED rather than silently dropped —
# `upkeep-refresh check --installroot=/foo` must not look like it honoured the flag.
assert_exit 2 "refresh: extra args rejected"  bash "$RH" check --installroot=/foo
assert_exit 2 "refresh: trailing empty arg rejected" bash "$RH" refresh ''
# UPKEEP_REFRESH_ECHO mirrors apply's seam: print the final command instead of exec'ing it.
assert_eq "$(UPKEEP_REFRESH_ECHO=1 bash "$RH" check)" "dnf5 --cacheonly check-update --quiet" \
  "refresh helper: check builds exact command"
assert_eq "$(UPKEEP_REFRESH_ECHO=1 bash "$RH" refresh)" "dnf5 makecache --refresh" \
  "refresh helper: refresh builds exact command"
assert_exit 2 "apply: no verb"          bash "$AH"
assert_exit 2 "apply: bad verb"         bash "$AH" rm-rf
assert_exit 2 "apply: injection via exclude" bash "$AH" dnf-upgrade '--exclude=foo;rm -rf /'
assert_exit 2 "apply: option smuggling"      bash "$AH" dnf-upgrade '--installroot=/'
assert_exit 2 "apply: bad flatpak id"        bash "$AH" flatpak-update -y 'evil;id'
# UPKEEP_APPLY_ECHO=1 makes the helper print the final command instead of exec'ing it (test seam)
got="$(UPKEEP_APPLY_ECHO=1 bash "$AH" dnf-upgrade -y --exclude=vim-common --exclude=kernel-core)"
assert_eq "$got" "dnf5 upgrade -y --exclude=vim-common --exclude=kernel-core" "dnf-upgrade builds exact command"
got2="$(UPKEEP_APPLY_ECHO=1 bash "$AH" dnf-offline-stage -y)"
assert_eq "$got2" "dnf5 upgrade --offline -y" "offline stage builds exact command"
got3="$(UPKEEP_APPLY_ECHO=1 bash "$AH" flatpak-update -y)"
assert_eq "$got3" "flatpak update --system --noninteractive -y" "flatpak all-apps command"
# auto_accept=false must reach flatpak: --noninteractive is part of the -y mapping, never hardcoded,
# or a user who turned auto-accept off would still get a silent unattended flatpak upgrade.
got4="$(UPKEEP_APPLY_ECHO=1 bash "$AH" flatpak-update)"
assert_eq "$got4" "flatpak update --system" "no -y omits the auto-accept flags"

# The LC_ALL=C.UTF-8 pin precedes validation on purpose: under a UTF-8 locale glibc widens
# [A-Za-z] to accented letters, so a caller's locale must not be able to widen what the ROOT
# helper accepts. ECHO is set as a second guard: if the pin ever regressed, this asserts loudly
# instead of reaching a real dnf5. Probe first — on a box without en_US.UTF-8 the range does not
# widen and the assertion would pass for the wrong reason.
if LC_ALL=en_US.UTF-8 bash -c '[[ "é" =~ ^[A-Za-z]$ ]]' 2>/dev/null; then
  assert_exit 2 "apply: caller locale cannot widen the name pattern" \
    env LC_ALL=en_US.UTF-8 UPKEEP_APPLY_ECHO=1 bash "$AH" dnf-upgrade '--exclude=évil'
else
  echo "ok: SKIPPED locale probe (en_US.UTF-8 unavailable)"
fi

# Root-helper hardening: absolute interpreter + pinned, EXPORTED PATH. Exported matters: without
# it, children spawned under a cleared environment fall back to a default that puts /usr/local/bin
# first — for RPM scriptlets running as root, that is a writable-by-admin dir ahead of /usr/bin.
for h in "$RH" "$AH"; do
  head -1 "$h" | grep -qx '#!/bin/bash' && echo "ok: absolute shebang ($(basename "$h"))" \
    || { echo "FAIL: shebang ($(basename "$h"))"; _fail=1; }
  grep -qx 'export PATH=/usr/sbin:/usr/bin:/sbin:/bin' "$h" && echo "ok: exported pinned PATH ($(basename "$h"))" \
    || { echo "FAIL: PATH ($(basename "$h"))"; _fail=1; }
done

# Cross-boundary scope contract (v1 = system-scope flatpaks only): the helper validates app ids
# against `flatpak list --system`, so the backend's check commands must carry --system too, or a
# per-user app would be counted in the badge and then refused at update time.
FP="$REPO_ROOT/backends/flatpak.sh"
grep -q 'flatpak remote-ls --updates --system --app' "$FP" && echo "ok: check scope is --system" \
  || { echo "FAIL: remote-ls not --system scoped"; _fail=1; }
grep -q 'flatpak list --system --app' "$FP" && echo "ok: installed lookup scope is --system" \
  || { echo "FAIL: list not --system scoped"; _fail=1; }
grep -q 'flatpak list --system --app --columns=application' "$AH" && echo "ok: helper validates against the same scope" \
  || { echo "FAIL: helper scope drifted from the backend"; _fail=1; }
# The per-app loop is the one privileged argv no test can execute (its installed-set validation
# is deliberately not env-overridable), so its scope is pinned by source grep instead: dropping
# --system there would update per-USER apps from a root helper the badge never counted.
grep -q 'run_noexec flatpak update --system' "$AH" && echo "ok: per-app privileged argv pinned" \
  || { echo "FAIL: per-app privileged argv lost --system"; _fail=1; }
finish
