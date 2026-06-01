terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  common_tags = {
    Project     = var.project
    Environment = "benchmark"
    ManagedBy   = "terraform"
  }
}

# ─── VPC ─────────────────────────────────────────────────────────────────────

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project}-vpc"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Required tags for EKS subnet discovery
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  tags = local.common_tags
}

# ─── IAM: k6 runner S3 access (used by both clusters via EKS Pod Identity) ──
# S3 bucket and ECR repositories are created manually (persistent resources).
# This role grants k6 runner pods access to the manually created S3 bucket.

resource "aws_iam_role" "k6_runner" {
  name = "${var.project}-k6-runner"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "k6_runner_s3" {
  name = "s3-results-access"
  role = aws_iam_role.k6_runner.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
      Resource = [
        "arn:aws:s3:::${var.s3_results_bucket}",
        "arn:aws:s3:::${var.s3_results_bucket}/*",
      ]
    }]
  })
}

# ─── AWS Budget Nuclear Shutdown ──────────────────────────────────────────────
# Budget lives in shared stack so it persists across experiment apply/destroy
# cycles. Cluster names and RDS identifiers must stay aligned with the
# experiment stack naming inputs.

module "aws_budget" {
  source = "../modules/aws-budget"

  project                  = var.project
  aws_region               = var.aws_region
  budget_amount            = var.budget_amount
  budget_threshold_percent = var.budget_threshold_percent
  budget_alert_emails      = var.budget_alert_emails
  cluster_names            = [var.monolith_cluster_name, var.msa_cluster_name, var.sequential_cluster_name]
  rds_instance_ids         = ["${var.monolith_cluster_name}-postgres", "${var.msa_cluster_name}-postgres", "${var.sequential_cluster_name}-postgres"]
  vpc_id                   = module.vpc.vpc_id
  delete_eks               = true
  tags                     = local.common_tags
}
