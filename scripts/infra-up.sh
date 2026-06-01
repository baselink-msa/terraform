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
# 5. DB 마이그레이션 (seed-dev.sql 직접 실행)
###############################################################################
log "4.5/5 DB 시드 실행 중..."
STEP_START=$(date +%s)
cd "$GITOPS_ROOT"

# ConfigMap(backend-config)을 먼저 apply (서비스가 참조함)
kubectl apply -f base/namespace.yaml -f base/configmap.yaml 2>/dev/null || true

# 기존 리소스 정리
kubectl delete configmap seed-sql -n baselink-dev --ignore-not-found=true 2>/dev/null
kubectl delete pod psql-seed-run -n baselink-dev --ignore-not-found=true 2>/dev/null

# seed SQL을 ConfigMap으로 생성
kubectl create configmap seed-sql \
  --from-file=seed-dev.sql="$GITOPS_ROOT/db/seed-dev.sql" \
  -n baselink-dev

# psql Pod로 seed 실행 (amd64 노드에서, backend-secret의 비밀번호 사용)
RDS_HOST=$(cd "$ENV_DIR/infra" && terraform output -raw rds_endpoint 2>/dev/null | cut -d: -f1 || echo "")
if [ -z "$RDS_HOST" ]; then
  warn "RDS 호스트를 못 읽었어요. DB 시드를 수동으로 실행하세요."
else
  kubectl run psql-seed-run --rm -i --restart=Never -n baselink-dev \
    --overrides="{
      \"spec\": {
        \"nodeSelector\": {\"kubernetes.io/arch\": \"amd64\"},
        \"containers\": [{
          \"name\": \"psql\",
          \"image\": \"postgres:16-alpine\",
          \"command\": [\"sh\", \"-c\", \"psql -h $RDS_HOST -U baseball -d baseball_platform -f /sql/seed-dev.sql\"],
          \"env\": [
            {\"name\": \"PGPASSWORD\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"backend-secret\", \"key\": \"SPRING_DATASOURCE_PASSWORD\"}}}
          ],
          \"volumeMounts\": [{\"name\": \"sql\", \"mountPath\": \"/sql\"}]
        }],
        \"volumes\": [{\"name\": \"sql\", \"configMap\": {\"name\": \"seed-sql\"}}]
      }
    }" --image=postgres:16-alpine 2>&1 | tail -5

  if [ $? -eq 0 ]; then
    log "    DB 시드 완료 ($(elapsed $STEP_START))"
  else
    warn "DB 시드 실행 중 일부 오류 발생. 로그를 확인하세요."
  fi
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
