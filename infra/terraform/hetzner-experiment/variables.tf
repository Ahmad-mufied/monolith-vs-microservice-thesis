variable "hcloud_token" {
  description = "Hetzner Cloud API token."
  type        = string
  sensitive   = true
}

variable "project" {
  description = "Project name prefix for Hetzner resources."
  type        = string
  default     = "skripsi"
}

variable "location" {
  description = "Hetzner Cloud location for benchmark servers."
  type        = string
  default     = "sin"
}

variable "monolith_cluster_name" {
  description = "Hetzner k3s cluster name for the monolith benchmark stack."
  type        = string
  default     = "skripsi-hetzner-monolith"
}

variable "msa_cluster_name" {
  description = "Hetzner k3s cluster name for the microservices benchmark stack."
  type        = string
  default     = "skripsi-hetzner-msa"
}

variable "control_plane_server_type" {
  description = "Control-plane server type."
  type        = string
  default     = "ccx13"
}

variable "app_server_type" {
  description = "App worker server type."
  type        = string
  default     = "ccx43"
}

variable "testing_server_type" {
  description = "k6 testing worker server type."
  type        = string
  default     = "ccx23"
}

variable "postgres_server_type" {
  description = "PostgreSQL server type."
  type        = string
  default     = "ccx33"
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
