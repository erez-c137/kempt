#!/usr/bin/env bash
# Updates no upgrade can install: check-update lists them, every upgrade skips them for broken
# dependencies. The dry run that finds them, the marking, the counts, the status lines and the run
# summary. Witness: tests/fixtures/dnf-upgrade-broken-deps.txt (MANIFEST.md).
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/backends/dnf.sh"
KEMPT="$REPO_ROOT/bin/kempt"
WITNESS="$FIXTURES/dnf-upgrade-broken-deps.txt"

# --- the parser ----------------------------------------------------------------------------------
assert_eq "$(dnf_blocked_parse < "$WITNESS" | paste -sd' ')" "ffmpeg ffmpeg-libs libavdevice" \
  "the witness: the three names in the section, and none of the problem lines above it"
assert_eq "$(printf 'Package Arch Version Repository Size\nNothing to do.\n' | dnf_blocked_parse)" "" \
  "no section: nothing"
assert_eq "$(printf 'Skipping packages with broken dependencies:\n\nNothing to do.\n' | dnf_blocked_parse)" "" \
  "an empty section: nothing"
assert_eq "$(dnf_blocked_parse < /dev/null)" "" "no output at all: nothing"
twins=$'Skipping packages with broken dependencies:\n foo x86_64 1.0-2.fc44 updates 1.0 MiB\n foo i686   1.0-2.fc44 updates 1.0 MiB\n'
assert_eq "$(dnf_blocked_parse <<<"$twins")" "foo" "a multilib pair is one name"
# The section ends at the next heading even without a blank line, and an indented row under another
# heading is not read.
after=$'Skipping packages with broken dependencies:\n a x86_64 1-1.fc44 r 1.0 MiB\nUpgrading:\n b x86_64 2-1.fc44 r 1.0 MiB\n'
assert_eq "$(dnf_blocked_parse <<<"$after")" "a" "the section ends at the next heading"
other=$'Skipping packages with conflicts:\n c x86_64 1-1.fc44 r 1.0 MiB\n'
assert_eq "$(dnf_blocked_parse <<<"$other")" "" "another skipping section is not read"
bad=$'Skipping packages with broken dependencies:\n -rf x86_64 1-1.fc44 r 1.0 MiB\n short\n'
assert_eq "$(dnf_blocked_parse <<<"$bad")" "" "a row that is not a package row, or a name Kempt refuses, is dropped"

# --- the run log ---------------------------------------------------------------------------------
LOGF="$TESTTMP/run.log"
{ printf 'earlier run\n'; cat "$WITNESS"; } > "$LOGF.old"
printf '\n== System (dnf) ==\n' > "$LOGF"
from="$(stat -c %s "$LOGF")"
cat "$WITNESS" >> "$LOGF"
printf '\n== Apps (flatpak) ==\nNothing to update.\n' >> "$LOGF"
assert_eq "$(dnf_blocked_from_log "$LOGF" "$from")" '["ffmpeg","ffmpeg-libs","libavdevice"]' \
  "the run log: the names, as a JSON list"
printf '\n== System (dnf) ==\nNothing to do.\n' > "$LOGF.clean"
assert_eq "$(dnf_blocked_from_log "$LOGF.clean" 0)" '[]' "a clean run log: an empty list"
assert_eq "$(dnf_blocked_from_log "$TESTTMP/no-such.log" 0)" '[]' "no log: an empty list"
# Only this run's part of the log: an earlier section before the offset is not this run's.
cat "$LOGF.old" > "$LOGF.two"; off2="$(stat -c %s "$LOGF.two")"; printf 'Nothing to do.\n' >> "$LOGF.two"
assert_eq "$(dnf_blocked_from_log "$LOGF.two" "$off2")" '[]' "an earlier run's section is not read"

# --- marking -------------------------------------------------------------------------------------
names_f="$TESTTMP/names"; printf 'ffmpeg\nffmpeg-libs\nlibavdevice\n' > "$names_f"
items='[{"name":"ffmpeg","from":"1","to":"2","held":false},{"name":"ffmpeg-libs","from":"1","to":"2","held":true},
        {"name":"bash","from":"1","to":"2","held":false}]'
marked="$(mark_blocked "$names_f" <<<"$items")"
assert_eq "$(jq -c '[.[] | select(.blocked == true) | .name]' <<<"$marked")" '["ffmpeg"]' \
  "a listed, not held item is marked; a held one is not (held wins)"
assert_eq "$(jq -c '[.[] | has("blocked")]' <<<"$marked")" '[true,false,false]' \
  "the key is written only when true"
assert_eq "$(mark_blocked /dev/null <<<"$items" | jq -c '[.[] | select(.blocked)] | length')" "0" \
  "no names: nothing is marked"

