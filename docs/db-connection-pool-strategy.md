# DB Connection Pool 관리 전략

이 문서는 Baselink dev 환경에서 RDS PostgreSQL connection 고갈을 막기 위한 connection pool, KEDA replica, 대기열 입장 제어 전략을 정리합니다.

## 1. 왜 필요한가

KEDA는 트래픽이 많아지면 backend pod를 늘립니다. 하지만 pod가 늘어날수록 각 pod가 RDS connection pool을 만들기 때문에, 애플리케이션 처리량보다 RDS connection 한계가 먼저 병목이 될 수 있습니다.

예를 들어 Hikari maximum pool size가 `3`이고 어떤 서비스가 `10` replicas까지 늘어나면, 그 서비스 하나만 최대 `30`개의 DB connection을 사용할 수 있습니다. 여러 서비스가 동시에 scale-out되면 작은 dev RDS에서는 connection 고갈이 먼저 발생할 수 있습니다.

따라서 autoscaling과 connection pool은 따로 보면 안 됩니다.

```text
KEDA maxReplicaCount
  x 서비스별 DB connection pool size
  <= RDS가 안전하게 감당할 수 있는 app connection budget
```

## 2. 현재 확인된 RDS 기준값

2026-06-17 기준 dev RDS 상태는 다음과 같습니다.

| 항목 | 값 |
| --- | --- |
| DB identifier | `baselink-dev-postgres` |
| Instance class | `db.t4g.micro` |
| Engine | PostgreSQL 16.14 |
| Multi-AZ | `true` |
| `max_connections` | `79` |
| 확인 시점 연결 수 | `21` |
| 연결 상태 | `active=1`, `idle=14`, internal/none=6 |

확인 명령:

```powershell
aws rds describe-db-instances `
  --db-instance-identifier baselink-dev-postgres `
  --query "DBInstances[0].{Class:DBInstanceClass,Status:DBInstanceStatus,MultiAZ:MultiAZ,Engine:Engine,EngineVersion:EngineVersion}"
```

```sql
SHOW max_connections;

SELECT count(*) AS current_connections
FROM pg_stat_activity;

SELECT coalesce(state, 'none') AS state, count(*)
FROM pg_stat_activity
GROUP BY state
ORDER BY state;
```

## 3. 현재 애플리케이션 설정

Terraform addon layer에서 Spring Boot 서비스에 공통 DB 설정을 주입합니다.

```hcl
SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE = "3"
SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE      = "1"
```

이 값은 기본값이고, GitOps `base/workloads.yaml`에서 Spring Boot 서비스별 override를 적용했습니다.

| 서비스 | 현재 max pool | 현재 min idle |
| --- | ---: | ---: |
| `auth-service` | 2 | 1 |
| `game-service` | 2 | 1 |
| `admin-service` | 1 | 1 |
| `waiting-room-service` | 1 | 1 |
| `ticket-worker-service` | 3 | 1 |
| `seat-lock-service` | 2 | 1 |
| `ticket-service` | 4 | 1 |

현재 의미:

- 예매 핵심 쓰기 경로인 `ticket-service`에 가장 큰 pool을 배정했습니다.
- 대기열/관리 서비스는 DB보다 Redis 또는 관리 기능 중심이므로 pool을 작게 유지합니다.
- Python 서비스인 `order-service`, `ai-chatbot-service`는 Hikari 대상이 아니므로 별도 DB connection 정책이 필요합니다.

## 4. 현재 KEDA replica 기준

현재 GitOps KEDA 설정의 주요 max replica는 다음과 같습니다.

| 서비스 | DB 사용 | min replicas | max replicas |
| --- | --- | ---: | ---: |
| `auth-service` | O | 2 | 10 |
| `game-service` | O | 2 | 10 |
| `ticket-service` | O | 2 | 10 |
| `ticket-worker-service` | O | 2 | 10 |
| `seat-lock-service` | O | 2 | 10 |
| `waiting-room-service` | O | 2 | 10 |
| `admin-service` | O | 2 | 3 |
| `order-service` | O, Python | 2 | 10 |
| `ai-chatbot-service` | O, Python | 2 | 10 |

