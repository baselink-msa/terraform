# elasticache 모듈

ElastiCache for Redis 복제 그룹을 프로비저닝하는 모듈입니다 (cluster mode disabled).

## 개요

baselink의 좌석 잠금·예매 대기열 등 **빠른 동시성 제어가 필요한 데이터**를 위한 인메모리 저장소(Redis)를 만듭니다. primary 1대와 replica N대로 구성되며, 읽기용·쓰기용 엔드포인트가 분리되어 제공됩니다.

보안 그룹을 함께 만들어, 지정한 보안 그룹(예: EKS 노드)에서 오는 트래픽만 Redis 포트로 들어올 수 있도록 제한합니다.

## 생성 리소스

- Redis 복제 그룹 (`aws_elasticache_replication_group`)
- 보안 그룹 + 인바운드/아웃바운드 규칙
- 서브넷 그룹
- 파라미터 그룹

## 입력 변수

| 변수 | 설명 | 타입 | 기본값 | 필수 |
|---|---|---|---|:--:|
| `name` | 리소스 이름 접두어 | string | — | ✓ |
| `vpc_id` | 보안 그룹을 둘 VPC ID | string | — | ✓ |
| `subnet_ids` | Redis 노드용 서브넷 (프라이빗) | list(string) | — | ✓ |
| `allowed_security_group_ids` | Redis 포트 접근을 허용할 보안 그룹 | list(string) | — | ✓ |
| `engine` | 캐시 엔진 (redis/valkey) | string | `"redis"` | |
| `engine_version` | 엔진 버전 | string | `"7.1"` | |
| `parameter_group_family` | 파라미터 그룹 family | string | `"redis7"` | |
| `node_type` | 캐시 노드 타입 | string | `"cache.t4g.small"` | |
| `num_cache_clusters` | 전체 노드 수 (primary 1 + replica N) | number | `2` | |
| `automatic_failover_enabled` | primary 장애 시 replica 자동 승격 | bool | `true` | |
| `multi_az_enabled` | primary·replica를 서로 다른 AZ에 배치 | bool | `true` | |
| `port` | Redis 포트 | number | `6379` | |
| `maxmemory_policy` | 메모리가 가득 찼을 때의 정책 | string | `"volatile-lru"` | |
| `at_rest_encryption_enabled` | 저장 데이터 암호화 | bool | `true` | |
| `transit_encryption_enabled` | 전송 중 암호화(TLS) | bool | `true` | |
| `auth_token` | Redis AUTH 토큰 (선택, sensitive) | string | `null` | |
| `snapshot_retention_limit` | 자동 스냅샷 보관 일수 (0=비활성) | number | `1` | |
| `apply_immediately` | 변경을 즉시 적용 | bool | `false` | |
| `auth_token_secret_arn` | Secrets Manager의 auth_token ARN. 지정 시 var.auth_token 무시 | string | `null` | |
| `tags` | 공통 태그 | map(string) | `{}` | |

## 출력값

| 출력 | 설명 |
|---|---|
| `primary_endpoint_address` | 쓰기용 엔드포인트 |
| `reader_endpoint_address` | 읽기용 엔드포인트 (replica 분산) |
| `port` | Redis 포트 |
| `security_group_id` | Redis 보안 그룹 ID |
| `replication_group_id` | 복제 그룹 ID |

## 사용 예시

```hcl
module "elasticache" {
  source     = "../../../modules/elasticache"
  name       = "baselink-dev"
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  # EKS 노드에서만 Redis 접근 허용
  allowed_security_group_ids = [module.eks.cluster_security_group_id]

  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false
}
```

## 다른 모듈과의 관계

- **입력으로 받음**: `vpc_id`, `subnet_ids` ← vpc 모듈 / `allowed_security_group_ids` ← eks 모듈의 `cluster_security_group_id`
- **출력 제공**: `primary_endpoint_address` 등 → 애플리케이션이 Redis 접속에 사용

## 참고

- `automatic_failover_enabled` 또는 `multi_az_enabled`를 `true`로 두려면 `num_cache_clusters`가 2 이상이어야 합니다 (모듈 `validation`이 강제).
- Valkey로 전환할 때는 `engine`·`engine_version`·`parameter_group_family` 세 변수만 교체하면 됩니다.
- 좌석 잠금처럼 손실되면 안 되는 데이터를 다룬다면 `maxmemory_policy`를 `noeviction`으로 두는 것을 검토하세요.
- `transit_encryption_enabled = true`이면 클라이언트도 TLS로 접속해야 합니다.