# --- the dry run ---------------------------------------------------------------------------------
cat > "$TESTTMP/dryrun-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TESTTMP/dryrun-calls"
[[ -f "$TESTTMP/dryrun-sleep" ]] && sleep 5
cat "$TESTTMP/dryrun-out" 2>/dev/null
exit "\$(cat "$TESTTMP/dryrun-rc" 2>/dev/null || echo 0)"
STUB
chmod +x "$TESTTMP/dryrun-stub"
export KEMPT_DNF_DRYRUN_CMD="$TESTTMP/dryrun-stub"
cp "$WITNESS" "$TESTTMP/dryrun-out"

assert_eq "$(dnf_blocked_names)" "" "no readable system cache: not asked, nothing blocked"
assert_eq "$([[ -e "$TESTTMP/dryrun-calls" ]] && echo asked || echo not-asked)" "not-asked" \
  "...and the dry run did not run against the user's own cache"
export KEMPT_DNF_CACHE_DIR="$TESTTMP/system-cache"; mkdir -p "$KEMPT_DNF_CACHE_DIR"
# The folder is the test user's, which the ownership scan would rightly refuse over; it reads clean
# here, and nothing is staged, so status shows what a plain check found.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/find-clean"; chmod +x "$TESTTMP/find-clean"
export KEMPT_FIND="$TESTTMP/find-clean" KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml"
assert_eq "$(dnf_blocked_names | paste -sd' ')" "ffmpeg ffmpeg-libs libavdevice" "the dry run's answer"
assert_eq "$(tail -n 1 "$TESTTMP/dryrun-calls")" \
  "--setopt=cachedir=$TESTTMP/system-cache -C upgrade --assumeno" \
  "cache-only, against the system cache, and never past the question"
"$KEMPT" hold dnf:ffmpeg >/dev/null 2>&1
dnf_blocked_names >/dev/null
assert_contains "$(tail -n 1 "$TESTTMP/dryrun-calls")" "--exclude=ffmpeg" "a hold is excluded, as the real update excludes it"
"$KEMPT" unhold dnf:ffmpeg >/dev/null 2>&1
echo 1 > "$TESTTMP/dryrun-rc"
assert_eq "$(dnf_blocked_names | grep -c . || true)" "3" "exit 1 (a refused transaction) still answers"
echo 2 > "$TESTTMP/dryrun-rc"
assert_eq "$(dnf_blocked_names)" "" "any other exit code: nothing blocked"
echo 0 > "$TESTTMP/dryrun-rc"
touch "$TESTTMP/dryrun-sleep"
assert_eq "$(BLOCKED_QUERY_TIMEOUT=1 dnf_blocked_names)" "" "a dry run past its time: nothing blocked"
rm -f "$TESTTMP/dryrun-sleep"
assert_eq "$(KEMPT_DNF_DRYRUN_CMD="$TESTTMP/no-such-dnf" dnf_blocked_names)" "" "a dry run that cannot start: nothing blocked"
assert_eq "$(dnf_mark_blocked <<<"$items" | jq -c '[.[] | select(.blocked == true) | .name]')" '["ffmpeg"]' \
  "the filter marks what the dry run names"
assert_eq "$(KEMPT_DNF_DRYRUN_CMD="$TESTTMP/no-such-dnf" dnf_mark_blocked <<<"$items" | jq -c .)" "$(jq -c . <<<"$items")" \
  "...and hands the items on unchanged when it fails"

# --- the check -----------------------------------------------------------------------------------
# The pending list: three of the names the witness skips, and two that install.
cat > "$TESTTMP/check-out" <<'EOF'
ffmpeg.x86_64        8.1.3-2.fc44  rpmfusion-free-updates
ffmpeg-libs.x86_64   8.1.3-2.fc44  rpmfusion-free-updates
ffmpeg-libs.i686     8.1.3-2.fc44  rpmfusion-free-updates
libavdevice.x86_64   8.1.3-2.fc44  rpmfusion-free-updates
bash.x86_64          5.3.10-1.fc44 updates
curl.x86_64          8.18.0-9.fc44 updates
EOF
printf 'ffmpeg\t8.1.3-1.fc44\nffmpeg-libs\t8.1.3-1.fc44\nlibavdevice\t8.1.3-1.fc44\nbash\t5.3.9-3.fc44\ncurl\t8.18.0-8.fc44\n' \
  > "$TESTTMP/installed.tsv"
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$TESTTMP/check-out"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"; chmod +x "$TESTTMP/dnf-reboot-no"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub" KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no"
export KEMPT_DNF_INSTALLED_CMD="cat $TESTTMP/installed.tsv" KEMPT_SKIP_REFRESH=1
"$KEMPT" config set include_flatpak false >/dev/null

