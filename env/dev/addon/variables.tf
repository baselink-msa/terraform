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
  default     = "sds"
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
