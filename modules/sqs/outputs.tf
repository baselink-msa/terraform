output "queue_id" {
  description = "SQS 큐의 ID (URL과 동일)"
  value       = aws_sqs_queue.this.id
}

output "queue_arn" {
  description = "SQS 큐의 ARN"
  value       = aws_sqs_queue.this.arn
}

output "queue_url" {
  description = "SQS 큐의 접속 URL (Spring Boot application.yml 에 주입할 값)"
  value       = aws_sqs_queue.this.url
}

output "dead_letter_queue_arn" {
  description = "ARN of the dead-letter queue, or null when disabled."
  value       = var.create_dead_letter_queue ? aws_sqs_queue.dead_letter[0].arn : null
}

output "dead_letter_queue_url" {
  description = "URL of the dead-letter queue, or null when disabled."
  value       = var.create_dead_letter_queue ? aws_sqs_queue.dead_letter[0].url : null
}

output "dead_letter_queue_alarm_name" {
  description = "Name of the DLQ CloudWatch alarm, or null when disabled."
  value       = var.create_dead_letter_queue && var.create_dead_letter_queue_alarm ? aws_cloudwatch_metric_alarm.dead_letter_messages_visible[0].alarm_name : null
}

output "dead_letter_queue_alarm_arn" {
  description = "ARN of the DLQ CloudWatch alarm, or null when disabled."
  value       = var.create_dead_letter_queue && var.create_dead_letter_queue_alarm ? aws_cloudwatch_metric_alarm.dead_letter_messages_visible[0].arn : null
}
