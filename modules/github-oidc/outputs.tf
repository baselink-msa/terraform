output "github_actions_role_arn" {
  description = "GitHub Actions에서 사용할 AWS IAM Role ARN"
  value       = aws_iam_role.github_actions.arn
}