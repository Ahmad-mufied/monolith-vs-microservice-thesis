#!/usr/bin/env bash
set -euo pipefail
umask 077

required_files=(
  env/terraform.shared.env
  env/terraform.experiment.env
)

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "missing $file; run: make env-init-eks" >&2
    exit 1
  fi
done

set -a
source env/terraform.shared.env
source env/terraform.experiment.env
set +a

: "${S3_RESULTS_BUCKET:?S3_RESULTS_BUCKET must be set in env/terraform.shared.env}"
: "${DB_PASSWORD:?DB_PASSWORD must be set in env/terraform.experiment.env}"

shared_aws_region="${AWS_REGION:-ap-southeast-1}"
shared_project="${PROJECT:-skripsi}"
experiment_aws_region="${AWS_REGION:-ap-southeast-1}"
experiment_project="${PROJECT:-skripsi}"
experiment_db_instance_class="${DB_INSTANCE_CLASS:-db.t3.micro}"

cat > infra/terraform/shared/terraform.tfvars <<EOF
aws_region        = "${shared_aws_region}"
project           = "${shared_project}"
s3_results_bucket = "${S3_RESULTS_BUCKET}"
EOF

cat > infra/terraform/experiment/terraform.tfvars <<EOF
aws_region  = "${experiment_aws_region}"
project     = "${experiment_project}"
db_password = "${DB_PASSWORD}"
db_instance_class = "${experiment_db_instance_class}"
EOF

echo "Rendered Terraform tfvars files:"
echo "  infra/terraform/shared/terraform.tfvars"
echo "  infra/terraform/experiment/terraform.tfvars"
