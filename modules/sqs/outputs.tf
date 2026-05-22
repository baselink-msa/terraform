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