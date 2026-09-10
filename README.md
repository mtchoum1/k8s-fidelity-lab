# k8s-fidelity-lab

This project uses a single Kubernetes Operator + Custom Resource Definition (CRD) called **ModelInferencePipeline**. As you push a feature or change through each tier, the change will pass lower levels but reveal subtle real-world failure modes (like root user restrictions or route syntax) as you climb to higher fidelity tiers.

## Repository Structure

```
k8s-fidelity-lab/
├── README.md                   # Instructions & benchmarking scorecard template
├── api/v1alpha1/               # CRD definition for ModelInferencePipeline
│   └── modelpipeline_types.go
├── controllers/                # Go Operator controller logic
│   └── modelpipeline_controller.go
├── config/
│   ├── crd/                    # Generated CRD manifests
│   ├── samples/                # Sample CRD instances to apply
│   └── argocd/                 # ArgoCD Application manifests
├── Tiltfile                    # Tilt configuration for local live updates
├── kwok/                       # KWOK cluster & fake node manifests
├── rhoai/                      # RHOAI / OpenDataHub CRD integration specs
├── scripts/                    # Helper scripts to run tests & measure resources
│   ├── measure.sh              # Script using `time` and `ps`/`podman stats`
│   ├── container.sh            # Podman build + kind image-load helpers
│   └── tilt-up.sh              # Start Tilt with Podman socket configured
│   ├── run-envtest.sh
│   ├── run-kwok.sh
│   └── run-kind.sh
└── metrics-log.csv             # Template to log your benchmarking results
```

## Demo Workload Scenario

The operator deploys an AI model inference service with **4 intentional edge-case bugs**:

| Bug | Caught At | Description |
|-----|-----------|-------------|
| **Schema Bug** | Tier 1 (envtest) | `gpuCount` is `int32` in Go but `type: string` in the CRD OpenAPI schema |
| **Scale Reconciliation Bug** | Tier 2 (KWOK) | Global reconcile barrier deadlocks under 500+ pipelines |
| **Container Runtime Bug** | Tier 3 (kind) | Missing `torch` dependency / broken default entrypoint |
| **OpenShift Security Bug** | Tier 7 (OpenShift) | `runAsRoot: true` violates `restricted-v2` SCC |

## Prerequisites

