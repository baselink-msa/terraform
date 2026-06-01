output "ecr_repository_urls" {
  description = "Map of backend service names to ECR repository URLs."
  value       = module.ecr.repository_urls
}
