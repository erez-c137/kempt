#!/usr/bin/env bash
# `kempt hold` and `kempt unhold` against a transaction that is already armed.
#
# The trap, in one sequence a user actually runs: stage 83 packages with the kernel among them,
# read something worrying about that kernel, run `kempt hold dnf:kernel-core` because that is what
# Kempt taught them to do, restart - and kernel-core installs. Nothing lied: dnf5 built and stored
# that transaction before the hold existed, holds apply when Kempt builds a transaction, and dnf5
# offers no way to edit a stored one. But the user assembled a true belief out of Kempt's own
# surfaces and the machine contradicted it, which is the exact failure this project exists to
# remove - at its worst, because installing the thing you feared is the point of holding it.
#
# What this file pins is the shape of the answer, and the shape is deliberately small:
#
#   the hold is ALWAYS recorded. Recording never fails, never blocks, never prompts, never
#   escalates, and the exit status stays 0. `hold` is a bookkeeping verb.
#
#   a warning may be wrong in ONE direction. Names may CONFIRM a conflict; only a
#   transaction-derived list may deny one. Where the list is check-derived or missing, the generic
#   warning fires instead of silence - it can be wrong by warning about a package that is not in
#   there, never by staying quiet about one that is.
#
#   interactive and non-interactive are identical. There is no prompt, no y/N, no TTY test. The
#   rebuild is a command the user types, or a button the widget offers.
#
# Copy is quoted verbatim from the spec's copy table, and quoted here rather than built from the
# helpers, so a rewrite of the renderers cannot silently rewrite what the user reads.
source "$(dirname "$0")/lib.sh"; sandbox
KEMPT="$REPO_ROOT/bin/kempt"
source "$REPO_ROOT/lib/common.sh"

# --- the plural renderer, on its own --------------------------------------------------------------
# One name per invocation is the CLI's contract, so today this only ever renders one. It is written
# and pinned anyway because the widget's conflict banner and the doctor line both name a SET, and a
# second implementation of "a, b and c" is a second thing to keep in step with this one.
# Cap 4, then ", and N more": a Qt or KDE bump legitimately puts dozens of names in the set, and a
# sentence that lists them all is a sentence nobody reads.
phrase() { printf '%s\n' "$@" | names_phrase; }
assert_eq "$(phrase kernel-core)" "kernel-core" "one name is just the name"
assert_eq "$(phrase kernel-core systemd)" "kernel-core and systemd" "two names join with and, no comma"
assert_eq "$(phrase kernel-core systemd glibc)" "kernel-core, systemd and glibc" \
  "three names: commas, then and before the last"
assert_eq "$(phrase kernel-core systemd glibc mesa)" "kernel-core, systemd, glibc and mesa" \
  "four names is the cap, and still reads as a sentence"
assert_eq "$(phrase kernel-core systemd glibc mesa kwin)" "kernel-core, systemd, glibc, mesa, and 1 more" \
  "one past the cap becomes a count"
assert_eq "$(phrase kernel-core systemd glibc mesa kwin dbus)" "kernel-core, systemd, glibc, mesa, and 2 more" \
  "six names: four named, the rest counted"
assert_eq "$(printf '' | names_phrase)" "" "no names renders nothing at all"

# The sentences themselves, singular and plural. The verb moves with the noun - "installs it" for
# one package, "installs them" for several - the same rule the staged summary line follows.
assert_eq "$(printf 'kernel-core\n' | hold_staged_warning)" \
  "The staged update still contains kernel-core and installs it on the next restart." \
  "the singular warning, verbatim"
assert_eq "$(printf 'kernel-core\nsystemd\nglibc\n' | hold_staged_warning)" \
  "The staged update still contains kernel-core, systemd and glibc and installs them on the next restart." \
  "the plural warning, verbatim"
assert_eq "$KEMPT_STAGED_RECIPE" \
  "When ready: kempt update --surface=offline (rebuilds it with your holds) or sudo dnf5 offline clean (removes it)." \
  "the recipe offers both remedies - rebuild it, or remove it"
