output "region" {
  description = "Vultr region used by shared resources."
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

output "bastion_firewall_group_id" {
  description = "Firewall group ID for bastion instance."
  value       = vultr_firewall_group.bastion.id
}

output "operator_public_ip" {
  description = "Auto-detected operator public IP used for bastion firewall rule."
  value       = local.operator_public_ip
}

