#!/usr/bin/env bash
set -euo pipefail
umask 077

env_file="env/oci.env"
if [ ! -f "$env_file" ]; then
  echo "missing $env_file; copy from env/oci.env.example" >&2
  exit 1
fi

set -a
source "$env_file"
set +a

: "${OCI_COMPARTMENT_OCID:?OCI_COMPARTMENT_OCID must be set in env/oci.env}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set in env/oci.env}"

if [ "$OCI_COMPARTMENT_OCID" = "ocid1.compartment.oc1..example" ]; then
  echo "ERROR: OCI_COMPARTMENT_OCID in env/oci.env is still the placeholder 'ocid1.compartment.oc1..example'" >&2
  echo "Please edit env/oci.env and paste your actual Tenancy/Compartment OCID (e.g. ocid1.tenancy.oc1..aaaa...)" >&2
  exit 1
fi

execution_mode="${OCI_EXECUTION_MODE:-sequential}"

cat > infra/terraform/oci/terraform.tfvars <<EOF
# Generated automatically by scripts/render-oci-tfvars.sh from env/oci.env
region               = "${OCI_REGION:-ap-kulai-2}"
compartment_id       = "${OCI_COMPARTMENT_OCID}"
private_key_password = "${OCI_PRIVATE_KEY_PASSWORD:-}"
execution_mode       = "${execution_mode}"
node_shape     = "${OCI_NODE_SHAPE:-VM.Standard.E4.Flex}"
testing_node_shape = "${OCI_TESTING_NODE_SHAPE:-VM.Standard3.Flex}"
db_shape       = "${OCI_DB_SHAPE:-VM.Standard3.Flex}"
db_version     = "${OCI_DB_VERSION:-17}"
db_password    = "${POSTGRES_PASSWORD}"

app_node_ocpus             = ${OCI_APP_NODE_OCPUS:-8}
app_node_memory_in_gbs     = ${OCI_APP_NODE_MEMORY_IN_GBS:-32}
app_node_count             = ${OCI_APP_NODE_COUNT:-1}

testing_node_ocpus         = ${OCI_TESTING_NODE_OCPUS:-4}
testing_node_memory_in_gbs = ${OCI_TESTING_NODE_MEMORY_IN_GBS:-16}
testing_node_count         = ${OCI_TESTING_NODE_COUNT:-1}

db_ocpus                   = ${OCI_DB_OCPUS:-2}
db_memory_in_gbs           = ${OCI_DB_MEMORY_IN_GBS:-8}

kubernetes_version         = "${OCI_KUBERNETES_VERSION:-v1.36.0}"
EOF

echo "Rendered OCI Terraform tfvars to infra/terraform/oci/terraform.tfvars (execution_mode=${execution_mode})"
