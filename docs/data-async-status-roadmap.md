# Data & Async Processing 현황 및 로드맵

## 1. 문서 목적

이 문서는 BaseLink 프로젝트의 Data & Async Processing 영역에 대한 현재 기준점입니다.

다음 내용을 한곳에서 관리합니다.

- 현재 구현 및 배포 상태
- 실제 검증이 끝난 항목
- 설계만 있고 아직 구현하지 않은 항목
- 중요한 트러블슈팅과 재발 방지 내용
- 다음 작업 우선순위와 완료 조건
- 발표에서 사용할 핵심 메시지
- 팀 프로젝트와 개인 프로젝트의 역할 경계

RDS, SQS, Valkey, 백업/복구, DR, DB connection 관리, 대기열 admission control의 상세 설계는 기존 문서를 따릅니다. 이 문서는 상세 문서를 대체하지 않고 전체 현황을 연결하는 인덱스 역할을 합니다.

## 2. 업데이트 규칙

큰 작업이 하나 끝날 때마다 다음 항목을 갱신합니다.

1. 구현 상태를 `계획`, `구현`, `배포`, `검증 완료` 중 하나로 변경합니다.
2. 실제 검증 명령, 수치, 수행일을 기록합니다.
3. 중요한 문제는 트러블슈팅 기록에 추가합니다.
4. 발표 포인트를 한두 문장으로 남깁니다.
5. 후속 작업과 우선순위를 다시 정리합니다.

상태 기준:

| 상태 | 의미 |
| --- | --- |
| 계획 | 방향이나 문서만 존재 |
| 구현 | 코드 또는 Terraform/GitOps 변경 완료 |
| 배포 | 실제 AWS/EKS 환경에 반영 |
| 검증 완료 | 정상·장애 경로 또는 복구 절차까지 확인 |

마지막 점검일: `2026-06-22`

## 3. 전체 상태 요약

| 영역 | 현재 상태 | 핵심 결과 |
| --- | --- | --- |
| RDS PostgreSQL | 검증 완료 | Multi-AZ, 7일 PITR, 삭제 보호, Flyway 기반 DB 관리 |
| SQS 비동기 처리 | 검증 완료 | 원본 큐, DLQ, 재시도, redrive, backlog/DLQ 알람 |
| Valkey | 배포 | 2노드 Multi-AZ, automatic failover, 저장 암호화 |
| AWS Backup | 검증 완료 | Daily snapshot 생성과 임시 RDS 복원 리허설 완료 |
| DR | 일부 검증 완료 | AZ/논리 장애 대응 완료, 리전 DR은 설계 단계 |
| Connection Pool | 검증 완료 | Spring/Python/KEDA 전체 app budget 60 적용 |
| 동적 대기열 | 검증 완료 | Ready Pod 용량과 RDS 압력을 반영한 자동 감속 |
| 운영 모니터링 | 일부 검증 완료 | CloudWatch·Backup EventBridge→SNS→Amazon Q 전달 성공, Slack 화면 최종 확인 대기 |
| 발표/Runbook | 진행 중 | 구현 상태 동기화 완료, 감속 전용 Runbook과 최종 증거 캡처 필요 |
| 개인 프로젝트 | MVP 검증 완료 | Outbox→SQS→Lambda→S3→Athena→Capacity Advisor E2E 및 실패 경로 검증 |

현재 완성도 판단:

| 기준 | 완성도 | 설명 |
| --- | ---: | --- |
| 팀 핵심 기능 구현 | 약 90% | 데이터 저장·비동기 처리·복구·DB 보호 기능 구현 완료 |
| 팀 운영 검증·문서 | 약 80% | 부하 테스트, 일부 Slack 알림, 감속 Runbook이 남음 |
| 개인 프로젝트 MVP | 약 90% | 기능과 E2E 완료, 실제 부하 데이터 기반 최종 수치가 남음 |
| 발표 준비 | 약 65% | 문서 동기화 중이며 캡처·아키텍처 그림·리허설 필요 |

## 4. RDS PostgreSQL

### 4.1 현재 구현

- PostgreSQL `db.t4g.micro`
- Multi-AZ 활성화
- automated backup 7일 보존
- PITR 사용 가능
- deletion protection 활성화
- 삭제 시 final snapshot 생성
- RDS CPU, connection, storage, memory CloudWatch Alarm
- 최종 영구 데이터 저장소로 사용

주요 데이터:

- 사용자와 권한
- 경기, 구장, 좌석
- 예약과 좌석 상태
- 주문
- FAQ

### 4.2 Flyway 기반 DB 관리

초기 수동 schema 생성과 Hibernate `ddl-auto=update` 방식에서 Flyway 중심으로 전환했습니다.

