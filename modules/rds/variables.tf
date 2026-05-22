variable "identifier" {
  description = "RDS 인스턴스 식별자 (예: baseball-db-dev)"
  type        = string
}

variable "engine_version" {
  type    = string
  default = "16.3" # Docker 환경(postgres:16)과 동일
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro" # 가성비 좋은 ARM 기반 인스턴스
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "db_name" {
  type    = string
  default = "baseball_platform"
}

variable "username" {
  type    = string
  default = "baseball"
}

variable "password" {
  description = "데이터베이스 마스터 비밀번호 (tfvars에서 주입해야 함)"
  type        = string
  sensitive   = true # 콘솔 화면에 비밀번호가 노출되지 않도록 마스킹 처리
}

variable "vpc_security_group_ids" {
  description = "적용할 보안 그룹 ID 리스트"
  type        = list(string)
  default     = []
}

variable "db_subnet_group_name" {
  description = "DB 서브넷 그룹 이름"
  type        = string
  default     = ""
}

variable "skip_final_snapshot" {
  type    = bool
  default = true # 개발 환경에서는 true 권장
}

variable "publicly_accessible" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}