- Go 1.22+
- [Podman](https://podman.io/getting-started/installation) (container builds and kind node provider)
- [uv](https://docs.astral.sh/uv/) (Python venv for the inference server)
- `kubectl`
- Optional per tier: [envtest binaries](https://book.kubebuilder.io/reference/envtest), [KWOK](https://kwok.sigs.k8s.io/), [kind](https://kind.sigs.k8s.io/), [Tilt](https://tilt.dev/), [ArgoCD](https://argo-cd.readthedocs.io/), OpenShift CLI (`oc`)

```bash
go mod download
chmod +x scripts/*.sh kwok/generate-nodes.sh

# Python inference server (local dev with all dependencies, including torch)
make uv-sync
source .venv/bin/activate
python inference_server.py
```

On macOS, start the Podman machine before building images:

```bash
podman machine start
```

## Sequential Step-by-Step Execution Plan

### Stage 1: Unit & API Logic (envtest)

**Run:** `./scripts/run-envtest.sh` or `go test ./controllers/... -v`

Boots a standalone kube-apiserver and etcd locally without Docker or Kubelets.

| Measure | What to Record |
|---------|----------------|
| Time | Seconds to complete tests |
| Resource | RAM consumed by etcd + kube-apiserver |
| Confidence | **15–20%** — validates CRD schema and Go controller logic |

**Fails to catch:** Real Pod containers or image existence.

### Stage 2: Controller Scale Testing (KWOK)

**Run:** `./scripts/run-kwok.sh`

Creates fake nodes and applies 500 `ModelInferencePipeline` CRs.

| Measure | What to Record |
|---------|----------------|
| Time | Cluster spin-up + reconcile of 500 CRs |
| Resource | RAM of kwok process vs Podman |
| Confidence | **35–45%** — proves controller won't choke under API load |

**Fails to catch:** Container images are never pulled or executed.

### Stage 3: Real Container Runtime (kind)

**Run:** `./scripts/run-kind.sh`

Runs real Kubelets with Podman as the container runtime (`KIND_EXPERIMENTAL_PROVIDER=podman`).

| Measure | What to Record |
|---------|----------------|
| Time | Image build, load into kind, reach Running state |
| Resource | Podman CPU/RAM (typically 2–4 GB) |
| Confidence | **60–70%** — validates image pulls, entrypoints, DNS |

**Fails to catch:** OpenShift SCC policies and OpenShift-specific CRDs.

### Stage 4: Inner-Loop Live Updates (tilt)

**Run:** `./scripts/tilt-up.sh` (after Stage 3 kind cluster is running)

Watches local Go code and Containerfiles for live reload via Podman.

| Measure | What to Record |
|---------|----------------|
| Time | Ctrl+S → updated logs in Tilt dashboard (aim for < 3 s) |
| Resource | Tilt file-watcher overhead |
| Confidence | **65–70%** — same as kind, 10× faster iteration |

### Stage 5: MLOps Integration (rhoai-in-kind)

**Run:** `./scripts/run-rhoai-in-kind.sh`

Installs ODH operator dependencies into kind.

| Measure | What to Record |
|---------|----------------|
| Time | Operator initialization (5–10 min) |
| Resource | Podman memory (8–12 GB typical) |
| Confidence | **80–85%** — validates MLOps control plane integration |

### Stage 6: Declarative Sync & Drift (argocd)

**Run:** Install ArgoCD and apply `config/argocd/application.yaml` (update `repoURL` first).

| Measure | What to Record |
|---------|----------------|
| Time | Git push → ArgoCD sync |
| Resource | ArgoCD controller pod (~1 GB RAM) |
| Confidence | **90%** — proves manifests render cleanly via GitOps |

### Stage 7: Full Production Environment (OpenShift)

**Run:** `oc apply -f config/samples/modelpipeline_v1alpha1_openshift-root.yaml`

| Measure | What to Record |
|---------|----------------|
| Time | Full CI/CD pipeline (10–30 min) |
| Resource | Cloud node cost |
| Confidence | **100%** after fixing `SecurityContext` |

**The catch:** OpenShift `restricted-v2` SCC blocks root containers (`runAsUser: 0`). Fix `runAsRoot` in the spec and add a non-root `SecurityContext` in the controller.

## Local Measurement Scorecard

Log your manual measurements in `metrics-log.csv` or fill in the table below as you execute each step:

| Tier | Tool | Setup Time | Change Iteration Time | RAM Usage (MB/GB) | CPU Usage (%) | Confidence Score | Issues Caught at this Level |
|------|------|------------|----------------------|-------------------|---------------|------------------|----------------------------|
| 1 | envtest | | | | | 20% | Go syntax, CRD Schema errors |
| 2 | KWOK | | | | | 40% | Controller deadlock under scale |
| 3 | kind | | | | | 65% | Missing container binaries, broken DNS |
| 4 | tilt | | | | | 65% | Velocity metric (Hot-reload speed) |
| 5 | rhoai-in-kind | | | | | 80% | Missing KServe / MLOps CRD dependencies |
| 6 | argocd | | | | | 90% | GitOps sync drift, broken Kustomize refs |
| 7 | OpenShift | | | | | 100% | SCC permission denied, Route ingress errors |

### Measurement Helper

```bash
./scripts/measure.sh "go test ./controllers/... -v"
./scripts/measure.sh "./scripts/run-kind.sh"
```

## Fixing Each Intentional Bug

1. **Schema (Tier 1):** Remove `+kubebuilder:validation:Type=string` from `GPUCount` in `api/v1alpha1/modelpipeline_types.go`, regenerate CRD with `make manifests`.
2. **Scale (Tier 2):** Remove `reconcileBarrier` / `reconcileCond` pattern in `controllers/modelpipeline_controller.go`.
3. **Runtime (Tier 3):** Add `RUN pip install torch` to `Dockerfile.inference`, or fix the default `command` in the controller. Locally, `make uv-sync` installs torch into `.venv` for testing the fixed server.
4. **OpenShift (Tier 7):** Set `runAsRoot: false` and use `runAsUser: 1001040000` (or let OpenShift assign via SCC).

## Quick Reference

```bash
make uv-sync           # Python venv (.venv) with torch
make test              # Tier 1
./scripts/run-kwok.sh  # Tier 2
./scripts/run-kind.sh  # Tier 3 (Podman build + kind load)
./scripts/tilt-up.sh   # Tier 4
./scripts/run-rhoai-in-kind.sh  # Tier 5
kubectl apply -f config/argocd/ # Tier 6
oc apply -f config/samples/modelpipeline_v1alpha1_openshift-root.yaml  # Tier 7

make podman-build              # Build operator image
make podman-build-inference    # Build inference server image
```
