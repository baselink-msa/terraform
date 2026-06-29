# 운영 알람 Runbook

이 문서는 dev 환경의 Data & Async Processing 영역에서 사용하는 CloudWatch Alarm 대응 절차를 정리합니다.

대상 리소스:

- RDS PostgreSQL: 예매 데이터, 경기/좌석/주문 데이터 저장소
- Valkey ElastiCache: 대기열, 좌석 선점, 짧은 TTL 캐시
- SQS: 예매 확정 비동기 처리 큐와 DLQ
- AWS Backup: RDS backup, cross-region copy, restore job
- WAF: CloudFront/API ALB 보안 차단 및 비정상 요청 감지
- SNS + Amazon Q Developer: CloudWatch Alarm을 Slack 채널로 전달

## 1. 알림 흐름

운영 알림 채널은 두 성격으로 분리해서 사용한다.

| 채널 | 목적 | 예시 |
| --- | --- | --- |
| `aws-alerts` | 장애/위험 감지용 즉시 알림 | RDS connection high, SQS DLQ, Backup copy 실패, WAF 차단 |
| `capacity-reports` 또는 `ops-reports` | 운영 의사결정용 정기 리포트 | Capacity Advisor 안전 입장량 추천, 최근 감속/복구 신호 |

이 문서는 `aws-alerts`로 들어오는 장애/위험 알림을 중심으로 정리한다.

```text
RDS / Valkey / SQS metric
  -> CloudWatch Alarm
WAF metric
  -> CloudWatch Alarm
AWS Backup job state
  -> EventBridge Rule
  -> SNS Topic: baselink-dev-ops-alerts
  -> Amazon Q Developer Slack channel configuration
  -> aws-alerts
```

Slack에는 장애 알림과 복구 알림이 모두 도착합니다.

- `ALARM`: 기준치를 넘었거나 장애 조건이 감지됨
- `OK`: 기준치가 정상 범위로 돌아옴
- `INSUFFICIENT_DATA`: CloudWatch가 아직 판단할 데이터가 부족함

`INSUFFICIENT_DATA`는 새 알람 생성 직후나 리소스가 삭제된 경우에 보일 수 있습니다.

## 2. 알람 목록

### RDS PostgreSQL

| 알람 이름 | 조건 | 의미 |
| --- | --- | --- |
| `baselink-dev-rds-cpu-high` | CPUUtilization >= 80%, 5분 x 2회 | DB 쿼리 부하가 높거나 연결이 몰림 |
| `baselink-dev-rds-free-storage-low` | FreeStorageSpace <= 2GiB, 5분 x 2회 | DB 디스크 여유 공간 부족 |
| `baselink-dev-rds-connections-high` | DatabaseConnections >= 60, 5분 x 2회 | app connection budget에 가까워짐 |
| `baselink-dev-rds-freeable-memory-low` | FreeableMemory <= 100MiB, 5분 x 2회 | DB 메모리 압박 |

### Valkey ElastiCache

현재 dev 환경은 `baselink-dev-redis-001`, `baselink-dev-redis-002` 두 캐시 노드를 사용합니다.

| 알람 이름 패턴 | 조건 | 의미 |
| --- | --- | --- |
| `baselink-dev-redis-001-engine-cpu-high` | EngineCPUUtilization >= 80%, 5분 x 2회 | Valkey 엔진 처리 부하 높음 |
| `baselink-dev-redis-002-engine-cpu-high` | EngineCPUUtilization >= 80%, 5분 x 2회 | replica 노드 엔진 처리 부하 높음 |
| `baselink-dev-redis-001-memory-high` | DatabaseMemoryUsagePercentage >= 80%, 5분 x 2회 | primary 캐시 메모리 사용률 높음 |
| `baselink-dev-redis-002-memory-high` | DatabaseMemoryUsagePercentage >= 80%, 5분 x 2회 | replica 캐시 메모리 사용률 높음 |
| `baselink-dev-redis-001-evictions-detected` | Evictions > 0, 5분 x 1회 | 메모리 부족으로 캐시 키가 밀려남 |
| `baselink-dev-redis-002-evictions-detected` | Evictions > 0, 5분 x 1회 | replica에서 캐시 키가 밀려남 |
| `baselink-dev-redis-002-replication-lag-high` | ReplicationLag >= 5초, 5분 x 2회 | primary와 replica 간 복제 지연 |

