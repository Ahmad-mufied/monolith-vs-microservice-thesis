output "budget_name" {
  description = "AWS Budget name"
  value       = aws_budgets_budget.cost.name
}

output "lambda_function_name" {
  description = "Lambda function name for nuclear shutdown"
  value       = aws_lambda_function.shutdown.function_name
}

output "sns_topic_arn" {
  description = "SNS topic ARN for nuclear shutdown"
  value       = aws_sns_topic.budget_nuclear.arn
}
