#!/usr/bin/env bash
set -euo pipefail

MONO_K8S="kubectl --context=monolith"
MSA_K8S="kubectl --context=msa"
MONOLITH_PREPARE_MANIFEST_PATH="${MONOLITH_PREPARE_MANIFEST_PATH:-deployments/k8s/cloud/monolith/prepare-monolith-enrichment-benchmark-data-job.yaml}"
MICROSERVICES_PREPARE_MANIFEST_PATH="${MICROSERVICES_PREPARE_MANIFEST_PATH:-deployments/k8s/cloud/microservices/prepare-microservices-enrichment-benchmark-data-job.yaml}"
PREPARE_ENRICHMENT_TIMEOUT="${PREPARE_ENRICHMENT_TIMEOUT:-300s}"

echo "Preparing enrichment benchmark data on both clusters..."

$MONO_K8S delete job prepare-monolith-enrichment-benchmark-data-job -n mono --ignore-not-found
$MONO_K8S apply -f "$MONOLITH_PREPARE_MANIFEST_PATH"
$MONO_K8S wait --for=condition=complete job/prepare-monolith-enrichment-benchmark-data-job -n mono --timeout="$PREPARE_ENRICHMENT_TIMEOUT"

$MSA_K8S delete job prepare-microservices-enrichment-benchmark-data-job -n msa --ignore-not-found
$MSA_K8S apply -f "$MICROSERVICES_PREPARE_MANIFEST_PATH"
$MSA_K8S wait --for=condition=complete job/prepare-microservices-enrichment-benchmark-data-job -n msa --timeout="$PREPARE_ENRICHMENT_TIMEOUT"

echo "Enrichment benchmark data ready on both clusters."
