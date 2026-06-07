variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "aws_profile" {
  type    = string
  default = "agh"
}

variable "curve_db_name" {
  type        = string
  default     = "curve"
  description = "curve DB의 초기 데이터베이스 이름"
}

variable "curve_db_user" {
  type        = string
  default     = "curve_admin"
  description = "curve DB master 사용자명"
}

variable "ceiling_rps" {
  type        = number
  default     = 160
  description = "CloudWatch 에 발행할 predicted_rps 최대 clamp 값"
}

variable "curve_db_subnet_group_name" {
  type        = string
  description = "agh-curve-db 가 이미 속한 DB 서브넷 그룹 이름 (기적용 리소스, Terraform 외부에서 관리)"
}

variable "enable_pod_identity_agent_addon" {
  type        = bool
  default     = true
  description = "EKS Pod Identity Agent addon 활성화 여부 (false = 이미 설치된 경우 건너뜀)"
}
