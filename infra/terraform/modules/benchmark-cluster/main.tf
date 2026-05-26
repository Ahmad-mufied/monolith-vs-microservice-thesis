terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  common_tags = {
    Project      = var.project
    Environment  = "benchmark"
    Architecture = var.architecture
    ManagedBy    = "terraform"
  }
}

# ─── EKS Cluster ─────────────────────────────────────────────────────────────

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.31"

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  cluster_endpoint_public_access       = true
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # Enable EKS Pod Identity
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    eks-pod-identity-agent = {}
  }

  eks_managed_node_groups = {
    app_nodes = {
      name           = "app-nodes"
      instance_types = ["c8i.2xlarge"]
      min_size       = 2
      max_size       = 2
      desired_size   = 2

      labels = {
        "node-group" = "app"
      }
    }

    testing_nodes = {
      name           = "testing-nodes"
      instance_types = ["t3.large"]
      min_size       = 1
      max_size       = 1
      desired_size   = 1

      labels = {
        "node-group" = "testing"
      }

      taints = [{
        key    = "workload"
        value  = "benchmark"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  tags = local.common_tags
}

# ─── EKS Pod Identity for k6 runner ──────────────────────────────────────────

resource "aws_eks_pod_identity_association" "k6_runner" {
  cluster_name    = module.eks.cluster_name
  namespace       = "benchmark"
  service_account = "k6-runner"
  role_arn        = var.k6_runner_role_arn
}

# ─── RDS Security Group ───────────────────────────────────────────────────────

resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-rds"
  description = "Allow PostgreSQL from EKS nodes"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

# ─── RDS Subnet Group ─────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name       = "${var.cluster_name}-rds"
  subnet_ids = var.private_subnet_ids
  tags       = local.common_tags
}

# ─── RDS Instance ─────────────────────────────────────────────────────────────

resource "aws_db_instance" "postgres" {
  identifier = "${var.cluster_name}-postgres"

  engine         = "postgres"
  engine_version = "18"
  instance_class = var.db_instance_class

  db_name  = "bootstrap"
  username = "postgres_admin"
  password = var.db_password

  allocated_storage     = 20
  max_allocated_storage = 50
  storage_type          = "gp3"

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible     = false
  multi_az                = false
  deletion_protection     = false
  skip_final_snapshot     = true
  backup_retention_period = 0

  tags = local.common_tags
}
