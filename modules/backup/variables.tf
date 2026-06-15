variable "name_prefix" {
  description = "Name prefix used for AWS Backup resources."
  type        = string
}

variable "vault_name" {
  description = "Optional AWS Backup vault name. Defaults to <name_prefix>-backup-vault."
  type        = string
  default     = null
}

variable "plan_name" {
  description = "Optional AWS Backup plan name. Defaults to <name_prefix>-backup-plan."
  type        = string
  default     = null
}

variable "selection_name" {
  description = "Optional AWS Backup selection name. Defaults to <name_prefix>-backup-selection."
  type        = string
  default     = null
}

variable "rule_name" {
  description = "Backup rule name."
  type        = string
  default     = "daily-snapshot"
}

variable "schedule" {
  description = "AWS Backup cron expression. The default runs daily at 04:00 KST."
  type        = string
  default     = "cron(0 19 ? * * *)"
}

variable "start_window_minutes" {
  description = "Number of minutes after the scheduled time that a backup job can start."
  type        = number
  default     = 60
}

variable "completion_window_minutes" {
  description = "Number of minutes after a backup job starts that it must complete."
  type        = number
  default     = 180
}

variable "delete_after_days" {
  description = "Number of days to retain recovery points."
  type        = number
  default     = 7

  validation {
    condition     = var.delete_after_days >= 1
    error_message = "delete_after_days must be at least 1."
  }
}

variable "resource_arns" {
  description = "Resource ARNs protected by this backup plan."
  type        = list(string)

  validation {
    condition     = length(var.resource_arns) > 0
    error_message = "resource_arns must contain at least one ARN."
  }
}

variable "kms_key_arn" {
  description = "Optional KMS key ARN for the backup vault."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to AWS Backup resources."
  type        = map(string)
  default     = {}
}
