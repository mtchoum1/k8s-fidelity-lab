#!/usr/bin/env bash
# Pass/fail helpers for in-cluster tier validation (baseline fails until fixed).
set -euo pipefail

: "${LAB_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

lab_baseline_bug_present() {
  local marker="$1"
  local file="${2:-}"
  [[ -n "$file" ]] || return 1
  grep -q "$marker" "$LAB_ROOT/$file"
}

lab_tier3_fix_applied() {
  grep -q 'Name: "SIDECAR_LOG_DIR"' "$LAB_ROOT/controllers/modelpipeline_controller.go"
}

lab_tier5_baseline_bug_present() {
  grep -E '^\s*apiVersion:\s*serving\.kserve\.io/v1beta1\s*$' \
    "$LAB_ROOT/rhoai/inferenceservice-v1beta1.yaml"
}

lab_tier6_baseline_bug_present() {
  grep -qE '^\s*path:\s*/spec/sidecarLoging\s*$' \
    "$LAB_ROOT/config/overlays/pr104/sidecar-patch.yaml"
}

lab_tier7_baseline_bug_present() {
  grep -q 'HostPath: &corev1.HostPathVolumeSource' \
    "$LAB_ROOT/controllers/modelpipeline_controller.go" \
    && grep -q 'Path: "/var/log"' \
    "$LAB_ROOT/controllers/modelpipeline_controller.go" \
    && grep -q 'int64Ptr(0)' \
    "$LAB_ROOT/controllers/modelpipeline_controller.go"
}

lab_tier7_fix_applied() {
  grep -q 'EmptyDir: &corev1.EmptyDirVolumeSource' \
    "$LAB_ROOT/controllers/modelpipeline_controller.go" \
    && grep -q 'RunAsNonRoot: boolPtr(true)' \
    "$LAB_ROOT/controllers/modelpipeline_controller.go" \
    && ! grep -q 'int64Ptr(0)' \
    "$LAB_ROOT/controllers/modelpipeline_controller.go" \
    && ! grep -qE 'RunAsUser:\s+int64Ptr\(' \
    "$LAB_ROOT/controllers/modelpipeline_controller.go"
}

lab_tier_pass() {
  echo ""
  echo "PASS: $*"
  exit 0
}

lab_tier_fail() {
  echo ""
  echo "FAIL: $*"
  exit 1
}

lab_tier_expect_baseline_failure() {
  echo ""
  echo "EXPECTED on baseline (apply fix and re-run): $*"
  exit 1
}
