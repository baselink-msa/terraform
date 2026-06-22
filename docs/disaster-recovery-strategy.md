# 재해복구 전략

이 문서는 Baselink 프로젝트의 재해복구, 고가용성, 백업 전략을 정리합니다.

목표는 단순히 장애가 발생한 뒤 대응하는 것이 아니라, 장애가 발생해도 데이터 손실과 서비스 중단 시간을 예측 가능한 범위 안으로 제한하는 것입니다.

최종 상태 확인일: 2026-06-22

## 1. 용어 정리

| 용어 | 의미 |
| --- | --- |
| HA | High Availability. 단일 장애 지점이 생겨도 서비스가 계속 동작하도록 만드는 구성 |
| DR | Disaster Recovery. 큰 장애나 데이터 손상 이후 서비스를 복구하는 전략 |
| RPO | Recovery Point Objective. 장애 시 허용 가능한 최대 데이터 손실 시간 |
| RTO | Recovery Time Objective. 장애 후 서비스 복구까지 허용 가능한 최대 시간 |
| AZ 장애 | 같은 리전 안의 하나의 가용 영역 장애 |
| Region 장애 | 서울 리전 전체 장애처럼 리전 단위로 서비스 사용이 어려운 상황 |

HA와 DR은 다릅니다.

- HA는 장애가 나도 계속 버티는 구조입니다.
- DR은 장애가 났을 때 어디까지 되돌리고 얼마나 빨리 복구할지 정하는 구조입니다.

## 2. 현재 구성 요약

현재 dev 환경은 `ap-northeast-2` 서울 리전을 기본 리전으로 사용합니다.

| 영역 | 현재 구성 | 현재 평가 |
| --- | --- | --- |
| VPC/Subnet | 2개 AZ에 public/private app/private data subnet 구성 | AZ 분산 기반 있음 |
| EKS | private app subnet 2개 AZ 사용, system node group 최소 2대 | 기본 HA 기반 있음 |
| Backend Pod | KEDA/HPA 사용, 서비스별 minReplica 1~2, 일부 topology spread 적용 | 서비스 복제는 있으나 서비스별 편차 있음 |
| RDS PostgreSQL | Multi-AZ, automated backup 7일, PITR, 삭제 보호, final snapshot | AZ 장애와 논리 장애 복구 기반 검증 |
| Valkey ElastiCache | primary 1 + replica 1, Multi-AZ, automatic failover 활성화 | 캐시 계층 AZ 장애 대비 좋음 |
| SQS | 원본 큐 + DLQ + redrive allow policy + backlog/DLQ 알람 | 비동기 메시지 안정성 좋음 |
| CloudFront/WAF | CloudFront, WAF, origin 보호 헤더 사용 | 엣지 보안/전달 안정성 좋음 |
| GitOps/Flyway | Kubernetes manifest와 DB migration SQL 관리 | 재배포/재구성 기반 있음 |
| AWS Backup | KMS 암호화 vault, daily snapshot, 7일 보존, 명시적 RDS ARN selection | 실제 recovery point 복원 리허설 완료 |
| Cross-Region DR | 도쿄 백업·네트워크 Pilot Light와 RDS 복원 검증 완료 | Compute와 endpoint 전환 경로 보완 필요 |

## 3. 장애 시나리오

### 3.1 AZ 장애

예시:

- `ap-northeast-2a` 장애
- 특정 AZ의 EKS node 장애
- RDS primary가 위치한 AZ 장애
- Valkey primary가 위치한 AZ 장애

현재 기대 동작:

- EKS pod는 다른 AZ의 node로 재스케줄될 수 있습니다.
- RDS Multi-AZ가 활성화되어 있으면 standby로 failover됩니다.
- Valkey automatic failover가 활성화되어 있으면 replica가 primary로 승격될 수 있습니다.
- SQS, CloudFront는 managed service이므로 일반적으로 AZ 장애를 서비스 내부에서 흡수합니다.

보완 포인트:

- 모든 핵심 서비스에 topology spread와 minReplica 2 이상이 일관되게 적용되어 있는지 확인합니다.
- PodDisruptionBudget을 추가해 의도치 않은 동시 중단을 줄입니다.
- RDS/Valkey failover 후 애플리케이션 재연결이 정상인지 테스트합니다.

