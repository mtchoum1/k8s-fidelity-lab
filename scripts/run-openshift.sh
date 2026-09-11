#!/usr/bin/env bash
# Tier 7: OpenShift Local (CRC) — build, push images, install operator, apply sample.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPERATOR_IMG="ghcr.io/k8s-fidelity-lab/operator:latest"
INFERENCE_IMG="ghcr.io/k8s-fidelity-lab/inference-server:latest"
SIDECAR_IMG="ghcr.io/k8s-fidelity-lab/metrics-sidecar:latest"

# Default: Quay.io repo https://quay.io/repository/mtchoumi-aaet/lab-image
QUAY_IMAGE_PREFIX="${QUAY_IMAGE_PREFIX:-quay.io/mtchoumi-aaet/lab-image}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-quay}"   # quay | crc
LAB_NAMESPACE="${LAB_NAMESPACE:-fidelity-lab-system}"

# shellcheck source=scripts/container.sh
source "$ROOT/scripts/container.sh"
setup_podman_env

echo "=== Tier 7: OpenShift / CRC ==="

if ! command -v oc &>/dev/null; then
  echo "oc CLI not found. Install OpenShift CLI: https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html"
  exit 1
fi

if ! oc whoami &>/dev/null; then
  echo "Not logged in to OpenShift. Run:"
  echo "  eval \$(crc oc-env)"
  echo "  oc login -u developer -p developer https://api.crc.testing:6443"
  exit 1
fi

echo "Cluster: $(oc whoami) @ $(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}')"

detect_cluster_goarch() {
  local arch
  arch="$(oc get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || true)"
  case "$arch" in
    arm64|aarch64) echo arm64 ;;
    amd64|x86_64)  echo amd64 ;;
    *)
      case "$(uname -m)" in
        arm64|aarch64) echo arm64 ;;
        *) echo amd64 ;;
      esac
      ;;
  esac
}

GOARCH="${GOARCH:-$(detect_cluster_goarch)}"
echo "Building operator for GOARCH=${GOARCH} (must match cluster nodes)"
OPERATOR_BUILD_ARGS=(--build-arg "TARGETARCH=${GOARCH}")

quay_login() {
  if [[ -n "${QUAY_USERNAME:-}" ]]; then
    local pass="${QUAY_PASSWORD:-${QUAY_TOKEN:-}}"
    if [[ -z "$pass" ]]; then
      echo "error: set QUAY_PASSWORD or QUAY_TOKEN when QUAY_USERNAME is set"
      exit 1
    fi
    "$CONTAINER_RUNTIME" login quay.io -u "$QUAY_USERNAME" -p "$pass"
    return
  fi
  if ! "$CONTAINER_RUNTIME" login quay.io; then
    echo "error: log in to Quay first:"
    echo "  export QUAY_USERNAME=your-user"
    echo "  export QUAY_TOKEN=your-token    # Quay robot account or CLI password"
    echo "  $CONTAINER_RUNTIME login quay.io -u \"\$QUAY_USERNAME\" -p \"\$QUAY_TOKEN\""
    exit 1
  fi
}

ensure_quay_pull_secret() {
  local ns="$1"
  local sa="${2:-default}"
  [[ -n "${QUAY_USERNAME:-}" ]] || return 0
  local pass="${QUAY_PASSWORD:-${QUAY_TOKEN:-}}"
  [[ -n "$pass" ]] || return 0

  oc create secret docker-registry quay-lab-image-pull \
    --docker-server=quay.io \
    --docker-username="$QUAY_USERNAME" \
    --docker-password="$pass" \
    -n "$ns" --dry-run=client -o yaml | oc apply -f -
  oc secrets link "$sa" quay-lab-image-pull --for=pull -n "$ns" >/dev/null 2>&1 || true
}

push_image_quay() {
  local tag="$1"
  local source_tag="$2"
  local build_args=("${@:3}")
  local dst="${QUAY_IMAGE_PREFIX}:${tag}"

  echo "Building ${tag}..."
  container_build -t "$source_tag" "${build_args[@]}"
  echo "Pushing ${dst}..."
  quay_login
  "$CONTAINER_RUNTIME" tag "$source_tag" "$dst"
  "$CONTAINER_RUNTIME" push "$dst"
}

# --- Optional CRC internal registry (set IMAGE_REGISTRY=crc) ---
REGISTRY_PF_PORT="${REGISTRY_PF_PORT:-5001}"

