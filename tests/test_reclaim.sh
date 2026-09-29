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
[[ -n "${PKCHECK_SWAP:-}" ]] && cp "$PKCHECK_SWAP" "$LISTING"
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
config_set reclaim nonsense
assert_eq "$(check | jq -r '.reclaim.mode')" "ask" "an unknown value publishes ask"
config_set reclaim ask
age_state 7200
check >/dev/null

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
rm -f "$RECLAIM_SIZES_FILE"
out="$(TIMEOUT_EXPIRE=du PATH="$TESTTMP/tbin:$PATH" check)"
assert_eq "$(jq -c '.reclaim | [.offerable_bytes, .status]' <<<"$out")" '[null,"unknown_size"]' \
  "a du that runs out of time is an unknown size"
check >/dev/null

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
reset_calls

hist_before="$(find "$HIST_DIR" -name '*.json' 2>/dev/null | wc -l)"
rc=0; out="$(reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$rc" "0" "the set on offer, allowed: removed, exit 0"
assert_eq "$(calls uninstall)" "--noninteractive" "flatpak removes with --noninteractive when nobody pressed anything"
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

# The widget's button: a person pressed it, so no permission check and no --noninteractive.
restore_offer
rc=0; out="$(PKCHECK_RC=1 reclaim -y --expect="$DIGEST5" --allow-auth)" || rc=$?
assert_eq "$rc" "0" "--allow-auth removes where polkit would ask"
assert_eq "$(calls pkcheck)" "(none)" "...without the no-dialog check"
assert_eq "$(calls uninstall)" "" "...and lets flatpak raise the dialog"

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
assert_contains "$out" "Flatpak could not remove them." "...said plainly"
assert_eq "$(state_reclaim | jq -c '[.status, .digest]')" "[\"failed\",\"$DIGEST5\"]" \
  "the closing check publishes failed, for this set only"

# The removal is given ten minutes: one that hangs must not hold the update lock for ever, and
# running out of time is a failure like any other.
restore_offer
rm -f "$STUBS/timeout.calls"
rc=0; out="$(TIMEOUT_EXPIRE=uninstall PATH="$TESTTMP/tbin:$PATH" reclaim -y --expect="$DIGEST5")" || rc=$?
assert_contains "$(cat "$STUBS/timeout.calls" 2>/dev/null)" "600 uninstall" "the removal is given 600 seconds"
assert_eq "$rc|$(jq -r '.result' "$RECLAIM_LAST_FILE")" "1|failed" "...and one that runs out of time is a failure: exit 1"
assert_contains "$(tail -n 3 "$EVENTS_FILE")" "failed rc=124" "...logged with its exit code"

# The last thing before the removal is the re-list and its comparison. An app that starts needing a
# runtime while polkit answers must stop the removal, so the permission check comes before that last
# look. (The same for du, which only the automatic step can reach uncached: test_update.sh.)
jq '.used += [.unused[0]] | .unused = .unused[1:]' "$UNUSED_FX" > "$TESTTMP/now-used.json"
restore_offer
rc=0; out="$(PKCHECK_SWAP="$TESTTMP/now-used.json" reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$rc|$(calls uninstall)" "6|(none)" "a runtime that became used while polkit answered is not removed"

# What went is everything installed before minus what is left, so a removal that took more than the
# list (flatpak works its list out again when it runs) is reported as it happened.
restore_offer
jq '.unused = [] | .used = .used[1:]' "$UNUSED_FX" > "$AFTER"
rc=0; out="$(reclaim -y --expect="$DIGEST5")" || rc=$?
assert_eq "$(jq -c '.refs | length' "$RECLAIM_LAST_FILE")|$(jq -r '.refs | index("app/net.mkiol.SpeechNote/x86_64/stable") != null' "$RECLAIM_LAST_FILE")" \
  "6|true" "an extra ref that went is named among the refs gone"
assert_eq "$(jq -r '.bytes' "$RECLAIM_LAST_FILE")" "1975000000" \
  "...and adds nothing to the space freed, which counts only the refs on offer"
jq '.unused = []' "$UNUSED_FX" > "$AFTER"

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
assert_eq "$rc|$(calls uninstall)" "0|uninstall --unused --no-related --system -y --noninteractive" \
  "the removal passes --no-related, so it takes the listed refs and no related ref besides"
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
