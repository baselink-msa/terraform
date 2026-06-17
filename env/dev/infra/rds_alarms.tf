locals {
  rds_alarm_actions = var.enable_slack_alerts ? [aws_sns_topic.ops_alerts[0].arn] : []
  rds_instance_id   = "${local.name_prefix}-postgres"
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${local.name_prefix}-rds-cpu-high"
  alarm_description   = "RDS CPUUtilization is high for the dev PostgreSQL instance."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 80
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = local.rds_instance_id
  }

  alarm_actions = local.rds_alarm_actions
  ok_actions    = local.rds_alarm_actions

  tags = merge(local.common_tags, {
    Purpose = "rds-monitoring"
    Metric  = "CPUUtilization"
  })
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  alarm_name          = "${local.name_prefix}-rds-free-storage-low"
  alarm_description   = "RDS FreeStorageSpace is low for the dev PostgreSQL instance."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 2147483648
  comparison_operator = "LessThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = local.rds_instance_id
  }

  alarm_actions = local.rds_alarm_actions
  ok_actions    = local.rds_alarm_actions

  tags = merge(local.common_tags, {
    Purpose = "rds-monitoring"
    Metric  = "FreeStorageSpace"
  })
}

resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  alarm_name          = "${local.name_prefix}-rds-connections-high"
  alarm_description   = "RDS DatabaseConnections is approaching the safe app connection budget for the dev PostgreSQL instance."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 60
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = local.rds_instance_id
  }

  alarm_actions = local.rds_alarm_actions
  ok_actions    = local.rds_alarm_actions

  tags = merge(local.common_tags, {
    Purpose = "rds-monitoring"
    Metric  = "DatabaseConnections"
  })
}

resource "aws_cloudwatch_metric_alarm" "rds_freeable_memory_low" {
  alarm_name          = "${local.name_prefix}-rds-freeable-memory-low"
  alarm_description   = "RDS FreeableMemory is low for the dev PostgreSQL instance."
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 104857600
  comparison_operator = "LessThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = local.rds_instance_id
  }

  alarm_actions = local.rds_alarm_actions
  ok_actions    = local.rds_alarm_actions

  tags = merge(local.common_tags, {
    Purpose = "rds-monitoring"
    Metric  = "FreeableMemory"
  })
}
