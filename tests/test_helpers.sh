#!/usr/bin/env bash
# The two root helpers, run for real against a stand-in tree: dnf5 and systemd-run are recording
# scripts, and every path the helpers read is under $T. A helper reads that tree only when it is not
# root, so a suite run as root must not run them at all: as root they would reach the real dnf5.
source "$(dirname "$0")/lib.sh"; sandbox
exec </dev/null
if (( EUID == 0 )); then echo "ok: skipped as root, where the helpers ignore the stand-in tree"; exit 0; fi
RH="$REPO_ROOT/libexec/kempt-refresh"
AH="$REPO_ROOT/libexec/kempt-apply"
FIX="$FIXTURES"

make_tree() {  # dir → a tree shaped like the real one, with recording stand-ins for dnf5 and systemd-run
  local t="$1"
  mkdir -p "$t/usr/bin" "$t/var/cache/libdnf5" "$t/usr/lib/sysimage/libdnf5/offline" "$t/var/lib/dnf/offline"
  # The stand-in runs what follows `--`, as the real one does for a scope. -p, so that a BASH_ENV
  # reaching this stand-in cannot look as if it had reached the helper.
  cat > "$t/usr/bin/systemd-run" <<EOF
#!/bin/bash -p
printf '%s\n' "\$@" > "$t/run.argv"
while [[ "\$1" != -- ]]; do shift; done; shift
exec "\$@"
EOF
  cat > "$t/usr/bin/dnf5" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$t/dnf5.argv"
env -0 | LC_ALL=C sort -z | tr '\0' '\n' | grep -vE '^(_|PWD|SHLVL)=' > "$t/dnf5.env"
umask > "$t/dnf5.umask"
pwd > "$t/dnf5.cwd"
grep -E '^(SigIgn):' /proc/\$\$/status > "$t/dnf5.sig"
ulimit -f > "$t/dnf5.fsize"; ulimit -c > "$t/dnf5.core"; ulimit -n > "$t/dnf5.nofile"
echo "dnf5 on stdout"; echo "dnf5 on stderr" >&2
exit "\$(cat "$t/dnf5.rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$t/usr/bin/systemd-run" "$t/usr/bin/dnf5"
}
T="$TESTTMP/tree"; make_tree "$T"
export KEMPT_HELPER_ROOT="$T"
ran() { [[ -e "$T/dnf5.argv" ]] && echo ran || echo "did not run"; }
argv() { tr '\n' ' ' < "$T/dnf5.argv" | sed 's/ $//'; }
fresh() { rm -f "$T"/dnf5.* "$T"/run.argv; }
STATE="$T/usr/lib/sysimage/libdnf5"; CACHE="$T/var/cache/libdnf5"; STAGED="$T/var/lib/dnf/offline"
STORED="$STATE/offline/offline-transaction-state.toml"; LINK="$T/system-update"

# --- fixed arguments: nothing a caller adds ever reaches dnf5 --------------------------------------
refused_2() {  # label helper args...
  local label="$1" h="$2"; shift 2; fresh
  assert_exit 2 "$label" -- bash "$h" "$@"
  assert_eq "$(ran)" "did not run" "...and dnf5 did not run"
}
refused_2 "refresh: no verb" "$RH"
refused_2 "refresh: bad verb" "$RH" nuke
refused_2 "refresh: an extra argument" "$RH" check --installroot=/foo
refused_2 "refresh: a trailing empty argument" "$RH" refresh ''
# The no-dialog file must not know an upgrade verb: pkexec picks the action by path, so a verb here
# would be an update with no dialog for any active local user.
for v in dnf-upgrade dnf-offline-stage dnf-offline-arm dnf-offline-clean upgrade; do
  refused_2 "refresh: refuses $v" "$RH" "$v" -y
done
assert_eq "$(grep -vE '^[[:space:]]*#' "$RH" | grep -cE 'upgrade|offline|install|remove|reinstall|distro-sync|swap')" "0" \
  "kempt-refresh's code names no verb that changes packages"
