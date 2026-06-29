# Load Test Validation Plan

## 1. 문서 목적

이 문서는 Baselink dev 환경에서 부하테스트를 수행할 때, Data & Async / Reliability 담당 영역이 실제로 정상 동작하는지 검증하기 위한 기준을 정리한다.

부하테스트 담당자의 Ansible/k6 실행 환경이 준비되면, 이 문서를 기준으로 다음을 확인한다.

- RDS connection pool과 connection budget이 안전하게 유지되는가
- 대기열 자동 감속이 RDS 여유율을 반영해 신규 입장을 조절하는가
- SQS worker와 DLQ 흐름이 부하 상황에서도 안정적으로 동작하는가
- Valkey 기반 대기열/좌석 잠금이 부하 상황에서도 장애 없이 동작하는가
- Kafka 이벤트 스트리밍과 S3/Athena 적재가 누락 없이 이어지는가
- Capacity Advisor가 실제 부하 표본으로 안전 입장량을 계산할 수 있는가
- Read Replica 또는 RDS Proxy 도입이 필요한 근거가 있는가

이 문서는 테스트 실행 명령 모음이 아니라, 테스트 결과를 어떻게 해석할지에 대한 기준 문서다.

## 2. 현재 실행 대기 상태

현재 Ansible 레포에는 Capacity Advisor 검증용 k6 시나리오가 추가되어 있다.

```text
ansible/k6/capacity-advisor-flow.js
ansible/docs/capacity-advisor-loadtest-verification.md
```

다만 로컬에는 아직 부하테스트 EC2 접속 정보가 담긴 `ansible/inventory.ini`가 없다.

따라서 현재 상태는 다음과 같다.

```text
부하테스트 시나리오 준비 완료
부하테스트 실행 환경 inventory 대기 중
```

inventory가 준비되면 다음 순서로 진행한다.

```text
1. ansible loadtest -m ping
2. ansible-playbook ansible/playbook.yml
3. capacity-advisor-flow.js smoke 실행
4. baseline/load 단계 실행
5. Kafka -> S3 sink 실행
6. Capacity Advisor 실행
7. AWS/Grafana 지표와 함께 결과 해석
```

## 3. 검증 대상과 기대 결과

| 영역 | 검증 목표 | 정상 기준 | 이상 신호 |
| --- | --- | --- | --- |
| RDS | connection budget 유지 | DatabaseConnections가 app budget 범위 안에서 움직임 | 연결 수 급증, Hikari timeout, password/auth 오류 |
| 대기열 자동 감속 | DB 여유율 기반 신규 입장 조절 | RDS 사용률이 높아질수록 입장량이 완만하게 감소 | DB가 위험한데 입장이 계속 열림, 또는 과도하게 0에 가까워짐 |
| SQS worker | 비동기 예매 확정 처리 | backlog가 일시 증가해도 해소됨, DLQ 증가 없음 | Visible messages와 Oldest age가 계속 증가 |
| Valkey | 대기열/좌석 잠금 안정성 | CurrConnections, CPU, latency가 안정 범위 | eviction, failover, latency 급증 |
| Kafka | 이벤트 dual publish | ticket/waiting topic에 이벤트 적재 | producer failure metric 증가, topic 이벤트 누락 |
| S3/Athena | 분석 가능한 이벤트 적재 | 날짜/gameId/producer 기준 조회 가능 | partition 누락, malformed event, count 불일치 |
| Capacity Advisor | 실제 표본 기반 추천 | status=RECOMMENDED, confidence=MEDIUM 이상 | 표본 부족, 추천값 과도하게 낮음, 계산 근거 부족 |
| Read Replica 판단 | 읽기 병목 여부 확인 | read 부하가 RDS CPU/IOPS를 지배하는지 확인 | 조회 API p95 증가와 ReadIOPS/CPU 상승 |
| RDS Proxy 판단 | connection storm 여부 확인 | pool/KEDA budget으로 충분한지 확인 | CPU는 여유인데 connection timeout 발생 |

## 4. 권장 부하테스트 순서

### 4.1 Smoke

목적은 전체 API 흐름이 깨지지 않는지 확인하는 것이다.

```bash
ansible-playbook ansible/run-scenario.yml \
  -e scenario_script=capacity-advisor-flow.js \
  -e scenario_vus=2 \
  -e scenario_duration=1m \
  -e loadtest_capacity_game_id=9001 \
  -e loadtest_user_id_base=2740000000 \
  -e loadtest_seat_id_base=3680000000
```

