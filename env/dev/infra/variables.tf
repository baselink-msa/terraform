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
