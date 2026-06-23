# Application Database Credential Separation

## 목적

현재 backend 서비스는 RDS master 계정을 런타임 연결에 함께 사용합니다. RDS가 master 비밀번호를 자동 교체하면 Kubernetes `backend-secret`과 실행 중인 Pod가 즉시 따라가지 못해 전체 DB API가 실패할 수 있습니다.

이를 다음 두 책임으로 분리합니다.

| 계정 | 용도 | 비밀번호 정책 |
|---|---|---|
| RDS master (`baseball`) | Flyway migration, 운영 복구, 계정 관리 | RDS 관리형 rotation 유지 |
| application (`baselink_app`) | backend 서비스의 평상시 SELECT/INSERT/UPDATE/DELETE | 별도 Secrets Manager Secret에 고정 저장 |

애플리케이션은 테이블 생성, 스키마 변경, 계정 생성 권한을 갖지 않습니다. Flyway만 master 계정을 사용합니다.

## 왜 이 구조가 필요한가

- master 비밀번호가 rotation되어도 실행 중인 API의 DB 연결 정보는 바뀌지 않습니다.
- 애플리케이션 침해 시 노출되는 DB 권한을 런타임 작업 범위로 제한합니다.
- migration 자격증명과 서비스 자격증명의 생명주기를 독립적으로 관리합니다.
- 장애 원인이었던 `RDS Secret -> Kubernetes Secret -> Pod`의 즉시 동기화 의존성을 런타임 경로에서 제거합니다.

## 단계별 적용

### 1단계: Secret과 DB 계정 준비

Terraform infra가 다음 Secret 컨테이너를 생성합니다.

```text
baselink-dev/database/application
```

Secret 값은 Terraform state에 저장하지 않습니다. 다음 스크립트가 AWS Secrets Manager에서 안전한 임의 비밀번호를 생성하고, EKS 내부의 임시 PostgreSQL Job을 통해 `baselink_app` 계정과 권한을 생성합니다.

```bash
./scripts/bootstrap-app-db-user.sh
```

스크립트는 재실행할 수 있습니다. Secret이 이미 존재하면 같은 비밀번호를 사용하고 DB role의 비밀번호와 권한을 다시 맞춥니다.

이 단계에서는 `backend-secret`을 변경하지 않으므로 실행 중인 서비스에는 영향이 없습니다.

### 2단계: Flyway credential 분리

- Terraform addon에 `flyway-secret`을 추가합니다.
- `auth-service`에만 `SPRING_FLYWAY_USER`, `SPRING_FLYWAY_PASSWORD`를 주입합니다.
- Flyway migration이 master 계정으로 정상 실행되는지 검증합니다.

### 3단계: 런타임 계정 전환

- `backend-secret`의 datasource username/password를 application Secret 값으로 교체합니다.
- KEDA PostgreSQL scaler도 최소 권한 계정으로 전환합니다.
- Reloader rollout 후 로그인, 게임 조회, 예매, Outbox publisher, 챗봇 DB 조회를 검증합니다.

## 롤백

런타임 전환 후 문제가 발생하면 `backend-secret`의 datasource 자격증명을 RDS master Secret 값으로 되돌립니다. Reloader가 backend Deployment를 rolling restart하면 기존 연결 방식으로 복구됩니다.

DB의 `baselink_app` role과 application Secret은 즉시 삭제하지 않습니다. 원인 분석 및 재전환이 끝난 뒤 별도 변경으로 정리합니다.

## 보안 주의사항

- Secret 값을 터미널이나 CI 로그에 출력하지 않습니다.
- application Secret version을 Terraform resource로 관리하지 않아 비밀번호가 Terraform state에 기록되지 않게 합니다.
- 임시 Kubernetes Secret과 Job은 스크립트 종료 시 삭제합니다.
- RDS master rotation은 끄지 않습니다. 런타임 서비스가 master 비밀번호에 의존하지 않도록 구조를 바꾸는 것이 목표입니다.
