###############################################################################
# modules/eks-addons/outputs.tf
###############################################################################

output "karpenter_controller_role_arn" {
  description = "Karpenter 컨트롤러 IAM 역할 ARN (IRSA)"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_node_role_arn" {
  description = "Karpenter가 띄우는 노드의 IAM 역할 ARN"
  value       = aws_iam_role.karpenter_node.arn
}

output "karpenter_node_instance_profile" {
  description = "Karpenter 노드 instance profile 이름 (EC2NodeClass가 참조)"
  value       = aws_iam_instance_profile.karpenter_node.name
}

output "interruption_queue_name" {
  description = "Karpenter 중단 알림 SQS 큐 이름 (비활성화 시 null)"
  value       = var.enable_interruption_queue ? aws_sqs_queue.karpenter_interruption[0].name : null
}

output "karpenter_namespace" {
  description = "Karpenter 네임스페이스"
  value       = var.karpenter_namespace
}

output "keda_namespace" {
  description = "KEDA 네임스페이스"
  value       = var.keda_namespace
}
