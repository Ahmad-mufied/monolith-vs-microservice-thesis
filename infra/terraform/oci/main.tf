terraform {
  required_version = ">= 1.5.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0"
    }
  }
}

provider "oci" {
  region               = var.region
  tenancy_ocid         = var.tenancy_ocid != "" ? var.tenancy_ocid : null
  user_ocid            = var.user_ocid != "" ? var.user_ocid : null
  fingerprint          = var.fingerprint != "" ? var.fingerprint : null
  private_key_path     = var.private_key_path != "" ? var.private_key_path : null
  private_key_password = var.private_key_password != "" ? var.private_key_password : null
}

locals {
  common_labels = {
    project     = var.project
    environment = "benchmark"
    managed_by  = "terraform"
  }

  architectures = var.execution_mode == "parallel" ? {
    monolith = { architecture = "monolith" }
    msa      = { architecture = "msa" }
  } : {
    sequential = { architecture = "sequential" }
  }
}

# ─── Networking ───────────────────────────────────────────────────────────────

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

resource "oci_core_vcn" "benchmark_vcn" {
  compartment_id = var.compartment_id
  display_name   = "${var.project}-oci-vcn"
  cidr_block     = "10.0.0.0/16"
  dns_label      = "skripsivcn"
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.benchmark_vcn.id
  display_name   = "${var.project}-oci-igw"
  enabled        = true
}

resource "oci_core_route_table" "public_route_table" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.benchmark_vcn.id
  display_name   = "${var.project}-oci-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_nat_gateway" "nat_gateway" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.benchmark_vcn.id
  display_name   = "${var.project}-oci-nat-gw"
}

resource "oci_core_route_table" "private_route_table" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.benchmark_vcn.id
  display_name   = "${var.project}-oci-private-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.nat_gateway.id
  }
}

# ─── Subnets ──────────────────────────────────────────────────────────────────

resource "oci_core_security_list" "oke_security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.benchmark_vcn.id
  display_name   = "${var.project}-oke-security-list"

  ingress_security_rules {
    source   = "10.0.0.0/16"
    protocol = "all"
  }

  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "6"
    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "6"
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
}

resource "oci_core_subnet" "oke_subnet" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.benchmark_vcn.id
  display_name      = "${var.project}-oke-subnet"
  cidr_block        = "10.0.10.0/24"
  route_table_id    = oci_core_route_table.public_route_table.id
  security_list_ids = [oci_core_security_list.oke_security_list.id]
  dns_label         = "okesubnet"
}

resource "oci_core_subnet" "db_monolith_subnet" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.benchmark_vcn.id
  display_name      = "${var.project}-db-monolith-subnet"
  cidr_block        = "10.0.2.0/24"
  route_table_id    = oci_core_route_table.private_route_table.id
  security_list_ids = [oci_core_security_list.oke_security_list.id]
  dns_label         = "dbmono"
}

resource "oci_core_subnet" "db_msa_subnet" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.benchmark_vcn.id
  display_name      = "${var.project}-db-msa-subnet"
  cidr_block        = "10.0.4.0/24"
  route_table_id    = oci_core_route_table.private_route_table.id
  security_list_ids = [oci_core_security_list.oke_security_list.id]
  dns_label         = "dbmsa"
}

# ─── Single OKE Cluster & Architecture Node Pools ────────────────────────────

resource "oci_containerengine_cluster" "benchmark" {
  compartment_id     = var.compartment_id
  kubernetes_version = var.kubernetes_version
  name               = "${var.project}-oci-cluster"
  vcn_id             = oci_core_vcn.benchmark_vcn.id
  type               = "BASIC_CLUSTER"

  endpoint_config {
    is_public_ip_enabled = true
    subnet_id            = oci_core_subnet.oke_subnet.id
  }
}

data "oci_containerengine_node_pool_option" "oke_node_pool_option" {
  node_pool_option_id = oci_containerengine_cluster.benchmark.id
  compartment_id      = var.compartment_id
}

