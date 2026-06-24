output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "IDs of public subnets, ordered by availability_zones."
  value       = [for key in sort(keys(aws_subnet.public)) : aws_subnet.public[key].id]
}

output "private_app_subnet_ids" {
  description = "IDs of private application subnets, ordered by availability_zones."
  value       = [for key in sort(keys(aws_subnet.private_app)) : aws_subnet.private_app[key].id]
}

output "private_data_subnet_ids" {
  description = "IDs of private data subnets, ordered by availability_zones."
  value       = [for key in sort(keys(aws_subnet.private_data)) : aws_subnet.private_data[key].id]
}

output "public_route_table_id" {
  description = "ID of the public route table."
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "ID of the first private route table."
  value       = values(aws_route_table.private)[0].id
}

output "private_route_table_ids" {
  description = "IDs of private route tables."
  value       = [for key in sort(keys(aws_route_table.private)) : aws_route_table.private[key].id]
}

output "nat_gateway_id" {
  description = "ID of the first NAT gateway, or null when NAT gateway is disabled."
  value       = try(values(aws_nat_gateway.this)[0].id, null)
}

output "nat_gateway_ids" {
  description = "IDs of NAT gateways."
  value       = [for key in sort(keys(aws_nat_gateway.this)) : aws_nat_gateway.this[key].id]
}

output "internet_gateway_id" {
  description = "ID of the internet gateway."
  value       = aws_internet_gateway.this.id
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 gateway VPC endpoint."
  value       = aws_vpc_endpoint.s3.id
}

output "interface_endpoint_ids" {
  description = "IDs of interface VPC endpoints keyed by service suffix."
  value       = { for service, endpoint in aws_vpc_endpoint.interface : service => endpoint.id }
}

output "interface_endpoint_security_group_id" {
  description = "Security group ID attached to interface VPC endpoints, or null when no interface endpoint is enabled."
  value       = try(aws_security_group.interface_endpoints[0].id, null)
}
