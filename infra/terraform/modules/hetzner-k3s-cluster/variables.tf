variable "cluster_name" {
  description = "Name prefix for the Hetzner k3s cluster resources."
  type        = string
}

variable "architecture" {
  description = "Architecture label for tags and metadata."
  type        = string

  validation {
    condition     = contains(["monolith", "msa", "benchmark"], var.architecture)
    error_message = "architecture must be monolith, msa, or benchmark."
  }
}

variable "location" {
  description = "Hetzner Cloud location for all cluster servers."
  type        = string
  default     = "sin"
}

variable "network_id" {
  description = "Hetzner Cloud private network ID."
  type        = number
}

variable "network_cidr" {
  description = "Hetzner Cloud private network CIDR allowed to reach cluster-internal services."
  type        = string
}

variable "network_zone" {
  description = "Hetzner Cloud network zone for private subnet attachments."
  type        = string
}

variable "ssh_key_ids" {
  description = "Hetzner Cloud SSH key IDs allowed on the provisioned servers."
  type        = list(number)
}

variable "control_plane_firewall_ids" {
  description = "Firewall IDs attached to control-plane servers."
  type        = list(number)
}

variable "app_firewall_ids" {
  description = "Firewall IDs attached to app worker servers."
  type        = list(number)
}

variable "testing_firewall_ids" {
  description = "Firewall IDs attached to testing worker servers."
  type        = list(number)
}

variable "postgres_firewall_ids" {
  description = "Firewall IDs attached to PostgreSQL servers."
  type        = list(number)
}

variable "control_plane_server_type" {
  description = "Hetzner Cloud server type for the k3s control plane."
  type        = string
  default     = "ccx13"
}

variable "app_server_type" {
  description = "Hetzner Cloud server type for app worker nodes."
  type        = string
  default     = "ccx43"
}

variable "testing_server_type" {
  description = "Hetzner Cloud server type for k6 testing nodes."
  type        = string
  default     = "ccx23"
}

variable "postgres_server_type" {
  description = "Hetzner Cloud server type for the PostgreSQL VM."
  type        = string
  default     = "ccx33"
}

variable "app_node_count" {
  description = "Number of app worker nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.app_node_count == 2
    error_message = "app_node_count must remain 2 for the thesis fair baseline."
  }
}

variable "testing_node_count" {
  description = "Number of k6 testing worker nodes."
  type        = number
  default     = 1

  validation {
    condition     = var.testing_node_count == 1
    error_message = "testing_node_count must remain 1 unless the methodology docs are updated."
  }
}

variable "image" {
  description = "Base image used for Hetzner servers."
  type        = string
  default     = "ubuntu-24.04"
}

variable "postgres_password" {
  description = "PostgreSQL postgres_admin password."
  type        = string
  sensitive   = true
}

variable "labels" {
  description = "Additional Hetzner resource labels."
  type        = map(string)
  default     = {}
}
