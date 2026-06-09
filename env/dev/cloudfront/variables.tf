variable "aws_region" {
  description = "AWS region where regional resources are created."
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI profile name to use for authentication. Optional if using environment variables or instance roles."
  type        = string
  default     = null
}

variable "project_name" {
  description = "Project name used for resource naming and tags."
  type        = string
  default     = "baselink"
}

variable "environment" {
  description = "Environment name used for resource naming and tags."
  type        = string
  default     = "dev"
}

variable "cloudfront_distribution_id" {
  description = "Existing CloudFront distribution ID imported into Terraform."
  type        = string
  default     = "E1L0BJIJOTT0R6"
}

variable "cloudfront_frontend_bucket_name" {
  description = "S3 bucket name used as the CloudFront static frontend origin."
  type        = string
  default     = "baselink-frontend-740831361032-ap-northeast-2"
}

variable "cloudfront_frontend_oac_id" {
  description = "Existing CloudFront Origin Access Control ID for the frontend S3 origin."
  type        = string
  default     = "E3SJ29MDW83EO9"
}

variable "cloudfront_frontend_oac_name" {
  description = "CloudFront Origin Access Control name for the frontend S3 origin."
  type        = string
  default     = "baselink-frontend-oac"
}

variable "cloudfront_api_origin_domain_name" {
  description = "API ALB origin domain used by CloudFront. post-apply-dev.sh keeps this value aligned with the current Kubernetes Ingress ALB DNS."
  type        = string
  default     = "k8s-baselinkdevapi-91612a5742-1864663002.ap-northeast-2.elb.amazonaws.com"
}

variable "cloudfront_origin_verify_header_name" {
  description = "Custom header name sent by CloudFront to the API ALB origin."
  type        = string
  default     = "X-Origin-Verify"
}

variable "cloudfront_origin_verify_header_value" {
  description = "Custom header value sent by CloudFront to the API ALB origin."
  type        = string
  sensitive   = true
}

variable "cloudfront_frontend_cache_policy_id" {
  description = "CloudFront cache policy ID used by the default frontend cache behavior."
  type        = string
  default     = "658327ea-f89d-4fab-a63d-7e88639e58f6"
}

variable "cloudfront_api_cache_policy_id" {
  description = "CloudFront cache policy ID used by the /api/* cache behavior."
  type        = string
  default     = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
}

variable "cloudfront_api_origin_request_policy_id" {
  description = "CloudFront origin request policy ID used by the /api/* cache behavior."
  type        = string
  default     = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
}
