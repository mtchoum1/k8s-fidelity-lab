#!/bin/bash
# Usage: ./scripts/measure.sh "command-to-run"
# macOS: uses /usr/bin/time -l  |  Linux: uses /usr/bin/time -v (or GNU time)
# Also appends results to .lab/tier-metrics.csv when LAB_METRICS_TIER is set.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lab-metrics.sh
source "$ROOT/scripts/lab-metrics.sh"

CMD="${1:-}"
if [[ -z "$CMD" ]]; then
  echo "Usage: $0 \"command-to-run\""
  exit 1
fi

echo "=== Measuring Execution: $CMD ==="

if lab_metrics_run_timed "$CMD"; then
  exit 0
else
  exit 1
fi
