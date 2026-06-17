# DR 발표 요약

이 문서는 Baselink 프로젝트 발표에서 재해복구와 데이터 안정성 파트를 설명하기 위한 요약 자료입니다.

상세 설계와 운영 절차는 아래 문서를 기준으로 합니다.

- 전체 DR 전략: `docs/disaster-recovery-strategy.md`
- AWS Backup 설계: `docs/aws-backup-design.md`
- AWS Backup 복구 Runbook: `docs/aws-backup-restore-runbook.md`
- DB Connection Pool 전략: `docs/db-connection-pool-strategy.md`
- RDS PITR Runbook: `modules/rds/RUNBOOK.md`
- SQS 운영 문서: `modules/sqs/README.md`

## 1. 발표 핵심 메시지

Baselink는 티켓 예매 서비스 특성상 경기 오픈 시점에 트래픽이 몰리고, 좌석/예약 데이터의 정합성이 중요합니다.

그래서 데이터/비동기 처리 영역에서는 단순히 리소스를 만드는 것보다 다음 세 가지를 목표로 설계했습니다.

1. 장애가 나도 서비스가 바로 죽지 않도록 이중화한다.
2. 데이터가 손상되거나 삭제되어도 복구할 수 있게 백업한다.
3. 백업이 실제로 복구 가능한지 리허설로 검증한다.

## 2. 현재 안정성 구성 요약

| 영역 | 현재 구성 | 기대 효과 |
| --- | --- | --- |
| RDS PostgreSQL | Multi-AZ, deletion protection, final snapshot, automated backup 7일, AWS Backup daily snapshot | DB 장애와 실수 삭제에 대비 |
| Valkey ElastiCache | primary + replica, Multi-AZ, automatic failover | 대기열/캐시 계층의 AZ 장애 대비 |
| SQS | 원본 큐, DLQ, redrive allow policy, backlog/DLQ CloudWatch Alarm | 비동기 처리 실패 격리와 재처리 가능 |
| GitOps/Terraform | 인프라와 배포 설정 코드화 | 장애 후 동일 환경 재구성 가능 |
| CloudWatch/SNS/Slack | RDS, Valkey, SQS 알람을 Slack으로 전달 | 장애 징후를 빠르게 인지 |
| AWS Backup | RDS daily snapshot 백업 중앙 관리 | 복구 지점 관리와 DR 확장 기반 |

## 3. RPO/RTO 목표

RPO는 장애가 났을 때 허용 가능한 데이터 손실 시간이고, RTO는 서비스 복구까지 허용 가능한 시간입니다.

| 장애 상황 | 목표 RPO | 목표 RTO | 대응 방식 |
| --- | --- | --- | --- |
| RDS 단일 AZ 장애 | 수초~수분 | 수분 | RDS Multi-AZ failover |
| RDS 데이터 손상/실수 삭제 | 5분 이내 또는 snapshot 시점 | 30~60분 | PITR 또는 AWS Backup restore |
| Valkey 노드/AZ 장애 | 캐시 데이터 성격에 따라 일부 손실 허용 | 15~30분 | replica 승격, 애플리케이션 재연결 |
| SQS worker 처리 실패 | 메시지 보존 기간 내 0 | 10~30분 | DLQ 격리 후 redrive |
| 서울 리전 장애 | 일 단위 snapshot 기준 | 수 시간 | DR 리전에 인프라 재구성 후 RDS snapshot restore |

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

복구 리허설 결과:

- 수행일: 2026-06-16
- Restore job ID: `ac3abb77-f3fa-41c7-a5c4-2d94bbb7bbe1`
- 복원 DB: `baselink-dev-postgres-restore-20260616`
- Restore 결과: `COMPLETED`
- 정리 결과: 임시 RDS 삭제 완료

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

현재 dev 환경은 서울 리전 단일 리전 기반입니다. 따라서 서울 리전 전체 장애를 자동으로 즉시 복구하는 active-active 구조는 아닙니다.

현실적인 전략은 Pilot Light 방식입니다.

Pilot Light 전략:

- 평상시에는 DR 리전에 최소 구성만 준비합니다.
- Terraform과 GitOps로 VPC, EKS, SQS, Valkey, backend를 재구성할 수 있게 합니다.
- RDS는 AWS Backup snapshot을 DR 리전으로 복사하는 방향으로 확장합니다.
- 장애 발생 시 DR 리전에 RDS를 복원하고 backend endpoint를 전환합니다.

비용 관점:

- active-active는 가장 빠르지만 비용과 복잡도가 큽니다.
- Pilot Light는 비용을 줄이면서 핵심 복구 경로를 준비할 수 있어 프로젝트 규모에 적합합니다.

## 7. 발표 흐름 예시

1. 예매 서비스에서는 좌석/예약 데이터가 가장 중요하다고 설명합니다.
2. RDS, Valkey, SQS가 각각 어떤 데이터를 담당하는지 설명합니다.
3. RDS는 영구 데이터, Valkey는 빠른 상태/캐시, SQS는 비동기 메시지라고 구분합니다.
4. 장애가 나지 않도록 Multi-AZ, replica, DLQ, alarm을 구성했다고 설명합니다.
5. 장애가 나도 복구할 수 있도록 PITR과 AWS Backup을 적용했다고 설명합니다.
6. 단순 설계가 아니라 실제 임시 RDS 복구 리허설을 수행했다고 강조합니다.
7. 리전 장애는 Pilot Light 전략으로 확장 가능하다고 마무리합니다.

## 8. 발표용 한 문장 요약

> Baselink의 데이터 계층은 RDS Multi-AZ, Valkey failover, SQS DLQ로 장애를 흡수하고, PITR과 AWS Backup으로 데이터 복구 지점을 확보했습니다. 특히 AWS Backup recovery point에서 임시 RDS를 실제 복구하고 EKS 내부에서 데이터를 검증해, 백업이 실제 복구 가능한 상태임을 확인했습니다.

## 9. 향후 개선 계획

| 개선 항목 | 목적 | 우선순위 |
| --- | --- | --- |
| RDS Read Replica 검토 | 경기/좌석 조회 트래픽 분산 | 중 |
| 서비스별 Hikari pool size 분리 | scale-out 시 RDS connection 고갈 방지 | 높음 |
| RDS connection alarm threshold 재조정 | 현재 RDS `max_connections`에 맞는 조기 경보 | 완료 |
| AWS Backup cross-region copy | 서울 리전 장애 대비 | 중 |
| Valkey snapshot 정책 검토 | 캐시/대기열 장애 복구 선택지 확대 | 중 |
| SQS SSE 명시 관리 | 메시지 암호화 정책 명확화 | 중 |
| DR 리전 tfvars 초안 | 리전 장애 시 인프라 재구성 시간 단축 | 낮음 |

