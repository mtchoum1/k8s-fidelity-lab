#!/usr/bin/env bash
# Tier 6: Kustomize check, ArgoCD install, git push, sync, and health validation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lab-metrics.sh
source "$ROOT/scripts/lab-metrics.sh"
# shellcheck source=scripts/cluster.sh
source "$ROOT/scripts/cluster.sh"
# shellcheck source=scripts/lab-tier-check.sh
source "$ROOT/scripts/lab-tier-check.sh"
# shellcheck source=scripts/argocd-lib.sh
source "$ROOT/scripts/argocd-lib.sh"

CLUSTER_NAME="${KIND_CLUSTER_NAME:-fidelity-kind}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
LAB_ROOT="$ROOT"
ARGOCD_PF_PID=""

lab_tier6_cleanup() {
  lab_argocd_stop_port_forward
  _lab_cluster_cleanup_kind
}

register_lab_kind_cleanup() {
  LAB_CLUSTER_NAME="${1:-fidelity-kind}"
  trap 'lab_tier6_cleanup' EXIT INT TERM
}

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

if lab_tier6_baseline_bug_present; then
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
# Server-side apply avoids last-applied-configuration exceeding 256KiB on large CRDs
# (e.g. applicationsets.argoproj.io) — same pattern as OLM in run-rhoai-in-kind.sh.
kubectl apply --server-side --force-conflicts -n "$ARGOCD_NAMESPACE" -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  echo "Waiting for ArgoCD core components..."
  kubectl -n "$ARGOCD_NAMESPACE" wait --for=condition=Available deployment/argocd-server --timeout=300s
  kubectl -n "$ARGOCD_NAMESPACE" wait --for=condition=Available deployment/argocd-repo-server --timeout=300s

lab_metrics_handoff "git push, ArgoCD connect, sync, and health check"

echo ""
echo "Installing ModelInferencePipeline CRD (required before Application sync)..."
kubectl apply -f "$ROOT/config/crd/bases/"
kubectl wait --for=condition=Established crd/modelinferencepipelines.fidelity.ai --timeout=120s

lab_argocd_ensure_tier6_fix_pushed

echo ""
echo "Connecting ArgoCD Application to GitHub..."
ARGOCD_NAMESPACE="$ARGOCD_NAMESPACE" "$ROOT/scripts/argocd-connect-github.sh"

lab_argocd_require_cli
lab_argocd_configure_local_ui
lab_argocd_cli_login
lab_argocd_open_ui

lab_argocd_sync_and_wait
lab_argocd_verify_cluster_resources

lab_tier_pass "ArgoCD synced ${ARGOCD_APP_NAME}; ModelInferencePipeline healthy in ${ARGOCD_DEST_NAMESPACE}"
