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

# What this script shadows, and where it puts the originals. Named once, so the restore below
# cannot drift away from the lines that do the shadowing.
DNF5_BIN=/usr/bin/dnf5
DNF5_REAL=/usr/bin/dnf5.real
REPOS_DIR=/etc/yum.repos.d
REPOS_BAK=/tmp/repos.bak

# Put both back HOWEVER this script ends: a failed assertion, a Ctrl-C, a killed terminal. The
# restores written inline further down only run when the script reaches them, which is precisely
# not the case worth protecting against. The container is thrown away afterwards, so this is not
# for the container's sake - it is for the run under KEMPT_GATE_I_MEAN_IT, where an exit between
# the shadow and the restore leaves a machine whose dnf5 is renamed and whose every repository
# points at a dead address, with nothing on screen saying so.
gate_restore() {
  [[ -e "$DNF5_REAL" ]] && mv -f "$DNF5_REAL" "$DNF5_BIN"
  [[ -d "$REPOS_BAK" ]] && cp -f "$REPOS_BAK"/*.repo "$REPOS_DIR"/ 2>/dev/null
  # Never the last command's status: in an EXIT trap that is the only thing the reader could
  # mistake for the gate's own verdict.
  return 0
}
trap gate_restore EXIT

ROOT=/opt/kempt
export HOME=/root
export KEMPT_PKEXEC= KEMPT_APPLY_HELPER=$ROOT/libexec/kempt-apply KEMPT_REFRESH_HELPER=$ROOT/libexec/kempt-refresh
export KEMPT_NOTIFY=/tmp/gate-notify
# notify() stays quiet with no desktop session, and this container has none.
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent
# The gate drives Kempt as root inside its container, which Kempt otherwise refuses.
export KEMPT_ALLOW_ROOT=1
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
toml_key() { sed -n "s/^$1 = \"\(.*\)\"/\1/p" "$TOML" 2>/dev/null; }
problem() { jq -r '.offline_stage_problem // "none"' "$STATE/state.json" 2>/dev/null; }
events() { cat "$STATE/events.log" 2>/dev/null || true; }
notes()  { cat /tmp/gate-notifications; }
txnames() { jq -r '.rpms[] | select(.action=="Upgrade" or .action=="Install") | .nevra | sub("\\.[^.]*$";"") | split("-") | .[0:-2] | join("-")' "$TXJSON" 2>/dev/null | sort -u; }
section() { echo; echo "=== $1 ==="; }
# What staging again has to reuse: the downloaded packages by inode, and the bytes this container
# received, which are held against the size of those packages.
stage_rpms() { find "$PKGCACHE" /usr/lib/sysimage/libdnf5/offline -name '*.rpm' -printf '%p %i %T@ %s\n' 2>/dev/null | sort; }
rx_bytes() { awk 'NR > 2 && $1 != "lo:" { s += $2 } END { print s + 0 }' /proc/net/dev; }

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
is "the count is dnf5's own" "$(jq -r .offline_staged.count "$STATE/state.json")" "$(jq '[.rpms[] | select(.action=="Upgrade" or .action=="Install")] | length' "$TXJSON")"
is "...and Kempt wrote no record of its own" "$(ls "$STATE" | grep -c 'offline_staged\|offline-partial')" "0"
has "event: offline staged" "$(events)" "offline staged"
has "notification: ready" "$(notes)" "are ready"
NAME=$(txnames | sed -n 1p); OTHER=$(txnames | sed -n 2p)
echo "  staged: $(txnames | tr '\n' ' ')"

section "S2 hold a staged package: the warning comes from the live transaction"
err=$("$K" hold "dnf:$NAME" 2>&1 >/dev/null); rc=$?
is "hold exits 0" "$rc" "0"
has "warns that the staged update still contains it" "$err" "The staged update still contains $NAME"
has "and offers both remedies" "$err" "kempt unstage (removes it)"
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
    bash -c "umask 077; mkdir -p /tmp/tester/s /tmp/tester/c; $K hold dnf:$NAME 2>&1 >/dev/null")
has "an unprivileged user's hold reads the live transaction too" "$u" "still contains $NAME"

section "S3 rebuild with the hold: the excluded package leaves the transaction"
: > /tmp/gate-notifications
rpms_before=$(stage_rpms)
"$K" update --surface=offline --no-flatpak > /tmp/s3.out 2>&1; rc=$?
is "rebuild exits 0" "$rc" "0"
is "the rebuild downloads nothing new" "$(comm -13 <(printf '%s\n' "$rpms_before") <(stage_rpms))" ""
is "dnf5 says ready again" "$(toml_status)" "ready"
lacks_name "the held package is no longer in dnf5's transaction" "$(txnames)" "$NAME"
has "dnf5's own record carries the exclusion" "$(toml_key cmd_line)" "--exclude=$NAME"
has "event: offline restage names the hold" "$(events)" "offline restage (holds: $NAME)"
"$K" check > /tmp/s3.json 2>/dev/null
is "no conflict left" "$(jq -c '.offline_staged.holds_conflict' /tmp/s3.json)" "[]"
err=$("$K" unhold "dnf:$NAME" 2>&1 >/dev/null)
has "unhold says the stage was built without it" "$err" "was built without $NAME"
err=$("$K" hold "dnf:$NAME" 2>&1 >/dev/null)
is "holding it again is silent: the transaction really lacks it" "$err" ""
"$K" unhold "dnf:$NAME" >/dev/null 2>&1

section "S4 a transaction replaced outside Kempt: described from what dnf5 holds"
dnf5 -y -q upgrade --offline "$OTHER" >/dev/null 2>&1 && DNF_SYSTEM_UPGRADE_NO_REBOOT=1 dnf5 -y -q offline reboot >/dev/null 2>&1
is "the outside stage is armed" "$(toml_status)" "ready"
"$K" check > /tmp/s4.json 2>/dev/null
is "the widget is told what dnf5 holds" "$(jq -r .offline_staged.count /tmp/s4.json)" "$(jq '[.rpms[] | select(.action=="Upgrade" or .action=="Install")] | length' "$TXJSON")"
d=$("$K" doctor 2>&1)
has "doctor describes it" "$d" "on the next restart"
"$K" update --surface=offline --no-flatpak > /tmp/s4.out 2>&1
is "a Kempt rebuild leaves it armed" "$(toml_status)" "ready"

section "S5 rebuild fails on the network: the previous armed stage survives untouched"
# Real dnf5, real failure: hold OTHER so the first stage never downloads its package, then unhold it
# and cut the repositories off. The rebuild needs that one package, cannot get it, and dnf5 fails
# before it has replaced anything - so the previous transaction must still be armed, and Kempt
# must leave it alone.
"$K" hold "dnf:$OTHER" >/dev/null 2>&1
"$K" update --surface=offline --no-flatpak > /tmp/s5a.out 2>&1
is "a stage without $OTHER is armed" "$(toml_status)" "ready"
lacks_name "...and really lacks $OTHER" "$(txnames)" "$OTHER"
at5=$(stat -c %Y "$TOML")
"$K" unhold "dnf:$OTHER" >/dev/null 2>&1
mkdir -p "$REPOS_BAK" && cp "$REPOS_DIR"/*.repo "$REPOS_BAK"/
sed -i -e 's|^metalink=.*|baseurl=http://127.0.0.1:9/|' -e 's|^baseurl=.*|baseurl=http://127.0.0.1:9/|' "$REPOS_DIR"/*.repo
: > /tmp/gate-notifications
"$K" update --surface=offline --no-flatpak > /tmp/s5.out 2>&1; rc=$?
[[ "$rc" != 0 ]] && ok "the rebuild fails" || bad "the rebuild did not fail" "$(tail -3 /tmp/s5.out)"
echo "  on disk after the failed rebuild: toml=$(toml_status) symlink=$([[ -L $LINK ]] && echo present || echo absent)"
is "the previous transaction is still armed" "$(toml_status)" "ready"
[[ -L "$LINK" ]] && ok "the boot symlink still stands" || bad "the boot symlink is gone"
lacks_name "...and it is the same stage, still without $OTHER" "$(txnames)" "$OTHER"
is "no clean was run against it: dnf5's record is the same file" "$(stat -c %Y "$TOML")" "$at5"
has "event: restage failed, previous stage intact" "$(events)" "offline restage failed (previous stage intact)"
has "notification says the previous one still installs" "$(notes)" "The earlier ones are unchanged and still install"
cp "$REPOS_BAK"/*.repo "$REPOS_DIR"/

section "S6 dnf5 replaces the old stage and then fails (simulated): the unwind, with and without a working clean"
# Real dnf5 keeps the old transaction on a download failure (S5). The other outcome, a new stage
# that replaced the old one and then died, is simulated: the wrapper destroys the old transaction
# the way a replace does and then fails, so the toml is absent when Kempt looks.
mv "$DNF5_BIN" "$DNF5_REAL"
cat > "$DNF5_BIN" <<'W'
#!/bin/bash
[[ "$*" == *"upgrade --offline"* && -e /tmp/gate-destroy-old ]] && { /usr/bin/dnf5.real -y -q offline clean >/dev/null 2>&1; echo "gate: the stage died after replacing the old transaction" >&2; exit 1; }
[[ "$*" == *"offline clean"* && -e /tmp/gate-fail-clean ]] && { echo "gate: clean refused" >&2; exit 1; }
[[ "$*" == *"offline reboot"* && -e /tmp/gate-fail-arm ]] && { echo "gate: arm refused" >&2; exit 1; }
exec /usr/bin/dnf5.real "$@"
W
chmod 755 "$DNF5_BIN"
"$K" update --surface=offline --no-flatpak > /tmp/s6a.out 2>&1
is "a fresh stage is armed" "$(toml_status)" "ready"
touch /tmp/gate-destroy-old /tmp/gate-fail-clean; : > /tmp/gate-notifications
"$K" update --surface=offline --no-flatpak > /tmp/s6.out 2>&1; rc=$?
[[ "$rc" != 0 ]] && ok "the rebuild fails" || bad "the rebuild did not fail"
echo "  on disk after the refused clean: toml=$(toml_status) symlink=$([[ -L $LINK ]] && echo present || echo absent)"
has "the notification points at doctor, which names the command" "$(notes)" "See: kempt doctor"
d=$("$K" doctor 2>&1); rc=$?
if [[ "$(toml_status)" == absent && ! -L "$LINK" ]]; then
  # The simulated destroy is a real `offline clean`, so it leaves nothing behind: no toml, no
  # symlink. A stage dnf5 no longer holds has nothing left to report.
  is "doctor passes: nothing left to report" "$rc" "0"
else
  is "something stranded: doctor fails" "$rc" "1"
  has "...and names the clean command" "$d" "dnf5 offline clean"
fi
rm -f /tmp/gate-fail-clean /tmp/gate-destroy-old
"$K" update --surface=offline --no-flatpak > /tmp/s6b.out 2>&1
is "a fresh stage is armed again" "$(toml_status)" "ready"
touch /tmp/gate-destroy-old; : > /tmp/gate-notifications
"$K" update --surface=offline --no-flatpak > /tmp/s6c.out 2>&1; rc=$?
[[ "$rc" != 0 ]] && ok "the rebuild fails" || bad "the rebuild did not fail"
has "event: the destroyed stage was discarded" "$(events)" "offline stage discarded (rebuild failed)"
is "transaction gone" "$(toml_status)" "absent"
[[ -L "$LINK" ]] && bad "boot symlink still standing" || ok "boot symlink gone"
has "notification says what was lost" "$(notes)" "the earlier updates were removed and could not be prepared again"
rm -f /tmp/gate-destroy-old

section "S7 arm failure: the stage is unwound"
touch /tmp/gate-fail-arm; : > /tmp/gate-notifications
"$K" update --surface=offline --no-flatpak > /tmp/s7.out 2>&1; rc=$?
[[ "$rc" != 0 ]] && ok "the run fails" || bad "the run did not fail"
is "transaction unwound" "$(toml_status)" "absent"
has "notification names the arm" "$(notes)" "could not be set to install"
rm -f /tmp/gate-fail-arm

section "S8 a boot link over a transaction that is not set to install"
"$K" update --surface=offline --no-flatpak > /tmp/s8a.out 2>&1
is "armed" "$(toml_status)" "ready"
sed -i 's/^status = "ready"/status = "download-complete"/' "$TOML"
"$K" check >/dev/null 2>&1
is "nothing is published as pending" "$(jq -r '.offline_staged // "absent"' "$STATE/state.json")" "absent"
is "published as lost" "$(problem)" "lost"
d=$("$K" doctor 2>&1); rc=$?
has "doctor: the boot symlink stands over a transaction that is not armed" "$d" "boot symlink"
is "...exit 1" "$rc" "1"
dnf5.real -y -q offline clean >/dev/null 2>&1
"$K" check >/dev/null 2>&1
is "after a real clean nothing is left to say" "$(problem)" "none"

section "S9b staging when every pending update is held"
# `dnf5 upgrade --offline` prints "Nothing to do", exits 0 and stores NOTHING when the transaction
# would be empty. Arming then fails with "No offline transaction is stored", which Kempt used to
# report as "staged but could not arm the restart install" - rc 1 and a FAILED notification over
# the user's own holds doing exactly what they asked. Found on a real machine with one pending
# update held; this pins it against real dnf5.
dnf5 -y -q offline clean >/dev/null 2>&1; rm -f "$LINK"
"$K" check >/dev/null 2>&1
mapfile -t all_pending < <("$K" check 2>/dev/null | jq -r '.backends.dnf.items[].name')
for p in "${all_pending[@]}"; do "$K" hold "dnf:$p" >/dev/null 2>&1; done
echo "  held every pending update: ${#all_pending[@]}"
: > /tmp/gate-notifications
before_n=$(ls -1 "$STATE/history" 2>/dev/null | wc -l)
"$K" update --surface=offline --no-flatpak > /tmp/s9b.out 2>&1; nrc=$?
is "a stage with nothing in it exits 0" "$nrc" "0"
is "...and dnf5 stored no transaction" "$(toml_status)" "absent"
is "...so nothing promises one" "$(jq -r '.offline_staged // "absent"' "$STATE/state.json")" "absent"
has "the event names the reason" "$(events)" "nothing to stage"
has "...and so does the notification" "$(notes)" "has nothing to install"
hasnt "...which does not blame the arm" "$(notes)" "could not be set to install"
hasnt "...and does not promise a restart" "$(notes)" "install on the next restart"
d=$("$K" doctor 2>&1); rc=$?
is "doctor is clean afterwards" "$rc" "0"
for p in "${all_pending[@]}"; do "$K" unhold "dnf:$p" >/dev/null 2>&1; done

section "S10 a ready transaction whose /system-update symlink is gone"
# `ready` with no symlink is a transaction no restart can run, because only `dnf5 offline reboot`
# makes that symlink again. Removing it by hand stands for what PackageKit does.
"$K" update --surface=offline --no-flatpak > /tmp/s10.out 2>&1
is "armed again" "$(toml_status)" "ready"
[[ -L "$LINK" ]] && ok "the symlink is there to remove" || bad "no symlink to remove"
rm -f "$LINK"
: > /tmp/gate-notifications
"$K" check > /dev/null 2>&1
has "announced as a stage no restart will install" "$(notes)" "No restart will install your prepared updates now"
is "published as lost" "$(problem)" "lost"
is "dnf5 still says ready, so this is read from the link" "$(toml_status)" "ready"
is "nothing is published as a pending install" "$(jq -r '.offline_staged // "absent"' "$STATE/state.json")" "absent"
d=$("$K" doctor 2>&1)
has "doctor says to stage again" "$d" "Prepare them again with: kempt update --surface=offline"
# The way back, which is what the widget and the docs offer: stage again over the lost stage. Whether
# that downloads again is measured rather than assumed, because the changelog tells people it does not.
rpms_before=$(stage_rpms); rx_before=$(rx_bytes)
"$K" update --surface=offline --no-flatpak > /tmp/s10-again.out 2>&1
rx_after=$(rx_bytes); rpms_after=$(stage_rpms)
is "staging again arms it" "$(toml_status)" "ready"
[[ -L "$LINK" ]] && ok "...with the symlink back" || bad "staging again left no symlink" "$(tail -3 /tmp/s10-again.out)"
is "...and nothing wrong is left to say" "$(problem)" "none"
rpm_count=$(grep -c . <<<"$rpms_after"); rpm_bytes=$(awk '{ s += $4 } END { print s + 0 }' <<<"$rpms_after")
echo "  measured: $rpm_count packages, $rpm_bytes bytes; received $((rx_after - rx_before)) bytes while staging again"
(( rx_before > 0 )) && ok "the counter saw the first download, so a small number means something" \
  || bad "the receive counter reads zero, so it measures nothing" "$rx_before"
[[ -n "$rpms_before" ]] && ok "there was a download to reuse" || bad "no packages on disk before staging again"
is "staging again keeps the same downloaded files" "$rpms_after" "$rpms_before"
(( rx_after - rx_before < rpm_bytes )) && ok "...and receives less than the packages weigh" \
  || bad "staging again downloaded the packages" "$((rx_after - rx_before)) bytes for $rpm_bytes"
rm -f "$LINK"
"$K" check > /dev/null 2>&1
is "lost again, for the clean below" "$(problem)" "lost"
dnf5 -y -q offline clean >/dev/null 2>&1
"$K" check >/dev/null 2>&1
is "a real clean then leaves nothing to say" "$(problem)" "none"

section "S11 an ordinary dnf5 install under an armed stage disarms it"
# Running `dnf5 install` while an offline transaction is armed removes /system-update and leaves the
# status at `ready`, which is why `ready` is never read alone.
"$K" update --surface=offline --no-flatpak > /tmp/s11.out 2>&1
is "armed" "$(toml_status)" "ready"
[[ -L "$LINK" ]] && ok "...symlink and all" || bad "the stage armed without a symlink" "toml=$(toml_status)"
before_hist=$(ls -1 "$STATE/history" 2>/dev/null | wc -l)
: > /tmp/gate-notifications
dnf5 -y -q install bc >/dev/null 2>&1
is "dnf5 kept the transaction" "$(toml_status)" "ready"
[[ -L "$LINK" ]] && bad "dnf5 left the symlink alone - this scenario is about it not doing that" \
                 || ok "...and silently dropped the boot symlink, which is the whole finding"
"$K" check >/dev/null 2>&1
is "no history entry: no restart happened" "$(ls -1 "$STATE/history" 2>/dev/null | wc -l)" "$before_hist"
hasnt "...and nothing was announced as applied" "$(notes)" "were installed during the restart"
has "the user is told the stage will not install" "$(notes)" "No restart will install your prepared updates now"
is "published as lost" "$(problem)" "lost"
is "...and nothing is published as pending" "$(jq -r '.offline_staged // "absent"' "$STATE/state.json")" "absent"
d=$("$K" doctor 2>&1)
has "doctor names it" "$d" "prepared updates will not install"
dnf5 -y -q offline clean >/dev/null 2>&1
"$K" check >/dev/null 2>&1

section "S12 the package set moves with the arming intact: not an apply either"
# The symlink is restored by hand after the install because S11 just proved dnf5 removes it: what is
# being modelled is any rpm-level change that leaves dnf5's offline state alone. Nothing here has seen
# a restart, so nothing may report one.
"$K" update --surface=offline --no-flatpak > /tmp/s12.out 2>&1
is "armed again" "$(toml_status)" "ready"
link_target=$(readlink "$LINK" 2>/dev/null || echo /var/lib/dnf/offline)
before_hist=$(ls -1 "$STATE/history" 2>/dev/null | wc -l)
: > /tmp/gate-notifications
dnf5 -y -q install patch >/dev/null 2>&1
ln -sfn "$link_target" "$LINK"
is "the stage is still fully armed" "$(toml_status)" "ready"
[[ -L "$LINK" ]] && ok "...symlink included" || bad "the symlink was not restored"
"$K" check >/dev/null 2>&1
is "no history entry was fabricated" "$(ls -1 "$STATE/history" 2>/dev/null | wc -l)" "$before_hist"
hasnt "nothing was announced as applied" "$(notes)" "were installed during the restart"
hasnt "...and nothing was announced as dead either" "$(notes)" "No restart will install"
is "...and dnf5 still holds the transaction" "$(toml_status)" "ready"
dnf5 -y -q offline clean >/dev/null 2>&1
rm -f "$LINK"
"$K" check >/dev/null 2>&1

section "S9 restore"
mv -f "$DNF5_REAL" "$DNF5_BIN"
d=$("$K" doctor 2>&1)
hasnt "doctor: no staged-update failure left" "$(grep -E '^FAIL' <<<"$d")" "prepared updates"
hasnt "doctor: no boot-symlink failure left" "$(grep -E '^FAIL' <<<"$d")" "boot symlink"
grep -E '^FAIL' <<<"$d" | sed 's/^/  doctor (container, expected): /' 

# --- transaction identity, against a real applied transaction -------------------------------------
# `dnf5 offline _execute` is the command dnf5-offline-transaction.service runs at boot. In a
# container it applies the stored transaction, removes the toml, transaction.json and the boot
# symlink, and then exits 1 because there is no D-Bus to ask for the reboot: its exit status is not
# the result, dnf5's record going away is.
# These run last because applying a transaction upgrades dnf5 itself, which the shadowed binary
# S6 installs could not survive.
reported() { jq -r '[.backends.dnf[] | arrays | .[].name] | .[]' "$1" 2>/dev/null | sort -u; }
newest_hist() { ls -1t "$STATE"/history/*.json 2>/dev/null | head -1; }
history_top() { dnf5 history list --json 2>/dev/null | jq 'map(.id) | max // 0'; }

section "S13 the history names the transaction a restart applied"
"$K" check > /tmp/s13.json 2>/dev/null
P1=$(jq -r '.backends.dnf.items[0].name // empty' /tmp/s13.json)
"$K" hold "dnf:$P1" >/dev/null 2>&1   # so the stage command carries an --exclude, like a rebuild
"$K" update --surface=offline --no-flatpak > /tmp/s13a.out 2>&1
is "armed" "$(toml_status)" "ready"
has "dnf5's command carries the hold" "$(toml_key cmd_line)" "--exclude=$P1"
staged13=$(txnames)
before_id=$(history_top)
DBUS_SYSTEM_BUS_ADDRESS=unix:path=/nonexistent dnf5 offline _execute > /tmp/s13-exec.out 2>&1
is "the transaction applied, and dnf5's record went with it" "$(toml_status)" "absent"
applied_id=$(history_top)
(( applied_id > before_id )) && ok "dnf5 recorded it as history entry $applied_id" || bad "no new history entry" "$before_id -> $applied_id"
OUT=""; for p in cpio diffutils file which; do rpm -q "$p" >/dev/null 2>&1 || { OUT=$p; break; }; done
dnf5 -y -q install "$OUT" >/dev/null 2>&1
rpm -q "$OUT" >/dev/null 2>&1 && ok "something else installed $OUT across the same restart" \
                             || bad "the outside install did not happen, so this scenario proves less" "$OUT"
: > /tmp/gate-notifications
"$K" check >/dev/null 2>&1
h=$(newest_hist)
is "reported as the staged update" "$(jq -r .surface "$h")" "offline (applied on reboot)"
is "...naming dnf5's own history entry for it" "$(jq -r '.transaction_id // "absent"' "$h")" "$applied_id"
[[ -n "$(reported "$h")" ]] && ok "...with a report" || bad "the report is empty"
lacks_name "the outside install is not reported as part of the stage" "$(reported "$h")" "$OUT"
is "...and every reported package is one the stage carried" "$(comm -23 <(reported "$h") <(printf '%s\n' "$staged13"))" ""
has "notification: applied" "$(notes)" "were installed during the restart"
"$K" check >/dev/null 2>&1
is "one restart is one notification" "$(grep -c 'were installed during the restart' /tmp/gate-notifications)" "1"
"$K" unhold "dnf:$P1" >/dev/null 2>&1

section "S14 a stage replaced outside Kempt, with no check before the restart: what ran is reported"
# Kempt no longer knows whose stage it was. It says what dnf5's history says ran, by package.
dnf5 -y -q --disablerepo='updates*' downgrade zsh nano >/dev/null 2>&1   # updates to stage again
"$K" check > /tmp/s14.json 2>/dev/null
n14=$(jq -r '.backends.dnf.actionable // 0' /tmp/s14.json)
(( n14 >= 2 )) && ok "$n14 updates to stage" || bad "fewer than 2 pending updates, the scenario needs a set to split" "$n14"
"$K" update --surface=offline --no-flatpak > /tmp/s14a.out 2>&1
is "Kempt's stage is armed" "$(toml_status)" "ready"
X14=$(txnames | sed -n 1p)
dnf5 -y -q offline clean >/dev/null 2>&1
dnf5 -y -q upgrade --offline --exclude="$X14" >/dev/null 2>&1 && DNF_SYSTEM_UPGRADE_NO_REBOOT=1 dnf5 -y -q offline reboot >/dev/null 2>&1
is "the outside stage is armed" "$(toml_status)" "ready"
DBUS_SYSTEM_BUS_ADDRESS=unix:path=/nonexistent dnf5 offline _execute > /tmp/s14-exec.out 2>&1
is "it applied" "$(toml_status)" "absent"
: > /tmp/gate-notifications; n_hist=$(ls -1 "$STATE/history" | wc -l)
"$K" check >/dev/null 2>&1
h=$(newest_hist)
is "one entry for the restart" "$(ls -1 "$STATE/history" | wc -l)" "$((n_hist + 1))"
is "...naming dnf5's row" "$(jq -r '.transaction_id // "absent"' "$h")" "$(history_top)"
lacks_name "...and what that row did, not what Kempt built" "$(reported "$h")" "$X14"

section "S15 a stage replaced outside Kempt and seen before the restart: described, with nothing to say"
dnf5 -y -q --disablerepo='updates*' downgrade zsh nano >/dev/null 2>&1
"$K" update --surface=offline --no-flatpak > /tmp/s15a.out 2>&1
is "Kempt's stage is armed" "$(toml_status)" "ready"
X15=$(txnames | sed -n 1p)
dnf5 -y -q offline clean >/dev/null 2>&1
dnf5 -y -q upgrade --offline --exclude="$X15" >/dev/null 2>&1 && DNF_SYSTEM_UPGRADE_NO_REBOOT=1 dnf5 -y -q offline reboot >/dev/null 2>&1
: > /tmp/gate-notifications
"$K" check >/dev/null 2>&1
is "nothing is announced" "$(notes)" ""
is "the count is what dnf5 now holds" "$(jq -r .offline_staged.count "$STATE/state.json")" "$(jq '[.rpms[] | select(.action=="Upgrade" or .action=="Install")] | length' "$TXJSON")"
DBUS_SYSTEM_BUS_ADDRESS=unix:path=/nonexistent dnf5 offline _execute > /tmp/s15-exec.out 2>&1
"$K" check >/dev/null 2>&1
lacks_name "after the restart the report is what ran" "$(reported "$(newest_hist)")" "$X15"

section "S16 another updater prepares the restart, then installs the same packages"
# What Discover's notifier does through PackageKit: it unlinks /system-update and points it at
# PackageKit's prepared update, leaving dnf5's state at `ready`. dnf5 will not run behind a symlink
# that is not its own, so Kempt's stage is not armed while it stands. The restart then installs
# PackageKit's set, which is often exactly the staged one. That install is modelled by installing
# the staged packages from dnf5's own download, and systemd removing the symlink afterwards.
# Last, because it installs what is pending, and the sections before it need pending updates.
dnf5 -y -q offline clean >/dev/null 2>&1; rm -f "$LINK"
dnf5 -y -q --disablerepo='updates*' downgrade zsh nano >/dev/null 2>&1
"$K" update --surface=offline --no-flatpak > /tmp/s16.out 2>&1
is "armed" "$(toml_status)" "ready"
ln -sfn /var/lib/PackageKit/prepared-update "$LINK"
"$K" check >/dev/null 2>&1
is "behind another updater's symlink nothing is published as pending" \
  "$(jq -r '.offline_staged // "absent"' "$STATE/state.json")" "absent"
is "...and the stage is published as blocked" "$(jq -r '.offline_stage_blocked | type' "$STATE/state.json")" "object"
d=$("$K" doctor 2>&1)
has "doctor says another updater has prepared the restart" "$d" "another updater has prepared the next restart"
"$K" unstage >/dev/null 2>&1; urc=$?
is "unstage refuses while that symlink stands" "$urc" "5"
is "...and dnf5 still holds the stage" "$(toml_status)" "ready"
is "...and the other updater's symlink still stands" "$(readlink "$LINK")" "/var/lib/PackageKit/prepared-update"
mapfile -t s16_rpms < <(jq -r '.rpms[] | select(.action=="Upgrade" or .action=="Install") | .package_path' "$TXJSON")
echo "  installing the ${#s16_rpms[@]} staged packages the way another updater would"
dnf5 -y -q install "${s16_rpms[@]}" >/dev/null 2>&1 || bad "the staged packages did not install"
rm -f "$LINK"
before_hist=$(ls -1 "$STATE/history" 2>/dev/null | wc -l)
: > /tmp/gate-notifications
"$K" check >/dev/null 2>&1
is "with everything already here, nothing is said" "$(notes)" ""
is "...and no entry claims a restart" "$(ls -1 "$STATE/history" 2>/dev/null | wc -l)" "$before_hist"
is "dnf5 still holds the stage it never ran" "$(toml_status)" "ready"
d=$("$K" doctor 2>&1)
has "doctor explains the leftover" "$d" "whose updates are already installed"
hasnt "...and calls nothing unable to install" "$(grep -E '^FAIL' <<<"$d")" "can never install"
"$K" unstage >/dev/null 2>&1
is "with the symlink gone, unstage removes the leftover" "$(toml_status)" "absent"

echo
echo "GATE: $pass ok, $fail FAIL"
(( fail == 0 ))
