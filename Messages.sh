#!/bin/sh
# The widget's translations. Run from anywhere.
#   Messages.sh                  writes the template, po/<domain>.pot, from every i18n() call
#   Messages.sh install <dir>    compiles po/<lang>.po into <dir>/contents/locale, for a package
# A translation is one file, po/<lang>.po, made from the template with msginit.
set -eu
root="$(cd "$(dirname "$0")" && pwd)"
domain=plasma_applet_io.github.erez_c137.kempt

if [ "${1:-}" = install ]; then
    for po in "$root"/po/*.po; do
        [ -e "$po" ] || continue
        lang="$(basename "$po" .po)"
        mkdir -p "$2/contents/locale/$lang/LC_MESSAGES"
        msgfmt -o "$2/contents/locale/$lang/LC_MESSAGES/$domain.mo" "$po"
    done
    exit 0
fi

cd "$root"
mkdir -p po
find plasmoid/contents -name '*.qml' -o -name '*.js' | LC_ALL=C sort | xargs xgettext \
    --from-code=UTF-8 --language=JavaScript --add-location=file --sort-by-file \
    --package-name=kempt --no-wrap \
    --keyword --keyword=i18n:1 --keyword=i18nc:1c,2 --keyword=i18np:1,2 --keyword=i18ncp:1c,2,3 \
    --output="po/$domain.pot"
