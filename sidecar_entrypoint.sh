#!/bin/sh
# PR #104 metrics/logging sidecar entrypoint.
set -eu

# Required by the sidecar — INTENTIONAL TIER 3 BUG when controller omits this env var.
if [ -z "${SIDECAR_LOG_DIR:-}" ]; then
  echo "error: SIDECAR_LOG_DIR environment variable is required" >&2
  exit 1
fi

mkdir -p "${SIDECAR_LOG_DIR}"
LOG_FILE="${SIDECAR_LOG_DIR}/inference-metrics.log"

echo "sidecar starting; writing metrics to ${LOG_FILE}"
while true; do
  echo "$(date -Iseconds) batch_throughput=0 gpu_util=0" >> "${LOG_FILE}"
  sleep 5
done
