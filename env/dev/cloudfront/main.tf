locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

import {
  to = module.cloudfront.aws_cloudfront_distribution.frontend
  id = var.cloudfront_distribution_id
}

import {
  to = module.cloudfront.aws_s3_bucket.frontend
  id = var.cloudfront_frontend_bucket_name
}

import {
  to = module.cloudfront.aws_s3_bucket_public_access_block.frontend
  id = var.cloudfront_frontend_bucket_name
}

import {
  to = module.cloudfront.aws_cloudfront_origin_access_control.frontend_s3
  id = var.cloudfront_frontend_oac_id
}

module "cloudfront" {
  source = "../../../modules/cloudfront"

  aws_region                   = var.aws_region
  distribution_comment         = "BaseLink frontend distribution"
  frontend_bucket_name         = var.cloudfront_frontend_bucket_name
  frontend_oac_name            = var.cloudfront_frontend_oac_name
  frontend_oac_description     = "BaseLink frontend S3 OAC"
  api_origin_domain_name       = var.cloudfront_api_origin_domain_name
  origin_verify_header_name    = var.cloudfront_origin_verify_header_name
  origin_verify_header_value   = var.cloudfront_origin_verify_header_value
  frontend_cache_policy_id     = var.cloudfront_frontend_cache_policy_id
  api_cache_policy_id          = var.cloudfront_api_cache_policy_id
  api_origin_request_policy_id = var.cloudfront_api_origin_request_policy_id
  web_acl_arn                  = data.terraform_remote_state.infra.outputs.cloudfront_waf_web_acl_arn
  tags                         = local.common_tags
}