assert_eq "$(hold_generic_warning kernel-core)" \
  "The staged update was built before this hold and may still install kernel-core on the next restart. Rebuilding applies all current holds." \
  "the warning for when no list may be trusted, verbatim"
assert_eq "$(unhold_staged_warning kernel-core)" \
  "The staged update was built without kernel-core - the next restart will not install it. Rebuild when ready: kempt update --surface=offline." \
  "the unhold mirror, verbatim"

# --- a real armed stage to hold against ----------------------------------------------------------
# The marker is written by a real `kempt update --surface=offline`, not by hand: the fields the
# warning reads are the fields that command writes, and a hand-built marker would pass for a shape
# the CLI never produces.
export WORLD="$TESTTMP/world"; mkdir -p "$WORLD"
cp "$FIXTURES/snap-before.tsv" "$WORLD/rpm.tsv"
cat > "$TESTTMP/apply-stub" <<STUB
#!/usr/bin/env bash
echo "APPLY \$@" >> "$WORLD/apply-calls"
exit 0
STUB
chmod +x "$TESTTMP/apply-stub"
cat > "$TESTTMP/refresh-stub" <<STUB
#!/usr/bin/env bash
[[ "\$1" == check ]] && { cat "$FIXTURES/dnf-check-update.txt"; exit 100; }
exit 0
STUB
chmod +x "$TESTTMP/refresh-stub"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTTMP/dnf-reboot-no"
chmod +x "$TESTTMP/dnf-reboot-no"
export KEMPT_APPLY_HELPER="$TESTTMP/apply-stub"
export KEMPT_REFRESH_HELPER="$TESTTMP/refresh-stub"
export KEMPT_DNF_INSTALLED_CMD="cat $WORLD/rpm.tsv"
export KEMPT_DNF_CMD="$TESTTMP/dnf-reboot-no"
export KEMPT_SKIP_REFRESH=1
"$KEMPT" config set include_flatpak false >/dev/null
marker="$KEMPT_STATE_DIR/offline_staged.json"
st="$KEMPT_STATE_DIR/state.json"
printf 'not a transaction\n' > "$TESTTMP/tx-garbage.json"
events_tail() { tail -1 "$KEMPT_STATE_DIR/events.log" 2>/dev/null | cut -d' ' -f3-; }

# stderr and the exit status together, because either alone would pass for the wrong reason: a
# warning that also failed the command would break the "recording never blocks" invariant, and a
# clean exit that said nothing is the bug this whole file is about.
hold_stderr() {  # args... → the warning on stdout, and asserts the command still exited 0
  local rc=0 out
  out="$("$KEMPT" "$@" 2>&1 >/dev/null)" || rc=$?
  [[ "$rc" == 0 ]] || { echo "FAIL: kempt $* exited $rc, and recording a hold must never fail" >&2; _fail=1; }
  printf '%s\n' "$out"
}

"$KEMPT" update --surface=offline --no-flatpak >/dev/null
assert_exit 0 "the stage armed and left a marker" -- test -f "$marker"
assert_eq "$(jq -r '.staged_names_source' "$marker")" "transaction" \
  "...whose names came from dnf5's own transaction"

# THE TRAP, closed. librepo is in the recorded transaction; holding it now cannot take it out.
warn="$(hold_stderr hold dnf:librepo)"
assert_eq "$warn" "$(printf '%s\n%s\n' \
  "The staged update still contains librepo and installs it on the next restart." \
  "$KEMPT_STAGED_RECIPE")" \
  "holding a package the stage contains says so, and says what to do about it"
assert_eq "$(holds_for dnf)" "librepo" "...and the hold is recorded all the same"
assert_eq "$(events_tail)" "hold dnf:librepo (staged update still contains it)" \
  "...and the event log carries the conflict, not just the hold"

# Same command with a terminal on stdin and with none. There is no prompt to be interactive about,
# so the two must be indistinguishable - a warning that only appeared for someone sitting at a
# terminal would be missing from exactly the case that needs it, a hold clicked in the panel.
tty_warn="$(KEMPT_ASSUME_TTY=1 "$KEMPT" hold dnf:librepo 2>&1 >/dev/null </dev/null || true)"
assert_eq "$tty_warn" "$warn" "interactive and non-interactive say exactly the same thing"

