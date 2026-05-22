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

variable "tags" {
  description = "리소스에 부여할 태그"
  type        = map(string)
  default     = {}
}