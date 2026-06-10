output "external_k6_s3_access_key_id" {
  description = "Access key ID for external k6 S3 uploads."
  value       = aws_iam_access_key.external_k6_s3_writer.id
  sensitive   = true
}

output "external_k6_s3_secret_access_key" {
  description = "Secret access key for external k6 S3 uploads."
  value       = aws_iam_access_key.external_k6_s3_writer.secret
  sensitive   = true
}

output "vultr_k6_s3_access_key_id" {
  description = "Access key ID for Vultr k6 S3 uploads."
  value       = aws_iam_access_key.external_k6_s3_writer.id
  sensitive   = true
}

output "vultr_k6_s3_secret_access_key" {
  description = "Secret access key for Vultr k6 S3 uploads."
  value       = aws_iam_access_key.external_k6_s3_writer.secret
  sensitive   = true
}

output "writer_user_name" {
  description = "IAM user name for external k6 S3 uploads."
  value       = aws_iam_user.external_k6_s3_writer.name
}
