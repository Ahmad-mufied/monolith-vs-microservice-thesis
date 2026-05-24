#!/usr/bin/env bash
set -euo pipefail

MONO_K8S="kubectl --context=monolith"
MSA_K8S="kubectl --context=msa"

echo "Preparing enrichment benchmark data on both clusters..."

$MONO_K8S delete job prepare-monolith-enrichment-benchmark-data-job -n mono --ignore-not-found
$MONO_K8S apply -f deployments/k8s/eks/monolith/prepare-monolith-enrichment-benchmark-data-job.yaml
$MONO_K8S wait --for=condition=complete job/prepare-monolith-enrichment-benchmark-data-job -n mono --timeout=300s

$MSA_K8S delete job prepare-microservices-enrichment-benchmark-data-job -n msa --ignore-not-found
$MSA_K8S apply -f deployments/k8s/eks/microservices/prepare-microservices-enrichment-benchmark-data-job.yaml
$MSA_K8S wait --for=condition=complete job/prepare-microservices-enrichment-benchmark-data-job -n msa --timeout=300s

echo "Enrichment benchmark data ready on both clusters."
