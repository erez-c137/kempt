#!/usr/bin/env bash
# Two documentation defects that a reader sees and a diff does not.
#
# Both are silent by construction, which is why they get a test rather than a convention. A
# Markdown table broken by a blank line still renders - just without the rows below the break, as
# literal pipe-laden text - and a seam missing from the environment-seams table is a variable that
# works perfectly and is documented nowhere. Both shipped on main: the 2026-09-05 documentation
# review found a broken table in docs/architecture.md and another in docs/usage.md, each dropping
# that week's own rows out of the rendered page, and three live seams absent from a table sitting
# under a sentence that claims to list every one of them.
#
# Nothing here needs jq, a package manager or a desktop: it reads the tree it is standing in.
source "$(dirname "$0")/lib.sh"; sandbox

# --- a table split in two by a blank line --------------------------------------------------------
# The rule is exactly the rendering rule: a blank line ENDS a table, so a row, a blank line and
# another row is one table that renders and one block of text that does not.
# docs/research/ is excluded for the reason CONTRIBUTING.md gives about the same tree - it is a
# working archive rather than published documentation, and the em-dash sweep already exempts it.
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
done < <(find "$REPO_ROOT" -name '*.md' -not -path '*/.git/*' -not -path '*/docs/research/*' | sort)
assert_eq "${broken%$'\n'}" "" "no Markdown table is split in two by a blank line"

# --- every environment seam has a row in the seams table -----------------------------------------
# docs/architecture.md's seams table sits under a sentence saying every impure call in the CLI goes
# through one of these. That claim is about the CODE, so this test derives the list from the code
# and asks the table about it, rather than asking a maintained list about either.
#
# A seam is a KEMPT_* variable read with a default - ${KEMPT_X:-...} or ${KEMPT_X-...} - which is
# precisely what "overridable from the environment" means. Plain assignments (KEMPT_NAME_RE, the
# two size caps, KEMPT_STAGED_RECIPE, KEMPT_AUTH_DECLINED, KEMPT_JQ_COUNTS) are internal constants
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

finish
