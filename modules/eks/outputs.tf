###############################################################################
# modules/eks/outputs.tf
###############################################################################

output "cluster_name" {
  description = "EKS 클러스터 이름"
  value       = aws_eks_cluster.this.name
}

output "cluster_version" {
  description = "EKS 쿠버네티스 버전"
  value       = aws_eks_cluster.this.version
}

output "cluster_endpoint" {
  description = "API 서버 엔드포인트 URL (kubernetes/helm provider 설정에 사용)"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "클러스터 CA 인증서(base64). kubeconfig·provider 구성에 사용"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "EKS가 자동 생성한 클러스터 보안 그룹 ID"
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

#--- IRSA: IAM/IRSA 모듈이 입력으로 받는 값 ---------------------------
output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN. IRSA 역할의 신뢰 정책에서 사용"
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL (https:// 접두어 포함). IRSA 신뢰 정책 condition에 사용"
  value       = aws_iam_openid_connect_provider.this.url
}

#--- eks-addons 모듈(Karpenter·KEDA)이 입력으로 받는 값 ---------------------
output "node_role_arn" {
  description = "노드그룹 IAM 역할 ARN (Karpenter가 띄우는 노드에도 재사용 가능)"
  value       = aws_iam_role.node.arn
}

output "secrets_kms_key_arn" {
  description = "Kubernetes secrets 암호화에 쓰는 KMS 키 ARN (비활성화 시 null)"
  value       = var.enable_secrets_encryption ? aws_kms_key.eks[0].arn : null
}
