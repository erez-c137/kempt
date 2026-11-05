#!/usr/bin/env bash
# Reclaiming disk space: the Flatpak refs nothing installed uses. The listing helper, the size
# estimate, the reclaim block in state.json and `kempt reclaim` itself.
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
# A terminal escape loses its ESC, so it can do nothing, and its text stays: the widget shows plain text.
assert_eq "$(printf 'error: \033[1mbad\033[0m\r\n' | error_line_of)" "error: [1mbad[0m" "...with control characters removed"
# 200 characters, cut on a character boundary: the result is still valid UTF-8.
long="$(printf 'error: %s' "$(printf '\xc3\xa9%.0s' {1..300})" | error_line_of)"
assert_eq "$(printf '%s' "$long" | LC_ALL=C.UTF-8 wc -m)|$(printf '%s' "$long" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && echo valid)" "200|valid" \
  "...cut to 200 characters without splitting one"

# --- the listing helper ---------------------------------------------------------------------------
# Run against a stand-in for PyGObject (tests/fixtures/fake-gi) that serves the fixture's refs, so
# this needs python3 and nothing else: no libflatpak, no system installation, no network.
helper() { PYTHONPATH="$FIXTURES/fake-gi" PYTHONDONTWRITEBYTECODE=1 "$HELPER" "$@"; }
if command -v python3 >/dev/null 2>&1; then
  # The fixture's installation moved to a directory with a repo in it, as a real one has.
  HFX="$TESTTMP/helper-fx.json"; mkdir -p "$TESTTMP/inst/repo"
  jq --arg p "$TESTTMP/inst" '.installation = $p' "$UNUSED_FX" > "$HFX"
  export FAKE_FLATPAK_JSON="$HFX" FAKE_FLATPAK_CALLS="$TESTTMP/fake-calls"
  hout="$(helper)" || hout="rc=$?"
  assert_json_eq "$hout" "$(jq 'del(.installation)' "$HFX")" \
    "the helper prints the unused refs, and the rest as used"
  # new_user() creates ~/.local/share/flatpak/repo as a side effect, so the helper must never call it.
  assert_eq "$(cat "$TESTTMP/fake-calls")" "new_system" "the helper opens the system installation and nothing else"
  rc=0; FAKE_FLATPAK_FAIL="boom" helper >"$TESTTMP/hout" 2>"$TESTTMP/herr" || rc=$?
  assert_eq "$rc|$(wc -c < "$TESTTMP/hout")" "1|0" "a library that fails is a non-zero exit with nothing on stdout"
  assert_contains "$(cat "$TESTTMP/herr")" "flatpak did not answer: boom" "...and the reason on stderr"
  rc=0; PYTHONPATH="$TESTTMP/no-such-dir" PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 python3 -S "$HELPER" \
    >/dev/null 2>"$TESTTMP/herr" || rc=$?
  assert_eq "$rc" "3" "no PyGObject at all is exit 3"
  # flatpak installed, nothing ever installed with it: no repo yet, and nothing to list.
  jq --arg p "$TESTTMP/no-repo" '.installation = $p' "$UNUSED_FX" > "$TESTTMP/norepo-fx.json"
  rc=0; hout="$(FAKE_FLATPAK_JSON="$TESTTMP/norepo-fx.json" helper 2>/dev/null)" || rc=$?
  assert_eq "$rc|$(jq -c '[.unused, .used]' <<<"$hout" 2>/dev/null)" "0|[[],[]]" \
    "a system installation with no repository yet lists nothing, and is not a failure"
  assert_exit 2 "the helper takes no arguments" -- env PYTHONPATH="$FIXTURES/fake-gi" "$HELPER" --user
  # -s keeps a `gi` in the user's site-packages from shadowing the system one. Proved with
  # usercustomize, which Python imports from the user site at startup unless -s is given.
  export PYTHONUSERBASE="$TESTTMP/userbase"
  usite="$(python3 -c 'import site; print(site.getusersitepackages())')"
  mkdir -p "$usite"
  printf 'open(%s, "w").write("loaded")\n' "'$TESTTMP/usersite-loaded'" > "$usite/usercustomize.py"
  helper >/dev/null 2>&1 || true
  assert_eq "$(cat "$TESTTMP/usersite-loaded" 2>/dev/null || echo "not loaded")" "not loaded" \
    "nothing in the user's site-packages is loaded"
  unset PYTHONUSERBASE FAKE_FLATPAK_JSON FAKE_FLATPAK_CALLS
