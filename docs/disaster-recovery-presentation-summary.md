# DR 발표 요약

이 문서는 Baselink 프로젝트 발표에서 재해복구와 데이터 안정성 파트를 설명하기 위한 요약 자료입니다.

최종 상태 확인일: 2026-06-22

상세 설계와 운영 절차는 아래 문서를 기준으로 합니다.

- 전체 DR 전략: `docs/disaster-recovery-strategy.md`
- AWS Backup 설계: `docs/aws-backup-design.md`
- AWS Backup 복구 Runbook: `docs/aws-backup-restore-runbook.md`
- DB Connection Pool 전략: `docs/db-connection-pool-strategy.md`
- Data & Async 전체 현황: `docs/data-async-status-roadmap.md`
- Ticket Event/Outbox 설계: `docs/ticket-reliability-event-outbox-design.md`
- RDS PITR Runbook: `modules/rds/RUNBOOK.md`
- SQS 운영 문서: `modules/sqs/README.md`

## 1. 발표 핵심 메시지

Baselink는 티켓 예매 서비스 특성상 경기 오픈 시점에 트래픽이 몰리고, 좌석/예약 데이터의 정합성이 중요합니다.

그래서 데이터/비동기 처리 영역에서는 단순히 리소스를 만드는 것보다 다음 네 가지를 목표로 설계했습니다.

1. 장애가 나도 서비스가 바로 죽지 않도록 이중화한다.
2. 데이터가 손상되거나 삭제되어도 복구할 수 있게 백업한다.
3. 백업이 실제로 복구 가능한지 리허설로 검증한다.
4. 트래픽이 몰릴 때 DB 한계 안에서 자동으로 유입량을 제어한다.

## 2. 현재 안정성 구성 요약

| 영역 | 현재 구성 | 기대 효과 |
| --- | --- | --- |
| RDS PostgreSQL | Multi-AZ, deletion protection, final snapshot, automated backup 7일, AWS Backup daily snapshot | DB 장애와 실수 삭제에 대비 |
| Valkey ElastiCache | primary + replica, Multi-AZ, automatic failover | 대기열/캐시 계층의 AZ 장애 대비 |
| SQS | 원본 큐, DLQ, redrive allow policy, backlog/DLQ CloudWatch Alarm | 비동기 처리 실패 격리와 재처리 가능 |
| GitOps/Terraform | 인프라와 배포 설정 코드화 | 장애 후 동일 환경 재구성 가능 |
| CloudWatch/SNS/Slack | RDS, Valkey, SQS 알람을 Slack으로 전달 | 장애 징후를 빠르게 인지 |
| AWS Backup | RDS daily snapshot 백업 중앙 관리 | 복구 지점 관리와 DR 확장 기반 |
| DB Connection Budget | Spring/Python pool과 KEDA maxReplicaCount를 app budget 60 안에 적용 | scale-out 중 RDS connection 고갈 예방 |
| RDS-aware Admission | RDS connection 40/50/55/60 단계별 대기열 자동 감속 | DB 위험 구간 진입 전 신규 트래픽 제어 |
| Python DB Pool 관측 | pool 사용량, 여유, timeout, p95 대기시간 Prometheus/Grafana 연동 | Python 서비스 connection 병목 조기 확인 |

## 3. RPO/RTO 목표

RPO는 장애가 났을 때 허용 가능한 데이터 손실 시간이고, RTO는 서비스 복구까지 허용 가능한 시간입니다.

| 장애 상황 | 목표 RPO | 목표 RTO | 대응 방식 |
| --- | --- | --- | --- |
| RDS 단일 AZ 장애 | 수초~수분 | 수분 | RDS Multi-AZ failover |
| RDS 데이터 손상/실수 삭제 | 5분 이내 또는 snapshot 시점 | 30~60분 | PITR 또는 AWS Backup restore |
| Valkey 노드/AZ 장애 | 캐시 데이터 성격에 따라 일부 손실 허용 | 15~30분 | replica 승격, 애플리케이션 재연결 |
| SQS worker 처리 실패 | 메시지 보존 기간 내 0 | 10~30분 | DLQ 격리 후 redrive |
| 서울 리전 장애 | daily copy 기준 최대 24시간 | 2~4시간 | 도쿄 Pilot Light 재구성 후 RDS recovery point restore |

