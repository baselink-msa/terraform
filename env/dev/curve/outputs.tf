output "curve_db_endpoint" {
  description = "agh-curve-db 접속 엔드포인트 (호스트:포트)"
  value       = module.curve_db.db_instance_endpoint
}

output "curve_db_security_group_id" {
  description = "agh-curve-db 보안그룹 ID"
  value       = aws_security_group.curve_db.id
}

output "curve_alerts_topic_arn" {
  description = "P6 워치독 알람 SNS topic ARN"
  value       = aws_sns_topic.curve_alerts.arn
}
