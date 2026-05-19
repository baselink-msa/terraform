output "vpc_id" {
  description = "ID of the dev VPC."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs for public ALB, NAT gateway, and optional bastion-style resources."
  value       = module.vpc.public_subnet_ids
}

output "private_app_subnet_ids" {
  description = "Private app subnet IDs for EKS worker nodes and backend pods."
  value       = module.vpc.private_app_subnet_ids
}

output "private_data_subnet_ids" {
  description = "Private data subnet IDs for RDS, Redis, and other data-layer services."
  value       = module.vpc.private_data_subnet_ids
}

output "public_route_table_id" {
  description = "ID of the public route table."
  value       = module.vpc.public_route_table_id
}

output "private_route_table_id" {
  description = "ID of the first private route table."
  value       = module.vpc.private_route_table_id
}

output "private_route_table_ids" {
  description = "IDs of private route tables."
  value       = module.vpc.private_route_table_ids
}

output "nat_gateway_id" {
  description = "ID of the first NAT gateway, or null when NAT gateway is disabled."
  value       = module.vpc.nat_gateway_id
}

output "internet_gateway_id" {
  description = "ID of the internet gateway."
  value       = module.vpc.internet_gateway_id
}
