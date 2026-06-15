locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
  }
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
  grafana_origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"  # AllViewer
  web_acl_arn                  = data.terraform_remote_state.infra.outputs.cloudfront_waf_web_acl_arn
  grafana_origin_domain_name   = "k8s-baselinkmonitorin-4e1b0881bd-1178469240.ap-northeast-2.elb.amazonaws.com"
  tags                         = local.common_tags
}