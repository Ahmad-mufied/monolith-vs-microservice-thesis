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

variable "sequential_cluster_name" {
  description = "Single Hetzner k3s cluster name for sequential benchmark execution."
  type        = string
  default     = "skripsi-hetzner-benchmark"
}

variable "control_plane_server_type" {
  description = "Control-plane server type. Defaults to CCX13 for the single k3s server baseline; changing it directly changes control-plane cost and headroom."
  type        = string
  default     = "ccx13"
}

variable "app_server_type" {
  description = "App worker server type. Defaults to CCX43 for the thesis fair baseline; changing it directly changes application capacity and the largest share of cluster cost."
  type        = string
  default     = "ccx43"
}

variable "testing_server_type" {
  description = "k6 testing worker server type. Defaults to CCX23 for the dedicated benchmark runner node; changing it directly changes k6-side capacity and cost."
  type        = string
  default     = "ccx23"
}

variable "postgres_server_type" {
  description = "PostgreSQL server type. Defaults to CCX33 for the dedicated PostgreSQL VM baseline; changing it directly changes database capacity and cost."
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
