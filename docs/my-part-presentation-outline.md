# My Part Presentation Outline

## 1. 문서 목적

이 문서는 Baselink MSA 프로젝트에서 내가 맡은 Data & Async / Reliability / DR / Kafka 개인 프로젝트 파트를 발표와 멘토 설명용으로 정리한 자료다.

팀 발표에서는 각자 맡은 파트의 PPT를 만든 뒤 합치기로 했으므로, 이 문서는 내 파트 PPT에 들어갈 핵심 메시지, 슬라이드 구성, 설명 스크립트, 캡처 후보, 예상 질문 답변을 정리한다.

## 2. 내 담당 파트 한 문장 요약

```text
예매 서비스의 데이터 안정성과 장애 대응력을 높이기 위해 RDS, SQS, Valkey, Backup/DR, DB connection budget, 대기열 자동 감속, Kafka 이벤트 스트리밍과 Capacity Advisor를 설계·구현·검증했다.
```

발표용으로 더 짧게 말하면 다음과 같다.

```text
트래픽이 몰려도 DB가 무너지지 않고, 장애가 나도 복구 가능하며, 실제 처리량을 이벤트로 분석해 안전한 입장량을 판단할 수 있는 데이터 안정성 기반을 만들었습니다.
```

## 3. 발표 핵심 메시지

내 파트의 핵심은 “리소스를 많이 붙였다”가 아니다.

핵심 메시지는 다음 세 가지다.

1. 장애를 막는 구조
   - RDS connection budget
   - Hikari/Python pool 제한
   - KEDA maxReplicaCount 제한
   - RDS-aware 대기열 자동 감속

2. 장애가 나도 복구하는 구조
   - RDS Multi-AZ
   - PITR
   - AWS Backup
   - Cross-region backup
   - Tokyo Pilot Light DR
   - SQS DLQ/redrive

3. 운영 판단 근거를 만드는 구조
   - Transactional Outbox
   - Kafka/MSK Serverless
   - Kafka -> S3/Athena
   - Capacity Advisor
   - 부하테스트 기반 검증 계획

## 4. 전체 아키텍처 설명 흐름

내 파트는 다음 흐름으로 설명하면 자연스럽다.

```text
사용자 트래픽 증가
-> 대기열이 신규 입장 속도를 제어
-> 예매 요청은 RDS transaction으로 저장
-> 중요한 비동기 작업은 SQS worker가 처리
-> 실패 메시지는 DLQ에 격리
-> 예매/대기열 이벤트는 Outbox와 Kafka로 기록
-> 이벤트는 S3/Athena에 쌓여 처리량 분석에 사용
-> Capacity Advisor가 안전 입장량을 추천
-> RDS/Backup/DR 구성으로 장애와 데이터 손실에 대비
```

이 흐름을 한 장의 그림으로 만들면 PPT에서 가장 이해가 쉽다.

```text
User
  |
  v
Waiting Room / Admission Control
  |                 ^
  |                 |
  v                 | RDS connection pressure
Ticket Service ---> RDS PostgreSQL
  |                  |
  | Outbox           | PITR / AWS Backup / Cross-region copy
  v                  v
SQS Worker         Restore / DR
  |
  v
Reservation Confirm

Outbox / Domain Events
  |
  v
Kafka/MSK
  |
  v
S3 + Athena
  |
  v
Capacity Advisor
```

## 5. PPT 권장 구성

내 파트는 8~10장 정도가 적당하다.

전체 발표 시간이 짧다면 6장으로 줄이고, 기술 질문 대비용 appendix를 뒤에 붙인다.

### Slide 1. 담당 범위와 문제 정의

제목:

```text
Data Reliability & Event-driven Capacity Control
```

넣을 내용:

- 담당 범위: RDS, SQS, Valkey, Backup/DR, DB connection, 대기열 자동 감속, Kafka/Capacity Advisor
- 해결하려는 문제:
  - 예매 트래픽이 몰리면 DB connection이 먼저 한계에 도달할 수 있음
  - 장애 발생 시 데이터 복구 가능성이 중요함
  - 단순 모니터링이 아니라 “운영 판단 근거”가 필요함

발표 멘트:

```text
제가 맡은 파트는 예매 기능 자체보다, 예매 서비스가 트래픽과 장애 상황에서도 안정적으로 버티고 복구될 수 있게 만드는 데이터 안정성 영역입니다.
```

캡처 후보:

- `docs/data-async-status-roadmap.md`
- 전체 담당 범위 표

### Slide 2. RDS 안정성 설계

제목:

```text
RDS: 최종 데이터 저장소 보호
```

넣을 내용:

- PostgreSQL Multi-AZ
- deletion protection
- final snapshot
- automated backup 7일
- PITR
- AWS Backup daily snapshot
- Flyway 기반 schema 관리
- application DB 계정 분리

강조 포인트:

```text
RDS는 예매, 좌석, 사용자, 주문 데이터의 최종 저장소이므로 장애 예방과 복구 가능성을 모두 설계했다.
```

발표 멘트:

```text
RDS는 단순히 생성한 것이 아니라 Multi-AZ로 가용성을 확보하고, PITR과 AWS Backup으로 특정 시점 복구까지 가능하도록 구성했습니다. 또한 Flyway로 DB 구조를 코드 이력으로 관리해 복원 후에도 schema 검증이 가능하게 했습니다.
```

캡처 후보:

- AWS RDS 콘솔: Multi-AZ, backup retention
- Terraform `modules/rds/main.tf`
- Flyway migration 목록
- PITR restore runbook

### Slide 3. Backup / Restore / DR

제목:

```text
백업이 아니라 복구 가능성을 검증
```

넣을 내용:

- AWS Backup vault/plan/selection
- on-demand backup 검증
- RDS restore job 검증
- PITR restore 검증
- Tokyo cross-region backup copy
- Tokyo Pilot Light network
- Tokyo private RDS restore
- ECR Cross-Region Replication

강조 포인트:

```text
백업 설정만 확인한 것이 아니라 실제 복원 DB를 만들고 EKS 내부에서 schema/table/row count를 검증했다.
```

발표 멘트:

```text
백업은 설정만 있다고 끝나는 게 아니라 실제로 복구가 되어야 의미가 있습니다. 그래서 recovery point에서 임시 RDS를 복원하고, EKS 내부에서 Flyway 이력과 핵심 테이블 row count를 확인했습니다. 이후 도쿄 리전에도 recovery point를 복사하고 private RDS 복원까지 검증했습니다.
```

캡처 후보:

- AWS Backup recovery point
- Restore job completed
- `docs/aws-backup-restore-runbook.md`
- `docs/disaster-recovery-strategy.md`
- `docs/tokyo-dr-compute-cutover-runbook.md`

### Slide 4. SQS / DLQ 기반 비동기 처리

제목:

```text
SQS: 실패를 격리하고 재처리 가능한 구조
```

넣을 내용:

- ticket-confirm-queue
- ticket-confirm-dlq
- maxReceiveCount
- visibility timeout
- DLQ alarm
- redrive policy
- worker 비동기 처리

강조 포인트:

```text
처리 실패 메시지를 유실하지 않고 DLQ에 격리해 원인 분석 후 재처리할 수 있게 했다.
```

발표 멘트:

```text
예매 확정처럼 반드시 처리되어야 하는 비동기 작업은 SQS로 분리했습니다. worker가 반복 실패하면 메시지를 DLQ로 격리하고, 운영자가 원인을 확인한 뒤 redrive할 수 있는 구조로 만들었습니다.
```

캡처 후보:

- SQS queue / DLQ 콘솔
- CloudWatch alarm
- Slack alarm 수신 화면
- `modules/sqs/README.md`

