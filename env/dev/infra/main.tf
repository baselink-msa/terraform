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

  # ─── 배선 (다른 모듈 output) ───
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_app_subnet_ids

  # ─── 클러스터 이름은 local 사용 (VPC 서브넷 태그와 맞춰야 해서) ───
  cluster_name = local.cluster_name

  # ─── tfvars 의 eks = {...} 객체에서 꺼내쓰기 ───
  kubernetes_version         = var.eks.kubernetes_version
  system_node_instance_types = var.eks.system_node_instance_types
  system_node_capacity_type  = var.eks.system_node_capacity_type
  system_node_desired_size   = var.eks.system_node_desired_size
  system_node_min_size       = var.eks.system_node_min_size
  system_node_max_size       = var.eks.system_node_max_size
  endpoint_public_access     = var.eks.endpoint_public_access
  endpoint_private_access    = var.eks.endpoint_private_access
  public_access_cidrs        = var.eks.public_access_cidrs
  enable_secrets_encryption  = var.eks.enable_secrets_encryption

  # ─── 태그는 공통 + tfvars 머지 ───
  tags = merge(local.common_tags, var.eks.tags)
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

  # ─── 배선 ───
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_data_subnet_ids
  allowed_security_group_ids = [module.eks.cluster_security_group_id]

  # ─── tfvars 의 elasticache = {...} 객체에서 ───
  name                       = var.elasticache.name
  engine                     = var.elasticache.engine
  engine_version             = var.elasticache.engine_version
  parameter_group_family     = var.elasticache.parameter_group_family
  node_type                  = var.elasticache.node_type
  num_cache_clusters         = var.elasticache.num_cache_clusters
  automatic_failover_enabled = var.elasticache.automatic_failover_enabled
  multi_az_enabled           = var.elasticache.multi_az_enabled
  maxmemory_policy           = var.elasticache.maxmemory_policy
  at_rest_encryption_enabled = var.elasticache.at_rest_encryption_enabled
  transit_encryption_enabled = var.elasticache.transit_encryption_enabled
  snapshot_retention_limit   = var.elasticache.snapshot_retention_limit
  apply_immediately          = var.elasticache.apply_immediately

  # ─── 태그 ───
  tags = merge(local.common_tags, var.elasticache.tags)
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
          "bedrock:ApplyGuardrail",
          "bedrock-agent-runtime:InvokeAgent",
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
          "bedrock:ApplyGuardrail",
          "bedrock-agent-runtime:InvokeAgent",
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
