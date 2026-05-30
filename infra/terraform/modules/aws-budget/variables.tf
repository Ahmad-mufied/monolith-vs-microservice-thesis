variable "project" {
  description = "Project name prefix"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "budget_amount" {
  description = "Monthly budget in USD"
  type        = number
}

variable "budget_threshold_percent" {
  description = "Budget threshold percentage to trigger nuclear shutdown"
  type        = number
  default     = 100
}

variable "budget_alert_emails" {
  description = "Email addresses for budget alerts (50%, 80%, 95%)"
  type        = list(string)
}

variable "cluster_names" {
  description = "EKS cluster names to destroy on nuclear shutdown"
  type        = list(string)
}

variable "rds_instance_ids" {
  description = "RDS instance identifiers to stop on nuclear shutdown"
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID for NAT Gateway discovery"
  type        = string
}

variable "delete_eks" {
  description = "Whether to delete EKS clusters on nuclear shutdown"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
