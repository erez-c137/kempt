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
toml_status() { sed -n 's/^status = "\(.*\)"/\1/p' "$TOML" 2>/dev/null; [[ -f "$TOML" ]] || echo absent; }
marker() { cat "$STATE/offline_staged.json" 2>/dev/null || echo ""; }
events() { cat "$STATE/events.log" 2>/dev/null || true; }
notes()  { cat /tmp/gate-notifications; }
txnames() { jq -r '.rpms[] | select(.action=="Upgrade" or .action=="Install") | .nevra | sub("\\.[^.]*$";"") | split("-") | .[0:-2] | join("-")' "$TXJSON" 2>/dev/null | sort -u; }
section() { echo; echo "=== $1 ==="; }

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
hasnt "the held package is no longer in dnf5's transaction" "$(txnames)" "$NAME"
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

section "S5 stage failure over an armed stage (repos unreachable, cache emptied)"
mkdir -p /tmp/repos.bak && cp /etc/yum.repos.d/*.repo /tmp/repos.bak/
sed -i -e 's|^metalink=.*|baseurl=http://127.0.0.1:9/|' -e 's|^baseurl=.*|baseurl=http://127.0.0.1:9/|' /etc/yum.repos.d/*.repo
rm -f "$PKGCACHE"/*.rpm 2>/dev/null
: > /tmp/gate-notifications
"$K" update --surface=offline --no-flatpak > /tmp/s5.out 2>&1; rc=$?
[[ "$rc" != 0 ]] && ok "the rebuild fails" || bad "the rebuild did not fail" "$(tail -3 /tmp/s5.out)"
has "event: the destroyed stage was discarded and the marker cleared" "$(events)" "rebuild failed, stage discarded"
is "marker gone" "$(marker)" ""
is "transaction gone (clean ran)" "$(toml_status)" "absent"
[[ -L "$LINK" ]] && bad "boot symlink still standing" || ok "boot symlink gone"
has "notification says what was lost" "$(notes)" "the previous staged update was discarded and could not be rebuilt"
cp /tmp/repos.bak/*.repo /etc/yum.repos.d/

section "S6 stage failure AND clean failure (state d): the marker is kept for doctor"
mv /usr/bin/dnf5 /usr/bin/dnf5.real
cat > /usr/bin/dnf5 <<'W'
#!/bin/bash
[[ "$*" == *"offline clean"* && -e /tmp/gate-fail-clean ]] && { echo "gate: clean refused" >&2; exit 1; }
[[ "$*" == *"offline reboot"* && -e /tmp/gate-fail-arm ]] && { echo "gate: arm refused" >&2; exit 1; }
exec /usr/bin/dnf5.real "$@"
W
chmod 755 /usr/bin/dnf5
"$K" update --surface=offline --no-flatpak > /tmp/s6a.out 2>&1
is "a fresh stage is armed" "$(toml_status)" "ready"
sed -i -e 's|^metalink=.*|baseurl=http://127.0.0.1:9/|' -e 's|^baseurl=.*|baseurl=http://127.0.0.1:9/|' /etc/yum.repos.d/*.repo
rm -f "$PKGCACHE"/*.rpm 2>/dev/null; touch /tmp/gate-fail-clean
: > /tmp/gate-notifications
"$K" update --surface=offline --no-flatpak > /tmp/s6.out 2>&1; rc=$?
[[ "$rc" != 0 ]] && ok "the rebuild fails" || bad "the rebuild did not fail"
[[ -n "$(marker)" ]] && ok "marker KEPT when the clean failed" || bad "marker removed although the clean failed"
has "notification carries the clean command" "$(notes)" "sudo dnf5 offline clean"
d=$("$K" doctor 2>&1); rc=$?
is "doctor fails" "$rc" "1"
has "...and names the clean command" "$d" "dnf5 offline clean"
rm -f /tmp/gate-fail-clean; cp /tmp/repos.bak/*.repo /etc/yum.repos.d/
dnf5.real -y -q offline clean >/dev/null 2>&1; rm -f "$STATE/offline_staged.json"

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

section "S9 restore"
mv -f /usr/bin/dnf5.real /usr/bin/dnf5
d=$("$K" doctor 2>&1)
hasnt "doctor: no staged-update failure left" "$(grep -E '^FAIL' <<<"$d")" "staged update"
hasnt "doctor: no boot-symlink failure left" "$(grep -E '^FAIL' <<<"$d")" "boot symlink"
grep -E '^FAIL' <<<"$d" | sed 's/^/  doctor (container, expected): /' 
echo
echo "GATE: $pass ok, $fail FAIL"
(( fail == 0 ))
