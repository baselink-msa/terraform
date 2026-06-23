output "distribution_id" {
  description = "CloudFront distribution ID."
  value       = aws_cloudfront_distribution.frontend.id
}

output "distribution_domain_name" {
  description = "CloudFront distribution domain name."
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "aliases" {
  description = "Alternate domain names associated with the CloudFront distribution."
  value       = aws_cloudfront_distribution.frontend.aliases
}

output "distribution_arn" {
  description = "CloudFront distribution ARN."
  value       = aws_cloudfront_distribution.frontend.arn
}

output "frontend_bucket_name" {
  description = "Frontend S3 bucket name."
  value       = aws_s3_bucket.frontend.id
}

output "frontend_oac_id" {
  description = "CloudFront Origin Access Control ID."
  value       = aws_cloudfront_origin_access_control.frontend_s3.id
}
