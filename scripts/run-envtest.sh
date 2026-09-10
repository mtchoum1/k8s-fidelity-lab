#!/usr/bin/env bash
# Tier 1: Run controller tests with KubeBuilder envtest.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "=== Tier 1: envtest (CRD schema + controller logic) ==="

if [[ -z "${KUBEBUILDER_ASSETS:-}" ]]; then
  SETUP_ENVTEST="$(go env GOPATH)/bin/setup-envtest"
  if [[ ! -x "$SETUP_ENVTEST" ]]; then
    echo "Installing setup-envtest..."
    go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest
  fi
  export KUBEBUILDER_ASSETS="$("$SETUP_ENVTEST" use -p path)"
  echo "Using envtest binaries: ${KUBEBUILDER_ASSETS}"
fi

if [[ -x "$ROOT/scripts/measure.sh" ]]; then
  "$ROOT/scripts/measure.sh" "go test ./controllers/... -v -count=1"
else
  go test ./controllers/... -v -count=1
fi
