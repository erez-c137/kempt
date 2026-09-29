#!/usr/bin/env bash
# Reclaiming disk space: the Flatpak refs nothing installed uses. The listing helper, the size
# estimate, the stability rule, the reclaim block in state.json and `kempt reclaim` itself.
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
KEMPT="$REPO_ROOT/bin/kempt"
HELPER="$REPO_ROOT/libexec/kempt-flatpak-unused"
UNUSED_FX="$FIXTURES/flatpak-unused.json"

# --- error_line_of: the one line of flatpak's output that says why --------------------------------
# flatpak ends a failed transaction with a generic "error: There were one or more errors"; the line
# that names the ref and the reason is the "error: Failed to" before it.
assert_eq "$(printf 'Uninstalling\nerror: Failed to uninstall runtime/a/x86_64/1: busy\nerror: There were one or more errors\n' | error_line_of)" \
  "error: Failed to uninstall runtime/a/x86_64/1: busy" "error_line_of prefers flatpak's \"Failed to\" line over its generic last one"
assert_eq "$(printf 'error: first\nerror: second\nwarning: after\n' | error_line_of)" "error: second" \
  "...else the last error: line"
# Terminal escapes of every kind go: CSI with private parameters (hide cursor), OSC (window title,
# hyperlink) and the C1 CSI, as U+009B or a lone byte after ASCII. A 0x9b inside a UTF-8 character stays.
assert_eq "$(printf '\033[?25l\033]0;flatpak\007error: Failed to \033]8;;http://x\033\\go\033]8;;\033\\ \xc2\x9b1mhere\xc2\x9b0m \x9b1mnow \xc3\x9b\033[?25h\n' | error_line_of)" \
  "error: Failed to go here now $(printf '\xc3\x9b')" "...with CSI, OSC and C1 CSI sequences removed"
# 200 characters, cut on a character boundary: the result is still valid UTF-8.
long="$(printf 'error: %s' "$(printf '\xc3\xa9%.0s' {1..300})" | error_line_of)"
assert_eq "$(printf '%s' "$long" | LC_ALL=C.UTF-8 wc -m)|$(printf '%s' "$long" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && echo valid)" "200|valid" \
  "...cut to 200 characters without splitting one"

# --- the listing helper ---------------------------------------------------------------------------
# Run against a stand-in for PyGObject (tests/fixtures/fake-gi) that serves the fixture's refs, so
# this needs python3 and nothing else: no libflatpak, no system installation, no network.
if command -v python3 >/dev/null 2>&1; then
  export FAKE_FLATPAK_JSON="$UNUSED_FX" FAKE_FLATPAK_CALLS="$TESTTMP/fake-calls"
  hout="$(PYTHONPATH="$FIXTURES/fake-gi" PYTHONDONTWRITEBYTECODE=1 "$HELPER")" || hout="rc=$?"
  assert_json_eq "$hout" "$(cat "$UNUSED_FX")" \
    "the helper prints the installation, the unused refs with their end-of-life reason, and the rest as used"
  assert_eq "$(jq -r '.unused[4].eol' <<<"$hout" 2>/dev/null)" \
    "We strongly recommend moving to the latest stable version of the Platform and SDK" \
    "...an end-of-life runtime carries flatpak's reason"
  assert_eq "$(jq -r '.unused[0].eol' <<<"$hout" 2>/dev/null)" "null" "...and a supported one carries null"
  # new_user() creates ~/.local/share/flatpak/repo as a side effect, so the helper must never call it.
  assert_eq "$(cat "$TESTTMP/fake-calls")" "new_system" "the helper opens the system installation and nothing else"
  rc=0; FAKE_FLATPAK_FAIL="boom" PYTHONPATH="$FIXTURES/fake-gi" PYTHONDONTWRITEBYTECODE=1 \
    "$HELPER" >"$TESTTMP/hout" 2>"$TESTTMP/herr" || rc=$?
  assert_eq "$rc" "1" "a library that fails is a non-zero exit"
  assert_eq "$(wc -c < "$TESTTMP/hout")" "0" "...with nothing on stdout for the CLI to parse"
  assert_contains "$(cat "$TESTTMP/herr")" "flatpak did not answer: boom" "...and the reason on stderr"
  rc=0; PYTHONPATH="$TESTTMP/no-such-dir" PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 python3 -S "$HELPER" \
    >/dev/null 2>"$TESTTMP/herr" || rc=$?
  assert_eq "$rc" "3" "no PyGObject at all is exit 3"
  assert_exit 2 "the helper takes no arguments" -- env PYTHONPATH="$FIXTURES/fake-gi" "$HELPER" --user
  unset FAKE_FLATPAK_JSON FAKE_FLATPAK_CALLS
else
  skip "python3 not installed: the listing helper was not run"
fi
# Not under lib/ or backends/: the package strips the shebang from every file there, and this one
# is executed rather than sourced.
assert_eq "$(head -1 "$HELPER")" "#!/usr/bin/python3 -s" "the helper names its interpreter absolutely, without the user's site-packages"
# -s keeps a `gi` in ~/.local/lib/python3.*/site-packages from shadowing the system one. Proved with
# usercustomize, which Python imports from the user site at startup unless -s is given.
if command -v python3 >/dev/null 2>&1; then
  export PYTHONUSERBASE="$TESTTMP/userbase"
  usite="$(python3 -c 'import site; print(site.getusersitepackages())')"
  mkdir -p "$usite"
  printf 'open(%s, "w").write("loaded")\n' "'$TESTTMP/usersite-loaded'" > "$usite/usercustomize.py"
  FAKE_FLATPAK_JSON="$UNUSED_FX" PYTHONPATH="$FIXTURES/fake-gi" PYTHONDONTWRITEBYTECODE=1 "$HELPER" >/dev/null 2>&1 || true
  assert_eq "$(cat "$TESTTMP/usersite-loaded" 2>/dev/null || echo "not loaded")" "not loaded" \
    "...so nothing in the user's site-packages is loaded"
  unset PYTHONUSERBASE
fi
assert_exit 0 "...and is executable in the tree" -- test -x "$HELPER"

# --- stubs for everything the CLI runs ------------------------------------------------------------
# The listing stub serves $LISTING, which a test rewrites to change what is unused; the removal stub
# logs its arguments and then swaps in $AFTER, the way a real removal changes the next listing.
# du prints one line per argument in argument order, from a table keyed by path, which is the
# real command's output shape. A path not in the table makes it fail, like a directory du cannot read.
STUBS="$TESTTMP/stubs"; mkdir -p "$STUBS"
LISTING="$TESTTMP/listing.json"; AFTER="$TESTTMP/after.json"; DU_TABLE="$TESTTMP/du-table.tsv"
export LISTING AFTER DU_TABLE STUBS
cat > "$STUBS/unused" <<'STUB'
#!/usr/bin/env bash
echo run >> "$STUBS/unused.calls"
[[ -n "${UNUSED_FAIL:-}" || -e "$STUBS/unused.fail" ]] && { echo "flatpak did not answer" >&2; exit 1; }
cat "$LISTING"
STUB
cat > "$STUBS/du" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUBS/du.calls"
[[ "$1" == -sb && "$2" == -- ]] || exit 2
shift 2
for d in "$@"; do
  b="$(awk -F'\t' -v d="$d" '$1 == d { print $2; exit }' "$DU_TABLE")"
  [[ -n "$b" ]] || { echo "du: cannot access '$d'" >&2; exit 1; }
  printf '%s\t%s\n' "$b" "$d"