### SQS

| 알람 이름 | 조건 | 의미 |
| --- | --- | --- |
| `baselink-dev-ticket-confirm-queue-backlog` | 원본 큐 visible messages >= 10, 5분 x 2회 | 워커 처리 속도가 유입량을 따라가지 못함 |
| `baselink-dev-ticket-confirm-dlq-messages-visible` | DLQ visible messages >= 1, 1분 x 1회 | 메시지가 반복 실패 후 DLQ로 격리됨 |
| `baselink-dev-ticket-domain-events-backlog` | 원본 큐 visible messages >= 100, 5분 x 2회 | 이벤트 분석 파이프라인 적재가 지연됨 |
| `baselink-dev-ticket-domain-events-dlq-messages-visible` | DLQ visible messages >= 1, 1분 x 1회 | 이벤트 적재 실패 메시지가 DLQ로 격리됨 |

### AWS Backup

| EventBridge rule | 감지 상태 | 의미 |
| --- | --- | --- |
| `baselink-dev-backup-job-failure` | `FAILED`, `ABORTED`, `EXPIRED` | 정기 또는 수동 백업이 복구 지점을 만들지 못함 |
| `baselink-dev-copy-job-failure` | `FAILED` | 도쿄 리전 cross-region copy 실패 |
| `baselink-dev-restore-job-failure` | `FAILED` | 복구 리허설 또는 실제 복원 실패 |

### WAF

CloudFront WAF와 API ALB WAF는 보안/비정상 트래픽 징후를 `aws-alerts`로 전달한다.

| 범위 | 알림 패턴 | 조건 | 의미 |
| --- | --- | --- | --- |
| CloudFront WAF | `baselink-dev-cloudfront-waf-*-blocked` | BlockedRequests > 0, 5분 x 1회 | edge에서 차단된 요청 발생 |
| CloudFront WAF | `baselink-dev-cloudfront-waf-*-counted` | CountedRequests > 0, 5분 x 1회 | count mode rule에 매칭된 요청 발생 |
| API ALB WAF | `baselink-dev-api-alb-waf-*-blocked` | BlockedRequests > 0, 5분 x 1회 | API ALB 앞단에서 차단된 요청 발생 |
| API ALB WAF | `baselink-dev-api-alb-waf-*-counted` | CountedRequests > 0, 5분 x 1회 | API ALB count mode rule에 매칭된 요청 발생 |

주요 rule 계열:

- Amazon IP reputation
- Anonymous IP
- Common rule
- Known bad inputs
- SQL injection
- Admin protection
- Global rate limit
- Non-KR geo
- Body size

WAF 알림은 애플리케이션 장애가 아니라 비정상 요청이나 보안 정책 매칭일 수 있다. 알림을 받으면 같은 시간대 CloudFront/API 4xx, ALB target 5xx, 사용자 영향 여부를 함께 확인한다.

## 3. 공통 1차 대응

Slack 알림을 받으면 먼저 아래 순서로 확인합니다.

1. 알람 이름과 상태를 확인합니다.
2. 같은 시간대에 다른 알람도 함께 울렸는지 확인합니다.
3. AWS Console 또는 CLI로 실제 metric 값을 확인합니다.
4. EKS pod 상태와 애플리케이션 로그를 함께 봅니다.
5. 원인을 수정한 뒤 알람이 `OK`로 돌아오는지 확인합니다.

현재 알람 상태 확인:

```powershell
aws cloudwatch describe-alarms `
  --alarm-names `
    baselink-dev-rds-cpu-high `
    baselink-dev-rds-free-storage-low `
    baselink-dev-rds-connections-high `
    baselink-dev-rds-freeable-memory-low `
    baselink-dev-redis-001-engine-cpu-high `
    baselink-dev-redis-002-engine-cpu-high `
    baselink-dev-redis-001-memory-high `
    baselink-dev-redis-002-memory-high `
    baselink-dev-redis-001-evictions-detected `
    baselink-dev-redis-002-evictions-detected `
    baselink-dev-redis-002-replication-lag-high `
    baselink-dev-ticket-confirm-queue-backlog `
    baselink-dev-ticket-confirm-dlq-messages-visible `
    baselink-dev-ticket-domain-events-backlog `
    baselink-dev-ticket-domain-events-dlq-messages-visible `
  --query "MetricAlarms[].{Name:AlarmName,State:StateValue,Reason:StateReason}"
