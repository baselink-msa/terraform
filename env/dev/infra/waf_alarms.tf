locals {
  waf_regional_alarm_actions   = var.enable_slack_alerts ? [aws_sns_topic.ops_alerts[0].arn] : []
  waf_cloudfront_alarm_actions = var.enable_slack_alerts ? [aws_sns_topic.edge_ops_alerts[0].arn] : []

  cloudfront_waf_blocked_rules = {
    amazon_ip_reputation = {
      metric_name = "${local.cloudfront_waf_name}-amazon-ip-reputation"
      description = "CloudFront WAF Amazon IP reputation block detected."
    }
    anonymous_ip = {
      metric_name = "${local.cloudfront_waf_name}-anonymous-ip"
      description = "CloudFront WAF anonymous IP block detected."
    }
    common = {
      metric_name = "${local.cloudfront_waf_name}-common"
      description = "CloudFront WAF common rule block detected."
    }
    known_bad_inputs = {
      metric_name = "${local.cloudfront_waf_name}-known-bad-inputs"
      description = "CloudFront WAF known bad inputs block detected."
    }
    global_rate = {
      metric_name = "${local.cloudfront_waf_name}-global-rate"
      description = "CloudFront WAF rate based rule block detected."
    }
    non_kr_geo = {
      metric_name = "${local.cloudfront_waf_name}-non-kr-geo"
      description = "CloudFront WAF non-KR geo block detected."
    }
    body_size = {
      metric_name = "${local.cloudfront_waf_name}-body-size"
      description = "CloudFront WAF body size block detected."
    }
  }

  cloudfront_waf_counted_rules = {
    common_size_restrictions_body = {
      metric_name = "${local.cloudfront_waf_name}-common"
      description = "CloudFront WAF common rule SizeRestrictions_BODY counted."
    }
  }

  api_alb_waf_blocked_rules = {
    amazon_ip_reputation = {
      metric_name = "${local.api_alb_waf_name}-amazon-ip-reputation"
      description = "API ALB WAF Amazon IP reputation block detected."
    }
    known_bad_inputs = {
      metric_name = "${local.api_alb_waf_name}-known-bad-inputs"
      description = "API ALB WAF known bad inputs block detected."
    }
    sqli = {
      metric_name = "${local.api_alb_waf_name}-sqli"
      description = "API ALB WAF SQL injection block detected."
    }
    admin_protection = {
      metric_name = "${local.api_alb_waf_name}-admin-protection"
      description = "API ALB WAF admin protection block detected."
    }
    common = {
      metric_name = "${local.api_alb_waf_name}-common"
      description = "API ALB WAF common rule block detected."
    }
    global_rate = {
      metric_name = "${local.api_alb_waf_name}-global-rate"
      description = "API ALB WAF rate based rule block detected."
    }
    body_size = {
      metric_name = "${local.api_alb_waf_name}-body-size"
      description = "API ALB WAF body size block detected."
    }
  }

  api_alb_waf_counted_rules = {
    common_size_restrictions_body = {
      metric_name = "${local.api_alb_waf_name}-common"
      description = "API ALB WAF common rule SizeRestrictions_BODY counted."
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "cloudfront_waf_blocked_requests" {
  provider = aws.use1
  for_each = local.cloudfront_waf_blocked_rules

  alarm_name          = "${local.name_prefix}-cloudfront-waf-${each.key}-blocked"
  alarm_description   = each.value.description
  namespace           = "AWS/WAFV2"
  metric_name         = "BlockedRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = var.waf_blocked_requests_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = local.cloudfront_waf_name
    Rule   = each.value.metric_name
    Region = "Global"
  }

  alarm_actions = local.waf_cloudfront_alarm_actions
  ok_actions    = local.waf_cloudfront_alarm_actions

  tags = merge(local.common_tags, {
    Purpose = "waf-monitoring"
    Scope   = "cloudfront"
    Rule    = each.key
    Metric  = "BlockedRequests"
  })
}

resource "aws_cloudwatch_metric_alarm" "cloudfront_waf_counted_requests" {
  provider = aws.use1
  for_each = local.cloudfront_waf_counted_rules

  alarm_name          = "${local.name_prefix}-cloudfront-waf-${each.key}-counted"
  alarm_description   = each.value.description
  namespace           = "AWS/WAFV2"
  metric_name         = "CountedRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = var.waf_counted_requests_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = local.cloudfront_waf_name
    Rule   = each.value.metric_name
    Region = "Global"
  }

  alarm_actions = local.waf_cloudfront_alarm_actions
  ok_actions    = local.waf_cloudfront_alarm_actions

  tags = merge(local.common_tags, {
    Purpose = "waf-monitoring"
    Scope   = "cloudfront"
    Rule    = each.key
    Metric  = "CountedRequests"
  })
}

resource "aws_cloudwatch_metric_alarm" "api_alb_waf_blocked_requests" {
  for_each = local.api_alb_waf_blocked_rules

  alarm_name          = "${local.name_prefix}-api-alb-waf-${each.key}-blocked"
  alarm_description   = each.value.description
  namespace           = "AWS/WAFV2"
  metric_name         = "BlockedRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = var.waf_blocked_requests_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = local.api_alb_waf_name
    Rule   = each.value.metric_name
    Region = var.aws_region
  }

  alarm_actions = local.waf_regional_alarm_actions
  ok_actions    = local.waf_regional_alarm_actions

  tags = merge(local.common_tags, {
    Purpose = "waf-monitoring"
    Scope   = "api-alb"
    Rule    = each.key
    Metric  = "BlockedRequests"
  })
}

resource "aws_cloudwatch_metric_alarm" "api_alb_waf_counted_requests" {
  for_each = local.api_alb_waf_counted_rules

  alarm_name          = "${local.name_prefix}-api-alb-waf-${each.key}-counted"
  alarm_description   = each.value.description
  namespace           = "AWS/WAFV2"
  metric_name         = "CountedRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = var.waf_counted_requests_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = local.api_alb_waf_name
    Rule   = each.value.metric_name
    Region = var.aws_region
  }

  alarm_actions = local.waf_regional_alarm_actions
  ok_actions    = local.waf_regional_alarm_actions

  tags = merge(local.common_tags, {
    Purpose = "waf-monitoring"
    Scope   = "api-alb"
    Rule    = each.key
    Metric  = "CountedRequests"
  })
}