else
  skip "python3 not installed: the listing helper was not run"
fi
assert_exit 0 "the helper is executable in the tree" -- test -x "$HELPER"

# --- the removal is by name, and never with related refs ------------------------------------------
# On a VM `flatpak uninstall --unused` removed a codecs extension another installed GNOME Platform
# needed. The seam's default is the whole of that protection, so it is read from the real file.
default_cmd="$(sed -n 's/^KEMPT_FLATPAK_UNINSTALL_CMD="\${KEMPT_FLATPAK_UNINSTALL_CMD:-\(.*\)}"$/\1/p' "$REPO_ROOT/backends/flatpak.sh")"
assert_eq "$default_cmd" "flatpak uninstall --system --no-related -y" \
  "the removal is system scope, without related refs, and never --unused"

# --- stubs for everything the CLI runs ------------------------------------------------------------
# The listing stub serves $LISTING, or $LISTING.<n> for its n-th call when that exists; the removal
# stub logs each argument on its own line and swaps in $AFTER, the way a real removal changes the
# next listing. du is the real command's shape, from a table keyed by path.
STUBS="$TESTTMP/stubs"; mkdir -p "$STUBS"
LISTING="$TESTTMP/listing.json"; AFTER="$TESTTMP/after.json"; DU_TABLE="$TESTTMP/du-table.tsv"
export LISTING AFTER DU_TABLE STUBS
cat > "$STUBS/unused" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$STUBS/unused.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUBS/unused.n"
[[ -e "$STUBS/unused.fail.$n" || -e "$STUBS/unused.fail" ]] && { echo "flatpak did not answer" >&2; exit 1; }
if [[ -e "$LISTING.$n" ]]; then cat "$LISTING.$n"; else cat "$LISTING"; fi
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
printf '%s\n' "$@" > "$STUBS/uninstall.args"
[[ -f "$AFTER" ]] && cp "$AFTER" "$LISTING"
[[ -n "${UNINSTALL_SAY:-}" ]] && printf '%s\n' "$UNINSTALL_SAY"
if [[ -n "${UNINSTALL_WAIT:-}" ]]; then
  : > "$STUBS/uninstall.started"
  for _ in {1..300}; do [[ -e "$UNINSTALL_WAIT" ]] && break; sleep 0.1; done
