#!/usr/bin/env bash
# Tier 6: Kustomize baseline check + ArgoCD install on kind.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lab-metrics.sh
source "$ROOT/scripts/lab-metrics.sh"
# shellcheck source=scripts/cluster.sh
source "$ROOT/scripts/cluster.sh"
# shellcheck source=scripts/lab-tier-check.sh
source "$ROOT/scripts/lab-tier-check.sh"

CLUSTER_NAME="${KIND_CLUSTER_NAME:-fidelity-kind}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
register_lab_kind_cleanup "$CLUSTER_NAME"

echo "=== Tier 6: GitOps / Kustomize + ArgoCD ==="

ensure_kind_cluster "$CLUSTER_NAME" "$ROOT/config/kind-config.yaml"

lab_metrics_handoff "kustomize build check"

echo ""
echo "Checking kustomize overlay..."
set +e
KUSTOMIZE_OUTPUT="$(kubectl kustomize "$ROOT/config/overlays/pr104" 2>&1)"
KUSTOMIZE_RC=$?
set -e

if lab_baseline_bug_present 'sidecarLoging' 'config/overlays/pr104/sidecar-patch.yaml'; then
  if [[ "$KUSTOMIZE_RC" -eq 0 ]]; then
    lab_tier_fail "kustomize build succeeded on baseline — patch typo may already be fixed"
  fi
  echo "$KUSTOMIZE_OUTPUT"
  lab_tier_expect_baseline_failure "kustomize build fails on malformed sidecarLogging patch path"
fi

if [[ "$KUSTOMIZE_RC" -ne 0 ]]; then
  echo "$KUSTOMIZE_OUTPUT"
  lab_tier_fail "kustomize build still fails after fix — correct sidecarLoging → sidecarLogging in sidecar-patch.yaml"
fi

echo "kustomize build succeeded."

echo ""
echo "Installing ArgoCD in namespace ${ARGOCD_NAMESPACE}..."
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$ARGOCD_NAMESPACE" -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD server..."
kubectl -n "$ARGOCD_NAMESPACE" wait --for=condition=Available deployment/argocd-server --timeout=300s

echo ""
echo "Next: ./scripts/argocd-connect-github.sh  (then verify sync in UI/CLI)"
lab_tier_pass "kustomize overlay builds and ArgoCD is installed"
