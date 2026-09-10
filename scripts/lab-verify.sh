#!/usr/bin/env bash
# Verify the broken baseline is intact — intentional bugs must still be present.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

QUIET=false
if [[ "${1:-}" == "--quiet" ]]; then
  QUIET=true
fi

log() {
  if [[ "$QUIET" == false ]]; then
    echo "$@"
  fi
}

fail() {
  printf 'lab-verify FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  log "  OK: $*"
}

log "=== lab-verify: checking PR #104 baseline integrity ==="

# --- Tier 1: envtest documents schema + nil-pointer bugs ---
if [[ -z "${KUBEBUILDER_ASSETS:-}" ]]; then
  SETUP_ENVTEST="$(go env GOPATH)/bin/setup-envtest"
  if [[ -x "$SETUP_ENVTEST" ]]; then
    export KUBEBUILDER_ASSETS="$("$SETUP_ENVTEST" use -p path)"
  fi
fi

if [[ -n "${KUBEBUILDER_ASSETS:-}" ]]; then
  go test ./controllers/... -count=1 >/dev/null 2>&1 || fail "Tier 1 envtest suite must pass on baseline"
  pass "Tier 1 envtest suite passes"
else
  log "  SKIP: Tier 1 envtest (install setup-envtest or set KUBEBUILDER_ASSETS)"
fi

grep -q 'INTENTIONAL TIER 1 BUG' api/v1alpha1/modelpipeline_types.go \
  || fail "Tier 1 schema bug marker missing from modelpipeline_types.go"
pass "Tier 1 schema bug marker present"

grep -q 'gpuMemoryScaleFactors' controllers/modelpipeline_controller.go \
  || fail "Tier 1 GPU scale map missing"
pass "Tier 1 nil-pointer scale map present"

# --- Tier 2: sequential pod status polling ---
grep -q 'podStatusPollLock' controllers/modelpipeline_controller.go \
  || fail "Tier 2 scale bug (podStatusPollLock) missing"
pass "Tier 2 reconcile starvation bug present"

# --- Tier 3: sidecar missing SIDECAR_LOG_DIR in controller ---
grep -q 'INTENTIONAL TIER 3 BUG' controllers/modelpipeline_controller.go \
  || fail "Tier 3 sidecar env bug marker missing"
pass "Tier 3 sidecar env bug marker present"

if SIDECAR_LOG_DIR= bash "$ROOT/sidecar_entrypoint.sh" >/dev/null 2>&1; then
  fail "Tier 3 sidecar must exit non-zero without SIDECAR_LOG_DIR"
fi
pass "Tier 3 sidecar fails without SIDECAR_LOG_DIR"

# --- Tier 5: KServe v1beta1 ---
grep -q 'serving.kserve.io/v1beta1' rhoai/inferenceservice-v1beta1.yaml \
  || fail "Tier 5 KServe v1beta1 bug missing"
pass "Tier 5 KServe apiVersion bug present"

# --- Tier 6: malformed Kustomize patch ---
if kubectl kustomize config/overlays/pr104 >/dev/null 2>&1; then
  fail "Tier 6 kustomize overlay must fail to build on baseline"
fi
pass "Tier 6 kustomize overlay fails to build (expected)"

grep -q 'sidecarLoging' config/overlays/pr104/sidecar-patch.yaml \
  || fail "Tier 6 patch typo (sidecarLoging) missing"
pass "Tier 6 patch typo present"

# --- Tier 7: root sidecar on /var/log ---
grep -q 'INTENTIONAL TIER 7 BUG' controllers/modelpipeline_controller.go \
  || fail "Tier 7 SCC bug marker missing"
pass "Tier 7 OpenShift SCC bug marker present"

grep -q 'int64Ptr(0)' controllers/modelpipeline_controller.go \
  || fail "Tier 7 root UID sidecar missing"
pass "Tier 7 root UID sidecar present"

log ""
log "lab-verify PASS: all intentional bugs are present"
