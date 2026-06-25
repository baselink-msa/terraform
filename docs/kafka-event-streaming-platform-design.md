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
- 아직 서비스 producer dual publish 구현은 진행하지 않음

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
- waiting-room-service 이벤트를 SQS와 Kafka에 dual publish
- ticket-service Outbox publisher도 domain event를 SQS와 Kafka에 dual publish
- Kafka publish 실패는 핵심 요청을 실패시키지 않습니다.

완료 조건:

- backend Pod에서 Kafka 환경변수 확인 `완료`
- SQS 기존 이벤트 파이프라인 정상
- Kafka topic에도 동일 envelope 적재
- producer 실패 metric 확인

검증 기록:

- Terraform Apply Dev 성공
- GitOps backend Deployment에 `configmap.reloader.stakater.com/reload: "backend-config"` annotation 반영
- 전체 backend Deployment Ready 상태 확인
- `ticket-service`, `ticket-worker-service`, `waiting-room-service`에서 `KAFKA_*` 환경변수 확인
- ConfigMap 환경변수는 Pod 시작 시점에 주입되므로, 기존 Pod까지 최신 값을 받도록 backend Deployment 9개를 1회 rolling restart했다.

### Phase 3: Kafka to S3 sink

선택지는 두 가지입니다.

1. custom consumer
2. Kafka Connect S3 Sink

dev에서는 custom consumer가 단순합니다.

완료 조건:

- Kafka event가 S3 partition으로 저장
- Athena에서 기존 Capacity Advisor 쿼리 재사용 가능

### Phase 4: Realtime Capacity Intelligence

- 최근 1분/5분 입장권 발급량
- 예매 요청 대비 확정률
- DB 감속 발생률
- 안전 입장량 추천

완료 조건:

- load test 중 실시간 처리량과 추천값 산출
- 발표용 Markdown 리포트 생성

## 8. 리스크와 방어 논리

| 질문 | 답변 |
|---|---|
| 왜 SQS만 쓰지 않았나? | SQS는 작업 처리 큐로 적합하지만 여러 consumer가 같은 이벤트 로그를 시간순으로 재사용하는 분석/관측 백본에는 Kafka가 더 적합합니다. |
| Kafka가 과한 것 아닌가? | 핵심 예매 경로를 대체하지 않고 분석/관측 경로에만 붙여 리스크를 낮췄습니다. |
| 비용은 어떻게 제어하나? | dev 기본값은 비활성화하고, MSK Serverless를 선택해 broker capacity 관리를 줄입니다. |
| 중복 이벤트는 어떻게 처리하나? | 모든 event는 `eventId`를 가지며 consumer가 idempotency를 보장합니다. |
| 장애 시 예매가 실패하나? | Phase 2에서도 Kafka publish 실패는 예매 흐름을 중단하지 않도록 설계합니다. |
