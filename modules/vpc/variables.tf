variable "project_name" {
  description = "Project name used for resource naming."
  type        = string
}

variable "environment" {
  description = "Environment name used for resource naming."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "availability_zones" {
  description = "Availability zones where subnets will be created."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) > 0
    error_message = "availability_zones must contain at least one AZ."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets. The order must match availability_zones."
  type        = list(string)

  validation {
    condition     = alltrue([for cidr in var.public_subnet_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Every public subnet CIDR must be a valid CIDR block."
  }

  validation {
    condition     = length(var.public_subnet_cidrs) == length(var.availability_zones)
    error_message = "public_subnet_cidrs must have the same length as availability_zones."
  }
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for private application subnets. The order must match availability_zones."
  type        = list(string)

  validation {
    condition     = alltrue([for cidr in var.private_app_subnet_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Every private app subnet CIDR must be a valid CIDR block."
  }

  validation {
    condition     = length(var.private_app_subnet_cidrs) == length(var.availability_zones)
    error_message = "private_app_subnet_cidrs must have the same length as availability_zones."
  }
}

variable "private_data_subnet_cidrs" {
  description = "CIDR blocks for private data subnets. The order must match availability_zones."
  type        = list(string)

  validation {
    condition     = alltrue([for cidr in var.private_data_subnet_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Every private data subnet CIDR must be a valid CIDR block."
  }

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
  description = "Whether to create a single shared NAT gateway. If false, one NAT gateway is created per public subnet."
  type        = bool
  default     = true
}

variable "interface_endpoint_services" {
  description = "AWS regional service suffixes for interface VPC endpoints, for example ecr.api, ecr.dkr, and logs."
  type        = set(string)
  default     = []
}

variable "interface_endpoint_private_dns_enabled" {
  description = "Whether to enable private DNS names for interface VPC endpoints."
  type        = bool
  default     = true
}

variable "eks_cluster_name" {
  description = "Optional EKS cluster name used for Kubernetes subnet discovery tags."
  type        = string
  default     = ""
}
