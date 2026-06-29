# Ticket Capacity Advisor

Athena의 티켓 이벤트 통계와 현재 RDS connection 수를 이용해 설명 가능한 입장 정책 추천 보고서를 생성합니다.

```powershell
python tools/ticket_capacity_advisor.py `
  --game-id 1 `
  --current-policy 40 `
  --current-db-connections 20 `
  --lookback-days 7
```

합성 표본만 분리해서 분석:

```powershell
python tools/generate_capacity_test_events.py --samples 40

python tools/ticket_capacity_advisor.py `
  --game-id 1 `
  --current-policy 40 `
  --current-db-connections 20 `
  --producer-filter capacity-load-test
```

합성 이벤트는 항상 `producer=capacity-load-test`로 저장됩니다. 실제 운영 근거와 섞어서 사용하지 않습니다.

Kafka dual publish로 들어온 운영 이벤트만 묶어서 분석:

```powershell
python tools/ticket_capacity_advisor.py `
  --game-id 1 `
  --current-policy 40 `
  --current-db-connections 20 `
  --producer-in ticket-service,waiting-room-service
```

출력:

- `capacity-reports/game-1-capacity.json`
- `capacity-reports/game-1-capacity.md`

계산 원칙:

- 과거 안정 구간의 예약 확정 처리량을 기준으로 합니다.
- 예약 전환율, 안전계수, 평균 대기 시간을 보정합니다.
- 추천값은 한 번에 현재 정책보다 25% 넘게 올리지 않습니다.
- 최소 표본이 부족하면 `INSUFFICIENT_DATA`로 추천을 보류합니다.
- 현재 DB 압력은 장기 정책 추천값을 다시 깎지 않고 `effectiveEnterPerMinuteNow`에만 반영합니다.
- 결과는 운영자 검토용이며 대기열 설정을 자동으로 변경하지 않습니다.

## Capacity Advisor Slack 알림

운영자가 리포트 파일을 직접 열지 않아도 추천값과 최근 감속/복구 신호를 Slack에서 확인할 수 있습니다.

먼저 dry-run으로 Slack payload를 확인합니다.

```powershell
python tools/slack_capacity_advisor_notify.py `
  --report-json capacity-reports/game-9001-capacity.json `
  --report-url https://github.com/baselink-msa/terraform/actions `
  --dry-run
```

실제 Slack 전송:

```powershell
$env:CAPACITY_ADVISOR_SLACK_WEBHOOK_URL="<slack-incoming-webhook-url>"

python tools/slack_capacity_advisor_notify.py `
  --report-json capacity-reports/game-9001-capacity.json
```

Slack 메시지에는 다음 정보가 포함됩니다.

- 추천 입장량
- 현재 정책
- 현재 DB 반영 입장량
- DB pressure level과 connection 수
- 이벤트 표본 수
- 안정 확정 처리량, 예약 확정률, 안전계수, 대기시간 보정 등 산출 지표
- 판단 근거
- Kafka `capacity.signals` 기반 최근 감속/복구 신호
- SQS `ticket-confirm-queue` / `ticket-confirm-dlq` 기반 worker 처리 상태
- CloudWatch `AWS/ElastiCache` 기반 Valkey/좌석 잠금 계층 상태
- Athena event lake 기반 좌석 잠금 이벤트 상태
- Athena event lake 기반 Kafka pipeline health

GitHub Actions 자동 알림:

```text
.github/workflows/capacity-advisor-slack.yml
```

필수 GitHub Secret:

```text
CAPACITY_ADVISOR_SLACK_WEBHOOK_URL
```

기존 AWS 인증에는 `AWS_TERRAFORM_ROLE_ARN`을 재사용합니다.

선택 Repository Variables:

```text
CAPACITY_ADVISOR_GAME_ID=9001
CAPACITY_ADVISOR_CURRENT_POLICY=40
CAPACITY_ADVISOR_LOOKBACK_DAYS=1
CAPACITY_ADVISOR_MINIMUM_SAMPLES=20
CAPACITY_ADVISOR_PRODUCER_IN=ticket-service,waiting-room-service
CAPACITY_ADVISOR_DB_INSTANCE_ID=baselink-dev-postgres
CAPACITY_ADVISOR_CURRENT_DB_CONNECTIONS=22
CAPACITY_ADVISOR_SQS_SOURCE_QUEUE_NAME=ticket-confirm-queue
CAPACITY_ADVISOR_SQS_DLQ_NAME=ticket-confirm-dlq
CAPACITY_ADVISOR_SQS_BACKLOG_THRESHOLD=10
CAPACITY_ADVISOR_SQS_OLDEST_AGE_THRESHOLD_SECONDS=300
CAPACITY_ADVISOR_SQS_DLQ_THRESHOLD=1
CAPACITY_ADVISOR_VALKEY_CLUSTER_IDS=baselink-dev-redis-001,baselink-dev-redis-002
CAPACITY_ADVISOR_VALKEY_REPLICA_CLUSTER_IDS=baselink-dev-redis-002
CAPACITY_ADVISOR_VALKEY_LOOKBACK_MINUTES=15
CAPACITY_ADVISOR_VALKEY_CPU_THRESHOLD_PERCENT=80
CAPACITY_ADVISOR_VALKEY_MEMORY_THRESHOLD_PERCENT=80
CAPACITY_ADVISOR_VALKEY_REPLICATION_LAG_THRESHOLD_SECONDS=5
CAPACITY_ADVISOR_VALKEY_EVICTION_THRESHOLD=0
CAPACITY_ADVISOR_KAFKA_EXPECTED_PRODUCERS=ticket-service,waiting-room-service
CAPACITY_ADVISOR_KAFKA_EXPECTED_EVENT_TYPES=WAITING_ENTERED,ACCESS_TOKEN_ISSUED,RESERVATION_REQUESTED,RESERVATION_CONFIRMED
CAPACITY_ADVISOR_KAFKA_STALE_AFTER_HOURS=24
CAPACITY_ADVISOR_SEAT_LOCK_PRODUCER=seat-lock-service
CAPACITY_ADVISOR_SEAT_LOCK_FAILURE_RATE_THRESHOLD_PERCENT=60
```

SQS status troubleshooting:

- `UNKNOWN` means the report could not query SQS queue attributes.
- The report includes the AWS CLI exit code and stderr so the next run can show
  whether the cause is queue name, region, or IAM permission.
- Queue depth is read from SQS queue attributes. Oldest message age is read from
  the CloudWatch `AWS/SQS` metric `ApproximateAgeOfOldestMessage`.
- Check `CAPACITY_ADVISOR_SQS_SOURCE_QUEUE_NAME`,
  `CAPACITY_ADVISOR_SQS_DLQ_NAME`, and the GitHub Actions role permissions
  `sqs:GetQueueUrl` / `sqs:GetQueueAttributes` / `cloudwatch:GetMetricStatistics`.

`CAPACITY_ADVISOR_CURRENT_DB_CONNECTIONS`를 지정하지 않으면 workflow가 CloudWatch `AWS/RDS DatabaseConnections` 최근 값을 조회합니다.

SQS/Worker 상태는 AWS CLI로 SQS queue attributes를 조회해 리포트에 포함합니다.

| 상태 | 의미 |
| --- | --- |
| `HEALTHY` | 원본 큐와 DLQ에 대기 메시지가 없음 |
| `PROCESSING` | 메시지가 처리 중이지만 backlog 기준은 넘지 않음 |
| `BACKLOG` | 원본 큐 visible messages가 기준 이상 |
| `DELAYED` | 가장 오래된 메시지 대기 시간이 기준 이상 |
| `DLQ_DETECTED` | DLQ에 메시지가 있음 |
| `UNKNOWN` | SQS 상태 조회 실패 또는 생략 |

Valkey/좌석 잠금 계층 상태는 CloudWatch `AWS/ElastiCache` metric을 조회해 리포트에 포함합니다. 현재는 좌석 잠금 backend event를 Kafka로 발행하는 단계가 아니라, 리포트 생성 시점의 Valkey 운영 상태를 함께 붙이는 1차 구현입니다.

| 상태 | 의미 |
| --- | --- |
| `HEALTHY` | CPU, memory, eviction, replication lag가 기준 이내 |
| `CPU_HIGH` | 대기열/좌석 잠금 요청 집중으로 Valkey engine CPU가 높음 |
| `MEMORY_HIGH` | TTL key 증가 등으로 메모리 사용률이 높음 |
| `EVICTIONS_DETECTED` | 좌석 lock, access token 같은 TTL key 유실 위험이 있음 |
| `REPLICATION_LAG` | replica 지연으로 failover/읽기 안정성 저하를 의심 |
| `UNKNOWN` | Valkey 상태 조회 실패 또는 생략 |

