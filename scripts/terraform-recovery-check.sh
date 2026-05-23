#!/usr/bin/env bash
set -euo pipefail

terraform_aws_profile="${TERRAFORM_AWS_PROFILE:-terraform-process}"
aws_region="${AWS_REGION:-ap-southeast-1}"
project_prefix="${PROJECT_PREFIX:-skripsi}"

tf_shared_dir="infra/terraform/shared"
tf_experiment_dir="infra/terraform/experiment"

terraform_with_profile() {
  AWS_PROFILE="$terraform_aws_profile" terraform "$@"
}

aws_with_profile() {
  AWS_PROFILE="$terraform_aws_profile" aws "$@"
}

have_state_address() {
  local state_list="$1"
  local address="$2"
  grep -Fqx "$address" <<<"$state_list"
}

list_or_empty() {
  "$@" 2>/dev/null || true
}

print_section() {
  local title="$1"
  echo
  echo "== $title =="
}

print_status() {
  local status="$1"
  local message="$2"
  printf '[%s] %s\n' "$status" "$message"
}

echo "Terraform recovery check"
echo "  AWS profile : $terraform_aws_profile"
echo "  AWS region  : $aws_region"

print_section "Preflight"
if ! aws_with_profile sts get-caller-identity >/dev/null 2>&1; then
  print_status "BLOCKED" "AWS auth failed for profile '$terraform_aws_profile'. Run: aws login && make terraform-auth-check"
  exit 1
fi

if [[ ! -d "$tf_shared_dir" || ! -d "$tf_experiment_dir" ]]; then
  print_status "BLOCKED" "Terraform directories not found from current working directory"
  exit 1
fi

terraform_with_profile -chdir="$tf_shared_dir" init -input=false >/dev/null
terraform_with_profile -chdir="$tf_experiment_dir" init -input=false >/dev/null
print_status "OK" "Terraform auth and init succeeded"

shared_state_list="$(terraform_with_profile -chdir="$tf_shared_dir" state list 2>/dev/null || true)"
experiment_state_list="$(terraform_with_profile -chdir="$tf_experiment_dir" state list 2>/dev/null || true)"

print_section "Shared stack"
if [[ -z "$shared_state_list" ]]; then
  print_status "REVIEW" "No shared Terraform state entries found"
else
  print_status "OK" "Shared Terraform state is readable"
fi

shared_vpc_id="$(list_or_empty terraform_with_profile -chdir="$tf_shared_dir" output -raw vpc_id)"
shared_role_arn="$(list_or_empty terraform_with_profile -chdir="$tf_shared_dir" output -raw k6_runner_role_arn)"
shared_role_name="${shared_role_arn##*/}"

if [[ -n "$shared_vpc_id" ]]; then
  if aws_with_profile ec2 describe-vpcs --region "$aws_region" --vpc-ids "$shared_vpc_id" >/dev/null 2>&1; then
    print_status "OK" "Shared VPC exists in AWS: $shared_vpc_id"
  else
    print_status "STALE_IN_STATE" "Shared VPC missing in AWS: $shared_vpc_id"
  fi
fi

if [[ -n "$shared_role_name" ]]; then
  if aws_with_profile iam get-role --role-name "$shared_role_name" >/dev/null 2>&1; then
    print_status "OK" "Shared IAM role exists in AWS: $shared_role_name"
  else
    print_status "STALE_IN_STATE" "Shared IAM role missing in AWS: $shared_role_name"
  fi
fi

print_section "Experiment stack"
if [[ -z "$experiment_state_list" ]]; then
  print_status "REVIEW" "No experiment Terraform state entries found"
  print_section "Suggested next steps"
  echo "1. Experiment state is already empty."
  echo "2. If this matches your intent, no further Terraform state cleanup is required."
  echo "3. If you expected experiment resources to still exist in AWS, import them explicitly before applying."
  exit 0
else
  print_status "OK" "Experiment Terraform state is readable"
fi

monolith_cluster_name="${MONOLITH_CLUSTER_NAME:-${project_prefix}-monolith}"
msa_cluster_name="${MSA_CLUSTER_NAME:-${project_prefix}-msa}"
monolith_rds_id="${MONOLITH_RDS_ID:-${project_prefix}-monolith-postgres}"
msa_rds_id="${MSA_RDS_ID:-${project_prefix}-msa-postgres}"

