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
