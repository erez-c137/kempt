#!/usr/bin/env bash
# One rule set for dnf's folders. On each tree the real root helper, kempt doctor's row and the
# CLI's refusal give one answer. The tree's owner is the test user, who is root inside a user
# namespace, and the helper's test mode reads that owner as root. So both read the same bytes.
source "$(dirname "$0")/lib.sh"
sandbox

K="$REPO_ROOT/bin/kempt"
HELPER="$REPO_ROOT/libexec/kempt-apply"
R="$TESTTMP/root"
STATE="$R/usr/lib/sysimage/libdnf5"; STAGED="$R/var/lib/dnf/offline"; CACHE="$R/var/cache/libdnf5"
export KEMPT_DNF_SYSIMAGE_DIR="$STATE" KEMPT_DNF_OFFLINE_PKG_DIR="$STAGED" KEMPT_DNF_CACHE_DIR="$CACHE"
export KEMPT_ALLOW_ROOT=1 KEMPT_SKIP_REFRESH=1 KEMPT_OFFLINE_TOML="$TESTTMP/no-toml"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/apply-log"; chmod +x "$TESTTMP/apply-log"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/refresh-ok"; chmod +x "$TESTTMP/refresh-ok"
export KEMPT_APPLY_HELPER="$TESTTMP/apply-log" KEMPT_REFRESH_HELPER="$TESTTMP/refresh-ok"

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
mkdir -p usr/lib/sysimage/libdnf5 usr/bin run var/lib/dnf/offline var/cache/libdnf5/repo/packages srv
printf "#!/usr/bin/env bash\nexit 7\n" > usr/bin/systemd-run
chmod -R 755 .
fail_stub() {  # path message [status] → a find that fails on that path and is otherwise the real one
  local s="$R/stub-find"
  { printf "%s\n" "#!/bin/bash" "for a; do if [[ \"\$a\" == \"$1\" ]]; then"
    [[ -z "$2" ]] || printf "%s\n" "  echo \"find: \$a: $2\" >&2"
    printf "%s\n" "  exit ${3:-1}; fi; done" "exec /usr/bin/find \"\$@\""
  } > "$s"
  chmod 755 "$s"; echo "$s"
}
'
DOCTOR="" REFUSAL="" HELPER_RC=""
tree() {  # setup → DOCTOR, REFUSAL (a run's stderr) and HELPER_RC, read from one tree
  DOCTOR="$(timeout 120 unshare --map-auto --map-root-user --mount env R="$R" K="$K" PRELUDE="$PRELUDE" SETUP="$1" bash -c '
    eval "$PRELUDE"
    eval "$SETUP" || { echo "setup failed"; exit 0; }
    cd / || exit 9
    "$K" update --surface=offline --no-flatpak >/dev/null 2>"$R.refusal" </dev/null || true
    "$K" doctor 2>&1 || true' 2>&1)" || true
  REFUSAL="$(cat "$R.refusal" 2>/dev/null)"
  HELPER_RC=0
  KEMPT_HELPER_ROOT="$R" "$HELPER" dnf-upgrade -y >/dev/null 2>&1 || HELPER_RC=$?
  timeout 60 unshare --map-auto --map-root-user rm -rf "$R" "$R.refusal"
}
same_answer() {  # pass|fail title setup
  tree "$3"
  assert_not_contains "$DOCTOR" "setup failed" "$2: the tree was built"
  if [[ "$1" == pass ]]; then
    assert_eq "$HELPER_RC" "7" "$2: the helper goes on"
    assert_not_contains "$DOCTOR" "FAIL  dnf folders" "...doctor passes"
    assert_contains "$DOCTOR" "kempt doctor:" "...having run to its end"
    assert_not_contains "$REFUSAL" "other users can change" "...and a run is not refused"
  else
    assert_eq "$HELPER_RC" "3" "$2: the helper refuses"
    assert_contains "$DOCTOR" "FAIL  dnf folders: other users can change files in " "...doctor fails"
    assert_contains "$REFUSAL" "nothing was changed, because other users can change files in " "...and a run is refused"
  fi
}
while IFS='|' read -r want title setup; do
  [[ -n "$title" ]] || continue
  same_answer "$want" "$title" "$setup"
