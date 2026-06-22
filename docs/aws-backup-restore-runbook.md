# AWS Backup Restore Runbook

이 문서는 AWS Backup recovery point를 사용해 `baselink-dev-postgres` RDS PostgreSQL을 새 RDS 인스턴스로 복원하고 검증하는 절차를 정리합니다.

AWS Backup restore는 기존 DB를 직접 덮어쓰지 않습니다. recovery point를 기준으로 새 RDS 인스턴스를 만들고, 복원된 DB를 검증한 뒤 필요한 경우 애플리케이션 연결 전환 또는 데이터 비교를 진행합니다.

## 1. 사용 상황

AWS Backup restore는 다음 상황에서 사용합니다.

- RDS daily snapshot 기준으로 DB를 복원해야 할 때
- on-demand backup으로 만든 특정 복구 지점을 검증해야 할 때
- PITR이 아니라 명확한 snapshot 시점으로 복구해도 충분할 때
- DR 리허설에서 백업이 실제 복구 가능한지 검증할 때

PITR이 필요한 상황:

- 특정 시각 직전으로 복원해야 할 때
- 잘못된 SQL 실행 직전 상태가 필요할 때
- snapshot 생성 시각보다 더 세밀한 복구 시점이 필요할 때

PITR 절차는 `modules/rds/RUNBOOK.md`를 따릅니다.

## 2. 현재 백업 구성

현재 dev 환경의 AWS Backup 구성은 다음과 같습니다.

| 항목 | 값 |
| --- | --- |
| Backup vault | `baselink-dev-backup-vault` |
| Backup plan | `baselink-dev-backup-plan` |
| Backup selection | `baselink-dev-backup-selection` |
| Backup role | `arn:aws:iam::740831361032:role/baselink-dev-backup-role` |
| 대상 RDS | `arn:aws:rds:ap-northeast-2:740831361032:db:baselink-dev-postgres` |
| 자동 백업 시간 | 매일 KST 04:00 |
| 보존 기간 | 7일 |

검증된 recovery point 예시:

| 종류 | 생성 시각 | 상태 | 삭제 예정 |
| --- | --- | --- | --- |
| 자동 daily backup | 2026-06-16 04:00 KST | `COMPLETED` | 2026-06-23 04:00 KST |
| on-demand backup | 2026-06-16 11:43 KST | `COMPLETED` | 2026-06-23 11:43 KST |

## 3. 복구 전 확인

복구 작업 전 아래를 확인합니다.

1. 어떤 recovery point로 복원할지 결정합니다.
2. 복원 DB 이름을 정합니다.
3. 복원 DB가 사용할 subnet group과 security group을 확인합니다.
4. 복원 DB 생성 비용과 삭제 일정을 팀에 공유합니다.
5. 기존 운영 DB를 직접 수정하지 않는다는 점을 확인합니다.

권장 복원 DB 이름:

```text
baselink-dev-postgres-restore-YYYYMMDD-HHMM
```

예시:

```powershell
$targetDb = "baselink-dev-postgres-restore-20260616-1143"
```

## 4. Recovery Point 조회

Backup vault에 있는 recovery point 목록을 조회합니다.

```powershell
aws backup list-recovery-points-by-backup-vault `
  --backup-vault-name baselink-dev-backup-vault `
  --query "RecoveryPoints[].{Status:Status,Created:CreationDate,DeleteAt:CalculatedLifecycle.DeleteAt,ResourceArn:ResourceArn,RecoveryPointArn:RecoveryPointArn}" `
  --output table
```

확인 기준:

- `Status`가 `COMPLETED`여야 합니다.
- `ResourceArn`이 `baselink-dev-postgres` RDS를 가리켜야 합니다.
- `DeleteAt`이 지나지 않은 recovery point여야 합니다.

복원할 recovery point ARN을 변수로 저장합니다.

```powershell
$recoveryPointArn = "arn:aws:rds:ap-northeast-2:740831361032:snapshot:awsbackup:job-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

