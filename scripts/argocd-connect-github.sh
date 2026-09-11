#!/usr/bin/env bash
# Point ArgoCD at this repo's GitHub origin and current branch, then apply the Application.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAME="${ARGOCD_APP_NAME:-fidelity-lab-pr104}"
SOURCE_PATH="${ARGOCD_SOURCE_PATH:-config/overlays/pr104}"
DEST_NAMESPACE="${ARGOCD_DEST_NAMESPACE:-default}"

normalize_repo_url() {
  local url="$1"
  case "$url" in
    git@github.com:*)
      url="https://github.com/${url#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      url="https://github.com/${url#ssh://git@github.com/}"
      ;;
  esac
  url="${url%.git}"
  echo "${url}.git"
}

detect_repo_url() {
  if [[ -n "${ARGOCD_REPO_URL:-}" ]]; then
    normalize_repo_url "$ARGOCD_REPO_URL"
    return
  fi
  if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Not a git repo. Set ARGOCD_REPO_URL=https://github.com/ORG/REPO.git" >&2
    exit 1
  fi
  normalize_repo_url "$(git -C "$REPO_ROOT" remote get-url origin)"
}

detect_branch() {
  if [[ -n "${ARGOCD_TARGET_REVISION:-}" ]]; then
    echo "$ARGOCD_TARGET_REVISION"
    return
  fi
  git -C "$REPO_ROOT" branch --show-current
}

detect_github_token() {
  if [[ -n "${ARGOCD_GITHUB_TOKEN:-}" ]]; then
    echo "$ARGOCD_GITHUB_TOKEN"
    return
  fi
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    echo "$GITHUB_TOKEN"
    return
  fi
  if command -v gh &>/dev/null; then
    gh auth token 2>/dev/null || true
  fi
}

repo_url="$(detect_repo_url)"
branch="$(detect_branch)"
token="$(detect_github_token)"

if [[ -z "$branch" ]]; then
  echo "Could not detect branch. Set ARGOCD_TARGET_REVISION=your-branch" >&2
  exit 1
fi

if ! kubectl -n "$NAMESPACE" get deployment argocd-server &>/dev/null; then
  echo "ArgoCD not installed. Run:"
  echo "  kubectl create namespace argocd"
  echo "  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
  echo "  kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s"
  exit 1
fi

echo "=== ArgoCD GitHub connect ==="
echo "  repo:   ${repo_url}"
echo "  branch: ${branch}"
echo "  path:   ${SOURCE_PATH}"
echo ""

kubectl apply -f "${REPO_ROOT}/config/argocd/namespace.yaml"

if [[ -n "$token" ]]; then
  secret_name="repo-$(echo "$repo_url" | sed -E 's|https?://||; s|/|.|g; s|\.git$||')"
  echo "Registering GitHub credentials (private repo or rate limits)..."
  kubectl -n "$NAMESPACE" create secret generic "$secret_name" \
    --from-literal=type=git \
    --from-literal=url="$repo_url" \
    --from-literal=username=git \
    --from-literal=password="$token" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$NAMESPACE" label secret "$secret_name" \
    argocd.argoproj.io/secret-type=repository --overwrite
else
  echo "No GitHub token found (public repo is fine)."
  echo "For a private repo, export ARGOCD_GITHUB_TOKEN or run: gh auth login"
fi

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    fidelity.ai/pr: "104"
spec:
  project: default
  source:
    repoURL: ${repo_url}
    targetRevision: ${branch}
    path: ${SOURCE_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${DEST_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

echo ""
echo "Application ${APP_NAME} applied."
echo ""
echo "Next:"
echo "  ./scripts/argocd-login.sh"
echo "  argocd app get ${APP_NAME}"
echo "  argocd app sync ${APP_NAME}   # after fixing kustomize overlay if needed"
echo ""
echo "Override repo/branch without editing files:"
echo "  ARGOCD_REPO_URL=https://github.com/you/repo.git ARGOCD_TARGET_REVISION=main ./scripts/argocd-connect-github.sh"
