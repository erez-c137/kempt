#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
POL="$REPO_ROOT/polkit/org.erez.upkeep.policy"
RULES_IN="$REPO_ROOT/polkit/49-upkeep.rules.in"

if command -v xmllint >/dev/null; then
  if xmllint --noout "$POL"; then echo "ok: policy XML well-formed"
  else echo "FAIL: policy XML malformed"; _fail=1; fi
else echo "ok: xmllint unavailable, skipped"; fi
assert_eq "$(grep -c '<action id=' "$POL")" "2" "two actions defined"
grep -q 'org.erez.upkeep.refresh' "$POL" && echo "ok: refresh action present" || { echo "FAIL: refresh action"; _fail=1; }
grep -q 'org.erez.upkeep.apply' "$POL" && echo "ok: apply action present" || { echo "FAIL: apply action"; _fail=1; }
grep -q '<allow_active>yes</allow_active>' "$POL" && echo "ok: refresh is no-dialog" || { echo "FAIL: allow_active"; _fail=1; }
grep -q 'auth_admin_keep' "$POL" && echo "ok: apply is auth_admin_keep" || { echo "FAIL: auth_admin_keep"; _fail=1; }
grep -q '/usr/local/libexec/upkeep-refresh' "$POL" && echo "ok: refresh path annotated" || { echo "FAIL: refresh path"; _fail=1; }
grep -q '/usr/local/libexec/upkeep-apply' "$POL" && echo "ok: apply path annotated" || { echo "FAIL: apply path"; _fail=1; }
grep -q '@USER@' "$RULES_IN" && echo "ok: rules template has placeholder" || { echo "FAIL: placeholder"; _fail=1; }
grep -q 'org.erez.upkeep.apply' "$RULES_IN" && echo "ok: rules scoped to apply action only" || { echo "FAIL: rules scope"; _fail=1; }
grep -q 'org.erez.upkeep.refresh' "$RULES_IN" && { echo "FAIL: rules must NOT touch refresh"; _fail=1; } || echo "ok: refresh not in rules"
finish
