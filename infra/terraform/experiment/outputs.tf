output "monolith_cluster_name" {
  value = module.monolith_cluster.cluster_name
}

output "monolith_rds_endpoint" {
  value = module.monolith_cluster.rds_endpoint
}

output "monolith_kubeconfig_command" {
  value = module.monolith_cluster.kubeconfig_command
}

output "msa_cluster_name" {
  value = module.msa_cluster.cluster_name
}

output "msa_rds_endpoint" {
  value = module.msa_cluster.rds_endpoint
}

output "msa_kubeconfig_command" {
  value = module.msa_cluster.kubeconfig_command
}
