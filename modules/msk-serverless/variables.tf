variable "enabled" {
  description = "Whether to create the MSK Serverless event streaming backbone."
  type        = bool
  default     = false
}

variable "cluster_name" {
  description = "MSK Serverless cluster name."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs where MSK Serverless creates VPC connectivity."
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID where the MSK Serverless security group is created."
  type        = string
}

variable "client_security_group_ids" {
  description = "Security groups allowed to connect to MSK Serverless with IAM authentication."
  type        = list(string)
}

variable "tags" {
  description = "Tags applied to MSK Serverless resources."
  type        = map(string)
  default     = {}
}
