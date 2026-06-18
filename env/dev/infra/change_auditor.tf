# ────────────────────────────────────────────────────────────────────
# AWS 변경 추적 및 감사 알림 시스템 (개인 프로젝트)
#
# CloudTrail 변경 이벤트 → EventBridge → SQS → Lambda
# → AI 요약(Bedrock Claude) + 위험도 분류 → Slack 알림
# ────────────────────────────────────────────────────────────────────

module "change_auditor" {
  source = "../../../modules/change-auditor"

  project_name       = "change-auditor"
  environment        = var.environment
  aws_region         = var.aws_region
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_app_subnet_ids
  slack_webhook_url  = var.change_auditor_slack_webhook_url

  bedrock_model_id = "anthropic.claude-3-haiku-20240307-v1:0"
  bedrock_region   = "ap-northeast-2"

  log_retention_days    = 14
  dynamodb_billing_mode = "PAY_PER_REQUEST"

  tags = local.common_tags
}
