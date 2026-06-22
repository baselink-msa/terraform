data "aws_caller_identity" "current" {}

locals {
  backup_failure_event_rules = var.enable_slack_alerts ? {
    backup = {
      detail_type = "Backup Job State Change"
      detail_key  = "state"
      values      = ["FAILED", "ABORTED", "EXPIRED"]
    }
    copy = {
      detail_type = "Copy Job State Change"
      detail_key  = "state"
      values      = ["FAILED"]
    }
    restore = {
      detail_type = "Restore Job State Change"
      detail_key  = "status"
      values      = ["FAILED"]
    }
  } : {}
}

resource "aws_cloudwatch_event_rule" "backup_failure" {
  for_each = local.backup_failure_event_rules

  name        = "${local.name_prefix}-${each.key}-job-failure"
  description = "Notify operators when an AWS Backup ${each.key} job cannot complete."

  event_pattern = jsonencode({
    source      = ["aws.backup"]
    detail-type = [each.value.detail_type]
    detail = {
      (each.value.detail_key) = each.value.values
    }
  })

  tags = merge(local.common_tags, {
    Purpose = "backup-failure-alert"
  })
}

resource "aws_cloudwatch_event_target" "backup_failure_sns" {
  for_each = aws_cloudwatch_event_rule.backup_failure

  rule = each.value.name
  arn  = aws_sns_topic.ops_alerts[0].arn
}

data "aws_iam_policy_document" "ops_alerts_topic" {
  count = var.enable_slack_alerts ? 1 : 0

  statement {
    sid    = "AllowAccountOwner"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions = [
      "SNS:GetTopicAttributes",
      "SNS:SetTopicAttributes",
      "SNS:AddPermission",
      "SNS:RemovePermission",
      "SNS:DeleteTopic",
      "SNS:Subscribe",
      "SNS:ListSubscriptionsByTopic",
      "SNS:Publish",
    ]

    resources = [aws_sns_topic.ops_alerts[0].arn]
  }

  statement {
    sid    = "AllowEventBridgeBackupAlerts"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.ops_alerts[0].arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [for rule in aws_cloudwatch_event_rule.backup_failure : rule.arn]
    }
  }
}

resource "aws_sns_topic_policy" "ops_alerts" {
  count = var.enable_slack_alerts ? 1 : 0

  arn    = aws_sns_topic.ops_alerts[0].arn
  policy = data.aws_iam_policy_document.ops_alerts_topic[0].json
}
