output "cluster_name" {
  description = "Sequential Hetzner k3s cluster name."
  value       = module.sequential_cluster.cluster_name
}

output "control_plane_public_ip" {
  description = "Sequential control-plane public IPv4 address."
  value       = module.sequential_cluster.control_plane_public_ip
}

output "postgres_private_ip" {
  description = "Sequential PostgreSQL private IPv4 address."
  value       = module.sequential_cluster.postgres_private_ip
}

output "kubeconfig_fetch_command" {
  description = "Command to fetch sequential kubeconfig."
  value       = module.sequential_cluster.kubeconfig_fetch_command
}
