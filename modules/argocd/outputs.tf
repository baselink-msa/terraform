###############################################################################
# modules/argocd/outputs.tf
###############################################################################

output "namespace" {
  description = "ArgoCD가 설치된 네임스페이스"
  value       = var.namespace
}

output "release_name" {
  description = "Helm release 이름"
  value       = helm_release.argo_cd.name
}

output "image_updater_role_arn" {
  description = "Image Updater IRSA role ARN (활성화된 경우, 비활성화 시 빈 문자열)"
  value       = var.enable_image_updater_irsa ? aws_iam_role.argocd_image_updater[0].arn : ""
}
