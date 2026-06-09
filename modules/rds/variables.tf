variable "identifier" {
  description = "RDS instance identifier."
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "16.14"
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GiB."
  type        = number
  default     = 20
}

variable "multi_az" {
  description = "Whether to enable a standby DB instance in another Availability Zone."
  type        = bool
  default     = false
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "baseball_platform"
}

variable "username" {
  description = "Master username."
  type        = string
  default     = "baseball"
}

variable "password" {
  description = "Master password. Ignored when manage_master_user_password is true."
  type        = string
  default     = null
  sensitive   = true
}

variable "manage_master_user_password" {
  description = "Whether AWS Secrets Manager manages the master password."
  type        = bool
  default     = true
}

variable "vpc_security_group_ids" {
  description = "Security group IDs attached to the RDS instance."
  type        = list(string)
}

variable "db_subnet_group_name" {
  description = "DB subnet group name."
  type        = string
}

variable "backup_retention_period" {
  description = "Number of days to retain automated backups. Set to 0 to disable automated backups and PITR."
  type        = number
  default     = 0

  validation {
    condition     = var.backup_retention_period >= 0 && var.backup_retention_period <= 35
    error_message = "backup_retention_period must be between 0 and 35 days."
  }
}

variable "backup_window" {
  description = "Daily UTC time range during which automated backups are created, for example 18:00-18:30."
  type        = string
  default     = null
}

variable "copy_tags_to_snapshot" {
  description = "Whether to copy DB instance tags to snapshots."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Whether to skip final snapshot on destroy."
  type        = bool
  default     = true
}

variable "publicly_accessible" {
  description = "Whether the DB instance is publicly accessible."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to resources."
  type        = map(string)
  default     = {}
}
