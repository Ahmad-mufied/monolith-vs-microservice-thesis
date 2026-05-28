SHELL := /bin/bash
.DEFAULT_GOAL := help

# =========================
# Paths
# =========================

MONOLITH_DIR := monolith

API_GATEWAY_DIR := microservices/api-gateway
AUTH_SERVICE_DIR := microservices/auth-service
ITEM_SERVICE_DIR := microservices/item-service
TRANSACTION_SERVICE_DIR := microservices/transaction-service

COMPOSE_DIR := deployments/compose
K8S_DIR := deployments/k8s
HELM_DIR := deployments/helm

# =========================
# Images
# =========================

MONOLITH_IMAGE := skripsi/monolith:local
API_GATEWAY_IMAGE := skripsi/api-gateway:local
AUTH_SERVICE_IMAGE := skripsi/auth-service:local
ITEM_SERVICE_IMAGE := skripsi/item-service:local
TRANSACTION_SERVICE_IMAGE := skripsi/transaction-service:local
SEED_IMAGE := skripsi/seed-runner:local

MINIKUBE_CPUS ?= 2
MINIKUBE_MEMORY ?= 3072
MINIKUBE_DISK_SIZE ?= 20g
MINIKUBE_NODE_CONTAINER ?= minikube
MONOLITH_PORT ?= 8080
API_GATEWAY_PORT ?= 8080
DATADOG_NAMESPACE ?= datadog
DATADOG_RELEASE ?= datadog
DATADOG_SITE ?= $(shell if [ -f env/datadog.eks.env ]; then grep -E '^DATADOG_SITE=' env/datadog.eks.env | head -n 1 | cut -d= -f2-; else printf '%s' 'datadoghq.com'; fi)
DATADOG_CHART_VERSION ?= 3.134.0
TERRAFORM_AWS_PROFILE ?= terraform-process

# =========================
# Env Files
# =========================

MONOLITH_ENV := env/monolith.env
API_GATEWAY_ENV := env/api-gateway.env
AUTH_SERVICE_ENV := env/auth-service.env
ITEM_SERVICE_ENV := env/item-service.env
TRANSACTION_SERVICE_ENV := env/transaction-service.env
AWS_BENCHMARK_ENV := env/aws-benchmark.env
TERRAFORM_SHARED_ENV := env/terraform.shared.env
TERRAFORM_EXPERIMENT_ENV := env/terraform.experiment.env
DATADOG_EKS_ENV := env/datadog.eks.env
EKS_IMAGE_TAG_ENV := env/image-tag.eks.env

# =========================
# Tooling
# =========================

GOLANGCI_LINT ?= golangci-lint
GOLANGCI_LINT_INSTALL ?= go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest
GOSEC ?= gosec
GOSEC_INSTALL ?= go install github.com/securego/gosec/v2/cmd/gosec@latest

# =========================
# Help
# =========================

.PHONY: help
help:
	@echo "Available commands:"
	@echo ""
	@echo "Development:"
	@echo "  make env-init-base"
	@echo "  make env-init-datadog-minikube"
	@echo "  make env-init-monolith"
	@echo "  make env-init-microservices"
	@echo "  make env-init-eks"
	@echo "  make fmt"
	@echo "  make test"
	@echo "  make lint"
	@echo "  make lint-install"
	@echo "  make golint"
	@echo "  make gosec"
	@echo "  make fix"
	@echo "  make gofix"
	@echo "  make tidy"
	@echo "  make proto"
	@echo ""
	@echo "Run locally with go run:"
	@echo "  make run-monolith"
	@echo "  make run-monolith-local"
	@echo "  make run-api-gateway"
	@echo "  make run-auth-service"
	@echo "  make run-item-service"
	@echo "  make run-transaction-service"
	@echo "  make run-api-gateway-local"
	@echo "  make run-auth-service-local"
	@echo "  make run-item-service-local"
	@echo "  make run-transaction-service-local"
	@echo ""
	@echo "Docker Compose:"
	@echo "  make compose-db-up"
	@echo "  make compose-monolith-up"
	@echo "  make compose-microservices-up"
	@echo "  make compose-down"
	@echo ""
	@echo "Migration:"
	@echo "  make migrate-monolith-local"
	@echo "  make migrate-monolith"
	@echo "  make migrate-microservices"
	@echo "  make migrate-microservices-local"
	@echo ""
	@echo "Seed and Reset:"
	@echo "  make reset-monolith-data"
	@echo "  make seed-monolith-data DATASET=smoke"
	@echo "  make seed-monolith-data DATASET=benchmark"
	@echo "  make prepare-monolith-enrichment-data DATASET=smoke"
	@echo "  make prepare-monolith-enrichment-data DATASET=benchmark"
	@echo "  make reset-microservices-data"
	@echo "  make seed-microservices-data DATASET=smoke"
	@echo "  make seed-microservices-data DATASET=benchmark"
	@echo "  make prepare-microservices-enrichment-data DATASET=smoke"
	@echo "  make prepare-microservices-enrichment-data DATASET=benchmark"
	@echo ""
	@echo "Minikube:"
	@echo "  make minikube-start"
	@echo "  make minikube-stop"
	@echo "  make minikube-delete"
	@echo "  make minikube-load-monolith"
	@echo "  make minikube-load-microservices"
	@echo "  make minikube-deploy-postgres"
	@echo "  make minikube-sync-postgres-password  # internal recovery step"
	@echo "  make minikube-db-bootstrap"
	@echo "  make minikube-migrate-monolith"
	@echo "  make minikube-reset-monolith-data"
	@echo "  make minikube-seed-monolith-smoke"
	@echo "  make minikube-seed-monolith-benchmark"
	@echo "  make minikube-bootstrap-monolith-smoke"
	@echo "  make minikube-bootstrap-monolith-benchmark"
	@echo "  make minikube-prepare-monolith-enrichment-smoke"
	@echo "  make minikube-prepare-monolith-enrichment-benchmark"
	@echo "  make minikube-bootstrap-monolith-enrichment-smoke"
	@echo "  make minikube-bootstrap-monolith-enrichment-benchmark"
	@echo "  make minikube-deploy-monolith"
	@echo "  make minikube-migrate-microservices"
	@echo "  make minikube-reset-microservices-data"
	@echo "  make minikube-seed-microservices-smoke"
	@echo "  make minikube-seed-microservices-benchmark"
	@echo "  make minikube-bootstrap-microservices-smoke"
	@echo "  make minikube-bootstrap-microservices-benchmark"
	@echo "  make minikube-prepare-microservices-enrichment-smoke"
	@echo "  make minikube-prepare-microservices-enrichment-benchmark"
	@echo "  make minikube-bootstrap-microservices-enrichment-smoke"
	@echo "  make minikube-bootstrap-microservices-enrichment-benchmark"
	@echo "  make minikube-deploy-microservices"
	@echo "  make minikube-port-forward-monolith"
	@echo "  make minikube-port-forward-api-gateway"
	@echo "  make minikube-load-images"
	@echo "  make minikube-deploy-monolith-hpa"
	@echo "  make minikube-deploy-microservices-hpa"
	@echo "  make datadog-secret"
	@echo "  make datadog-install-minikube"
	@echo "  make datadog-install-eks-monolith"
	@echo "  make datadog-install-eks-msa"
	@echo "  make datadog-status"
	@echo "  make datadog-uninstall"
	@echo "  make ecr-check-tag"
	@echo "  make eks-show-image-tag"
	@echo "  make eks-pin-image-tag IMAGE_TAG=<tag>"
	@echo "  make eks-unpin-image-tag"
	@echo "  make eks-render-manifests"
	@echo "  make eks-render-tfvars"
	@echo "  make terraform-auth-check"
	@echo "  make terraform-recovery-check"
	@echo "  make terraform-recovery-fix-tainted-nodegroups      # dry-run safe untaint suggestions"
	@echo "  make terraform-recovery-fix-tainted-nodegroups-apply # untaint active healthy node groups"
	@echo "  make eks-prepare-enrichment-benchmark"
	@echo "  make run-benchmark-suite SCALING_MODE=fixed TEST_DURATION=5m RPS_LEVELS=\"1000 2500 5000\""
	@echo "  make eks-create-secrets"
	@echo "  make create-eks-secrets-monolith"
	@echo "  make create-eks-secrets-microservices"
	@echo "  make eks-deploy-all"
	@echo "  make eks-deploy-all-fixed"
	@echo "  make eks-deploy-all-hpa"
	@echo "  make create-local-postgres-secrets"
	@echo "  make create-local-secrets"
	@echo "  make create-local-secrets-microservices"
	@echo ""

