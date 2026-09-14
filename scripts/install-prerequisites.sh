#!/usr/bin/env bash
# Install or verify k8s-fidelity-lab prerequisites.
#
# Usage:
#   ./scripts/install-prerequisites.sh              # install core tools (Tiers 1–4)
#   ./scripts/install-prerequisites.sh --all          # install tools for all tiers (1–7)
#   ./scripts/install-prerequisites.sh --tier 5       # install tools for a single tier
#   ./scripts/install-prerequisites.sh --check        # verify only, no installs
#   ./scripts/install-prerequisites.sh --check --all    # verify full tier set
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GO_MIN_VERSION="1.22"
INSTALL=false
CHECK_ONLY=false
SCOPE="core"   # core | all | tier
TIER=""

usage() {
  cat <<'EOF'
Usage: ./scripts/install-prerequisites.sh [options]

Options:
  --check           Verify prerequisites; do not install anything
  --core            Install core tools for Tiers 1–4 (default when installing)
  --all             Install tools for all tiers (1–7), where auto-install is possible
  --tier <N>        Install tools for a single tier (1–7)
  -h, --help        Show this help

Core tools (Tiers 1–4):
  go, kubectl, podman, uv, setup-envtest, kind, kwokctl, tilt

Additional tools (--all / per-tier):
  Tier 6: argocd CLI, kustomize (via kubectl)
  Tier 7: oc (OpenShift CLI) — CRC must be installed manually

After install, the script also runs:
  go mod download
  chmod +x lab scripts/*.sh kwok/generate-nodes.sh
  uv sync (if uv is available)
  podman machine start (macOS, when Podman uses podman machine)

Examples:
  ./scripts/install-prerequisites.sh --check
  ./scripts/install-prerequisites.sh
  ./scripts/install-prerequisites.sh --all
  ./scripts/install-prerequisites.sh --tier 2
EOF
}

log() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

detect_os() {
  case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux)  echo "linux" ;;
    *)      echo "unknown" ;;
  esac
}

go_version_ok() {
  if ! have_cmd go; then
    return 1
  fi
  local ver
  ver="$(go env GOVERSION 2>/dev/null | sed 's/^go//')"
  [[ -n "$ver" ]] || return 1
  printf '%s\n%s\n' "$GO_MIN_VERSION" "$ver" | sort -V | head -1 | grep -qx "$GO_MIN_VERSION"
}

require_homebrew_on_mac() {
  if [[ "$(detect_os)" == "darwin" ]] && ! have_cmd brew; then
    die "Homebrew is required on macOS. Install from https://brew.sh then re-run."
  fi
}

brew_install() {
  local pkg="$1"
  if brew list "$pkg" &>/dev/null; then
    log "  OK (already installed): brew $pkg"
    return 0
  fi
  log "  installing: brew install $pkg"
  brew install "$pkg"
}

install_with_brew() {
  local pkg
  for pkg in "$@"; do
    brew_install "$pkg"
  done
}

install_uv() {
  if have_cmd uv; then
    log "  OK (already installed): uv"
    return 0
  fi
  log "  installing: uv (official installer)"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="${HOME}/.local/bin:${PATH}"
}

install_kubectl_linux() {
  if have_cmd kubectl; then
    log "  OK (already installed): kubectl"
    return 0
  fi
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "unsupported architecture for kubectl install: $(uname -m)" ;;
  esac
  log "  installing: kubectl (stable release)"
  curl -Ls "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/${arch}/kubectl" \
    -o /tmp/kubectl
  chmod +x /tmp/kubectl
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl
}

install_kind_linux() {
  if have_cmd kind; then
    log "  OK (already installed): kind"
    return 0
  fi
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "unsupported architecture for kind install: $(uname -m)" ;;
  esac
  log "  installing: kind v0.24.0"
  curl -Ls "https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-${arch}" -o /tmp/kind
  chmod +x /tmp/kind
  sudo install -m 0755 /tmp/kind /usr/local/bin/kind
  rm -f /tmp/kind
}

install_kwokctl_linux() {
  if have_cmd kwokctl; then
    log "  OK (already installed): kwokctl"
    return 0
  fi
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "unsupported architecture for kwokctl install: $(uname -m)" ;;
  esac
  local version="v0.6.0"
  log "  installing: kwokctl ${version}"
  curl -Ls "https://github.com/kubernetes-sigs/kwok/releases/download/${version}/kwokctl-linux-${arch}" \
    -o /tmp/kwokctl
  chmod +x /tmp/kwokctl
  sudo install -m 0755 /tmp/kwokctl /usr/local/bin/kwokctl
  rm -f /tmp/kwokctl
}

install_tilt_linux() {
  if have_cmd tilt; then
    log "  OK (already installed): tilt"
    return 0
  fi
  log "  installing: tilt"
  curl -fsSL https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/install.sh | bash
}

install_argocd_linux() {
  if have_cmd argocd; then
    log "  OK (already installed): argocd"
    return 0
  fi
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "unsupported architecture for argocd install: $(uname -m)" ;;
  esac
  log "  installing: argocd CLI (stable)"
  curl -Ls "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-${arch}" \
    -o /tmp/argocd
  chmod +x /tmp/argocd
  sudo install -m 0755 /tmp/argocd /usr/local/bin/argocd
  rm -f /tmp/argocd
}

install_oc_linux() {
  if have_cmd oc; then
    log "  OK (already installed): oc"
    return 0
  fi
  warn "oc (OpenShift CLI) is not auto-installed on Linux."
  warn "Install from: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/"
}

install_go_linux() {
  if go_version_ok; then
    log "  OK (already installed): go $(go env GOVERSION)"
    return 0
  fi
  warn "Go ${GO_MIN_VERSION}+ is required but not found (or too old)."
  warn "Install from your package manager or https://go.dev/dl/"
}

install_podman_linux() {
  if have_cmd podman; then
    log "  OK (already installed): podman"
    return 0
  fi
  if have_cmd apt-get; then
    log "  installing: podman (apt)"
    sudo apt-get update
    sudo apt-get install -y podman
    return 0
  fi
  if have_cmd dnf; then
    log "  installing: podman (dnf)"
    sudo dnf install -y podman
    return 0
  fi
  warn "podman not found. Install from https://podman.io/getting-started/installation"
}

install_package() {
  local tool="$1"
  local os
  os="$(detect_os)"

  case "$tool" in
    go)
      if [[ "$os" == "darwin" ]]; then install_with_brew go
      else install_go_linux; fi
      ;;
    kubectl)
      if [[ "$os" == "darwin" ]]; then install_with_brew kubectl
      else install_kubectl_linux; fi
      ;;
    podman)
      if [[ "$os" == "darwin" ]]; then install_with_brew podman
      else install_podman_linux; fi
      ;;
    uv)
      install_uv
      ;;
    kind)
      if [[ "$os" == "darwin" ]]; then install_with_brew kind
      else install_kind_linux; fi
      ;;
    kwokctl)
      if [[ "$os" == "darwin" ]]; then install_with_brew kwok
      else install_kwokctl_linux; fi
      ;;
    tilt)
      if [[ "$os" == "darwin" ]]; then install_with_brew tilt
      else install_tilt_linux; fi
      ;;
    argocd)
      if [[ "$os" == "darwin" ]]; then install_with_brew argocd
      else install_argocd_linux; fi
      ;;
    oc)
      if [[ "$os" == "darwin" ]]; then install_with_brew openshift-cli
      else install_oc_linux; fi
      ;;
    crc)
      warn "CRC (OpenShift Local) must be installed manually:"
      warn "  https://developers.redhat.com/products/openshift-local/overview"
      ;;
    *)
      die "unknown tool: $tool"
      ;;
  esac
}

install_go_tools() {
  log ""
  log "=== Go tools (setup-envtest) ==="
  if ! go_version_ok; then
    warn "skipping setup-envtest — Go ${GO_MIN_VERSION}+ required"
    return 0
  fi
  local setup_envtest gopath
  gopath="$(go env GOPATH)"
  setup_envtest="${gopath}/bin/setup-envtest"
  if [[ -x "$setup_envtest" ]]; then
    log "  OK (already installed): setup-envtest"
  else
    log "  installing: setup-envtest"
    go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest
  fi
  log "  caching envtest binaries (Kubernetes 1.30)..."
  KUBEBUILDER_ASSETS="$("$setup_envtest" use 1.30.x -p path)"
  export KUBEBUILDER_ASSETS
  log "  KUBEBUILDER_ASSETS=${KUBEBUILDER_ASSETS}"
}

setup_repo() {
  log ""
  log "=== Repository setup ==="
  chmod +x lab scripts/*.sh kwok/generate-nodes.sh

  if go_version_ok; then
    log "  running: go mod download"
    go mod download
  else
    warn "skipping go mod download — Go ${GO_MIN_VERSION}+ required"
  fi

  if have_cmd uv; then
    log "  running: uv sync"
    uv sync
  else
    warn "skipping uv sync — uv not installed"
  fi

  if [[ "$(detect_os)" == "darwin" ]] && have_cmd podman && podman machine list &>/dev/null 2>&1; then
    log "  starting: podman machine"
    podman machine start 2>/dev/null || true
  fi
}

tools_for_scope() {
  local scope="$1"
  local tier="${2:-}"

  case "$scope" in
    tier)
      case "$tier" in
        1) printf '%s\n' go kubectl setup-envtest ;;
        2) printf '%s\n' go kubectl kwokctl ;;
        3) printf '%s\n' go kubectl podman kind ;;
        4) printf '%s\n' go kubectl podman kind tilt ;;
        5) printf '%s\n' go kubectl podman kind ;;
        6) printf '%s\n' go kubectl podman kind argocd ;;
        7) printf '%s\n' go kubectl podman oc crc ;;
        *) die "unknown tier: $tier (expected 1–7)" ;;
      esac
      ;;
    core)
      printf '%s\n' go kubectl podman uv kind kwokctl tilt setup-envtest
      ;;
    all)
      printf '%s\n' go kubectl podman uv kind kwokctl tilt argocd oc crc setup-envtest
      ;;
    *)
      die "unknown scope: $scope"
      ;;
  esac
}

check_tool() {
  local tool="$1"
  case "$tool" in
    go)
      go_version_ok
      ;;
    setup-envtest)
      have_cmd setup-envtest || [[ -x "$(go env GOPATH 2>/dev/null)/bin/setup-envtest" ]]
      ;;
    crc)
      have_cmd crc
      ;;
    *)
      have_cmd "$tool"
      ;;
  esac
}

print_check_row() {
  local tool="$1"
  local tier_note="$2"
  if check_tool "$tool"; then
    printf '  OK   %-14s %s\n' "$tool" "$tier_note"
  else
    printf '  MISS %-14s %s\n' "$tool" "$tier_note"
  fi
}

run_check() {
  local scope="$1"
  local tier="${2:-}"
  local missing=0
  local tool tier_note

  log "=== k8s-fidelity-lab prerequisite check (${scope}) ==="
  log ""

  while IFS= read -r tool; do
    [[ -n "$tool" ]] || continue
    tier_note=""
    case "$tool" in
      go|setup-envtest) tier_note="Tier 1" ;;
      kwokctl) tier_note="Tier 2" ;;
      podman|kind) tier_note="Tiers 3–6" ;;
      tilt) tier_note="Tier 4" ;;
      argocd) tier_note="Tier 6" ;;
      oc|crc) tier_note="Tier 7" ;;
      kubectl) tier_note="All tiers" ;;
      uv) tier_note="Python inference dev" ;;
    esac
    if check_tool "$tool"; then
      print_check_row "$tool" "$tier_note"
    else
      print_check_row "$tool" "$tier_note"
      missing=$((missing + 1))
    fi
  done < <(tools_for_scope "$scope" "$tier")

  log ""
  if [[ "$missing" -eq 0 ]]; then
    log "All checked prerequisites are installed."
    return 0
  fi
  log "${missing} prerequisite(s) missing."
  log "Install with: ./scripts/install-prerequisites.sh${scope:+ --${scope}}${tier:+ --tier ${tier}}"
  return 1
}

run_install() {
  local scope="$1"
  local tier="${2:-}"
  local os tool

  os="$(detect_os)"
  if [[ "$os" == "darwin" ]]; then
    require_homebrew_on_mac
  elif [[ "$os" == "unknown" ]]; then
    die "unsupported OS: $(uname -s)"
  fi

  log "=== Installing k8s-fidelity-lab prerequisites (${scope}) ==="
  log "Platform: ${os} ($(uname -m))"
  log ""

  while IFS= read -r tool; do
    [[ -n "$tool" ]] || continue
    [[ "$tool" == "setup-envtest" ]] && continue
    log "--- ${tool} ---"
    install_package "$tool"
  done < <(tools_for_scope "$scope" "$tier")

  install_go_tools
  setup_repo

  log ""
  log "=== Post-install verification ==="
  run_check "$scope" "$tier" || true

  log ""
  log "Next steps:"
  log "  git checkout -b lab/\$(whoami) lab-v1.0-pr104"
  log "  ./lab verify"
  log "  ./lab run 1"
  if [[ "$scope" == "all" ]] || [[ "$scope" == "tier" && "$tier" == "7" ]]; then
    if ! have_cmd crc; then
      log ""
      log "Tier 7 also requires CRC (OpenShift Local) — install manually if not present."
    fi
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK_ONLY=true
      shift
      ;;
    --core)
      SCOPE="core"
      INSTALL=true
      shift
      ;;
    --all)
      SCOPE="all"
      INSTALL=true
      shift
      ;;
    --tier)
      SCOPE="tier"
      INSTALL=true
      TIER="${2:-}"
      [[ -n "$TIER" ]] || die "--tier requires a number (1–7)"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (try --help)"
      ;;
  esac
done

if [[ "$CHECK_ONLY" == true ]]; then
  run_check "$SCOPE" "$TIER"
  exit $?
fi

if [[ "$INSTALL" == false ]]; then
  INSTALL=true
  SCOPE="core"
fi

run_install "$SCOPE" "$TIER"