현재 서비스별 Hikari override를 반영해도, KEDA max replica가 대부분 `10`으로 유지되면 Spring Boot 서비스만 단순 계산해도 다음과 같습니다.

```text
auth                 10 x 2 = 20
game                 10 x 2 = 20
ticket               10 x 4 = 40
ticket-worker        10 x 3 = 30
seat-lock            10 x 2 = 20
waiting-room         10 x 1 = 10
admin                 3 x 1 =  3
--------------------------------
Spring Boot 합계               143
```

현재 RDS `max_connections`가 79이므로, 모든 서비스가 동시에 최대로 scale-out되고 각 pod가 pool을 모두 사용하면 RDS connection 한계를 초과할 수 있습니다.

실제로는 모든 서비스가 동시에 maximum pool을 꽉 채우지는 않지만, 운영 설계는 최악의 경우를 기준으로 안전 여유를 둬야 합니다.

## 5. Connection budget 설계

RDS의 모든 connection을 애플리케이션이 써서는 안 됩니다.

관리자 접속, Flyway migration, KEDA PostgreSQL scaler, 운영 점검용 `psql`, RDS 내부 작업을 위해 여유분을 남겨야 합니다.

dev 기준 권장 budget:

| 구분 | connection 수 |
| --- | ---: |
| RDS `max_connections` | 79 |
| 운영/관리/내부 여유분 | 15~20 |
| 애플리케이션 안전 budget | 약 55~60 |

따라서 dev에서는 아래 기준을 권장합니다.

```text
모든 app pod의 최대 DB connection 합계 <= 60
```

`60`은 고정값이 아니라 현재 dev RDS `db.t4g.micro`의 `max_connections=79`에서 운영 여유분을 뺀 값입니다. RDS instance class가 커지거나 DB parameter가 바뀌면 `max_connections`도 달라질 수 있으므로 app budget도 다시 계산해야 합니다.

권장 계산식:

```text
app connection budget
= RDS max_connections
  - 운영/관리/마이그레이션/KEDA/점검 여유분
```

dev에서는 현재 다음처럼 잡습니다.

```text
79 - 19 = 60
```

운영에서는 RDS 여유분을 더 크게 잡는 것이 안전합니다.

## 6. 서비스별 권장 pool 전략

모든 서비스에 같은 pool size를 주는 것보다, 서비스 역할에 따라 다르게 주는 것이 좋습니다.

| 서비스 | 성격 | 권장 max pool | 권장 min idle | 이유 |
| --- | --- | ---: | ---: | --- |
| `auth-service` | 로그인/회원 | 2 | 1 | 트래픽은 있지만 예매 핵심 DB 쓰기보다 우선순위 낮음 |
| `game-service` | 경기/좌석 조회 | 2 | 1 | 조회 중심, read replica 도입 전까지 RDS 부담 주의 |
| `waiting-room-service` | 대기열 정책 조회 + Redis 중심 | 1 | 0~1 | 주 역할은 Redis 대기열, DB는 정책 조회용 |
| `ticket-service` | 예매 요청/예약 생성 | 4 | 1 | 핵심 쓰기 경로, connection budget 내에서 우선 배정 |
| `ticket-worker-service` | SQS 메시지 처리 | 3 | 1 | worker concurrency와 함께 조절 필요 |
| `seat-lock-service` | 좌석 선점/상태 | 2 | 1 | Valkey 중심으로 가는 것이 바람직 |
| `admin-service` | 관리자 기능 | 1 | 0~1 | 트래픽 낮음, pool 크게 둘 필요 없음 |
| `order-service` | 주문/결제 단계 | 2 | 1 | 결제 단계 트래픽은 funnel 후반 |
| `ai-chatbot-service` | FAQ/AI 보조 | 1 | 0~1 | 장애 시 예매 핵심 기능보다 우선순위 낮음 |

