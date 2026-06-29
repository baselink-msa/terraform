# Baselink 작업 연속성 인수인계 문서

## 1. 문서 목적

이 문서는 채팅 컨텍스트가 가득 차거나 다른 채팅방에서 작업을 이어가야 할 때, AI가 현재 프로젝트 맥락을 빠르게 복구하기 위한 인수인계 문서다.

다음 내용을 계속 갱신한다.

- 사용자가 프로젝트에서 맡은 역할
- 현재까지 구현한 주요 기능
- 지금 진행 중인 작업
- 남은 작업과 우선순위
- 작업할 때 사용자가 선호하는 진행 방식
- 구현 내용이나 발표 설명을 참고할 문서 위치
- 최근 트러블슈팅과 주의해야 할 운영 상태

새 채팅방에서 작업을 이어갈 때는 먼저 이 문서를 읽고, 필요하면 관련 상세 문서를 함께 확인한다.

## 2. 사용자 역할과 담당 범위

사용자는 Baselink MSA 프로젝트에서 데이터 안정성, 비동기 처리, 재해복구, DB 보호, 이벤트 기반 처리 고도화 영역을 주로 담당한다.

주요 담당 범위:

- RDS PostgreSQL 안정성
- AWS Backup과 PITR 복구 검증
- Cross-Region DR와 도쿄 Pilot Light
- SQS 기반 비동기 처리와 DLQ 운영
- Valkey Multi-AZ/failover 구성 이해와 설명
- DB connection pool budget과 RDS-aware admission control
- Python DB connection 제한과 모니터링 협업
- Outbox 기반 Ticket Event Pipeline
- Kafka/MSK Serverless 기반 이벤트 스트리밍 개인 프로젝트
- 발표용 요약 문서와 운영 Runbook 정리

발표 관점에서 사용자의 포지션은 다음처럼 설명할 수 있다.

```text
티켓 예매 서비스의 데이터 안정성과 장애 대응력을 높이기 위해
RDS, SQS, Valkey, Backup, DR, DB connection budget, 대기열 감속,
Outbox/Kafka 이벤트 파이프라인을 설계·구현·검증한 담당자
```

## 3. 작업 진행 방식 선호

사용자는 작업을 단순히 수행하는 것보다 “왜 이 작업을 하는지”와 “작업 후 무엇을 얻는지”를 함께 이해하고 싶어 한다.

따라서 앞으로 작업할 때는 다음 방식을 지킨다.

1. 작업 시작 전
   - 현재 상황을 짧게 요약한다.
   - 다음 작업을 왜 하는지 설명한다.
   - 위험하거나 비용이 드는 작업이면 먼저 짚고 넘어간다.

2. 작업 중
   - 긴 작업은 중간중간 진행 상황을 알려준다.
   - Terraform apply, GitHub Actions, AWS 리소스 생성처럼 시간이 걸리는 작업은 상태를 확인하며 진행한다.
   - 기존 사용자 변경분은 절대 함부로 덮어쓰지 않는다.

3. 작업 후
   - 무엇을 변경했는지 설명한다.
   - 왜 이 작업을 했는지 설명한다.
   - 어떤 기능이나 효과를 얻었는지 쉽게 설명한다.
   - 검증한 명령/결과를 요약한다.
   - 다음 작업 후보와 우선순위를 제안한다.

4. Git 작업
   - 사용자는 PR 생성과 merge를 직접 한다.
   - AI는 commit과 push까지만 수행한다.
   - PR을 만들라는 명시 요청이 없으면 PR은 만들지 않는다.

5. 문서 관리
   - 큰 작업이 끝날 때마다 관련 md 문서를 업데이트한다.
   - 발표에 쓸 수 있는 표현과 검증 결과를 문서에 남긴다.
   - 새 채팅방에서도 이어갈 수 있도록 이 문서를 갱신한다.

## 4. 현재 전체 구현 상태 요약

마지막 업데이트: `2026-06-29`

| 영역 | 상태 | 요약 |
| --- | --- | --- |
| RDS PostgreSQL | 검증 완료 | Multi-AZ, PITR, AWS Backup, Flyway, application DB 계정 분리까지 완료 |
| SQS 비동기 처리 | 검증 완료 | ticket-confirm, ticket-domain-events 큐/DLQ/알람 구성 |
| Valkey | 배포 | Multi-AZ primary/replica, automatic failover 구성 |
| Backup/Restore | 검증 완료 | AWS Backup, PITR, 임시 RDS 복원, Flyway/schema/data 검증 완료 |
| DR | 일부 검증 완료 | 도쿄 cross-region backup, Pilot Light network, 도쿄 RDS 복원 검증 완료 |
| DB Connection Pool | 검증 완료 | Spring/Python/KEDA connection budget과 RDS-aware 감속 구현 |
| 운영 알림 | 일부 검증 완료 | `aws-alerts` 장애/위험 알림, Capacity Advisor Slack 리포트 workflow 구현 |
| Outbox Event Pipeline | MVP 검증 완료 | Outbox→SQS→Lambda→S3→Athena→Capacity Advisor 기반 구현 |
| Kafka/MSK 개인 프로젝트 | 부하 검증 완료 | MSK Serverless, topic 5개, ticket/waiting/seat-lock/capacity signal publish, Kafka→S3 sink, Capacity Advisor Slack 리포트, SQS/Worker·Valkey·Kafka pipeline health, seat-lock, infra audit, 실제 k6 부하 기반 Advisor 재검증 완료 |
| 발표 문서 | 진행 중 | 담당 파트 발표 outline 작성, Slack 리포트/부하테스트 결과/Advisor 추천값 해석 보강 중 |

## 5. 최근 완료한 핵심 작업

### 5.1 RDS Secret rotation 장애 대응과 DB 계정 분리

문제:

- RDS master password rotation 이후 Kubernetes `backend-secret`과 실행 중인 Pod가 최신 비밀번호를 따라가지 못했다.
- 로그인, 게임 조회, 예매, DB 기반 챗봇 응답이 실패했다.

개선:

- RDS master 계정은 Flyway/migration/운영 복구 용도로 유지했다.
- 애플리케이션 런타임용 `baselink_app` 계정을 별도로 만들었다.
- `backend-secret`은 application Secret을 사용하도록 전환했다.
- `flyway-secret`은 master Secret을 사용하도록 분리했다.
- KEDA PostgreSQL scaler도 application 계정으로 전환했다.

효과:

- RDS master rotation이 발생해도 평상시 API DB 연결이 직접 영향받지 않는다.
- 런타임 권한이 최소화된다.
- Flyway와 application credential 생명주기가 분리된다.

참고 문서:

- `docs/application-database-credential-design.md`
- `docs/application-db-credential-cutover-runbook.md`

### 5.2 Backup, PITR, DR 검증

완료한 작업:

- RDS automated backup 7일 보존 확인
- AWS Backup daily snapshot 구성
- on-demand backup과 recovery point 확인
- 임시 RDS restore 후 EKS 내부 접속 검증
- PITR 복원 후 Flyway/schema/data/ticket-service smoke test 검증
- 도쿄 cross-region backup copy 검증
- 도쿄 Pilot Light network 배포
- 도쿄 private RDS 복원 검증

효과:

- “백업이 있다”가 아니라 “복구 가능한 백업임을 실제로 검증했다”고 설명할 수 있다.
- 서울 리전 장애 시 도쿄 복구 기반을 보여줄 수 있다.

참고 문서:

- `docs/aws-backup-design.md`
- `docs/aws-backup-restore-runbook.md`
- `docs/disaster-recovery-strategy.md`
- `docs/disaster-recovery-presentation-summary.md`
- `docs/tokyo-dr-compute-cutover-runbook.md`
- `docs/ecr-cross-region-replication-runbook.md`

### 5.3 DB connection budget과 대기열 자동 감속

완료한 작업:

- Spring/Python/KEDA 전체 app DB connection budget을 약 60 안에서 관리하도록 조정했다.
- RDS connection 사용량에 따라 대기열 입장량을 자동 감속하는 구조를 구현했다.
- NORMAL, 감속, STOP 단계별 통합 테스트를 진행했다.
- Python DB pool metric은 Prometheus 수집까지 확인했고, Grafana 패널/알림은 모니터링 담당자에게 요청했다.

효과:

- 트래픽이 몰려도 Pod scale-out이 RDS connection 고갈로 이어지지 않도록 방어한다.
- 대기열 시스템이 단순 입장 제어가 아니라 DB 상태를 반영하는 보호 장치가 된다.

참고 문서:

- `docs/db-connection-pool-strategy.md`
- `docs/data-async-status-roadmap.md`
- `docs/ops-alarm-runbook.md`

### 5.4 Outbox 기반 Ticket Event Pipeline