```

EKS workload 확인:

```powershell
kubectl get pods -n baselink-dev
kubectl get hpa -n baselink-dev
kubectl get scaledobject -n baselink-dev
```

## 4. RDS 알람 대응

### CPU 높음

가능한 원인:

- 경기 오픈 시간대에 조회/예매 요청이 집중됨
- 느린 쿼리 또는 인덱스 부족
- 커넥션 풀이 과도하게 열림

확인:

```powershell
aws cloudwatch get-metric-statistics `
  --namespace AWS/RDS `
  --metric-name CPUUtilization `
  --dimensions Name=DBInstanceIdentifier,Value=baselink-dev-postgres `
  --start-time (Get-Date).AddMinutes(-30).ToUniversalTime().ToString("s") `
  --end-time (Get-Date).ToUniversalTime().ToString("s") `
  --period 300 `
  --statistics Average,Maximum
```

1차 대응:

- 같은 시각 `DatabaseConnections`도 높은지 확인합니다.
- 백엔드 pod 로그에서 DB timeout, slow query, connection pool exhausted 메시지를 찾습니다.
- 특정 API가 원인이면 해당 서비스 담당자에게 공유합니다.
- 장기적으로는 인덱스 추가, 쿼리 개선, 커넥션 풀 제한을 검토합니다.

### 스토리지 부족

가능한 원인:

- 주문/로그성 데이터 증가
- migration 또는 seed 데이터 반복 적재
- autovacuum 지연으로 테이블/인덱스 bloat 발생

확인:

```powershell
aws rds describe-db-instances `
  --db-instance-identifier baselink-dev-postgres `
  --query "DBInstances[0].{Status:DBInstanceStatus,AllocatedStorage:AllocatedStorage,StorageType:StorageType,PendingModifiedValues:PendingModifiedValues}"
```

1차 대응:

- 불필요한 테스트 데이터가 반복 적재됐는지 확인합니다.
- 급한 경우 스토리지 증설 PR을 준비합니다.
- 삭제/정리 작업은 팀과 공유 후 진행합니다.

### 커넥션 많음

가능한 원인:

- pod 수 증가로 DB 커넥션 총량 증가
- 커넥션 누수
- 장애 재시도 루프

확인:

```powershell
kubectl get pods -n baselink-dev
kubectl logs -n baselink-dev deploy/ticket-service --tail=100
kubectl logs -n baselink-dev deploy/ticket-worker-service --tail=100
```

1차 대응:

- 갑자기 증가한 pod 수가 있는지 확인합니다.
- DB connection pool 설정과 KEDA/HPA 스케일링 상태를 확인합니다.
- 반복 에러로 재시도가 쌓이면 애플리케이션 담당자와 함께 원인을 중지합니다.

### 메모리 부족

가능한 원인:

- 큰 쿼리, 정렬, 조인 증가
- connection 증가
- maintenance 작업 또는 autovacuum 영향

1차 대응:

- CPU/커넥션 알람과 함께 발생했는지 확인합니다.
- 같은 시간대 애플리케이션 배포나 대량 데이터 작업이 있었는지 확인합니다.
- 반복 발생 시 인스턴스 크기와 쿼리 최적화를 검토합니다.

## 5. Valkey 알람 대응

### Engine CPU 높음

가능한 원인:

- 대기열 진입/갱신 요청 급증
- 좌석 선점 lock 요청 급증
- hot key에 요청 집중

확인:

```powershell
aws elasticache describe-replication-groups `
  --replication-group-id baselink-dev-redis `
  --query "ReplicationGroups[0].NodeGroups[0].NodeGroupMembers[].{ClusterId:CacheClusterId,Role:CurrentRole,AZ:PreferredAvailabilityZone}"
```

1차 대응:

- 예매 오픈 시간대인지 확인합니다.
- ticket-service, waiting-room 관련 pod의 요청/에러 로그를 확인합니다.
- CPU가 계속 높으면 node type 상향 또는 캐시 접근 패턴 개선을 검토합니다.

### 메모리 높음 또는 Evictions 발생

가능한 원인:

- 좌석 lock TTL이 예상보다 길거나 해제되지 않음
- 대기열/캐시 키가 너무 많이 쌓임
- `maxmemory-policy`에 의해 키가 밀려남

확인:

```powershell
aws cloudwatch get-metric-statistics `
  --namespace AWS/ElastiCache `
  --metric-name DatabaseMemoryUsagePercentage `
  --dimensions Name=CacheClusterId,Value=baselink-dev-redis-001 `
  --start-time (Get-Date).AddMinutes(-30).ToUniversalTime().ToString("s") `
  --end-time (Get-Date).ToUniversalTime().ToString("s") `
  --period 300 `
  --statistics Average,Maximum
```

1차 대응:

- 최근 예매/대기열 테스트가 있었는지 확인합니다.
- 좌석 lock TTL과 대기열 TTL이 정상인지 애플리케이션 설정을 확인합니다.
- evictions가 반복되면 캐시 용량 증설 또는 key 설계 개선을 검토합니다.

### 복제 지연

가능한 원인:

- primary 부하가 높아 replica 반영이 늦어짐
- 네트워크 또는 AZ 간 일시 지연
- failover 직전/직후 상태 변화

확인:

```powershell
aws cloudwatch get-metric-statistics `
  --namespace AWS/ElastiCache `
  --metric-name ReplicationLag `
  --dimensions Name=CacheClusterId,Value=baselink-dev-redis-002 `
  --start-time (Get-Date).AddMinutes(-30).ToUniversalTime().ToString("s") `
  --end-time (Get-Date).ToUniversalTime().ToString("s") `
  --period 300 `
  --statistics Average,Maximum
```

1차 대응:

- primary CPU/메모리 알람과 함께 발생했는지 확인합니다.
- `describe-replication-groups`로 primary/replica 역할이 바뀌었는지 확인합니다.
- 지연이 계속되면 ElastiCache 이벤트와 AWS 상태를 확인합니다.

## 6. SQS 알람 대응

### 원본 큐 적체

원본 큐 backlog 알람은 메시지가 아직 실패하지는 않았지만 consumer가 처리 속도를 따라가지 못할 때 울립니다.

| 알림 | 대상 consumer | 의미 |
| --- | --- | --- |
| `baselink-dev-ticket-confirm-queue-backlog` | `ticket-worker-service` | 예매 확정 비동기 처리가 밀림 |
| `baselink-dev-ticket-domain-events-backlog` | ticket event writer Lambda | 이벤트 S3 적재 파이프라인이 밀림 |

확인:

```powershell
$queueUrl = aws sqs get-queue-url `
  --queue-name ticket-confirm-queue `
  --query QueueUrl `
  --output text

