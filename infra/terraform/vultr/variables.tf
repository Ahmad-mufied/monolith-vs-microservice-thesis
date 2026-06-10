variable "project" {
  description = "Project name prefix for Vultr benchmark resources."
  type        = string
  default     = "skripsi"
}

variable "region" {
  description = "Vultr region for VKE, VPC, and PostgreSQL compute."
  type        = string
  default     = "sgp"
}

variable "execution_mode" {
  description = "Benchmark execution mode: sequential (1 cluster) or parallel (2 clusters)."
  type        = string
  default     = "sequential"

  validation {
    condition     = contains(["sequential", "parallel"], var.execution_mode)
    error_message = "execution_mode must be sequential or parallel."
  }
}

variable "vpc_subnet" {
  description = "Legacy Vultr VPC IPv4 subnet. VKE currently requires legacy VPC, not VPC 2.0."
  type        = string
  default     = "10.20.0.0"
}

variable "vpc_subnet_mask" {
  description = "Legacy Vultr VPC subnet mask length."
  type        = number
  default     = 16

  validation {
    condition     = var.vpc_subnet_mask >= 8 && var.vpc_subnet_mask <= 30
    error_message = "vpc_subnet_mask must be between 8 and 30."
  }
}

variable "operator_cidrs" {
  description = "Explicit operator CIDRs allowed to reach PostgreSQL node SSH."
  type        = list(string)

  validation {
    condition = (
      length(var.operator_cidrs) > 0 &&
      alltrue([
        for cidr in var.operator_cidrs :
        can(cidrhost(cidr, 0)) &&
        cidr != "0.0.0.0/0" &&
        cidr != "::/0" &&
        !startswith(cidr, "REPLACE_WITH_")
      ])
    )
    error_message = "operator_cidrs must contain explicit CIDRs and must not allow 0.0.0.0/0 or ::/0."
  }
}

variable "operator_ssh_public_key" {
  description = "Operator SSH public key used to access Vultr PostgreSQL nodes."
  type        = string

  validation {
    condition     = startswith(var.operator_ssh_public_key, "ssh-")
    error_message = "operator_ssh_public_key must be an SSH public key."
  }
}

variable "kubernetes_version" {
  description = "VKE Kubernetes version."
  type        = string
}

variable "cluster_names" {
  description = "Map of cluster key to VKE cluster name. Keys: sequential, or monolith+msa."
  type        = map(string)
  default     = {}
}

variable "app_node_plan" {
  description = "VKE app node pool plan."
  type        = string
  default     = "voc-c-8c-16gb-150s-amd"
}

variable "app_node_count" {
  description = "VKE app node pool node count."
  type        = number
  default     = 1

  validation {
    condition     = var.app_node_count >= 1 && floor(var.app_node_count) == var.app_node_count
    error_message = "app_node_count must be a positive whole number."
  }
}

variable "testing_node_plan" {
  description = "VKE testing node pool plan."
  type        = string
  default     = "vc2-2c-4gb"
}

variable "postgres_plan" {
  description = "Vultr PostgreSQL compute plan."
  type        = string
  default     = "voc-c-2c-4gb-50s-amd"
}

variable "postgres_os_id" {
  description = "Vultr OS ID for PostgreSQL compute."
  type        = number
  default     = 1743
}

variable "postgres_password" {
  description = "PostgreSQL postgres_admin password."
  type        = string
  sensitive   = true
}