로컬에서 Athena/DB 부분만 확인하고 SQS 조회를 생략하려면 다음 옵션을 사용할 수 있습니다.

```powershell
python tools/ticket_capacity_advisor.py `
  --game-id 9001 `
  --current-policy 40 `
  --current-db-connections 22 `
  --skip-sqs-worker
```

Valkey CloudWatch 조회도 생략하려면 다음 옵션을 추가합니다.

```powershell
python tools/ticket_capacity_advisor.py `
  --game-id 9001 `
  --current-policy 40 `
  --current-db-connections 22 `
  --skip-valkey-status
```

Kafka pipeline health는 Athena `ticket_events` event lake를 조회해 Kafka→S3/Athena 분석 경로가 Capacity Advisor에 필요한 표본을 제공하고 있는지 확인합니다.

| 상태 | 의미 |
| --- | --- |
| `HEALTHY` | 기대 producer와 핵심 event type이 모두 존재하고 최신 이벤트가 기준 이내 |
| `NO_EVENTS` | 조회 기간에 event lake 이벤트가 없음 |
| `STALE` | 최신 이벤트가 `kafka-stale-after-hours` 기준보다 오래됨 |
| `PARTIAL` | 특정 producer 또는 핵심 event type이 누락됨 |
| `PRODUCER_FAILURE` | `KAFKA_PRODUCE_FAILED` audit event가 감지됨 |
| `INVALID_EVENTS` | `KAFKA_EVENT_INVALID` audit event가 감지됨 |

## Seat-lock event summary

Capacity Advisor는 Athena `ticket_events`에서 `seat-lock-service`가 발행한 좌석 잠금 이벤트를 조회해 리포트와 Slack 메시지에 함께 표시합니다.

포함 항목:

- `SEAT_LOCK_REQUESTED`
- `SEAT_LOCKED`
- `SEAT_LOCK_FAILED`
- `SEAT_UNLOCKED`

리포트에는 잠금 요청 수, 성공 수, 실패 수, 해제 수, 성공률, 실패율, 해제율, 최신 이벤트가 표시됩니다.

상태 의미:

| 상태 | 의미 |
| --- | --- |
| `HEALTHY` | 조회 기간에 좌석 잠금 실패가 없거나 실패율이 기준 이하 |
| `COMPETITION_DETECTED` | 중복 잠금 시도 등 좌석 선점 경쟁이 관측됨 |
| `FAILURE_RATE_HIGH` | 실패율이 기준을 초과해 좌석 잠금 병목 또는 오류 가능성 있음 |
| `NO_EVENTS` | 조회 기간에 seat-lock 이벤트가 없음 |

기본 실패율 기준은 60%입니다.

```powershell
python tools/ticket_capacity_advisor.py `
  --game-id 9001 `
  --current-policy 40 `
  --current-db-connections 20 `
  --lookback-days 1 `
  --producer-in ticket-service,waiting-room-service `
  --seat-lock-producer seat-lock-service `
  --seat-lock-failure-rate-threshold-percent 60
```

## Infra audit events

Kafka/SQS 파이프라인의 실행 이력도 같은 S3/Athena event lake에 남길 수 있습니다.

지원 event type:

- `KAFKA_PRODUCE_FAILED`
- `KAFKA_S3_SINK_DELAYED`
- `KAFKA_EVENT_SKIPPED`
- `KAFKA_EVENT_INVALID`
- `KAFKA_S3_SINK_COMPLETED`
- `SQS_WORKER_STATUS_RECORDED`
- `SQS_BACKLOG_DETECTED`
- `SQS_DLQ_DETECTED`

Kafka S3 sink 실행 완료 이벤트를 남기려면 `--emit-audit-event`를 추가합니다.

```powershell
python tools/kafka_s3_sink.py `
  --consume `
  --bootstrap-server <bootstrap-server> `
  --bucket baselink-dev-ticket-events-740831361032 `
  --topics ticket.domain.events waiting.operational.events reservation.lifecycle.events capacity.signals `
  --producer-in ticket-service,waiting-room-service,seat-lock-service `
  --emit-audit-event
```

SQS worker 상태를 audit event로 남기려면 다음 도구를 사용합니다.

```powershell
python tools/record_sqs_worker_audit.py `
  --bucket baselink-dev-ticket-events-740831361032 `
  --source-queue-name ticket-confirm-queue `
  --dlq-name ticket-confirm-dlq `
  --region ap-northeast-2
