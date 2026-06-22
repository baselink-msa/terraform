# Ticket Reliability Event Pipeline 및 Transactional Outbox 설계

## 1. 목적

이 문서는 개인 프로젝트 `Ticket Reliability Data Platform & Capacity Advisor`의 MVP 설계와 구현·검증 결과를 정의합니다.

목표:

- 예약 transaction과 이벤트 기록을 원자적으로 저장합니다.
- 메시지가 중복 전달되어도 결과가 중복되지 않게 합니다.
- 대기열 이벤트가 RDS 보호 기능을 약화시키지 않게 합니다.
- 이벤트를 S3에 분석 가능한 형태로 적재합니다.
- Athena의 과거 처리량으로 정책 추천값을 계산하고 현재 DB 압력은 별도 운영 참고값으로 제공합니다.
- AI는 계산을 대신하지 않고 결과의 근거를 설명합니다.

범위에서 제외:

- 별도 Grafana 대시보드
- 범용 인프라 모니터링
- AI의 무승인 인프라 변경
- 복잡한 미래 트래픽 ML 예측

## 1.1 현재 상태 요약

2026년 6월 22일 기준 MVP의 핵심 구현과 E2E 검증을 완료했습니다.

```text
예약 transaction + Outbox
→ Publisher
→ SQS/DLQ
→ Event Writer Lambda
→ S3 partition
→ Glue/Athena
→ Capacity Advisor
→ JSON/Markdown 근거 보고서
```

한 문장 요약:

> 예매와 대기열 이벤트를 유실과 중복에 안전하게 수집하고 실제 처리량을 분석해, 운영자가 검토할 수 있는 안전 입장량과 근거를 제공하는 프로젝트입니다.

남은 핵심 작업:

- 합성 데이터가 아닌 실제 부하 테스트 이벤트로 Advisor 재계산
- 안정·경고·STOP 시나리오 결과 캡처
- 발표 데모와 예상 질문 자료 정리
- 시간이 남으면 승인형 DLQ redrive 또는 Bedrock 자연어 요약

## 2. 개선 전 문제

개선 전 예약 생성 흐름:

```text
예약 PENDING 저장 및 commit
→ 애플리케이션이 SQS send
→ send 실패 시 log만 기록
```

이 구조에는 다음 실패 구간이 있습니다.

```text
DB commit 성공
→ 프로세스 종료 또는 SQS 장애
→ 메시지 미발행
→ 예약은 존재하지만 worker가 이벤트를 받지 못함
```

기존 idempotency key는 중복 예약을 줄이지만 DB commit과 메시지 발행 사이의 원자성은 보장하지 못했습니다.

Transactional Outbox는 예약과 발행할 이벤트를 같은 DB transaction에 저장하여 이 구간을 제거합니다.

## 3. 설계 원칙

1. 예약의 진실 데이터는 RDS입니다.
2. 예약 상태 변경과 Outbox 기록은 같은 transaction에서 commit합니다.
3. Publisher는 at-least-once 전달을 사용합니다.
4. 중복은 `eventId`를 기준으로 consumer에서 무해하게 처리합니다.
5. 대기열 진입 경로에는 Outbox를 위한 RDS 쓰기를 추가하지 않습니다.
6. 개인정보 원문은 분석 이벤트에 저장하지 않습니다.
7. 입장량 추천은 규칙과 수식으로 계산합니다.
8. Bedrock은 계산 결과의 자연어 설명만 담당합니다.

## 4. 이벤트 신뢰성 등급

이벤트 성격에 따라 두 경로를 사용합니다.

### 4.1 Tier A: Transactional Domain Event

대상:

- `RESERVATION_REQUESTED`
- `RESERVATION_CONFIRMED`
- `RESERVATION_CANCELED`
- 향후 `RESERVATION_FAILED`

보장:

- 예약 상태와 Outbox event가 함께 commit
- Publisher 재시도
- at-least-once 전달
- `eventId` 기반 중복 제거

