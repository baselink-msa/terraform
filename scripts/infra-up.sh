#!/bin/bash
set -e

###############################################################################
# infra-up.sh — 개발 환경 전체 올리기
# 순서: infra → ecr → addon → kubeconfig → git-ops apply
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GITOPS_ROOT="$(cd "$TERRAFORM_ROOT/../baselink-gitops" && pwd)"

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
# 4. kubeconfig 업데이트
###############################################################################
log "    kubeconfig 업데이트 중..."
CLUSTER_NAME=$(cd "$ENV_DIR/infra" && terraform output -raw eks_cluster_name 2>/dev/null || echo "")
REGION="ap-northeast-2"

if [ -n "$CLUSTER_NAME" ]; then
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias "$CLUSTER_NAME"
else
  warn "cluster_name output을 못 읽었어요. 수동으로 kubeconfig 설정하세요."
fi

###############################################################################
# 4.5. backend-secret 생성 (없으면)
###############################################################################
log "    backend-secret 확인 중..."
# 네임스페이스가 없을 수 있으므로 먼저 생성
kubectl create namespace baselink-dev 2>/dev/null || true

if ! kubectl get secret backend-secret -n baselink-dev >/dev/null 2>&1; then
  log "    backend-secret 생성 중..."
  RDS_SECRET_ARN=$(aws secretsmanager list-secrets --query 'SecretList[?contains(Name,`rds`)].ARN' --output text | head -1)
  if [ -n "$RDS_SECRET_ARN" ]; then
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
  log "    backend-secret 생성 완료"
else
  log "    backend-secret 이미 존재"
fi

###############################################################################
# 5. git-ops — kubectl apply
###############################################################################
log "5/6 git-ops apply 시작..."
STEP_START=$(date +%s)
cd "$GITOPS_ROOT"
kubectl apply -k overlays/dev
log "    git-ops 완료 ($(elapsed $STEP_START))"

###############################################################################
# 5.5. auth-service Ready 대기 (Flyway DB 마이그레이션 자동 실행)
###############################################################################
log "    auth-service 대기 중 (DB 마이그레이션 자동 실행)..."
set +e
kubectl rollout status deploy/auth-service -n baselink-dev --timeout=180s 2>/dev/null
if [ $? -eq 0 ]; then
  log "    auth-service Ready — DB 마이그레이션 완료"
else
  warn "auth-service 시작 지연. 로그 확인: kubectl logs deploy/auth-service -n baselink-dev"
fi
set -e

###############################################################################
# 7. CloudFront ALB origin 업데이트
###############################################################################
log "    CloudFront origin 업데이트 중..."
CF_DIST_ID="E1L0BJIJOTT0R6"

# Ingress가 ALB를 프로비저닝할 때까지 대기 (최대 3분)
ALB_HOST=""
for i in $(seq 1 18); do
  ALB_HOST=$(kubectl get ingress baselink-api -n baselink-dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [ -n "$ALB_HOST" ]; then break; fi
  sleep 10
done

if [ -n "$ALB_HOST" ]; then
  # 현재 CloudFront 설정 가져오기
  CF_CONFIG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --output json)
  ETAG=$(echo "$CF_CONFIG" | python3 -c "import sys,json; print(json.load(sys.stdin)['ETag'])")
  
  # ALB origin 도메인 업데이트
  UPDATED_CONFIG=$(echo "$CF_CONFIG" | python3 -c "
import sys, json
config = json.load(sys.stdin)
dist_config = config['DistributionConfig']
for origin in dist_config['Origins']['Items']:
    if 'elb.amazonaws.com' in origin.get('DomainName', '') or origin.get('Id','') == 'api':
        origin['DomainName'] = '$ALB_HOST'
        break
json.dump(dist_config, sys.stdout)
")
  
  echo "$UPDATED_CONFIG" > /tmp/cf-update.json
  aws cloudfront update-distribution --id "$CF_DIST_ID" --if-match "$ETAG" --distribution-config file:///tmp/cf-update.json > /dev/null 2>&1
  rm -f /tmp/cf-update.json
  log "    CloudFront origin 업데이트 완료: $ALB_HOST"
else
  warn "ALB 주소를 가져올 수 없습니다. CloudFront origin을 수동으로 업데이트하세요."
fi

###############################################################################
echo ""
log "========================================="
log " 전체 완료! 총 소요시간: $(elapsed $TOTAL_START)"
log "========================================="
