#!/usr/bin/env bash
# The root helper's checks on dnf's folders and every folder above them, run as root in a user
# namespace against a small tree shaped like the real one. The helper's seams are honoured there,
# because that uid map is not the full identity and this copy is not at a path polkit binds to;
# the seam rule itself is tested at the end, at the paths polkit does bind to.
source "$(dirname "$0")/lib.sh"
sandbox

AH="$REPO_ROOT/libexec/kempt-apply"
K="$REPO_ROOT/bin/kempt"
R="$TESTTMP/root"
STATE="$R/usr/lib/sysimage/libdnf5"; STAGED="$R/var/lib/dnf/offline"; CACHE="$R/var/cache/libdnf5"
export KEMPT_DNF_SYSIMAGE_DIR="$STATE" KEMPT_DNF_OFFLINE_PKG_DIR="$STAGED" KEMPT_DNF_CACHE_DIR="$CACHE"
export KEMPT_DNF_PARENTS_TOP="$R" KEMPT_APPLY_ECHO=1 KEMPT_ALLOW_ROOT=1

UNSAFE="Updates paused for safety: users other than root can change"
ATOMIC="Kempt does not update atomic Fedora (Kinoite, Silverblue, bootc image mode); use Discover, rpm-ostree or bootc upgrade."

# ---------------------------------------------------------------------------------------------------
# What needs no namespace: the seam rule's map test, and the two walkers side by side.
# ---------------------------------------------------------------------------------------------------
eval "$(sed -n '/^uid_map_is_identity() {/,/^}/p' "$AH")"
assert_exit 0 "the full identity map is real root's" -- uid_map_is_identity "         0          0 4294967295"
assert_exit 0 "...and so is no map at all, so a missing file honours no seam" -- uid_map_is_identity ""
assert_exit 1 "an unprivileged namespace's map is not" -- uid_map_is_identity "         0       1000          1"
assert_exit 1 "...nor a map that stops short of the whole range" -- uid_map_is_identity "         0          0 65536"
assert_exit 1 "...nor one of several lines" -- uid_map_is_identity $'         0          0 4294967295\n         1     100000      65536'

