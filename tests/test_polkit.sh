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

# --- render_passwordless_rule: what it REFUSES to hand to a root install(1) ---
source "$REPO_ROOT/lib/common.sh"
UPKEEP="$REPO_ROOT/bin/upkeep"
ME="$(id -un)"
SCOPE='subject.active && subject.local'
# No hostile-USERNAME render test lives here: the render takes the name from $(id -un) and refuses
# anything outside ^[a-z_][a-z0-9._-]*$, so a crafted name is unreachable rather than merely
# harmless — asserting on one would only be testing awk. The binding tests are these guard tests
# (what the self-check refuses) plus the production-path check below, which proves a hostile USER
# env var never reaches the render at all.

# (a) scope clause stripped → refused, nothing written
sed 's/ && subject.active && subject.local//' "$RULES_IN" > "$TESTTMP/tmpl-noscope"
assert_exit 2 "render refuses a template that lost the scope clause" \
  render_passwordless_rule "$TESTTMP/tmpl-noscope" "$TESTTMP/out-noscope"
[[ -e "$TESTTMP/out-noscope" ]] && { echo "FAIL: refused render still wrote a file"; _fail=1; } \
  || echo "ok: refused render leaves nothing behind"
# (a2) the same, but with the clause surviving in a COMMENT: a self-check that reads comments
# would install a rule whose executable half has no scope test at all.
{ echo "// $SCOPE"; cat "$TESTTMP/tmpl-noscope"; } > "$TESTTMP/tmpl-commentonly"
assert_exit 2 "render is not fooled by a scope clause that survives only in a comment" \
  render_passwordless_rule "$TESTTMP/tmpl-commentonly" "$TESTTMP/out-commentonly"

# (b) action id swapped for a broader one → refused (this template would grant pkexec itself)
sed 's/org.erez.upkeep.apply/org.freedesktop.policykit.exec/' "$RULES_IN" > "$TESTTMP/tmpl-badaction"
assert_exit 2 "render refuses a template with a different action id" \
  render_passwordless_rule "$TESTTMP/tmpl-badaction" "$TESTTMP/out-badaction"
[[ -e "$TESTTMP/out-badaction" ]] && { echo "FAIL: refused render still wrote a file"; _fail=1; } \
  || echo "ok: wrong-action render leaves nothing behind"

# (b2) a second rule block appended → refused (one addRule is the whole contract)
{ cat "$RULES_IN"; echo 'polkit.addRule(function(action, subject) { return polkit.Result.YES; });'; } \
  > "$TESTTMP/tmpl-tworules"
assert_exit 2 "render refuses a template carrying a second rule block" \
  render_passwordless_rule "$TESTTMP/tmpl-tworules" "$TESTTMP/out-tworules"

# (c) the shipped template → accepted, and the result is exactly what should be installed
assert_exit 0 "render accepts the shipped template" \
  render_passwordless_rule "$RULES_IN" "$TESTTMP/out-good"
grep -qF "subject.user == \"$ME\"" "$TESTTMP/out-good" && echo "ok: rendered for the real username" \
  || { echo "FAIL: username not rendered"; _fail=1; }
grep -qF "$SCOPE" "$TESTTMP/out-good" && echo "ok: rendered rule keeps the scope clause" \
  || { echo "FAIL: rendered rule lost the scope"; _fail=1; }
assert_eq "$(grep -c 'polkit.addRule' "$TESTTMP/out-good")" "1" "exactly one polkit.addRule"
grep -q '@USER@' "$TESTTMP/out-good" && { echo "FAIL: placeholder left unsubstituted"; _fail=1; } \
  || echo "ok: no placeholder survives the render"

# The destination is handed to a ROOT install(1), so its shape is pinned. Both rejections happen
# before anything is invoked; the sandbox paths mean a regression could only hit TESTTMP anyway.
assert_exit 2 "enable rejects a destination that is not a .rules file" \
  env UPKEEP_RULES_DST="$TESTTMP/notrules" "$UPKEEP" enable-passwordless
assert_exit 2 "enable rejects a relative destination" \
  env UPKEEP_RULES_DST="relative/49-upkeep.rules" "$UPKEEP" enable-passwordless
assert_exit 2 "enable-passwordless takes no arguments" \
  env UPKEEP_RULES_DST="$TESTTMP/absent.rules" "$UPKEEP" enable-passwordless --force
assert_exit 2 "disable-passwordless takes no arguments" \
  env UPKEEP_RULES_DST="$TESTTMP/absent.rules" "$UPKEEP" disable-passwordless --force
# Disabling something that was never enabled is not a failure, and must not raise an auth prompt
# to discover that: nothing is invoked when the destination does not exist.
assert_eq "$(UPKEEP_RULES_DST="$TESTTMP/absent.rules" "$UPKEEP" disable-passwordless)" \
  "passwordless was not enabled" "disable is a clean no-op when nothing is installed"
# ...but that no-op must never be a GUESS. The real /etc/polkit-1/rules.d is 0750 root:polkitd,
# so an unprivileged existence test reports "absent" for a file that is really there; treating
# that as "nothing to do" would leave a live passwordless grant in place while claiming it was
# never enabled. Unsearchable destination directory → proceed to the removal instead.
mkdir -p "$TESTTMP/locked"; chmod 000 "$TESTTMP/locked"
assert_exit 1 "disable does not guess when the destination directory cannot be searched" \
  env UPKEEP_RULES_DST="$TESTTMP/locked/49-upkeep.rules" "$UPKEEP" disable-passwordless
grep -q 'was not enabled' "$TESTTMP/last_output" \
  && { echo "FAIL: disable claimed 'not enabled' without being able to look"; _fail=1; } \
  || echo "ok: no false 'was not enabled' when the directory cannot be searched"
chmod 755 "$TESTTMP/locked"

# Production path through the documented seams: no pkexec wrapper (sandbox exports it empty),
# destination and mktemp both inside TESTTMP, hostile USER in the environment. /etc is never a
# target. The install step fails (a non-root user cannot -o root) after GNU install has already
# written the bytes, so the sandboxed destination holds exactly what would have been installed.
out="$(TMPDIR="$TESTTMP" UPKEEP_RULES_DST="$TESTTMP/rules-out.rules" USER='x/;s/subject.active/true/;s/QQQ/' \
       "$UPKEEP" enable-passwordless 2>"$TESTTMP/pw-err")" || true
assert_eq "$out" "" "unprivileged enable-passwordless never claims success"
[[ -f "$TESTTMP/rules-out.rules" ]] && echo "ok: production render reached the destination" \
  || { echo "FAIL: no render artifact to inspect"; _fail=1; }
grep -qF "subject.user == \"$ME\"" "$TESTTMP/rules-out.rules" \
  && echo "ok: rendered rule names id -un, not \$USER" || { echo "FAIL: USER env reached the render"; _fail=1; }
grep -qF "$SCOPE" "$TESTTMP/rules-out.rules" && echo "ok: installed render keeps the scope clause" \
  || { echo "FAIL: installed render lost the scope"; _fail=1; }
finish
