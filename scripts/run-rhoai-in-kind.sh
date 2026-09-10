#!/usr/bin/env bash
# Tier 5: Deploy RHOAI / ODH operator dependencies into kind.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== Tier 5: rhoai-in-kind (MLOps integration) ==="

# Ensure kind cluster exists from Tier 3
if ! kubectl cluster-info &>/dev/null; then
  echo "No cluster detected. Run ./scripts/run-kind.sh first."
  exit 1
fi

echo "Installing OLM (required for ODH operator subscription)..."
kubectl apply -f https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.27.0/crds.yaml
kubectl apply -f https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.27.0/olm.yaml

echo "Waiting for OLM pods..."
kubectl -n olm wait --for=condition=Ready pod -l app=olm-operator --timeout=300s

echo "Applying RHOAI / ODH integration manifests..."
kubectl apply -k "$ROOT/rhoai/"

echo "Apply fidelity lab CRD and KServe bridge sample..."
kubectl apply -f "$ROOT/config/crd/bases/"

echo "Monitor ODH operator installation (5-10 min):"
kubectl get pods -n opendatahub -w
