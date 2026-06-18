variable "aws_region" {
  description = "AWS region used by the S3 origin domain name."
  type        = string
}

variable "distribution_comment" {
  description = "CloudFront distribution comment."
  type        = string
}

variable "frontend_bucket_name" {
  description = "S3 bucket name used as the static frontend origin."
  type        = string
}

variable "frontend_oac_name" {
  description = "CloudFront Origin Access Control name for the frontend S3 origin."
  type        = string
}

variable "frontend_oac_description" {
  description = "CloudFront Origin Access Control description."
  type        = string
  default     = ""
}

variable "frontend_origin_id" {
  description = "CloudFront origin ID for the frontend S3 origin."
  type        = string
  default     = "baselink-frontend-s3-origin"
}

variable "api_origin_id" {
  description = "CloudFront origin ID for the API ALB origin."
  type        = string
  default     = "baselink-dev-api-alb"
}

variable "api_origin_domain_name" {
  description = "API ALB origin domain name."
  type        = string
}

variable "origin_verify_header_name" {
  description = "Custom header name sent by CloudFront to the API ALB origin."
  type        = string
}

variable "origin_verify_header_value" {
  description = "Custom header value sent by CloudFront to the API ALB origin."
  type        = string
  sensitive   = true
}

variable "frontend_cache_policy_id" {
  description = "CloudFront cache policy ID used by the default frontend cache behavior."
  type        = string
}

variable "api_cache_policy_id" {
  description = "CloudFront cache policy ID used by the /api/* cache behavior."
  type        = string
}

variable "api_origin_request_policy_id" {
  description = "CloudFront origin request policy ID used by the /api/* cache behavior."
  type        = string
}

variable "grafana_origin_request_policy_id" {
  description = "CloudFront origin request policy ID used by the /grafana/* cache behavior."
  type        = string
  default     = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AllViewer
}

variable "web_acl_arn" {
  description = "CloudFront-scope WAF web ACL ARN."
  type        = string
}

variable "tags" {
  description = "Tags applied to supported CloudFront and S3 resources."
  type        = map(string)
  default     = {}
}
