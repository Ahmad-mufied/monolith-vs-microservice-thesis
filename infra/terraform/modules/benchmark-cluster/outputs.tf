output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_version" {
  description = "Configured Kubernetes minor version for the EKS cluster"
  value       = var.cluster_version
}

output "cluster_support_type" {
  description = "Configured EKS upgrade policy support type"
  value       = var.cluster_support_type
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.address
}

output "rds_port" {
  value = aws_db_instance.postgres.port
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${data.aws_region.current.name} --alias ${var.architecture}"
}

output "rds_identifier" {
  description = "RDS instance identifier"
  value       = aws_db_instance.postgres.identifier
}

data "aws_region" "current" {}
