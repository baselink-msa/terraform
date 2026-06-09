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

output "eks_cluster_name" {
  description = "Name of the dev EKS cluster."
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "Endpoint of the dev EKS cluster."
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_certificate_authority_data" {
  description = "Base64 encoded certificate authority data for the dev EKS cluster."
  value       = module.eks.cluster_certificate_authority_data
}

output "eks_cluster_security_group_id" {
  description = "Security group ID associated with the dev EKS cluster."
  value       = module.eks.cluster_security_group_id
}

output "eks_oidc_provider_arn" {
  description = "IAM OIDC provider ARN for the dev EKS cluster."
  value       = module.eks.oidc_provider_arn
}

output "eks_oidc_provider_url" {
  description = "IAM OIDC provider URL for the dev EKS cluster."
  value       = module.eks.oidc_provider_url
}

output "rds_endpoint" {
  description = "Endpoint of the dev RDS instance."
  value       = module.rds.db_instance_endpoint
}

output "rds_master_user_secret_arn" {
  description = "ARN of the RDS-managed master user secret."
  value       = module.rds.master_user_secret_arn
}

output "redis_primary_endpoint" {
  description = "Primary endpoint of the dev Redis replication group."
  value       = module.elasticache.primary_endpoint_address
}

output "ticket_confirm_queue_url" {
  description = "URL of the ticket confirmation SQS queue."
  value       = module.sqs_ticket_confirm.queue_url
}

output "ticket_confirm_dlq_url" {
  description = "URL of the ticket confirmation dead-letter queue."
  value       = module.sqs_ticket_confirm.dead_letter_queue_url
}

output "ticket_confirm_dlq_arn" {
  description = "ARN of the ticket confirmation dead-letter queue."
  value       = module.sqs_ticket_confirm.dead_letter_queue_arn
}

output "ticket_confirm_dlq_alarm_name" {
  description = "Name of the ticket confirmation DLQ CloudWatch alarm."
  value       = module.sqs_ticket_confirm.dead_letter_queue_alarm_name
}

output "ticket_confirm_dlq_alarm_arn" {
  description = "ARN of the ticket confirmation DLQ CloudWatch alarm."
  value       = module.sqs_ticket_confirm.dead_letter_queue_alarm_arn
}

output "ops_alerts_sns_topic_arn" {
  description = "SNS topic ARN used for team operations alerts."
  value       = var.enable_slack_alerts ? aws_sns_topic.ops_alerts[0].arn : null
}

output "ops_alerts_slack_configuration_arn" {
  description = "Amazon Q Developer Slack channel configuration ARN for operations alerts."
  value       = var.enable_slack_alerts ? aws_chatbot_slack_channel_configuration.ops_alerts[0].chat_configuration_arn : null
}

output "cloudfront_waf_web_acl_arn" {
  description = "CloudFront-scope WAF web ACL ARN for the Baselink dev distribution."
  value       = aws_wafv2_web_acl.cloudfront.arn
}

output "api_alb_waf_web_acl_arn" {
  description = "Regional WAF web ACL ARN for the API ALB."
  value       = aws_wafv2_web_acl.api_alb.arn
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID associated by infra-up.sh."
  value       = var.cloudfront_distribution_id
}

output "github_actions_terraform_role_arn" {
  description = "IAM role ARN used by GitHub Actions Terraform workflows."
  value       = aws_iam_role.github_actions_terraform.arn
}
