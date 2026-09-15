#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; sandbox
POL="$REPO_ROOT/polkit/io.github.erez_c137.kempt.policy"
RULES_IN="$REPO_ROOT/polkit/49-kempt.rules.in"

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
grep -q '@USER@' "$RULES_IN" && echo "ok: rules template has placeholder" || { echo "FAIL: placeholder"; _fail=1; }
grep -q 'io.github.erez_c137.kempt.apply' "$RULES_IN" && echo "ok: rules scoped to apply action only" || { echo "FAIL: rules scope"; _fail=1; }
grep -q 'io.github.erez_c137.kempt.refresh' "$RULES_IN" && { echo "FAIL: rules must NOT touch refresh"; _fail=1; } || echo "ok: refresh not in rules"

# --- render_passwordless_rule: what it REFUSES to hand to a root install(1) ---
source "$REPO_ROOT/lib/common.sh"
KEMPT="$REPO_ROOT/bin/kempt"
ME="$(id -un)"
SCOPE='subject.active && subject.local'
# No hostile-USERNAME render test lives here: the render takes the name from $(id -un) and refuses
# anything outside ^[a-z_][a-z0-9._-]*$, so a crafted name is unreachable rather than merely
# harmless - asserting on one would only be testing awk. The binding tests are these guard tests
# (what the self-check refuses) plus the production-path check below, which proves a hostile USER
# env var never reaches the render at all.

# The render prints the checked rule on stdout and nothing else; the caller pipes that into root's
# install(1). So "refused" has to mean "printed nothing": a partial rule on stdout would be a rule
# on its way to root.
render_stdout() { render_passwordless_rule "$1" 2>/dev/null || true; }

# (a) scope clause stripped → refused, nothing printed
sed 's/ && subject.active && subject.local//' "$RULES_IN" > "$TESTTMP/tmpl-noscope"
assert_exit 2 "render refuses a template that lost the scope clause" \
  render_passwordless_rule "$TESTTMP/tmpl-noscope"
assert_eq "$(render_stdout "$TESTTMP/tmpl-noscope")" "" "refused render prints nothing"
# (a2) the same, but with the clause surviving in a COMMENT: a self-check that reads comments
# would install a rule whose executable half has no scope test at all.
{ echo "// $SCOPE"; cat "$TESTTMP/tmpl-noscope"; } > "$TESTTMP/tmpl-commentonly"
assert_exit 2 "render is not fooled by a scope clause that survives only in a comment" \
  render_passwordless_rule "$TESTTMP/tmpl-commentonly"

# (b) action id swapped for a broader one → refused (this template would grant pkexec itself)
sed 's/io.github.erez_c137.kempt.apply/org.freedesktop.policykit.exec/' "$RULES_IN" > "$TESTTMP/tmpl-badaction"
assert_exit 2 "render refuses a template with a different action id" \
  render_passwordless_rule "$TESTTMP/tmpl-badaction"
assert_eq "$(render_stdout "$TESTTMP/tmpl-badaction")" "" "wrong-action render prints nothing"

# (b1b) a WIDENED rule inside the one permitted block → refused. This is the case every
# grep-based check missed: the scope clause is there, the action id is there, there is exactly one
# addRule, and the rule grants passwordless root for EVERY polkit action from ANY session,
# including a remote one. It rendered clean and went to a root install(1).
awk '/^polkit.addRule/ { print; print "    if (subject.user == \"@USER@\") return polkit.Result.YES;"; next } { print }' \
    "$RULES_IN" > "$TESTTMP/tmpl-widened"
assert_exit 2 "render refuses a rule widened inside the block it is allowed to have" -- \
  render_passwordless_rule "$TESTTMP/tmpl-widened"
# ...and the refusal has to be readable by whoever hits it, because the person running
# enable-passwordless is being told their grant did NOT happen. Checked here, before the next
# assertion overwrites last_output.
grep -qF 'refusing' "$TESTTMP/last_output" \
  && echo "ok: ...and says it is refusing rather than naming a 'scope check'" \
  || { echo "FAIL: the refusal does not read as a refusal"; _fail=1; sed 's/^/    /' "$TESTTMP/last_output"; }
assert_eq "$(render_stdout "$TESTTMP/tmpl-widened")" "" "widened render prints nothing"

# (b2) a second rule block appended → refused (one addRule is the whole contract)
{ cat "$RULES_IN"; echo 'polkit.addRule(function(action, subject) { return polkit.Result.YES; });'; } \
  > "$TESTTMP/tmpl-tworules"
assert_exit 2 "render refuses a template carrying a second rule block" \
  render_passwordless_rule "$TESTTMP/tmpl-tworules"

