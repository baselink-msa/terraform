terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
  }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  az_indexes = range(length(var.availability_zones))

  public_subnets = {
    for index in local.az_indexes : tostring(index) => {
      az     = var.availability_zones[index]
      cidr   = var.public_subnet_cidrs[index]
      suffix = regex("[a-z]$", var.availability_zones[index])
    }
  }

  private_app_subnets = {
    for index in local.az_indexes : tostring(index) => {
      az     = var.availability_zones[index]
      cidr   = var.private_app_subnet_cidrs[index]
      suffix = regex("[a-z]$", var.availability_zones[index])
    }
  }

  private_data_subnets = {
    for index in local.az_indexes : tostring(index) => {
      az     = var.availability_zones[index]
      cidr   = var.private_data_subnet_cidrs[index]
      suffix = regex("[a-z]$", var.availability_zones[index])
    }
  }

  nat_indexes = var.enable_nat_gateway ? (var.single_nat_gateway ? ["0"] : keys(local.public_subnets)) : []

  eks_cluster_tag = var.eks_cluster_name == "" ? {} : {
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = merge(
    local.eks_cluster_tag,
    {
      Name                     = "${local.name_prefix}-public-${each.value.suffix}"
      Tier                     = "public"
      "kubernetes.io/role/elb" = "1"
    }
  )
}

resource "aws_subnet" "private_app" {
  for_each = local.private_app_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = merge(
    local.eks_cluster_tag,
    {
      Name                              = "${local.name_prefix}-private-app-${each.value.suffix}"
      Tier                              = "private-app"
      "kubernetes.io/role/internal-elb" = "1"
    }
  )
}

resource "aws_subnet" "private_data" {
  for_each = local.private_data_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = {
    Name = "${local.name_prefix}-private-data-${each.value.suffix}"
    Tier = "private-data"
  }
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_indexes)

  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip-${local.public_subnets[each.key].suffix}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.nat_indexes)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = {
    Name = "${local.name_prefix}-nat-${local.public_subnets[each.key].suffix}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  for_each = var.single_nat_gateway ? { "0" = local.public_subnets["0"] } : local.public_subnets

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-private-app-rt-${each.value.suffix}"
  }
}

resource "aws_route_table" "private_data" {
  for_each = var.single_nat_gateway ? { "0" = local.public_subnets["0"] } : local.public_subnets

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-private-data-rt-${each.value.suffix}"
  }
}

resource "aws_route" "private_app_default" {
  for_each = var.enable_nat_gateway ? aws_route_table.private : {}

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? "0" : each.key].id
}

resource "aws_route" "private_data_default" {
  for_each = var.enable_nat_gateway ? aws_route_table.private_data : {}

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? "0" : each.key].id
}

resource "aws_route_table_association" "private_app" {
  for_each = aws_subnet.private_app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[var.single_nat_gateway ? "0" : each.key].id
}

resource "aws_route_table_association" "private_data" {
  for_each = aws_subnet.private_data

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private_data[var.single_nat_gateway ? "0" : each.key].id
}

data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    [for key in sort(keys(aws_route_table.private)) : aws_route_table.private[key].id],
    [for key in sort(keys(aws_route_table.private_data)) : aws_route_table.private_data[key].id]
  )

  tags = {
    Name = "${local.name_prefix}-s3-gw"
  }
}

resource "aws_security_group" "interface_endpoints" {
  count = length(var.interface_endpoint_services) > 0 ? 1 : 0

  name        = "${local.name_prefix}-interface-endpoints"
  description = "HTTPS access to private interface VPC endpoints"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-interface-endpoints"
  }
}

resource "aws_vpc_security_group_ingress_rule" "interface_endpoints_https_from_vpc" {
  count = length(var.interface_endpoint_services) > 0 ? 1 : 0

  security_group_id = aws_security_group.interface_endpoints[0].id
  cidr_ipv4         = aws_vpc.this.cidr_block
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS from VPC resources"
}

resource "aws_vpc_security_group_egress_rule" "interface_endpoints_all" {
  count = length(var.interface_endpoint_services) > 0 ? 1 : 0

  security_group_id = aws_security_group.interface_endpoints[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow endpoint return traffic"
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.interface_endpoint_services

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for key in sort(keys(aws_subnet.private_app)) : aws_subnet.private_app[key].id]
  security_group_ids  = [aws_security_group.interface_endpoints[0].id]
  private_dns_enabled = var.interface_endpoint_private_dns_enabled

  tags = {
    Name = "${local.name_prefix}-${replace(each.key, ".", "-")}-vpce"
  }
}
