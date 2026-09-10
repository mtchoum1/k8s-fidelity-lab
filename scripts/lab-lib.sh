#!/usr/bin/env bash
# Shared helpers for the k8s-fidelity-lab CLI.
set -euo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LAB_SCENARIO="${LAB_SCENARIO:-pr104}"
export LAB_BASELINE_REF="${LAB_BASELINE_REF:-main}"
LAB_STATE_DIR="${LAB_ROOT}/.lab"
LAB_RUN_LOG="${LAB_STATE_DIR}/runs.log"

lab_ensure_state_dir() {
  mkdir -p "$LAB_STATE_DIR"
}

lab_log_run() {
  local tier="$1"
  local status="$2"
  lab_ensure_state_dir
  echo "$(date -Iseconds) tier=${tier} status=${status} scenario=${LAB_SCENARIO}" >> "$LAB_RUN_LOG"
}

lab_usage() {
  cat <<EOF
Usage: ./lab <command> [args]

Commands:
  run <tier>    Run a fidelity tier (1-7, or 'all' for automated checks only)
  verify        Confirm intentional bugs are still present (baseline integrity)
  reset         Restore scenario files from baseline ref (${LAB_BASELINE_REF})
  status        Show scenario, baseline integrity, and recent runs
  hint <tier>   Show symptom description without the full fix

Environment:
  LAB_SCENARIO       Active scenario (default: pr104)
  LAB_BASELINE_REF   Git ref to reset/verify against (default: main)

Examples:
  ./lab verify
  ./lab run 1
  ./lab run 3
  make lab-reset
EOF
}

lab_hint() {
  local tier="${1:-}"
  case "$tier" in
    1) echo "Symptom: CRs without gpuMemoryRequirement are rejected; controller panics on unknown GPU tiers like 8Gi." ;;
    2) echo "Symptom: Controller logs show requeue loops; pipelines never reach Running under 100×5 load." ;;
    3) echo "Symptom: metrics-sidecar container CrashLoopBackOff; logs show SIDECAR_LOG_DIR is required." ;;
    4) echo "Symptom: N/A — measure hot-reload time after applying the Tier 3 fix via Tilt." ;;
    5) echo "Symptom: InferenceService apply fails; CRD apiVersion serving.kserve.io/v1beta1 not served." ;;
    6) echo "Symptom: kubectl kustomize config/overlays/pr104 fails; ArgoCD reports SyncFailed." ;;
    7) echo "Symptom: Pod CreateContainerConfigError; SCC denies root sidecar mounting /var/log." ;;
    *) lab_usage; return 1 ;;
  esac
}

lab_run_tier() {
  local tier="$1"
  cd "$LAB_ROOT"

  case "$tier" in
    1)
      echo "=== Tier 1: envtest ==="
      ./scripts/run-envtest.sh
      ;;
    2)
      echo "=== Tier 2: KWOK scale ==="
      ./scripts/run-kwok.sh
      ;;
    3)
      echo "=== Tier 3: kind + sidecar runtime ==="
      ./scripts/run-kind.sh
      ;;
    4)
      echo "=== Tier 4: Tilt inner loop ==="
      ./scripts/tilt-up.sh
      ;;
    5)
      echo "=== Tier 5: rhoai-in-kind ==="
      ./scripts/run-rhoai-in-kind.sh
      ;;
    6)
      echo "=== Tier 6: GitOps / Kustomize ==="
      echo "Expect kustomize build to FAIL on the broken baseline:"
      if kubectl kustomize config/overlays/pr104; then
        echo "ERROR: overlay built successfully — Tier 6 bug may already be fixed."
        return 1
      fi
      echo ""
      echo "Next: install ArgoCD and apply config/argocd/application.yaml (update repoURL)."
      echo "  kubectl apply -f config/argocd/namespace.yaml"
      echo "  kubectl apply -f config/argocd/application.yaml"
      ;;
    7)
      echo "=== Tier 7: OpenShift production ==="
      if ! command -v oc &>/dev/null; then
        echo "oc CLI not found. Apply manually on OpenShift:"
        echo "  oc apply -f config/samples/modelpipeline_v1alpha1_openshift-root.yaml"
        echo "Expect CreateContainerConfigError from restricted-v2 SCC."
        return 0
      fi
      echo "Applying PR #104 OpenShift sample (expect SCC failure on baseline)..."
      oc apply -f config/samples/modelpipeline_v1alpha1_openshift-root.yaml
      echo "Watch: oc get pods -w"
      ;;
    all)
      echo "=== Running lab-verify (all tier integrity checks) ==="
      ./scripts/lab-verify.sh
      echo ""
      echo "Interactive tiers 2-7 require cluster tooling. Run individually:"
      echo "  ./lab run 1   # envtest"
      echo "  ./lab run 2   # KWOK"
      echo "  ./lab run 3   # kind"
      ;;
    *)
      echo "Unknown tier: ${tier}"
      lab_usage
      return 1
      ;;
  esac
}

lab_status() {
  cd "$LAB_ROOT"
  lab_ensure_state_dir

  echo "Scenario:      ${LAB_SCENARIO}"
  echo "Baseline ref:  ${LAB_BASELINE_REF}"
  echo ""

  if ./scripts/lab-verify.sh >/dev/null 2>&1; then
    echo "Integrity:     OK — intentional bugs are present"
  else
    echo "Integrity:     MODIFIED — run: ./lab reset  (or: make lab-reset)"
  fi

  if [[ -f "$LAB_RUN_LOG" ]]; then
    echo ""
    echo "Recent runs:"
    tail -5 "$LAB_RUN_LOG"
  else
    echo ""
    echo "Recent runs:   (none — run ./lab run <tier>)"
  fi
}
