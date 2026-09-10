# Tier 4: Inner-loop live updates for PR #104 (hot-reload sidecar env-var fix).
# Uses Podman via DOCKER_HOST — run ./scripts/tilt-up.sh (not bare `tilt up`).
allow_k8s_contexts('kind-fidelity-kind')

docker_build(
    'ghcr.io/k8s-fidelity-lab/operator',
    '.',
    dockerfile='Dockerfile',
    live_update=[
        sync('./controllers', '/workspace/controllers'),
        sync('./api', '/workspace/api'),
        run('go build -o /manager main.go', trigger=['./controllers', './api', './main.go']),
    ],
)

docker_build(
    'ghcr.io/k8s-fidelity-lab/inference-server',
    '.',
    dockerfile='Dockerfile.inference',
)

docker_build(
    'ghcr.io/k8s-fidelity-lab/metrics-sidecar',
    '.',
    dockerfile='Dockerfile.sidecar',
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
