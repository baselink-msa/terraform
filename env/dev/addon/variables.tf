###############################################################################
# environments/dev/addon/variables.tf
#
###############################################################################

variable "aws_region" {
  description = "AWS region where the dev EKS cluster exists."
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI profile name to use for authentication. Optional if using environment variables or instance roles."
  type        = string
  default     = null
}

variable "project_name" {
  description = "Project name used for resource tagging."
  type        = string
  default     = "baselink"
}

variable "environment" {
  description = "Environment name used for resource tagging."
  type        = string
  default     = "dev"
}

variable "keda_predictive_paused" {
  description = <<-EOT
    true 면 KEDA predictive ScaledObject 5개 정지 (dev 비용 보호).
    영향: 5개 ScaledObject 의 cpu + postgresql 트리거 모두 정지.
    기본 false (정상 동작).
  EOT
  type        = bool
  default     = false
}