### 4.2 Tier B: Operational Flow Event

대상:

- `WAITING_ENTERED`
- `ACCESS_TOKEN_ISSUED`

대기열 API마다 RDS에 event를 저장하면 RDS connection과 write 부하가 증가해 admission control의 목적과 충돌합니다.

따라서 전용 SQS queue에 비동기로 발행합니다.

보장:

- 애플리케이션의 짧은 bounded retry
- SQS at-least-once 전달
- `eventId` 기반 중복 제거
- 발행 실패가 대기열 입장이나 token 발급을 중단시키지 않음

제약:

- 프로세스가 발행 전에 종료되면 일부 이벤트가 누락될 수 있음
- 분석 보고서에 이벤트 수집률과 누락 가능성을 명시

MVP 이후 더 강한 보장이 필요하면 Redis Stream relay 또는 별도 ingestion buffer를 검토합니다.

## 5. 공통 Event Envelope

모든 이벤트는 같은 envelope을 사용합니다.

```json
{
  "eventId": "019f1234-7abc-7000-9000-123456789abc",
  "eventType": "RESERVATION_REQUESTED",
  "schemaVersion": 1,
  "occurredAt": "2026-06-19T09:15:23.421Z",
  "producer": "ticket-service",
  "aggregateType": "RESERVATION",
  "aggregateId": "381",
  "gameId": 1,
  "userKey": "sha256:...",
  "traceId": "7ca4...",
  "payload": {
    "reservationId": 381,
    "seatId": 12,
    "status": "PENDING"
  }
}
```

필드:

| 필드 | 필수 | 설명 |
| --- | --- | --- |
| `eventId` | 예 | 전역 유일 ID, 중복 제거 기준 |
| `eventType` | 예 | 이벤트 이름 |
| `schemaVersion` | 예 | payload 호환성 버전 |
| `occurredAt` | 예 | UTC 이벤트 발생 시각 |
| `producer` | 예 | 생성 서비스 |
| `aggregateType` | 예 | `RESERVATION`, `WAITING_SESSION` |
| `aggregateId` | 예 | aggregate 식별자 |
| `gameId` | 예 | 경기별 partition/분석 기준 |
| `userKey` | 아니오 | salt를 사용한 비가역 사용자 식별자 |
| `traceId` | 아니오 | 요청 추적 ID |
| `payload` | 예 | 이벤트별 데이터 |

규칙:

- 이메일, 이름, token, lock ID 원문은 저장하지 않습니다.
- timestamp는 UTC ISO-8601을 사용합니다.
- 기존 필드는 삭제하거나 의미를 변경하지 않습니다.
- breaking change가 필요하면 `schemaVersion`을 증가시킵니다.

## 6. MVP 이벤트 정의

### 6.1 `WAITING_ENTERED`

발생 시점:

- 사용자가 대기열 ZSET에 등록된 후

payload:

```json
{
  "initialRank": 42,
  "policyMaxEnterPerMinute": 100
}
```

### 6.2 `ACCESS_TOKEN_ISSUED`

발생 시점:

- Redis Lua script가 token 발급과 분당 counter 증가에 성공한 후

payload:

```json
{
  "waitingSeconds": 87,
  "effectiveEnterPerMinute": 30,
  "dbPressureLevel": "CAUTION",
  "dbThrottlePercent": 75
}
```

token ID 원문은 저장하지 않습니다.

### 6.3 `RESERVATION_REQUESTED`

발생 시점:

- 예약 `PENDING` 저장 transaction 내부

payload:

```json
{
  "reservationId": 381,
  "seatId": 12,
  "status": "PENDING"
}
```

### 6.4 `RESERVATION_CONFIRMED`

발생 시점:

- 예약 상태와 game seat 상태를 확정하는 transaction 내부

payload:

```json
{
  "reservationId": 381,
  "seatId": 12,
  "status": "CONFIRMED",
  "pendingDurationSeconds": 14
}
```

