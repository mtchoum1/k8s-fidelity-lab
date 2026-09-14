#!/usr/bin/env bash
# Tier 5: Deploy RHOAI / ODH operator dependencies into kind.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lab-metrics.sh
source "$ROOT/scripts/lab-metrics.sh"
# shellcheck source=scripts/cluster.sh
source "$ROOT/scripts/cluster.sh"

CLUSTER_NAME="${KIND_CLUSTER_NAME:-fidelity-kind}"
register_lab_kind_cleanup "$CLUSTER_NAME"

echo "=== Tier 5: rhoai-in-kind (MLOps integration) ==="

ensure_kubectl_cluster "$CLUSTER_NAME" "$ROOT/config/kind-config.yaml"

echo "Installing OLM (required for ODH operator subscription)..."
# Server-side apply avoids the clusterserviceversions CRD last-applied-configuration
# annotation exceeding the 256KiB limit (common with kubectl apply on OLM crds.yaml).
kubectl apply --server-side --force-conflicts -f \
  https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.27.0/crds.yaml
kubectl apply --server-side --force-conflicts -f \
  https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.27.0/olm.yaml

echo "Waiting for OLM pods..."
kubectl -n olm wait --for=condition=Ready pod -l app=olm-operator --timeout=300s

echo "Applying ODH namespace, subscription, and lab KServe CRD (v1 only)..."
kubectl apply -f "$ROOT/rhoai/odh-subscription.yaml"
kubectl apply -f "$ROOT/rhoai/kserve-integration.yaml"
kubectl apply -f "$ROOT/rhoai/kserve-crds-lab.yaml"
kubectl wait --for=condition=Established crd/inferenceservices.serving.kserve.io --timeout=120s

echo ""
echo "Applying InferenceService (baseline expects v1beta1 apiVersion failure)..."
if kubectl apply -f "$ROOT/rhoai/inferenceservice-v1beta1.yaml"; then
  echo "InferenceService applied — if you already fixed apiVersion to v1, this is expected."
else
  echo ""
  echo "Expected on baseline: no matches for kind InferenceService in version serving.kserve.io/v1beta1"
  echo "Fix: change apiVersion to serving.kserve.io/v1 in rhoai/inferenceservice-v1beta1.yaml"
fi

lab_metrics_handoff "OLM/KServe installed; ODH continues in background"

echo ""
echo "ODH operator subscription is installing in the background (may take 5-10 min on kind)."
echo "Watching opendatahub pods (Ctrl+C to stop and delete cluster):"
kubectl get pods -n opendatahub -w