aws sqs get-queue-attributes `
  --queue-url $queueUrl `
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateAgeOfOldestMessage
```

해석:

- `ApproximateNumberOfMessages`: 아직 처리되지 않은 대기 메시지
- `ApproximateNumberOfMessagesNotVisible`: 워커가 가져가서 처리 중인 메시지
- `ApproximateAgeOfOldestMessage`: 가장 오래 기다린 메시지의 대기 시간

1차 대응:

- `ticket-worker-service` pod가 떠 있는지 확인합니다.
- 워커 로그에서 DB 에러, SQS permission 에러, timeout을 찾습니다.
- KEDA scaler가 정상인지 확인합니다.
- 워커 pod 수가 부족하면 KEDA/HPA 설정과 node 여유 용량을 확인합니다.

```powershell
kubectl get pods -n baselink-dev -l app=ticket-worker-service
kubectl logs -n baselink-dev deploy/ticket-worker-service --tail=100
kubectl get scaledobject -n baselink-dev
kubectl get hpa -n baselink-dev
```

복구 기준:

- 원본 큐 visible messages가 10개 미만으로 내려갑니다.
- 오래된 메시지 age가 감소합니다.
- CloudWatch Alarm이 `OK`로 돌아옵니다.

### DLQ 메시지 발생

DLQ 알람은 메시지가 반복 처리 실패 후 격리됐다는 뜻입니다.

| 알림 | DLQ | 의미 |
| --- | --- | --- |
| `baselink-dev-ticket-confirm-dlq-messages-visible` | `ticket-confirm-dlq` | 예매 확정 명령 처리 실패 메시지 격리 |
| `baselink-dev-ticket-domain-events-dlq-messages-visible` | `ticket-domain-events-dlq` | 이벤트 적재 실패 메시지 격리 |

원본 큐 적체와의 차이:

- 원본 큐 적체: 아직 처리 중이거나 처리 대기 중인 메시지가 밀림
- DLQ 발생: 재시도 한도를 넘어서 실패 메시지가 격리됨

확인:

```powershell
$dlqUrl = aws sqs get-queue-url `
  --queue-name ticket-confirm-dlq `
  --query QueueUrl `
  --output text

aws sqs get-queue-attributes `
  --queue-url $dlqUrl `
  --attribute-names ApproximateNumberOfMessages ApproximateAgeOfOldestMessage
```

1차 대응:

- DLQ 메시지를 바로 redrive하지 않습니다.
- 먼저 실패 원인을 확인합니다.
- 원인이 DB schema, 권한, 애플리케이션 버그라면 수정 후 redrive합니다.
- 자세한 redrive 절차는 `modules/sqs/README.md`의 DLQ 운영 절차를 따릅니다.

`ticket-domain-events` DLQ는 Capacity Advisor와 Kafka/S3 분석 경로에도 영향을 줄 수 있다. 이 DLQ가 발생하면 단순히 메시지 재처리만 보지 말고, 해당 시간대 S3 적재 누락과 Athena 표본 부족 여부도 함께 확인한다.

## 7. 진단 스크립트와 AI 분석 템플릿

알람을 받으면 먼저 `scripts/diagnose-data-alarm.ps1`로 현재 상태를 수집합니다.

이 스크립트는 복구 작업을 실행하지 않고, 읽기 전용 진단 정보를 모읍니다.

- CloudWatch Alarm 상태
- RDS 상태와 CPU/커넥션/메모리/스토리지 metric
- Valkey replication group 상태
- SQS 원본 큐와 DLQ 적체 상태
- EKS pod, HPA, ScaledObject 상태
- `ticket-worker-service`, `ticket-service` 최근 로그

실행 예시:

```powershell
.\scripts\diagnose-data-alarm.ps1 `
  -AlarmName baselink-dev-rds-cpu-high `
  -Namespace baselink-dev `
  -LookbackMinutes 30
```

SQS 알람일 때:

```powershell
.\scripts\diagnose-data-alarm.ps1 `
  -AlarmName baselink-dev-ticket-confirm-queue-backlog `
  -Namespace baselink-dev `
  -LookbackMinutes 30
```

AI 분석 요청 템플릿:

```text
아래는 Baselink dev 환경의 운영 알람 진단 결과입니다.

목표:
- 장애 원인 후보를 가능성 높은 순서로 정리
- 즉시 완화 조치와 근본 해결 조치를 분리
- 데이터 정합성에 위험한 작업은 승인 필요 작업으로 표시
- 실행하면 안 되는 작업이 있다면 명확히 표시

알람 이름:
발생 시각:
사용자 영향:

진단 스크립트 출력:
<scripts/diagnose-data-alarm.ps1 출력 붙여넣기>

응답 형식:
1. 현재 상황 요약
2. 가장 가능성 높은 원인 후보
3. 바로 확인할 추가 항목
4. 안전한 1차 완화 조치
5. 승인 후 진행해야 하는 조치
6. 재발 방지 작업
```

### 알람별 조치 판단 기준

