#!/bin/bash
set -e

###############################################################################
# infra-down.sh — 개발 환경 전체 내리기 (ECR 제외)
# 순서: git-ops 삭제 → addon destroy → infra destroy
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GITOPS_ROOT="$(cd "$TERRAFORM_ROOT/../baselink-gitops" && pwd)"

ENV_DIR="$TERRAFORM_ROOT/env/dev"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[DOWN]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

elapsed() {
  local start=$1
  local end=$(date +%s)
  echo "$(( end - start ))초"
}

TOTAL_START=$(date +%s)

###############################################################################
# 1. git-ops — kubectl delete
###############################################################################
log "1/3 git-ops 서비스 내리는 중..."
STEP_START=$(date +%s)
cd "$GITOPS_ROOT"
kubectl delete -k overlays/dev --ignore-not-found=true 2>/dev/null || warn "kubectl delete 일부 실패 (무시)"
log "    git-ops 삭제 완료 ($(elapsed $STEP_START))"

###############################################################################
# 2. Terraform — addon destroy
###############################################################################
log "2/3 Terraform addon destroy 시작..."
STEP_START=$(date +%s)
cd "$ENV_DIR/addon"
terraform init -input=false -no-color > /dev/null 2>&1
terraform destroy -auto-approve -input=false
log "    addon destroy 완료 ($(elapsed $STEP_START))"

###############################################################################
# 3. Terraform — infra destroy
###############################################################################
log "3/3 Terraform infra destroy 시작..."
STEP_START=$(date +%s)
cd "$ENV_DIR/infra"
terraform init -input=false -no-color > /dev/null 2>&1
terraform destroy -auto-approve -input=false
log "    infra destroy 완료 ($(elapsed $STEP_START))"

###############################################################################
echo ""
log "========================================="
log " 전체 내리기 완료! 총 소요시간: $(elapsed $TOTAL_START)"
log " ECR은 유지됩니다."
log "========================================="