서비스별 분리는 GitOps `base/workloads.yaml`의 각 Deployment `env`에 아래처럼 적용합니다.

```yaml
env:
  - name: SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE
    value: "4"
  - name: SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE
    value: "1"
```

적용 위치:

- 공통 기본값: Terraform addon `backend-config`
- 서비스별 override: GitOps `base/workloads.yaml`의 각 Deployment `env`

이렇게 하면 대부분 서비스는 공통 기본값을 사용하고, 예매 핵심 서비스만 별도로 더 큰 pool을 받을 수 있습니다.

## 7. KEDA와 함께 보는 기준

KEDA max replica는 CPU나 PostgreSQL scaler 기준만으로 정하면 안 됩니다. DB connection budget도 함께 봐야 합니다.

예시:

```text
ticket-service max replicas = 10
Hikari max pool = 3
최대 DB connection = 30
```

ticket-service 하나는 괜찮아 보이지만, ticket-worker, seat-lock, waiting-room, auth가 함께 늘어나면 RDS 한계에 가까워집니다.

권장 방식:

1. 서비스별 pool size를 정합니다.
2. 서비스별 max replica를 정합니다.
3. `pool size x max replicas` 합계를 계산합니다.
4. 합계가 app connection budget 60을 넘으면 조정합니다.

dev RDS app budget 60 기준의 KEDA maxReplicaCount 변경 제안은 다음과 같습니다.

| 서비스 | max replicas | max pool | 최대 connection |
| --- | ---: | ---: | ---: |
| `ticket-service` | 6 | 4 | 24 |
| `ticket-worker-service` | 4 | 3 | 12 |
| `seat-lock-service` | 4 | 2 | 8 |
| `waiting-room-service` | 4 | 1 | 4 |
| `auth-service` | 3 | 2 | 6 |
| `game-service` | 2 | 2 | 4 |
| `admin-service` | 2 | 1 | 2 |
| 합계 |  |  | 60 |

이 변경안은 dev의 작은 RDS에서 connection 고갈을 막기 위한 보수적인 기준입니다.

- `ticket-service`는 예매 확정 경로이므로 가장 큰 connection budget을 배정합니다.
- `ticket-worker-service`는 SQS 적체를 처리하지만, DB가 병목이면 worker만 늘려도 장애가 커질 수 있어 `4`로 제한합니다.
- `waiting-room-service`는 Redis 중심 서비스이므로 DB pool과 replica를 낮게 둡니다.
- `auth-service`, `game-service`, `admin-service`는 예매 피크 때 핵심 쓰기 경로보다 낮은 우선순위로 둡니다.

주의할 점:

- Python 서비스인 `order-service`, `ai-chatbot-service`의 DB connection 수는 Hikari 계산에 포함되지 않았습니다. 두 서비스의 DB driver/pool 정책을 확인한 뒤 별도 budget을 잡아야 합니다.
- KEDA 담당자의 예측 스케일링 쿼리가 반환하는 pod 수가 이 maxReplicaCount를 넘으면, 실제 replica는 maxReplicaCount에서 잘립니다.
- 이 변경은 처리량을 무조건 줄이자는 의미가 아니라, 현재 dev RDS 크기에서 DB가 먼저 죽지 않도록 autoscaling 상한을 DB budget과 맞추자는 의미입니다.

GitOps 변경안:

| ScaledObject | 현재 maxReplicaCount | 제안 maxReplicaCount |
| --- | ---: | ---: |
| `ticket-service-scaler` | 10 | 6 |
| `ticket-worker-scaler` | 10 | 4 |
| `seat-lock-service-scaler` | 10 | 4 |
| `waiting-room-service-scaler` | 10 | 4 |
| `auth-service-scaler` | 10 | 3 |
| `game-service-scaler` | 10 | 2 |
| `admin-service-scaler` | 3 | 2 |

