#!/usr/bin/env bash
# Does kempt-apply report the truth when a package step disturbs the message bus? systemd-run --wait
# hears over the bus: with reexec it hung after dnf5 had finished, and with broker it returned 0 while
# dnf5 ran on. The helper reads the service's own record instead, and this checks that it still does.
#
# As root in a Fedora VM you are willing to lose, with Kempt installed. One case per boot, because a
# restarted broker slows every later dnf5 until the next restart. It adds a repository and updates
# everything the VM has waiting. Not part of tests/run_tests.sh: it needs a real bus.
#
#   KEMPT_GATE_I_MEAN_IT=1 tests/live/bus-check.sh reexec <account with a running user manager>
#   KEMPT_GATE_I_MEAN_IT=1 tests/live/bus-check.sh broker
set -euo pipefail
[[ -n "${KEMPT_GATE_I_MEAN_IT:-}" && $EUID -eq 0 ]] || { echo "bus-check: as root in a VM you can lose, with KEMPT_GATE_I_MEAN_IT=1" >&2; exit 2; }
case "${1:-}" in
  reexec) step="/usr/bin/systemctl --machine=${2:?which account}@.host --user daemon-reexec" ;;
  broker) step="/usr/bin/systemctl restart dbus-broker" ;;
  *) echo "usage: bus-check.sh reexec ACCOUNT|broker" >&2; exit 2 ;;
esac

n=kempt-bus-check d=/var/tmp/$n conf=/etc/yum.repos.d/$n.repo mark=/var/tmp/$n.done
cleanup() { rpm -e --noscripts "$n" >/dev/null 2>&1 || true; rm -rf "$d" "$conf" "$mark"; }
trap cleanup EXIT
cleanup
mkdir -p "$d/top" "$d/repo"
build() {
  printf 'Name: %s\nVersion: %s\nRelease: 1\nSummary: t\nLicense: MIT\nBuildArch: noarch\n%%description\nt\n%s\n%%files\n' "$n" "$1" "$2" > "$d/$1.spec"
  rpmbuild -bb --quiet --define "_topdir $d/top" --define "_rpmdir $d/repo" "$d/$1.spec" 2>/dev/null
}
build 1 ""
rpm -i --quiet "$d"/repo/noarch/$n-1-1.noarch.rpm
rm "$d"/repo/noarch/$n-1-1.noarch.rpm
build 2 "%pre
echo pre start; $step; echo pre step rc=\$?; sleep 3; touch $mark"
createrepo_c -q "$d/repo"
printf '[%s]\nname=t\nbaseurl=file://%s/repo\ngpgcheck=0\nmetadata_expire=0\n' "$n" "$d" > "$conf"
dnf5 -q makecache --refresh >/dev/null

rc=0 start=$SECONDS
timeout 400 /usr/libexec/kempt-apply dnf-upgrade -y </dev/null >"$d/out" 2>&1 || rc=$?
took=$((SECONDS - start)) running="$(pgrep -x dnf5 || true)" have="$(rpm -q --qf '%{VERSION}' "$n")"
echo "$1: helper rc=$rc after ${took}s; dnf5 still running: ${running:-no}; package version $have; %pre finished: $([[ -e $mark ]] && echo yes || echo no)"
[[ $rc -eq 0 && -z "$running" && "$have" == 2 && -e "$mark" ]] || { echo "bus-check: FAIL"; tail -5 "$d/out"; exit 1; }
echo "bus-check: pass"
