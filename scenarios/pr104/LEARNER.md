# PR #104 Learner Worksheet

**Scenario:** feat: Add high-throughput GPU batch inference & metrics sidecar  
**Goal:** Push one change through seven fidelity tiers and record what each tier catches.

## Before You Start

```bash
git checkout -b lab/$(whoami)    # never fix bugs on main
./lab verify                     # confirm baseline bugs are present
./lab status
```

Keep `main` (or tag `lab-v1.0-pr104`) frozen. Commit fixes only on your `lab/*` branch.

## Scorecard

Copy this table into `metrics-log.csv` or your notes as you complete each tier.

| Tier | Tool | Setup Time | Iteration Time | RAM | CPU % | What failed? | What you fixed |
|------|------|------------|----------------|-----|-------|--------------|----------------|
| 1 | envtest | | | | | | |
| 2 | KWOK | | | | | | |
| 3 | kind | | | | | | |
| 4 | tilt | | | | | | |
| 5 | rhoai-in-kind | | | | | | |
| 6 | argocd | | | | | | |
| 7 | OpenShift | | | | | | |

---

## Tier 1 — envtest (20% confidence)

```bash
./lab run 1
# hint only:
./lab hint 1
```

**What you're testing:** CRD schema for `spec.gpuMemoryRequirement` and controller unit logic.

**Observe:**
- [ ] Which test passes? Which test documents the schema rejection?
- [ ] What happens when `gpuMemoryRequirement` is `"8Gi"` (not in the scale map)?

**Fix (on your branch):** Add `// +optional` to `GPUMemoryRequirement` in `api/v1alpha1/modelpipeline_types.go` and register missing GPU tiers in `gpuMemoryScaleFactors`. Regenerate CRD: `make manifests`.

**Re-run:** `./lab run 1`

---

## Tier 2 — KWOK (40% confidence)

```bash
./lab run 2
./lab hint 2
```

**What you're testing:** 100 pipelines × 5 replicas = 500 pods.

**Observe:**
- [ ] How long until reconcile stalls?
- [ ] What do operator logs show (`kubectl -n fidelity-lab-system logs -l app=fidelity-lab-operator`)?

**Fix:** Remove `podStatusPollLock` and sequential `waitForPodStatuses` in `controllers/modelpipeline_controller.go`.

---

## Tier 3 — kind (65% confidence)

```bash
podman machine start   # macOS
./lab run 3
./lab hint 3
```

**What you're testing:** Sidecar container pulls, starts, and mounts volumes.

**Observe:**
- [ ] `kubectl get pods` — which container is in `CrashLoopBackOff`?
- [ ] `kubectl logs <pod> -c metrics-sidecar` — what error?

**Fix:** Set `SIDECAR_LOG_DIR` env var in `buildSidecarContainer`.

---

## Tier 4 — Tilt (65% confidence, velocity)

```bash
./lab run 4
./lab hint 4
```

**What you're testing:** Time from saving the Tier 3 fix to seeing updated behavior.

**Observe:**
- [ ] Seconds from Ctrl+S to healthy sidecar in Tilt UI?
- [ ] How does that compare to a full `./lab run 3` rebuild?

**Fix:** No new bug — measure iteration speed after Tier 3 fix.

---

## Tier 5 — rhoai-in-kind (80% confidence)

```bash
./lab run 5
./lab hint 5
```

**What you're testing:** KServe / RHOAI integration for the sidecar-enabled pipeline.

**Observe:**
- [ ] Does `InferenceService` apply succeed?
- [ ] What apiVersion error appears?

**Fix:** Change `serving.kserve.io/v1beta1` → `serving.kserve.io/v1` in `rhoai/inferenceservice-v1beta1.yaml`.

---

## Tier 6 — ArgoCD (90% confidence)

```bash
./lab run 6
./lab hint 6
```

**What you're testing:** Declarative deploy from `config/overlays/pr104`.

**Observe:**
- [ ] Does `kubectl kustomize config/overlays/pr104` succeed on baseline? (It should **fail**.)
- [ ] After installing ArgoCD, what sync error appears?

**Fix:** Correct patch path `/spec/sidecarLoging` → `/spec/sidecarLogging` in `config/overlays/pr104/sidecar-patch.yaml`.

---

## Tier 7 — OpenShift (100% confidence)

```bash
./lab run 7
./lab hint 7
```

**What you're testing:** Production SCCs, routes, and real hardware.

**Observe:**
- [ ] Pod events: `oc describe pod <name>`
- [ ] SCC denial message for root + `/var/log` mount?

**Fix:** `runAsNonRoot: true`, `emptyDir` for logs, non-root `SIDECAR_LOG_DIR`.

---

## Reset for Another Run

```bash
./lab reset      # restore broken baseline from main
./lab verify
git checkout -b lab/$(whoami)-run2
```

## Reflection Questions

1. Which tier gave you the highest confidence gain for the lowest cost?
2. Which bug would have reached production if you stopped at Tier 2?
3. Would your team's CI run `./lab verify` on the frozen baseline branch?
