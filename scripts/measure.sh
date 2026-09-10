#!/bin/bash
# Usage: ./scripts/measure.sh "command-to-run"

set -euo pipefail

CMD="${1:-}"
if [[ -z "$CMD" ]]; then
  echo "Usage: $0 \"command-to-run\""
  exit 1
fi

echo "=== Measuring Execution: $CMD ==="

START_TIME=$(date +%s)

set +e
/usr/bin/time -v bash -c "$CMD" 2> comm_stats.tmp
CMD_EXIT=$?
set -e

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo "--------------------------------------"
echo "Total Time Elapsed: ${ELAPSED} seconds"
grep "Maximum resident set size" comm_stats.tmp || true
rm -f comm_stats.tmp

if command -v podman &>/dev/null; then
  echo "Podman container stats (if any running):"
  podman stats --no-stream 2>/dev/null || true
fi

exit "$CMD_EXIT"
