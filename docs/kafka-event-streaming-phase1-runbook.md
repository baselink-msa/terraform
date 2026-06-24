# Kafka Event Streaming Phase 1 Runbook

## 1. 목적

이 문서는 Baselink dev 환경에서 Kafka 이벤트 스트리밍 인프라의 첫 번째 실제 생성 단계를 안전하게 수행하기 위한 런북이다.

Phase 1의 목표는 애플리케이션 트래픽을 Kafka로 전환하는 것이 아니다. 목표는 다음 세 가지다.

1. Amazon MSK Serverless 클러스터를 생성한다.
2. EKS backend runtime이 IAM 인증으로 Kafka에 접근할 수 있는 네트워크/IAM 기반을 준비한다.
3. bootstrap broker와 topic 목록을 Secrets Manager에 저장해 이후 Backend/GitOps 연동 PR에서 재사용할 수 있게 한다.

즉, Phase 1은 “Kafka를 서비스 핵심 경로에 넣는 단계”가 아니라 “Kafka를 붙일 수 있는 인프라 레일을 까는 단계”다.

## 2. 현재 구조에서 Kafka의 위치

Kafka는 기존 SQS를 대체하지 않는다.

```text
예매 확정 명령 처리
-> SQS + ticket-worker 유지

예매/대기열/운영 이벤트 스트림
-> Kafka로 확장

장기 분석 저장
-> S3 + Glue + Athena 유지 또는 Kafka sink로 확장
```

따라서 Kafka 생성 중 문제가 생겨도 기존 예매 확정 SQS 경로는 그대로 유지되어야 한다.

## 3. 사전 조건

다음 PR이 main에 merge되어 있어야 한다.

- Kafka 이벤트 스트리밍 설계 문서
- `modules/msk-serverless`
- `env/dev/infra/kafka.tf`
- `enable_kafka_event_streaming` 변수

또한 dev infra Terraform apply 권한이 있는 GitHub Actions secret/variable을 수정할 수 있어야 한다.

## 4. 생성 절차

### 4.1 GitHub Actions 변수 수정

GitHub Repository Secrets의 `DEV_INFRA_TFVARS`에서 다음 값을 추가하거나 변경한다.

```hcl
enable_kafka_event_streaming = true
```

로컬 `terraform/env/dev/infra/terraform.tfvars`도 같은 값으로 맞추면 로컬 plan 확인이 쉬워진다.

주의:

- MSK Serverless는 비용이 발생할 수 있다.
- dev 환경 기본값은 의도적으로 `false`다.
- 발표/검증 일정에 맞춰 잠깐 켠 뒤, 필요 없으면 다시 `false`로 내릴 수 있다.

### 4.2 Terraform Plan 확인

GitHub Actions에서 `Terraform Plan Dev`를 실행한다.

예상되는 주요 생성 리소스:

- MSK Serverless cluster
- MSK용 Security Group
- EKS cluster security group에서 MSK IAM broker port `9098` 접근 허용 rule
- backend runtime IRSA Kafka policy
- Kafka runtime config Secrets Manager secret
- Kafka runtime config secret version

Plan에서 RDS, EKS, VPC endpoint, SQS, Valkey 등 Kafka와 무관한 큰 변경이 함께 보이면 apply하지 말고 먼저 원인을 확인한다.

### 4.3 Terraform Apply

Plan이 Kafka 관련 변경만 포함한다면 `Terraform Apply Dev`를 실행한다.

생성 완료 후 Terraform output에서 다음 값을 확인한다.

```text
kafka_event_streaming_cluster_arn
kafka_event_streaming_bootstrap_brokers_sasl_iam
kafka_event_streaming_config_secret_arn
```

## 5. AWS 콘솔 확인 포인트

### 5.1 Amazon MSK

AWS Console에서 다음을 확인한다.

```text
Amazon MSK
-> Serverless clusters
-> baselink-dev-event-streaming
```

확인할 항목:

- Cluster 상태가 `Active`인지
- Region이 `ap-northeast-2`인지
- VPC가 dev VPC인지
- subnet이 private data subnet인지
- Authentication이 IAM 기반인지

### 5.2 EC2 Security Group

MSK용 Security Group에서 inbound rule을 확인한다.

```text
TCP 9098
Source: EKS cluster security group
```

의미:

- EKS 내부 backend Pod가 IAM 인증 Kafka broker에 접근할 수 있다.
- 외부 public internet에서 Kafka broker로 직접 접근할 수 없다.

### 5.3 IAM

backend runtime IRSA role에 Kafka policy가 붙었는지 확인한다.

역할:

```text
baselink-dev-backend-runtime-irsa
```

확인할 권한:

- `kafka-cluster:Connect`
- `kafka-cluster:DescribeCluster`
- `kafka-cluster:DescribeTopic`
- `kafka-cluster:WriteData`
- `kafka-cluster:DescribeGroup`
- `kafka-cluster:AlterGroup`
- `secretsmanager:GetSecretValue`

