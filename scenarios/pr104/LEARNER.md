# PR #104 Learner Worksheet

**Scenario:** feat: Add high-throughput GPU batch inference & metrics sidecar  
**Goal:** Push one change through seven fidelity tiers and record what each tier catches.

## What Changed in PR #104

| Area | Change |
|------|--------|
| **CRD API** (`api/v1alpha1/`) | Added `spec.gpuMemoryRequirement` and `spec.sidecarLogging: true` |
| **Controller** (`controllers/`) | Injects a metrics sidecar; dynamically scales replicas by GPU tier |
| **GitOps** (`config/overlays/pr104/`) | Kustomize overlay with RHOAI `InferenceService` annotations |
| **RHOAI** (`rhoai/`) | KServe `InferenceService` bridge |
| **Sidecar** (`Dockerfile.sidecar`) | New metrics/logging sidecar image |

```
[PR #104 Submitted]
       │
       ├── Tier 1 (envtest) ───► missing +optional on gpuMemoryRequirement
       ├── Tier 2 (KWOK) ──────► reconciler queue starvation at 500 pods
       ├── Tier 3 (kind) ──────► SIDECAR_LOG_DIR env var missing
       ├── Tier 4 (Tilt) ──────► hot-reload fix in ~2 seconds
       ├── Tier 5 (RHOAI) ─────► KServe apiVersion v1beta1 conflict
       ├── Tier 6 (ArgoCD) ────► malformed Kustomize patch path
       └── Tier 7 (OpenShift) ─► SCC blocks root sidecar on /var/log
```

## Before You Start

```bash
git checkout -b lab/$(whoami) lab-v1.0-pr104
./lab verify                     # confirm baseline bugs are present
./lab status
```

Keep `main` / `lab-v1.0-pr104` frozen. Commit fixes only on your `lab/*` branch.

> After applying fixes, `./lab verify` will fail — that is expected. Use `./lab run <tier>` to validate.

## Scorecard

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
./lab hint 1
```

**What you're testing:** CRD schema for `spec.gpuMemoryRequirement` and controller unit logic.

**Observe:**
- [ ] Which test passes? Which test documents the schema rejection?
- [ ] What happens when `gpuMemoryRequirement` is `"8Gi"` (not in the scale map)?

### Symptoms

- CRs without `gpuMemoryRequirement` are rejected at admission
- Controller panics on unknown GPU tiers (e.g. `"8Gi"`)

### Fix steps

**Files:** `api/v1alpha1/modelpipeline_types.go`, `controllers/modelpipeline_controller.go`, `controllers/modelpipeline_controller_test.go`, `config/crd/bases/` (via `make manifests`)

**Step 1 — Fix the Go type** (`api/v1alpha1/modelpipeline_types.go`):

```go
// GPUMemoryRequirement is the GPU memory allocation per replica (e.g. "16Gi").
// +optional
// +kubebuilder:validation:MinLength=1
GPUMemoryRequirement string `json:"gpuMemoryRequirement,omitempty"`
```

Both `// +optional` **and** `,omitempty` on the JSON tag are required. The marker alone does not update the CRD.

**Step 2 — Regenerate the CRD:**

```bash
make manifests
```

Verify `gpuMemoryRequirement` is **not** under `required:` in the **correct** file:

```bash
grep -A5 'required:' config/crd/bases/fidelity.ai_modelinferencepipelines.yaml
# expect: image, modelName, replicas — NOT gpuMemoryRequirement
```

If the field is still listed, check you are not looking at a stale file. `make manifests` updates `fidelity.ai_modelinferencepipelines.yaml` only — delete any stray `config/crd/bases/_modelinferencepipelines.yaml` if it appears (that means `+groupName` was missing from `api/v1alpha1/groupversion_info.go`).

**Step 3 — Fix nil-pointer in replica scaling** (`controllers/modelpipeline_controller.go`):

