#!/usr/bin/env bash
# kempt doctor's rows on dnf's folders and every folder above them, and the CLI's refusal built on
# them (apply_unsafe_dir), run as root in a user namespace against a small tree shaped like the real
# one. The root helper's own, much shorter, folder check is in test_helpers.sh.
source "$(dirname "$0")/lib.sh"
sandbox

K="$REPO_ROOT/bin/kempt"
R="$TESTTMP/root"
STATE="$R/usr/lib/sysimage/libdnf5"; STAGED="$R/var/lib/dnf/offline"; CACHE="$R/var/cache/libdnf5"
export KEMPT_DNF_SYSIMAGE_DIR="$STATE" KEMPT_DNF_OFFLINE_PKG_DIR="$STAGED" KEMPT_DNF_CACHE_DIR="$CACHE"
export KEMPT_DNF_PARENTS_TOP="$R" KEMPT_ALLOW_ROOT=1

if ! timeout 20 unshare --map-auto --map-root-user --mount true 2>/dev/null; then
  skip "no user namespaces here, so the folder rows did not run"
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
  OUT="$(timeout 120 unshare --map-auto --map-root-user --mount env "$@" R="$R" K="$K" PRELUDE="$PRELUDE" bash -c '
    eval "$PRELUDE"
    eval "$1" || { echo "setup failed"; echo "rc=9"; rm -rf "$R"; exit 0; }
    cd / || exit 9
    rc=0; eval "$2" 2>&1 || rc=$?
    cd /; rm -rf "$R"; echo "rc=$rc"' _ "$setup" "$after" 2>&1)" || true
  tail="${OUT##*$'\n'}"
  RC="${tail#rc=}"
}
# --- what doctor says ---------------------------------------------------------------------------------------
doctor_in_ns() {  # setup [env...] → OUT is doctor's output
  local setup="$1"; shift
  in_ns '"$K" doctor || true' "$setup" "$@"
}
HOLD="Until this is fixed, Kempt will not install, stage or discard updates."
TMPFS='mount_at "$R/var/cache" tmpfs rw; chmod 1777 var/cache'
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
assert_contains "$OUT" "FAIL  mount namespace: Kempt is running in a different mount namespace from the system" "doctor reports another mount namespace"
assert_contains "$OUT" "what it checks is not what dnf5 uses" "...and says what that means"
assert_not_contains "$OUT" "$HOLD" "...and does not promise a refusal Kempt does not make"

# --- which trees doctor fails, and that the CLI refuses exactly those --------------------------------------
ROWS='^FAIL  (dnf |Kempt |.*mount namespace|.*could not check)'
row() {  # pass|fail title setup [env...]
  local want="$1" title="$2" setup="$3" rows; shift 3
  in_ns '"$K" doctor || true' "$setup" "$@"
  rows="$(grep -E "$ROWS" <<<"$OUT" || true)"
  if [[ "$want" == pass ]]; then
    assert_eq "$rows" "" "doctor passes: $title"
  else
    assert_contains "$rows" "FAIL  " "doctor fails: $title"
  fi
}
while IFS='|' read -r want title setup; do
  [[ -n "$title" ]] || continue
  row "$want" "$title" "$setup"
