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
- 판단 근거
- Kafka `capacity.signals` 기반 최근 감속/복구 신호

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
```

`CAPACITY_ADVISOR_CURRENT_DB_CONNECTIONS`를 지정하지 않으면 workflow가 CloudWatch `AWS/RDS DatabaseConnections` 최근 값을 조회합니다.

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
  --topics ticket.domain.events waiting.operational.events capacity.signals `
  --producer-in ticket-service,waiting-room-service
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
  --topics ticket.domain.events waiting.operational.events `
  --producer-in ticket-service,waiting-room-service
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
