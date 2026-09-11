#!/usr/bin/env bash
# Reset ArgoCD admin password to a known value (lab troubleshooting).
set -euo pipefail

NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
NEW_PASSWORD="${ARGOCD_ADMIN_PASSWORD:-admin}"

if ! command -v argocd &>/dev/null; then
  echo "argocd CLI required: brew install argocd"
  exit 1
fi

BCRYPT="$(argocd account bcrypt --password "$NEW_PASSWORD")"
MTIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

kubectl -n "$NAMESPACE" patch secret argocd-secret --type merge -p \
  "{\"stringData\":{\"admin.password\":\"${BCRYPT}\",\"admin.passwordMtime\":\"${MTIME}\"}}"

echo "Admin password reset."
echo "  Username: admin"
echo "  Password: ${NEW_PASSWORD}"
echo ""
echo "Then use the UI: ./scripts/argocd-ui-access.sh"