push_image_crc() {
  local name="$1"
  local source_tag="$2"
  local build_args=("${@:3}")
  local registry_host
  registry_host="$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "$registry_host" ]]; then
    oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge \
      -p '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}' >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      registry_host="$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)"
      [[ -n "$registry_host" ]] && break
      sleep 2
    done
  fi
  [[ -n "$registry_host" ]] || { echo "error: CRC image registry route unavailable"; exit 1; }

  echo "Building ${name}..."
  container_build -t "$source_tag" "${build_args[@]}"
  local dst="localhost:${REGISTRY_PF_PORT}/default/${name}:latest"
  echo "Pushing ${dst} via port-forward..."
  oc port-forward -n openshift-image-registry svc/image-registry "${REGISTRY_PF_PORT}:5000" >/tmp/crc-registry-pf.log 2>&1 &
  local pf_pid=$!
  for _ in $(seq 1 15); do
    curl -sf "http://localhost:${REGISTRY_PF_PORT}/v2/" >/dev/null 2>&1 && break
    sleep 1
  done
  "$CONTAINER_RUNTIME" login -u kubeadmin -p "$(oc whoami -t)" "localhost:${REGISTRY_PF_PORT}" --tls-verify=false
  "$CONTAINER_RUNTIME" tag "$source_tag" "$dst"
  "$CONTAINER_RUNTIME" push --tls-verify=false "$dst"
  kill "$pf_pid" 2>/dev/null || true
}

if [[ "$IMAGE_REGISTRY" == "quay" ]]; then
  echo "Image registry: Quay (${QUAY_IMAGE_PREFIX})"
  push_image_quay operator "$OPERATOR_IMG" "${OPERATOR_BUILD_ARGS[@]}" "$ROOT"
  push_image_quay inference-server "$INFERENCE_IMG" -f "$ROOT/Dockerfile.inference" "$ROOT"
  push_image_quay metrics-sidecar "$SIDECAR_IMG" -f "$ROOT/Dockerfile.sidecar" "$ROOT"
  OPERATOR_REF="${QUAY_IMAGE_PREFIX}:operator"
  INFERENCE_REF="${QUAY_IMAGE_PREFIX}:inference-server"
  SIDECAR_REF="${QUAY_IMAGE_PREFIX}:metrics-sidecar"
else
  echo "Image registry: CRC internal (IMAGE_REGISTRY=crc)"
  CRC_REGISTRY="image-registry.openshift-image-registry.svc:5000/default"
  push_image_crc operator "$OPERATOR_IMG" "$ROOT"
  push_image_crc inference-server "$INFERENCE_IMG" -f "$ROOT/Dockerfile.inference" "$ROOT"
  push_image_crc metrics-sidecar "$SIDECAR_IMG" -f "$ROOT/Dockerfile.sidecar" "$ROOT"
  OPERATOR_REF="${CRC_REGISTRY}/operator:latest"
  INFERENCE_REF="${CRC_REGISTRY}/inference-server:latest"
  SIDECAR_REF="${CRC_REGISTRY}/metrics-sidecar:latest"
fi

echo "Installing CRD and operator..."
oc apply -f "$ROOT/config/crd/bases/"
oc apply -f "$ROOT/config/operator/"

ensure_quay_pull_secret "$LAB_NAMESPACE" fidelity-lab-operator
ensure_quay_pull_secret "$LAB_NAMESPACE" default

oc -n "$LAB_NAMESPACE" set image deployment/fidelity-lab-operator manager="${OPERATOR_REF}"
# oc apply resets image to ghcr.io; force pull fresh Quay tag (same :operator, new arch).
oc -n "$LAB_NAMESPACE" patch deployment/fidelity-lab-operator --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Always"}]'
oc -n "$LAB_NAMESPACE" rollout restart deployment/fidelity-lab-operator
oc -n "$LAB_NAMESPACE" delete pod -l app=fidelity-lab-operator --force --grace-period=0 2>/dev/null || true

echo "Waiting for operator..."
oc -n "$LAB_NAMESPACE" rollout status deployment/fidelity-lab-operator --timeout=300s

echo "Applying Tier 7 sample in namespace ${LAB_NAMESPACE} (expect SCC failure on baseline)..."
oc apply -f - <<EOF
apiVersion: fidelity.ai/v1alpha1
kind: ModelInferencePipeline
metadata:
  name: pr104-openshift-sidecar
  namespace: ${LAB_NAMESPACE}
spec:
  modelName: sklearn-iris
  replicas: 1
  image: ${INFERENCE_REF}
  gpuMemoryRequirement: "16Gi"
  sidecarLogging: true
  sidecarImage: ${SIDECAR_REF}
EOF

echo ""
echo "Images:"
echo "  operator:         ${OPERATOR_REF}"
echo "  inference-server: ${INFERENCE_REF}"
echo "  metrics-sidecar:  ${SIDECAR_REF}"
echo ""
echo "All Tier 7 resources are in namespace: ${LAB_NAMESPACE}"
echo "  oc project ${LAB_NAMESPACE}"
echo ""
echo "Verify Tier 7 SCC failure (pods may not appear — check deployment/replicaset):"
echo "  oc project ${LAB_NAMESPACE}"
echo "  oc get deployment pr104-openshift-sidecar-inference"
echo "  oc describe rs -l fidelity.ai/pipeline=pr104-openshift-sidecar | tail -20"