기존 개인 프로젝트 MVP:

```text
사용자가 대기열에 들어오고,
입장권을 받고,
예매를 요청하고,
예매를 확정하는 전 과정을 이벤트로 기록한 뒤,
실제 시스템 처리량을 계산해 안전한 입장 인원을 추천하는 프로젝트
```

구현 흐름:

```text
ticket-service / waiting-room-service
-> RDS Transactional Outbox
-> Publisher
-> SQS ticket-domain-events
-> Lambda writer
-> S3 partitioned JSON
-> Glue/Athena
-> Capacity report
```

효과:

- 예매 transaction과 이벤트 기록의 원자성을 보장한다.
- 분석용 이벤트를 S3/Athena에서 조회할 수 있다.
- Capacity Advisor의 기반 데이터를 만들 수 있다.

참고 문서:

- `docs/ticket-reliability-event-outbox-design.md`
- `capacity-reports/game-1-capacity.md`
- `capacity-reports/game-1-capacity.json`

### 5.5 Kafka/MSK Serverless 이벤트 스트리밍 프로젝트

Kafka 도입 목적:

```text
기존 Outbox/SQS/S3 분석 흐름을 서비스 전체 이벤트 스트리밍 인프라로 확장한다.
```

중요한 역할 분리:

| 기술 | 역할 |
| --- | --- |
| SQS | 반드시 처리해야 하는 명령/작업 큐 |
| Outbox | DB transaction과 이벤트 기록의 원자성 보장 |
| Kafka | 여러 consumer가 재사용할 수 있는 이벤트 로그 |
| S3/Athena | 장기 분석 저장소 |
| Capacity Advisor | 실제 처리량과 DB 여유율 기반 추천 |

완료한 Kafka 작업:

- Kafka 도입 설계 문서 작성
- MSK Serverless Terraform module 추가
- `enable_kafka_event_streaming` 변수 추가
- GitHub `DEV_INFRA_TFVARS`에 `enable_kafka_event_streaming = true` 반영
- MSK Serverless cluster `baselink-dev-event-streaming` 생성
- Kafka runtime config Secret 생성
- backend runtime IRSA Kafka policy 생성
- EKS 내부 network smoke test 성공
- EKS 내부 Kafka CLI `AWS_MSK_IAM` client smoke test 성공
- backend runtime IRSA topic bootstrap 권한 추가
- Kafka topic 5개 생성 및 목록 조회 성공
- Terraform addon `backend-config`에 Kafka bootstrap broker와 topic 환경변수 주입 완료
- GitOps backend Deployment에 `backend-config` Reloader annotation 적용 완료
- backend Pod rolling restart 후 `ticket-service`, `ticket-worker-service`, `waiting-room-service`에서 Kafka 환경변수 확인 완료
- `ticket-service` Outbox publisher가 `DOMAIN_EVENTS`를 기존 SQS와 Kafka `ticket.domain.events`에 dual publish하도록 구현 완료
- dev 환경에서 `RESERVATION_REQUESTED` 이벤트를 Kafka topic에서 직접 consume해 검증 완료
- `waiting-room-service`가 `WAITING_ENTERED`, `ACCESS_TOKEN_ISSUED`를 Kafka `waiting.operational.events`에 발행하도록 구현 완료
- `waiting-room-service`가 RDS connection 압력 변화 시 `capacity.signals`에 감속/중지/복구 이벤트를 발행하도록 구현 완료
- Kafka→S3 sink runner를 구현해 Kafka 이벤트를 기존 S3/Athena event lake로 적재 가능
- Capacity Advisor가 `capacity.signals`를 읽어 최근 감속/복구 신호를 리포트에 포함하도록 개선 완료
- GitHub Actions 기반 Capacity Advisor Slack report workflow 구현 완료
- Capacity Advisor가 `ticket-confirm-queue`와 `ticket-confirm-dlq`의 SQS 상태를 조회해 리포트와 Slack 메시지에 포함하도록 구현 완료
- Capacity Advisor가 Valkey CloudWatch metric을 조회해 CPU, memory, eviction, replication lag 상태를 리포트와 Slack 메시지에 포함하도록 구현 완료
- Capacity Advisor가 Athena event lake를 조회해 Kafka pipeline health를 리포트와 Slack 메시지에 포함하도록 구현 완료
- `seat-lock-service`가 `reservation.lifecycle.events`로 좌석 잠금 이벤트를 발행하도록 구현 완료
- Kafka→S3 sink runner가 `SEAT_LOCK_REQUESTED`, `SEAT_LOCKED`, `SEAT_LOCK_FAILED`, `SEAT_UNLOCKED`를 허용하도록 확장 완료
- SQS/worker 상태를 `SQS_WORKER_STATUS_RECORDED` audit event로 S3 event lake에 기록하도록 구현 완료
- Kafka S3 sink 완료를 `KAFKA_S3_SINK_COMPLETED` audit event로 기록하도록 구현 완료
- 실제 k6 부하테스트로 waiting/ticket 이벤트 표본을 생성하고 Kafka→S3→Athena→Capacity Advisor 재검증 완료

현재 확인된 bootstrap broker:

```text
boot-twqovxpi.c3.kafka-serverless.ap-northeast-2.amazonaws.com:9098
```

현재 확인된 cluster ARN:

```text
arn:aws:kafka:ap-northeast-2:740831361032:cluster/baselink-dev-event-streaming/5035b953-51c2-4766-a051-c8a458561832-s3
```

주의:

- MSK Serverless는 실제 비용이 발생할 수 있다.
- Kafka topic은 생성 완료했다.
- `ticket-service` domain event dual publish는 검증 완료했다.
- `waiting-room-service` Kafka publish와 Kafka→S3 sink는 구현 완료했다.
- Capacity Advisor Slack report는 workflow와 GitHub Repository Secret `CAPACITY_ADVISOR_SLACK_WEBHOOK_URL` 설정까지 완료했고, 실제 Slack 전송을 검증했다.
- ConfigMap 값은 Pod 시작 시점에 env로 주입되므로, ConfigMap 변경과 Reloader annotation 적용 순서가 엇갈린 경우에는 1회 rolling restart가 필요할 수 있다.

참고 문서:

- `docs/kafka-event-streaming-platform-design.md`
- `docs/kafka-event-streaming-phase1-runbook.md`
- `modules/msk-serverless/README.md`

## 6. 현재 진행 중인 작업

현재 진행 중인 개인 프로젝트 방향은 다음과 같다.

```text
Kafka/MSK Serverless 기반 이벤트 스트리밍 플랫폼을 구축해
대기열, 예매, 운영 이벤트를 공통 이벤트 로그로 모으고,
이를 S3/Athena/Capacity Advisor와 연결해
처리량 분석과 안전 입장량 추천을 고도화한다.
```

현재 단계:

```text
Phase 4 검증 완료
-> MSK Serverless 인프라 생성
-> EKS 내부 네트워크 접근 검증
-> AWS_MSK_IAM client smoke test 검증
-> Kafka topic 5개 생성과 목록 조회 검증
-> Backend/GitOps Kafka config 주입
-> backend Pod Kafka 환경변수 검증
-> ticket-service Outbox domain event Kafka dual publish 검증
-> waiting-room-service 대기열 운영 이벤트 Kafka publish 구현
-> capacity.signals 감속/복구 이벤트 Kafka publish 구현
-> Kafka to S3/Athena sink runner 구현
-> Capacity Advisor capacity.signals 리포트 반영
-> Capacity Advisor Slack report workflow 구현
-> Capacity Advisor SQS/Worker 상태 섹션 구현
-> Capacity Advisor Valkey/좌석 잠금 계층 상태 섹션 구현
-> Capacity Advisor Kafka pipeline health 섹션 구현
-> seat-lock-service 좌석 잠금 이벤트 Kafka publish 구현
-> Capacity Advisor seat-lock 이벤트 섹션 구현
-> infra.audit 1차 이벤트 기록 구현
-> 실제 k6 부하테스트 기반 Capacity Advisor 재검증 완료
```

다음 단계:

```text
부하테스트 결과 기반 운영 판단과 발표 정리
-> project-continuity-handoff 최신화
-> load-test-validation-plan 최신화
-> kafka-capacity-advisor-e2e-verification 최신화
-> 발표용 outline 최신화
-> Capacity Advisor 추천값 minimum floor / 최대 감소율 guardrail 구현
-> Read Replica 판단을 위한 조회 API 부하테스트 검토
-> RDS Proxy 판단을 위한 connection storm 부하테스트 검토
```

## 7. 남은 작업 우선순위

### P0: 실제 부하테스트 결과 문서화와 발표/인수인계 정리

목표:

