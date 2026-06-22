module "tokyo_vpc" {
  source = "../../../modules/vpc"

  providers = {
    aws = aws.tokyo
  }

  project_name              = "${var.project_name}-dr"
  environment               = var.environment
  vpc_cidr                  = var.dr_vpc_cidr
  availability_zones        = var.dr_availability_zones
  public_subnet_cidrs       = var.dr_public_subnet_cidrs
  private_app_subnet_cidrs  = var.dr_private_app_subnet_cidrs
  private_data_subnet_cidrs = var.dr_private_data_subnet_cidrs
  enable_nat_gateway        = var.dr_enable_nat_gateway
  single_nat_gateway        = var.dr_single_nat_gateway
  eks_cluster_name          = local.dr_cluster_name
}

resource "aws_security_group" "tokyo_app" {
  provider = aws.tokyo

  name        = "${local.name_prefix}-tokyo-app"
  description = "Reserved for temporary Pilot Light application validation resources."
  vpc_id      = module.tokyo_vpc.vpc_id

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-tokyo-app"
    Purpose = "pilot-light-application"
    Region  = var.dr_region
  })
}

resource "aws_vpc_security_group_egress_rule" "tokyo_app_all" {
  provider = aws.tokyo

  security_group_id = aws_security_group.tokyo_app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "tokyo_rds" {
  provider = aws.tokyo

  name        = "${local.name_prefix}-tokyo-rds"
  description = "PostgreSQL access from Tokyo Pilot Light application resources."
  vpc_id      = module.tokyo_vpc.vpc_id

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-tokyo-rds"
    Purpose = "pilot-light-database"
    Region  = var.dr_region
  })
}

resource "aws_vpc_security_group_ingress_rule" "tokyo_rds_postgres_from_app" {
  provider = aws.tokyo

  security_group_id            = aws_security_group.tokyo_rds.id
  referenced_security_group_id = aws_security_group.tokyo_app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from Tokyo Pilot Light application security group"
}

resource "aws_vpc_security_group_egress_rule" "tokyo_rds_all" {
  provider = aws.tokyo

  security_group_id = aws_security_group.tokyo_rds.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_db_subnet_group" "tokyo_rds" {
  provider = aws.tokyo

  name       = "${local.name_prefix}-tokyo-rds"
  subnet_ids = module.tokyo_vpc.private_data_subnet_ids

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-tokyo-rds"
    Purpose = "pilot-light-database"
    Region  = var.dr_region
  })
}
