# PR #104 Learner Worksheet

**Scenario:** feat: Add high-throughput GPU batch inference & metrics sidecar  
**Goal:** Push one change through seven fidelity tiers and record what each tier catches.

## What Changed in PR #104


| Area                                  | Change                                                             |
| ------------------------------------- | ------------------------------------------------------------------ |
| **CRD API** (`api/v1alpha1/`)         | Added `spec.gpuMemoryRequirement` and `spec.sidecarLogging: true`  |
| **Controller** (`controllers/`)       | Injects a metrics sidecar; dynamically scales replicas by GPU tier |
| **GitOps** (`config/overlays/pr104/`) | Kustomize overlay with RHOAI `InferenceService` annotations        |
| **RHOAI** (`rhoai/`)                  | KServe `InferenceService` bridge                                   |
| **Sidecar** (`Dockerfile.sidecar`)    | New metrics/logging sidecar image                                  |


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


| Tier | Tool          | Setup Time | Iteration Time | RAM | CPU % | What failed? | What you fixed |
| ---- | ------------- | ---------- | -------------- | --- | ----- | ------------ | -------------- |
| 1    | envtest       |            |                |     |       |              |                |
| 2    | KWOK          |            |                |     |       |              |                |
| 3    | kind          |            |                |     |       |              |                |
| 4    | tilt          |            |                |     |       |              |                |
| 5    | rhoai-in-kind |            |                |     |       |              |                |
| 6    | argocd        |            |                |     |       |              |                |
| 7    | OpenShift     |            |                |     |       |              |                |


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


| Test                           | Change from                      | Change to                           |
| ------------------------------ | -------------------------------- | ----------------------------------- |
| Missing `gpuMemoryRequirement` | `Expect(err).To(HaveOccurred())` | `Expect(err).NotTo(HaveOccurred())` |
| `gpuMemoryRequirement: "8Gi"`  | `Expect(...).To(Panic())`        | `Expect(...).NotTo(Panic())`        |


If you skip this step you will see:

```
Expected an error to have occurred.  Got: <nil>
Expected func() to panic
```

That means your **fix worked** — the tests just need updating.

**Verify:** `./lab run 1` — expect 3 specs PASS.

### Common mistakes