## 5. Restore Metadata 확인

AWS Backup restore job에는 RDS 복원 metadata가 필요합니다. 먼저 recovery point에서 기본 metadata를 확인합니다.

```powershell
aws backup get-recovery-point-restore-metadata `
  --backup-vault-name baselink-dev-backup-vault `
  --recovery-point-arn $recoveryPointArn `
  --query "RestoreMetadata"
```

metadata에는 기존 DB의 subnet group, security group, engine, instance class 같은 값이 포함될 수 있습니다.

복원 테스트에서는 기존 운영 DB와 충돌하지 않도록 `DBInstanceIdentifier`를 새 이름으로 바꿉니다.
또한 복원 테스트 DB는 검증 후 삭제해야 하므로 `DeletionProtection`을 `false`로 둡니다.

## 6. Restore Job 시작

아래 예시는 기존 metadata를 참고해 새 RDS 인스턴스로 복원하는 흐름입니다.

먼저 필요한 값을 확인합니다.

```powershell
aws rds describe-db-instances `
  --db-instance-identifier baselink-dev-postgres `
  --query "DBInstances[0].{DBSubnetGroup:DBSubnetGroup.DBSubnetGroupName,SecurityGroups:VpcSecurityGroups[].VpcSecurityGroupId,DBInstanceClass:DBInstanceClass,Engine:Engine,MultiAZ:MultiAZ,PubliclyAccessible:PubliclyAccessible}"
```

복원 job을 시작합니다.

```powershell
$targetDb = "baselink-dev-postgres-restore-20260616-1143"
$backupRoleArn = "arn:aws:iam::740831361032:role/baselink-dev-backup-role"

$metadata = @{
  DBInstanceIdentifier = $targetDb
  DBInstanceClass      = "db.t4g.micro"
  DBSubnetGroupName    = "baselink-dev-rds"
  VpcSecurityGroupIds  = '["sg-xxxxxxxxxxxxxxxxx"]'
  PubliclyAccessible   = "false"
  MultiAZ              = "false"
  DeletionProtection   = "false"
} | ConvertTo-Json -Compress

aws backup start-restore-job `
  --recovery-point-arn $recoveryPointArn `
  --iam-role-arn $backupRoleArn `
  --resource-type RDS `
  --metadata $metadata `
  --query "{RestoreJobId:RestoreJobId}" `
  --output table
```

주의:

- `VpcSecurityGroupIds`는 실제 RDS security group ID로 바꿉니다.
- `VpcSecurityGroupIds` 값은 JSON 배열 문자열 형태입니다. 예: `'["sg-0333b09e68319fd15"]'`
- 복구 리허설에서는 비용 절감을 위해 `MultiAZ = false`로 복원할 수 있습니다.
- 실제 장애 복구에서는 운영 기준에 맞춰 Multi-AZ 여부를 결정합니다.
- 복원 DB는 기존 DB와 endpoint가 다릅니다.
- 복원 테스트 DB는 삭제 정리를 위해 `DeletionProtection = false`로 둡니다.

## 7. Restore Job 상태 확인

restore job ID를 변수로 저장합니다.

```powershell
$restoreJobId = "<restore-job-id>"
```

상태를 확인합니다.

```powershell
aws backup describe-restore-job `
  --restore-job-id $restoreJobId `
  --query "{JobId:RestoreJobId,Status:Status,StatusMessage:StatusMessage,Created:CreationDate,Completed:CompletionDate,ResourceArn:CreatedResourceArn}" `
  --output table
```

`Status`가 `COMPLETED`가 될 때까지 기다립니다.

RDS 인스턴스 상태도 확인합니다.

```powershell
aws rds wait db-instance-available `
  --db-instance-identifier $targetDb

aws rds describe-db-instances `
  --db-instance-identifier $targetDb `
  --query "DBInstances[0].{Identifier:DBInstanceIdentifier,Status:DBInstanceStatus,Endpoint:Endpoint.Address,Engine:Engine,EngineVersion:EngineVersion,MultiAZ:MultiAZ}"