done <<'TABLE'
pass|stock|:
pass|the folders missing|rm -rf usr/lib/sysimage/libdnf5 var/lib/dnf/offline var/cache/libdnf5
pass|a folder group root can write|chmod 775 var/cache/libdnf5
pass|a parent anyone can write|chmod 777 var/lib
pass|a sticky parent anyone can write|chmod 1777 var/cache
pass|a link in the cache|ln -s packages var/cache/libdnf5/repo/l
pass|a root-owned link in the staged folder|ln -s /etc var/lib/dnf/offline/out
pass|a root-owned link at the folder itself|mkdir -m 777 srv/open; rm -rf var/cache/libdnf5; ln -s ../../srv/open var/cache/libdnf5
pass|a link at the folder that leads nowhere|rm -rf var/lib/dnf/offline; ln -s nowhere var/lib/dnf/offline
fail|the state folder 0777|chmod 777 usr/lib/sysimage/libdnf5
fail|the staged folder 0777|chmod 777 var/lib/dnf/offline
fail|the cache folder 0777|chmod 777 var/cache/libdnf5
fail|a folder deep in the cache 0777|chmod 777 var/cache/libdnf5/repo/packages
fail|a world-writable file in the cache|: > var/cache/libdnf5/repo/f; chmod 666 var/cache/libdnf5/repo/f
fail|a world-writable file in the state|: > usr/lib/sysimage/libdnf5/f; chmod 666 usr/lib/sysimage/libdnf5/f
TABLE
if command -v setfacl >/dev/null; then
  same_answer pass "a write ACL on a parent" 'setfacl -m u:0:rwx var'
  same_answer pass "a write ACL inside the state" ': > usr/lib/sysimage/libdnf5/f; setfacl -m u:0:rw usr/lib/sysimage/libdnf5/f'
fi
if other_ids "the cases with a second user"; then
  same_answer pass "a parent another user owns" 'chown 1000 var/lib'
  same_answer pass "a parent another group can write" 'chown 0:1000 var/lib; chmod 775 var/lib'
  same_answer pass "a cache file in another group, not writable" ': > var/cache/libdnf5/f; chown 0:1000 var/cache/libdnf5/f'
  same_answer fail "a cache file another user owns" ': > var/cache/libdnf5/f; chown 1000 var/cache/libdnf5/f'
  same_answer fail "a cache file another group can write" ': > var/cache/libdnf5/f; chown 0:1000 var/cache/libdnf5/f; chmod 664 var/cache/libdnf5/f'
  same_answer fail "a link another user owns, reported as the link" 'ln -s / var/lib/dnf/offline/out; chown -h 1000 var/lib/dnf/offline/out'
  # A link to another user's world-writable folder is judged by its owner and never followed.
  same_answer pass "a root-owned link to another user's open folder" 'mkdir -m 777 srv/o; chown 1000 srv/o; ln -s "$R/srv/o" var/cache/libdnf5/repo/l'
fi

# --- when the check itself cannot run ---------------------------------------------------------------
# Doctor says so plainly. A run is not stopped, because only root's answer counts then.
for _path in "$STATE" "$STAGED" "$CACHE"; do
  tree "export KEMPT_FIND=\"\$(fail_stub '$_path' 'Stale file handle')\""
  assert_contains "$DOCTOR" "FAIL  dnf folders: Kempt could not check $_path (Stale file handle). Root checks again" "a find that fails on $_path is a FAIL naming the error"
  assert_not_contains "$DOCTOR" "other users can change" "...and not the unsafe words"
  assert_not_contains "$REFUSAL" "other users can change" "...and a run is left to the helper"