### 3.2 데이터 손상 또는 실수 삭제

예시:

- 잘못된 SQL로 예매 데이터 삭제
- 잘못된 Flyway migration
- 운영자가 seed 데이터를 잘못 실행
- 애플리케이션 버그로 잘못된 상태 저장

현재 기대 동작:

- RDS automated backup 7일과 PITR이 활성화되어 특정 시점으로 새 DB를 복원할 수 있습니다.
- Flyway migration 이력으로 schema를 추적할 수 있습니다.
- seed SQL로 dev 기준 초기 데이터를 재구성할 수 있습니다.
- AWS Backup recovery point에서 임시 RDS를 복원하고 EKS 내부에서 schema와 데이터를 검증한 이력이 있습니다.

보완 포인트:

- RDS PITR 복구 리허설을 정기적으로 수행합니다.
- 중요한 변경 전 on-demand snapshot 또는 AWS Backup 백업을 만듭니다.
- 복구 DB 검증 후 endpoint 전환 절차를 문서화합니다.

### 3.3 리전 장애

예시:

- 서울 리전 RDS 접근 불가
- 서울 리전 EKS/ALB 장애
- 서울 리전 전체 네트워크 장애

현재 기대 동작:

- 현재는 단일 리전 기반이므로 서울 리전 전체 장애 시 즉시 자동 복구되지는 않습니다.
- 서울 리전 내부의 recovery point만 존재하므로 리전 전체 장애 시 현재 백업만으로 즉시 복구할 수 없습니다.
- Terraform/GitOps/ECR 이미지/교차 리전 DB 백업을 이용해 DR 리전에 복구하는 구현이 필요합니다.

추천 전략:

- 비용과 구현 난이도를 고려해 `Pilot Light` 전략을 기본으로 합니다.
- DR 리전은 `ap-northeast-1` 도쿄로 확정합니다.
- RDS daily recovery point를 도쿄 backup vault로 복사합니다.
- 애플리케이션 인프라는 Terraform/GitOps로 DR 리전에 재구성할 수 있게 합니다.

## 4. RPO/RTO 목표

dev 환경은 비용 제약이 있으므로 완전한 운영 수준 DR을 모두 켜지는 않습니다. 대신 발표와 설계 기준은 아래 목표를 기준으로 합니다.

| 대상 | 목표 RPO | 목표 RTO | 전략 |
| --- | ---: | ---: | --- |
| RDS PostgreSQL 논리 장애 | 5분 이내 | 30~60분 | Multi-AZ + RDS native PITR + AWS Backup snapshot |
| 서울 리전 장애 | daily copy 기준 최대 24시간 | 2~4시간 | 도쿄 recovery point 복원 + Pilot Light 재구성 |
| Valkey ElastiCache | 1시간~1일 | 15~30분 | Multi-AZ failover + snapshot |
| SQS 원본 큐/DLQ | 메시지 보존 기간 내 0 | 10~30분 | SQS durability + DLQ + redrive |
| EKS/Backend | 0 | 30~60분 | Terraform + GitOps + ECR 이미지 재배포 |
| Frontend S3/CloudFront | 0~수분 | 10~30분 | S3 versioning/replication + CloudFront origin 전환 |
| Secrets/Config | 0~수분 | 30분 | Secrets Manager/External Secrets 또는 재생성 절차 |
| Terraform state | 최근 state 기준 | 30분 | S3 versioning + backend 복구 |

## 5. 서비스별 전략

### 5.1 VPC와 네트워크

현재:

- 2개 AZ에 public subnet, private app subnet, private data subnet이 있습니다.
- dev 비용 절감을 위해 NAT Gateway는 single NAT 구성이 사용될 수 있습니다.

권장:

- 운영 환경에서는 AZ별 NAT Gateway를 두는 것이 더 안전합니다.
- DR 리전에도 동일한 CIDR 또는 충돌 없는 CIDR 설계를 미리 정합니다.
- VPC, subnet, route table, security group은 Terraform으로 재생성 가능해야 합니다.

### 5.2 EKS와 Backend

현재:

- EKS cluster는 2개 private app subnet을 사용합니다.
- system node group은 최소 2대로 구성됩니다.
- KEDA/HPA로 서비스별 scale out을 수행합니다.
- 일부 중요 서비스는 topology spread가 적용되어 있습니다.

권장:

- 핵심 서비스는 minReplica 2 이상을 유지합니다.
- 모든 user-facing 서비스에 topology spread를 일관되게 적용합니다.
- PodDisruptionBudget을 추가합니다.
- readiness/liveness probe를 모든 서비스에 일관되게 둡니다.
- DR 리전에서는 Terraform과 GitOps로 EKS와 backend를 재배포합니다.

복구 방식:

```text
Terraform apply in DR region
  -> EKS/addon 생성
  -> ECR 이미지 pull 가능 확인
  -> GitOps manifest apply
  -> backend-secret/config 동기화
  -> Flyway migration 실행
  -> CloudFront/Route 53 origin 전환
```

### 5.3 RDS PostgreSQL

현재:

- Multi-AZ가 활성화되어 있습니다.
- backup retention은 7일로 설정되어 있습니다.
- backup window는 UTC `18:00-18:30`입니다.
- copy tags to snapshot이 활성화되어 있습니다.
- deletion protection을 활성화해 실수 삭제를 막습니다.
- final snapshot을 활성화해 의도적 삭제 시 마지막 복구 지점을 남깁니다.

권장:

- 삭제 보호를 해제하는 변경은 별도 PR과 팀 합의 후 진행합니다.
- final snapshot 이름 충돌 여부를 삭제 전 확인합니다.
- RDS native PITR과 AWS Backup daily snapshot의 역할을 분리해 유지합니다.
- 중요한 시점에는 on-demand backup을 생성합니다.
- cross-region copy를 통해 DR 리전에 RDS snapshot을 보관합니다.

RDS DR 전략:

| 장애 | 복구 방식 |
| --- | --- |
| 단일 AZ 장애 | RDS Multi-AZ failover |
| 데이터 실수 삭제 | PITR로 새 DB 복원 |
| 잘못된 migration | migration 직전 시점으로 PITR 복원 후 데이터 비교 |
| 서울 리전 장애 | DR 리전 snapshot 복원 후 backend endpoint 전환 |

Read replica 위치:

- Read replica는 주로 읽기 부하 분산용입니다.
- 장애 복구의 기본 수단은 Multi-AZ와 백업/PITR입니다.
- 읽기 API가 DB에 큰 부하를 만들면 game/admin/FAQ 조회를 read replica로 분리하는 전략을 검토합니다.

커넥션 관리:

- 서비스별 Hikari maximum pool size를 정합니다.
- 전체 pod 수 x 서비스별 max pool이 RDS 허용 커넥션을 넘지 않게 계산합니다.
- 필요하면 RDS Proxy 또는 PgBouncer를 검토합니다.

### 5.4 Valkey ElastiCache

현재:

- Valkey engine을 사용합니다.
- primary 1개와 replica 1개가 있습니다.
- Multi-AZ와 automatic failover가 활성화되어 있습니다.
- at-rest encryption은 활성화되어 있습니다.
- transit encryption은 비활성화되어 있습니다.
- snapshot retention은 0일입니다.

권장:

- dev에서도 최소 1일 snapshot retention을 검토합니다.
- 운영 기준은 3~7일 snapshot retention을 검토합니다.
- snapshot window를 명시합니다.
- 클라이언트 TLS 적용 가능성을 확인한 뒤 transit encryption을 활성화합니다.
- 좌석 lock TTL, 대기열 TTL, 캐시 key namespace 정책을 문서화합니다.
- evictions가 좌석 선점 정합성에 미치는 영향을 정의합니다.

Valkey DR 전략:

| 장애 | 복구 방식 |
| --- | --- |
| primary 노드 장애 | replica 자동 승격 |
| AZ 장애 | Multi-AZ failover |
| 캐시 데이터 유실 | DB 기반 재구성 가능한 데이터와 불가능한 데이터를 구분 |
| 리전 장애 | DR 리전에 Valkey 재생성, 필요 시 snapshot restore |

주의:

- Valkey는 RDS와 달리 모든 데이터를 영구 데이터로 보지 않습니다.
- 좌석 lock, 대기열 상태처럼 TTL 기반 데이터는 복구보다 재진입/재시도 설계가 더 중요할 수 있습니다.

### 5.5 SQS

현재:

- `ticket-confirm-queue` 원본 큐가 있습니다.
- `ticket-confirm-dlq` DLQ가 있습니다.
- `max_receive_count = 5`입니다.
- DLQ retention은 14일입니다.
- 원본 큐 retention은 기본 1일입니다.
- 원본 큐 backlog 알람과 DLQ 알람이 있습니다.

권장:

- 원본 큐 retention을 4일 이상으로 늘릴지 검토합니다.
- receive wait time을 10~20초로 설정해 long polling을 활성화합니다.
- visibility timeout이 worker 최대 처리 시간보다 충분히 길어야 합니다.
- 메시지 idempotency key를 기준으로 중복 처리를 방지합니다.
- SQS SSE 암호화 설정을 명시적으로 관리합니다.

SQS DR 전략:

| 장애 | 복구 방식 |
| --- | --- |
| worker 처리 실패 | DLQ 이동 후 원인 수정, redrive |
| 일시적 처리 지연 | 원본 큐 backlog 유지, worker scale out |
| 리전 장애 | DR 리전에 동일 queue/DLQ 생성, 장애 전 미처리 메시지는 원본 리전 복구 후 처리 |

주의:

- SQS 메시지는 리전 단위 서비스입니다.
- 리전 장애 시 기존 큐의 미처리 메시지를 즉시 다른 리전에서 읽을 수 있는 구조는 아닙니다.
- 정말 강한 리전 DR이 필요하면 이벤트를 RDS에도 outbox 형태로 저장하거나, EventBridge global endpoint 같은 별도 설계를 검토합니다.

### 5.6 Frontend S3, CloudFront, WAF

현재:

- CloudFront가 frontend S3 origin과 API ALB origin을 사용합니다.
- WAF가 CloudFront/API 경로를 보호합니다.

권장:

- frontend S3 bucket versioning을 활성화합니다.
- 필요하면 S3 Cross-Region Replication을 적용합니다.
- CloudFront origin을 DR 리전 ALB/S3로 전환하는 절차를 문서화합니다.
- WAF rule은 Terraform으로 재생성 가능하게 유지합니다.

### 5.7 ECR 이미지

현재:

- backend 이미지는 ECR에 push합니다.
- cross-region replication 여부는 추가 확인이 필요합니다.

권장:

- DR 리전에 ECR repository를 미리 만들거나 replication rule을 둡니다.
- 최소한 release image tag와 digest를 문서화합니다.
- DR 리전 EKS가 이미지를 pull할 수 있어야 합니다.

### 5.8 Secrets와 Config

현재:

- `backend-config`, `backend-secret`, `postgres-keda-secret`은 addon 레이어에서 생성됩니다.
- 일부 민감 값은 GitOps에 커밋하지 않습니다.

권장:

- External Secrets Operator와 Secrets Manager 연동을 검토합니다.
- DR 리전에 필요한 secret 목록을 문서화합니다.
- secret rotation과 재생성 절차를 정리합니다.
- DB endpoint, Valkey endpoint, SQS endpoint 교체 절차를 Runbook에 포함합니다.

### 5.9 Terraform State와 GitOps

현재:

- Terraform backend는 remote state를 사용합니다.
- GitHub PR 기반 Terraform apply 흐름이 있습니다.
- GitOps manifest로 Kubernetes 리소스를 재구성할 수 있습니다.

권장:

- Terraform state bucket versioning을 확인합니다.
- state bucket 복구 전략을 문서화합니다.
- GitHub repository 자체가 단일 장애 지점이 되지 않도록 release tag와 백업 전략을 둡니다.
- DR 리전용 tfvars 또는 workspace 전략을 준비합니다.

## 6. AWS Backup 구현 상태와 확장 전략

AWS Backup은 백업 정책을 중앙에서 관리하기 위한 서비스입니다.

현재 구현:

- `modules/backup`에서 vault, plan, selection, service role을 Terraform으로 관리합니다.
- `baselink-dev-backup-vault`는 KMS 암호화를 사용합니다.
- `baselink-dev-postgres`의 ARN을 명시적으로 selection에 전달합니다.
- 매일 04:00 KST에 snapshot을 만들고 7일간 보존합니다.
- RDS native automated backup 7일이 PITR을 담당하고 AWS Backup은 daily snapshot을 담당합니다.
- 2026-06-16 recovery point에서 임시 RDS 복원과 데이터 검증을 완료했습니다.
- 2026-06-22 기준 최근 daily backup job이 정상 완료됐으며 vault에 recovery point 8개가 존재합니다.

현재와 목표 정책:

| Rule | 상태 | 대상 | 주기 | 보존 | 목적 |
| --- | --- | --- | --- | --- | --- |
| RDS native automated backup | 적용 | RDS | continuous log | 7일 | PITR |
| daily-rds-snapshot | 적용 | RDS | daily | 7일 | 일 단위 복구/검증 |
| daily-rds-copy | 배포·on-demand copy 검증 완료 | RDS recovery point | daily | 14일 | 도쿄 리전 장애 복구 |

비용 고려:

- AWS Backup은 사용한 백업 스토리지, 리전 간 전송, 복구 데이터량 등을 기준으로 비용이 발생합니다.
- RDS continuous backup은 최대 35일 PITR을 지원합니다.
- continuous backup은 cold storage 전환 대상이 아닙니다.
- snapshot은 장기 보존이 가능하지만 보존 기간이 길수록 비용이 늘어납니다.
- dev 환경에서는 짧은 보존 기간으로 시작하고, 발표에서는 운영 기준안을 별도로 설명합니다.

남은 구현:

1. 다음 scheduled daily copy 자동 생성 확인
2. 도쿄 복원용 네트워크와 DB subnet group 준비
3. 도쿄 recovery point 복원 리허설

## 7. 리전 DR 전략

선정 DR 리전:

- `ap-northeast-1` Tokyo

선택 기준:

- 서울 리전과 물리적으로 분리되어야 합니다.
- 네트워크 지연이 너무 크지 않아야 합니다.
- 필요한 AWS 서비스가 모두 지원되어야 합니다.
- 비용과 운영 난이도를 감당할 수 있어야 합니다.

추천 모델:

| 모델 | 설명 | 비용 | RTO | 추천 여부 |
| --- | --- | ---: | ---: | --- |
| Backup & Restore | 백업만 타 리전에 보관, 장애 시 새로 복원 | 낮음 | 김 | 최소 전략 |
| Pilot Light | 네트워크/백업/기본 리소스만 준비 | 낮음~중간 | 중간 | 추천 |
| Warm Standby | 축소된 EKS/RDS/Valkey를 미리 운영 | 중간~높음 | 짧음 | 운영 고도화 |
| Active-Active | 두 리전에서 동시에 서비스 | 높음 | 매우 짧음 | 현재 범위 밖 |

현재 프로젝트에는 Pilot Light를 추천합니다.

현재 성숙도:

- 데이터 Pilot Light: 완료
  - 도쿄 KMS key, Backup vault, 암호화 recovery point 상시 보관
- 네트워크 Pilot Light: 구현·배포 완료
  - 도쿄 VPC, 2개 AZ subnet, DB subnet group, app/RDS security group
- Compute Pilot Light: 아직 미구현
  - EKS, EC2 검증 인스턴스, Valkey, SQS는 장애 또는 리허설 시 생성

도쿄 recovery point에서 private RDS를 복원하고 임시 SSM EC2로 데이터를 검증해 데이터 복구 경로까지 증명했습니다. 다만 전체 서비스 복구에는 EKS, Valkey, SQS, backend와 endpoint 전환 검증이 남아 있습니다.

Pilot Light 구성:

- DR 리전 VPC/Subnet Terraform 구현·배포 완료
- DR EKS 이름 `baselink-dev-tokyo`와 subnet discovery tag 고정
- 평상시 비활성, DR 선언 시에만 단일 NAT를 생성하는 activation 입력 준비
- DR 리전 ECR repository 또는 replication 준비
- RDS snapshot cross-region copy
- frontend S3 replication 또는 배포 산출물 재배포 절차
- Terraform DR tfvars 준비
- GitOps manifest는 동일 repo 사용
- CloudFront origin 전환 절차 준비

