variable "aws_region" {
  description = "AWS region where regional resources are created."
  type        = string
  default     = "ap-northeast-2"
}

variable "dr_region" {
  description = "AWS Region used for Pilot Light disaster recovery resources."
  type        = string
  default     = "ap-northeast-1"
}

variable "backup_copy_retention_days" {
  description = "Retention period for RDS recovery point copies in the DR Region."
  type        = number
  default     = 14

  validation {
    condition     = var.backup_copy_retention_days >= 1
    error_message = "backup_copy_retention_days must be at least 1."
  }
}

variable "dr_availability_zones" {
  description = "Availability zones used by the Tokyo Pilot Light network."
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]

  validation {
    condition     = length(var.dr_availability_zones) == 2
    error_message = "dr_availability_zones must contain exactly two availability zones."
  }
}

variable "dr_vpc_cidr" {
  description = "CIDR block for the Tokyo Pilot Light VPC."
  type        = string
  default     = "10.100.0.0/16"

  validation {
    condition     = can(cidrhost(var.dr_vpc_cidr, 0))
    error_message = "dr_vpc_cidr must be a valid CIDR block."
  }
}

variable "dr_public_subnet_cidrs" {
  description = "Public subnet CIDRs reserved for future Tokyo ingress resources."
  type        = list(string)
  default     = ["10.100.0.0/24", "10.100.10.0/24"]
}

variable "dr_private_app_subnet_cidrs" {
  description = "Private application subnet CIDRs reserved for future Tokyo compute resources."
  type        = list(string)
  default     = ["10.100.20.0/24", "10.100.30.0/24"]
}

variable "dr_private_data_subnet_cidrs" {
  description = "Private data subnet CIDRs used by restored Tokyo RDS instances."
  type        = list(string)
  default     = ["10.100.40.0/24", "10.100.50.0/24"]
}

variable "dr_enable_nat_gateway" {
  description = "Whether to activate a NAT gateway for Tokyo private subnets during a DR recovery. Keep false for Pilot Light standby and set true only while compute is active."
  type        = bool
  default     = false
}

variable "dr_single_nat_gateway" {
  description = "Whether Tokyo DR uses one shared NAT gateway. A single NAT limits recovery cost but is not AZ-redundant."
  type        = bool
  default     = true
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
  description = "Whether to create a single shared NAT gateway. Keep false for AZ-aligned private routing."
  type        = bool
  default     = false
}

variable "vpc_interface_endpoint_services" {
  description = "Interface VPC endpoint service suffixes enabled in private app subnets."
  type        = set(string)
  default     = ["ecr.api", "ecr.dkr", "monitoring", "sqs", "sts"]
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
  default     = 2000
}

variable "waf_blocked_requests_alarm_threshold" {
  description = "Number of WAF blocked requests in one evaluation period that triggers Slack alerting."
  type        = number
  default     = 0
}

variable "waf_counted_requests_alarm_threshold" {
  description = "Number of WAF counted requests in one evaluation period that triggers Slack alerting."
  type        = number
  default     = 0
}

variable "cloudfront_distribution_id" {
  description = "CloudFront distribution ID managed by the dev cloudfront layer."
  type        = string
  default     = "E1L0BJIJOTT0R6"
}

variable "cloudfront_distribution_domain_name" {
  description = "CloudFront viewer domain used by Lambda GAME_API_URL. post-apply-dev.sh refreshes this after the cloudfront layer apply, preferring the custom alias when configured."
  type        = string
  default     = "baselink.kro.kr"
}

variable "github_actions_runner_instance_type" {
  description = "EC2 instance type for the dev GitHub Actions self-hosted runner."
  type        = string
  default     = "t3.small"
}

# ── Change Auditor (개인 프로젝트) ──────────────────────────────────

variable "change_auditor_slack_webhook_url" {
  description = "Slack Incoming Webhook URL for the Change Auditor notifications."
  type        = string
  sensitive   = true
  default     = ""
}
