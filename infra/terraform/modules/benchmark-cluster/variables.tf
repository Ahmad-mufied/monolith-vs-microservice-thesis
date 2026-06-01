variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "architecture" {
  description = "Architecture label: monolith, msa, or benchmark"
  type        = string
  validation {
    condition     = contains(["monolith", "msa", "benchmark"], var.architecture)
    error_message = "architecture must be monolith, msa, or benchmark"
  }
}

variable "project" {
  description = "Project name prefix"
  type        = string
  default     = "skripsi"
}

variable "vpc_id" {
  description = "VPC ID from shared module"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs from shared module"
  type        = list(string)
}

variable "k6_runner_role_arn" {
  description = "IAM role ARN for k6 runner EKS Pod Identity"
  type        = string
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public EKS Kubernetes API endpoint"
  type        = list(string)

  validation {
    condition = (
      length(var.cluster_endpoint_public_access_cidrs) > 0 &&
      alltrue([
        for cidr in var.cluster_endpoint_public_access_cidrs :
        can(cidrhost(cidr, 0)) &&
        cidr != "0.0.0.0/0" &&
        cidr != "::/0" &&
        !startswith(cidr, "REPLACE_WITH_")
      ])
    )
    error_message = "cluster_endpoint_public_access_cidrs must contain one or more explicit CIDRs, must not use placeholders, and must not allow 0.0.0.0/0 or ::/0."
  }
}

variable "db_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class for the benchmark cluster database"
  type        = string
}
