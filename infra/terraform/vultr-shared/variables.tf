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

