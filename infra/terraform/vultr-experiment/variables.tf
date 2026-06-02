variable "project" {
  description = "Project name prefix for Vultr resources."
  type        = string
  default     = "skripsi"
}

variable "region" {
  description = "Vultr region."
  type        = string
  default     = "sgp"
}

variable "kubernetes_version" {
  description = "VKE Kubernetes version."
  type        = string
}

variable "monolith_cluster_name" {
  description = "VKE cluster name for monolith benchmark."
  type        = string
  default     = "skripsi-vultr-monolith"
}

variable "msa_cluster_name" {
  description = "VKE cluster name for microservices benchmark."
  type        = string
  default     = "skripsi-vultr-msa"
}

variable "app_node_plan" {
  description = "VKE app node pool plan."
  type        = string
  default     = "voc-c-16c-32gb-300s"
}

variable "testing_node_plan" {
  description = "VKE testing node pool plan."
  type        = string
  default     = "vc2-4c-8gb"
}

variable "postgres_plan" {
  description = "Vultr PostgreSQL compute plan."
  type        = string
  default     = "vc2-4c-8gb"
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

