# Image URL to use all building/pushing image targets
IMG ?= ghcr.io/k8s-fidelity-lab/operator:latest
INFERENCE_IMG ?= ghcr.io/k8s-fidelity-lab/inference-server:latest

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

.PHONY: manifests
manifests:
	@command -v controller-gen >/dev/null 2>&1 || { \
		echo "Install controller-gen: go install sigs.k8s.io/controller-tools/cmd/controller-gen@latest"; \
		exit 1; \
	}
	controller-gen crd paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: install
install:
	kubectl apply -f config/crd/bases/

.PHONY: deploy
deploy:
	kubectl apply -f config/operator/
