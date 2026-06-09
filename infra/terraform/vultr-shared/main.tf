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
}

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

data "http" "operator_ip" {
  url = "https://ifconfig.me"

  retry {
    attempts     = 3
    min_delay_ms = 1000
    max_delay_ms = 3000
  }
}

locals {
  operator_public_ip = "${chomp(data.http.operator_ip.response_body)}/32"
}

resource "vultr_firewall_group" "bastion" {
  description = "${var.project}-vultr-bastion"
}

resource "vultr_firewall_rule" "bastion_ssh_operator" {
  firewall_group_id = vultr_firewall_group.bastion.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = split("/", local.operator_public_ip)[0]
  subnet_size       = tonumber(split("/", local.operator_public_ip)[1])
  port              = "2002"
  notes             = "Operator SSH access (auto-detected IP)"
}