# =========================
# Local Env
# =========================

.PHONY: env-init-base
env-init-base:
	bash scripts/env-init-base.sh

.PHONY: env-init-datadog-minikube
env-init-datadog-minikube:
	bash scripts/env-init-datadog-minikube.sh

.PHONY: env-init-monolith
env-init-monolith: env-init-base
	bash scripts/env-init-monolith.sh

.PHONY: env-init-microservices
env-init-microservices: env-init-base
	bash scripts/env-init-microservices.sh

.PHONY: env-init-eks
env-init-eks:
	bash scripts/env-init-eks.sh

# =========================
# Go Development
# =========================

.PHONY: fmt
fmt:
	cd $(MONOLITH_DIR) && go fmt ./...
	cd $(API_GATEWAY_DIR) && go fmt ./...
	cd $(AUTH_SERVICE_DIR) && go fmt ./...
	cd $(ITEM_SERVICE_DIR) && go fmt ./...
	cd $(TRANSACTION_SERVICE_DIR) && go fmt ./...

.PHONY: test
test:
	cd $(MONOLITH_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then go test ./...; else echo "skip test ($(MONOLITH_DIR)): no go packages"; fi
	cd $(API_GATEWAY_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then go test ./...; else echo "skip test ($(API_GATEWAY_DIR)): no go packages"; fi
	cd $(AUTH_SERVICE_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then go test ./...; else echo "skip test ($(AUTH_SERVICE_DIR)): no go packages"; fi
	cd $(ITEM_SERVICE_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then go test ./...; else echo "skip test ($(ITEM_SERVICE_DIR)): no go packages"; fi
	cd $(TRANSACTION_SERVICE_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then go test ./...; else echo "skip test ($(TRANSACTION_SERVICE_DIR)): no go packages"; fi

.PHONY: lint-install
lint-install:
	$(GOLANGCI_LINT_INSTALL)

.PHONY: lint golint
lint:
	@command -v $(GOLANGCI_LINT) >/dev/null || (echo "golangci-lint not found. Install with: make lint-install"; exit 1)
	cd $(MONOLITH_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then $(GOLANGCI_LINT) run --config="$(CURDIR)/.golangci.yml" ./...; else echo "skip lint ($(MONOLITH_DIR)): no go packages"; fi
	cd $(API_GATEWAY_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then $(GOLANGCI_LINT) run --config="$(CURDIR)/.golangci.yml" ./...; else echo "skip lint ($(API_GATEWAY_DIR)): no go packages"; fi
	cd $(AUTH_SERVICE_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then $(GOLANGCI_LINT) run --config="$(CURDIR)/.golangci.yml" ./...; else echo "skip lint ($(AUTH_SERVICE_DIR)): no go packages"; fi
	cd $(ITEM_SERVICE_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then $(GOLANGCI_LINT) run --config="$(CURDIR)/.golangci.yml" ./...; else echo "skip lint ($(ITEM_SERVICE_DIR)): no go packages"; fi
	cd $(TRANSACTION_SERVICE_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then $(GOLANGCI_LINT) run --config="$(CURDIR)/.golangci.yml" ./...; else echo "skip lint ($(TRANSACTION_SERVICE_DIR)): no go packages"; fi

golint: lint

.PHONY: gosec-install
gosec-install:
	$(GOSEC_INSTALL)

.PHONY: gosec security
gosec:
	@command -v $(GOSEC) >/dev/null || (echo "gosec not found. Install with: make gosec-install"; exit 1)
	cd $(MONOLITH_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then $(GOSEC) ./...; else echo "skip gosec ($(MONOLITH_DIR)): no go packages"; fi
	cd $(API_GATEWAY_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then $(GOSEC) ./...; else echo "skip gosec ($(API_GATEWAY_DIR)): no go packages"; fi
	cd $(AUTH_SERVICE_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then $(GOSEC) ./...; else echo "skip gosec ($(AUTH_SERVICE_DIR)): no go packages"; fi
	cd $(ITEM_SERVICE_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then $(GOSEC) ./...; else echo "skip gosec ($(ITEM_SERVICE_DIR)): no go packages"; fi
	cd $(TRANSACTION_SERVICE_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then $(GOSEC) ./...; else echo "skip gosec ($(TRANSACTION_SERVICE_DIR)): no go packages"; fi

security: gosec

.PHONY: gofix go-fix fix
gofix:
	@for d in "$(MONOLITH_DIR)" "$(API_GATEWAY_DIR)" "$(AUTH_SERVICE_DIR)" "$(ITEM_SERVICE_DIR)" "$(TRANSACTION_SERVICE_DIR)"; do \
		pkgs="$$(go list ./$$d/... 2>/tmp/gofix-go-list.err)" || { echo "go list failed ($$d):"; sed -n '1,10p' /tmp/gofix-go-list.err; exit 1; }; \
		if [ -n "$$pkgs" ]; then go fix ./$$d/...; else echo "skip fix ($$d): no go packages"; fi; \
	done

go-fix: gofix
fix: gofix

.PHONY: tidy
tidy:
	cd $(MONOLITH_DIR) && go mod tidy
	cd $(API_GATEWAY_DIR) && go mod tidy
	cd $(AUTH_SERVICE_DIR) && go mod tidy
	cd $(ITEM_SERVICE_DIR) && go mod tidy
	cd $(TRANSACTION_SERVICE_DIR) && go mod tidy
	go work sync

.PHONY: proto
proto:
	buf generate

# =========================
# Run Locally with Go
# =========================

.PHONY: run-monolith
run-monolith:
	cd $(MONOLITH_DIR) && go run ./cmd/server

.PHONY: run-monolith-local
run-monolith-local:
	bash -c 'set -euo pipefail; set -a; source $(MONOLITH_ENV); DATABASE_URL="$${MONO_DATABASE_URL:?MONO_DATABASE_URL is required}"; set +a; cd $(MONOLITH_DIR) && go run ./cmd/server'

.PHONY: run-api-gateway
run-api-gateway:
	cd $(API_GATEWAY_DIR) && go run ./cmd/server

.PHONY: run-auth-service
run-auth-service:
	cd $(AUTH_SERVICE_DIR) && go run ./cmd/server

.PHONY: run-item-service
run-item-service:
	cd $(ITEM_SERVICE_DIR) && go run ./cmd/server

.PHONY: run-transaction-service
run-transaction-service:
	cd $(TRANSACTION_SERVICE_DIR) && go run ./cmd/server

.PHONY: run-api-gateway-local
run-api-gateway-local:
	bash -c 'set -euo pipefail; set -a; source $(API_GATEWAY_ENV); set +a; cd $(API_GATEWAY_DIR) && go run ./cmd/server'

.PHONY: run-auth-service-local
run-auth-service-local:
	bash -c 'set -euo pipefail; set -a; source $(AUTH_SERVICE_ENV); set +a; cd $(AUTH_SERVICE_DIR) && go run ./cmd/server'

.PHONY: run-item-service-local
run-item-service-local:
	bash -c 'set -euo pipefail; set -a; source $(ITEM_SERVICE_ENV); set +a; cd $(ITEM_SERVICE_DIR) && go run ./cmd/server'

.PHONY: run-transaction-service-local
run-transaction-service-local:
	bash -c 'set -euo pipefail; set -a; source $(TRANSACTION_SERVICE_ENV); set +a; cd $(TRANSACTION_SERVICE_DIR) && go run ./cmd/server'

# =========================
# Docker Build
# =========================

.PHONY: docker-build-monolith
docker-build-monolith:
	docker build -t $(MONOLITH_IMAGE) -f $(MONOLITH_DIR)/Dockerfile .

.PHONY: docker-build-seed
docker-build-seed:
	docker build -t $(SEED_IMAGE) -f seed/Dockerfile .

.PHONY: docker-build-microservices
docker-build-microservices:
	docker build -t $(API_GATEWAY_IMAGE) -f $(API_GATEWAY_DIR)/Dockerfile .
	docker build -t $(AUTH_SERVICE_IMAGE) -f $(AUTH_SERVICE_DIR)/Dockerfile .
	docker build -t $(ITEM_SERVICE_IMAGE) -f $(ITEM_SERVICE_DIR)/Dockerfile .
	docker build -t $(TRANSACTION_SERVICE_IMAGE) -f $(TRANSACTION_SERVICE_DIR)/Dockerfile .

.PHONY: docker-build-all
docker-build-all: docker-build-monolith docker-build-seed docker-build-microservices

# =========================
# Docker Compose
# =========================

.PHONY: compose-db-up
compose-db-up:
	docker compose -f $(COMPOSE_DIR)/docker-compose.db.yml up --build

.PHONY: compose-monolith-up
compose-monolith-up:
	docker compose -f $(COMPOSE_DIR)/docker-compose.monolith.yml up --build

.PHONY: compose-microservices-up
compose-microservices-up:
	docker compose -f $(COMPOSE_DIR)/docker-compose.microservices.yml up --build

.PHONY: compose-down
compose-down:
	docker compose -f $(COMPOSE_DIR)/docker-compose.db.yml down -v --remove-orphans || true
	docker compose -f $(COMPOSE_DIR)/docker-compose.monolith.yml down -v --remove-orphans || true
	docker compose -f $(COMPOSE_DIR)/docker-compose.microservices.yml down -v --remove-orphans || true

# =========================
# Migration
# =========================

.PHONY: migrate-monolith
migrate-monolith:
	goose -dir $(MONOLITH_DIR)/migrations postgres "$$MONO_DATABASE_URL" up

.PHONY: migrate-monolith-local
migrate-monolith-local:
	bash -c 'set -euo pipefail; set -a; source $(MONOLITH_ENV); set +a; goose -dir $(MONOLITH_DIR)/migrations postgres "$${MONO_DATABASE_URL:?MONO_DATABASE_URL is required}" up'

.PHONY: migrate-auth
migrate-auth:
	goose -dir $(AUTH_SERVICE_DIR)/migrations postgres "$$AUTH_DATABASE_URL" up

.PHONY: migrate-item
migrate-item:
	goose -dir $(ITEM_SERVICE_DIR)/migrations postgres "$$ITEM_DATABASE_URL" up

.PHONY: migrate-transaction
migrate-transaction:
	goose -dir $(TRANSACTION_SERVICE_DIR)/migrations postgres "$$TRANSACTION_DATABASE_URL" up

.PHONY: migrate-microservices
migrate-microservices: migrate-auth migrate-item migrate-transaction

.PHONY: migrate-microservices-local
migrate-microservices-local:
	bash -c 'set -euo pipefail; set -a; source $(AUTH_SERVICE_ENV); source $(ITEM_SERVICE_ENV); source $(TRANSACTION_SERVICE_ENV); : "$${AUTH_DATABASE_URL:?AUTH_DATABASE_URL is required}"; : "$${ITEM_DATABASE_URL:?ITEM_DATABASE_URL is required}"; : "$${TRANSACTION_DATABASE_URL:?TRANSACTION_DATABASE_URL is required}"; set +a; $(MAKE) migrate-microservices'

# =========================
# Seed and Reset
# =========================

.PHONY: seed-monolith-data
seed-monolith-data:
	@bash -ec 'set -a; source env/monolith.env; set +a; \
		: "$${MONO_DATABASE_URL:?MONO_DATABASE_URL is required}"; \
		cd seed && go run ./cmd/seed-runner seed-monolith-data \
			--dataset="$${DATASET:-smoke}" \
			--database-url="$$MONO_DATABASE_URL"'

.PHONY: seed-microservices-data
seed-microservices-data:
	@bash -ec 'set -a; source env/auth-service.env; source env/item-service.env; source env/transaction-service.env; set +a; \
		: "$${AUTH_DATABASE_URL:?AUTH_DATABASE_URL is required}"; \
		: "$${ITEM_DATABASE_URL:?ITEM_DATABASE_URL is required}"; \
		: "$${TRANSACTION_DATABASE_URL:?TRANSACTION_DATABASE_URL is required}"; \
		cd seed && go run ./cmd/seed-runner seed-microservices-data \
			--dataset="$${DATASET:-smoke}" \
			--auth-database-url="$$AUTH_DATABASE_URL" \
			--item-database-url="$$ITEM_DATABASE_URL" \
			--transaction-database-url="$$TRANSACTION_DATABASE_URL"'

.PHONY: reset-monolith-data
reset-monolith-data:
	@bash -ec 'set -a; source env/monolith.env; set +a; \
		: "$${MONO_DATABASE_URL:?MONO_DATABASE_URL is required}"; \
		cd seed && go run ./cmd/seed-runner reset-monolith-data \
			--database-url="$$MONO_DATABASE_URL"'

.PHONY: prepare-monolith-enrichment-data
prepare-monolith-enrichment-data:
	@bash -ec 'set -a; source env/monolith.env; set +a; \
		: "$${MONO_DATABASE_URL:?MONO_DATABASE_URL is required}"; \
		cd seed && go run ./cmd/seed-runner prepare-monolith-enrichment-data \
			--dataset="$${DATASET:-smoke}" \
			--database-url="$$MONO_DATABASE_URL"'

.PHONY: reset-microservices-data
reset-microservices-data:
	@bash -ec 'set -a; source env/auth-service.env; source env/item-service.env; source env/transaction-service.env; set +a; \
		: "$${AUTH_DATABASE_URL:?AUTH_DATABASE_URL is required}"; \
		: "$${ITEM_DATABASE_URL:?ITEM_DATABASE_URL is required}"; \
		: "$${TRANSACTION_DATABASE_URL:?TRANSACTION_DATABASE_URL is required}"; \
		cd seed && go run ./cmd/seed-runner reset-microservices-data \
			--auth-database-url="$$AUTH_DATABASE_URL" \
			--item-database-url="$$ITEM_DATABASE_URL" \
			--transaction-database-url="$$TRANSACTION_DATABASE_URL"'

.PHONY: prepare-microservices-enrichment-data
prepare-microservices-enrichment-data:
	@bash -ec 'set -a; source env/auth-service.env; source env/item-service.env; source env/transaction-service.env; set +a; \
		: "$${AUTH_DATABASE_URL:?AUTH_DATABASE_URL is required}"; \
		: "$${ITEM_DATABASE_URL:?ITEM_DATABASE_URL is required}"; \
		: "$${TRANSACTION_DATABASE_URL:?TRANSACTION_DATABASE_URL is required}"; \
		cd seed && go run ./cmd/seed-runner prepare-microservices-enrichment-data \
			--dataset="$${DATASET:-smoke}" \
			--auth-database-url="$$AUTH_DATABASE_URL" \
			--item-database-url="$$ITEM_DATABASE_URL" \
			--transaction-database-url="$$TRANSACTION_DATABASE_URL"'

# =========================
# Kubernetes Local Secrets
# =========================

.PHONY: create-local-postgres-secrets
create-local-postgres-secrets:
	bash scripts/create-local-postgres-secrets.sh

.PHONY: create-local-secrets
create-local-secrets:
	bash scripts/create-local-secrets.sh

.PHONY: create-local-secrets-microservices
create-local-secrets-microservices:
	bash scripts/create-local-secrets-microservices.sh

# =========================
# Minikube
# =========================

.PHONY: minikube-start
minikube-start:
	minikube start --driver=docker --cpus=$(MINIKUBE_CPUS) --memory=$(MINIKUBE_MEMORY) --disk-size=$(MINIKUBE_DISK_SIZE)
	minikube addons enable ingress
	minikube addons enable metrics-server

.PHONY: minikube-stop
minikube-stop:
	minikube stop

.PHONY: minikube-delete
minikube-delete:
	minikube delete

.PHONY: minikube-load-images
minikube-load-images: minikube-load-monolith minikube-load-microservices

.PHONY: minikube-load-seed
minikube-load-seed: docker-build-seed
	docker save $(SEED_IMAGE) | docker exec -i $(MINIKUBE_NODE_CONTAINER) docker load

.PHONY: minikube-load-monolith
minikube-load-monolith: minikube-load-seed docker-build-monolith
	docker save $(MONOLITH_IMAGE) | docker exec -i $(MINIKUBE_NODE_CONTAINER) docker load

.PHONY: minikube-load-microservices
minikube-load-microservices: minikube-load-seed docker-build-microservices
	docker save $(API_GATEWAY_IMAGE) | docker exec -i $(MINIKUBE_NODE_CONTAINER) docker load
	docker save $(AUTH_SERVICE_IMAGE) | docker exec -i $(MINIKUBE_NODE_CONTAINER) docker load
	docker save $(ITEM_SERVICE_IMAGE) | docker exec -i $(MINIKUBE_NODE_CONTAINER) docker load
	docker save $(TRANSACTION_SERVICE_IMAGE) | docker exec -i $(MINIKUBE_NODE_CONTAINER) docker load

.PHONY: minikube-deploy-postgres
minikube-deploy-postgres: create-local-postgres-secrets
	kubectl apply -f $(K8S_DIR)/namespaces/local.yaml
	kubectl apply -f $(K8S_DIR)/local/shared/postgres.yaml
	kubectl wait --for=condition=ready pod/postgres-0 -n local-database --timeout=180s
	$(MAKE) minikube-sync-postgres-password

.PHONY: minikube-sync-postgres-password
minikube-sync-postgres-password:
	@test -f env/postgres.env || { echo "missing env/postgres.env; run: make env-init-base" >&2; exit 1; }
	set -a; . env/postgres.env; set +a; \
	: "$${POSTGRES_USER:?POSTGRES_USER must be set in env/postgres.env}"; \
	: "$${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set in env/postgres.env}"; \
	kubectl exec -n local-database postgres-0 -- env \
	POSTGRES_USER="$$POSTGRES_USER" \
	POSTGRES_PASSWORD="$$POSTGRES_PASSWORD" \
	/bin/sh -ec 'printf "%s\n" "SELECT format('\''ALTER USER %I WITH PASSWORD %L'\'', :'\''role'\'', :'\''password'\'') \gexec" | psql -v ON_ERROR_STOP=1 -v role="$$POSTGRES_USER" -v password="$$POSTGRES_PASSWORD" -U "$$POSTGRES_USER" -d postgres'

.PHONY: minikube-db-bootstrap
minikube-db-bootstrap: minikube-deploy-postgres
	kubectl delete job db-bootstrap-job -n local-database --ignore-not-found
	kubectl apply -f $(K8S_DIR)/local/shared/db-bootstrap-job.yaml
	kubectl wait --for=condition=complete job/db-bootstrap-job -n local-database --timeout=180s

.PHONY: minikube-migrate-monolith
minikube-migrate-monolith: minikube-load-monolith create-local-secrets minikube-db-bootstrap
	kubectl delete job monolith-migration-job -n mono --ignore-not-found
	kubectl apply -f $(K8S_DIR)/local/monolith/migration-job.yaml
	kubectl wait --for=condition=complete job/monolith-migration-job -n mono --timeout=180s

.PHONY: minikube-reset-monolith-data
minikube-reset-monolith-data: minikube-load-seed create-local-secrets
	kubectl delete job reset-monolith-data-job -n mono --ignore-not-found
	kubectl apply -f $(K8S_DIR)/local/monolith/reset-monolith-data-job.yaml
	kubectl wait --for=condition=complete job/reset-monolith-data-job -n mono --timeout=180s

.PHONY: minikube-seed-monolith-smoke
minikube-seed-monolith-smoke: minikube-reset-monolith-data
	kubectl delete job seed-monolith-smoke-data-job -n mono --ignore-not-found
	kubectl apply -f $(K8S_DIR)/local/monolith/seed-monolith-smoke-data-job.yaml
	kubectl wait --for=condition=complete job/seed-monolith-smoke-data-job -n mono --timeout=180s

.PHONY: minikube-seed-monolith-benchmark
minikube-seed-monolith-benchmark: minikube-reset-monolith-data
	kubectl delete job seed-monolith-benchmark-data-job -n mono --ignore-not-found
	kubectl apply -f $(K8S_DIR)/local/monolith/seed-monolith-benchmark-data-job.yaml
	kubectl wait --for=condition=complete job/seed-monolith-benchmark-data-job -n mono --timeout=300s

.PHONY: minikube-bootstrap-monolith-smoke
minikube-bootstrap-monolith-smoke:
	$(MAKE) minikube-migrate-monolith
	$(MAKE) minikube-seed-monolith-smoke
	$(MAKE) minikube-deploy-monolith

.PHONY: minikube-bootstrap-monolith-benchmark
minikube-bootstrap-monolith-benchmark:
	$(MAKE) minikube-migrate-monolith
	$(MAKE) minikube-seed-monolith-benchmark
	$(MAKE) minikube-deploy-monolith

.PHONY: minikube-prepare-monolith-enrichment-smoke
minikube-prepare-monolith-enrichment-smoke: minikube-load-seed create-local-secrets
	kubectl delete job prepare-monolith-enrichment-smoke-data-job -n mono --ignore-not-found
	kubectl apply -f $(K8S_DIR)/local/monolith/prepare-monolith-enrichment-smoke-data-job.yaml
	kubectl wait --for=condition=complete job/prepare-monolith-enrichment-smoke-data-job -n mono --timeout=180s

.PHONY: minikube-prepare-monolith-enrichment-benchmark
minikube-prepare-monolith-enrichment-benchmark: minikube-load-seed create-local-secrets
	kubectl delete job prepare-monolith-enrichment-benchmark-data-job -n mono --ignore-not-found
	kubectl apply -f $(K8S_DIR)/local/monolith/prepare-monolith-enrichment-benchmark-data-job.yaml
	kubectl wait --for=condition=complete job/prepare-monolith-enrichment-benchmark-data-job -n mono --timeout=180s

.PHONY: minikube-bootstrap-monolith-enrichment-smoke
minikube-bootstrap-monolith-enrichment-smoke:
	$(MAKE) minikube-migrate-monolith
	$(MAKE) minikube-seed-monolith-smoke
	$(MAKE) minikube-prepare-monolith-enrichment-smoke
	$(MAKE) minikube-deploy-monolith

.PHONY: minikube-bootstrap-monolith-enrichment-benchmark
minikube-bootstrap-monolith-enrichment-benchmark:
	$(MAKE) minikube-migrate-monolith
	$(MAKE) minikube-seed-monolith-benchmark
	$(MAKE) minikube-prepare-monolith-enrichment-benchmark
	$(MAKE) minikube-deploy-monolith

.PHONY: minikube-deploy-monolith
minikube-deploy-monolith: minikube-load-monolith create-local-secrets
	kubectl apply -f $(K8S_DIR)/local/monolith/monolith.yaml
	kubectl apply -f $(K8S_DIR)/local/monolith/resource-management-fixed.yaml
	kubectl apply -f $(K8S_DIR)/local/monolith/ingress.yaml
	kubectl rollout restart deployment/monolith -n mono
	kubectl rollout status deployment/monolith -n mono --timeout=180s

.PHONY: minikube-deploy-monolith-hpa
minikube-deploy-monolith-hpa: minikube-load-monolith create-local-secrets
	kubectl apply -f $(K8S_DIR)/local/monolith/monolith.yaml
	kubectl apply -f $(K8S_DIR)/local/monolith/resource-management-hpa.yaml
	kubectl apply -f $(K8S_DIR)/local/monolith/ingress.yaml
	kubectl rollout restart deployment/monolith -n mono
	kubectl rollout status deployment/monolith -n mono --timeout=180s

.PHONY: minikube-migrate-microservices
minikube-migrate-microservices: minikube-load-microservices create-local-secrets-microservices minikube-db-bootstrap
	kubectl delete job auth-migration-job -n msa --ignore-not-found
	kubectl apply -f $(K8S_DIR)/local/microservices/auth-migration-job.yaml
	kubectl wait --for=condition=complete job/auth-migration-job -n msa --timeout=180s
	kubectl delete job item-migration-job -n msa --ignore-not-found
	kubectl apply -f $(K8S_DIR)/local/microservices/item-migration-job.yaml
	kubectl wait --for=condition=complete job/item-migration-job -n msa --timeout=180s
	kubectl delete job transaction-migration-job -n msa --ignore-not-found
	kubectl apply -f $(K8S_DIR)/local/microservices/transaction-migration-job.yaml
	kubectl wait --for=condition=complete job/transaction-migration-job -n msa --timeout=180s

.PHONY: minikube-reset-microservices-data
minikube-reset-microservices-data: minikube-load-seed create-local-secrets-microservices
	kubectl delete job reset-microservices-data-job -n msa --ignore-not-found
	kubectl apply -f $(K8S_DIR)/local/microservices/reset-microservices-data-job.yaml
	kubectl wait --for=condition=complete job/reset-microservices-data-job -n msa --timeout=180s

.PHONY: minikube-seed-microservices-smoke
minikube-seed-microservices-smoke: minikube-reset-microservices-data
	kubectl delete job seed-microservices-smoke-data-job -n msa --ignore-not-found
	kubectl apply -f $(K8S_DIR)/local/microservices/seed-microservices-smoke-data-job.yaml
	kubectl wait --for=condition=complete job/seed-microservices-smoke-data-job -n msa --timeout=180s

.PHONY: minikube-seed-microservices-benchmark
minikube-seed-microservices-benchmark: minikube-reset-microservices-data
	kubectl delete job seed-microservices-benchmark-data-job -n msa --ignore-not-found
	kubectl apply -f $(K8S_DIR)/local/microservices/seed-microservices-benchmark-data-job.yaml
	kubectl wait --for=condition=complete job/seed-microservices-benchmark-data-job -n msa --timeout=300s

.PHONY: minikube-bootstrap-microservices-smoke
minikube-bootstrap-microservices-smoke:
	$(MAKE) minikube-migrate-microservices
	$(MAKE) minikube-seed-microservices-smoke
	$(MAKE) minikube-deploy-microservices

.PHONY: minikube-bootstrap-microservices-benchmark
minikube-bootstrap-microservices-benchmark:
	$(MAKE) minikube-migrate-microservices
	$(MAKE) minikube-seed-microservices-benchmark
	$(MAKE) minikube-deploy-microservices

.PHONY: minikube-prepare-microservices-enrichment-smoke
minikube-prepare-microservices-enrichment-smoke: minikube-load-seed create-local-secrets-microservices
	kubectl delete job prepare-microservices-enrichment-smoke-data-job -n msa --ignore-not-found
	kubectl apply -f $(K8S_DIR)/local/microservices/prepare-microservices-enrichment-smoke-data-job.yaml
	kubectl wait --for=condition=complete job/prepare-microservices-enrichment-smoke-data-job -n msa --timeout=180s

.PHONY: minikube-prepare-microservices-enrichment-benchmark
minikube-prepare-microservices-enrichment-benchmark: minikube-load-seed create-local-secrets-microservices
	kubectl delete job prepare-microservices-enrichment-benchmark-data-job -n msa --ignore-not-found
	kubectl apply -f $(K8S_DIR)/local/microservices/prepare-microservices-enrichment-benchmark-data-job.yaml
	kubectl wait --for=condition=complete job/prepare-microservices-enrichment-benchmark-data-job -n msa --timeout=180s

.PHONY: minikube-bootstrap-microservices-enrichment-smoke
minikube-bootstrap-microservices-enrichment-smoke:
	$(MAKE) minikube-migrate-microservices
	$(MAKE) minikube-seed-microservices-smoke
	$(MAKE) minikube-prepare-microservices-enrichment-smoke
	$(MAKE) minikube-deploy-microservices

.PHONY: minikube-bootstrap-microservices-enrichment-benchmark
minikube-bootstrap-microservices-enrichment-benchmark:
	$(MAKE) minikube-migrate-microservices
	$(MAKE) minikube-seed-microservices-benchmark
	$(MAKE) minikube-prepare-microservices-enrichment-benchmark
	$(MAKE) minikube-deploy-microservices

.PHONY: minikube-deploy-microservices
minikube-deploy-microservices: minikube-load-microservices create-local-secrets-microservices
	kubectl apply -f $(K8S_DIR)/local/microservices/auth-service.yaml
	kubectl apply -f $(K8S_DIR)/local/microservices/item-service.yaml
	kubectl apply -f $(K8S_DIR)/local/microservices/transaction-service.yaml
	kubectl apply -f $(K8S_DIR)/local/microservices/api-gateway.yaml
	kubectl apply -f $(K8S_DIR)/local/microservices/resource-management-fixed.yaml
	kubectl apply -f $(K8S_DIR)/local/microservices/api-gateway-ingress.yaml
	kubectl rollout restart deployment/auth-service -n msa
	kubectl rollout restart deployment/item-service -n msa
	kubectl rollout restart deployment/transaction-service -n msa
	kubectl rollout restart deployment/api-gateway -n msa
	kubectl rollout status deployment/auth-service -n msa --timeout=180s
	kubectl rollout status deployment/item-service -n msa --timeout=180s
	kubectl rollout status deployment/transaction-service -n msa --timeout=180s
	kubectl rollout status deployment/api-gateway -n msa --timeout=180s

.PHONY: minikube-deploy-microservices-hpa
minikube-deploy-microservices-hpa: minikube-load-microservices create-local-secrets-microservices
	kubectl apply -f $(K8S_DIR)/local/microservices/auth-service.yaml
	kubectl apply -f $(K8S_DIR)/local/microservices/item-service.yaml
	kubectl apply -f $(K8S_DIR)/local/microservices/transaction-service.yaml
	kubectl apply -f $(K8S_DIR)/local/microservices/api-gateway.yaml
	kubectl apply -f $(K8S_DIR)/local/microservices/resource-management-hpa.yaml
	kubectl apply -f $(K8S_DIR)/local/microservices/api-gateway-ingress.yaml
	kubectl rollout restart deployment/auth-service -n msa
	kubectl rollout restart deployment/item-service -n msa
	kubectl rollout restart deployment/transaction-service -n msa
	kubectl rollout restart deployment/api-gateway -n msa
	kubectl rollout status deployment/auth-service -n msa --timeout=180s
	kubectl rollout status deployment/item-service -n msa --timeout=180s
	kubectl rollout status deployment/transaction-service -n msa --timeout=180s
	kubectl rollout status deployment/api-gateway -n msa --timeout=180s

.PHONY: minikube-port-forward-monolith
minikube-port-forward-monolith:
	kubectl port-forward svc/monolith -n mono $(MONOLITH_PORT):8080

.PHONY: minikube-port-forward-api-gateway
minikube-port-forward-api-gateway:
	kubectl port-forward svc/api-gateway -n msa $(API_GATEWAY_PORT):8080

.PHONY: minikube-status
minikube-status:
	kubectl get nodes
	kubectl get pods -A

# =========================
# Datadog
# =========================

.PHONY: datadog-secret
datadog-secret:
	DATADOG_NAMESPACE=$(DATADOG_NAMESPACE) DATADOG_SITE=$(DATADOG_SITE) bash scripts/create-datadog-secret.sh

.PHONY: datadog-repo
datadog-repo:
	helm repo add datadog https://helm.datadoghq.com --force-update
	helm repo update datadog

.PHONY: datadog-install-minikube
datadog-install-minikube: datadog-secret datadog-repo
	helm upgrade --install $(DATADOG_RELEASE) datadog/datadog \
		--version $(DATADOG_CHART_VERSION) \
		--namespace $(DATADOG_NAMESPACE) \
		--values $(HELM_DIR)/datadog/values-minikube.yaml \
		--set datadog.site=$(DATADOG_SITE)
	kubectl rollout status daemonset/$(DATADOG_RELEASE) -n $(DATADOG_NAMESPACE) --timeout=300s

.PHONY: datadog-install-eks-monolith
datadog-install-eks-monolith: datadog-repo
	KUBE_CONTEXT=monolith DATADOG_NAMESPACE=$(DATADOG_NAMESPACE) DATADOG_SITE=$(DATADOG_SITE) bash scripts/create-datadog-secret.sh
	helm upgrade --install $(DATADOG_RELEASE) datadog/datadog \
		--version $(DATADOG_CHART_VERSION) \
		--kube-context=monolith \
		--namespace $(DATADOG_NAMESPACE) \
		--values $(HELM_DIR)/datadog/values-eks-monolith.yaml \
		--set datadog.site=$(DATADOG_SITE)
	kubectl --context=monolith rollout status daemonset/$(DATADOG_RELEASE) -n $(DATADOG_NAMESPACE) --timeout=300s

.PHONY: datadog-install-eks-msa
datadog-install-eks-msa: datadog-repo
	KUBE_CONTEXT=msa DATADOG_NAMESPACE=$(DATADOG_NAMESPACE) DATADOG_SITE=$(DATADOG_SITE) bash scripts/create-datadog-secret.sh
	helm upgrade --install $(DATADOG_RELEASE) datadog/datadog \
		--version $(DATADOG_CHART_VERSION) \
		--kube-context=msa \
		--namespace $(DATADOG_NAMESPACE) \
		--values $(HELM_DIR)/datadog/values-eks-msa.yaml \
		--set datadog.site=$(DATADOG_SITE)
	kubectl --context=msa rollout status daemonset/$(DATADOG_RELEASE) -n $(DATADOG_NAMESPACE) --timeout=300s

.PHONY: datadog-status
datadog-status:
	kubectl get pods,svc,daemonset,deploy -n $(DATADOG_NAMESPACE)

.PHONY: datadog-uninstall
datadog-uninstall:
	helm uninstall $(DATADOG_RELEASE) -n $(DATADOG_NAMESPACE)

# =========================
# EKS / Terraform
# =========================

SCENARIO     ?= login
TARGET_RPS   ?= 1000
RUN_ID       ?= eks-run-001
ATTEMPT      ?= attempt-01
SCALING_MODE ?= fixed
K6_PROFILE   ?= steady
TEST_DURATION ?= 5m
SCENARIOS    ?= login create-transaction enriched-transactions
RPS_LEVELS   ?= 1000 2500 5000 7500 10000
S3_BUCKET    ?= skripsi-benchmark-results
DATADOG_ENABLED ?= true
DATADOG_ENV ?= benchmark

.PHONY: terraform-fmt
terraform-fmt:
	cd infra/terraform/shared && terraform fmt -recursive
	cd infra/terraform/experiment && terraform fmt -recursive

# =========================
# AWS Persistent Resources (one-time setup)
# =========================

AWS_REGION    ?= ap-southeast-1
ECR_NAMESPACE ?= skripsi

.PHONY: aws-create-s3
aws-create-s3:
	aws s3api create-bucket \
		--bucket $(S3_BUCKET) \
		--region $(AWS_REGION) \
		--create-bucket-configuration LocationConstraint=$(AWS_REGION)
	aws s3api put-public-access-block \
		--bucket $(S3_BUCKET) \
		--public-access-block-configuration \
		"BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
	@echo "S3 bucket created: $(S3_BUCKET)"

.PHONY: aws-create-ecr
aws-create-ecr:
	@for repo in monolith api-gateway auth-service item-service transaction-service seed-runner k6-runner; do \
		aws ecr create-repository \
			--repository-name "$(ECR_NAMESPACE)/$$repo" \
			--image-tag-mutability IMMUTABLE \
			--region $(AWS_REGION) \
			--query 'repository.repositoryUri' \
			--output text; \
	done

.PHONY: aws-ecr-login
aws-ecr-login:
	$(eval ACCOUNT_ID := $(shell aws sts get-caller-identity --query Account --output text))
	aws ecr get-login-password --region $(AWS_REGION) \
		| docker login --username AWS --password-stdin \
		  "$(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com"

.PHONY: ecr-check-tag
ecr-check-tag:
	@set -euo pipefail; \
	if [ -z "$(IMAGE_TAG)" ]; then \
		echo "IMAGE_TAG must not be empty" >&2; \
		exit 1; \
	fi; \
	missing=0; \
	for repo in monolith api-gateway auth-service item-service transaction-service seed-runner k6-runner; do \
		if aws ecr describe-images \
			--region "$(AWS_REGION)" \
			--repository-name "$(ECR_NAMESPACE)/$$repo" \
			--image-ids imageTag="$(IMAGE_TAG)" \
			--query 'imageDetails[0].[imageDigest,imagePushedAt]' \
			--output text >/tmp/ecr-check-tag.txt 2>/dev/null; then \
			printf 'FOUND   %-20s %s\n' "$$repo" "$$(tr '\t' ' ' </tmp/ecr-check-tag.txt)"; \
			:; \
		else \
			printf 'MISSING %-20s %s:%s\n' "$$repo" "$(ECR_NAMESPACE)/$$repo" "$(IMAGE_TAG)"; \
			missing=1; \
		fi; \
	done; \
	rm -f /tmp/ecr-check-tag.txt; \
	if [ "$$missing" -ne 0 ]; then \
		echo "One or more required ECR images are missing for IMAGE_TAG=$(IMAGE_TAG)" >&2; \
		exit 1; \
	fi

# =========================
# ECR Image Build and Push
# =========================

IMAGE_TAG ?= $(shell if [ -f $(EKS_IMAGE_TAG_ENV) ]; then grep -E '^IMAGE_TAG=' $(EKS_IMAGE_TAG_ENV) | head -n 1 | cut -d= -f2-; else git rev-parse --short HEAD; fi)

.PHONY: eks-show-image-tag
eks-show-image-tag:
	@echo "IMAGE_TAG=$(IMAGE_TAG)"
	@if [ -f $(EKS_IMAGE_TAG_ENV) ]; then \
		echo "source=$(EKS_IMAGE_TAG_ENV)"; \
	else \
		echo "source=git rev-parse --short HEAD"; \
	fi

.PHONY: eks-pin-image-tag
eks-pin-image-tag:
	@if [ -z "$(IMAGE_TAG)" ]; then \
		echo "IMAGE_TAG is required" >&2; \
		exit 1; \
	fi
	@printf 'IMAGE_TAG=%s\n' "$(IMAGE_TAG)" > $(EKS_IMAGE_TAG_ENV)
	@echo "Pinned EKS deploy IMAGE_TAG=$(IMAGE_TAG) in $(EKS_IMAGE_TAG_ENV)"

.PHONY: eks-unpin-image-tag
eks-unpin-image-tag:
	rm -f $(EKS_IMAGE_TAG_ENV)
	@echo "Removed pinned EKS deploy image tag file $(EKS_IMAGE_TAG_ENV)"

.PHONY: ecr-push-all
ecr-push-all: aws-ecr-login
	$(eval ACCOUNT_ID := $(shell aws sts get-caller-identity --query Account --output text))
	$(eval ECR := $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com)
	docker build -t $(ECR)/$(ECR_NAMESPACE)/monolith:$(IMAGE_TAG) -f monolith/Dockerfile .
	docker push $(ECR)/$(ECR_NAMESPACE)/monolith:$(IMAGE_TAG)
	docker build -t $(ECR)/$(ECR_NAMESPACE)/api-gateway:$(IMAGE_TAG) -f microservices/api-gateway/Dockerfile .
	docker push $(ECR)/$(ECR_NAMESPACE)/api-gateway:$(IMAGE_TAG)
	docker build -t $(ECR)/$(ECR_NAMESPACE)/auth-service:$(IMAGE_TAG) -f microservices/auth-service/Dockerfile .
	docker push $(ECR)/$(ECR_NAMESPACE)/auth-service:$(IMAGE_TAG)
	docker build -t $(ECR)/$(ECR_NAMESPACE)/item-service:$(IMAGE_TAG) -f microservices/item-service/Dockerfile .
	docker push $(ECR)/$(ECR_NAMESPACE)/item-service:$(IMAGE_TAG)
	docker build -t $(ECR)/$(ECR_NAMESPACE)/transaction-service:$(IMAGE_TAG) -f microservices/transaction-service/Dockerfile .
	docker push $(ECR)/$(ECR_NAMESPACE)/transaction-service:$(IMAGE_TAG)
	docker build -t $(ECR)/$(ECR_NAMESPACE)/seed-runner:$(IMAGE_TAG) -f seed/Dockerfile .
	docker push $(ECR)/$(ECR_NAMESPACE)/seed-runner:$(IMAGE_TAG)
	docker build -t $(ECR)/$(ECR_NAMESPACE)/k6-runner:$(IMAGE_TAG) -f k6/runner/Dockerfile .
	docker push $(ECR)/$(ECR_NAMESPACE)/k6-runner:$(IMAGE_TAG)
	@echo "All images pushed with tag: $(IMAGE_TAG)"

.PHONY: eks-render-manifests eks-update-manifests
eks-render-manifests eks-update-manifests:
	$(eval RENDER_DIR := $(shell mktemp -d))
	@echo "Rendering EKS manifests to $(RENDER_DIR)"
	@IMAGE_TAG=$(IMAGE_TAG) AWS_REGION=$(AWS_REGION) ECR_NAMESPACE=$(ECR_NAMESPACE) OUTPUT_DIR="$(RENDER_DIR)" bash scripts/render-eks-manifests.sh >/dev/null
	@bash scripts/validate-eks-assets.sh deploy "$(RENDER_DIR)"
	@echo "Rendered manifests ready at $(RENDER_DIR)"

.PHONY: eks-validate-manifests
eks-validate-manifests:
	@set -euo pipefail; \
	RENDER_DIR="$$(mktemp -d)"; \
	trap 'rm -rf "$$RENDER_DIR"' EXIT; \
	echo "Validating rendered EKS manifests in $$RENDER_DIR"; \
	IMAGE_TAG=$(IMAGE_TAG) AWS_REGION=$(AWS_REGION) ECR_NAMESPACE=$(ECR_NAMESPACE) OUTPUT_DIR="$$RENDER_DIR" bash scripts/render-eks-manifests.sh >/dev/null; \
	bash scripts/validate-eks-assets.sh deploy "$$RENDER_DIR"

.PHONY: eks-render-tfvars
eks-render-tfvars:
	bash scripts/render-eks-tfvars.sh


terraform-validate:
	cd infra/terraform/shared && AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) terraform validate
	cd infra/terraform/experiment && AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) terraform validate

.PHONY: terraform-auth-check
terraform-auth-check:
	@echo "Running terraform init for experiment auth check with AWS profile '$(TERRAFORM_AWS_PROFILE)'..."
	TERRAFORM_AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) bash scripts/terraform-experiment.sh init -input=false
	@echo "Running terraform plan for experiment auth check with AWS profile '$(TERRAFORM_AWS_PROFILE)'..."
	TERRAFORM_AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) bash scripts/terraform-experiment.sh plan -input=false -lock=false -no-color >/dev/null
	@echo "Terraform auth check passed with AWS profile '$(TERRAFORM_AWS_PROFILE)'"

.PHONY: terraform-recovery-check
terraform-recovery-check:
	TERRAFORM_AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) bash scripts/terraform-recovery-check.sh

.PHONY: terraform-recovery-fix-tainted-nodegroups
terraform-recovery-fix-tainted-nodegroups:
	TERRAFORM_AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) bash scripts/terraform-recovery-fix-tainted-nodegroups.sh

.PHONY: terraform-recovery-fix-tainted-nodegroups-apply
terraform-recovery-fix-tainted-nodegroups-apply:
	TERRAFORM_AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) bash scripts/terraform-recovery-fix-tainted-nodegroups.sh --apply

.PHONY: eks-shared-apply
eks-shared-apply:
	cd infra/terraform/shared && AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) terraform init && AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) terraform apply

.PHONY: eks-shared-destroy
eks-shared-destroy:
	cd infra/terraform/shared && AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) terraform init && AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) terraform destroy

.PHONY: eks-apply
eks-apply:
	TERRAFORM_AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) bash scripts/terraform-experiment.sh init
	TERRAFORM_AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) bash scripts/terraform-experiment.sh apply

.PHONY: eks-destroy
eks-destroy:
	TERRAFORM_AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) bash scripts/terraform-experiment.sh init
	TERRAFORM_AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) bash scripts/terraform-experiment.sh destroy

