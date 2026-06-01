output "monolith_cluster_name" {
  description = "Monolith Hetzner k3s cluster name."
  value       = module.monolith_cluster.cluster_name
}

output "monolith_control_plane_public_ip" {
  description = "Monolith control-plane public IPv4 address."
  value       = module.monolith_cluster.control_plane_public_ip
}

output "monolith_postgres_private_ip" {
  description = "Monolith PostgreSQL private IPv4 address."
  value       = module.monolith_cluster.postgres_private_ip
}

output "msa_cluster_name" {
  description = "MSA Hetzner k3s cluster name."
  value       = module.msa_cluster.cluster_name
}

output "msa_control_plane_public_ip" {
  description = "MSA control-plane public IPv4 address."
  value       = module.msa_cluster.control_plane_public_ip
}

output "msa_postgres_private_ip" {
  description = "MSA PostgreSQL private IPv4 address."
  value       = module.msa_cluster.postgres_private_ip
}
