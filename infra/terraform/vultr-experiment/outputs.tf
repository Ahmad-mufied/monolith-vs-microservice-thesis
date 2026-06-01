output "monolith_cluster_name" {
  description = "Monolith VKE cluster name."
  value       = module.monolith_cluster.cluster_name
}

output "monolith_kube_config" {
  description = "Base64 encoded monolith VKE kubeconfig."
  value       = module.monolith_cluster.kube_config
  sensitive   = true
}

output "monolith_postgres_private_ip" {
  description = "Monolith PostgreSQL private IPv4 address."
  value       = module.monolith_cluster.postgres_private_ip
}

output "msa_cluster_name" {
  description = "MSA VKE cluster name."
  value       = module.msa_cluster.cluster_name
}

output "msa_kube_config" {
  description = "Base64 encoded MSA VKE kubeconfig."
  value       = module.msa_cluster.kube_config
  sensitive   = true
}

output "msa_postgres_private_ip" {
  description = "MSA PostgreSQL private IPv4 address."
  value       = module.msa_cluster.postgres_private_ip
}

