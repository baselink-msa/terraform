# Kafka Event Streaming Platform 설계

## 1. 목적

기존 개인 프로젝트는 사용자가 대기열에 들어오고, 입장권을 받고, 예매를 요청하고, 예매를 확정하는 전 과정을 이벤트로 기록한 뒤 실제 처리량을 계산해 안전한 입장 인원을 추천하는 구조입니다.

Kafka 도입의 목적은 이 흐름을 “티켓 도메인 분석 기능”에서 “서비스 전체 이벤트 스트리밍 인프라”로 확장하는 것입니다.

한 문장으로 요약하면 다음과 같습니다.

> Kafka 기반 이벤트 스트리밍 플랫폼을 추가해 대기열·예매·인프라 이벤트를 공통 로그로 수집하고, 처리량 분석과 안전 입장량 추천, 장애 추적의 기반을 만든다.

## 2. SQS와 Kafka의 역할 분리

Kafka는 기존 SQS를 대체하지 않습니다.

| 영역 | 사용 기술 | 역할 |
|---|---|---|
| 예매 확정 명령 처리 | SQS + ticket-worker | 반드시 처리해야 하는 작업 큐 |
| 예매 transaction과 이벤트 원자성 | RDS Transactional Outbox | 예약 상태와 이벤트 기록을 같은 transaction으로 보장 |
| 서비스 전체 이벤트 로그 | Kafka | 여러 consumer가 같은 이벤트를 시간순으로 재사용 |
| 장기 분석 저장소 | S3 + Athena | 비용 효율적인 분석과 보고서 생성 |
| 안전 입장량 추천 | Capacity Advisor | 실제 처리량과 DB 여유율 기반 추천 |

발표 메시지:

```text
SQS는 해야 할 작업을 안정적으로 처리하는 큐이고,
Kafka는 일어난 일을 여러 관점에서 재사용하는 이벤트 로그입니다.
```

따라서 첫 단계에서는 예매 핵심 경로를 Kafka로 옮기지 않습니다. 기존 예매 처리 안정성은 유지하고, Kafka는 분석·관측·용량 판단 경로에 붙입니다.

## 3. 목표 아키텍처

```text
waiting-room-service
ticket-service outbox publisher
future infra event producers
        |
        v
Kafka topics
        |
        +--> S3 sink consumer
        |       -> S3 partitioned JSON
        |       -> Glue/Athena
        |       -> Capacity Advisor
        |
        +--> realtime capacity consumer
        |       -> 최근 1분/5분 처리량 집계
        |       -> 안전 입장량 추천
        |
        +--> alert/audit consumer
                -> 실패 이벤트, 지연, 병목 탐지
```

## 4. AWS 구현 선택

1단계 IaC는 Amazon MSK Serverless를 기준으로 준비합니다.

선택 이유:

- 브로커 용량과 파티션 운영 부담을 줄일 수 있습니다.
- 서울 리전에서 사용할 수 있습니다.
- IAM 인증/인가를 사용할 수 있어 기존 IRSA 흐름과 잘 맞습니다.
- Apache Kafka 호환 클라이언트를 사용할 수 있습니다.
- AWS Glue Schema Registry, AWS Lambda, AWS PrivateLink와 연결 가능한 관리형 Kafka 기반입니다.

주의사항:

- MSK Serverless는 비용이 발생하므로 dev 기본값은 비활성화합니다.
- MSK Serverless는 IAM access control을 사용합니다.
- IAM broker 접근은 AWS 내부 port `9098`을 사용합니다.
- 첫 구현에서는 예매 확정 처리 경로를 Kafka로 옮기지 않습니다.

공식 참고:

- AWS MSK Serverless: https://docs.aws.amazon.com/msk/latest/developerguide/serverless.html
- AWS MSK port: https://docs.aws.amazon.com/msk/latest/developerguide/port-info.html
- AWS MSK IAM access control: https://docs.aws.amazon.com/msk/latest/developerguide/iam-access-control.html

## 5. Topic 설계

