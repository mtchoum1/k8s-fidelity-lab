#!/usr/bin/env bash
# Tier 4: Start Tilt with Podman configured for image builds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lab-metrics.sh
source "$ROOT/scripts/lab-metrics.sh"
# shellcheck source=scripts/cluster.sh
source "$ROOT/scripts/cluster.sh"
# shellcheck source=scripts/container.sh
source "$ROOT/scripts/container.sh"

CLUSTER_NAME="${KIND_CLUSTER_NAME:-fidelity-kind}"
register_lab_kind_cleanup "$CLUSTER_NAME"

ensure_podman_machine
setup_podman_env
ensure_kind_cluster "$CLUSTER_NAME" "$ROOT/config/kind-config.yaml"

# Podman's docker-compatible API does not support BuildKit's gRPC session endpoint.
# Without this, Tilt fails with: "failed to dial gRPC: unable to upgrade to h2c, received 404"
export DOCKER_BUILDKIT=0
export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"

if ! command -v tilt &>/dev/null; then
  echo "tilt not found. Install: https://docs.tilt.dev/install.html"
  exit 1
fi

echo "Using DOCKER_HOST=${DOCKER_HOST:-default} with DOCKER_BUILDKIT=0 (required for Podman)"

lab_metrics_handoff "Tilt UI — record hot-reload iteration time manually in scorecard"

cd "$ROOT"
tilt up "$@"