check_cluster() {
  local cluster_name="$1"
  local addon_address="$2"
  local pod_identity_address="$3"
  local nodegroup_app_address="$4"
  local nodegroup_testing_address="$5"

  local cluster_status=""
  cluster_status="$(list_or_empty aws_with_profile eks describe-cluster --region "$aws_region" --name "$cluster_name" --query 'cluster.status' --output text)"

  if [[ -z "$cluster_status" || "$cluster_status" == "None" ]]; then
    print_status "STALE_IN_STATE" "Cluster missing in AWS: $cluster_name"
    return
  fi

  if [[ "$cluster_status" == "ACTIVE" ]]; then
    print_status "OK" "Cluster active in AWS: $cluster_name"
  else
    print_status "IN_PROGRESS" "Cluster present but not active: $cluster_name ($cluster_status)"
  fi

  local nodegroups
  nodegroups="$(list_or_empty aws_with_profile eks list-nodegroups --region "$aws_region" --cluster-name "$cluster_name" --query 'nodegroups' --output text)"
  if [[ -n "$nodegroups" ]]; then
    print_status "OK" "Node groups in AWS for $cluster_name: $nodegroups"
  else
    print_status "REVIEW" "No node groups returned for $cluster_name"
  fi

  local addon_status
  addon_status="$(list_or_empty aws_with_profile eks describe-addon --region "$aws_region" --cluster-name "$cluster_name" --addon-name eks-pod-identity-agent --query 'addon.status' --output text)"
  if have_state_address "$experiment_state_list" "$addon_address"; then
    if [[ -n "$addon_status" && "$addon_status" != "None" ]]; then
      if [[ "$addon_status" == "ACTIVE" ]]; then
        print_status "OK" "Addon active for $cluster_name: eks-pod-identity-agent"
      else
        print_status "IN_PROGRESS" "Addon present but not active for $cluster_name: $addon_status"
      fi
    else
      print_status "STALE_IN_STATE" "Addon missing in AWS for $cluster_name: eks-pod-identity-agent"
      printf '  suggested: AWS_PROFILE=%s terraform -chdir=%s state rm %s\n' \
        "$terraform_aws_profile" "$tf_experiment_dir" "$addon_address"
    fi
  fi

  local pod_identity_id=""
  pod_identity_id="$(list_or_empty aws_with_profile eks list-pod-identity-associations \
    --region "$aws_region" \
    --cluster-name "$cluster_name" \
    --query "associations[?namespace=='benchmark' && serviceAccount=='k6-runner'].associationId | [0]" \
    --output text)"
  if have_state_address "$experiment_state_list" "$pod_identity_address"; then
    if [[ -n "$pod_identity_id" && "$pod_identity_id" != "None" ]]; then
      print_status "OK" "Pod identity association exists for $cluster_name benchmark/k6-runner"
    else
      print_status "STALE_IN_STATE" "Pod identity association missing in AWS for $cluster_name benchmark/k6-runner"
      printf '  suggested: AWS_PROFILE=%s terraform -chdir=%s state rm %s\n' \
        "$terraform_aws_profile" "$tf_experiment_dir" "$pod_identity_address"
    fi
  fi

  if have_state_address "$experiment_state_list" "$nodegroup_app_address" || have_state_address "$experiment_state_list" "$nodegroup_testing_address"; then
    if [[ -z "$nodegroups" ]]; then
      print_status "STALE_IN_STATE" "State expects node groups for $cluster_name but AWS returned none"
    fi
  fi
}

check_rds() {
  local db_id="$1"
  local state_address="$2"
  local status=""
  status="$(list_or_empty aws_with_profile rds describe-db-instances --region "$aws_region" --db-instance-identifier "$db_id" --query 'DBInstances[0].DBInstanceStatus' --output text)"

  if have_state_address "$experiment_state_list" "$state_address"; then
    if [[ -z "$status" || "$status" == "None" ]]; then
      print_status "STALE_IN_STATE" "RDS missing in AWS: $db_id"
      printf '  suggested: AWS_PROFILE=%s terraform -chdir=%s state rm %s\n' \
        "$terraform_aws_profile" "$tf_experiment_dir" "$state_address"
    elif [[ "$status" == "available" ]]; then
      print_status "OK" "RDS available in AWS: $db_id"
    else
      print_status "IN_PROGRESS" "RDS present but not ready: $db_id ($status)"
    fi
  fi
}

check_cluster \
  "$monolith_cluster_name" \
  'module.monolith_cluster.module.eks.aws_eks_addon.this["eks-pod-identity-agent"]' \
  'module.monolith_cluster.aws_eks_pod_identity_association.k6_runner' \
  'module.monolith_cluster.module.eks.module.eks_managed_node_group["app_nodes"].aws_eks_node_group.this[0]' \
  'module.monolith_cluster.module.eks.module.eks_managed_node_group["testing_nodes"].aws_eks_node_group.this[0]'

check_cluster \
  "$msa_cluster_name" \
  'module.msa_cluster.module.eks.aws_eks_addon.this["eks-pod-identity-agent"]' \
  'module.msa_cluster.aws_eks_pod_identity_association.k6_runner' \
  'module.msa_cluster.module.eks.module.eks_managed_node_group["app_nodes"].aws_eks_node_group.this[0]' \
  'module.msa_cluster.module.eks.module.eks_managed_node_group["testing_nodes"].aws_eks_node_group.this[0]'

check_rds "$monolith_rds_id" 'module.monolith_cluster.aws_db_instance.postgres'
check_rds "$msa_rds_id" 'module.msa_cluster.aws_db_instance.postgres'

print_section "Suggested next steps"
echo "1. If all critical resources are [OK], run:"
printf '   AWS_PROFILE=%s terraform -chdir=%s plan -input=false -lock=false\n' "$terraform_aws_profile" "$tf_experiment_dir"
echo "2. If any resource is [STALE_IN_STATE], review the suggested terraform state rm commands before applying them."
echo "3. If AWS has resources that state does not track, import them explicitly instead of recreating blindly."
echo "4. If resources are [IN_PROGRESS], wait for AWS to finish before retrying apply/destroy."
