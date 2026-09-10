#!/usr/bin/env bash
# Shared Podman helpers for image build and kind image loading.
set -euo pipefail

CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-podman}"

container_require() {
  if ! command -v "$CONTAINER_RUNTIME" &>/dev/null; then
    echo "error: ${CONTAINER_RUNTIME} not found. Install Podman: https://podman.io/getting-started/installation"
    exit 1
  fi
}

container_build() {
  container_require
  "$CONTAINER_RUNTIME" build "$@"
}

# kind cannot pull directly from the Podman local store on all platforms;
# save the image to a tarball and load it into the kind node.
kind_load_image() {
  local image="$1"
  local cluster="$2"
  local tar

  container_require
  tar="$(mktemp "/tmp/kind-image-${cluster}.XXXXXX.tar")"
  "$CONTAINER_RUNTIME" save "$image" -o "$tar"
  kind load image-archive "$tar" --name "$cluster"
  rm -f "$tar"
}

setup_podman_env() {
  if [[ "$CONTAINER_RUNTIME" != "podman" ]]; then
    return 0
  fi

  # kind: use Podman as the node provider when available.
  export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"

  # Tilt and other docker-CLI tools: point at the Podman socket.
  if [[ -z "${DOCKER_HOST:-}" ]] && command -v podman &>/dev/null; then
    if podman machine list &>/dev/null 2>&1; then
      local socket
      socket="$(podman machine inspect --format '{{ .ConnectionInfo.PodmanSocket.Path }}' 2>/dev/null || true)"
      if [[ -n "$socket" ]]; then
        export DOCKER_HOST="unix://${socket}"
      fi
    elif [[ -S "/run/user/$(id -u)/podman/podman.sock" ]]; then
      export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
    fi
  fi
}
