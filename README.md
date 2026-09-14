# k8s-fidelity-lab

A reusable lab framework for teaching **Kubernetes testing fidelity**. Each scenario packages a single Pull Request with intentional bugs that are caught at progressively higher validation tiers — from envtest to production OpenShift.

## How It Works

```
[PR submitted]
       │
       ├── Tier 1 (envtest) ───► API schema & unit logic
       ├── Tier 2 (KWOK) ──────► Controller scale behavior
       ├── Tier 3 (kind) ──────► Real container runtime
       ├── Tier 4 (Tilt) ──────► Inner-loop iteration velocity
       ├── Tier 5 (RHOAI) ─────► MLOps platform integration
       ├── Tier 6 (ArgoCD) ────► GitOps declarative sync
       └── Tier 7 (OpenShift) ─► Enterprise security & policy
                                        │
                           [100% Production Confidence]
```

Each tier validates something the previous tier cannot. Scenario-specific bugs, symptoms, and fix steps live in that scenario's learner worksheet — not here.

## What the Code Does

This lab ships a minimal **Kubernetes operator** for PR #104: *feat: GPU batch inference & metrics sidecar*. The operator watches `ModelInferencePipeline` custom resources and reconciles them into Deployments.

| Component | Path | Purpose |
|-----------|------|---------|
| **CRD API** | `api/v1alpha1/modelpipeline_types.go` | Defines `ModelInferencePipeline` spec (`modelName`, `replicas`, `image`, `gpuMemoryRequirement`, `sidecarLogging`) and status (`phase`, `readyReplicas`) |
| **Controller** | `controllers/modelpipeline_controller.go` | Creates/updates a `{name}-inference` Deployment; scales replicas by GPU memory tier; optionally injects a metrics sidecar |
| **Entrypoint** | `main.go` | Starts the controller-runtime manager with health probes on `:8081` |
| **Sidecar image** | `Dockerfile.sidecar`, `sidecar_entrypoint.sh` | Metrics/logging sidecar that requires `SIDECAR_LOG_DIR` at startup |
| **RHOAI bridge** | `rhoai/` | KServe `InferenceService` manifest linking to the pipeline |
| **GitOps overlay** | `config/overlays/pr104/` | Kustomize patches for PR #104 annotations |

**Reconcile flow (intended behavior after all fixes):**

1. User applies a `ModelInferencePipeline` CR.
2. Controller computes replica count: `baseReplicas × gpuScaleFactor` (e.g. `"16Gi"` → 2×).
3. If `sidecarLogging: true`, the Deployment gets a `metrics-sidecar` container with log volume mounts and RHOAI/KServe annotations.
4. Controller updates CR status to `Running` with `readyReplicas`.

Each scenario embeds **intentional bugs** at different layers so learners discover what each testing tier catches that the previous one misses.

## Tests Explained

The lab has three kinds of validation: **Go unit tests** (Tier 1), **baseline integrity checks** (`./lab verify`), and **tier runner scripts** (Tiers 1–7).

### Tier 1 — Go unit tests (`controllers/`)

