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

## 9. 결과 기록 템플릿

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

## 10. 부하테스트 결과별 후속 판단

### 10.1 정상 동작

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

### 10.2 RDS connection 병목

```text
DatabaseConnections 급증
HikariPool timeout
RDS CPU는 낮거나 보통
```

후속 작업:

- Hikari pool/KEDA max replica 재검토
- RDS Proxy 도입 타당성 문서화
- connection diagnostic script 검토

### 10.3 읽기 병목

```text
조회 API p95 증가
ReadIOPS/CPU 상승
write 경로보다 read 경로가 병목
```

후속 작업:

- Read Replica 설계 문서화
- reader datasource 분리 대상 API 선정
- replica lag 허용 범위 정의

### 10.4 SQS worker 병목

```text
Visible messages 지속 증가
Oldest message age 증가
DLQ 증가
```

후속 작업:

- worker replica/KEDA 기준 조정
- Visibility Timeout 재검토
- batch 처리량과 재시도 정책 점검

### 10.5 Capacity Advisor 추천값 과도하게 낮음

```text
recommendedPolicyEnterPerMinute가 1명/분처럼 지나치게 낮음
하지만 RDS/SQS/서비스 지표는 여유 있음
```

후속 작업:

- minimum floor 정책 추가
- 표본 수와 duration 확대
- 성공 처리량 산식 재검토
- 직전 정책 대비 최대 감소율 적용

## 11. 이번 문서화 작업의 의미

이 작업은 부하테스트를 당장 실행하지 못하는 상황에서도, 테스트가 가능해졌을 때 결과를 바로 해석할 수 있도록 기준을 먼저 세우는 작업이다.

기대 효과:

- 부하테스트 결과가 단순 숫자로 흩어지지 않는다.
- RDS Proxy, Read Replica, worker scale-out 같은 후속 작업을 감이 아니라 지표로 판단할 수 있다.
- Capacity Advisor 추천값이 왜 그런지 설명할 수 있다.
- 발표에서 구현했다가 아니라 검증했고 병목 판단 기준을 세웠다는 메시지를 만들 수 있다.

## 12. 관련 문서

- `docs/data-async-status-roadmap.md`
- `docs/project-continuity-handoff.md`
- `docs/db-connection-pool-strategy.md`
- `docs/kafka-event-streaming-platform-design.md`
- `docs/kafka-capacity-advisor-e2e-verification.md`
- `docs/ticket-reliability-event-outbox-design.md`
- `docs/ops-alarm-runbook.md`
- `../capacity-reports/game-1-capacity.md`
- `../../ansible/docs/capacity-advisor-loadtest-verification.md`
