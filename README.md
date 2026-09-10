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
- **Tier 2:** [KWOK](https://kwok.sigs.k8s.io/) — install `kwokctl` and create a cluster before `./lab run 2` (see [KWOK install guide](https://kwok.sigs.k8s.io/docs/user/install/))

```bash
go mod download
chmod +x lab scripts/*.sh kwok/generate-nodes.sh
```

On macOS: `podman machine start`

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

Log timings in `metrics-log.csv` as you complete each tier:

```bash
./scripts/measure.sh "go test ./controllers/... -v"
./scripts/measure.sh "./lab run 3"
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
