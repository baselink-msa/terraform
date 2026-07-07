locals {
  cloudfront_waf_name = "${local.name_prefix}-cloudfront-web-acl"
  api_alb_waf_name    = "${local.name_prefix}-api-alb-web-acl"

  cloudfront_waf_log_group_name = "aws-waf-logs-${local.name_prefix}-cloudfront"
  api_alb_waf_log_group_name    = "aws-waf-logs-${local.name_prefix}-api-alb"
}

resource "aws_cloudwatch_log_group" "waf_cloudfront" {
  provider = aws.use1

  name              = local.cloudfront_waf_log_group_name
  retention_in_days = var.waf_log_retention_days

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "waf_api_alb" {
  name              = local.api_alb_waf_log_group_name
  retention_in_days = var.waf_log_retention_days

  tags = local.common_tags
}

resource "aws_wafv2_web_acl" "cloudfront" {
  provider = aws.use1

  name        = local.cloudfront_waf_name
  description = "WAF web ACL for the Baselink dev CloudFront distribution. All rules enforce block mode."
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "AWS-AWSManagedRulesAmazonIpReputationList"
    priority = 0

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.cloudfront_waf_name}-amazon-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesAnonymousIpList"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAnonymousIpList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.cloudfront_waf_name}-anonymous-ip"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }

        rule_action_override {
          name = "NoUserAgent_HEADER"
          action_to_use {
            count {}
          }
        }

        rule_action_override {
          name = "CrossSiteScripting_COOKIE"
          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.cloudfront_waf_name}-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.cloudfront_waf_name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "GlobalRateBasedRule"
    priority = 4

    action {
      block {}
    }

    statement {
      rate_based_statement {
        aggregate_key_type = "IP"
        limit              = var.waf_rate_limit
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.cloudfront_waf_name}-global-rate"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "GeoRule"
    priority = 5

    action {
      block {}
    }

    statement {
      not_statement {
        statement {
          geo_match_statement {
            country_codes = ["KR"]
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.cloudfront_waf_name}-non-kr-geo"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "BodySizeRestrictionRule"
    priority = 6

    action {
      block {}
    }

    statement {
      size_constraint_statement {
        comparison_operator = "GT"
        size                = 16384

        field_to_match {
          body {
            oversize_handling = "MATCH"
          }
        }

        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.cloudfront_waf_name}-body-size"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.cloudfront_waf_name
    sampled_requests_enabled   = true
  }

  tags = local.common_tags
}

resource "aws_wafv2_web_acl" "api_alb" {
  name        = local.api_alb_waf_name
  description = "Regional WAF web ACL for the Baselink dev API ALB. All rules enforce block mode."
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWS-AWSManagedRulesAmazonIpReputationList"
    priority = 0

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.api_alb_waf_name}-amazon-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.api_alb_waf_name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesSQLiRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.api_alb_waf_name}-sqli"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesAdminProtectionRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAdminProtectionRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.api_alb_waf_name}-admin-protection"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }

        rule_action_override {
          name = "NoUserAgent_HEADER"
          action_to_use {
            count {}
          }
        }

        rule_action_override {
          name = "CrossSiteScripting_COOKIE"
          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.api_alb_waf_name}-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "GlobalRateBasedRule"
    priority = 5

    action {
      block {}
    }

    statement {
      rate_based_statement {
        aggregate_key_type = "IP"
        limit              = var.waf_rate_limit
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.api_alb_waf_name}-global-rate"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "BodySizeRestrictionRule"
    priority = 6

    action {
      block {}
    }

    statement {
      size_constraint_statement {
        comparison_operator = "GT"
        size                = 16384

        field_to_match {
          body {
            oversize_handling = "MATCH"
          }
        }

        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.api_alb_waf_name}-body-size"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.api_alb_waf_name
    sampled_requests_enabled   = true
  }

  tags = local.common_tags
}

resource "aws_wafv2_web_acl_logging_configuration" "cloudfront" {
  provider = aws.use1

  log_destination_configs = [aws_cloudwatch_log_group.waf_cloudfront.arn]
  resource_arn            = aws_wafv2_web_acl.cloudfront.arn
}

resource "aws_wafv2_web_acl_logging_configuration" "api_alb" {
  log_destination_configs = [aws_cloudwatch_log_group.waf_api_alb.arn]
  resource_arn            = aws_wafv2_web_acl.api_alb.arn
}

import {
  to = aws_cloudwatch_log_group.waf_cloudfront
  id = "aws-waf-logs-baselink-dev-cloudfront"
}

import {
  to = aws_cloudwatch_log_group.waf_api_alb
  id = "aws-waf-logs-baselink-dev-api-alb"
}

import {
  to = aws_wafv2_web_acl.cloudfront
  id = "e03b407b-c939-499e-bb50-0c040a1f22ce/baselink-dev-cloudfront-web-acl/CLOUDFRONT"
}

import {
  to = aws_wafv2_web_acl.api_alb
  id = "95e3485a-2e19-4941-8fbf-d2cd7bbb4f47/baselink-dev-api-alb-web-acl/REGIONAL"
}

import {
  to = aws_wafv2_web_acl_logging_configuration.cloudfront
  id = "arn:aws:wafv2:us-east-1:740831361032:global/webacl/baselink-dev-cloudfront-web-acl/e03b407b-c939-499e-bb50-0c040a1f22ce"
}

import {
  to = aws_wafv2_web_acl_logging_configuration.api_alb
  id = "arn:aws:wafv2:ap-northeast-2:740831361032:regional/webacl/baselink-dev-api-alb-web-acl/95e3485a-2e19-4941-8fbf-d2cd7bbb4f47"
}