# (c) the shipped template → accepted, and what it prints is exactly what should be installed
assert_exit 0 "render accepts the shipped template" \
  render_passwordless_rule "$RULES_IN"
render_passwordless_rule "$RULES_IN" > "$TESTTMP/out-good" 2>/dev/null
grep -qF "subject.user == \"$ME\"" "$TESTTMP/out-good" && echo "ok: rendered for the real username" \
  || { echo "FAIL: username not rendered"; _fail=1; }
grep -qF "$SCOPE" "$TESTTMP/out-good" && echo "ok: rendered rule keeps the scope clause" \
  || { echo "FAIL: rendered rule lost the scope"; _fail=1; }
assert_eq "$(grep -c 'polkit.addRule' "$TESTTMP/out-good")" "1" "exactly one polkit.addRule"
grep -q '@USER@' "$TESTTMP/out-good" && { echo "FAIL: placeholder left unsubstituted"; _fail=1; } \
  || echo "ok: no placeholder survives the render"

# The destination goes to a ROOT install(1) and a ROOT rm. Without a pkexec wrapper (the sandbox)
# both run as the user, and that is the only case in which the test setting KEMPT_RULES_DST is
# honoured, and then only for an absolute *.rules path. These rejections happen before anything runs.
assert_exit 2 "enable rejects a destination that is not a .rules file" \
  env KEMPT_RULES_DST="$TESTTMP/notrules" "$KEMPT" enable-passwordless
assert_exit 2 "enable rejects a relative destination" \
  env KEMPT_RULES_DST="relative/49-kempt.rules" "$KEMPT" enable-passwordless
assert_exit 2 "enable-passwordless takes no arguments" \
  env KEMPT_RULES_DST="$TESTTMP/absent.rules" "$KEMPT" enable-passwordless --force

# Through pkexec the destination is fixed, and the test setting is refused outright. A recording
# stand-in shows what root would have been asked to do, and for every destination below the answer
# must be nothing. The list is where a root-owned .rules file does harm: the other three polkit rules
# directories, a file the distribution ships, a udev rules directory, a path that walks out with
# `..`, places outside any system prefix, and a user-writable directory, which a same-user process
# could swap for a symlink between any check and the write.
cat > "$TESTTMP/pkexec-record" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TESTTMP/pkexec-calls"
[[ " \$* " == *" /dev/stdin "* ]] && cat >/dev/null
exit 0
STUB
chmod +x "$TESTTMP/pkexec-record"
mkdir -p "$TESTTMP/race/d"
polkit_dst_rejected() {  # path label
  : > "$TESTTMP/pkexec-calls"
  assert_exit 2 "$2" env KEMPT_PKEXEC="$TESTTMP/pkexec-record" KEMPT_RULES_DST="$1" "$KEMPT" enable-passwordless
  grep -q 'invalid rules destination' "$TESTTMP/last_output" \
    && echo "ok: ...and says why ($1)" || { echo "FAIL: no rejection message for $1"; _fail=1; }
  assert_eq "$(wc -l < "$TESTTMP/pkexec-calls")" "0" "...and pkexec is never asked ($1)"
}
polkit_dst_rejected '/root/49-kempt.rules' "through pkexec, a destination in root's home is refused"
polkit_dst_rejected '/srv/49-kempt.rules' "through pkexec, a destination under /srv is refused"
polkit_dst_rejected '/home/other/.49-kempt.rules' "through pkexec, a destination in another user's home is refused"
polkit_dst_rejected "$TESTTMP/race/d/49-kempt.rules" \
  "through pkexec, a destination in a user-writable directory is refused"
polkit_dst_rejected '/etc/polkit-1/rules.d/49-kempt.rules' \
  "through pkexec, the test setting is refused even when it names the real destination"
polkit_dst_rejected '/etc/polkit-1/rules.d/../../cron.d/x.rules' \
  "enable rejects a destination that walks out of the polkit rules directory"
polkit_dst_rejected '/etc/cron.d/49-kempt.rules' \
  "enable rejects a .rules file elsewhere under /etc"
polkit_dst_rejected '/etc/polkit-1/rules.d/sub/49-kempt.rules' \
  "enable rejects a subdirectory of the polkit rules directory"
# The other three directories polkit reads. Kempt pins the admin one; these belong to the
# runtime and to packages, and a root-owned Kempt rule in any of them is a grant nobody would
# think to look for. All three were accepted destinations before this guard.
polkit_dst_rejected '/run/polkit-1/rules.d/49-kempt.rules' \
  "enable rejects polkit's runtime rules directory"