fi
exit "${UNINSTALL_RC:-0}"
STUB
chmod +x "$STUBS"/*
{
  jq -r '.used[].deploy_dir | "\(.)\t4000000000"' "$UNUSED_FX"
  jq -r '.unused[] | "\(.deploy_dir)\t\({"runtime/org.freedesktop.Platform/x86_64/24.08": 600000000,
          "runtime/org.freedesktop.Platform.GL.default/x86_64/24.08": 450000000,
          "runtime/org.freedesktop.Platform.GL.default/x86_64/24.08extra": 20000000,
          "runtime/org.freedesktop.Platform.Locale/x86_64/24.08": 5000000,
          "runtime/org.kde.Platform/x86_64/5.15-23.08": 900000000}[.ref])"' "$UNUSED_FX"
} > "$DU_TABLE"
export KEMPT_FLATPAK_UNUSED_CMD="$STUBS/unused" KEMPT_DU_CMD="$STUBS/du" KEMPT_FLATPAK_UNINSTALL_CMD="$STUBS/uninstall"
export KEMPT_REFRESH_HELPER="$STUBS/uninstall.none" KEMPT_SKIP_REFRESH=1 KEMPT_DNF_CMD=true \
       KEMPT_FLATPAK_REMOTE_CMD=true KEMPT_FLATPAK_LIST_CMD=true

P24=runtime/org.freedesktop.Platform/x86_64/24.08
KDE=runtime/org.kde.Platform/x86_64/5.15-23.08
GL=runtime/org.freedesktop.Platform.GL.default/x86_64/24.08
ALL5="$(jq -r '.unused[].ref' "$UNUSED_FX" | LC_ALL=C sort)"
# The fixture with every unused ref gone but the ones named.
only() { jq --args '.unused |= map(select(.ref | IN($ARGS.positional[])))' "$@" <"$UNUSED_FX"; }
# The fixture with this ref back in use: an app was installed that needs it, so it is on the used side.
in_use() { jq --arg r "$1" '.used += [.unused[] | select(.ref == $r) | {ref, deploy_dir}] | .unused |= map(select(.ref != $r))' "$UNUSED_FX"; }
reset() { rm -f "$STUBS"/uninstall.args "$STUBS"/du.calls "$STUBS"/unused.n "$STUBS"/unused.fail* "$LISTING".* "$AFTER"; cp "$UNUSED_FX" "$LISTING"; }
reclaim() { "$KEMPT" reclaim "$@" </dev/null 2>"$TESTTMP/err" >"$TESTTMP/out"; }
said_out() { cat "$TESTTMP/out"; }
said_err() { cat "$TESTTMP/err"; }
args() { cat "$STUBS/uninstall.args" 2>/dev/null || echo "(no removal)"; }
reset

# --- the shape check: nothing odd in the list reaches du or flatpak ---------------------------------
bad_list() { jq "$1" "$UNUSED_FX" > "$LISTING"; flatpak_unused_list >/dev/null 2>&1 && echo accepted || echo rejected; }
source "$REPO_ROOT/backends/flatpak.sh"
assert_eq "$(bad_list '.')" "accepted" "premise: the fixture passes the shape check"
assert_eq "$(bad_list '.unused[0].ref = "--force-remove"')" "rejected" "a ref that looks like an option rejects the whole list"
assert_eq "$(bad_list '.used[0].deploy_dir = "relative/dir"')" "rejected" "...and so does a deploy directory that is not absolute"
assert_eq "$(bad_list '.unused[0].ref = "app/org.example.App/x86_64/stable"')" "rejected" "...and so does an app on the unused side"
assert_eq "$(bad_list '.used[0].ref = "app/org.example.App/x86_64/stable"')" "accepted" "...while an app on the used side is what used means"
reset

# --- the size estimate ----------------------------------------------------------------------------
# One du over the used directories first: GNU du counts a hard-linked file once, for the first
# argument that reaches it, and flatpak deploys hard-link shared files. The real du, on real links.
HL="$TESTTMP/hl"; mkdir -p "$HL/used" "$HL/unused"
head -c 200000 /dev/zero > "$HL/used/shared"; ln "$HL/used/shared" "$HL/unused/shared"
head -c 3000 /dev/zero > "$HL/unused/own"
HL_LIST="$(jq -nc --arg u "$HL/used" --arg n "$HL/unused" \
  '{unused: [{ref: "runtime/x/x86_64/1", deploy_dir: $n}], used: [{ref: "runtime/y/x86_64/1", deploy_dir: $u}]}')"
hl_bytes="$(KEMPT_DU_CMD=du flatpak_unused_sizes "$HL_LIST" | cut -f2)"
assert_eq "$(( hl_bytes < 200000 && hl_bytes >= 3000 ))" "1" "a file shared with a used ref is not counted as freed"
rc=0; KEMPT_DU_CMD=false flatpak_unused_sizes "$HL_LIST" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "a du that fails is no estimate"
rc=0; DU_LIST="$(jq -c '.unused[0].deploy_dir = "/nowhere"' <<<"$HL_LIST")"
out="$(KEMPT_DU_CMD="printf 1\t$HL/used\n" flatpak_unused_sizes "$DU_LIST" 2>/dev/null)" || rc=$?
assert_eq "$rc|$out" "1|" "...and so is one that leaves an unused directory out"

# --- the block in state.json ----------------------------------------------------------------------
check() { "$KEMPT" check >/dev/null 2>&1 || true; }
block() { jq -c '.reclaim' "$KEMPT_STATE_DIR/state.json"; }
check
assert_eq "$(jq -c '[.refs | length, (.[0] | keys[])], .bytes' <<<"$(block)" | tr '\n' ' ')" '[5,"ref"] 1975000000 ' \
  "a check lists every unused ref, and their size"
assert_eq "$(wc -l < "$STUBS/du.calls")" "1" "...from one du"
assert_eq "$(tr ' ' '\n' < "$STUBS/du.calls" | grep -n -m1 -F "$(jq -r '.unused[0].deploy_dir' "$UNUSED_FX")" | cut -d: -f1)" \
  "$(( 2 + $(jq '.used | length' "$UNUSED_FX") + 1 ))" "...with the used directories first"
touch "$STUBS/unused.fail"; check
assert_eq "$(block)" "null" "a listing that fails leaves no block, so no offer"
rm "$STUBS/unused.fail"; rc=0; KEMPT_DU_CMD=false "$KEMPT" check >/dev/null 2>&1 || rc=$?
assert_eq "$rc|$(jq -c '.bytes' <<<"$(block)")" "0|null" "a du that fails never fails the check, and the size is unknown"
for v in SUDO_UID PKEXEC_UID; do
  env "$v=1000" "$KEMPT" check >/dev/null 2>&1 || true
  assert_eq "$(block)" "null" "under $v there is no block: libflatpak would count root's apps, not this person's"
done
"$KEMPT" config set include_flatpak false >/dev/null; check
assert_eq "$(block)" "null" "with Flatpak left out of updates there is no block"
"$KEMPT" config set include_flatpak true >/dev/null
reset

# --- refusals: flatpak is never reached --------------------------------------------------------------
for v in SUDO_UID PKEXEC_UID; do
  rc=0; env "$v=1000" "$KEMPT" reclaim -y </dev/null >/dev/null 2>"$TESTTMP/err" || rc=$?
  assert_eq "$rc|$(args)" "5|(no removal)" "under $v nothing is removed"
  assert_contains "$(said_err)" "as yourself" "...and it says why"
done
rc=0; KEMPT_FLATPAK_UNINSTALL_CMD="$TESTTMP/no-such-flatpak" reclaim -y || rc=$?
assert_eq "$rc" "5" "with no flatpak nothing is removed"
rc=0; reclaim || rc=$?
assert_eq "$rc|$(args)" "5|(no removal)" "no -y and no terminal to ask at is never a silent yes"
assert_contains "$(said_out)" "  $KDE" "...the list is still shown"
assert_contains "$(said_out)" "Up to 2.0 GB can be freed." "...with its size"
rc=0; reclaim --bogus || rc=$?
assert_eq "$rc|$(args)" "2|(no removal)" "an unknown option is a usage error"
rc=0; flock "$KEMPT_STATE_DIR/lock" "$KEMPT" reclaim -y </dev/null >/dev/null 2>"$TESTTMP/err" || rc=$?
assert_eq "$rc|$(args)" "3|(no removal)" "with an update running nothing is removed"
touch "$STUBS/unused.fail"; rc=0; reclaim -y || rc=$?
assert_eq "$rc|$(args)" "1|(no removal)" "a listing that fails removes nothing"
assert_contains "$(said_err)" "Nothing was removed" "...and says so"
reset; jq '.unused = []' "$UNUSED_FX" > "$LISTING"
rc=0; reclaim -y || rc=$?
assert_eq "$rc|$(args)|$(said_out)" "0|(no removal)|Nothing to remove." "nothing unused is not a failure"

# --- what reaches flatpak: by name, after --, and only what is on both lists -------------------------
reset; only > "$AFTER"
rc=0; reclaim -y || rc=$?
assert_eq "$rc|$(args)" "0|$(printf -- '--\n%s' "$ALL5")" "every ref on the list goes by name, after --"
assert_exit 0 "...the update lock is free again" -- flock -n "$KEMPT_STATE_DIR/lock" true
# Killed mid-removal, kempt leaves the update lock with the flatpak that inherited it: no update
# starts until flatpak has finished.
for sig in TERM HUP; do
  reset; only > "$AFTER"; rm -f "$STUBS/uninstall.started" "$STUBS/go"
  UNINSTALL_WAIT="$STUBS/go" "$KEMPT" reclaim -y </dev/null >/dev/null 2>&1 & p=$!
  for _ in {1..100}; do [[ -e "$STUBS/uninstall.started" ]] && break; sleep 0.1; done
  kill -"$sig" "$p"; wait "$p" 2>/dev/null || true
  assert_exit 1 "after SIG$sig the update lock stays held while flatpak runs" -- flock -n "$KEMPT_STATE_DIR/lock" true
  touch "$STUBS/go"
  assert_exit 0 "...and is free once flatpak has ended" -- flock -w 30 "$KEMPT_STATE_DIR/lock" true
done
# Listing 1 is the one shown, listing 2 the one read just before the removal.
reset
only "$P24" "$KDE" > "$LISTING.1"; only "$KDE" "$GL" > "$LISTING.2"; only "$GL" > "$LISTING"
rc=0; reclaim -y || rc=$?
assert_eq "$(args)" "$(printf -- '--\n%s' "$KDE")" \
  "a ref that came back into use and one that newly went unused both stay: only refs on both lists go"
# Back in use between the two reads: installed still, and on the second list's used side.
reset; in_use "$KDE" > "$LISTING.2"; in_use "$KDE" | jq '.unused = []' > "$AFTER"
rc=0; reclaim -y || rc=$?
assert_eq "$rc|$(args)" "0|$(printf -- '--\n%s' "$(grep -vF "$KDE" <<<"$ALL5")")" \
  "a ref back in use by the second read does not reach flatpak"
reset; only "$P24" > "$LISTING.1"; only "$KDE" > "$LISTING.2"
rc=0; reclaim -y || rc=$?
assert_eq "$rc|$(args)|$(said_out | tail -1)" "0|(no removal)|Nothing to remove." "two lists with nothing in common remove nothing"
reset; touch "$STUBS/unused.fail.2"
rc=0; reclaim -y || rc=$?
assert_eq "$rc|$(args)" "1|(no removal)" "a second list that fails removes nothing"
# What the widget does: it names what it showed. A name not on the list never reaches flatpak.
reset
rc=0; reclaim -y -- "$KDE" "--force-remove" "runtime/org.example.NotListed/x86_64/1" "$KDE" || rc=$?
assert_eq "$(args)" "$(printf -- '--\n%s' "$KDE")" "named refs narrow the removal, and a name off the list goes nowhere"
assert_eq "$(said_out | grep -c '^  ')" "1" "...the list shown is the narrowed one"
reset; only "$P24" > "$LISTING"
rc=0; reclaim -y -- "$KDE" || rc=$?
assert_eq "$rc|$(args)|$(said_out)" "0|(no removal)|Nothing to remove." "a named ref no longer unused removes nothing"

# --- the result comes from the list read afterwards -----------------------------------------------
reset; only > "$AFTER"
rc=0; reclaim -y || rc=$?
assert_eq "$rc|$(said_out | tail -1)|$(said_err)" "0|Removed 5 runtimes.|" "all gone is a count, on stdout, with exit 0"
assert_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "Unused runtimes: Removed 5 runtimes. Gone: $(tr '\n' ' ' <<<"$ALL5" | sed 's/ $//')." "...and an event line that names them"
assert_eq "$(block)" '{"refs":[],"bytes":0}' "...and the closing check takes the offer away"
assert_eq "$(ls "$KEMPT_STATE_DIR/history" 2>/dev/null | wc -l)" "0" "...and a removal writes no history entry"
# Flatpak failed and nothing went: its reason, and no word of success.
reset; ERR='error: Failed to uninstall runtime/x: busy'
rc=0; UNINSTALL_RC=1 UNINSTALL_SAY="$(printf 'Uninstalling\n%s\nerror: There were one or more errors' "$ERR")" reclaim -y || rc=$?
assert_eq "$rc" "1" "flatpak failing is exit 1"
assert_eq "$(said_err)" "Flatpak stopped with exit code 1: $ERR. Nothing was removed. Still installed: $(tr '\n' ' ' <<<"$ALL5" | sed 's/ $//')." \
  "...its reason first, then that nothing went, then what remained"
assert_not_contains "$(said_out)$(said_err)" "Removed" "...and never that anything went"
assert_eq "$(said_err | wc -l)" "1" "...in one line, the one the widget shows"
# The removal ran out of time: timeout's exit status, said in words.
reset; rc=0; UNINSTALL_RC=124 UNINSTALL_SAY="error: late" reclaim -y || rc=$?
assert_eq "$rc" "1" "a removal that ran out of time is exit 1"
assert_contains "$(said_err)" "Flatpak took too long, so Kempt stopped it. Nothing was removed." "...and says it waited too long"
assert_not_contains "$(said_err)" "124" "...not an exit code"
# Flatpak said yes and nothing went: the command running is no success.
reset
rc=0; reclaim -y || rc=$?
assert_eq "$rc" "1" "flatpak saying yes with nothing gone is not a success"
assert_contains "$(said_err)" "Nothing was removed." "...it says so"
assert_not_contains "$(said_out)" "Removed" "...and claims nothing"
# Part went: flatpak stopped with some gone.
reset; only "$KDE" > "$AFTER"
rc=0; UNINSTALL_RC=1 reclaim -y || rc=$?
assert_eq "$rc" "1" "part gone and flatpak failing is exit 1"
assert_contains "$(said_err)" "Flatpak stopped with exit code 1. Removed 4 runtimes. Still installed: $KDE." \
  "...with what went, counted from the refs really gone, and what remained"
assert_not_contains "$(tail -1 "$KEMPT_STATE_DIR/events.log" | sed 's/.* Gone: //')" "$KDE" "...and the event line names only what went"
# Flatpak said yes and left one.
reset; only "$KDE" > "$AFTER"
rc=0; reclaim -y || rc=$?
assert_eq "$rc" "1" "flatpak saying yes with one left is not a success either"
assert_contains "$(said_err)" "Still installed: $KDE." "...and says which"
# Another tool removes something during ours: not counted as ours.
reset; only "$P24" > "$AFTER"
rc=0; reclaim -y -- "$KDE" || rc=$?
assert_eq "$rc|$(said_out | tail -1)" "0|Removed 1 runtime." "what another tool removed meanwhile is not counted"
# Back in use by the time of the list afterwards: not removed, and still installed.
reset; in_use "$KDE" | jq '.unused = []' > "$AFTER"
rc=0; reclaim -y || rc=$?
assert_eq "$rc" "1" "a ref flatpak was given that is now on the used side is not a success"
assert_contains "$(said_err)" "Still installed: $KDE." "...it is still installed"
assert_contains "$(said_err)" "Removed 4 runtimes." "...and it is not counted as gone"
# All gone, though flatpak failed: the removal is real, and so is the failure.
reset; only > "$AFTER"
rc=0; UNINSTALL_RC=1 reclaim -y || rc=$?
assert_eq "$rc" "1" "all gone with flatpak failing is still exit 1"
assert_contains "$(said_err)" "Flatpak stopped with exit code 1. Removed 5 runtimes." "...and says both"
# The list afterwards cannot be read: Kempt does not know, flatpak's exit status or not.
for frc in 0 1; do
  reset; only > "$AFTER"; touch "$STUBS/unused.fail.3"
  rc=0; UNINSTALL_RC=$frc reclaim -y || rc=$?
  assert_eq "$rc" "1" "with the list afterwards unreadable (flatpak exit $frc) it is exit 1"
  assert_contains "$(said_err)" "cannot say what was removed" "...and it cannot say what went"
  assert_not_contains "$(said_out)" "Removed" "...and claims nothing"
done
# No size: the removal does not need one, and no size is claimed.
reset; only > "$AFTER"; cp "$DU_TABLE" "$DU_TABLE.bak"; : > "$DU_TABLE"
rc=0; reclaim -y || rc=$?
assert_eq "$rc|$(said_out | tail -1)" "0|Removed 5 runtimes." "a size that cannot be worked out stops nothing"
assert_not_contains "$(said_out)" "can be freed" "...and is not claimed"
reset; only "$KDE" "$P24" "$GL" "runtime/org.freedesktop.Platform.Locale/x86_64/24.08" > "$AFTER"
rc=0; reclaim -y -- runtime/org.freedesktop.Platform.GL.default/x86_64/24.08extra || rc=$?
assert_eq "$rc|$(said_out | tail -1)" "0|Removed 1 runtime." "...one of them in the singular"
cp "$DU_TABLE.bak" "$DU_TABLE"

finish