```text
auth-service 시작
→ Flyway migration 실행
→ schema/table/constraint 생성
→ dev seed 적용
→ Hibernate ddl-auto=validate
```

현재 migration:

- `V1__create_schemas_and_tables.sql`
- `V2__create_ticket_open_schedule.sql`
- `V3__add_ticket_uniqueness_constraints.sql`
- `V4__align_game_seat_price_type.sql`
- `V5__create_ticket_event_outbox.sql`
- `R__seed_dev_data.sql`

효과:

- 새 RDS에서도 동일한 DB 구조 재현
- DB 변경 이력 관리
- 팀원별 schema 불일치 방지
- 애플리케이션 Entity와 실제 DB 구조 검증

### 4.3 정합성 처리

- 예약별 idempotency key 사용
- 동일 사용자·경기·좌석 요청의 중복 예약 방지
- worker는 `PENDING` 예약만 처리
- 예약과 Outbox event를 같은 transaction으로 저장
- Publisher가 commit된 Outbox event를 SQS로 발행
- worker 재처리 시 이미 처리된 예약은 무시

### 4.4 남은 작업

- RDS 저장 암호화 적용
- Read Replica 설계
- RDS Proxy 도입 타당성 검토
- Performance Insights/Database Insights 운영 기준 수립
- 장기 실행 쿼리와 서비스별 connection 자동 진단
- 실제 부하 테스트 기반 인스턴스 크기 재평가

주의:

현재 RDS 저장 암호화는 비활성화 상태입니다. 기존 인스턴스에서 단순 활성화할 수 없으므로 암호화 snapshot 복사, 새 RDS 복원, 검증, endpoint 전환 절차가 필요합니다.

## 5. SQS 및 비동기 Worker

### 5.1 현재 처리 흐름

```text
ticket-service
→ 예약 PENDING 저장
→ DB commit 완료
→ ticket-confirm-queue 메시지 발행
→ ticket-worker-service 처리
→ 예약 상태 확정
→ 반복 실패 시 DLQ
```

### 5.2 현재 설정

| 항목 | 값 |
| --- | --- |
| 원본 큐 | `ticket-confirm-queue` |
| 원본 메시지 보존 | 1일 |
| Visibility Timeout | 30초 |
| 최대 수신 횟수 | 5회 |
| DLQ | `ticket-confirm-dlq` |
| DLQ 보존 | 14일 |
| 암호화 | AWS 관리형 SSE 활성 |

### 5.3 장애 처리

- 원본 큐 backlog 알람
- DLQ 메시지 알람
- Slack 알림
- 실패 메시지 격리
- 원인 수정 후 DLQ redrive
- 지정된 원본 큐만 redrive할 수 있도록 allow policy 적용

### 5.4 남은 작업

- worker 최악 처리시간과 Visibility Timeout 비교
- 원본 큐 보존 기간 4일 이상 여부 검토
- 메시지 payload에 schema version 도입
- DLQ 원인 분류 및 승인형 재처리 도구
- 비동기 처리 부하 테스트

Transactional Outbox는 구현·배포·검증을 완료했습니다. 예약 transaction과 event 기록을 함께 commit하고 Publisher가 재시도하므로 DB commit과 SQS 발행 사이의 유실 구간을 줄였습니다.

## 6. Valkey

### 6.1 현재 구현

- Valkey 8 계열
- `cache.t4g.micro` 2노드
- Primary/Replica 구성
- 서로 다른 AZ에 배치
- automatic failover 활성화
- 저장 암호화 활성화
- CPU, memory, eviction, replication lag 알람

담당 데이터:

- 대기열 순위
- 분당 입장 counter
- access token
- 좌석 lock
- TTL 기반 임시 상태

영구 예약 데이터는 RDS에 저장하여 Valkey 장애가 최종 예약 데이터 유실로 이어지지 않게 분리했습니다.

### 6.2 남은 작업

- 전송 암호화 TLS 적용
- AUTH token과 Secrets Manager 연동
- snapshot retention 정책 결정
- 실제 primary 장애 failover 리허설
- key naming, TTL, 삭제 정책 최신화
- eviction 발생 시 좌석 lock과 대기열 영향 검증

현재 전송 암호화와 AUTH는 비활성화 상태입니다.

## 7. 백업과 복구

### 7.1 RDS Native Backup

- automated backup 7일
- PITR 사용 가능
- Multi-AZ는 물리 장애 대응
- PITR은 삭제, 잘못된 migration, 데이터 오염 같은 논리 장애 대응

PITR은 기존 DB를 되감지 않습니다.

```text
특정 시점의 새 RDS 복원
→ 데이터 검증
→ endpoint 전환 또는 필요한 데이터 복사
```

### 7.2 AWS Backup

