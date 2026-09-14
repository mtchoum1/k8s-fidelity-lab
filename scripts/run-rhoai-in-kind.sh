#!/usr/bin/env bash
# Tier 5: Deploy RHOAI / ODH operator dependencies into kind.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lab-metrics.sh
source "$ROOT/scripts/lab-metrics.sh"
# shellcheck source=scripts/cluster.sh
source "$ROOT/scripts/cluster.sh"
# shellcheck source=scripts/lab-tier-check.sh
source "$ROOT/scripts/lab-tier-check.sh"

CLUSTER_NAME="${KIND_CLUSTER_NAME:-fidelity-kind}"
register_lab_kind_cleanup "$CLUSTER_NAME"

echo "=== Tier 5: rhoai-in-kind (MLOps integration) ==="

ensure_kubectl_cluster "$CLUSTER_NAME" "$ROOT/config/kind-config.yaml"

echo "Installing OLM (required for ODH operator subscription)..."
kubectl apply --server-side --force-conflicts -f \
  https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.27.0/crds.yaml
kubectl apply --server-side --force-conflicts -f \
  https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.27.0/olm.yaml

echo "Waiting for OLM pods..."
kubectl -n olm wait --for=condition=Ready pod -l app=olm-operator --timeout=300s

lab_metrics_handoff "applying rhoai kustomize overlay"

echo "Installing ModelInferencePipeline CRD (required by kserve-integration)..."
kubectl apply -f "$ROOT/config/crd/bases/fidelity.ai_modelinferencepipelines.yaml"
kubectl wait --for=condition=Established crd/modelinferencepipelines.fidelity.ai --timeout=120s

echo ""
echo "Applying ODH subscription, KServe CRD, and InferenceService..."
echo "  kubectl apply -k rhoai/"
set +e
kubectl apply -k "$ROOT/rhoai" 2>&1 || true
set -e

echo "Waiting for KServe CRD to become established..."
kubectl wait --for=condition=Established crd/inferenceservices.serving.kserve.io --timeout=120s

set +e
APPLY_OUTPUT="$(kubectl apply -k "$ROOT/rhoai" 2>&1)"
APPLY_RC=$?
set -e
echo "$APPLY_OUTPUT"

if lab_tier5_baseline_bug_present; then
  if [[ "$APPLY_RC" -ne 0 ]]; then
    lab_tier_expect_baseline_failure "InferenceService apiVersion serving.kserve.io/v1beta1 not served"
  fi
  lab_tier_fail "InferenceService applied on baseline — apiVersion should still be v1beta1"
fi

if [[ "$APPLY_RC" -ne 0 ]]; then
  lab_tier_fail "InferenceService apply failed after fix — check apiVersion is serving.kserve.io/v1"
fi

lab_tier_pass "InferenceService applied with serving.kserve.io/v1"
