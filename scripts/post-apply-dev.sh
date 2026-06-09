#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_DIR="$TERRAFORM_ROOT/env/dev"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[POST]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

elapsed() {
  local start=$1
  local end
  end=$(date +%s)
  echo "$(( end - start ))초"
}

REGION="${AWS_REGION:-ap-northeast-2}"
TOTAL_START=$(date +%s)

log "AWS 인증 확인 중..."
if ! aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1; then
  err "AWS 인증을 찾을 수 없습니다."
fi

log "kubeconfig 업데이트 중..."
CLUSTER_NAME=$(cd "$ENV_DIR/infra" && terraform output -raw eks_cluster_name 2>/dev/null || echo "")

if [ -n "$CLUSTER_NAME" ]; then
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias "$CLUSTER_NAME"
else
  warn "cluster_name output을 못 읽었어요. 수동으로 kubeconfig 설정하세요."
fi

log "backend-secret 확인 중..."
kubectl create namespace baselink-dev 2>/dev/null || true

if ! kubectl get secret backend-secret -n baselink-dev >/dev/null 2>&1; then
  log "backend-secret 생성 중..."
  RDS_SECRET_ARN=$(aws rds describe-db-instances --db-instance-identifier baselink-dev-postgres --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text 2>/dev/null || echo "")
  if [ -n "$RDS_SECRET_ARN" ] && [ "$RDS_SECRET_ARN" != "None" ]; then
    RDS_CREDS=$(aws secretsmanager get-secret-value --secret-id "$RDS_SECRET_ARN" --query 'SecretString' --output text)
    DB_USER=$(echo "$RDS_CREDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
    DB_PASS=$(echo "$RDS_CREDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")
  else
    DB_USER="baseball"
    DB_PASS="baseball"
    warn "Secrets Manager에서 RDS 비밀번호를 못 찾았어요. 기본값 사용."
  fi
  kubectl create secret generic backend-secret -n baselink-dev \
    --from-literal=SPRING_DATASOURCE_USERNAME="$DB_USER" \
    --from-literal=SPRING_DATASOURCE_PASSWORD="$DB_PASS" \
    --from-literal=APP_JWT_SECRET="$(openssl rand -base64 48)"
  log "backend-secret 생성 완료"
else
  log "backend-secret 이미 존재"
fi

log "Argo CD git-ops sync 대기 중..."
STEP_START=$(date +%s)
SYNC_STATUS=""
for i in $(seq 1 30); do
  SYNC_STATUS=$(kubectl get application baselink-app -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
  if [ "$SYNC_STATUS" = "Synced" ]; then break; fi
  sleep 10
done

if [ "$SYNC_STATUS" = "Synced" ]; then
  log "Argo CD sync 완료 ($(elapsed "$STEP_START"))"
else
  warn "Argo CD sync 지연. 확인: kubectl get application baselink-app -n argocd"
fi

log "API ALB 직접 접근 차단 annotation 적용 중..."
CF_DIST_ID=$(cd "$ENV_DIR/infra" && terraform output -raw cloudfront_distribution_id 2>/dev/null || echo "E1L0BJIJOTT0R6")
CF_WAF_ARN=$(cd "$ENV_DIR/infra" && terraform output -raw cloudfront_waf_web_acl_arn 2>/dev/null || echo "")
API_ALB_WAF_ARN=$(cd "$ENV_DIR/infra" && terraform output -raw api_alb_waf_web_acl_arn 2>/dev/null || echo "")
ORIGIN_HEADER_NAME="${CF_ORIGIN_VERIFY_HEADER_NAME:-X-Origin-Verify}"
ORIGIN_HEADER_VALUE="${CF_ORIGIN_VERIFY_HEADER_VALUE:-}"

CF_PREFIX_LIST_ID=$(aws ec2 describe-managed-prefix-lists \
  --region "$REGION" \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].PrefixListId' \
  --output text 2>/dev/null || echo "")

if [ -n "$CF_PREFIX_LIST_ID" ] && [ "$CF_PREFIX_LIST_ID" != "None" ]; then
  kubectl annotate ingress baselink-api -n baselink-dev \
    "alb.ingress.kubernetes.io/security-group-prefix-lists=$CF_PREFIX_LIST_ID" \
    --overwrite >/dev/null
  log "ALB ingress source를 CloudFront managed prefix list로 제한: $CF_PREFIX_LIST_ID"
else
  warn "CloudFront managed prefix list ID를 못 읽었습니다. ALB SG 제한 annotation을 건너뜁니다."
fi

if [ -n "$API_ALB_WAF_ARN" ]; then
  kubectl annotate ingress baselink-api -n baselink-dev \
    "alb.ingress.kubernetes.io/wafv2-acl-arn=$API_ALB_WAF_ARN" \
    --overwrite >/dev/null
  log "API ALB WAF 연결 annotation 적용: $API_ALB_WAF_ARN"
else
  warn "API ALB WAF ARN을 못 읽었습니다. WAF annotation을 건너뜁니다."
fi

if [ -z "$ORIGIN_HEADER_VALUE" ]; then
  CF_CONFIG_FOR_HEADER=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --output json 2>/dev/null || echo "")
  if [ -n "$CF_CONFIG_FOR_HEADER" ]; then
    ORIGIN_HEADER_VALUE=$(echo "$CF_CONFIG_FOR_HEADER" | ORIGIN_HEADER_NAME="$ORIGIN_HEADER_NAME" python3 -c "
import json, os, sys
try:
    config = json.load(sys.stdin)['DistributionConfig']
except Exception:
    print('')
    raise SystemExit
header_name = os.environ['ORIGIN_HEADER_NAME'].lower()
for origin in config.get('Origins', {}).get('Items', []):
    if 'elb.amazonaws.com' not in origin.get('DomainName', '') and origin.get('Id', '') != 'api':
        continue
    for header in origin.get('CustomHeaders', {}).get('Items', []):
        if header.get('HeaderName', '').lower() == header_name:
            print(header.get('HeaderValue', ''))
            raise SystemExit
print('')
")
  fi
fi

if [ -n "$ORIGIN_HEADER_VALUE" ]; then
  CONDITION_JSON=$(ORIGIN_HEADER_NAME="$ORIGIN_HEADER_NAME" ORIGIN_HEADER_VALUE="$ORIGIN_HEADER_VALUE" python3 -c "
import json, os
print(json.dumps([{
    'field': 'http-header',
    'httpHeaderConfig': {
        'httpHeaderName': os.environ['ORIGIN_HEADER_NAME'],
        'values': [os.environ['ORIGIN_HEADER_VALUE']]
    }
}], separators=(',', ':')))
")
  for svc in auth-service game-service admin-service waiting-room-service ai-chatbot-service order-service seat-lock-service ticket-service; do
    kubectl annotate ingress baselink-api -n baselink-dev \
      "alb.ingress.kubernetes.io/conditions.$svc=$CONDITION_JSON" \
      --overwrite >/dev/null
  done
  log "CloudFront origin custom header 조건을 API ALB rule에 적용"
else
  warn "CloudFront ALB origin에서 $ORIGIN_HEADER_NAME custom header 값을 못 읽었습니다. header 조건 annotation을 건너뜁니다."
fi

log "auth-service 대기 중 (DB 마이그레이션 자동 실행)..."
set +e
kubectl rollout status deploy/auth-service -n baselink-dev --timeout=180s 2>/dev/null
if [ $? -eq 0 ]; then
  log "auth-service Ready - DB 마이그레이션 완료"
else
  warn "auth-service 시작 지연. 로그 확인: kubectl logs deploy/auth-service -n baselink-dev"
fi
set -e

log "CloudFront origin Terraform 반영 중..."
ALB_HOST=""
for i in $(seq 1 18); do
  ALB_HOST=$(kubectl get ingress baselink-api -n baselink-dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [ -n "$ALB_HOST" ]; then break; fi
  sleep 10
done

if [ -n "$ALB_HOST" ]; then
  if [ -n "$ORIGIN_HEADER_VALUE" ]; then
    export TF_VAR_cloudfront_api_origin_domain_name="$ALB_HOST"
    export TF_VAR_cloudfront_origin_verify_header_name="$ORIGIN_HEADER_NAME"
    export TF_VAR_cloudfront_origin_verify_header_value="$ORIGIN_HEADER_VALUE"

    (
      cd "$ENV_DIR/cloudfront"
      terraform init -input=false -no-color > /dev/null 2>&1
      terraform apply -auto-approve -input=false
    )
    CF_DOMAIN=$(cd "$ENV_DIR/cloudfront" && terraform output -raw cloudfront_distribution_domain_name 2>/dev/null || echo "")
    if [ -n "$CF_DOMAIN" ]; then
      (
        cd "$ENV_DIR/infra"
        terraform init -input=false -no-color > /dev/null 2>&1
        TF_VAR_cloudfront_distribution_domain_name="$CF_DOMAIN" terraform apply -auto-approve -input=false
      )
      log "Lambda GAME_API_URL CloudFront domain 반영 완료: $CF_DOMAIN"
    else
      warn "CloudFront domain output을 못 읽었습니다. Lambda GAME_API_URL 재반영을 건너뜁니다."
    fi
    log "CloudFront origin Terraform 반영 완료: $ALB_HOST"
  else
    warn "CloudFront origin custom header 값을 못 읽었습니다. Terraform CloudFront 반영을 건너뜁니다."
  fi
else
  warn "ALB 주소를 가져올 수 없습니다. CloudFront origin을 수동으로 업데이트하세요."
fi

log "후처리 완료! 총 소요시간: $(elapsed "$TOTAL_START")"
