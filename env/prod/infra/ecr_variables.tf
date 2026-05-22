variable "ecr_environment" {
  description = "ECR 모듈용 배포 환경"
  type        = string
}

variable "ecr_repositories" {
  description = "ECR 모듈용 리포지토리 목록"
  type        = list(string)
}