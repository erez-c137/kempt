#!/usr/bin/env bash
# Documentation defects that a reader sees and a diff does not, and the limits that keep the docs
# short.
#
# A Markdown table broken by a blank line still renders, but the rows below the break show as
# literal text full of pipes. A seam missing from the environment-seams table works and is
# documented nowhere. Neither shows in a diff, so each gets a test instead of a convention.
#
# Nothing here needs jq, a package manager or a desktop: it reads the tree it is standing in. The
# word budgets and the prose check need python3.
source "$(dirname "$0")/lib.sh"; sandbox

# --- a table split in two by a blank line --------------------------------------------------------
# The rule is exactly the rendering rule: a blank line ENDS a table, so a row, a blank line and
# another row is one table that renders and one block of text that does not.
# Every .md in the tree, with no exclusions.
broken=""
while IFS= read -r f; do
  hits="$(awk '
    BEGIN { p2 = ""; p1 = "" }
    p2 ~ /^[ \t]*\|/ && p1 ~ /^[ \t]*$/ && $0 ~ /^[ \t]*\|/ { printf "%d ", NR - 1 }
    { p2 = p1; p1 = $0 }
  ' "$f")"
  # The `if` form rather than `[[ ... ]] && x=y`: a false test as the last command of a loop body
  # returns 1, and errexit would end the file there rather than at an assertion.
  if [[ -n "$hits" ]]; then
    broken+="${f#"$REPO_ROOT"/} line(s): ${hits% }"$'\n'
  fi
done < <(find "$REPO_ROOT" -name '*.md' -not -path '*/.git/*' -not -path '*/internal/*' | sort)
assert_eq "${broken%$'\n'}" "" "no Markdown table is split in two by a blank line"

# --- every environment seam has a row in the seams table -----------------------------------------
# docs/architecture.md's seams table sits under a sentence saying every impure call in the CLI goes
# through one of these. That claim is about the CODE, so this test derives the list from the code
# and asks the table about it, rather than asking a maintained list about either.
#
# A seam is a KEMPT_* variable read with a default - ${KEMPT_X:-...} or ${KEMPT_X-...} - which is
# precisely what "overridable from the environment" means. Plain assignments (KEMPT_NAME_RE, the
# two size caps, KEMPT_STAGED_RECIPE, the KEMPT_AUTH_* sentences, KEMPT_JQ_COUNTS) are internal constants
# that no caller can influence, and they are excluded by that SHAPE rather than by a list - so a
# constant that becomes a seam is caught on the day it does, not remembered.
ARCH="$REPO_ROOT/docs/architecture.md"

# Not exempt from the table, but in the list below with a reason. Empty today, and it stays here so
# the next one has a home: add a name only with a comment saying why a reader could never need it.
NOT_SEAMS=()

table="$(awk '/^## Environment seams$/ { f = 1; next } f && /^## / { exit } f' "$ARCH")"
assert_eq "$([[ -n "$table" ]] && echo found || echo missing)" "found" \
  "docs/architecture.md still has an '## Environment seams' section"

undocumented=""
while IFS= read -r v; do
  [[ -n "$v" ]] || continue
  skip=false
  for x in ${NOT_SEAMS[@]+"${NOT_SEAMS[@]}"}; do
    if [[ "$x" == "$v" ]]; then skip=true; fi
  done
  if [[ "$skip" == true ]]; then continue; fi
  # Backticked, because that is how the table writes a variable and a bare grep would also match
  # the same name in the prose around it.
  if ! grep -qF "\`$v\`" <<<"$table"; then
    undocumented+="$v "
  fi
