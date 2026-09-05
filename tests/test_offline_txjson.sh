#!/usr/bin/env bash
# dnf5's stored offline transaction, read as a list of package NAMES.
#
# Why this file exists at all: a hold that arrives after a stage cannot change the transaction dnf5
# has already built (there is no API to edit one), so the only honest thing Kempt can do is SAY so -
# and saying so truthfully needs the staged set. `/usr/lib/sysimage/libdnf5/offline/transaction.json`
# is that set, written by dnf5, root-owned 0644 in a 0755 directory (verified in a Fedora 44
# container, 2026-09-05), which is what lets an unprivileged check read it at all.
#
# The two rules every assertion below serves:
#
#   names may CONFIRM a conflict and only a transaction-derived list may DENY one. So a list this
#   parser produces is allowed to make Kempt stay silent about a package - which means every way
#   the parse can go wrong has to end in "no list", never in a short list that looks complete.
#
#   any surprise degrades, nothing crashes. This is a file another project writes, in a format it
#   never promised us. A dnf5 that changes it costs Kempt precision, not truth, and never an exit
#   status under `set -euo pipefail`.
source "$(dirname "$0")/lib.sh"; sandbox
source "$REPO_ROOT/lib/common.sh"

# The function under test, pointed at one file. Called this way everywhere below so the seam is
# the only thing that varies between a case that parses and a case that must not.
tx() {  # path → the names on stdout, the function's own rc
  KEMPT_OFFLINE_TXJSON="$1" offline_txjson_names
}
# Every degradation is asserted the same way: nothing on stdout AND a non-zero status. Either one
# alone would pass for the wrong reason - a silent rc 0 is exactly the "empty list that denies a
# conflict" this parser must never produce, and a non-zero status with names on stdout would leave
# a caller that ignores rc reading a partial set.
assert_degrades() {  # path label
  local out rc=0
  out="$(tx "$1")" || rc=$?
  if [[ -n "$out" ]]; then
    echo "FAIL: $2"; echo "  expected: no names"; echo "  got:      $out"; _fail=1
  elif [[ "$rc" == 0 ]]; then
    echo "FAIL: $2"; echo "  expected: a non-zero status, so the caller falls back"; echo "  got:      rc 0"; _fail=1
  else
    echo "ok: $2"
  fi
}

# --- the two recorded transactions ---------------------------------------------------------------
# Both were staged against a real dnf5 5.4.3.0 in a Fedora 44 container on 2026-09-05 and copied
# out byte for byte (tests/fixtures/MANIFEST.md). The first is a plain stage of three packages; the
# second is the same stage re-made with --exclude=librepo, which is what a hold DOES to a
# transaction Kempt builds. Between them they pin the one distinction the whole feature rests on:
# a name that is in the staged set, and a name that is not.
assert_eq "$(tx "$FIXTURES/offline-transaction-full.json")" "$(printf 'ca-certificates\nlibrepo\nopenldap\n')" \
  "the staged set is the names dnf5 recorded, sorted"
assert_eq "$(tx "$FIXTURES/offline-transaction-excluded.json")" "$(printf 'ca-certificates\nopenldap\n')" \
  "a package excluded at stage time is absent from the transaction, so it is absent here"

# Hyphens are the reason the name cannot be taken as "up to the first -": ca-certificates has one,
# and every kernel-* package a user would ever hold has one too. The full fixture already proves
# it, and this says why out loud so a future rewrite cannot pass by splitting on the wrong end.
assert_eq "$(tx "$FIXTURES/offline-transaction-full.json" | grep -c '^ca-certificates$')" "1" \
  "a hyphenated package name survives whole"

