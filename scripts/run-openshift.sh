#!/usr/bin/env bash
# Tier 7: OpenShift Local (CRC) — build, push images, install operator, apply sample.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lab-metrics.sh
source "$ROOT/scripts/lab-metrics.sh"
# shellcheck source=scripts/cluster.sh
source "$ROOT/scripts/cluster.sh"
# shellcheck source=scripts/lab-tier-check.sh
source "$ROOT/scripts/lab-tier-check.sh"
OPERATOR_IMG="ghcr.io/k8s-fidelity-lab/operator:latest"
INFERENCE_IMG="ghcr.io/k8s-fidelity-lab/inference-server:latest"
SIDECAR_IMG="ghcr.io/k8s-fidelity-lab/metrics-sidecar:latest"

IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr}"   # ghcr | crc
LAB_NAMESPACE="${LAB_NAMESPACE:-fidelity-lab-system}"

# shellcheck source=scripts/container.sh
source "$ROOT/scripts/container.sh"
setup_podman_env

detect_ghcr_image_prefix() {
  if [[ -n "${GHCR_IMAGE_PREFIX:-}" ]]; then
    echo "$GHCR_IMAGE_PREFIX"
    return 0
  fi
  if ! git -C "$ROOT" rev-parse --is-inside-work-tree &>/dev/null; then
    echo "ghcr.io/k8s-fidelity-lab/lab-image"
    return 0
  fi
  local url owner repo
  url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  case "$url" in
    git@github.com:*)
      owner="${url#git@github.com:}"
      owner="${owner%%/*}"
      repo="${url##*/}"
      ;;
    https://github.com/*)
      owner="${url#https://github.com/}"
      owner="${owner%%/*}"
      repo="${url##*/}"
      ;;
    *)
      echo "ghcr.io/k8s-fidelity-lab/lab-image"
      return 0
      ;;
  esac
  repo="${repo%.git}"
  echo "ghcr.io/${owner}/${repo}"
}

GHCR_IMAGE_PREFIX="$(detect_ghcr_image_prefix)"

register_lab_crc_cleanup

echo "=== Tier 7: OpenShift / CRC ==="

ensure_openshift_cluster

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

detect_ghcr_credentials() {
  GHCR_TOKEN="${GITHUB_TOKEN:-${GHCR_TOKEN:-}}"
  if [[ -z "$GHCR_TOKEN" ]] && command -v gh &>/dev/null; then
    GHCR_TOKEN="$(gh auth token 2>/dev/null || true)"
  fi
  GHCR_USERNAME="${GHCR_USERNAME:-${GITHUB_USERNAME:-}}"
  if [[ -z "$GHCR_USERNAME" ]] && command -v gh &>/dev/null; then
    GHCR_USERNAME="$(gh api user -q .login 2>/dev/null || true)"
  fi
  export GHCR_TOKEN GHCR_USERNAME
}

ghcr_login() {
  detect_ghcr_credentials
  if [[ -z "${GHCR_TOKEN:-}" || -z "${GHCR_USERNAME:-}" ]]; then
    echo "error: log in to GitHub Container Registry first:"
    echo "  gh auth login"
    echo "  export GITHUB_TOKEN=\$(gh auth token)"
    echo "  export GHCR_USERNAME=\$(gh api user -q .login)"
    echo "  $CONTAINER_RUNTIME login ghcr.io -u \"\$GHCR_USERNAME\" --password-stdin <<< \"\$GITHUB_TOKEN\""
    exit 1
  fi
  echo "$GHCR_TOKEN" | "$CONTAINER_RUNTIME" login ghcr.io -u "$GHCR_USERNAME" --password-stdin
}

ensure_ghcr_pull_secret() {
  local ns="$1"
  local sa="${2:-default}"
  detect_ghcr_credentials
  [[ -n "${GHCR_TOKEN:-}" && -n "${GHCR_USERNAME:-}" ]] || return 0

  oc create secret docker-registry ghcr-lab-image-pull \
    --docker-server=ghcr.io \
    --docker-username="$GHCR_USERNAME" \
    --docker-password="$GHCR_TOKEN" \
    -n "$ns" --dry-run=client -o yaml | oc apply -f -
  oc secrets link "$sa" ghcr-lab-image-pull --for=pull -n "$ns" >/dev/null 2>&1 || true
}

