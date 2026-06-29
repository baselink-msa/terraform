# Kafka Capacity Advisor E2E 검증 기록

검증일: 2026-06-26

## 1. 검증 목적

이번 검증의 목적은 Kafka 개인 프로젝트가 단순히 MSK Serverless와 producer만 붙인 상태가 아니라, 실제 운영 이벤트를 분석 저장소와 Capacity Advisor까지 연결할 수 있는지 확인하는 것이다.

최종적으로 확인하려는 흐름은 다음과 같다.

```text
waiting-room-service / ticket-service
-> Kafka topics
-> Kafka to S3 sink runner
-> S3 partitioned JSON
-> Glue/Athena ticket_events
-> Capacity Advisor report
```

이 검증을 통해 발표에서 다음 내용을 증명할 수 있다.

- Kafka가 SQS를 대체하는 것이 아니라, 여러 consumer가 재사용할 수 있는 이벤트 로그 역할을 한다.
- Kafka에 들어온 이벤트를 S3/Athena 분석 경로로 내릴 수 있다.
- 대기열 진입, 입장권 발급, 예매 요청, 예매 확정 흐름을 하나의 분석 데이터셋으로 묶을 수 있다.
- Capacity Advisor가 표본 부족 시 추천을 보류하고, 표본이 채워지면 설명 가능한 추천값을 생성한다.

## 2. 검증 전제

MSK Serverless cluster:

```text
baselink-dev-event-streaming
```

Bootstrap broker:

```text
boot-twqovxpi.c3.kafka-serverless.ap-northeast-2.amazonaws.com:9098
```

검증 대상 topic:

```text
ticket.domain.events
waiting.operational.events
```

분석 S3 bucket:

```text
baselink-dev-ticket-events-740831361032
```

분석 prefix:

```text
ticket-events/
```

Capacity Advisor 실행 옵션:

```powershell
python tools\ticket_capacity_advisor.py `
  --game-id 1 `
  --current-policy 1 `
  --current-db-connections 19 `
  --lookback-days 1 `
  --minimum-samples 1 `
  --producer-in ticket-service,waiting-room-service
```

## 3. 실제 이벤트 생성 흐름

검증에는 실제 dev EKS 내부 서비스 호출을 사용했다.

### 3.1 대기열 진입

호출:

```text
POST http://waiting-room-service:8084/api/waiting-room/games/1/enter
Header: X-User-Id: 1783405273
```

생성되는 이벤트:

```text
WAITING_ENTERED
```

### 3.2 입장권 발급

호출:

```text
POST http://waiting-room-service:8084/api/waiting-room/games/1/issue-token
Header: X-User-Id: 1783405273
```

응답에서 발급된 token:

```text
43435b02-2da4-48ce-8750-fb953c2f5283
```

생성되는 이벤트:

```text
ACCESS_TOKEN_ISSUED
```

### 3.3 예약 요청

처음에는 `ticket-service:8082`로 호출해 timeout이 발생했다.

확인 결과 dev Kubernetes Service의 실제 port는 다음과 같았다.

```text
ticket-service:8087
waiting-room-service:8084
```

따라서 올바른 호출은 다음과 같다.

```text
POST http://ticket-service:8087/api/tickets/reserve?gameId=1&seatId=1783405273&lockId=43435b02-2da4-48ce-8750-fb953c2f5283
Header: X-User-Id: 1783405273
```

생성 결과:

```text
reservationId = 4716
status = PENDING
```

생성되는 이벤트:

```text
RESERVATION_REQUESTED
```

### 3.4 예약 확정

호출:

```text
POST http://ticket-service:8087/api/tickets/4716/confirm
Header: X-User-Id: 1783405273
```

생성 결과:

```text
reservationId = 4716
status = CONFIRMED
```

생성되는 이벤트:

```text
RESERVATION_CONFIRMED
```

## 4. Kafka sink 실행 결과

### 4.1 ticket.domain.events dry-run

