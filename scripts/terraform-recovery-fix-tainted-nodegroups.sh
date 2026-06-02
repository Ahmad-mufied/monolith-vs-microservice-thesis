#!/usr/bin/env bash
set -euo pipefail

terraform_aws_profile="${TERRAFORM_AWS_PROFILE:-terraform-process}"
aws_region="${AWS_REGION:-ap-southeast-1}"
project_prefix="${PROJECT_PREFIX:-skripsi}"
tf_experiment_dir="infra/terraform/aws-parallel"
apply=false

usage() {
  cat <<'USAGE'
Usage:
  scripts/terraform-recovery-fix-tainted-nodegroups.sh [--apply]

Default mode is dry-run. It only prints the untaint commands that are safe to
run when an EKS managed node group is:
  - present in Terraform state,
  - marked as tainted in Terraform state,
  - ACTIVE in AWS, and
  - has no EKS node group health issues.

Use --apply to run the suggested untaint commands.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      apply=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

terraform_with_profile() {
  AWS_PROFILE="$terraform_aws_profile" terraform "$@"
}

aws_with_profile() {
  AWS_PROFILE="$terraform_aws_profile" aws "$@"
}

state_show_or_empty() {
  local address="$1"
  terraform_with_profile -chdir="$tf_experiment_dir" state show -no-color "$address" 2>/dev/null || true
}

value_from_state_show() {
  local state_show="$1"
  local key="$2"
  awk -v key="$key" '
    $1 == key && $2 == "=" {
      gsub(/"/, "", $3)
      print $3
      exit
    }
  ' <<<"$state_show"
}

print_status() {
  local status="$1"
  local message="$2"
  printf '[%s] %s\n' "$status" "$message"
}

check_and_fix() {
  local cluster_name="$1"
  local address="$2"
  local label="$3"
  local state_show=""
  local state_id=""
  local nodegroup_name=""
  local nodegroup_status=""
  local health_issues_json=""
  local health_issue_count=""

  state_show="$(state_show_or_empty "$address")"
  if [[ -z "$state_show" ]]; then
    print_status "SKIP" "$label node group address is not in Terraform state: $address"
    return
  fi

  if ! grep -Fq '(tainted)' <<<"$state_show"; then
    print_status "OK" "$label node group is not tainted in Terraform state"
    return
  fi

  state_id="$(value_from_state_show "$state_show" "id")"
  nodegroup_name="${state_id#*:}"
  if [[ -z "$nodegroup_name" || "$nodegroup_name" == "$state_id" ]]; then
    nodegroup_name="$(value_from_state_show "$state_show" "node_group_name")"
  fi

  if [[ -z "$nodegroup_name" ]]; then
    print_status "REVIEW" "$label node group is tainted, but the node group name could not be read from state"
    return
  fi

  nodegroup_status="$(aws_with_profile eks describe-nodegroup \
    --region "$aws_region" \
    --cluster-name "$cluster_name" \
    --nodegroup-name "$nodegroup_name" \
    --query 'nodegroup.status' \
    --output text 2>/dev/null || true)"

  if [[ -z "$nodegroup_status" || "$nodegroup_status" == "None" ]]; then
    print_status "REVIEW" "$label node group is tainted, but AWS did not return it: $cluster_name/$nodegroup_name"
    return
  fi

  health_issues_json="$(aws_with_profile eks describe-nodegroup \
    --region "$aws_region" \
    --cluster-name "$cluster_name" \
    --nodegroup-name "$nodegroup_name" \
    --query 'nodegroup.health.issues' \
    --output json 2>/dev/null || true)"

  case "$health_issues_json" in
    ""|"null"|"None"|"[]")
      health_issue_count="0"
      ;;
    *)
      health_issue_count="1+"
      ;;
  esac

  if [[ "$nodegroup_status" != "ACTIVE" || "$health_issue_count" != "0" ]]; then
    print_status "SKIP" "$label node group is tainted but not safe to untaint yet: $cluster_name/$nodegroup_name status=$nodegroup_status health_issues=$health_issue_count"
    return
  fi

  if [[ "$apply" == "true" ]]; then
    print_status "FIX" "Untainting active healthy $label node group: $cluster_name/$nodegroup_name"
    terraform_with_profile -chdir="$tf_experiment_dir" untaint "$address"
  else
    print_status "DRY_RUN" "Safe to untaint active healthy $label node group: $cluster_name/$nodegroup_name"
    printf '  run: AWS_PROFILE=%s terraform -chdir=%s untaint %q\n' \
      "$terraform_aws_profile" "$tf_experiment_dir" "$address"
  fi
}

if [[ ! -d "$tf_experiment_dir" ]]; then
  print_status "BLOCKED" "Terraform experiment directory not found from current working directory"
  exit 1
fi

if ! aws_with_profile sts get-caller-identity >/dev/null 2>&1; then
  print_status "BLOCKED" "AWS auth failed for profile '$terraform_aws_profile'. Run: aws login && make terraform-auth-check"
  exit 1
fi

terraform_with_profile -chdir="$tf_experiment_dir" init -input=false >/dev/null

monolith_cluster_name="${MONOLITH_CLUSTER_NAME:-${project_prefix}-monolith}"
msa_cluster_name="${MSA_CLUSTER_NAME:-${project_prefix}-msa}"

echo "Terraform tainted node group recovery"
echo "  mode        : $([[ "$apply" == "true" ]] && echo apply || echo dry-run)"
echo "  AWS profile : $terraform_aws_profile"
echo "  AWS region  : $aws_region"

check_and_fix "$monolith_cluster_name" 'module.monolith_cluster.module.eks.module.eks_managed_node_group["app_nodes"].aws_eks_node_group.this[0]' "monolith app"
check_and_fix "$monolith_cluster_name" 'module.monolith_cluster.module.eks.module.eks_managed_node_group["testing_nodes"].aws_eks_node_group.this[0]' "monolith testing"
check_and_fix "$msa_cluster_name" 'module.msa_cluster.module.eks.module.eks_managed_node_group["app_nodes"].aws_eks_node_group.this[0]' "MSA app"
check_and_fix "$msa_cluster_name" 'module.msa_cluster.module.eks.module.eks_managed_node_group["testing_nodes"].aws_eks_node_group.this[0]' "MSA testing"

if [[ "$apply" == "true" ]]; then
  echo
  echo "Next:"
  echo "  TERRAFORM_AWS_PROFILE=$terraform_aws_profile bash scripts/terraform-aws-parallel.sh plan -input=false -lock=false -no-color"
else
  echo
  echo "Dry-run only. Re-run with --apply to untaint safe active node groups."
fi
