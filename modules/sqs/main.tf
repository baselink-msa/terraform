resource "aws_sqs_queue" "this" {
  name                      = var.queue_name
  delay_seconds             = var.delay_seconds
  max_message_size          = var.max_message_size
  message_retention_seconds = var.message_retention_seconds
  receive_wait_time_seconds = var.receive_wait_time_seconds
  redrive_policy = var.create_dead_letter_queue ? jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter[0].arn
    maxReceiveCount     = var.max_receive_count
  }) : null

  tags = var.tags
}

resource "aws_sqs_queue" "dead_letter" {
  count = var.create_dead_letter_queue ? 1 : 0

  name                      = var.dead_letter_queue_name != null ? var.dead_letter_queue_name : "${var.queue_name}-dlq"
  message_retention_seconds = var.dead_letter_queue_message_retention_seconds

  tags = merge(var.tags, {
    Purpose = "dead-letter-queue"
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dead_letter" {
  count = var.create_dead_letter_queue ? 1 : 0

  queue_url = aws_sqs_queue.dead_letter[0].id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.this.arn]
  })
}

resource "aws_cloudwatch_metric_alarm" "dead_letter_messages_visible" {
  count = var.create_dead_letter_queue && var.create_dead_letter_queue_alarm ? 1 : 0

  alarm_name          = var.dead_letter_queue_alarm_name != null ? var.dead_letter_queue_alarm_name : "${var.queue_name}-dlq-messages-visible"
  alarm_description   = "Detects messages waiting in the dead-letter queue for ${var.queue_name}."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.dead_letter_queue_alarm_evaluation_periods
  threshold           = var.dead_letter_queue_alarm_threshold
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = var.dead_letter_queue_alarm_period
  statistic           = "Maximum"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.dead_letter_queue_alarm_actions
  ok_actions          = var.dead_letter_queue_alarm_ok_actions

  dimensions = {
    QueueName = aws_sqs_queue.dead_letter[0].name
  }

  tags = merge(var.tags, {
    Purpose = "dead-letter-queue-alarm"
  })
}

resource "aws_cloudwatch_metric_alarm" "queue_backlog_messages_visible" {
  count = var.create_queue_backlog_alarm ? 1 : 0

  alarm_name          = var.queue_backlog_alarm_name != null ? var.queue_backlog_alarm_name : "${var.queue_name}-messages-visible"
  alarm_description   = "Detects messages waiting in the source queue for ${var.queue_name}."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.queue_backlog_alarm_evaluation_periods
  threshold           = var.queue_backlog_alarm_threshold
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = var.queue_backlog_alarm_period
  statistic           = "Maximum"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.queue_backlog_alarm_actions
  ok_actions          = var.queue_backlog_alarm_ok_actions

  dimensions = {
    QueueName = aws_sqs_queue.this.name
  }

  tags = merge(var.tags, {
    Purpose = "source-queue-backlog-alarm"
  })
}