done < <(
  # The root helpers and the widget are in this list too. They read seams of their own
  # (KEMPT_*_ECHO in the helpers, the state and config directories in the widget), and leaving
  # them out meant a seam could be added there and documented nowhere without the suite noticing.
  grep -ohE '\$\{KEMPT_[A-Z0-9_]+:?-' \
    "$REPO_ROOT/lib/common.sh" "$REPO_ROOT/bin/kempt" \
    "$REPO_ROOT"/backends/*.sh "$REPO_ROOT/install.sh" \
    "$REPO_ROOT"/libexec/* "$REPO_ROOT"/plasmoid/contents/ui/*.qml \
    "$REPO_ROOT"/plasmoid/contents/ui/*.js \
  | sed 's/^\${//; s/[-:].*$//' | sort -u
)
assert_eq "${undocumented% }" "" \
  "every KEMPT_* seam read by the code has a row in the environment-seams table"

# --- every event line has a row in the `kempt log` vocabulary table ------------------------------
# docs/usage.md's log section says "The vocabulary is fixed, so the file is worth grepping". That is
# a promise about the CODE, so this derives the list from the code and asks the table about it -
# the same shape as the seams check above. It was already false for five families when this was
# written, and it went false again for seven more the day `kempt unstage` was added, in both cases
# with nothing to notice.
#
# The key is the first two words of each line's LITERAL prefix: the text before the first variable,
# which is the part a person greps for and the part that must never appear from nowhere. So this
# binds the VOCABULARY rather than whole sentences - a new variant inside a documented family
# ("offline marker kept" beside "offline marker cleared") passes, a new family does not. Binding
# whole sentences is not possible from here: most of them are half shell expansion.
LOGSEC="$(awk '/^## log$/ { f = 1; next } f && /^## / { exit } f' "$REPO_ROOT/docs/usage.md")"
assert_eq "$([[ -n "$LOGSEC" ]] && echo found || echo missing)" "found" \
  "docs/usage.md still has a '## log' section"

undocumented_events=""
while IFS= read -r ev; do
  [[ -n "$ev" ]] || continue
  grep -qF "$ev" <<<"$LOGSEC" || undocumented_events+="$ev; "
done < <(
  # `[^"$]+` stops at the first variable, so what is captured is only the fixed text. Both files,
  # because log_event is called from the library as well as the CLI.
  grep -ohE 'log_event "[^"$]+' "$REPO_ROOT/bin/kempt" "$REPO_ROOT/lib/common.sh" \
  | sed 's/^log_event "//' \
  | awk 'NF >= 2 { print $1 " " $2; next } NF == 1 { print $1 }' \
  | sort -u
)
assert_eq "${undocumented_events%; }" "" \
  "every log_event line has a row in the kempt log vocabulary table"

# --- the release check is named where somebody will look for it ---------------------------------
# A check nobody can find is never run. The script exists, it is executable, and the three
# documents a contributor reads name it.
assert_exit 0 "the release check exists" -- test -f "$REPO_ROOT/tests/release/release-check.sh"
assert_exit 0 "...and its runner is executable" -- test -x "$REPO_ROOT/tests/release/run-release-check.sh"
for doc in docs/RELEASING.md CONTRIBUTING.md AGENTS.md; do
  grep -q 'tests/release' "$REPO_ROOT/$doc" \
    && echo "ok: $doc names the release check" \
    || { echo "FAIL: $doc never mentions tests/release, so a reader cannot find it"; _fail=1; }
done
# It reads the version, so it cannot go stale when the version moves.
grep -q 'VERSION' "$REPO_ROOT/tests/release/release-check.sh" \
  && echo "ok: the release check reads VERSION" \
  || { echo "FAIL: the release check does not read VERSION"; _fail=1; }
if grep -qE '[0-9]+\.[0-9]+\.[0-9]+' "$REPO_ROOT/tests/release/release-check.sh"; then
  echo "FAIL: the release check hardcodes a version, which is how the last one went stale"; _fail=1
else
  echo "ok: ...and hardcodes no version of its own"
fi

# --- every doc stays inside its word budget and passes the prose check ---------------------------
# A change to a doc leaves it no longer (AGENTS.md, "Writing"). Each budget was set about 5% above
# the doc's size, rounded up. tools/prose-check.py counts the words, and it skips code blocks,
# tables, headings and blockquotes, so an example or a table row costs nothing. Raise a budget only
# when the reader gains something new, and say why in the commit.
declare -A WORD_BUDGET=(
  [README.md]=820
  [AGENTS.md]=420
  [CONTRIBUTING.md]=1700
  [SECURITY.md]=420
  [tests/README.md]=310
  [docs/architecture.md]=4500
  [docs/configuration.md]=1150
  [docs/install.md]=1550
  [docs/RELEASING.md]=840
  [docs/ROADMAP.md]=1750
  [docs/security.md]=3600
  [docs/usage.md]=2800
  [docs/widget.md]=2600
)
# A new doc needs a row, so it cannot grow outside the table.
unbudgeted=""
for f in "$REPO_ROOT"/docs/*.md; do
  rel="${f#"$REPO_ROOT"/}"
  if [[ -z "${WORD_BUDGET[$rel]+set}" ]]; then unbudgeted+="$rel "; fi
done
assert_eq "${unbudgeted% }" "" "every docs/*.md has a word budget in tests/test_docs.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is missing, so the word budgets and the prose check cannot run"; _fail=1
else
  while IFS= read -r rel; do
    # The first line reads "FILE: N words, M per sentence, PASS" or "..., FAIL, ...".
    out="$(python3 "$REPO_ROOT/tools/prose-check.py" "$REPO_ROOT/$rel")" || true
    head="${out%%$'\n'*}"
    words="$(sed -nE 's/^.*: ([0-9]+) words, .*$/\1/p' <<<"$head")"
    budget="${WORD_BUDGET[$rel]}"
    if [[ -z "$words" ]]; then
      echo "FAIL: tools/prose-check.py could not read $rel"; _fail=1
    elif (( words > budget )); then
      echo "FAIL: $rel is $words words, its budget is $budget: cut it, or raise the budget in this table and say why in the commit"
      _fail=1
    else
      echo "ok: $rel is $words words, inside its budget of $budget"
    fi
    if [[ "$head" == *", PASS" ]]; then
      echo "ok: $rel passes tools/prose-check.py"
    else
      echo "FAIL: $rel fails tools/prose-check.py. Run python3 tools/prose-check.py --show $rel"
      printf '%s\n' "$out" | sed 1d
      _fail=1
    fi
  done < <(printf '%s\n' "${!WORD_BUDGET[@]}" | sort)
fi

# --- the public tree does not talk about how it was made ------------------------------------------
# Public files state facts without saying who decided them or how the work was done
# (CONTRIBUTING.md, "What never goes in a public file"). This catches the words a search can find.
#
# The patterns are assembled from fragments so this file does not match itself, and the scan skips
# .git, internal/, .claude/ (local tool state, gitignored, never shipped) and every binary (grep -I). No `git ls-files`: the RPM's %check stage runs the
# suite against a copy of the tree with no .git in it at all.
private_words=("found""er" "hostile ""panel" "UX ""panel" "Task ""W[0-9]" "WP-""[A-Z][0-9]" "\bFab""le\b" "sub""agent")
private_re="$(printf '%s|' "${private_words[@]}")"; private_re="${private_re%|}"
leaked=""
while IFS= read -r f; do
  [[ "$f" == "$REPO_ROOT/tests/test_docs.sh" ]] && continue   # holds the patterns themselves
  grep -qIiE "$private_re" "$f" 2>/dev/null && leaked+="${f#"$REPO_ROOT/"} "
done < <(find "$REPO_ROOT" \
           -path "$REPO_ROOT/.git" -prune -o \
           -path "$REPO_ROOT/internal" -prune -o \
           -path "$REPO_ROOT/.claude" -prune -o \
           -type f -print)
assert_eq "${leaked% }" "" \
  "no public file talks about the project's own review process"

# --- and no public file cites a document the public cannot open ----------------------------------
# A comment that cites a notes file sends the reader to a file that is not here. Every .md a public
# file names must be in the tree. Paths built from a variable are skipped, and so are the files a
# documented command creates (made_by_commands).
# .claude/ is local tooling state, never tracked or shipped, so it is pruned with internal/.
present="$(find "$REPO_ROOT" -path "$REPO_ROOT/.git" -prune -o -path "$REPO_ROOT/internal" -prune \
             -o -path "$REPO_ROOT/.claude" -prune -o -name '*.md' -type f -printf '%f\n' | sort -u)"
made_by_commands=("notes.md")   # docs/RELEASING.md: gh release create --notes-file notes.md
missing=""
while IFS= read -r f; do
  while IFS= read -r ref; do
    [[ "$ref" == *'$'* ]] && continue
    [[ " ${made_by_commands[*]} " == *" ${ref##*/} "* ]] && continue
    grep -qxF -- "${ref##*/}" <<<"$present" || missing+="${f#"$REPO_ROOT/"}:${ref##*/} "
  done < <(grep -oIE '[$A-Za-z0-9_./{}-]*[A-Za-z0-9_-]\.md\b' "$f" 2>/dev/null | sort -u)
