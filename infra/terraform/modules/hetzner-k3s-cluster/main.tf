terraform {
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

locals {
  common_labels = merge(var.labels, {
    project      = "skripsi"
    environment  = "benchmark"
    architecture = var.architecture
    managed_by   = "terraform"
  })

  control_plane_name = "${var.cluster_name}-control-1"
  postgres_name      = "${var.cluster_name}-postgres"
}

resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

resource "hcloud_server" "control_plane" {
  name         = local.control_plane_name
  image        = var.image
  server_type  = var.control_plane_server_type
  location     = var.location
  ssh_keys     = var.ssh_key_ids
  firewall_ids = var.control_plane_firewall_ids

  labels = merge(local.common_labels, {
    role = "control-plane"
  })

  network {
    network_id = var.network_id
  }

  user_data = templatefile("${path.module}/templates/control-plane-cloud-init.yaml.tftpl", {
    cluster_name = var.cluster_name
    k3s_token    = random_password.k3s_token.result
  })
}

resource "hcloud_server" "app" {
  count = var.app_node_count

  name         = "${var.cluster_name}-app-${count.index + 1}"
  image        = var.image
  server_type  = var.app_server_type
  location     = var.location
  ssh_keys     = var.ssh_key_ids
  firewall_ids = var.app_firewall_ids

  labels = merge(local.common_labels, {
    role       = "app"
    node_group = "app"
  })

  network {
    network_id = var.network_id
  }

  user_data = templatefile("${path.module}/templates/agent-cloud-init.yaml.tftpl", {
    node_group         = "app"
    k3s_token          = random_password.k3s_token.result
    control_private_ip = one(hcloud_server.control_plane.network).ip
    extra_node_args    = "--node-label=node-group=app"
  })

  depends_on = [hcloud_server.control_plane]
}

resource "hcloud_server" "testing" {
  count = var.testing_node_count

  name         = "${var.cluster_name}-testing-${count.index + 1}"
  image        = var.image
  server_type  = var.testing_server_type
  location     = var.location
  ssh_keys     = var.ssh_key_ids
  firewall_ids = var.testing_firewall_ids

  labels = merge(local.common_labels, {
    role       = "testing"
    node_group = "testing"
  })

  network {
    network_id = var.network_id
  }

  user_data = templatefile("${path.module}/templates/agent-cloud-init.yaml.tftpl", {
    node_group         = "testing"
    k3s_token          = random_password.k3s_token.result
    control_private_ip = one(hcloud_server.control_plane.network).ip
    extra_node_args    = "--node-label=node-group=testing --node-taint=workload=benchmark:NoSchedule"
  })

  depends_on = [hcloud_server.control_plane]
}

resource "hcloud_server" "postgres" {
  name         = local.postgres_name
  image        = var.image
  server_type  = var.postgres_server_type
  location     = var.location
  ssh_keys     = var.ssh_key_ids
  firewall_ids = var.postgres_firewall_ids

  labels = merge(local.common_labels, {
    role = "postgres"
  })

  network {
    network_id = var.network_id
  }

  user_data = templatefile("${path.module}/templates/postgres-cloud-init.yaml.tftpl", {
    network_cidr      = var.network_cidr
    postgres_password = replace(var.postgres_password, "'", "''")
  })
}
