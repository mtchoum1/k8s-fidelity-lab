#!/usr/bin/env bash
# Tier 3: kind cluster with real container runtime.
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
OPERATOR_IMG="ghcr.io/k8s-fidelity-lab/operator:latest"
INFERENCE_IMG="ghcr.io/k8s-fidelity-lab/inference-server:latest"
SIDECAR_IMG="ghcr.io/k8s-fidelity-lab/metrics-sidecar:latest"
PIPELINE_LABEL="fidelity.ai/pipeline=pr104-sidecar-broken"

echo "=== Tier 3: kind (real Kubelets + Podman container runtime) ==="

ensure_kind_cluster "$CLUSTER_NAME" "$ROOT/config/kind-config.yaml"

# shellcheck source=scripts/container.sh
source "$ROOT/scripts/container.sh"
setup_podman_env

echo "Building and loading images with Podman..."
container_build -t "$OPERATOR_IMG" "$ROOT"
kind_load_image "$OPERATOR_IMG" "$CLUSTER_NAME"

container_build -t "$INFERENCE_IMG" -f "$ROOT/Dockerfile.inference" "$ROOT"
kind_load_image "$INFERENCE_IMG" "$CLUSTER_NAME"

container_build -t "$SIDECAR_IMG" -f "$ROOT/Dockerfile.sidecar" "$ROOT"
kind_load_image "$SIDECAR_IMG" "$CLUSTER_NAME"

kubectl apply -f "$ROOT/config/crd/bases/"
kubectl apply -f "$ROOT/config/operator/"

echo "Waiting for operator to be ready..."
kubectl -n fidelity-lab-system rollout status deployment/fidelity-lab-operator --timeout=120s

echo "Applying PR #104 sample with broken sidecar env (expect CrashLoopBackOff on baseline)..."
kubectl apply -f "$ROOT/config/samples/modelpipeline_v1alpha1_kind-broken.yaml"

lab_metrics_handoff "waiting for inference pod and sidecar state"

echo "Waiting for inference pod (up to 120s)..."
for _ in $(seq 1 60); do
  if kubectl get pods -n default -l "$PIPELINE_LABEL" --no-headers 2>/dev/null | grep -q .; then
    break
  fi
  sleep 2
done

if ! kubectl get pods -n default -l "$PIPELINE_LABEL" --no-headers 2>/dev/null | grep -q .; then
  echo "No inference pod yet. Operator logs:"
  kubectl -n fidelity-lab-system logs -l app=fidelity-lab-operator --tail=30
  lab_tier_fail "inference pod was not created"
fi

echo "Waiting for sidecar container state (up to 120s)..."
SIDECAR_REASON=""
for _ in $(seq 1 60); do
  SIDECAR_REASON="$(kubectl get pods -n default -l "$PIPELINE_LABEL" -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="metrics-sidecar")].state.waiting.reason}' 2>/dev/null || true)"
  SIDECAR_READY="$(kubectl get pods -n default -l "$PIPELINE_LABEL" -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="metrics-sidecar")].ready}' 2>/dev/null || true)"
  if [[ -n "$SIDECAR_REASON" ]] || [[ "$SIDECAR_READY" == "true" ]]; then
    break
  fi
  sleep 2
done

POD_STATUS="$(kubectl get pods -n default -l "$PIPELINE_LABEL" --no-headers 2>/dev/null | awk '{print $3}' | head -1)"
echo "Pod status: ${POD_STATUS:-unknown} | sidecar waiting reason: ${SIDECAR_REASON:-none}"

if [[ "$SIDECAR_REASON" == "ErrImagePull" || "$SIDECAR_REASON" == "ImagePullBackOff" ]]; then
  echo "Image pull events:"
  kubectl describe pods -n default -l "$PIPELINE_LABEL" 2>/dev/null | sed -n '/Events:/,$p' | tail -15
  lab_tier_fail "sidecar image pull failed — re-run ./lab run 3 (kind-loaded images need imagePullPolicy: IfNotPresent on controller containers)"
fi

if ! lab_tier3_fix_applied; then
  if [[ "$SIDECAR_REASON" == "CrashLoopBackOff" ]] || [[ "$POD_STATUS" == *"CrashLoopBackOff"* ]]; then
    lab_tier_expect_baseline_failure "metrics-sidecar CrashLoopBackOff (SIDECAR_LOG_DIR missing from pod template)"
  fi
  lab_tier_fail "Tier 3 sidecar bug not observed (pod=${POD_STATUS}, sidecar reason=${SIDECAR_REASON:-none})"
fi

if [[ "$SIDECAR_READY" != "true" ]]; then
  echo "Sidecar logs:"
  kubectl logs -n default -l "$PIPELINE_LABEL" -c metrics-sidecar --tail=20 2>/dev/null || true
  lab_tier_fail "metrics-sidecar is not ready — add SIDECAR_LOG_DIR and mount /var/log/sidecar"
fi

lab_tier_pass "inference pod 2/2 Running with healthy metrics-sidecar"
