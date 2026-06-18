locals {
  name_prefix = "${var.project_name}-${var.environment}"
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
  })
}

# ────────────────────────────────────────────────────────────────────
# Slack Webhook Secret
# ────────────────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "slack_webhook" {
  name                    = "${local.name_prefix}-slack-webhook"
  description             = "Slack Webhook URL for AWS Change Auditor notifications"
  recovery_window_in_days = 0
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "slack_webhook" {
  secret_id     = aws_secretsmanager_secret.slack_webhook.id
  secret_string = jsonencode({ webhook_url = var.slack_webhook_url })
}

# ────────────────────────────────────────────────────────────────────
# DynamoDB — 이벤트 처리 이력 저장
# ────────────────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "events" {
  name         = "${local.name_prefix}-events"
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "event_id"
  range_key    = "event_time"

  attribute {
    name = "event_id"
    type = "S"
  }

  attribute {
    name = "event_time"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = local.common_tags
}

# ────────────────────────────────────────────────────────────────────
# SQS — EventBridge → SQS → Lambda
# ────────────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "events_dlq" {
  name                      = "${local.name_prefix}-events-dlq"
  message_retention_seconds = 1209600 # 14 days
  tags                      = local.common_tags
}

resource "aws_sqs_queue" "events" {
  name                       = "${local.name_prefix}-events"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 86400 # 1 day

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.events_dlq.arn
    maxReceiveCount     = 3
  })

  tags = local.common_tags
}

resource "aws_sqs_queue_policy" "events" {
  queue_url = aws_sqs_queue.events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridge"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.events.arn
    }]
  })
}

# ────────────────────────────────────────────────────────────────────
# EventBridge — CloudTrail 변경성 이벤트 수신
# ────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_event_rule" "cloudtrail_changes" {
  name        = "${local.name_prefix}-cloudtrail-changes"
  description = "Capture mutating CloudTrail events for change auditing (Phase 1)"

  event_pattern = jsonencode({
    source      = ["aws.ec2", "aws.iam", "aws.s3", "aws.rds", "aws.elasticache", "aws.eks", "aws.kms", "aws.elasticloadbalancing"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      readOnly = [false]
      eventName = [
        { "prefix" : "Create" },
        { "prefix" : "Delete" },
        { "prefix" : "Update" },
        { "prefix" : "Modify" },
        { "prefix" : "Put" },
        { "prefix" : "Attach" },
        { "prefix" : "Detach" },
        { "prefix" : "Authorize" },
        { "prefix" : "Revoke" },
        { "prefix" : "Add" },
        { "prefix" : "Remove" },
        { "prefix" : "Enable" },
        { "prefix" : "Disable" },
        { "prefix" : "Schedule" },
        { "prefix" : "Run" },
        { "prefix" : "Terminate" },
        { "prefix" : "Stop" },
        { "prefix" : "Reboot" }
      ]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "to_sqs" {
  rule      = aws_cloudwatch_event_rule.cloudtrail_changes.name
  target_id = "send-to-sqs"
  arn       = aws_sqs_queue.events.arn
}

# ────────────────────────────────────────────────────────────────────
# Lambda — 이벤트 처리
# ────────────────────────────────────────────────────────────────────

resource "aws_security_group" "lambda" {
  name        = "${local.name_prefix}-lambda"
  description = "Change Auditor Lambda egress"
  vpc_id      = var.vpc_id
  tags        = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "lambda_all" {
  security_group_id = aws_security_group.lambda.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name_prefix}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_inline" {
  name = "${local.name_prefix}-lambda-inline"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQS"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.events.arn
      },
      {
        Sid    = "DynamoDB"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:Query",
        ]
        Resource = aws_dynamodb_table.events.arn
      },
      {
        Sid      = "SecretsManager"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.slack_webhook.arn
      },
      {
        Sid      = "Bedrock"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${var.bedrock_region}::foundation-model/${var.bedrock_model_id}"
      },
      {
        Sid    = "ConfigRead"
        Effect = "Allow"
        Action = [
          "config:GetResourceConfigHistory",
          "config:BatchGetResourceConfig",
        ]
        Resource = "*"
      },
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          aws_cloudwatch_log_group.lambda.arn,
          "${aws_cloudwatch_log_group.lambda.arn}:*",
        ]
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name_prefix}-handler"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "handler" {
  function_name    = "${local.name_prefix}-handler"
  description      = "AWS Change Auditor: CloudTrail 변경 이벤트 수집 → AI 요약 → Slack 알림"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 120
  memory_size      = 256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      SLACK_WEBHOOK_SECRET_ARN = aws_secretsmanager_secret.slack_webhook.arn
      BEDROCK_MODEL_ID         = var.bedrock_model_id
      BEDROCK_REGION           = var.bedrock_region
      DYNAMODB_TABLE           = aws_dynamodb_table.events.name
      ENVIRONMENT              = var.environment
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
  tags       = local.common_tags
}

# ── SQS → Lambda 트리거 ─────────────────────────────────────────────

resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn                   = aws_sqs_queue.events.arn
  function_name                      = aws_lambda_function.handler.arn
  batch_size                         = 5
  maximum_batching_window_in_seconds = 30
  enabled                            = true
}
