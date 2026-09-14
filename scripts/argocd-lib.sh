#!/usr/bin/env bash
# Shared ArgoCD helpers for Tier 6 automation.
set -euo pipefail

: "${LAB_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-fidelity-lab-pr104}"
ARGOCD_UI_PORT="${ARGOCD_UI_PORT:-9090}"
ARGOCD_TIER6_PATCH="${ARGOCD_TIER6_PATCH:-config/overlays/pr104/sidecar-patch.yaml}"
ARGOCD_DEST_NAMESPACE="${ARGOCD_DEST_NAMESPACE:-default}"
ARGOCD_MIP_NAME="${ARGOCD_MIP_NAME:-pr104-gpu-batch-pipeline}"
ARGOCD_PF_PID=""

lab_argocd_require_cli() {
  if ! command -v argocd &>/dev/null; then
    lab_tier_fail "argocd CLI not found — install with: brew install argocd"
  fi
}

lab_argocd_admin_password() {
  if [[ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]]; then
    printf '%s' "$ARGOCD_ADMIN_PASSWORD"
    return 0
  fi
  kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d
}

lab_argocd_configure_local_ui() {
  local ui_url="http://127.0.0.1:${ARGOCD_UI_PORT}"

  echo "Configuring ArgoCD for local HTTP UI at ${ui_url} ..."
  kubectl -n "$ARGOCD_NAMESPACE" patch configmap argocd-cmd-params-cm --type merge \
    -p '{"data":{"server.insecure":"true"}}'
  kubectl -n "$ARGOCD_NAMESPACE" patch configmap argocd-cm --type merge \
    -p "$(printf '{"data":{"url":"%s"}}' "$ui_url")"

  kubectl -n "$ARGOCD_NAMESPACE" rollout restart deployment/argocd-server
  kubectl -n "$ARGOCD_NAMESPACE" rollout status deployment/argocd-server --timeout=120s
}

lab_argocd_ensure_port_forward() {
  if [[ -n "${ARGOCD_PF_PID:-}" ]] && kill -0 "$ARGOCD_PF_PID" 2>/dev/null \
    && curl -sf "http://127.0.0.1:${ARGOCD_UI_PORT}/healthz" &>/dev/null; then
    return 0
  fi

  lab_argocd_stop_port_forward
  lab_argocd_start_port_forward
}

lab_argocd_start_port_forward() {
  local log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/argocd-pf-XXXXXX")"
  log_file="${log_file}.log"

  echo "Starting ArgoCD UI port-forward on http://127.0.0.1:${ARGOCD_UI_PORT} ..."
  kubectl port-forward "svc/argocd-server" -n "$ARGOCD_NAMESPACE" \
    "${ARGOCD_UI_PORT}:80" >"$log_file" 2>&1 &
  ARGOCD_PF_PID=$!

  for _ in $(seq 1 40); do
    if curl -sf "http://127.0.0.1:${ARGOCD_UI_PORT}/healthz" &>/dev/null; then
      return 0
    fi
    if ! kill -0 "$ARGOCD_PF_PID" 2>/dev/null; then
      echo "Port-forward exited. Log:"
      cat "$log_file"
      lab_tier_fail "ArgoCD port-forward failed — check argocd-server pods"
    fi
    sleep 0.5
  done

  echo "Port-forward log:"
  cat "$log_file"
  lab_tier_fail "ArgoCD UI not reachable on http://127.0.0.1:${ARGOCD_UI_PORT}"
}

lab_argocd_stop_port_forward() {
  if [[ -n "${ARGOCD_PF_PID:-}" ]] && kill -0 "$ARGOCD_PF_PID" 2>/dev/null; then
    kill "$ARGOCD_PF_PID" 2>/dev/null || true
    wait "$ARGOCD_PF_PID" 2>/dev/null || true
  fi
  ARGOCD_PF_PID=""
}

lab_argocd_cli_login() {
  local password login_args
  password="$(lab_argocd_admin_password)"

  lab_argocd_ensure_port_forward

  login_args=(
    --username admin
    --password "$password"
    --plaintext
    --grpc-web
    --skip-test-tls
  )

  echo "Logging in to ArgoCD CLI as admin..."
  if argocd login "127.0.0.1:${ARGOCD_UI_PORT}" "${login_args[@]}"; then
    :
  else
    echo "Initial admin login failed — resetting password to '${ARGOCD_ADMIN_PASSWORD:-admin}'..."
    ARGOCD_ADMIN_PASSWORD="${ARGOCD_ADMIN_PASSWORD:-admin}"
    BCRYPT="$(argocd account bcrypt --password "$ARGOCD_ADMIN_PASSWORD")"
    MTIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    kubectl -n "$ARGOCD_NAMESPACE" patch secret argocd-secret --type merge -p \
      "{\"stringData\":{\"admin.password\":\"${BCRYPT}\",\"admin.passwordMtime\":\"${MTIME}\"}}"
    sleep 5
    lab_argocd_ensure_port_forward
    password="$ARGOCD_ADMIN_PASSWORD"
    login_args=(
      --username admin
      --password "$password"
      --plaintext
      --grpc-web
      --skip-test-tls
    )
    argocd login "127.0.0.1:${ARGOCD_UI_PORT}" "${login_args[@]}"
  fi

  if command -v pbcopy &>/dev/null; then
    printf '%s' "$password" | pbcopy
    echo "  Admin password copied to clipboard."
  fi
}

