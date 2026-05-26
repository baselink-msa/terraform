locals {
  name_prefix  = "${var.project_name}-${var.environment}"
  cluster_name = var.eks_cluster_name != "" ? var.eks_cluster_name : local.name_prefix

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

module "vpc" {
  source = "../../../modules/vpc"

  project_name              = var.project_name
  environment               = var.environment
  vpc_cidr                  = var.vpc_cidr
  availability_zones        = var.availability_zones
  public_subnet_cidrs       = var.public_subnet_cidrs
  private_app_subnet_cidrs  = var.private_app_subnet_cidrs
  private_data_subnet_cidrs = var.private_data_subnet_cidrs
  enable_nat_gateway        = var.enable_nat_gateway
  single_nat_gateway        = var.single_nat_gateway
  eks_cluster_name          = local.cluster_name
}

module "eks" {
  source = "../../../modules/eks"

  cluster_name = local.cluster_name
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_app_subnet_ids
  tags         = local.common_tags
}

resource "aws_db_subnet_group" "rds" {
  name       = "${local.name_prefix}-rds"
  subnet_ids = module.vpc.private_data_subnet_ids

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds"
  })
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds"
  description = "PostgreSQL access from EKS"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds"
  })
}

resource "aws_vpc_security_group_ingress_rule" "rds_postgres_from_eks" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = module.eks.cluster_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from EKS cluster security group"
}

resource "aws_vpc_security_group_egress_rule" "rds_all" {
  security_group_id = aws_security_group.rds.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

module "rds" {
  source = "../../../modules/rds"

  identifier             = "${local.name_prefix}-postgres"
  db_name                = "baseball_platform"
  username               = "baseball"
  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  publicly_accessible    = false
  skip_final_snapshot    = true
  tags                   = local.common_tags
}

module "elasticache" {
  source = "../../../modules/elasticache"

  name                       = local.name_prefix
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_data_subnet_ids
  allowed_security_group_ids = [module.eks.cluster_security_group_id]
  tags                       = local.common_tags
}

module "sqs_ticket_confirm" {
  source = "../../../modules/sqs"

  queue_name = "ticket-confirm-queue"
  tags       = local.common_tags
}

resource "aws_iam_role_policy" "eks_node_backend_runtime" {
  name = "${local.name_prefix}-backend-runtime"
  role = split("/", module.eks.node_role_arn)[1]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TicketConfirmQueueAccess"
        Effect = "Allow"
        Action = [
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = module.sqs_ticket_confirm.queue_arn
      },
      {
        Sid    = "ChatbotBedrockAccess"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock-agent-runtime:Retrieve",
          "bedrock-agent-runtime:RetrieveAndGenerate"
        ]
        Resource = "*"
      }
    ]
  })
}

locals {
  eks_oidc_issuer = replace(module.eks.oidc_provider_url, "https://", "")
}

data "aws_iam_policy_document" "backend_runtime_irsa_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_issuer}:sub"
      values   = ["system:serviceaccount:baselink-dev:backend-runtime"]
    }
  }
}

resource "aws_iam_role" "backend_runtime_irsa" {
  name               = "${local.name_prefix}-backend-runtime-irsa"
  assume_role_policy = data.aws_iam_policy_document.backend_runtime_irsa_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "backend_runtime_irsa" {
  name = "${local.name_prefix}-backend-runtime"
  role = aws_iam_role.backend_runtime_irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TicketConfirmQueueAccess"
        Effect = "Allow"
        Action = [
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = module.sqs_ticket_confirm.queue_arn
      },
      {
        Sid    = "ChatbotBedrockAccess"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock-agent-runtime:Retrieve",
          "bedrock-agent-runtime:RetrieveAndGenerate"
        ]
        Resource = "*"
      }
    ]
  })
}

output "backend_runtime_irsa_role_arn" {
  description = "IAM role ARN used by the backend-runtime Kubernetes service account."
  value       = aws_iam_role.backend_runtime_irsa.arn
}
