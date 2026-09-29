#!/usr/bin/env bash
# Reclaiming disk space: the Flatpak refs nothing installed uses. The listing helper, the size
# estimate, the stability rule, the reclaim block in state.json and `kempt reclaim` itself.
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
KEMPT="$REPO_ROOT/bin/kempt"
HELPER="$REPO_ROOT/libexec/kempt-flatpak-unused"
UNUSED_FX="$FIXTURES/flatpak-unused.json"

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
assert_eq "$(head -1 "$HELPER")" "#!/usr/bin/python3" "the helper names its interpreter absolutely"
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
[[ -n "${UNUSED_FAIL:-}" ]] && { echo "flatpak did not answer" >&2; exit 1; }
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
[[ -n "${UNINSTALL_RC:-}" && "$UNINSTALL_RC" != 0 ]] && { echo "error: removal failed" >&2; exit "$UNINSTALL_RC"; }
[[ -f "$AFTER" ]] && cp "$AFTER" "$LISTING"
echo "Uninstalling..."
STUB
cat > "$STUBS/pkcheck" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUBS/pkcheck.calls"
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

# --- the reclaim block: first sighting --------------------------------------------------------------
out="$(check)"
assert_eq "$(jq -r '.reclaim.mode' <<<"$out")" "ask" "a check publishes the reclaim block, mode ask by default"
assert_eq "$(jq -c '[.reclaim.refs[].ref]' <<<"$out")" "$ALL5" "...listing every unused ref"
assert_eq "$(jq -c '.reclaim.refs[0] | keys' <<<"$out")" '["commit","eol","ref","since"]' \
  "...each with its commit, since and end-of-life reason"
assert_eq "$(jq -r '.reclaim.refs[4].eol' <<<"$out")" \
  "We strongly recommend moving to the latest stable version of the Platform and SDK" "...the reason carried as flatpak gave it"
# Seen for the first time, so none has been unused for an hour: nothing is offered yet.
assert_eq "$(jq -c '.reclaim | [.offerable_bytes, .digest, .status]' <<<"$out")" '[0,"","ok"]' \
  "refs seen unused for the first time are not offered: no bytes, no digest"
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

# Part of the set offerable: a ref whose commit changed starts again.
jq '(.unused[] | select(.ref | endswith("24.08extra"))).commit = ("e" * 64)' "$UNUSED_FX" > "$LISTING"
out="$(check)"
assert_eq "$(jq -r '.reclaim.refs[] | select(.ref | endswith("24.08extra")) | .since' <<<"$out" | cut -c1-10)" \
  "$(date -u +%Y-%m-%d)" "a ref whose commit changed is a new sighting"
assert_eq "$(jq -r '.reclaim.offerable_bytes' <<<"$out")" "1955000000" "...and drops out of the offer until it has aged"
assert_eq "$(wc -l < "$STUBS/du.calls")" "2" "...and a changed commit means a new size estimate"
assert_eq "$([[ "$(jq -r '.reclaim.digest' <<<"$out")" != "$DIGEST5" ]] && echo differs)" "differs" \
  "...under a different digest"
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
realdu_sizes="$(KEMPT_DU_CMD=du flatpak_unused_sizes "$realdu_listing")" || realdu_sizes="rc=$?"
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
config_set reclaim nonsense
assert_eq "$(check | jq -r '.reclaim.mode')" "ask" "an unknown value publishes ask"
config_set reclaim ask
age_state 7200
check >/dev/null

finish
