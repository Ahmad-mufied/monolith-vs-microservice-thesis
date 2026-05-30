terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project}-budget"
  account_id  = data.aws_caller_identity.current.account_id
}

# ─── CloudWatch Log Group for Lambda ──────────────────────────────────────────

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name_prefix}-nuclear-shutdown"
  retention_in_days = 7
  tags              = var.tags
}

# ─── IAM Role for Lambda ──────────────────────────────────────────────────────

resource "aws_iam_role" "lambda" {
  name = "${local.name_prefix}-nuclear-shutdown-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "lambda" {
  name = "${local.name_prefix}-nuclear-shutdown-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EKSPermissions"
        Effect = "Allow"
        Action = [
          "eks:ListNodegroups",
          "eks:DescribeNodegroup",
          "eks:UpdateNodegroupConfig",
          "eks:DeleteNodegroup",
          "eks:DescribeCluster",
          "eks:DeleteCluster",
        ]
        Resource = flatten([
          for cluster in var.cluster_names : [
            "arn:aws:eks:${var.aws_region}:${local.account_id}:cluster/${cluster}",
            "arn:aws:eks:${var.aws_region}:${local.account_id}:nodegroup/${cluster}/*",
          ]
        ])
      },
      {
        Sid      = "RDSPermissions"
        Effect   = "Allow"
        Action   = ["rds:DescribeDBInstances", "rds:StopDBInstance"]
        Resource = "*"
      },
      {
        Sid    = "EC2NATGatewayPermissions"
        Effect = "Allow"
        Action = [
          "ec2:DescribeNatGateways",
          "ec2:DeleteNatGateway",
          "ec2:DescribeAddresses",
          "ec2:ReleaseAddress",
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
    ]
  })
}

# ─── Lambda Function ──────────────────────────────────────────────────────────

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/budget_nuclear_shutdown.py"
  output_path = "${path.module}/lambda/budget_nuclear_shutdown.zip"
}

resource "aws_lambda_function" "shutdown" {
  function_name    = "${local.name_prefix}-nuclear-shutdown"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  role             = aws_iam_role.lambda.arn
  handler          = "budget_nuclear_shutdown.lambda_handler"
  runtime          = "python3.12"
  timeout          = 900
  memory_size      = 256

  environment {
    variables = {
      EKS_CLUSTERS     = join(",", var.cluster_names)
      RDS_INSTANCE_IDS = join(",", var.rds_instance_ids)
      VPC_ID           = var.vpc_id
      DELETE_EKS       = var.delete_eks ? "true" : "false"
      AWS_REGION       = var.aws_region
    }
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy.lambda,
    aws_cloudwatch_log_group.lambda,
  ]
}

# ─── SNS Topic (nuclear trigger) ─────────────────────────────────────────────

resource "aws_sns_topic" "budget_nuclear" {
  name = "${local.name_prefix}-nuclear"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "nuclear_lambda" {
  topic_arn = aws_sns_topic.budget_nuclear.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.shutdown.arn
}

resource "aws_lambda_permission" "sns" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.shutdown.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.budget_nuclear.arn
}

# ─── AWS Budget ───────────────────────────────────────────────────────────────

resource "aws_budgets_budget" "cost" {
  name              = "${local.name_prefix}-auto-destroy-at-${var.budget_threshold_percent}pct"
  budget_type       = "COST"
  limit_amount      = tostring(var.budget_amount)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-01_00:00"

  # 50% — email warning
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  # 80% — email warning
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  # 95% — email critical warning
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 95
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  # 100% — SNS → Lambda (nuclear shutdown)
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = var.budget_threshold_percent
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_nuclear.arn]
  }
}