## 7. Outbox Table

Flyway `V5__create_ticket_event_outbox.sql`로 생성합니다.

```sql
CREATE TABLE ticket_schema.event_outbox (
    outbox_id BIGSERIAL PRIMARY KEY,
    event_id UUID NOT NULL,
    event_type VARCHAR(80) NOT NULL,
    schema_version INTEGER NOT NULL,
    aggregate_type VARCHAR(80) NOT NULL,
    aggregate_id VARCHAR(120) NOT NULL,
    game_id BIGINT,
    payload JSONB NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    locked_at TIMESTAMPTZ,
    locked_by VARCHAR(120),
    published_at TIMESTAMPTZ,
    last_error VARCHAR(1000),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_event_outbox_event_id UNIQUE (event_id),
    CONSTRAINT event_outbox_status_check
        CHECK (status IN ('PENDING', 'PROCESSING', 'PUBLISHED', 'FAILED'))
);

CREATE INDEX idx_event_outbox_publishable
    ON ticket_schema.event_outbox (status, next_attempt_at, outbox_id)
    WHERE status IN ('PENDING', 'FAILED');

CREATE INDEX idx_event_outbox_processing_lease
    ON ticket_schema.event_outbox (status, locked_at)
    WHERE status = 'PROCESSING';
```

보존:

- `PUBLISHED`: 7일 후 삭제
- `FAILED`: 수동 확인 전 유지
- 운영 확장 시 월별 partition 검토

## 8. Transaction 경계

### 8.1 예약 요청

```text
@Transactional
1. idempotency key로 기존 예약 확인
2. 신규 예약 PENDING 저장
3. RESERVATION_REQUESTED Outbox 저장
4. commit
```

기존 예약이 있으면 새 Outbox event를 만들지 않고 기존 예약을 반환합니다.

현재 `requestReservation()`이 같은 bean의 `saveReservationInTransaction()`을 호출하는 구조는 Spring proxy self-invocation 때문에 메서드 단위 transaction 경계가 의도대로 적용되지 않을 수 있습니다.

MVP 구현에서는 다음 중 하나로 수정합니다.

- 권장: 예약 저장과 Outbox 기록을 하나의 `@Transactional requestReservation()`에 둠
- 대안: 별도 transactional component로 분리

### 8.2 예약 확정

```text
@Transactional
1. PENDING 예약 조회
2. 예약 CONFIRMED
3. game seat SOLD
4. RESERVATION_CONFIRMED Outbox 저장
5. commit
```

이미 CONFIRMED인 요청은 멱등 응답으로 처리하고 중복 event를 생성하지 않습니다.

## 9. Outbox Publisher

ticket-service replica가 여러 개이므로 한 번에 같은 row를 처리하지 않게 claim lease를 사용합니다.

### 9.1 Claim

짧은 DB transaction에서 publish할 row를 선점합니다.

```sql
WITH candidates AS (
    SELECT outbox_id
    FROM ticket_schema.event_outbox
    WHERE status IN ('PENDING', 'FAILED')
      AND next_attempt_at <= now()
    ORDER BY outbox_id
    FOR UPDATE SKIP LOCKED
    LIMIT :batch_size
)
UPDATE ticket_schema.event_outbox o
SET status = 'PROCESSING',
    locked_at = now(),
    locked_by = :instance_id,
    attempts = attempts + 1
FROM candidates c
WHERE o.outbox_id = c.outbox_id
RETURNING o.*;
```

DB transaction을 commit한 뒤 SQS에 batch publish합니다. 네트워크 호출 동안 DB lock을 유지하지 않습니다.

### 9.2 성공과 실패

성공:

```text
status=PUBLISHED
published_at=now
locked_at/locked_by=null
```

실패:

```text
status=FAILED
next_attempt_at=now + exponential backoff
last_error 저장
locked_at/locked_by=null
```

재시도:

```text
1분, 2분, 4분, 8분, 최대 15분
```