현재 구성:

- Backup Vault
- Backup Plan
- 명시적 RDS ARN 기반 Backup Selection
- 매일 04:00 KST snapshot
- 7일 보존
- Cross-region Copy 미적용

### 7.3 복원 리허설

완료한 절차:

1. Recovery Point 선택
2. AWS Backup restore job 실행
3. 임시 RDS 생성
4. EKS 내부에서 복원 DB 접속
5. schema/table/row count 검증
6. 임시 RDS 삭제

발표 포인트:

> 백업 설정만 확인한 것이 아니라 실제 Recovery Point에서 새 RDS를 복원하고 애플리케이션 네트워크 내부에서 데이터를 검증했습니다.

### 7.4 남은 작업

- 자동 데이터 검증 스크립트
- 복구 리허설 정기 실행
- Cross-region Copy
- 복원 리소스 자동 정리 보호 장치

2026-06-22 추가 검증:

- 명시한 시점으로 RDS native PITR 복원 완료
- 최신 복구 가능 시각 지연 약 3분 28초로 RPO 5분 목표 확인
- DB 인프라 복구 시간 약 7분 21초 측정
- Flyway V1~V5와 핵심 schema/table/row count 확인
- PITR endpoint로 임시 `ticket-service` 기동
- Actuator health `UP`과 읽기 API 성공
- 임시 Pod와 RDS 삭제 완료

## 8. DR

### 8.1 현재 대응 가능한 장애

| 장애 | 대응 |
| --- | --- |
| RDS 인스턴스/AZ 장애 | Multi-AZ failover |
| Valkey 노드/AZ 장애 | Replica 자동 승격 |
| Pod/Node 중단 | 다중 replica, topology spread, PDB |
| 데이터 삭제/오염 | PITR 또는 AWS Backup restore |
| Worker 처리 실패 | SQS 재시도, DLQ, redrive |

### 8.2 리전 장애

현재 서울 단일 리전이며 완전한 리전 DR은 구현되지 않았습니다.

목표 전략은 Pilot Light입니다.

```text
DR 리전 인프라 준비
→ Cross-region snapshot 복원
→ EKS/Valkey/SQS/backend 재구성
→ smoke test
→ endpoint 전환
```

남은 작업:

- DR 리전용 Terraform tfvars
- AWS Backup Cross-region Copy
- ECR/S3 Cross-region Replication
- Secrets 동기화
- Route 53 또는 CloudFront failover
- 리전 장애 복구 리허설

## 9. DB Connection Pool과 Autoscaling

### 9.1 Connection Budget

현재 RDS `max_connections=79`를 기준으로 약 19개를 운영·관리·migration 여유로 남기고 app budget을 60으로 설정했습니다.

| 서비스 | max Pod | Pod당 Pool | 최대 Connection |
| --- | ---: | ---: | ---: |
| `ticket-service` | 5 | 4 | 20 |
| `ticket-worker-service` | 4 | 3 | 12 |
| `seat-lock-service` | 4 | 2 | 8 |
| `waiting-room-service` | 4 | 1 | 4 |
| `auth-service` | 2 | 2 | 4 |
| `game-service` | 2 | 2 | 4 |
| `admin-service` | 2 | 1 | 2 |
| Spring Boot 소계 |  |  | 54 |
| `order-service` | 4 | 1 | 4 |
| `ai-chatbot-service` | 2 | 1 | 2 |
| Python 소계 |  |  | 6 |
| 합계 |  |  | 60 |

KEDA `maxReplicaCount`도 이 budget에 맞게 적용했습니다.

### 9.2 Python Pool

기존 요청별 `psycopg2.connect()` 방식을 bounded `ThreadedConnectionPool`로 변경했습니다.

- Pod당 최대 connection 1개
- pool 획득 timeout 2초
- DB connect timeout 3초
- statement timeout 5초
- 반환 전 rollback
- 고갈 시 `503 DB_CONNECTION_POOL_EXHAUSTED`

Prometheus metric:

- `python_db_pool_in_use`
- `python_db_pool_available`
- `python_db_pool_max`
- `python_db_pool_acquire_timeout_total`
- `python_db_pool_acquire_wait_seconds`

Grafana에는 서비스별 pool 현황, 사용률, p95 획득 지연, timeout 패널이 반영됐습니다.

### 9.3 남은 작업

- Python pool 전용 Prometheus Alert Rule 검증
- Spring Hikari metric 통합
- 실제 pool 포화 E2E 테스트
- connection 진단 자동화
- 부하 테스트 기반 pool과 KEDA 상한 재조정

## 10. 대기열 Admission Control

### 10.1 역할

대기열은 단순한 사용자 순번 UI가 아니라 backend와 DB가 감당할 수 있는 속도로 신규 사용자를 흘려보내는 보호 계층입니다.

