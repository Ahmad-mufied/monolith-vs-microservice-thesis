provider "vultr" {}

locals {
  common_labels = {
    project     = var.project
    environment = "benchmark"
    managed_by  = "terraform"
  }

  vpc_cidr = "${var.vpc_subnet}/${var.vpc_subnet_mask}"

  operator_ipv4_cidrs = [
    for cidr in var.operator_cidrs : cidr
    if !strcontains(cidr, ":")
  ]

  clusters = var.execution_mode == "parallel" ? {
    monolith = { architecture = "monolith" }
    msa      = { architecture = "msa" }
    } : {
    sequential = { architecture = "sequential" }
  }
}

# ─── Shared Infrastructure ───────────────────────────────────────────────────

resource "vultr_vpc" "benchmark" {
  region         = var.region
  description    = "${var.project}-vultr-benchmark"
  v4_subnet      = var.vpc_subnet
  v4_subnet_mask = var.vpc_subnet_mask
}

resource "vultr_ssh_key" "operator" {
  name    = "${var.project}-vultr-operator"
  ssh_key = var.operator_ssh_public_key
}

resource "vultr_firewall_group" "postgres" {
  description = "${var.project}-vultr-postgres"
}

resource "vultr_firewall_rule" "postgres_private" {
  firewall_group_id = vultr_firewall_group.postgres.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = var.vpc_subnet
  subnet_size       = var.vpc_subnet_mask
  port              = "5432"
  notes             = "PostgreSQL private VPC access only"
}

resource "vultr_firewall_rule" "postgres_ssh_private" {
  firewall_group_id = vultr_firewall_group.postgres.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = var.vpc_subnet
  subnet_size       = var.vpc_subnet_mask
  port              = "22"
  notes             = "SSH private VPC access only"
}

resource "vultr_firewall_rule" "postgres_ssh_operator" {
  for_each = toset(local.operator_ipv4_cidrs)

  firewall_group_id = vultr_firewall_group.postgres.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = split("/", each.value)[0]
  subnet_size       = tonumber(split("/", each.value)[1])
  port              = "22"
  notes             = "Operator SSH access"
}

# ─── Benchmark Clusters ──────────────────────────────────────────────────────

module "cluster" {
  for_each = local.clusters
  source   = "../modules/vultr-vke-benchmark-cluster"

  cluster_name               = lookup(var.cluster_names, each.key, "${var.project}-vultr-${each.key}")
  architecture               = each.value.architecture
  region                     = var.region
  kubernetes_version         = var.kubernetes_version
  vpc_id                     = vultr_vpc.benchmark.id
  vpc_cidr                   = local.vpc_cidr
  ssh_key_ids                = [vultr_ssh_key.operator.id]
  postgres_firewall_group_id = vultr_firewall_group.postgres.id
  app_node_plan              = var.app_node_plan
  app_node_count             = var.app_node_count
  testing_node_plan          = var.testing_node_plan
  postgres_plan              = var.postgres_plan
  postgres_os_id             = var.postgres_os_id
  postgres_password          = var.postgres_password
  labels                     = local.common_labels
}