- 현재 구현 상태를 다음 채팅방이 바로 이어받을 수 있게 정리한다.
- `aws-alerts` 장애/위험 알림과 Capacity Advisor 운영 리포트 알림을 분리해서 설명한다.
- 발표용 문서에 Kafka/Capacity Advisor/Slack 리포트/실제 부하 검증 내용을 반영한다.

대상 문서:

```text
docs/project-continuity-handoff.md
docs/load-test-validation-plan.md
docs/kafka-capacity-advisor-e2e-verification.md
docs/kafka-event-streaming-platform-design.md
docs/my-part-presentation-outline.md
```

왜 필요한가:

- 채팅 컨텍스트가 다시 가득 차도 작업 맥락을 잃지 않는다.
- 발표에서 “무엇을 만들었는가”뿐 아니라 “왜 필요했고 어떤 효과가 있는가”를 설명하기 쉽다.
- 실제 Terraform 코드와 운영 Runbook의 차이를 줄인다.

### 완료: Capacity Advisor Slack 실제 전송 검증

목표:

- GitHub Repository Secret `CAPACITY_ADVISOR_SLACK_WEBHOOK_URL`을 추가한다.
- `capacity-reports` 또는 `ops-reports` 채널로 실제 Slack 메시지가 오는지 확인한다.
- 발표 캡처용으로 GitHub Actions 실행 화면과 Slack 메시지를 확보한다.

결과:

- GitHub Repository Secret 설정 완료
- Capacity Advisor Slack Report workflow 수동 실행 성공
- Slack 메시지에 추천 입장량, 판단 근거, SQS/Worker, Valkey, seat-lock, Kafka pipeline health가 표시됨
- 이후 Webhook URL 노출 사고가 있었고 사용자가 새 Webhook으로 교체 완료

### 완료: Capacity Advisor 추천 산식 운영 guardrail 1차 적용

배경:

- 실제 부하테스트 후 Capacity Advisor는 `RECOMMENDED`, `HIGH` 신뢰도로 1명/분을 추천했다.
- 추천값이 낮은 이유는 DB 위험이 아니라 관측된 안정 예약 확정 처리량 2.0건/분에 안전계수 0.8과 `floor()`가 적용됐기 때문이다.
- 안정성 관점에서는 보수적이지만 실제 운영 정책으로 바로 적용하기에는 너무 낮을 수 있다.

적용한 개선:

- minimum floor 정책 추가: 기본 10명/분
- 직전 정책 대비 최대 감소율 guardrail 추가: 기본 50%
- raw 추천값과 운영 guardrail 적용값을 리포트 계산 근거에 함께 표시
- GitHub Actions에서 `CAPACITY_ADVISOR_MINIMUM_POLICY_FLOOR`, `CAPACITY_ADVISOR_MAX_DECREASE_PERCENT` Repository Variables로 조정 가능

동일 부하테스트 입력 기준 결과:

```text
v1 raw recommendation: 1.6명/분
v1 recommended policy: 1명/분
v2 policy floor guardrail: 20명/분
v2 recommended policy: 20명/분
```

남은 고도화:

- 예매 오픈 규모/목표 대기시간을 반영한 policy profile 추가
- `testRunId` 또는 시간 범위 필터로 실제 부하테스트 구간만 분리 분석

효과:

- 심사위원 질문인 “1명/분이면 사용자 경험이 너무 나쁜 것 아닌가?”에 설득력 있게 답할 수 있다.
- Capacity Advisor를 자동 제어기가 아니라 운영 판단 보조 도구로 안전하게 설명할 수 있다.

### 완료: Capacity Advisor 리포트 확장 1차 - SQS/Worker 상태

목표:

- SQS backlog, DLQ, worker 처리 지연을 `infra.audit.events` 또는 리포트 섹션으로 추가한다.
- Capacity Advisor가 단순 입장량 추천을 넘어 예매 처리 파이프라인 상태까지 보여주게 한다.

구현 결과:

- `tools/ticket_capacity_advisor.py`에 `SqsWorkerSummary`를 추가했다.
- 기본 대상은 `ticket-confirm-queue`와 `ticket-confirm-dlq`다.
- SQS queue attributes를 조회해 `HEALTHY`, `PROCESSING`, `BACKLOG`, `DELAYED`, `DLQ_DETECTED`, `UNKNOWN`으로 상태를 표시한다.
- Markdown 리포트에 `SQS/Worker 처리 상태` 섹션을 추가했다.
- Slack payload에 `SQS/Worker 상태` 섹션을 추가했다.
- GitHub Actions workflow에서 SQS queue name과 threshold를 Repository Variables로 조정할 수 있게 했다.

검증:

```text
python -B -m unittest discover tools\tests
28 tests OK
```

추천 이벤트:

```text
SQS_BACKLOG_DETECTED
SQS_BACKLOG_RECOVERED
SQS_DLQ_DETECTED
WORKER_PROCESSING_DELAYED
WORKER_RECOVERED
```

효과:

- 추천 입장량이 낮게 나온 이유가 DB 때문인지, worker/SQS 때문인지 구분할 수 있다.
- `aws-alerts`의 장애 알림과 `capacity-reports`의 운영 판단 리포트가 연결된다.

남은 확장:

- 현재는 리포트 실행 시점의 SQS 현재 상태를 조회하는 방식이다.
- 다음 단계에서 Kafka `infra.audit.events`에 `SQS_BACKLOG_DETECTED`, `SQS_DLQ_DETECTED` 같은 이벤트를 기록하면 시간대별 처리 지연 이력까지 분석할 수 있다.

### 완료: Capacity Advisor 리포트 확장 2차 - Valkey/좌석 잠금 계층 상태

목표:

- Valkey 운영 상태를 Capacity Advisor 판단 근거에 추가한다.
- Valkey CPU, memory, eviction 알림과 좌석 lock 실패를 함께 해석할 수 있게 한다.

구현 결과:

- `tools/ticket_capacity_advisor.py`에 `ValkeyStatusSummary`를 추가했다.
- CloudWatch `AWS/ElastiCache`에서 `EngineCPUUtilization`, `DatabaseMemoryUsagePercentage`, `Evictions`, `ReplicationLag`를 조회한다.
- 조회 결과를 `HEALTHY`, `CPU_HIGH`, `MEMORY_HIGH`, `EVICTIONS_DETECTED`, `REPLICATION_LAG`, `UNKNOWN`으로 분류한다.
- Markdown 리포트에 `Valkey/좌석 잠금 계층 상태` 섹션을 추가했다.
- Slack payload에 `Valkey/좌석 잠금 계층 상태` 섹션을 추가했다.
- GitHub Actions workflow에서 Valkey cluster id와 threshold를 Repository Variables로 조정할 수 있게 했다.

검증:

```text
python -B -m unittest discover tools\tests
28 tests OK
```

효과:

- 추천 입장량이 낮거나 운영 위험 신호가 있을 때 DB/SQS뿐 아니라 Valkey 상태까지 함께 볼 수 있다.
- eviction 발생 시 access token, 좌석 lock 같은 TTL key 유실 위험을 운영 리포트에서 바로 확인할 수 있다.
- Kafka 개인 프로젝트가 대기열 처리량 계산을 넘어 좌석 잠금/캐시 계층 안정성까지 확장된다.

남은 확장:

- 현재는 리포트 실행 시점의 Valkey 현재 상태를 CloudWatch에서 조회하는 방식이다.
- 다음 단계에서 `seat-lock-service`가 아래 이벤트를 Kafka로 발행하면 좌석 잠금 성공률과 실패 원인까지 시간대별로 분석할 수 있다.

추천 이벤트:

```text
SEAT_LOCK_REQUESTED
SEAT_LOCKED
SEAT_LOCK_FAILED
SEAT_LOCK_EXPIRED
SEAT_UNLOCKED
```

효과:

- Kafka 개인 프로젝트가 대기열 처리량 계산에만 머무르지 않고 좌석 선점/Valkey 안정성까지 확장된다.
- 심사위원에게 인프라 관점의 이벤트 스트리밍 활용 사례로 설명하기 좋다.

### 완료: Kafka 파이프라인 자체 상태 리포트

목표:

- Kafka producer 실패, sink 지연, invalid event, S3 적재 완료 여부를 리포트에 포함한다.

구현 결과:

- `tools/ticket_capacity_advisor.py`에 `KafkaPipelineHealthSummary`를 추가했다.
- Athena `ticket_events` event lake를 조회해 전체 이벤트 수, 최신 이벤트 시각, producer별 count, event type별 count를 계산한다.
- 기본 기대 producer는 `ticket-service`, `waiting-room-service`다.
- 기본 기대 event type은 `WAITING_ENTERED`, `ACCESS_TOKEN_ISSUED`, `RESERVATION_REQUESTED`, `RESERVATION_CONFIRMED`다.
- 누락 producer/event type이 있으면 `PARTIAL`로 표시한다.
- event lake에 이벤트가 없으면 `NO_EVENTS`, 최신 이벤트가 오래됐으면 `STALE`로 표시한다.
- `infra.audit.events`가 `KAFKA_PRODUCE_FAILED`, `KAFKA_EVENT_INVALID`, `KAFKA_EVENT_SKIPPED`, `KAFKA_S3_SINK_COMPLETED`를 적재하면 같은 섹션에서 count를 보여줄 수 있다.
- Markdown 리포트와 Slack payload에 `Kafka 파이프라인 상태` 섹션을 추가했다.

검증:

```text
python -B -m unittest discover tools\tests
34 tests OK
```

추천 이벤트:

```text
KAFKA_PRODUCE_FAILED
KAFKA_S3_SINK_DELAYED
KAFKA_EVENT_SKIPPED
KAFKA_EVENT_INVALID
KAFKA_S3_SINK_COMPLETED
```

효과:

- Athena 표본 부족이 실제 트래픽 부족인지, Kafka/S3 적재 지연인지 구분할 수 있다.
- Kafka를 “도입했다”가 아니라 “운영 가능한 이벤트 파이프라인으로 관리한다”고 설명할 수 있다.

### P3: Capacity Advisor 트리거 고도화

좋은 방향:

```text
예매 오픈 30분 전
-> 이전 이벤트 기반 Capacity Advisor 실행
-> Slack으로 추천 입장량 전송

예매 진행 중 5분마다
-> 최근 5분 이벤트와 RDS 상태 분석
-> 위험하면 Slack 전송

ADMISSION_THROTTLE_APPLIED 발생
-> 즉시 Slack 알림

SQS DLQ 발생
-> 즉시 Slack 알림
```

구현 방향:

- 단기: GitHub Actions `workflow_dispatch`와 schedule을 활용한다.
- 중기: EventBridge schedule을 예매 오픈 시간과 연결한다.
- 장기: Kafka consumer 또는 Lambda가 `capacity.signals`, DLQ 이벤트를 감지해 즉시 Slack으로 전송한다.

### 완료: Kafka topic bootstrap

목표:

- 아래 topic을 실제 Kafka cluster에 생성한다.

```text
ticket.domain.events
waiting.operational.events
reservation.lifecycle.events
capacity.signals
infra.audit.events
```

추천 구현:

- Kubernetes Job으로 `backend-runtime` service account를 사용한다.
- Kafka CLI와 AWS MSK IAM auth jar를 사용한다.
- topic 생성 후 `kafka-topics.sh --list`로 검증한다.

결과:

- 2026-06-25 기준 topic 5개 생성 완료
- `KAFKA_TOPIC_LIST_FINAL_OK` 확인
- GitOps `kafka-topic-bootstrap` PostSync hook manifest는 main에 반영
- 최초 sync에서 hook Job 실행 흔적이 남지 않아 동일 명령을 임시 Pod에서 수동 실행해 topic 생성을 완료

생성 완료 topic:

```text
capacity.signals
infra.audit.events
reservation.lifecycle.events
ticket.domain.events
waiting.operational.events
```

### 완료: Backend/GitOps Kafka config 주입

목표:

- Terraform addon `backend-config`에 Kafka 접속 정보와 topic 이름을 추가한다.
- GitOps Deployment가 `backend-config` 변경을 감지해 rolling restart되도록 Reloader annotation을 보강한다.
- Backend producer 코드가 들어가기 전에 공통 환경변수 이름을 고정한다.

적용한 PR:

```text
Terraform: feat/kafka-backend-config
GitOps:    feat/backend-config-reloader
```

추가 완료 환경변수:

```text
KAFKA_ENABLED=true
KAFKA_BOOTSTRAP_SERVERS=boot-twqovxpi.c3.kafka-serverless.ap-northeast-2.amazonaws.com:9098
KAFKA_SECURITY_PROTOCOL=SASL_SSL
KAFKA_SASL_MECHANISM=AWS_MSK_IAM
KAFKA_TOPIC_TICKET_DOMAIN_EVENTS=ticket.domain.events
KAFKA_TOPIC_WAITING_OPERATIONAL_EVENTS=waiting.operational.events
KAFKA_TOPIC_RESERVATION_LIFECYCLE_EVENTS=reservation.lifecycle.events
KAFKA_TOPIC_CAPACITY_SIGNALS=capacity.signals
KAFKA_TOPIC_INFRA_AUDIT_EVENTS=infra.audit.events
```

검증 결과:

- Terraform Apply Dev 성공
- GitOps `backend-config` Reloader annotation 반영
- 전체 backend Deployment Ready 상태 확인
- `ticket-service`, `ticket-worker-service`, `waiting-room-service`에서 `KAFKA_*` 환경변수 확인
- ConfigMap 변경 후 이미 떠 있던 Pod는 env가 자동 갱신되지 않으므로, 2026-06-25에 backend Deployment 9개를 1회 rolling restart해 최신 `backend-config`를 반영했다.

검증 명령:

```bash
kubectl get configmap backend-config -n baselink-dev -o yaml
kubectl exec -n baselink-dev deploy/ticket-service -- sh -c "env | sort | grep KAFKA"
kubectl exec -n baselink-dev deploy/ticket-worker-service -- sh -c "env | sort | grep KAFKA"
kubectl exec -n baselink-dev deploy/waiting-room-service -- sh -c "env | sort | grep KAFKA"
```

### 완료: ticket-service Outbox publisher dual publish

목표:

- 기존 SQS 발행은 유지한다.
- Kafka에도 같은 event envelope를 발행한다.
- Kafka publish 실패가 예약/예매 핵심 transaction을 실패시키지 않도록 한다.

중요 원칙:

```text
SQS는 안정 처리 경로,
Kafka는 이벤트 스트리밍/분석 경로다.
```

구현 결과:

- Backend PR `feat/ticket-outbox-kafka-dual-publish` merge 완료
- `ticket-service` image `f67032bb2c2b1b9d0e282ad7a3a1b10e301edbad` dev 배포 완료
- `DOMAIN_EVENTS` 목적지 Outbox event만 Kafka `ticket.domain.events`에 보조 발행
- `TICKET_CONFIRM` 명령 이벤트는 기존 SQS `ticket-confirm-queue` 경로 유지
- Kafka 실패는 `ticket_kafka_publish_total{result="failure"}` metric과 log로 남기고 Outbox 자체는 SQS 성공 기준으로 `PUBLISHED` 처리

검증 결과:

```text
reservationId=4715
eventType=RESERVATION_REQUESTED
topic=ticket.domain.events
producer=ticket-service
```

Kafka consume 결과:

```json
{"gameId": 1, "eventId": "e9104823-50a2-4cca-b9bb-f63dc268f45a", "payload": {"seatId": 1783270886, "status": "PENDING", "reservationId": 4715}, "traceId": null, "userKey": null, "producer": "ticket-service", "eventType": "RESERVATION_REQUESTED", "occurredAt": "2026-06-26T02:28:09.689020218Z", "aggregateId": "4715", "aggregateType": "RESERVATION", "schemaVersion": 1}
```

트러블슈팅 기록:

- consumer smoke test 중 `GroupAuthorizationException` 발생
  - 원인: consumer group 권한은 있었지만 topic `ReadData` 권한이 부족했다.
  - 조치: `kafka-cluster:ReadData`, `DescribeTopic`을 topic ARN에 추가했다.
- producer smoke test 중 `ClusterAuthorizationException` 발생
  - 원인: Spring Kafka producer가 `enable.idempotence=true`로 동작하면서 cluster-level `WriteDataIdempotently` 권한이 필요했다.
  - 조치: `kafka-cluster:WriteDataIdempotently`를 MSK cluster ARN에 추가했다.

### 완료: waiting-room-service 이벤트 publish

목표:

- 대기열 진입, 입장권 발급, admission decision 이벤트를 Kafka에 발행한다.
- 안전 입장량 추천과 연결할 데이터를 확보한다.

### 완료: Kafka to S3/Athena sink

목표:

- Kafka 이벤트를 S3 partitioned JSON으로 적재한다.
- 기존 Athena/Capacity Advisor 분석 흐름과 연결한다.

선택지:

- dev에서는 custom consumer가 단순하다.
- 시간이 많으면 Kafka Connect S3 Sink도 검토 가능하다.

### P3: Realtime Capacity Advisor 고도화

목표:

- 최근 1분/5분 처리량을 Kafka 이벤트 기반으로 계산한다.
- DB 여유율과 함께 안전 입장량 추천을 더 정교하게 만든다.

## 8. 새 채팅방에서 우선 확인할 파일

새 채팅방에서 작업을 이어갈 때는 아래 순서로 확인하면 된다.