lab_argocd_open_ui() {
  [[ "${ARGOCD_SKIP_UI:-}" == "1" ]] && return 0

  lab_argocd_ensure_port_forward

  local url="http://127.0.0.1:${ARGOCD_UI_PORT}"
  echo "ArgoCD UI: ${url}  (username: admin, use http not https)"
  echo "  If the browser shows CORS errors, hard-refresh or open a private window at the URL above."

  case "$(uname -s)" in
    Darwin) open "$url" ;;
    Linux)
      if command -v xdg-open &>/dev/null; then
        xdg-open "$url" >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

lab_argocd_ensure_tier6_fix_pushed() {
  if [[ "${ARGOCD_SKIP_GIT:-}" == "1" ]]; then
    echo "ARGOCD_SKIP_GIT=1 — skipping git commit/push"
    return 0
  fi

  if ! git -C "$LAB_ROOT" rev-parse --is-inside-work-tree &>/dev/null; then
    lab_tier_fail "not a git repository — ArgoCD sync requires the Tier 6 fix on GitHub"
  fi

  local branch
  branch="$(git -C "$LAB_ROOT" branch --show-current 2>/dev/null || true)"
  if [[ -z "$branch" ]]; then
    lab_tier_fail "detached HEAD — checkout a branch (e.g. lab/\$(whoami)) before Tier 6"
  fi

  if ! git -C "$LAB_ROOT" diff --quiet -- "$ARGOCD_TIER6_PATCH" 2>/dev/null \
    || ! git -C "$LAB_ROOT" diff --cached --quiet -- "$ARGOCD_TIER6_PATCH" 2>/dev/null; then
    echo "Committing Tier 6 fix: ${ARGOCD_TIER6_PATCH}"
    git -C "$LAB_ROOT" add "$ARGOCD_TIER6_PATCH"
    git -C "$LAB_ROOT" commit -m "$(cat <<'EOF'
fix(tier6): correct sidecarLogging kustomize patch path

ArgoCD sync requires the fixed overlay on the remote branch.
EOF
)"
  else
    echo "Tier 6 patch already committed locally."
  fi

  echo "Pushing to origin/${branch} (ArgoCD reads from GitHub)..."
  if ! git -C "$LAB_ROOT" push -u origin "HEAD:refs/heads/${branch}"; then
    lab_tier_fail "git push failed — push ${ARGOCD_TIER6_PATCH} manually, then re-run ./lab run 6"
  fi
}

lab_argocd_sync_and_wait() {
  echo ""
  echo "Refreshing and syncing Application ${ARGOCD_APP_NAME}..."
  argocd app get "$ARGOCD_APP_NAME" --refresh hard >/dev/null 2>&1 || \
    argocd app get "$ARGOCD_APP_NAME" --refresh >/dev/null 2>&1 || true
  sleep 3

  set +e
  SYNC_OUTPUT="$(argocd app sync "$ARGOCD_APP_NAME" --force --prune --timeout 300 2>&1)"
  SYNC_RC=$?
  set -e
  echo "$SYNC_OUTPUT"
  if [[ "$SYNC_RC" -ne 0 ]]; then
    argocd app get "$ARGOCD_APP_NAME" || true
    lab_tier_fail "argocd app sync failed — check repo branch and kustomize overlay on GitHub"
  fi

  echo "Waiting for Application to become Synced and Healthy..."
  if ! argocd app wait "$ARGOCD_APP_NAME" --sync --health --timeout 300; then
    echo ""
    argocd app get "$ARGOCD_APP_NAME" || true
    lab_tier_fail "ArgoCD Application did not reach Synced/Healthy within 300s"
  fi
}

lab_argocd_verify_cluster_resources() {
  echo ""
  echo "Verifying synced resources in cluster..."

  if ! kubectl get crd modelinferencepipelines.fidelity.ai &>/dev/null; then
    lab_tier_fail "ModelInferencePipeline CRD missing — apply config/crd/bases/ before sync"
  fi

  if ! kubectl -n "$ARGOCD_DEST_NAMESPACE" get modelinferencepipeline "$ARGOCD_MIP_NAME" &>/dev/null; then
    echo "Resources in ${ARGOCD_DEST_NAMESPACE}:"
    kubectl -n "$ARGOCD_DEST_NAMESPACE" get modelinferencepipelines 2>/dev/null || true
    lab_tier_fail "ModelInferencePipeline/${ARGOCD_MIP_NAME} not found after ArgoCD sync"
  fi

  local sidecar_logging
  sidecar_logging="$(kubectl -n "$ARGOCD_DEST_NAMESPACE" get modelinferencepipeline "$ARGOCD_MIP_NAME" \
    -o jsonpath='{.spec.sidecarLogging}' 2>/dev/null || true)"
  if [[ "$sidecar_logging" != "true" ]]; then
    lab_tier_fail "ModelInferencePipeline sidecarLogging=${sidecar_logging:-<unset>} — overlay patch may not have applied"
  fi

  local sync_status health_status
  sync_status="$(argocd app get "$ARGOCD_APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health_status="$(argocd app get "$ARGOCD_APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  echo "  ArgoCD sync:   ${sync_status:-unknown}"
  echo "  ArgoCD health: ${health_status:-unknown}"
  echo "  CR:            ModelInferencePipeline/${ARGOCD_MIP_NAME} (sidecarLogging=true)"
}
