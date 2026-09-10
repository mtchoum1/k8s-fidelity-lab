#!/usr/bin/env bash
# Generate 100 KWOK fake nodes for scale testing.
set -euo pipefail

OUTPUT="${1:-kwok/fake-nodes.yaml}"
NODE_COUNT="${2:-100}"

cat > "$OUTPUT" <<'HEADER'
# Auto-generated KWOK fake nodes for scale testing.
HEADER

for i in $(seq 0 $((NODE_COUNT - 1))); do
  cat >> "$OUTPUT" <<EOF
---
apiVersion: v1
kind: Node
metadata:
  annotations:
    node.alpha.kubernetes.io/ttl: "0"
    kwok.x-k8s.io/node: fake
  labels:
    beta.kubernetes.io/arch: amd64
    beta.kubernetes.io/os: linux
    kubernetes.io/arch: amd64
    kubernetes.io/hostname: kwok-node-${i}
    kubernetes.io/os: linux
    kwok.x-k8s.io/node: fake
    node-role.kubernetes.io/worker: ""
    type: kwok
  name: kwok-node-${i}
status:
  allocatable:
    cpu: 32
    memory: 256Gi
    pods: 110
  capacity:
    cpu: 32
    memory: 256Gi
    pods: 110
  nodeInfo:
    architecture: amd64
    operatingSystem: linux
  phase: Running
EOF
done

echo "Generated ${NODE_COUNT} fake nodes in ${OUTPUT}"