refused_2 "apply: no verb" "$AH"
refused_2 "apply: bad verb" "$AH" rm-rf
refused_2 "apply: the flatpak verb is gone" "$AH" flatpak-update -y
refused_2 "apply: arm takes no arguments" "$AH" dnf-offline-arm -y
refused_2 "apply: clean takes no arguments" "$AH" dnf-offline-clean --installroot=/
for bad in '--installroot=/tmp/x' '--setopt=reposdir=/tmp' 'extra-package' '--' '-foo' '*' '--exclude' \
           '--exclude=' '--exclude=foo;rm -rf /' $'--exclude=a\nb' '--exclude=a b' '--exclude=a/b' \
           '--exclude=-x' '--exclude=*' '--exclude=foo*' '--exclude=שלום'; do
  refused_2 "apply: dnf-upgrade refuses '${bad//$'\n'/\\n}'" "$AH" dnf-upgrade "$bad"
  refused_2 "apply: dnf-offline-stage refuses '${bad//$'\n'/\\n}'" "$AH" dnf-offline-stage "$bad"
done

ok_verb() {  # label want-dnf5-argv helper args...
  local label="$1" want="$2" h="$3"; shift 3; fresh
  assert_exit 0 "$label" -- bash "$h" "$@"
  assert_eq "$(argv)" "$want" "...exact dnf5 command"
}
ok_verb "dnf-upgrade" "upgrade -y --exclude=vim-common --exclude=kernel-core" "$AH" dnf-upgrade -y --exclude=vim-common --exclude=kernel-core
ok_verb "dnf-upgrade with no answer given, so dnf5 can ask" "upgrade" "$AH" dnf-upgrade
ok_verb "dnf-offline-stage" "upgrade --offline -y --exclude=g++" "$AH" dnf-offline-stage -y --exclude=g++
ok_verb "dnf-offline-arm" "offline reboot -y" "$AH" dnf-offline-arm
ok_verb "dnf-offline-clean" "offline clean -y" "$AH" dnf-offline-clean
KEMPT_DNF5_VERSION=5.2.18.0 ok_verb "check on dnf5 5.2 asks for text" "--cacheonly check-update --quiet" "$RH" check
KEMPT_DNF5_VERSION=5.3.9 ok_verb "...and on 5.3.9" "--cacheonly check-update --quiet" "$RH" check
KEMPT_DNF5_VERSION=5.4.0.0 ok_verb "check on dnf5 5.4 asks for JSON" "--cacheonly check-update --quiet --json" "$RH" check
KEMPT_DNF5_VERSION=5.10.0.0 ok_verb "...compared as versions, so 5.10 is newer than 5.4" "--cacheonly check-update --quiet --json" "$RH" check
KEMPT_DNF5_VERSION=garbage ok_verb "...and a version it cannot read gets text" "--cacheonly check-update --quiet" "$RH" check
ok_verb "refresh" "makecache --refresh" "$RH" refresh

# --- how dnf5 starts: a scope, direct exec, HUP and PIPE ignored ------------------------------------
run_argv() { awk '$0 == "--" { exit } { print }' "$T/run.argv" | tr '\n' ' ' | sed 's/ $//'; }
fresh; bash "$AH" dnf-upgrade -y >/dev/null 2>&1
assert_eq "$(run_argv)" "--scope --quiet --collect" "dnf-upgrade runs under a scope, ignoring HUP"
fresh; bash "$RH" refresh >/dev/null 2>&1
assert_eq "$(run_argv)" "--scope --quiet --collect --unit=kempt-refresh-refresh -p RuntimeMaxSec=120 -p TimeoutStopSec=10" \
  "refresh: the same, one at a time, bounded as root"
fresh; bash "$RH" check >/dev/null 2>&1
assert_eq "$(run_argv)" "--scope --quiet --collect --unit=kempt-refresh-check -p RuntimeMaxSec=120 -p TimeoutStopSec=10" \
  "check: the same, one at a time, bounded as root"
for h in "$AH" "$RH"; do
  assert_eq "$(grep -vE '^[[:space:]]*#' "$h" | grep -c 'exec "\$ROOT/usr/bin/systemd-run"')" "1" "${h##*/}: one way to start dnf5, by exec"
done

# The exit status and both output streams are the caller's own. The CLI reads stdout as data.
fresh; echo 100 > "$T/dnf5.rc"
assert_exit 100 "check: dnf5's exit status comes back" -- env KEMPT_DNF5_VERSION=5.2 bash "$RH" check
fresh; echo 1 > "$T/dnf5.rc"
assert_exit 1 "apply: a failed dnf5's exit status comes back" -- bash "$AH" dnf-upgrade -y
fresh; out="$(bash "$RH" check 2>/dev/null)"
assert_eq "$out" "dnf5 on stdout" "check: stderr is not merged into the stdout the CLI parses"
fresh; out="$(bash "$AH" dnf-upgrade -y 2>&1 >/dev/null)"
assert_eq "$out" "dnf5 on stderr" "apply: stderr stays stderr"