state="$("$KEMPT" check)"
assert_eq "$(jq -c '[.backends.dnf.items[] | select(.blocked == true) | .name]' <<<"$state")" \
  '["ffmpeg","ffmpeg-libs","libavdevice"]' "partial: the three are marked blocked"
assert_eq "$(jq -r '.actionable' <<<"$state")" "2" "partial: only the two that install are actionable"
assert_eq "$(jq -r '.blocked_total' <<<"$state")" "3" "partial: blocked_total says three"
assert_eq "$(jq -r '.backends.dnf.actionable, .backends.dnf.blocked' <<<"$state" | paste -sd' ')" "2 3" \
  "partial: the backend's own counts"
assert_eq "$(jq -r '.held_total' <<<"$state")" "0" "partial: nothing counted as held"
assert_contains "$(tail -n 1 "$KEMPT_STATE_DIR/events.log")" "Checked: 2 updates to install, 3 cannot install yet" \
  "the event line says it"
out="$("$KEMPT" status 2>&1 || true)"
assert_eq "$(head -n 1 <<<"$out")" "2 updates" "status: the header counts what installs"
assert_contains "$out" "Cannot install yet: 3 (ffmpeg, ffmpeg-libs and libavdevice)" "status: the blocked line names them"
out="$("$KEMPT" status --list 2>&1 || true)"
assert_eq "$(grep -c 'cannot install yet$' <<<"$out" || true)" "3" "status --list: each blocked row is marked"
assert_eq "$("$KEMPT" status --json | jq -r '.blocked_total')" "3" "status --json carries blocked_total"

# Held wins, and nothing is counted twice: hold one of the three.
"$KEMPT" hold dnf:ffmpeg >/dev/null 2>&1
state="$("$KEMPT" check)"
assert_eq "$(jq -r '[.actionable, .held_total, .blocked_total] | join(" ")' <<<"$state")" "2 1 2" \
  "a held package the dry run also names counts as held, once"

# All blocked: everything that is not held is blocked.
"$KEMPT" unhold dnf:ffmpeg >/dev/null 2>&1
grep -v -e '^bash' -e '^curl' "$TESTTMP/check-out" > "$TESTTMP/check-out.new"; mv "$TESTTMP/check-out.new" "$TESTTMP/check-out"
state="$("$KEMPT" check)"
assert_eq "$(jq -r '[.actionable, .blocked_total] | join(" ")' <<<"$state")" "0 3" "all blocked: nothing actionable"
assert_eq "$(jq -r '.backends.dnf.download_bytes // "none"' <<<"$state")" "0" "all blocked: nothing to download"
out="$("$KEMPT" status 2>&1 || true)"
assert_eq "$(head -n 1 <<<"$out")" "Up to date · 3 waiting" "all blocked: status says up to date, with the waiting count"
if command -v node >/dev/null 2>&1; then
  vm="$(node -e '
    const fs = require("fs"); const L = require(process.argv[1]);
    const vm = L.viewModel(L.parseState(fs.readFileSync(process.argv[2], "utf8")), false, "", { nowMs: Date.now() });
    console.log(JSON.stringify({ badge: vm.badgeVisible, icon: vm.iconState, actionable: vm.actionable,
                                 header: vm.headerText, rows: vm.rows.filter((r) => r.blocked).length }));
  ' "$REPO_ROOT/plasmoid/contents/ui/logic.js" "$KEMPT_STATE_DIR/state.json")"
  assert_json_eq "$vm" '{"badge":false,"icon":"uptodate","actionable":0,"header":"Up to date · 3 waiting","rows":3}' \
    "all blocked: no badge, no button, the rows still listed"
else
  skip "node is absent, so the widget's reading of an all-blocked state was NOT checked"
fi

# The dry run failing: exactly the check as it was, nothing blocked.
echo 2 > "$TESTTMP/dryrun-rc"
state="$("$KEMPT" check)"
assert_eq "$(jq -r '[.actionable, .blocked_total] | join(" ")' <<<"$state")" "3 0" "a failed dry run marks nothing"
echo 0 > "$TESTTMP/dryrun-rc"
# ...and on an image-based system it is not asked at all.
: > "$TESTTMP/dryrun-calls"
touch "$TESTTMP/ostree-booted"
KEMPT_OSTREE_MARKER="$TESTTMP/ostree-booted" "$KEMPT" check >/dev/null 2>&1 || true
assert_eq "$(grep -c . "$TESTTMP/dryrun-calls" || true)" "0" "an image-based system: the dry run is not asked"
# ...nor when everything pending is held.
for n in ffmpeg ffmpeg-libs libavdevice; do "$KEMPT" hold "dnf:$n" >/dev/null 2>&1; done
"$KEMPT" check >/dev/null
assert_eq "$(grep -c . "$TESTTMP/dryrun-calls" || true)" "0" "everything held: the dry run is not asked"
for n in ffmpeg ffmpeg-libs libavdevice; do "$KEMPT" unhold "dnf:$n" >/dev/null 2>&1; done

