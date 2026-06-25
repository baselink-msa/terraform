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

마지막 업데이트: `2026-06-25`

| 영역 | 상태 | 요약 |
| --- | --- | --- |
| RDS PostgreSQL | 검증 완료 | Multi-AZ, PITR, AWS Backup, Flyway, application DB 계정 분리까지 완료 |
| SQS 비동기 처리 | 검증 완료 | ticket-confirm, ticket-domain-events 큐/DLQ/알람 구성 |
| Valkey | 배포 | Multi-AZ primary/replica, automatic failover 구성 |
| Backup/Restore | 검증 완료 | AWS Backup, PITR, 임시 RDS 복원, Flyway/schema/data 검증 완료 |
| DR | 일부 검증 완료 | 도쿄 cross-region backup, Pilot Light network, 도쿄 RDS 복원 검증 완료 |
| DB Connection Pool | 검증 완료 | Spring/Python/KEDA connection budget과 RDS-aware 감속 구현 |
| 운영 알림 | 일부 검증 완료 | Slack 알림 경로 확인, Python DB pool 전용 패널/알림은 모니터링 담당자 협업 |
| Outbox Event Pipeline | MVP 검증 완료 | Outbox→SQS→Lambda→S3→Athena→Capacity Advisor 기반 구현 |
| Kafka/MSK 개인 프로젝트 | Phase 2 일부 완료 | MSK Serverless, IAM client smoke test, topic 5개 생성, backend Kafka config 주입과 Pod 환경변수 검증 완료 |
| 발표 문서 | 진행 중 | DR/Backup/Outbox/Kafka 문서가 있으며 최종 발표용 캡처와 요약 보강 필요 |

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
- Backend producer와 Kafka dual publish는 아직 구현하지 않았다.
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
Phase 1+ 완료
-> MSK Serverless 인프라 생성
-> EKS 내부 네트워크 접근 검증
-> AWS_MSK_IAM client smoke test 검증
-> Kafka topic 5개 생성과 목록 조회 검증
-> Backend/GitOps Kafka config 주입
-> backend Pod Kafka 환경변수 검증
```

다음 단계:

```text
Phase 2 준비
-> Outbox publisher dual publish
```

## 7. 남은 작업 우선순위

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

### P0 다음: ticket outbox publisher dual publish

목표:

- Backend 서비스가 Kafka bootstrap broker와 topic 목록을 사용할 수 있게 한다.

선택지:

1. GitOps Secret/ConfigMap으로 주입
2. External Secrets로 Secrets Manager 값을 Kubernetes Secret에 동기화
3. 서비스가 AWS SDK로 Secrets Manager를 직접 조회

추천:

- 발표와 운영 명확성을 위해 External Secrets 또는 GitOps Secret 동기화 방식이 좋다.

### P1: ticket outbox publisher dual publish

목표:

- 기존 SQS 발행은 유지한다.
- Kafka에도 같은 event envelope를 발행한다.
- Kafka publish 실패가 예약/예매 핵심 transaction을 실패시키지 않도록 한다.

중요 원칙:

```text
SQS는 안정 처리 경로,
Kafka는 이벤트 스트리밍/분석 경로다.
```

### P2: waiting-room-service 이벤트 publish

목표:

- 대기열 진입, 입장권 발급, admission decision 이벤트를 Kafka에 발행한다.
- 안전 입장량 추천과 연결할 데이터를 확보한다.

### P2: Kafka to S3/Athena sink

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
현재 Kafka/MSK Serverless Phase 1, Kafka topic bootstrap, Backend/GitOps Kafka config 주입과 Pod 환경변수 검증까지 완료됐고, 다음 작업은 ticket-service Outbox publisher dual publish부터 이어가면 돼.
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