# --- what pkexec passes on from the caller never reaches dnf5 ---------------------------------------
# HUP (bit 0) and PIPE (bit 12) are ignored, and everything the caller ignored is back to default.
# QUIT (bit 2) is the stand-in's own: bash ignores it in every script it runs. The real dnf5's mask is
# read from /proc on a real run in the release check's VM log.
WANT_IGN="SigIgn:	0000000000001005"
for h in "$AH" "$RH"; do
  v=dnf-upgrade; [[ "$h" == "$RH" ]] && v=check
  fresh
  ( trap '' TERM INT QUIT USR1; umask 000; ulimit -S -f 1024 -n 64; ulimit -S -c 1024 2>/dev/null || true; cd /tmp
    env -i PATH="$PATH" KEMPT_HELPER_ROOT="$T" KEMPT_DNF5_VERSION=5.2 LD_PRELOAD= BASH_ENV="$TESTTMP/evil" EVIL=1 \
      DNF_SYSTEM_UPGRADE_NO_REBOOT=0 "$h" "$v" >/dev/null 2>&1 ) || true
  n="${h##*/}"
  assert_eq "$(cat "$T/dnf5.umask")" "0022" "$n: the caller's umask 000 does not reach dnf5"
  assert_eq "$(cat "$T/dnf5.cwd")" "/" "$n: nor its directory"
  assert_eq "$(cat "$T/dnf5.sig")" "$WANT_IGN" "$n: nor its ignored signals, and HUP and PIPE are ignored"
  assert_eq "$(cat "$T/dnf5.fsize")" "unlimited" "$n: nor its low file size limit"
  assert_eq "$(cat "$T/dnf5.core")" "0" "$n: core files stay off"
  assert_eq "$(cat "$T/dnf5.nofile")" "4096" "$n: open files are reset"
  assert_eq "$(cut -d= -f1 "$T/dnf5.env" | tr '\n' ' ')" "HOME LC_ALL PATH " "$n: dnf5's environment is these three and nothing else"
  assert_contains "$(cat "$T/dnf5.env")" "PATH=/usr/sbin:/usr/bin:/sbin:/bin" "$n: PATH is pinned"
done
# -p: bash reads no startup file a caller names, and imports no function.
printf 'touch "%s/PWNED"\n' "$TESTTMP" > "$TESTTMP/evil"
fresh; env BASH_ENV="$TESTTMP/evil" 'BASH_FUNC_find%%=() { touch "'"$TESTTMP"'/PWNED"; }' "$AH" dnf-upgrade -y >/dev/null 2>&1 || true
assert_eq "$([[ -e "$TESTTMP/PWNED" ]] && echo yes || echo no)" "no" "apply: BASH_ENV and exported functions are not read"
fresh; env BASH_ENV="$TESTTMP/evil" 'BASH_FUNC_find%%=() { touch "'"$TESTTMP"'/PWNED"; }' "$RH" refresh >/dev/null 2>&1 || true
assert_eq "$([[ -e "$TESTTMP/PWNED" ]] && echo yes || echo no)" "no" "refresh: BASH_ENV and exported functions are not read"
# The file's executable line is what makes that true when pkexec runs it.
assert_eq "$(head -n1 "$AH")" "#!/usr/bin/bash -p" "apply: bash -p by absolute path"
assert_eq "$(head -n1 "$RH")" "#!/usr/bin/bash -p" "refresh: bash -p by absolute path"

# arm must never reboot the box. The switch is in the environment, and for this verb alone.
fresh; bash "$AH" dnf-offline-arm >/dev/null 2>&1
assert_contains "$(cat "$T/dnf5.env")" "DNF_SYSTEM_UPGRADE_NO_REBOOT=1" "arm: dnf5 is told not to reboot"
fresh; bash "$AH" dnf-offline-stage -y >/dev/null 2>&1
assert_not_contains "$(cat "$T/dnf5.env")" "DNF_SYSTEM_UPGRADE_NO_REBOOT" "stage: the switch is set for arm alone"

