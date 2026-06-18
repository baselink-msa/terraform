variable "project_name" {
  description = "Project name prefix for resource naming."
  type        = string
  default     = "change-auditor"
}

variable "environment" {
  description = "Environment name (dev, prod)."
  type        = string
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "ap-northeast-2"
}

variable "vpc_id" {
  description = "VPC ID for Lambda (needed for Config API access)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for Lambda VPC config."
  type        = list(string)
}

variable "slack_webhook_url" {
  description = "Slack Incoming Webhook URL for change notifications."
  type        = string
  sensitive   = true
}

variable "bedrock_model_id" {
  description = "Bedrock model ID for AI analysis."
  type        = string
  default     = "anthropic.claude-3-haiku-20240307-v1:0"
}

variable "bedrock_region" {
  description = "Bedrock service region."
  type        = string
  default     = "us-east-1"
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days."
  type        = number
  default     = 14
}

variable "dynamodb_billing_mode" {
  description = "DynamoDB billing mode (PAY_PER_REQUEST or PROVISIONED)."
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "tags" {
  description = "Additional tags for all resources."
  type        = map(string)
  default     = {}
}