| Topic | Producer | Consumer | 목적 |
|---|---|---|---|
| `ticket.domain.events` | ticket-service outbox publisher | S3 sink, Capacity Advisor | 예매 요청/확정/취소 |
| `waiting.operational.events` | waiting-room-service | S3 sink, Capacity Advisor | 대기열 진입, 입장권 발급 |
| `reservation.lifecycle.events` | ticket-service/ticket-worker | 실시간 집계 | 예매 처리 상태 흐름 |
| `capacity.signals` | waiting-room-service/advisor | 대시보드/알림 | DB 감속, 안전 입장량 추천 |
| `infra.audit.events` | 운영 이벤트 producer | 감사/장애 분석 | 배포, 알림, DLQ, 복구 이벤트 |

Partition key:

- 기본: `gameId`
- `gameId`가 없으면 `aggregateId`
- 운영 이벤트는 `eventType` 또는 `resourceId`

이렇게 하면 특정 경기의 대기열과 예매 흐름을 시간순으로 분석하기 쉽습니다.

## 5.1 현재 실제 수집/활용 중인 이벤트

2026-06-29 기준으로 실제 구현·검증된 이벤트 활용 범위는 다음과 같습니다.

| Topic | Event type | 현재 활용 |
| --- | --- | --- |
| `ticket.domain.events` | `RESERVATION_REQUESTED`, `RESERVATION_CONFIRMED` | 예매 요청/확정 처리량 분석, Capacity Advisor 표본 |
| `waiting.operational.events` | `WAITING_ENTERED`, `ACCESS_TOKEN_ISSUED` | 대기열 유입량, 입장권 발급량, 평균 대기시간 분석 |
| `reservation.lifecycle.events` | `SEAT_LOCK_REQUESTED`, `SEAT_LOCKED`, `SEAT_LOCK_FAILED`, `SEAT_UNLOCKED` | 좌석 잠금 성공/실패/해제 흐름 분석, Valkey 상태와 상관관계 분석 |
| `capacity.signals` | `ADMISSION_THROTTLE_APPLIED`, `ADMISSION_STOP_APPLIED`, `ADMISSION_THROTTLE_RECOVERED` | RDS connection 압력에 따른 감속/중지/복구 이력 분석 |

현재 Capacity Advisor 리포트는 아래 내용을 함께 본다.

- 대기열 진입 수
- 입장권 발급 수
- 예매 요청 수
- 예매 확정 수
- 안정적인 분당 확정 처리량
- 평균 대기 시간
- 평균 effective 입장량
- 현재 RDS `DatabaseConnections`
- 최근 Kafka `capacity.signals` 감속/복구 신호
- SQS/Worker backlog, DLQ 상태
- Valkey engine CPU, memory, eviction, replication lag 상태
- Kafka pipeline health

즉, 현재 구현은 단순히 “Kafka topic을 만들었다”가 아니라 다음 흐름까지 이어져 있다.

```text
Backend event
-> Kafka topic
-> Kafka S3 sink runner
-> S3 partitioned JSON
-> Glue/Athena ticket_events
-> Capacity Advisor JSON/Markdown report
-> Slack report workflow
```

## 6. Event Envelope

기존 개인 프로젝트의 공통 envelope를 유지합니다.

```json
{
  "eventId": "019f1234-7abc-7000-9000-123456789abc",
  "eventType": "RESERVATION_REQUESTED",
  "schemaVersion": 1,
  "occurredAt": "2026-06-24T09:15:23.421Z",
  "producer": "ticket-service",
  "aggregateType": "RESERVATION",
  "aggregateId": "381",
  "gameId": 1,
  "userKey": "sha256:...",
  "traceId": "7ca4...",
  "payload": {}
}
```

규칙:

- 개인정보 원문은 저장하지 않습니다.
- token, seat lock id 같은 민감 운영 식별자는 저장하지 않습니다.
- breaking change는 `schemaVersion`을 올립니다.
- consumer는 `eventId`로 idempotency를 보장합니다.

## 7. 단계별 구현 계획

### Phase 0: 설계와 비활성 IaC 뼈대