done < <(find "$REPO_ROOT" -path "$REPO_ROOT/.git" -prune -o -path "$REPO_ROOT/internal" -prune \
           -o -path "$REPO_ROOT/.claude" -prune -o -type f -print)
assert_eq "$(tr ' ' '\n' <<<"${missing% }" | sort -u | tr '\n' ' ' | sed 's/ $//')" "" \
  "every .md file a public file names is in the repository"

# --- and no email address outside the three places a format requires one -------------------------
# The RPM %changelog's format is `Name <email>`, a security policy has to say where to send a
# report, and a code of conduct has to say who to tell. Everywhere else an address is either a
# leak or a maintenance burden, and both were in this tree. .claude/ is local tool state, never
# shipped, and holds other checkouts of this tree.
mail_re='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
mail_ok=("$REPO_ROOT/kempt.spec" "$REPO_ROOT/SECURITY.md" "$REPO_ROOT/CODE_OF_CONDUCT.md"
         "$REPO_ROOT/tests/test_docs.sh")
addressed=""
while IFS= read -r f; do
  skip=false
  for x in "${mail_ok[@]}"; do [[ "$f" == "$x" ]] && skip=true; done
  [[ "$skip" == true ]] && continue
  grep -qIE "$mail_re" "$f" 2>/dev/null && addressed+="${f#"$REPO_ROOT/"} "
done < <(find "$REPO_ROOT" \
           -path "$REPO_ROOT/.git" -prune -o \
           -path "$REPO_ROOT/internal" -prune -o \
           -path "$REPO_ROOT/.claude" -prune -o \
           -type f -print)
assert_eq "${addressed% }" "" \
  "no email address outside the spec changelog, SECURITY.md and CODE_OF_CONDUCT.md"

# kempt reclaim has no --allow-auth: every removal asks polkit without a dialog. No doc may offer it.
USAGE_RECLAIM="$(awk '/^  reclaim \[/ { print; getline; print }' "$REPO_ROOT/bin/kempt")"
assert_contains "$USAGE_RECLAIM" "--expect=DIGEST" "premise: kempt usage has the reclaim line"
assert_eq "$(grep -rlF -e '--allow-auth' -e 'allow\-auth' "$REPO_ROOT/bin" "$REPO_ROOT/docs" "$REPO_ROOT/plasmoid" \
  "$REPO_ROOT/README.md" 2>/dev/null | sed "s|$REPO_ROOT/||" | tr '\n' ' ')" "" \
  "no command line, doc or widget passes or documents reclaim --allow-auth"

finish