.PHONY: eks-destroy-confirmed
eks-destroy-confirmed:
	S3_BENCHMARK_DATA_VERIFIED=true $(MAKE) eks-destroy

.PHONY: eks-setup-contexts
eks-setup-contexts:
	bash scripts/setup-eks-contexts.sh

.PHONY: eks-deploy-monolith
eks-deploy-monolith:
	SCALING_MODE=$(SCALING_MODE) IMAGE_TAG=$(IMAGE_TAG) AWS_REGION=$(AWS_REGION) ECR_NAMESPACE=$(ECR_NAMESPACE) bash scripts/deploy-monolith-cluster.sh

.PHONY: eks-deploy-msa
eks-deploy-msa:
	SCALING_MODE=$(SCALING_MODE) IMAGE_TAG=$(IMAGE_TAG) AWS_REGION=$(AWS_REGION) ECR_NAMESPACE=$(ECR_NAMESPACE) bash scripts/deploy-msa-cluster.sh

.PHONY: eks-deploy-all
eks-deploy-all:
	$(MAKE) ecr-check-tag IMAGE_TAG=$(IMAGE_TAG) AWS_REGION=$(AWS_REGION) ECR_NAMESPACE=$(ECR_NAMESPACE)
	SCALING_MODE=$(SCALING_MODE) IMAGE_TAG=$(IMAGE_TAG) AWS_REGION=$(AWS_REGION) ECR_NAMESPACE=$(ECR_NAMESPACE) bash scripts/deploy-all-eks-clusters.sh

