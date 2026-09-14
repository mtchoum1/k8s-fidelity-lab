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