최대 10회 실패 시:

- 자동 재시도 중지
- 운영 알림용 metric 증가
- 수동 재처리 대상 표시

### 9.3 Crash 복구

SQS 전송 후 `PUBLISHED` 갱신 전에 프로세스가 종료되면 같은 event가 다시 전송될 수 있습니다.

이는 at-least-once의 정상 동작입니다. S3 writer가 `eventId` 기반 object key를 사용해 중복을 무해하게 만듭니다.

10분 이상 `PROCESSING`인 row는 lease 만료로 보고 `FAILED`로 되돌립니다.

## 10. Event Ingestion Pipeline

1주 MVP는 관리 지점을 줄이기 위해 다음 구조를 사용합니다.

```text
Reservation Outbox Publisher ─┐
                              ├→ ticket-domain-events SQS
Waiting Event Publisher ──────┘
                                      ↓
                              Event Writer Lambda
                                      ↓
                                      S3
                                      ↓
                                Glue/Athena
```

SQS:

- 원본 queue와 DLQ
- Standard queue
- SSE 활성화
- event envelope JSON 전달

Lambda:

- batch 수신
- envelope validation
- schema version 확인
- S3 `PutObject`
- 실패 item만 partial batch failure로 반환

S3 key:

```text
s3://<bucket>/ticket-events/
  event_date=2026-06-19/
  event_type=RESERVATION_CONFIRMED/
  game_id=1/
  <eventId>.json
```

같은 `eventId`는 같은 key를 사용하므로 중복 전달 시 overwrite되어 분석 결과가 중복되지 않습니다.

MVP 이후 이벤트량이 커지면 Lambda writer를 Firehose Parquet 변환으로 교체할 수 있습니다.

## 11. Athena 분석

### 11.1 경기별 유입

```sql
SELECT game_id, count(*) AS waiting_entered
FROM ticket_events
WHERE event_type = 'WAITING_ENTERED'
  AND event_date = current_date
GROUP BY game_id;
```

### 11.2 평균 대기시간

```sql
SELECT game_id,
       avg(CAST(json_extract_scalar(payload, '$.waitingSeconds') AS double))
           AS avg_waiting_seconds
FROM ticket_events
WHERE event_type = 'ACCESS_TOKEN_ISSUED'
GROUP BY game_id;
```

### 11.3 예약 전환율

```sql
WITH requested AS (
    SELECT game_id, count(*) AS request_count
    FROM ticket_events
    WHERE event_type = 'RESERVATION_REQUESTED'
    GROUP BY game_id
),
confirmed AS (
    SELECT game_id, count(*) AS confirm_count
    FROM ticket_events
    WHERE event_type = 'RESERVATION_CONFIRMED'
    GROUP BY game_id
)
SELECT r.game_id,
       r.request_count,
       coalesce(c.confirm_count, 0) AS confirm_count,
       100.0 * coalesce(c.confirm_count, 0) / nullif(r.request_count, 0)
           AS conversion_percent
FROM requested r
LEFT JOIN confirmed c ON c.game_id = r.game_id;
```

## 12. 안전 입장량 추천

AI가 수치를 임의로 생성하지 않도록 규칙 기반으로 계산합니다.

```text
관측 안정 처리량 =
최근 정상 구간의 RESERVATION_CONFIRMED / 분

DB 여유율 =
max(0, 1 - current_connections / connection_budget)

Queue 보정 =
SQS backlog가 증가하면 0.5~0.8, 안정적이면 1.0

전환 보정 =
최근 확정률 / 기준 확정률, 최대 1.0

추천 입장량 =
floor(
  관측 안정 처리량
  × 0.8 안전계수
  × DB 여유율
  × Queue 보정
  × 전환 보정
)
```

안전장치:

- 추천값은 관리자 상한을 넘지 않음
- 데이터 표본이 부족하면 추천하지 않음
- STOP 단계에서는 항상 0
- 한 번에 기존 설정의 25% 이상 증가는 권고하지 않음
- 결과에 입력 시각과 근거 수치를 포함