```go
var gpuMemoryScaleFactors = map[string]*gpuScaleFactor{
    "8Gi":  {Multiplier: 1},
    "16Gi": {Multiplier: 2},
    "32Gi": {Multiplier: 4},
}
```

Or guard in `computeReplicas`:

```go
scale := gpuMemoryScaleFactors[pipeline.Spec.GPUMemoryRequirement]
if scale == nil {
    return base
}
return base * scale.Multiplier
```

**Step 4 — Update tests** (`controllers/modelpipeline_controller_test.go`) — **required, easy to miss**:

After Steps 1–3, the old tests still expect the *broken* behavior and will fail. You must invert them:

| Test | Change from | Change to |
|------|-------------|-----------|
| Missing `gpuMemoryRequirement` | `Expect(err).To(HaveOccurred())` | `Expect(err).NotTo(HaveOccurred())` |
| `gpuMemoryRequirement: "8Gi"` | `Expect(...).To(Panic())` | `Expect(...).NotTo(Panic())` |

If you skip this step you will see:

```
Expected an error to have occurred.  Got: <nil>
Expected func() to panic
```

That means your **fix worked** — the tests just need updating.

**Verify:** `./lab run 1` — expect 3 specs PASS.

### Common mistakes

| Error | Cause |
|-------|-------|
| `make manifests` fails | Use `make manifests` (not `make manifest`); Makefile auto-installs `controller-gen` |
| CRD still requires field | Missing `,omitempty` — re-run `make manifests` |
| `grep` still shows `gpuMemoryRequirement` required | Wrong CRD file, or `_modelinferencepipelines.yaml` created — fix `+groupName` in `groupversion_info.go`, delete stray file, re-run `make manifests` |
| `Expected an error to have occurred` | CRD fixed but test not updated (Step 4) |
| Tests pass but cluster rejects CR | CRD not applied: `kubectl apply -f config/crd/bases/` |

---

## Tier 2 — KWOK (40% confidence)

```bash
./lab run 2
./lab hint 2
```

**What you're testing:** 100 pipelines × 5 replicas = 500 pods.

**Observe:**
- [ ] How long until reconcile stalls?
- [ ] Operator logs: `kubectl -n fidelity-lab-system logs -l app=fidelity-lab-operator`

### Symptoms

- Operator logs: `waiting on pod status updates`
- Pipelines never reach `Running` at scale

### Fix steps

**File:** `controllers/modelpipeline_controller.go`

**Step 1 — Remove the global poll lock:**

```go
var podStatusPollLock sync.Mutex   // delete this
```

**Step 2 — Remove the blocking call from `Reconcile`:**

```go
if err := r.waitForPodStatuses(ctx, pipeline, deployName); err != nil {
    ...
}
```

**Step 3 — Delete `waitForPodStatuses`** (or replace with non-blocking status update).

**Verify:**

```bash
PIPELINE_COUNT=20 ./scripts/run-kwok.sh   # short demo
./lab run 2                               # full 100 × 5 load
```

---

## Tier 3 — kind (65% confidence)

```bash
podman machine start   # macOS
./lab run 3
./lab hint 3
```

**What you're testing:** Sidecar container pulls, starts, and mounts volumes.

**Observe:**
- [ ] `kubectl get pods` — which container is `CrashLoopBackOff`?
- [ ] `kubectl logs <pod> -c metrics-sidecar`

### Symptoms

```
error: SIDECAR_LOG_DIR environment variable is required
```

### Fix steps

**File:** `controllers/modelpipeline_controller.go` → `buildSidecarContainer`

**Step 1 — Add the env var:**

```go
return corev1.Container{
    Name:    "metrics-sidecar",
    Image:   image,
    Command: []string{"/usr/local/bin/sidecar-entrypoint.sh"},
    Env: []corev1.EnvVar{
        {Name: "SIDECAR_LOG_DIR", Value: "/var/log/sidecar"},
    },
    // SecurityContext and volume unchanged until Tier 7
    ...
}
```

**Step 2 — Rebuild and reload:**

```bash
./lab run 3
```

**Verify:**