polkit_dst_rejected '/usr/local/share/polkit-1/rules.d/49-kempt.rules' \
  "enable rejects polkit's /usr/local rules directory"
# ...and this one is not hypothetical: 50-default.rules is a file Fedora's polkit package ships,
# so the old guard would have handed root an install(1) that OVERWRITES distribution policy.
polkit_dst_rejected '/usr/share/polkit-1/rules.d/50-default.rules' \
  "enable rejects overwriting the polkit rules file the distribution ships"
# A .rules file is not only a polkit thing. udev reads them too, from a root-owned directory.
polkit_dst_rejected '/usr/lib/udev/rules.d/99-kempt.rules' \
  "enable rejects a udev rules directory, which also takes .rules files"
# ...and with no test setting, pkexec is asked about exactly the fixed path, for both commands.
: > "$TESTTMP/pkexec-calls"
assert_exit 0 "through pkexec, enable installs to the fixed destination" -- \
  env KEMPT_PKEXEC="$TESTTMP/pkexec-record" "$KEMPT" enable-passwordless
assert_eq "$(cat "$TESTTMP/pkexec-calls")" \
  "install -m 0644 -o root -g root /dev/stdin /etc/polkit-1/rules.d/49-kempt.rules" \
  "...and that destination is exactly /etc/polkit-1/rules.d/49-kempt.rules"
: > "$TESTTMP/pkexec-calls"
assert_exit 2 "through pkexec, disable refuses the test setting too" -- \
  env KEMPT_PKEXEC="$TESTTMP/pkexec-record" KEMPT_RULES_DST="$TESTTMP/race/d/49-kempt.rules" "$KEMPT" disable-passwordless
assert_eq "$(wc -l < "$TESTTMP/pkexec-calls")" "0" "...and pkexec is never asked"
assert_exit 0 "through pkexec, disable still works on the fixed destination" -- \
  env KEMPT_PKEXEC="$TESTTMP/pkexec-record" "$KEMPT" disable-passwordless
# The real directory is 0750 root:polkitd, so an unprivileged run cannot look inside it and asks
# root to remove the file. A box where the directory is searchable and the file is absent answers
# "was not enabled" without asking; both are correct, and only the path asked about is pinned.
if [[ -s "$TESTTMP/pkexec-calls" ]]; then
  assert_eq "$(cat "$TESTTMP/pkexec-calls")" "rm -f /etc/polkit-1/rules.d/49-kempt.rules" \
    "...removing exactly /etc/polkit-1/rules.d/49-kempt.rules"
else
  grep -q 'was not enabled' "$TESTTMP/last_output" \
    && echo "ok: ...and reports the fixed destination as not enabled" \
    || { echo "FAIL: disable neither removed the fixed path nor reported it absent"; _fail=1; }
fi

# As root, pkexec is not needed to write anywhere, so the test setting is refused there too. Run
# as EUID 0 in an unprivileged user namespace, without sudo: if the refusal failed, the "root"
# install would land in TESTTMP, where the second assertion finds it.
if [[ $EUID -ne 0 ]] && command -v unshare >/dev/null && timeout 20 unshare --map-root-user true 2>/dev/null; then
  assert_exit 2 "as root, the test setting is refused even with no pkexec wrapper" -- \
    timeout 20 unshare --map-root-user env KEMPT_RULES_DST="$TESTTMP/as-root.rules" "$KEMPT" enable-passwordless
  assert_exit 1 "...and nothing is written there" -- test -e "$TESTTMP/as-root.rules"
else
  skip "as-root destination test - needs an unprivileged user namespace"
fi

# Without a wrapper, the test setting is how this file drives the real install(1). It runs as the
# user, so it fails at `-o root` with exit 1, after the shape check (exit 2) has passed.
assert_exit 1 "without pkexec, a sandbox destination reaches the unprivileged install" \
  env KEMPT_RULES_DST="$TESTTMP/accepted.rules" "$KEMPT" enable-passwordless
grep -q 'invalid rules destination' "$TESTTMP/last_output" \
  && { echo "FAIL: the sandbox destination was rejected"; _fail=1; } \
  || echo "ok: the sandbox destination is accepted"
[[ -e /etc/polkit-1/rules.d/49-kempt.rules ]] \
  && { echo "FAIL: a polkit rule exists in /etc after the suite ran"; _fail=1; } \
  || echo "ok: nothing reached /etc"
assert_exit 2 "disable-passwordless takes no arguments" \
  env KEMPT_RULES_DST="$TESTTMP/absent.rules" "$KEMPT" disable-passwordless --force
