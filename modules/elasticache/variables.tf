###############################################################################
# modules/elasticache/variables.tf
###############################################################################

#--- 기본 식별자 -------------------------------------------------------------
variable "name" {
  description = "리소스 이름 접두어 (예: baselink-dev)"
  type        = string
}

#--- 네트워크 (VPC 모듈에서 입력으로 전달받음) -------------------------------
variable "vpc_id" {
  description = "Redis 보안 그룹을 둘 VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "Redis 노드를 둘 서브넷 ID 목록 (프라이빗 서브넷)"
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Redis 6379 접근을 허용할 보안 그룹 목록 (EKS 노드 SG 등)"
  type        = list(string)
}

#--- 엔진 (Valkey 전환 시 이 3개만 교체) -------------------------------------
variable "engine" {
  description = "캐시 엔진 (redis 또는 valkey)"
  type        = string
  default     = "redis"
}

variable "engine_version" {
  description = "엔진 버전 (Redis OSS 예: 7.1 / Valkey 예: 8.1)"
  type        = string
  default     = "7.1"
}

variable "parameter_group_family" {
  description = "파라미터 그룹 family (Redis 7.x: redis7 / Valkey 8.x: valkey8)"
  type        = string
  default     = "redis7"
}

#--- 노드 구성 ---------------------------------------------------------------
variable "node_type" {
  description = "캐시 노드 타입 (Graviton t4g 권장)"
  type        = string
  default     = "cache.t4g.small"
}

variable "num_cache_clusters" {
  description = "전체 노드 수 = primary 1 + replica N (HA 구성 시 2 이상)"
  type        = number
  default     = 2
}

variable "automatic_failover_enabled" {
  description = "primary 장애 시 replica 자동 승격 (num_cache_clusters >= 2 필요)"
  type        = bool
  default     = true
  validation {
    condition     = var.automatic_failover_enabled == false || var.num_cache_clusters >= 2
    error_message = "automatic_failover_enabled = true 이려면 num_cache_clusters가 2 이상이어야 합니다."
  }
}

variable "multi_az_enabled" {
  description = "primary와 replica를 서로 다른 AZ에 배치 (automatic_failover 필요)"
  type        = bool
  default     = true
  validation {
    condition     = var.multi_az_enabled == false || var.automatic_failover_enabled == true
    error_message = "multi_az_enabled = true 이려면 automatic_failover_enabled = true 여야 합니다."
  }
}

variable "port" {
  description = "Redis 포트"
  type        = number
  default     = 6379
}

variable "maxmemory_policy" {
  description = "메모리 가득 찼을 때의 정책 (락 데이터 보호 필요 시 noeviction 고려)"
  type        = string
  default     = "volatile-lru"
}

#--- 암호화 ------------------------------------------------------------------
variable "at_rest_encryption_enabled" {
  description = "저장 데이터 암호화"
  type        = bool
  default     = true
}

variable "transit_encryption_enabled" {
  description = "전송 중 암호화(TLS). true면 클라이언트도 TLS 접속 필요"
  type        = bool
  default     = true
}

variable "auth_token" {
  description = "Redis AUTH 토큰 (선택). 설정 시 transit_encryption_enabled = true 필수"
  type        = string
  default     = null
  sensitive   = true
}

#--- 운영 옵션 ---------------------------------------------------------------
variable "snapshot_retention_limit" {
  description = "자동 스냅샷 보관 일수 (0 = 비활성, 최소 1 권장)"
  type        = number
  default     = 1
}

variable "snapshot_window" {
  description = "일일 자동 스냅샷 시간대 (UTC, 예: 18:00-19:00 = KST 03:00-04:00)"
  type        = string
  default     = "18:00-19:00"
}

variable "maintenance_window" {
  description = "주간 유지보수 윈도우 (UTC, 예: sun:19:00-sun:20:00 = KST 월 04:00-05:00)"
  type        = string
  default     = "sun:19:00-sun:20:00"
}

variable "notification_topic_arn" {
  description = "장애·failover 이벤트를 받을 SNS 토픽 ARN (null이면 비활성)"
  type        = string
  default     = null
}

variable "extra_parameters" {
  description = "파라미터 그룹에 추가할 Redis 파라미터 목록"
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "apply_immediately" {
  description = "변경을 유지보수 시간대 대기 없이 즉시 적용할지"
  type        = bool
  default     = false
}

variable "tags" {
  description = "모든 리소스에 공통으로 붙일 태그"
  type        = map(string)
  default     = {}
}
