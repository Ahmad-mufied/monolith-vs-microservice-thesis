variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project" {
  type    = string
  default = "skripsi"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Operator public CIDR allowlist for the public EKS Kubernetes API endpoint"
  type        = list(string)
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
