variable "queue_name" {
  description = "생성할 SQS 큐의 이름입니다."
  type        = string
  default     = "ticket-confirm-queue" # 백엔드 코드와 맞춘 기본값
}

variable "delay_seconds" {
  type    = number
  default = 0
}

variable "max_message_size" {
  description = "최대 메시지 크기 (기본 256KB)"
  type        = number
  default     = 262144
}

variable "message_retention_seconds" {
  description = "메시지 보관 기간 (기본 1일 = 86400초)"
  type        = number
  default     = 86400
}

variable "receive_wait_time_seconds" {
  type    = number
  default = 0
}

variable "create_dead_letter_queue" {
  description = "Whether to create and connect a dead-letter queue."
  type        = bool
  default     = false
}

variable "dead_letter_queue_name" {
  description = "Optional dead-letter queue name. Defaults to <queue_name>-dlq."
  type        = string
  default     = null
}

variable "dead_letter_queue_message_retention_seconds" {
  description = "How long failed messages remain in the dead-letter queue. Defaults to 14 days."
  type        = number
  default     = 1209600
}

variable "max_receive_count" {
  description = "Number of failed receives before a message moves to the dead-letter queue."
  type        = number
  default     = 5

  validation {
    condition     = var.max_receive_count >= 1
    error_message = "max_receive_count must be at least 1."
  }
}

variable "tags" {
  description = "리소스에 부여할 태그"
  type        = map(string)
  default     = {}
}