### 10.2 현재 입장량 계산

```text
기본 입장량 =
min(
  관리자 maxEnterPerMinute,
  ticket-service Ready Pod × Pod당 처리량
)

최종 입장량 =
기본 입장량 × RDS connection 감속률
```

현재 ticket-service Pod당 처리량 기본값은 20명/분입니다.

### 10.3 RDS 기반 자동 감속

| RDS Connection | 단계 | 감속률 |
| ---: | --- | ---: |
| 0~39 | NORMAL | 100% |
| 40~49 | CAUTION | 75% |
| 50~54 | WARNING | 50% |
| 55~59 | CRITICAL | 25% |
| 60 이상 | STOP | 0% |

진행 중인 예약을 중단하지 않고 신규 입장 속도만 낮춥니다.

추가 구현:

- RDS connection 조회 결과 5초 cache
- API에 connection, budget, 감속률, 단계 노출
- Prometheus metric 노출
- `backend-config` 변경 시 Reloader 자동 rollout
- 단계별 통합 테스트 완료

### 10.4 분당 입장과 Token TTL 분리

과거에는 token TTL이 입장 가능 인원 계산에 섞여 다음 사용자가 불필요하게 오래 대기했습니다.

현재는 다음처럼 분리했습니다.

- 분당 counter: 유입 속도 제어
- Token TTL: 좌석 선택 권한 유지

검증 결과:

- 첫 사용자는 즉시 입장
- 같은 분의 두 번째 사용자는 대기
- 다음 분에는 첫 token TTL이 남아 있어도 입장

### 10.5 남은 작업

- 자동 감속 전용 Runbook
- RDS connection 조회 실패 fallback 테스트
- `maxActiveSessions` 검토
- 실제 부하 테스트 기반 Pod당 처리량 재산정
- Valkey latency와 SQS backlog를 감속 입력으로 사용할지 검토
- 대기시간 예측 정확도 검증

## 11. 운영과 모니터링 역할 경계

모니터링 담당:

- Prometheus/Grafana 시각화
- CloudWatch/Prometheus Alert Rule
- Slack 알림 연결
- 서비스 latency/error, CPU/memory 대시보드

Data & Async 담당:

- 데이터 정합성과 migration
- RDS/Valkey/SQS 데이터 흐름
- connection budget과 admission 정책
- DLQ 재처리 의미와 안전 조건
- 복구 절차와 데이터 검증
- 이벤트 schema와 분석 데이터 기반

공통 영역은 데이터를 만드는 쪽과 보여주는 쪽으로 나눕니다.

```text
Data & Async: metric/event 의미, 생성, 정상 범위, 판단 규칙
Monitoring: 수집, 시각화, Alert Rule, 알림 채널
```

## 12. 중요 트러블슈팅 기록

| 문제 | 원인 | 해결 및 교훈 |
| --- | --- | --- |
| 새 RDS에서 서비스 기동 실패 | schema/table 부재 | Flyway migration으로 자동 재현 |
| SQS 호출 인증 실패 | 애플리케이션에 test credential 고정 | IRSA 기본 credential chain 사용 |
| EKS Pod에서 AWS 권한 획득 실패 | Node Role 의존 | ServiceAccount 기반 IRSA 적용 |
| 이전 이미지가 재사용됨 | 가변 `dev` tag와 pull policy | immutable commit tag와 pull 정책 정리 |
| Linux 이미지에서 Gradle 실행 실패 | Windows CRLF | Docker build 단계에서 줄바꿈 처리 |
| Gradle plugin 충돌 | Wrapper와 plugin 버전 불일치 | 검증된 Gradle 버전으로 build |
| 대기 인원 0인데 장시간 대기 | 분당 입장과 token TTL 혼용 | Redis 분당 counter와 token TTL 분리 |
| Python DB connection 상한 없음 | 요청마다 신규 connect | bounded pool과 timeout 적용 |
| Prometheus 서비스 label 충돌 | target `service` label과 중복 | `exported_service`로 조회 |
| Backup restore 명령 JSON 오류 | PowerShell quoting | metadata 파일 또는 구조화된 전달 방식 사용 |

## 13. 앞으로 남은 작업

### 우선순위 1: 기록과 운영 절차 완결

- 이 문서와 발표 요약 최신화
- 자동 감속 전용 Runbook
- Python pool/감속 Alert Rule E2E 검증
- 중요한 트러블슈팅 상세 기록

완료 조건:

- 장애 발생부터 확인, 완화, 복구, 사후 검증 절차가 문서에 존재
- 실제 테스트 알림이 Slack까지 전달
- 발표 요약의 상태와 실제 배포 상태가 일치

