output "sequential_cluster_name" {
  value = module.sequential_cluster.cluster_name
}

output "sequential_rds_endpoint" {
  value = module.sequential_cluster.rds_endpoint
}

output "sequential_kubeconfig_command" {
  value = module.sequential_cluster.kubeconfig_command
}