# --- the test tree exists only for a process that is not root ---------------------------------------
assert_exit 1 "apply: with no stand-in tree a process that is not root stops" -- env -u KEMPT_HELPER_ROOT bash "$AH" dnf-upgrade -y
assert_exit 1 "refresh: the same" -- env -u KEMPT_HELPER_ROOT bash "$RH" refresh
for h in "$AH" "$RH"; do
  assert_eq "$(awk '/^if \(\( EUID \)\); then/ { if ($0 !~ /; fi$/) b = 1; next } b && /^fi$/ { b = 0; next } b { next } /KEMPT_/ && !/^[[:space:]]*#/' "$h" \
    | grep -vc 'if (( EUID )); then ROOT=' )" "0" "${h##*/}: reads no KEMPT_ setting outside the block root never enters"
  assert_eq "$(grep -cE '^(if \(\( EUID \)\); then|ROOT="" OWNER=0 GROUP=0$)' "$h")" "2" "${h##*/}: real paths unless not root"
done
assert_contains "$(cat "$AH")" 'STATE="$ROOT/usr/lib/sysimage/libdnf5" STAGED="$ROOT/var/lib/dnf/offline" CACHE="$ROOT/var/cache/libdnf5"' \
  "apply: the three real folders"
assert_contains "$(cat "$AH")" 'STORED="$STATE/offline/offline-transaction-state.toml" LINK="$ROOT/system-update"' \
  "apply: dnf5's real record and link"
assert_contains "$(cat "$RH")" 'CACHE="$ROOT/var/cache/libdnf5"' "refresh: the real cache"

# --- the stored-upgrade guard ------------------------------------------------------------------------
stored_refused() {  # label: what's at $STORED now
  local v a
  for v in dnf-offline-stage dnf-offline-arm dnf-offline-clean; do
    a=(); [[ "$v" == dnf-offline-stage ]] && a=(-y)
    fresh
    assert_exit 3 "$v is refused over $1" -- bash "$AH" "$v" "${a[@]}"
    assert_contains "$(cat "$TESTTMP/last_output")" "kempt-apply: refusing: a Fedora release upgrade may be stored" "...and says why"
    assert_eq "$(ran)" "did not run" "...and dnf5 did not run"
  done
}
stored_allowed() {
  local v a
  for v in dnf-offline-stage dnf-offline-arm dnf-offline-clean; do
    a=(); [[ "$v" == dnf-offline-stage ]] && a=(-y)
    fresh
    assert_exit 0 "$v is allowed over $1" -- bash "$AH" "$v" "${a[@]}"
    assert_eq "$(ran)" "ran" "...and dnf5 ran"
  done
}
for f in offline-release-upgrade offline-release-upgrade-downloaded offline-release-upgrade-incomplete; do
  cp "$FIX/$f.toml" "$STORED"; stored_refused "$f"
done
for f in offline-ready offline-download-complete offline-identity-staged; do
  cp "$FIX/$f.toml" "$STORED"; stored_allowed "$f"
done
printf 'this is not a transaction-state file\n' > "$STORED"; stored_refused "a file with neither release"
sed 's/^target_releasever = .*/target_releasever = "45\\n"/' "$FIX/offline-ready.toml" > "$STORED"; stored_refused "a release that is not shaped like one"
sed '/^target_releasever/d' "$FIX/offline-ready.toml" > "$STORED"; stored_refused "a file missing one release"
: > "$STORED"; stored_refused "an empty file"
cp "$FIX/offline-ready.toml" "$STORED"; chmod 000 "$STORED"; stored_refused "a file that cannot be read"; chmod 644 "$STORED"; rm -f "$STORED"
ln -s "$TESTTMP/nowhere" "$STORED"; stored_refused "a dangling link"; rm -f "$STORED"
mkdir "$STORED"; stored_refused "a directory"; rmdir "$STORED"
stored_allowed "nothing stored"
# A live update beside a stored release upgrade is what the CLI offers on purpose.
cp "$FIX/offline-release-upgrade.toml" "$STORED"; fresh
assert_exit 0 "dnf-upgrade is allowed beside a stored release upgrade" -- bash "$AH" dnf-upgrade -y
rm -f "$STORED"

