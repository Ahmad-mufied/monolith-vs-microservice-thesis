#!/usr/bin/env bash
set -euo pipefail

env_file="env/terraform.experiment.env"

if [[ -f "$env_file" ]]; then
  set -a
  source "$env_file"
  set +a
fi

terraform_aws_profile="${TERRAFORM_AWS_PROFILE:-terraform-process}"
aws_region="${AWS_REGION:-ap-southeast-1}"
cluster_name="${SEQUENTIAL_CLUSTER_NAME:-skripsi-benchmark}"
rds_identifier="${cluster_name}-postgres"
tf_shared_dir="infra/terraform/aws-shared"
tf_sequential_dir="infra/terraform/aws-sequential"

terraform_with_profile() {
  AWS_PROFILE="$terraform_aws_profile" terraform "$@"
}

aws_with_profile() {
  AWS_PROFILE="$terraform_aws_profile" aws "$@"
}

print_status() {
  local status="$1"
  local message="$2"
  printf '[%s] %s\n' "$status" "$message"
}

blocked=0

echo "Terraform sequential recovery check"
echo "  AWS profile : $terraform_aws_profile"
echo "  AWS region  : $aws_region"
echo "  cluster     : $cluster_name"

if ! aws_with_profile sts get-caller-identity >/dev/null 2>&1; then
  print_status "BLOCKED" "AWS auth failed for profile '$terraform_aws_profile'. Run: aws login && make terraform-auth-check"
  exit 1
fi

terraform_with_profile -chdir="$tf_shared_dir" init -input=false >/dev/null
terraform_with_profile -chdir="$tf_sequential_dir" init -input=false >/dev/null
print_status "OK" "Terraform auth and init succeeded"

shared_state_list="$(terraform_with_profile -chdir="$tf_shared_dir" state list 2>/dev/null || true)"
sequential_state_list="$(terraform_with_profile -chdir="$tf_sequential_dir" state list 2>/dev/null || true)"

if [[ -z "$shared_state_list" ]]; then
  print_status "REVIEW" "No shared Terraform state entries found"
else
  print_status "OK" "Shared Terraform state is readable"
fi

for output_name in vpc_id private_subnet_ids k6_runner_role_arn; do
  if terraform_with_profile -chdir="$tf_shared_dir" output -json "$output_name" >/dev/null 2>&1; then
    print_status "OK" "Shared output exists: $output_name"
  else
    print_status "BLOCKED" "Shared output missing: $output_name"
    blocked=1
  fi
done

state_tracks_cluster=false
state_tracks_rds=false
if grep -Fq 'module.sequential_cluster.module.eks.aws_eks_cluster.this[0]' <<<"$sequential_state_list"; then
  state_tracks_cluster=true
fi
if grep -Fq 'module.sequential_cluster.aws_db_instance.postgres' <<<"$sequential_state_list"; then
  state_tracks_rds=true
fi

cluster_status="$(aws_with_profile eks describe-cluster --region "$aws_region" --name "$cluster_name" --query 'cluster.status' --output text 2>/dev/null || true)"
rds_status="$(aws_with_profile rds describe-db-instances --region "$aws_region" --db-instance-identifier "$rds_identifier" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || true)"

if [[ -n "$sequential_state_list" ]]; then
  print_status "OK" "Sequential Terraform state is readable"
else
  print_status "REVIEW" "No sequential Terraform state entries found"
fi

if [[ -n "$cluster_status" && "$cluster_status" != "None" ]]; then
  if [[ "$state_tracks_cluster" == "true" ]]; then
    print_status "OK" "Sequential cluster exists and is tracked: $cluster_name ($cluster_status)"
    for addon_name in vpc-cni coredns kube-proxy eks-pod-identity-agent; do
      addon_status="$(aws_with_profile eks describe-addon \
        --region "$aws_region" \
        --cluster-name "$cluster_name" \
        --addon-name "$addon_name" \
        --query 'addon.status' \
        --output text 2>/dev/null || true)"
      if [[ "$addon_status" == "ACTIVE" ]]; then
        print_status "OK" "Sequential addon active: $cluster_name/$addon_name"
      elif [[ -n "$addon_status" && "$addon_status" != "None" ]]; then
        print_status "IN_PROGRESS" "Sequential addon present but not active: $cluster_name/$addon_name ($addon_status)"
      else
        print_status "REVIEW" "Sequential addon not found yet: $cluster_name/$addon_name"
      fi
    done
  else
    print_status "BLOCKED" "Sequential cluster exists in AWS but is not tracked in state: $cluster_name ($cluster_status)"
    blocked=1
  fi
else
  print_status "OK" "Sequential cluster is absent in AWS: $cluster_name"
fi

if [[ -n "$rds_status" && "$rds_status" != "None" ]]; then
  if [[ "$state_tracks_rds" == "true" ]]; then
    print_status "OK" "Sequential RDS exists and is tracked: $rds_identifier ($rds_status)"
  else
    print_status "BLOCKED" "Sequential RDS exists in AWS but is not tracked in state: $rds_identifier ($rds_status)"
    blocked=1
  fi
else
  print_status "OK" "Sequential RDS is absent in AWS: $rds_identifier"
fi

echo
if [[ "$blocked" -ne 0 ]]; then
  echo "Recovery check found blocking drift. Fix/import/remove the live resource mismatch before sequential apply." >&2
  exit 1
fi

echo "Next:"
echo "  TERRAFORM_AWS_PROFILE=$terraform_aws_profile bash scripts/terraform-aws-sequential.sh plan -input=false -lock=false -no-color"
