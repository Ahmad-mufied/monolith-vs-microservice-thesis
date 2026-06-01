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

variable "cluster_version" {
  description = "Kubernetes minor version for the EKS benchmark cluster"
  type        = string
  default     = "1.34"

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.cluster_version)) && !startswith(var.cluster_version, "REPLACE_WITH_")
    error_message = "cluster_version must be a Kubernetes minor version such as 1.34."
  }
}

variable "cluster_support_type" {
  description = "EKS upgrade policy support type. Use STANDARD to avoid Extended Support charges."
  type        = string
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "EXTENDED"], var.cluster_support_type)
    error_message = "cluster_support_type must be STANDARD or EXTENDED."
  }
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