### 5.4 Secrets Manager

다음 Secret이 생성되었는지 확인한다.

```text
baselink-dev/kafka/event-streaming
```

Secret 값에는 다음 정보가 들어간다.

```json
{
  "clusterArn": "...",
  "bootstrapBrokersSaslIam": "...",
  "topics": [
    "ticket.domain.events",
    "waiting.operational.events",
    "reservation.lifecycle.events",
    "capacity.signals",
    "infra.audit.events"
  ],
  "securityProtocol": "SASL_SSL",
  "saslMechanism": "AWS_MSK_IAM"
}
```

이 Secret은 이후 Backend/GitOps PR에서 Kafka producer 설정의 기준값으로 사용한다.

## 6. 완료 기준

Phase 1은 다음 조건을 만족하면 완료로 본다.

- MSK Serverless cluster가 `Active` 상태다.
- Terraform output으로 bootstrap broker를 확인할 수 있다.
- Kafka runtime config Secret이 생성되어 있다.
- backend runtime IRSA role이 Kafka 접근 권한과 Secret 조회 권한을 가진다.
- EKS 내부 임시 Pod에서 MSK broker DNS를 PrivateLink endpoint로 해석할 수 있다.
- EKS 내부 임시 Pod에서 MSK IAM broker port `9098` TCP 연결을 확인할 수 있다.
- EKS 내부 Kafka CLI에서 `AWS_MSK_IAM` 인증으로 broker metadata 또는 topic 목록 조회를 수행할 수 있다.
- 기존 SQS 기반 예매 확정 경로가 영향을 받지 않는다.

## 7. Phase 1 검증 기록

검증 일시:

```text
2026-06-24
```

검증 결과:

- MSK Serverless cluster `baselink-dev-event-streaming` 생성 완료
- cluster 상태 `ACTIVE` 확인
- Kafka runtime config Secret `baselink-dev/kafka/event-streaming` 생성 확인
- backend runtime IRSA role에 Kafka 접근 policy 확인
- EKS 내부 Pod에서 broker DNS 조회 성공
- EKS 내부 Pod에서 TCP `9098` 연결 성공
- EKS 내부 Kafka CLI에서 `AWS_MSK_IAM` 인증 기반 topic 목록 조회 성공

확인된 bootstrap broker:

```text
boot-twqovxpi.c3.kafka-serverless.ap-northeast-2.amazonaws.com:9098
```

네트워크 smoke test 결과:

```text
boot-twqovxpi.c3.kafka-serverless.ap-northeast-2.amazonaws.com
-> vpce-...ap-northeast-2.vpce.amazonaws.com
-> private IP 10.0.40.x / 10.0.50.x

9098 open
```

IAM client smoke test 결과:

```text
KAFKA_IAM_SMOKE_OK
```

의미:

```text
EKS backend-runtime service account
-> backend runtime IRSA
-> AWS_MSK_IAM
-> MSK Serverless broker metadata 조회
```

까지 확인되었다.

주의:

- 아직 Kafka topic은 생성하지 않았다.
- 따라서 topic 목록 조회 결과는 비어 있을 수 있다.
- 현재 검증은 “Kafka 인프라 접근 가능성”을 확인한 것이며, 실제 서비스 이벤트 publish는 Backend/GitOps 연동 단계에서 진행한다.

## 8. 롤백 절차

Kafka 인프라를 잠시 비활성화해야 한다면 `DEV_INFRA_TFVARS`에서 다음 값을 다시 설정한다.

```hcl
enable_kafka_event_streaming = false
```

이후 Terraform Plan/Apply를 실행한다.

예상 결과:

- MSK Serverless cluster 삭제
- MSK용 Security Group 삭제
- Kafka IAM policy 삭제
- Kafka runtime config Secret 삭제 예약

주의:

- Secrets Manager secret은 `recovery_window_in_days = 7`로 설정되어 있어 즉시 영구 삭제되지 않는다.
- Kafka는 아직 핵심 예매 처리 경로가 아니므로, Phase 1 롤백이 기존 SQS 기반 예매 확정 흐름을 중단시키면 안 된다.

## 9. 다음 단계

Phase 1 완료 후 다음 작업은 Backend/GitOps 연동이다.

우선순위:

1. Kafka producer 설정을 읽을 수 있도록 backend runtime 환경변수 또는 External Secrets 연동 설계
2. ticket outbox publisher의 dual publish 구조 설계
3. waiting-room-service의 대기열 이벤트 publish 구조 설계
4. Kafka publish 실패가 기존 SQS/DB transaction을 막지 않도록 fallback 정책 구현
5. Kafka event를 S3/Athena 분석 경로로 적재하는 sink consumer 구현

핵심 원칙:

```text
Kafka는 관측/분석/추천 경로를 강화한다.
SQS는 예매 확정 명령 처리의 안정성을 계속 담당한다.
```
