data "aws_iam_policy_document" "chatbot_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["chatbot.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic" "ops_alerts" {
  count = var.enable_slack_alerts ? 1 : 0

  name = "${local.name_prefix}-ops-alerts"

  tags = merge(local.common_tags, {
    Purpose = "ops-alerts"
  })
}

resource "aws_sns_topic" "edge_ops_alerts" {
  provider = aws.use1
  count    = var.enable_slack_alerts ? 1 : 0

  name = "${local.name_prefix}-edge-ops-alerts"

  tags = merge(local.common_tags, {
    Purpose = "edge-ops-alerts"
  })
}

resource "aws_iam_role" "chatbot_slack" {
  count = var.enable_slack_alerts ? 1 : 0

  name               = "${local.name_prefix}-chatbot-slack"
  assume_role_policy = data.aws_iam_policy_document.chatbot_assume_role.json

  tags = merge(local.common_tags, {
    Purpose = "chatops"
  })
}

resource "aws_iam_role_policy" "chatbot_slack_readonly" {
  count = var.enable_slack_alerts ? 1 : 0

  name = "${local.name_prefix}-chatbot-slack-readonly"
  role = aws_iam_role.chatbot_slack[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadCloudWatchAlarmContext"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarms",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics"
        ]
        Resource = "*"
      },
      {
        Sid    = "ReadTicketQueues"
        Effect = "Allow"
        Action = [
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = [
          module.sqs_ticket_confirm.queue_arn,
          module.sqs_ticket_confirm.dead_letter_queue_arn
        ]
      }
    ]
  })
}

resource "aws_chatbot_slack_channel_configuration" "ops_alerts" {
  count = var.enable_slack_alerts ? 1 : 0

  configuration_name          = "${local.name_prefix}-ops-alerts"
  iam_role_arn                = aws_iam_role.chatbot_slack[0].arn
  slack_team_id               = var.slack_workspace_id
  slack_channel_id            = var.slack_channel_id
  sns_topic_arns              = [aws_sns_topic.ops_alerts[0].arn, aws_sns_topic.edge_ops_alerts[0].arn]
  guardrail_policy_arns       = ["arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"]
  logging_level               = "ERROR"
  user_authorization_required = true

  tags = merge(local.common_tags, {
    Purpose = "chatops"
  })
}
