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

variable "network_cidr" {
  description = "Private network CIDR for Hetzner benchmark resources."
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_cidr" {
  description = "Private subnet CIDR attached to Hetzner Cloud servers."
  type        = string
  default     = "10.10.1.0/24"
}

variable "network_zone" {
  description = "Hetzner Cloud network zone."
  type        = string
  default     = "ap-southeast"
}

variable "operator_cidrs" {
  description = "Explicit operator CIDRs allowed to reach SSH and Kubernetes API."
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
  description = "Operator SSH public key used to access Hetzner servers."
  type        = string

  validation {
    condition     = startswith(var.operator_ssh_public_key, "ssh-")
    error_message = "operator_ssh_public_key must be an SSH public key."
  }
}
