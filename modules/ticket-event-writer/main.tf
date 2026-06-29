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

  rule {
    id     = "expire-athena-query-results"
    status = "Enabled"

    filter {
      prefix = "athena-results/"
    }

    expiration {
      days = 7
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
  excludes = [
    "__pycache__",
    "__pycache__/*",
    "*.pyc"
  ]
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

resource "aws_glue_catalog_database" "ticket_events" {
  name        = replace("${var.name_prefix}_ticket_events", "-", "_")
  description = "Ticket reliability events stored by the event writer Lambda."
}

resource "aws_glue_catalog_table" "ticket_events" {
  name          = "ticket_events"
  database_name = aws_glue_catalog_database.ticket_events.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL                              = "TRUE"
    "projection.enabled"                  = "true"
    "projection.event_date.type"          = "date"
    "projection.event_date.range"         = "2026-01-01,NOW"
    "projection.event_date.format"        = "yyyy-MM-dd"
    "projection.event_date.interval"      = "1"
    "projection.event_date.interval.unit" = "DAYS"
    "projection.event_type.type"          = "enum"
    "projection.event_type.values" = join(",", [
      "WAITING_ENTERED",
      "ACCESS_TOKEN_ISSUED",
      "RESERVATION_REQUESTED",
      "RESERVATION_CONFIRMED",
      "ADMISSION_THROTTLE_APPLIED",
      "ADMISSION_STOP_APPLIED",
      "ADMISSION_THROTTLE_RECOVERED",
      "SEAT_LOCK_REQUESTED",
      "SEAT_LOCKED",
      "SEAT_LOCK_FAILED",
      "SEAT_UNLOCKED"
    ])
    "storage.location.template" = "s3://${aws_s3_bucket.events.id}/ticket-events/event_date=$${event_date}/event_type=$${event_type}/"
  }

  partition_keys {
    name = "event_date"
    type = "string"
  }

  partition_keys {
    name = "event_type"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.events.id}/ticket-events/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "ticket-event-json"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"

      parameters = {
        "case.insensitive" = "true"
      }
    }

    columns {
      name = "eventid"
      type = "string"
    }

    columns {
      name = "schemaVersion"
      type = "int"
    }

    columns {
      name = "occurredAt"
      type = "string"
    }

    columns {
      name = "producer"
      type = "string"
    }

    columns {
      name = "aggregateType"
      type = "string"
    }

    columns {
      name = "aggregateId"
      type = "string"
    }

    columns {
      name = "gameId"
      type = "bigint"
    }

    columns {
      name = "userKey"
      type = "string"
    }

    columns {
      name = "traceId"
      type = "string"
    }

    columns {
      name = "payload"
      type = "struct<initialRank:bigint,policyMaxEnterPerMinute:bigint,waitingSeconds:double,effectiveEnterPerMinute:bigint,dbPressureLevel:string,dbThrottlePercent:double,reservationId:bigint,seatId:bigint,status:string,pendingDurationSeconds:double,reason:string,currentDbConnections:bigint,dbConnectionBudget:bigint,currentReadyPodCount:bigint,projectedReadyPodCount:bigint,baseEnterPerMinute:bigint,projectedEnterPerMinute:bigint,currentMinuteRemainingSlots:bigint,canEnter:boolean>"
    }
  }
}

resource "aws_athena_workgroup" "ticket_events" {
  name        = "${var.name_prefix}-ticket-events"
  description = "Athena workgroup for ticket reliability event analysis."
  state       = "ENABLED"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.events.id}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  tags = var.tags
}

resource "aws_athena_named_query" "daily_event_volume" {
  name        = "ticket-events-daily-volume"
  description = "Counts today's ticket events by game and event type."
  database    = aws_glue_catalog_database.ticket_events.name
  workgroup   = aws_athena_workgroup.ticket_events.name
  query       = <<-SQL
    SELECT
      gameId AS game_id,
      event_type,
      count(*) AS event_count
    FROM ticket_events
    WHERE event_date = date_format(current_date, '%Y-%m-%d')
    GROUP BY gameId, event_type
    ORDER BY gameId, event_type
  SQL
}

resource "aws_athena_named_query" "average_waiting_time" {
  name        = "ticket-events-average-waiting-time"
  description = "Calculates today's average waiting time by game."
  database    = aws_glue_catalog_database.ticket_events.name
  workgroup   = aws_athena_workgroup.ticket_events.name
  query       = <<-SQL
    SELECT
      gameId AS game_id,
      avg(payload.waitingSeconds) AS avg_waiting_seconds,
      count(*) AS issued_token_count
    FROM ticket_events
    WHERE event_date = date_format(current_date, '%Y-%m-%d')
      AND event_type = 'ACCESS_TOKEN_ISSUED'
    GROUP BY gameId
    ORDER BY gameId
  SQL
}

resource "aws_athena_named_query" "reservation_conversion" {
  name        = "ticket-events-reservation-conversion"
  description = "Calculates today's reservation request-to-confirm conversion by game."
  database    = aws_glue_catalog_database.ticket_events.name
  workgroup   = aws_athena_workgroup.ticket_events.name
  query       = <<-SQL
    SELECT
      gameId AS game_id,
      count_if(event_type = 'RESERVATION_REQUESTED') AS request_count,
      count_if(event_type = 'RESERVATION_CONFIRMED') AS confirm_count,
      100.0 * count_if(event_type = 'RESERVATION_CONFIRMED')
        / nullif(count_if(event_type = 'RESERVATION_REQUESTED'), 0)
        AS conversion_percent
    FROM ticket_events
    WHERE event_date = date_format(current_date, '%Y-%m-%d')
      AND event_type IN ('RESERVATION_REQUESTED', 'RESERVATION_CONFIRMED')
    GROUP BY gameId
    ORDER BY gameId
  SQL
}