정상 기준:

```text
waiting enter 성공
waiting issue-token 성공
ticket reserve 성공
ticket confirm 성공
k6 threshold 통과
```

### 4.2 Baseline

목적은 Capacity Advisor가 사용할 수 있는 최소 표본을 확보하는 것이다.

```bash
ansible-playbook ansible/run-scenario.yml \
  -e scenario_script=capacity-advisor-flow.js \
  -e scenario_vus=10 \
  -e scenario_duration=3m \
  -e loadtest_capacity_game_id=9001 \
  -e loadtest_user_id_base=2741000000 \
  -e loadtest_seat_id_base=3681000000
```

정상 기준:

```text
reservation_confirmed 표본 20건 이상
ticket.domain.events와 waiting.operational.events 적재
S3 sink 이후 Athena/Advisor 조회 가능
```

### 4.3 Load

목적은 실제 부하 증가 시 병목 위치를 찾는 것이다.

```bash
ansible-playbook ansible/run-scenario.yml \
  -e scenario_script=capacity-advisor-flow.js \
  -e scenario_vus=30 \
  -e scenario_duration=5m \
  -e loadtest_capacity_game_id=9001 \
  -e loadtest_user_id_base=2742000000 \
  -e loadtest_seat_id_base=3682000000
```

정상 기준:

```text
5xx가 지속 증가하지 않음
ticket-service와 waiting-room-service p95가 안정화됨
RDS connection이 budget 안에 있음
SQS backlog가 계속 누적되지 않음
Kafka/S3 이벤트 적재가 따라감
```

## 5. 테스트 후 Capacity Advisor 실행

부하테스트가 끝나면 Kafka topic의 이벤트를 S3로 적재한다.

```bash
python tools/kafka_s3_sink.py \
  --topic ticket.domain.events \
  --max-records 1000 \
  --idle-timeout-seconds 15

python tools/kafka_s3_sink.py \
  --topic waiting.operational.events \
  --max-records 1000 \
  --idle-timeout-seconds 15
```

그 다음 Capacity Advisor를 실행한다.

```bash
python tools/ticket_capacity_advisor.py \
  --game-id 9001 \
  --current-policy 40 \
  --current-db-connections 19 \
  --lookback-days 1 \
  --minimum-samples 20 \
  --producer-in ticket-service,waiting-room-service
```

결과에서 확인할 값:

```text
waiting_entered
access_tokens_issued
reservation_requested
reservation_confirmed
stable_confirmed_per_minute
average_waiting_seconds
recommendedPolicyEnterPerMinute
confidence
status
```

## 6. Capacity Advisor 추천값 해석 기준

Capacity Advisor의 추천값은 낮을수록 무조건 좋은 값이 아니다.

추천값이 지나치게 낮으면 다음 문제가 생긴다.

- 사용자는 대기열에서 오래 기다린다.
- RDS와 worker 자원이 남아도 신규 입장이 막힌다.
- 서비스 처리량이 과도하게 줄어든다.
- 실제 운영 정책으로 사용하기 어렵다.

따라서 추천값은 다음 지표와 함께 해석한다.

| 지표 | 의미 |
| --- | --- |
| `stable_confirmed_per_minute` | 실제 안정적으로 확정 처리된 분당 처리량 |
| `average_waiting_seconds` | 사용자가 평균적으로 기다린 시간 |
| RDS DatabaseConnections | DB connection 여유율 |
| SQS backlog | worker가 처리량을 따라가고 있는지 |
| ticket-service p95 | 예매 요청 경로의 응답 지연 |
| waiting issue-token 실패율 | 대기열 정책이 너무 보수적인지 |

운영적으로는 다음 보정이 필요하다.

```text
최소 입장량 floor
직전 정책 대비 최대 증감률
confidence 낮을 때 추천 보류
표본 부족 시 추천값 미적용
DB 위험 상태에서는 보수적 추천
```

발표 메시지:

```text
Capacity Advisor는 단순히 가장 낮은 입장량을 추천하는 도구가 아니라,
실제 확정 처리량과 DB 여유율, 대기시간을 함께 보면서
서비스 안정성과 사용자 대기시간 사이의 균형점을 찾기 위한 판단 보조 도구입니다.
```

## 7. RDS Proxy 도입 판단 기준

RDS Proxy는 DB가 느려서가 아니라 connection 관리가 병목일 때 검토한다.