`minReplicaCount=2`와 PDB가 적용되어 있으므로, `game-service`와 `admin-service`처럼 `maxReplicaCount=2`인 서비스는 최소 2개를 유지하되 그 이상으로는 늘리지 않는 구조가 됩니다.

`order-service`, `ai-chatbot-service`는 별도 DB connection 정책을 확인하기 전까지 이번 Spring Boot Hikari budget 변경 범위에서 제외합니다.

## 8. RDS instance class 판단 기준

현재 dev RDS는 `db.t4g.micro`입니다.

작은 팀 프로젝트 dev 환경에서는 비용을 아끼기 위해 `db.t4g.micro`를 유지하는 것이 합리적입니다. 다만 다음 조건 중 하나라도 반복되면 RDS class 상향을 검토해야 합니다.

| 판단 기준 | 의미 | 권장 조치 |
| --- | --- | --- |
| `DatabaseConnections`가 55~60 근처에 자주 도달 | connection budget이 부족함 | KEDA max/pool/대기열 입장량 조정 후에도 반복되면 class 상향 |
| CPU가 70~80% 이상으로 지속 | DB 연산 자체가 부족함 | 쿼리/인덱스 확인 후 class 상향 |
| FreeableMemory 부족 또는 swap 증가 | 메모리 부족 | class 상향 우선 검토 |
| 정상 쿼리인데 connection timeout 반복 | DB connection 수 또는 pool 구조 문제 | RDS Proxy, pool 조정, class 상향 검토 |
| 조회 트래픽이 대부분 | primary DB보다 read 부하가 큼 | read replica 또는 cache 우선 검토 |

결론:

- 지금 당장 `db.t4g.micro`를 무조건 키우기보다는, dev에서는 KEDA maxReplicaCount와 Hikari pool을 먼저 budget 안에 맞춥니다.
- 부하 테스트에서 connection/CPU/memory 중 무엇이 먼저 한계에 닿는지 확인한 뒤 instance class를 올리는 것이 설득력 있습니다.
- 발표에서는 “작은 RDS를 쓴다”가 약점이 아니라, “작은 RDS의 한계를 계산하고 autoscaling 상한과 대기열 입장량으로 보호했다”가 어필 포인트입니다.

## 9. 동적 대기열과의 연결

대기열의 역할은 사용자를 줄 세우는 것만이 아니라, backend와 RDS를 보호하는 admission control입니다.

현재 waiting-room-service는 다음 방식으로 실제 입장 허용량을 계산합니다.

```text
실제 입장 허용량
= min(관리자 maxEnterPerMinute, ticket-service Ready Pod 수 x pod당 처리량)
```

현재 설정:

```text
WAITING_ROOM_TICKET_SERVICE_CAPACITY_PER_POD_PER_MINUTE = 20
```

예시:

```text
ticket-service Ready Pod = 2
pod당 처리량 = 20명/분
시스템 처리 가능량 = 40명/분

관리자 maxEnterPerMinute = 10
실제 입장 허용량 = min(10, 40) = 10명/분
```

2026-06-17 테스트 결과:

| 테스트 | 결과 |
| --- | --- |
| gameId `1` 정책 | `maxEnterPerMinute=10`, `tokenTtlSeconds=300` |
| 테스트 사용자 수 | 15 |
| 토큰 발급 성공 | 10 |
| 429 제한 응답 | 5 |

이 결과는 대기열 admission control이 관리자 상한과 Redis 분 단위 counter를 기준으로 동작하고 있음을 보여줍니다.

## 10. 운영 모니터링 기준

현재 RDS connection alarm은 `DatabaseConnections >= 60` 기준입니다.

이전 기준인 `80`은 현재 RDS `max_connections=79`보다 높아 실제 조기 경보로 의미가 약했습니다. dev 기준으로는 app connection budget에 맞춰 다음처럼 단계별로 보는 것을 권장합니다.

