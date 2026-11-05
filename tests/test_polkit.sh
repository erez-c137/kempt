#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
POL="$REPO_ROOT/polkit/io.github.erez_c137.kempt.policy"
RULES="$REPO_ROOT/polkit/49-kempt.rules"
SPEC="$REPO_ROOT/kempt.spec"

if command -v xmllint >/dev/null; then
  if xmllint --noout "$POL"; then echo "ok: policy XML well-formed"
  else echo "FAIL: policy XML malformed"; _fail=1; fi
else echo "ok: xmllint unavailable, skipped"; fi
assert_eq "$(grep -c '<action id=' "$POL")" "2" "two actions defined"
grep -q 'io.github.erez_c137.kempt.refresh' "$POL" && echo "ok: refresh action present" || { echo "FAIL: refresh action"; _fail=1; }
grep -q 'io.github.erez_c137.kempt.apply' "$POL" && echo "ok: apply action present" || { echo "FAIL: apply action"; _fail=1; }
grep -q '<allow_active>yes</allow_active>' "$POL" && echo "ok: refresh is no-dialog" || { echo "FAIL: allow_active"; _fail=1; }
grep -q 'auth_admin_keep' "$POL" && echo "ok: apply is auth_admin_keep" || { echo "FAIL: auth_admin_keep"; _fail=1; }
grep -q '/usr/local/libexec/kempt-refresh' "$POL" && echo "ok: refresh path annotated" || { echo "FAIL: refresh path"; _fail=1; }
grep -q '/usr/local/libexec/kempt-apply' "$POL" && echo "ok: apply path annotated" || { echo "FAIL: apply path"; _fail=1; }

# --- the fixed rule: one test on one action, shipped by the package --------------------------------
# What is executable, comments left out, so a clause surviving in a comment does not count.
CODE="$(sed -E 's://.*$::; /^[[:space:]]*$/d' "$RULES")"
assert_contains "$CODE" 'action.id == "io.github.erez_c137.kempt.apply"' "the rule names the apply action"
assert_contains "$CODE" 'subject.active' "...for an active session"
assert_contains "$CODE" 'subject.local' "...at this machine"
assert_contains "$CODE" 'subject.isInGroup("wheel")' "...of an administrator"
assert_eq "$(grep -c 'polkit.addRule' <<<"$CODE")" "1" "...in one block"
assert_eq "$(grep -c 'polkit.Result' <<<"$CODE")" "1" "...with one answer"
assert_contains "$CODE" 'return polkit.Result.YES' "...which is yes"
assert_not_contains "$CODE" 'kempt.refresh' "...and it leaves the no-dialog action alone"
assert_not_contains "$CODE" '@USER@' "...and names no user"
if command -v node >/dev/null; then
  # The rule run, with polkit's own question: a test on the words would pass a rule that returns too much.
  answer() {  # action active local wheel
    node -e '
      let rule; const polkit = { addRule: f => { rule = f; }, Result: { YES: "yes" } };
      eval(require("fs").readFileSync(process.argv[1], "utf8"));
      const [id, active, local, wheel] = process.argv.slice(2);
      console.log(rule({ id }, { active: active === "1", local: local === "1", isInGroup: g => g === "wheel" && wheel === "1" }) ?? "default");
    ' "$RULES" "$@"
  }
  A=io.github.erez_c137.kempt.apply
  assert_eq "$(answer $A 1 1 1)" "yes" "wheel, active and local: yes, with no password"
  assert_eq "$(answer $A 1 0 1)" "default" "wheel over SSH: the rule stays out, and the policy says no"
  assert_eq "$(answer $A 0 1 1)" "default" "wheel in a session in the background: the rule stays out"
  assert_eq "$(answer $A 1 1 0)" "default" "not wheel at the desk: the rule stays out, and the policy asks an admin"
  assert_eq "$(answer org.freedesktop.policykit.exec 1 1 1)" "default" "another action: the rule stays out"
else
  skip "no node here, so the rule was not run"
fi
POLTXT="$(cat "$POL")"
assert_contains "$POLTXT" '<allow_any>no</allow_any>' "the policy says no to a remote session"
assert_contains "$POLTXT" '<allow_inactive>no</allow_inactive>' "...and to a session in the background"

# --- the package owns the rule, and an upgrade leaves one rule and no other -----------------------------
assert_contains "$(sed -n '/^%install/,/^%files/p' "$SPEC")" '%{buildroot}%{_datadir}/polkit-1/rules.d/49-kempt.rules' "the package installs the rule"
assert_contains "$(sed -n '/^%files$/,/^%package\|^%files /p' "$SPEC")" '%{_datadir}/polkit-1/rules.d/49-kempt.rules' "...and lists it"
assert_not_contains "$(cat "$SPEC")" '%post' "no step on every install or upgrade touches an override"
# The rule the old opt-in wrote goes once, on the upgrade from before 0.3.0, and only if it is that rule.
TRIG="$(sed -n '/^%triggerun -- kempt < 0\.3\.0$/,/^%/{/^%/d;p}' "$SPEC")"
assert_contains "$TRIG" 'rm -f "$f"' "the upgrade from before 0.3.0 can remove the old rule"
DST="$TESTTMP/49-kempt.rules"
trigger_on() { sed "s|/etc/polkit-1/rules.d/49-kempt.rules|$DST|" <<<"$TRIG" | sh; }
old_rule() { sed "s/@USER@/${2:-someone.else-2}/g" "$FIXTURES/old-rule-$1.rules.in"; }
gone() { local rc=0; trigger_on || rc=$?; assert_eq "$rc" "0" "...the step exits 0"; assert_eq "$([[ -e "$DST" || -L "$DST" ]] && echo stays || echo gone)" "$1" "$2"; rm -f "$DST"; }
gone gone "nothing there: nothing to do"
for v in 0.1.0 0.2.0; do
  old_rule "$v" > "$DST"; gone gone "the rule $v wrote is removed"
  old_rule "$v" _u1 > "$DST"; gone gone "...whatever user it names"
  { old_rule "$v"; echo '// mine'; } > "$DST"; gone stays "...a line added to it makes it the admin's, and it stays"
  old_rule "$v" | sed 's/polkit.Result.YES/polkit.Result.AUTH_ADMIN/' > "$DST"; gone stays "...and so does a changed answer"
  old_rule "$v" 'a b' > "$DST"; gone stays "...and a user no opt-in could have written"
done
printf 'polkit.addRule(function(action, subject) { return polkit.Result.NOT_HANDLED; });\n' > "$DST"; gone stays "a hand-written override stays"
: > "$DST"; gone stays "an empty file stays"
old_rule 0.2.0 > "$DST.target"; ln -s "$DST.target" "$DST"; gone stays "a link stays"; rm -f "$DST.target"
assert_not_contains "$(cat "$REPO_ROOT/bin/kempt")" 'passwordless' "the CLI has no opt-in left"
finish
