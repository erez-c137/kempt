#!/usr/bin/env bash
# The live container gate for the offline lifecycle: stage, arm, hold, rebuild, and the failure
# paths, against REAL dnf5, as root, with no polkit in the way (KEMPT_PKEXEC empty, helpers run
# directly). It deliberately breaks repositories, deletes dnf5's package cache and shadows the
# dnf5 binary to inject failures, so it must only ever run inside the throwaway container that
# tests/live/run-offline-gate.sh creates. NEVER on a real box.
#
# Not part of tests/run_tests.sh: it needs the network, root, and a Fedora image, and it takes
# minutes. It is the house rule "live container run before merging offline work" written down.
set -u

# REFUSED unless this is a throwaway container, and that is a check rather than a sentence now.
# What follows renames /usr/bin/dnf5, empties dnf5's package cache and points every repository at a
# dead address. On a real Fedora machine that is a broken package manager and a lost afternoon, and
# the only thing standing between this file and that was the paragraph above asking politely.
# Three independent signals, any one of which is enough: podman/docker leave /run/.containerenv or
# /.dockerenv, and the runner exports KEMPT_GATE_CONTAINER. KEMPT_GATE_I_MEAN_IT is the deliberate
# override for someone doing this in a VM they are willing to lose.
if [[ ! -e /run/.containerenv && ! -e /.dockerenv
      && -z "${KEMPT_GATE_CONTAINER:-}" && -z "${KEMPT_GATE_I_MEAN_IT:-}" ]]; then
  cat >&2 <<'REFUSE'
kempt: refusing to run the live gate here.

This script breaks the package manager on purpose: it shadows /usr/bin/dnf5, empties dnf5's
package cache and points every repository at a dead address. It is only ever safe in a container
you are about to throw away.

Run it the intended way:   tests/live/run-offline-gate.sh
That builds the container, runs this inside it, and removes it afterwards.
REFUSE
  exit 2
fi

ROOT=/opt/kempt
export HOME=/root
export KEMPT_PKEXEC= KEMPT_APPLY_HELPER=$ROOT/libexec/kempt-apply KEMPT_REFRESH_HELPER=$ROOT/libexec/kempt-refresh
export KEMPT_NOTIFY=/tmp/gate-notify KEMPT_TERMINAL=/bin/true
K=$ROOT/bin/kempt
STATE=$HOME/.local/state/kempt
TOML=/usr/lib/sysimage/libdnf5/offline/offline-transaction-state.toml
TXJSON=/usr/lib/sysimage/libdnf5/offline/transaction.json
LINK=/system-update
PKGCACHE=/var/lib/dnf/offline/packages
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> /tmp/gate-notifications\n' > /tmp/gate-notify; chmod +x /tmp/gate-notify
: > /tmp/gate-notifications
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && echo "  got: $2"; fail=$((fail+1)); }
is()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "'$2' (expected '$3')"; }
has() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1" "$(head -c 300 <<<"$2")"; }
hasnt() { grep -qF -- "$3" <<<"$2" && bad "$1" "$(head -c 300 <<<"$2")" || ok "$1"; }
# For a list of package names, one per line: the whole line must match. `hasnt` matches any
# substring, so holding curl reads as still staged while libcurl is, and dnf5 as still staged while
# dnf5-plugins is.
lacks_name() { grep -qxF -- "$3" <<<"$2" && bad "$1" "$(head -c 300 <<<"$2")" || ok "$1"; }
toml_status() { sed -n 's/^status = "\(.*\)"/\1/p' "$TOML" 2>/dev/null; [[ -f "$TOML" ]] || echo absent; }
marker() { cat "$STATE/offline_staged.json" 2>/dev/null || echo ""; }
events() { cat "$STATE/events.log" 2>/dev/null || true; }
notes()  { cat /tmp/gate-notifications; }
txnames() { jq -r '.rpms[] | select(.action=="Upgrade" or .action=="Install") | .nevra | sub("\\.[^.]*$";"") | split("-") | .[0:-2] | join("-")' "$TXJSON" 2>/dev/null | sort -u; }
section() { echo; echo "=== $1 ==="; }

# The image is rebuilt continuously and is sometimes fully current, in which case there is no
# transaction to stage and every scenario below is vacuous - the gate used to depend, silently, on
# whatever the image happened to be behind on. So make the updates: install the GA build of a few
# packages with the updates repo disabled, and `updates` then has one for each.
for p in zsh nano tree sqlite; do
  dnf5 -y -q --disablerepo='updates*' install "$p" >/dev/null 2>&1
done

