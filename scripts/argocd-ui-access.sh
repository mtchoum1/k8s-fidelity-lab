#!/usr/bin/env bash
# Open ArgoCD web UI on kind: enable HTTP (server.insecure) and print login details.
set -euo pipefail

NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
LOCAL_PORT="${ARGOCD_UI_PORT:-8080}"
USERNAME="admin"

if ! kubectl -n "$NAMESPACE" get deployment argocd-server &>/dev/null; then
  echo "ArgoCD not installed in namespace ${NAMESPACE}."
  exit 1
fi

# HTTP on port 80 avoids browser TLS/cookie issues with port-forwarded HTTPS.
if ! kubectl -n "$NAMESPACE" get configmap argocd-cmd-params-cm -o jsonpath='{.data.server\.insecure}' 2>/dev/null | grep -q '^true$'; then
  echo "Enabling server.insecure (HTTP UI for local port-forward)..."
  kubectl -n "$NAMESPACE" patch configmap argocd-cmd-params-cm --type merge \
    -p '{"data":{"server.insecure":"true"}}'
  kubectl -n "$NAMESPACE" rollout restart deployment/argocd-server
  kubectl -n "$NAMESPACE" rollout status deployment/argocd-server --timeout=120s
fi

if kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret &>/dev/null; then
  PASSWORD="$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"
else
  echo "Initial admin secret missing — set a known password (e.g. admin):"
  echo "  argocd account bcrypt --password 'admin'   # then patch argocd-secret"
  exit 1
fi

if command -v pbcopy &>/dev/null; then
  printf '%s' "$PASSWORD" | pbcopy
  CLIP=" (copied to clipboard)"
else
  CLIP=""
fi

echo ""
echo "=== ArgoCD web UI ==="
echo "  1. In another terminal (or background), run:"
echo "       kubectl port-forward svc/argocd-server -n ${NAMESPACE} ${LOCAL_PORT}:80"
echo "  2. Open:  http://localhost:${LOCAL_PORT}"
echo "  3. Username:  ${USERNAME}   (not adminuser)"
echo "  4. Password:  ${PASSWORD}${CLIP}"
echo ""
echo "If login still fails, reset admin password:"
echo "  ./scripts/argocd-reset-admin.sh"
echo ""