### Slide 5. Valkey와 대기열/좌석 잠금

제목:

```text
Valkey: 빠른 임시 상태와 RDS 영구 데이터 분리
```

넣을 내용:

- 대기열 rank
- access token
- 좌석 lock
- TTL 기반 임시 상태
- Multi-AZ primary/replica
- automatic failover

강조 포인트:

```text
Valkey는 빠른 임시 상태를 담당하고, 최종 예매 데이터는 RDS에 저장되도록 책임을 분리했다.
```

발표 멘트:

```text
대기열 순번이나 좌석 잠금 같은 빠르게 만료되는 상태는 Valkey에 두고, 최종 예매 데이터는 RDS에 저장했습니다. 이렇게 역할을 분리해서 빠른 응답성과 데이터 정합성을 동시에 가져가도록 했습니다.
```

캡처 후보:

- ElastiCache Valkey replication group
- Multi-AZ / automatic failover 설정
- 대기열 API 응답

### Slide 6. DB Connection Budget과 자동 감속

제목:

```text
트래픽 증가보다 먼저 DB connection 한계를 계산
```

넣을 내용:

- RDS max_connections 79
- 운영/관리 여유분 약 19
- app budget 약 60
- 서비스별 Hikari pool
- Python bounded pool
- KEDA maxReplicaCount 제한
- RDS connection 단계별 감속

핵심 표:

| RDS Connection | 상태 | 입장 비율 |
| ---: | --- | ---: |
| 0~39 | NORMAL | 100% |
| 40~49 | CAUTION | 75% |
| 50~54 | WARNING | 50% |
| 55~59 | CRITICAL | 25% |
| 60 이상 | STOP | 0% |

강조 포인트:

```text
Pod를 무작정 늘리는 것이 아니라 RDS가 감당 가능한 connection budget 안에서 autoscaling과 입장량을 제어했다.
```

발표 멘트:

```text
KEDA가 Pod를 늘려도 RDS connection은 무한하지 않습니다. 그래서 서비스별 pool과 max replica를 계산해 전체 app connection이 60 안에 들어오게 제한했고, RDS connection이 위험 구간에 가까워지면 대기열 신규 입장을 자동으로 줄이도록 했습니다.
```

캡처 후보:

- `docs/db-connection-pool-strategy.md`
- KEDA maxReplicaCount 코드
- waiting-room admission API 결과
- RDS DatabaseConnections 그래프

### Slide 7. Kafka 개인 프로젝트: 이벤트 스트리밍 플랫폼

제목:

```text
Kafka: 여러 consumer가 재사용 가능한 이벤트 로그
```

넣을 내용:

- MSK Serverless
- IAM 인증
- topic 5개
  - `ticket.domain.events`
  - `waiting.operational.events`
  - `reservation.lifecycle.events`
  - `capacity.signals`
  - `infra.audit.events`
- ticket-service / waiting-room-service dual publish
- SQS와 Kafka 역할 분리

강조 포인트:

```text
SQS는 반드시 처리해야 하는 작업 큐, Kafka는 여러 consumer가 재사용하는 이벤트 로그로 역할을 분리했다.
```

발표 멘트:

```text
Kafka는 기존 SQS를 대체하려고 넣은 것이 아닙니다. SQS는 예매 확정처럼 반드시 처리해야 하는 작업 큐로 유지하고, Kafka는 대기열과 예매 이벤트를 여러 consumer가 재사용할 수 있는 공통 이벤트 로그로 사용했습니다.
```

캡처 후보:

- MSK Serverless cluster
- topic list
- Terraform MSK module
- backend `KAFKA_*` config
- Kafka consume 결과

### Slide 8. Outbox -> Kafka -> S3/Athena -> Capacity Advisor

제목:

```text
이벤트 기반 Capacity Advisor
```

넣을 내용:

- Transactional Outbox
- Kafka dual publish
- Kafka S3 sink
- S3 partitioned JSON
- Glue/Athena query
- Capacity Advisor report
- 처리량과 DB 여유율 기반 안전 입장량 추천
- SQS/Worker backlog/DLQ 상태
- Valkey/좌석 잠금 계층 상태
- Kafka pipeline health
- Slack 운영 리포트

검증된 이벤트:

```text
WAITING_ENTERED
ACCESS_TOKEN_ISSUED
RESERVATION_REQUESTED
RESERVATION_CONFIRMED
ADMISSION_THROTTLE_APPLIED
ADMISSION_STOP_APPLIED
ADMISSION_THROTTLE_RECOVERED
SEAT_LOCK_REQUESTED
SEAT_LOCKED
SEAT_LOCK_FAILED
SEAT_UNLOCKED
```

강조 포인트:

```text
단순 모니터링 대시보드가 아니라, 실제 사용자 흐름 이벤트와 DB 압력 신호를 분석해 운영자가 검토할 수 있는 입장량 추천 근거를 만들었다.
```

발표 멘트:

```text
사용자가 대기열에 들어오고, 입장권을 받고, 좌석을 잠그고, 예매를 요청하고, 확정되는 전 과정을 이벤트로 기록했습니다. 이 이벤트를 Kafka에서 S3/Athena로 적재하고, Capacity Advisor가 실제 확정 처리량과 DB 여유율을 기준으로 안전 입장량을 추천하도록 만들었습니다. 여기에 RDS connection 압력으로 감속이 발생했는지, SQS worker 처리 상태가 밀리는지, Valkey에서 좌석 lock/access token 같은 TTL 상태가 위험해질 조짐이 있는지, 그리고 Kafka/S3/Athena 분석 파이프라인에 기대 producer와 event type이 제대로 들어오는지까지 리포트에 함께 보여주도록 확장했습니다.
```

캡처 후보:

- S3 partition
- Athena query 결과
- Capacity Advisor JSON/Markdown
- Capacity Advisor Slack report
- `docs/kafka-capacity-advisor-e2e-verification.md`
- `capacity-reports/game-1-capacity.md`

### Slide 8-1. 운영 알림과 리포트 채널 분리

제목:

```text
장애 알림과 운영 리포트의 역할 분리
```

넣을 내용:

| 채널 | 목적 | 예시 |
| --- | --- | --- |
| `aws-alerts` | 장애/위험 감지 | RDS connection high, SQS DLQ, Backup 실패, WAF 차단 |
| `capacity-reports` 또는 `ops-reports` | 운영 의사결정 | 다음 예매 오픈 전 안전 입장량 추천, 최근 감속/복구 요약 |

강조 포인트:

```text
기존 알림은 “문제가 생겼다”를 알려주고, Capacity Advisor 리포트는 “운영자가 다음 입장 정책을 어떻게 잡을지” 판단하게 돕는다.
```

발표 멘트:

```text
장애 알림과 운영 리포트는 목적이 다르기 때문에 채널을 분리했습니다. aws-alerts는 즉시 대응해야 하는 위험 신호를 받고, capacity-reports는 예매 오픈 전이나 운영 중에 입장량을 어떻게 조정할지 판단하는 리포트를 받는 구조로 정리했습니다.
```

캡처 후보:

- Slack `aws-alerts` 알림 화면
- Capacity Advisor Slack report 화면
- GitHub Actions `Capacity Advisor Slack Report` 실행 화면
- `docs/ops-alarm-runbook.md`

### Slide 9. 부하테스트 기반 검증 결과

제목:

```text
구현에서 끝내지 않고 실제 부하로 검증
```

넣을 내용:

- k6 `capacity-advisor-flow.js`로 실제 API 흐름 검증
  - 대기열 진입
  - 입장권 발급
  - 예매 요청
  - 예매 확정
