output "backup_vault_name" {
  description = "AWS Backup vault name."
  value       = aws_backup_vault.this.name
}

output "backup_vault_arn" {
  description = "AWS Backup vault ARN."
  value       = aws_backup_vault.this.arn
}

output "backup_plan_id" {
  description = "AWS Backup plan ID."
  value       = aws_backup_plan.this.id
}

output "backup_plan_arn" {
  description = "AWS Backup plan ARN."
  value       = aws_backup_plan.this.arn
}

output "backup_role_arn" {
  description = "IAM role ARN used by AWS Backup."
  value       = aws_iam_role.backup.arn
}