명령:

```powershell
python tools\kafka_s3_sink.py `
  --consume `
  --dry-run `
  --bootstrap-server boot-twqovxpi.c3.kafka-serverless.ap-northeast-2.amazonaws.com:9098 `
  --bucket baselink-dev-ticket-events-740831361032 `
  --topics ticket.domain.events `
  --producer-in ticket-service `
  --max-seconds 100 `
  --topic-timeout-ms 15000 `
  --ready-timeout-seconds 120
```

결과:

```json
{
  "accepted": 3,
  "written": 0,
  "skipped": 0,
  "invalid": 0
}
```

확인된 이벤트:

```text
RESERVATION_REQUESTED
RESERVATION_CONFIRMED
```

### 4.2 ticket.domain.events S3 적재

결과:

```json
{
  "accepted": 3,
  "written": 3,
  "skipped": 0,
  "invalid": 0
}
```

### 4.3 waiting.operational.events dry-run

결과:

```json
{
  "accepted": 4,
  "written": 0,
  "skipped": 0,
  "invalid": 0
}
```

확인된 이벤트:

```text
WAITING_ENTERED
ACCESS_TOKEN_ISSUED
```

### 4.4 waiting.operational.events S3 적재

결과:

```json
{
  "accepted": 4,
  "written": 4,
  "skipped": 0,
  "invalid": 0
}
```

## 5. S3 적재 확인

S3에서 확인된 주요 object:

```text
ticket-events/event_date=2026-06-26/event_type=WAITING_ENTERED/game_id=1/...
ticket-events/event_date=2026-06-26/event_type=ACCESS_TOKEN_ISSUED/game_id=1/...
ticket-events/event_date=2026-06-26/event_type=RESERVATION_REQUESTED/game_id=1/...
ticket-events/event_date=2026-06-26/event_type=RESERVATION_CONFIRMED/game_id=1/...
```

확인된 대표 객체:

```text
ACCESS_TOKEN_ISSUED:
4e3d883f-7848-42f3-bcc7-fd91699464ee.json

RESERVATION_CONFIRMED:
20740feb-5c9a-41e3-b6a9-8645c0813a1d.json