- smoke/baseline/load 단계 실행
- 주요 결과:
  - smoke: 2 VU / 1분 / HTTP 실패율 0.00%
  - baseline: 10 VU / 3분 / HTTP 실패율 0.08%
  - load: 30 VU / 5분 / HTTP 실패율 0.20%
  - load에서 ticket reserve/confirm은 성공, p95 약 130ms
  - load에서 waiting-room token/status check가 제한되어 check 성공률 74.27%
- 부하 이후 인프라 상태:
  - RDS DatabaseConnections 최대 28/60
  - SQS backlog 0, DLQ 0
  - Valkey CPU 1.23%, memory 5.32%, evictions 0
  - Kafka event lake total events 1,361
- Capacity Advisor 결과:
  - `RECOMMENDED`
  - `HIGH`
  - v1 원시 계산 기준 추천 정책 1명/분
  - v2 guardrail 적용 후 운영 추천 정책 20명/분
  - 시간 범위 필터로 30 VU load 구간만 분리 분석 시 안정 확정 처리량 27건/분, 추천 21명/분
  - 표본: 대기열 진입 402 / 입장권 317 / 예약 요청 317 / 예약 확정 317

강조 포인트:

```text
이번 부하에서는 DB 병목보다 waiting-room admission control이 먼저 작동했다.
RDS Proxy는 connection storm이 확인될 때, Read Replica는 조회 API 병목이 확인될 때 도입하는 것이 합리적이다.
```

발표 멘트:

```text
구현에서 끝내지 않고 실제 부하테스트로 대기열부터 예매 확정까지의 흐름을 검증했습니다. 30 VU 부하에서도 예매 요청과 확정 API는 성공했고 p95도 약 130ms 수준이었습니다. 반면 대기열 token/status check는 일부 제한되어, waiting-room admission control이 먼저 backend를 보호하는 형태로 동작했습니다. 부하 이후 RDS connection은 최대 28/60, SQS backlog와 DLQ는 0, Valkey도 안정적이었습니다. 초기 Advisor는 하루치 표본이 섞여 원시 계산 기준 1명/분처럼 너무 낮은 값을 냈지만, time range filter로 실제 30 VU load 구간만 분리하니 안정 확정 처리량 27건/분, 추천 21명/분으로 확인됐습니다. 그래서 RDS Proxy는 당장 도입하는 것이 아니라 connection storm이 확인될 때 도입하고, Read Replica는 조회 API 중심 부하테스트에서 병목이 확인될 때 적용하는 것이 합리적이라고 판단했습니다.
```

캡처 후보:

- `docs/load-test-validation-plan.md`
- Ansible `capacity-advisor-flow.js`
- k6 summary 결과
- Capacity Advisor Slack report
- S3/Athena event lake count

### Slide 10. 결과와 남은 과제

제목:

```text
결과: 장애 예방, 복구 가능성, 운영 판단 근거 확보
```

넣을 내용:

완료:

- RDS Multi-AZ / PITR / AWS Backup
- 실제 복원 리허설
- Tokyo cross-region backup / RDS restore
- SQS DLQ / alarm
- Valkey Multi-AZ
- DB connection budget
- 대기열 자동 감속
- Kafka/MSK 이벤트 스트리밍
- Kafka -> S3/Athena -> Capacity Advisor E2E
- Capacity Advisor Slack report workflow
- SQS/Worker 상태 리포트 섹션
- Valkey/좌석 잠금 계층 상태 리포트 섹션
- Kafka pipeline health 리포트 섹션
- seat-lock-service Kafka 이벤트 발행
- seat-lock 이벤트 Slack/Advisor 섹션
- infra audit event 1차 기록
- 실제 k6 부하테스트 기반 Capacity Advisor 재검증

남은 작업:

- Capacity Advisor testRunId 기반 부하 구간 분리 분석
- 조회 API 부하테스트로 Read Replica 필요성 판단
- connection storm 부하테스트로 RDS Proxy 필요성 판단
- `infra.audit.events` 기반 Kafka sink/producer 상태 이력화 추가 확장
- 예매 오픈 전/진행 중/감속 발생 시 Slack 트리거 고도화
- DR compute 전체 cutover 리허설
- 발표 캡처 정리

마무리 멘트:

```text
이번 작업을 통해 예매 서비스가 단순히 정상 상황에서 동작하는 수준을 넘어, 트래픽 증가와 장애 상황에서도 데이터 안정성과 복구 가능성을 갖도록 기반을 만들었습니다.
```

## 6. 6장 축약 버전

시간이 부족하면 10장을 6장으로 줄인다.

| 슬라이드 | 제목 | 핵심 |
| --- | --- | --- |
| 1 | 담당 범위와 문제 정의 | 데이터 안정성, 장애 복구, 운영 판단 |
| 2 | RDS/Backup/DR | Multi-AZ, PITR, AWS Backup, Tokyo DR |
| 3 | SQS/Valkey/Connection Budget | 비동기 처리, 임시 상태, DB 보호 |
| 4 | 대기열 자동 감속 | RDS connection 기반 입장량 제어 |
| 5 | Kafka + Capacity Advisor | 이벤트 로그, S3/Athena, 안전 입장량 |
| 6 | 검증 결과와 남은 작업 | 완료 항목, 실제 부하 검증, 고도화 |

## 7. 발표에서 꼭 보여주면 좋은 캡처 목록

우선순위가 높은 캡처:

1. RDS 콘솔
   - Multi-AZ
   - backup retention
   - latest restorable time

2. AWS Backup 콘솔
   - backup vault
   - recovery point
   - restore job completed
   - cross-region copy

3. SQS 콘솔
   - source queue
   - DLQ
   - CloudWatch alarm

4. Valkey 콘솔
   - primary/replica
   - Multi-AZ / automatic failover

5. MSK 콘솔
   - Serverless cluster
   - IAM bootstrap broker

6. Kafka topic / consume 결과
   - `ticket.domain.events`
   - `waiting.operational.events`

7. S3 partition
   - `event_type=...`
   - `game_id=...`

8. Athena / Capacity Advisor 결과
   - event count
   - recommendedPolicyEnterPerMinute
   - confidence/status
   - capacity.signals 감속/복구 섹션

9. Slack 알림/리포트
   - `aws-alerts` 장애/위험 알림
   - Capacity Advisor Slack report
   - GitHub Actions workflow run

10. Terraform 코드
   - RDS module
   - SQS module
   - MSK module
   - backend config

11. 문서
   - `docs/load-test-validation-plan.md`
   - `docs/kafka-capacity-advisor-e2e-verification.md`
   - `docs/ops-alarm-runbook.md`

## 8. 멘토 설명용 3분 버전

