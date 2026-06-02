output "cluster_name" {
  description = "VKE cluster name."
  value       = vultr_kubernetes.cluster.label
}

output "cluster_id" {
  description = "VKE cluster ID."
  value       = vultr_kubernetes.cluster.id
}

output "kube_config" {
  description = "Base64 encoded VKE kubeconfig."
  value       = vultr_kubernetes.cluster.kube_config
  sensitive   = true
}

output "app_node_pool" {
  description = "Default app node pool metadata."
  value       = vultr_kubernetes.cluster.node_pools
}

output "testing_node_pool_id" {
  description = "Testing node pool ID."
  value       = vultr_kubernetes_node_pools.testing.id
}

output "postgres_private_ip" {
  description = "PostgreSQL private IPv4 address."
  value       = try(vultr_instance.postgres.internal_ip, "")
}

output "postgres_public_ip" {
  description = "PostgreSQL public IPv4 address for operator SSH only."
  value       = vultr_instance.postgres.main_ip
}

