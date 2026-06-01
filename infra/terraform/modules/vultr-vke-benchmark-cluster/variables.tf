variable "cluster_name" {
  description = "VKE cluster name."
  type        = string
}

variable "architecture" {
  description = "Benchmark architecture label."
  type        = string
}

variable "region" {
  description = "Vultr region."
  type        = string
}

variable "kubernetes_version" {
  description = "VKE Kubernetes version."
  type        = string
}

variable "vpc_id" {
  description = "Legacy Vultr VPC ID."
  type        = string
}

variable "vpc_cidr" {
  description = "Legacy Vultr VPC CIDR."
  type        = string
}

variable "ssh_key_ids" {
  description = "SSH key IDs for PostgreSQL VM."
  type        = list(string)
}

variable "postgres_firewall_group_id" {
  description = "Firewall group ID for PostgreSQL VM."
  type        = string
}

variable "app_node_plan" {
  description = "VKE app node pool plan."
  type        = string
}

variable "app_node_count" {
  description = "VKE app node pool node count."
  type        = number
  default     = 2
}

variable "testing_node_plan" {
  description = "VKE testing node pool plan."
  type        = string
}

variable "testing_node_count" {
  description = "VKE testing node pool node count."
  type        = number
  default     = 1
}

variable "postgres_plan" {
  description = "Vultr PostgreSQL compute plan."
  type        = string
}

variable "postgres_os_id" {
  description = "Vultr OS ID for PostgreSQL compute."
  type        = number
}

variable "postgres_password" {
  description = "PostgreSQL postgres_admin password."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.postgres_password) >= 16 && var.postgres_password == trimspace(var.postgres_password)
    error_message = "postgres_password must be at least 16 characters and must not contain leading or trailing whitespace."
  }
}

variable "labels" {
  description = "Common resource labels."
  type        = map(string)
  default     = {}
}