section "S0 check (real metadata refresh through the refresh helper)"
"$K" config set include_flatpak false >/dev/null 2>&1   # the image has no flatpak; the gate is about dnf5
mkdir -p /usr/share/polkit-1/actions && cp "$ROOT"/polkit/*.policy /usr/share/polkit-1/actions/
"$K" check > /tmp/s0.json 2>/tmp/s0.err; rc=$?
is "check exits 0" "$rc" "0"
actionable=$(jq -r '.backends.dnf.actionable // 0' /tmp/s0.json)
echo "  pending dnf updates: $actionable"
if (( actionable < 2 )); then echo "FAIL: the image has fewer than 2 pending updates; the gate needs a real transaction"; exit 1; fi
is "no transaction staged yet" "$(toml_status)" "absent"

section "S1 stage + arm"
"$K" update --surface=offline --no-flatpak > /tmp/s1.out 2>&1; rc=$?
is "offline update exits 0" "$rc" "0"
is "dnf5 says ready" "$(toml_status)" "ready"
[[ -L "$LINK" ]] && ok "/system-update symlink stands" || bad "no /system-update symlink"
m=$(marker)
is "marker names come from the transaction" "$(jq -r '.staged_names_source' <<<"$m")" "transaction"
is "marker names equal dnf5's stored transaction" "$(jq -r '.staged_names[]' <<<"$m" | sort -u | tr '\n' ' ')" "$(txnames | tr '\n' ' ')"
is "nothing excluded (no holds)" "$(jq -c '.staged_excluded' <<<"$m")" "[]"
is "marker is private" "$(stat -c %a "$STATE/offline_staged.json")" "600"
has "event: offline staged" "$(events)" "offline staged"
has "notification: staged" "$(notes)" "staged"
NAME=$(jq -r '.staged_names[0]' <<<"$m"); OTHER=$(jq -r '.staged_names[1] // .staged_names[0]' <<<"$m")
echo "  staged: $(txnames | tr '\n' ' ')"

section "S2 hold a staged package: the warning comes from the live transaction"
err=$("$K" hold "dnf:$NAME" 2>&1 >/dev/null); rc=$?
is "hold exits 0" "$rc" "0"
has "warns that the staged update still contains it" "$err" "The staged update still contains $NAME"
has "and offers both remedies" "$err" "sudo dnf5 offline clean"
err=$("$K" hold "dnf:zzz-not-pending-anywhere" 2>&1 >/dev/null)
is "a name absent from the transaction is silent" "$err" ""
"$K" unhold dnf:zzz-not-pending-anywhere >/dev/null 2>&1
"$K" check > /tmp/s2.json 2>/dev/null
is "state.json publishes the conflict" "$(jq -c '.offline_staged.holds_conflict' /tmp/s2.json)" "[\"$NAME\"]"
is "...from the transaction" "$(jq -r '.offline_staged.names_source' /tmp/s2.json)" "transaction"
d=$("$K" doctor 2>&1)
has "doctor names the held package on its info row" "$d" "despite the hold"
mkdir -p /tmp/tester && chown 1000:1000 /tmp/tester
u=$(setpriv --reuid=1000 --regid=1000 --clear-groups env HOME=/tmp/tester KEMPT_STATE_DIR=/tmp/tester/s KEMPT_CONFIG_DIR=/tmp/tester/c \
    bash -c "umask 077; mkdir -p /tmp/tester/s /tmp/tester/c; printf '{\"staged_at\":\"x\",\"boot_id\":\"b\",\"staged\":1,\"armed\":true,\"staged_names\":[\"nothing\"],\"staged_names_source\":\"check\"}\n' > /tmp/tester/s/offline_staged.json; $K hold dnf:$NAME 2>&1 >/dev/null")
has "an unprivileged user's hold reads the live transaction too" "$u" "still contains $NAME"

section "S3 rebuild with the hold: the excluded package leaves the transaction"
: > /tmp/gate-notifications
"$K" update --surface=offline --no-flatpak > /tmp/s3.out 2>&1; rc=$?
is "rebuild exits 0" "$rc" "0"
is "dnf5 says ready again" "$(toml_status)" "ready"
lacks_name "the held package is no longer in dnf5's transaction" "$(txnames)" "$NAME"
m=$(marker)
is "marker records the exclusion" "$(jq -c '.staged_excluded' <<<"$m")" "[\"$NAME\"]"
has "event: offline restage names the hold" "$(events)" "offline restage (holds: $NAME)"
"$K" check > /tmp/s3.json 2>/dev/null
is "no conflict left" "$(jq -c '.offline_staged.holds_conflict' /tmp/s3.json)" "[]"
err=$("$K" unhold "dnf:$NAME" 2>&1 >/dev/null)
has "unhold says the stage was built without it" "$err" "was built without $NAME"
err=$("$K" hold "dnf:$NAME" 2>&1 >/dev/null)
is "holding it again is silent: the transaction really lacks it" "$err" ""
"$K" unhold "dnf:$NAME" >/dev/null 2>&1

section "S4 drift: a transaction replaced outside Kempt"
dnf5 -y -q upgrade --offline "$OTHER" >/dev/null 2>&1 && DNF_SYSTEM_UPGRADE_NO_REBOOT=1 dnf5 -y -q offline reboot >/dev/null 2>&1
is "the outside stage is armed" "$(toml_status)" "ready"
d=$("$K" doctor 2>&1); rc=$?
has "doctor fails: not the one Kempt built" "$d" "not the one Kempt built"
is "...with exit 1" "$rc" "1"
"$K" update --surface=offline --no-flatpak > /tmp/s4.out 2>&1
d=$("$K" doctor 2>&1)
hasnt "a Kempt rebuild clears the drift" "$d" "not the one Kempt built"

section "S5 rebuild fails on the network: the previous armed stage survives untouched"
# Real dnf5, real failure: hold OTHER so the first stage never downloads its package, then unhold it
# and cut the repositories off. The rebuild needs that one package, cannot get it, and dnf5 fails
# before it has replaced anything - so the previous transaction must still be armed, and Kempt
# must leave it alone.
"$K" hold "dnf:$OTHER" >/dev/null 2>&1
"$K" update --surface=offline --no-flatpak > /tmp/s5a.out 2>&1
is "a stage without $OTHER is armed" "$(toml_status)" "ready"
lacks_name "...and really lacks $OTHER" "$(txnames)" "$OTHER"
at5=$(jq -r .staged_at < "$STATE/offline_staged.json")
"$K" unhold "dnf:$OTHER" >/dev/null 2>&1
mkdir -p /tmp/repos.bak && cp /etc/yum.repos.d/*.repo /tmp/repos.bak/
sed -i -e 's|^metalink=.*|baseurl=http://127.0.0.1:9/|' -e 's|^baseurl=.*|baseurl=http://127.0.0.1:9/|' /etc/yum.repos.d/*.repo
: > /tmp/gate-notifications; ev5=$(events | grep -c 'offline marker cleared')
"$K" update --surface=offline --no-flatpak > /tmp/s5.out 2>&1; rc=$?
[[ "$rc" != 0 ]] && ok "the rebuild fails" || bad "the rebuild did not fail" "$(tail -3 /tmp/s5.out)"
echo "  on disk after the failed rebuild: toml=$(toml_status) symlink=$([[ -L $LINK ]] && echo present || echo absent) marker=$([[ -n "$(marker)" ]] && echo present || echo absent)"
is "the previous transaction is still armed" "$(toml_status)" "ready"
[[ -L "$LINK" ]] && ok "the boot symlink still stands" || bad "the boot symlink is gone"
lacks_name "...and it is the same stage, still without $OTHER" "$(txnames)" "$OTHER"
is "the marker is the same marker" "$(jq -r .staged_at < "$STATE/offline_staged.json" 2>/dev/null)" "$at5"
is "no clean was run against it" "$(events | grep -c 'offline marker cleared')" "$ev5"
has "event: restage failed, previous stage intact" "$(events)" "offline restage failed (previous stage intact)"
has "notification says the previous one still installs" "$(notes)" "still installs on the next restart"
cp /tmp/repos.bak/*.repo /etc/yum.repos.d/

section "S6 dnf5 replaces the old stage and then fails (simulated): the unwind, with and without a working clean"
# Real dnf5 keeps the old transaction on a download failure (S5). The other outcome, a new stage
# that replaced the old one and then died, is simulated: the wrapper destroys the old transaction
# the way a replace does and then fails, so the toml is absent when Kempt looks.
mv /usr/bin/dnf5 /usr/bin/dnf5.real
cat > /usr/bin/dnf5 <<'W'
#!/bin/bash
[[ "$*" == *"upgrade --offline"* && -e /tmp/gate-destroy-old ]] && { /usr/bin/dnf5.real -y -q offline clean >/dev/null 2>&1; echo "gate: the stage died after replacing the old transaction" >&2; exit 1; }
[[ "$*" == *"offline clean"* && -e /tmp/gate-fail-clean ]] && { echo "gate: clean refused" >&2; exit 1; }
[[ "$*" == *"offline reboot"* && -e /tmp/gate-fail-arm ]] && { echo "gate: arm refused" >&2; exit 1; }
exec /usr/bin/dnf5.real "$@"
W
chmod 755 /usr/bin/dnf5
"$K" update --surface=offline --no-flatpak > /tmp/s6a.out 2>&1
is "a fresh stage is armed" "$(toml_status)" "ready"
touch /tmp/gate-destroy-old /tmp/gate-fail-clean; : > /tmp/gate-notifications
"$K" update --surface=offline --no-flatpak > /tmp/s6.out 2>&1; rc=$?
[[ "$rc" != 0 ]] && ok "the rebuild fails" || bad "the rebuild did not fail"
echo "  on disk after the refused clean: toml=$(toml_status) symlink=$([[ -L $LINK ]] && echo present || echo absent) marker=$([[ -n "$(marker)" ]] && echo present || echo absent)"
has "notification carries the clean command" "$(notes)" "sudo dnf5 offline clean"
d=$("$K" doctor 2>&1); rc=$?
if [[ "$(toml_status)" == absent && ! -L "$LINK" ]]; then
  # The simulated destroy is a real `offline clean`, so it leaves nothing behind: no toml, no
  # symlink. That is not state (d); it is "the stage is gone", and the run's own follow-up check
  # is right to clear the marker as such rather than keep it for a doctor row with nothing to
  # point at. State (d) proper (a non-ready toml under a standing symlink) is pinned hermetically.
  is "nothing stranded, so the follow-up check cleared the marker as a gone stage" "$(marker)" ""
  has "...and said so" "$(events)" "offline marker cleared (stage gone)"
  is "doctor passes: nothing left to report" "$rc" "0"
else
  [[ -n "$(marker)" ]] && ok "marker KEPT when the clean was refused" || bad "marker removed although the clean was refused"
  is "something stranded: doctor fails" "$rc" "1"
  has "...and names the clean command" "$d" "dnf5 offline clean"
fi
rm -f /tmp/gate-fail-clean /tmp/gate-destroy-old; rm -f "$STATE/offline_staged.json"
"$K" update --surface=offline --no-flatpak > /tmp/s6b.out 2>&1
is "a fresh stage is armed again" "$(toml_status)" "ready"
touch /tmp/gate-destroy-old; : > /tmp/gate-notifications
"$K" update --surface=offline --no-flatpak > /tmp/s6c.out 2>&1; rc=$?
[[ "$rc" != 0 ]] && ok "the rebuild fails" || bad "the rebuild did not fail"
has "event: the destroyed stage was discarded and the marker cleared" "$(events)" "rebuild failed, stage discarded"
is "marker gone" "$(marker)" ""
is "transaction gone" "$(toml_status)" "absent"
[[ -L "$LINK" ]] && bad "boot symlink still standing" || ok "boot symlink gone"
has "notification says what was lost" "$(notes)" "the previous staged update was discarded and could not be rebuilt"
rm -f /tmp/gate-destroy-old

section "S7 arm failure: the stage is unwound"
touch /tmp/gate-fail-arm; : > /tmp/gate-notifications
"$K" update --surface=offline --no-flatpak > /tmp/s7.out 2>&1; rc=$?
[[ "$rc" != 0 ]] && ok "the run fails" || bad "the run did not fail"
is "transaction unwound" "$(toml_status)" "absent"
is "no marker written" "$(marker)" ""
has "notification names the arm" "$(notes)" "could not arm"
rm -f /tmp/gate-fail-arm

section "S8 detour boot: announced once, marker demoted, never cleared"
"$K" update --surface=offline --no-flatpak > /tmp/s8a.out 2>&1
is "armed" "$(toml_status)" "ready"
sed -i 's/^status = "ready"/status = "download-complete"/' "$TOML"
pre=$(jq -r '.pre_snapshot' < "$STATE/offline_staged.json")
( cd "$ROOT" && source lib/common.sh && source backends/dnf.sh && dnf_snapshot > /tmp/gate-now.tsv )
if [[ "$(sha256sum < "$pre")" == "$(sha256sum < /tmp/gate-now.tsv)" ]]; then ok "diagnosis: pre-snapshot equals a fresh snapshot"; else
  bad "diagnosis: pre-snapshot differs from a fresh snapshot of an unchanged box" "$(wc -l < "$pre") vs $(wc -l < /tmp/gate-now.tsv) rows"; fi
command -v cmp >/dev/null && ok "the image has cmp" || echo "note: the image has no cmp (diffutils absent) - the harvest must not need it"
: > /tmp/gate-notifications
KEMPT_BOOT_ID=another-boot "$K" check >/dev/null 2>&1
has "announced" "$(notes)" "can no longer install on a restart"
is "marker demoted" "$(jq -r '.armed' < "$STATE/offline_staged.json")" "false"
n1=$(grep -c 'can no longer install' /tmp/gate-notifications)
KEMPT_BOOT_ID=another-boot "$K" check >/dev/null 2>&1
is "announced once, not twice" "$(grep -c 'can no longer install' /tmp/gate-notifications)" "$n1"
d=$("$K" doctor 2>&1); rc=$?
has "doctor: the boot symlink stands over a transaction that is not armed" "$d" "boot symlink"
is "...exit 1" "$rc" "1"
dnf5.real -y -q offline clean >/dev/null 2>&1
KEMPT_BOOT_ID=another-boot "$K" check >/dev/null 2>&1
is "after a real clean the next check clears the demoted marker" "$(marker)" ""

section "S9b staging when every pending update is held"
# `dnf5 upgrade --offline` prints "Nothing to do", exits 0 and stores NOTHING when the transaction
# would be empty. Arming then fails with "No offline transaction is stored", which Kempt used to
# report as "staged but could not arm the restart install" - rc 1 and a FAILED notification over
# the user's own holds doing exactly what they asked. Found on a real machine with one pending
# update held; this pins it against real dnf5.
dnf5 -y -q offline clean >/dev/null 2>&1; rm -f "$LINK" "$STATE/offline_staged.json"
"$K" check >/dev/null 2>&1
mapfile -t all_pending < <("$K" check 2>/dev/null | jq -r '.backends.dnf.items[].name')
for p in "${all_pending[@]}"; do "$K" hold "dnf:$p" >/dev/null 2>&1; done
echo "  held every pending update: ${#all_pending[@]}"
: > /tmp/gate-notifications
before_n=$(ls -1 "$STATE/history" 2>/dev/null | wc -l)
"$K" update --surface=offline --no-flatpak > /tmp/s9b.out 2>&1; nrc=$?
is "a stage with nothing in it exits 0" "$nrc" "0"
is "...and dnf5 stored no transaction" "$(toml_status)" "absent"
[[ -z "$(marker)" ]] && ok "...so no marker promises one" || bad "a marker was written for an empty stage" "$(marker)"
has "the event names the reason" "$(events)" "nothing to stage"
has "...and so does the notification" "$(notes)" "Nothing to stage"
hasnt "...which does not blame the arm" "$(notes)" "could not arm"
hasnt "...and does not promise a restart" "$(notes)" "install on the next restart"
d=$("$K" doctor 2>&1); rc=$?
is "doctor is clean afterwards" "$rc" "0"
for p in "${all_pending[@]}"; do "$K" unhold "dnf:$p" >/dev/null 2>&1; done

section "S10 a ready transaction whose /system-update symlink is gone"
# Arming is TWO things and Kempt read only one of them. systemd.offline-updates(7): the symlink is
# the mechanism, and systemd removes it once system-update.target has been reached - so `ready`
# with no symlink, across a boot, is a transaction the restart walked past and that no later
# restart can run either, because only `dnf5 offline reboot` makes that symlink again. Every
# surface used to call it a pending install, after every restart, forever.
"$K" update --surface=offline --no-flatpak > /tmp/s10.out 2>&1
is "armed again" "$(toml_status)" "ready"
[[ -L "$LINK" ]] && ok "the symlink is there to remove" || bad "no symlink to remove"
rm -f "$LINK"
: > /tmp/gate-notifications
KEMPT_BOOT_ID=s10-boot "$K" check > /dev/null 2>&1
has "announced as a stage that can no longer install" "$(notes)" "can no longer install on a restart"
is "marker demoted rather than deleted" "$(jq -r '.armed' <<<"$(marker)")" "false"
is "dnf5 still says ready - the demote is Kempt's reading, not dnf5's" "$(toml_status)" "ready"
is "nothing is published as a pending install" "$(jq -r '.offline_staged // "absent"' "$STATE/state.json")" "absent"
d=$("$K" doctor 2>&1); rc=$?
has "doctor names it" "$d" "staged update can never install"
has "...and offers the re-stage" "$d" "kempt update --surface=offline"
is "...exit 1" "$rc" "1"
dnf5 -y -q offline clean >/dev/null 2>&1
KEMPT_BOOT_ID=s10-boot "$K" check >/dev/null 2>&1
is "a real clean then clears the demoted marker" "$(marker)" ""

section "S11 an ordinary dnf5 install under an armed stage disarms it"
# Found by this gate, and it is not in any documentation: running `dnf5 install` while an offline
# transaction is armed REMOVES /system-update and leaves the status at `ready`. The transaction is
# still stored, dnf5 still calls it ready, and no restart will ever run it - only
# `dnf5 offline reboot` makes that symlink again. Kempt read the status and never the symlink, so
# it promised "installs on the next restart" after every restart, forever.
"$K" update --surface=offline --no-flatpak > /tmp/s11.out 2>&1
is "armed" "$(toml_status)" "ready"
[[ -L "$LINK" ]] && ok "...symlink and all" || bad "the stage armed without a symlink" "toml=$(toml_status)"
before_hist=$(ls -1 "$STATE/history" 2>/dev/null | wc -l)
: > /tmp/gate-notifications
dnf5 -y -q install bc >/dev/null 2>&1
is "dnf5 kept the transaction" "$(toml_status)" "ready"
[[ -L "$LINK" ]] && bad "dnf5 left the symlink alone - this scenario is about it not doing that" \
                 || ok "...and silently dropped the boot symlink, which is the whole finding"
KEMPT_BOOT_ID=s11-boot "$K" check >/dev/null 2>&1
is "no history entry was fabricated" "$(ls -1 "$STATE/history" 2>/dev/null | wc -l)" "$before_hist"
hasnt "...and nothing was announced as applied" "$(notes)" "were applied on reboot"
has "the user is told the stage can no longer install" "$(notes)" "can no longer install on a restart"
is "the marker is demoted, not deleted" "$(jq -r '.armed' <<<"$(marker)")" "false"
is "...and nothing is published as pending" "$(jq -r '.offline_staged // "absent"' "$STATE/state.json")" "absent"
d=$("$K" doctor 2>&1); rc=$?
has "doctor names it" "$d" "staged update can never install"
is "...exit 1" "$rc" "1"
dnf5 -y -q offline clean >/dev/null 2>&1
KEMPT_BOOT_ID=s11-boot "$K" check >/dev/null 2>&1

section "S12 the package set moves with the arming intact: not an apply either"
# The other half, and the one the harvest used to get wrong: boot changed + package set moved was
# read as "the stage applied". Applying really does remove the toml, transaction.json and the
# symlink (dnf5 offline _execute), so with all three still there the set moved because something
# else moved it - dnf-automatic, GNOME Software, an rpm installed directly. Harvesting there wrote
# a history entry naming the OTHER tool's packages, announced "Staged updates were applied on
# reboot", and threw away the marker and baseline of a transaction still going to install.
# The symlink is restored by hand after the install because S11 just proved dnf5 removes it: what
# is being modelled here is any rpm-level change that leaves dnf5's offline state alone.
"$K" update --surface=offline --no-flatpak > /tmp/s12.out 2>&1
is "armed again" "$(toml_status)" "ready"
link_target=$(readlink "$LINK" 2>/dev/null || echo /var/lib/dnf/offline)
s12_pre=$(jq -r '.pre_snapshot' <<<"$(marker)")
before_hist=$(ls -1 "$STATE/history" 2>/dev/null | wc -l)
: > /tmp/gate-notifications
dnf5 -y -q install patch >/dev/null 2>&1
ln -sfn "$link_target" "$LINK"
( cd "$ROOT" && source lib/common.sh && source backends/dnf.sh && dnf_snapshot > /tmp/gate-s12.tsv )
if [[ "$(sha256sum < "$s12_pre")" != "$(sha256sum < /tmp/gate-s12.tsv)" ]]; then
  ok "something else really moved the installed set"
else
  bad "the installed set did not move - this scenario proves nothing"
fi
is "the stage is still fully armed" "$(toml_status)" "ready"
[[ -L "$LINK" ]] && ok "...symlink included" || bad "the symlink was not restored"
KEMPT_BOOT_ID=s12-boot "$K" check >/dev/null 2>&1
is "no history entry was fabricated" "$(ls -1 "$STATE/history" 2>/dev/null | wc -l)" "$before_hist"
hasnt "nothing was announced as applied" "$(notes)" "were applied on reboot"
hasnt "...and nothing was announced as dead either" "$(notes)" "can no longer install"
[[ -n "$(marker)" ]] && ok "the armed stage keeps its marker" || bad "the marker of an armed stage was deleted"
is "...still armed" "$(jq -r '.armed' <<<"$(marker)")" "true"
is "...and dnf5 still holds the transaction" "$(toml_status)" "ready"
has "the deferral is recorded" "$(events | grep -i harvest || echo '(no harvest events at all)')" "harvest deferred"
# Once, not once per check: this state lasts until the restart that installs it.
n_def=$(events | grep -c 'harvest deferred' || true)
KEMPT_BOOT_ID=s12-boot "$K" check >/dev/null 2>&1
is "...exactly once" "$(events | grep -c 'harvest deferred' || true)" "$n_def"
dnf5 -y -q offline clean >/dev/null 2>&1
rm -f "$LINK"
KEMPT_BOOT_ID=s12-boot "$K" check >/dev/null 2>&1

section "S9 restore"
mv -f /usr/bin/dnf5.real /usr/bin/dnf5
d=$("$K" doctor 2>&1)
hasnt "doctor: no staged-update failure left" "$(grep -E '^FAIL' <<<"$d")" "staged update"
hasnt "doctor: no boot-symlink failure left" "$(grep -E '^FAIL' <<<"$d")" "boot symlink"
grep -E '^FAIL' <<<"$d" | sed 's/^/  doctor (container, expected): /' 

# --- transaction identity, against a real applied transaction -------------------------------------
# `dnf5 offline _execute` is the command dnf5-offline-transaction.service runs at boot. In a
# container it applies the stored transaction, removes the toml, transaction.json and the boot
# symlink, and then exits 1 because there is no D-Bus to ask for the reboot: its exit status is not
# the result, dnf5's record going away is. The restart is simulated the usual way, KEMPT_BOOT_ID.
# These run last because applying a transaction upgrades dnf5 itself, which the shadowed binary
# S6 installs could not survive.
reported() { jq -r '[.backends.dnf[] | arrays | .[].name] | .[]' "$1" 2>/dev/null | sort -u; }
newest_hist() { ls -1t "$STATE"/history/*.json 2>/dev/null | head -1; }
toml_key() { sed -n "s/^$1 = \"\(.*\)\"/\1/p" "$TOML" 2>/dev/null; }
history_top() { dnf5 history list --json 2>/dev/null | jq 'map(.id) | max // 0'; }

section "S13 the history names the transaction a restart applied"
"$K" check > /tmp/s13.json 2>/dev/null
P1=$(jq -r '.backends.dnf.items[0].name // empty' /tmp/s13.json)
"$K" hold "dnf:$P1" >/dev/null 2>&1   # so the stage command carries an --exclude, like a rebuild
"$K" update --surface=offline --no-flatpak > /tmp/s13a.out 2>&1
is "armed" "$(toml_status)" "ready"
m=$(marker)
is "the marker records dnf5's rpmdb cookie" "$(jq -r '.rpmdb_cookie // "absent"' <<<"$m")" "$(toml_key rpmdb_cookie)"
is "...and the command that built the transaction" "$(jq -r '.cmd_line // "absent"' <<<"$m")" "$(toml_key cmd_line)"
has "...which carries the hold" "$(jq -r '.cmd_line // ""' <<<"$m")" "--exclude=$P1"
staged13=$(jq -r '.staged_names[]' <<<"$m" | sort -u)
before_id=$(history_top)
dnf5 offline _execute > /tmp/s13-exec.out 2>&1
is "the transaction applied, and dnf5's record went with it" "$(toml_status)" "absent"
applied_id=$(history_top)
(( applied_id > before_id )) && ok "dnf5 recorded it as history entry $applied_id" || bad "no new history entry" "$before_id -> $applied_id"
OUT=""; for p in cpio diffutils file which; do rpm -q "$p" >/dev/null 2>&1 || { OUT=$p; break; }; done
dnf5 -y -q install "$OUT" >/dev/null 2>&1
rpm -q "$OUT" >/dev/null 2>&1 && ok "something else installed $OUT across the same restart" \
                             || bad "the outside install did not happen, so this scenario proves less" "$OUT"
: > /tmp/gate-notifications
KEMPT_BOOT_ID=s13-boot "$K" check >/dev/null 2>&1
h=$(newest_hist)
is "harvested as the staged update" "$(jq -r .surface "$h")" "offline (applied on reboot)"
is "...naming dnf5's own history entry for it" "$(jq -r '.transaction_id // "absent"' "$h")" "$applied_id"
[[ -n "$(reported "$h")" ]] && ok "...with a report" || bad "the report is empty"
lacks_name "the outside install is not reported as part of the stage" "$(reported "$h")" "$OUT"
is "...and every reported package is one the stage carried" "$(comm -23 <(reported "$h") <(printf '%s\n' "$staged13"))" ""
has "notification: applied" "$(notes)" "were applied on reboot"
is "marker consumed" "$(marker)" ""
"$K" unhold "dnf:$P1" >/dev/null 2>&1

section "S14 a stage replaced outside Kempt with no check before the restart: not reported as Kempt's"
# The shape transaction identity exists for: `sudo dnf5 offline clean` and a stage of one's own,
# then a restart, with nothing in between that could have noticed.
dnf5 -y -q --disablerepo='updates*' downgrade zsh nano >/dev/null 2>&1   # updates to stage again
"$K" check > /tmp/s14.json 2>/dev/null
n14=$(jq -r '.backends.dnf.actionable // 0' /tmp/s14.json)
(( n14 >= 2 )) && ok "$n14 updates to stage" || bad "fewer than 2 pending updates, the scenario needs a set to split" "$n14"
"$K" update --surface=offline --no-flatpak > /tmp/s14a.out 2>&1
is "Kempt's stage is armed" "$(toml_status)" "ready"
m=$(marker); X14=$(jq -r '.staged_names[0]' <<<"$m")
dnf5 -y -q offline clean >/dev/null 2>&1
dnf5 -y -q upgrade --offline --exclude="$X14" >/dev/null 2>&1 && DNF_SYSTEM_UPGRADE_NO_REBOOT=1 dnf5 -y -q offline reboot >/dev/null 2>&1
is "the outside stage is armed" "$(toml_status)" "ready"
is "...against the same rpmdb cookie Kempt recorded, so the cookie alone cannot tell them apart" "$(toml_key rpmdb_cookie)" "$(jq -r .rpmdb_cookie <<<"$m")"
dnf5 offline _execute > /tmp/s14-exec.out 2>&1
is "it applied" "$(toml_status)" "absent"
: > /tmp/gate-notifications; n_hist=$(ls -1 "$STATE/history" | wc -l)
KEMPT_BOOT_ID=s14-boot "$K" check >/dev/null 2>&1
h=$(newest_hist)
is "one entry for the restart" "$(ls -1 "$STATE/history" | wc -l)" "$((n_hist + 1))"
is "...which says the staged update did not run" "$(jq -r .surface "$h")" "restart (staged update did not run)"
is "...and names no transaction as Kempt's" "$(jq -r '.transaction_id // "absent"' "$h")" "absent"
has "notification: did not run" "$(notes)" "did not run on the restart"
hasnt "...never that it was applied" "$(notes)" "were applied on reboot"
has "event: did not run" "$(events)" "harvest found the staged transaction did not run"
is "marker consumed" "$(marker)" ""

section "S15 a stage replaced outside Kempt and seen before the restart: said once"
dnf5 -y -q --disablerepo='updates*' downgrade zsh nano >/dev/null 2>&1
"$K" update --surface=offline --no-flatpak > /tmp/s15a.out 2>&1
is "Kempt's stage is armed" "$(toml_status)" "ready"
m=$(marker); X15=$(jq -r '.staged_names[0]' <<<"$m"); at15=$(jq -r .staged_at <<<"$m")
is "a check over Kempt's own stage announces nothing" "$(grep -c 'replaced outside Kempt' /tmp/gate-notifications)" "0"
dnf5 -y -q offline clean >/dev/null 2>&1
dnf5 -y -q upgrade --offline --exclude="$X15" >/dev/null 2>&1 && DNF_SYSTEM_UPGRADE_NO_REBOOT=1 dnf5 -y -q offline reboot >/dev/null 2>&1
: > /tmp/gate-notifications
"$K" check >/dev/null 2>&1
has "announced" "$(notes)" "replaced outside Kempt"
has "...naming what differs" "$(events)" "offline stage replaced outside Kempt (command, packages) - announced"
is "the marker records it" "$(jq -r '.replaced // "absent"' <<<"$(marker)")" "true"
is "...and is still the stage Kempt made" "$(jq -r .staged_at <<<"$(marker)")" "$at15"
"$K" check >/dev/null 2>&1
is "said once, not once per check" "$(grep -c 'replaced outside Kempt' /tmp/gate-notifications)" "1"
dnf5 offline _execute > /tmp/s15-exec.out 2>&1
KEMPT_BOOT_ID=s15-boot "$K" check >/dev/null 2>&1
is "after the restart it is not reported as Kempt's" "$(jq -r .surface "$(newest_hist)")" "restart (staged update did not run)"
is "marker consumed" "$(marker)" ""

echo
echo "GATE: $pass ok, $fail FAIL"
(( fail == 0 ))
