# 도쿄 DR Compute 활성화와 Endpoint 전환 Runbook

이 문서는 서울 리전 전체 장애 시 도쿄 Pilot Light 네트워크 위에 최소 compute를 활성화하고, 복원 RDS와 새 backend를 검증한 뒤 CloudFront API origin을 전환하는 절차를 정의합니다.

현재 상시 준비된 범위는 도쿄 KMS, Backup vault, RDS recovery point, VPC, subnet, DB subnet group과 security group입니다. EKS, Valkey, SQS와 NAT Gateway는 비용을 줄이기 위해 평상시에 실행하지 않습니다.

## 1. 이 작업을 하는 이유

RDS 복원만 성공해도 데이터는 살릴 수 있지만 서비스가 자동으로 복구되는 것은 아닙니다. backend가 실행되려면 다음 항목이 모두 도쿄 값으로 맞아야 합니다.

```text
EKS와 addon
→ ECR 이미지
→ RDS·Valkey·SQS endpoint
→ IAM/IRSA
→ GitOps workload
→ ALB
→ CloudFront API origin
```

이 순서와 전환 기준을 미리 고정하면 실제 장애 중 즉흥적으로 리소스를 연결하다가 잘못된 DB나 서울 큐를 사용하는 사고를 줄일 수 있습니다.

## 2. DR 활성화 원칙

- DR 선언 전에는 도쿄 compute를 생성하지 않습니다.
- 복구 중에도 서울 운영 리소스를 수정하거나 삭제하지 않습니다.
- 도쿄 backend는 외부 트래픽을 받기 전에 내부 smoke test를 통과해야 합니다.
- CloudFront origin 전환은 승인 지점이며 자동 수행하지 않습니다.
- 실패하면 CloudFront origin을 서울 ALB로 되돌릴 수 있어야 합니다.
- 복구 훈련이 끝나면 RDS를 제외한 임시 compute와 NAT를 정리합니다.

## 3. 현재 준비된 Terraform 입력

| 항목 | 값 또는 입력 | 상태 |
| --- | --- | --- |
| DR Region | `ap-northeast-1` | 완료 |
| DR VPC | `10.100.0.0/16` | 배포 완료 |
| DR EKS 이름 | `baselink-dev-tokyo` | subnet discovery 이름으로 고정 |
| Public subnet | `10.100.0.0/24`, `10.100.10.0/24` | 배포 완료 |
| Private app subnet | `10.100.20.0/24`, `10.100.30.0/24` | 배포 완료 |
| Private data subnet | `10.100.40.0/24`, `10.100.50.0/24` | 배포 완료 |
| NAT | `dr_enable_nat_gateway = false` | 평상시 비활성 |
| NAT 구성 | `dr_single_nat_gateway = true` | DR 활성화 시 비용 우선 |

도쿄 subnet에는 `kubernetes.io/cluster/baselink-dev-tokyo=shared` 태그를 미리 적용합니다. 이를 통해 EKS와 Load Balancer Controller가 복구 중에 사용할 subnet 이름을 사전에 확정합니다.

## 4. NAT 활성화 결정

현재 도쿄 private subnet은 S3 Gateway Endpoint만 있고 NAT가 없습니다. EKS node와 pod가 ECR, STS, Helm repository 등으로 통신하려면 다음 두 방식 중 하나가 필요합니다.

| 방식 | 장점 | 단점 | 현재 선택 |
| --- | --- | --- | --- |
| DR 중 단일 NAT 생성 | 구현이 단순하고 외부 dependency 접근 가능 | 시간당 비용, 단일 AZ 의존 | 기본 복구 방식 |
| ECR·STS 등 VPC Endpoint 상시 유지 | NAT 없이 private 통신 | endpoint별 고정 비용과 관리 증가 | 향후 고도화 |

DR 활성화 시 GitHub `DEV_INFRA_TFVARS`와 승인된 로컬 입력에서 다음 값을 사용합니다.

```hcl
dr_enable_nat_gateway = true
dr_single_nat_gateway = true
```

훈련 또는 장애 종료 후 `dr_enable_nat_gateway = false`로 되돌리고 plan에서 NAT Gateway와 EIP만 제거되는지 확인합니다.

## 5. 최소 Compute 목표 구성

첫 복구 목표는 전체 운영 용량이 아니라 핵심 API 검증이 가능한 최소 구성입니다.

