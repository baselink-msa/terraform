variable "name_prefix" {
  description = "Prefix used for ticket event writer resources."
  type        = string
}

variable "source_queue_arn" {
  description = "ARN of the SQS queue containing ticket event envelopes."
  type        = string
}

variable "event_retention_days" {
  description = "Number of days to retain dev ticket event objects."
  type        = number
  default     = 14
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period for the writer Lambda."
  type        = number
  default     = 14
}

variable "batch_size" {
  description = "Maximum number of SQS records delivered to one Lambda invocation."
  type        = number
  default     = 10
}

variable "tags" {
  description = "Tags applied to ticket event writer resources."
  type        = map(string)
  default     = {}
}