.PHONY: eks-deploy-all-fixed
eks-deploy-all-fixed:
	SCALING_MODE=fixed $(MAKE) eks-deploy-all IMAGE_TAG=$(IMAGE_TAG) AWS_REGION=$(AWS_REGION) ECR_NAMESPACE=$(ECR_NAMESPACE)

.PHONY: eks-deploy-all-hpa
eks-deploy-all-hpa:
	SCALING_MODE=hpa $(MAKE) eks-deploy-all IMAGE_TAG=$(IMAGE_TAG) AWS_REGION=$(AWS_REGION) ECR_NAMESPACE=$(ECR_NAMESPACE)

.PHONY: eks-prepare-enrichment-benchmark
eks-prepare-enrichment-benchmark:
	bash scripts/prepare-enrichment-benchmark.sh

.PHONY: create-eks-secrets-monolith
create-eks-secrets-monolith:
	TERRAFORM_AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) bash scripts/create-eks-secrets-monolith.sh

.PHONY: create-eks-secrets-microservices
create-eks-secrets-microservices:
	TERRAFORM_AWS_PROFILE=$(TERRAFORM_AWS_PROFILE) bash scripts/create-eks-secrets-microservices.sh

.PHONY: eks-create-secrets
eks-create-secrets:
	$(MAKE) create-eks-secrets-monolith
	$(MAKE) create-eks-secrets-microservices

