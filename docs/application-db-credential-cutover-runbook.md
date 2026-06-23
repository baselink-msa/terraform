# 애플리케이션 DB 계정 전환 Runbook

## 목적

backend 서비스가 RDS master 계정을 직접 사용하지 않고 고정된 `baselink_app` 계정을 사용하도록 전환합니다.

최종 역할은 다음과 같습니다.

| Kubernetes Secret | DB 계정 | 사용자 |
|---|---|---|
| `backend-secret` | `baselink_app` | 모든 backend 런타임 서비스 |
| `flyway-secret` | RDS master (`baseball`) | `auth-service`의 Flyway |
| `postgres-keda-secret` | `baselink_app` | KEDA PostgreSQL scaler |

RDS master 비밀번호가 rotation되더라도 일반 API가 사용하는 `backend-secret`은 변경되지 않습니다. 따라서 이전과 같은 로그인·예매·챗봇 전체 장애가 발생하는 범위를 제거합니다.

## 사전 조건

- `baselink-dev/database/application` Secrets Manager Secret이 존재해야 합니다.
- RDS에 `baselink_app` role과 런타임 권한이 생성되어 있어야 합니다.
- `auth-service`에 `SPRING_FLYWAY_USER`, `SPRING_FLYWAY_PASSWORD` 설정이 배포되어 있어야 합니다.
- auth-service Deployment가 `backend-secret,flyway-secret`을 Reloader 대상으로 지정해야 합니다.

## KEDA pause 상태 보호

현재 dev 환경의 predictive PostgreSQL scaler 5개는 비용 보호를 위해 pause되어 있습니다.

GitHub Actions의 `DEV_ADDON_TFVARS`에 다음 값이 있어야 합니다.

```hcl
keda_predictive_paused = true
```

이 값이 `false`이면 전체 addon apply 과정에서 다음 pause annotation이 제거됩니다.

- `auth-service-scaler`
- `order-service-scaler`
- `seat-lock-service-scaler`
- `ticket-service-scaler`
- `waiting-room-service-scaler`

자격증명 전환 PR을 병합하기 전에 Terraform plan이 다음 범위인지 확인합니다.

```text
Plan: 1 to add, 2 to change, 0 to destroy
```

예상 리소스:

- create: `kubectl_manifest.flyway_secret`
- update: `kubectl_manifest.backend_secret`
- update: `kubectl_manifest.postgres_keda_secret`

## 배포 흐름

```text
Terraform addon apply
-> flyway-secret 생성
-> backend-secret을 baselink_app으로 변경
-> postgres-keda-secret을 baselink_app으로 변경
-> Reloader가 backend Deployment rolling restart
-> auth-service는 런타임 연결에 baselink_app 사용
-> auth-service Flyway는 RDS master 사용
```

## 검증

### Deployment

```bash
kubectl get deploy -n baselink-dev
kubectl get pods -n baselink-dev
```

DB 사용 Deployment 9개가 모두 Ready/Available 상태여야 합니다.

### 자격증명 분리

Secret 원문을 출력하지 않고 username과 hash만 비교합니다.

```bash
kubectl get secret backend-secret -n baselink-dev \
  -o jsonpath='{.data.SPRING_DATASOURCE_USERNAME}' | base64 -d

kubectl get secret flyway-secret -n baselink-dev \
  -o jsonpath='{.data.SPRING_FLYWAY_USER}' | base64 -d
```

예상 결과:

```text
backend-secret: baselink_app
flyway-secret:  baseball
```

### 로그

다음 오류가 없어야 합니다.

```text
password authentication failed
SQLState: 28P01
permission denied
FlywayException
CannotCreateTransactionException
```

### API

- 로그인
- 게임 목록 조회
- 내 예매 조회
- 예매 요청
- 챗봇 FAQ 또는 DB 기반 답변
- Outbox publisher 처리

## 롤백

전환 후 권한 오류가 발생하면 `backend-secret`의 datasource username/password를 현재 RDS master Secret 값으로 되돌립니다.

Reloader가 backend Deployment를 재시작한 뒤 API를 다시 검증합니다. `baselink_app` role과 application Secret은 원인 분석이 끝날 때까지 삭제하지 않습니다.

## 남아 있는 보완 작업

RDS master rotation과 `flyway-secret`의 동기화는 현재 Terraform addon apply 시점에 수행됩니다. 일반 API는 master 계정을 사용하지 않으므로 rotation으로 인한 전체 서비스 장애는 방지되지만, rotation 직후 Terraform apply 없이 auth-service를 새로 배포하면 Flyway 자격증명이 오래된 상태일 수 있습니다.

후속 작업으로 External Secrets Operator 또는 rotation EventBridge 자동화를 도입해 다음 경로를 완성합니다.

```text
RDS master rotation
-> Secrets Manager 변경 감지
-> flyway-secret 자동 동기화
-> auth-service만 안전하게 restart
```
