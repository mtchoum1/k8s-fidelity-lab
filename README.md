# k8s-fidelity-lab

This project demonstrates **Kubernetes testing fidelity** using a single Pull Request that flows through seven validation tiers. Each tier catches bugs the previous tier cannot see.

## The Change Under Test

**PR #104: feat: Add high-throughput GPU batch inference & metrics sidecar**

What the developer modified:

| Area | Change |
|------|--------|
| **CRD API** (`api/v1alpha1/`) | Added `spec.gpuMemoryRequirement` and `spec.sidecarLogging: true` |
| **Controller** (`controllers/`) | Injects a metrics sidecar container; dynamically scales replicas by GPU tier |
| **GitOps** (`config/overlays/pr104/`) | Kustomize overlay with RHOAI `InferenceService` annotations |
| **RHOAI** (`rhoai/`) | KServe `InferenceService` bridge for the sidecar-enabled pipeline |
| **Sidecar** (`Dockerfile.sidecar`) | New metrics/logging sidecar image |

```
[PR #104 Submitted]
       │
       ├── Tier 1 (envtest) ───► Go logic & CRD schema     → missing +optional on gpuMemoryRequirement
       ├── Tier 2 (KWOK) ──────► Scale at 500 pods         → reconciler queue starvation
       ├── Tier 3 (kind) ──────► Sidecar container runtime → SIDECAR_LOG_DIR env var missing
       ├── Tier 4 (Tilt) ──────► Inner-loop velocity       → hot-reload fix in ~2 seconds
       ├── Tier 5 (RHOAI) ─────► MLOps integration        → KServe apiVersion v1beta1 conflict
       ├── Tier 6 (ArgoCD) ────► GitOps sync              → malformed Kustomize patch path
       └── Tier 7 (OpenShift) ─► Enterprise runtime        → SCC blocks root sidecar on /var/log
                                                    │
                                       [100% Production Confidence]
```

## Repository Structure

```
k8s-fidelity-lab/
├── api/v1alpha1/               # CRD types (PR #104 fields)
├── controllers/                # Reconcile loop + sidecar injection
├── config/
│   ├── base/                   # Base ModelInferencePipeline manifest
│   ├── overlays/pr104/         # GitOps overlay (Tier 6 — intentional Kustomize bug)
│   ├── crd/                    # Generated CRD manifests
│   ├── samples/                # Per-tier sample CRs
│   └── argocd/                 # ArgoCD Application for PR #104 overlay
├── sidecar_entrypoint.sh       # Metrics sidecar (Tier 3 env-var bug)
├── Dockerfile.sidecar
├── kwok/                       # Fake nodes for scale testing
├── rhoai/                      # KServe InferenceService (Tier 5 apiVersion bug)
├── scripts/                    # Tier runner scripts
├── Tiltfile                    # Tier 4 hot-reload
└── metrics-log.csv             # Benchmarking scorecard
```

## Prerequisites