# Disabling something that was never enabled is not a failure, and must not raise an auth prompt
# to discover that: nothing is invoked when the destination does not exist.
assert_eq "$(KEMPT_RULES_DST="$TESTTMP/absent.rules" "$KEMPT" disable-passwordless)" \
  "passwordless was not enabled" "disable is a clean no-op when nothing is installed"
# ...but that no-op must never be a GUESS. The real /etc/polkit-1/rules.d is 0750 root:polkitd,
# so an unprivileged existence test reports "absent" for a file that is really there; treating
# that as "nothing to do" would leave a live passwordless grant in place while claiming it was
# never enabled. Unsearchable destination directory → proceed to the removal instead.
mkdir -p "$TESTTMP/locked"; chmod 000 "$TESTTMP/locked"
assert_exit 1 "disable does not guess when the destination directory cannot be searched" \
  env KEMPT_RULES_DST="$TESTTMP/locked/49-kempt.rules" "$KEMPT" disable-passwordless
grep -q 'was not enabled' "$TESTTMP/last_output" \
  && { echo "FAIL: disable claimed 'not enabled' without being able to look"; _fail=1; } \
  || echo "ok: no false 'was not enabled' when the directory cannot be searched"
chmod 755 "$TESTTMP/locked"

# --- root installs the bytes that were checked -----------------------------------------------------
# The authentication dialog can stay open for as long as a person takes to answer it. If the checked
# rule sat in a file of the user's, any process running as the user could rewrite it in that time and
# root would install the new text. So the rule reaches install(1) on stdin, and no file is left for
# anyone to rewrite.
# The stand-in for pkexec plays both sides: it first rewrites every file the command left in TMPDIR
# with a rule that grants everything, then reads its source argument exactly as root's install(1)
# would. It writes nowhere outside TESTTMP.
mkdir -p "$TESTTMP/swap-tmp"
cat > "$TESTTMP/pkexec-swap" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$TESTTMP/swap-argv"
find "$TESTTMP/swap-tmp" -type f -exec sh -c 'printf "polkit.addRule(function(a, s) { return polkit.Result.YES; });\n" > "\$1"' _ {} \;
cat -- "\${@: -2:1}" > "$TESTTMP/swap-installed"
STUB
chmod +x "$TESTTMP/pkexec-swap"
assert_exit 0 "enable-passwordless succeeds through a pkexec that reads its source as root would" -- \
  env TMPDIR="$TESTTMP/swap-tmp" KEMPT_PKEXEC="$TESTTMP/pkexec-swap" "$KEMPT" enable-passwordless
assert_eq "$(cat "$TESTTMP/swap-argv")" \
  "install -m 0644 -o root -g root /dev/stdin /etc/polkit-1/rules.d/49-kempt.rules" \
  "root's install(1) reads the rule from stdin, not from a file path"
if cmp -s "$TESTTMP/out-good" "$TESTTMP/swap-installed"; then
  echo "ok: ...and what it installs is byte for byte the rule that was checked, after a same-user rewrite"
else
  echo "FAIL: root would install something other than the checked rule"; _fail=1
  sed 's/^/    /' "$TESTTMP/swap-installed"
fi
assert_eq "$(find "$TESTTMP/swap-tmp" -type f | wc -l)" "0" "...and no rendered file is left in TMPDIR to rewrite"

# Production path through the documented seams: no pkexec wrapper (sandbox exports it empty),
# destination and mktemp both inside TESTTMP, hostile USER in the environment. /etc is never a
# target. The install step fails (a non-root user cannot -o root) after GNU install has already
# written the bytes, so the sandboxed destination holds exactly what would have been installed.
out="$(TMPDIR="$TESTTMP" KEMPT_RULES_DST="$TESTTMP/rules-out.rules" USER='x/;s/subject.active/true/;s/QQQ/' \
       "$KEMPT" enable-passwordless 2>"$TESTTMP/pw-err")" || true
assert_eq "$out" "" "unprivileged enable-passwordless never claims success"
[[ -f "$TESTTMP/rules-out.rules" ]] && echo "ok: production render reached the destination" \
  || { echo "FAIL: no render artifact to inspect"; _fail=1; }
grep -qF "subject.user == \"$ME\"" "$TESTTMP/rules-out.rules" \
  && echo "ok: rendered rule names id -un, not \$USER" || { echo "FAIL: USER env reached the render"; _fail=1; }
grep -qF "$SCOPE" "$TESTTMP/rules-out.rules" && echo "ok: installed render keeps the scope clause" \
  || { echo "FAIL: installed render lost the scope"; _fail=1; }
finish