현재 PR 범위입니다.

- Kafka 도입 설계 문서 작성
- optional MSK Serverless Terraform module 추가
- dev infra에 `enable_kafka_event_streaming = false` 기본값 추가
- backend runtime IRSA Kafka 권한 구조 준비
- PR 병합만으로 Kafka 리소스가 생성되지 않도록 보호

완료 조건:

- `terraform validate` 통과
- `enable_kafka_event_streaming=false` plan에서 MSK 리소스 생성 없음

### Phase 1: MSK Serverless 생성

- `enable_kafka_event_streaming=true`
- MSK Serverless cluster 생성
- EKS cluster security group에서 MSK IAM broker port `9098` 접근 허용
- bootstrap broker output 확인
- bootstrap broker와 topic 목록을 Secrets Manager runtime config로 저장

완료 조건:

- AWS 콘솔에서 MSK cluster 확인
- Terraform output으로 IAM bootstrap broker 확인
- Secrets Manager에서 `baselink-dev/kafka/event-streaming` Secret 확인
- backend runtime IRSA role이 Kafka 접근 권한과 runtime config Secret 조회 권한을 가짐
- 임시 Kafka client pod 또는 이후 Backend producer에서 topic metadata 조회

진행 상태:

- 2026-06-24 기준 MSK Serverless cluster 생성 완료
- EKS 내부 network smoke test 완료
- EKS 내부 Kafka CLI `AWS_MSK_IAM` client smoke test 완료
- 2026-06-25 기준 Kafka topic 5개 생성과 목록 조회 검증 완료
- 2026-06-25 기준 backend runtime `backend-config`에 Kafka 환경변수 주입 완료
- 2026-06-25 기준 backend Pod에서 Kafka 환경변수 확인 완료
- 2026-06-26 기준 `ticket-service` Outbox domain event dual publish 구현 및 dev 검증 완료
- 2026-06-26 기준 `waiting-room-service` 대기열 운영 이벤트 Kafka publish 구현 완료
- 2026-06-26 기준 Kafka→S3 sink runner와 Capacity Advisor E2E 검증 완료
- 2026-06-29 기준 `capacity.signals` 감속/복구 이벤트 publish와 Capacity Advisor 리포트 반영 완료
- 2026-06-29 기준 Capacity Advisor Slack report workflow 구현 완료
- 2026-06-29 기준 SQS/Worker와 Valkey/좌석 잠금 계층 상태를 Capacity Advisor 리포트와 Slack 메시지에 반영 완료
- 2026-06-29 기준 Athena event lake 기반 Kafka pipeline health를 Capacity Advisor 리포트와 Slack 메시지에 반영 완료
- 2026-06-29 기준 `seat-lock-service` 좌석 잠금 이벤트 Kafka publish와 Kafka→S3 sink 허용 event type 반영 완료
- 2026-06-29 기준 `SQS_WORKER_STATUS_RECORDED`, `KAFKA_S3_SINK_COMPLETED` audit event를 S3/Athena event lake와 Slack report에서 검증 완료
- 2026-06-29 기준 실제 k6 부하테스트 이벤트 표본으로 Capacity Advisor `HIGH` 신뢰도 재검증 완료
- 2026-06-29 기준 Capacity Advisor에 minimum policy floor와 max decrease guardrail을 추가해 1명/분 급락 문제를 20명/분 운영 추천으로 보정 완료

생성 완료 topic:

```text
ticket.domain.events
waiting.operational.events
reservation.lifecycle.events
capacity.signals
infra.audit.events
```

### Phase 2: Dual publisher

기존 SQS 경로는 유지합니다.

- Terraform addon `backend-config`에 Kafka bootstrap broker와 topic 환경변수를 주입합니다. `2026-06-25 완료`
- GitOps Deployment에 `backend-config` Reloader annotation을 추가해 ConfigMap 변경 시 Pod가 새 환경변수를 받게 합니다. `2026-06-25 완료`
- waiting-room-service 이벤트를 SQS/Lambda 분석 경로와 Kafka에 함께 적재 `2026-06-26 완료`
- ticket-service Outbox publisher도 domain event를 SQS와 Kafka에 dual publish `2026-06-26 완료`
- Kafka publish 실패는 핵심 요청을 실패시키지 않습니다.