출력 예:

```json
{
  "gameId": 1,
  "recommendedEnterPerMinute": 28,
  "currentEnterPerMinute": 40,
  "confidence": "MEDIUM",
  "reasons": [
    "최근 정상 예약 확정 처리량 60건/분",
    "RDS connection 45/60",
    "SQS backlog 증가",
    "최근 예약 확정률 82%"
  ]
}
```

## 13. Metric

Outbox:

- `ticket_outbox_pending`
- `ticket_outbox_oldest_pending_seconds`
- `ticket_outbox_publish_total{result}`
- `ticket_outbox_retry_total`
- `ticket_outbox_failed`

Event writer:

- `ticket_event_ingested_total{event_type}`
- `ticket_event_invalid_total{reason}`
- `ticket_event_s3_write_total{result}`

Metric의 의미와 정상 범위는 Data & Async 영역에서 정의하고, Grafana/Alert Rule 구성은 모니터링 담당과 협업합니다.

## 14. 보안과 개인정보

- SQS와 S3 암호화 활성화
- S3 public access 차단
- Lambda에는 해당 queue receive와 bucket prefix write만 허용
- Athena에는 읽기 전용 role 사용
- 사용자 ID는 salt 기반 SHA-256 `userKey`로 변환
- token, lock ID, 이메일, 이름은 이벤트에 기록하지 않음
- S3 lifecycle로 dev event를 14일 후 삭제
- payload validation 실패 데이터는 별도 quarantine prefix 또는 DLQ로 격리

## 15. 테스트 계획

### 15.1 Transaction 원자성

- 예약 저장과 Outbox 저장이 함께 성공
- Outbox 저장 실패 시 예약도 rollback
- 중복 idempotency key 요청 시 예약과 event가 추가되지 않음

### 15.2 Publisher

- 다중 replica에서 같은 row를 동시에 처리하지 않음
- SQS 장애 시 retry/backoff
- SQS 성공 후 DB 갱신 전 crash를 재현해 중복 전달 확인
- 중복 전달 후 S3 object가 하나만 존재
- 오래된 `PROCESSING` lease 복구

### 15.3 Pipeline

- 4종 event schema validation
- 잘못된 schema version은 DLQ
- S3 partition과 object key 확인
- Athena 유입, 대기시간, 전환율 query 검증

### 15.4 Capacity Report

- 정상, DB 경고, SQS backlog, STOP 시나리오
- 같은 입력에 같은 추천값 생성
- 표본 부족 시 추천 보류
- AI 요약이 없어도 JSON/Markdown 보고서 생성

## 16. 구현 순서

### 1일차

- event envelope Java DTO
- Flyway Outbox migration
- Outbox entity/repository
- 예약 요청 transaction 수정

### 2일차

- 예약 확정 Outbox 기록
- Publisher claim/retry/lease
- 단위 테스트

### 3일차

- 이벤트 전용 SQS/DLQ Terraform
- Event Writer Lambda
- S3 bucket/prefix/lifecycle

### 4일차

- 대기열 2종 이벤트 발행
- Glue/Athena table
- 핵심 query

### 5일차

- 안전 입장량 계산기
- JSON/Markdown 보고서
- 실패 경로 통합 테스트

### 6~7일차

- EKS 배포
- end-to-end 검증
- 결과 캡처
- 발표 및 트러블슈팅 문서

## 17. MVP 완료 조건

- 예약과 `RESERVATION_REQUESTED` Outbox가 같은 transaction으로 저장됨
- SQS 장애 후 자동 재시도로 event가 전달됨
- 중복 전달 후 S3 event가 하나만 남음
- 4종 핵심 이벤트가 날짜·경기별로 조회됨
- Athena로 평균 대기시간과 예약 전환율 계산
- 안전 입장량 JSON 또는 Markdown 보고서 생성
- AI가 없어도 전체 핵심 기능 동작
- 구현, 실패 경로, 한계가 발표 문서에 반영됨

