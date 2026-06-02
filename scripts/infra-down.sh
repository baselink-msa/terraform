#!/bin/bash
set -e

###############################################################################
# infra-down.sh — 개발 환경 전체 내리기 (ECR 제외)
# 순서: git-ops 삭제 → Karpenter 노드 정리 → addon destroy → infra destroy
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

log()  { echo -e "${GREEN}[DOWN]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

elapsed() {
  local start=$1
  local end=$(date +%s)
  echo "$(( end - start ))초"
}

# VPC 내 잔여 리소스 정리 함수
cleanup_vpc_resources() {
  local vpc_id=$1
  if [ -z "$vpc_id" ]; then return; fi

  log "    VPC 잔여 리소스 정리 중 ($vpc_id)..."

  # 1. 남은 EC2 인스턴스 강제 종료
  local instances=$(aws ec2 describe-instances \
    --filters "Name=vpc-id,Values=$vpc_id" "Name=instance-state-name,Values=running,pending,stopping,shutting-down" \
    --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null)
  if [ -n "$instances" ]; then
    log "    인스턴스 종료: $instances"
    aws ec2 terminate-instances --instance-ids $instances >/dev/null 2>&1
    # 종료 대기 (최대 90초)
    local count=0
    while [ $count -lt 18 ]; do
      local still=$(aws ec2 describe-instances --instance-ids $instances \
        --filters "Name=instance-state-name,Values=running,shutting-down,stopping" \
        --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null)
      if [ -z "$still" ]; then break; fi
      sleep 5
      count=$((count + 1))
    done
  fi

  # 2. EKS 보안그룹 삭제 (default 제외)
  local sgs=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null)
  for sg in $sgs; do
    # 먼저 인바운드/아웃바운드 규칙에서 다른 SG 참조 제거
    aws ec2 revoke-security-group-ingress --group-id "$sg" \
      --security-group-rule-ids $(aws ec2 describe-security-group-rules \
        --filters "Name=group-id,Values=$sg" \
        --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text 2>/dev/null) 2>/dev/null || true
    aws ec2 revoke-security-group-egress --group-id "$sg" \
      --security-group-rule-ids $(aws ec2 describe-security-group-rules \
        --filters "Name=group-id,Values=$sg" \
        --query 'SecurityGroupRules[?IsEgress].SecurityGroupRuleId' --output text 2>/dev/null) 2>/dev/null || true
    aws ec2 delete-security-group --group-id "$sg" 2>/dev/null && log "    SG 삭제: $sg"
  done

  # 3. 잔여 ENI 삭제
  local enis=$(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$vpc_id" "Name=status,Values=available" \
    --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null)
  for eni in $enis; do
    aws ec2 delete-network-interface --network-interface-id "$eni" 2>/dev/null && log "    ENI 삭제: $eni"
  done
}

TOTAL_START=$(date +%s)

###############################################################################
# 1. git-ops — kubectl delete
###############################################################################
log "1/3 git-ops 서비스 내리는 중..."
STEP_START=$(date +%s)
cd "$GITOPS_ROOT"
kubectl delete application baselink-app -n argocd --ignore-not-found=true 2>/dev/null || true
kubectl delete -k overlays/dev --ignore-not-found=true 2>/dev/null || warn "kubectl delete 일부 실패 (무시)"
log "    git-ops 삭제 완료 ($(elapsed $STEP_START))"

###############################################################################
# 1.5. Karpenter 노드 정리 (ENI 잔류 방지)
###############################################################################
log "    Karpenter 노드 정리 중..."
kubectl delete nodeclaim --all -A --timeout=30s 2>/dev/null || true
kubectl delete nodepool --all -A --timeout=30s 2>/dev/null || true

# VPC ID 미리 확보
VPC_ID=$(cd "$ENV_DIR/infra" && terraform output -raw vpc_id 2>/dev/null || echo "")

# VPC 내 모든 인스턴스 종료 (Karpenter 태그 유무 관계없이)
if [ -n "$VPC_ID" ]; then
  cleanup_vpc_resources "$VPC_ID"
fi
log "    Karpenter 노드 정리 완료"

###############################################################################
# 2. Terraform — addon destroy
###############################################################################
log "2/3 Terraform addon destroy 시작..."
STEP_START=$(date +%s)
cd "$ENV_DIR/addon"
terraform init -input=false -no-color > /dev/null 2>&1
set +e
terraform destroy -auto-approve -input=false 2>&1
ADDON_EXIT=$?
set -e
if [ $ADDON_EXIT -ne 0 ]; then
  warn "addon destroy 일부 실패 (infra destroy에서 정리됨)"
fi
log "    addon destroy 완료 ($(elapsed $STEP_START))"

###############################################################################
# 3. Terraform — infra destroy
###############################################################################
log "3/3 Terraform infra destroy 시작..."
STEP_START=$(date +%s)
cd "$ENV_DIR/infra"
terraform init -input=false -no-color > /dev/null 2>&1

MAX_RETRIES=3
set +e
for i in $(seq 1 $MAX_RETRIES); do
  terraform destroy -auto-approve -input=false 2>&1
  if [ $? -eq 0 ]; then
    break
  else
    if [ $i -lt $MAX_RETRIES ]; then
      warn "destroy 실패 (시도 $i/$MAX_RETRIES). 잔여 리소스 정리 후 재시도... (30초)"
      # VPC ID가 아직 있으면 정리
      VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || echo "")
      if [ -n "$VPC_ID" ]; then
        cleanup_vpc_resources "$VPC_ID"
      fi
      sleep 30
    else
      set -e
      err "infra destroy 실패 ($MAX_RETRIES회 시도). 수동 확인 필요."
    fi
  fi
done
set -e
log "    infra destroy 완료 ($(elapsed $STEP_START))"

###############################################################################
# 3.5. CloudWatch Log Group 정리 (다음 apply 시 충돌 방지)
###############################################################################
log "    CloudWatch Log Group 정리 중..."
aws logs delete-log-group --log-group-name /aws/eks/baselink-dev/cluster 2>/dev/null && log "    EKS Log Group 삭제 완료" || true

###############################################################################
echo ""
log "========================================="
log " 전체 내리기 완료! 총 소요시간: $(elapsed $TOTAL_START)"
log " ECR은 유지됩니다."
log "========================================="