1. 전체 현황과 우선순위
   - `docs/project-continuity-handoff.md`
   - `docs/data-async-status-roadmap.md`

2. Kafka 개인 프로젝트
   - `docs/kafka-event-streaming-platform-design.md`
   - `docs/kafka-event-streaming-phase1-runbook.md`
   - `modules/msk-serverless/README.md`

3. Outbox/Event Pipeline
   - `docs/ticket-reliability-event-outbox-design.md`
   - `capacity-reports/game-1-capacity.md`

4. RDS/DB credential
   - `docs/application-database-credential-design.md`
   - `docs/application-db-credential-cutover-runbook.md`
   - `docs/db-connection-pool-strategy.md`

5. Backup/DR
   - `docs/aws-backup-design.md`
   - `docs/aws-backup-restore-runbook.md`
   - `docs/disaster-recovery-strategy.md`
   - `docs/disaster-recovery-presentation-summary.md`
   - `docs/tokyo-dr-compute-cutover-runbook.md`

6. 운영 알림과 Runbook
   - `docs/ops-alarm-runbook.md`
   - `docs/dev-iac-pipeline.md`

## 9. 다음 채팅방 시작용 프롬프트 예시

다른 채팅방에서 이어갈 때는 다음처럼 요청하면 좋다.

```text
terraform/docs/project-continuity-handoff.md를 먼저 읽고 현재 작업 맥락을 복구해줘.
나는 Baselink 프로젝트에서 데이터 안정성/DR/비동기 처리/Kafka 이벤트 스트리밍 파트를 담당하고 있어.
현재 MSK Serverless, Kafka topic bootstrap, Backend/GitOps Kafka config 주입, ticket-service/waiting-room-service Kafka publish, Kafka→S3 sink, Capacity Advisor capacity.signals 리포트, Slack report workflow까지 구현됐어.
다음 작업은 문서 최신화 이후 Capacity Advisor 리포트에 SQS/Worker 상태, 좌석 잠금/Valkey 이벤트, Kafka 파이프라인 자체 상태를 추가하는 방향으로 이어가면 돼.
작업 후에는 항상 왜 이 작업을 했는지와 어떤 결과를 얻는지 쉽게 설명해줘.
PR 생성은 내가 할 테니 commit/push까지만 해줘.
```

## 10. 운영상 주의사항

### 10.1 Terraform source of truth 주의

MSK Serverless 생성 중 다음 문제가 있었다.

```text
로컬 terraform.tfvars: enable_kafka_event_streaming = true
GitHub DEV_INFRA_TFVARS: false 또는 값 없음
```

이 상태에서 로컬 apply로 MSK를 만들면 GitHub Actions apply가 Kafka를 삭제했다.

교훈:

- 실제 dev infra 상태를 유지하려면 GitHub `DEV_INFRA_TFVARS`와 로컬 `terraform.tfvars` 값을 맞춘다.
- 비용 리소스를 켜고 끌 때는 GitHub Actions의 in-progress apply가 없는지 확인한다.

### 10.2 MSK 비용 주의

MSK Serverless는 실제 비용이 발생할 수 있다.

발표나 검증이 끝난 뒤 장기간 사용하지 않는다면 다음 값을 false로 내려서 비활성화할 수 있다.

```hcl
enable_kafka_event_streaming = false
```

단, 비활성화하면 MSK cluster와 Kafka IAM policy가 삭제되고, Kafka runtime Secret은 삭제 예약 상태가 된다.

### 10.3 EKS API 접근 IP 주의

와이파이가 바뀌어 로컬 IP가 변경되면 kubectl이 실패할 수 있다.

해결 방법:

1. `terraform/env/dev/infra/terraform.tfvars`의 `eks.public_access_cidrs`에 현재 public IP `/32` 추가
2. GitHub `DEV_INFRA_TFVARS`에도 동일하게 반영
3. Terraform Apply Dev 실행
4. `kubectl get nodes`로 확인

최근 사용한 IP:

```text
218.237.104.164/32
121.153.133.126/32
```

### 10.4 GitHub Actions와 로컬 apply 충돌 주의

Terraform apply 중 state lock이 잡힐 수 있다.

확인 방법:

- GitHub Actions `Terraform Apply Dev`가 in-progress인지 확인한다.
- 로컬 apply가 lock 에러를 내면 기다렸다가 재시도한다.
- 강제 unlock은 마지막 수단으로만 고려한다.

## 11. 발표용 핵심 메시지 모음

### 데이터 안정성

```text
RDS는 Multi-AZ와 PITR, AWS Backup을 함께 사용했고,
실제 복원 DB에 접속해 Flyway 이력과 핵심 테이블을 검증했습니다.
```

### Connection 보호

```text
Pod를 늘리는 것만으로는 트래픽을 해결할 수 없기 때문에,
Spring/Python/KEDA의 DB connection budget을 먼저 잡고
RDS 상태에 따라 대기열 입장량을 자동 감속하도록 설계했습니다.
```

### SQS와 Kafka 역할 분리

```text
SQS는 반드시 처리해야 하는 예매 명령을 안정적으로 처리하는 큐이고,
Kafka는 일어난 이벤트를 여러 consumer가 재사용하는 공통 이벤트 로그입니다.
```

### Kafka 개인 프로젝트

```text
MSK Serverless를 통해 EKS 내부에서 IAM 인증으로 접근 가능한 이벤트 스트리밍 기반을 만들었고,
이후 대기열·예매·운영 이벤트를 Kafka로 모아 Capacity Advisor와 장애 분석에 활용할 수 있게 확장 중입니다.
```

### DR

```text
서울 리전 장애를 가정해 도쿄 리전에 백업과 Pilot Light 네트워크를 준비했고,
도쿄 recovery point에서 private RDS 복원까지 검증했습니다.
```

## 12. 업데이트 규칙

앞으로 큰 작업이 끝나면 이 문서에서 최소한 아래 항목을 갱신한다.

- `4. 현재 전체 구현 상태 요약`
- `5. 최근 완료한 핵심 작업`
- `6. 현재 진행 중인 작업`
- `7. 남은 작업 우선순위`
- `10. 운영상 주의사항`

작업이 Kafka 관련이면 다음 문서도 함께 갱신한다.

- `docs/kafka-event-streaming-platform-design.md`
- `docs/kafka-event-streaming-phase1-runbook.md`

작업이 Backup/DR 관련이면 다음 문서도 함께 갱신한다.

- `docs/disaster-recovery-presentation-summary.md`
- `docs/disaster-recovery-strategy.md`
- `docs/aws-backup-restore-runbook.md`

작업이 Outbox/Capacity 관련이면 다음 문서도 함께 갱신한다.

- `docs/ticket-reliability-event-outbox-design.md`
- `docs/data-async-status-roadmap.md`
- `capacity-reports/*.md`

## 13. 2026-06-28 부하테스트 문서화 업데이트

이 섹션은 실제 부하테스트 실행 전 작성한 기준 문서화 기록이다. 이후 2026-06-29에 부하테스트 EC2 접속 정보가 준비되어 실제 k6 실행과 Capacity Advisor 재검증까지 완료했다. 최신 결과는 이 문서의 마지막 `2026-06-29 추가 handoff: 실제 부하테스트 기반 Capacity Advisor 재검증 완료` 섹션과 `docs/load-test-validation-plan.md`를 기준으로 본다.

당시에는 로컬에 Ansible 부하테스트 EC2 접속 정보인 `ansible/inventory.ini`가 없었으므로, 실제 실행 전에는 다음 정보가 필요했다.

```text
부하테스트 EC2 Public IP
SSH user
SSH private key path
```

당시에는 부하테스트 실행 전에 결과 해석 기준을 먼저 정리했다.

추가된 문서:

```text
docs/load-test-validation-plan.md
```

이 문서는 다음 내용을 한 번에 연결한다.

- RDS connection budget 검증
- 대기열 자동 감속 검증
- SQS worker와 DLQ 검증
- Valkey 대기열/좌석 잠금 검증
- Kafka 이벤트 발행 검증
- Kafka -> S3/Athena 적재 검증
- Capacity Advisor 추천값 검증
- RDS Proxy 도입 판단 기준
- Read Replica 도입 판단 기준
- 부하테스트 결과 기록 템플릿

다음 채팅방에서 부하테스트 작업을 이어갈 때는 먼저 아래 문서를 함께 확인한다.

```text
terraform/docs/load-test-validation-plan.md
ansible/docs/capacity-advisor-loadtest-verification.md
```

## 14. 2026-06-28 발표/PPT 초안 업데이트

팀 발표 자료는 각자 담당 파트를 PPT로 만든 뒤 합치는 방향이다.

Data & Async / Reliability / DR / Kafka 개인 프로젝트 담당 파트의 발표 구성을 아래 문서로 정리했다.