```text
제가 맡은 파트는 예매 서비스의 데이터 안정성과 장애 대응력입니다.

먼저 RDS는 Multi-AZ, PITR, AWS Backup을 적용했고, 실제 recovery point에서 임시 RDS를 복원해 Flyway 이력과 핵심 테이블 데이터를 검증했습니다. 도쿄 리전에도 backup copy와 private RDS restore를 검증해 Pilot Light DR의 데이터 기반을 만들었습니다.

트래픽이 몰릴 때는 DB connection이 병목이 될 수 있기 때문에, 서비스별 Hikari pool과 Python pool, KEDA max replica를 RDS connection budget 안에 들어오도록 제한했습니다. 그리고 RDS connection 사용률이 올라가면 대기열 신규 입장량을 자동으로 줄이도록 admission control을 구현했습니다.

비동기 처리 쪽은 SQS와 DLQ로 예매 확정 메시지를 안정적으로 처리하고, 실패 메시지는 격리 후 redrive할 수 있게 했습니다. Valkey는 대기열, access token, 좌석 lock처럼 빠르게 만료되는 상태를 담당하고, 최종 예매 데이터는 RDS에 저장하도록 책임을 분리했습니다.

개인 프로젝트로는 Kafka/MSK Serverless 기반 이벤트 스트리밍을 추가했습니다. SQS는 작업 큐로 유지하고, Kafka는 ticket-service, waiting-room-service, seat-lock-service의 이벤트를 여러 consumer가 재사용할 수 있는 이벤트 로그로 사용했습니다. 이 이벤트를 S3/Athena에 적재하고 Capacity Advisor가 실제 처리량과 DB 여유율을 기준으로 안전 입장량을 추천하도록 만들었습니다. 또한 `capacity.signals`로 감속/복구 이력을 기록하고, SQS worker backlog/DLQ, Valkey CPU·memory·eviction·replication lag, Kafka pipeline health까지 리포트에 함께 보여주도록 확장했습니다. 운영자가 리포트를 직접 열지 않아도 Slack에서 추천 입장량과 판단 근거를 확인할 수 있도록 Slack report workflow도 구현했습니다.

실제 k6 부하테스트도 수행했습니다. smoke, baseline, 30 VU load를 실행했고, ticket reserve/confirm은 정상 처리되었으며 RDS connection은 최대 28/60, SQS backlog와 DLQ는 0, Valkey도 안정적이었습니다. Kafka event lake에는 1,361건의 이벤트가 적재됐고 Capacity Advisor는 `HIGH` 신뢰도로 추천값을 계산했습니다. 하루치 전체 표본으로 보면 raw 계산이 1.6명/분이라 낮게 보였지만, time range filter로 실제 30 VU load 구간만 분리하니 안정 확정 처리량 27건/분, 추천 21명/분으로 확인됐습니다. 이번 부하에서는 DB 병목보다 waiting-room admission control이 먼저 작동했기 때문에, RDS Proxy와 Read Replica는 무조건 도입이 아니라 각각 connection storm과 조회 API 병목이 확인될 때 도입하는 것으로 판단했습니다.
```

## 9. 예상 질문과 답변

### Q1. 왜 RDS Proxy를 바로 도입하지 않았나요?

```text
먼저 Hikari pool, Python pool, KEDA maxReplicaCount로 connection budget을 계산해 RDS connection을 제어했습니다.
RDS Proxy는 connection storm이나 pool timeout이 실제 부하테스트에서 확인될 때 도입하는 것이 더 합리적이라고 판단했습니다.
```

### Q2. 왜 Read Replica를 바로 만들지 않았나요?

```text
Read Replica는 조회 부하가 실제 병목일 때 효과가 있습니다.
예매 확정이나 좌석 잠금처럼 최신성이 중요한 경로는 replica lag 때문에 reader로 보내면 위험합니다.
따라서 부하테스트에서 조회 API p95, ReadIOPS, RDS CPU를 확인한 뒤 lag를 허용할 수 있는 조회 API부터 분리하는 방향으로 설계했습니다.
```

### Q3. SQS가 있는데 왜 Kafka를 추가했나요?

```text
SQS와 Kafka의 역할이 다릅니다.
SQS는 반드시 처리해야 하는 작업 큐이고, Kafka는 여러 consumer가 같은 이벤트를 재사용할 수 있는 이벤트 로그입니다.
예매 확정 같은 명령 처리는 SQS로 유지하고, 대기열/예매 이벤트 분석과 Capacity Advisor에는 Kafka를 사용했습니다.
```

### Q4. Capacity Advisor 추천값이 낮으면 좋은 것 아닌가요?

