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
# Every .md in the tree, with no exclusions. The working papers that used to need one are not
# published any more - they live with the project's private notes, outside this repository.
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

# --- the public tree does not talk about its own review process ----------------------------------
# This repository is public, and it was carrying the vocabulary of a private one: the maintainer
# named in the third person, the review exercises a finding came out of, work-package codes with
# no referent, and the codename of a tool used to draft a document. From outside it reads as
# internal minutes left in the source, and two of them were shipping inside the RPM - the icon
# SVGs, which name a person and a date for a design decision that stands perfectly well on its own.
#
# The rule is the same one the comments follow: the FACT stays, the provenance goes. "61 packages
# staged at 10:31 and nothing changed" is evidence with or without whose machine it was.
# internal/ is gitignored and is where that vocabulary belongs.
#
# The patterns are assembled from fragments so this file does not match itself, and the scan skips
# .git, internal/ and every binary (grep -I). No `git ls-files`: the RPM's %check stage runs the
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
           -type f -print)
assert_eq "${leaked% }" "" \
  "no public file talks about the project's own review process"

# --- and no email address outside the three places a format requires one -------------------------
# The RPM %changelog's format is `Name <email>`, a security policy has to say where to send a
# report, and a code of conduct has to say who to tell. Everywhere else an address is either a
# leak or a maintenance burden, and both were in this tree.
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
           -type f -print)
assert_eq "${addressed% }" "" \
  "no email address outside the spec changelog, SECURITY.md and CODE_OF_CONDUCT.md"

finish