```bash
kubectl logs <pod-name> -c metrics-sidecar
# expect: "sidecar starting; writing metrics to ..."
```

---

## Tier 4 — Tilt (65% confidence, velocity)

```bash
./lab run 4
./lab hint 4
```

**What you're testing:** Time from saving the Tier 3 fix to seeing updated behavior.

**Observe:**
- [ ] Seconds from Ctrl+S to healthy sidecar in Tilt UI?
- [ ] Compare to a full `./lab run 3` rebuild

### Fix steps

No new bug. Apply the Tier 3 fix, then:

```bash
./scripts/tilt-up.sh
```

Save `controllers/modelpipeline_controller.go` and record hot-reload time in your scorecard (target: < 3 seconds).

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

### Symptoms

```
no matches for kind "InferenceService" in version "serving.kserve.io/v1beta1"
```

### Fix steps

**File:** `rhoai/inferenceservice-v1beta1.yaml`

**Step 1 — Update apiVersion:**

```yaml
apiVersion: serving.kserve.io/v1   # was: v1beta1
kind: InferenceService
```

**Step 2 — Re-apply:**

```bash
kubectl apply -k rhoai/
```

**Verify:**

```bash
kubectl get inferenceservice -n opendatahub
```

---

## Tier 6 — ArgoCD (90% confidence)

```bash
./lab run 6
./lab hint 6
```

**What you're testing:** Declarative deploy from `config/overlays/pr104`.

**Observe:**
- [ ] `kubectl kustomize config/overlays/pr104` — should **fail** on baseline
- [ ] ArgoCD sync error after install

### Symptoms

```
error: unable to find patch path /spec/sidecarLoging
```

### Fix steps

**File:** `config/overlays/pr104/sidecar-patch.yaml`

**Step 1 — Fix the typo:**

```yaml
- op: replace
  path: /spec/sidecarLogging    # was: /spec/sidecarLoging
  value: true
```

**Verify:**

```bash
kubectl kustomize config/overlays/pr104   # should succeed
```

Install ArgoCD and apply `config/argocd/application.yaml` (update `repoURL`).

---

## Tier 7 — OpenShift (100% confidence)

```bash
./lab run 7
./lab hint 7
```

**What you're testing:** Production SCCs, routes, and real hardware.

**Observe:**
- [ ] `oc describe pod <name>` — SCC denial events?
- [ ] `CreateContainerConfigError` for root + `/var/log` mount?

### Symptoms

```
unable to validate against any security context constraint
```

### Fix steps

**File:** `controllers/modelpipeline_controller.go`

**Step 1 — Replace root security context** in `buildSidecarContainer`:

```go
SecurityContext: &corev1.SecurityContext{
    RunAsNonRoot: boolPtr(true),
    RunAsUser:    int64Ptr(1001040000),
},
```

**Step 2 — Replace `hostPath` with `emptyDir`** in `buildDeployment`:

```go
volumes = append(volumes, corev1.Volume{
    Name: "sidecar-logs",
    VolumeSource: corev1.VolumeSource{
        EmptyDir: &corev1.EmptyDirVolumeSource{},
    },
})
```

**Step 3 — Align env var and mount** (with Tier 3 fix):

```go
Env: []corev1.EnvVar{
    {Name: "SIDECAR_LOG_DIR", Value: "/var/log/sidecar"},
},
VolumeMounts: []corev1.VolumeMount{
    {Name: "sidecar-logs", MountPath: "/var/log/sidecar"},
},
```

**Verify:**

```bash
oc apply -f config/samples/modelpipeline_v1alpha1_openshift-root.yaml
oc get pods -w
```

---

## Reset for Another Run

```bash
./lab reset
./lab verify
git checkout -b lab/$(whoami)-run2 lab-v1.0-pr104
```

## Reflection Questions

1. Which tier gave you the highest confidence gain for the lowest cost?
2. Which bug would have reached production if you stopped at Tier 2?
3. Would your team's CI run `./lab verify` on the frozen baseline branch?