done
STUB
cat > "$STUBS/uninstall" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUBS/uninstall.calls"
[[ -n "${UNINSTALL_OUT:-}" ]] && { cat "$UNINSTALL_OUT"; exit "${UNINSTALL_RC:-0}"; }
[[ -n "${UNINSTALL_RC:-}" && "$UNINSTALL_RC" != 0 ]] && { echo "error: removal failed" >&2; exit "$UNINSTALL_RC"; }
[[ -f "$AFTER" ]] && cp "$AFTER" "$LISTING"
echo "Uninstalling..."
STUB
cat > "$STUBS/pkcheck" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUBS/pkcheck.calls"
[[ -n "${PKCHECK_SWAP:-}" ]] && cp "$PKCHECK_SWAP" "$LISTING"
[[ -n "${PKCHECK_HANG:-}" ]] && exec sleep 30
exit "${PKCHECK_RC:-0}"
STUB
cat > "$STUBS/getent" <<'STUB'
#!/usr/bin/env bash
printf 'root:x:0:0:root:/root:/bin/bash\n'
printf 'alex:x:1000:1000:Alex:/home/alex:/bin/bash\n'
[[ -n "${SECOND_HUMAN:-}" ]] && printf 'sam:x:1001:1001:Sam:/home/sam:/bin/zsh\n'
printf 'nobody:x:65534:65534:Kernel Overflow User:/:/usr/sbin/nologin\n'
printf 'sddm:x:975:975:SDDM Greeter:/var/lib/sddm:/usr/sbin/nologin\n'
STUB
chmod +x "$STUBS"/*
cp "$UNUSED_FX" "$LISTING"
# Sizes in the shape a real removal showed: GL 24.08extra shares most of its files with 24.08, so
# du credits them to 24.08 and 24.08extra's own line is small.
{
  jq -r '.used[].deploy_dir | "\(.)\t4000000000"' "$UNUSED_FX"
  jq -r '.unused[] | "\(.deploy_dir)\t\({"runtime/org.freedesktop.Platform/x86_64/24.08": 600000000,
          "runtime/org.freedesktop.Platform.GL.default/x86_64/24.08": 450000000,
          "runtime/org.freedesktop.Platform.GL.default/x86_64/24.08extra": 20000000,
          "runtime/org.freedesktop.Platform.Locale/x86_64/24.08": 5000000,
          "runtime/org.kde.Platform/x86_64/5.15-23.08": 900000000}[.ref])"' "$UNUSED_FX"
} > "$DU_TABLE"
export KEMPT_FLATPAK_UNUSED_CMD="$STUBS/unused" KEMPT_DU_CMD="$STUBS/du" \
       KEMPT_FLATPAK_UNINSTALL_CMD="$STUBS/uninstall" KEMPT_PKCHECK="$STUBS/pkcheck" \
       KEMPT_GETENT_CMD="$STUBS/getent"
# Checks with nothing else pending: dnf answers empty, flatpak's other queries are pinned at `true`.
cat > "$STUBS/refresh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUBS/refresh"
export KEMPT_REFRESH_HELPER="$STUBS/refresh" KEMPT_SKIP_REFRESH=1 KEMPT_DNF_CMD=true \
       KEMPT_FLATPAK_REMOTE_CMD=true KEMPT_FLATPAK_LIST_CMD=true

check() { "$KEMPT" check 2>/dev/null; }
state_reclaim() { jq -c '.reclaim' "$KEMPT_STATE_DIR/state.json"; }
ALL5="$(jq -c '[.unused[].ref]' "$UNUSED_FX")"
REFS5="$(jq -r '[.unused[].ref] | join(" ")' "$UNUSED_FX")"

# --- the reclaim block: first sighting --------------------------------------------------------------
out="$(check)"
assert_eq "$(jq -r '.reclaim.mode' <<<"$out")" "ask" "a check publishes the reclaim block, mode ask by default"
assert_eq "$(jq -c '[.reclaim.refs[].ref]' <<<"$out")" "$ALL5" "...listing every unused ref"
assert_eq "$(jq -c '.reclaim.refs[0] | keys' <<<"$out")" '["commit","eol","ref","since"]' \
  "...each with its commit, since and end-of-life reason"
assert_eq "$(jq -r '.reclaim.refs[4].eol' <<<"$out")" \
  "We strongly recommend moving to the latest stable version of the Platform and SDK" "...the reason carried as flatpak gave it"
# Seen for the first time, so none has been unused for an hour: nothing is offered yet.
assert_eq "$(jq -c '.reclaim | [.offerable_bytes, .digest, .status]' <<<"$out")" '[null,"","ok"]' \
  "refs seen unused for the first time are not offered: no bytes, no digest"
assert_eq "$([[ -s "$STUBS/du.calls" ]] && echo ran || echo none)" "none" "...and with no offer there is no size to estimate"
assert_eq "$(jq -r '.reclaim.refs[0].since | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' <<<"$out")" "true" \
  "...and since is UTC in a form jq and JavaScript both read back"
first_since="$(jq -r '.reclaim.refs[0].since' <<<"$out")"
assert_eq "$(state_reclaim | jq -r '.mode')" "ask" "the block is in state.json, not only on stdout"

# --- stability: an hour unused with the same commit -------------------------------------------------
# Age the recorded sightings by rewriting state.json, the file the next check reads them back from.
age_state() {  # seconds ago [jq ref filter]
  local t; t="$(date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ)"
  jq --arg t "$t" "(.reclaim.refs[] | select(${2:-true})).since = \$t" "$KEMPT_STATE_DIR/state.json" > "$TESTTMP/st" \
    && mv "$TESTTMP/st" "$KEMPT_STATE_DIR/state.json"
}
out="$(check)"
assert_eq "$(jq -r '.reclaim.refs[0].since' <<<"$out")" "$first_since" "a second check keeps the first sighting"
age_state 3500
out="$(check)"
assert_eq "$(jq -r '.reclaim.digest' <<<"$out")" "" "58 minutes unused is not yet offerable"
age_state 3700
out="$(check)"
assert_eq "$(jq -r '.reclaim.offerable_bytes' <<<"$out")" "1975000000" \
  "past an hour every ref is offerable, and the bytes are du's per-directory figures summed"
DIGEST5="$(jq -r '.reclaim.digest' <<<"$out")"
assert_eq "$(grep -cE '^[0-9a-f]{16}$' <<<"$DIGEST5")" "1" "...under a 16-character digest"
assert_eq "$DIGEST5" "$(jq -r '.unused[] | "\(.ref)\t\(.commit)"' "$UNUSED_FX" | reclaim_digest)" \
  "...which is the digest of the offerable refs and commits"
# du ran over the used directories FIRST, so a file shared with a used ref is credited to it.
first_du="$(head -1 "$STUBS/du.calls")"
assert_eq "$(awk '{print $3}' <<<"$first_du")" "$(jq -r '.used[0].deploy_dir' "$UNUSED_FX")" \
  "du is given the used deploy directories before the unused ones"
assert_eq "$(awk '{print NF - 2}' <<<"$first_du")" "11" "...all eleven of them, in one call"
assert_eq "$(wc -l < "$STUBS/du.calls")" "1" "the size estimate is cached while the installed set is unchanged"

# A ref whose commit changed starts again, and while any ref is younger than an hour nothing is
# offered: the removal takes the whole list, so an offer of the older part could only fail.
jq '(.unused[] | select(.ref | endswith("24.08extra"))).commit = ("e" * 64)' "$UNUSED_FX" > "$LISTING"
out="$(check)"
assert_eq "$(jq -r '.reclaim.refs[] | select(.ref | endswith("24.08extra")) | .since' <<<"$out" | cut -c1-10)" \
  "$(date -u +%Y-%m-%d)" "a ref whose commit changed is a new sighting"
assert_eq "$(jq -c '.reclaim | [.offerable_bytes, .digest, .status, (.refs | length)]' <<<"$out")" '[null,"","ok",5]' \
  "...and until it has aged nothing is offered, while every ref is still listed"
assert_eq "$(wc -l < "$STUBS/du.calls")" "1" "...and no size estimate while there is no offer"
cp "$UNUSED_FX" "$LISTING"
check >/dev/null
age_state 7200
out="$(check)"
assert_eq "$(jq -r '.reclaim.digest' <<<"$out")" "$DIGEST5" "the same set back, aged again, is the same digest"

# A since from the future (the clock stepped back) or one that cannot be read starts again.
jq '.reclaim.refs[0].since = "2999-01-01T00:00:00Z" | .reclaim.refs[1].since = "yesterday"' \
  "$KEMPT_STATE_DIR/state.json" > "$TESTTMP/st" && mv "$TESTTMP/st" "$KEMPT_STATE_DIR/state.json"
out="$(check)"
assert_eq "$(jq -r '[.reclaim.refs[0,1].since[0:10]] | unique | .[]' <<<"$out")" "$(date -u +%Y-%m-%d)" \
  "a since in the future or unreadable is a new sighting"
age_state 7200

# --- the size rule against the real GNU du ---------------------------------------------------------
# The estimate rests on one behaviour of du: a hard-linked file is counted once, for the first
# argument that reaches it. flatpak deploys hard-link shared files, so a file an unused ref shares
# with a used one must not be counted as freed. Proved here with the real command on real links.
source "$REPO_ROOT/backends/flatpak.sh"
R="$TESTTMP/realdu"; mkdir -p "$R/used" "$R/a" "$R/b"
head -c 1000000 /dev/zero > "$R/used/shared-with-used"; ln "$R/used/shared-with-used" "$R/a/shared-with-used"
head -c 3000 /dev/zero > "$R/a/own"
head -c 50000 /dev/zero > "$R/a/shared-a-b"; ln "$R/a/shared-a-b" "$R/b/shared-a-b"
realdu_listing="$(jq -cn --arg r "$R" --arg c "$(printf 'a%.0s' {1..64})" '{installation: "/x",
  used: [{ref: "app/org.example.App/x86_64/stable", commit: $c, deploy_dir: ($r + "/used")}],
  unused: [{ref: "runtime/org.example.A/x86_64/1", commit: $c, deploy_dir: ($r + "/a"), eol: null},
           {ref: "runtime/org.example.B/x86_64/1", commit: $c, deploy_dir: ($r + "/b"), eol: null}]}')"
rm -f "$RECLAIM_SIZES_FILE"
realdu_sizes="$(KEMPT_DU_CMD="du" flatpak_unused_sizes "$realdu_listing")" || realdu_sizes="rc=$?"
a_bytes="$(awk -F'\t' '$1 ~ /example.A/ { print $2 }' <<<"$realdu_sizes")"
b_bytes="$(awk -F'\t' '$1 ~ /example.B/ { print $2 }' <<<"$realdu_sizes")"
assert_eq "$([[ "$a_bytes" =~ ^[0-9]+$ ]] && (( a_bytes >= 53000 && a_bytes < 1000000 )) && echo yes || echo "no: $realdu_sizes")" "yes" \
  "real du: a file an unused ref shares with a used ref is not counted as freed"
assert_eq "$([[ "$b_bytes" =~ ^[0-9]+$ ]] && (( b_bytes < 50000 )) && echo yes || echo "no: $realdu_sizes")" "yes" \
  "real du: a file two unused refs share is counted once, for the first"
rm -f "$RECLAIM_SIZES_FILE"

# --- sizes that cannot be worked out ----------------------------------------------------------------
rm -f "$RECLAIM_SIZES_FILE"
grep -v 'org.kde.Platform/x86_64/5.15-23.08' "$DU_TABLE" > "$TESTTMP/du-short"; cp "$DU_TABLE" "$TESTTMP/du-full"
cp "$TESTTMP/du-short" "$DU_TABLE"
out="$(check)"
assert_eq "$(jq -c '.reclaim | [.offerable_bytes, .status]' <<<"$out")" '[null,"unknown_size"]' \
  "a du that fails is an unknown size, never a smaller one"
assert_eq "$(jq -r '.reclaim.digest' <<<"$out")" "$DIGEST5" "...and the set is still offered"
assert_eq "$(jq -r '.status' <<<"$out")" "ok" "...and the check itself is ok"
cp "$TESTTMP/du-full" "$DU_TABLE"
out="$(check)"
assert_eq "$(jq -c '.reclaim | [.offerable_bytes, .status]' <<<"$out")" '[1975000000,"ok"]' "a du that works again restores the figure"

# --- a listing that fails ----------------------------------------------------------------------------
out="$(UNUSED_FAIL=1 check)"
assert_eq "$(jq -c '.reclaim | [.status, .refs, .digest, .offerable_bytes]' <<<"$out")" '["failed",[],"",null]' \
  "a listing that fails is status failed with nothing offered"
assert_eq "$(jq -r '.status' <<<"$out")" "ok" "...and never a failed check"
printf 'not json' > "$LISTING"
assert_eq "$(check | jq -r '.reclaim.status')" "failed" "a listing that is not JSON is the same failure"
jq '.unused[0].deploy_dir = "--files0-from=/etc/shadow"' "$UNUSED_FX" > "$LISTING"
assert_eq "$(check | jq -r '.reclaim.status')" "failed" \
  "a deploy directory that is not an absolute path rejects the whole listing before du sees it"
jq '.unused[0].commit = "HEAD"' "$UNUSED_FX" > "$LISTING"
assert_eq "$(check | jq -r '.reclaim.status')" "failed" "...and so does a commit that is not one"
cp "$UNUSED_FX" "$LISTING"
jq '.unused = []' "$UNUSED_FX" > "$TESTTMP/none.json"

# --- where the block does not appear -----------------------------------------------------------------
# No listing and no block at all: flatpak off, flatpak absent, reclaim=off, or an elevated process.
rm -f "$STUBS/unused.calls"
config_set include_flatpak false
assert_eq "$(check | jq -c '.reclaim')" "null" "include_flatpak=false: no reclaim block"
config_set include_flatpak true
config_set reclaim off
assert_eq "$(check | jq -c '.reclaim')" "null" "reclaim=off: no reclaim block"
config_set reclaim ask
assert_eq "$(KEMPT_FLATPAK_UNINSTALL_CMD="$TESTTMP/no-flatpak uninstall" check | jq -c '.reclaim')" "null" \
  "no flatpak installed: no reclaim block"
assert_eq "$(SUDO_UID=1000 check | jq -c '.reclaim')" "null" "under sudo: no reclaim block"
assert_eq "$(PKEXEC_UID=1000 check | jq -c '.reclaim')" "null" "under pkexec: no reclaim block"
assert_eq "$([[ -e "$STUBS/unused.calls" ]] && echo listed || echo never)" "never" "...and in none of those was anything listed"

# --- the mode published -----------------------------------------------------------------------------
config_set reclaim automatic
assert_eq "$(check | jq -r '.reclaim.mode')" "automatic" "reclaim=automatic on a one-person machine publishes automatic"
assert_eq "$(SECOND_HUMAN=1 check | jq -r '.reclaim.mode')" "ask" \
  "...with a second human account it publishes ask, because flatpak cannot see their apps"
assert_eq "$(KEMPT_GETENT_CMD="$TESTTMP/no-getent" check | jq -r '.reclaim.mode')" "ask" \
  "...an account lookup that fails reads the same way"
touch "$TESTTMP/ostree-booted"
assert_eq "$(KEMPT_OSTREE_MARKER="$TESTTMP/ostree-booted" check | jq -r '.reclaim.mode')" "ask" \
  "...and on an image-based system, where Kempt runs no updates to remove after, it publishes ask"
# Accounts the old count missed. A second stand-in getent prints the one-person machine above plus
# $EXTRA_PASSWD, so each case adds one line.
cat > "$STUBS/getent-plus" <<'STUB'
#!/usr/bin/env bash
"$STUBS/getent"
[[ -n "${EXTRA_PASSWD:-}" ]] && printf '%s\n' "$EXTRA_PASSWD"
exit 0
STUB
chmod +x "$STUBS/getent-plus"
mode_with() { EXTRA_PASSWD="$1" KEMPT_GETENT_CMD="$STUBS/getent-plus" check | jq -r '.reclaim.mode'; }
assert_eq "$(mode_with 'kim:x:60100:60100:Kim:/home/kim:/bin/bash')" "ask" \
  "a systemd-homed account (UID above 60000) is a second person"
assert_eq "$(mode_with 'lee:x:1002:1002:Lee:/home/lee:')" "ask" "...and so is an account with an empty shell, which means /bin/sh"
assert_eq "$(mode_with 'nobody:x:65534:65534:Nobody:/:/bin/bash')" "automatic" "...but never nobody, whatever its shell"
assert_eq "$(mode_with 'svc:x:1003:1003::/var/lib/svc:/sbin/nologin')" "automatic" "...nor an account that cannot log in"
printf 'passwd:     files sss systemd\n' > "$TESTTMP/nss-sss"
printf '# passwd: files sss\npasswd:     files systemd  # no sss here\n' > "$TESTTMP/nss-local"
# sss and winbind count only when that service is set up, since upgraded machines keep an old
# `passwd: sss files` line with no sssd behind it.
nss_mode() { KEMPT_NSSWITCH_FILE="$TESTTMP/$1" check | jq -r '.reclaim.mode'; }
assert_eq "$(nss_mode nss-sss)" "automatic" \
  "sss in nsswitch.conf with no sssd config publishes automatic, as an upgraded machine keeps the line"
SD="$TESTTMP/sssd"; mkdir -p "$SD/conf.d"
printf '[sssd]\nservices = nss\n' > "$SD/sssd.conf"
assert_eq "$(KEMPT_SSSD_DIR="$SD" nss_mode nss-sss)" "automatic" "...and so does an sssd config with no domain"
printf '[domain/corp.example]\nid_provider = ldap\n' > "$SD/conf.d/corp.conf"
assert_eq "$(KEMPT_SSSD_DIR="$SD" nss_mode nss-sss)" "ask" \
  "an sssd domain publishes ask, since getent lists none of its accounts"
rm "$SD/conf.d/corp.conf"; chmod 000 "$SD/sssd.conf"
assert_eq "$(KEMPT_SSSD_DIR="$SD" nss_mode nss-sss)" "ask" "...and so does an sssd config it cannot read"
chmod 600 "$SD/sssd.conf"; chmod 000 "$SD"
cat > "$STUBS/systemctl" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == *sssd.service* ]] || exit 1
[[ -n "${SSSD_SHOW:-}" ]] || exit 1
printf '%b' "$SSSD_SHOW"
STUB
chmod +x "$STUBS/systemctl"
sd_mode() { SSSD_SHOW="$1" KEMPT_SYSTEMCTL_CMD="$STUBS/systemctl" KEMPT_SSSD_DIR="$SD" nss_mode nss-sss; }
assert_eq "$(sd_mode 'ActiveState=inactive\nConditionResult=no\nConditionTimestampMonotonic=4512\n')" "automatic" \
  "an sssd dir it cannot read defers to systemd: sssd found no config when it last tried, automatic"
assert_eq "$(sd_mode 'ActiveState=active\nConditionResult=yes\nConditionTimestampMonotonic=4512\n')" "ask" \
  "...sssd running publishes ask"
assert_eq "$(sd_mode 'ActiveState=inactive\nConditionResult=no\nConditionTimestampMonotonic=0\n')" "ask" \
  "...sssd never tried is not proof of no config, so ask"
assert_eq "$(sd_mode '')" "ask" "...and a systemctl that fails publishes ask"
chmod 700 "$SD"
printf 'passwd:     files winbind\n' > "$TESTTMP/nss-winbind"
assert_eq "$(nss_mode nss-winbind)" "automatic" "winbind in nsswitch.conf with no smb.conf publishes automatic"
printf '[global]\n\tsecurity = user\n; security = ads\n' > "$TESTTMP/smb.conf"
assert_eq "$(KEMPT_SMB_CONF="$TESTTMP/smb.conf" nss_mode nss-winbind)" "automatic" \
  "...and so does a Samba that joins no domain, a commented-out line included"
printf '[global]\n   Security = ADS\n' > "$TESTTMP/smb.conf"
assert_eq "$(KEMPT_SMB_CONF="$TESTTMP/smb.conf" nss_mode nss-winbind)" "ask" "a Samba joined to a domain publishes ask"
chmod 000 "$TESTTMP/smb.conf"
assert_eq "$(KEMPT_SMB_CONF="$TESTTMP/smb.conf" nss_mode nss-winbind)" "ask" "...and so does an smb.conf it cannot read"
chmod 600 "$TESTTMP/smb.conf"
printf 'passwd:     files ldap\n' > "$TESTTMP/nss-ldap"
assert_eq "$(nss_mode nss-ldap)" "ask" "ldap in nsswitch.conf publishes ask from the line alone"
assert_eq "$(KEMPT_NSSWITCH_FILE="$TESTTMP/nss-local" check | jq -r '.reclaim.mode')" "automatic" \
  "...while local sources, and a commented-out sss, publish automatic"
HR="$TESTTMP/homes"; mkdir -p "$HR/home/alex/.local/share/flatpak"
ln -s home "$HR/var-home"
assert_eq "$(KEMPT_HOME_ROOTS="$HR/home $HR/var-home" check | jq -r '.reclaim.mode')" "automatic" \
  "one home with Flatpak data, reached through two paths, is one person"
mkdir -p "$HR/home/sam/.local/share/flatpak"
assert_eq "$(KEMPT_HOME_ROOTS="$HR/home $HR/var-home" check | jq -r '.reclaim.mode')" "ask" \
  "two homes with Flatpak data publish ask"
config_set reclaim nonsense
assert_eq "$(check | jq -r '.reclaim.mode')" "ask" "an unknown value publishes ask"
config_set reclaim ask
age_state 7200
check >/dev/null

# --- the before-snapshot guard ----------------------------------------------------------------------
# reclaim_all_in_snapshot, from bin/kempt: after an update, every ref must have been installed when
# the run began. Its snapshot rows are `id/branch` for a runtime and a bare `id` for an app.
source /dev/stdin <<<"$(sed -n '/^reclaim_all_in_snapshot()/,/^}/p' "$KEMPT")"
snap_classified() { jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '[.[] | {ref: ., commit: ("a" * 64), since: $now, eol: null, offerable: true}]' <<<"$1"; }
SNAPF="$TESTTMP/fp-before.tsv"
printf 'org.freedesktop.Platform/24.08\t?\t%s\n' "$(printf 'a%.0s' {1..64})" > "$SNAPF"
in_snap() { reclaim_all_in_snapshot "$(snap_classified "$1")" "$SNAPF" && echo present || echo missing; }
assert_eq "$(in_snap '["runtime/org.freedesktop.Platform/x86_64/24.08"]')" "present" "a runtime in the snapshot is present"
assert_eq "$(in_snap '["runtime/org.kde.Platform/x86_64/6.9"]')" "missing" "...one that is not there is missing"
assert_eq "$(in_snap '["runtime/org.freedesktop.Platform.Locale/x86_64/24.08"]')" "present" \
  "a runtime's Locale extension, hidden from the snapshot, is present when its runtime is"
# An app's extension: the app row is its bare id, with no branch.
printf 'org.mozilla.firefox\t140.0\t%s\n' "$(printf 'b%.0s' {1..64})" >> "$SNAPF"
assert_eq "$(in_snap '["runtime/org.mozilla.firefox.Locale/x86_64/stable"]')" "present" \
  "an app's Locale extension is present when the app is"
assert_eq "$(in_snap '["runtime/org.mozilla.firefox/x86_64/stable"]')" "missing" \
  "...but a runtime that is not an extension never matches an app row"
assert_eq "$(in_snap '["runtime/org.mozilla.firefox2.Locale/x86_64/stable"]')" "missing" \
  "...nor does another app's extension"
# The app is gone as well, so the snapshot cannot show the extension. A check that saw it unused
# before the run began proves it was there.
grep -v firefox "$SNAPF" > "$SNAPF.new" && mv "$SNAPF.new" "$SNAPF"
touch -d '2026-06-01 12:00:00 UTC' "$SNAPF"
fx_ref='[{"ref":"runtime/org.mozilla.firefox.Locale/x86_64/stable","commit":"'"$(printf 'c%.0s' {1..64})"'","eol":null,"offerable":true'
assert_eq "$(reclaim_all_in_snapshot "$fx_ref"',"since":"2026-06-01T10:00:00Z"}]' "$SNAPF" && echo present || echo missing)" "present" \
  "an extension whose app is gone is present when a check saw it unused before the run began"
assert_eq "$(reclaim_all_in_snapshot "$fx_ref"',"since":"2026-06-01T12:30:00Z"}]' "$SNAPF" && echo present || echo missing)" "missing" \
  "...and missing when it was first seen after"
fx_rt='[{"ref":"runtime/org.kde.Platform/x86_64/6.9","commit":"'"$(printf 'c%.0s' {1..64})"'","eol":null,"offerable":true'
assert_eq "$(reclaim_all_in_snapshot "$fx_rt"',"since":"2026-06-01T10:00:00Z"}]' "$SNAPF" && echo present || echo missing)" "missing" \
  "...a rule for extensions only: a runtime the snapshot does not have stays missing"
: > "$SNAPF"
assert_eq "$(in_snap '["runtime/org.freedesktop.Platform/x86_64/24.08"]')" "missing" \
  "an empty snapshot proves nothing: every ref reads as missing"

# --- a listing too big for one argument ------------------------------------------------------------
# Linux caps one argument at 128 KiB, which about 460 installed refs pass. 1000 unused refs must
# still be listed, sized and offered.
jq -n --arg c "$(printf 'd%.0s' {1..64})" '{installation: "/var/lib/flatpak", used: [],
  unused: [range(1000) | {ref: "runtime/org.example.Big\(.)/x86_64/1", commit: $c,
                          deploy_dir: "/var/lib/flatpak/runtime/org.example.Big\(.)/x86_64/1/\($c)", eol: null}]}' > "$LISTING"
cp "$DU_TABLE" "$TESTTMP/du-before-big"
jq -r '.unused[].deploy_dir | "\(.)\t1000"' "$LISTING" > "$DU_TABLE"
rm -f "$RECLAIM_SIZES_FILE"
assert_eq "$(check | jq -c '.reclaim | [.status, (.refs | length)]')" '["ok",1000]' "a check lists 1000 unused refs"
age_state 7200
out="$(check)"
assert_eq "$(jq -c '.reclaim | [.status, (.refs | length), .offerable_bytes, (.digest | length)]' <<<"$out")" '["ok",1000,1000000,16]' \
  "...and, once they have aged, sizes and offers all of them"
assert_eq "$(check | jq -r '.reclaim.offerable_bytes')" "1000000" "...and serves the size from its cache"
rc=0; out="$("$KEMPT" reclaim --list </dev/null 2>&1)" || rc=$?
assert_eq "$rc|$(grep -c 'org.example.Big' <<<"$out")" "0|1000" "kempt reclaim --list shows all 1000"
cp "$TESTTMP/du-before-big" "$DU_TABLE"; cp "$UNUSED_FX" "$LISTING"; rm -f "$RECLAIM_SIZES_FILE"
check >/dev/null; age_state 7200; check >/dev/null

# --- a damaged size cache ---------------------------------------------------------------------------
# The cache is served only when its key matches AND every unused ref has a number in it.
assert_eq "$(check | jq -r '.reclaim.offerable_bytes')" "1975000000" "setup: the size cache holds all five"
for damage in '.sizes[.sizes | keys[0]] = "lots"' 'del(.sizes[.sizes | keys[0]])' '.sizes = []'; do
  jq "$damage" "$RECLAIM_SIZES_FILE" > "$TESTTMP/sz" && mv "$TESTTMP/sz" "$RECLAIM_SIZES_FILE"
  rm -f "$STUBS/du.calls"
  assert_eq "$(check | jq -c '.reclaim | [.offerable_bytes, .status]')|$(cat "$STUBS/du.calls" 2>/dev/null | wc -l)" \
    '[1975000000,"ok"]|1' "a size cache damaged by $damage is measured again, not served as unknown"
done

# --- time limits inside the check ------------------------------------------------------------------
# The check holds check.lock, and the widget gives a check 120 s. The listing gets 15 s and du 30 s,
# so both together stay well inside it. A stand-in `timeout` records the limit it was given, and
# answers 124 (time is up) for the command named in TIMEOUT_EXPIRE.
mkdir -p "$TESTTMP/tbin"
cat > "$TESTTMP/tbin/timeout" <<'STUB'
#!/usr/bin/env bash
echo "$1 $(basename "$2")" >> "$STUBS/timeout.calls"
[[ -n "${TIMEOUT_EXPIRE:-}" && "$(basename "$2")" == "$TIMEOUT_EXPIRE" ]] && exit 124
shift; exec "$@"
STUB
chmod +x "$TESTTMP/tbin/timeout"
rm -f "$RECLAIM_SIZES_FILE" "$STUBS/timeout.calls"
PATH="$TESTTMP/tbin:$PATH" check >/dev/null
assert_contains "$(cat "$STUBS/timeout.calls")" "15 unused" "the listing is given 15 seconds"
assert_contains "$(cat "$STUBS/timeout.calls")" "30 du" "...and du 30"
config_set reclaim automatic
rm -f "$STUBS/timeout.calls"
assert_eq "$(TIMEOUT_EXPIRE=getent PATH="$TESTTMP/tbin:$PATH" check | jq -r '.reclaim.mode')" "ask" \
  "an account lookup that runs out of time publishes ask"
assert_contains "$(cat "$STUBS/timeout.calls")" "5 getent" "...and it is given 5 seconds"
config_set reclaim ask
rm -f "$RECLAIM_SIZES_FILE"
out="$(TIMEOUT_EXPIRE=du PATH="$TESTTMP/tbin:$PATH" check)"
assert_eq "$(jq -c '.reclaim | [.offerable_bytes, .status]' <<<"$out")" '[null,"unknown_size"]' \
  "a du that runs out of time is an unknown size"
check >/dev/null

# --- kempt reclaim with no check on record ---------------------------------------------------------
# Nothing records when a ref became unused until a check lists it. kempt reclaim runs that check
# itself, so the hour starts now and a second try an hour later can remove them.
cp "$KEMPT_STATE_DIR/state.json" "$TESTTMP/state-before-first"
jq 'del(.reclaim)' "$TESTTMP/state-before-first" > "$KEMPT_STATE_DIR/state.json"
rc=0; out="$("$KEMPT" reclaim -y </dev/null 2>&1)" || rc=$?
assert_eq "$rc" "6" "first use, with no check on record: refused, exit 6"
assert_contains "$out" "These were first seen just now" "...saying they were first seen now"
assert_contains "$out" "Try again in an hour." "...and when to try again"
assert_contains "$out" "(first seen just now)" "...with each ref marked the same way"
assert_eq "$(state_reclaim | jq -c '[.status, (.refs | length)]')" '["ok",5]' \
  "...and a check has recorded when each was first seen"
assert_exit 0 "...and let go of the update lock" -- flock -n "$KEMPT_STATE_DIR/lock" true
assert_exit 0 "...and of the check lock" -- flock -n "$KEMPT_STATE_DIR/check.lock" true
age_state 7200
rc=0; out="$("$KEMPT" reclaim --list </dev/null 2>&1)" || rc=$?
assert_eq "$rc" "0" "an hour later the same list is on record"
assert_not_contains "$out" "first seen just now" "...and no longer called new"
assert_not_contains "$out" "less than an hour" "...nor too young to remove"
# --list says the same on first use. With an update holding the lock it lists without the check.
jq 'del(.reclaim)' "$TESTTMP/state-before-first" > "$KEMPT_STATE_DIR/state.json"
rc=0; out="$("$KEMPT" reclaim --list </dev/null 2>&1)" || rc=$?
assert_eq "$rc" "0" "reclaim --list on first use exits 0"
assert_contains "$out" "These were first seen just now. They can be removed in an hour." "...and says when they can go"
jq 'del(.reclaim)' "$TESTTMP/state-before-first" > "$KEMPT_STATE_DIR/state.json"
rc=0; out="$(flock "$KEMPT_STATE_DIR/lock" "$KEMPT" reclaim --list </dev/null 2>&1)" || rc=$?
assert_eq "$rc|$(state_reclaim)" "0|null" "with an update running, --list still lists and runs no check"
cp "$TESTTMP/state-before-first" "$KEMPT_STATE_DIR/state.json"

# --- kempt reclaim ----------------------------------------------------------------------------------
# Every ref has been unused for two hours now, so the whole set is on offer under DIGEST5.
jq '.unused = []' "$UNUSED_FX" > "$AFTER"   # what a removal that took everything leaves behind
reclaim() { "$KEMPT" reclaim "$@" </dev/null 2>&1; }
calls() { cat "$STUBS/$1.calls" 2>/dev/null || echo "(none)"; }
reset_calls() { rm -f "$STUBS"/uninstall.calls "$STUBS"/pkcheck.calls; }
# Back to all five unused and offerable: the listing restored, one check to record them, aged.
restore_offer() { cp "$UNUSED_FX" "$LISTING"; check >/dev/null; age_state 7200; check >/dev/null; reset_calls; }
reset_calls

rc=0; out="$(reclaim --list)" || rc=$?
assert_eq "$rc" "0" "reclaim --list exits 0"
assert_contains "$out" "No installed app uses these Flatpak runtimes:" "...under a plain heading"
assert_contains "$out" "  runtime/org.freedesktop.Platform.GL.default/x86_64/24.08extra" "...one ref per line"
assert_contains "$out" "runtime/org.kde.Platform/x86_64/5.15-23.08 (no longer supported)" "...an end-of-life one marked, in the widget's words"
assert_contains "$out" "Removing them frees about 2.0 GB." "...and the estimate, said as one"
assert_eq "$(calls uninstall)" "(none)" "...and removes nothing"

rc=0; out="$(reclaim)" || rc=$?
assert_eq "$rc" "5" "no -y and no terminal to ask on: refused, exit 5"
assert_contains "$out" "Run kempt reclaim -y" "...saying how to remove without being asked"
assert_eq "$(calls uninstall)" "(none)" "...and nothing removed"

assert_exit 2 "--expect takes a digest and nothing else" -- "$KEMPT" reclaim -y --expect=HEAD
assert_exit 2 "an unknown option is a usage error" -- "$KEMPT" reclaim --force

rc=0; out="$(reclaim -y --expect=0123456789abcdef)" || rc=$?
assert_eq "$rc" "6" "a digest that is not the set on offer: exit 6"
assert_contains "$out" "What Flatpak can remove changed since this was shown. Nothing was removed." "...in the widget's words"
assert_eq "$(calls uninstall)" "(none)" "...and nothing removed"
assert_eq "$(jq -r '.result' "$RECLAIM_LAST_FILE")" "changed" "...recorded as the last outcome"
assert_contains "$(tail -n 3 "$EVENTS_FILE")" "reclaim changed (digest), nothing removed" "...and in the event log"

# Every runtime on the offer in use again: the set changed, not "nothing to remove", and the check
# that follows takes the offer out of state.json so the widget stops showing it.
jq '.used += .unused | .unused = []' "$UNUSED_FX" > "$LISTING"
rc=0; out="$(reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$rc|$(calls uninstall)" "6|(none)" "an offer whose runtimes are all in use again: exit 6, nothing removed"
assert_contains "$out" "What Flatpak can remove changed since this was shown." "...in the widget's words"
assert_eq "$(jq -r '.result' "$RECLAIM_LAST_FILE")" "changed" "...recorded as the last outcome"
assert_contains "$(tail -n 3 "$EVENTS_FILE")" "reclaim changed (digest), nothing removed" "...and in the event log"
assert_eq "$(state_reclaim | jq -r '.digest')" "" "...and the offer is gone from state.json"
rc=0; out="$(reclaim -y)" || rc=$?
assert_eq "$rc" "0" "the same, with no offer named: nothing to remove, exit 0"
assert_contains "$out" "Nothing to remove." "...said as such"
restore_offer

# A set that grew: one more unused ref than was shown means the removal would take it too, unseen.
jq '.unused += [{"ref":"runtime/org.gnome.Platform/x86_64/46","commit":"'"$(printf 'g%.0s' {1..64} | tr g a)"'",
     "deploy_dir":"/var/lib/flatpak/runtime/org.gnome.Platform/x86_64/46/aa","eol":null}]' "$UNUSED_FX" > "$LISTING"
rc=0; out="$(reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$rc" "6" "one ref more than was shown: exit 6"
assert_eq "$(calls uninstall)" "(none)" "...and nothing removed"
# The same set without --expect, where the extra ref has only just been seen: too new to remove,
# and said before any question is asked.
rc=0; out="$(reclaim -y)" || rc=$?
assert_eq "$rc" "6" "a ref unused for less than an hour blocks the removal: exit 6"
assert_contains "$out" "Kempt waits an hour" "...saying why"
assert_eq "$(calls uninstall)" "(none)" "...and nothing removed"
rc=0; out="$(reclaim)" || rc=$?
assert_eq "$rc" "6" "...refused before the question, not after it"
assert_not_contains "$out" "Remove them?" "...so nobody is asked to agree to a removal that cannot happen"
cp "$UNUSED_FX" "$LISTING"

# Permission: asked of polkit without a dialog, and a no is needs_auth, not a prompt.
rc=0; out="$(PKCHECK_RC=1 reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$rc" "5" "polkit would ask for a password: exit 5"
assert_contains "$out" "Removing these needs an administrator. Nothing was removed." "...in the widget's words"
assert_eq "$(calls uninstall)" "(none)" "...and nothing removed"
assert_contains "$(calls pkcheck)" "--action-id org.freedesktop.Flatpak.runtime-uninstall --process " \
  "the permission asked is flatpak's own removal action, for this process"
assert_not_contains "$(calls pkcheck)" "--allow-user-interaction" "...never allowed to raise a dialog"
assert_eq "$(state_reclaim | jq -r '.status')" "needs_auth" "the closing check publishes needs_auth"
assert_eq "$(state_reclaim | jq -r '.last.result')" "needs_auth" "...with the outcome as last"
# A polkit that never answers is a no, within the bound, not a removal that waits with the lock.
rc=0; out="$(PKCHECK_HANG=1 KEMPT_RECLAIM_PKCHECK_TIMEOUT=1 reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$rc|$(calls uninstall)" "5|(none)" "a pkcheck that hangs: needs an administrator, nothing removed"
reset_calls

hist_before="$(find "$HIST_DIR" -name '*.json' 2>/dev/null | wc -l)"
rc=0; out="$(reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$rc" "0" "the set on offer, allowed: removed, exit 0"
assert_eq "$(calls uninstall)" "$REFS5" "flatpak is given the refs on offer by name"
assert_contains "$out" "Uninstalling..." "flatpak's own output is shown"
assert_contains "$out" "Freed about 2.0 GB." "...then what was freed"
assert_json_eq "$(jq -c '{via, result, refs, bytes, digest}' "$RECLAIM_LAST_FILE")" \
  "{\"via\":\"cli\",\"result\":\"removed\",\"refs\":$ALL5,\"bytes\":1975000000,\"digest\":\"$DIGEST5\"}" \
  "the outcome names the refs that went, their size and the set agreed to"
assert_contains "$(tail -n 3 "$EVENTS_FILE")" "reclaim removed 5 runtimes (1975000000 bytes)" "...and the event log says it"
assert_eq "$(state_reclaim | jq -c '[.refs, .digest, .status, .last.result]')" '[[],"","ok","removed"]' \
  "the closing check publishes that nothing is left to offer"
assert_eq "$(find "$HIST_DIR" -name '*.json' 2>/dev/null | wc -l)" "$hist_before" \
  "a removal writes no history entry: the last run is still the last update"
assert_exit 0 "...and leaves the update lock free" -- flock -n "$KEMPT_STATE_DIR/lock" true

rc=0; out="$(reclaim -y)" || rc=$?
assert_eq "$rc" "0" "nothing unused: exit 0"
assert_eq "$out" "Nothing to remove. Every installed Flatpak runtime is in use." "...in plain words"

# There is no way past the permission check: flatpak's --noninteractive transaction never shows a
# polkit dialog, so a removal polkit would ask about can only fail.
restore_offer
rc=0; out="$(PKCHECK_RC=1 reclaim -y --expect="$DIGEST5" --allow-auth)" || rc=$?
assert_eq "$rc|$(calls uninstall)" "2|(none)" "--allow-auth is not an option: a usage error, nothing removed"

# Only some of the set went: the refs really gone are what counts, and so are only their bytes.
restore_offer
jq '.unused = [.unused[] | select(.ref | test("kde"))]' "$UNUSED_FX" > "$AFTER"
rc=0; out="$(reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$(jq -c '[(.refs | length), .bytes]' "$RECLAIM_LAST_FILE")" '[4,1075000000]' \
  "a partial removal counts only the refs gone, at their own sizes"
jq '.unused = []' "$UNUSED_FX" > "$AFTER"

# With no size to give, the count is said instead, and one is said as one.
restore_offer
jq '.unused = .unused[1:]' "$UNUSED_FX" > "$AFTER"
mv "$DU_TABLE" "$DU_TABLE.off"; rm -f "$RECLAIM_SIZES_FILE"
rc=0; out="$(reclaim -y --expect="$DIGEST5")" || rc=$?
mv "$DU_TABLE.off" "$DU_TABLE"
assert_contains "$out" "Removed 1 runtime." "one runtime removed with no size known is said in the singular"
jq '.unused = []' "$UNUSED_FX" > "$AFTER"

restore_offer
rc=0; out="$(UNINSTALL_RC=1 reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$rc" "1" "a removal flatpak fails: exit 1"
assert_contains "$out" "Flatpak could not remove them: error: removal failed" "...said plainly, with flatpak's reason"
assert_eq "$(state_reclaim | jq -c '[.status, .digest]')" "[\"failed\",\"$DIGEST5\"]" \
  "the closing check publishes failed, for this set only"

# Flatpak's reason is kept: on screen, in the event log and in the last outcome. The last line
# starting with "error:" wins over any later line, and it is made safe first: one line, no colour
# codes or control characters, 200 characters at most.
FP_ERR="error: Failed to uninstall runtime/org.kde.Platform/x86_64/5.15-23.08: No such file or directory"
printf 'Uninstalling 5 refs\n\033[1m%s\033[0m\r\n\nwarning: something after it\n' "$FP_ERR" > "$TESTTMP/fp-out"
restore_offer
rc=0; out="$(UNINSTALL_OUT="$TESTTMP/fp-out" UNINSTALL_RC=1 reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$rc" "1" "a removal flatpak refuses: exit 1"
assert_contains "$out" "Flatpak could not remove them: $FP_ERR" "...saying what flatpak said"
assert_eq "$(jq -r '.error' "$RECLAIM_LAST_FILE")" "$FP_ERR" "...kept as the last outcome's error, cleaned"
assert_eq "$(jq -c '[.result, .refs, .bytes]' "$RECLAIM_LAST_FILE")" '["failed",[],0]' \
  "...next to the fields the widget reads, unchanged"
assert_contains "$(grep 'reclaim failed' "$EVENTS_FILE" | tail -n 1)" "reclaim failed rc=1: $FP_ERR" \
  "...and in the event log, with the exit code"
assert_eq "$(state_reclaim | jq -r '.last.error')" "$FP_ERR" "...and in state.json after the closing check"
# polkit refusing flatpak's system helper after pkcheck said yes is the same answer as the gate's no.
printf 'error: Failed to uninstall runtime/org.kde.Platform/x86_64/5.15-23.08: Flatpak system operation Uninstall not allowed for user\n' > "$TESTTMP/fp-out"
restore_offer
rc=0; out="$(UNINSTALL_OUT="$TESTTMP/fp-out" UNINSTALL_RC=1 reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$rc|$(jq -r '.result' "$RECLAIM_LAST_FILE")" "5|needs_auth" \
  "flatpak's \"not allowed for user\" is needs_auth: exit 5"
assert_contains "$out" "Removing these needs an administrator. Nothing was removed." "...in the widget's words"
# No error line: the last line that says anything. A long one is cut, and a tab is dropped.
printf 'Uninstalling\n%s\tend\n\n' "$(printf 'x%.0s' {1..300})" > "$TESTTMP/fp-out"
restore_offer
rc=0; out="$(UNINSTALL_OUT="$TESTTMP/fp-out" UNINSTALL_RC=2 reclaim -y --expect="$DIGEST5" 2>/dev/null)" || rc=$?
kept="$(jq -r '.error' "$RECLAIM_LAST_FILE")"
assert_eq "${#kept}|$(tr -d 'x' <<<"$kept")" "200|" "with no error line, the last non-empty one, cut to 200 characters"
assert_eq "$(grep -c 'reclaim failed rc=2' "$EVENTS_FILE")|$(grep 'reclaim failed rc=2' "$EVENTS_FILE" | tr -d '[:print:]' | wc -c)" "1|1" \
  "...and the event stays one printable line"

# The removal is given ten minutes: one that hangs must not hold the update lock for ever, and
# running out of time is a failure like any other.
restore_offer
rm -f "$STUBS/timeout.calls"
rc=0; out="$(TIMEOUT_EXPIRE=uninstall PATH="$TESTTMP/tbin:$PATH" reclaim -y --expect="$DIGEST5")" || rc=$?
assert_contains "$(cat "$STUBS/timeout.calls" 2>/dev/null)" "600 uninstall" "the removal is given 600 seconds"
assert_eq "$rc|$(jq -r '.result' "$RECLAIM_LAST_FILE")" "1|failed" "...and one that runs out of time is a failure: exit 1"
assert_contains "$(tail -n 3 "$EVENTS_FILE")" "failed rc=124" "...logged with its exit code"
assert_contains "$out" "Flatpak could not remove them (exit code 124). See: kempt log" \
  "...and with nothing said, the exit code on screen and the log that keeps it"
assert_eq "$(jq -r 'has("error")' "$RECLAIM_LAST_FILE")" "false" "...where there is no error line to keep"

# The last thing before the removal is the re-list and its comparison. An app that starts needing a
# runtime while polkit answers must stop the removal, so the permission check comes before that last
# look. (The same for du, which only the automatic step can reach uncached: test_update.sh.)
jq '.used += [.unused[0]] | .unused = .unused[1:]' "$UNUSED_FX" > "$TESTTMP/now-used.json"
restore_offer
rc=0; out="$(PKCHECK_SWAP="$TESTTMP/now-used.json" reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$rc|$(calls uninstall)" "6|(none)" "a runtime that became used while polkit answered is not removed"

# What went is everything installed before minus what is left, so a removal that took more than the
# list is reported as it happened.
restore_offer
jq '.unused = [] | .used = .used[1:]' "$UNUSED_FX" > "$AFTER"
rc=0; out="$(reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$(jq -c '.refs | length' "$RECLAIM_LAST_FILE")|$(jq -r '.refs | index("app/net.mkiol.SpeechNote/x86_64/stable") != null' "$RECLAIM_LAST_FILE")" \
  "6|true" "an extra ref that went is named among the refs gone"
assert_eq "$(jq -r '.bytes' "$RECLAIM_LAST_FILE")" "1975000000" \
  "...and adds nothing to the space freed, which counts only the refs on offer"
jq '.unused = []' "$UNUSED_FX" > "$AFTER"

# A runtime an app starts needing between the last look and the removal is only named, never
# forced: flatpak refuses to remove a runtime an installed app uses, and it stays.
cat > "$STUBS/uninstall-used" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUBS/uninstall.calls"
keep="runtime/org.kde.Platform/x86_64/5.15-23.08"
jq --arg k "$keep" '.used += [.unused[] | select(.ref == $k)] | .unused = []' "$LISTING" > "$LISTING.new" \
  && mv "$LISTING.new" "$LISTING"
echo "error: Failed to uninstall $keep: Can't remove $keep, it is needed for: app/org.example.App/x86_64/stable" >&2
exit 1
STUB
chmod +x "$STUBS/uninstall-used"
restore_offer
rc=0; out="$(KEMPT_FLATPAK_UNINSTALL_CMD="$STUBS/uninstall-used" reclaim -y --expect="$DIGEST5")" || rc=$?
assert_not_contains "$(calls uninstall)" "--force-remove" "a removal never forces out a runtime an app uses"
assert_eq "$(jq -r '.refs | index("runtime/org.kde.Platform/x86_64/5.15-23.08")' "$RECLAIM_LAST_FILE")|$(jq -r '.refs | length' "$RECLAIM_LAST_FILE")" \
  "null|4" "...so the runtime that became used in the gap is not among the refs gone"
# Flatpak failing part-way is reported as it happened: what was freed, flatpak's error, and exit 1.
assert_eq "$rc" "1" "a removal flatpak stopped part-way: exit 1"
assert_contains "$out" "Freed about 1.1 GB." "...saying what it freed"
assert_contains "$out" "Flatpak could not remove all of them: error: Failed to uninstall runtime/org.kde.Platform/x86_64/5.15-23.08" \
  "...and flatpak's error"
assert_eq "$(jq -c '[.result, .partial, .bytes]' "$RECLAIM_LAST_FILE")" '["removed",true,1075000000]' \
  "...recorded as removed and partial, with the bytes of the refs that went"
assert_contains "$(grep 'reclaim removed' "$EVENTS_FILE" | tail -n 1)" "reclaim removed 4 runtimes (1075000000 bytes) rc=1, not all of them: error: Failed" \
  "...and in the event log"

# Flatpak failed and the list afterwards cannot be read: what went is unknown, never "nothing".
cat > "$STUBS/uninstall-blind" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUBS/uninstall.calls"
touch "$STUBS/unused.fail"
echo "error: Failed to uninstall runtime/org.kde.Platform/x86_64/5.15-23.08: interrupted" >&2
exit 1
STUB
chmod +x "$STUBS/uninstall-blind"
restore_offer
rc=0; out="$(KEMPT_FLATPAK_UNINSTALL_CMD="$STUBS/uninstall-blind" reclaim -y --expect="$DIGEST5")" || rc=$?
rm -f "$STUBS/unused.fail"
assert_eq "$rc" "1" "a failed removal whose outcome cannot be read: exit 1"
assert_contains "$out" "the removal may be partial. Check again with: kempt reclaim --list" "...saying it may be partial"
assert_not_contains "$out" "Nothing was removed" "...and never that nothing was removed"
assert_eq "$(jq -c '[.result, .refs, .bytes, .partial]' "$RECLAIM_LAST_FILE")" '["failed",null,null,true]' \
  "...recorded with refs null and partial, so no reader counts it as nothing"
assert_contains "$(grep 'reclaim failed' "$EVENTS_FILE" | tail -n 1)" "what was removed is unknown" "...and the event log says so"

# flatpak's output is copied to a file in Kempt's own state dir, never the shared /tmp, and the
# file goes with kempt: at the end of a removal, and from the EXIT trap when kempt is killed.
cat > "$STUBS/uninstall-peek" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUBS/uninstall.calls"
ls "$KEMPT_STATE_DIR"/reclaim-out.* 2>/dev/null | wc -l > "$STUBS/peek"
ls "$TMPDIR" | wc -l >> "$STUBS/peek"
[[ -n "${PEEK_KILL:-}" ]] && { kill -TERM "$(ps -o ppid= -p "$PPID" | tr -d ' ')"; sleep 1; exit 1; }
[[ -f "$AFTER" ]] && cp "$AFTER" "$LISTING"
STUB
chmod +x "$STUBS/uninstall-peek"
mkdir -p "$TESTTMP/tmpdir"
restore_offer
rc=0; out="$(TMPDIR="$TESTTMP/tmpdir" KEMPT_FLATPAK_UNINSTALL_CMD="$STUBS/uninstall-peek" reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$rc|$(tr '\n' ' ' < "$STUBS/peek")" "0|1 0 " "the removal keeps flatpak's output in Kempt's state dir, not in TMPDIR"
assert_eq "$(ls "$KEMPT_STATE_DIR"/reclaim-out.* 2>/dev/null | wc -l)" "0" "...and removes it afterwards"
restore_offer
rc=0; out="$(PEEK_KILL=1 KEMPT_FLATPAK_UNINSTALL_CMD="$STUBS/uninstall-peek" reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$rc|$(head -1 "$STUBS/peek")" "143|1" "premise: kempt was killed while the file existed"
assert_eq "$(ls "$KEMPT_STATE_DIR"/reclaim-out.* 2>/dev/null | wc -l)" "0" "...and its EXIT trap removed the file"
assert_exit 0 "...and still released the update lock" -- flock -n "$KEMPT_STATE_DIR/lock" true
# A kill no trap sees leaves the file for the next run's sweep, once it is an hour old.
touch -d '2 hours ago' "$KEMPT_STATE_DIR/reclaim-out.stale"
restore_offer; reclaim --list >/dev/null 2>&1 || true
assert_eq "$([[ -e "$KEMPT_STATE_DIR/reclaim-out.stale" ]] && echo left || echo swept)" "swept" \
  "a copy left by a kempt killed outright is swept after an hour"

# A long list of refs passes through jq as files, not arguments: Linux caps one argument at 128 KiB,
# and past it the gone set and its size would silently read as nothing. reclaim_remove alone, with
# the listing, the gate and the record stubbed.
BIG="$TESTTMP/big"; mkdir -p "$BIG"
jq -cn '{installation: "/var/lib/flatpak", used: [],
  unused: [range(1000) | {ref: ("runtime/org.example.Platform.Extension.With.A.Long.Name.Number\(.)/x86_64/"
    + ("x" * 60)), commit: "c", deploy_dir: "/d", eol: null}]}' > "$BIG/before.json"
jq -r '.unused[].ref + "\t1000000"' "$BIG/before.json" > "$BIG/sizes.tsv"
assert_eq "$(( $(jq -c '[.unused[].ref]' "$BIG/before.json" | wc -c) > 131072 ))" "1" \
  "premise: the synthetic gone set is past the 128 KiB argument limit"
big_out="$(
  trap - EXIT  # the sandbox's cleanup is the parent's: this subshell must not run it on exit
  export KEMPT_STATE_DIR="$BIG" KEMPT_FLATPAK_UNINSTALL_CMD=true
  eval "$(sed -n '/^reclaim_remove() {/,/^}/p' "$KEMPT")"
  flatpak_unused_list() {
    local n; n=$(( $(cat "$BIG/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$BIG/calls"
    if (( n <= 2 )); then cat "$BIG/before.json"; else jq -c '.unused = []' "$BIG/before.json"; fi
  }
  flatpak_unused_sizes() { cat "$BIG/sizes.tsv"; }
  reclaim_compare() { RECLAIM_DIGEST=d; return 0; }
  reclaim_authorized() { return 0; }
  reclaim_record() { :; }
  reclaim_remove cli d >/dev/null
  printf '%s|%s|%s' "$RECLAIM_RESULT" "$(jq length <<<"$RECLAIM_GONE")" "$RECLAIM_BYTES"
)"
assert_eq "$big_out" "removed|1000|1000000000" "a removal of 1000 refs records all of them and their size"

# The removal command as shipped, through a stand-in flatpak. Without --no-related, flatpak also
# removes the related refs of what it removes, even one another installed runtime still uses.
restore_offer
mkdir -p "$TESTTMP/fpbin"
cat > "$TESTTMP/fpbin/flatpak" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == uninstall ]] || exit 0
echo "$*" >> "$STUBS/uninstall.calls"
[[ -f "$AFTER" ]] && cp "$AFTER" "$LISTING"
exit 0
STUB
chmod +x "$TESTTMP/fpbin/flatpak"
rc=0; out="$(env -u KEMPT_FLATPAK_UNINSTALL_CMD PATH="$TESTTMP/fpbin:$PATH" \
  "$KEMPT" reclaim -y --expect="$DIGEST5" </dev/null 2>&1)" || rc=$?
assert_eq "$rc|$(calls uninstall)" "0|uninstall --system --no-related --noninteractive $REFS5" \
  "the removal names the refs on offer and passes --no-related, so it takes those refs and no related ref besides"
restore_offer

# Refusals that come before anything is listed.
reset_calls
rc=0; out="$(SUDO_UID=1000 reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$rc" "5" "under sudo: refused, exit 5"
assert_contains "$out" "not as root" "...saying why"
rc=0; PKEXEC_UID=1000 reclaim -y >/dev/null || rc=$?
assert_eq "$rc" "5" "under pkexec: the same"
config_set reclaim off
rc=0; out="$(reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$rc" "5" "reclaim=off: removal refused, exit 5"
assert_exit 0 "...while --list still shows what could go" -- "$KEMPT" reclaim --list
config_set reclaim ask
config_set include_flatpak false
assert_exit 5 "include_flatpak=false: refused" -- "$KEMPT" reclaim -y
config_set include_flatpak true
assert_exit 3 "an update holding the lock: exit 3, without waiting" -- \
  flock "$KEMPT_STATE_DIR/lock" "$KEMPT" reclaim -y --expect="$DIGEST5"
assert_eq "$(calls uninstall)" "(none)" "and none of those removed anything"
rc=0; out="$(UNUSED_FAIL=1 reclaim -y)" || rc=$?
assert_eq "$rc" "1" "a listing that fails: exit 1, nothing removed"

finish