### 우선순위 2: 성능 기준 확보

- 예매/조회/worker 부하 테스트
- 안정 처리량 측정
- RDS CPU, connection, latency, DB Load 분석
- ticket-service Pod당 20명/분 재산정

완료 조건:

- 안정·경고·실패 구간 수치 확보
- KEDA와 pool 상한의 근거 제시
- RDS class 상향 조건 수립

### 우선순위 3: DB 확장 아키텍처 검토

- Read Replica 설계
- RDS Proxy 타당성 검토
- cache 우선 적용 대상 분류

완료 조건:

- 읽기/쓰기 API 분류
- replication lag 허용 여부 정의
- writer/reader datasource 전환안
- Proxy 도입 비용과 기대 효과 비교

### 우선순위 4: 보안 강화

- RDS 저장 암호화
- Valkey TLS/AUTH
- External Secrets와 Secrets Manager
- SQS SSE Terraform 명시 관리

### 우선순위 5: 리전 DR

- Cross-region backup
- DR 리전 tfvars
- 복제와 endpoint 전환
- 전체 복구 리허설

## 14. 개인 프로젝트 방향

### 14.1 권장 주제

`Ticket Reliability Data Platform & Capacity Advisor`

운영 대시보드를 만드는 프로젝트가 아니라, 예매·대기열 이벤트를 유실과 중복에 안전하게 수집·분석하고 근거가 있는 입장 정책을 추천하는 데이터 신뢰성 플랫폼으로 정의합니다.

한 문장 요약:

> 예매와 대기열 이벤트를 신뢰성 있게 S3에 축적하고 Athena로 실제 처리량을 분석해, 운영자가 검토할 수 있는 안전 입장량과 계산 근거를 제공하는 프로젝트입니다.

핵심 질문:

- 예매 흐름의 어떤 단계에서 실패했는가?
- 이벤트가 유실되거나 중복되어도 분석 결과를 신뢰할 수 있는가?
- RDS와 Worker가 안정적으로 처리 가능한 입장량은 얼마인가?
- DLQ 메시지를 어떤 조건에서 안전하게 재처리할 수 있는가?

### 14.2 모니터링 담당과 겹치지 않는 범위

개인 프로젝트가 담당할 것:

- 예매 이벤트 schema와 version
- Transactional Outbox
- SQS/Lambda/S3 적재
- 중복 제거와 idempotency
- DLQ 실패 경로 검증과 향후 승인형 redrive
- Athena 기반 처리량·전환율 계산
- 규칙 기반 안전 입장량 추천
- 규칙 기반 JSON/Markdown 근거 보고서
- 선택적으로 Bedrock을 이용한 자연어 요약

모니터링 담당 영역으로 남길 것:

- Grafana 시각화 디자인
- 일반 인프라 metric 대시보드
- 범용 CPU/memory/latency 알람
- Slack 채널과 Alertmanager 운영

### 14.3 단계별 구현

1. 공통 envelope와 핵심 이벤트 4종 정의 — 완료
2. Outbox table과 Publisher 구현 — 완료
3. SQS/Lambda/S3 적재 — 완료
4. Glue/Athena 분석 table과 SQL — 완료
5. 대기열 이벤트 비동기 발행 — 완료
6. 규칙 기반 Capacity Advisor와 보고서 — 완료
7. 실제 부하 테스트 데이터로 처리량 근거 교체 — 남음
8. 승인형 redrive와 Bedrock 요약 — 선택 고도화

### 14.4 MVP 완료 기준

- 이벤트 발행 실패가 예매 transaction을 깨뜨리지 않음
- 같은 이벤트가 중복 전달돼도 분석 결과가 중복되지 않음
- S3에서 날짜·경기별 partition 조회 가능
- Athena로 대기열→예약 확정 전환율 계산 가능
- 잘못된 이벤트가 재시도 후 DLQ로 격리됨
- 추천 입장량에 계산 근거가 포함됨
- AI가 직접 인프라를 변경하지 않고 설명과 제안만 수행

현재 검증 완료 내용:

- 실제 대기열 API로 `WAITING_ENTERED`, `ACCESS_TOKEN_ISSUED` 적재 확인
- Athena 일별 유입, 평균 대기시간, 예약 전환율 query 실행 성공
- 합성 표본 152건을 실제 SQS 파이프라인으로 적재
- `producer=capacity-load-test`로 운영 데이터와 합성 데이터 분리
- Capacity Advisor JSON/Markdown 보고서 생성
- 표본 부족 시 추천 보류, DB STOP 시 유효 입장량 0, 정책 증가 25% 제한 검증

발표 메시지:

