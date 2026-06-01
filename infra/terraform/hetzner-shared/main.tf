terraform {
  required_version = ">= 1.6"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.50"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

locals {
  common_labels = {
    project     = var.project
    environment = "benchmark"
    managed_by  = "terraform"
  }
}

resource "hcloud_network" "main" {
  name     = "${var.project}-hetzner-network"
  ip_range = var.network_cidr
  labels   = local.common_labels
}

resource "hcloud_network_subnet" "main" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = var.subnet_cidr
}

resource "hcloud_ssh_key" "operator" {
  name       = "${var.project}-operator"
  public_key = var.operator_ssh_public_key
  labels     = local.common_labels
}

resource "hcloud_firewall" "control_plane" {
  name   = "${var.project}-control-plane"
  labels = local.common_labels

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.operator_cidrs
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = var.operator_cidrs
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = [var.network_cidr]
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = [var.network_cidr]
  }
}

resource "hcloud_firewall" "worker" {
  name   = "${var.project}-worker"
  labels = local.common_labels

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.operator_cidrs
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "1-65535"
    source_ips = [var.network_cidr]
  }

  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "1-65535"
    source_ips = [var.network_cidr]
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = [var.network_cidr]
  }
}

resource "hcloud_firewall" "postgres" {
  name   = "${var.project}-postgres"
  labels = local.common_labels

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.operator_cidrs
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "5432"
    source_ips = [var.network_cidr]
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = [var.network_cidr]
  }
}
