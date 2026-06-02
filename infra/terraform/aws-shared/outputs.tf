output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "k6_runner_role_arn" {
  value = aws_iam_role.k6_runner.arn
}

output "hetzner_k6_s3_access_key_id" {
  description = "Access key ID for Hetzner k6 S3 uploads."
  value       = aws_iam_access_key.hetzner_k6_s3_writer.id
  sensitive   = true
}

output "hetzner_k6_s3_secret_access_key" {
  description = "Secret access key for Hetzner k6 S3 uploads."
  value       = aws_iam_access_key.hetzner_k6_s3_writer.secret
  sensitive   = true
}

output "budget_name" {
  description = "AWS Budget name"
  value       = module.aws_budget.budget_name
}

output "budget_lambda_function_name" {
  description = "Lambda function name for nuclear shutdown"
  value       = module.aws_budget.lambda_function_name
}
