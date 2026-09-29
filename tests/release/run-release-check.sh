#!/usr/bin/env bash
# Runs tests/release/release-check.sh in a throwaway Fedora container and removes it afterwards.
# Needs podman and the network; takes several minutes. Exit status is the check's.
#
# Run this before tagging a release. It builds the packages from the tree you are standing in and
# proves them the way a person meets them: installed on a machine that has never seen Kempt.
set -euo pipefail
IMG="${KEMPT_RELEASE_IMAGE:-registry.fedoraproject.org/fedora:44}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
name="kempt-release-check-$$"
podman rm -f "$name" >/dev/null 2>&1 || true
podman run -d --name "$name" "$IMG" sleep 3000 >/dev/null
trap 'podman rm -f "$name" >/dev/null 2>&1 || true' EXIT
# What the release tarball holds: Source0 is `git archive` of the tag, so build from git archive
# too. `git stash create` adds uncommitted edits to tracked files without touching the stash list;
# a clean tree gives nothing and HEAD is used. Untracked files are left out, as the tag leaves them.
untracked="$(git -C "$ROOT" ls-files -o --exclude-standard)"
if [[ -n "$untracked" ]]; then
  echo "warning: these untracked files are not in the build, and would not be in the release tarball:" >&2
  while IFS= read -r f; do printf '  %s\n' "$f"; done <<<"$untracked" >&2
fi
rev="$(git -C "$ROOT" stash create 2>/dev/null || true)"
git -C "$ROOT" archive --format=tar "${rev:-HEAD}" \
  | podman exec -i "$name" bash -c 'mkdir -p /src && tar -xf - -C /src && rm -rf /src/internal'
podman exec "$name" bash -c 'dnf5 -y -q install jq util-linux >/dev/null 2>&1'
# The check refuses to run outside a throwaway container; this is the runner saying it built one.
podman exec -e KEMPT_RELEASE_CONTAINER=1 "$name" bash /src/tests/release/release-check.sh
