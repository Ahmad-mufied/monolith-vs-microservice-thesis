output "network_id" {
  description = "Hetzner private network ID."
  value       = hcloud_network.main.id
}

output "network_cidr" {
  description = "Hetzner private network CIDR."
  value       = var.network_cidr
}

output "network_zone" {
  description = "Hetzner private network zone."
  value       = var.network_zone
}

output "ssh_key_ids" {
  description = "SSH key IDs for server provisioning."
  value       = [hcloud_ssh_key.operator.id]
}

output "control_plane_firewall_ids" {
  description = "Firewall IDs for control-plane nodes."
  value       = [hcloud_firewall.control_plane.id]
}

output "app_firewall_ids" {
  description = "Firewall IDs for app nodes."
  value       = [hcloud_firewall.worker.id]
}

output "testing_firewall_ids" {
  description = "Firewall IDs for testing nodes."
  value       = [hcloud_firewall.worker.id]
}

output "postgres_firewall_ids" {
  description = "Firewall IDs for PostgreSQL nodes."
  value       = [hcloud_firewall.postgres.id]
}
