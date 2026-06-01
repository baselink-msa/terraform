output "repository_urls" {
  description = "생성된 ECR 리포지토리의 URL 목록 (Map 형태)"
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}