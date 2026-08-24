#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
RH="$REPO_ROOT/libexec/upkeep-refresh"
AH="$REPO_ROOT/libexec/upkeep-apply"

assert_exit 2 "refresh: no verb"        bash "$RH"
assert_exit 2 "refresh: bad verb"       bash "$RH" nuke
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
# [A-Za-z] to accented letters (verified: é, Ä, ß all match under en_US.UTF-8), so a caller's
# locale must not be able to widen what the ROOT helper accepts. ECHO is set as a second guard:
# if the pin ever regressed, this asserts loudly instead of reaching a real dnf5.
assert_exit 2 "apply: caller locale cannot widen the name pattern" \
  env LC_ALL=en_US.UTF-8 UPKEEP_APPLY_ECHO=1 bash "$AH" dnf-upgrade '--exclude=évil'

# Root-helper hardening: absolute interpreter + fixed PATH, so neither is caller-controlled.
for h in "$RH" "$AH"; do
  head -1 "$h" | grep -qx '#!/bin/bash' && echo "ok: absolute shebang ($(basename "$h"))" \
    || { echo "FAIL: shebang ($(basename "$h"))"; _fail=1; }
  grep -qE '^(export )?PATH=/usr/sbin:/usr/bin:/sbin:/bin$' "$h" && echo "ok: fixed PATH ($(basename "$h"))" \
    || { echo "FAIL: PATH ($(basename "$h"))"; _fail=1; }
done
finish