도입을 검토할 신호:

- Pod scale-out 이후 DatabaseConnections가 급증한다.
- RDS CPU는 여유가 있는데 HikariPool timeout이 발생한다.
- 짧은 요청이 많아 connection 생성/반납 churn이 커진다.
- Lambda 또는 burst성 workload가 RDS에 직접 연결된다.
- 장애 직후 Pod 재시작이 몰리면서 connection storm이 발생한다.

아직 도입하지 않아도 되는 신호:

- connection budget 안에서 안정적으로 유지된다.
- timeout 없이 p95가 안정적이다.
- 병목이 connection이 아니라 query, CPU, IO, lock 쪽이다.
- 현재 비용과 운영 복잡도 대비 이득이 작다.

발표 메시지:

```text
현재는 Hikari pool과 KEDA max replica를 connection budget에 맞춰 제한해 RDS를 보호했습니다.
부하테스트에서 connection storm이나 pool timeout이 확인되면 RDS Proxy를 도입하는 것이 합리적입니다.
```

## 8. Read Replica 도입 판단 기준

Read Replica는 조회 API가 실제 병목임이 확인될 때 검토한다.

도입을 검토할 신호:

- `/api/games`, `/api/games/{gameId}/seats` 같은 조회 API p95가 크게 증가한다.
- RDS ReadIOPS, CPU, DB Load가 읽기 요청에 의해 상승한다.
- write 부하는 크지 않은데 조회 요청 때문에 전체 DB가 느려진다.
- replica lag를 허용할 수 있는 API가 명확하다.

주의할 점:

- 예매 확정, 좌석 잠금, 결제처럼 최신성이 중요한 경로는 reader로 보내면 안 된다.
- replica lag가 사용자에게 잘못된 좌석 상태를 보여줄 수 있다.
- 애플리케이션에 writer/reader datasource 분리가 필요하다.

발표 메시지:

```text
Read Replica는 무조건 만드는 것이 아니라,
부하테스트에서 읽기 API가 RDS 병목을 만든다는 근거가 확인될 때
조회성 API부터 분리하는 방식으로 도입하는 것이 안전합니다.
```

## 9. 2026-06-29 실제 부하테스트 기반 Capacity Advisor 재검증

### 9.1 검증 목적

이번 검증의 목적은 Capacity Advisor가 수동으로 만든 작은 표본이 아니라 실제 k6 부하테스트로 생성된 이벤트 표본을 기준으로 안전 입장량을 다시 계산할 수 있는지 확인하는 것이다.

검증 흐름:

```text
k6 부하테스트
-> waiting-room-service / ticket-service 실제 API 호출
-> Kafka 이벤트 발행
-> Kafka to S3 sink 실행
-> S3/Athena event lake 최신화
-> Capacity Advisor 재계산
-> RDS/SQS/Valkey/Kafka pipeline health 함께 확인
```

이 검증을 통해 다음을 확인했다.

- 부하 상황에서도 ticket reserve/confirm 경로가 정상 처리되는가
- waiting-room admission control이 입장 제한을 실제로 수행하는가
- Kafka/S3/Athena event lake가 부하테스트 이벤트를 분석 가능한 표본으로 축적하는가
- Capacity Advisor가 실제 부하 표본을 기반으로 추천값과 판단 근거를 생성하는가
- RDS Proxy 또는 Read Replica를 즉시 도입해야 할 정도의 DB 병목이 있었는가

### 9.2 k6 실행 결과

실행 환경:

| 항목 | 값 |
| --- | --- |
| 부하테스트 실행 위치 | EC2 `baselink-dev-loadtest-20260628` |
| 대상 gameId | `9001` |
| 주요 API 흐름 | 대기열 진입 -> 입장권 발급 -> 예매 요청 -> 예매 확정 |
| 결과 파일 위치 | `/opt/baselink-loadtest/results/*/summary.json` |

실행 결과:

| 시나리오 | VU | 기간 | HTTP 요청 수 | HTTP 실패율 | Check 성공률 | 전체 p95 | 예약 요청 p95 | 예약 확정 p95 | 입장권 발급 p95 |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| smoke | 2 | 1m | 321 | 0.00% | 99.84% | 93.45ms | 41.95ms | 39.19ms | 111.91ms |
| baseline | 10 | 3m | 1,278 | 0.08% | 99.80% | 68.86ms | 57.16ms | 43.15ms | 87.83ms |
| load | 30 | 5m | 3,549 | 0.20% | 74.27% | 55.61ms | 129.80ms | 126.23ms | 133.13ms |

