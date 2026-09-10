# PR #104 Facilitator Guide

**Audience:** Workshop instructors, lab maintainers  
**Duration:** 90 min (lightning) to 6 h (full platform track)  
**Prerequisite:** Learners have forked/cloned repo and run `./lab verify` successfully.

## Agenda Options

| Mode | Tiers | Time | Skip |
|------|-------|------|------|
| Lightning | 1 → 3 → 7 (demo) | 60 min | 2, 4, 5, 6 live |
| Developer | 1 → 4 | 2 h | 5, 7 or slide-only |
| Platform | 1 → 7 | 4–6 h | none |

Recommended flow: **demonstrate failure → `./lab hint N` → learner fixes → re-run tier**.

## Pre-Workshop Checklist

```bash
# On instructor machine / CI:
./lab verify                    # must PASS on main
git tag lab-v1.0-pr104          # publish frozen baseline tag

# Learner setup (5 min):
git clone <fork-url>
cd k8s-fidelity-lab
chmod +x lab scripts/*.sh kwok/generate-nodes.sh
git checkout -b lab/<name> lab-v1.0-pr104
./lab verify
```

| Requirement | Tier | Notes |
|-------------|------|-------|
| Go 1.22+ | 1 | envtest auto-installs via setup-envtest |
| KWOK | 2 | `PIPELINE_COUNT=10` for dry-run |
| Podman + kind | 3–4 | 8 GB RAM minimum |
| OLM + kind | 5 | 12 GB RAM; allow 10 min install |
| ArgoCD | 6 | Can demo with `kubectl kustomize` only |
| OpenShift sandbox | 7 | Or slide + `oc describe` recording |

## Tier-by-Tier: Expected Failures

### Tier 1 — envtest (~10 min)

**Run:** `./lab run 1`

| Check | Expected on baseline |
|-------|---------------------|
| `go test ./controllers/...` | 3 specs PASS (tests *document* bugs) |
| Missing `gpuMemoryRequirement` | Admission rejection |
| `gpuMemoryRequirement: "8Gi"` | Panic in `buildDeployment` |

**Talking point:** Unit tests catch schema and nil-pointer logic; they do not run containers.

**Common rabbit hole:** Learners fix Go types but forget `make manifests` / CRD regen.

---

### Tier 2 — KWOK (~15 min)

**Run:** `./lab run 2` (use `PIPELINE_COUNT=20` for short demo)

**Expected:** Controller requeues indefinitely; status never reaches `Running` at scale.

**Log line to highlight:** `waiting on pod status updates`

**Fix location:** `waitForPodStatuses` + `podStatusPollLock` in `modelpipeline_controller.go`

---

### Tier 3 — kind (~20 min)

**Run:** `./lab run 3`

**Expected:**
```
metrics-sidecar: error: SIDECAR_LOG_DIR environment variable is required
```

**Verify:** `kubectl logs <pod> -c metrics-sidecar`

**Fix:** Add env to `buildSidecarContainer`:
```go
Env: []corev1.EnvVar{{Name: "SIDECAR_LOG_DIR", Value: "/var/log/sidecar"}},
```

---

### Tier 4 — Tilt (~10 min)

**Run:** `./lab run 4` (after Tier 3 kind cluster exists)

**Expected:** Hot-reload in < 3 s after controller fix.

**Talking point:** Same fidelity as kind; 10× faster iteration — measure and log in scorecard.

---

### Tier 5 — rhoai-in-kind (~15 min demo / 45 min hands-on)

**Run:** `./lab run 5`

**Expected:** `InferenceService` apiVersion `serving.kserve.io/v1beta1` not served.

**Shortcut for crowded rooms:** `grep apiVersion rhoai/inferenceservice-v1beta1.yaml` + explain without full ODH install.

---

### Tier 6 — ArgoCD (~10 min)

**Run:** `./lab run 6`

**Expected:**
```bash
kubectl kustomize config/overlays/pr104
# error: unable to find patch matching path /spec/sidecarLoging
```

**Fix:** Typo `sidecarLoging` → `sidecarLogging` in `sidecar-patch.yaml`

**ArgoCD UI:** Application `fidelity-lab-pr104` shows `SyncFailed` until fixed.

---

### Tier 7 — OpenShift (~15 min)

**Run:** `./lab run 7` or pre-recorded `oc describe pod` output

**Expected:** `CreateContainerConfigError` — SCC `restricted-v2` denies `runAsUser: 0` + hostPath `/var/log`.

**Fix checklist:**
- [ ] `runAsNonRoot: true` on sidecar
- [ ] Replace `hostPath` with `emptyDir`
- [ ] Set `SIDECAR_LOG_DIR` to mounted emptyDir path

---

## Baseline Integrity (CI)

Add to pipeline on `main`:

```bash
./lab verify
```

If this fails on `main`, someone merged a fix or broke a marker comment. Do **not** run workshop until restored:

```bash
git checkout main
./lab reset
./lab verify
```

## Solution Branches (instructor only)

Maintain optional branches for demos:

```
solutions/tier-01-schema
solutions/tier-02-scale
...
solutions/tier-07-openshift
```

Each branch = cumulative fixes through that tier. Do not publish to learners until after the session.

## Troubleshooting

| Symptom | Cause | Action |
|---------|-------|--------|
| `./lab verify` fails on fresh clone | Missing setup-envtest | `go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest` |
| Tier 3 pods ImagePullBackOff | Images not loaded into kind | Re-run `./lab run 3` |
| Tier 6 kustomize succeeds | Bug already fixed | `./lab reset` |
| Learner fixed bugs on main | Skipped Step 0 | `git checkout main && ./lab reset` |

## Reset Between Cohorts

```bash
git checkout main
git pull
./lab verify
# tag new cohort if needed:
git tag lab-v1.0-pr104-cohort2
```

Learners always start: `git checkout -b lab/name lab-v1.0-pr104`