done <<'TABLE'
pass|stock|:
fail|/var/lib 0777|chmod 777 var/lib
fail|/var/lib 1777|chmod 1777 var/lib
pass|/var/lib group root writable|chmod 775 var/lib
pass|leaf missing, parent safe|rm -rf var/lib/dnf/offline
fail|leaf missing, parent writable|rm -rf var/lib/dnf/offline; chmod 777 var/lib/dnf
fail|state folder 0777|chmod 777 usr/lib/sysimage/libdnf5
fail|cache folder 0777|chmod 777 var/cache/libdnf5
fail|cache packages 0777|chmod 777 var/cache/libdnf5/repo/packages
fail|a writable file in the cache|: > var/cache/libdnf5/repo/f; chmod 666 var/cache/libdnf5/repo/f
fail|a writable file in the state|: > usr/lib/sysimage/libdnf5/f; chmod 666 usr/lib/sysimage/libdnf5/f
fail|a link in the staged folder|ln -s /etc var/lib/dnf/offline/out
pass|a link in the cache|ln -s packages var/cache/libdnf5/repo/l
pass|root link to /srv/var|mkdir -p srv/var; mv var/lib var/cache srv/var/; rm -rf var; ln -s srv/var var
fail|link target parent writable|mkdir -p srv/var; mv var/lib var/cache srv/var/; rm -rf var; ln -s srv/var var; chmod 777 srv
fail|link loop|rm -rf var; ln -s var var
pass|dangling link, safe parent|rm -rf var/lib/dnf/offline; ln -s nowhere var/lib/dnf/offline
fail|user FUSE on a parent|fuse_at "$R/var"
pass|root FUSE on a parent|fuse_at "$R/var" fuse.sshfs 0
fail|user FUSE inside the cache|fuse_at "$R/var/cache/libdnf5/repo"
pass|FUSE beside the path|fuse_at "$R/srv"
fail|unreadable mount table|export KEMPT_MOUNTINFO="$R/no-such-table"
fail|empty mount table|: > "$mi"
fail|find ESTALE on a parent|export KEMPT_FIND="$(fail_stub "$R/var/lib" find "Stale file handle")"
fail|find EACCES on a parent|export KEMPT_FIND="$(fail_stub "$R/var/lib" find "Permission denied")"
pass|find ENOENT on the leaf|export KEMPT_FIND="$(fail_stub "$R/var/lib/dnf/offline" find "No such file or directory")"
fail|getfacl EIO on a parent|export KEMPT_GETFACL="$(fail_stub "$R/var/lib" getfacl "Input/output error")"
fail|find ESTALE on the state folder|export KEMPT_FIND="$(fail_stub "$R/usr/lib/sysimage/libdnf5" find "Stale file handle")"
fail|find ESTALE on the staged folder|export KEMPT_FIND="$(fail_stub "$R/var/lib/dnf/offline" find "Stale file handle")"
fail|find ESTALE on the cache folder|export KEMPT_FIND="$(fail_stub "$R/var/cache/libdnf5" find "Stale file handle")"
fail|find EACCES in the trees|export KEMPT_FIND="$(fail_stub -ignore_readdir_race find "Permission denied")"
fail|find silent in the trees|export KEMPT_FIND="$(fail_stub -ignore_readdir_race find "")"
fail|getfacl EACCES in the trees|export KEMPT_GETFACL="$(fail_stub -R getfacl "Permission denied")"
fail|atomic system|: > marker; export KEMPT_OSTREE_MARKER="$R/marker"
fail|another mount namespace|ln -s "mnt:[1]" ns1; export KEMPT_MNT_NS_INIT="$R/ns1"
fail|the vanished words with exit 127 on a parent|export KEMPT_FIND="$(fail_stub "$R/var/lib" find "No such file or directory" "" 127)"
fail|the vanished words with exit 127 from getfacl|export KEMPT_GETFACL="$(fail_stub "$R/var/lib" getfacl "No such file or directory" "" 127)"
fail|the vanished words with exit 127 in the trees|export KEMPT_FIND="$(fail_stub -ignore_readdir_race find "No such file or directory" "" 127)"
fail|the vanished words with exit 127 from getfacl -R|export KEMPT_GETFACL="$(fail_stub -R getfacl "No such file or directory" "" 127)"
fail|no find at all|export KEMPT_FIND="$R/no-such-find"
pass|root FUSE with an empty source|printf "2 1 0:2 / %s rw - fuse.x  rw,user_id=0,group_id=0\n" "$R/var" >> "$mi"
fail|user FUSE with an empty source|printf "2 1 0:2 / %s rw - fuse.x  rw,user_id=1000,group_id=1000\n" "$R/var" >> "$mi"
fail|a mount line with a field too many|printf "2 1 0:2 / %s rw - fuse x src rw,user_id=0\n" "$R/srv" >> "$mi"
fail|awk cannot run|mount --bind /dev/null "$(readlink -f /usr/bin/awk)"
fail|writable offline folder in the state|mkdir -p usr/lib/sysimage/libdnf5/offline; chmod 777 usr/lib/sysimage/libdnf5/offline
TABLE
if command -v setfacl >/dev/null; then
  row fail "write ACL on /var" 'setfacl -m u:0:rwx var'
  row pass "write ACL on /var with mask r-x" 'setfacl -m u:0:rwx,m::r-x var'
  row fail "default write ACL on /var" 'setfacl -m d:u:0:rwx var'
  row fail "write ACL inside the state" ': > usr/lib/sysimage/libdnf5/f; setfacl -m u:0:rw usr/lib/sysimage/libdnf5/f'
