terraform {
  required_version = ">= 1.6"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

data "terraform_remote_state" "shared" {
  backend = "local"
  config = {
    path = "../hetzner-shared/terraform.tfstate"
  }
}

locals {
  common_labels = {
    project     = var.project
    environment = "benchmark"
    managed_by  = "terraform"
  }
}

module "sequential_cluster" {
  source = "../modules/hetzner-k3s-cluster"

  cluster_name               = var.sequential_cluster_name
  architecture               = "benchmark"
  location                   = var.location
  network_id                 = data.terraform_remote_state.shared.outputs.network_id
  network_zone               = data.terraform_remote_state.shared.outputs.network_zone
  ssh_key_ids                = data.terraform_remote_state.shared.outputs.ssh_key_ids
  control_plane_firewall_ids = data.terraform_remote_state.shared.outputs.control_plane_firewall_ids
  app_firewall_ids           = data.terraform_remote_state.shared.outputs.app_firewall_ids
  testing_firewall_ids       = data.terraform_remote_state.shared.outputs.testing_firewall_ids
  postgres_firewall_ids      = data.terraform_remote_state.shared.outputs.postgres_firewall_ids
  control_plane_server_type  = var.control_plane_server_type
  app_server_type            = var.app_server_type
  testing_server_type        = var.testing_server_type
  postgres_server_type       = var.postgres_server_type
  postgres_password          = var.postgres_password
  labels                     = local.common_labels
}
