output "lambda_function_name" {
  description = "Change Auditor Lambda function name."
  value       = aws_lambda_function.handler.function_name
}

output "lambda_function_arn" {
  description = "Change Auditor Lambda function ARN."
  value       = aws_lambda_function.handler.arn
}

output "sqs_queue_url" {
  description = "SQS queue URL for CloudTrail events."
  value       = aws_sqs_queue.events.url
}

output "sqs_queue_arn" {
  description = "SQS queue ARN."
  value       = aws_sqs_queue.events.arn
}

output "dynamodb_table_name" {
  description = "DynamoDB table name for event history."
  value       = aws_dynamodb_table.events.name
}

output "eventbridge_rule_arn" {
  description = "EventBridge rule ARN."
  value       = aws_cloudwatch_event_rule.cloudtrail_changes.arn
}