완료 조건:

- backend Pod에서 Kafka 환경변수 확인 `완료`
- SQS 기존 이벤트 파이프라인 정상 `ticket-service Outbox 기준 완료`
- Kafka topic에도 동일 envelope 적재 `ticket.domain.events 완료`
- Kafka `waiting.operational.events`, `capacity.signals` 발행 경로 구현 `완료`
- producer 성공/실패 metric 확인 `ticket_kafka_publish_total 확인`

검증 기록:

- Terraform Apply Dev 성공
- GitOps backend Deployment에 `configmap.reloader.stakater.com/reload: "backend-config"` annotation 반영
- 전체 backend Deployment Ready 상태 확인
- `ticket-service`, `ticket-worker-service`, `waiting-room-service`에서 `KAFKA_*` 환경변수 확인
- ConfigMap 환경변수는 Pod 시작 시점에 주입되므로, 기존 Pod까지 최신 값을 받도록 backend Deployment 9개를 1회 rolling restart했다.
- `ticket-service` image `f67032bb2c2b1b9d0e282ad7a3a1b10e301edbad` 배포 후 내부 API로 예약 요청을 생성했다.
- Kafka `ticket.domain.events`에서 `reservationId=4715`, `eventType=RESERVATION_REQUESTED`, `producer=ticket-service` 이벤트를 consume해 확인했다.
- MSK IAM 트러블슈팅:
  - consumer 검증에는 topic `ReadData` 권한과 `baselink-*` group 권한이 필요했다.
  - idempotent Kafka producer에는 cluster-level `WriteDataIdempotently` 권한이 필요했다.

### Phase 3: Kafka to S3 sink

선택지는 두 가지입니다.

1. custom consumer
2. Kafka Connect S3 Sink

dev에서는 custom consumer가 단순합니다.

완료 조건:

- Kafka event가 S3 partition으로 저장
- Athena에서 기존 Capacity Advisor 쿼리 재사용 가능

진행 상태:

- dev/demo용 custom sink runner 구현 완료
- `ticket.domain.events`, `waiting.operational.events`, `capacity.signals` topic을 S3/Athena event lake로 적재 가능
- 기존 Lambda writer와 같은 event envelope, 같은 S3 partition layout을 사용
- `eventId` 기반 object key를 사용해 같은 이벤트를 재처리해도 idempotent하게 덮어씀
- sink runner는 현재 bounded dev/demo 실행 방식이며, 상시 운영 consumer나 Kafka Connect S3 Sink는 향후 선택 작업

### Phase 4: Realtime Capacity Intelligence

- 최근 1분/5분 입장권 발급량
- 예매 요청 대비 확정률
- DB 감속 발생률
- 안전 입장량 추천

완료 조건:

- load test 중 실시간 처리량과 추천값 산출
- 발표용 Markdown 리포트 생성

진행 상태:

- Athena 기반 Capacity Advisor JSON/Markdown 리포트 생성 완료
- 최근 `capacity.signals` 감속/복구 신호 섹션 추가 완료
- GitHub Actions 기반 Capacity Advisor Slack report workflow 구현 완료
- SQS/Worker 상태 섹션 추가 완료
- Valkey/좌석 잠금 계층 상태 섹션 추가 완료
- Kafka pipeline health 섹션 추가 완료
- 기본 schedule은 매일 09:00 KST
- `workflow_dispatch`로 수동 실행 가능
- `CAPACITY_ADVISOR_SLACK_WEBHOOK_URL` Secret 추가 후 실제 Slack 전송 검증 완료
- Secret이 없을 때는 dry-run payload만 출력하고 성공 처리하는 fallback 구조 유지

아직 자동화되지 않은 부분:

- 예매 오픈 30분 전 자동 실행
- 예매 진행 중 5분마다 위험 상태만 Slack 전송
- `ADMISSION_THROTTLE_APPLIED` 발생 즉시 Slack 알림
- SQS DLQ 발생 즉시 Capacity Advisor 맥락 리포트 전송

이 네 가지는 GitHub Actions schedule만으로도 일부 구현할 수 있지만, 정확한 이벤트 기반 트리거가 필요하면 EventBridge/Lambda 또는 Kafka consumer 기반으로 확장하는 것이 더 자연스럽다.

## 7.1 Capacity Advisor Slack 알림 전략

Slack 채널은 목적에 따라 분리한다.

| 채널 | 목적 | 예시 |
| --- | --- | --- |
| `aws-alerts` | 장애/위험 감지 | RDS high connection, SQS DLQ, Backup 실패, WAF 차단 |
| `capacity-reports` 또는 `ops-reports` | 운영 의사결정 리포트 | 다음 예매 오픈 전 안전 입장량 추천, 최근 감속/복구 요약 |

현재 구현:

```text
GitHub Actions schedule 또는 manual dispatch
-> Athena 기반 Capacity Advisor 실행
-> RDS DatabaseConnections 최근 값 조회
-> JSON/Markdown 리포트 생성
-> Slack webhook 전송
```

향후 추천 구조:

```text
예매 오픈 30분 전
-> 이전 이벤트 기반 Capacity Advisor 실행
-> capacity-reports로 추천 입장량 전송

예매 진행 중 5분마다
-> 최근 5분 이벤트와 RDS 상태 분석
-> 위험하면 capacity-reports 또는 aws-alerts로 전송

ADMISSION_THROTTLE_APPLIED 발생
-> 즉시 aws-alerts로 위험 알림
-> capacity-reports에는 후속 리포트 또는 요약 전송

SQS DLQ 발생
-> 즉시 aws-alerts로 장애 알림
-> 필요 시 Capacity Advisor 리포트에 backlog/DLQ 맥락 추가
```

`CAPACITY_ADVISOR_SLACK_WEBHOOK_URL` GitHub Repository Secret은 추가 완료됐고 실제 Slack 전송도 검증했다. Webhook URL이 노출되면 즉시 Slack에서 새 URL을 발급해 GitHub Secret을 교체한다.

## 7.2 Kafka 리포트 확장 후보

Capacity Advisor를 “안전 입장량 추천”에서 “예매 인프라 상태 기반 운영 리포트”로 넓히기 위해 다음 이벤트를 추가하는 것이 좋다.

### 1순위: SQS/Worker 처리 상태

권장 topic:

```text
infra.audit.events
```

2026-06-29 1차 구현 상태:

- Capacity Advisor가 AWS CLI로 `ticket-confirm-queue`와 `ticket-confirm-dlq`의 SQS attributes를 조회합니다.
- JSON/Markdown 리포트에 `sqsWorker` 섹션을 추가했습니다.
- Slack report에도 `SQS/Worker 상태` 섹션을 추가했습니다.
- `record_sqs_worker_audit.py`로 SQS 상태를 `SQS_WORKER_STATUS_RECORDED`, `SQS_BACKLOG_DETECTED`, `SQS_DLQ_DETECTED` audit event로 S3/Athena event lake에 기록할 수 있습니다.
- 2026-06-29 부하테스트 이후 `SQS_WORKER_STATUS_RECORDED`가 Slack report의 Kafka pipeline health에 표시되는 것을 확인했습니다.

권장 event type:

```text
SQS_BACKLOG_DETECTED
SQS_BACKLOG_RECOVERED
SQS_DLQ_DETECTED
WORKER_PROCESSING_DELAYED
WORKER_RECOVERED
```

리포트 활용:

- ticket-confirm queue backlog 발생 횟수
- DLQ 발생 여부
- 가장 오래 기다린 메시지 age
- worker 처리 지연 여부
- 현재 추천 입장량을 낮춰야 하는 운영 근거

### 2순위: 좌석 잠금 / Valkey 이벤트

권장 topic:

```text
reservation.lifecycle.events 또는 seat-lock.events
```