| Error                                              | Cause                                                                                                                                               |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make manifests` fails                             | Use `make manifests` (not `make manifest`); Makefile auto-installs `controller-gen`                                                                 |
| CRD still requires field                           | Missing `,omitempty` — re-run `make manifests`                                                                                                      |
| `grep` still shows `gpuMemoryRequirement` required | Wrong CRD file, or `_modelinferencepipelines.yaml` created — fix `+groupName` in `groupversion_info.go`, delete stray file, re-run `make manifests` |
| `Expected an error to have occurred`               | CRD fixed but test not updated (Step 4)                                                                                                             |
| Tests pass but cluster rejects CR                  | CRD not applied: `kubectl apply -f config/crd/bases/`                                                                                               |


---



## Tier 2 — KWOK (40% confidence)

**Prerequisite:** Install [KWOK](https://kwok.sigs.k8s.io/docs/user/install/) (`kwokctl`) and create a cluster (the lab does not install KWOK for you):

```bash
kwokctl create cluster --name fidelity-kwok --wait 5m
kubectl config use-context kwok-fidelity-kwok   # not "fidelity-kwok" (kwokctl hint is misleading)
```

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

**Step 2 — Remove the blocking call from** `Reconcile`**:**

```go
if err := r.waitForPodStatuses(ctx, pipeline, deployName); err != nil {
    ...
}
```

**Step 3 — Delete** `waitForPodStatuses` (or replace with non-blocking status update).

**Step 4 — Rebuild and run locally** — KWOK fake nodes do **not** run real containers. `./lab run 2` builds and runs `./bin/manager` on your machine against the KWOK API. Editing `modelpipeline_controller.go` alone is not enough; you do not redeploy an in-cluster operator for this tier.

**Verify:**

```bash
PIPELINE_COUNT=20 ./scripts/run-kwok.sh   # short demo
./lab run 2                               # full 100 × 5 load
```

After the fix, you should see `Pipeline status: N/N Running` and steady local operator logs (no `waiting on pod status updates` spam).

### Common mistakes


| Error                                    | Cause                                                                                       |
| ---------------------------------------- | ------------------------------------------------------------------------------------------- |
| `kwokctl not found`                      | Install KWOK before Tier 2 — see prerequisite above                                         |
| `KWOK cluster 'fidelity-kwok' not found` | Run `kwokctl create cluster --name fidelity-kwok` first; verify with `kwokctl get clusters` |
| `context "fidelity-kwok" does not exist` | Use context `kwok-fidelity-kwok` (see prerequisite above)                                   |
| `no logs found for container "manager"`  | Old workflow — KWOK cannot run in-cluster pods; use updated `./lab run 2` (local operator)  |
| CRs stay empty / no `Running` phase      | Operator not running locally, or stale in-cluster Deployment still applied                  |


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

**Prerequisite:** Tier 3 kind cluster running (`kubectl config current-context` → `kind-fidelity-kind`), [Tilt](https://docs.tilt.dev/install.html) installed, Podman running (`podman machine start` on macOS). Use `./scripts/tilt-up.sh` — not bare `tilt up` (sets Podman socket + `DOCKER_BUILDKIT=0`).

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

### Common mistakes


| Error                                                           | Cause                                                                                                                                        |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `failed to dial gRPC: unable to upgrade to h2c, received 404`   | Podman does not support Docker BuildKit — run `./scripts/tilt-up.sh` (sets `DOCKER_BUILDKIT=0`), not `tilt up` directly                      |
| `Error loading image to KIND: exit status 1`                    | Tilt's built-in `kind load` fails with Podman — use updated Tiltfile (`custom_build` + `kind load image-archive`) via `./scripts/tilt-up.sh` |
| `Image not used in any Kubernetes config` for inference/sidecar | Harmless before fix — images are in the CR `spec`, not a Pod; Tiltfile uses `k8s_kind()` to wire them up                                     |
| `Kind without a local image registry`                           | Informational only — safe to ignore for this lab                                                                                             |
| Build succeeds but cluster unchanged                            | Wrong kube context — Tiltfile allows only `kind-fidelity-kind`; Tier 3 kind cluster must still be running                                    |
| `tilt not found`                                                | Install Tilt and re-run `./lab run 4`                                                                                                        |


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



### Common mistakes


| Error                                                      | Cause                                                                                                                    |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `clusterserviceversions... metadata.annotations: Too long` | OLM CRD install via plain `kubectl apply` — fixed in `run-rhoai-in-kind.sh` (uses `--server-side`); re-run `./lab run 5` |
| `the server doesn't have a resource type "inferenceservice"` | KServe CRD not installed yet — re-run `./lab run 5` (installs lab KServe CRD before InferenceService) |
| `no matches ... v1beta1` | **Tier 5 bug** — CRD serves only `v1`; fix apiVersion in `rhoai/inferenceservice-v1beta1.yaml` |
| `no matches ... v1` after your fix | CRD missing — run `./lab run 5` first, then apply InferenceService |
| OLM install hangs                                          | Allow 5–10 min; needs Tier 3 kind cluster with ~12 GB RAM free                                                           |


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
error: testing value /spec/sidecarLoging failed: test failed
```



### Fix steps

**File:** `config/overlays/pr104/sidecar-patch.yaml`

**Step 1 — Fix the typo:**

```yaml
- op: test
  path: /spec/sidecarLogging    # was: /spec/sidecarLoging
  value: true
```

**Verify:**

```bash
kubectl kustomize config/overlays/pr104   # should succeed
```

**Step 2 — Install ArgoCD and apply the Application:**

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s
./scripts/argocd-connect-github.sh   # uses git origin + current branch (lab/mtchoumi, etc.)
```

Or set explicitly:

```bash
ARGOCD_REPO_URL=https://github.com/mtchoum1/k8s-fidelity-lab.git \
ARGOCD_TARGET_REVISION=lab/mtchoumi \
./scripts/argocd-connect-github.sh
```

**Step 3 — Web UI login** (recommended on kind):

