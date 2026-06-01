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
# 1.5. Karpenter 노드 정리 (ENI 잔류 방지)
###############################################################################
log "    Karpenter 노드 정리 중..."
# NodePool/NodeClaim 삭제 → Karpenter가 노드를 graceful drain & terminate
kubectl delete nodeclaim --all -A 2>/dev/null || true
kubectl delete nodepool --all -A 2>/dev/null || true

# Karpenter가 정리할 시간을 주고, 남은 인스턴스 강제 종료
sleep 15
KARPENTER_INSTANCES=$(aws ec2 describe-instances \
  --filters "Name=tag:karpenter.sh/managed-by,Values=*" "Name=instance-state-name,Values=running,pending,stopping" \
  --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null)
if [ -n "$KARPENTER_INSTANCES" ]; then
  log "    Karpenter 인스턴스 강제 종료: $KARPENTER_INSTANCES"
  aws ec2 terminate-instances --instance-ids $KARPENTER_INSTANCES >/dev/null 2>&1
  aws ec2 wait instance-terminated --instance-ids $KARPENTER_INSTANCES 2>/dev/null || sleep 30
fi
log "    Karpenter 노드 정리 완료"

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
# 2.5. EKS 잔여 보안그룹 + ENI 정리 (VPC 삭제 차단 방지)
###############################################################################
log "    EKS 잔여 리소스 정리 중..."
VPC_ID=$(cd "$ENV_DIR/infra" && terraform output -raw vpc_id 2>/dev/null || echo "")
if [ -n "$VPC_ID" ]; then
  # 보안그룹 정리
  EKS_SGS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=eks-cluster-sg-*" \
    --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null)
  for sg in $EKS_SGS; do
    aws ec2 delete-security-group --group-id "$sg" 2>/dev/null && log "    SG 삭제: $sg"
  done

  # 잔여 ENI 정리
  for eni in $(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
    --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null); do
    aws ec2 delete-network-interface --network-interface-id "$eni" 2>/dev/null && log "    ENI 삭제: $eni"
  done
fi

###############################################################################
# 3. Terraform — infra destroy
###############################################################################
log "3/3 Terraform infra destroy 시작..."
STEP_START=$(date +%s)
cd "$ENV_DIR/infra"
terraform init -input=false -no-color > /dev/null 2>&1

# EKS 삭제 후 ENI 정리에 시간이 걸려서 서브넷 삭제가 실패할 수 있음
# 최대 3번 retry (사이에 60초 대기)
MAX_RETRIES=3
set +e  # retry 로직을 위해 일시적으로 에러 시 종료 비활성화
for i in $(seq 1 $MAX_RETRIES); do
  terraform destroy -auto-approve -input=false 2>&1
  if [ $? -eq 0 ]; then
    break
  else
    if [ $i -lt $MAX_RETRIES ]; then
      warn "destroy 실패 (시도 $i/$MAX_RETRIES). ENI 정리 대기 중... (60초)"
      # 잔여 ENI 정리 시도
      for subnet in $(aws ec2 describe-subnets --filters "Name=tag:Project,Values=baselink" --query 'Subnets[*].SubnetId' --output text 2>/dev/null); do
        for eni in $(aws ec2 describe-network-interfaces --filters "Name=subnet-id,Values=$subnet" "Name=status,Values=available" --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null); do
          aws ec2 delete-network-interface --network-interface-id "$eni" 2>/dev/null && log "    ENI 삭제: $eni"
        done
      done
      sleep 60
    else
      set -e
      err "infra destroy 실패 ($MAX_RETRIES회 시도). 수동 확인 필요."
    fi
  fi
done
set -e
log "    infra destroy 완료 ($(elapsed $STEP_START))"

###############################################################################
echo ""
log "========================================="
log " 전체 내리기 완료! 총 소요시간: $(elapsed $TOTAL_START)"
log " ECR은 유지됩니다."
log "========================================="
