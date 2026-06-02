variable "aws_region" {
  description = "AWS region used by the Terraform AWS provider."
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project name prefix for AWS IAM resources."
  type        = string
  default     = "skripsi"
}

variable "s3_results_bucket" {
  description = "Existing S3 bucket that stores benchmark artifacts."
  type        = string

  validation {
    condition     = length(trimspace(var.s3_results_bucket)) > 0
    error_message = "s3_results_bucket must not be empty."
  }
}

variable "writer_name" {
  description = "Optional IAM user name override for external k6 S3 uploads."
  type        = string
  default     = ""
}
