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
# shellcheck source=scripts/lab-tier-check.sh
source "$ROOT/scripts/lab-tier-check.sh"
CLUSTER_NAME="${KWOK_CLUSTER_NAME:-fidelity-kwok}"
LAB_CLUSTER_NAME="$CLUSTER_NAME"
PIPELINE_COUNT="${PIPELINE_COUNT:-100}"
OBSERVE_SECONDS="${TIER2_OBSERVE_SECONDS:-90}"
MANAGER_PID=""

cleanup() {
  if [[ -n "$MANAGER_PID" ]] && kill -0 "$MANAGER_PID" 2>/dev/null; then
    kill "$MANAGER_PID" 2>/dev/null || true
    wait "$MANAGER_PID" 2>/dev/null || true
  fi
  _lab_cluster_cleanup_kwok
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

lab_metrics_handoff "observing pipeline reconcile under load"

echo ""
echo "Observing pipeline status for ${OBSERVE_SECONDS}s..."
RUNNING=0
TOTAL=0
for elapsed in $(seq 5 5 "$OBSERVE_SECONDS"); do
  RUNNING="$(kubectl get modelinferencepipelines -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c Running || true)"
  TOTAL="$(kubectl get modelinferencepipelines --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  POD_COUNT="$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  REQUEUE_COUNT="$(grep -c "waiting on pod status updates" "$MANAGER_LOG" 2>/dev/null || true)"
  echo "  [${elapsed}s] ${RUNNING}/${TOTAL} pipelines Running | ${POD_COUNT} pods | ${REQUEUE_COUNT} requeue log lines"
  sleep 5
done

REQUEUE_COUNT="$(grep -c "waiting on pod status updates" "$MANAGER_LOG" 2>/dev/null || true)"
POD_COUNT="$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo ""
echo "Final: ${RUNNING}/${TOTAL} Running | ${POD_COUNT} pods | ${REQUEUE_COUNT} requeue log lines"

if lab_baseline_bug_present 'podStatusPollLock' 'controllers/modelpipeline_controller.go'; then
  if [[ "$POD_COUNT" -eq 0 ]]; then
    lab_tier_fail "no pods in cluster — KWOK pod simulation did not start; cannot observe Tier 2 starvation"
  fi
  if [[ "$RUNNING" -eq "$TOTAL" ]] && [[ "$REQUEUE_COUNT" -eq 0 ]]; then
    lab_tier_fail "all pipelines reached Running with no requeue — Tier 2 starvation bug was not observed"
  fi
  lab_tier_expect_baseline_failure "reconcile starvation (${RUNNING}/${TOTAL} Running, ${REQUEUE_COUNT} requeue events in operator log)"
fi

if [[ "$RUNNING" -lt "$TOTAL" ]]; then
  lab_tier_fail "only ${RUNNING}/${TOTAL} pipelines Running — Tier 2 fix incomplete or observe window too short (try TIER2_OBSERVE_SECONDS=120)"
fi

if [[ "$REQUEUE_COUNT" -gt 0 ]]; then
  lab_tier_fail "operator still logging requeue loops (${REQUEUE_COUNT}) — remove podStatusPollLock / waitForPodStatuses blocking"
fi

lab_tier_pass "${RUNNING}/${TOTAL} pipelines Running with no reconcile starvation"