resource "oci_containerengine_node_pool" "app_nodes" {
  for_each           = local.architectures
  cluster_id         = oci_containerengine_cluster.benchmark.id
  compartment_id     = var.compartment_id
  kubernetes_version = var.kubernetes_version
  name               = "${var.project}-oci-${each.key}-app-node"
  node_shape         = var.node_shape

  node_shape_config {
    ocpus         = var.app_node_ocpus
    memory_in_gbs = var.app_node_memory_in_gbs
  }

  node_config_details {
    size = var.app_node_count
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = oci_core_subnet.oke_subnet.id
    }
  }

  initial_node_labels {
    key   = "node-group"
    value = "app"
  }
  initial_node_labels {
    key   = "workload"
    value = "application"
  }
  initial_node_labels {
    key   = "architecture"
    value = each.value.architecture
  }

  node_source_details {
    image_id    = var.node_image_id != "" ? var.node_image_id : [for s in data.oci_containerengine_node_pool_option.oke_node_pool_option.sources : s.image_id if (length(regexall(".*aarch64.*", s.source_name)) > 0) == (var.node_shape == "VM.Standard.A1.Flex") && length(regexall(".*GPU.*", s.source_name)) == 0 && length(regexall(replace(trimprefix(var.kubernetes_version, "v"), ".", "[.]"), s.source_name)) > 0][0]
    source_type = "IMAGE"
  }
}

resource "oci_containerengine_node_pool" "testing_nodes" {
  cluster_id         = oci_containerengine_cluster.benchmark.id
  compartment_id     = var.compartment_id
  kubernetes_version = var.kubernetes_version
  name               = "${var.project}-oci-test-node"
  node_shape         = var.testing_node_shape

  node_shape_config {
    ocpus         = var.testing_node_ocpus
    memory_in_gbs = var.testing_node_memory_in_gbs
  }

  node_config_details {
    size = var.testing_node_count
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = oci_core_subnet.oke_subnet.id
    }
  }

  initial_node_labels {
    key   = "node-group"
    value = "testing"
  }
  initial_node_labels {
    key   = "workload"
    value = "benchmark"
  }

  node_source_details {
    image_id    = var.node_image_id != "" ? var.node_image_id : [for s in data.oci_containerengine_node_pool_option.oke_node_pool_option.sources : s.image_id if (length(regexall(".*aarch64.*", s.source_name)) > 0) == (var.testing_node_shape == "VM.Standard.A1.Flex") && length(regexall(".*GPU.*", s.source_name)) == 0 && length(regexall(replace(trimprefix(var.kubernetes_version, "v"), ".", "[.]"), s.source_name)) > 0][0]
    source_type = "IMAGE"
  }
}

# ─── Dedicated PostgreSQL Database Compute VMs ────────────────────────────────

data "oci_core_images" "db_image" {
  compartment_id           = var.compartment_id
  operating_system         = "Oracle Linux"
  operating_system_version = "8"
  shape                    = var.db_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "db" {
  for_each            = local.architectures
  compartment_id      = var.compartment_id
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "${var.project}-oci-${each.key}-db"
  shape               = var.db_shape

  shape_config {
    ocpus         = var.db_ocpus
    memory_in_gbs = var.db_memory_in_gbs
  }

  create_vnic_details {
    subnet_id        = each.key == "monolith" ? oci_core_subnet.db_monolith_subnet.id : oci_core_subnet.db_msa_subnet.id
    assign_public_ip = false
    display_name     = "${var.project}-oci-${each.key}-db-vnic"
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.db_image.images[0].id
  }

  metadata = {
    user_data = base64encode(<<-EOF
      #!/bin/bash
      systemctl stop firewalld || true
      systemctl disable firewalld || true
      iptables -F || true
      dnf install -y podman || true
      podman run -d \
        --name postgres \
        --restart always \
        -p 5432:5432 \
        -e POSTGRES_USER=postgres_admin \
        -e POSTGRES_PASSWORD='${var.db_password}' \
        -e POSTGRES_DB=postgres \
        docker.io/library/postgres:18-alpine
    EOF
    )
  }
}
