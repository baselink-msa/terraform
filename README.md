# BaseLink Terraform

BaseLink dev 인프라를 구성하는 Terraform 저장소입니다. EKS 기반 MSA 실행 환경과 프론트엔드 정적 배포 리소스를 함께 관리합니다.

## 관리 리소스

- VPC, public/private subnet, NAT, routing
- EKS cluster, node group, Karpenter
- EKS addons 및 Helm 기반 addon
- RDS PostgreSQL
- ElastiCache Redis
- SQS 예매 검증 큐
- ECR 서비스별 저장소
- S3 + CloudFront 프론트엔드 배포
- GitHub OIDC/CI 관련 IAM
- Argo CD 설치 모듈

## 디렉터리 구조

```text
modules/
  argocd/
  ecr/
  eks/
  eks-addons/
  elasticache/
  github-oidc/
  iam/
  rds/
  s3/
  sqs/
  vpc/
scripts/
  infra-up.sh
  infra-down.sh
env/
  dev/
    infra/
    ecr/
    addon/
```

환경별 apply 단위는 `env/<env>/<layer>`입니다.

## 사전 준비

- Terraform 1.10 이상
- AWS CLI 인증
- kubectl
- Helm

AWS 인증이 만료되면 Terraform, kubectl, ECR 조회가 모두 실패합니다.

```bash
aws login
aws sts get-caller-identity
```

## dev 인프라 생성

스크립트 사용:

```bash
./scripts/infra-up.sh
```

수동 실행:

```bash
cd env/dev/infra
terraform init
terraform validate
terraform plan
terraform apply

cd ../ecr
terraform init
terraform validate
terraform plan
terraform apply

cd ../addon
terraform init
terraform validate
terraform plan
terraform apply
```

항상 `infra` → `ecr` → `addon` 순서로 적용합니다.

## dev 인프라 종료

```bash
./scripts/infra-down.sh
```

종료 전에는 GitOps 리소스, LoadBalancer, PVC 등 클러스터 내부 리소스가 AWS 리소스 삭제를 막지 않는지 확인합니다.

## 배포 후 연결

```bash
aws eks update-kubeconfig --region ap-northeast-2 --name baselink-dev
kubectl get nodes
kubectl get pods -A
```

GitOps 적용:

```bash
cd ../baselink-gitops
kubectl apply -k overlays/dev
```

프론트엔드 배포:

```bash
cd ../baselink-app/baselink-front
npm run build
aws s3 sync dist/ s3://baselink-frontend-740831361032-ap-northeast-2 --delete
aws cloudfront create-invalidation --distribution-id E1L0BJIJOTT0R6 --paths "/*"
```

## 주요 값

- AWS 계정: `740831361032`
- 리전: `ap-northeast-2`
- EKS 클러스터: `baselink-dev`
- Kubernetes 네임스페이스: `baselink-dev`
- RDS DB: `baseball_platform`
- S3 버킷: `baselink-frontend-740831361032-ap-northeast-2`
- CloudFront 배포 ID: `E1L0BJIJOTT0R6`

## 검증 명령

```bash
terraform fmt -recursive
terraform validate
kubectl get nodes -o wide
kubectl get deploy,pods,svc,ingress -n baselink-dev
aws ecr describe-repositories --region ap-northeast-2
aws cloudfront get-distribution-config --id E1L0BJIJOTT0R6
```

## CI/CD와의 연결

백엔드 CI는 서비스별 ECR 저장소에 multi-arch 이미지를 push합니다.

```text
dev-auth-service
dev-game-service
dev-admin-service
dev-waiting-room-service
dev-ticket-worker-service
dev-seat-lock-service
dev-ticket-service
dev-order-service
dev-ai-chatbot-service
```

GitOps overlay가 각 이미지 태그를 Git SHA로 고정하고, Argo CD가 해당 변경을 클러스터에 반영합니다.

## 알려진 이슈

- Karpenter IAM 정책이 현재 넓은 권한을 사용합니다. 추후 AWS/Karpenter 공식 권장 조건을 기준으로 최소 권한화해야 합니다.
- RDS 초기화는 Terraform이 아니라 GitOps 저장소의 `db/seed-dev.sql`로 수행합니다.
- 운영 환경에서는 state, secret, migration, autoscaling 정책을 dev와 분리해야 합니다.