| 구성 | 최소값 | 이유 |
| --- | ---: | --- |
| EKS system node | 1 | CoreDNS, Karpenter, KEDA, Argo CD, LBC 실행 |
| system node type | `t4g.large` 1대 | 기존 arm64 이미지와 addon 호환 유지 |
| Karpenter app node | 최소 1대 | backend workload 실행 |
| backend replica | 서비스별 1 | 기능 검증 우선 |
| RDS | 복원 시 Single-AZ 가능 | 데이터 검증 후 실제 DR에서는 Multi-AZ 전환 판단 |
| Valkey | 1 primary부터 시작 가능 | 좌석 lock과 대기열 기능 복구 |
| SQS | 원본 큐와 DLQ | 예매 비동기 처리 복구 |

시스템 노드는 `CriticalAddonsOnly` taint가 있어 일반 backend pod가 올라가지 않습니다. 따라서 Karpenter 설치와 app node 생성까지 완료돼야 API workload가 실행됩니다.

## 6. 전환해야 하는 설정 목록

### 6.1 Terraform addon의 `backend-config`

| 설정 | 서울 값 | 도쿄 전환값 |
| --- | --- | --- |
| `AWS_REGION` | `ap-northeast-2` | `ap-northeast-1` |
| `SPRING_CLOUD_AWS_REGION_STATIC` | `ap-northeast-2` | `ap-northeast-1` |
| `SPRING_CLOUD_AWS_SQS_ENDPOINT` | 서울 SQS endpoint | 도쿄 SQS endpoint |
| `SPRING_DATASOURCE_URL` | 서울 RDS endpoint | 복원된 도쿄 RDS endpoint |
| `SPRING_DATA_REDIS_HOST` | 서울 Valkey endpoint | 도쿄 Valkey endpoint |

### 6.2 Secret

- `SPRING_DATASOURCE_USERNAME`
- `SPRING_DATASOURCE_PASSWORD`
- `APP_JWT_SECRET`
- `postgres-keda-secret.connection`

DB 자격증명은 Git에 저장하지 않습니다. 복원 RDS가 원본 master secret을 자동 복제하지 않을 수 있으므로 restore 결과와 Secrets Manager 값을 실제 접속으로 검증합니다. JWT secret은 기존 사용자 세션 유지가 필요하면 서울 값과 동일한 비밀을 안전한 경로로 복구합니다.

### 6.3 GitOps에서 하드코딩을 제거하거나 덮어써야 하는 값

- `base/serviceaccount.yaml`의 서울 IRSA role ARN
- `base/keda.yaml`의 서울 SQS queue URL과 `awsRegion`
- `overlays/dev/kustomization.yaml`의 서울 ECR image URI
- Ingress의 origin 검증 header와 도쿄 ALB 접근 정책

DR overlay는 서울 `overlays/dev`를 직접 수정하지 않고 `overlays/dr-tokyo`로 분리하는 것을 원칙으로 합니다.

## 7. 복구 실행 순서

### Phase A. 선언과 데이터 복구

1. 서울 리전 장애 범위와 데이터 손상 여부를 확인합니다.
2. DR 책임자와 서비스 책임자가 도쿄 전환을 승인합니다.
3. 최신 `COMPLETED` 도쿄 recovery point의 생성 시각과 암호화를 확인합니다.
4. 도쿄 DB subnet group과 RDS security group으로 새 RDS를 복원합니다.
5. Flyway 이력과 핵심 테이블을 읽기 전용으로 검증합니다.

### Phase B. Compute 활성화

1. `dr_enable_nat_gateway = true`로 Terraform plan을 생성합니다.
2. plan에서 서울 리소스 변경과 예상하지 않은 삭제가 `0`인지 확인합니다.
3. 단일 NAT와 EIP를 적용합니다.
4. 별도 DR compute state에서 `baselink-dev-tokyo` EKS를 생성합니다.
5. addon 레이어로 LBC, Karpenter, KEDA, Reloader와 Argo CD를 설치합니다.
6. 도쿄 Valkey와 SQS 원본 큐/DLQ를 생성합니다.
7. 도쿄 ECR image 또는 검증된 cross-region image를 준비합니다.

### Phase C. Backend 연결

