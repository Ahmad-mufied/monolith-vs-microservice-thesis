# ─── Shared Outputs ──────────────────────────────────────────────────────────

output "region" {
  description = "Vultr region used by benchmark resources."
  value       = var.region
}

output "vpc_id" {
  description = "Legacy Vultr VPC ID used by VKE and PostgreSQL compute."
  value       = vultr_vpc.benchmark.id
}

output "vpc_cidr" {
  description = "Legacy Vultr VPC CIDR."
  value       = local.vpc_cidr
}

output "ssh_key_ids" {
  description = "Operator SSH key IDs for Vultr compute instances."
  value       = [vultr_ssh_key.operator.id]
}

output "postgres_firewall_group_id" {
  description = "Firewall group ID for PostgreSQL compute nodes."
  value       = vultr_firewall_group.postgres.id
}

output "execution_mode" {
  description = "Current execution mode."
  value       = var.execution_mode
}

# ─── Sequential Outputs ──────────────────────────────────────────────────────

output "sequential_cluster_name" {
  description = "Sequential VKE cluster name."
  value       = var.execution_mode == "sequential" ? module.cluster["sequential"].cluster_name : null
}

output "sequential_kube_config" {
  description = "Base64 encoded sequential VKE kubeconfig."
  value       = var.execution_mode == "sequential" ? module.cluster["sequential"].kube_config : null
  sensitive   = true
}

output "sequential_postgres_private_ip" {
  description = "Sequential PostgreSQL private IPv4 address."
  value       = var.execution_mode == "sequential" ? module.cluster["sequential"].postgres_private_ip : null
}

# ─── Parallel Outputs ────────────────────────────────────────────────────────

output "monolith_cluster_name" {
  description = "Monolith VKE cluster name."
  value       = var.execution_mode == "parallel" ? module.cluster["monolith"].cluster_name : null
}

output "monolith_kube_config" {
  description = "Base64 encoded monolith VKE kubeconfig."
  value       = var.execution_mode == "parallel" ? module.cluster["monolith"].kube_config : null
  sensitive   = true
}

output "monolith_postgres_private_ip" {
  description = "Monolith PostgreSQL private IPv4 address."
  value       = var.execution_mode == "parallel" ? module.cluster["monolith"].postgres_private_ip : null
}

output "msa_cluster_name" {
  description = "MSA VKE cluster name."
  value       = var.execution_mode == "parallel" ? module.cluster["msa"].cluster_name : null
}

output "msa_kube_config" {
  description = "Base64 encoded MSA VKE kubeconfig."
  value       = var.execution_mode == "parallel" ? module.cluster["msa"].kube_config : null
  sensitive   = true
}

output "msa_postgres_private_ip" {
  description = "MSA PostgreSQL private IPv4 address."
  value       = var.execution_mode == "parallel" ? module.cluster["msa"].postgres_private_ip : null
}