```

이 단계는 상시 Kafka producer/consumer가 아니라 dev/발표 검증용 기록 도구입니다. 운영 상시화가 필요해지면 `infra.audit.events` topic으로 producer를 붙이고, 기존 Kafka S3 sink 또는 전용 consumer가 같은 event lake에 적재하도록 확장합니다.
| `UNKNOWN` | Kafka pipeline health 조회 실패 또는 생략 |

로컬에서 Kafka pipeline health 조회를 생략하려면 다음 옵션을 추가합니다.

```powershell
python tools/ticket_capacity_advisor.py `
  --game-id 9001 `
  --current-policy 40 `
  --current-db-connections 22 `
  --skip-kafka-pipeline-health
```

기본 schedule은 매일 09:00 KST입니다. 발표 캡처용으로는 Actions에서 `Capacity Advisor Slack Report`를 수동 실행한 뒤 Slack 메시지와 workflow artifact를 함께 캡처하면 좋습니다.

## Kafka to S3 sink runner

Kafka topic의 이벤트를 기존 S3/Athena event lake에 저장합니다. 같은 event envelope과 같은 S3 key를 사용하므로 기존 Lambda writer와 Athena table, Capacity Advisor를 그대로 재사용할 수 있습니다.

파일 입력으로 먼저 검증:

```powershell
python tools/kafka_s3_sink.py `
  --input-jsonl .\kafka-events.jsonl `
  --bucket baselink-dev-ticket-events-740831361032 `
  --dry-run
```

MSK Serverless topic에서 직접 읽어 S3에 적재:

```powershell
python tools/kafka_s3_sink.py `
  --consume `
  --bootstrap-server boot-twqovxpi.c3.kafka-serverless.ap-northeast-2.amazonaws.com:9098 `
  --bucket baselink-dev-ticket-events-740831361032 `
  --topics ticket.domain.events waiting.operational.events reservation.lifecycle.events capacity.signals `
  --producer-in ticket-service,waiting-room-service,seat-lock-service
```

이 runner는 발표와 dev 검증용 bounded consumer입니다. 운영 상시 sink가 필요해지면 같은 S3 partition 규칙을 유지한 채 Lambda MSK trigger, Kafka Connect S3 Sink, 또는 전용 consumer Deployment로 확장합니다.

## Kafka Capacity flow runner

실제 dev 서비스 API를 호출해 Capacity Advisor가 필요로 하는 운영 이벤트 표본을 만듭니다.

```text
waiting-room-service enter
-> waiting-room-service issue-token
-> ticket-service reserve
-> ticket-service confirm
```

1건 생성:

```powershell
python tools/run_kafka_capacity_flow.py --samples 1 --game-id 9001
```

`game-id 9001`은 표본 생성을 위한 격리된 dev sample id입니다. 실제 game 1 대기열에 이미 사용자가 남아 있으면 새 사용자의 순번이 뒤로 밀릴 수 있으므로, 표본 생성에는 깨끗한 game id를 쓰는 편이 안정적입니다.

현재 dev 대기열 정책이 1명/분인 game에서는 여러 건을 만들 때 토큰 발급 window를 기다려야 합니다. runner는 `issue-token` 실패 시 retry를 수행합니다.

```powershell
python tools/run_kafka_capacity_flow.py `
  --samples 20 `
  --game-id 9001 `
  --issue-token-max-attempts 20 `
  --issue-token-retry-delay-seconds 5
```

표본 생성 후 Kafka topic을 S3로 적재합니다.

```powershell
python tools/kafka_s3_sink.py `
  --consume `
  --bootstrap-server boot-twqovxpi.c3.kafka-serverless.ap-northeast-2.amazonaws.com:9098 `
  --bucket baselink-dev-ticket-events-740831361032 `
  --topics ticket.domain.events waiting.operational.events reservation.lifecycle.events `
  --producer-in ticket-service,waiting-room-service,seat-lock-service
```

그 다음 Advisor를 더 현실적인 최소 표본 기준으로 실행합니다.

```powershell
python tools/ticket_capacity_advisor.py `
  --game-id 9001 `
  --current-policy 1 `
  --current-db-connections 19 `
  --lookback-days 1 `
  --minimum-samples 20 `
  --producer-in ticket-service,waiting-room-service
```

테스트:

```powershell
python -m unittest discover -s tools/tests -v
```