```text
무조건 낮을수록 좋은 것은 아닙니다.
너무 낮으면 사용자는 오래 기다리고, 시스템 자원이 남아도 입장을 막게 됩니다.
그래서 추천값은 실제 확정 처리량, 평균 대기시간, RDS connection 여유율, SQS backlog, p95 latency를 함께 보고 해석해야 합니다.
이번 부하테스트에서도 원시 계산은 1명/분까지 내려갔지만 RDS/SQS/Valkey는 정상이라, 운영 정책으로 바로 쓰기에는 과도하게 보수적이라고 판단했습니다.
그래서 minimum floor와 최대 감소율 guardrail을 적용해 동일 표본 기준 운영 추천값을 20명/분으로 보정했습니다.
또 시간 범위 필터로 실제 30 VU load 구간만 분리하니 안정 확정 처리량은 27건/분, 추천값은 21명/분으로 확인됐습니다. 따라서 1명/분은 시스템 한계가 아니라 표본이 섞였을 때의 보수적 계산 결과였습니다.
```

### Q5. 백업은 실제로 복구해봤나요?

```text
네. AWS Backup recovery point에서 임시 RDS를 복원했고, EKS 내부에서 Flyway 이력과 핵심 테이블 row count를 검증했습니다.
또 PITR 복원과 도쿄 리전 cross-region recovery point 기반 private RDS restore도 검증했습니다.
```

### Q6. DR은 active-active인가요?

```text
아닙니다. 현재 프로젝트 규모와 비용을 고려해 Pilot Light 방식으로 설계했습니다.
평상시에는 도쿄 리전에 최소 기반만 준비하고, 장애 시 recovery point에서 RDS를 복원한 뒤 compute와 endpoint를 전환하는 전략입니다.
```

### Q7. Kafka 장애가 나면 예매도 실패하나요?

```text
예매 핵심 경로는 Kafka에 의존하지 않도록 설계했습니다.
예매 transaction과 Outbox 기록이 우선이고, Kafka publish 실패는 metric/log로 남겨 분석 경로에 영향을 주되 예매 transaction 자체를 깨뜨리지 않도록 분리했습니다.
```

### Q8. aws-alerts와 Capacity Advisor Slack 리포트는 뭐가 다른가요?

```text
aws-alerts는 장애나 위험 징후를 즉시 알려주는 채널입니다.
예를 들어 RDS connection high, SQS DLQ, Backup 실패, WAF 차단 같은 알림이 여기에 들어갑니다.

Capacity Advisor Slack 리포트는 장애 알림이 아니라 운영 의사결정용 리포트입니다.
이전 이벤트와 현재 DB 상태를 기반으로 다음 예매 오픈 때 안전 입장량을 어떻게 잡을지 판단할 수 있게 돕습니다.
그래서 capacity-reports 또는 ops-reports처럼 별도 채널로 분리하는 것이 좋습니다.
```

## 10. 발표 자료 작성 팁

- 슬라이드마다 “무엇을 만들었는가”보다 “왜 필요했는가”를 먼저 말한다.
- AWS 콘솔 캡처는 한 장에 너무 많이 넣지 않는다.
- 숫자가 있는 검증 결과는 표로 보여준다.
- Kafka와 SQS는 대체 관계가 아니라 역할 분리라는 점을 명확히 말한다.
- Capacity Advisor는 AI 예측 시스템처럼 말하지 말고, 규칙 기반 판단 보조 도구로 설명한다.
- RDS Proxy/Read Replica를 안 만든 이유는 “못 했다”가 아니라 “부하테스트 지표로 도입 조건을 판단하기 위해 보류했다”라고 설명한다.

## 11. 최종 한 장 요약

```text
RDS는 안전하게 저장하고,
SQS는 실패 가능한 작업을 격리하고,
Valkey는 빠른 임시 상태를 처리하고,
Connection Budget은 DB를 보호하고,
대기열 자동 감속은 트래픽을 조절하고,
Kafka는 이벤트를 공통 로그로 모으고,
S3/Athena/Capacity Advisor와 Slack 리포트는 운영 판단 근거를 만든다.
```

이 문장을 마지막 슬라이드나 Q&A 직전에 넣으면 내 담당 파트가 한 번에 정리된다.