WAITING_ENTERED:
45d8806c-6621-4d1b-8df8-1fc887d50c23.json
05861a79-d12a-4600-91e3-44a24a115049.json
e6bb73a7-351c-431f-b380-0115d6456193.json
```

## 6. Capacity Advisor 결과

Advisor 입력 집계:

```json
{
  "waiting_entered": 3,
  "access_tokens_issued": 1,
  "reservation_requested": 4,
  "reservation_confirmed": 1,
  "stable_confirmed_per_minute": 1.0,
  "average_waiting_seconds": 4.0,
  "average_effective_enter_per_minute": 1.0,
  "current_db_connections": 19,
  "producer_filters": [
    "ticket-service",
    "waiting-room-service"
  ]
}
```

Advisor 보고서:

```json
{
  "status": "RECOMMENDED",
  "confidence": "MEDIUM",
  "recommendedPolicyEnterPerMinute": 1,
  "effectiveEnterPerMinuteNow": 1,
  "dbPressureLevel": "NORMAL",
  "dbThrottlePercent": 100
}
```

계산 근거:

```text
안정 구간 예약 확정 처리량은 분당 1.00건
예약 요청 대비 확정률은 25.0%
안전계수 0.80 적용
대기시간 보정 1.00 적용
현재 DB 상태 NORMAL
```

추천값이 1로 유지된 이유:

- 현재 정책이 이미 1명/분이다.
- 관측된 평균 effective enter per minute도 1명/분이다.
- 표본이 아직 작으므로 무리하게 입장량을 올리지 않는 것이 안전하다.
- Advisor는 현재 설정 대비 한 번에 25% 넘게 증가하지 않는 guardrail을 적용한다.

## 7. 이번 검증에서 얻은 결과

이번 검증으로 다음을 확인했다.

1. `waiting-room-service`와 `ticket-service`가 실제 운영 이벤트를 Kafka에 발행한다.
2. Kafka sink runner가 두 topic의 이벤트를 읽어 기존 S3 partition layout으로 저장한다.
3. S3에 저장된 Kafka 이벤트는 기존 Glue/Athena `ticket_events` table에서 분석 가능하다.
4. Capacity Advisor가 여러 producer를 묶어 하나의 사용자 흐름으로 분석할 수 있다.
5. 표본 부족 상태에서는 추천을 보류하고, 표본이 채워지면 설명 가능한 추천값을 생성한다.

## 8. 발표 포인트

발표에서는 다음 순서로 보여주면 좋다.

1. MSK Serverless cluster와 topic 목록
2. `ticket-service`, `waiting-room-service`의 Kafka producer 설정
3. 실제 사용자 흐름 API 호출
4. Kafka sink runner 실행 결과
5. S3 partition에 이벤트가 쌓인 화면
6. Athena query 또는 Capacity Advisor 실행 결과
7. 추천값이 왜 1명/분으로 유지되었는지 설명

핵심 메시지:

```text
Kafka를 단순 메시지 브로커로 추가한 것이 아니라,
대기열과 예매 이벤트를 공통 이벤트 로그로 모으고,
이를 S3/Athena 분석 저장소와 Capacity Advisor로 연결해
운영자가 근거 있는 입장 정책을 판단할 수 있게 만들었다.
```

## 9. 남은 작업

현재 검증은 최소 표본으로 E2E 동작을 증명한 상태다.

다음 고도화 후보:

- 부하 테스트로 더 많은 `ACCESS_TOKEN_ISSUED`, `RESERVATION_CONFIRMED` 표본 생성
- `minimum-samples`를 20 이상으로 올려 더 현실적인 추천 보고서 생성
- Kafka sink를 수동 runner에서 상시 consumer 또는 Kafka Connect S3 Sink로 확장
- `reservation.lifecycle.events`, `capacity.signals` topic까지 활용 범위 확장
- 발표용 캡처 수집: Kafka consume, S3 partition, Athena 결과, Advisor markdown 보고서

## 10. 2026-06-27 update: 표본 확대용 flow runner

최소 E2E 검증 이후, 수동 API 호출을 반복하지 않고 표본을 만들 수 있도록 `tools/run_kafka_capacity_flow.py`를 추가했다.

이 runner는 Kafka나 S3에 직접 이벤트를 넣지 않는다. 실제 dev 서비스 API를 호출해 backend 서비스가 자연스럽게 이벤트를 발행하게 만든다.

실행 흐름:

```text
waiting-room-service enter
-> waiting-room-service issue-token
-> ticket-service reserve
-> ticket-service confirm
```

기본 game id는 `9001`이다.

이유:

- 실제 game 1 대기열에는 이전 테스트 사용자가 남아 있을 수 있다.
- 이 경우 새 사용자의 rank가 뒤로 밀려 `issue-token`이 계속 실패할 수 있다.
- 표본 생성용 game id를 분리하면 깨끗한 Redis queue에서 더 안정적으로 시나리오를 반복할 수 있다.
- `ticket_schema.reservations.game_id`에는 foreign key가 없으므로 표본용 game id로 예약 이벤트 생성이 가능하다.

1건 smoke test 결과:

```json
{
  "index": 0,
  "user_id": 2742560957,
  "seat_id": 3682560957,
  "status": "CONFIRMED",
  "reservation_id": 4717
}
```

실행 로그:

```text
enter result: position=1 canEnter=True effectiveEnterPerMinute=40
issue token succeeded
reservation requested: reservationId=4717
reservation confirmed: reservationId=4717
```

표본 확대 예시:

```powershell
python tools/run_kafka_capacity_flow.py `
  --samples 20 `
  --game-id 9001 `
  --issue-token-max-attempts 20 `
  --issue-token-retry-delay-seconds 5
