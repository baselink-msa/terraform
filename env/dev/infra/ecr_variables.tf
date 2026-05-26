variable "ecr_environment" {
  description = "ECR 모듈용 배포 환경"
  type        = string
}

variable "ecr_repositories" {
  description = "ECR 모듈용 리포지토리 목록"
  type        = list(string)
}

variable "ecr_force_delete" {
  description = "dev ECR 리포지토리에 이미지가 남아 있어도 destroy 시 함께 삭제할지 여부"
  type        = bool
  default     = true
}