| 알람 | 바로 해도 되는 조치 | 승인 후 진행할 조치 | 주의할 점 |
| --- | --- | --- | --- |
| RDS CPU 높음 | metric/로그 확인, 최근 배포 확인, 과도한 테스트 중단 | 인덱스 추가, 쿼리 변경, DB 인스턴스 크기 변경 | 인덱스 추가는 Flyway migration과 리뷰 필요 |
| RDS 커넥션 많음 | pod 수/HPA 확인, DB timeout 로그 확인 | 커넥션 풀 제한 변경, replica/read 분리 설계 | 무작정 pod를 늘리면 DB 부하가 더 커질 수 있음 |
| RDS 스토리지 부족 | 테스트 데이터 반복 적재 여부 확인 | 스토리지 증설, 대량 삭제, vacuum 전략 변경 | 삭제 작업은 백업/PITR 가능 상태 확인 후 진행 |
| Valkey CPU 높음 | 예매 오픈/부하 테스트 여부 확인, hot key 후보 확인 | node type 상향, 캐시 key 설계 변경 | 캐시 flush는 좌석 선점/대기열 상태를 깨뜨릴 수 있음 |
| Valkey evictions | TTL/key 증가 여부 확인 | 용량 증설, maxmemory-policy 재검토 | eviction은 좌석 lock 유실 가능성과 함께 판단 |
| SQS 원본 큐 적체 | worker pod/HPA/KEDA 확인, worker 로그 확인 | worker concurrency 변경, KEDA 기준 변경 | DB 병목이면 worker만 늘려도 해결되지 않음 |
| SQS DLQ 발생 | 메시지 수/실패 로그 확인 | 원인 수정 후 redrive | 원인 수정 전 redrive 금지 |

### 직접 해결로 이어지는 작업 방식

운영자는 알람을 보고 바로 리소스를 임의 변경하기보다, 변경 종류에 따라 아래 방식을 선택합니다.

- DB 인덱스 추가: Flyway migration SQL 작성 후 PR
- 쿼리 개선: backend 코드 수정 후 테스트/PR
- 커넥션 풀 제한: backend 설정 또는 Kubernetes Secret/ConfigMap 변경 PR
- worker 처리량 조정: GitOps의 KEDA/HPA 설정 변경 PR
- DLQ redrive: 원인 수정 확인 후 운영 명령으로 수동 실행
- RDS 복구: `modules/rds/RUNBOOK.md`의 PITR 절차에 따라 새 DB로 복원 후 전환 검토

이 구조는 AI가 조치 후보를 빠르게 정리하도록 돕되, 데이터 정합성에 영향을 주는 작업은 사람이 승인하도록 하기 위한 운영 방식입니다.

## 8. AWS Backup 실패 이벤트 대응

AWS Backup 이벤트는 CloudWatch metric alarm이 아니라 EventBridge 상태 변경 이벤트로 수집합니다.

1차 확인:

```powershell
aws backup list-backup-jobs `
  --by-state FAILED `
  --query "BackupJobs[].{JobId:BackupJobId,Resource:ResourceArn,Message:StatusMessage,Created:CreationDate}"

aws backup list-copy-jobs `
  --by-state FAILED `
  --query "CopyJobs[].{JobId:CopyJobId,Resource:ResourceArn,Message:StatusMessage,Created:CreationDate}"

aws backup list-restore-jobs `
  --query "RestoreJobs[?Status=='FAILED'].{JobId:RestoreJobId,Resource:CreatedResourceArn,Message:StatusMessage,Created:CreationDate}"
