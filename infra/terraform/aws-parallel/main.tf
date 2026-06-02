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

# ─── Read shared outputs ──────────────────────────────────────────────────────

data "terraform_remote_state" "shared" {
  backend = "local"
  config = {
    path = "../aws-shared/terraform.tfstate"
  }
}

locals {
  vpc_id             = data.terraform_remote_state.shared.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.shared.outputs.private_subnet_ids
  k6_runner_role_arn = data.terraform_remote_state.shared.outputs.k6_runner_role_arn
}

# ─── Monolith Cluster ─────────────────────────────────────────────────────────

module "monolith_cluster" {
  source = "../modules/benchmark-cluster"

  cluster_name                         = var.monolith_cluster_name
  architecture                         = "monolith"
  project                              = var.project
  cluster_version                      = var.cluster_version
  cluster_support_type                 = var.cluster_support_type
  vpc_id                               = local.vpc_id
  private_subnet_ids                   = local.private_subnet_ids
  k6_runner_role_arn                   = local.k6_runner_role_arn
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  db_password                          = var.db_password
  db_instance_class                    = var.db_instance_class
}

# ─── MSA Cluster ──────────────────────────────────────────────────────────────

module "msa_cluster" {
  source = "../modules/benchmark-cluster"

  cluster_name                         = var.msa_cluster_name
  architecture                         = "msa"
  project                              = var.project
  cluster_version                      = var.cluster_version
  cluster_support_type                 = var.cluster_support_type
  vpc_id                               = local.vpc_id
  private_subnet_ids                   = local.private_subnet_ids
  k6_runner_role_arn                   = local.k6_runner_role_arn
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  db_password                          = var.db_password
  db_instance_class                    = var.db_instance_class
}