# --- the foreign-link guard ---------------------------------------------------------------------------
clean_refused() {
  fresh
  assert_exit 3 "clean is refused when $1" -- bash "$AH" dnf-offline-clean
  assert_contains "$(cat "$TESTTMP/last_output")" "another updater has prepared the next restart" "...and says why"
  assert_eq "$(ran)" "did not run" "...and dnf5 did not run"
}
clean_ok() { fresh; assert_exit 0 "clean goes ahead when $1" -- bash "$AH" dnf-offline-clean; assert_eq "$(ran)" "ran" "...and dnf5 ran"; }
clean_ok "there is no link"
mkdir -p "$T/var/lib/PackageKit"; ln -s "$T/var/lib/PackageKit/prepared-update" "$LINK"; clean_refused "the link is PackageKit's"; rm -f "$LINK"
ln -s /nowhere "$LINK"; clean_refused "the link goes nowhere"; rm -f "$LINK"
: > "$LINK"; clean_refused "it is a plain file"; rm -f "$LINK"
mkdir "$LINK"; clean_refused "it is a directory"; rmdir "$LINK"
ln -s "$STATE/offline" "$LINK"; clean_ok "the link is dnf5's"; rm -f "$LINK"
ln -s usr/lib/sysimage/libdnf5/offline "$LINK"; clean_ok "the link is dnf5's and relative"; rm -f "$LINK"
ln -s "$STATE/offline" "$LINK"; mv "$STATE/offline" "$STATE/offline.away"; clean_ok "the link is dnf5's and its folder is gone"
mv "$STATE/offline.away" "$STATE/offline"; rm -f "$LINK"
# Only clean deletes the link. The others make or keep it.
ln -s /nowhere "$LINK"; fresh; assert_exit 0 "arm does not look at the link: dnf5 itself refuses to replace it" -- bash "$AH" dnf-offline-arm; rm -f "$LINK"

# --- the folder check --------------------------------------------------------------------------------
folder_refused() {  # label folder-var
  local v a d="$2"
  for v in dnf-upgrade dnf-offline-stage dnf-offline-arm; do
    a=(); [[ "$v" != dnf-offline-arm ]] && a=(-y)
    fresh
    assert_exit 3 "$v is refused: $1" -- bash "$AH" "$v" "${a[@]}"
    assert_contains "$(cat "$TESTTMP/last_output")" "kempt-apply: Updates paused for safety: users other than root can change $d. Run kempt doctor for the fix." "...and names the folder"
    assert_eq "$(ran)" "did not run" "...and dnf5 did not run"
  done
}
for d in "$STATE" "$STAGED" "$CACHE"; do
  chmod 777 "$d"; folder_refused "${d##*/} is 777" "$d"; chmod 755 "$d"
  : > "$d/f"; chmod 666 "$d/f"; folder_refused "a file in ${d##*/} is 666" "$d"; rm -f "$d/f"
  mkdir -p "$d/a/b"; chmod 777 "$d/a/b"; folder_refused "a folder deep in ${d##*/} is 777" "$d"; rm -rf "$d/a"
  # A link's mode bits mean nothing, so a link is judged by its owner alone.
  ln -s /etc/passwd "$d/l"; fresh; assert_exit 0 "a link of the right owner in ${d##*/} passes" -- bash "$AH" dnf-upgrade -y; rm -f "$d/l"
done
# Clean is doctor's way out of an unsafe folder, and deletes rather than installs, so it does not stop.
chmod 777 "$CACHE"; fresh; assert_exit 0 "clean is not stopped by the folder check" -- bash "$AH" dnf-offline-clean; chmod 755 "$CACHE"
# Refresh runs root's dnf5 over the same cache, so it refuses alike. It has no business with the others.
for v in check refresh; do
  chmod 777 "$CACHE"; fresh
  assert_exit 3 "refresh $v is refused while the cache is 777" -- bash "$RH" "$v"
  assert_contains "$(cat "$TESTTMP/last_output")" "kempt-refresh: Updates paused for safety: users other than root can change $CACHE. Run kempt doctor for the fix." "...and names it"
  assert_eq "$(ran)" "did not run" "...and dnf5 did not run"
  chmod 755 "$CACHE"
  : > "$CACHE/f"; chmod 666 "$CACHE/f"; fresh
  assert_exit 3 "refresh $v is refused over a 666 file in the cache" -- bash "$RH" "$v"; rm -f "$CACHE/f"
  ln -s /etc/passwd "$CACHE/l"; fresh
  assert_exit 0 "refresh $v passes a link of the right owner in the cache" -- bash "$RH" "$v"; rm -f "$CACHE/l"
  chmod 777 "$STAGED"; fresh
  assert_exit 0 "refresh $v does not look at the staged folder" -- bash "$RH" "$v"; chmod 755 "$STAGED"
