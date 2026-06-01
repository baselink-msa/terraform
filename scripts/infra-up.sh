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
    --from-literal=APP_JWT_SECRET="baselink-dev-jwt-secret-key-2026-minimum-32-bytes-long"
  log "    backend-secret 생성 완료"
else
  log "    backend-secret 이미 존재"
fi

###############################################################################
# 5. DB 마이그레이션 (Flyway Job)
###############################################################################
log "4.5/5 DB 마이그레이션 실행 중..."
STEP_START=$(date +%s)
cd "$GITOPS_ROOT"

# ConfigMap(backend-config)을 먼저 apply (Flyway Job이 참조함)
kubectl apply -k overlays/dev --selector='app notin (admin-service,auth-service,game-service,order-service,ai-chatbot-service,seat-lock-service,ticket-service,ticket-worker-service,waiting-room-service)' 2>/dev/null || kubectl apply -f base/namespace.yaml -f base/configmap.yaml 2>/dev/null || true

# 기존 Job/ConfigMap 정리
kubectl delete job db-migration -n baselink-dev --ignore-not-found=true 2>/dev/null
kubectl delete configmap flyway-sql -n baselink-dev --ignore-not-found=true 2>/dev/null

# Flyway SQL ConfigMap 생성
kubectl create configmap flyway-sql \
  --from-file="$GITOPS_ROOT/db/flyway/sql" \
  -n baselink-dev

# Flyway Job 실행
kubectl apply -f "$GITOPS_ROOT/db/flyway/job.example.yaml"

# Job 완료 대기
if kubectl wait --for=condition=complete job/db-migration -n baselink-dev --timeout=240s 2>/dev/null; then
  log "    DB 마이그레이션 완료 ($(elapsed $STEP_START))"
  kubectl logs job/db-migration -n baselink-dev 2>/dev/null | tail -5
else
  warn "DB 마이그레이션 실패. 로그 확인:"
  kubectl logs job/db-migration -n baselink-dev 2>/dev/null | tail -20
fi

###############################################################################
# 6. git-ops — kubectl apply
###############################################################################
log "5/5 git-ops apply 시작..."
STEP_START=$(date +%s)
cd "$GITOPS_ROOT"
kubectl apply -k overlays/dev
log "    git-ops 완료 ($(elapsed $STEP_START))"

###############################################################################
echo ""
log "========================================="
log " 전체 완료! 총 소요시간: $(elapsed $TOTAL_START)"
log "========================================="