```bash
chmod +x scripts/argocd-ui-access.sh scripts/argocd-reset-admin.sh
./scripts/argocd-ui-access.sh
# follow printed steps: port-forward to :80, open http://localhost:8080
```

Username is **`admin`** (not `adminuser`). Copy the password to clipboard:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d | pbcopy
```

If you still get “Invalid username or password”, reset to a known password:

```bash
./scripts/argocd-reset-admin.sh          # sets password to "admin"
./scripts/argocd-ui-access.sh
```

**Step 4 — CLI login** (optional):

```bash
./scripts/argocd-login.sh
```

### Common mistakes

| Error | Cause |
|-------|-------|
| `Invalid username or password` | Username must be **`admin`**; paste password with `pbcopy` or run `./scripts/argocd-reset-admin.sh` |
| UI blank / TLS errors | Use HTTP: `./scripts/argocd-ui-access.sh` then `port-forward ... 8080:80` and open **http://**localhost:8080 |
| `unable to forward port ... Pending` | Wait for `kubectl -n argocd wait --for=condition=Available deployment/argocd-server` |
| `zsh: bad pattern: ^[[200~kubectl` | Bracketed-paste artifact — retype the command without paste markers |

---



## Tier 7 — OpenShift (100% confidence)

**Requires OpenShift Local (CRC) or a real OpenShift cluster — not kind.** Kind has no `restricted-v2` SCC, so this bug never surfaces there.

```bash
./lab run 7      # runs scripts/run-openshift.sh when present
./lab hint 7
```

**What you're testing:** Production security policy blocks a root sidecar that mounts host `/var/log`.

**Time budget:** ~25 min setup (CRC + image push) · ~10 min to diagnose · ~5 min to fix and rebuild



### Prerequisites

Before you start, confirm:

- [ ] **CRC** installed and **~16 GB RAM** free (quit heavy apps; on Mac, `podman machine stop` if CRC fails to start)
- [ ] **`oc` CLI** on your PATH (`eval $(crc oc-env)` after `crc start`)
- [ ] **Quay.io** login (default image registry) — or set `IMAGE_REGISTRY=crc` to use CRC's internal registry only
- [ ] **Podman or Docker** for building images



### Step 1 — Start OpenShift Local (~10 min)

Use the terminal — not Podman Desktop's Start button (that often yields `provider does not have any connection to start`).

```bash
podman machine stop          # optional; frees vfkit RAM on Apple Silicon Macs
crc start                    # first start ~5–10 min; save kubeadmin password from output
eval $(crc oc-env)
oc login -u developer -p developer https://api.crc.testing:6443
oc get nodes                 # STATUS Ready; note architecture (arm64 on M-series Macs)
```



### Step 2 — Build images, push, deploy (~10 min)

Images land in [quay.io/mtchoumi-aaet/lab-image](https://quay.io/repository/mtchoumi-aaet/lab-image) (`operator`, `inference-server`, `metrics-sidecar` tags).

```bash
export QUAY_USERNAME=your-quay-user
export QUAY_TOKEN=your-quay-token    # Quay → Account Settings → Generate Encrypted Password

chmod +x scripts/run-openshift.sh
./scripts/run-openshift.sh
# equivalent: ./lab run 7
```

The script:

1. Detects cluster **CPU arch** (`arm64` vs `amd64`) and builds the operator for that arch
2. Pushes all three images to Quay (or CRC registry when `IMAGE_REGISTRY=crc`)
3. Installs the CRD and operator in **`fidelity-lab-system`**
4. Applies the Tier 7 `ModelInferencePipeline` sample in the same namespace

```bash
oc project fidelity-lab-system
```



### Step 3 — Diagnose the SCC failure (~5 min)

OpenShift often **rejects the pod spec before any pod is created**. Do not assume `oc get pods` will show a failing pod.

```bash
oc project fidelity-lab-system

# Operator is expected to be Running — the bug is on the inference deployment
oc get pods -l app=fidelity-lab-operator

oc get deployment pr104-openshift-sidecar-inference
# expect READY 0/2, AVAILABLE 0, and conditions like ReplicaFailure / FailedCreate

oc describe rs -l fidelity.ai/pipeline=pr104-openshift-sidecar | tail -30
# look for: unable to validate against any security context constraint
#           hostPath volumes are not allowed
#           runAsUser: 0 is not allowed
```

**Checklist — baseline should show:**

- [ ] Operator pod `Running` in `fidelity-lab-system`
- [ ] Inference deployment **not** ready (`0/2`)
- [ ] ReplicaSet events cite **SCC** + **`hostPath`** + **`runAsUser: 0`**
- [ ] `oc get pods -l fidelity.ai/pipeline=pr104-openshift-sidecar` may return **No resources found** (normal on baseline)



### Step 4 — Fix the controller

**File:** `controllers/modelpipeline_controller.go`

Fix **Tier 7 (SCC)** and **Tier 3 (sidecar env)** together — after SCC passes, the sidecar still needs `SIDECAR_LOG_DIR`.

**4a — Sidecar security context** in `buildSidecarContainer` (drop root UID):

```go
SecurityContext: &corev1.SecurityContext{
    RunAsNonRoot: boolPtr(true),
    RunAsUser:    int64Ptr(1001040000),
},
```

**4b — Replace `hostPath` with `emptyDir`** in `buildDeployment`:

```go
volumes = append(volumes, corev1.Volume{
    Name: "sidecar-logs",
    VolumeSource: corev1.VolumeSource{
        EmptyDir: &corev1.EmptyDirVolumeSource{},
    },
})
```

**4c — Align env var and mount** in `buildSidecarContainer` (Tier 3 + Tier 7):

```go
Env: []corev1.EnvVar{
    {Name: "SIDECAR_LOG_DIR", Value: "/var/log/sidecar"},
},
VolumeMounts: []corev1.VolumeMount{
    {Name: "sidecar-logs", MountPath: "/var/log/sidecar"},
},
```



### Step 5 — Rebuild and verify (~5 min)

Re-run the deploy script so the cluster picks up your fixed operator image:

```bash
./scripts/run-openshift.sh

oc project fidelity-lab-system
oc rollout status deployment/pr104-openshift-sidecar-inference --timeout=180s
oc get pods -l fidelity.ai/pipeline=pr104-openshift-sidecar
# expect 2/2 Running (inference + metrics-sidecar)

oc logs -l fidelity.ai/pipeline=pr104-openshift-sidecar -c metrics-sidecar --tail=20
# no "SIDECAR_LOG_DIR is required" errors
```



### Common mistakes


| Error | Cause |
| ----- | ----- |
| `no matches for kind "ModelInferencePipeline"` | CRD not installed — run `./scripts/run-openshift.sh` end-to-end; do not only `oc apply` the sample YAML |
| Pods `2/2 Running` on kind | Tier 7 needs OpenShift SCC — kind has no `restricted-v2` |
| `provider does not have any connection to start` | Podman Desktop UI — use `crc start` in a terminal instead |
| `connection reset` on `oc login` | CRC stopped or Podman machine conflict — `podman machine stop && crc start` |
| `No resources found` on `oc describe pod` | Wrong namespace — `oc project fidelity-lab-system`; or SCC blocked pod creation (check `oc describe rs` instead) |
| `No resources found` after you expected a pod | Baseline behavior — SCC failure appears on the **ReplicaSet**, not always as a Pod |
| Operator `CrashLoopBackOff` / `lfstack.push` on CRC Mac | Wrong image arch — script auto-detects `arm64`; re-run `./scripts/run-openshift.sh` |
| Inference `ImagePullBackOff` on `ghcr.io` (403) | CRC cannot pull ghcr.io — use Quay via `./scripts/run-openshift.sh` |
| `unauthorized` on Quay push | Export `QUAY_USERNAME` + `QUAY_TOKEN`, then `podman login quay.io` |
| Sidecar `CrashLoopBackOff` after SCC fix | Tier 3 bug — add `SIDECAR_LOG_DIR` and mount `/var/log/sidecar` (Step 4c) |
| `oc apply` sample only after fix | Operator image is stale — always `./scripts/run-openshift.sh` to rebuild and roll out |



### Symptoms (quick reference)

```
unable to validate against any security context constraint
CreateContainerConfigError
hostPath volumes are not allowed
runAsUser: 0 is not allowed
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