## 4. 장애 유형별 설명

### 4.1 RDS 장애

RDS는 예매 시스템의 최종 데이터를 저장하는 가장 중요한 계층입니다.

대응 전략:

- Multi-AZ로 primary 장애 시 standby로 failover합니다.
- 삭제 방지를 위해 deletion protection을 활성화했습니다.
- 삭제가 필요한 경우에도 final snapshot을 남겨 마지막 복구 지점을 확보합니다.
- RDS native automated backup을 7일 보존하도록 설정했습니다.
- AWS Backup으로 daily snapshot을 별도 중앙 정책으로 관리합니다.

발표 포인트:

> RDS는 Multi-AZ로 장애를 흡수하고, PITR과 AWS Backup으로 데이터 손상 시점 전으로 되돌릴 수 있게 설계했습니다. 또한 실제 Recovery Point에서 임시 RDS를 복구해 백업의 실효성을 검증했습니다.

### 4.2 Valkey 장애

Valkey는 대기열, 좌석 잠금, 캐시처럼 빠른 응답이 필요한 데이터를 담당합니다.

대응 전략:

- primary와 replica를 구성합니다.
- Multi-AZ와 automatic failover로 한 AZ 장애에 대비합니다.
- TTL 기반 데이터는 영구 복구보다 만료/재시도/재진입 설계를 우선합니다.
- 중요한 영구 데이터는 Valkey가 아니라 RDS에 저장합니다.

발표 포인트:

> Valkey는 빠른 대기열 처리와 캐시를 담당하지만, 최종 진실 데이터는 RDS에 둡니다. 장애 시 캐시는 재생성 가능하게 보고, Valkey는 Multi-AZ failover로 가용성을 확보했습니다.

### 4.3 SQS 장애 또는 worker 처리 실패

SQS는 예매 요청처럼 비동기로 처리할 수 있는 작업을 안전하게 전달하는 계층입니다.

대응 전략:

- worker가 메시지 처리를 반복 실패하면 DLQ로 격리합니다.
- DLQ 메시지는 원인 확인 후 redrive 절차로 원본 큐에 재처리할 수 있습니다.
- 원본 큐 backlog와 DLQ 메시지 수를 CloudWatch Alarm으로 감시합니다.
- Slack 알림으로 운영자가 빠르게 인지할 수 있게 했습니다.

발표 포인트:

> SQS는 실패한 요청을 바로 버리지 않고 DLQ에 격리합니다. 장애가 해결되면 redrive로 재처리할 수 있어 비동기 처리의 유실 가능성을 줄였습니다.

## 5. 실제 검증 완료 항목

| 검증 항목 | 결과 |
| --- | --- |
| AWS Backup vault 생성 확인 | 완료 |
| AWS Backup plan/selection 생성 확인 | 완료 |
| daily recovery point 생성 확인 | 완료 |
| on-demand backup 생성 확인 | 완료 |
| recovery point에서 임시 RDS restore | 완료 |
| EKS 내부 Pod에서 복원 DB 접속 | 완료 |
| 주요 schema/table/row count 검증 | 완료 |
| 임시 restore DB 삭제 | 완료 |
| 2026-06-22 daily backup 및 recovery point 8개 확인 | 완료 |
| Backup/Copy/Restore 실패 EventBridge 배포 | 완료 |
| 명시 시점 RDS native PITR 복원 | 완료 |
| PITR DB Flyway/schema/data 검증 | 완료 |
| PITR endpoint 기반 ticket-service smoke test | 완료 |
| KEDA maxReplicaCount connection budget 적용 | 완료 |
| Python bounded DB pool 배포 및 RDS 연결 검증 | 완료 |
| RDS 감속 NORMAL~STOP 단계별 통합 테스트 | 완료 |
| Python DB pool metric Prometheus 수집 | 완료 |

