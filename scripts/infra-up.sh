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

###############################################################################
# 0. AWS 인증 확인
###############################################################################
log "    AWS 인증 확인 중..."
if ! aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1; then
  err "AWS 인증을 찾을 수 없습니다. aws configure, aws sso login, 또는 AWS_PROFILE 환경변수를 설정한 뒤 다시 실행하세요."
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
