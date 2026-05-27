###############################################################################
# modules/argocd/variables.tf
###############################################################################

variable "cluster_name" {
  description = "ArgoCD가 설치될 EKS 클러스터 이름 (태깅·IRSA 명명에 사용)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN (IRSA 신뢰 정책에 사용)"
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS OIDC provider URL (https:// 포함/미포함 모두 허용)"
  type        = string
}

variable "namespace" {
  description = "ArgoCD가 설치될 K8s 네임스페이스"
  type        = string
  default     = "argocd"
}

variable "argocd_version" {
  description = "argo-cd Helm 차트 버전 (값 확정은 사용자가 README에 명시)"
  type        = string
  default     = "7.7.5"
}

variable "server_service_type" {
  description = "ArgoCD 서버 서비스 노출 방식 (ClusterIP / NodePort / LoadBalancer)"
  type        = string
  default     = "ClusterIP"
  validation {
    condition     = contains(["ClusterIP", "NodePort", "LoadBalancer"], var.server_service_type)
    error_message = "server_service_type must be ClusterIP, NodePort, or LoadBalancer."
  }
}

variable "server_insecure" {
  description = "ArgoCD 서버를 HTTP(insecure)로 띄울지 (true면 ALB 등 외부에서 TLS 종료)"
  type        = bool
  default     = false
}

variable "enable_image_updater_irsa" {
  description = "ArgoCD Image Updater용 IRSA 역할을 만들지 (ECR 조회 권한)"
  type        = bool
  default     = false
}

variable "extra_helm_values" {
  description = "ArgoCD Helm 차트에 추가 전달할 values (YAML 문자열). 비워두면 기본만 사용."
  type        = string
  default     = ""
}

variable "tags" {
  description = "리소스 태그"
  type        = map(string)
  default     = {}
}