```text
docs/my-part-presentation-outline.md
```

이 문서에는 다음 내용이 포함되어 있다.

- 내 담당 파트 한 문장 요약
- 발표 핵심 메시지
- 전체 아키텍처 설명 흐름
- 10장 기준 PPT 슬라이드 구성
- 6장 축약 버전
- 캡처 후보 목록
- 멘토 설명용 3분 버전
- 예상 질문과 답변
- 최종 한 장 요약 문장

다음에 PPT 파일을 만들 때는 이 문서를 기준으로 슬라이드 원고를 옮기고, AWS 콘솔/코드/검증 결과 캡처를 붙이면 된다.

## 15. 2026-06-29 운영 알림/Capacity Advisor/Kafka 리포트 최신화

이번 업데이트의 목적은 현재 구현 상태를 발표와 다음 채팅방 인수인계 기준으로 맞추는 것이다.

정리한 방향:

```text
aws-alerts
-> 장애/위험 감지용 즉시 알림

capacity-reports 또는 ops-reports
-> Capacity Advisor 운영 의사결정용 리포트
```

`aws-alerts`로 가는 것으로 정리한 알림:

- RDS CPU, storage, connections, memory
- Valkey engine CPU, memory, evictions, replication lag
- SQS `ticket-confirm-queue` backlog/DLQ
- SQS `ticket-domain-events` backlog/DLQ
- AWS Backup backup/copy/restore failure
- CloudFront/API ALB WAF blocked/counted requests

Capacity Advisor Slack report 현재 상태:

- GitHub Actions workflow 구현 완료
- 매일 09:00 KST schedule 실행 가능
- `workflow_dispatch` 수동 실행 가능
- RDS `DatabaseConnections` 최근 값을 CloudWatch에서 조회 가능
- Athena 기반 Capacity Advisor JSON/Markdown 생성
- Slack payload에 추천 입장량, DB 상태, 표본 수, 산출 지표, 판단 근거, 최근 `capacity.signals` 포함
- SQS/Worker backlog, DLQ 상태 포함
- Valkey engine CPU, memory, evictions, replication lag 상태 포함
- Kafka pipeline health 포함
- `CAPACITY_ADVISOR_SLACK_WEBHOOK_URL` Secret 추가 완료, 실제 Slack 전송 검증 완료
- Secret이 없을 때는 workflow가 dry-run payload를 출력하는 fallback 구조 유지

Secret 관련 주의:

```text
GitHub Repository Secret CAPACITY_ADVISOR_SLACK_WEBHOOK_URL은 추가 완료했다.
Webhook URL이 노출되면 즉시 Slack에서 새 URL을 발급해 Secret을 교체한다.
```

2026-06-29 실제 서비스 표본 재검증:

- `kubectl get nodes`와 서비스 deployment/pod 상태 확인 완료
- `waiting-room-service`, `ticket-service`, `seat-lock-service`, `ticket-worker-service` Ready 확인
- `tools/run_kafka_capacity_flow.py` 1건 smoke test 성공
  - reservationId `6246`
- `tools/run_kafka_capacity_flow.py` 20건 표본 생성 성공
  - requested `20`
  - succeeded `20`
  - failed `0`
  - reservationId `6247~6266`
- Capacity Advisor 전체 리포트 로컬 실행 결과
  - samples: waiting/access/requested/confirmed 모두 `21`
  - SQS/Worker: `HEALTHY`
  - Valkey: `HEALTHY`
  - Kafka pipeline: `HEALTHY`
  - Kafka event lake total events: `84`
  - Advisor status: `RECOMMENDED`
  - confidence: `MEDIUM`
  - recommended policy: `1명/분`
  - 이유: 실제 순차 smoke 표본에서 안정 예약 확정 처리량이 `1.0건/분`으로 관측되어 보수적으로 추천했다.
- GitHub Actions `Capacity Advisor Slack Report` 수동 실행과 Slack 메시지 확인 완료
  - workflow run: `https://github.com/baselink-msa/terraform/actions/runs/28355999346`
  - Slack 메시지에 `RECOMMENDED`, `MEDIUM`, 추천 정책 `1명/분`, 산출 지표, SQS `HEALTHY`, Valkey `HEALTHY`, Kafka pipeline `HEALTHY` 표시 확인

Kafka sink runner 보강:

- 기존 runner는 임시 consumer Pod가 `ContainerCreating`인 상태에서 바로 `kubectl logs`를 호출해 실패할 수 있었다.
- `kubectl wait --for=condition=Ready`를 추가해 Pod Ready 이후 logs를 조회하도록 수정했다.
- Ready 실패 시 `kubectl get pod`와 `kubectl describe pod`를 함께 보여주도록 개선했다.

Kafka 리포트 확장 후보:

1. SQS/Worker 처리 상태 - 1차 구현 완료
   - backlog, DLQ, worker delay, recovery
   - Capacity Advisor 추천값의 운영 근거로 사용

2. 좌석 잠금/Valkey 상태 - CloudWatch 기반 1차 구현 완료
   - Valkey engine CPU, memory, evictions, replication lag
   - 좌석 lock/access token 같은 TTL key 유실 위험 해석

3. 좌석 잠금 Kafka 이벤트 - 1차 구현 완료
   - seat lock requested/locked/failed/unlocked
   - expired 이벤트는 Valkey TTL 만료 감지 구조를 붙인 뒤 후속 구현
   - Valkey 부하와 좌석 선점 실패 상관관계 분석

4. Kafka 파이프라인 자체 상태 - Athena event lake 기반 1차 구현 완료
   - producer failure, sink delay, invalid event, sink completed
   - 표본 부족 원인을 실제 트래픽 부족과 파이프라인 지연으로 구분

향후 트리거 고도화 방향:

```text
예매 오픈 30분 전
-> 이전 이벤트 기반 Capacity Advisor 실행
-> Slack으로 추천 입장량 전송

예매 진행 중 5분마다
-> 최근 5분 이벤트와 RDS 상태 분석
-> 위험하면 Slack 전송

ADMISSION_THROTTLE_APPLIED 발생
-> 즉시 Slack 알림

SQS DLQ 발생
-> 즉시 Slack 알림
```

다음 작업 추천:

```text
1. seat-lock-service Kafka 이벤트 dev consume/S3/Athena 검증
2. SQS/Worker 상태를 Kafka `infra.audit.events` 이벤트 이력으로 확장
3. 실제 Kafka sink 실행 결과를 `infra.audit.events`로 적재
4. 실제 부하테스트 결과로 Capacity Advisor 추천값 보정
5. 발표용 Slack 메시지, Actions run, Athena/S3 event lake 캡처 정리
```

## 2026-06-29 추가 handoff: seat-lock Kafka E2E 검증 완료

현재 채팅에서 이어서 수행한 작업:

- `seat-lock-service`의 Kafka 이벤트 발행이 실제 dev Pod에 반영되어 있는지 확인했다.
- 기존 dev Deployment가 과거 이미지로 떠 있어 GitOps main의 desired image인 `25d421d3f7b061faaef1750204c55bba02f5d855`로 수동 정렬했다.
- `SeatLockKafkaPublisher`가 app jar에 포함된 것을 확인했다.
- seat-lock API를 호출해 좌석 잠금 성공, 중복 잠금 실패, 잠금 해제 흐름을 만들었다.
- Kafka publish metric에서 `reservation.lifecycle.events` 발행 성공 5건, 실패 0건을 확인했다.
- Kafka S3 sink runner로 `seat-lock-service` 이벤트를 S3에 적재했다.

S3 sink 결과:

```json
{
  "accepted": 5,
  "written": 5,
  "skipped": 0,
  "invalid": 0
}
```

중간에 발견한 문제:

- S3에는 seat-lock 이벤트가 적재됐지만 Athena 조회 결과가 0건이었다.
- 원인은 Glue `ticket_events` table의 partition projection enum에 seat-lock 이벤트 타입이 없었기 때문이다.
- `projection.event_type.values`에 없는 이벤트 타입은 S3에 파일이 있어도 Athena가 partition을 스캔하지 않는다.

수정 완료:

- Terraform PR `fix/ticket-events-projection-seat-lock`에서 Glue projection과 Lambda writer 허용 event type을 확장했다.
- 추가된 event type:
  - `ADMISSION_THROTTLE_APPLIED`
  - `ADMISSION_STOP_APPLIED`
  - `ADMISSION_THROTTLE_RECOVERED`
  - `SEAT_LOCK_REQUESTED`
  - `SEAT_LOCKED`
  - `SEAT_LOCK_FAILED`
  - `SEAT_UNLOCKED`
- PR merge 후 `Terraform Apply Dev`의 infra 단계가 성공했고, 실제 Glue projection 반영을 확인했다.