```

표본 생성 후에는 기존 Kafka sink와 Capacity Advisor를 같은 game id로 실행한다.

```powershell
python tools/kafka_s3_sink.py `
  --consume `
  --bootstrap-server boot-twqovxpi.c3.kafka-serverless.ap-northeast-2.amazonaws.com:9098 `
  --bucket baselink-dev-ticket-events-740831361032 `
  --topics ticket.domain.events waiting.operational.events `
  --producer-in ticket-service,waiting-room-service

python tools/ticket_capacity_advisor.py `
  --game-id 9001 `
  --current-policy 40 `
  --current-db-connections 19 `
  --lookback-days 1 `
  --minimum-samples 20 `
  --producer-in ticket-service,waiting-room-service
```

## 11. 2026-06-27 update: minimum-samples 20 기준 검증 결과

표본 확대용 flow runner를 사용해 `gameId=9001` 기준 실제 서비스 흐름 20건을 추가 생성했다.

실행 명령:

```powershell
python tools/run_kafka_capacity_flow.py `
  --samples 20 `
  --game-id 9001 `
  --issue-token-max-attempts 20 `
  --issue-token-retry-delay-seconds 5
```

실행 결과:

```json
{
  "samplesRequested": 20,
  "succeeded": 20,
  "failed": 0
}
```

생성된 예약 범위:

```text
reservationId = 4718 ~ 4737
status = CONFIRMED
```

이후 Kafka sink runner로 topic 이벤트를 S3에 적재했다.

```powershell
python tools/kafka_s3_sink.py `
  --consume `
  --bootstrap-server boot-twqovxpi.c3.kafka-serverless.ap-northeast-2.amazonaws.com:9098 `
  --bucket baselink-dev-ticket-events-740831361032 `
  --topics ticket.domain.events `
  --producer-in ticket-service

python tools/kafka_s3_sink.py `
  --consume `
  --bootstrap-server boot-twqovxpi.c3.kafka-serverless.ap-northeast-2.amazonaws.com:9098 `
  --bucket baselink-dev-ticket-events-740831361032 `
  --topics waiting.operational.events `
  --producer-in waiting-room-service
```

S3 적재 결과:

```text
ticket.domain.events:
accepted = 45
written = 45

waiting.operational.events:
accepted = 49
written = 49
```

`accepted` 수가 20보다 큰 이유는 sink runner가 topic을 처음부터 읽어 이전 검증 이벤트도 함께 다시 처리했기 때문이다. S3 object key는 `eventId` 기반이므로 같은 이벤트는 같은 위치에 덮어써져 idempotent하게 처리된다.

S3에서 `game_id=9001` 기준 객체 수를 확인했다.

```text
Count = 84
```

이는 다음과 일치한다.

```text
4 event types x 21 samples = 84 objects
```

21건인 이유는 2026-06-27에 먼저 수행한 smoke test 1건과 이후 표본 확대 20건이 함께 포함되었기 때문이다.

Capacity Advisor 실행:

```powershell
python tools/ticket_capacity_advisor.py `
  --game-id 9001 `
  --current-policy 40 `
  --current-db-connections 19 `
  --lookback-days 1 `
  --minimum-samples 20 `
  --producer-in ticket-service,waiting-room-service
```

Advisor 입력 집계:

```json
{
  "waiting_entered": 21,
  "access_tokens_issued": 21,
  "reservation_requested": 21,
  "reservation_confirmed": 21,
  "stable_confirmed_per_minute": 1.0,
  "average_waiting_seconds": 11.29,
  "average_effective_enter_per_minute": 40.0,
  "current_db_connections": 19
}
```

Advisor 결과:

```json
{
  "status": "RECOMMENDED",
  "confidence": "MEDIUM",
  "recommendedPolicyEnterPerMinute": 1,
  "effectiveEnterPerMinuteNow": 1,
  "dbPressureLevel": "NORMAL",
  "dbThrottlePercent": 100
}
```

