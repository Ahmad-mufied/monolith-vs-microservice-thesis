locals {
  writer_name = var.writer_name != "" ? var.writer_name : "${var.project}-external-k6-s3-writer"

  common_tags = {
    Project     = var.project
    Environment = "benchmark"
    ManagedBy   = "terraform"
    Scope       = "external-k6-s3-writer"
  }
}

resource "aws_iam_user" "external_k6_s3_writer" {
  name = local.writer_name
  path = "/benchmark/"

  tags = local.common_tags
}

resource "aws_iam_access_key" "external_k6_s3_writer" {
  user = aws_iam_user.external_k6_s3_writer.name
}

resource "aws_iam_user_policy" "external_k6_s3_writer" {
  name = "s3-results-prefix-access"
  user = aws_iam_user.external_k6_s3_writer.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBenchmarkExperimentPrefix"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.s3_results_bucket}"
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "experiments",
              "experiments/*",
            ]
          }
        }
      },
      {
        Sid    = "ReadWriteBenchmarkArtifacts"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = "arn:aws:s3:::${var.s3_results_bucket}/experiments/*"
      },
    ]
  })
}
