#!/usr/bin/env bash
# Build RPMs from this checkout, named as a preview of the NEXT release, and install them.
#
#   tools/build-local.sh              test, build, install, reload the widget
#   tools/build-local.sh --no-test    skip the suite (it still runs nowhere else - use sparingly)
#   tools/build-local.sh --no-install build only; the RPMs land in ~/rpmbuild/RPMS/noarch
#   tools/build-local.sh --print-name print the name this checkout would build, and stop
#
# THE NAME. After v0.1.4 is tagged, the fourth commit on top of it builds as
#
#   kempt-0.1.5~dev.4-0.git1a2b3c4.20260922T193500.1.fc44     (rpm -q)
#   kempt 0.1.5~dev.4+git1a2b3c4                               (kempt --version, the widget)
#
# - 0.1.5 is the release this build is a preview of: the patch after the newest tag, or VERSION
#   itself once a release bump has moved it past the tag.
# - dev.N counts the commits since that tag, so it only goes up, and any checkout can say which
#   commit a number was built from. `.dirty` is appended when the tree had uncommitted changes.
# - The tilde is RPM's pre-release marker: 0.1.5~dev.4 sorts BELOW 0.1.5, so the real release
#   upgrades over every hand build by itself. A fourth number (0.1.5.1) or a suffix would sort
#   ABOVE it and pin the hand build in place with dnf reporting nothing to do.
# - The Release carries the commit and the build time through kempt.spec's kempt_local stamp, so
#   two builds of the same commit are still two different packages.
#
# The checkout's own files are never edited. The rename happens in a copy of the tree - VERSION,
# the widget's KPlugin.Version and the spec's Version: - so the release files keep saying the
# release. That copy fails tests/test_version.sh by design (a dev name is not a plain version and
# the metainfo names no such release), so the package is built with --nocheck, and the suite runs
# here instead, against the real tree, before anything is built.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_tests=1 install=1 print_only=0
for a in "$@"; do
  case "$a" in
    --no-test) run_tests=0 ;;
    --no-install) install=0 ;;
    --print-name) print_only=1 ;;
    -h|--help) sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

git_() { git -C "$REPO" "$@"; }

version="$(head -1 "$REPO/VERSION" | tr -d '[:space:]')"
[[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] \
  || { echo "VERSION is not a plain x.y.z: '$version'" >&2; exit 1; }
tag="$(git_ describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)"
if [[ -z "$tag" ]]; then
  # Nothing released yet: every commit is a preview of VERSION.
  next="$version"; count="$(git_ rev-list --count HEAD)"
else
  released="${tag#v}"
  count="$(git_ rev-list --count "$tag..HEAD")"
  if [[ "$version" != "$released" ]] \
     && [[ "$(printf '%s\n%s\n' "$released" "$version" | sort -V | tail -1)" == "$version" ]]; then
    next="$version"                      # a release bump already names the next version
  else
    IFS=. read -r ma mi pa <<< "$released"
    next="$ma.$mi.$((pa + 1))"
  fi
fi
sha="$(git_ rev-parse --short=7 HEAD)"
dirty=""
# Untracked files count: the build copies them, so a build that includes one is not the commit.
[[ -n "$(git_ status --porcelain)" ]] && dirty=".dirty"

rpm_version="$next~dev.$count"
display="$rpm_version+git$sha$dirty"
stamp="git$sha$dirty.$(date +%Y%m%dT%H%M%S)"

if (( print_only )); then
  printf '%s\n' "$display"
  exit 0
fi

if (( run_tests )); then
  echo "== test suite"
  "$REPO/tests/run_tests.sh" > "${TMPDIR:-/tmp}/kempt-build-local-tests.log" 2>&1 \
    || { echo "the suite failed - see ${TMPDIR:-/tmp}/kempt-build-local-tests.log" >&2; exit 1; }
  tail -1 "${TMPDIR:-/tmp}/kempt-build-local-tests.log"
fi

echo "== building kempt $display"
work="$(mktemp -d "${TMPDIR:-/tmp}/kempt-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT
top="$work/kempt-$rpm_version"
mkdir -p "$top"
# The working tree as it is, uncommitted edits included (that is what .dirty says), but only
# files git knows or would add - never build output or ignored scratch.
# A tracked file deleted in the working tree is still listed, so only what exists is copied.
( cd "$REPO"
  git ls-files -z --cached --others --exclude-standard \
    | while IFS= read -r -d '' f; do if [[ -e "$f" || -L "$f" ]]; then printf '%s\0' "$f"; fi; done \
    | xargs -0 cp -a --parents -t "$top" )
printf '%s\n' "$display" > "$top/VERSION"
jq --arg v "$display" '.KPlugin.Version = $v' "$REPO/plasmoid/metadata.json" > "$top/plasmoid/metadata.json"
sed -i "s|^Version:.*|Version:        $rpm_version|" "$top/kempt.spec"

mkdir -p "$work/SOURCES"
tar -C "$work" -czf "$work/SOURCES/kempt-$rpm_version.tar.gz" "kempt-$rpm_version"
# Timestamps: rpm clamps installed mtimes to the spec's newest %changelog date, which does not move
# between hand builds, and Plasma's QML cache validates against that mtime - so without these two
# the panel keeps drawing the previous build's widget.
rpmbuild --define "_topdir $work" --define "kempt_local $stamp" \
         --define "source_date_epoch_from_changelog 0" \
         --define "clamp_mtime_to_source_date_epoch 0" \
         --nocheck -bb "$top/kempt.spec" > "$work/rpmbuild.log" 2>&1 \
  || { tail -30 "$work/rpmbuild.log" >&2; echo "rpmbuild failed" >&2; exit 1; }
out="$HOME/rpmbuild/RPMS/noarch"
mkdir -p "$out"
cp "$work"/RPMS/noarch/*.rpm "$out/"
rpms=("$work"/RPMS/noarch/*.rpm); rpms=("${rpms[@]##*/}")
printf '   %s\n' "${rpms[@]}"

(( install )) || { echo "built into $out"; exit 0; }

echo "== installing"
sudo dnf install -y "${rpms[@]/#/$out/}"
# Installed over a same-version build, Plasma serves its compiled copy of the old widget from this
# cache. Clearing it costs one recompile.
rm -rf "$HOME/.cache/plasmashell/qmlcache"
if systemctl --user is-active --quiet plasma-plasmashell 2>/dev/null; then
  systemctl --user restart plasma-plasmashell
fi
kempt --version