추천값이 `1`로 나온 이유:

- 표본은 충분해졌지만 안정 구간의 예약 확정 처리량이 분당 1건으로 관측되었다.
- 예약 요청 대비 확정률은 100%였지만, 실제 처리량 기준 capacity가 낮게 측정되었다.
- Advisor는 안전계수 `0.8`을 적용한다.
- 현재 정책은 40명/분이지만, 관측된 처리량이 낮기 때문에 안전한 추천값을 1명/분으로 제시했다.
- 현재 DB 상태는 `NORMAL`이므로 실시간 감속률은 100%이다.

이번 검증의 의미:

- 최소 표본 1건 기반 검증을 넘어 `minimum-samples=20` 기준으로도 Advisor가 실행되었다.
- Kafka 이벤트 4종이 모두 20건 이상 확보되었다.
- Kafka → S3 → Athena → Capacity Advisor 흐름이 더 현실적인 표본 수로 검증되었다.
- 추천값이 무조건 증가하지 않고, 실제 처리량이 낮으면 보수적으로 낮은 값을 제안한다는 점을 확인했다.

발표 메시지:

```text
표본을 20건 이상 확보한 뒤에도 Capacity Advisor는 현재 정책을 무조건 높이지 않았습니다.
Kafka/Athena에서 관측한 실제 예약 확정 처리량이 낮았기 때문에,
안전계수와 DB 상태를 반영해 1명/분을 추천했습니다.
즉, 이 기능은 자동 증설 버튼이 아니라 운영자가 검토할 수 있는 보수적 의사결정 근거를 제공합니다.
```

## 12. 2026-06-29 update: Slack report 전 실제 서비스 표본 재검증

목적:

- Slack report가 `INSUFFICIENT_DATA`와 `NO_EVENTS`에 머무르는 상태를 넘어서, 실제 dev 서비스 이벤트를 기반으로 의미 있는 리포트를 만들 수 있는지 확인한다.
- 임의 계산값이 아니라 `waiting-room-service`와 `ticket-service` API를 직접 호출해 생성된 이벤트로 Capacity Advisor를 검증한다.
- SQS/Worker, Valkey, Kafka pipeline health 섹션까지 함께 정상 조회되는지 확인한다.

사전 확인:

```powershell
kubectl get nodes
kubectl get deploy,pod -n baselink-dev
```

결과:

- 현재 접속 IP에서 EKS API 접근 가능
- `waiting-room-service`, `ticket-service`, `seat-lock-service`, `ticket-worker-service` 모두 Ready

1건 smoke test:

```powershell
python -B tools/run_kafka_capacity_flow.py `
  --samples 1 `
  --game-id 9001 `
  --issue-token-max-attempts 20 `
  --issue-token-retry-delay-seconds 5
```

결과:

```json
{
  "samplesRequested": 1,
  "succeeded": 1,
  "failed": 0,
  "reservationId": 6246
}
```

20건 표본 생성:

```powershell
python -B tools/run_kafka_capacity_flow.py `
  --samples 20 `
  --game-id 9001 `
  --issue-token-max-attempts 20 `
  --issue-token-retry-delay-seconds 5
```

결과:

```json
{
  "samplesRequested": 20,
  "succeeded": 20,
  "failed": 0,
  "reservationIdRange": "6247~6266"
}
```

Kafka sink runner 보강:

- 기존 sink runner는 임시 consumer Pod가 아직 `ContainerCreating`인 상태에서 바로 `kubectl logs`를 호출해 실패할 수 있었다.
- `kubectl wait --for=condition=Ready`로 Pod Ready를 기다린 뒤 logs를 조회하도록 수정했다.
- Ready 실패 시 `kubectl get pod`와 `kubectl describe pod` 결과를 함께 출력하도록 개선했다.

Capacity Advisor 전체 리포트 검증:

```powershell
python -B tools/ticket_capacity_advisor.py `
  --game-id 9001 `
  --current-policy 40 `
  --current-db-connections 19 `
  --lookback-days 1 `
  --minimum-samples 20 `
  --producer-in ticket-service,waiting-room-service
```

입력 집계:

```json
{
  "waiting_entered": 21,
  "access_tokens_issued": 21,
  "reservation_requested": 21,
  "reservation_confirmed": 21,
  "stable_confirmed_per_minute": 1.0,
  "average_waiting_seconds": 4.1,
  "average_effective_enter_per_minute": 40.0,
  "current_db_connections": 19
}
```

운영 상태 섹션:

```json
{
  "sqsWorker": {
    "status": "HEALTHY",
    "visible_messages": 0,
    "not_visible_messages": 0,
    "oldest_message_age_seconds": 0,
    "dlq_visible_messages": 0
  },
  "valkeyStatus": {
    "status": "HEALTHY",
    "max_engine_cpu_percent": 0.75,
    "max_memory_usage_percent": 5.3,
    "total_evictions": 0,
    "max_replication_lag_seconds": 0.0
  },
  "kafkaPipelineHealth": {
    "status": "HEALTHY",
    "total_events": 84,
    "producer_counts": {
      "ticket-service": 42,
      "waiting-room-service": 42
    },
    "event_type_counts": {
      "WAITING_ENTERED": 21,
      "ACCESS_TOKEN_ISSUED": 21,
      "RESERVATION_REQUESTED": 21,
      "RESERVATION_CONFIRMED": 21
    }
  }
}
```

Advisor 결과:

```json
{
  "status": "RECOMMENDED",
  "confidence": "MEDIUM",
  "recommendedPolicyEnterPerMinute": 1,
  "effectiveEnterPerMinuteNow": 1,
  "dbPressureLevel": "NORMAL",
  "dbThrottlePercent": 100
}
```

해석:

- 실제 dev 서비스 경로로 생성한 이벤트가 S3/Athena event lake에 반영되었다.
- `minimum-samples=20` 기준을 만족해 `INSUFFICIENT_DATA`가 아니라 `RECOMMENDED`로 판단했다.
- SQS/Worker는 backlog와 DLQ가 없어 `HEALTHY`로 판단했다.
- Valkey는 CPU, memory, eviction, replication lag가 모두 안정 범위라 `HEALTHY`로 판단했다.
- Kafka pipeline은 기대 producer와 event type이 모두 존재해 `HEALTHY`로 판단했다.
- 추천값이 `1명/분`인 이유는 현재 표본에서 관측된 안정 예매 확정 처리량이 분당 1건 수준이기 때문이다. 이는 "무조건 많이 입장"시키는 기능이 아니라, 실제 처리량이 낮게 관측되면 보수적으로 추천하는 운영 의사결정 보조 도구임을 보여준다.

Slack report 수동 실행 검증:

- GitHub Actions `Capacity Advisor Slack Report`를 수동 실행했다.
- Workflow run: `https://github.com/baselink-msa/terraform/actions/runs/28355999346`
- Slack 메시지에서도 `RECOMMENDED`, SQS `HEALTHY`, Valkey `HEALTHY`, Kafka pipeline `HEALTHY`가 표시되었다.
- Slack 메시지의 산출 지표에 안정 확정 처리량 `1.0건/분`, 예약 확정률 `100.0%`, 안전계수 `0.8`, 대기시간 보정 `1.0`, 관측 입장량 상한 `40.0명/분`이 표시되었다.
- 이 캡처는 발표에서 "운영자가 Slack만 보고 추천값과 그 이유, 주변 인프라 상태를 함께 확인할 수 있다"는 근거로 사용할 수 있다.

## 2026-06-29 seat-lock Kafka E2E 검증

목적:

- 좌석 잠금 계층도 Kafka 이벤트 스트리밍 플랫폼에 연결되었는지 확인한다.
- `seat-lock-service`가 발행한 이벤트가 Kafka topic을 거쳐 S3 event lake에 저장되고 Athena에서 조회되는지 검증한다.
- Valkey 기반 좌석 잠금 흐름을 Capacity Advisor/운영 리포트가 나중에 재사용할 수 있는 분석 이벤트로 남긴다.

검증 흐름:

```text
seat-lock-service API
-> reservation.lifecycle.events
-> Kafka S3 sink runner
-> S3 ticket-events partition
-> Glue/Athena ticket_events
```

검증 중 확인한 이슈:

- `seat-lock-service`는 Kafka publish metric 기준 이벤트를 정상 발행했다.
- Kafka S3 sink runner도 `accepted=5`, `written=5`로 S3 적재에 성공했다.
- 하지만 최초 Athena 조회 결과는 0건이었다.
- 원인은 Glue table의 partition projection `projection.event_type.values`에 seat-lock 이벤트 타입이 빠져 있었기 때문이다.
- S3에는 파일이 있어도 projection enum에 없는 `event_type` partition은 Athena가 스캔하지 않는다.

수정:

- `modules/ticket-event-writer/main.tf`의 Glue projection 허용 event type에 아래 항목을 추가했다.
  - `ADMISSION_THROTTLE_APPLIED`
  - `ADMISSION_STOP_APPLIED`
  - `ADMISSION_THROTTLE_RECOVERED`
  - `SEAT_LOCK_REQUESTED`
  - `SEAT_LOCKED`
  - `SEAT_LOCK_FAILED`
  - `SEAT_UNLOCKED`
- Lambda 기반 `ticket-event-writer`의 허용 event type도 같은 목록으로 확장했다.
- seat-lock 이벤트가 S3 key로 정상 변환되는 단위 테스트를 추가했다.

검증 명령:

```powershell
python -B -m unittest modules.ticket-event-writer.tests.test_handler
```

Terraform apply 이후 실제 Glue projection:

```text
WAITING_ENTERED,
ACCESS_TOKEN_ISSUED,
RESERVATION_REQUESTED,
RESERVATION_CONFIRMED,
ADMISSION_THROTTLE_APPLIED,
ADMISSION_STOP_APPLIED,
ADMISSION_THROTTLE_RECOVERED,
SEAT_LOCK_REQUESTED,
SEAT_LOCKED,
SEAT_LOCK_FAILED,
SEAT_UNLOCKED
```

Athena 검증 결과:

| event_type | producer | count | latest |
| --- | --- | ---: | --- |
| `SEAT_LOCKED` | `seat-lock-service` | 1 | `2026-06-29T07:57:30.310014051Z` |
| `SEAT_LOCK_FAILED` | `seat-lock-service` | 1 | `2026-06-29T07:57:30.412134716Z` |
| `SEAT_LOCK_REQUESTED` | `seat-lock-service` | 2 | `2026-06-29T07:57:30.375012452Z` |
| `SEAT_UNLOCKED` | `seat-lock-service` | 1 | `2026-06-29T07:57:30.567262716Z` |

해석:

- 좌석 잠금 요청, 잠금 성공, 중복 잠금 실패, 잠금 해제 이벤트가 모두 Kafka/S3/Athena 경로에서 확인되었다.
- seat-lock 이벤트는 이제 단순 로그가 아니라 날짜와 이벤트 타입 기준으로 조회 가능한 운영 분석 데이터가 되었다.
- 이후 Capacity Advisor 리포트에 좌석 잠금 성공률, 실패율, 해제 흐름, Valkey 상태와의 상관관계를 추가할 수 있는 기반이 마련되었다.

## 2026-06-29 Capacity Advisor Slack seat-lock/infra audit 검증

목적:

- Capacity Advisor Slack 메시지에 좌석 잠금 이벤트 상태가 표시되는지 확인한다.
- `infra.audit.events` 1차 기반으로 SQS worker 상태와 Kafka S3 sink 완료 이벤트가 S3/Athena event lake에 기록되는지 확인한다.
- Capacity Advisor의 Kafka pipeline health가 audit event까지 함께 읽는지 확인한다.