done
tree 'export KEMPT_FIND="$(fail_stub -ignore_readdir_race "")"'
assert_contains "$DOCTOR" "Kempt could not check $CACHE (the check failed)" "a find that fails without a word still says so"
tree 'export KEMPT_FIND="$(fail_stub -ignore_readdir_race "No such file or directory" 127)"'
assert_contains "$DOCTOR" "Kempt could not check $CACHE (" "the vanished words with exit 127 are a failure"
tree 'export KEMPT_FIND="$R/no-such-find"'
assert_contains "$DOCTOR" "Kempt could not check $CACHE (" "no find at all is a failure"
tree "export KEMPT_FIND=\"\$(fail_stub '$CACHE' 'No such file or directory')\""
assert_not_contains "$DOCTOR" "FAIL  dnf folders" "a name that vanished while it ran is not a failure"
assert_contains "$DOCTOR" "kempt doctor:" "...and doctor ran to its end"

# --- the mount namespace row ------------------------------------------------------------------------
tree 'ln -s "mnt:[1]" ns1; export KEMPT_MNT_NS_INIT="$R/ns1"'
assert_contains "$DOCTOR" "FAIL  mount namespace: Kempt is running in a different mount namespace from the system" "doctor reports another mount namespace"
assert_contains "$DOCTOR" "what it checks is not what dnf5 uses" "...and says what that means"

# --- doctor as an ordinary user: a folder only root can read is not a problem it can name ------------------
# In a namespace with a second uid, on a tmpfs that uid can reach.
if other_ids "doctor as an ordinary user"; then
  as_user() {  # setup → OUT: doctor's folder rows, if any, and its last line
    OUT="$(timeout 120 unshare --map-auto --map-root-user --mount env REPO="$REPO_ROOT" SETUP="$1" bash -c '
      # The checkout may itself sit under /mnt, which the tmpfs below hides: copy it out first.
      stage="$(mktemp -d)" && cp -r "$REPO"/bin "$REPO"/lib "$REPO"/backends "$REPO"/VERSION "$stage"/ 2>/dev/null
      mount -t tmpfs -o mode=755 none /mnt || exit 9
      mkdir -p /mnt/repo /mnt/h && cp -r "$stage"/. /mnt/repo/
      chown -R 1000:1000 /mnt/h; chmod -R a+rX /mnt/repo
      R=/mnt/root; mkdir -p $R/usr/lib/sysimage/libdnf5 $R/var/lib/dnf/offline $R/var/cache/libdnf5/repo/packages; chmod -R 755 $R
      export KEMPT_DNF_SYSIMAGE_DIR=$R/usr/lib/sysimage/libdnf5 KEMPT_DNF_OFFLINE_PKG_DIR=$R/var/lib/dnf/offline KEMPT_DNF_CACHE_DIR=$R/var/cache/libdnf5
      export KEMPT_MNT_NS_INIT=/proc/self/ns/mnt KEMPT_OFFLINE_LINK=/mnt/no-link
      export HOME=/mnt/h XDG_CONFIG_HOME=/mnt/h/c XDG_STATE_HOME=/mnt/h/s XDG_CACHE_HOME=/mnt/h/x KEMPT_CONFIG_DIR=/mnt/h/c KEMPT_STATE_DIR=/mnt/h/st
      cd / || exit 9
      eval "$SETUP"
      setpriv --reuid=1000 --regid=1000 --clear-groups --bounding-set=-all --inh-caps=-all /mnt/repo/bin/kempt doctor 2>&1 | grep -E "dnf folders|^kempt doctor:" || true
    ' 2>&1)" || true
  }
  as_user 'chmod 700 $R/var/cache/libdnf5/repo'
  assert_not_contains "$OUT" "FAIL  dnf folders" "doctor passes what it can read over a folder only root can read"
  assert_contains "$OUT" "kempt doctor:" "...having run to its end"
  as_user 'chmod 000 $R/var/lib/dnf'
  assert_not_contains "$OUT" "FAIL  dnf folders" "...and over a folder above one it cannot enter"
  assert_contains "$OUT" "kempt doctor:" "...having run to its end again"
  as_user 'chmod 700 $R/var/cache/libdnf5/repo; chmod 777 $R/usr/lib/sysimage/libdnf5'
  assert_contains "$OUT" "FAIL  dnf folders: other users can change files in /mnt/root/usr/lib/sysimage/libdnf5" "...and still finds what it can read"
fi

finish