fi
if other_ids "the cases with a second user"; then
  row fail "/var/lib another user owns" 'chown 1000 var/lib'
  row fail "/var/lib group-writable, another group" 'chown 0:1000 var/lib; chmod 775 var/lib'
  row pass "/var/lib another group, not writable" 'chown 0:1000 var/lib'
  row fail "a file another user owns in the cache" ': > var/cache/libdnf5/repo/f; chown 1000 var/cache/libdnf5/repo/f'
fi

# --- doctor as an ordinary user: a folder only root can read is not a problem it can name ------------------
# In a namespace with a second uid, on a tmpfs that uid can reach.
if other_ids "doctor as an ordinary user"; then
  as_user() {  # setup → OUT: doctor's rows for the dnf folders
    OUT="$(timeout 120 unshare --map-auto --map-root-user --mount env REPO="$REPO_ROOT" SETUP="$1" bash -c '
      # The checkout may itself sit under /mnt, which the tmpfs below hides: copy it out first.
      stage="$(mktemp -d)" && cp -r "$REPO"/bin "$REPO"/lib "$REPO"/backends "$REPO"/VERSION "$stage"/ 2>/dev/null
      mount -t tmpfs -o mode=755 none /mnt || exit 9
      mkdir -p /mnt/repo /mnt/h && cp -r "$stage"/. /mnt/repo/
      chown -R 1000:1000 /mnt/h; chmod -R a+rX /mnt/repo
      R=/mnt/root; mkdir -p $R/usr/lib/sysimage/libdnf5 $R/var/lib/dnf/offline $R/var/cache/libdnf5/repo/packages; chmod -R 755 $R
      mi=/mnt/mi; printf "1 0 0:1 / / rw - ext4 /dev/root rw\n" > $mi; chmod 644 $mi
      export KEMPT_DNF_SYSIMAGE_DIR=$R/usr/lib/sysimage/libdnf5 KEMPT_DNF_OFFLINE_PKG_DIR=$R/var/lib/dnf/offline KEMPT_DNF_CACHE_DIR=$R/var/cache/libdnf5
      export KEMPT_DNF_PARENTS_TOP=$R KEMPT_MOUNTINFO=$mi KEMPT_MNT_NS_INIT=/proc/self/ns/mnt KEMPT_OFFLINE_LINK=/mnt/no-link
      export HOME=/mnt/h XDG_CONFIG_HOME=/mnt/h/c XDG_STATE_HOME=/mnt/h/s XDG_CACHE_HOME=/mnt/h/x KEMPT_CONFIG_DIR=/mnt/h/c KEMPT_STATE_DIR=/mnt/h/st
      cd / || exit 9
      eval "$SETUP"
      setpriv --reuid=1000 --regid=1000 --clear-groups --bounding-set=-all --inh-caps=-all /mnt/repo/bin/kempt doctor 2>&1 | grep -E "^(FAIL|WARN) +(dnf |Kempt )" || true
    ' 2>&1)" || true
  }
  NFS='printf "2 1 0:2 / %s rw - nfs4 srv:/x rw,vers=4.2\n" $R/var >> $mi'
  as_user 'chmod 700 $R/var/cache/libdnf5/repo'
  assert_not_contains "$OUT" "FAIL  dnf" "doctor fails nothing over a folder only root can read"
  as_user "chmod 000 \$R/var/lib/dnf; $NFS"
  assert_not_contains "$OUT" "FAIL  dnf" "...nor over one a network file system hides"
fi

finish