# --- what counts as INSTALLING -------------------------------------------------------------------
# Every upgraded package appears TWICE in dnf5's record: the incoming build as "Upgrade" and the
# outgoing one as "Replaced". Reading both would be harmless for an upgrade (same name twice) and
# actively wrong for anything else: a package being REMOVED by the transaction is not a package the
# next restart installs, and reporting it as one would warn a user about a hold that is already
# being honoured.
cat > "$TESTTMP/actions.json" <<'JSON'
{"rpms":[
  {"nevra":"aaa-1.0-1.fc44.x86_64","action":"Upgrade"},
  {"nevra":"bbb-1.0-1.fc44.x86_64","action":"Install"},
  {"nevra":"ccc-1.0-1.fc44.x86_64","action":"Downgrade"},
  {"nevra":"ddd-1.0-1.fc44.x86_64","action":"Reinstall"},
  {"nevra":"outgoing-0.9-1.fc44.x86_64","action":"Replaced"},
  {"nevra":"dropped-0.9-1.fc44.x86_64","action":"Remove"},
  {"nevra":"gone-0.9-1.fc44.x86_64","action":"Removed"}
]}
JSON
assert_eq "$(tx "$TESTTMP/actions.json")" "$(printf 'aaa\nbbb\nccc\nddd\n')" \
  "the four actions that put a package on the disk are the staged set"
assert_eq "$(tx "$TESTTMP/actions.json" | grep -cE '^(outgoing|dropped|gone)$' || true)" "0" \
  "...and the outgoing side of the transaction is not in it"

# --- the name, taken out of a nevra --------------------------------------------------------------
# name-[epoch:]version-release.arch, read from the RIGHT: drop .arch, then -release, then -version.
# Neither the epoch nor the hyphens in the name can be found by looking from the left, and both are
# ordinary on a box that holds kernels: `kernel-core-2:6.18.1-1.fc44.x86_64` is one name, one epoch
# and two hyphens that mean different things.
cat > "$TESTTMP/nevra.json" <<'JSON'
{"rpms":[
  {"nevra":"kernel-core-2:6.18.1-1.fc44.x86_64","action":"Upgrade"},
  {"nevra":"qt6-qtbase-common-1:6.9.2-3.fc44.noarch","action":"Upgrade"},
  {"nevra":"tar-1.35-6.fc44.x86_64","action":"Upgrade"}
]}
JSON
assert_eq "$(tx "$TESTTMP/nevra.json")" "$(printf 'kernel-core\nqt6-qtbase-common\ntar\n')" \
  "an epoch and a multi-hyphen name both read back as the name alone"

# One package, two architectures, is one decision to a user and one name here. The multilib pair is
# also what makes `unique` load-bearing rather than tidy: a caller intersecting a hold against this
# list would otherwise see the same name twice and could report a conflict twice.
cat > "$TESTTMP/multilib.json" <<'JSON'
{"rpms":[
  {"nevra":"bash-5.3.10-1.fc44.x86_64","action":"Upgrade"},
  {"nevra":"bash-5.3.9-4.fc44.i686","action":"Upgrade"}
]}
JSON
assert_eq "$(tx "$TESTTMP/multilib.json")" "bash" "multilib twins are one name, listed once"

# --- every way this can go wrong ends in "no list" ------------------------------------------------
# The format-stability rule (spec 9b, adopted from the second opinion): the parser is pure, the
# fixtures are real dnf5 output, and ANY surprise degrades to the marker snapshot plus the generic
# warning. Never to silence, which would deny a conflict on evidence we do not have; never to a
# crash, which would take a check or a `kempt hold` down over a file dnf5 owns.
assert_degrades "$TESTTMP/no-such-transaction.json" "a transaction that is not there yields no list"

: > "$TESTTMP/empty.json"
assert_degrades "$TESTTMP/empty.json" "a zero-length file yields no list, not an empty transaction"

printf 'this is not json at all\n' > "$TESTTMP/garbage.json"
assert_degrades "$TESTTMP/garbage.json" "a file that is not JSON yields no list"

printf '{"rpms":[{"nevra":"aaa-1.0-1.fc44.x86_64","action":"Upgra' > "$TESTTMP/truncated.json"
assert_degrades "$TESTTMP/truncated.json" "a truncated file yields no list"