복구 리허설 결과:

- 수행일: 2026-06-16
- Restore job ID: `ac3abb77-f3fa-41c7-a5c4-2d94bbb7bbe1`
- 복원 DB: `baselink-dev-postgres-restore-20260616`
- Restore 결과: `COMPLETED`
- 정리 결과: 임시 RDS 삭제 완료

PITR 리허설 결과:

- 수행일: 2026-06-22
- 최신 복구 가능 시각 지연: 약 3분 28초
- 지정 복원 시점: 2026-06-22 15:39:24 KST
- DB 인프라 복구 시간: 약 7분 21초
- Hikari connection과 Spring Boot 기동 성공
- Actuator health `UP`
- 읽기 API 호출 성공
- 운영 DB와 운영 Deployment 변경 없음
- 임시 Pod와 RDS 삭제 완료

검증한 주요 데이터:

| 테이블 | row count |
| --- | ---: |
| `auth_schema.users` | 5 |
| `chatbot_schema.faq` | 7 |
| `game_schema.games` | 3 |
| `game_schema.seat_sections` | 25 |
| `game_schema.stadiums` | 5 |
| `ticket_schema.seats` | 1000 |
| `ticket_schema.game_seats` | 600 |
| `ticket_schema.reservations` | 8 |

## 6. 리전 장애 전략

현재 dev 환경은 서울 리전 단일 리전 기반입니다. 따라서 서울 리전 전체 장애를 자동으로 즉시 복구하는 active-active 구조는 아닙니다. DR 리전은 도쿄(`ap-northeast-1`)로 정하고 Pilot Light 구현을 진행합니다.

현실적인 전략은 Pilot Light 방식입니다.

Pilot Light 전략:

- 평상시에는 DR 리전에 최소 구성만 준비합니다.
- Terraform과 GitOps로 VPC, EKS, SQS, Valkey, backend를 재구성할 수 있게 합니다.
- RDS daily recovery point를 도쿄 backup vault로 복사합니다.
- 장애 발생 시 DR 리전에 RDS를 복원하고 backend endpoint를 전환합니다.

비용 관점:

- active-active는 가장 빠르지만 비용과 복잡도가 큽니다.
- Pilot Light는 비용을 줄이면서 핵심 복구 경로를 준비할 수 있어 프로젝트 규모에 적합합니다.

## 7. DB connection budget 기반 안정성 설계

KEDA와 Karpenter는 트래픽이 몰릴 때 pod와 node를 늘려줍니다. 하지만 RDS connection 수는 무한하지 않기 때문에, pod가 너무 많이 늘어나면 오히려 DB connection 고갈이 먼저 발생할 수 있습니다.

현재 dev RDS 기준:

| 항목 | 값 |
| --- | ---: |
| RDS instance class | `db.t4g.micro` |
| PostgreSQL `max_connections` | 79 |
| 운영/관리/마이그레이션 여유분 | 약 19 |
| app connection budget | 약 60 |

적용/설계한 내용:

- Spring Boot 서비스별 Hikari pool size를 역할별로 분리했습니다.
- 예매 핵심 쓰기 경로인 `ticket-service`에 pool을 우선 배정했습니다.
- 대기열/관리 서비스는 작은 pool을 사용하게 해 DB 부담을 낮췄습니다.
- KEDA maxReplicaCount를 Spring과 Python 서비스 전체의 `replica x pool <= 60` 기준으로 조정했습니다.
- RDS connection이 40/50/55/60에 도달하면 대기열 입장량을 75%/50%/25%/0%로 자동 감속하도록 구현했습니다.
- Python 서비스도 요청마다 connection을 새로 만들던 구조에서 bounded psycopg2 pool로 변경했습니다.

KEDA 변경안:

| 서비스 | maxReplicaCount | pod당 max pool | 최대 connection |
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

