#!/usr/bin/env bash
# Every sentence Kempt says about a stored Fedora release upgrade, against every state dnf5 can
# leave one in.
#
# This file exists because one defect came back three times in three different shapes: a sentence
# that contradicts the data it quotes. First "installs on the next restart" over a transaction that
# was only downloaded; then "downloaded but not started (status ready)"; then "has been downloaded"
# over a status of download-incomplete. Each fix described one more state and left the next one
# folded into a bucket whose sentence was false for it.
#
# So the guard is a MATRIX rather than another example: four states dnf5 can record, four surfaces
# that describe them, and the rules below hold for every cell. Adding a fifth state without a
# sentence for it fails here, and so does wording any of them to claim something the state denies.
#
# The four status words are dnf5 5.4.3's own, read out of the binary rather than guessed:
#   ready, download-complete, download-incomplete, transaction-incomplete
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"
export WORLD="$TESTTMP/world"; mkdir -p "$WORLD"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
printf '#!/usr/bin/env bash\n[[ "$1" == check ]] && { cat %s/dnf-check-update.txt; exit 100; }\nexit 0\n' "$FIXTURES" > "$TESTTMP/rs"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/noop"
printf '#!/usr/bin/env bash\necho "APPLY $@" >> %s/apply-calls\nexit 0\n' "$WORLD" > "$TESTTMP/ap"
chmod +x "$TESTTMP/rs" "$TESTTMP/noop" "$TESTTMP/ap"
export KEMPT_REFRESH_HELPER="$TESTTMP/rs" KEMPT_APPLY_HELPER="$TESTTMP/ap" KEMPT_SKIP_REFRESH=1
export KEMPT_DNF_CMD="$TESTTMP/noop" KEMPT_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
"$KEMPT" config set include_flatpak false >/dev/null
ln -sfn "$TESTTMP" "$TESTTMP/live-link"
NO_LINK="$TESTTMP/no-link"

# A toml per status word, built from the committed capture so only the one line under test moves.
mk_toml() {  # status → path
  local f="$TESTTMP/relup-$1.toml"
  sed "s/^status = .*/status = \"$1\"/" "$FIXTURES/offline-release-upgrade.toml" > "$f"
  printf '%s' "$f"
}

# What each surface says, for one (status, symlink) pair.
render() {  # status link → sets $R_STATE $R_REFUSE $R_DOCTOR $R_JSON $R_WIDGET
  export KEMPT_OFFLINE_TOML="$(mk_toml "$1")" KEMPT_OFFLINE_LINK="$2"
  R_STATE="$(bash -c "source '$REPO_ROOT/lib/common.sh'; offline_release_upgrade_state")"
  R_REFUSE="$({ "$KEMPT" update --surface=offline 2>&1 || true; } | head -1)"
  R_DOCTOR="$({ "$KEMPT" doctor 2>&1 || true; } | grep -E '^(info|FAIL) .*Fedora release upgrade' | head -1)"
  "$KEMPT" check >/dev/null 2>&1
  R_JSON="$(jq -r '.release_upgrade.state // "MISSING"' "$KEMPT_STATE_DIR/state.json")"
  R_WIDGET="$(node -e '
    const L = require(process.argv[1]);
    const st = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
    process.stdout.write(L.viewModel(st, false, "", {surface: "background"}).releaseUpgradeMessage);
  ' "$REPO_ROOT/plasmoid/contents/ui/logic.js" "$KEMPT_STATE_DIR/state.json" 2>/dev/null)"
}

# The rules, applied to all four surfaces at once. Each is a thing that has actually been said
# wrongly at least once.
check_cell() {  # status link expected_state
  render "$1" "$2"
  local where="$1$([[ "$2" == "$NO_LINK" ]] && echo ', no boot marker')"
  assert_eq "$R_STATE" "$3" "dnf5 says \"$1\"${2:+ }$([[ "$2" == "$NO_LINK" ]] && echo 'with no boot marker') -> $3"
  assert_eq "$R_JSON" "$3" "...and the state file publishes the same word, so the widget agrees"
  local s
  for s in "$R_REFUSE" "$R_DOCTOR" "$R_WIDGET"; do
    [[ -n "$s" ]] || { echo "FAIL: nothing said about $where by one of the surfaces"; _fail=1; continue; }
    # RULE 1: only an armed transaction may be said to install on a restart.
    if [[ "$3" != armed && "$s" == *"installs on the next restart"* ]]; then
      echo "FAIL: $where promises the next restart will install it"; echo "  $s"; _fail=1
    fi
    # RULE 2: "downloaded" is dnf5's word for exactly one status. Saying it over any other quotes a
    # status word that means the opposite.
    if [[ "$3" != downloaded && "$s" == *"has been downloaded"* ]]; then
      echo "FAIL: $where calls a $1 transaction downloaded"; echo "  $s"; _fail=1
    fi
    # RULE 3: `dnf5 system-upgrade reboot` starts a DOWNLOADED transaction and re-arms a stranded
    # one. dnf5 declines it for a transaction that did not finish, so recommending it there is
    # advice that fails in front of the reader.
    if [[ "$3" == incomplete && "$s" == *"system-upgrade reboot"* ]]; then
      echo "FAIL: $where recommends a command dnf5 refuses in that state"; echo "  $s"; _fail=1
    fi
    # RULE 4: whatever else it says, it says WHICH upgrade. A sentence about an unnamed release
    # upgrade cannot be acted on.
    case "$s" in *"44 -> 45"*|*"Fedora 45"*) ;; *)
      echo "FAIL: $where does not name the release"; echo "  $s"; _fail=1 ;;
    esac
  done
  # RULE 5: the refusal happens in all four states. Staging cancels a stored transaction whatever
  # state it is in, and that is the whole reason any of this exists.
  : > "$WORLD/apply-calls"
  local rc=0
  "$KEMPT" update --surface=offline >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "5" "...and staging over it is refused in pre-flight, changing nothing"
  assert_eq "$(grep -c 'APPLY dnf-offline-stage' "$WORLD/apply-calls" || true)" "0" \
    "...with dnf5 never asked to stage"
}

check_cell ready                  "$TESTTMP/live-link" armed
check_cell ready                  "$NO_LINK"           stranded
check_cell download-complete      "$NO_LINK"           downloaded
check_cell download-incomplete    "$NO_LINK"           incomplete
check_cell transaction-incomplete "$NO_LINK"           incomplete
# A word no dnf5 has written yet must land somewhere that promises nothing, rather than in the
# bucket whose sentence happens to be first.
check_cell some-future-word       "$NO_LINK"           incomplete

# ...and the whole matrix is silent on a box with no release upgrade stored, which is every box.
export KEMPT_OFFLINE_TOML="$FIXTURES/offline-ready.toml" KEMPT_OFFLINE_LINK="$TESTTMP/live-link"
"$KEMPT" check >/dev/null 2>&1
assert_eq "$(jq -r 'has("release_upgrade")' "$KEMPT_STATE_DIR/state.json")" "false" \
  "an ordinary staged transaction is not a release upgrade, and nothing here fires"
: > "$WORLD/apply-calls"
"$KEMPT" update --surface=offline >/dev/null 2>&1 || true
grep -q 'APPLY dnf-offline-stage' "$WORLD/apply-calls" \
  && echo "ok: ...and staging over it still works, which is what holds depend on" \
  || { echo "FAIL: the refusal fired on an ordinary transaction"; _fail=1; }

finish