권장 event type:

```text
SEAT_LOCK_REQUESTED
SEAT_LOCKED
SEAT_LOCK_FAILED
SEAT_LOCK_EXPIRED
SEAT_UNLOCKED
```

2026-06-29 1차 구현 상태:

- Capacity Advisor가 CloudWatch `AWS/ElastiCache` metric을 조회해 Valkey 상태를 리포트에 포함합니다.
- 조회 metric은 `EngineCPUUtilization`, `DatabaseMemoryUsagePercentage`, `Evictions`, `ReplicationLag`입니다.
- JSON/Markdown 리포트에 `valkeyStatus` 섹션을 추가했습니다.
- Slack report에도 `Valkey/좌석 잠금 계층 상태` 섹션을 추가했습니다.
- `EVICTIONS_DETECTED`, `REPLICATION_LAG`는 위험 알림 emoji, `CPU_HIGH`, `MEMORY_HIGH`는 주의 알림 emoji로 표시합니다.

2026-06-29 2차 구현 상태:

- `seat-lock-service`가 `reservation.lifecycle.events` topic으로 좌석 잠금 이벤트를 발행합니다.
- 구현 event type은 `SEAT_LOCK_REQUESTED`, `SEAT_LOCKED`, `SEAT_LOCK_FAILED`, `SEAT_UNLOCKED`입니다.
- Kafka publish 실패는 좌석 잠금 API를 실패시키지 않고 metric/log로만 남깁니다.
- 성공 이벤트인 `SEAT_LOCKED`, `SEAT_UNLOCKED`는 DB transaction commit 이후 발행되도록 구성했습니다.
- `lockId` 같은 좌석 잠금 토큰성 값은 payload에 저장하지 않습니다.
- Kafka→S3 sink runner가 seat-lock event type을 허용하도록 확장했습니다.
- `SEAT_LOCK_EXPIRED`는 Valkey TTL 만료를 정확히 감지하는 keyspace notification 또는 sweep job이 생긴 뒤 추가하는 후속 작업으로 남겨둡니다.

리포트 활용:

- 좌석 잠금 성공률
- 좌석 잠금 실패 수
- lock 만료/잔류 의심 건수
- 인기 좌석 구역 또는 hot key 후보
- Valkey eviction/CPU 알람과의 상관관계

### 3순위: Kafka 파이프라인 자체 상태

권장 topic:

```text
infra.audit.events
```

권장 event type:

```text
KAFKA_PRODUCE_FAILED
KAFKA_S3_SINK_DELAYED
KAFKA_EVENT_SKIPPED
KAFKA_EVENT_INVALID
KAFKA_S3_SINK_COMPLETED
```

2026-06-29 1차 구현 상태:

- Capacity Advisor가 Athena `ticket_events` event lake를 조회해 Kafka pipeline health를 계산합니다.
- 기대 producer는 기본적으로 `ticket-service`, `waiting-room-service`입니다.
- 기대 event type은 `WAITING_ENTERED`, `ACCESS_TOKEN_ISSUED`, `RESERVATION_REQUESTED`, `RESERVATION_CONFIRMED`입니다.
- 리포트는 전체 이벤트 수, 최신 이벤트 시각, producer별 count, event type별 count, 누락 producer, 누락 event type을 보여줍니다.
- `KAFKA_S3_SINK_COMPLETED`와 `SQS_WORKER_STATUS_RECORDED` audit event가 적재되면 같은 섹션에 함께 표시합니다.
- 2026-06-29 기준 Slack report에서 `sink completed 1`, `sqs-worker-audit-recorder=1~2`가 표시되는 것을 검증했습니다.
- `KAFKA_PRODUCE_FAILED`, `KAFKA_EVENT_INVALID`, `KAFKA_EVENT_SKIPPED`는 구조는 열려 있고, 실제 producer/sink 실패 자동 발행은 후속 확장입니다.
- 아직 MSK broker metric, consumer lag, 상시 sink 지연을 직접 조회하는 단계는 아닙니다. 현재는 Capacity Advisor가 실제로 사용하는 S3/Athena event lake 기준의 pipeline health입니다.

