output "cluster_name" {
  description = "Hetzner k3s cluster name."
  value       = var.cluster_name
}

output "control_plane_public_ip" {
  description = "Public IPv4 address of the k3s control plane."
  value       = hcloud_server.control_plane.ipv4_address
}

output "control_plane_private_ip" {
  description = "Private IPv4 address of the k3s control plane."
  value       = one(hcloud_server.control_plane.network).ip
}

output "app_private_ips" {
  description = "Private IPv4 addresses of app worker nodes."
  value       = [for node in hcloud_server.app : one(node.network).ip]
}

output "testing_private_ips" {
  description = "Private IPv4 addresses of testing worker nodes."
  value       = [for node in hcloud_server.testing : one(node.network).ip]
}

output "postgres_private_ip" {
  description = "Private IPv4 address of the PostgreSQL server."
  value       = one(hcloud_server.postgres.network).ip
}