- Go 1.22+
- [Podman](https://podman.io/getting-started/installation)
- [uv](https://docs.astral.sh/uv/) (Python venv for local inference server)
- `kubectl`
- Optional per tier: [envtest](https://book.kubebuilder.io/reference/envtest), [KWOK](https://kwok.sigs.k8s.io/), [kind](https://kind.sigs.k8s.io/), [Tilt](https://tilt.dev/), [ArgoCD](https://argo-cd.readthedocs.io/), OpenShift CLI (`oc`)

```bash
go mod download
chmod +x scripts/*.sh kwok/generate-nodes.sh

make uv-sync
source .venv/bin/activate
python inference_server.py
```

On macOS: `podman machine start`

## Step 0: Fork or Branch (preserve the intentional bugs)

**Do this first.** Each tier ends with fixing one deliberate bug from PR #104. If you commit fixes on `main`, you lose the broken baseline.

```bash
# Fork on GitHub, or branch locally:
git checkout -b broken-baseline    # frozen PR #104 bugs — never commit fixes here
git checkout -b lab/$(whoami)    # your working branch for tier fixes
```

## Tier-by-Tier Breakdown

### Tier 1 — envtest (API & Unit Test)

**Run:** `./scripts/run-envtest.sh`

**Testing:** Is `spec.gpuMemoryRequirement` defined correctly in Go and OpenAPI?

**Passes:** `go test ./controllers/... -v` validates schema and controller logic.

**Bug caught:** Missing `// +optional` on `GPUMemoryRequirement` — envtest rejects CRs that omit the GPU field. Controller also nil-pointer panics on unregistered GPU tiers (e.g. `"8Gi"`).

### Tier 2 — KWOK (Scale Simulation)

**Run:** `./scripts/run-kwok.sh`

**Testing:** 100 users each create a pipeline with 5 replicas (500 pods total).

**Passes:** KWOK schedules 500 fake pods across 100 fake nodes in seconds.

**Bug caught:** Controller holds a global lock and polls pod statuses sequentially, starving the reconcile worker pool.

### Tier 3 — kind (Real Container Runtime)

**Run:** `./scripts/run-kind.sh`

**Testing:** Does the metrics sidecar image pull, start, and mount volumes?

**Passes:** Kubelet schedules the pod and sets up networking.

**Bug caught:** Sidecar `CrashLoopBackOff` — `SIDECAR_LOG_DIR` env var missing from the controller's Pod template.

### Tier 4 — Tilt (Inner-Loop Iteration)

**Run:** `./scripts/tilt-up.sh` (after Tier 3 kind cluster exists)

**Testing:** Fix the Tier 3 missing env var without a full cluster rebuild.

**Passes:** Tilt hot-reloads the controller binary or sidecar script in ~2 seconds after Ctrl+S.

### Tier 5 — rhoai-in-kind (MLOps Platform Integration)

**Run:** `./scripts/run-rhoai-in-kind.sh`

**Testing:** Does the sidecar hook into RHOAI's KServe control plane?

**Passes:** Operator creates an `InferenceService` managed by OpenDataHub.

**Bug caught:** `rhoai/inferenceservice-v1beta1.yaml` uses `serving.kserve.io/v1beta1` — conflicts with the installed RHOAI operator (expects `v1`).

### Tier 6 — ArgoCD (GitOps Deployment)

**Run:** Install ArgoCD; apply `config/argocd/application.yaml` (update `repoURL`).

**Testing:** Can PR #104 deploy declaratively from Git?

**Passes:** ArgoCD syncs the `config/overlays/pr104` path.

**Bug caught:** `config/overlays/pr104/sidecar-patch.yaml` has typo path `/spec/sidecarLoging` — Kustomize build fails with `SyncFailed`.

Verify locally: `kubectl kustomize config/overlays/pr104` (expect error).

### Tier 7 — OpenShift (Production Environment)

**Run:** `oc apply -f config/samples/modelpipeline_v1alpha1_openshift-root.yaml`

**Testing:** Sidecar under production SCCs, routes, and real hardware.

**Bug caught:** Sidecar runs as root (`runAsUser: 0`) and mounts `/var/log` — OpenShift `restricted-v2` SCC blocks pod start (`CreateContainerConfigError`).

**Final fix:** Inject `securityContext.runAsNonRoot: true`, set `SIDECAR_LOG_DIR`, and use an `emptyDir` volume for logs. Re-run Tier 7 for 100% confidence.

## Local Measurement Scorecard

| Tier | Tool | Confidence | Issues Caught |
|------|------|------------|---------------|
| 1 | envtest | 20% | Missing +optional; nil pointer on GPU tier |
| 2 | KWOK | 40% | Reconciler queue starvation at 500 pods |
| 3 | kind | 65% | Sidecar missing SIDECAR_LOG_DIR |
| 4 | tilt | 65% | Hot-reload velocity (~2 s) |
| 5 | rhoai-in-kind | 80% | KServe v1beta1 apiVersion conflict |
| 6 | argocd | 90% | Malformed Kustomize sidecarLogging patch |
| 7 | OpenShift | 100% | SCC root UID 0 on /var/log mount |

Log timings in `metrics-log.csv`:

```bash
./scripts/measure.sh "go test ./controllers/... -v"
./scripts/measure.sh "./scripts/run-kind.sh"
```

## Fixing Each Intentional Bug (on your working branch only)

1. **Tier 1:** Add `// +optional` to `GPUMemoryRequirement`; register all GPU tiers in `gpuMemoryScaleFactors`; run `make manifests`.
2. **Tier 2:** Remove `podStatusPollLock` and sequential `waitForPodStatuses` polling.
3. **Tier 3:** Set `SIDECAR_LOG_DIR=/var/log/sidecar` in `buildSidecarContainer`.
4. **Tier 4:** No code fix — measure iteration time with Tilt after Tier 3 fix.
5. **Tier 5:** Change `apiVersion` to `serving.kserve.io/v1` in `rhoai/inferenceservice-v1beta1.yaml`.
6. **Tier 6:** Fix patch path to `/spec/sidecarLogging` in `config/overlays/pr104/sidecar-patch.yaml`.
7. **Tier 7:** Replace `hostPath /var/log` + `runAsUser: 0` with `emptyDir` volume and `runAsNonRoot: true`.

## Quick Reference

```bash
git checkout -b lab/$(whoami)          # Step 0
make test                              # Tier 1
./scripts/run-kwok.sh                  # Tier 2 (100 × 5 = 500 pods)
./scripts/run-kind.sh                  # Tier 3
./scripts/tilt-up.sh                   # Tier 4
./scripts/run-rhoai-in-kind.sh         # Tier 5
kubectl apply -f config/argocd/        # Tier 6
oc apply -f config/samples/modelpipeline_v1alpha1_openshift-root.yaml  # Tier 7

make podman-build                      # Operator image
make podman-build-inference            # Inference server image
make podman-build-sidecar              # Metrics sidecar image
```
