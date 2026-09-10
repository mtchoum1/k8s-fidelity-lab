# Image URL to use all building/pushing image targets
IMG ?= ghcr.io/k8s-fidelity-lab/operator:latest
INFERENCE_IMG ?= ghcr.io/k8s-fidelity-lab/inference-server:latest
SIDECAR_IMG ?= ghcr.io/k8s-fidelity-lab/metrics-sidecar:latest

.PHONY: all
all: build

.PHONY: fmt
fmt:
	go fmt ./...

.PHONY: vet
vet:
	go vet ./...

.PHONY: test
test: fmt vet
	go test ./controllers/... -v -coverprofile cover.out

.PHONY: build
build:
	go build -o bin/manager main.go

.PHONY: run
run:
	go run ./main.go

.PHONY: uv-sync
uv-sync:
	uv venv --python 3.11
	uv sync

.PHONY: podman-build
podman-build:
	podman build -t ${IMG} .

.PHONY: podman-build-inference
podman-build-inference:
	podman build -t ${INFERENCE_IMG} -f Dockerfile.inference .

.PHONY: podman-build-sidecar
podman-build-sidecar:
	podman build -t ${SIDECAR_IMG} -f Dockerfile.sidecar .

CONTROLLER_GEN ?= $(shell go env GOPATH)/bin/controller-gen
CONTROLLER_GEN_VERSION ?= v0.15.0

.PHONY: manifests
manifests:
	@test -x "$(CONTROLLER_GEN)" || { \
		echo "Installing controller-gen $(CONTROLLER_GEN_VERSION) to $(CONTROLLER_GEN)..."; \
		go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_GEN_VERSION); \
	}
	"$(CONTROLLER_GEN)" crd paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: install
install:
	kubectl apply -f config/crd/bases/

.PHONY: deploy
deploy:
	kubectl apply -f config/operator/

.PHONY: lab-verify
lab-verify:
	./scripts/lab-verify.sh

.PHONY: lab-reset
lab-reset:
	./scripts/lab-reset.sh

.PHONY: lab-status
lab-status:
	./lab status

# Run a single tier: make lab-run TIER=3
.PHONY: lab-run
lab-run:
	@test -n "$(TIER)" || (echo "Usage: make lab-run TIER=1"; exit 1)
	./lab run $(TIER)