> 운영 지표를 시각화하는 데 그치지 않고, 예매 이벤트를 유실과 중복에 안전하게 수집해 사용자 흐름과 처리 용량을 계산하고, 장애 상황에서 안전한 재처리와 입장량 결정을 지원하는 데이터 신뢰성 플랫폼을 구현했습니다.

## 15. 관련 문서

- `docs/db-connection-pool-strategy.md`
- `docs/disaster-recovery-strategy.md`
- `docs/disaster-recovery-presentation-summary.md`
- `docs/aws-backup-design.md`
- `docs/aws-backup-restore-runbook.md`
- `docs/ops-alarm-runbook.md`
- `modules/rds/README.md`
- `modules/rds/RUNBOOK.md`
- `modules/sqs/README.md`

## 16. 프로젝트 종료 2주 실행 계획

### 16.1 기본 원칙

남은 기간은 다음처럼 사용합니다.

```text
첫 1주:
기존 팀 프로젝트 안정성 검증 완결
+ 개인 프로젝트 MVP 구현

마지막 1주:
기능 동결
+ 발표 자료
+ 데모 리허설
+ 예상 질문과 답변
+ 장애 발생 시 대체 시나리오 준비
```

새 기능은 구현 여부보다 다음 완료 조건을 더 중요하게 봅니다.

- 실제 환경에 배포되어 있음
- 정상 경로와 대표 실패 경로를 검증함
- 결과 수치와 화면을 증거로 남김
- Runbook과 발표 요약이 최신 상태임
- 데모 실패 시 사용할 캡처나 녹화 자료가 있음

첫 주가 끝난 뒤에는 치명적인 결함 수정 외 신규 기능을 추가하지 않습니다.

### 16.2 우선순위

#### P0: 반드시 완료

| 작업 | 이유 | 완료 조건 |
| --- | --- | --- |
| 현재 문서와 발표 요약 최신화 | 실제 구현과 발표 내용 불일치 방지 | Python pool, 자동 감속, 최신 검증 결과가 모든 요약 문서에 일치 |
| Backup/Restore 실패 알림 | 백업 실패를 늦게 발견하면 실제 RPO가 목표보다 커짐 | EventBridge transformer와 CloudWatch 권한 검증 완료, Slack 화면 확인만 남음 |
| RDS PITR 및 복원 endpoint 검증 | snapshot 복원 외 논리 장애와 서비스 연결 전환 증거 필요 | 완료: 임의 시점 복원, DB 검증, 임시 backend smoke test |
| Python pool/자동 감속 Alert Rule 검증 | 기능은 있지만 장애 통지 검증이 부족함 | Warning/Critical 테스트 알림이 Slack까지 전달 |
| 자동 감속 장애 대응 Runbook | 평가 시 운영 대응 질문에 대비 | NORMAL~STOP, DB 조회 실패, 복구 절차가 명시됨 |
| 핵심 부하 테스트 1회 | pool/KEDA/입장량 수치의 근거 확보 | 안정·경고 구간의 처리량, connection, latency 기록 |
| 개인 프로젝트 실제 부하 데이터 검증 | 합성 표본이 아닌 운영 근거 확보 | 부하 테스트 producer의 처리량으로 Advisor 보고서 재생성 |
| 개인 프로젝트 데모 증거 확보 | 발표 중 AWS 의존성 대비 | S3 partition, Athena 결과, 보고서 JSON/Markdown 캡처 |

#### P1: P0 완료 후 수행

| 작업 | 이유 | 완료 조건 |
| --- | --- | --- |
| 도쿄 Pilot Light 리전 DR | 재해복구 담당 범위를 리전 장애까지 확장 | cross-region copy, DR plan, 복원 리허설, endpoint 전환 Runbook 완료 |
| Read Replica 설계 문서 | 조회 확장 질문에 대한 근거 있는 답변 | 읽기 API, 일관성, lag, fallback, 비용 정리 |
| RDS Proxy 타당성 검토 | connection storm 대응 질문에 대비 | 현재 pool 방식과 Proxy 비교 및 도입 조건 정의 |
| Connection 진단 스크립트 | 장애 원인 수집 시간 단축 | 전체/서비스별 connection과 장기 쿼리를 한 번에 출력 |
| 중요 트러블슈팅 상세 기록 | 발표와 기술 면접 재사용 | 문제·원인·해결·검증·재발 방지 형식으로 정리 |

#### P2: 시간이 남을 때만 수행

- RDS 저장 암호화 마이그레이션
- Valkey TLS/AUTH 전환
- 실제 Read Replica 또는 RDS Proxy 생성
- Valkey failover 리허설
- 승인형 자동 변경

P2 작업은 가치가 높지만 기존 환경 변경 범위와 장애 위험이 큽니다. 발표 직전에는 설계와 도입 조건까지만 설명하고, 충분한 검증 시간이 확보될 때만 실제 적용합니다.