1. `backend-config`, `backend-secret`, `postgres-keda-secret`을 도쿄 값으로 생성합니다.
2. DR GitOps overlay를 sync합니다.
3. 모든 Deployment가 도쿄 endpoint만 참조하는지 확인합니다.
4. Flyway는 `validate`를 기본으로 하고, 새 migration 실행은 별도 승인합니다.
5. worker는 API 읽기 검증이 끝난 뒤 활성화해 오래된 메시지나 중복 처리를 방지합니다.

### Phase D. 전환 전 검증

필수 검증:

```powershell
kubectl --context baselink-dev-tokyo get nodes
kubectl --context baselink-dev-tokyo -n baselink-dev get pods
kubectl --context baselink-dev-tokyo -n baselink-dev get ingress baselink-api
kubectl --context baselink-dev-tokyo -n baselink-dev get configmap backend-config -o yaml
```

- auth health와 로그인
- 경기 목록 조회
- 좌석 조회
- 대기열 상태 조회
- 쓰기 차단 상태에서 예매 API가 의도대로 동작하는지 확인
- RDS connection 수, Valkey 연결, SQS queue attribute 확인
- 도쿄 ALB에 CloudFront origin 검증 header를 포함한 직접 요청

### Phase E. CloudFront API Origin 전환

현재 CloudFront `/api/*`는 단일 ALB domain을 origin으로 사용합니다. 도쿄 ALB가 검증된 후에만 `cloudfront_api_origin_domain_name`을 도쿄 ALB DNS로 변경합니다.

전환 전 기록:

- 기존 서울 ALB DNS
- 신규 도쿄 ALB DNS
- CloudFront distribution ID
- 전환 승인자와 시각
- smoke test 결과

Terraform plan에서 CloudFront distribution의 API origin domain만 변경되는지 확인하고 apply합니다. 전환 후 `/api/games`, `/api/auth`, `/api/waiting-room`을 CloudFront URL로 다시 검증합니다.

## 8. Rollback

도쿄 API 오류율 증가, 데이터 불일치 또는 인증 문제가 발견되면 다음 순서로 원복합니다.

1. 쓰기 API를 차단하고 신규 worker 처리를 중지합니다.
2. CloudFront API origin을 기록해 둔 서울 ALB DNS로 되돌립니다.
3. CloudFront 경유 핵심 API가 서울로 돌아왔는지 확인합니다.
4. 도쿄 DB에 발생한 쓰기와 SQS 메시지를 별도로 보존합니다.
5. 원인 분석 전 도쿄 RDS를 삭제하지 않습니다.

서울 리전이 완전히 사용할 수 없는 상황이라면 endpoint rollback은 불가능합니다. 이 경우 도쿄에서 읽기 전용 또는 제한 기능으로 서비스를 유지하고 데이터 문제를 우선 해결합니다.

## 9. 정리와 비용 차단

훈련 종료 후 다음 순서로 정리합니다.

1. CloudFront origin이 서울인지 확인
2. DR GitOps sync와 worker 중지
3. EKS, Valkey, SQS 등 임시 compute/data-plane 삭제 승인
4. `dr_enable_nat_gateway = false` 적용
5. EIP와 NAT Gateway 삭제 확인
6. 복원 RDS 보존 또는 삭제 결정
7. 도쿄 Backup vault, KMS, VPC와 subnet은 Pilot Light로 유지

## 10. 완료 기준과 현재 한계

현재 완료:

- 도쿄 데이터·네트워크 Pilot Light
- cross-region copy와 RDS 복원·데이터 검증
- DR EKS 이름과 subnet discovery tag 고정
- 필요할 때만 NAT를 활성화할 Terraform 입력
- compute 활성화, 설정 교체, CloudFront 전환과 rollback 순서

아직 구현·검증이 필요한 항목:

- 별도 DR compute Terraform state와 EKS stack
- 도쿄 Valkey와 SQS 생성
- ECR cross-region replication 배포와 신규 image 검증
- 기존 GitOps 활성 image 9개 도쿄 bootstrap
- GitOps `overlays/dr-tokyo`
- 도쿄 ALB와 CloudFront 실제 전환 리허설
- 전체 서비스 RTO 측정

따라서 이 단계에서 얻는 것은 자동 리전 전환이 아니라, 데이터 복원 이후 무엇을 어떤 순서로 연결해야 하는지 명확한 실행 경로와 비용 제어 수단입니다.