```

대응 원칙:

- `FAILED`: IAM 권한, vault/KMS key, 대상 리소스 상태, `statusMessage`를 확인하고 원인을 수정합니다.
- `ABORTED`: 누가 어떤 이유로 중단했는지 CloudTrail과 작업 이력을 확인합니다.
- `EXPIRED`: start window 안에 작업이 시작되지 못한 이유와 동일 리소스의 선행 작업을 확인합니다.
- copy 실패 시 서울 recovery point는 유지되지만 리전 DR RPO가 증가하므로 우선순위를 높여 재복사합니다.
- restore 실패 시 기존 운영 DB를 변경하지 말고 새 identifier로 복원 작업을 다시 수행합니다.

EventBridge 패턴 확인:

```powershell
aws events describe-rule --name baselink-dev-backup-job-failure
aws events list-targets-by-rule --rule baselink-dev-backup-job-failure
aws events describe-rule --name baselink-dev-copy-job-failure
aws events describe-rule --name baselink-dev-restore-job-failure
```

AWS Backup은 EventBridge 이벤트를 best effort 방식으로 전달하므로, 정기 점검에서는 최근 backup job 완료 여부와 recovery point 개수도 함께 확인합니다.

Slack 전달 형식:

- Amazon Q Developer는 SNS에 발행된 임의 문자열을 모두 Slack으로 전달하지 않습니다.
- Backup/Copy/Restore EventBridge target은 Input Transformer로 이벤트를 Amazon Q custom notification schema로 변환합니다.
- 변환 결과에는 작업 유형, 상태, AWS 리전, job ID, 이벤트 시각, 후속 조치가 포함됩니다.
- 일반 `aws sns publish --message "plain text"` 테스트가 Slack에 나타나지 않는 것은 SNS 연결 실패를 의미하지 않습니다.

## 9. Slack 알림 테스트

### 기존 CloudWatch Alarm 경로

운영 알람을 실제 장애 없이 테스트하려면 CloudWatch Alarm 상태를 수동으로 바꿀 수 있습니다.

주의:

- 이 명령은 실제 metric 값을 바꾸지 않습니다.
- Slack 장애/복구 알림 경로만 검증합니다.
- 테스트 전 팀 Slack에 알림 테스트라고 공유합니다.

장애 알림 테스트:

```powershell
aws cloudwatch set-alarm-state `
  --alarm-name baselink-dev-ticket-confirm-queue-backlog `
  --state-value ALARM `
  --state-reason "Manual alarm notification test"
```

복구 알림 테스트:

```powershell
aws cloudwatch set-alarm-state `
  --alarm-name baselink-dev-ticket-confirm-queue-backlog `
  --state-value OK `
  --state-reason "Manual recovery notification test"
```

테스트 후 확인:

```powershell
aws cloudwatch describe-alarms `
  --alarm-names baselink-dev-ticket-confirm-queue-backlog `
  --query "MetricAlarms[0].{Name:AlarmName,State:StateValue,Reason:StateReason}"
```

### Amazon Q custom notification 경로

일반 문자열 대신 Amazon Q 공식 schema를 사용합니다.

```powershell
$messageFile = Join-Path $env:TEMP "amazon-q-backup-alert-test.json"

@{
  version = "1.0"
  source  = "custom"
  id      = "backup-alert-path-test"
  content = @{
    textType   = "client-markdown"
    title      = ":white_check_mark: AWS Backup alert path test"
    description = "TEST ONLY: custom notification delivery to the existing aws-alerts channel."
    nextSteps  = @("Confirm this message is visible in Slack", "No backup job has failed")
    keywords   = @("AWS Backup", "Test", "DR")
  }
  metadata = @{
    threadId = "baselink-backup-alerts"
    summary  = "AWS Backup alert path test"
    enableCustomActions = $false
  }
} | ConvertTo-Json -Depth 10 | Set-Content -Encoding ascii $messageFile

aws sns publish `
  --topic-arn arn:aws:sns:ap-northeast-2:740831361032:baselink-dev-ops-alerts `
  --subject "AWS Backup custom notification test" `
  --message "file://$messageFile"

Remove-Item -LiteralPath $messageFile
```

채널에 나타나야 하는 메시지:

- DLQ alarm `ALARM`과 `OK`
- `AWS Backup alert path test` custom notification

이 테스트는 Slack 표시 형식과 SNS 구독을 확인합니다. 실제 EventBridge rule 자체는 다음 Backup/Copy/Restore 실패 이벤트가 발생할 때 같은 custom schema로 전달됩니다.

주의:

- PowerShell에서 JSON 문자열을 `--message $message`로 직접 전달하면 따옴표가 제거될 수 있습니다.
- Windows PowerShell 5.1의 `Set-Content -Encoding utf8`은 BOM을 추가해 AWS CLI `file://` 읽기가 실패할 수 있습니다. 현재 영문 테스트 payload는 `-Encoding ascii`를 사용합니다.
- Amazon Q 오류 로그에 `{version:1.0,...}`처럼 key의 큰따옴표가 없는 payload가 보이면 JSON 전달 방식 문제입니다.
- JSON 파일을 만들고 `--message file://<path>`로 전달하면 원형을 보존할 수 있습니다.
- SNS topic policy에는 EventBridge뿐 아니라 `cloudwatch.amazonaws.com`의 `SNS:Publish` 권한도 유지해야 기존 DLQ/RDS/Valkey/WAF alarm이 계속 전달됩니다.

