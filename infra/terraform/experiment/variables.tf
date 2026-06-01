variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project" {
  description = "Project name prefix"
  type        = string
  default     = "skripsi"
}

variable "cluster_version" {
  description = "Kubernetes minor version for both EKS benchmark clusters"
  type        = string
  default     = "1.34"

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.cluster_version)) && !startswith(var.cluster_version, "REPLACE_WITH_")
    error_message = "cluster_version must be a Kubernetes minor version such as 1.34."
  }
}

variable "cluster_support_type" {
  description = "EKS upgrade policy support type for both benchmark clusters"
  type        = string
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "EXTENDED"], var.cluster_support_type)
    error_message = "cluster_support_type must be STANDARD or EXTENDED."
  }
}

variable "monolith_cluster_name" {
  description = "EKS cluster name for the monolith benchmark stack"
  type        = string
  default     = "skripsi-monolith"
}

variable "msa_cluster_name" {
  description = "EKS cluster name for the microservices benchmark stack"
  type        = string
  default     = "skripsi-msa"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Operator public CIDR allowlist for the public EKS Kubernetes API endpoint"
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
  description = "RDS master password for both clusters"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class for both benchmark cluster databases"
  type        = string
  default     = "db.t3.micro"
}
