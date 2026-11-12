#!/usr/bin/env bash
# Translation plumbing: the template matches the source, a .po compiles to the path Plasma reads,
# and the widget's words stay whole sentences in i18n() calls where they are used.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox

UI="$REPO_ROOT/plasmoid/contents/ui"
DOMAIN=plasma_applet_io.github.erez_c137.kempt
POT="po/$DOMAIN.pot"
WORK="$TESTTMP/work"
mkdir -p "$WORK"

assert_eq "$(jq -r .KPlugin.Id "$REPO_ROOT/plasmoid/metadata.json")" "${DOMAIN#plasma_applet_}" \
  "the domain is the widget's id, which is how Plasma finds its catalog"

if command -v xgettext >/dev/null 2>&1 && command -v msgfmt >/dev/null 2>&1; then
  mkdir -p "$WORK/repo/plasmoid"
  cp -a "$REPO_ROOT/Messages.sh" "$WORK/repo/"
  cp -a "$REPO_ROOT/plasmoid/contents" "$WORK/repo/plasmoid/"
  sh "$WORK/repo/Messages.sh" 2>/dev/null
  assert_eq "$(diff <(grep -v POT-Creation-Date "$REPO_ROOT/$POT") <(grep -v POT-Creation-Date "$WORK/repo/$POT") | wc -l)" "0" \
    "po/$DOMAIN.pot is current: run ./Messages.sh"
  assert_eq "$(grep -cF 'msgid "%1 failed to start after the update."' "$WORK/repo/$POT")" "1" "...a sentence from logic.js is in it"
  assert_eq "$(grep -cF 'msgid "Mute Until It Starts"' "$WORK/repo/$POT")" "1" "...and one from the QML"
  assert_eq "$(grep -c 'msgid_plural "%1 updates"' "$WORK/repo/$POT")" "1" "...with its plural"
  # A fragment that goes into another sentence carries a note saying so.
  for _fragment in "the Linux kernel" "just now" "%1 and %2" "update info %1 days old"; do
    assert_eq "$(grep -B6 -E "^msgid(_plural)? \"$_fragment\"$" "$WORK/repo/$POT" | grep -c '^#\. TRANSLATORS:')" "1" \
      "the template tells a translator where this goes: $_fragment"
  done
  assert_eq "$(grep -c 'msgid "sudo dnf copr enable erez-c137/kempt &&' "$WORK/repo/$POT")" "0" "...and a command to copy is not in it"

  mkdir -p "$WORK/out"
  sh "$WORK/repo/Messages.sh" install "$WORK/out"
  assert_eq "$(find "$WORK/out" -type f | wc -l)" "0" "with no translations, a package gets no catalogs"
  cat > "$WORK/repo/po/xx.po" <<'PO'
msgid ""
msgstr "Content-Type: text/plain; charset=UTF-8\n"

msgid "Update Now"
msgstr "Now Update"
PO
  sh "$WORK/repo/Messages.sh" install "$WORK/out"
  MO="$WORK/out/contents/locale/xx/LC_MESSAGES/$DOMAIN.mo"
  assert_eq "$(msgunfmt "$MO" 2>/dev/null | grep -c 'Now Update')" "1" "po/xx.po compiles to contents/locale/xx/LC_MESSAGES/<domain>.mo"
else
  skip "gettext tools absent, so the template was not compared"
fi

# The rest needs no gettext.
# Words on screen in the settings page go through i18n too. A string that reaches a label or a message
# there is an assignment or a fallback, written bare.
assert_eq "$(grep -nE '(\|\||\?|:|loadError =|Result =) *\(?"[^"]*[A-Z][a-z]+[^"]* ?[^"]*"' "$UI/configGeneral.qml" | grep -vE 'i18n|Logic\.|^[0-9]+: *//|key:|icon\.' || true)" "" \
  "no bare sentence in the settings page"
assert_eq "$(grep -c '\bCOPY\b' "$UI"/*.js "$UI"/*.qml | grep -vc ':0$')" "0" "no copy table, and no file reads one"
# A call at load time runs once and never again, and prints a warning for an unfilled %1.
assert_eq "$(grep -cE '^var .*i18n' "$UI/logic.js")" "0" "logic.js calls i18n in no table at load time"
# `i18n("x") + " y"` and `"x " + i18n("y")` are fragments. Between whole sentences only a space or
# a newline may join them.
FRAGMENTS="$(sed -E 's/" *\\n *" \+//; s/\+ "\\n"//g; s/\+ " "//g' "$UI"/*.js "$UI"/*.qml | grep -nE 'i18n[pc]*\("[^"]*"[^)]*\) \+ "|" \+ i18n' || true)"
assert_eq "$FRAGMENTS" "" "no sentence is glued to words outside its i18n call"
assert_eq "$(grep -E '"[^"]*" \+ [a-zA-Z.]+ \+ "[^"]* [^"]*"' "$UI/logic.js" | grep -cv '" startup "')" "0" \
  "logic.js builds no sentence around a value"

finish