Athena 최종 검증:

| event_type | producer | count |
| --- | --- | ---: |
| `SEAT_LOCK_REQUESTED` | `seat-lock-service` | 2 |
| `SEAT_LOCKED` | `seat-lock-service` | 1 |
| `SEAT_LOCK_FAILED` | `seat-lock-service` | 1 |
| `SEAT_UNLOCKED` | `seat-lock-service` | 1 |

이 작업을 수행한 이유:

- 기존 Capacity Advisor는 대기열 진입, 입장권 발급, 예약 요청, 예약 확정 이벤트 중심이었다.
- 좌석 잠금은 Valkey를 사용하는 핵심 실시간 계층이므로, 이 흐름도 이벤트로 남겨야 예매 병목과 실패 원인을 더 넓게 분석할 수 있다.
- Kafka를 단순히 “안전 입장량 계산용”으로만 쓰는 것이 아니라, 여러 서비스의 운영 이벤트를 수집하는 인프라 이벤트 플랫폼으로 확장하는 근거가 된다.

얻은 결과:

- seat-lock 이벤트가 Kafka, S3, Athena까지 end-to-end로 검증되었다.
- 이후 발표에서 “Kafka를 대기열 계산에만 쓴 것이 아니라, 좌석 잠금/Valkey 계층까지 관측 가능한 이벤트 플랫폼으로 확장했다”고 설명할 수 있다.
- 후속 작업으로 좌석 잠금 성공률, 실패율, 해제율, lock 잔류 의심 이벤트를 Capacity Advisor 리포트에 추가할 수 있다.

다음 우선순위:

```text
P0. 발표/멘토 설명용 검증 문서 최신화와 캡처 목록 정리
P0. 실제 부하테스트 결과로 Capacity Advisor 추천값 보정
P1. SQS/Worker 상태를 `infra.audit.events` 이벤트 이력으로 적재
P1. Kafka S3 sink 실행 결과를 `infra.audit.events`로 적재
P1. seat-lock 이벤트 기반 좌석 잠금 성공률/실패율 리포트 섹션 추가
P2. ADMISSION_THROTTLE_APPLIED, SQS DLQ 발생 시 event-driven Slack 알림
P2. 예매 오픈 30분 전/예매 중 5분마다 Capacity Advisor 자동 실행
```

## 2026-06-29 추가 handoff: Capacity Advisor seat-lock/infra audit 확장

이번 추가 작업 목표:

- Capacity Advisor 리포트에 seat-lock 이벤트 상태를 붙여 Valkey/좌석 잠금 계층을 더 구체적으로 설명한다.
- `infra.audit.events` 방향의 1차 기반을 만들어 Kafka/SQS 파이프라인 자체 상태도 이벤트 이력으로 남길 수 있게 한다.

구현 내용:

- `tools/ticket_capacity_advisor.py`
  - `SeatLockSummary` 추가
  - Athena `ticket_events`에서 seat-lock 이벤트 집계
  - JSON/Markdown 리포트에 `seatLock` 섹션 추가
  - 상태값: `HEALTHY`, `COMPETITION_DETECTED`, `FAILURE_RATE_HIGH`, `NO_EVENTS`
- `tools/slack_capacity_advisor_notify.py`
  - Slack 메시지에 `좌석 잠금 이벤트 상태` 섹션 추가
  - `FAILURE_RATE_HIGH`일 때 warning emoji 적용
- `.github/workflows/capacity-advisor-slack.yml`
  - `CAPACITY_ADVISOR_SEAT_LOCK_PRODUCER`
  - `CAPACITY_ADVISOR_SEAT_LOCK_FAILURE_RATE_THRESHOLD_PERCENT`
  - 위 Repository Variables를 사용할 수 있도록 연결
- `modules/ticket-event-writer`
  - Glue projection과 Lambda writer 허용 event type에 infra audit 이벤트 추가
  - payload struct에 audit/SQS snapshot 필드 추가
- `tools/kafka_s3_sink.py`
  - `--emit-audit-event` 옵션 추가
  - sink 실행 완료를 `KAFKA_S3_SINK_COMPLETED` 이벤트로 기록 가능
- `tools/record_sqs_worker_audit.py`
  - SQS 원본 큐/DLQ 상태를 조회해 audit event로 기록
  - 상태에 따라 `SQS_WORKER_STATUS_RECORDED`, `SQS_BACKLOG_DETECTED`, `SQS_DLQ_DETECTED` 사용

실제 dev 확인:

```json
{
  "seatLock": {
    "status": "COMPETITION_DETECTED",
    "requested": 2,
    "locked": 1,
    "failed": 1,
    "unlocked": 1,
    "success_rate_percent": 50.0,
    "failure_rate_percent": 50.0,
    "unlock_rate_percent": 100.0,
    "latest_event_type": "SEAT_UNLOCKED"
  }
}
```

해석:

- `COMPETITION_DETECTED`는 장애가 아니라 중복 잠금 시도/좌석 선점 경쟁이 관측됐다는 의미다.
- 현재 표본은 E2E 검증용으로 일부러 중복 잠금 실패를 만들었기 때문에 실패율이 50%로 보인다.
- 실제 부하테스트에서는 이 값을 좌석 잠금 경쟁률과 Valkey 안정성 판단 근거로 사용할 수 있다.

검증:

```text
python -B -m unittest tools.tests.test_ticket_capacity_advisor tools.tests.test_slack_capacity_advisor_notify tools.tests.test_kafka_s3_sink tools.tests.test_record_sqs_worker_audit modules.ticket-event-writer.tests.test_handler
```

결과:

```text
Ran 48 tests
OK
```

다음 작업 추천:

```text
1. 이 브랜치 PR merge 후 Terraform Apply Dev 확인
2. Capacity Advisor Slack Report 수동 실행으로 Slack seat-lock 섹션 확인
3. record_sqs_worker_audit.py를 실제 bucket 대상으로 1회 실행해 SQS audit event 적재 확인
4. kafka_s3_sink.py --emit-audit-event를 실제 sink 실행에 붙여 KAFKA_S3_SINK_COMPLETED 적재 확인
5. 부하테스트로 실제 동시성 표본을 만든 뒤 Capacity Advisor 추천값 재검증
```

## 2026-06-29 추가 handoff: Slack seat-lock/infra audit 검증 완료

PR merge와 `Terraform Apply Dev` 완료 후 Capacity Advisor Slack Report를 수동 실행했다.

Slack report:

- Workflow run: `https://github.com/baselink-msa/terraform/actions/runs/28361099309`
- 상태: `RECOMMENDED`
- 신뢰도: `MEDIUM`
- 현재 정책: `40명/분`
- 추천 정책: `1명/분`
- DB 상태: `NORMAL (16/60)`
- SQS/Worker: `HEALTHY`
- Valkey: `HEALTHY`
- Kafka pipeline: `HEALTHY`

새로 확인한 seat-lock Slack 섹션:

```text
좌석 잠금 이벤트 상태
상태 COMPETITION_DETECTED / producer seat-lock-service
요청 2 성공 1 실패 1 해제 1
성공률 50.0% / 실패율 50.0% / 해제율 100.0%
latest SEAT_UNLOCKED at 2026-06-29T07:57:30.567262716Z / seat 900819838
```

해석:

- `COMPETITION_DETECTED`는 좌석 잠금 계층 장애가 아니라 중복 잠금 시도/좌석 선점 경쟁이 관측됐다는 뜻이다.
- 현재 표본은 E2E 검증용이라 실패율이 높게 보일 수 있다.
- 실제 부하테스트에서는 이 값을 좌석 잠금 경쟁률, Valkey 안정성, 예매 병목 분석 근거로 사용한다.

infra audit 실제 적재 검증:

| event_type | producer | count |
| --- | --- | ---: |
| `SQS_WORKER_STATUS_RECORDED` | `sqs-worker-audit-recorder` | 1 |
| `KAFKA_S3_SINK_COMPLETED` | `kafka-s3-sink` | 1 |

audit event 반영 후 Capacity Advisor:

```text
Kafka pipeline events: 91
producer counts:
- ticket-service=42
- waiting-room-service=42
- seat-lock-service=5
- sqs-worker-audit-recorder=1
- kafka-s3-sink=1
sink completed events: 1
```

다음 남은 작업:

```text
P0. 실제 부하테스트로 Capacity Advisor 추천값 재검증
P0. 부하테스트 결과를 load-test validation 문서에 기록
P1. Capacity Advisor Slack Report를 한 번 더 실행해 sink completed=1이 Slack에 표시되는지 캡처
P1. 발표용 내 담당 파트 전체 요약 문서 최종 정리
P2. event-driven Slack 알림: ADMISSION_THROTTLE_APPLIED, SQS DLQ 즉시 알림
P2. 예매 오픈 30분 전/예매 중 5분마다 Capacity Advisor 자동 실행
```

