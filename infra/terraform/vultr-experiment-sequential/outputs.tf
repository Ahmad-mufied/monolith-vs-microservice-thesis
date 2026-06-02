output "sequential_cluster_name" {
  description = "Sequential VKE cluster name."
  value       = module.sequential_cluster.cluster_name
}

output "sequential_kube_config" {
  description = "Base64 encoded sequential VKE kubeconfig."
  value       = module.sequential_cluster.kube_config
  sensitive   = true
}

output "postgres_private_ip" {
  description = "Sequential PostgreSQL private IPv4 address."
  value       = module.sequential_cluster.postgres_private_ip
}

