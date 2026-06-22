# AWS Backup 설계

이 문서는 Baselink 프로젝트의 AWS Backup 구현과 리전 DR 확장 설계를 정리합니다.

목표는 RDS PostgreSQL 백업을 중앙 정책으로 관리하고, 이후 리전 DR 전략으로 확장할 수 있는 기반을 만드는 것입니다.

최종 상태 확인일: 2026-06-22

## 1. 도입 목적

현재 RDS는 자체 automated backup/PITR 설정을 사용합니다. AWS Backup을 추가하면 다음 장점이 있습니다.

- 백업 정책을 Terraform으로 표준화할 수 있습니다.
- backup vault, backup plan, backup selection을 한 곳에서 관리할 수 있습니다.
- 현재는 RDS ARN을 명시적으로 지정해 의도하지 않은 리소스가 백업 대상에 포함되지 않게 합니다.
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

### 현재 적용

RDS PostgreSQL을 AWS Backup 대상으로 적용했습니다.

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
| Continuous backup | RDS native PITR 7일 | 7~35일 |
| Daily snapshot | 7일 | 14~30일 |
| Cross-region copy | 초기에는 비활성 | 활성 권장 |
| Cold storage | 사용 안 함 | 장기 보존 snapshot에 한해 검토 |
| Backup selection | 명시적 RDS ARN | 태그 또는 ARN 기반 |
| Restore test | 2026-06-16 수동 리허설 완료 | 정기 리허설 |

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

## 7. Terraform 구현 상태

생성된 리소스:

- `aws_backup_vault`
- `aws_backup_plan`
- `aws_backup_selection`
- `aws_iam_role`
- `aws_iam_role_policy_attachment`

현재 plan rule:

| Rule | schedule | lifecycle | 목적 |
| --- | --- | --- | --- |
| `daily-rds-snapshot-7d` | cron daily | delete after 7 days | 일 단위 복구/검증 |

역할 분리:

- RDS native automated backup은 7일 PITR을 담당합니다.
- AWS Backup은 매일 04:00 KST snapshot과 recovery point 중앙 관리를 담당합니다.
- Backup Selection은 `module.rds.db_instance_arn`을 명시적으로 전달합니다.
- vault는 KMS key로 암호화되어 있습니다.

2026-06-22 확인 결과:

- 2026-06-16부터 2026-06-22까지 daily backup job이 연속으로 `COMPLETED` 상태입니다.
- 최신 2026-06-22 04:00 KST 작업은 04:28 KST에 완료됐습니다.
- `baselink-dev-backup-vault`에 recovery point 8개가 존재합니다.
- Backup/Copy/Restore 실패 EventBridge와 기존 ops SNS 연동을 배포하고 Slack 전달까지 검증했습니다.
- Vault Lock은 아직 적용하지 않았습니다.
- 도쿄 cross-region copy는 Terraform 구현과 plan 검증을 완료했으며 배포를 기다리고 있습니다.

## 8. 비용 고려

비용 항목:

- 백업 스토리지 사용량
- cross-region copy 시 리전 간 데이터 전송과 대상 리전 저장 비용
- restore 시 복원 데이터 비용 또는 복구 대상 리소스 비용
- 장기 보존 snapshot 비용

dev 비용 절감 원칙:

- snapshot retention은 7일로 시작합니다.
- cross-region copy는 도쿄 리전에 14일 보존으로 적용하고 비용을 관찰합니다.
- on-demand backup은 리허설이 필요할 때만 생성합니다.
- 복원 테스트 후 생성된 RDS restore instance는 즉시 정리합니다.

## 9. Restore 테스트 결과와 남은 검증

2026-06-16 완료:

- recovery point에서 `baselink-dev-postgres-restore-20260616` 임시 RDS 복원
- EKS 내부 Pod에서 PostgreSQL 접속
- 주요 schema, table, row count 검증
- 복원 DB 삭제와 잔여 리소스 정리

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

상세 복구 절차는 `docs/aws-backup-restore-runbook.md`를 따릅니다.

남은 검증:

- RDS native PITR로 임의 시점 복원
- 임시 backend deployment를 복원 DB endpoint에 연결
- 핵심 조회 API와 쓰기 차단 상태 smoke test
- 측정 RPO/RTO 기록

## 10. Cross-Region DR 구현안

DR 리전은 `ap-northeast-1` 도쿄로 정합니다.

구현 범위:

- `aws.tokyo` provider alias로 도쿄 리소스를 분리합니다.
- 고객 관리형 KMS key와 `baselink-dev-tokyo-backup-vault`를 생성합니다.
- 서울 daily rule에 도쿄 vault 대상 `copy_action`을 추가합니다.
- 서울 recovery point는 7일, 도쿄 복사본은 14일 보존합니다.
- Backup/Copy/Restore 실패 이벤트를 기존 ops SNS와 Slack으로 전달합니다.

Terraform 구현 상태:

- `modules/backup`에 선택적 `copy_destination_vault_arn`과 `copy_delete_after_days`를 추가했습니다.
- 도쿄 KMS key는 rotation을 활성화하고 삭제 대기 기간을 30일로 설정했습니다.
- 도쿄 vault와 KMS key ARN을 Terraform output으로 노출했습니다.
- 격리 plan 결과는 리소스 3개 생성, 기존 backup plan 1개 제자리 수정, 삭제 0입니다.
- 첫 자동 copy는 배포 이후 다음 daily backup부터 발생합니다.

cross-region copy 정책 예시:

| 항목 | 값 |
| --- | --- |
| Source region | `ap-northeast-2` |
| Destination region | `ap-northeast-1` |
| Copy 대상 | daily RDS snapshot |
| Retention | dev 14일 |
| Continuous backup copy | transaction log copy가 아닌 snapshot copy 기준 |

## 11. 구현 우선순위

1. 현재 구성과 문서 동기화
2. Backup/Restore 실패 알림 배포와 Slack 전달 검증
3. RDS native PITR와 backend smoke test
4. 도쿄 backup vault와 cross-region copy 배포 및 copy job 확인
5. 도쿄 recovery point 복원 리허설
6. DR 인프라 Terraform plan과 endpoint 전환 Runbook

## 12. 발표 포인트

- RDS 자체 PITR만 사용하는 것이 아니라 AWS Backup을 통해 중앙 백업 정책을 설계했습니다.
- dev 환경에서는 RDS native PITR과 AWS Backup daily snapshot의 역할을 분리했고, 실제 복원 리허설로 recovery point가 사용 가능한지 검증했습니다.
- RPO/RTO를 먼저 정의한 뒤 backup retention과 restore 절차를 결정했습니다.
- 도쿄 KMS/vault와 scheduled copy를 코드화했으며, 다음 단계에서 실제 copy job과 도쿄 recovery point 복원을 검증합니다.
