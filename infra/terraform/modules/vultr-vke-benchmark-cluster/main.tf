locals {
  common_labels = merge(var.labels, {
    project      = "skripsi"
    environment  = "benchmark"
    architecture = var.architecture
    managed_by   = "terraform"
  })
}

resource "vultr_kubernetes" "cluster" {
  region  = var.region
  label   = var.cluster_name
  version = var.kubernetes_version
  vpc_id  = var.vpc_id

  node_pools {
    node_quantity = var.app_node_count
    plan          = var.app_node_plan
    label         = "${var.cluster_name}-app"
    auto_scaler   = false

    labels {
      key   = "node-group"
      value = "app"
    }

    labels {
      key   = "architecture"
      value = var.architecture
    }

    labels {
      key   = "workload"
      value = "application"
    }
  }
}

resource "vultr_kubernetes_node_pools" "testing" {
  cluster_id    = vultr_kubernetes.cluster.id
  node_quantity = var.testing_node_count
  plan          = var.testing_node_plan
  label         = "${var.cluster_name}-testing"
  tag           = "${var.cluster_name}-testing"
  auto_scaler   = false

  labels {
    key   = "node-group"
    value = "testing"
  }

  labels {
    key   = "architecture"
    value = var.architecture
  }

  labels {
    key   = "workload"
    value = "benchmark"
  }

  taints {
    key    = "workload"
    value  = "benchmark"
    effect = "NoSchedule"
  }
}

resource "vultr_instance" "postgres" {
  label             = "${var.cluster_name}-postgres"
  region            = var.region
  plan              = var.postgres_plan
  os_id             = var.postgres_os_id
  vpc_ids           = [var.vpc_id]
  ssh_key_ids       = var.ssh_key_ids
  firewall_group_id = var.postgres_firewall_group_id

  tags = [
    "project=${lookup(local.common_labels, "project", "skripsi")}",
    "environment=benchmark",
    "architecture=${var.architecture}",
    "role=postgres",
    "managed-by=terraform",
  ]

  user_data = templatefile("${path.module}/templates/postgres-cloud-init.yaml.tftpl", {
    vpc_cidr                      = var.vpc_cidr
    postgres_password_sql_literal = replace(var.postgres_password, "'", "''")
  })
}