Slack report 수동 실행:

- Workflow run: `https://github.com/baselink-msa/terraform/actions/runs/28361099309`
- generatedAt: `2026-06-29T09:09:42.570328+00:00`

Slack 메시지 주요 결과:

```text
상태: RECOMMENDED
신뢰도: MEDIUM
현재 정책: 40명/분
추천 정책: 1명/분
현재 DB 반영 입장량: 1명/분
DB 상태: NORMAL (16/60)
표본: 대기열 진입 21 / 입장권 21 / 예약 요청 21 / 예약 확정 21
SQS/Worker 상태: HEALTHY
Valkey/좌석 잠금 계층 상태: HEALTHY
Kafka 파이프라인 상태: HEALTHY
```

좌석 잠금 이벤트 상태:

```text
상태: COMPETITION_DETECTED
producer: seat-lock-service
요청 2 / 성공 1 / 실패 1 / 해제 1
성공률 50.0% / 실패율 50.0% / 해제율 100.0%
latest SEAT_UNLOCKED at 2026-06-29T07:57:30.567262716Z / seat 900819838
```

해석:

- `COMPETITION_DETECTED`는 장애가 아니라 좌석 선점 경쟁 또는 중복 잠금 시도가 관측됐다는 의미다.
- 현재 seat-lock 표본은 E2E 검증을 위해 일부러 중복 잠금 실패를 만든 데이터이므로 실패율 50%가 표시된다.
- Valkey metric은 `HEALTHY`이고 seat-lock event도 Athena에서 정상 조회되므로, 좌석 잠금 계층의 관측 경로가 정상이다.

infra audit event 실제 적재:

```powershell
python -B tools/record_sqs_worker_audit.py `
  --bucket baselink-dev-ticket-events-740831361032 `
  --source-queue-name ticket-confirm-queue `
  --dlq-name ticket-confirm-dlq `
  --region ap-northeast-2
```

결과:

```json
{
  "eventType": "SQS_WORKER_STATUS_RECORDED",
  "status": "HEALTHY",
  "visible_messages": 0,
  "not_visible_messages": 0,
  "dlq_visible_messages": 0
}
```

Kafka S3 sink 완료 audit event:

```powershell
python -B tools/kafka_s3_sink.py `
  --input-jsonl <empty-file> `
  --bucket baselink-dev-ticket-events-740831361032 `
  --producer-in seat-lock-service `
  --topics reservation.lifecycle.events `
  --emit-audit-event
```

Athena audit event 검증:

| event_type | producer | count | latest |
| --- | --- | ---: | --- |
| `KAFKA_S3_SINK_COMPLETED` | `kafka-s3-sink` | 1 | `2026-06-29T09:11:31.944598Z` |
| `SQS_WORKER_STATUS_RECORDED` | `sqs-worker-audit-recorder` | 1 | `2026-06-29T09:11:19.599924Z` |

audit event 반영 후 Capacity Advisor 로컬 재실행 결과:

```json
{
  "kafkaPipelineHealth": {
    "status": "HEALTHY",
    "total_events": 91,
    "producer_counts": {
      "ticket-service": 42,
      "waiting-room-service": 42,
      "seat-lock-service": 5,
      "sqs-worker-audit-recorder": 1,
      "kafka-s3-sink": 1
    },
    "sink_completed_events": 1
  }
}
```

의미:

- Capacity Advisor가 단순 입장량 추천을 넘어 SQS, Valkey, Kafka, seat-lock, infra audit event까지 함께 보는 운영 리포트로 확장되었다.
- Slack 메시지 하나로 운영자가 추천 입장량과 주변 인프라 상태를 함께 볼 수 있다.
- 발표에서는 “운영 의사결정용 리포트”와 “장애 알림”을 분리해 설명할 수 있다.
