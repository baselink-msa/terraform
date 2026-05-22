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
