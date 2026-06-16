# DR 발표 요약

이 문서는 Baselink 프로젝트 발표에서 재해복구와 데이터 안정성 파트를 설명하기 위한 요약 자료입니다.

상세 설계와 운영 절차는 아래 문서를 기준으로 합니다.

- 전체 DR 전략: `docs/disaster-recovery-strategy.md`
- AWS Backup 설계: `docs/aws-backup-design.md`
- AWS Backup 복구 Runbook: `docs/aws-backup-restore-runbook.md`
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

## 9. 지금까지 완료한 고도화 작업

아래 항목은 발표에서 "처음에는 수동 운영에 가까웠지만, 점진적으로 안정성과 복구 가능성을 높였다"는 흐름으로 설명할 수 있습니다.

| 작업 | 문제 의식 | 개선 결과 | 발표 포인트 |
| --- | --- | --- | --- |
| Flyway 기반 DB migration/seed 구조 정리 | RDS를 재생성하면 schema와 초기 데이터가 사라짐 | schema/table/seed 데이터를 반복 가능하게 적용 | DB 초기화가 사람의 기억이 아니라 코드와 migration 이력으로 관리됨 |
| RDS Multi-AZ 활성화 | DB 인스턴스/AZ 장애 시 서비스 중단 위험 | standby 인스턴스로 failover 가능 | 인스턴스 장애와 AZ 장애를 인프라 차원에서 흡수 |
| RDS deletion protection/final snapshot | 실수로 RDS가 삭제될 위험 | 삭제 보호와 최종 스냅샷으로 안전장치 추가 | `terraform destroy`나 실수 삭제로부터 핵심 데이터 보호 |
| RDS automated backup/PITR | 논리적 장애나 실수 삭제 시 복구 지점 필요 | 7일 보존 기반 특정 시점 복구 가능 | Multi-AZ는 장애 대응, PITR은 데이터 오염 대응이라는 차이를 설명 가능 |
| AWS Backup 도입 | RDS 백업 정책을 중앙에서 관리할 필요 | Backup vault/plan/selection으로 daily snapshot 관리 | DR 리전 cross-region copy로 확장 가능한 기반 마련 |
| AWS Backup restore 리허설 | 백업이 실제로 복구 가능한지 검증 필요 | 임시 RDS 복구, EKS 내부 접속, row count 검증 완료 | 단순 설정이 아니라 실제 복구 가능성을 증명 |
| Redis에서 Valkey로 전환 | Redis 호환 오픈소스 캐시 엔진 기반 정리 | Valkey 8.2 기반 ElastiCache 구성 | 대기열/좌석 lock/캐시 계층을 최신 Redis 호환 엔진으로 운영 |
| Valkey Multi-AZ/failover | 캐시 primary 장애 시 대기열/lock 계층 영향 | replica와 automatic failover 구성 | 캐시 계층도 단일 장애점이 되지 않게 설계 |
| SQS DLQ/redrive 구성 | worker 실패 메시지가 유실되거나 정상 처리를 막을 위험 | 실패 메시지를 DLQ로 격리하고 redrive 가능 | 실패를 버리지 않고 격리 후 재처리하는 비동기 안정성 확보 |
| SQS backlog/DLQ alarm | 큐 적체와 실패 메시지를 늦게 발견할 위험 | CloudWatch Alarm과 Slack 알림 구성 | 처리 지연과 최종 실패를 조기에 감지 |
| RDS/Valkey alarm | CPU, memory, connection, eviction, replication lag 이상 감지 필요 | 주요 지표 기반 CloudWatch Alarm 구성 | 장애 발생 전 이상 징후를 관측 가능 |
| Amazon Q Developer Slack 연동 | AWS 콘솔을 직접 보지 않으면 알람 인지가 느림 | CloudWatch Alarm을 Slack 채널로 전달 | 팀 전체가 같은 채널에서 장애/복구 알림 확인 |
| KEDA용 DB reader 권한 분리 | KEDA가 관리자 계정으로 DB를 조회하면 권한이 과함 | `keda_reader` 계정과 `postgres-keda-secret`로 읽기 전용 접근 | autoscaling 조회도 최소 권한 원칙으로 관리 |
| KEDA SQS scaler IAM 권한 정리 | 실제 KEDA가 사용하는 IAM Role과 문서/권한 위치가 혼동됨 | Pod Identity Role 기준으로 SQS 조회 권한 필요성을 문서화 | Kubernetes autoscaling과 AWS IAM 연결 구조를 이해하고 정리 |

## 10. 발표 가능한 트러블슈팅

사소한 명령어 실수보다, 설계 판단이나 운영 안정성으로 이어진 트러블슈팅만 발표 소재로 사용합니다.

### 10.1 Flyway seed 데이터 전환 후 화면 데이터가 달라진 문제

상황:

- 기존 `seed-dev.sql`과 Flyway repeatable seed의 데이터가 달라 브라우저 화면의 경기/좌석/구역/메뉴가 영어로 보였습니다.
- 좌석 선택 화면에서 기대한 구역별 좌석 배치가 나오지 않는 문제도 확인했습니다.

해결:

- 기존 한글 dev seed 데이터와 실제 화면에서 필요한 좌석/경기좌석 구조를 Flyway seed 기준으로 맞췄습니다.
- 복구 후에는 경기 목록, 좌석 선택, 관리자 기능이 정상 동작하는지 브라우저에서 확인했습니다.

발표 포인트:

> DB seed는 단순 테스트 데이터가 아니라 프론트 화면과 업무 흐름을 재현하는 기준 데이터입니다. Flyway 전환 과정에서 데이터 구조와 화면 동작을 함께 검증해, migration이 실제 서비스 동작까지 보장하도록 정리했습니다.

### 10.2 Terraform apply가 Kubernetes Secret을 다시 덮어쓸 수 있는 문제

상황:

- 실제 EKS에는 `postgres-keda-secret`을 `keda_reader` 계정으로 바꿨지만, Terraform addon 코드는 여전히 관리자 계정 기준 Secret을 만들 수 있는 상태였습니다.
- 이 상태에서 나중에 `terraform apply`가 실행되면 운영자가 수동으로 바꾼 Secret이 다시 관리자 계정으로 되돌아갈 수 있었습니다.

해결:

- 실제 클러스터 상태와 Terraform 코드의 desired state를 맞추는 방향으로 정리했습니다.
- KEDA는 필요한 테이블만 읽을 수 있는 `keda_reader` 계정과 전용 Secret을 사용하도록 했습니다.

발표 포인트:

> Kubernetes에서 수동 변경은 당장 동작하게 만들 수 있지만, Terraform이 관리하는 리소스라면 다음 apply 때 덮어써질 수 있습니다. 그래서 실제 상태와 IaC 코드를 일치시켜 운영 드리프트를 줄였습니다.

### 10.3 AWS Backup restore는 기존 DB를 되감는 작업이 아니라 새 DB를 만드는 작업

상황:

- 백업 복구를 처음 이해할 때 기존 운영 RDS가 바로 과거 시점으로 되돌아가는 것으로 오해할 수 있습니다.

정리:

- AWS Backup restore와 RDS PITR은 기존 DB를 직접 덮어쓰지 않고, Recovery Point 또는 특정 시점 기준으로 새 RDS 인스턴스를 생성합니다.
- 복구된 DB를 검증한 뒤 일부 데이터만 복구할지, endpoint를 전환할지 결정합니다.

발표 포인트:

> 복구는 곧바로 운영 DB를 바꾸는 위험한 작업이 아니라, 새 DB를 복원하고 검증한 뒤 전환 여부를 판단하는 절차로 설계했습니다.

### 10.4 AWS Backup restore 리허설 중 PowerShell JSON 전달 문제

상황:

- `aws backup start-restore-job --metadata`에 인라인 JSON을 넘길 때 PowerShell에서 따옴표가 깨져 AWS CLI가 JSON을 파싱하지 못했습니다.

해결:

- metadata를 임시 JSON 파일로 저장한 뒤 `--metadata file://<path>` 형식으로 전달해 Restore Job을 정상 시작했습니다.

발표 포인트:

> 실제 리허설을 해보면서 문서만으로는 드러나지 않는 CLI/운영 환경 차이를 발견했고, Windows PowerShell 기준으로 안정적인 복구 명령 방식을 Runbook에 반영했습니다.

### 10.5 KEDA 권한은 "권한이 있는 Role"이 아니라 "실제로 Pod가 사용하는 Role"에 있어야 하는 문제

상황:

- KEDA SQS scaler가 큐 길이를 읽으려면 SQS 조회 권한이 필요합니다.
- 단순히 어떤 IAM Role에 권한을 추가하는 것만으로는 부족하고, KEDA operator Pod가 실제로 사용하는 Role에 권한이 있어야 합니다.

정리:

- dev 환경에서는 KEDA operator가 EKS Pod Identity Association을 통해 `curve-keda-cloudwatch` Role을 사용하는 구조로 정리했습니다.
- 따라서 CloudWatch metric 조회 권한과 SQS queue 조회 권한은 같은 실제 실행 Role 기준으로 관리해야 합니다.

발표 포인트:

> Kubernetes autoscaling과 AWS IAM은 연결 지점이 중요합니다. 권한을 추가했는지가 아니라, 실제 Pod가 그 권한을 가진 Role로 AWS API를 호출하는지가 핵심이라는 점을 정리했습니다.

## 11. 향후 개선 계획

| 개선 항목 | 목적 | 우선순위 |
| --- | --- | --- |
| RDS Read Replica 검토 | 경기/좌석 조회 트래픽 분산 | 중 |
| DB connection pool 계산 문서화 | scale-out 시 RDS connection 고갈 방지 | 높음 |
| AWS Backup cross-region copy | 서울 리전 장애 대비 | 중 |
| Valkey snapshot 정책 검토 | 캐시/대기열 장애 복구 선택지 확대 | 중 |
| SQS SSE 명시 관리 | 메시지 암호화 정책 명확화 | 중 |
| DR 리전 tfvars 초안 | 리전 장애 시 인프라 재구성 시간 단축 | 낮음 |

