output "execution_mode" {
  description = "Execution mode used for the deployment."
  value       = var.execution_mode
}

output "region" {
  description = "OCI region."
  value       = var.region
}

output "compartment_id" {
  description = "OCI Compartment OCID."
  value       = var.compartment_id
}

output "cluster_ids" {
  description = "Map of architecture key to OKE Cluster OCID."
  value = {
    for k, v in local.architectures : k => oci_containerengine_cluster.benchmark.id
  }
}

output "cluster_names" {
  description = "Map of architecture key to OKE Cluster name."
  value = {
    for k, v in local.architectures : k => oci_containerengine_cluster.benchmark.name
  }
}

output "postgres_db_system_ids" {
  description = "Map of architecture key to PostgreSQL DB instance OCID."
  value = {
    for k, v in oci_core_instance.db : k => v.id
  }
}

output "postgres_endpoints" {
  description = "Map of architecture key to PostgreSQL DB private IP."
  value = {
    for k, v in oci_core_instance.db : k => v.private_ip
  }
}