| 단계 | 기준 | 의미 |
| --- | --- | --- |
| 관심 | 40 connections 이상 | 평소보다 높음, scale-out 상황 확인 |
| 경고 | 55 connections 이상 | app budget에 근접, 대기열 입장량/worker 처리량 조정 검토 |
| 위험 | 65 connections 이상 | 신규 connection 실패 가능성, KEDA max/pool/입장량 즉시 점검 |

현재 Terraform alarm 반영 사항:

- dev RDS는 `DatabaseConnections >= 60`으로 알람을 발생시킵니다.
- 운영 환경은 RDS instance class와 `max_connections`에 맞춰 threshold를 계산합니다.
- connection alarm이 울리면 대기열 `maxEnterPerMinute` 또는 pod당 입장 처리량을 낮추는 운영 절차를 둡니다.

## 11. 장애 예방 운영 절차

RDS connection이 높아질 때는 아래 순서로 확인합니다.

1. 현재 connection 수 확인

```sql
SELECT count(*) AS current_connections
FROM pg_stat_activity;
```

2. 서비스별 연결 수 확인

```sql
SELECT application_name, usename, state, count(*)
FROM pg_stat_activity
GROUP BY application_name, usename, state
ORDER BY count(*) DESC;
```

3. Kubernetes replica 확인

```powershell
kubectl get deploy -n baselink-dev
kubectl get scaledobject -n baselink-dev
```

4. 대기열 입장량 확인

```powershell
kubectl logs -n baselink-dev deployment/waiting-room-service --tail=100
```

5. 조치 후보

- 관리자 페이지에서 경기별 `maxEnterPerMinute`를 낮춥니다.
- `WAITING_ROOM_TICKET_SERVICE_CAPACITY_PER_POD_PER_MINUTE`를 낮춥니다.
- ticket-worker 처리량 또는 KEDA max replica를 낮춥니다.
- 서비스별 Hikari max pool size를 낮춥니다.
- 반복되는 조회 부하는 cache 또는 read replica 도입을 검토합니다.

## 12. 다음 고도화 작업

| 작업 | 목적 | 우선순위 |
| --- | --- | --- |
| 서비스별 Hikari pool size 분리 | 모든 서비스에 공통 pool을 주지 않고 역할별 제어 | 완료 |
| KEDA maxReplicaCount를 DB budget에 맞게 조정 | scale-out 상한을 RDS connection budget 안으로 제한 | 높음 |
| Python 서비스 DB connection 정책 확인 | `order-service`, `ai-chatbot-service` connection budget 분리 | 높음 |
| RDS connection alarm threshold 재조정 | 현재 RDS max_connections에 맞는 조기 경보 | 완료 |
| connection 진단 스크립트 추가 | CloudWatch 알람 후 서비스별 connection 현황 자동 수집 | 중 |
| 대기열 입장량과 RDS connection 연동 | RDS 위험 시 입장량 자동 감속 | 중 |
| RDS Proxy 검토 | connection storm 완화 | 중 |
| Read Replica 검토 | 경기/좌석 조회 부하 분산 | 중 |

## 13. 발표 포인트

- KEDA로 pod를 늘리는 것만으로는 안정성이 보장되지 않습니다.
- RDS connection은 작은 dev RDS에서 가장 먼저 한계에 닿을 수 있는 병목입니다.
- 서비스별 `replica x pool size`를 계산해 RDS connection budget 안에서 autoscaling 상한을 설계했습니다.
- `db.t4g.micro`의 `max_connections=79`를 기준으로 app budget을 약 60으로 잡고, 운영/마이그레이션/KEDA 점검 여유분을 남겼습니다.
- 동적 대기열 admission control은 backend pod 수뿐 아니라 RDS 보호 전략과 함께 동작해야 합니다.
- 향후에는 RDS connection 상태를 보고 대기열 입장량을 자동 조절하는 방향으로 고도화할 수 있습니다.