# A package that is NOT in the transaction. The transaction-derived list is the only evidence
# allowed to produce silence, and here it does: bash is pending, holding it is perfectly sensible,
# and it has nothing to do with the stage.
assert_eq "$(hold_stderr hold dnf:bash)" "" "a hold on a package the stage does not contain is silent"
assert_eq "$(events_tail)" "hold dnf:bash" "...and its event line carries no conflict either"

# Flatpak. The offline surface stages dnf and nothing else, so a flatpak hold can never conflict
# with an armed transaction - and the filter is explicit rather than left to come out empty by
# luck, because "no dnf name matched" and "this is not a dnf hold" are different reasons.
assert_eq "$(hold_stderr hold flatpak:org.gimp.GIMP)" "" "a flatpak hold over an armed stage is silent"
"$KEMPT" unhold flatpak:org.gimp.GIMP >/dev/null

# --- when the list cannot be trusted --------------------------------------------------------------
# The live record unreadable and the marker's own list transaction-derived: the marker decides, in
# BOTH directions. It is still evidence from a transaction, so it may still deny.
tx_broken() { KEMPT_OFFLINE_TXJSON="$TESTTMP/tx-garbage.json" "$@"; }
mwarn="$(tx_broken "$KEMPT" hold dnf:openldap 2>&1 >/dev/null || true)"
assert_eq "$mwarn" "$(printf '%s\n%s\n' \
  "The staged update still contains openldap and installs it on the next restart." \
  "$KEMPT_STAGED_RECIPE")" \
  "an unreadable transaction record falls back to the marker's own list, which still names it"
assert_eq "$(tx_broken "$KEMPT" hold dnf:tar 2>&1 >/dev/null || true)" "" \
  "...and that same list is still allowed to keep Kempt quiet about a package it does not contain"

# A marker whose names only ever came from a CHECK. A check cannot see the packages the resolver
# added, so its list may confirm a conflict and may never deny one - which leaves the generic
# warning as the only honest answer, for every name.
jq '.staged_names_source = "check"' "$marker" > "$marker.tmp" && mv "$marker.tmp" "$marker"
assert_eq "$(tx_broken "$KEMPT" hold dnf:tar 2>&1 >/dev/null || true)" \
  "The staged update was built before this hold and may still install tar on the next restart. Rebuilding applies all current holds."$'\n'"$KEMPT_STAGED_RECIPE" \
  "a check-derived list cannot deny anything, so the generic warning fires, recipe and all"
assert_eq "$(events_tail)" "hold dnf:tar" \
  "...and an unconfirmed conflict is not recorded as one"

# A marker written before any of this existed. It knows no names; the same generic warning is what
# is left, and it is the reason the warning exists in that form at all.
jq 'del(.staged_names, .staged_names_source, .staged_excluded)' "$marker" > "$marker.tmp" && mv "$marker.tmp" "$marker"
assert_eq "$(tx_broken "$KEMPT" hold dnf:curl 2>&1 >/dev/null || true)" \
  "The staged update was built before this hold and may still install curl on the next restart. Rebuilding applies all current holds."$'\n'"$KEMPT_STAGED_RECIPE" \
  "a legacy marker with no names warns generically rather than staying quiet, and still names the way out"
# ...and with the live record readable again, that same legacy marker needs no fallback at all: the
# transaction is right there, and it is the primary source precisely so a legacy marker costs
# nothing.
assert_eq "$(hold_stderr hold dnf:curl)" "" \
  "a legacy marker over a readable transaction is answered by the transaction"

# --- when there is nothing to conflict with -------------------------------------------------------
# Staged but never armed. It installs on no restart, so there is no promise for a hold to
# contradict, and `kempt doctor` is where that discrepancy is explained instead.
assert_eq "$(KEMPT_OFFLINE_TOML="$FIXTURES/offline-download-complete.toml" \
             "$KEMPT" hold dnf:librepo 2>&1 >/dev/null || true)" "" \
  "a stage that was never armed raises no warning: no restart applies it"
