data "aws_caller_identity" "current" {}

locals {
  function_name = "${var.name_prefix}-ticket-event-writer"
  bucket_name   = "${var.name_prefix}-ticket-events-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "events" {
  bucket = local.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_ownership_controls" "events" {
  bucket = aws_s3_bucket.events.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "events" {
  bucket = aws_s3_bucket.events.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "events" {
  bucket = aws_s3_bucket.events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.events.arn,
          "${aws_s3_bucket.events.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "events" {
  bucket = aws_s3_bucket.events.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "events" {
  bucket = aws_s3_bucket.events.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "events" {
  bucket = aws_s3_bucket.events.id

  rule {
    id     = "expire-dev-ticket-events"
    status = "Enabled"

    filter {
      prefix = "ticket-events/"
    }

    expiration {
      days = var.event_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.events]
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "writer" {
  name               = local.function_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = var.tags
}

resource "aws_cloudwatch_log_group" "writer" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_iam_role_policy" "writer" {
  name = "${local.function_name}-policy"
  role = aws_iam_role.writer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ConsumeTicketEvents"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = var.source_queue_arn
      },
      {
        Sid      = "WriteTicketEvents"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.events.arn}/ticket-events/*"
      },
      {
        Sid    = "WriteLambdaLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.writer.arn}:*"
      }
    ]
  })
}

data "archive_file" "writer" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/ticket-event-writer.zip"
}

resource "aws_lambda_function" "writer" {
  function_name    = local.function_name
  description      = "Validates ticket event envelopes and stores idempotent JSON objects in S3."
  filename         = data.archive_file.writer.output_path
  source_code_hash = data.archive_file.writer.output_base64sha256
  role             = aws_iam_role.writer.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      EVENT_BUCKET = aws_s3_bucket.events.id
      EVENT_PREFIX = "ticket-events"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.writer,
    aws_iam_role_policy.writer
  ]

  tags = var.tags
}

resource "aws_lambda_event_source_mapping" "ticket_events" {
  event_source_arn                   = var.source_queue_arn
  function_name                      = aws_lambda_function.writer.arn
  batch_size                         = var.batch_size
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
  enabled                            = true
}