30 VU load 시나리오에서 k6 `checks` threshold는 실패했다. 다만 실패 원인은 ticket reserve/confirm API가 아니라 waiting-room token/status check였다.

주요 check 결과:

| 시나리오 | issue-token 성공 | issue-token 실패 | ticket reserve 성공 | ticket reserve 실패 | ticket confirm 성공 | ticket confirm 실패 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| smoke | 72 | 0 | 72 | 0 | 72 | 0 |
| baseline | 152 | 1 | 152 | 0 | 152 | 0 |
| load | 72 | 7 | 72 | 0 | 72 | 0 |

해석:

- smoke와 baseline에서는 API와 예매 확정 흐름이 거의 정상이고 응답 시간도 안정적이다.
- 30 VU load에서는 HTTP 실패율이 0.20%로 낮지만, 대기열 position/token check 성공률이 떨어졌다.
- ticket reserve/confirm은 load 시나리오에서도 성공했고 p95도 130ms 안팎으로 유지됐다.
- 따라서 이번 부하에서 확인된 주요 현상은 DB/RDS 병목이 아니라 waiting-room admission control에 의한 입장 제한이다.

### 9.3 부하 이후 인프라 상태

부하테스트 직후 확인한 주요 인프라 지표:

| 영역 | 결과 | 해석 |
| --- | --- | --- |
| RDS DatabaseConnections | 최대 28/60 | connection budget 대비 여유 있음 |
| SQS `ticket-confirm-queue` | visible 0 / not visible 0 / delayed 0 | worker backlog 없음 |
| SQS `ticket-confirm-dlq` | visible 0 / not visible 0 / delayed 0 | DLQ 누적 없음 |
| backend deployment | waiting-room, ticket, ticket-worker, seat-lock 모두 2/2 Ready | 부하 후 rollout/Pod 상태 정상 |
| Valkey | CPU 1.23%, memory 5.32%, evictions 0, replication lag 0초 | 좌석 잠금/대기열 캐시 계층 안정 |

KEDA 상태:

- `ticket-worker-scaler`는 SQS trigger 기준으로 Ready 상태였다.
- 예측 감속 관련 backend scaler들은 운영 정책상 paused 상태였다.
- SQS backlog가 없었기 때문에 worker scale-out이 필요한 상황은 아니었다.

### 9.4 Kafka/S3/Athena 적재와 Capacity Advisor 재계산

부하테스트 이후 Kafka 이벤트를 S3 event lake로 다시 적재했다.

```powershell
python -B tools/kafka_s3_sink.py `
  --consume `
  --bootstrap-server boot-twqovxpi.c3.kafka-serverless.ap-northeast-2.amazonaws.com:9098 `
  --bucket baselink-dev-ticket-events-740831361032 `
  --topics ticket.domain.events waiting.operational.events reservation.lifecycle.events capacity.signals `
  --namespace baselink-dev `
  --service-account backend-runtime `
  --topic-timeout-ms 20000 `
  --ready-timeout-seconds 180 `
  --max-seconds 240 `
  --emit-audit-event
```

또한 부하 이후 SQS/worker 상태를 audit event로 남겼다.

```powershell
python -B tools/record_sqs_worker_audit.py `
  --bucket baselink-dev-ticket-events-740831361032 `
  --source-queue-name ticket-confirm-queue `
  --dlq-name ticket-confirm-dlq `
  --region ap-northeast-2
```

audit 결과:

```json
{
  "eventType": "SQS_WORKER_STATUS_RECORDED",
  "status": "HEALTHY",
  "visible_messages": 0,
  "not_visible_messages": 0,
  "oldest_message_age_seconds": 0,
  "dlq_visible_messages": 0
}
```

Capacity Advisor 재계산 명령:

```powershell
python -B tools/ticket_capacity_advisor.py `
  --game-id 9001 `
  --current-policy 40 `
  --current-db-connections 28 `
  --lookback-days 1 `
  --minimum-samples 20 `
  --producer-in ticket-service,waiting-room-service `
  --sqs-source-queue-name ticket-confirm-queue `
  --sqs-dlq-name ticket-confirm-dlq `
  --valkey-cluster-ids baselink-dev-redis-001,baselink-dev-redis-002 `
  --valkey-replica-cluster-ids baselink-dev-redis-002 `
  --output-dir capacity-reports/loadtest-capacity-advisor-20260629