push_image_ghcr() {
  local tag="$1"
  local source_tag="$2"
  local build_args=("${@:3}")
  local dst="${GHCR_IMAGE_PREFIX}:${tag}"

  echo "Building ${tag}..."
  container_build -t "$source_tag" "${build_args[@]}"
  echo "Pushing ${dst}..."
  ghcr_login
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

if [[ "$IMAGE_REGISTRY" == "ghcr" ]]; then
  echo "Image registry: GitHub Container Registry (${GHCR_IMAGE_PREFIX})"
  push_image_ghcr operator "$OPERATOR_IMG" "${OPERATOR_BUILD_ARGS[@]}" "$ROOT"
  push_image_ghcr inference-server "$INFERENCE_IMG" -f "$ROOT/Dockerfile.inference" "$ROOT"
  push_image_ghcr metrics-sidecar "$SIDECAR_IMG" -f "$ROOT/Dockerfile.sidecar" "$ROOT"
  OPERATOR_REF="${GHCR_IMAGE_PREFIX}:operator"
  INFERENCE_REF="${GHCR_IMAGE_PREFIX}:inference-server"
  SIDECAR_REF="${GHCR_IMAGE_PREFIX}:metrics-sidecar"
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

ensure_ghcr_pull_secret "$LAB_NAMESPACE" fidelity-lab-operator
ensure_ghcr_pull_secret "$LAB_NAMESPACE" default

oc -n "$LAB_NAMESPACE" set image deployment/fidelity-lab-operator manager="${OPERATOR_REF}"
oc -n "$LAB_NAMESPACE" patch deployment/fidelity-lab-operator --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Always"}]'
oc -n "$LAB_NAMESPACE" rollout restart deployment/fidelity-lab-operator
oc -n "$LAB_NAMESPACE" delete pod -l app=fidelity-lab-operator --force --grace-period=0 2>/dev/null || true

echo "Waiting for operator..."
oc -n "$LAB_NAMESPACE" rollout status deployment/fidelity-lab-operator --timeout=300s

PIPELINE_NAME="pr104-openshift-sidecar"
PIPELINE_LABEL="fidelity.ai/pipeline=${PIPELINE_NAME}"
DEPLOYMENT_NAME="${PIPELINE_NAME}-inference"

echo "Recreating Tier 7 sample in namespace ${LAB_NAMESPACE} (drops stale replicasets from prior runs)..."
oc delete modelinferencepipeline "$PIPELINE_NAME" -n "$LAB_NAMESPACE" --ignore-not-found --wait=false
oc delete deployment "$DEPLOYMENT_NAME" -n "$LAB_NAMESPACE" --ignore-not-found --wait=false
oc delete rs -n "$LAB_NAMESPACE" -l "$PIPELINE_LABEL" --ignore-not-found --wait=false
sleep 3

if lab_tier7_baseline_bug_present; then
  echo "Baseline bug present — expect SCC failure on root sidecar + hostPath /var/log"
else
  echo "Tier 7 fix detected in controller — expect SCC-compliant sidecar pod"
fi

oc apply -f - <<EOF
apiVersion: fidelity.ai/v1alpha1
kind: ModelInferencePipeline
metadata:
  name: ${PIPELINE_NAME}
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
lab_metrics_handoff "checking OpenShift SCC enforcement"

lab_tier7_newest_replicaset() {
  oc get rs -n "$LAB_NAMESPACE" -l "$PIPELINE_LABEL" \
    --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -1
}

lab_tier7_replicaset_scc_denial() {
  local rs="$1"
  [[ -n "$rs" ]] || return 1
  oc describe "$rs" -n "$LAB_NAMESPACE" 2>/dev/null \
    | grep -i 'unable to validate against any security context constraint' \
    | head -1
}

echo "Waiting for deployment/replicaset events (up to 120s)..."
SCC_DENIED=""
NEWEST_RS=""
for _ in $(seq 1 60); do
  NEWEST_RS="$(lab_tier7_newest_replicaset)"
  if [[ -n "$NEWEST_RS" ]]; then
    SCC_DENIED="$(lab_tier7_replicaset_scc_denial "$NEWEST_RS" || true)"
    if [[ -n "$SCC_DENIED" ]]; then
      break
    fi
  fi
  if oc get deployment "$DEPLOYMENT_NAME" -n "$LAB_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '[1-9]'; then
    break
  fi
  sleep 2
done

if lab_tier7_baseline_bug_present; then
  if [[ -n "$SCC_DENIED" ]]; then
    echo "$SCC_DENIED"
    lab_tier_expect_baseline_failure "OpenShift SCC denies root sidecar mounting /var/log"
  fi
  echo "Recent replicaset events (newest RS: ${NEWEST_RS:-none}):"
  if [[ -n "$NEWEST_RS" ]]; then
    oc describe "$NEWEST_RS" -n "$LAB_NAMESPACE" 2>/dev/null | tail -20 || true
  fi
  lab_tier_fail "Tier 7 SCC denial not observed on newest replicaset — sidecar may still run as root on /var/log"
fi

if ! lab_tier7_fix_applied; then
  lab_tier_fail "Tier 7 fix incomplete — use emptyDir volume, RunAsNonRoot, and drop int64Ptr(0)"
fi

echo "Waiting for inference deployment rollout..."
if ! oc -n "$LAB_NAMESPACE" rollout status "deployment/${DEPLOYMENT_NAME}" --timeout=180s; then
  echo "Deployment status:"
  oc get deployment "$DEPLOYMENT_NAME" -n "$LAB_NAMESPACE" -o wide 2>/dev/null || true
  if [[ -n "$NEWEST_RS" ]]; then
    echo "Newest replicaset events:"
    oc describe "$NEWEST_RS" -n "$LAB_NAMESPACE" 2>/dev/null | tail -20 || true
  fi
  lab_tier_fail "inference deployment did not become ready after SCC fix"
fi

READY="$(oc get pods -n "$LAB_NAMESPACE" -l "$PIPELINE_LABEL" -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="metrics-sidecar")].ready}' 2>/dev/null || true)"
if [[ "$READY" != "true" ]]; then
  echo "Sidecar logs:"
  oc logs -n "$LAB_NAMESPACE" -l "$PIPELINE_LABEL" -c metrics-sidecar --tail=20 2>/dev/null || true
  lab_tier_fail "metrics-sidecar not ready after SCC fix — also verify Tier 3 SIDECAR_LOG_DIR"
fi

lab_tier_pass "OpenShift pipeline running with SCC-compliant sidecar"
