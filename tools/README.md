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
  --topics ticket.domain.events waiting.operational.events `
  --producer-in ticket-service,waiting-room-service
```

이 runner는 발표와 dev 검증용 bounded consumer입니다. 운영 상시 sink가 필요해지면 같은 S3 partition 규칙을 유지한 채 Lambda MSK trigger, Kafka Connect S3 Sink, 또는 전용 consumer Deployment로 확장합니다.

테스트:

```powershell
python -m unittest discover -s tools/tests -v
```