```

## 8. 복원 DB 접속 확인

복원 DB endpoint를 변수로 저장합니다.

```powershell
$restoreEndpoint = "<restore-endpoint>"
```

EKS 안에서 임시 `psql` pod로 접속을 확인합니다.

```powershell
kubectl run psql-aws-backup-restore-check `
  -n baselink-dev `
  --rm -i `
  --restart=Never `
  --image=postgres:16-alpine `
  -- psql "postgresql://<user>:<password>@$restoreEndpoint:5432/baseball_platform?sslmode=require" `
  -c "select now();"
```

접속이 안 되면 다음을 확인합니다.

- 복원 DB security group
- subnet group
- EKS node security group에서 5432 접근 허용 여부
- DB 사용자/비밀번호
- SSL mode

## 9. Schema와 데이터 검증

주요 schema 확인:

```sql
select schema_name
from information_schema.schemata
where schema_name in ('auth_schema', 'game_schema', 'ticket_schema', 'order_schema', 'chatbot_schema')
order by schema_name;
```

Flyway 이력 확인:

```sql
select installed_rank, version, description, success, installed_on
from flyway_schema_history
order by installed_rank desc
limit 10;
```

주요 테이블 row count 확인:

```sql
select 'users' as table_name, count(*) from auth_schema.users
union all
select 'games', count(*) from game_schema.games
union all
select 'stadiums', count(*) from game_schema.stadiums
union all
select 'seats', count(*) from game_schema.seats
union all
select 'game_seats', count(*) from game_schema.game_seats
union all
select 'reservations', count(*) from ticket_schema.reservations;
```

검증 기준:

- schema가 모두 존재합니다.
- Flyway 이력이 존재하고 실패 migration이 없습니다.
- 핵심 테이블 row count가 예상 범위입니다.
- 복원 시점 이후 생성된 데이터가 없는 것은 정상입니다.

## 10. 애플리케이션 전환 판단

복원 DB를 바로 운영 DB로 바꾸지 않습니다.

전환이 필요한 경우:

1. 복원 DB 데이터가 정상인지 검증합니다.
2. 기존 운영 DB와 차이를 비교합니다.
3. 손실 가능한 데이터 범위를 팀에 공유합니다.
4. backend-secret 또는 External Secrets 값을 새 endpoint로 전환하는 PR을 준비합니다.
5. GitOps 배포 후 smoke test를 수행합니다.
6. 문제가 있으면 기존 endpoint로 rollback합니다.

일반 복구 리허설에서는 endpoint 전환을 하지 않습니다.

## 11. 복원 DB 정리

복구 리허설이 끝나면 복원 DB를 삭제합니다.

주의:

- 복원 DB 삭제 전 검증 결과를 문서화합니다.
- 운영 DB가 아니라 복원 DB인지 identifier를 다시 확인합니다.
- 복원 DB도 비용이 발생하므로 테스트 후 오래 두지 않습니다.

복원 DB 삭제:

```powershell
aws rds delete-db-instance `
  --db-instance-identifier $targetDb `
  --skip-final-snapshot
```

삭제 완료 대기:

```powershell
aws rds wait db-instance-deleted `
  --db-instance-identifier $targetDb
```

## 12. 테스트 결과 기록 양식

```text
테스트 일시:
수행자:
Recovery point ARN:
Recovery point 생성 시각:
Restore job ID:
복원 DB identifier:
복원 DB endpoint:
복원 완료 시각:

검증 결과:
- DB 접속:
- schema 확인:
- Flyway 이력:
- 주요 테이블 row count:
- 애플리케이션 전환 여부:

정리 결과:
- 복원 DB 삭제:
- 남은 리소스:
- 특이사항:
```

## 13. 현재 검증 상태

2026-06-22 기준으로 다음은 검증 완료되었습니다.