### 16.3 개인 프로젝트 1주 MVP

개인 프로젝트 이름:

```text
Ticket Reliability Data Platform & Capacity Advisor
```

신뢰성 있는 이벤트 파이프라인과 근거 기반 입장량 추천까지의 MVP 구현과 E2E 검증을 완료했습니다.

#### 완료된 필수 범위

1. 공통 이벤트 envelope과 schema version
2. 핵심 이벤트 4종
   - `WAITING_ENTERED`
   - `ACCESS_TOKEN_ISSUED`
   - `RESERVATION_REQUESTED`
   - `RESERVATION_CONFIRMED`
3. Transactional Outbox
4. Outbox publisher의 재시도와 idempotency
5. S3 날짜·경기별 이벤트 적재
6. Athena 분석
   - 유입 수
   - 평균 대기시간
   - 예약 요청→확정 전환율
   - 처리 실패 수
7. 규칙 기반 안전 입장량 추천
8. 추천 근거를 Markdown 또는 JSON 보고서로 출력

검증 결과:

- 실제 API를 통한 대기열 진입·토큰 발급 이벤트 적재
- 잘못된 JSON의 재시도와 DLQ 격리
- Glue Partition Projection과 Athena query 실행
- 합성 표본 152건 기반 Advisor 계산
- 실제 데이터와 합성 데이터를 producer로 분리
- 동일 입력 재현성, 최소 표본, STOP, 25% 증가 제한 단위 테스트

#### 선택 범위

- Bedrock을 이용한 보고서 자연어 요약
- Slack 보고서 전달
- 간단한 승인형 redrive
- React 전용 화면
- 미래 트래픽 예측

AI는 필수 계산을 담당하지 않습니다. 처리량과 안전 입장량은 재현 가능한 규칙과 수식으로 계산하고, Bedrock은 결과 설명과 요약에만 사용합니다.

#### 범위에서 제외

- 별도 Grafana 대시보드 디자인
- 범용 CPU/memory/latency 모니터링
- Alertmanager 운영
- AI의 무승인 인프라 변경
- 복잡한 실시간 ML 예측

이 범위를 제외함으로써 모니터링 담당자와 역할이 겹치지 않고 Data & Async 담당자의 이벤트 정합성, 비동기 처리, 분석 데이터 설계 역량을 보여줍니다.

### 16.4 첫 주 일자별 계획

| 일차 | 팀 프로젝트 | 개인 프로젝트 |
| --- | --- | --- |
| 1일차 | 문서 상태 동기화, Alert Rule/Runbook 범위 확정 | 이벤트 schema와 Outbox 설계 |
| 2일차 | Python pool/감속 알림 E2E 검증 | Outbox migration과 이벤트 기록 구현 |
| 3일차 | 핵심 부하 테스트 준비 | Publisher와 재시도/idempotency 구현 |
| 4일차 | 부하 테스트 실행과 결과 기록 | S3 적재 파이프라인 구현 |
| 5일차 | Read Replica/Proxy 판단 문서 | Athena table/query와 입장량 계산 |
| 6일차 | 트러블슈팅·발표 요약 갱신 | 통합 테스트와 실패 경로 검증 |
| 7일차 | 전체 회귀 테스트와 기능 동결 | MVP 데모 시나리오와 결과 보고서 확정 |

### 16.5 마지막 주 계획

| 일차 | 작업 |
| --- | --- |
| 1~2일차 | 발표 구조, 아키텍처 그림, 역할과 문제 정의 |
| 3일차 | 구현 근거 수치, 복구 리허설, 부하 테스트 결과 반영 |
| 4일차 | 개인 프로젝트 데모와 팀 프로젝트 연계 설명 |
| 5일차 | 예상 질문, 한계, 비용, 보안, 확장 전략 답변 준비 |
| 6일차 | 전체 발표와 데모 리허설, 시간 측정 |
| 7일차 | 최종 수정, 데모 영상·캡처·복구용 자료 확인 |

### 16.6 기능 동결 기준

다음 조건이 충족되면 신규 구현을 멈추고 발표 준비로 전환합니다.

- [x] 기존 backend 핵심 Pod 정상
- [x] Flyway V5 migration과 Outbox table 정상
- [x] 이벤트 SQS 처리와 DLQ 실패 경로 확인
- [x] RDS Backup Restore 증거 확보
- [x] Connection budget과 자동 감속 단계 검증
- [ ] Python pool 및 감속 Slack 알림 최종 검증
- [x] 개인 프로젝트 핵심 이벤트 4종 S3 적재
- [x] Athena 핵심 query 실행
- [x] 안전 입장량 보고서 생성
- [ ] 실제 부하 테스트 수치와 발표 캡처 확보
- [ ] 자동 감속 Runbook과 최종 발표 문서 완결