발표 포인트:

> 단순히 pod를 많이 늘리는 것이 아니라, RDS가 안전하게 감당할 수 있는 connection budget을 먼저 계산하고 그 안에서 Hikari pool과 KEDA maxReplicaCount를 설계했습니다.

추가 검증:

- Python 서비스는 Pod당 최대 connection을 1개로 제한했습니다.
- 반복 API 호출 후 `order-service=2`, `ai-chatbot-service=1` connection을 확인했습니다.
- `idle in transaction=0`을 확인했습니다.
- 대기열 기본 입장량 40명/분이 DB 압력 단계에 따라 `40→30→20→10→0`으로 감속되는 것을 검증했습니다.

발표 포인트:

> 컴퓨팅 확장량과 DB connection 상한을 함께 계산하고, 한계에 가까워지면 진행 중인 예약은 유지한 채 신규 입장만 단계적으로 줄이는 폐루프형 admission control을 구현했습니다.

## 8. 발표 가능한 주요 트러블슈팅

| 문제 | 원인 | 해결 | 발표 포인트 |
| --- | --- | --- | --- |
| 새 RDS에서 서비스 기동 실패 | schema/table 생성이 수동 절차와 Hibernate에 분산 | Flyway migration과 `ddl-auto=validate`로 전환 | DB 구조를 코드와 이력으로 재현 |
| Worker의 SQS 인증 실패 | 테스트 credential이 애플리케이션 설정에 고정 | 고정 credential 제거, IRSA credential chain 사용 | Pod 단위 최소 권한 적용 |
| 새 이미지가 배포되지 않음 | 가변 `dev` tag와 노드 image cache | commit 기반 image tag와 pull 정책 적용 | 배포 결과를 tag와 rollout으로 검증 |
| 대기 인원 0인데 최대 5분 대기 | 분당 입장량과 token TTL을 같은 개념으로 계산 | 분당 Redis counter와 좌석 선택 token TTL 분리 | Rate limit과 권한 TTL의 책임 분리 |
| Python connection 증가 상한 없음 | 요청마다 `psycopg2.connect()` 수행 | bounded pool, timeout, rollback 적용 | 언어별 DB client 특성을 connection budget에 포함 |
| Prometheus 서비스 구분 실패 | Kubernetes target의 `service` label과 애플리케이션 label 충돌 | `exported_service` label 사용 | metric label 충돌까지 실제 수집 단계에서 검증 |
| AWS Backup restore 명령 실패 | PowerShell에서 metadata JSON quoting 손상 | 구조화된 metadata 전달 방식으로 변경 | 복구 Runbook은 실제 셸 환경까지 검증 |
| Flyway V5 배포 후 신규 Pod 기동 실패 | 기존 예약 데이터에 중복 idempotency key 존재 | 예약 행은 보존하고 대표 key만 남긴 뒤 unique index 생성 | Migration은 기존 데이터 품질까지 고려해야 함 |
| Event Writer E2E에서 S3 객체 미생성 | PowerShell이 SQS JSON 내부 따옴표를 제거 | 인자 배열을 보존해 JSON 전달, Lambda log로 입력 오류 확인 | 비동기 장애는 Producer·Queue·Consumer 구간을 나눠 진단 |

## 9. 발표 흐름 예시

1. 예매 서비스에서는 좌석/예약 데이터가 가장 중요하다고 설명합니다.
2. RDS, Valkey, SQS가 각각 어떤 데이터를 담당하는지 설명합니다.
3. RDS는 영구 데이터, Valkey는 빠른 상태/캐시, SQS는 비동기 메시지라고 구분합니다.
4. 장애가 나지 않도록 Multi-AZ, replica, DLQ, alarm을 구성했다고 설명합니다.
5. 장애가 나도 복구할 수 있도록 PITR과 AWS Backup을 적용했다고 설명합니다.
6. 단순 설계가 아니라 실제 임시 RDS 복구 리허설을 수행했다고 강조합니다.
7. KEDA/Hikari를 RDS connection budget 안에서 설계해 장애를 예방했다고 설명합니다.
8. RDS 압력에 따라 대기열 입장량이 자동 감속되는 결과를 보여줍니다.
9. 개인 고도화에서는 Transactional Outbox부터 S3/Athena 분석과 안전 입장량 보고서까지의 E2E 결과를 설명합니다.
10. 리전 장애는 Pilot Light 전략으로 확장 가능하다고 마무리합니다.

