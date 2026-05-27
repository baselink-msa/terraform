variable "aws_region" {
  description = "AWS region where ECR repositories are created."
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI profile name to use for authentication."
  type        = string
  default     = "sds"
}

variable "ecr_environment" {
  description = "ECR repository environment prefix."
  type        = string
}

variable "ecr_repositories" {
  description = "ECR repository names without the environment prefix."
  type        = list(string)
}

variable "ecr_force_delete" {
  description = "Whether ECR repositories can be deleted with images during destroy."
  type        = bool
  default     = false
}
