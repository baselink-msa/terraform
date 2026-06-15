# AWS Backup 설계

이 문서는 Baselink 프로젝트의 AWS Backup 도입 설계를 정리합니다.

목표는 RDS PostgreSQL 백업을 중앙 정책으로 관리하고, 이후 리전 DR 전략으로 확장할 수 있는 기반을 만드는 것입니다.

## 1. 도입 목적

현재 RDS는 자체 automated backup/PITR 설정을 사용합니다. AWS Backup을 추가하면 다음 장점이 있습니다.

- 백업 정책을 Terraform으로 표준화할 수 있습니다.
- backup vault, backup plan, backup selection을 한 곳에서 관리할 수 있습니다.
- 태그 기반으로 백업 대상을 선택할 수 있습니다.
- 필요 시 cross-region copy로 DR 리전에 백업을 보관할 수 있습니다.
- on-demand backup과 restore 테스트를 운영 절차로 만들 수 있습니다.

AWS Backup은 장애를 막는 기능이 아니라, 장애 이후 복구 가능한 지점을 안정적으로 관리하는 기능입니다.

## 2. 공식 동작 기준

AWS Backup은 RDS에 대해 continuous backup과 PITR을 지원합니다.

- continuous backup은 최초 full backup 이후 transaction log를 계속 백업해 특정 시점으로 복구할 수 있게 합니다.
- PITR은 최대 35일까지 사용할 수 있습니다.
- AWS Backup 문서에서는 continuous backup과 snapshot backup을 함께 사용하는 것을 권장합니다.
- on-demand backup은 특정 시점의 snapshot이며, PITR처럼 기간 내 임의 시점으로 되감는 방식은 아닙니다.
- continuous backup은 cold storage 전환을 지원하지 않습니다.
- RDS continuous backup을 AWS Backup이 관리하면 RDS automated backup window 제어 방식에 영향이 있습니다.

참고:

- AWS Backup PITR: https://docs.aws.amazon.com/aws-backup/latest/devguide/point-in-time-recovery.html
- AWS Backup Cross-Region Copy: https://docs.aws.amazon.com/aws-backup/latest/devguide/cross-region-backup.html
- AWS Backup Pricing: https://aws.amazon.com/backup/pricing/

## 3. 적용 범위

### 이번 단계

이번 단계에서는 RDS PostgreSQL을 AWS Backup 대상으로 설계합니다.

대상:

- `baselink-dev-postgres`

제외:

- Valkey ElastiCache: ElastiCache snapshot retention으로 별도 관리
- SQS: 메시지 보존, DLQ, redrive로 관리
- EKS workload: GitOps와 ECR 이미지로 재배포
- Frontend S3: S3 versioning/replication 별도 검토

### 향후 확장

- RDS cross-region copy
- Frontend S3 backup 또는 replication
- Terraform state bucket versioning 점검
- Secrets Manager 복제 또는 재생성 절차

## 4. Backup 전략

dev 환경은 비용을 줄이는 것이 중요하므로 처음부터 모든 DR 기능을 켜지 않습니다.

| 구분 | dev 적용안 | 운영 가정 |
| --- | --- | --- |
| Backup vault | 1개 | 환경별 또는 계정별 분리 |
| Continuous backup | 7일 | 7~35일 |
| Daily snapshot | 7일 | 14~30일 |
| Cross-region copy | 초기에는 비활성 | 활성 권장 |
| Cold storage | 사용 안 함 | 장기 보존 snapshot에 한해 검토 |
| Backup selection | 태그 기반 | 태그 기반 |
| Restore test | 수동 리허설 | 정기 리허설 |

## 5. RPO/RTO

| 장애 상황 | 목표 RPO | 목표 RTO | 복구 방식 |
| --- | ---: | ---: | --- |
| RDS 인스턴스 장애 | 수초~수분 | 수분 | Multi-AZ failover |
| 데이터 실수 삭제 | 5분 이내 | 30~60분 | PITR로 새 DB 복원 |
| 잘못된 migration | 5분 이내 | 30~60분 | migration 전 시점 PITR |
| 서울 리전 장애 | 일 단위 snapshot 기준 | 수 시간 | DR 리전 snapshot restore |

리전 장애에 대한 RPO/RTO는 cross-region copy를 실제로 켠 뒤 다시 조정합니다.

## 6. Terraform 구조

추천 구조:

```text
modules/backup/
  main.tf
  variables.tf
  outputs.tf
  README.md

env/dev/infra/
  main.tf
```

처음에는 `env/dev/infra`에서 RDS와 함께 AWS Backup 모듈을 호출합니다.

이유:

- RDS ARN과 태그를 같은 infra layer에서 참조하기 쉽습니다.
- dev 환경에서는 별도 backup layer를 두기보다 리뷰와 적용 흐름이 단순합니다.
- 나중에 backup 대상이 늘어나면 `env/dev/backup` 레이어로 분리할 수 있습니다.

## 7. Terraform 리소스 설계