printf '["not","an","object"]\n' > "$TESTTMP/array.json"
assert_degrades "$TESTTMP/array.json" "valid JSON of the wrong shape yields no list"

printf '{"version":"1.0"}\n' > "$TESTTMP/norpms.json"
assert_degrades "$TESTTMP/norpms.json" "no rpms key at all yields no list"

printf '{"rpms":{"nevra":"aaa-1.0-1.fc44.x86_64"},"version":"1.0"}\n' > "$TESTTMP/rpmsobj.json"
assert_degrades "$TESTTMP/rpmsobj.json" "an rpms that is not an array yields no list"

# An entry with no nevra, or a nevra that is not a string, is checked across the WHOLE array rather
# than only the entries this parser would have kept: a record dnf5 shaped differently from what we
# expect is a record we cannot claim to have read, whatever the action on that one entry says.
printf '{"rpms":[{"nevra":"aaa-1.0-1.fc44.x86_64","action":"Upgrade"},{"action":"Upgrade"}],"version":"1.0"}\n' \
  > "$TESTTMP/nonevra.json"
assert_degrades "$TESTTMP/nonevra.json" "an entry with no nevra yields no list, not the rest of them"
printf '{"rpms":[{"nevra":["aaa"],"action":"Upgrade"}],"version":"1.0"}\n' > "$TESTTMP/nevratype.json"
assert_degrades "$TESTTMP/nevratype.json" "a nevra that is not a string yields no list"
printf '{"rpms":[{"nevra":"aaa-1.0-1.fc44.x86_64","action":"Upgrade"},"loose"],"version":"1.0"}\n' \
  > "$TESTTMP/entrytype.json"
assert_degrades "$TESTTMP/entrytype.json" "an entry that is not an object yields no list"

# The version field is dnf5's own format stamp. "1.0" is what it writes today; anything outside the
# 1.x line is a format this parser has never seen, and a parser that reads an unknown format
# confidently is exactly what the stability rule forbids. Absent is NOT a surprise - a build that
# stops stamping the file is not a build that changed the shape of it.
printf '{"rpms":[{"nevra":"aaa-1.0-1.fc44.x86_64","action":"Upgrade"}],"version":"2.0"}\n' > "$TESTTMP/v2.json"
assert_degrades "$TESTTMP/v2.json" "a version outside the 1.x line yields no list"
printf '{"rpms":[{"nevra":"aaa-1.0-1.fc44.x86_64","action":"Upgrade"}],"version":1.0}\n' > "$TESTTMP/vnum.json"
assert_degrades "$TESTTMP/vnum.json" "a version that is not even a string yields no list"
printf '{"rpms":[{"nevra":"aaa-1.0-1.fc44.x86_64","action":"Upgrade"}]}\n' > "$TESTTMP/nover.json"
assert_eq "$(tx "$TESTTMP/nover.json")" "aaa" "a record with no version stamp still reads"

# THE NAME GATE. One regex covers jq, the shell, QML and a terminal, and it is the same
# KEMPT_NAME_RE a hold is validated against - so a name this parser would hand onwards is a name
# every other part of Kempt already accepts. One bad name drops the WHOLE list rather than being
# filtered out of it: a list with a name removed is a list that can deny a conflict it never saw.
printf '{"rpms":[{"nevra":"aaa-1.0-1.fc44.x86_64","action":"Upgrade"},{"nevra":"../evil-1.0-1.fc44.x86_64","action":"Upgrade"}],"version":"1.0"}\n' \
  > "$TESTTMP/badname.json"
assert_degrades "$TESTTMP/badname.json" "one name that fails the name gate drops the whole list"
# A nevra too short to carry a version and a release at all leaves nothing to call a name, which
# the same gate refuses - there is no second rule to keep in step.
printf '{"rpms":[{"nevra":"weird","action":"Upgrade"}],"version":"1.0"}\n' > "$TESTTMP/shortnevra.json"
assert_degrades "$TESTTMP/shortnevra.json" "a nevra that is not a nevra drops the list"
# A newline inside a nevra would arrive at a line-based caller as TWO names, each of which passes
# the gate on its own. The count the parser emits alongside the names is what catches it.
printf '{"rpms":[{"nevra":"aa\\nbb-1.0-1.fc44.x86_64","action":"Upgrade"}],"version":"1.0"}\n' \
  > "$TESTTMP/newline.json"
