#!/usr/bin/env bash
# Tier 4: Start Tilt with Podman configured for image builds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/container.sh
source "$ROOT/scripts/container.sh"

if command -v podman &>/dev/null && podman machine list &>/dev/null 2>&1; then
  podman machine start 2>/dev/null || true
fi

setup_podman_env

# Podman's docker-compatible API does not support BuildKit's gRPC session endpoint.
# Without this, Tilt fails with: "failed to dial gRPC: unable to upgrade to h2c, received 404"
export DOCKER_BUILDKIT=0
export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"

if ! command -v tilt &>/dev/null; then
  echo "tilt not found. Install: https://docs.tilt.dev/install.html"
  exit 1
fi

echo "Using DOCKER_HOST=${DOCKER_HOST:-default} with DOCKER_BUILDKIT=0 (required for Podman)"

cd "$ROOT"
tilt up "$@"
