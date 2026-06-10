locals {
  valkey_alarm_actions = var.enable_slack_alerts ? [aws_sns_topic.ops_alerts[0].arn] : []
  valkey_cache_cluster_ids = [
    for index in range(var.elasticache.num_cache_clusters) :
    format("%s-redis-%03d", var.elasticache.name, index + 1)
  ]
  valkey_replica_cache_cluster_ids = length(local.valkey_cache_cluster_ids) > 1 ? slice(local.valkey_cache_cluster_ids, 1, length(local.valkey_cache_cluster_ids)) : []
}

resource "aws_cloudwatch_metric_alarm" "valkey_engine_cpu_high" {
  for_each = toset(local.valkey_cache_cluster_ids)

  alarm_name          = "${each.value}-engine-cpu-high"
  alarm_description   = "Valkey EngineCPUUtilization is high for cache cluster ${each.value}."
  namespace           = "AWS/ElastiCache"
  metric_name         = "EngineCPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 80
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    CacheClusterId = each.value
  }

  alarm_actions = local.valkey_alarm_actions
  ok_actions    = local.valkey_alarm_actions

  tags = merge(local.common_tags, {
    Purpose = "valkey-monitoring"
    Metric  = "EngineCPUUtilization"
  })
}

resource "aws_cloudwatch_metric_alarm" "valkey_memory_high" {
  for_each = toset(local.valkey_cache_cluster_ids)

  alarm_name          = "${each.value}-memory-high"
  alarm_description   = "Valkey DatabaseMemoryUsagePercentage is high for cache cluster ${each.value}."
  namespace           = "AWS/ElastiCache"
  metric_name         = "DatabaseMemoryUsagePercentage"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 80
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    CacheClusterId = each.value
  }

  alarm_actions = local.valkey_alarm_actions
  ok_actions    = local.valkey_alarm_actions

  tags = merge(local.common_tags, {
    Purpose = "valkey-monitoring"
    Metric  = "DatabaseMemoryUsagePercentage"
  })
}

resource "aws_cloudwatch_metric_alarm" "valkey_evictions_detected" {
  for_each = toset(local.valkey_cache_cluster_ids)

  alarm_name          = "${each.value}-evictions-detected"
  alarm_description   = "Valkey Evictions were detected for cache cluster ${each.value}."
  namespace           = "AWS/ElastiCache"
  metric_name         = "Evictions"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    CacheClusterId = each.value
  }

  alarm_actions = local.valkey_alarm_actions
  ok_actions    = local.valkey_alarm_actions

  tags = merge(local.common_tags, {
    Purpose = "valkey-monitoring"
    Metric  = "Evictions"
  })
}

resource "aws_cloudwatch_metric_alarm" "valkey_replication_lag_high" {
  for_each = toset(local.valkey_replica_cache_cluster_ids)

  alarm_name          = "${each.value}-replication-lag-high"
  alarm_description   = "Valkey ReplicationLag is high for replica cache cluster ${each.value}."
  namespace           = "AWS/ElastiCache"
  metric_name         = "ReplicationLag"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    CacheClusterId = each.value
  }

  alarm_actions = local.valkey_alarm_actions
  ok_actions    = local.valkey_alarm_actions

  tags = merge(local.common_tags, {
    Purpose = "valkey-monitoring"
    Metric  = "ReplicationLag"
  })
}