assert_degrades "$TESTTMP/newline.json" "a name carrying a newline drops the list"

# Size, for the same reason the marker has a cap: past it the file is not a record this program
# wrote or expects, and a reader that parses whatever it is handed is a reader that can be handed
# anything. The honest cost is written down where the cap is: a transaction big enough to pass a
# megabyte of JSON degrades to no list, which is the safe direction.
{ printf '{"rpms":[{"nevra":"aaa-1.0-1.fc44.x86_64","action":"Upgrade","pad":"'
  head -c 1100000 /dev/zero | tr '\0' 'a'
  printf '"}],"version":"1.0"}\n'; } > "$TESTTMP/huge.json"
assert_exit 0 "the oversized fixture really is valid JSON" -- jq -e . "$TESTTMP/huge.json"
assert_degrades "$TESTTMP/huge.json" "a transaction record over 1 MB yields no list"

# Unreadable, which is the state on any box where dnf5 has not staged anything and the one this
# runs as an ordinary user in. Mode 000 rather than a missing file: the two arrive at the same
# answer through different branches, and both have to.
cp "$FIXTURES/offline-transaction-full.json" "$TESTTMP/locked.json"
chmod 000 "$TESTTMP/locked.json"
assert_degrades "$TESTTMP/locked.json" "a transaction record that cannot be read yields no list"
chmod 644 "$TESTTMP/locked.json"

# --- and none of it exits ------------------------------------------------------------------------
# The contract the callers rely on: `names="$(offline_txjson_names)" || fall back`. Under
# `set -euo pipefail` a stray `jq` rc or an unbound variable inside the function would kill the
# whole command - a `kempt check` losing every pending package because dnf5 wrote a file we did not
# recognise. Run in a real errexit shell rather than asserted from inside this one.
degraded_run() {  # path → what a strict shell prints
  bash -c 'set -euo pipefail; source "$1/lib/common.sh"
           export KEMPT_OFFLINE_TXJSON="$2"
           if names="$(offline_txjson_names)"; then echo "parsed:$(wc -l <<<"$names")"; else echo "degraded"; fi
           echo "still running"' _ "$REPO_ROOT" "$1"
}
assert_eq "$(degraded_run "$TESTTMP/garbage.json")" "$(printf 'degraded\nstill running\n')" \
  "a strict shell survives a transaction record it cannot parse"
assert_eq "$(degraded_run "$FIXTURES/offline-transaction-full.json")" "$(printf 'parsed:3\nstill running\n')" \
  "...and reads the real one in the same shell"

# --- the name gate on its own --------------------------------------------------------------------
# Shared with the marker write, where the list can also come from a check rather than from the
# transaction. One definition, so the two sources are held to one standard.
assert_exit 0 "a list of ordinary names passes the gate" -- \
  bash -c 'source "$1/lib/common.sh"; printf "bash\nca-certificates\nqt6-qtbase\n" | names_all_valid' _ "$REPO_ROOT"
assert_exit 1 "a list with one bad name does not" -- \
  bash -c 'source "$1/lib/common.sh"; printf "bash\n--exclude=x\n" | names_all_valid' _ "$REPO_ROOT"
assert_exit 1 "...and neither does one carrying an empty line" -- \
  bash -c 'source "$1/lib/common.sh"; printf "bash\n\n" | names_all_valid' _ "$REPO_ROOT"
assert_exit 0 "an empty list is vacuously valid" -- \
  bash -c 'source "$1/lib/common.sh"; printf "" | names_all_valid' _ "$REPO_ROOT"

finish
