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
