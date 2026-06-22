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

output "glue_database_name" {
  description = "Glue Data Catalog database containing the ticket event table."
  value       = aws_glue_catalog_database.ticket_events.name
}

output "glue_table_name" {
  description = "Glue Data Catalog table for ticket event JSON objects."
  value       = aws_glue_catalog_table.ticket_events.name
}

output "athena_workgroup_name" {
  description = "Athena workgroup used for ticket reliability analysis."
  value       = aws_athena_workgroup.ticket_events.name
}