Run with `./lab run 1` or `go test ./controllers/... -v`. Tests use [envtest](https://book.kubebuilder.io/reference/envtest): a real Kubernetes API server and etcd binary, but no kubelet or container runtime.

**Test harness** (`controllers/suite_test.go`):

- Boots envtest with CRDs from `config/crd/bases/`
- Registers the `fidelity.ai/v1alpha1` scheme
- Provides a `k8sClient` used by all specs
- Entry point: `TestControllers` runs the Ginkgo suite

**Spec 1 — CR with `gpuMemoryRequirement` present**

```go
It("Should accept a CR that includes gpuMemoryRequirement (PR #104)")
```

Creates a typed `ModelInferencePipeline` with `GPUMemoryRequirement: "16Gi"` and `SidecarLogging: true`. Asserts the CR is accepted by the API server and fields round-trip correctly. Validates the happy path for the new PR #104 field.

**Spec 2 — CR missing `gpuMemoryRequirement` (optional field)**

```go
It("Should accept CRs missing gpuMemoryRequirement (Tier 1 — +optional)")
```

Uses an **unstructured** object so `gpuMemoryRequirement` is truly absent from JSON (the typed Go client would send `""`). On the broken baseline, CRD admission rejects this because the field is incorrectly required. After fixing `// +optional` and `,omitempty` plus regenerating the CRD, this spec passes.

**Spec 3 — Nil-pointer guard in replica scaling**

```go
It("Should not panic when gpuMemoryRequirement is not in the scale map")
```

Calls `buildDeployment()` directly with `GPUMemoryRequirement: "8Gi"`. On the broken baseline, `computeReplicas()` looks up an unknown tier in `gpuMemoryScaleFactors`, gets `nil`, and panics on dereference. After adding a default/guard in `computeReplicas`, this spec passes.

| Test | What it catches | Baseline symptom | Fix location |
|------|-----------------|------------------|--------------|
| Spec 2 | CRD schema too strict | `Create` fails at admission | `modelpipeline_types.go` + `make manifests` |
| Spec 3 | Controller nil pointer | Ginkgo panic in `buildDeployment` | `computeReplicas()` in controller |

On the frozen baseline, **2 of 3 specs fail** — which is why `./lab verify` expects the envtest suite to fail until Tier 1 fixes are applied.

### Baseline integrity — `./lab verify`

`scripts/lab-verify.sh` confirms intentional bugs are still present (for cohort facilitators). It does **not** replace tier runners; it greps for bug markers and runs quick smoke checks:

| Check | Tier | What it validates |
|-------|------|-------------------|
| `go test ./controllers/...` must **fail** | 1 | Unit tests still catch schema + nil-pointer bugs |
| `INTENTIONAL TIER 1 BUG` in types | 1 | Schema bug marker present |
| `gpuMemoryScaleFactors` map | 1 | Nil-pointer scale map present |
| `podStatusPollLock` in controller | 2 | Reconcile starvation bug present |
| `INTENTIONAL TIER 3 BUG` marker | 3 | Sidecar env bug documented |
| `sidecar_entrypoint.sh` exits non-zero without `SIDECAR_LOG_DIR` | 3 | Sidecar entrypoint enforces env var |
| `serving.kserve.io/v1beta1` in RHOAI manifest | 5 | KServe apiVersion conflict present |
| `kubectl kustomize config/overlays/pr104` must **fail** | 6 | Malformed Kustomize patch |
| `sidecarLoging` typo in patch | 6 | GitOps typo present |
| `INTENTIONAL TIER 7 BUG` + `int64Ptr(0)` | 7 | Root UID sidecar on hostPath `/var/log` |

After you apply fixes, `./lab verify` is **expected to fail** — use `./lab run <tier>` instead.

### Tier runners — integration validation (Tiers 1–7)

Each `./lab run <N>` script exercises behavior that unit tests alone cannot cover.

| Tier | Script | What it tests | Pass criteria |
|------|--------|---------------|---------------|
| **1** | `scripts/run-envtest.sh` | Same as Go unit tests above | All 3 Ginkgo specs pass |
| **2** | `scripts/run-kwok.sh` | Controller under load: 100 CRs × 5 replicas = 500 pods on [KWOK](https://kwok.sigs.k8s.io/) fake nodes | All pipelines reach `Running` without requeue starvation in operator logs |
| **3** | `scripts/run-kind.sh` | Real kubelet + Podman images; sidecar container startup | Inference pod `2/2 Running`; metrics-sidecar ready (needs `SIDECAR_LOG_DIR`) |
| **4** | `scripts/tilt-up.sh` | Developer inner loop via [Tilt](https://tilt.dev/) hot-reload | Manual: record iteration time after controller fix |
| **5** | `scripts/run-rhoai-in-kind.sh` | OLM + ODH + KServe CRD; apply `InferenceService` | `kubectl apply -k rhoai/` succeeds with `serving.kserve.io/v1` |
| **6** | `scripts/run-argocd.sh` | Kustomize overlay build + ArgoCD install on kind | `kubectl kustomize config/overlays/pr104` succeeds; ArgoCD server Available |
| **7** | `scripts/run-openshift.sh` | OpenShift Local (CRC): SCC enforcement on sidecar | Pod runs with SCC-compliant security context (non-root, no hostPath `/var/log`) |

Tier scripts use helpers from `scripts/lab-tier-check.sh`:

- `lab_tier_expect_baseline_failure` — exits with a message when the bug is correctly still broken
- `lab_tier_pass` / `lab_tier_fail` — explicit pass/fail after fixes are applied

**What each tier catches that the previous tier cannot:**

| Tier | Gap filled |
|------|------------|
| 1 → 2 | envtest has no real reconcile queue or hundreds of concurrent objects |
| 2 → 3 | KWOK fakes pods; it never runs container entrypoints or pulls images |
| 3 → 4 | kind proves correctness once; Tilt measures how fast you can iterate |
| 4 → 5 | Single-cluster Deployments ≠ MLOps platform CRDs (KServe, ODH) |
| 5 → 6 | Direct `kubectl apply` ≠ GitOps drift detection and Kustomize overlays |
| 6 → 7 | kind has no SCCs, restricted UIDs, or enterprise policy enforcement |

Fix steps for each tier: [scenarios/pr104/LEARNER.md](scenarios/pr104/LEARNER.md).

## Scenarios

| Scenario | PR | Learner worksheet | Facilitator guide |
|----------|----|-------------------|-------------------|
| **pr104** | feat: GPU batch inference & metrics sidecar | [LEARNER.md](scenarios/pr104/LEARNER.md) | [FACILITATOR.md](scenarios/pr104/FACILITATOR.md) |

```bash
# Start a scenario (example: pr104)
git checkout -b lab/$(whoami) lab-v1.0-pr104
open scenarios/pr104/LEARNER.md
./lab verify
```

## Repository Structure

```
k8s-fidelity-lab/
├── scenarios/              # Per-PR worksheets (bugs, fixes, scorecards)
│   └── pr104/
├── api/                    # CRD types
├── controllers/            # Operator reconcile logic
├── config/                 # CRDs, samples, overlays, ArgoCD
├── scripts/                # Tier runners, lab-verify, lab-reset
├── lab                       # CLI entrypoint
├── kwok/                   # Fake nodes for scale testing
├── rhoai/                  # MLOps integration manifests
└── metrics-log.csv         # Benchmarking scorecard template
```

## Prerequisites

- Go 1.22+
- [Podman](https://podman.io/getting-started/installation)
- [uv](https://docs.astral.sh/uv/) (Python venv)
- `kubectl`
- Optional per tier: [envtest](https://book.kubebuilder.io/reference/envtest), [kind](https://kind.sigs.k8s.io/), [Tilt](https://tilt.dev/), [ArgoCD](https://argo-cd.readthedocs.io/), OpenShift CLI (`oc`)
- **Tier 2:** [KWOK](https://kwok.sigs.k8s.io/) — install `kwokctl` (`./lab run 2` creates the cluster if missing)
- **Tier 7:** [OpenShift Local (CRC)](https://developers.redhat.com/products/openshift-local/overview) — `./lab run 7` starts CRC if not running

```bash
# Install or verify all prerequisites (macOS: Homebrew; Linux: apt/dnf + direct downloads)
./scripts/install-prerequisites.sh --all
./scripts/install-prerequisites.sh --check --all

# Core only (Tiers 1–4): go, kubectl, podman, uv, kind, kwokctl, tilt, setup-envtest
./scripts/install-prerequisites.sh

# Per-tier install
./scripts/install-prerequisites.sh --tier 2

make install-prerequisites PREREQ_ARGS="--all"
make check-prerequisites
```

Manual fallback (also run by the script after install):

```bash
go mod download
chmod +x lab scripts/*.sh kwok/generate-nodes.sh
```

On macOS: `podman machine start`

Cluster teardown: tier scripts delete their cluster on exit (Ctrl+C ends interactive watches). Set `LAB_KEEP_CLUSTER=1` to keep the cluster when continuing tiers 3→6 in one session.

## Lab CLI

```bash
./lab verify              # confirm intentional bugs are present (run on frozen baseline)
./lab status              # scenario + integrity + recent runs
./lab run <1-7>           # run a fidelity tier
./lab hint <1-7>          # symptom only, no fix spoiler
./lab reset               # restore scenario files from baseline ref

make lab-verify           # same as ./lab verify
make lab-reset            # same as ./lab reset
make lab-run TIER=1       # same as ./lab run 1
```

Environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `LAB_SCENARIO` | `pr104` | Active scenario name |
| `LAB_BASELINE_REF` | `main` | Git ref for reset/verify |

Tag frozen baselines per cohort: `git tag lab-v1.0-pr104`

## Step 0: Fork or Branch (preserve the intentional bugs)

**Do this first.** Each tier ends with fixing deliberate bugs. If you commit fixes on `main`, you lose the broken baseline for future runs.

```bash
git checkout -b broken-baseline    # frozen bugs — never commit fixes here
git checkout -b lab/$(whoami)      # your working branch
```

## Tier Overview (generic)

| Tier | Tool | Confidence | What it validates |
|------|------|------------|-------------------|
| 1 | envtest | ~20% | CRD schema, Go types, controller unit logic |
| 2 | KWOK | ~40% | Controller behavior under API load / scale |
| 3 | kind | ~65% | Image pulls, entrypoints, volumes, DNS |
| 4 | tilt | ~65% | Developer iteration speed (hot-reload) |
| 5 | rhoai-in-kind | ~80% | MLOps control plane integration |
| 6 | argocd | ~90% | GitOps sync, Kustomize overlays |
| 7 | OpenShift | 100% | SCCs, routes, enterprise policy |

**Run any tier:** `./lab run <N>`

**Fix steps:** See your scenario's `LEARNER.md` (e.g. [scenarios/pr104/LEARNER.md](scenarios/pr104/LEARNER.md)).

> After applying fixes, `./lab verify` is expected to **fail** (it checks the broken baseline). Use `./lab run <tier>` to validate your fix instead.

## Scorecard

Each `./lab run <tier>` records setup time, elapsed time, peak RAM, and average CPU to `.lab/tier-metrics.csv` (gitignored). View collected data:

```bash
./lab metrics
./lab status    # includes latest metrics rows
```

Copy values into `metrics-log.csv` for your cohort scorecard. For one-off commands:

```bash
./scripts/measure.sh "go test ./controllers/... -v"
```

## Quick Reference

```bash
git checkout -b lab/$(whoami) lab-v1.0-pr104
./lab verify
./lab run 1 … ./lab run 7
./lab reset                    # restore broken baseline for next cohort

make podman-build
make podman-build-inference
make podman-build-sidecar
```

## Adding a New Scenario

1. Create `scenarios/<name>/LEARNER.md` and `FACILITATOR.md`
2. Embed intentional bugs across api, controllers, config, and manifests
3. Tag the frozen baseline: `git tag lab-v1.0-<name>`
4. Ensure `./lab verify` passes on the tagged commit
