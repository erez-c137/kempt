#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
upkeep_init_dirs

assert_eq "$(config_get surface terminal)" "terminal" "default when unset"
config_set surface background
assert_eq "$(config_get surface terminal)" "background" "reads set value"
config_set surface offline
assert_eq "$(config_get surface terminal)" "offline" "overwrite same key"
assert_eq "$(grep -c '^surface=' "$UPKEEP_CONFIG_DIR/config")" "1" "no duplicate keys"
config_set include_flatpak false
assert_eq "$(config_get include_flatpak true)" "false" "second key independent"
assert_eq "$(config_get surface terminal)" "offline" "setting a second key preserves the first"
assert_eq "$(config_get refresh_interval_min 60)" "60" "default numeric"

# Input validation: a key that could smuggle syntax, and a multi-line value that could inject
# a second key=value line into the config file, are both refused.
assert_exit 2 "config key validated" config_set 'auto.accept' x
assert_exit 2 "newline value rejected" config_set multi $'a\nb=c'
# A rejected write must not have disturbed what was already stored.
assert_eq "$(config_get surface terminal)" "offline" "rejected writes leave surface intact"
assert_eq "$(config_get include_flatpak true)" "false" "rejected writes leave include_flatpak intact"
assert_eq "$(grep -c '' "$UPKEEP_CONFIG_DIR/config")" "2" "rejected writes added no lines"
finish
