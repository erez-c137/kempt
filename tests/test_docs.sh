#!/usr/bin/env bash
# Documentation defects that a reader sees and a diff does not.
#
# A Markdown table broken by a blank line still renders, but the rows below the break show as
# literal text full of pipes, and that shows in no diff, so it gets a test instead of a convention.
#
# Nothing here needs jq, a package manager or a desktop: it reads the tree it is standing in. The
# prose check needs python3.
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

# --- every doc passes the prose check --------------------------------------------------------------
# tools/prose-check.py reads sentence length, asides and self-praise. It skips code blocks, tables,
# headings and blockquotes. Docs have no word limit; a release compares `wc -w` with the last tag.
PROSE_DOCS=(README.md CONTRIBUTING.md SECURITY.md "$REPO_ROOT"/docs/*.md)
if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is missing, so the prose check cannot run"; _fail=1
else
  for rel in "${PROSE_DOCS[@]}"; do
    rel="${rel#"$REPO_ROOT"/}"
    out="$(python3 "$REPO_ROOT/tools/prose-check.py" "$REPO_ROOT/$rel")" || true
    head="${out%%$'\n'*}"
    if [[ "$head" == *", PASS" ]]; then
      echo "ok: $rel passes tools/prose-check.py"
    else
      echo "FAIL: $rel fails tools/prose-check.py. Run python3 tools/prose-check.py --show $rel"
      printf '%s\n' "$out" | sed 1d
      _fail=1
    fi
  done
fi

# CHANGELOG.md and the man page are NOT run through tools/prose-check.py, on purpose. The changelog
# is a record of what changed, so the history words the check flags ("no longer", "an earlier
# version") are its job, and it is 15,000 words of past releases; the man page is roff, which the
# Markdown reader mistakes for 33-word sentences. They get the dash rules below instead.
# Customer-facing text: no em dash, and no " - " aside (rephrase or use a comma). Headings
# ("## [0.1.8] - Unreleased") and the two quoted messages the program prints with that dash stay.
# The man page spells dashes as roff escapes too: \(em, \(en, \[em], \[en], and \- between spaces as an
# aside. Its NAME line ("kempt \- ...") needs that escape, so it is excluded by content.
MAN="${MAN_PAGE:-$REPO_ROOT/docs/man/kempt.1}"
roff_dash='\\\((em|en)|\\\[(em|en)\]| \\- '
dashes="$(grep -nE '—|–' "$REPO_ROOT/CHANGELOG.md" "$MAN" | cut -d: -f1,2 | tr '\n' ' ' || true)"
dashes+="$(grep -nE "$roff_dash" "$MAN" | grep -vE '^[0-9]+:kempt \\- ' | cut -d: -f1 | sed 's/^/man:/' | tr '\n' ' ' || true)"
asides="$(grep -nE ' - ' "$REPO_ROOT/CHANGELOG.md" | grep -vE '^[0-9]+:## \[|Nothing to stage - |Updates staged - they' | cut -d: -f1 | tr '\n' ' ' || true)"
asides+="$(grep -nE ' - ' "$MAN" | cut -d: -f1 | sed 's/^/man:/' | tr '\n' ' ' || true)"
assert_eq "${dashes% }" "" "CHANGELOG.md and the man page have no em or en dash"
assert_eq "${asides% }" "" "CHANGELOG.md and the man page have no ' - ' aside (line numbers)"

# --- the public tree does not talk about how it was made ------------------------------------------
# Public files state facts without saying who decided them or how the work was done
# (CONTRIBUTING.md, "What never goes in a public file"). This catches the words a search can find.
#
# The words are kept as sha256 hashes, so this file does not spell them out. Each file is split
# into lowercase words of letters and digits. Every word is hashed, and so is every pair of
# neighbours. In a pair, a second word that starts with letters then a digit is also hashed as those
# letters plus 0, and as ?0 when one letter starts it, so a numbered label matches whatever its
# number. To add a word: printf '%s' word | sha256sum.
#
# The scan skips internal/, .git, every other hidden directory but .github/ and every binary file
# (one with a NUL byte). Hidden directories hold local editor state, never shipped, like internal/.
# No `git ls-files`: the RPM's %check stage runs the suite against a copy of the tree with no .git
# in it at all.
not_shipped=( \( -path "$REPO_ROOT/internal" -o -path "$REPO_ROOT/.git" -o \( -type d \
                -path "$REPO_ROOT/*" -name '.*' -not -name .github \) \) -prune -o )
private_hashes=(
  59458508a0827cff5f80ed091ebd8808fbe67c97357b58ca00a278e7359dec20
  52196a62f405150a678ad281ebac39879901a5b7c60ab556fb5af366f28aefca
  191d5c3a131a7bfef8bf2e068af9b6f1caab26779e14cdcf82bb19f4fa3b426c
  baec58b415a97c4a809989b50f1255c55b96d96ad0f701b30295260b65300297
  94a168d2da574b00ec6c787377278465271cf2b97e68af076fc3eee87eba8664
  d298391b07433318a02bd922ed5b90112a4302606c4928b54e3fb1c18130d92e
  09cf980b5ff304ac11b7f6d2c5c263da2a867425798ef5cc5d2ebcf55c4fcd23
  9826156e68288510fefc3aea66addcdbff00eb41261a5c9031d6254ddbb7c3c3
  b571424bde64029d3d806909d1e41e2aa62f4d3896ad6b58f90eaf33ea563180
  a0474b137c1a1e56b7ddeac25811fc5604005a4a6a594124cd079ca96243e8b0
  056f16a772f15a45ed3837bd191a375aaf719010b2b80028d4fb2caae610bba8
)
leaked="$(find "$REPO_ROOT" "${not_shipped[@]}" -type f -print0 \
  | python3 -c '
import hashlib, re, sys
bad = set(sys.argv[2:])
def h(text):
    return hashlib.sha256(text.encode()).hexdigest() in bad
out = []
for path in sys.stdin.buffer.read().split(b"\0"):
    if not path:
        continue
    try:
        data = open(path, "rb").read()
    except OSError:
        continue
    if b"\0" in data:
        continue
    words = re.findall(r"[a-z0-9]+", data.decode("utf-8", "replace").lower())
    hit = any(h(w) for w in set(words))
    for a, b in zip(words, words[1:]):
        if hit:
            break
        keys = [b]
        m = re.match(r"([a-z]+)[0-9]", b)
        if m:
            keys.append(m.group(1) + "0")
            if len(m.group(1)) == 1:
                keys.append("?0")
        hit = any(h(a + " " + k) for k in keys)
    if hit:
        out.append(path.decode("utf-8", "replace")[len(sys.argv[1]) + 1:])
print(" ".join(sorted(out)))
' "$REPO_ROOT" "${private_hashes[@]}")" \
  || leaked="(the private-word scan could not run)"
assert_eq "$leaked" "" \
  "no public file talks about the project's own review process"

# --- and no public file cites a document the public cannot open ----------------------------------
# A comment that cites a notes file sends the reader to a file that is not here. Every .md a public
# file names must be in the tree. Paths built from a variable are skipped, and so are the files a
# documented command creates (made_by_commands).
present="$(find "$REPO_ROOT" "${not_shipped[@]}" -name '*.md' -type f -printf '%f\n' | sort -u)"
made_by_commands=("notes.md")   # docs/RELEASING.md: gh release create --notes-file notes.md
missing=""
while IFS= read -r f; do
  while IFS= read -r ref; do
    [[ "$ref" == *'$'* ]] && continue
    [[ " ${made_by_commands[*]} " == *" ${ref##*/} "* ]] && continue
    grep -qxF -- "${ref##*/}" <<<"$present" || missing+="${f#"$REPO_ROOT/"}:${ref##*/} "
  done < <(grep -oIE '[$A-Za-z0-9_./{}-]*[A-Za-z0-9_-]\.md\b' "$f" 2>/dev/null | sort -u)
