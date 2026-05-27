variable "environment" {
  description = "dev"
  type        = string
}

variable "repositories" {
  description = "생성할 ECR 리포지토리 이름 목록"
  type        = list(string)
}

variable "force_delete" {
  description = "리포지토리에 이미지가 남아 있어도 destroy 시 함께 삭제할지 여부"
  type        = bool
  default     = false
}
