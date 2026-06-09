variable "aws_region" {
  description = "AWS region where regional resources are created."
  type        = string
  default     = "ap-northeast-2"
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

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "availability_zones" {
  description = "Availability zones used by the dev VPC."
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]

  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "The dev environment currently expects exactly two availability zones."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets. The order must match availability_zones."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.10.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == length(var.availability_zones)
    error_message = "public_subnet_cidrs must have the same length as availability_zones."
  }
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for private app subnets. The order must match availability_zones."
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.30.0/24"]

  validation {
    condition     = length(var.private_app_subnet_cidrs) == length(var.availability_zones)
    error_message = "private_app_subnet_cidrs must have the same length as availability_zones."
  }
}

variable "private_data_subnet_cidrs" {
  description = "CIDR blocks for private data subnets. The order must match availability_zones."
  type        = list(string)
  default     = ["10.0.40.0/24", "10.0.50.0/24"]

  validation {
    condition     = length(var.private_data_subnet_cidrs) == length(var.availability_zones)
    error_message = "private_data_subnet_cidrs must have the same length as availability_zones."
  }
}

variable "enable_nat_gateway" {
  description = "Whether to create NAT gateway resources for private subnet outbound internet access."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Whether to create a single shared NAT gateway for dev cost control."
  type        = bool
  default     = true
}

variable "eks_cluster_name" {
  description = "Optional EKS cluster name used for Kubernetes subnet discovery tags."
  type        = string
  default     = ""
}


variable "eks" {
  description = "EKS 모듈에 전달할 설정 객체. 필드 구조는 modules/eks/variables.tf 참조."
  type        = any
}

variable "elasticache" {
  description = "ElastiCache(Redis) 모듈에 전달할 설정 객체. 필드 구조는 modules/elasticache/variables.tf 참조."
  type        = any
}

variable "aws_profile" {
  description = "AWS CLI profile name to use for authentication. Optional if using environment variables or instance roles."
  type        = string
  default     = null
}

variable "enable_slack_alerts" {
  description = "Whether to send CloudWatch alarm notifications to the team Slack channel through Amazon Q Developer."
  type        = bool
  default     = true
}

variable "slack_workspace_id" {
  description = "Slack workspace ID connected to Amazon Q Developer in chat applications."
  type        = string
  default     = "T0B2G4P9WBZ"
}

variable "slack_channel_id" {
  description = "Slack channel ID that receives AWS alarm notifications."
  type        = string
  default     = "C0B80N6DAJX"
}

variable "waf_log_retention_days" {
  description = "Retention period in days for AWS WAF CloudWatch log groups."
  type        = number
  default     = 14
}

variable "waf_rate_limit" {
  description = "Maximum requests per 5-minute window per source IP before WAF rate rules match."
  type        = number
  default     = 1000
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

variable "github_actions_runner_instance_type" {
  description = "EC2 instance type for the dev GitHub Actions self-hosted runner."
  type        = string
  default     = "t3.small"
}