done < <(find "$REPO_ROOT" "${not_shipped[@]}" -type f -print)
assert_eq "$(tr ' ' '\n' <<<"${missing% }" | sort -u | tr '\n' ' ' | sed 's/ $//')" "" \
  "every .md file a public file names is in the repository"

# --- and no email address outside the three places a format requires one -------------------------
# The RPM %changelog's format is `Name <email>`, a security policy has to say where to send a
# report, and a code of conduct has to say who to tell. Everywhere else an address is either a
# leak or a maintenance burden, and both were in this tree. The scan skips the same paths as above.
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
           "${not_shipped[@]}" -type f -print)
assert_eq "${addressed% }" "" \
  "no email address outside the spec changelog, SECURITY.md and CODE_OF_CONDUCT.md"

# kempt reclaim has no --allow-auth: every removal runs without a dialog. No doc may offer it.
assert_eq "$(grep -rlF -e '--allow-auth' -e 'allow\-auth' "$REPO_ROOT/bin" "$REPO_ROOT/docs" "$REPO_ROOT/plasmoid" \
  "$REPO_ROOT/README.md" 2>/dev/null | sed "s|$REPO_ROOT/||" | tr '\n' ' ')" "" \
  "no command line, doc or widget passes or documents reclaim --allow-auth"

finish
