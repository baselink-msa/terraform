###############################################################################
# modules/eks/variables.tf
###############################################################################

#--- 기본 식별자 -------------------------------------------------------------
variable "cluster_name" {
  description = "EKS 클러스터 이름 (하위 리소스 이름의 접두어로 사용)"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS 쿠버네티스 버전"
  type        = string
  default     = "1.34"
}

variable "tags" {
  description = "모든 리소스에 공통으로 붙일 태그"
  type        = map(string)
  default     = {}
}

#--- 네트워크 (VPC 모듈에서 입력으로 전달받음) -------------------------------
variable "vpc_id" {
  description = "클러스터가 속할 VPC ID (팀 인터페이스용. cluster 리소스는 subnet으로 VPC를 추론하므로 직접 참조하지는 않음)"
  type        = string
}

variable "subnet_ids" {
  description = "컨트롤 플레인 ENI 및 노드그룹이 사용할 서브넷 ID 목록 (프라이빗 서브넷 권장)"
  type        = list(string)
}

#--- 클러스터 엔드포인트 접근 -------------------------------------------------
variable "endpoint_public_access" {
  description = "API 서버 엔드포인트를 인터넷에서 접근 가능하게 할지 (dev: true)"
  type        = bool
  default     = true
}

variable "endpoint_private_access" {
  description = "API 서버 엔드포인트를 VPC 내부에서 접근 가능하게 할지"
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "public 엔드포인트 접근을 허용할 CIDR 목록 (반드시 사무실/VPN IP로 제한할 것; 빈 목록이면 AWS가 0.0.0.0/0으로 해석함)"
  type        = list(string)
  default     = []
  validation {
    condition     = var.endpoint_public_access == false || length(var.public_access_cidrs) > 0
    error_message = "endpoint_public_access = true 이면 public_access_cidrs 에 최소 1개의 CIDR을 지정해야 합니다 (0.0.0.0/0 사용 금지)."
  }
}

#--- Control Plane 로깅 -------------------------------------------------------
variable "cluster_log_types" {
  description = "CloudWatch로 전송할 EKS control plane 로그 유형"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  validation {
    condition = alltrue([
      for t in var.cluster_log_types :
      contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], t)
    ])
    error_message = "cluster_log_types 에는 api, audit, authenticator, controllerManager, scheduler 중에서만 지정할 수 있습니다."
  }
}

#--- 시스템 노드그룹 ----------------------------------------------------------
variable "system_node_instance_types" {
  description = "시스템 노드그룹 인스턴스 타입 (Graviton 권장)"
  type        = list(string)
  default     = ["t4g.large"]
}

variable "system_node_capacity_type" {
  description = "노드 구매 옵션 (ON_DEMAND 또는 SPOT)"
  type        = string
  default     = "ON_DEMAND"
}

variable "system_node_disk_size" {
  description = "시스템 노드그룹 EBS 디스크 크기(GiB). 컨테이너 이미지 캐시를 고려해 50 이상 권장"
  type        = number
  default     = 50
}

variable "system_node_desired_size" {
  description = "시스템 노드그룹 희망 노드 수"
  type        = number
  default     = 2
}

variable "system_node_min_size" {
  description = "시스템 노드그룹 최소 노드 수"
  type        = number
  default     = 2
  validation {
    condition     = var.system_node_min_size >= 1
    error_message = "system_node_min_size는 1 이상이어야 합니다."
  }
}

variable "system_node_max_size" {
  description = "시스템 노드그룹 최대 노드 수"
  type        = number
  default     = 3
  validation {
    condition     = var.system_node_max_size >= var.system_node_min_size
    error_message = "system_node_max_size는 system_node_min_size 이상이어야 합니다."
  }
}

#--- 관리형 애드온 ------------------------------------------------------------
variable "cluster_addons" {
  description = "EKS 관리형으로 설치할 애드온 목록"
  type        = list(string)
  default     = ["vpc-cni", "coredns", "kube-proxy"]
}

variable "cluster_addon_versions" {
  description = "관리형 애드온 버전 고정 맵 (애드온명 => 버전 문자열). 비우면 EKS 기본 버전 자동 선택. 예: { \"vpc-cni\" = \"v1.18.1-eksbuild.3\", \"coredns\" = \"v1.11.1-eksbuild.4\" }"
  type        = map(string)
  default     = {}
}

#--- secrets 암호화 -----------------------------------------------------------
variable "enable_secrets_encryption" {
  description = "Kubernetes secrets를 KMS로 봉투 암호화할지 (활성화 후에는 비활성화 불가)"
  type        = bool
  default     = true
}
