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