### 8.4 Capacity Advisor seat-lock 이벤트 섹션

2026-06-29 기준 Capacity Advisor는 Athena event lake에서 `seat-lock-service`가 발행한 좌석 잠금 이벤트를 조회해 별도 섹션으로 표시합니다.

포함 이벤트:

```text
SEAT_LOCK_REQUESTED
SEAT_LOCKED
SEAT_LOCK_FAILED
SEAT_UNLOCKED
```

리포트가 보여주는 값:

- 좌석 잠금 요청 수
- 좌석 잠금 성공 수
- 좌석 잠금 실패 수
- 좌석 잠금 해제 수
- 잠금 성공률
- 잠금 실패율
- 잠금 해제율
- 최신 seat-lock 이벤트

의미:

- Valkey CloudWatch metric은 좌석 잠금 계층의 인프라 상태를 보여줍니다.
- seat-lock 이벤트 섹션은 실제 서비스 흐름에서 좌석 잠금이 성공했는지, 경쟁/중복 시도가 있었는지 보여줍니다.
- 두 정보를 함께 보면 “Valkey는 정상인데 좌석 잠금 실패가 많은지”, “Valkey 리소스 압박과 좌석 잠금 실패가 같이 증가하는지”를 구분할 수 있습니다.

### 8.5 infra.audit.events 1차 기반

Kafka/SQS 파이프라인 자체 상태도 분석 가능한 이벤트로 남기기 위해 event lake 허용 event type을 확장했습니다.

지원 이벤트:

```text
KAFKA_PRODUCE_FAILED
KAFKA_S3_SINK_DELAYED
KAFKA_EVENT_SKIPPED
KAFKA_EVENT_INVALID
KAFKA_S3_SINK_COMPLETED
SQS_WORKER_STATUS_RECORDED
SQS_BACKLOG_DETECTED
SQS_DLQ_DETECTED
```

현재 1차 구현:

- `kafka_s3_sink.py --emit-audit-event`로 sink 실행 완료를 `KAFKA_S3_SINK_COMPLETED` 이벤트로 기록할 수 있습니다.
- `record_sqs_worker_audit.py`로 SQS 원본 큐/DLQ 상태를 audit event로 기록할 수 있습니다.
- Capacity Advisor의 Kafka pipeline health는 이 audit event type들을 같은 Athena table에서 조회할 수 있습니다.

남은 확장:

- backend producer 실패를 `KAFKA_PRODUCE_FAILED`로 자동 발행
- 상시 Kafka sink 또는 EventBridge schedule로 SQS worker 상태 주기 기록
- `infra.audit.events` topic에 producer를 붙여 audit event도 Kafka topic을 거쳐 S3/Athena에 적재

리포트 활용:

- Kafka producer 실패 수
- S3 sink 적재 성공/실패 수
- invalid event 수
- 마지막 적재 시각
- Athena 표본 부족이 실제 트래픽 부족인지, 파이프라인 지연인지 구분

## 8. 리스크와 방어 논리

| 질문 | 답변 |
|---|---|
| 왜 SQS만 쓰지 않았나? | SQS는 작업 처리 큐로 적합하지만 여러 consumer가 같은 이벤트 로그를 시간순으로 재사용하는 분석/관측 백본에는 Kafka가 더 적합합니다. |
| Kafka가 과한 것 아닌가? | 핵심 예매 경로를 대체하지 않고 분석/관측 경로에만 붙여 리스크를 낮췄습니다. |
| 비용은 어떻게 제어하나? | dev 기본값은 비활성화하고, MSK Serverless를 선택해 broker capacity 관리를 줄입니다. |
| 중복 이벤트는 어떻게 처리하나? | 모든 event는 `eventId`를 가지며 consumer가 idempotency를 보장합니다. |
| 장애 시 예매가 실패하나? | Phase 2에서도 Kafka publish 실패는 예매 흐름을 중단하지 않도록 설계합니다. |
