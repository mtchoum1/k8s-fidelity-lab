# Tier 4: Inner-loop live updates for PR #104 (hot-reload sidecar env-var fix).
# Builds with Podman and loads into kind via image-archive. Tilt's built-in
# "kind load" step fails with Podman — run ./scripts/tilt-up.sh (not bare tilt up).
allow_k8s_contexts('kind-fidelity-kind')

CLUSTER_NAME = 'fidelity-kind'
OPERATOR_IMAGE = 'ghcr.io/k8s-fidelity-lab/operator:latest'
INFERENCE_IMAGE = 'ghcr.io/k8s-fidelity-lab/inference-server:latest'
SIDECAR_IMAGE = 'ghcr.io/k8s-fidelity-lab/metrics-sidecar:latest'

def podman_kind_build(image, dockerfile, deps, live_update=None):
    """Build with podman and load into kind (same pattern as scripts/container.sh)."""
    cmd = (
        'set -euo pipefail; '
        + 'podman build -t "$EXPECTED_REF" -f ' + dockerfile + ' .; '
        + 'tar="$(mktemp "${TMPDIR:-/tmp}/tilt-kind-XXXXXX.tar")"; '
        + 'podman save "$EXPECTED_REF" -o "$tar"; '
        + 'kind load image-archive "$tar" --name ' + CLUSTER_NAME + '; '
        + 'rm -f "$tar"'
    )
    kwargs = {
        'deps': deps,
        'disable_push': True,
        'skips_local_docker': True,
    }
    if live_update != None:
        kwargs['live_update'] = live_update
    custom_build(image, cmd, **kwargs)

# Tell Tilt where images live in our CRD (not a built-in Pod spec).
k8s_kind(
    'ModelInferencePipeline',
    api_version='fidelity.ai/v1alpha1',
    image_json_path=['{.spec.image}', '{.spec.sidecarImage}'],
    pod_readiness='wait',
)

podman_kind_build(
    OPERATOR_IMAGE,
    'Dockerfile',
    deps=['./controllers', './api', './main.go', 'Dockerfile', 'go.mod', 'go.sum'],
    live_update=[
        sync('./controllers', '/workspace/controllers'),
        sync('./api', '/workspace/api'),
        run('go build -o /manager main.go', trigger=['./controllers', './api', './main.go']),
    ],
)

podman_kind_build(
    INFERENCE_IMAGE,
    'Dockerfile.inference',
    deps=['./inference_server.py', 'Dockerfile.inference'],
)

podman_kind_build(
    SIDECAR_IMAGE,
    'Dockerfile.sidecar',
    deps=['./sidecar_entrypoint.sh', 'Dockerfile.sidecar'],
    live_update=[
        sync('./sidecar_entrypoint.sh', '/usr/local/bin/sidecar-entrypoint.sh'),
    ],
)

k8s_yaml([
    'config/crd/bases/fidelity.ai_modelinferencepipelines.yaml',
    'config/operator/deployment.yaml',
    'config/samples/modelpipeline_v1alpha1_pr104.yaml',
])

k8s_resource('fidelity-lab-operator', port_forwards=['8080:8080', '8081:8081'])

# Operator creates inference pods with this label — attach them to the CR resource.
k8s_resource(
    'pr104-gpu-batch-pipeline',
    extra_pod_selectors=[{'fidelity.ai/pipeline': 'pr104-gpu-batch-pipeline'}],
    resource_deps=['fidelity-lab-operator'],
)