## 10. 발표용 한 문장 요약

> Baselink의 데이터 계층은 RDS Multi-AZ, Valkey failover, SQS DLQ로 장애를 흡수하고 PITR과 AWS Backup으로 복구 지점을 확보했습니다. 여기에 DB connection budget과 대기열 자동 감속을 적용하고 실제 복원·감속·connection 검증까지 수행해, 장애 예방과 복구 가능성을 함께 확인했습니다.

개인 프로젝트 한 문장:

> 예매와 대기열 이벤트를 Transactional Outbox부터 S3/Athena까지 신뢰성 있게 전달하고, 실제 처리량을 바탕으로 운영자가 검토할 안전 입장량과 계산 근거를 생성했습니다.

## 11. 향후 개선 계획

| 개선 항목 | 목적 | 우선순위 |
| --- | --- | --- |
| RDS Read Replica 검토 | 경기/좌석 조회 트래픽 분산 | 중 |
| 서비스별 Hikari pool size 분리 | scale-out 시 RDS connection 고갈 방지 | 완료 |
| KEDA maxReplicaCount DB budget 반영 | RDS connection budget 안에서 autoscaling 제한 | 완료 |
| Python DB connection pool 제한 | Python 서비스의 순간 connection 증가 방지 | 배포 및 RDS 검증 완료 |
| Python DB pool Grafana 패널 | pool 사용량과 획득 지연 관측 | 완료 |
| Python DB pool Alert Rule | pool 고갈과 timeout 알림 | 진행 중 |
| RDS connection 기반 대기열 자동 감속 | DB 위험 구간에서 신규 입장량 자동 조절 | 단계별 통합 검증 완료 |
| 자동 감속 장애 대응 Runbook | STOP/fallback/복구 운영 절차 | 진행 예정 |
| Ticket Event Transactional Outbox | DB commit과 이벤트 발행 사이 유실 구간 제거 | 배포 및 Flyway/Publisher 검증 완료 |
| Event Writer와 S3 적재 | 이벤트를 중복에 안전한 분석 데이터로 보존 | SQS→Lambda→S3 E2E 검증 완료 |
| Glue/Athena 이벤트 분석 | 유입·대기시간·예약 전환율 계산 | Partition Projection과 핵심 query 검증 완료 |
| Capacity Advisor | 처리량 근거가 있는 입장 정책 추천 | JSON/Markdown 보고서와 합성 표본 검증 완료 |
| 실제 부하 테스트 기반 Advisor 재계산 | 합성 수치 대신 운영 가능한 근거 확보 | 진행 예정 |
| RDS connection alarm threshold 재조정 | 현재 RDS `max_connections`에 맞는 조기 경보 | 완료 |
| Backup/Restore 실패 알림 | 백업 실패 조기 발견 | EventBridge transformer, SNS 권한, 전달 지표 검증 완료 |
| RDS PITR와 복원 endpoint smoke test | 논리 장애 복구 및 연결 전환 증명 | 완료, DB RTO 약 7분 21초 |
| AWS Backup 도쿄 cross-region copy | 서울 리전 장애 대비 | Terraform 구현·plan 완료, 배포 대기 |
| Valkey snapshot 정책 검토 | 캐시/대기열 장애 복구 선택지 확대 | 중 |
| SQS SSE 명시 관리 | 메시지 암호화 정책 명확화 | 중 |
| DR 리전 Terraform plan | 리전 장애 시 인프라 재구성 시간 단축 | P1 최우선 |