# Every setting but the print-only one is read inside the block real root never enters.
assert_eq "$(awk '/^if \(\( SEAMS \)\); then$/ { inb = 1 } inb && /^fi$/ { inb = 0; next }
                  !inb && /\$\{?KEMPT_/ && !/KEMPT_APPLY_ECHO/ && !/^if \(\( SEAMS \)\) && / && !/^[[:space:]]*#/' "$AH")" "" \
  "kempt-apply reads no KEMPT_ setting outside the seam block"
assert_eq "$(grep -cE '^[[:space:]]*load_mounts$' "$AH")" "1" "the mount table is loaded at one place, once per run"
assert_eq "$(sed -n 's/^POLKIT_PATHS=(\(.*\))$/\1/p' "$AH")" "/usr/libexec/kempt-apply /usr/local/libexec/kempt-apply" \
  "the helper knows both installed paths"
assert_contains "$(cat "$REPO_ROOT/polkit/io.github.erez_c137.kempt.policy")" ">/usr/local/libexec/kempt-apply<" \
  "...and the polkit action binds the first of them from a checkout install"
assert_contains "$(cat "$REPO_ROOT/kempt.spec")" 'install -p -D -m 0755 libexec/kempt-apply   %{buildroot}%{_libexecdir}/kempt-apply' \
  "...and the RPM installs to the other"

# One tree, both walkers. The doctor's list stops before the last name, and the helper's goes on to it.
W="$TESTTMP/walk"; mkdir -p "$W/real/deep/dir" "$W/srv"
ln -s real "$W/rel"; ln -s "$W/real" "$W/abs"; ln -s rel "$W/chain"; ln -s ../real "$W/srv/up"
ln -s real/deep/../deep "$W/dots"; ln -s missing "$W/dangling"
mkdir "$W/$(printf 'nl\nname')"; ln -s "$(printf 'nl\nname\n')" "$W/tonl"; mkdir "$W/$(printf 'nl\nname\n')x" 2>/dev/null || true
ln -s selfloop "$W/selfloop"
walker_names() {  # path → the names the helper's walker checks, NUL-separated
  (
    # shellcheck disable=SC2329
    check_name() { printf '%s\0' "$1"; NAME_TYPE=d; [[ -L "$1" ]] && NAME_TYPE=l; return 0; }
    refuse_could_not_check() { printf '%s\0' //hops; exit 0; }
    eval "$(sed -n '/^walk_path() {/,/^}$/p' "$AH")"
    walk_path "$1"
  )
}
doctor_names() {
  (
    eval "$(sed -n '/^doctor_dnf_path_names() {$/,/^}$/p' "$K")"
    doctor_dnf_path_names "$1"
  )
}
joined() { local -a a; mapfile -d '' -t a; local IFS='|'; printf '%s' "${a[*]}"; }
for p in real/deep/dir rel/deep/dir abs/deep/dir chain/deep srv/up/deep dots/dir dangling/x tonl/y nothing/at/all selfloop/z rel/../srv; do
  w="$(walker_names "$W/$p" | joined)"
  d="$(doctor_names "$W/$p" | joined)"
  [[ "$w" == *'|//hops' ]] || w="${w%|*}"
  assert_eq "$w" "$d" "both walkers take the same steps through $p"
done
assert_contains "$(walker_names "$W/selfloop/z" | joined)" '//hops' "premise: a link loop is what the last comparison walked"

# ---------------------------------------------------------------------------------------------------
if ! timeout 20 unshare --map-auto --map-root-user --mount true 2>/dev/null; then
  skip "no user namespaces here, so the root-side folder checks did not run"
  finish
  exit 0
fi
if timeout 20 unshare --map-auto --map-root-user bash -c 'f=$(mktemp) && chown 1000:1000 "$f"; r=$?; rm -f "$f"; exit $r' 2>/dev/null; then
  other_ids() { :; }
else
  other_ids() { skip "no spare user ids in this namespace, so this case did not run: $1"; return 1; }
fi

# Written into each namespace run. Setups run in $R with these at hand.
PRELUDE='
mkdir -p "$R" && cd "$R" || exit 9
mkdir -p usr/lib/sysimage/libdnf5 var/lib/dnf/offline var/cache/libdnf5/repo/packages srv
chmod -R 755 .
mi="$R/mountinfo"; printf "1 0 0:1 / / rw - ext4 /dev/root rw\n" > "$mi"; export KEMPT_MOUNTINFO="$mi"
mount_at() { printf "2 1 0:2 / %s rw - %s src %s\n" "$1" "$2" "$3" >> "$mi"; }
fuse_at() { mount_at "$1" "${2:-fuse.sshfs}" "rw,user_id=${3:-1000},group_id=1000"; }
fail_stub() {  # path tool message [times] [status] → a stand-in that fails on that path, the first times if given, and is otherwise the tool
  local s="$R/stub-$2" n="$R/stub-$2.count"
  : > "$n"
  { printf "%s\n" "#!/bin/bash" "for a; do if [[ \"\$a\" == \"$1\" ]]; then"
    [[ -z "${4:-}" ]] || printf "%s\n" "  c=\$(wc -l < $n); echo x >> $n; if (( c >= $4 )); then exec /usr/bin/$2 \"\$@\"; fi"
    [[ -z "$3" ]] || printf "%s\n" "  echo \"$2: \$a: $3\" >&2"
    printf "%s\n" "  exit ${5:-1}; fi; done" "exec /usr/bin/$2 \"\$@\""
  } > "$s"
  chmod 755 "$s"; echo "$s"
}
'
OUT="" RC=0
in_ns() {  # command-for-after-setup setup [env...] → OUT, RC
  local after="$1" setup="$2" tail; shift 2
  OUT="$(timeout 120 unshare --map-auto --map-root-user --mount env "$@" R="$R" AH="$AH" K="$K" PRELUDE="$PRELUDE" bash -c '
    eval "$PRELUDE"
    eval "$1" || { echo "setup failed"; echo "rc=9"; rm -rf "$R"; exit 0; }
    cd / || exit 9
    rc=0; eval "$2" 2>&1 || rc=$?
    cd /; rm -rf "$R"; echo "rc=$rc"' _ "$setup" "$after" 2>&1)" || true
  tail="${OUT##*$'\n'}"
  RC="${tail#rc=}"
}
apply() { local verb="$1" setup="$2"; shift 2; in_ns "bash \"\$AH\" $verb" "$setup" "$@"; }

refuses() {  # title verb setup sentence [env...]
  local title="$1" verb="$2" setup="$3" want="$4"; shift 4
  apply "$verb" "$setup" "$@"
  assert_eq "$RC" "3" "$title"
  assert_contains "$OUT" "$want" "...in its own words"
  assert_not_contains "$OUT" "/usr/bin/dnf5" "...and starts nothing"
}
passes() {  # title verb setup [env...]
  local title="$1" verb="$2" setup="$3"; shift 3
  apply "$verb" "$setup" "$@"
  assert_eq "$RC" "0" "$title"
  assert_contains "$OUT" "/usr/bin/dnf5" "...and reaches dnf5's line"
}

passes "a stock tree passes" dnf-offline-stage ':'
for v in dnf-upgrade dnf-offline-arm dnf-offline-clean; do
  passes "...for $v too" "$v" ':'
done

# --- before the walk: atomic systems and mount namespaces ---------------------------------------
refuses "an atomic system is refused before anything else" dnf-offline-stage ': > marker' "kempt-apply: $ATOMIC" KEMPT_OSTREE_MARKER="$R/marker"
refuses "...and clean with it" dnf-offline-clean ': > marker' "$ATOMIC" KEMPT_OSTREE_MARKER="$R/marker"
refuses "a different mount namespace is refused" dnf-offline-stage 'ln -s "mnt:[1]" ns1' "different mount namespace from the system" KEMPT_MNT_NS_INIT="$R/ns1"
refuses "...and a namespace that cannot be read has its own sentence" dnf-offline-stage ':' "Kempt could not check the mount namespace" KEMPT_MNT_NS_INIT="$R/no-such-ns"
apply dnf-offline-stage ':' KEMPT_MNT_NS_INIT="$R/no-such-ns" KEMPT_SYSTEMD_BOOTED="$R/no-such-dir"
assert_eq "$RC" "4" "without systemd a container hears that first, with the same exit status as ever"
assert_contains "$OUT" "systemd is not running this system" "...in those words"
assert_not_contains "$OUT" "mount namespace" "...and nothing about namespaces"

# --- root owns it ----------------------------------------------------------------------------
if other_ids "a name another user owns"; then
  refuses "a folder another user owns is refused" dnf-offline-stage 'chown 1000 var/lib' "kempt-apply: $UNSAFE $R/var/lib. Run kempt doctor for the fix."
  refuses "...at the top of the walk" dnf-offline-stage 'chown 1000 usr' "$UNSAFE $R/usr."
  refuses "...and at the leaf" dnf-offline-stage 'chown 1000 usr/lib/sysimage/libdnf5' "$UNSAFE $STATE."
  passes "a group other than root that cannot write passes" dnf-offline-stage 'chown 0:1000 var/lib'
fi

# --- no group or other write, sticky or not --------------------------------------------------
refuses "a world-writable folder is refused" dnf-offline-stage 'chmod 777 var/lib' "$UNSAFE $R/var/lib."
refuses "...with the sticky bit too" dnf-offline-stage 'chmod 1777 var/lib' "$UNSAFE $R/var/lib."
passes "group root may write" dnf-offline-stage 'chmod 775 var/lib'
if other_ids "a group other than root that can write"; then
  refuses "another group may not" dnf-offline-stage 'chown 0:1000 var/lib; chmod 775 var/lib' "$UNSAFE $R/var/lib."
fi
passes "a missing leaf under a safe parent is safe" dnf-offline-stage 'rm -rf var/lib/dnf/offline'
refuses "...and under a writable parent it is not" dnf-offline-stage 'rm -rf var/lib/dnf/offline; chmod 777 var/lib/dnf' "$UNSAFE $R/var/lib/dnf."
passes "a missing branch under a safe parent is safe" dnf-offline-clean 'rm -rf var/lib/dnf'

# --- no ACL entry that grants write ------------------------------------------------------------
if command -v setfacl >/dev/null; then
  refuses "an ACL entry that grants write is refused" dnf-offline-stage 'setfacl -m u:0:rwx var' "$UNSAFE $R/var."
  passes "...but not with a mask that takes the write away" dnf-offline-stage 'setfacl -m u:0:rwx,m::r-x var'
  refuses "...and it is refused again with a mask that keeps it" dnf-offline-stage 'setfacl -m u:0:rwx,m::rwx var; chmod g-w var; setfacl -m m::rwx var' "$UNSAFE $R/var."
  refuses "a group entry counts" dnf-offline-stage 'setfacl -m g:0:rwx var' "$UNSAFE $R/var."
  passes "a read-only entry does not" dnf-offline-stage 'setfacl -m u:0:r-x var'
  refuses "a default entry counts" dnf-offline-stage 'setfacl -m d:u:0:rwx var' "$UNSAFE $R/var."
  passes "...with its own mask applied" dnf-offline-stage 'setfacl -m d:u:0:rwx,d:m::r-x var'
  refuses "a default entry for everyone counts" dnf-offline-stage 'setfacl -m d:o::rwx var' "$UNSAFE $R/var."
else
  skip "setfacl is not installed, so the ACL cases did not run"
fi
refuses "an ACL reading that cannot run refuses, rather than reading as no entries" dnf-offline-stage 'mount --bind /dev/null "$(readlink -f /usr/bin/awk)"' "its ACL entries could not be read"
refuses "with no getfacl the helper refuses" dnf-offline-stage ':' "could not check" KEMPT_GETFACL="$R/no-such-getfacl"
assert_contains "$OUT" "getfacl is missing" "...and says that is why"
refuses "...for clean too" dnf-offline-clean ':' "getfacl is missing" KEMPT_GETFACL="$R/no-such-getfacl"

# --- no user FUSE mount --------------------------------------------------------------------------
FUSEMSG="is on a mount made by a user other than root. Run kempt doctor for the fix."
for t in fuse fuse.sshfs fuseblk; do
  refuses "a $t mount by another user is refused" dnf-offline-stage "fuse_at \"\$R/var\" $t 1000" "$R/var $FUSEMSG"
  passes "...and one root made passes" dnf-offline-stage "fuse_at \"\$R/var\" $t 0"
done
passes "another kind of mount is not looked at" dnf-offline-stage 'mount_at "$R/var" tmpfs rw,user_id=1000'
passes "a mount that does not cover the path passes" dnf-offline-stage 'fuse_at "$R/srv"'
passes "...and neither does one whose name only starts the same" dnf-offline-stage 'fuse_at "$R/var/li"'
refuses "the deepest mount decides" dnf-offline-stage 'fuse_at "$R/var" fuse 0; fuse_at "$R/var/lib"' "$R/var/lib $FUSEMSG"
passes "...and the one on top decides between equals" dnf-offline-stage 'fuse_at "$R/var"; mount_at "$R/var" ext4 rw'
refuses "user_id=0 elsewhere in the options is not root's" dnf-offline-stage 'mount_at "$R/var" fuse rw,user_id=1000,xuser_id=0' "$R/var $FUSEMSG"
refuses "a mount point's octal escapes are decoded" dnf-offline-stage 'mkdir -p "var/my dir/f"; chmod -R 755 var; fuse_at "$R/var/my\040dir"' "$R/var/my dir $FUSEMSG" KEMPT_DNF_CACHE_DIR="$R/var/my dir/f"
refuses "a FUSE mount inside a tree it checks counts" dnf-offline-stage 'fuse_at "$CACHE/repo"' "$CACHE/repo $FUSEMSG" CACHE="$CACHE"
passes "...and a tree it does not check does not" dnf-offline-arm 'fuse_at "$CACHE/repo"' CACHE="$CACHE"
refuses "an unreadable mount table refuses" dnf-offline-stage 'export KEMPT_MOUNTINFO="$R/no-such-table"' "Kempt could not check the mount table (No such file or directory)."
refuses "...and so does an empty one" dnf-offline-stage ': > "$mi"' "Kempt could not check the mount table"
refuses "...and one with a line it cannot read" dnf-offline-stage 'echo "half a line" >> "$mi"' "Kempt could not check the mount table"

# --- links --------------------------------------------------------------------------------------
LINK_VAR='mkdir -p srv/var; mv var/lib var/cache srv/var/; rm -rf var;'
passes "a root-owned relative link is followed" dnf-offline-stage "$LINK_VAR ln -s srv/var var"
passes "...and an absolute one" dnf-offline-stage "$LINK_VAR ln -s \"\$R/srv/var\" var"
passes "...and a chain" dnf-offline-stage "$LINK_VAR ln -s step var; ln -s srv/var step"
refuses "a link's target path is checked" dnf-offline-stage "$LINK_VAR ln -s srv/var var; chmod 777 srv" "$UNSAFE $R/srv."
refuses "...through a chain" dnf-offline-stage "$LINK_VAR ln -s step var; ln -s srv/var step; chmod 777 srv/var" "$UNSAFE $R/srv/var."
if other_ids "a link another user owns"; then
  refuses "a link another user owns is refused" dnf-offline-stage "$LINK_VAR ln -s srv/var var; chown -h 1000 var" "$UNSAFE $R/var."
fi
refuses "past 40 links the helper stops" dnf-offline-stage "$LINK_VAR ln -s srv/var l41; for i in \$(seq 40 -1 0); do ln -s l\$((i + 1)) l\$i; done; ln -s l0 var" "(Too many levels of symbolic links)."
refuses "...and on a loop" dnf-offline-stage 'rm -rf var; ln -s var var' "(Too many levels of symbolic links)."
refuses "41 links are one too many" dnf-offline-stage "$LINK_VAR ln -s srv/var l39; for i in \$(seq 38 -1 0); do ln -s l\$((i + 1)) l\$i; done; ln -s l0 var" "(Too many levels of symbolic links)."
passes "40 links are still fine" dnf-offline-stage "$LINK_VAR ln -s srv/var l38; for i in \$(seq 37 -1 0); do ln -s l\$((i + 1)) l\$i; done; ln -s l0 var"
passes "a dangling link under safe folders is a missing name" dnf-offline-stage 'rm -rf var/lib/dnf/offline; ln -s nowhere var/lib/dnf/offline'
refuses "...and its target's parent still counts" dnf-offline-stage 'rm -rf var/lib/dnf/offline; ln -s ../../../srv/open/nowhere var/lib/dnf/offline; mkdir srv/open; chmod 777 srv/open' "$UNSAFE $R/srv/open."
passes "a newline in a name is followed exactly" dnf-offline-stage "$LINK_VAR mv srv/var \$'srv/new\\nline'; ln -s \$'srv/new\\nline' var"
refuses "...and printed as a plain character" dnf-offline-stage "$LINK_VAR mv srv/var \$'srv/new\\nline'; ln -s \$'srv/new\\nline' var; chmod 777 \$'srv/new\\nline'" "$UNSAFE $R/srv/new?line."
passes "a newline at the end of a link's target is kept" dnf-offline-stage "$LINK_VAR mv srv/var \$'srv/end\\n'; ln -s \$'srv/end\\n' var"
refuses "...and the name it leads to is the one checked" dnf-offline-stage "$LINK_VAR mv srv/var \$'srv/end\\n'; ln -s \$'srv/end\\n' var; chmod 777 \$'srv/end\\n'" "$UNSAFE $R/srv/end?."
refuses "a link inside the state folder is refused, where the cache's are not" dnf-offline-arm 'ln -s /etc usr/lib/sysimage/libdnf5/out' "users other than root can change files in $STATE."
passes "...in the cache a root-owned link is fine" dnf-offline-stage 'ln -s packages var/cache/libdnf5/repo/link'

# --- errors refuse, except a name that vanished -----------------------------------------------------
refuses "a stale folder gets its own sentence" dnf-offline-stage 'export KEMPT_FIND="$(fail_stub "$R/var/lib" find "Stale file handle")"' "kempt-apply: Kempt could not check $R/var/lib (Stale file handle). Run kempt doctor."
assert_not_contains "$OUT" "users other than root" "...never the unsafe-permissions words"
refuses "...and so does permission denied" dnf-offline-stage 'export KEMPT_FIND="$(fail_stub "$R/var/lib" find "Permission denied")"' "(Permission denied)."
passes "a name that vanished under a passed parent is safe" dnf-offline-stage 'export KEMPT_FIND="$(fail_stub "$R/var/lib/dnf/offline" find "No such file or directory")"'
refuses "a find with no words and a bad status answers nothing, so it refuses" dnf-offline-stage 'export KEMPT_FIND="$(fail_stub "$R/var/lib" find "")"' "Kempt could not check $R/var/lib"
refuses "the same on getfacl" dnf-offline-stage 'export KEMPT_GETFACL="$(fail_stub "$R/var/lib" getfacl "Input/output error")"' "Kempt could not check $R/var/lib (Input/output error)."
passes "...and a name gone by getfacl's turn is safe" dnf-offline-stage 'export KEMPT_GETFACL="$(fail_stub "$R/var/lib/dnf/offline" getfacl "No such file or directory")"'
refuses "...and a silent getfacl failure refuses" dnf-offline-stage 'export KEMPT_GETFACL="$(fail_stub "$R/var/lib" getfacl "")"' "Kempt could not check $R/var/lib"
# The closing of the old fail-open: a tree that cannot be read used to read as a tree with nothing wrong in it.
refuses "a tree find cannot read is refused" dnf-offline-arm 'mkdir -p "$STATE/d"; export KEMPT_FIND="$(fail_stub -ignore_readdir_race find "Permission denied")"' "Kempt could not check $STATE (Permission denied)." STATE="$STATE"
refuses "...and one it fails on without a word" dnf-offline-arm 'export KEMPT_FIND="$(fail_stub -ignore_readdir_race find "")"' "Kempt could not check $STATE (the check failed)."
refuses "...and one getfacl -R cannot read" dnf-offline-arm 'export KEMPT_GETFACL="$(fail_stub -R getfacl "Permission denied")"' "Kempt could not check $STATE (Permission denied)."
refuses "...and one getfacl -R fails on without a word" dnf-offline-arm 'export KEMPT_GETFACL="$(fail_stub -R getfacl "")"' "Kempt could not check $STATE (the check failed)."
passes "a name gone from the tree mid-scan is safe" dnf-offline-arm 'export KEMPT_FIND="$(fail_stub -ignore_readdir_race find "No such file or directory" 1)"'
# Staged and state get one try. The cache, which dnf-makecache.timer rewrites, gets a second.
apply dnf-offline-stage 'printf "%s\n" "#!/bin/bash" "if [[ \"\$*\" == *ignore_readdir_race* && \"\$*\" == *libdnf5\ * && \"\$*\" == *cache* ]]; then c=\$(wc -l < \"\$R/n\"); echo x >> \"\$R/n\"; (( c >= 1 )) || { echo \"find: x: Stale file handle\" >&2; exit 1; }; fi" "exec /usr/bin/find \"\$@\"" > stub; chmod 755 stub; : > n; export KEMPT_FIND="$R/stub"'
assert_eq "$RC" "0" "a cache check that fails once is tried again and passes"
apply dnf-offline-stage 'printf "%s\n" "#!/bin/bash" "if [[ \"\$*\" == *ignore_readdir_race* && \"\$*\" == *libdnf5\ * && \"\$*\" == *cache* ]]; then echo \"find: x: Stale file handle\" >&2; exit 1; fi" "exec /usr/bin/find \"\$@\"" > stub; chmod 755 stub; export KEMPT_FIND="$R/stub"'
assert_eq "$RC" "3" "...and one that fails twice refuses"
assert_contains "$OUT" "Kempt could not check $CACHE (Stale file handle)." "...naming the cache"
apply dnf-offline-stage 'printf "%s\n" "#!/bin/bash" "if [[ \"\$*\" == *ignore_readdir_race* && \"\$*\" == *libdnf5\ * && \"\$*\" == *sysimage* ]]; then c=\$(wc -l < \"\$R/n\"); echo x >> \"\$R/n\"; (( c >= 1 )) || { echo \"find: x: Stale file handle\" >&2; exit 1; }; fi" "exec /usr/bin/find \"\$@\"" > stub; chmod 755 stub; : > n; export KEMPT_FIND="$R/stub"'
assert_eq "$RC" "3" "the state folder gets no second try"

# --- which verb checks what -----------------------------------------------------------------------------
verbs_say() {  # title setup upgrade stage arm clean → each verb's exit status, in that order
  local title="$1" setup="$2" want="$3 $4 $5 $6" got="" v
  for v in dnf-upgrade dnf-offline-stage dnf-offline-arm dnf-offline-clean; do
    apply "$v" "$setup"
    got+="$RC "
  done
  assert_eq "${got% }" "$want" "$title"
}
verbs_say "a 0777 cache packages folder: upgrade and stage refuse, arm and clean run" 'chmod 777 var/cache/libdnf5/repo/packages' 3 3 0 0
verbs_say "a writable folder above the cache: upgrade and stage refuse, arm and clean run" 'chmod 777 var/cache' 3 3 0 0
verbs_say "a writable file in the state folder: only clean runs" ': > usr/lib/sysimage/libdnf5/f; chmod 666 usr/lib/sysimage/libdnf5/f' 3 3 3 0
verbs_say "a writable file in the staged folder: only clean runs" ': > var/lib/dnf/offline/p.rpm; chmod 666 var/lib/dnf/offline/p.rpm' 3 3 3 0
verbs_say "a writable folder above the state folder: all four refuse" 'chmod 777 usr/lib' 3 3 3 3
verbs_say "a writable folder above the staged folder: all four refuse" 'chmod 777 var/lib/dnf' 3 3 3 3
verbs_say "a writable state folder itself: all four refuse, since dnf5 deletes through it" 'chmod 777 usr/lib/sysimage/libdnf5' 3 3 3 3

# --- what comes first -----------------------------------------------------------------------------------
apply dnf-offline-clean 'chmod 777 var/lib' KEMPT_OFFLINE_TOML="$FIXTURES/offline-release-upgrade.toml"
assert_eq "$RC" "3" "clean is checked over its folders before what they hold is read"
assert_contains "$OUT" "$UNSAFE $R/var/lib." "...so the words are about the folders"
in_ns 'bash "$AH" dnf-upgrade --installroot=/' 'chmod 777 var/lib'
assert_eq "$RC" "2" "a bad argument is still exit 2, before any folder is read"

# --- compatibility ----------------------------------------------------------------------------------------
BIND='export KEMPT_MOUNTINFO=/proc/self/mountinfo; mkdir srv/safe; chmod 755 srv/safe;'
passes "a bind mount of a root-owned folder passes" dnf-offline-stage "$BIND mkdir -p srv/safe/libdnf5/repo; mount --bind srv/safe var/cache"
if other_ids "a bind mount of a user-owned folder"; then
  refuses "...and of a user-owned one is refused" dnf-offline-stage "$BIND chown 1000 srv/safe; mount --bind srv/safe var/cache" "$UNSAFE $R/var/cache."
fi
TMPFS='mount_at "$R/var/cache" tmpfs rw; chmod 1777 var/cache'
refuses "a default tmpfs over /var/cache is refused" dnf-offline-stage "$TMPFS" "$UNSAFE $R/var/cache."

# --- doctor says what the helper refused --------------------------------------------------------------------
doctor_in_ns() {  # setup [env...] → OUT is doctor's output
  local setup="$1"; shift
  in_ns '"$K" doctor || true' "$setup" "$@"
}
HOLD="Until this is fixed, Kempt will not install, stage or discard updates."
doctor_in_ns "$TMPFS"
assert_contains "$OUT" "FAIL  dnf folders' parents: other users can change $R/var/cache." "doctor's row names the folder"
assert_contains "$OUT" "mode=0755" "...and for a tmpfs says what to add to its mount options"
assert_contains "$OUT" "$HOLD" "...and says what stops until then"
doctor_in_ns 'fuse_at "$R/var"'
assert_contains "$OUT" "fusermount3 -u $R/var" "for a user's FUSE mount doctor gives the unmount"
assert_contains "$OUT" "$R/var" "...and names the folder"
assert_contains "$OUT" "$HOLD" "...and what stops"
doctor_in_ns 'export KEMPT_FIND="$(fail_stub "$R/var/lib" find "Stale file handle")"'
assert_contains "$OUT" "Kempt could not check $R/var/lib (Stale file handle)" "doctor gives the could-not-check words for an error"
assert_not_contains "$OUT" "other users can change $R/var/lib" "...and not the unsafe ones"
doctor_in_ns 'rm -rf usr/lib/sysimage/libdnf5; ln -s libdnf5 usr/lib/sysimage/libdnf5'
assert_contains "$OUT" "Too many levels of symbolic links" "doctor says a link loop on the way is too many links"
doctor_in_ns 'ln -s "mnt:[1]" ns1' KEMPT_MNT_NS_INIT="$R/ns1"
assert_contains "$OUT" "FAIL  " "premise: doctor reports a problem on another mount namespace"
assert_contains "$OUT" "mount namespace" "...in those words"

# --- parity: one table through both, doctor fails exactly when the helper exits 3 -------------------------
PARITY_ROWS='^FAIL  (dnf |Kempt |.*mount namespace|.*could not check)'
parity() {  # title setup [env...]
  local title="$1" setup="$2" helper rows; shift 2
  in_ns 'bash "$AH" dnf-offline-stage >/dev/null 2>&1; echo "helper=$?"; "$K" doctor || true' "$setup" "$@"
  helper="$(sed -n 's/^helper=//p' <<<"$OUT")"
  rows="$(grep -E "$PARITY_ROWS" <<<"$OUT" || true)"
  if [[ "$helper" == 3 ]]; then
    [[ -n "$rows" ]] && echo "ok: both refuse: $title" || { echo "FAIL: the helper refused and doctor has no row: $title"; _fail=1; printf '%s\n' "$OUT" | grep -E '^(FAIL|WARN) ' | cut -c1-200; }
  elif [[ "$helper" == 0 ]]; then
    [[ -z "$rows" ]] && echo "ok: both pass: $title" || { echo "FAIL: the helper passed and doctor fails: $title"; _fail=1; printf '%s\n' "$rows" | cut -c1-200; }
  else
    echo "FAIL: the helper exited $helper: $title"; _fail=1
  fi
}
while IFS='|' read -r title setup; do
  [[ -n "$title" ]] || continue
  parity "$title" "$setup"
done <<'TABLE'
stock|:
/var/lib 0777|chmod 777 var/lib
/var/lib 1777|chmod 1777 var/lib
/var/lib group root writable|chmod 775 var/lib
leaf missing, parent safe|rm -rf var/lib/dnf/offline
leaf missing, parent writable|rm -rf var/lib/dnf/offline; chmod 777 var/lib/dnf
state folder 0777|chmod 777 usr/lib/sysimage/libdnf5
cache folder 0777|chmod 777 var/cache/libdnf5
cache packages 0777|chmod 777 var/cache/libdnf5/repo/packages
a writable file in the cache|: > var/cache/libdnf5/repo/f; chmod 666 var/cache/libdnf5/repo/f
a writable file in the state|: > usr/lib/sysimage/libdnf5/f; chmod 666 usr/lib/sysimage/libdnf5/f
a link in the staged folder|ln -s /etc var/lib/dnf/offline/out
a link in the cache|ln -s packages var/cache/libdnf5/repo/l
root link to /srv/var|mkdir -p srv/var; mv var/lib var/cache srv/var/; rm -rf var; ln -s srv/var var
link target parent writable|mkdir -p srv/var; mv var/lib var/cache srv/var/; rm -rf var; ln -s srv/var var; chmod 777 srv
link loop|rm -rf var; ln -s var var
dangling link, safe parent|rm -rf var/lib/dnf/offline; ln -s nowhere var/lib/dnf/offline
user FUSE on a parent|fuse_at "$R/var"
root FUSE on a parent|fuse_at "$R/var" fuse.sshfs 0
user FUSE inside the cache|fuse_at "$R/var/cache/libdnf5/repo"
FUSE beside the path|fuse_at "$R/srv"
unreadable mount table|export KEMPT_MOUNTINFO="$R/no-such-table"
empty mount table|: > "$mi"
find ESTALE on a parent|export KEMPT_FIND="$(fail_stub "$R/var/lib" find "Stale file handle")"
find EACCES on a parent|export KEMPT_FIND="$(fail_stub "$R/var/lib" find "Permission denied")"
find ENOENT on the leaf|export KEMPT_FIND="$(fail_stub "$R/var/lib/dnf/offline" find "No such file or directory")"
getfacl EIO on a parent|export KEMPT_GETFACL="$(fail_stub "$R/var/lib" getfacl "Input/output error")"
find ESTALE on the state folder|export KEMPT_FIND="$(fail_stub "$R/usr/lib/sysimage/libdnf5" find "Stale file handle")"
find ESTALE on the staged folder|export KEMPT_FIND="$(fail_stub "$R/var/lib/dnf/offline" find "Stale file handle")"
find ESTALE on the cache folder|export KEMPT_FIND="$(fail_stub "$R/var/cache/libdnf5" find "Stale file handle")"
find EACCES in the trees|export KEMPT_FIND="$(fail_stub -ignore_readdir_race find "Permission denied")"
find silent in the trees|export KEMPT_FIND="$(fail_stub -ignore_readdir_race find "")"
getfacl EACCES in the trees|export KEMPT_GETFACL="$(fail_stub -R getfacl "Permission denied")"
atomic system|: > marker; export KEMPT_OSTREE_MARKER="$R/marker"
another mount namespace|ln -s "mnt:[1]" ns1; export KEMPT_MNT_NS_INIT="$R/ns1"
the vanished words with exit 127 on a parent|export KEMPT_FIND="$(fail_stub "$R/var/lib" find "No such file or directory" "" 127)"
the vanished words with exit 127 from getfacl|export KEMPT_GETFACL="$(fail_stub "$R/var/lib" getfacl "No such file or directory" "" 127)"
the vanished words with exit 127 in the trees|export KEMPT_FIND="$(fail_stub -ignore_readdir_race find "No such file or directory" "" 127)"
the vanished words with exit 127 from getfacl -R|export KEMPT_GETFACL="$(fail_stub -R getfacl "No such file or directory" "" 127)"
no find at all|export KEMPT_FIND="$R/no-such-find"
root FUSE with an empty source|printf "2 1 0:2 / %s rw - fuse.x  rw,user_id=0,group_id=0\n" "$R/var" >> "$mi"
user FUSE with an empty source|printf "2 1 0:2 / %s rw - fuse.x  rw,user_id=1000,group_id=1000\n" "$R/var" >> "$mi"
a mount line with a field too many|printf "2 1 0:2 / %s rw - fuse x src rw,user_id=0\n" "$R/srv" >> "$mi"
awk cannot run|mount --bind /dev/null "$(readlink -f /usr/bin/awk)"
writable offline folder in the state|mkdir -p usr/lib/sysimage/libdnf5/offline; chmod 777 usr/lib/sysimage/libdnf5/offline
TABLE
if command -v setfacl >/dev/null; then
  parity "write ACL on /var" 'setfacl -m u:0:rwx var'
  parity "write ACL on /var with mask r-x" 'setfacl -m u:0:rwx,m::r-x var'
  parity "default write ACL on /var" 'setfacl -m d:u:0:rwx var'
  parity "write ACL inside the state" ': > usr/lib/sysimage/libdnf5/f; setfacl -m u:0:rw usr/lib/sysimage/libdnf5/f'
fi
if other_ids "the parity cases with a second user"; then
  parity "/var/lib another user owns" 'chown 1000 var/lib'
  parity "/var/lib group-writable, another group" 'chown 0:1000 var/lib; chmod 775 var/lib'
  parity "/var/lib another group, not writable" 'chown 0:1000 var/lib'
  parity "a file another user owns in the cache" ': > var/cache/libdnf5/repo/f; chown 1000 var/cache/libdnf5/repo/f'
fi

# --- a tool that could not run has answered nothing, whatever its words -----------------------------
refuses "a find that could not start, in the vanished words, refuses over a writable /var/lib" dnf-offline-stage \
  'chmod 777 var/lib; export KEMPT_FIND="$(fail_stub "$R/var/lib" find "No such file or directory" "" 127)"' "Kempt could not check $R/var/lib"
refuses "...and over a good one" dnf-offline-stage \
  'export KEMPT_FIND="$(fail_stub "$R/var/lib" find "No such file or directory" "" 127)"' "Kempt could not check $R/var/lib"
refuses "...and so does a getfacl that could not start" dnf-offline-stage \
  'export KEMPT_GETFACL="$(fail_stub "$R/var/lib" getfacl "No such file or directory" "" 127)"' "Kempt could not check $R/var/lib"
refuses "...and in a tree, find" dnf-offline-arm \
  'export KEMPT_FIND="$(fail_stub -ignore_readdir_race find "No such file or directory" "" 127)"' "Kempt could not check"
refuses "...and in a tree, getfacl" dnf-offline-arm \
  'export KEMPT_GETFACL="$(fail_stub -R getfacl "No such file or directory" "" 127)"' "Kempt could not check"
refuses "no find at the set path refuses" dnf-offline-stage 'export KEMPT_FIND="$R/no-such-find"' "Kempt could not check"
refuses "...and no getfacl at the set path too" dnf-offline-stage 'export KEMPT_GETFACL="$R/no-such-getfacl"' "Kempt could not check"
apply dnf-offline-stage 'rm -rf var/lib/dnf/offline'
assert_eq "$RC" "0" "premise: a real missing folder is still status 1 from the real tools, and passes"

# --- clean deletes through the offline folder in dnf5's state ----------------------------------------
refuses "clean refuses a writable offline folder in the state" dnf-offline-clean \
  'mkdir -p usr/lib/sysimage/libdnf5/offline; chmod 777 usr/lib/sysimage/libdnf5/offline' "$UNSAFE $STATE/offline."
if other_ids "clean over an offline folder another user owns"; then
  refuses "...and one another user owns" dnf-offline-clean 'mkdir -p usr/lib/sysimage/libdnf5/offline; chown 1000 usr/lib/sysimage/libdnf5/offline' "$UNSAFE $STATE/offline."
fi
passes "...and passes with no such folder" dnf-offline-clean ':'
passes "...and with a root-owned one" dnf-offline-clean 'mkdir -p usr/lib/sysimage/libdnf5/offline'
passes "...and over a writable file in it, whose contents are not its concern" dnf-offline-clean \
  'mkdir -p usr/lib/sysimage/libdnf5/offline; : > usr/lib/sysimage/libdnf5/offline/f; chmod 666 usr/lib/sysimage/libdnf5/offline/f'

# --- a mount with an empty source keeps its options ----------------------------------------------------
passes "a root FUSE with an empty source passes" dnf-offline-stage \
  'printf "2 1 0:2 / %s rw - fuse.x  rw,user_id=0,group_id=0\n" "$R/var" >> "$mi"'
refuses "...and a user's is refused" dnf-offline-stage \
  'printf "2 1 0:2 / %s rw - fuse.x  rw,user_id=1000,group_id=1000\n" "$R/var" >> "$mi"' "is on a mount made by a user other than root"
refuses "a line with more fields than the kernel writes is not guessed at" dnf-offline-stage \
  'printf "2 1 0:2 / %s rw - fuse.x src rw,user_id=1000 rw,user_id=0\n" "$R/var" >> "$mi"' "a line in it could not be read"

# --- doctor as an ordinary user: what root is refused, the user may not see --------------------------------
# In a namespace with a second uid, on a tmpfs that uid can reach. The helper runs without capabilities,
# so a folder's mode stops it as a server would stop root.
if other_ids "doctor as an ordinary user"; then
  as_user() {  # setup → OUT: the helper's line, HELPER=<status>, then doctor's rows for the dnf folders
    OUT="$(timeout 120 unshare --map-auto --map-root-user --mount env REPO="$REPO_ROOT" SETUP="$1" bash -c '
      # The checkout may itself sit under /mnt, which the tmpfs below hides: copy it out first.
      stage="$(mktemp -d)" && cp -r "$REPO"/bin "$REPO"/lib "$REPO"/libexec "$REPO"/backends "$REPO"/VERSION "$stage"/ 2>/dev/null
      mount -t tmpfs -o mode=755 none /mnt || exit 9
      mkdir -p /mnt/repo /mnt/h && cp -r "$stage"/. /mnt/repo/
      chown -R 1000:1000 /mnt/h; chmod -R a+rX /mnt/repo
      R=/mnt/root; mkdir -p $R/usr/lib/sysimage/libdnf5 $R/var/lib/dnf/offline $R/var/cache/libdnf5/repo/packages; chmod -R 755 $R
      mi=/mnt/mi; printf "1 0 0:1 / / rw - ext4 /dev/root rw\n" > $mi; chmod 644 $mi
      export KEMPT_DNF_SYSIMAGE_DIR=$R/usr/lib/sysimage/libdnf5 KEMPT_DNF_OFFLINE_PKG_DIR=$R/var/lib/dnf/offline KEMPT_DNF_CACHE_DIR=$R/var/cache/libdnf5
      export KEMPT_DNF_PARENTS_TOP=$R KEMPT_APPLY_ECHO=1 KEMPT_MOUNTINFO=$mi KEMPT_MNT_NS_INIT=/proc/self/ns/mnt KEMPT_OFFLINE_LINK=/mnt/no-link
      export HOME=/mnt/h XDG_CONFIG_HOME=/mnt/h/c XDG_STATE_HOME=/mnt/h/s XDG_CACHE_HOME=/mnt/h/x KEMPT_CONFIG_DIR=/mnt/h/c KEMPT_STATE_DIR=/mnt/h/st
      cd / || exit 9
      eval "$SETUP"
      rc=0
      setpriv --bounding-set=-all --inh-caps=-all bash /mnt/repo/libexec/kempt-apply dnf-offline-clean 2>&1 | awk "/^kempt-apply:/" ; rc=${PIPESTATUS[0]}
      echo "HELPER=$rc"
      setpriv --reuid=1000 --regid=1000 --clear-groups --bounding-set=-all --inh-caps=-all /mnt/repo/bin/kempt doctor 2>&1 | grep -E "^(FAIL|WARN) +(dnf |Kempt )" || true
    ' 2>&1)" || true
  }
  NFS='printf "2 1 0:2 / %s rw - nfs4 srv:/x rw,vers=4.2\n" $R/var >> $mi'
  as_user 'chmod 700 $R/var/cache/libdnf5/repo'
  assert_contains "$OUT" "HELPER=0" "premise: without a network file system nothing stops root at a folder only it can read"
  assert_not_contains "$OUT" "FAIL  dnf" "...and fails nothing"
  as_user "chmod 000 \$R/var/lib/dnf; $NFS"
  assert_contains "$OUT" "HELPER=3" "premise: a server's refusal stops the helper on a parent"
  assert_contains "$OUT" "Kempt could not check" "premise: ...in its could-not-check words"
  assert_not_contains "$OUT" "FAIL  dnf" "...and cannot fail over it"
fi

# --- the seam rule: at a path polkit binds to, no setting counts, whatever the uid map says -------------------
# These runs cannot reach dnf5: the namespace differs from PID 1's, which is what they prove the helper sees.
if [[ -e /run/ostree-booted || ! -d /run/systemd/system || ! -x /usr/bin/systemd-run ]]; then
  skip "this system is not a booted ordinary Fedora, so the runs at polkit's paths did not run"
else
  # Every seam set to the answer that would let the helper through, with a tree that passes.
  LENIENT=(KEMPT_MNT_NS_INIT=/proc/self/ns/mnt KEMPT_OSTREE_MARKER="$R/no-marker")
  in_ns 'mkdir "$R/elsewhere"; cp "$AH" "$R/elsewhere/kempt-apply"; bash "$R/elsewhere/kempt-apply" dnf-offline-stage' ':' "${LENIENT[@]}"
  assert_eq "$RC" "0" "at any other path in a namespace the seams count"
  assert_contains "$OUT" "/usr/bin/dnf5" "premise: and the settings let it through"
  for dir in /usr/libexec /usr/local/libexec; do
    top="$dir"; [[ "$dir" == /usr/local/libexec ]] && top=/usr/local
    PUT="mount -t tmpfs none $top && mkdir -p $dir && cp \"\$AH\" $dir/kempt-apply"
    in_ns "bash $dir/kempt-apply dnf-offline-stage" "$PUT" "${LENIENT[@]}"
    assert_eq "$RC" "3" "at $dir no setting counts: the real namespace check refuses"
    assert_contains "$OUT" "mount namespace" "...over the real namespace"
    assert_not_contains "$OUT" "/usr/bin/dnf5" "...and starts nothing"
    in_ns "ln -s $dir/kempt-apply \"\$R/alias\"; bash \"\$R/alias\" dnf-offline-stage" "$PUT" "${LENIENT[@]}"
    assert_eq "$RC" "3" "...nor through a link to it"
    assert_contains "$OUT" "mount namespace" "...over the same check"
    in_ns "bash $dir/kempt-apply dnf-offline-stage" "$PUT; : > \"\$R/marker\"" KEMPT_MNT_NS_INIT=/proc/self/ns/mnt KEMPT_OSTREE_MARKER="$R/marker"
    assert_not_contains "$OUT" "atomic Fedora" "...and a marker named by a setting is not read"
  done
fi

finish