# No marker: either nothing was staged, or somebody else staged it. Not Kempt's promise to break.
mv "$marker" "$TESTTMP/marker.saved"
assert_eq "$(hold_stderr hold dnf:librepo)" "" "no marker, no promise, no warning"
mv "$TESTTMP/marker.saved" "$marker"

# --- unhold, the mirror case ----------------------------------------------------------------------
# Lower stakes and the same shape: the package was held, the stage was built without it, and
# releasing the hold does not put it back. Gated on staged_excluded because the transaction itself
# can never say WHY a package is absent from it - "held at stage time" and "had no update" look
# identical from the inside.
: > "$WORLD/apply-calls"
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
# Every hold the cases above left behind, cleared in one go: the assertions below are about which
# names the STAGE excluded, and a hold surviving from an earlier probe would put a second name in
# that list for reasons nothing here is testing.
: > "$KEMPT_CONFIG_DIR/holds"
"$KEMPT" hold dnf:curl >/dev/null 2>&1
"$KEMPT" update --surface=offline --no-flatpak >/dev/null
assert_eq "$(jq -c '.staged_excluded' "$marker")" '["curl"]' "the stage recorded what it left out"
assert_eq "$(hold_stderr unhold dnf:curl)" \
  "The staged update was built without curl - the next restart will not install it. Rebuild when ready: kempt update --surface=offline." \
  "releasing a hold the stage was built around says the stage will not install it"
assert_eq "$(events_tail)" "unhold dnf:curl (staged update was built without it)" \
  "...and the event log says which stage it means"
assert_eq "$(holds_for dnf | wc -l)" "0" "...and the hold really is gone"

# A package that was never excluded from this stage. Warning here would be nagging about a decision
# nobody made: the package simply had no update when the stage was built.
assert_eq "$(hold_stderr unhold dnf:never-held)" "" "unholding a package the stage never excluded is silent"
assert_eq "$(hold_stderr unhold dnf:librepo)" "" \
  "...including one that IS in the transaction: it is in there, so nothing was missed"

# The legacy fallback, for a marker with no staged_excluded at all: warn only when the package is
# pending RIGHT NOW, because a package with no update to miss cannot have been missed.
"$KEMPT" check >/dev/null
jq 'del(.staged_excluded)' "$marker" > "$marker.tmp" && mv "$marker.tmp" "$marker"
assert_eq "$(jq -r '[.backends.dnf.items[].name] | index("bash") != null' "$st")" "true" \
  "bash really is pending, which is what the fallback keys on"
assert_eq "$(hold_stderr unhold dnf:bash)" \
  "The staged update was built without bash - the next restart will not install it. Rebuild when ready: kempt update --surface=offline." \
  "a legacy marker falls back to what is pending now"
assert_eq "$(hold_stderr unhold dnf:not-a-package)" "" \
  "...and a package that is not pending at all is still silent"

# --- after the harvest ----------------------------------------------------------------------------
# The whole feature is scoped to the marker's lifetime, and this is what that means in practice:
# stage, hold (warned), restart, harvest - and now the same hold is an ordinary hold that applies to
# the next transaction Kempt builds. Nothing to warn about, because there is nothing staged.
# Pinned explicitly rather than left implied by the no-marker case above: it is the sequence a real
# user walks through, and a regression here would put a permanent warning on a package forever.
: > "$WORLD/apply-calls"
rm -f "$marker" "$KEMPT_STATE_DIR"/snapshots/offline-pre-*.tsv
"$KEMPT" update --surface=offline --no-flatpak >/dev/null
assert_eq "$(hold_stderr hold dnf:openldap)" "$(printf '%s\n%s\n' \
  "The staged update still contains openldap and installs it on the next restart." \
  "$KEMPT_STAGED_RECIPE")" \
  "before the restart, the hold conflicts with the armed stage"
# What the harvest does to the marker, done here directly: the transaction ran, the marker was
# turned into a history entry and removed. Nothing else about the box changed - the hold is still
# recorded, the transaction record is still readable, dnf5 still reports `ready`.
rm -f "$marker"
assert_eq "$(hold_stderr hold dnf:openldap)" "" \
  "after the harvest the same hold is silent: it applies to the next transaction, and says nothing about a past one"

finish
