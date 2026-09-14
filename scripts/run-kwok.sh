#!/usr/bin/env bash
# Tier 2: KWOK scale testing — 100 pipelines × 5 replicas = 500 pods (PR #104).
#
# KWOK fake nodes do not run real containers. The operator must run locally against
# the KWOK API (your local controller code), not as an in-cluster Deployment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lab-metrics.sh
source "$ROOT/scripts/lab-metrics.sh"
# shellcheck source=scripts/cluster.sh
source "$ROOT/scripts/cluster.sh"
CLUSTER_NAME="${KWOK_CLUSTER_NAME:-fidelity-kwok}"
PIPELINE_COUNT="${PIPELINE_COUNT:-100}"
MANAGER_PID=""

cleanup() {
  if [[ -n "$MANAGER_PID" ]] && kill -0 "$MANAGER_PID" 2>/dev/null; then
    kill "$MANAGER_PID" 2>/dev/null || true
    wait "$MANAGER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "=== Tier 2: KWOK scale test (${PIPELINE_COUNT} pipelines × 5 replicas = $((PIPELINE_COUNT * 5)) pods) ==="

ensure_kwok_cluster "$CLUSTER_NAME"

"$ROOT/kwok/generate-nodes.sh" "$ROOT/kwok/fake-nodes.yaml" 100
kubectl apply -f "$ROOT/kwok/fake-nodes.yaml"
kubectl apply -f "$ROOT/config/crd/bases/"

if kubectl get deployment fidelity-lab-operator -n fidelity-lab-system &>/dev/null; then
  echo "Removing in-cluster operator (KWOK nodes cannot run real containers)..."
  kubectl delete -f "$ROOT/config/operator/" --ignore-not-found
fi

echo "Building operator from local source (uses your Tier 2 fixes)..."
cd "$ROOT"
go build -o bin/manager main.go

MANAGER_LOG="$(mktemp "${TMPDIR:-/tmp}/fidelity-lab-manager-XXXXXX")"
MANAGER_LOG="${MANAGER_LOG}.log"
echo "Starting local operator (logs: ${MANAGER_LOG})..."
./bin/manager >"$MANAGER_LOG" 2>&1 &
MANAGER_PID=$!

for _ in $(seq 1 30); do
  if curl -sf http://127.0.0.1:8081/healthz &>/dev/null; then
    break
  fi
  if ! kill -0 "$MANAGER_PID" 2>/dev/null; then
    echo "Operator exited unexpectedly. Log output:"
    cat "$MANAGER_LOG"
    exit 1
  fi
  sleep 0.5
done

echo "Applying ${PIPELINE_COUNT} ModelInferencePipeline CRs..."
for i in $(seq 1 "$PIPELINE_COUNT"); do
  sed "s/PIPELINE_NAME/scale-test-$i/" "$ROOT/config/samples/modelpipeline_v1alpha1_scale-test.yaml" | kubectl apply -f -
done

echo ""
echo "Waiting for reconcile (5s)..."
sleep 5

RUNNING="$(kubectl get modelinferencepipelines -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c Running || true)"
TOTAL="$(kubectl get modelinferencepipelines --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo "Pipeline status: ${RUNNING}/${TOTAL} Running"

lab_metrics_handoff "interactive operator log watch"

echo ""
echo "Watch local operator logs (Ctrl+C to stop):"
tail -f "$MANAGER_LOG"
