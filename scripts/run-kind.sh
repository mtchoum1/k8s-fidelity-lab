#!/usr/bin/env bash
# Tier 3: kind cluster with real container runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-fidelity-kind}"
OPERATOR_IMG="ghcr.io/k8s-fidelity-lab/operator:latest"
INFERENCE_IMG="ghcr.io/k8s-fidelity-lab/inference-server:latest"
SIDECAR_IMG="ghcr.io/k8s-fidelity-lab/metrics-sidecar:latest"

# shellcheck source=scripts/container.sh
source "$ROOT/scripts/container.sh"
setup_podman_env

echo "=== Tier 3: kind (real Kubelets + Podman container runtime) ==="

if ! command -v kind &>/dev/null; then
  echo "kind not found. Install: https://kind.sigs.k8s.io/docs/user/quick-start/"
  exit 1
fi

kind create cluster --name "$CLUSTER_NAME" --config "$ROOT/config/kind-config.yaml" --wait 5m
kubectl cluster-info --context "kind-${CLUSTER_NAME}"

echo "Building and loading images with Podman..."
container_build -t "$OPERATOR_IMG" "$ROOT"
kind_load_image "$OPERATOR_IMG" "$CLUSTER_NAME"

container_build -t "$INFERENCE_IMG" -f "$ROOT/Dockerfile.inference" "$ROOT"
kind_load_image "$INFERENCE_IMG" "$CLUSTER_NAME"

container_build -t "$SIDECAR_IMG" -f "$ROOT/Dockerfile.sidecar" "$ROOT"
kind_load_image "$SIDECAR_IMG" "$CLUSTER_NAME"

kubectl apply -f "$ROOT/config/crd/bases/"
kubectl apply -f "$ROOT/config/operator/"

echo "Applying PR #104 sample with broken sidecar env (expect CrashLoopBackOff)..."
kubectl apply -f "$ROOT/config/samples/modelpipeline_v1alpha1_kind-broken.yaml"

echo "Check pod status:"
kubectl get pods -w
