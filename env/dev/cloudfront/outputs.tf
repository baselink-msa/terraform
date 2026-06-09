output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID managed by the dev cloudfront layer."
  value       = module.cloudfront.distribution_id
}

output "cloudfront_distribution_domain_name" {
  description = "CloudFront distribution domain name used by Lambda GAME_API_URL."
  value       = module.cloudfront.distribution_domain_name
}

output "cloudfront_distribution_arn" {
  description = "CloudFront distribution ARN."
  value       = module.cloudfront.distribution_arn
}

output "frontend_bucket_name" {
  description = "Frontend S3 bucket name."
  value       = module.cloudfront.frontend_bucket_name
}
