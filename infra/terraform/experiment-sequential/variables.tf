variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project name prefix"
  type        = string
  default     = "skripsi"
}

variable "sequential_cluster_name" {
  description = "Single EKS cluster name for sequential benchmark execution"
  type        = string
  default     = "skripsi-benchmark"
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
  description = "RDS master password for the sequential benchmark database"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class for the sequential benchmark database"
  type        = string
  default     = "db.t3.micro"
}