done
# A folder that does not exist yet is nothing to check: a first boot has no cache.
mv "$CACHE" "$CACHE.away"; fresh
assert_exit 0 "apply goes on with no cache folder" -- bash "$AH" dnf-upgrade -y
fresh; assert_exit 0 "refresh goes on with no cache folder" -- bash "$RH" refresh
mv "$CACHE.away" "$CACHE"
# find failing is a refusal, with its own words the doctor knows.
mkdir "$STAGED/shut"; chmod 000 "$STAGED/shut"; fresh
assert_exit 3 "a folder that cannot be read is a refusal" -- bash "$AH" dnf-upgrade -y
assert_contains "$(cat "$TESTTMP/last_output")" "kempt-apply: Kempt could not check $STAGED. Run kempt doctor." "...in its own words"
chmod 755 "$STAGED/shut"; rmdir "$STAGED/shut"
mkdir "$CACHE/shut"; chmod 000 "$CACHE/shut"; fresh
assert_exit 3 "refresh: the same" -- bash "$RH" refresh
assert_contains "$(cat "$TESTTMP/last_output")" "kempt-refresh: Kempt could not check $CACHE. Run kempt doctor." "...in its own words"
chmod 755 "$CACHE/shut"; rmdir "$CACHE/shut"

# Foreign owner and foreign group need a second id, so these run where the machine maps a uid range.
# Inside the namespace the tree is owned by 2000:2000 and the helpers run as that, so 2000 stands
# where root stands on a real machine.
if command -v setpriv >/dev/null \
   && timeout 20 unshare --map-auto --map-root-user bash -c 'p="$1/p"; : > "$p" && chown 2000:2000 "$p" && rm -f "$p"' _ "$TESTTMP" 2>/dev/null; then
  N="$TESTTMP/ns"; chmod 755 "$TESTTMP"; mkdir "$N"; make_tree "$N"; mkdir "$N/h"; cp "$AH" "$RH" "$N/h/"
  cat > "$TESTTMP/ns-case.sh" <<'EOS'
#!/bin/bash
# helper verb setup: as namespace root, build the case, run the helper as 2000, say its rc and whether dnf5 ran
N="$1" h="$2" v="$3" setup="$4"; shift 4
chown -R 2000:2000 "$N"
( cd "$N/var/cache/libdnf5" && eval "$setup" )
rc=0; setpriv --reuid=2000 --regid=2000 --clear-groups env KEMPT_HELPER_ROOT="$N" KEMPT_DNF5_VERSION=5.2 "$h" "$v" >/dev/null 2>&1 || rc=$?
echo "$rc $([[ -e "$N/dnf5.argv" ]] && echo ran || echo not)"
rm -f "$N/dnf5.argv"; rm -rf "$N/var/cache/libdnf5"/*
chown -R 0:0 "$N"
EOS
  nscase() { unshare --map-auto --map-root-user bash "$TESTTMP/ns-case.sh" "$N" "$1" "$2" "$3"; }
  for pair in "$N/h/kempt-apply dnf-upgrade" "$N/h/kempt-refresh check"; do
    h="${pair% *}" v="${pair#* }" n="${h##*/}"
    assert_eq "$(nscase "$h" "$v" ': > f; chown 1000:2000 f')" "3 not" "$n $v: a file of another owner stops it"
    assert_eq "$(nscase "$h" "$v" ': > f; chown 2000:1000 f; chmod 664 f')" "3 not" "$n $v: a file another group can write stops it"
    assert_eq "$(nscase "$h" "$v" ': > f; chown 2000:1000 f; chmod 644 f')" "0 ran" "$n $v: a file of another group that it cannot write does not"
    assert_eq "$(nscase "$h" "$v" 'ln -s /etc/passwd l; chown -h 1000:2000 l')" "3 not" "$n $v: a link of another owner stops it"
    assert_eq "$(nscase "$h" "$v" ': > f; chown 2000:2000 f')" "0 ran" "$n $v: the owner's own file does not"
  done
  chmod 755 "$N"
else
  echo "ok: no uid range here, so foreign owner and group cases are skipped"
fi

# --- size: the point of having two small files --------------------------------------------------------
assert_exit 0 "the two root helpers stay within 170 lines between them" -- \
  test "$(cat "$AH" "$RH" | wc -l)" -le 170