### 2026-06-22 알림 경로 검증 결과

발견한 문제:

- EventBridge 발행 권한을 추가하면서 기존 CloudWatch Alarm의 SNS 발행 권한이 topic policy에서 누락됐습니다.
- CloudWatch Alarm history에 `CloudWatch Alarms is not authorized to perform SNS:Publish` 오류가 기록됐습니다.
- 첫 custom 테스트는 PowerShell 인라인 JSON의 큰따옴표가 제거되어 Amazon Q에서 unsupported event로 거부됐습니다.
- 두 번째 파일 테스트는 Windows PowerShell UTF-8 BOM 때문에 AWS CLI가 파일을 읽지 못했습니다.

수정과 검증:

- SNS topic policy에 `cloudwatch.amazonaws.com`의 `SNS:Publish` 권한을 복구했습니다.
- Source account와 서울 리전 CloudWatch alarm ARN으로 권한 범위를 제한했습니다.
- Backup/Copy/Restore EventBridge target에는 Amazon Q custom notification Input Transformer가 적용됐습니다.
- DLQ alarm을 수동 `ALARM → OK`로 전환했고 두 action 모두 `Successfully executed action`을 확인했습니다.
- BOM 없는 JSON 파일로 custom notification을 발행했습니다.
- SNS 지표에서 3건 전달, 전달 실패 0건을 확인했습니다.
- custom 재발행 후 Amazon Q 오류 로그가 추가되지 않았습니다.

## 10. 발표용 요약

이 프로젝트의 Data & Async Processing 운영 안정성은 다음 흐름으로 설명할 수 있습니다.

- RDS는 Multi-AZ, 자동 백업, PITR, CloudWatch Alarm으로 데이터 저장소의 가용성과 복구 가능성을 확보했습니다.
- Valkey는 primary/replica Multi-AZ 구성과 CPU/메모리/eviction/복제 지연 알람으로 대기열과 좌석 선점 계층의 이상 징후를 감지합니다.
- SQS는 `ticket-confirm-queue`와 `ticket-domain-events`의 backlog 알람으로 처리 지연을 조기에 감지하고, DLQ 알람과 redrive 절차로 최종 실패 메시지를 안전하게 복구할 수 있게 했습니다.
- AWS Backup의 backup/copy/restore 실패는 EventBridge를 통해 기존 운영 Slack 채널로 전달합니다.
- WAF는 CloudFront/API ALB 앞단의 차단·count 이벤트를 Slack으로 전달해 비정상 요청과 보안 정책 매칭을 빠르게 확인할 수 있게 합니다.
- 모든 주요 알람은 SNS와 Amazon Q Developer를 통해 Slack으로 전달되어 팀이 장애와 복구 상태를 빠르게 공유할 수 있습니다.
- 진단 스크립트와 AI 분석 템플릿을 함께 준비해, 운영자가 metric과 로그를 빠르게 수집하고 안전한 조치 후보를 판단할 수 있게 했습니다.

## 11. 관련 문서

- `modules/rds/RUNBOOK.md`: RDS PITR 복구 절차
- `modules/rds/README.md`: RDS 백업/PITR 설정 설명
- `modules/sqs/README.md`: SQS DLQ redrive 운영 절차
- `env/dev/infra/rds_alarms.tf`: RDS CloudWatch Alarm Terraform 코드
- `env/dev/infra/valkey_alarms.tf`: Valkey CloudWatch Alarm Terraform 코드
- `modules/sqs/main.tf`: SQS DLQ 및 원본 큐 backlog 알람 Terraform 코드
- `env/dev/infra/backup_alarms.tf`: AWS Backup 실패 EventBridge와 SNS 정책
- `scripts/diagnose-data-alarm.ps1`: RDS, Valkey, SQS, EKS 상태 수집 스크립트
