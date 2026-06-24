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

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 gateway VPC endpoint."
  value       = module.vpc.s3_gateway_endpoint_id
}

output "interface_endpoint_ids" {
  description = "Interface VPC endpoint IDs keyed by service suffix."
  value       = module.vpc.interface_endpoint_ids
}

output "interface_endpoint_security_group_id" {
  description = "Security group ID attached to interface VPC endpoints."
  value       = module.vpc.interface_endpoint_security_group_id
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

output "app_database_secret_arn" {
  description = "ARN of the fixed application runtime database credential secret."
  value       = aws_secretsmanager_secret.app_database.arn
}

output "rds_backup_vault_name" {
  description = "AWS Backup vault name protecting the dev RDS instance."
  value       = module.backup.backup_vault_name
}

output "rds_backup_plan_id" {
  description = "AWS Backup plan ID protecting the dev RDS instance."
  value       = module.backup.backup_plan_id
}

output "rds_dr_backup_vault_name" {
  description = "AWS Backup vault name storing RDS copies in the Tokyo DR Region."
  value       = aws_backup_vault.tokyo.name
}

output "rds_dr_backup_vault_arn" {
  description = "AWS Backup vault ARN storing RDS copies in the Tokyo DR Region."
  value       = aws_backup_vault.tokyo.arn
}

output "rds_dr_backup_kms_key_arn" {
  description = "KMS key ARN encrypting RDS backup copies in the Tokyo DR Region."
  value       = aws_kms_key.tokyo_backup.arn
}

output "dr_vpc_id" {
  description = "VPC ID of the Tokyo Pilot Light network."
  value       = module.tokyo_vpc.vpc_id
}

output "dr_eks_cluster_name" {
  description = "Reserved EKS cluster name used by Tokyo subnet discovery tags and the future DR compute stack."
  value       = local.dr_cluster_name
}

output "dr_public_subnet_ids" {
  description = "Public subnet IDs reserved for temporary Tokyo validation resources."
  value       = module.tokyo_vpc.public_subnet_ids
}

output "dr_private_app_subnet_ids" {
  description = "Private application subnet IDs in the Tokyo Pilot Light network."
  value       = module.tokyo_vpc.private_app_subnet_ids
}

output "dr_private_data_subnet_ids" {
  description = "Private data subnet IDs used by restored Tokyo RDS instances."
  value       = module.tokyo_vpc.private_data_subnet_ids
}

output "dr_rds_subnet_group_name" {
  description = "DB subnet group used when restoring RDS in Tokyo."
  value       = aws_db_subnet_group.tokyo_rds.name
}

output "dr_app_security_group_id" {
  description = "Security group reserved for temporary Tokyo validation workloads."
  value       = aws_security_group.tokyo_app.id
}

output "dr_rds_security_group_id" {
  description = "Security group assigned to restored Tokyo RDS instances."
  value       = aws_security_group.tokyo_rds.id
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

output "ticket_domain_events_queue_url" {
  description = "URL of the ticket domain event queue."
  value       = module.sqs_ticket_domain_events.queue_url
}

output "ticket_domain_events_queue_arn" {
  description = "ARN of the ticket domain event queue."
  value       = module.sqs_ticket_domain_events.queue_arn
}

output "ticket_domain_events_dlq_url" {
  description = "URL of the ticket domain event dead-letter queue."
  value       = module.sqs_ticket_domain_events.dead_letter_queue_url
}

output "ticket_domain_events_dlq_arn" {
  description = "ARN of the ticket domain event dead-letter queue."
  value       = module.sqs_ticket_domain_events.dead_letter_queue_arn
}

output "ticket_event_bucket_name" {
  description = "S3 bucket containing partitioned ticket event JSON objects."
  value       = module.ticket_event_writer.bucket_name
}

output "ticket_event_writer_function_name" {
  description = "Name of the Lambda that writes ticket events to S3."
  value       = module.ticket_event_writer.lambda_function_name
}

output "ticket_event_glue_database_name" {
  description = "Glue Data Catalog database for ticket events."
  value       = module.ticket_event_writer.glue_database_name
}

output "ticket_event_athena_workgroup_name" {
  description = "Athena workgroup for ticket reliability analysis."
  value       = module.ticket_event_writer.athena_workgroup_name
}

output "ops_alerts_sns_topic_arn" {
  description = "SNS topic ARN used for team operations alerts."
  value       = var.enable_slack_alerts ? aws_sns_topic.ops_alerts[0].arn : null
}

output "edge_ops_alerts_sns_topic_arn" {
  description = "SNS topic ARN used for us-east-1 edge operations alerts."
  value       = var.enable_slack_alerts ? aws_sns_topic.edge_ops_alerts[0].arn : null
}

output "ops_alerts_slack_configuration_arn" {
  description = "Amazon Q Developer Slack channel configuration ARN for operations alerts."
  value       = var.enable_slack_alerts ? aws_chatbot_slack_channel_configuration.ops_alerts[0].chat_configuration_arn : null
}

output "backup_failure_event_rule_arns" {
  description = "EventBridge rule ARNs that notify the operations channel about failed AWS Backup jobs."
  value       = { for name, rule in aws_cloudwatch_event_rule.backup_failure : name => rule.arn }
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
  description = "CloudFront distribution ID managed by the dev cloudfront layer."
  value       = var.cloudfront_distribution_id
}

output "cloudfront_distribution_domain_name" {
  description = "CloudFront distribution domain name used by Lambda GAME_API_URL."
  value       = var.cloudfront_distribution_domain_name
}

output "github_actions_terraform_role_arn" {
  description = "IAM role ARN used by GitHub Actions Terraform workflows."
  value       = aws_iam_role.github_actions_terraform.arn
}

output "github_actions_runner_instance_id" {
  description = "EC2 instance ID for the dev GitHub Actions self-hosted runner."
  value       = aws_instance.github_actions_runner.id
}

output "github_actions_runner_private_ip" {
  description = "Private IP address of the dev GitHub Actions self-hosted runner."
  value       = aws_instance.github_actions_runner.private_ip
}

output "github_actions_runner_role_arn" {
  description = "IAM role ARN attached to the dev GitHub Actions self-hosted runner EC2 instance."
  value       = aws_iam_role.github_actions_runner.arn
}
