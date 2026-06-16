###############################################################################
# modules/eks-addons/variables.tf
###############################################################################

#--- eks 모듈에서 전달받는 입력 ---------------------------------------------
variable "cluster_name" {
  description = "EKS 클러스터 이름 (eks 모듈의 cluster_name output)"
  type        = string
}

variable "aws_region" {
  description = "AWS region where the EKS cluster exists."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the EKS cluster runs. Used by AWS Load Balancer Controller."
  type        = string
}

variable "oidc_provider_arn" {
  description = "IAM OIDC provider ARN (eks 모듈의 oidc_provider_arn output)"
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC provider URL (eks 모듈의 oidc_provider_url output). https:// 포함/미포함 모두 허용"
  type        = string
}

variable "node_subnet_ids" {
  description = "Karpenter가 노드를 띄울 서브넷 ID 목록 (보통 프라이빗 서브넷)"
  type        = list(string)
}

variable "node_security_group_ids" {
  description = "Karpenter 노드에 붙일 보안 그룹 ID 목록 (eks 모듈의 cluster_security_group_id 포함)"
  type        = list(string)
}

#--- 차트 버전 ---------------------------------------------------------------
variable "karpenter_version" {
  description = "Karpenter Helm 차트 버전 (팀에서 최신 stable 확인 후 고정 권장)"
  type        = string
  default     = "1.11.1"
}

variable "keda_version" {
  description = "KEDA Helm 차트 버전"
  type        = string
  default     = "2.19.0"
}

variable "aws_load_balancer_controller_version" {
  description = "AWS Load Balancer Controller Helm chart version."
  type        = string
  default     = "1.14.0"
}

variable "reloader_version" {
  description = "Stakater Reloader Helm chart version. Null uses the chart repository default."
  type        = string
  default     = null
}


#--- 네임스페이스 ------------------------------------------------------------
variable "karpenter_namespace" {
  description = "Karpenter 설치 네임스페이스"
  type        = string
  default     = "karpenter"
}

variable "karpenter_replicas" {
  description = "Karpenter controller replica 수 (HA를 위해 2 권장)"
  type        = number
  default     = 2
}

variable "keda_namespace" {
  description = "KEDA 설치 네임스페이스"
  type        = string
  default     = "keda"
}

variable "keda_operator_role_arn" {
  description = "Optional IRSA role ARN used by the KEDA operator for AWS-backed scalers."
  type        = string
  default     = ""
}

variable "aws_load_balancer_controller_namespace" {
  description = "Namespace for AWS Load Balancer Controller."
  type        = string
  default     = "kube-system"
}

variable "reloader_namespace" {
  description = "Namespace for Stakater Reloader."
  type        = string
  default     = "reloader"
}

#--- Spot SLR ----------------------------------------------------------------
variable "create_spot_slr" {
  description = "EC2 Spot service-linked role 생성 여부. 계정에 이미 존재하면 false 로 건너뜀 (import 불필요)."
  type        = bool
  default     = true
}

#--- 중단 알림 큐 ------------------------------------------------------------
variable "enable_interruption_queue" {
  description = "Spot 회수·인스턴스 상태 이벤트용 SQS 큐 + EventBridge 규칙 생성 여부"
  type        = bool
  default     = true
}

#--- NodePool / EC2NodeClass -------------------------------------------------
variable "ami_alias" {
  description = "EC2NodeClass AMI alias. al2023@latest 는 apply 마다 노드 교체 위험 — 버전 고정 권장. 업그레이드 시 명시적으로 변경"
  type        = string
  default     = "al2023@latest"
}

variable "node_arch" {
  description = "노드 CPU 아키텍처 (amd64 / arm64)"
  type        = list(string)
  default     = ["amd64", "arm64"]
}

variable "nodepool_critical_cpu_limit" {
  description = "Critical NodePool CPU 상한 (결제·funnel OnDemand 전용). 업그레이드 시 팀 워크로드 기준으로 조정. # dev 낮은 값 예시: \"64\""
  type        = string
  default     = "500"
}

variable "nodepool_general_cpu_limit" {
  description = "General NodePool CPU 상한 (game·order·admin·ai-chatbot Spot+OnDemand). # dev 낮은 값 예시: \"32\""
  type        = string
  default     = "300"
}

variable "nodepool_batch_cpu_limit" {
  description = "Batch NodePool CPU 상한 (ticket-worker SQS 비동기 Spot 우선). # dev 낮은 값 예시: \"32\""
  type        = string
  default     = "300"
}

#--- 공통 --------------------------------------------------------------------
variable "tags" {
  description = "모든 AWS 리소스에 공통으로 붙일 태그"
  type        = map(string)
  default     = {}
}

#--- Predictive scaling toggle (dev 비용 보호) ------------------------------
variable "keda_predictive_paused" {
  description = <<-EOT
    true 면 predictive 트리거 가진 5개 ScaledObject 에 pause annotation 부여.
    dev 에서 ticket_open_schedule 테스트 데이터 생성 시 불필요한 pod·node
    scale-up 방지용. 기본 false (정상 동작).
    영향: 해당 5개 ScaledObject 의 cpu + postgresql 트리거 모두 정지.
    토글: terraform apply -var="keda_predictive_paused=true|false"
  EOT
  type        = bool
  default     = false
}

variable "keda_target_namespace" {
  description = "ScaledObject 가 배포된 네임스페이스 (git-ops 가 관리)"
  type        = string
  default     = "baselink-dev"
}
