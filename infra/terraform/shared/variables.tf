variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project name prefix for all resources"
  type        = string
  default     = "skripsi"
}

variable "s3_results_bucket" {
  description = "Name of the manually created S3 bucket for benchmark results"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones"
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

# ─── Budget Nuclear Shutdown ──────────────────────────────────────────────────

variable "budget_amount" {
  description = "Monthly budget in USD for AWS nuclear shutdown protection"
  type        = number
  default     = 30
}

variable "budget_threshold_percent" {
  description = "Budget threshold percentage to trigger nuclear shutdown (100 = default)"
  type        = number
  default     = 100
}

variable "budget_alert_emails" {
  description = "Email addresses for budget warning alerts (50%, 80%, 95%)"
  type        = list(string)
  default     = []
}
