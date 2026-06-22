output "ecr_repository_urls" {
  description = "Map of backend service names to ECR repository URLs."
  value       = module.ecr.repository_urls
}

output "ecr_dr_repository_urls" {
  description = "Map of backend service names to ECR repository URLs in the Tokyo DR Region."
  value       = module.ecr_tokyo.repository_urls
}

output "ecr_replication_repository_prefix" {
  description = "Repository prefix selected by the cross-Region replication rule."
  value       = var.ecr_replication_enabled ? "${var.ecr_environment}-" : null
}