- AWS Backup vault 생성 확인
- AWS Backup plan 생성 확인
- AWS Backup selection 생성 확인
- 자동 daily backup recovery point 생성 확인
- on-demand backup job 생성 및 `COMPLETED` 확인
- recovery point에서 새 RDS 인스턴스로 restore
- 복원 DB 접속 확인
- schema와 데이터 검증
- 복원 DB 삭제 정리

운영 상태 확인:

- 2026-06-16부터 2026-06-22까지 daily backup job 연속 완료
- 최신 2026-06-22 04:00 KST 작업은 04:28 KST 완료
- `baselink-dev-backup-vault` recovery point 8개 확인

아직 남은 검증:

- 도쿄 리전 cross-region recovery point 복사와 복원
- Backup/Restore 테스트 메시지의 Slack 화면 확인

RDS native PITR와 복원 endpoint 기반 임시 backend smoke test는 2026-06-22 완료했습니다. 상세 결과는 `modules/rds/RUNBOOK.md`의 실제 리허설 결과를 따릅니다.

## 14. 관련 문서

- AWS Backup 설계: `docs/aws-backup-design.md`
- 전체 DR 전략: `docs/disaster-recovery-strategy.md`
- RDS PITR Runbook: `modules/rds/RUNBOOK.md`
- RDS 모듈 설명: `modules/rds/README.md`

## 15. 실제 복구 리허설 결과 - 2026-06-16

2026-06-16에 AWS Backup recovery point를 사용해 임시 RDS 복구 리허설을 수행했습니다.

테스트 개요:

- 수행자: Data & Async Processing 담당
- 백업 vault: `baselink-dev-backup-vault`
- Recovery point ARN: `arn:aws:rds:ap-northeast-2:740831361032:snapshot:awsbackup:job-4f2de47f-ec5b-44fa-b6bf-b17237ee958b`
- Recovery point 생성 시각: 2026-06-16 11:43:37 KST
- Restore job ID: `ac3abb77-f3fa-41c7-a5c4-2d94bbb7bbe1`
- 복원 DB identifier: `baselink-dev-postgres-restore-20260616`
- 복원 DB endpoint: `baselink-dev-postgres-restore-20260616.cves8emympgn.ap-northeast-2.rds.amazonaws.com`
- 복원 완료 시각: 2026-06-16 15:50:55 KST
- Restore job 결과: `COMPLETED`

복원 옵션:

- `DBInstanceClass`: `db.t4g.micro`
- `MultiAZ`: `false`
- `DeletionProtection`: `false`
- `PubliclyAccessible`: `false`
- `DBSubnetGroupName`: `baselink-dev-rds`
- `VpcSecurityGroupIds`: `["sg-0333b09e68319fd15"]`

검증 결과:

- EKS 내부 `baselink-dev` namespace에서 임시 `postgres:16-alpine` Pod로 복원 DB 접속 성공
- database: `baseball_platform`
- user: `baseball`
- 확인된 schema/table 수:
  - `auth_schema`: 2 tables
  - `chatbot_schema`: 1 table
  - `game_schema`: 3 tables
  - `ticket_schema`: 5 tables
- 주요 데이터 row count:
  - `auth_schema.users`: 5
  - `chatbot_schema.faq`: 7
  - `game_schema.games`: 3
  - `game_schema.seat_sections`: 25
  - `game_schema.stadiums`: 5
  - `ticket_schema.seats`: 1000
  - `ticket_schema.game_seats`: 600
  - `ticket_schema.reservations`: 8
- 경기 샘플 데이터 확인:
  - `두산 베어스` vs `LG 트윈스`, `TICKET_OPEN`, 2026-06-01 18:30
  - `KIA 타이거즈` vs `삼성 라이온즈`, `SCHEDULED`, 2026-06-03 18:30
  - `KIA Tigers` vs `LG Twins`, `SCHEDULED`, 2026-06-05 15:41

정리 결과:

- 임시 복원 DB 삭제 요청 완료
- 최종 확인 시 `DBInstanceNotFound` 응답으로 삭제 완료 확인
- 운영 RDS인 `baselink-dev-postgres`에는 endpoint 전환이나 데이터 변경을 수행하지 않았습니다.

리허설 중 확인한 Runbook 보완 포인트:

- PowerShell에서 `aws backup start-restore-job --metadata`에 인라인 JSON을 넘기면 따옴표가 깨질 수 있습니다.
- Windows PowerShell에서는 복구 metadata를 임시 JSON 파일로 저장한 뒤 `--metadata file://<path>` 형식으로 전달하는 방식이 더 안정적입니다.
- PowerShell의 `$Host`는 예약 변수이므로 DB endpoint 변수명으로는 `$dbHost` 같은 이름을 사용합니다.

## 16. 도쿄 Cross-Region Copy 검증 절차

Terraform 배포 후 서울의 다음 daily backup은 도쿄 `baselink-dev-tokyo-backup-vault`로 자동 복사됩니다.

서울 copy job 확인:

```powershell
aws backup list-copy-jobs `
  --region ap-northeast-2 `
  --query "CopyJobs[].{State:State,Created:CreationDate,Completed:CompletionDate,Destination:DestinationBackupVaultArn,Resource:ResourceArn,Message:StatusMessage}"
```

도쿄 vault와 recovery point 확인:

```powershell
aws backup describe-backup-vault `
  --region ap-northeast-1 `
  --backup-vault-name baselink-dev-tokyo-backup-vault

aws backup list-recovery-points-by-backup-vault `
  --region ap-northeast-1 `
  --backup-vault-name baselink-dev-tokyo-backup-vault `
  --query "RecoveryPoints[].{Arn:RecoveryPointArn,Status:Status,Created:CreationDate,ResourceType:ResourceType,Encrypted:IsEncrypted}"
```

검증 기준:

- copy job이 `COMPLETED` 상태입니다.
- destination vault ARN의 리전이 `ap-northeast-1`입니다.
- 도쿄 recovery point 보존 기간이 14일입니다.
- recovery point가 도쿄 고객 관리형 KMS key로 보호됩니다.
- 실패 시 `baselink-dev-copy-job-failure` EventBridge rule이 `aws-alerts` 채널로 알림을 보냅니다.

첫 scheduled copy를 기다리지 않고 검증해야 한다면 서울 recovery point를 선택해 on-demand copy를 실행할 수 있습니다. 실제 복원 리허설은 도쿄 VPC, DB subnet group, security group을 준비한 뒤 별도 임시 RDS identifier로 수행합니다.

### 16.1 실제 Cross-Region Copy 결과 - 2026-06-22

| 항목 | 결과 |
| --- | --- |
| Source Region | `ap-northeast-2` 서울 |
| Destination Region | `ap-northeast-1` 도쿄 |
| Copy Job ID | `4413572b-ca09-44d7-8d7d-fa95a881b702` |
| 시작 시각 | 2026-06-22 22:54:40 KST |
| 완료 시각 | 2026-06-22 23:01:46 KST |
| 소요 시간 | 약 7분 6초 |
| 결과 | `COMPLETED` |
| Destination Vault | `baselink-dev-tokyo-backup-vault` |
| 보존 | 14일, 2026-07-06 04:00 KST 삭제 예정 |
| 암호화 | 도쿄 고객 관리형 KMS key |

검증한 내용:

- 도쿄 vault에 recovery point 1개 생성
- destination recovery point 상태 `COMPLETED`
- `IsEncrypted = true`
- KMS key rotation 활성화, 365일 주기
- 서울 source recovery point는 그대로 유지
- 운영 RDS endpoint와 데이터 변경 없음

남은 검증:

- 다음 daily backup에서 scheduled copy job 자동 생성 확인
- 도쿄 네트워크와 DB subnet group 준비
- 도쿄 recovery point에서 임시 RDS 복원
- 복원 DB 데이터와 임시 backend smoke test
