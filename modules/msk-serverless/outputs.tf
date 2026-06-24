output "cluster_arn" {
  description = "MSK Serverless cluster ARN, or null when disabled."
  value       = var.enabled ? aws_msk_serverless_cluster.this[0].arn : null
}

output "cluster_uuid" {
  description = "MSK Serverless cluster UUID, or null when disabled."
  value       = var.enabled ? aws_msk_serverless_cluster.this[0].cluster_uuid : null
}

output "bootstrap_brokers_sasl_iam" {
  description = "IAM bootstrap broker string, or null when disabled."
  value       = var.enabled ? aws_msk_serverless_cluster.this[0].bootstrap_brokers_sasl_iam : null
}

output "security_group_id" {
  description = "Security group ID used by MSK Serverless, or null when disabled."
  value       = var.enabled ? aws_security_group.this[0].id : null
}
