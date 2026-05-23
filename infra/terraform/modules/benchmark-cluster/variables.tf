variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "architecture" {
  description = "Architecture label: monolith or msa"
  type        = string
  validation {
    condition     = contains(["monolith", "msa"], var.architecture)
    error_message = "architecture must be monolith or msa"
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

variable "db_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class for the benchmark cluster database"
  type        = string
}
