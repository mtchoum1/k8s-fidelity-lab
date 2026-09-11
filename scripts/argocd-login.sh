#!/usr/bin/env bash
# Log in to ArgoCD via CLI (use when UI login or port-forward is awkward).
set -euo pipefail

NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
LOCAL_PORT="${ARGOCD_LOCAL_PORT:-8443}"
USERNAME="${ARGOCD_USERNAME:-admin}"

if ! command -v argocd &>/dev/null; then
  echo "argocd CLI not found. Install: https://argo-cd.readthedocs.io/en/stable/cli_installation/"
  exit 1
fi

if ! kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret &>/dev/null; then
  echo "ArgoCD not installed. Install first:"
  echo "  kubectl create namespace argocd"
  echo "  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
  exit 1
fi

PASSWORD="$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"

echo "Port-forwarding argocd-server to localhost:${LOCAL_PORT} (Ctrl+C stops)..."
kubectl port-forward "svc/argocd-server" -n "$NAMESPACE" "${LOCAL_PORT}:443" >/tmp/argocd-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT INT TERM

for _ in $(seq 1 20); do
  if curl -ks "https://localhost:${LOCAL_PORT}/healthz" &>/dev/null; then
    break
  fi
  sleep 0.5
done

echo "Logging in as ${USERNAME}..."
argocd login "localhost:${LOCAL_PORT}" \
  --username "$USERNAME" \
  --password "$PASSWORD" \
  --insecure \
  --grpc-web

echo ""
echo "Logged in. Examples:"
echo "  argocd app list"
echo "  argocd app get fidelity-lab-pr104"
echo "  argocd app sync fidelity-lab-pr104"
echo ""
echo "Port-forward running (pid ${PF_PID}). Leave this terminal open or run port-forward separately:"
echo "  kubectl port-forward svc/argocd-server -n ${NAMESPACE} ${LOCAL_PORT}:443"

wait "$PF_PID"