.PHONY: run-benchmark-parallel
run-benchmark-parallel:
	SCENARIO=$(SCENARIO) \
	TARGET_RPS=$(TARGET_RPS) \
	RUN_ID=$(RUN_ID) \
	ATTEMPT=$(ATTEMPT) \
	SCALING_MODE=$(SCALING_MODE) \
	K6_PROFILE=$(K6_PROFILE) \
	TEST_DURATION=$(TEST_DURATION) \
	S3_BUCKET=$(S3_BUCKET) \
	DATADOG_ENABLED=$(DATADOG_ENABLED) \
	DATADOG_ENV=$(DATADOG_ENV) \
	bash scripts/run-benchmark-parallel.sh

.PHONY: run-benchmark-suite
run-benchmark-suite:
	SCALING_MODE=$(SCALING_MODE) \
	K6_PROFILE="$(if $(filter command line environment,$(origin K6_PROFILE)),$(K6_PROFILE),)" \
	TEST_DURATION=$(TEST_DURATION) \
	SCENARIOS="$(SCENARIOS)" \
	RPS_LEVELS="$(RPS_LEVELS)" \
	RUN_ID="$(if $(filter command line environment,$(origin RUN_ID)),$(RUN_ID),)" \
	ATTEMPT="$(if $(filter command line environment,$(origin ATTEMPT)),$(ATTEMPT),)" \
	S3_BUCKET=$(S3_BUCKET) \
	DATADOG_ENABLED=$(DATADOG_ENABLED) \
	DATADOG_ENV=$(DATADOG_ENV) \
	AWS_REGION=$(AWS_REGION) \
	bash scripts/run-benchmark-suite.sh