생성할 리소스:

- `aws_backup_vault`
- `aws_backup_plan`
- `aws_backup_selection`
- `aws_iam_role`
- `aws_iam_role_policy_attachment`

초기 plan rule:

| Rule | schedule | lifecycle | 목적 |
| --- | --- | --- | --- |
| `continuous-rds-7d` | continuous | delete after 7 days | PITR |
| `daily-rds-snapshot-7d` | cron daily | delete after 7 days | 일 단위 복구/검증 |

주의:

- AWS Backup continuous backup은 RDS automated backup 설정과 역할이 겹칠 수 있습니다.
- 기존 RDS `backup_retention_period = 7`과 AWS Backup continuous backup을 동시에 어떻게 운영할지 팀 리뷰가 필요합니다.
- AWS Backup이 continuous backup을 관리하면 RDS backup window 제어 방식이 달라질 수 있습니다.

따라서 첫 Terraform 구현은 두 가지 방식 중 하나를 선택합니다.

### 방식 A: Snapshot backup부터 도입

특징:

- AWS Backup vault/plan/selection을 먼저 검증합니다.
- RDS native PITR은 현재 설정을 유지합니다.
- AWS Backup은 daily snapshot만 담당합니다.
- 기존 RDS backup window 정책과 충돌 가능성이 낮습니다.

추천:

- dev 첫 적용에는 방식 A를 추천합니다.
- 이번 Terraform 구현은 방식 A를 적용합니다.

### 방식 B: AWS Backup continuous backup까지 도입

특징:

- AWS Backup이 RDS PITR 관리까지 담당합니다.
- 중앙 백업 정책 관점에서는 더 일관됩니다.
- 기존 RDS automated backup 설정과 운영 방식이 달라질 수 있습니다.
- 최초 PITR 활성화나 retention 변경은 maintenance window 영향을 받을 수 있습니다.

추천:

- 방식 A 검증 후 운영 가정으로 확장할 때 검토합니다.

## 8. 비용 고려

비용 항목:

- 백업 스토리지 사용량
- cross-region copy 시 리전 간 데이터 전송과 대상 리전 저장 비용
- restore 시 복원 데이터 비용 또는 복구 대상 리소스 비용
- 장기 보존 snapshot 비용

dev 비용 절감 원칙:

- snapshot retention은 7일로 시작합니다.
- cross-region copy는 설계만 먼저 하고 바로 켜지 않습니다.
- on-demand backup은 리허설이 필요할 때만 생성합니다.
- 복원 테스트 후 생성된 RDS restore instance는 즉시 정리합니다.

## 9. Restore 테스트 계획

테스트 목적:

- recovery point가 실제 생성되는지 확인합니다.
- snapshot restore로 새 RDS를 만들 수 있는지 확인합니다.
- 복원 DB에 접속해 schema와 핵심 데이터가 있는지 확인합니다.
- 테스트 후 복원 DB를 삭제합니다.

테스트 절차:

```text
1. AWS Backup recovery point 생성 확인
2. restore job 시작
3. 새 RDS instance available 대기
4. 보안 그룹과 subnet 설정 확인
5. Flyway schema history 확인
6. 경기/좌석/예매 핵심 테이블 row count 확인
7. 테스트 결과 문서화
8. restore instance 삭제
```

## 10. Cross-Region DR 확장안

초기 구현에서는 cross-region copy를 비활성화합니다.

향후 활성화 기준:

- 팀이 DR 리전을 확정합니다.
- DR 리전 backup vault를 생성합니다.
- KMS key와 IAM role을 준비합니다.
- cross-region copy retention을 정합니다.

추천 DR 리전:

- 1순위: `ap-northeast-1` Tokyo
- 2순위: `ap-southeast-1` Singapore

cross-region copy 정책 예시:

| 항목 | 값 |
| --- | --- |
| Source region | `ap-northeast-2` |
| Destination region | `ap-northeast-1` |
| Copy 대상 | daily RDS snapshot |
| Retention | 14~30일 |
| Continuous backup copy | transaction log copy가 아닌 snapshot copy 기준 |

## 11. 구현 우선순위

1. AWS Backup 설계 문서 리뷰
2. `modules/backup` 작성
3. dev infra에서 RDS daily snapshot backup 적용
4. backup vault와 recovery point 생성 확인
5. on-demand restore 리허설
6. cross-region copy 설계 확정
7. cross-region copy Terraform 추가

## 12. 발표 포인트

- RDS 자체 PITR만 사용하는 것이 아니라 AWS Backup을 통해 중앙 백업 정책을 설계했습니다.
- dev 환경에서는 비용을 고려해 daily snapshot부터 시작하고, 운영 환경에서는 continuous backup과 cross-region copy로 확장할 수 있게 설계했습니다.
- RPO/RTO를 먼저 정의한 뒤 backup retention과 restore 절차를 결정했습니다.
- 리전 장애에 대비해 DR 리전에 snapshot copy를 보관하는 방향을 제시했습니다.
