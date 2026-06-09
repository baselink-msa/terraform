# RDS PITR 복구 Runbook

이 문서는 `baselink-dev-postgres` RDS PostgreSQL 인스턴스의 PITR(Point-In-Time Recovery) 복구 절차를 정리합니다.

PITR은 기존 DB를 직접 롤백하지 않습니다. 특정 시점의 새 RDS 인스턴스를 생성한 뒤, 복원된 DB를 검증하고 필요한 복구 방식을 선택합니다.

## 1. 장애 상황 판단

PITR은 다음 상황에서 사용합니다.

- 실수로 데이터가 삭제된 경우
- 잘못된 배포나 migration으로 데이터가 오염된 경우
- 특정 시점의 DB 상태를 기준으로 데이터 비교가 필요한 경우

RDS 인스턴스 자체 장애는 먼저 Multi-AZ failover 상태를 확인합니다. Multi-AZ는 서버 장애 대응이고, PITR은 데이터 실수나 오염 복구에 사용합니다.

## 2. 현재 PITR 가능 여부 확인

```powershell
aws rds describe-db-instances `
  --db-instance-identifier baselink-dev-postgres `
  --query "DBInstances[0].{Status:DBInstanceStatus,BackupRetentionPeriod:BackupRetentionPeriod,LatestRestorableTime:LatestRestorableTime,PendingModifiedValues:PendingModifiedValues,MultiAZ:MultiAZ}"
```

확인 기준:

- `BackupRetentionPeriod`가 1 이상이어야 합니다.
- `LatestRestorableTime`이 `null`이 아니어야 합니다.
- `PendingModifiedValues.BackupRetentionPeriod`가 남아 있으면 아직 자동 백업 보존 설정이 완전히 반영되지 않은 상태입니다.

## 3. 복원 시점 결정

문제 발생 시각을 확인한 뒤, 그 직전 시점을 복원 시점으로 정합니다.

예시:

```text
문제 발생: 2026-06-09 11:10:00 KST
복원 시점: 2026-06-09 11:09:30 KST
```

AWS CLI는 UTC 시간을 사용합니다. KST는 UTC보다 9시간 빠릅니다.

```text
2026-06-09 11:09:30 KST
= 2026-06-09 02:09:30 UTC
```

## 4. PITR로 새 RDS 인스턴스 생성

복원 DB 식별자는 기존 DB와 달라야 합니다.

```powershell
$restoreTime = "2026-06-09T02:09:30Z"
$targetDb = "baselink-dev-postgres-restore-20260609"

aws rds restore-db-instance-to-point-in-time `
  --source-db-instance-identifier baselink-dev-postgres `
  --target-db-instance-identifier $targetDb `
  --restore-time $restoreTime `
  --use-latest-restorable-time false
```

가장 최근 복원 가능 시점으로 복원하려면 다음을 사용합니다.

```powershell
aws rds restore-db-instance-to-point-in-time `
  --source-db-instance-identifier baselink-dev-postgres `
  --target-db-instance-identifier $targetDb `
  --use-latest-restorable-time
```

주의:

- 새 RDS 인스턴스가 생성되므로 비용이 추가됩니다.
- 복원된 DB는 기존 DB와 endpoint가 다릅니다.
- 보안 그룹, subnet group, parameter group 등은 복원 결과를 확인한 뒤 필요하면 조정합니다.

## 5. 복원 완료 대기

```powershell
aws rds wait db-instance-available `
  --db-instance-identifier $targetDb
```

복원 DB endpoint 확인:

```powershell
aws rds describe-db-instances `
  --db-instance-identifier $targetDb `
  --query "DBInstances[0].{Endpoint:Endpoint.Address,Status:DBInstanceStatus,Engine:Engine,EngineVersion:EngineVersion}"
```

## 6. 복원 DB 접속 확인