## 2026-06-29 추가 handoff: Slack에서 sink completed=1 최종 확인

`infra.audit` 이벤트 적재 후 Capacity Advisor Slack Report를 다시 수동 실행했다.

- Workflow run: `https://github.com/baselink-msa/terraform/actions/runs/28361550976`
- 상태: `RECOMMENDED`
- SQS/Worker: `HEALTHY`
- Valkey: `HEALTHY`
- 좌석 잠금 이벤트 상태: `COMPETITION_DETECTED`
- Kafka pipeline: `HEALTHY`

Slack Kafka pipeline 섹션:

```text
events 91
producer counts kafka-s3-sink=1, seat-lock-service=5, sqs-worker-audit-recorder=1, ticket-service=42, waiting-room-service=42
event type counts KAFKA_S3_SINK_COMPLETED=1, SQS_WORKER_STATUS_RECORDED=1 포함
producer failures 0 / invalid 0 / skipped 0 / sink completed 1
```

의미:

- `KAFKA_S3_SINK_COMPLETED`와 `SQS_WORKER_STATUS_RECORDED`가 Athena event lake에 적재되고 Slack 리포트까지 반영됐다.
- Capacity Advisor가 이제 대기열/예매 표본뿐 아니라 Kafka sink 실행 이력과 SQS worker 상태 기록까지 함께 보여준다.
- 발표에서는 “Kafka/S3/Athena 기반 event lake에 운영 이벤트와 인프라 audit 이벤트를 함께 모으고, Slack 리포트에서 운영 의사결정에 필요한 상태를 통합 제공했다”고 설명하면 된다.

현재 개인 프로젝트 완료 판단:

```text
MVP+ 수준 완료
-> MSK Serverless
-> waiting/ticket/seat-lock/capacity signal 이벤트
-> Kafka -> S3/Athena event lake
-> Capacity Advisor 추천
-> SQS/Valkey/Kafka pipeline health
-> seat-lock event summary
-> infra audit event 1차 기록
-> Slack 운영 리포트 검증
```

다음 우선순위는 실제 부하테스트 기반 추천값 재검증이다.

## 2026-06-29 추가 handoff: 실제 부하테스트 기반 Capacity Advisor 재검증 완료

이번 추가 작업 목표:

- 실제 k6 부하테스트로 대기열/예매 이벤트 표본을 만든다.
- Kafka -> S3/Athena event lake에 부하테스트 이벤트를 적재한다.
- Capacity Advisor가 작은 수동 표본이 아니라 실제 부하 표본으로 추천값을 계산하는지 확인한다.
- RDS/SQS/Valkey/Kafka pipeline health를 함께 확인해 RDS Proxy, Read Replica, worker scale-out 필요성을 판단한다.

실행 환경:

```text
부하테스트 EC2: baselink-dev-loadtest-20260628
InstanceId: i-033bd16247a7df3ea
Public IP: 43.200.254.206
테스트 도구: k6 v2.0.0
원격 결과 위치: /opt/baselink-loadtest/results
대상 gameId: 9001
```

실행한 k6 시나리오:

| 시나리오 | VU | 기간 | HTTP 요청 수 | HTTP 실패율 | Check 성공률 | 전체 p95 | 예약 요청 p95 | 예약 확정 p95 | 입장권 발급 p95 |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| smoke | 2 | 1m | 321 | 0.00% | 99.84% | 93.45ms | 41.95ms | 39.19ms | 111.91ms |
| baseline | 10 | 3m | 1,278 | 0.08% | 99.80% | 68.86ms | 57.16ms | 43.15ms | 87.83ms |
| load | 30 | 5m | 3,549 | 0.20% | 74.27% | 55.61ms | 129.80ms | 126.23ms | 133.13ms |

해석:

- smoke/baseline은 정상에 가깝게 통과했다.
- 30 VU load에서는 k6 `checks` threshold가 실패했지만, 실패 지점은 ticket reserve/confirm이 아니라 waiting-room token/status check였다.
- ticket reserve와 confirm은 load에서도 성공했고 p95가 약 130ms 안팎이었다.
- 따라서 이번 부하는 DB/RDS 병목보다 waiting-room admission control이 먼저 작동한 것으로 해석한다.

부하 이후 인프라 상태:

| 영역 | 결과 | 해석 |
| --- | --- | --- |
| RDS DatabaseConnections | 최대 28/60 | connection budget 대비 여유 있음 |
| SQS `ticket-confirm-queue` | visible 0 / not visible 0 / delayed 0 | worker backlog 없음 |
| SQS `ticket-confirm-dlq` | visible 0 / not visible 0 / delayed 0 | DLQ 누적 없음 |
| backend deployment | waiting-room, ticket, ticket-worker, seat-lock 모두 2/2 Ready | 부하 후 Pod 상태 정상 |
| Valkey | CPU 1.23%, memory 5.32%, evictions 0, replication lag 0초 | 좌석 잠금/대기열 캐시 계층 안정 |

Kafka/S3/Athena 최신화:

- Kafka sink runner로 `ticket.domain.events`, `waiting.operational.events`, `reservation.lifecycle.events`, `capacity.signals`를 S3 event lake에 적재했다.
- SQS/worker 상태를 `SQS_WORKER_STATUS_RECORDED` audit event로 기록했다.
- S3에는 2026-06-29 18:24~18:33 KST 시간대의 `WAITING_ENTERED` 등 부하테스트 이벤트가 적재됐다.

Capacity Advisor 재계산 결과:

| 항목 | 결과 |
| --- | --- |
| 상태 | `RECOMMENDED` |
| 신뢰도 | `HIGH` |
| 현재 정책 | 40명/분 |
| 추천 정책 | v1 산식 기준 1명/분 |
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

v1 추천값 1명/분의 의미:

```text
stable_confirmed_per_minute = 2.0
reservation_conversion = 100%
safety_factor = 0.8
waiting_factor = 1.0

raw_recommendation = 2.0 * 1.0 * 0.8 * 1.0 = 1.6
floor(1.6) = 1
```

즉, v1 추천값 1명/분은 DB가 위험하다는 뜻이 아니다. 이번 부하테스트에서 관측된 안정 예약 확정 처리량이 분당 2건 수준이었고, Capacity Advisor가 안전계수와 내림 처리를 적용했기 때문에 나온 보수적인 추천값이다.

Capacity Advisor v2 guardrail 적용 결과:

```text
raw recommendation: 1.6명/분
raw policy: 1명/분
minimum policy floor: 10명/분
max decrease guardrail: 20명/분
recommended policy: 20명/분
effectiveEnterPerMinuteNow: 20명/분
```

의미:

- 관측 처리량이 낮다는 사실은 숨기지 않고 raw 값으로 보여준다.
- DB/SQS/Valkey가 정상인 상황에서는 현재 정책을 40명/분에서 1명/분으로 급격히 낮추지 않는다.
- Capacity Advisor가 시스템 보호와 사용자 경험을 함께 고려하는 운영 판단 도구에 가까워졌다.

이번 검증으로 얻은 결론:

- Capacity Advisor는 실제 부하테스트 이벤트를 기준으로 `HIGH` 신뢰도 추천값을 생성했다.
- Kafka -> S3 -> Athena -> Capacity Advisor 분석 경로는 부하 표본 기준으로 정상 동작했다.
- SQS backlog/DLQ와 Valkey 위험 신호는 없었다.
- RDS connection은 최대 28/60으로 여유가 있어 RDS Proxy를 즉시 도입할 근거는 확인되지 않았다.
- 예매 write 경로의 DB 병목은 확인되지 않았다.
- Read Replica는 조회 API 중심 부하테스트를 별도로 수행한 뒤 판단하는 것이 좋다.

다음 우선순위:

```text
P0. Capacity Advisor 부하테스트 구간 분리 분석
    - testRunId
    - start_time/end_time
    - smoke/순차 표본과 load 표본 분리
    - 예매 오픈 규모/목표 대기시간별 policy profile

P1. Read Replica 판단용 조회 API 부하테스트
    - games/seats/read-heavy API p95
    - RDS CPU/ReadIOPS
    - cache 우선 적용 가능성

P1. RDS Proxy 판단용 connection storm 부하테스트
    - Hikari timeout
    - DatabaseConnections budget 초과
    - connection churn

P1. 발표용 문서와 PPT 프롬프트 최신화
    - Slack Capacity Advisor 리포트
    - k6 결과표
    - S3/Athena event lake
    - RDS/SQS/Valkey health
```

최신 상세 문서:

```text
docs/load-test-validation-plan.md
docs/kafka-capacity-advisor-e2e-verification.md
docs/project-continuity-handoff.md
```
