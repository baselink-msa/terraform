###############################################################################
# environments/dev/addon/variables.tf
#
# TODO: 이 레이어 root에서 받을 변수를 정의하세요. (필요 시)
###############################################################################

variable "db_password" {
  description = "개발 환경 RDS 마스터 비밀번호"
  type        = string
  sensitive   = true
}