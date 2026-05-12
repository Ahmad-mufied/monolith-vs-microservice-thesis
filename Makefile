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

# =========================
# Images
# =========================

MONOLITH_IMAGE := skripsi/monolith:local
API_GATEWAY_IMAGE := skripsi/api-gateway:local
AUTH_SERVICE_IMAGE := skripsi/auth-service:local
ITEM_SERVICE_IMAGE := skripsi/item-service:local
TRANSACTION_SERVICE_IMAGE := skripsi/transaction-service:local

MINIKUBE_CPUS ?= 2
MINIKUBE_MEMORY ?= 3072
MINIKUBE_DISK_SIZE ?= 20g
MONOLITH_PORT ?= 8080

# =========================
# Env Files
# =========================

MONOLITH_ENV := env/monolith.env
API_GATEWAY_ENV := env/api-gateway.env
AUTH_SERVICE_ENV := env/auth-service.env
ITEM_SERVICE_ENV := env/item-service.env
TRANSACTION_SERVICE_ENV := env/transaction-service.env

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
	@echo "  make env-init-monolith"
	@echo "  make env-init-microservices"
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
	@echo "Seed:"
	@echo "  make seed-monolith"
	@echo "  make seed-microservices"
	@echo "  make reset-monolith"
	@echo "  make reset-microservices"
	@echo ""
	@echo "Minikube:"
	@echo "  make minikube-start"
	@echo "  make minikube-stop"
	@echo "  make minikube-load-monolith"
	@echo "  make minikube-deploy-postgres"
	@echo "  make minikube-db-bootstrap"
	@echo "  make minikube-migrate-monolith"
	@echo "  make minikube-deploy-monolith"
	@echo "  make minikube-port-forward-monolith"
	@echo "  make minikube-load-images"
	@echo "  make create-local-secrets"
	@echo ""

# =========================
# Local Env
# =========================

.PHONY: env-init-base
env-init-base:
	bash scripts/env-init-base.sh

.PHONY: env-init-monolith
env-init-monolith: env-init-base
	bash scripts/env-init-monolith.sh

.PHONY: env-init-microservices
env-init-microservices: env-init-base
	bash scripts/env-init-microservices.sh

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

.PHONY: docker-build-microservices
docker-build-microservices:
	docker build -t $(API_GATEWAY_IMAGE) ./$(API_GATEWAY_DIR)
	docker build -t $(AUTH_SERVICE_IMAGE) ./$(AUTH_SERVICE_DIR)
	docker build -t $(ITEM_SERVICE_IMAGE) ./$(ITEM_SERVICE_DIR)
	docker build -t $(TRANSACTION_SERVICE_IMAGE) ./$(TRANSACTION_SERVICE_DIR)

.PHONY: docker-build-all
docker-build-all: docker-build-monolith docker-build-microservices

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

.PHONY: seed-monolith
seed-monolith:
	go run ./seed/scripts/seed-monolith.go \
		--database-url="$$MONO_DATABASE_URL"

.PHONY: seed-microservices
seed-microservices:
	go run ./seed/scripts/seed-microservices.go \
		--auth-database-url="$$AUTH_DATABASE_URL" \
		--item-database-url="$$ITEM_DATABASE_URL" \
		--transaction-database-url="$$TRANSACTION_DATABASE_URL"

.PHONY: reset-monolith
reset-monolith:
	go run ./seed/scripts/reset-monolith.go \
		--database-url="$$MONO_DATABASE_URL"

.PHONY: reset-microservices
reset-microservices:
	go run ./seed/scripts/reset-microservices.go \
		--auth-database-url="$$AUTH_DATABASE_URL" \
		--item-database-url="$$ITEM_DATABASE_URL" \
		--transaction-database-url="$$TRANSACTION_DATABASE_URL"

# =========================
# Kubernetes Local Secrets
# =========================

.PHONY: create-local-secrets
create-local-secrets:
	bash scripts/create-local-secrets.sh

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
minikube-load-images:
	eval $$(minikube docker-env) && docker build -t $(MONOLITH_IMAGE) -f $(MONOLITH_DIR)/Dockerfile .
	eval $$(minikube docker-env) && docker build -t $(API_GATEWAY_IMAGE) ./$(API_GATEWAY_DIR)
	eval $$(minikube docker-env) && docker build -t $(AUTH_SERVICE_IMAGE) ./$(AUTH_SERVICE_DIR)
	eval $$(minikube docker-env) && docker build -t $(ITEM_SERVICE_IMAGE) ./$(ITEM_SERVICE_DIR)
	eval $$(minikube docker-env) && docker build -t $(TRANSACTION_SERVICE_IMAGE) ./$(TRANSACTION_SERVICE_DIR)

.PHONY: minikube-load-monolith
minikube-load-monolith:
	eval $$(minikube docker-env) && docker build -t $(MONOLITH_IMAGE) -f $(MONOLITH_DIR)/Dockerfile .

.PHONY: minikube-deploy-postgres
minikube-deploy-postgres: create-local-secrets
	kubectl apply -f $(K8S_DIR)/namespaces/benchmark.yaml
	kubectl apply -f $(K8S_DIR)/local/postgres.yaml
	kubectl wait --for=condition=ready pod/postgres-0 -n benchmark --timeout=180s

.PHONY: minikube-db-bootstrap
minikube-db-bootstrap: create-local-secrets
	kubectl delete job db-bootstrap-job -n benchmark --ignore-not-found
	kubectl apply -f $(K8S_DIR)/local/db-bootstrap-job.yaml
	kubectl wait --for=condition=complete job/db-bootstrap-job -n benchmark --timeout=180s

.PHONY: minikube-migrate-monolith
minikube-migrate-monolith: create-local-secrets
	kubectl delete job monolith-migration-job -n mono --ignore-not-found
	kubectl apply -f $(K8S_DIR)/monolith/migration-job.yaml
	kubectl wait --for=condition=complete job/monolith-migration-job -n mono --timeout=180s

.PHONY: minikube-deploy-monolith
minikube-deploy-monolith: create-local-secrets
	kubectl apply -f $(K8S_DIR)/monolith/monolith.yaml
	kubectl apply -f $(K8S_DIR)/monolith/ingress.yaml
	kubectl rollout status deployment/monolith -n mono --timeout=180s

.PHONY: minikube-port-forward-monolith
minikube-port-forward-monolith:
	kubectl port-forward svc/monolith -n mono $(MONOLITH_PORT):8080

.PHONY: minikube-status
minikube-status:
	kubectl get nodes
	kubectl get pods -A

# =========================
# EKS / Terraform
# =========================

.PHONY: terraform-fmt
terraform-fmt:
	cd infra/terraform/experiment && terraform fmt -recursive

.PHONY: terraform-validate
terraform-validate:
	cd infra/terraform/experiment && terraform validate

.PHONY: eks-apply
eks-apply:
	cd infra/terraform/experiment && terraform apply

.PHONY: eks-destroy
eks-destroy:
	cd infra/terraform/experiment && terraform destroy
