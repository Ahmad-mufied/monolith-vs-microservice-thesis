provider "vultr" {}

data "terraform_remote_state" "shared" {
  backend = "local"
  config = {
    path = "../vultr-shared/terraform.tfstate"
  }
}

locals {
  common_labels = {
    project     = var.project
    environment = "benchmark"
    managed_by  = "terraform"
  }
}

module "monolith_cluster" {
  source = "../modules/vultr-vke-benchmark-cluster"

  cluster_name               = var.monolith_cluster_name
  architecture               = "monolith"
  region                     = var.region
  kubernetes_version         = var.kubernetes_version
  vpc_id                     = data.terraform_remote_state.shared.outputs.vpc_id
  vpc_cidr                   = data.terraform_remote_state.shared.outputs.vpc_cidr
  ssh_key_ids                = data.terraform_remote_state.shared.outputs.ssh_key_ids
  postgres_firewall_group_id = data.terraform_remote_state.shared.outputs.postgres_firewall_group_id
  app_node_plan              = var.app_node_plan
  testing_node_plan          = var.testing_node_plan
  postgres_plan              = var.postgres_plan
  postgres_os_id             = var.postgres_os_id
  postgres_password          = var.postgres_password
  labels                     = local.common_labels
}

module "msa_cluster" {
  source = "../modules/vultr-vke-benchmark-cluster"

  cluster_name               = var.msa_cluster_name
  architecture               = "msa"
  region                     = var.region
  kubernetes_version         = var.kubernetes_version
  vpc_id                     = data.terraform_remote_state.shared.outputs.vpc_id
  vpc_cidr                   = data.terraform_remote_state.shared.outputs.vpc_cidr
  ssh_key_ids                = data.terraform_remote_state.shared.outputs.ssh_key_ids
  postgres_firewall_group_id = data.terraform_remote_state.shared.outputs.postgres_firewall_group_id
  app_node_plan              = var.app_node_plan
  testing_node_plan          = var.testing_node_plan
  postgres_plan              = var.postgres_plan
  postgres_os_id             = var.postgres_os_id
  postgres_password          = var.postgres_password
  labels                     = local.common_labels
}

