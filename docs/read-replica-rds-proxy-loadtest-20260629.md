# Read Replica / RDS Proxy 부하 검증 결과

검증일: 2026-06-29 KST

## 1. 검증 목적

이번 검증의 목적은 RDS Read Replica와 RDS Proxy를 “좋아 보이니까 넣는 것”이 아니라, 실제 부하 지표를 보고 지금 필요한지 판단하는 것이다.

- Read Replica는 조회 트래픽이 primary RDS의 CPU/ReadIOPS/ReadLatency를 밀어 올릴 때 도입 가치가 크다.
- RDS Proxy는 요청이 몰릴 때 DB connection이 급증하거나 HikariPool timeout이 발생할 때 도입 가치가 크다.

따라서 이번 검증에서는 다음 질문에 답했다.

```text
조회 API 부하가 RDS read 병목을 만들었는가?
예매 write path 부하가 DB connection budget을 위협했는가?
지금 당장 Read Replica 또는 RDS Proxy를 필수로 구현해야 하는가?
```

## 2. 테스트 경로와 주의사항

처음에는 외부 사용자 경로와 동일하게 CloudFront URL을 사용하려고 했다.

```text
https://baselink.kro.kr/api/games
```

하지만 2026-06-29 검증 시점에는 `/api/games`가 API JSON이 아니라 frontend S3의 `index.html`을 반환했다.

확인된 응답 특징:

```text
HTTP/2 200
content-type: text/html
x-cache: Error from cloudfront
body: <!doctype html>...
```

ALB 직접 접근도 timeout이 발생했다. 이는 ALB가 CloudFront 경로만 허용하도록 제한되어 있거나, direct 접근이 보안적으로 막혀 있는 상태로 해석된다.

따라서 이번 검증은 CloudFront/ALB 라우팅 문제를 제외하고, EKS 내부에서 서비스 DNS를 직접 호출하는 방식으로 진행했다.

```text
k6 Job in EKS
-> game-service / seat-lock-service / ticket-service
-> RDS / Valkey / SQS
```

이 방식은 외부 라우팅 검증은 아니지만, Read Replica와 RDS Proxy 판단에 필요한 DB 병목 여부를 분리해서 보기에는 더 적합하다.

## 3. Read Replica 필요성 검증

### 테스트 조건

EKS 내부 k6 Job으로 조회 API 부하를 발생시켰다.

```text
Job: k6-read-replica-check-20260629
VUS: 80
Duration: 2m
Target:
  GET http://game-service:8082/api/games
  GET http://game-service:8082/api/games/1/seats
```

실행 시간:

```text
2026-06-29T11:28:36Z ~ 2026-06-29T11:30:45Z
```

### k6 결과

| 항목 | 결과 |
| --- | ---: |
| HTTP requests | 72,148 |
| Iterations | 36,074 |
| HTTP failed | 0.00% |
| Checks | 100.00% |
| 전체 p95 | 171.40ms |
| `/api/games` p95 | 168.31ms |
| `/api/games/1/seats` p95 | 174.09ms |

### RDS 지표

조회 범위:

```text
2026-06-29T11:27:00Z ~ 2026-06-29T11:32:00Z
```

| Metric | Maximum |
| --- | ---: |
| CPUUtilization | 38.19% |
| DatabaseConnections | 22 |
| ReadIOPS | 1.35/s |
| ReadLatency | 8.9ms |

### 판단

현재 상태에서는 Read Replica를 필수로 도입할 근거가 약하다.

이유:

- 조회 API 80 VU / 2분 부하에서 실패율이 0%였다.
- 조회 API p95가 약 170ms 수준으로 안정적이었다.
- RDS connection은 최대 22개로 app connection budget 60 대비 여유가 있었다.
- ReadIOPS와 ReadLatency가 낮아 RDS read I/O 병목이 확인되지 않았다.
- RDS CPU가 한 시점에 38%까지 올라갔지만 지속적인 포화 상태는 아니었고, API 응답 저하로 이어지지 않았다.

따라서 지금은 Read Replica를 추가하기보다 다음 조건이 확인될 때 도입을 재검토하는 것이 합리적이다.

```text
조회 API p95/p99가 지속적으로 증가한다.
RDS CPU 또는 ReadIOPS가 조회 트래픽과 함께 지속적으로 높아진다.
예매 write path는 정상인데 조회 API 때문에 primary DB가 느려진다.
관리자/분석성 조회가 primary DB를 압박한다.
replica lag를 허용할 수 있는 조회 API가 명확히 분리된다.
```

## 4. RDS Proxy 필요성 검증

### 테스트 조건

EKS 내부 k6 Job으로 예매 write path에 부하를 발생시켰다.

```text
Job: k6-rds-proxy-check-20260629
VUS: 30
Duration: 2m
Target flow:
  GET game-service /api/games
  GET game-service /api/games/1/seats?status=AVAILABLE
  POST seat-lock-service /api/seats/locks
  POST ticket-service /api/tickets/reserve
  GET ticket-service /api/tickets/{reservationId}
  POST ticket-service /api/tickets/{reservationId}/cancel
```

실행 시간:

```text
2026-06-29T11:33:33Z ~ 2026-06-29T11:35:39Z
```

### k6 결과

| 항목 | 결과 |
| --- | ---: |
| HTTP requests | 31,086 |
| Iterations | 5,455 |
| HTTP failed | 1.76% |
| Checks | 97.90% |
| 전체 p95 | 191.01ms |
| seat-lock create p95 | 348.34ms |
| ticket reserve p95 | 174.55ms |
| ticket detail p95 | 155.77ms |
| ticket cancel p95 | 141.67ms |

