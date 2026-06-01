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
# 5. git-ops — kubectl apply
###############################################################################
log "4/4 git-ops apply 시작..."
STEP_START=$(date +%s)
cd "$GITOPS_ROOT"
kubectl apply -k overlays/dev
log "    git-ops 완료 ($(elapsed $STEP_START))"

###############################################################################
echo ""
log "========================================="
log " 전체 완료! 총 소요시간: $(elapsed $TOTAL_START)"
log "========================================="
