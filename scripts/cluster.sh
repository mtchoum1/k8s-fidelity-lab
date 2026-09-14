#!/usr/bin/env bash
# Idempotent cluster provisioning for fidelity-lab tiers (timed via lab-metrics handoff).
set -euo pipefail

: "${LAB_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

ensure_podman_machine() {
  if command -v podman &>/dev/null && podman machine list &>/dev/null 2>&1; then
    podman machine start 2>/dev/null || true
  fi
}

require_kind() {
  if ! command -v kind &>/dev/null; then
    echo "kind not found. Install: https://kind.sigs.k8s.io/docs/user/quick-start/"
    exit 1
  fi
}

ensure_kind_cluster() {
  local cluster_name="${1:-fidelity-kind}"
  local config_file="${2:-${LAB_ROOT}/config/kind-config.yaml}"

  require_kind
  # shellcheck source=scripts/container.sh
  source "${LAB_ROOT}/scripts/container.sh"
  setup_podman_env
  ensure_podman_machine

  if kind get clusters 2>/dev/null | grep -qx "$cluster_name"; then
    echo "kind cluster '${cluster_name}' already exists — reusing"
  else
    echo "Creating kind cluster '${cluster_name}' (may take several minutes)..."
    kind create cluster --name "$cluster_name" --config "$config_file" --wait 5m
  fi

  kubectl config use-context "kind-${cluster_name}"
  kubectl cluster-info --context "kind-${cluster_name}"
}

require_kwokctl() {
  if ! command -v kwokctl &>/dev/null; then
    echo "kwokctl not found."
    echo "Install KWOK: https://kwok.sigs.k8s.io/docs/user/install/"
    exit 1
  fi
}

ensure_kwok_cluster() {
  local cluster_name="${1:-fidelity-kwok}"

  require_kwokctl

  if kwokctl get clusters 2>/dev/null | grep -qx "$cluster_name"; then
    echo "KWOK cluster '${cluster_name}' already exists — reusing"
  else
    echo "Creating KWOK cluster '${cluster_name}' (may take a few minutes)..."
    kwokctl create cluster --name "$cluster_name" --wait 5m
  fi

  local kwok_context="kwok-${cluster_name}"
  local contexts
  contexts="$(kubectl config get-contexts -o name 2>/dev/null || true)"
  if ! grep -qx "$kwok_context" <<<"$contexts"; then
    if grep -qx "$cluster_name" <<<"$contexts"; then
      kwok_context="$cluster_name"
    else
      echo "kubectl context not found for KWOK cluster '${cluster_name}'."
      echo "Expected: kwok-${cluster_name} (or ${cluster_name})"
      exit 1
    fi
  fi
  kubectl config use-context "$kwok_context"
}

ensure_crc_openshift() {
  if ! command -v crc &>/dev/null; then
    echo "crc not found. Install OpenShift Local: https://developers.redhat.com/products/openshift-local/overview"
    exit 1
  fi

  local status
  status="$(crc status 2>/dev/null || true)"
  if grep -qi "Running" <<<"$status"; then
    echo "CRC cluster already running — reusing"
  else
    echo "Starting CRC (first start may take 5-10 min)..."
    crc start
  fi

  # shellcheck disable=SC1090
  eval "$(crc oc-env)"

  local api_url="${CRC_API_URL:-https://api.crc.testing:6443}"
  if ! oc whoami &>/dev/null; then
    echo "Logging in to OpenShift as developer..."
    oc login -u developer -p developer "$api_url" --insecure-skip-tls-verify=true
  fi
}

ensure_openshift_cluster() {
  if oc whoami &>/dev/null; then
    echo "OpenShift: $(oc whoami) @ $(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
    return 0
  fi

  if ! command -v oc &>/dev/null; then
    echo "oc CLI not found. Install OpenShift CLI: https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html"
    exit 1
  fi

  ensure_crc_openshift
  echo "OpenShift: $(oc whoami) @ $(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
}

ensure_kubectl_cluster() {
  local cluster_name="${1:-fidelity-kind}"
  local config_file="${2:-${LAB_ROOT}/config/kind-config.yaml}"

  if kubectl cluster-info &>/dev/null; then
    echo "Kubernetes cluster reachable — reusing current context: $(kubectl config current-context)"
    return 0
  fi

  echo "No cluster detected — provisioning kind cluster '${cluster_name}'..."
  ensure_kind_cluster "$cluster_name" "$config_file"
}
