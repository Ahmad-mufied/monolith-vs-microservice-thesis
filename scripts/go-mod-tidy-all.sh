#!/bin/bash

# Script to run go mod tidy on all Go modules

set -e

echo "Running go mod tidy on all modules..."

# Monolith
echo "→ monolith"
cd monolith && go mod tidy && cd ..

# API Gateway
echo "→ microservices/api-gateway"
cd microservices/api-gateway && go mod tidy && cd ../..

# Auth Service
echo "→ microservices/auth-service"
cd microservices/auth-service && go mod tidy && cd ../..

# Item Service
echo "→ microservices/item-service"
cd microservices/item-service && go mod tidy && cd ../..

# Transaction Service
echo "→ microservices/transaction-service"
cd microservices/transaction-service && go mod tidy && cd ../..

echo "✓ All modules tidied successfully!"
