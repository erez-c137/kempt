#!/usr/bin/env bash
set -uo pipefail
shopt -s nullglob
cd "$(dirname "$0")" || exit 1
rc=0
files=(test_*.sh)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "NO TEST FILES MATCHED test_*.sh"
  exit 1
fi
# Where the test files record what they could not run. A green suite that skipped the widget's
# whole QML half used to print ALL PASS and nothing else, which is how a CI badge comes to mean
# less than the person reading it thinks.
KEMPT_TEST_SKIPS="$(mktemp)"; export KEMPT_TEST_SKIPS

# Which files failed, not just that something did. A suite of 30 files ending in the word
# FAILURES makes the reader scroll back through thousands of ok: lines to find out where to look.
failed=()
# Files run KEMPT_TEST_JOBS at a time (default 4; 1 is the old one-after-another run). Each file has
# its own sandbox, and its output is held and printed whole when it ends, so lines of two files never
# mix. The widget's QML file counts and kills its own Qt processes, so it runs last and alone.
jobs=${KEMPT_TEST_JOBS:-4}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo "KEMPT_TEST_JOBS must be a positive number, got '$jobs'"; exit 1; }
last=test_widget_qml.sh
batch=()
for t in "${files[@]}"; do
  [[ $t == "$last" ]] && continue
  batch+=("$t")
done
OUT_DIR="$(mktemp -d)"
trap 'rm -f "$KEMPT_TEST_SKIPS"; rm -rf "$OUT_DIR"' EXIT
run_one() {  # run_one FILE: output and status kept under OUT_DIR, printed by wait_report
  bash "$1" > "$OUT_DIR/$1.out" 2>&1; echo $? > "$OUT_DIR/$1.rc"
}
report() {   # report FILE: print its output whole, record a failure
  echo "== $1"; cat "$OUT_DIR/$1.out"
  if [[ "$(cat "$OUT_DIR/$1.rc")" != 0 ]]; then rc=1; failed+=("$1"); fi
}
running=()
for t in "${batch[@]}"; do
  while (( ${#running[@]} >= jobs )); do
    # wait for the oldest, report whichever finished first by polling the rc files
    still=()
    for r in "${running[@]}"; do
      if [[ -e "$OUT_DIR/$r.rc" ]]; then report "$r"; else still+=("$r"); fi
    done
    running=(${still[@]+"${still[@]}"})
    (( ${#running[@]} >= jobs )) && sleep 0.5
  done
  run_one "$t" &
  running+=("$t")
done
while (( ${#running[@]} > 0 )); do
  still=()
  for r in "${running[@]}"; do
    if [[ -e "$OUT_DIR/$r.rc" ]]; then report "$r"; else still+=("$r"); fi
  done
  running=(${still[@]+"${still[@]}"})
  (( ${#running[@]} > 0 )) && sleep 0.5
done
wait
if [[ -e $last ]]; then
  echo "== $last"
  if ! bash "$last"; then rc=1; failed+=("$last"); fi
fi

skipped=$(grep -c . "$KEMPT_TEST_SKIPS" 2>/dev/null || true); skipped=${skipped:-0}
if [[ $rc -ne 0 ]]; then
  echo "FAILURES in ${#failed[@]} of ${#files[@]} file(s):"
  printf '    %s\n' ${failed[@]+"${failed[@]}"}
elif [[ $skipped -gt 0 ]]; then
  echo "ALL PASS - with $skipped skipped, so this run did not cover everything:"
  sed 's/^/    /' "$KEMPT_TEST_SKIPS"
else
  echo "ALL PASS"
fi
echo "ran ${#files[@]} test file(s)"
exit $rc
