#!/usr/bin/env bash
# Restore scenario files from the frozen baseline ref.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LAB_BASELINE_REF="${LAB_BASELINE_REF:-main}"

# Paths that contain intentional PR #104 bugs — reset only these, not learner notes.
RESET_PATHS=(
  api/
  controllers/
  config/
  rhoai/
  sidecar_entrypoint.sh
  Dockerfile.sidecar
  inference_server.py
  Tiltfile
)

echo "=== lab-reset: restoring scenario from ref '${LAB_BASELINE_REF}' ==="

if ! git rev-parse --verify "${LAB_BASELINE_REF}" >/dev/null 2>&1; then
  echo "error: baseline ref '${LAB_BASELINE_REF}' not found." >&2
  echo "Create it with: git tag lab-v1.0-pr104  # or set LAB_BASELINE_REF=main" >&2
  exit 1
fi

CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || echo "")"
if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "broken-baseline" ]]; then
  echo "warning: you are on '${CURRENT_BRANCH}'. Consider switching to a working branch first:" >&2
  echo "  git checkout -b lab/\$(whoami)" >&2
fi

git restore --source="${LAB_BASELINE_REF}" --worktree -- "${RESET_PATHS[@]}"

echo "Restored paths:"
printf '  - %s\n' "${RESET_PATHS[@]}"
echo ""
echo "Run ./lab verify to confirm baseline integrity."
