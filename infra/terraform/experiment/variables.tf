variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project" {
  type    = string
  default = "skripsi"
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
