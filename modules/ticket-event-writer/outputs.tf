output "bucket_name" {
  description = "S3 bucket containing partitioned ticket event JSON objects."
  value       = aws_s3_bucket.events.id
}

output "bucket_arn" {
  description = "ARN of the ticket event S3 bucket."
  value       = aws_s3_bucket.events.arn
}

output "lambda_function_name" {
  description = "Name of the ticket event writer Lambda."
  value       = aws_lambda_function.writer.function_name
}

output "lambda_function_arn" {
  description = "ARN of the ticket event writer Lambda."
  value       = aws_lambda_function.writer.arn
}
