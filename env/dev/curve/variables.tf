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

variable "lookahead_days" {
  type        = number
  default     = 14
  description = "writer Lambda 가 scaling_plan 을 미리 채울 경기 horizon (일 단위)"
}

variable "slack_webhook_url" {
  type        = string
  sensitive   = true
  description = "curve-scaler 주간 사전 리포트를 발송할 Slack Incoming Webhook URL"
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

variable "alert_email" {
  type        = string
  default     = ""
  description = "P6 워치독 알람 수신 이메일. 비어 있으면 SNS email 구독 생략 (topic 은 생성됨)."
}

variable "cost_per_pod_hour" {
  type        = number
  default     = 0.02
  description = "리포트 예상 비용 계산용 pod 시간당 단가(USD). 노드 경제성에 맞춰 조정."
}
