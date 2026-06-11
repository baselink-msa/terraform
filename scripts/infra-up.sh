#!/bin/bash
set -e

###############################################################################
# infra-up.sh — 개발 환경 전체 올리기
# 순서: infra → ecr → addon → kubeconfig → git-ops apply
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -d "$TERRAFORM_ROOT/../gitops" ]; then
  GITOPS_ROOT="$(cd "$TERRAFORM_ROOT/../gitops" && pwd)"
elif [ -d "$TERRAFORM_ROOT/../baselink-gitops" ]; then
  GITOPS_ROOT="$(cd "$TERRAFORM_ROOT/../baselink-gitops" && pwd)"
else
  echo "[ERR] gitops repository not found next to terraform repository."
  exit 1
fi

ENV_DIR="$TERRAFORM_ROOT/env/dev"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[UP]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

elapsed() {
  local start=$1
  local end=$(date +%s)
  echo "$(( end - start ))초"
}

TOTAL_START=$(date +%s)
REGION="ap-northeast-2"
CF_DIST_ID="${TF_VAR_cloudfront_distribution_id:-E1L0BJIJOTT0R6}"

###############################################################################
# 0. AWS 인증 확인
###############################################################################
log "    AWS 인증 확인 중..."
if ! aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1; then
  err "AWS 인증을 찾을 수 없습니다. aws configure, aws sso login, 또는 AWS_PROFILE 환경변수를 설정한 뒤 다시 실행하세요."
fi

###############################################################################
# 0.5. CloudFront import/apply용 현재 origin 설정 읽기
###############################################################################
log "    CloudFront 현재 origin 설정 확인 중..."
CF_CONFIG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --output json 2>/dev/null || echo "")
if [ -n "$CF_CONFIG" ]; then
  if [ -z "${TF_VAR_cloudfront_origin_verify_header_value:-}" ]; then
    export TF_VAR_cloudfront_origin_verify_header_value=$(echo "$CF_CONFIG" | python3 -c "
import json, sys
config = json.load(sys.stdin)['DistributionConfig']
for origin in config.get('Origins', {}).get('Items', []):
    if 'elb.amazonaws.com' not in origin.get('DomainName', '') and origin.get('Id', '') != 'baselink-dev-api-alb':
        continue
    for header in origin.get('CustomHeaders', {}).get('Items', []):
        if header.get('HeaderName', '').lower() == 'x-origin-verify':
            print(header.get('HeaderValue', ''))
            raise SystemExit
print('')
")
  fi

  if [ -z "${TF_VAR_cloudfront_api_origin_domain_name:-}" ]; then
    export TF_VAR_cloudfront_api_origin_domain_name=$(echo "$CF_CONFIG" | python3 -c "
import json, sys
config = json.load(sys.stdin)['DistributionConfig']
for origin in config.get('Origins', {}).get('Items', []):
    if 'elb.amazonaws.com' in origin.get('DomainName', '') or origin.get('Id', '') == 'baselink-dev-api-alb':
        print(origin.get('DomainName', ''))
        raise SystemExit
print('')
")
  fi
else
  warn "CloudFront 현재 설정을 읽지 못했습니다. TF_VAR_cloudfront_origin_verify_header_value가 필요할 수 있습니다."
fi

if [ -z "${TF_VAR_cloudfront_origin_verify_header_value:-}" ]; then
  err "CloudFront origin custom header 값을 찾지 못했습니다. CF_ORIGIN_VERIFY_HEADER_VALUE 또는 TF_VAR_cloudfront_origin_verify_header_value를 설정하세요."
fi

###############################################################################
# 1. Terraform — infra
###############################################################################
log "1/4 Terraform infra apply 시작..."
STEP_START=$(date +%s)
cd "$ENV_DIR/infra"
terraform init -input=false -no-color > /dev/null 2>&1
terraform apply -auto-approve -input=false
log "    infra 완료 ($(elapsed $STEP_START))"

###############################################################################
# 2. Terraform — ecr
###############################################################################
log "2/4 Terraform ecr apply 시작..."
STEP_START=$(date +%s)
cd "$ENV_DIR/ecr"
terraform init -input=false -no-color > /dev/null 2>&1
terraform apply -auto-approve -input=false
log "    ecr 완료 ($(elapsed $STEP_START))"

###############################################################################
# 3. Terraform — addon
###############################################################################
log "3/4 Terraform addon apply 시작..."
STEP_START=$(date +%s)
cd "$ENV_DIR/addon"
terraform init -input=false -no-color > /dev/null 2>&1
terraform apply -auto-approve -input=false
log "    addon 완료 ($(elapsed $STEP_START))"

###############################################################################
# 4. Terraform 이후 후처리
###############################################################################
log "4/4 Terraform 이후 후처리 시작..."
"$SCRIPT_DIR/post-apply-dev.sh"

###############################################################################
echo ""
log "========================================="
log " 전체 완료! 총 소요시간: $(elapsed $TOTAL_START)"
log "========================================="
