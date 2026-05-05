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

# =========================
# Images
# =========================

MONOLITH_IMAGE := skripsi/monolith:local
API_GATEWAY_IMAGE := skripsi/api-gateway:local
AUTH_SERVICE_IMAGE := skripsi/auth-service:local
ITEM_SERVICE_IMAGE := skripsi/item-service:local
TRANSACTION_SERVICE_IMAGE := skripsi/transaction-service:local

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
	@echo "  make run-api-gateway"
	@echo "  make run-auth-service"
	@echo "  make run-item-service"
	@echo "  make run-transaction-service"
	@echo ""
	@echo "Docker Compose:"
	@echo "  make compose-db-up"
	@echo "  make compose-monolith-up"
	@echo "  make compose-microservices-up"
	@echo "  make compose-down"
	@echo ""
	@echo "Migration:"
	@echo "  make migrate-monolith"
	@echo "  make migrate-microservices"
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
	@echo "  make minikube-load-images"
	@echo "  make create-local-secrets"
	@echo ""

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
	cd $(MONOLITH_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then go fix ./...; else echo "skip fix ($(MONOLITH_DIR)): no go packages"; fi
	cd $(API_GATEWAY_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then go fix ./...; else echo "skip fix ($(API_GATEWAY_DIR)): no go packages"; fi
	cd $(AUTH_SERVICE_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then go fix ./...; else echo "skip fix ($(AUTH_SERVICE_DIR)): no go packages"; fi
	cd $(ITEM_SERVICE_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then go fix ./...; else echo "skip fix ($(ITEM_SERVICE_DIR)): no go packages"; fi
	cd $(TRANSACTION_SERVICE_DIR) && pkgs="$$(go list ./... 2>/dev/null || true)" && if [ -n "$$pkgs" ]; then go fix ./...; else echo "skip fix ($(TRANSACTION_SERVICE_DIR)): no go packages"; fi

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

# =========================
# Docker Build
# =========================

.PHONY: docker-build-monolith
docker-build-monolith:
	docker build -t $(MONOLITH_IMAGE) ./$(MONOLITH_DIR)

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
	minikube start --driver=docker --cpus=4 --memory=6144 --disk-size=20g
	minikube addons enable ingress
	minikube addons enable metrics-server

.PHONY: minikube-stop
minikube-stop:
	minikube stop

.PHONY: minikube-delete
minikube-delete:
	minikube delete

.PHONY: minikube-load-images
minikube-load-images: docker-build-all
	minikube image load $(MONOLITH_IMAGE)
	minikube image load $(API_GATEWAY_IMAGE)
	minikube image load $(AUTH_SERVICE_IMAGE)
	minikube image load $(ITEM_SERVICE_IMAGE)
	minikube image load $(TRANSACTION_SERVICE_IMAGE)

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
