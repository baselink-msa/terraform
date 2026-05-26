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

variable "aws_load_balancer_controller_policy_url" {
  description = "Official IAM policy JSON URL for AWS Load Balancer Controller."
  type        = string
  default     = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json"
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

variable "aws_load_balancer_controller_namespace" {
  description = "Namespace for AWS Load Balancer Controller."
  type        = string
  default     = "kube-system"
}

#--- 중단 알림 큐 ------------------------------------------------------------
variable "enable_interruption_queue" {
  description = "Spot 회수·인스턴스 상태 이벤트용 SQS 큐 + EventBridge 규칙 생성 여부"
  type        = bool
  default     = true
}

#--- NodePool / EC2NodeClass -------------------------------------------------
variable "ami_alias" {
  description = "EC2NodeClass의 AMI alias (예: al2023@latest)"
  type        = string
  default     = "al2023@latest"
}

variable "node_capacity_types" {
  description = "Karpenter가 띄울 노드의 구매 옵션 (spot / on-demand)"
  type        = list(string)
  default     = ["spot", "on-demand"]
}

variable "node_arch" {
  description = "노드 CPU 아키텍처 (amd64 / arm64)"
  type        = list(string)
  default     = ["amd64", "arm64"]
}

variable "node_instance_categories" {
  description = "허용할 인스턴스 카테고리 (c=컴퓨트, m=범용, r=메모리 등)"
  type        = list(string)
  default     = ["c", "m", "r"]
}

variable "nodepool_cpu_limit" {
  description = "NodePool 전체 CPU 총량 상한 (코어 수). 비용 폭주 방지"
  type        = string
  default     = "1000"
}

variable "nodepool_memory_limit" {
  description = "NodePool 전체 메모리 총량 상한 (예: \"1000Gi\"). 비용 폭주 방지"
  type        = string
  default     = "1000Gi"
}

#--- 공통 --------------------------------------------------------------------
variable "tags" {
  description = "모든 AWS 리소스에 공통으로 붙일 태그"
  type        = map(string)
  default     = {}
}
