#!/usr/bin/env bash
# Tier 4: Start Tilt with Podman configured for image builds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/container.sh
source "$ROOT/scripts/container.sh"

setup_podman_env

if ! command -v tilt &>/dev/null; then
  echo "tilt not found. Install: https://docs.tilt.dev/install.html"
  exit 1
fi

cd "$ROOT"
tilt up "$@"