복원 DB가 기존 RDS 보안 그룹을 그대로 사용하지 않을 수 있습니다. 접속이 안 되면 보안 그룹과 subnet group을 먼저 확인합니다.

EKS 안에서 임시 `psql` pod를 띄워 확인할 수 있습니다.

```powershell
kubectl run psql-restore-check `
  -n baselink-dev `
  --rm -i `
  --restart=Never `
  --image=postgres:16-alpine `
  -- psql "postgresql://<user>:<password>@<restore-endpoint>:5432/baseball_platform?sslmode=require" `
  -c "select now();"
```

## 7. Schema와 데이터 검증

주요 schema 확인:

```sql
select schema_name
from information_schema.schemata
where schema_name in ('auth_schema', 'game_schema', 'ticket_schema', 'order_schema', 'chatbot_schema')
order by schema_name;
```

주요 데이터 확인:

```sql
select count(*) from auth_schema.users;
select count(*) from game_schema.games;
select count(*) from game_schema.stadiums;
select count(*) from ticket_schema.seats;
select count(*) from ticket_schema.game_seats;
select count(*) from ticket_schema.reservations;
```

Flyway 상태 확인:

```sql
select installed_rank, version, description, type, success, installed_on
from public.flyway_schema_history
order by installed_rank;
```

## 8. 복구 방식 선택

복원 DB 검증 후 아래 방식 중 하나를 선택합니다.

### 일부 데이터만 복구

특정 테이블이나 특정 행만 복구해야 한다면 복원 DB에서 필요한 데이터를 추출해 기존 DB에 반영합니다.

예시:

```text
복원 DB에서 누락된 reservation 확인
-> 기존 DB에 필요한 reservation만 재삽입
-> 중복/상태 충돌 검증
```

이 방식은 서비스 endpoint 변경이 없어 영향이 작지만, 수동 데이터 보정 절차가 필요합니다.

### 애플리케이션 연결 전환

기존 DB 전체가 오염되었고 복원 DB가 더 신뢰할 수 있다면, 애플리케이션의 DB endpoint를 복원 DB로 전환합니다.

확인할 항목:

- `backend-config`의 `SPRING_DATASOURCE_URL`
- `backend-secret`의 DB 사용자/비밀번호
- Flyway migration 상태
- 애플리케이션 pod 재시작 필요 여부

전환 후에는 서비스 API와 관리자 화면에서 데이터를 검증합니다.

## 9. 정상화 확인

서비스 확인:

```powershell
kubectl get pods -n baselink-dev
kubectl get svc -n baselink-dev
```

DB 확인:

```sql
select count(*) from game_schema.games;
select count(*) from ticket_schema.reservations;
```

비동기 처리 확인:

```powershell
aws sqs get-queue-attributes `
  --queue-url "https://sqs.ap-northeast-2.amazonaws.com/740831361032/ticket-confirm-queue" `
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```

## 10. 정리

복구가 끝난 뒤 아래 항목을 정리합니다.

- 복원 DB를 계속 사용할지 삭제할지 결정
- 임시 보안 그룹, 임시 secret, 임시 configmap 정리
- 장애 원인과 복구 시각 기록
- 재발 방지 조치 기록

복원 DB 삭제 예시:

```powershell
aws rds delete-db-instance `
  --db-instance-identifier $targetDb `
  --skip-final-snapshot
```

운영 환경에서는 삭제 전 final snapshot 생성을 검토합니다.

## 발표 포인트

- RDS Multi-AZ는 인스턴스 장애에 대응합니다.
- PITR은 데이터 삭제나 오염 같은 논리적 장애에 대응합니다.
- 자동 백업을 7일 동안 보존해 최근 시점으로 새 RDS를 복원할 수 있습니다.
- 복원 후 Flyway 이력과 핵심 테이블 count를 확인해 schema와 데이터 정합성을 검증합니다.
- 복구 방식은 일부 데이터 보정과 전체 DB endpoint 전환 중 상황에 맞게 선택합니다.
