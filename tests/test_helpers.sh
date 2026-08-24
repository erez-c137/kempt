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
finish