```

Capacity Advisor 결과:

| 항목 | 결과 |
| --- | --- |
| 상태 | `RECOMMENDED` |
| 신뢰도 | `HIGH` |
| 현재 정책 | 40명/분 |
| 추천 정책 | 1명/분 |
| DB 상태 | `NORMAL` (28/60) |
| 대기열 진입 | 402 |
| 입장권 발급 | 317 |
| 예약 요청 | 317 |
| 예약 확정 | 317 |
| 안정 구간 예약 확정 처리량 | 2.0건/분 |
| 예약 확정률 | 100.0% |
| 평균 대기 시간 | 약 8.31초 |
| Kafka pipeline health | `HEALTHY`, total events 1,361 |
| SQS/Worker | `HEALTHY` |
| Valkey | `HEALTHY` |

추천값이 1명/분으로 나온 이유:

```text
stable_confirmed_per_minute = 2.0
reservation_conversion = 100%
safety_factor = 0.8
waiting_factor = 1.0

raw_recommendation = 2.0 * 1.0 * 0.8 * 1.0 = 1.6
recommendedPolicyEnterPerMinute = floor(1.6) = 1
```

따라서 이번 추천값은 DB가 위험해서 1명/분을 제안한 것이 아니다. 현재 부하테스트에서 관측된 실제 예약 확정 처리량이 분당 2건 수준이었고, Capacity Advisor가 안전계수와 내림 처리를 적용했기 때문에 1명/분으로 계산됐다.

### 9.5 최종 판단

이번 검증의 결론:

- Capacity Advisor는 실제 부하테스트 이벤트를 기준으로 `HIGH` 신뢰도 추천값을 생성했다.
- Kafka -> S3 -> Athena -> Capacity Advisor 분석 경로는 부하테스트 표본 기준으로 정상 동작했다.
- SQS worker backlog와 DLQ는 발생하지 않았다.
- Valkey CPU, memory, eviction, replication lag는 안정적이었다.
- RDS connection은 최대 28/60으로 여유가 있었고, RDS Proxy를 즉시 도입해야 할 connection storm은 확인되지 않았다.
- ticket reserve/confirm p95가 130ms 안팎으로 유지되어 예매 write 경로의 DB 병목은 확인되지 않았다.
- Read Replica 도입 여부는 아직 조회 API 중심 부하테스트 결과가 더 필요하다.
- 추천값 1명/분은 안정성 관점에서는 보수적이지만, 실제 운영 정책으로 바로 쓰기에는 너무 낮을 수 있으므로 floor/감소율 guardrail 고도화가 필요하다.

발표용 핵심 메시지:

```text
구현에서 끝내지 않고 실제 부하테스트 이벤트를 Kafka/S3/Athena에 적재해 Capacity Advisor 추천값을 재검증했다.
이번 부하에서는 DB/RDS 병목이나 SQS backlog가 아니라 waiting-room admission control이 먼저 입장을 제한했다.
따라서 RDS Proxy는 즉시 도입이 아니라 connection storm이 확인될 때 도입하고,
Read Replica는 조회 API 부하 검증 후 판단하는 것이 합리적이다.
```

## 10. 결과 기록 템플릿

부하테스트가 끝나면 아래 형식으로 결과를 남긴다.

```text
Scenario:
Date:
Executor:
S3 Result URI:

Test Config:
- script:
- VU:
- duration:
- gameId:
- userIdBase:
- seatIdBase:

k6 Result:
- total requests:
- http failure rate:
- checks success rate:
- avg:
- p95:
- p99:

Kafka Result:
- ticket.domain.events count:
- waiting.operational.events count:
- duplicate events:
- malformed events:

S3/Athena Result:
- S3 prefix:
- queried rows:
- waiting_entered:
- access_tokens_issued:
- reservation_requested:
- reservation_confirmed:

Capacity Advisor Result:
- status:
- confidence:
- stable_confirmed_per_minute:
- average_waiting_seconds:
- recommendedPolicyEnterPerMinute:
- reason:

Infra Metrics:
- RDS max DatabaseConnections:
- RDS max CPU:
- SQS max visible messages:
- SQS max oldest message age:
- DLQ increase:
- Valkey CPU/CurrConnections:
- EKS scale-out:
- ALB 5xx:

Judgement:
- 정상 동작:
- 병목 후보:
- 추가 고도화:
- 발표에 사용할 핵심 메시지:
```

## 11. 부하테스트 결과별 후속 판단

### 11.1 정상 동작

```text
k6 threshold 통과
Kafka/S3/Athena/Advisor 결과 일치
RDS/SQS/Valkey 지표 안정
5xx 지속 증가 없음
```

후속 작업:

- 결과 문서화
- 발표 캡처 정리
- RDS Proxy/Read Replica는 조건부 도입으로 정리

### 11.2 RDS connection 병목

```text
DatabaseConnections 급증
HikariPool timeout
RDS CPU는 낮거나 보통
```

후속 작업:

- Hikari pool/KEDA max replica 재검토
- RDS Proxy 도입 타당성 문서화
- connection diagnostic script 검토

### 11.3 읽기 병목

```text
조회 API p95 증가
ReadIOPS/CPU 상승
write 경로보다 read 경로가 병목
```

후속 작업:

- Read Replica 설계 문서화
- reader datasource 분리 대상 API 선정
- replica lag 허용 범위 정의

### 11.4 SQS worker 병목

```text
Visible messages 지속 증가
Oldest message age 증가
DLQ 증가
```

후속 작업:

- worker replica/KEDA 기준 조정
- Visibility Timeout 재검토
- batch 처리량과 재시도 정책 점검

### 11.5 Capacity Advisor 추천값 과도하게 낮음

```text
recommendedPolicyEnterPerMinute가 1명/분처럼 지나치게 낮음
하지만 RDS/SQS/서비스 지표는 여유 있음
```

후속 작업:

- minimum floor 정책 추가
- 표본 수와 duration 확대
- 성공 처리량 산식 재검토
- 직전 정책 대비 최대 감소율 적용

## 12. 이번 문서화 작업의 의미

이 작업은 부하테스트 결과를 단순한 k6 숫자로 남기지 않고, RDS/SQS/Valkey/Kafka/Capacity Advisor 관점에서 운영 판단까지 연결하기 위한 문서화 작업이다.

기대 효과:

- 부하테스트 결과가 단순 숫자로 흩어지지 않는다.
- RDS Proxy, Read Replica, worker scale-out 같은 후속 작업을 감이 아니라 지표로 판단할 수 있다.
- Capacity Advisor 추천값이 왜 그런지 설명할 수 있다.
- 발표에서 구현했다가 아니라 검증했고 병목 판단 기준을 세웠다는 메시지를 만들 수 있다.

## 13. 다음 고도화 후보

1. Capacity Advisor 최소 운영 floor와 최대 감소율 guardrail
   - 현재 추천값은 관측 처리량에 안전계수와 `floor()`를 적용해 매우 보수적으로 내려갈 수 있다.
   - 운영 정책으로 바로 쓰려면 예매 오픈 규모, 목표 대기시간, 최소 입장 보장값을 반영해야 한다.

2. 조회 API 중심 Read Replica 판단 부하테스트
   - `GET /api/games`, 좌석 조회, 예매 가능 좌석 조회처럼 read-heavy API p95와 RDS CPU/ReadIOPS를 별도로 확인한다.
   - 실제 조회 병목이 확인될 때 read replica 또는 cache 우선 전략을 선택한다.

3. RDS Proxy 도입 판단 부하테스트
   - connection storm, Hikari timeout, RDS `DatabaseConnections` budget 초과가 재현될 때 도입한다.
   - 이번 Capacity Advisor 부하테스트에서는 최대 28/60으로 즉시 도입 근거는 확인되지 않았다.

4. waiting-room k6 check 기준 보정
   - 대기열이 의도적으로 입장을 제한하는 상황을 무조건 실패로 보지 않도록 check 기준을 분리한다.
   - 예: “토큰 발급 성공률”과 “입장 제한 정상 동작”을 별도 지표로 기록한다.

## 14. 관련 문서

- `docs/data-async-status-roadmap.md`
- `docs/project-continuity-handoff.md`
- `docs/db-connection-pool-strategy.md`
- `docs/kafka-event-streaming-platform-design.md`
- `docs/kafka-capacity-advisor-e2e-verification.md`
- `docs/ticket-reliability-event-outbox-design.md`
- `docs/ops-alarm-runbook.md`
- `../capacity-reports/game-1-capacity.md`
- `../../ansible/docs/capacity-advisor-loadtest-verification.md`
