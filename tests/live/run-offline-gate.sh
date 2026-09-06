#!/usr/bin/env bash
# Runs tests/live/offline-gate.sh in a throwaway Fedora container and removes it afterwards.
# Needs podman and the network; takes several minutes. Exit status is the gate's.
set -euo pipefail
IMG="${KEMPT_GATE_IMAGE:-registry.fedoraproject.org/fedora:44}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
name="kempt-offline-gate-$$"
podman rm -f "$name" >/dev/null 2>&1 || true
podman run -d --name "$name" "$IMG" sleep 2400 >/dev/null
trap 'podman rm -f "$name" >/dev/null 2>&1 || true' EXIT
tar -C "$ROOT" --exclude=.git -cf - . | podman exec -i "$name" bash -c 'mkdir -p /opt/kempt && tar -xf - -C /opt/kempt'
podman exec "$name" bash -c 'dnf5 -y -q install jq util-linux >/dev/null 2>&1'
# The gate refuses to run outside a throwaway container; this is the runner saying it built one.
podman exec -e KEMPT_GATE_CONTAINER=1 "$name" bash /opt/kempt/tests/live/offline-gate.sh