# --- the update run ------------------------------------------------------------------------------
# The apply stub prints what dnf5 printed on the day: the skipped section and "Nothing to do.".
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$TESTTMP/apply-calls"
case "\$1" in dnf-upgrade|dnf-offline-stage) cat "$WITNESS" ;; esac
exit 0
STUB
chmod +x "$TESTTMP/apply-stub"
cat > "$TESTTMP/notify-stub" <<STUB
#!/usr/bin/env bash
echo "NOTIFY \$@" >> "$TESTTMP/notifications"
STUB
chmod +x "$TESTTMP/notify-stub"
export KEMPT_APPLY_HELPER="$TESTTMP/apply-stub" KEMPT_NOTIFY="$TESTTMP/notify-stub"
newest_hist() { printf '%s\n' "$KEMPT_STATE_DIR/history/$(ls -1 "$KEMPT_STATE_DIR/history" | tail -1)"; }

"$KEMPT" update --surface=widget --no-flatpak >/dev/null 2>&1 || true
h="$(newest_hist)"
assert_eq "$(jq -c '.backends.dnf.skipped_blocked' "$h")" '["ffmpeg","ffmpeg-libs","libavdevice"]' \
  "the run records what dnf5 skipped"
assert_contains "$("$KEMPT" summary 2>&1)" "3 updates could not install yet: ffmpeg, ffmpeg-libs, libavdevice" \
  "the summary says so instead of a plain success"
assert_contains "$(cat "$TESTTMP/notifications")" "no package changes, 3 updates could not install yet" \
  "...and so does the notification"
assert_contains "$("$KEMPT" history 2>&1)" "3 updates could not install yet" "...and the history row"
if command -v node >/dev/null 2>&1; then
  line="$(node -e '
    const fs = require("fs"); const L = require(process.argv[1]);
    const run = L.lastRunOf(fs.readFileSync(process.argv[2], "utf8"));
    console.log(L.postRunLine(run) + "|" + L.lastRunSubtitle(run));' "$REPO_ROOT/plasmoid/contents/ui/logic.js" "$h")"
  assert_eq "$line" "3 updates could not install yet.|3 updates could not install yet." \
    "the widget's post-run line and last-update row say it"
fi

# A run with nothing skipped records nothing.
printf '#!/usr/bin/env bash\necho "APPLY $*" >> "%s"\necho "Nothing to do."\nexit 0\n' "$TESTTMP/apply-calls" > "$TESTTMP/apply-clean"
chmod +x "$TESTTMP/apply-clean"
push_back() { local f; for f in "$KEMPT_STATE_DIR"/history/*.json; do mv "$f" "${f%.json}-0.json"; done; }
push_back
KEMPT_APPLY_HELPER="$TESTTMP/apply-clean" "$KEMPT" update --surface=widget --no-flatpak >/dev/null 2>&1 || true
assert_eq "$(jq -r '.backends.dnf | has("skipped_blocked")' "$(newest_hist)")" "false" "a clean run: no skipped_blocked key"

# Staging with only blocked updates pending: dnf5 stores nothing, and the reason is not the holds.
push_back
: > "$TESTTMP/notifications"
"$KEMPT" hold dnf:bash >/dev/null 2>&1   # a hold exists, so the old wording would blame it
KEMPT_OFFLINE_TOML="$TESTTMP/no-such-transaction.toml" "$KEMPT" update --surface=offline --no-flatpak >/dev/null 2>&1 || true
h="$(newest_hist)"
assert_eq "$(jq -r .staged_nothing "$h")" "blocked" "staging: the entry says nothing was staged because of blocked updates"
assert_contains "$(cat "$KEMPT_STATE_DIR/events.log")" "Nothing to stage (3 waiting updates cannot install yet)" \
  "staging: the event line names the reason"
assert_not_contains "$(tail -n 5 "$KEMPT_STATE_DIR/events.log")" "every pending update is held" \
  "...and does not blame the holds"
assert_contains "$(cat "$TESTTMP/notifications")" "3 updates could not install yet, so the next restart has nothing to install" \
  "staging: the notification says it"
if command -v node >/dev/null 2>&1; then
  assert_eq "$(node -e '
    const fs = require("fs"); const L = require(process.argv[1]);
    console.log(L.postRunLine(L.lastRunOf(fs.readFileSync(process.argv[2], "utf8"))));' \
    "$REPO_ROOT/plasmoid/contents/ui/logic.js" "$h")" "3 updates could not install yet." \
    "staging: the widget's post-run line"
fi
"$KEMPT" unhold dnf:bash >/dev/null 2>&1

finish
