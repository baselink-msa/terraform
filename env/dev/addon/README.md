# Dev Addon Terraform

이 디렉터리는 dev EKS 클러스터 위의 addon 리소스를 관리합니다.

주요 관리 대상은 다음과 같습니다.

- Karpenter, KEDA, metrics-server
- Argo CD Application
- `backend-config` ConfigMap
- `backend-secret` Secret
- `postgres-keda-secret` Secret

## KEDA PostgreSQL 읽기 전용 계정

KEDA의 `postgresql` 트리거는 DB를 조회해서 예매 오픈 시간대에 파드 수를 늘릴지 판단합니다.

KEDA가 RDS 관리자 계정으로 DB를 조회하면 권한이 너무 넓기 때문에, 별도 읽기 전용 계정인 `keda_reader` 사용을 권장합니다.

현재 필요한 권한은 다음과 같습니다.

```sql
GRANT USAGE ON SCHEMA game_schema TO keda_reader;
GRANT SELECT ON game_schema.games, game_schema.stadiums TO keda_reader;
```

권한 확인 쿼리는 다음과 같습니다.

```sql
SELECT has_schema_privilege('keda_reader', 'game_schema', 'USAGE');
SELECT has_table_privilege('keda_reader', 'game_schema.games', 'SELECT');
SELECT has_table_privilege('keda_reader', 'game_schema.stadiums', 'SELECT');
```

세 결과가 모두 `true`이면 KEDA가 경기 정보와 구장 규모를 읽을 수 있습니다.

## postgres-keda-secret 덮어쓰기 방지

`postgres-keda-secret`은 Terraform addon 코드가 관리합니다.

따라서 EKS 클러스터에서 Secret을 직접 수정해도, 다음 `terraform apply` 때 Terraform 코드의 값으로 다시 덮어써질 수 있습니다.

이를 방지하기 위해 `keda_postgres_connection` 변수를 사용합니다.

로컬 `terraform.tfvars` 또는 환경변수에 다음 형식으로 값을 넣습니다.

```hcl
keda_postgres_connection = "postgresql://keda_reader:<password>@<rds-endpoint>/baseball_platform?sslmode=require"
```

이 값은 DB 비밀번호를 포함하므로 Git에 커밋하면 안 됩니다.

`terraform.tfvars`는 `.gitignore`에 포함되어 있으므로 로컬 전용 파일로 사용하고, 팀원에게는 형식만 공유합니다.

값을 설정하지 않으면 기존 호환성을 위해 RDS 관리자 계정 접속 문자열을 사용합니다. 실제 운영에서는 `keda_reader` 값을 설정한 뒤 apply하는 것을 권장합니다.
