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

# --- rendering the rules template: the name must be DATA, never sed script ---
# The scope clause is the whole point of the file: without `subject.active && subject.local`,
# a passwordless grant reaches inactive and remote sessions of that user.
UPKEEP="$REPO_ROOT/bin/upkeep"
ME="$(id -un)"
SCOPE='subject.active && subject.local'
# A username-shaped payload that closes sed's s/// and appends commands. Rejected outright by
# cmd_enable_passwordless's username guard; used here to prove the RENDERER is safe on its own.
HOSTILE='x/;s/subject.active/true/;s/QQQ/'

sed "s/@USER@/$HOSTILE/" "$RULES_IN" > "$TESTTMP/sed-render"
awk -v u="$HOSTILE" '{gsub(/@USER@/, u); print}' "$RULES_IN" > "$TESTTMP/awk-render"
# Regression guard for the defect this replaced: sed executed the payload and dropped the scope.
grep -qF "$SCOPE" "$TESTTMP/sed-render" && { echo "FAIL: sed render was expected to lose the scope"; _fail=1; } \
  || echo "ok: sed render loses the scope clause (the defect, now unreachable)"
grep -qF "$SCOPE" "$TESTTMP/awk-render" && echo "ok: awk render keeps the scope clause" \
  || { echo "FAIL: awk render lost the scope"; _fail=1; }
grep -qF "subject.user == \"$HOSTILE\"" "$TESTTMP/awk-render" \
  && echo "ok: payload stays inside the user string literal" || { echo "FAIL: payload escaped the literal"; _fail=1; }
# awk's gsub treats & in the replacement as the match, so the username guard (no & or backslash)
# is load-bearing, not decorative; for a real username the two renders are byte-identical.
awk -v u="$ME" '{gsub(/@USER@/, u); print}' "$RULES_IN" > "$TESTTMP/awk-real"
assert_eq "$(cat "$TESTTMP/awk-real")" "$(sed "s/@USER@/$ME/" "$RULES_IN")" "plain username renders identically"
grep -qF "subject.user == \"$ME\"" "$TESTTMP/awk-real" && echo "ok: real username rendered" || { echo "FAIL: username"; _fail=1; }
grep -qF "$SCOPE" "$TESTTMP/awk-real" && echo "ok: real render keeps the scope clause" || { echo "FAIL: real render scope"; _fail=1; }

# Production path through the documented seams: no pkexec wrapper (sandbox exports it empty),
# destination and mktemp both inside TESTTMP, hostile USER in the environment. /etc is never a
# target. The install step fails (a non-root user cannot -o root), which is the expected end.
out="$(TMPDIR="$TESTTMP" UPKEEP_RULES_DST="$TESTTMP/rules-out" USER="$HOSTILE" \
       "$UPKEEP" enable-passwordless 2>"$TESTTMP/pw-err")" || true
assert_eq "$out" "" "unprivileged enable-passwordless never claims success"
if [[ -f "$TESTTMP/rules-out" ]]; then   # GNU install writes bytes, then fails at chown
  grep -qF "subject.user == \"$ME\"" "$TESTTMP/rules-out" \
    && echo "ok: rendered rule names id -un, not \$USER" || { echo "FAIL: USER env reached the render"; _fail=1; }
  grep -qF "$SCOPE" "$TESTTMP/rules-out" && echo "ok: installed render keeps the scope clause" \
    || { echo "FAIL: installed render lost the scope"; _fail=1; }
else
  echo "ok: install left no artifact (render covered above)"
fi
finish