구현 완료 기준:

- 서울 daily backup이 도쿄 vault에 자동 복사됩니다.
- 도쿄 recovery point에서 새 RDS를 복원할 수 있습니다.
- DR용 Terraform 입력값으로 VPC, EKS, Valkey, SQS의 plan이 생성됩니다.
- ECR 이미지와 필수 secret/config의 복구 경로가 존재합니다.
- 임시 backend가 복원 DB에 연결되고 핵심 API smoke test를 통과합니다.
- endpoint 전환과 원복 절차, 측정 RPO/RTO가 Runbook에 기록됩니다.

리전 장애 복구 순서:

```text
1. 서울 리전 장애 범위 확인
2. DR 선언
3. DR 리전 Terraform apply
4. RDS snapshot 또는 AWS Backup recovery point로 DB 복원
5. Valkey/SQS 재생성
6. EKS addon/backend 배포
7. backend-secret/config endpoint를 DR 리전 값으로 교체
8. Flyway migration 상태 확인
9. smoke test
10. CloudFront/API origin 또는 DNS 전환
11. 사용자 공지 및 모니터링
```

## 8. 우선순위

### P0: 복구 가능성 증명

- 백업/DR 문서와 실제 구성 동기화 — 완료
- Backup/Restore 실패 EventBridge와 SNS 배포 — 완료
- RDS PITR 복원 리허설 — 완료
- 복원 DB endpoint를 이용한 backend smoke test — 완료
- 실제 측정 RPO/RTO와 복구 증거 기록 — 완료
- Slack 테스트 메시지 화면 확인 — 완료

### P1: 도쿄 Pilot Light

- 도쿄 backup vault와 RDS cross-region copy — 배포 및 실제 copy 검증 완료
- 도쿄 VPC, subnet, DB subnet group, security group — Terraform 배포 및 확인 완료
- 도쿄 recovery point 복원과 데이터 검증 — 완료, RDS 약 8분 40초·검증까지 약 16분 32초
- Compute 활성화와 endpoint 전환 Runbook — 작성 완료
- ECR cross-region replication
- 별도 DR compute state와 EKS/Valkey/SQS 구현
- GitOps `overlays/dr-tokyo` 구현

### P2: 운영 고도화

- S3 cross-region replication
- Valkey snapshot과 failover 리허설
- Route 53 또는 CloudFront 자동 failover
- Vault Lock과 별도 백업 계정
- 정기 전체 DR 훈련

## 9. 발표 포인트

- 단일 AZ 장애는 RDS Multi-AZ, Valkey Multi-AZ, EKS 다중 AZ 배포로 대응합니다.
- 데이터 손상은 RDS PITR과 Flyway migration 이력으로 복구합니다.
- 비동기 처리 실패는 SQS DLQ와 redrive 절차로 격리하고 재처리합니다.
- 리전 장애는 Pilot Light 전략으로 접근하며, 핵심 데이터는 AWS Backup cross-region copy로 보호하는 방향을 제시합니다.
- 비용을 고려해 dev 환경에는 최소 보존 정책을 적용하고, 운영 환경 기준은 별도 목표로 정의합니다.

## 10. 참고

- DR 발표 요약: `docs/disaster-recovery-presentation-summary.md`
- 도쿄 Compute와 Endpoint 전환: `docs/tokyo-dr-compute-cutover-runbook.md`
- AWS Backup continuous backup과 PITR: https://docs.aws.amazon.com/aws-backup/latest/devguide/point-in-time-recovery.html
- AWS Backup cross-region backup copy: https://docs.aws.amazon.com/aws-backup/latest/devguide/cross-region-backup.html
- AWS Backup pricing: https://aws.amazon.com/backup/pricing/
- Amazon RDS automated backups: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithAutomatedBackups.html
- DB Connection Pool 관리 전략: `docs/db-connection-pool-strategy.md`
- RDS PITR 복구 절차: `modules/rds/RUNBOOK.md`
- 운영 알람 Runbook: `docs/ops-alarm-runbook.md`