## 18. 발표 핵심 메시지

> 모니터링 화면을 추가하는 대신 예약 transaction과 이벤트 발행 사이의 유실 구간을 Transactional Outbox로 제거했습니다. 대기열 이벤트는 DB 보호 목적을 해치지 않도록 별도 비동기 경로로 수집하고, 모든 이벤트를 event ID 기반으로 중복에 안전하게 S3에 적재했습니다. 이를 통해 사용자 흐름과 실제 처리량을 분석하고 근거가 있는 안전 입장량을 추천할 수 있습니다.

## 19. 구현 진행 기록

### 2026-06-19: Outbox 기반 구조 1차 구현

완료:

- Flyway `V5__create_ticket_event_outbox.sql`
- 예약 idempotency key unique index
- 공통 `TicketEventEnvelope`와 schema version
- `EventOutbox` entity/repository
- 예약 요청과 `RESERVATION_REQUESTED` event의 동일 transaction 저장
- 예약 확정과 `RESERVATION_CONFIRMED` event의 동일 transaction 저장
- 전환 중 기능 공백을 막기 위해 기존 SQS 발행을 임시로 `afterCommit`에서 실행
- 중복 예약 요청 시 예약과 event를 추가 생성하지 않음
- 단위 테스트 3개 통과

이번 단계에서 얻은 결과:

- 예약 저장은 성공했지만 event 기록은 빠지는 상태를 transaction rollback으로 막을 수 있습니다.
- 동일 예약 재시도에서 분석 이벤트가 중복 생성되는 것을 막습니다.
- SQS worker가 commit되지 않은 예약을 먼저 읽는 race condition을 줄였습니다.
- Publisher 구현 전까지 기존 SQS 흐름을 유지해 단계적으로 전환할 기반을 마련했습니다.

아직 남은 내용:

- Outbox Publisher claim/retry/lease
- 실제 PostgreSQL Flyway migration 검증
- Flyway 실행과 ticket-service rollout 순서 보장
- SQS 장애와 process crash 통합 테스트

배포 주의:

현재 Flyway migration은 `auth-service` 시작 시 실행됩니다. `event_outbox` entity를 포함한 `ticket-service`가 migration보다 먼저 시작하면 Hibernate validation이 일시적으로 실패할 수 있습니다. 실제 배포 전 migration 선행 Job 또는 Argo CD sync wave 등으로 순서를 보장해야 합니다.

### 2026-06-21: Outbox Publisher와 이벤트 큐 구현

완료:

- PostgreSQL `FOR UPDATE SKIP LOCKED` 기반 batch claim
- Outbox 목적지 기반 queue routing
  - `TICKET_CONFIRM` → `ticket-confirm-queue`
  - `DOMAIN_EVENTS` → `ticket-domain-events`
- 기존 DB commit 이후 직접 SQS 발행 제거
- `PENDING/FAILED → PROCESSING → PUBLISHED` 상태 전이
- SQS 실패 시 지수 backoff 재시도
- 최대 10회 시도 후 terminal failure 분리
- 10분 이상 멈춘 `PROCESSING` lease 복구
- 발행 polling 2초, lease 복구 60초로 DB 부하 분리
- Outbox pending, oldest pending, terminal failure metric
- 전용 `ticket-domain-events` SQS
- 전용 DLQ와 redrive allow policy
- Source backlog와 DLQ CloudWatch Alarm
- SQS managed SSE 명시 활성화
- `backend-runtime` IRSA에 이벤트 발행 최소 권한 추가
- Publisher 성공·실패·lease 복구 단위 테스트 통과
- Terraform validate와 변경 범위 plan 확인

이번 단계에서 얻은 결과:

- 여러 ticket-service Pod가 동시에 실행돼도 같은 event row를 함께 선점하지 않습니다.
- 예약과 worker 명령, 분석 event가 같은 transaction에서 Outbox로 기록됩니다.
- SQS 장애가 발생해도 event가 DB에 남아 자동 재시도됩니다.
- SQS 전송 직후 Pod가 종료돼 중복 전달되더라도 이후 `eventId` 기반 consumer 멱등성으로 처리할 수 있습니다.
- 장시간 멈춘 Pod가 남긴 `PROCESSING` event를 자동 복구합니다.
- 애플리케이션 Pod에는 이벤트 queue 발행 권한만 부여하고 node role 권한은 확대하지 않았습니다.

검증 결과:

- Outbox 관련 단위 테스트 6개 통과
- Terraform configuration valid
- Target plan 기준 새 리소스:
  - 이벤트 source queue
  - 이벤트 DLQ
  - redrive allow policy
  - source backlog alarm
  - DLQ alarm
- Docker Desktop 미실행과 클러스터 API timeout으로 PostgreSQL migration 및 실제 EKS 통합 테스트는 아직 수행하지 못했습니다.

안전한 적용 순서:

1. Terraform PR로 이벤트 SQS/DLQ/IAM 적용
2. Flyway V5만 포함한 Backend migration PR 배포
3. `event_outbox` table, destination constraint, idempotency index 확인
4. Publisher 코드만 포함한 ticket-service PR 배포
5. 테스트 예약 생성
6. `TICKET_CONFIRM`, `DOMAIN_EVENTS` Outbox가 각각 `PUBLISHED`인지 확인
7. 두 SQS queue의 message 확인
8. SQS 장애 또는 권한 차단 상황에서 retry 확인

Flyway migration과 ticket-service 코드를 같은 PR로 merge하면 auth-service와 ticket-service CI가 병렬 실행될 수 있습니다. 이 경우 ticket-service가 `event_outbox` table 생성 전에 시작해 Hibernate validation에 실패할 수 있으므로 migration과 애플리케이션 PR을 분리합니다.

주의:

Target plan에는 IAM role의 EKS/OIDC dependency로 인해 별도의 EKS CIDR와 OIDC thumbprint 변경도 함께 표시됐습니다. 이벤트 인프라 적용 시 `-target`을 그대로 apply하지 않고 최신 main 기준 전체 plan을 팀과 검토해야 합니다.

### 2026-06-22: Event Writer와 S3 적재 검증

완료:

- `ticket-domain-events` SQS를 구독하는 Event Writer Lambda
- event envelope 필수 필드, schema version, event type 검증
- 실패한 SQS record만 재시도하는 partial batch failure
- S3 날짜·이벤트 종류·경기별 partition 적재
- `eventId` 기반 고정 object key로 중복 전달 멱등 처리
- S3 public access 차단, SSE-S3, TLS 강제, versioning
- dev 이벤트 14일 lifecycle
- 이벤트 큐 visibility timeout 180초 적용
- Lambda 최소 권한 IAM과 CloudWatch Logs
- Event Writer 단위 테스트 3개 통과
- 실제 SQS 이벤트를 전송해 다음 S3 object 생성 확인

```text
ticket-events/
  event_date=2026-06-22/
  event_type=RESERVATION_CONFIRMED/
  game_id=1/
  f1779bf2-7d36-43e2-8f21-059063780f99.json
```

검증 과정에서 확인한 문제:

- PowerShell에서 AWS CLI 인자로 JSON을 직접 전달했을 때 내부 따옴표가 제거되어 잘못된 JSON이 전송됐습니다.
- Lambda log에서 `JSONDecodeError`를 확인해 인프라 권한이나 S3 문제가 아닌 입력 직렬화 문제로 구분했습니다.
- 인자 배열을 보존하는 방식으로 다시 전송한 정상 이벤트는 SQS → Lambda → S3 경로를 통과했습니다.

다음 단계:

- Glue Data Catalog database와 external table
- 날짜·이벤트 종류 partition projection
- Athena 전용 workgroup과 암호화된 query result
- 일별 이벤트 수, 평균 대기 시간, 예약 전환율 named query
- 실제 Athena query 실행과 결과 검증

### 2026-06-22: Athena 분석 검증과 Capacity Advisor 구현

Athena 검증:

- `ticket-events-daily-volume` 실행 성공
- `ticket-events-average-waiting-time` 실행 성공
- `ticket-events-reservation-conversion` 실행 성공
- 실제 S3 이벤트를 `game_id=1`, `RESERVATION_CONFIRMED=1`로 조회
- Partition Projection을 사용하므로 일별 partition 수동 등록 불필요

Capacity Advisor:

- Athena에서 최근 기간의 대기열 진입, 토큰 발급, 예약 요청·확정 수집
- 예약 확정 분당 안정 처리량 중앙값 계산
- 예약 전환율, 안전계수, 평균 대기 시간 보정
- 현재 정책 대비 한 번에 25%를 넘는 증가는 제한
- 최소 표본 미달 시 `INSUFFICIENT_DATA`로 추천 보류
- JSON과 Markdown 보고서 생성
- AI 없이 동일 입력에 동일 결과를 내는 규칙 기반 계산

기존 자동 감속과의 역할 분리:

```text
Capacity Advisor
  과거 정상 구간 데이터 → recommendedPolicyEnterPerMinute

Waiting Room Admission Control
  현재 RDS 압력 → effectiveEnterPerMinuteNow
```

Advisor는 현재 DB 여유율을 장기 정책값에 중복 적용하지 않습니다. DB 압력은 현재 운영 참고값과 경고 근거로만 사용하며, 실제 서비스의 자동 감속이 최종 입장량을 제어합니다.

실제 첫 실행 결과:

```text
current DB connections = 20 / 60
db pressure = NORMAL
reservation confirmed samples = 1
waiting/access/request samples = 0
result = INSUFFICIENT_DATA
```

표본이 부족한 상태에서 임의의 추천값을 생성하지 않고 기존 정책 유지를 권고하는 것을 확인했습니다.

### 2026-06-22: 대기열 이벤트 E2E와 합성 표본 검증

실제 API E2E:

1. `POST /api/waiting-room/games/1/enter`
2. 최초 순번 `1` 확인
3. `POST /api/waiting-room/games/1/issue-token`
4. 토큰 발급 성공
5. 토큰 반납
6. `WAITING_ENTERED`, `ACCESS_TOKEN_ISSUED` S3 적재 확인
7. Athena에서 평균 대기시간 `4초` 조회

합성 표본:

```text
producer = capacity-load-test
WAITING_ENTERED = 40
ACCESS_TOKEN_ISSUED = 40
RESERVATION_REQUESTED = 40
RESERVATION_CONFIRMED = 32
conversion = 80%
```

합성 표본은 실제 운영 이벤트와 섞이지 않도록 producer filter로 분리합니다.

Capacity Advisor 검증 결과:

```text
stable confirmed throughput = 4건/분
average waiting = 55.7초
average observed admission = 31.9명/분
current DB connections = 19/60
DB pressure = NORMAL
recommended policy = 4명/분
confidence = MEDIUM
```

추천값이 4명/분인 이유는 합성 시나리오가 예약 확정을 분당 4건으로 분산해 생성했기 때문입니다. 이는 계산기가 단순히 총 표본 수만 보는 것이 아니라 시간당 안정 처리량을 반영한다는 것을 검증합니다.

주의:

- 합성 데이터는 파이프라인과 계산 공식 검증용입니다.
- 합성 데이터로 계산한 추천값을 실제 운영 정책의 근거로 사용하지 않습니다.
- 실제 정책값은 부하 테스트 또는 실제 운영 이벤트만 필터링해 다시 계산해야 합니다.
- `capacity-load-test` producer 데이터는 발표에서 시뮬레이션 결과로 명확히 표시합니다.