### 16.7 평가 질문 대비 핵심 판단

| 예상 질문 | 답변 방향 |
| --- | --- |
| 왜 Read Replica를 만들지 않았나? | 실제 읽기 병목을 먼저 측정하고, lag를 허용할 API에만 도입하기 위해 설계와 조건을 분리함 |
| 왜 RDS Proxy가 없나? | bounded pool과 KEDA 상한으로 connection을 먼저 제어했으며 짧은 connection storm이 확인될 때 도입 |
| AI가 잘못 판단하면? | 수치는 규칙 엔진이 계산하고 AI는 설명만 담당하며 자동 변경은 하지 않음 |
| 이벤트가 중복되면? | event ID, Outbox 상태, consumer idempotency, Athena 중복 제거 기준 적용 |
| 이벤트 발행이 실패하면 예약도 실패하나? | 예약 transaction과 Outbox 기록을 함께 commit하고 publisher가 비동기로 재시도 |
| 모니터링 담당자와 무엇이 다른가? | 팀원은 시스템 상태를 시각화하고, 개인 프로젝트는 신뢰성 있는 이벤트 생성·전달·분석과 용량 판단 근거를 제공 |

## 17. 진행 기록

### 2026-06-19

완료:

- Data & Async 전체 현황과 2주 실행 계획 작성
- DR 발표 요약을 실제 배포·검증 상태와 동기화
- Python bounded pool과 RDS 자동 감속 검증 결과 반영
- 발표 가능한 주요 트러블슈팅 표 추가
- 개인 프로젝트 Event/Outbox 상세 설계 완료
- Flyway Outbox migration과 공통 event envelope 구현
- 예약 요청/확정 transaction에 Outbox event 기록
- 예약 worker 명령과 분석 event를 목적지별 Outbox로 통합
- DB commit 이후 직접 SQS 발행 경로 제거
- 신규·중복·확정 event 단위 테스트 통과

설계 문서:

- `docs/ticket-reliability-event-outbox-design.md`

다음 구현:

1. 최신 main 기준 Terraform PR과 이벤트 큐 적용
2. Flyway V5 선행 배포 및 PostgreSQL migration 검증
3. ticket-service Publisher 배포
4. SQS 장애·중복 전달 통합 테스트
5. Event Writer Lambda와 S3 적재

### 2026-06-21

완료:

- Outbox `SKIP LOCKED` batch claim 구현
- Publisher success/failure 상태 전이
- 지수 backoff 재시도와 max attempts
- 만료 lease 자동 복구
- Outbox 운영 metric
- 이벤트 전용 SQS/DLQ/CloudWatch Alarm Terraform
- IRSA 발행 최소 권한
- Outbox 단위 테스트 총 6개 통과
- Terraform validate와 target plan 검증

남은 검증:

- 실제 PostgreSQL Flyway V5 실행
- 실제 SQS 발행과 Outbox `PUBLISHED`
- SQS 장애 시 `FAILED → retry → PUBLISHED`
- 중복 전달 consumer 멱등성

### 2026-06-22

완료:

- Flyway V5 중복 idempotency key migration 장애 수정 및 실제 적용
- `event_outbox` 생성, Publisher 기동, ticket-service schema validation 확인
- Event Writer Lambda와 S3 보안·lifecycle 구성
- 잘못된 JSON 재시도 후 DLQ 격리와 정상 JSON S3 적재 검증
- Glue Data Catalog, Partition Projection, Athena Workgroup 구성
- 일별 이벤트 수, 평균 대기시간, 예약 전환율 query 실행
- 실제 waiting-room API를 통한 대기열 진입·토큰 발급 이벤트 E2E
- Capacity Advisor와 JSON/Markdown 보고서 구현
- 합성 표본 152건 적재 및 producer 분리
- 최소 표본 보류, DB 압력 분리, STOP, 25% 증가 제한 테스트

현재 남은 작업:

1. 실제 부하 테스트로 예약 확정 처리량과 Pod당 처리량 측정
2. 실제 부하 테스트 producer만 사용해 Capacity Advisor 재실행
3. Python pool 및 자동 감속 Alert Rule의 Slack E2E 확인
4. 자동 감속 장애 대응 Runbook 완성
5. 발표용 AWS 콘솔·Athena·보고서 화면 캡처
6. 전체 데모 리허설 후 신규 기능 동결

선택 고도화:

- 승인형 DLQ redrive
- Bedrock 기반 보고서 자연어 요약
- Read Replica 설계와 RDS Proxy 타당성 문서
- RDS 암호화 및 Valkey TLS/AUTH 전환
