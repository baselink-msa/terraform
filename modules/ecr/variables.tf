variable "environment" {
  description = "dev"
  type        = string
}

variable "repositories" {
  description = "생성할 ECR 리포지토리 이름 목록"
  type        = list(string)
}