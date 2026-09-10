#!/bin/bash
# Usage: ./scripts/measure.sh "command-to-run"
# macOS: uses /usr/bin/time -l  |  Linux: uses /usr/bin/time -v (or GNU time)

set -euo pipefail

CMD="${1:-}"
if [[ -z "$CMD" ]]; then
  echo "Usage: $0 \"command-to-run\""
  exit 1
fi

echo "=== Measuring Execution: $CMD ==="

START_TIME=$(date +%s)
OUTPUT_TMP="$(mktemp "${TMPDIR:-/tmp}/lab-measure.XXXXXX")"

run_with_time() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    /usr/bin/time -l bash -c "$CMD"
  elif command -v gtime &>/dev/null; then
    gtime -v bash -c "$CMD"
  else
    /usr/bin/time -v bash -c "$CMD"
  fi
}

set +e
run_with_time > "$OUTPUT_TMP" 2>&1
CMD_EXIT=$?
set -e

cat "$OUTPUT_TMP"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo "--------------------------------------"
echo "Total Time Elapsed: ${ELAPSED} seconds"
# GNU time (-v) and BSD time (-l) use different labels
grep -E "Maximum resident set size|maximum resident set size" "$OUTPUT_TMP" || true
rm -f "$OUTPUT_TMP"

if command -v podman &>/dev/null; then
  echo "Podman container stats (if any running):"
  podman stats --no-stream 2>/dev/null || true
fi

exit "$CMD_EXIT"
