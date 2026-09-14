#!/usr/bin/env bash
# Tier 6: Kustomize baseline check + ArgoCD install on kind.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lab-metrics.sh
source "$ROOT/scripts/lab-metrics.sh"
# shellcheck source=scripts/cluster.sh
source "$ROOT/scripts/cluster.sh"

CLUSTER_NAME="${KIND_CLUSTER_NAME:-fidelity-kind}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

echo "=== Tier 6: GitOps / Kustomize + ArgoCD ==="

ensure_kind_cluster "$CLUSTER_NAME" "$ROOT/config/kind-config.yaml"

echo ""
echo "Expect kustomize build to FAIL on the broken baseline:"
if kubectl kustomize "$ROOT/config/overlays/pr104"; then
  echo "ERROR: overlay built successfully — Tier 6 bug may already be fixed."
  exit 1
fi

echo ""
echo "Installing ArgoCD in namespace ${ARGOCD_NAMESPACE}..."
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$ARGOCD_NAMESPACE" -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD server..."
kubectl -n "$ARGOCD_NAMESPACE" wait --for=condition=Available deployment/argocd-server --timeout=300s

lab_metrics_handoff "ArgoCD installed; connect repo and verify sync failure"

echo ""
echo "Next steps:"
echo "  ./scripts/argocd-connect-github.sh   # auto-detects origin + current branch"
echo "  ./scripts/argocd-login.sh"
echo "  ./scripts/argocd-ui-access.sh"