실패는 대부분 `seat-lock-service`의 잠금 생성 timeout/경합에서 발생했다.

```text
seat lock status 200: 89%
ticket reserve status 200: pass
ticket detail status 200: pass
ticket cancel status 200: pass
```

즉 이번 실패는 ticket-service의 DB connection 부족이라기보다, 좌석 잠금 경합 또는 seat-lock 계층의 응답 지연으로 보는 것이 맞다.

### RDS 지표

조회 범위:

```text
2026-06-29T11:32:00Z ~ 2026-06-29T11:37:00Z
```

| Metric | Maximum |
| --- | ---: |
| DatabaseConnections | 33 |
| CPUUtilization | 16.49% |
| WriteIOPS | 149.81/s |
| WriteLatency | 3.78ms |

SQS 상태:

| Queue | Visible | NotVisible | Delayed |
| --- | ---: | ---: | ---: |
| ticket-confirm-queue | 0 | 0 | 0 |
| ticket-confirm-dlq | 0 | 0 | 0 |

### 판단

현재 상태에서는 RDS Proxy를 필수로 도입할 근거가 약하다.

이유:

- DatabaseConnections가 최대 33개로 connection budget 60 대비 여유가 있었다.
- RDS CPU가 최대 16.49%로 낮았다.
- WriteIOPS는 증가했지만 WriteLatency가 최대 3.78ms 수준으로 안정적이었다.
- ticket reserve/detail/cancel 경로의 p95가 200ms 안팎으로 안정적이었다.
- SQS backlog와 DLQ가 남지 않았다.
- HikariPool timeout이나 DB connection 부족으로 보이는 증상이 확인되지 않았다.

따라서 지금은 RDS Proxy를 추가하기보다, 다음 조건이 관측될 때 도입을 재검토하는 것이 합리적이다.

```text
DatabaseConnections가 50~60 근처까지 자주 상승한다.
RDS CPU는 낮은데 HikariPool connection timeout이 발생한다.
Pod scale-out 직후 DB connection이 급격히 튄다.
짧은 시간에 로그인/예매 요청이 몰리면서 connection churn이 커진다.
RDS failover 이후 connection 복구 시간이 운영상 문제가 된다.
```

## 5. 최종 결론

이번 검증 기준으로는 Read Replica와 RDS Proxy 모두 “지금 당장 필수 구현”은 아니다.

| 항목 | 현재 판단 | 이유 |
| --- | --- | --- |
| Read Replica | 선택 / 추후 고도화 | 조회 API p95 안정, 실패율 0%, RDS ReadIOPS/ReadLatency 낮음 |
| RDS Proxy | 선택 / 조건부 도입 | DB connections 최대 33/60, WriteLatency 낮음, Hikari timeout 징후 없음 |

발표에서는 다음처럼 설명하면 좋다.

```text
Read Replica와 RDS Proxy는 좋은 안정성 옵션이지만, 무조건 넣는다고 좋은 구조가 되는 것은 아닙니다.
이번 부하 검증에서는 조회 API와 예매 write path를 분리해서 확인했고,
현재 병목은 RDS read 또는 DB connection storm이 아니라는 결론을 얻었습니다.

따라서 현재는 connection pool 제한, KEDA replica 제한, 대기열 자동 감속으로 DB를 보호하고,
Read Replica와 RDS Proxy는 지표가 특정 조건을 넘을 때 도입하는 조건부 고도화 작업으로 정리했습니다.
```

## 6. 이번 작업을 수행한 이유와 얻은 결과

이번 작업을 수행한 이유:

- Read Replica와 RDS Proxy 도입 여부를 감이 아니라 실제 부하 지표로 판단하기 위해서다.
- 불필요한 비용과 구조 복잡도를 추가하지 않기 위해서다.
- 발표에서 “왜 안 넣었는지”까지 설명할 수 있는 근거를 만들기 위해서다.

얻은 결과:

- 조회 API 부하에서 RDS read 병목이 확인되지 않았다.
- 예매 write path 부하에서 DB connection storm이 확인되지 않았다.
- 현재 구조의 DB 보호 장치가 기본 부하에서는 정상적으로 동작함을 확인했다.
- CloudFront `/api/*` 라우팅 이슈는 별도 프론트/라우팅 이슈로 분리했다.
- Read Replica와 RDS Proxy는 현재 필수가 아니라, 조건부 선택 작업으로 정리할 수 있게 되었다.

## 7. 남은 후속 작업

1. CloudFront `/api/*` 라우팅 정상화 확인
   - 현재 `/api/games`가 frontend HTML을 반환한다.
   - 외부 사용자 경로 기준 부하테스트를 다시 하려면 이 문제가 먼저 해결되어야 한다.

2. seat-lock 계층 경합 원인 분석
   - RDS Proxy 검증 중 seat-lock create timeout이 일부 발생했다.
   - DB connection 문제는 아니지만, Valkey/seat-lock 경합 관점에서 별도 고도화 후보가 된다.

3. 더 큰 부하에서 재검증
   - 현재 결과는 dev 환경의 1차 판단이다.
   - 실제 발표 전에는 CloudFront 라우팅 복구 후 외부 경로 기준 smoke/load 테스트를 한 번 더 수행하면 좋다.
