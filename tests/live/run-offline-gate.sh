#!/usr/bin/env bash
# Runs tests/live/offline-gate.sh in a throwaway Fedora container and removes it afterwards.
# Needs podman and the network; takes several minutes. Exit status is the gate's.
# The root helpers start dnf5 only through systemd-run, so the container boots systemd as PID 1.
set -euo pipefail
BASE="${KEMPT_GATE_IMAGE:-registry.fedoraproject.org/fedora:44}"
ROOT="${KEMPT_GATE_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
name="kempt-offline-gate-$$"
img="localhost/kempt-offline-gate:$$"
podman rm -f "$name" >/dev/null 2>&1 || true
trap 'podman rm -f "$name" >/dev/null 2>&1 || true; podman rmi -f "$img" >/dev/null 2>&1 || true' EXIT
printf 'FROM %s\nRUN dnf5 -y -q install systemd jq util-linux && dnf5 clean all\nCMD ["/sbin/init"]\n' "$BASE" \
  | podman build -q -t "$img" -f - >/dev/null
podman run -d --name "$name" --systemd=always "$img" >/dev/null
podman exec "$name" systemctl is-system-running --wait >/dev/null || true   # "degraded" is fine
# Tracked files only, as they are on disk: worktrees and private notes stay out of the container.
git -C "$ROOT" ls-files -z | tar -C "$ROOT" --null --ignore-failed-read -T - -cf - | podman exec -i "$name" bash -c 'mkdir -p /opt/kempt && tar -xf - -C /opt/kempt'
# The gate refuses to run outside a throwaway container; this is the runner saying it built one.
podman exec -e KEMPT_GATE_CONTAINER=1 "$name" bash /opt/kempt/tests/live/offline-gate.sh
