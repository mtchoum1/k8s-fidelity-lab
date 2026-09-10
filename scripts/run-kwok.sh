#!/usr/bin/env bash
# Tier 2: KWOK scale testing with 500 ModelInferencePipeline CRs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${KWOK_CLUSTER_NAME:-fidelity-kwok}"
PIPELINE_COUNT="${PIPELINE_COUNT:-500}"

echo "=== Tier 2: KWOK scale test (${PIPELINE_COUNT} pipelines) ==="

if ! command -v kwokctl &>/dev/null; then
  echo "kwokctl not found. Install: https://kwok.sigs.k8s.io/docs/user/install/"
  exit 1
fi

kwokctl create cluster --name "$CLUSTER_NAME" --wait 5m
kubectl config use-context "kwok-$CLUSTER_NAME"

"$ROOT/kwok/generate-nodes.sh" "$ROOT/kwok/fake-nodes.yaml" 100
kubectl apply -f "$ROOT/kwok/fake-nodes.yaml"
kubectl apply -f "$ROOT/config/crd/bases/"
kubectl apply -f "$ROOT/config/operator/"

echo "Applying ${PIPELINE_COUNT} ModelInferencePipeline CRs..."
for i in $(seq 1 "$PIPELINE_COUNT"); do
  sed "s/PIPELINE_NAME/scale-test-$i/" "$ROOT/config/samples/modelpipeline_v1alpha1_scale-test.yaml" | kubectl apply -f -
done

echo "Watch controller logs for reconcile deadlock under scale:"
kubectl -n fidelity-lab-system logs -l app=fidelity-lab-operator -f
