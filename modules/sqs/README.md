# SQS 모듈

BaseLink 티켓 예매 확정 요청을 비동기로 처리하기 위한 SQS 큐를 생성하는 모듈입니다.

현재 dev 환경에서는 `ticket-confirm-queue`와 `ticket-confirm-dlq`를 구성합니다. `ticket-worker-service`가 원본 큐의 메시지를 처리하다가 반복 실패하면 메시지는 DLQ로 이동하고, CloudWatch Alarm과 SNS를 거쳐 Slack 채널로 알림이 전송됩니다.

## 구성 흐름

```text
ticket-service
  -> ticket-confirm-queue
  -> ticket-worker-service
  -> 처리 성공: 메시지 삭제
  -> 처리 실패 반복: ticket-confirm-dlq 이동
  -> CloudWatch Alarm
  -> SNS Topic
  -> Amazon Q Developer
  -> Slack 알림 채널
```

## 생성 리소스

- 원본 큐: `ticket-confirm-queue`
- DLQ: `ticket-confirm-dlq`
- Redrive policy: 원본 큐에서 5회 초과 실패 시 DLQ 이동
- Redrive allow policy: 원본 큐에서 온 메시지만 DLQ redrive 허용
- CloudWatch Alarm: DLQ에 보이는 메시지가 1개 이상이면 `ALARM`
- SNS Topic: `baselink-dev-ops-alerts`
- Slack 연동: Amazon Q Developer chat configuration

## dev 환경 사용 예시

```hcl
module "sqs_ticket_confirm" {
  source = "../../../modules/sqs"

  queue_name               = "ticket-confirm-queue"
  create_dead_letter_queue = true
  dead_letter_queue_name   = "ticket-confirm-dlq"
  max_receive_count        = 5

  create_dead_letter_queue_alarm = true
  dead_letter_queue_alarm_name   = "${local.name_prefix}-ticket-confirm-dlq-messages-visible"
  dead_letter_queue_alarm_actions    = [aws_sns_topic.ops_alerts[0].arn]
  dead_letter_queue_alarm_ok_actions = [aws_sns_topic.ops_alerts[0].arn]

  tags = local.common_tags
}
```

## 운영 절차: DLQ 알림이 왔을 때

Slack에 `baselink-dev-ticket-confirm-dlq-messages-visible` 알림이 오면 아래 순서로 처리합니다.

### 1. DLQ 메시지 수 확인

```powershell
$dlq = "https://sqs.ap-northeast-2.amazonaws.com/740831361032/ticket-confirm-dlq"

aws sqs get-queue-attributes `
  --queue-url $dlq `
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```

`ApproximateNumberOfMessages`가 1 이상이면 아직 처리되지 않은 실패 메시지가 DLQ에 남아 있는 상태입니다.

### 2. 워커 로그 확인

```powershell
kubectl logs deployment/ticket-worker-service `
  -n baselink-dev `
  --since=30m
```

확인할 내용:

- JSON 파싱 실패인지
- 예약 ID가 존재하지 않는지
- DB 연결 오류인지
- 비즈니스 상태가 이미 `CONFIRMED` 또는 `CANCELED`인지
- 배포 직후 schema mismatch가 발생했는지

### 3. 메시지 본문 확인

운영자가 메시지 내용을 확인해야 할 때는 DLQ 메시지를 짧은 visibility timeout으로 조회합니다.

```powershell
aws sqs receive-message `
  --queue-url $dlq `
  --max-number-of-messages 1 `
  --visibility-timeout 30 `
  --wait-time-seconds 5 `
  --attribute-names ApproximateReceiveCount `
  --output json
```

주의:

- `receive-message`는 메시지를 삭제하지 않습니다.
- 조회한 메시지는 visibility timeout 동안 잠시 보이지 않습니다.
- 원인 분석 없이 바로 삭제하지 않습니다.

### 4. 원인 수정

원인에 따라 먼저 시스템을 복구합니다.

예시:

- 워커 버그라면 backend 수정 및 재배포
- DB schema 문제라면 Flyway migration 적용
- 잘못된 메시지 포맷이라면 producer 또는 worker 파싱 로직 수정
- 일시적 DB 장애라면 RDS 상태 및 backend connection pool 확인

원인 수정 없이 redrive하면 같은 메시지가 다시 DLQ로 돌아올 수 있습니다.

### 5. DLQ 메시지를 원본 큐로 redrive

AWS SQS의 `StartMessageMoveTask`는 DLQ 메시지를 원본 큐 또는 지정한 목적지 큐로 다시 이동합니다. 이 프로젝트에서는 원본 큐인 `ticket-confirm-queue`로 되돌려 `ticket-worker-service`가 다시 처리하게 합니다.

```powershell
$dlqArn = "arn:aws:sqs:ap-northeast-2:740831361032:ticket-confirm-dlq"
$sourceQueueArn = "arn:aws:sqs:ap-northeast-2:740831361032:ticket-confirm-queue"

aws sqs start-message-move-task `
  --source-arn $dlqArn `
  --destination-arn $sourceQueueArn `
  --max-number-of-messages-per-second 10
```

출력의 `TaskHandle`은 redrive 진행 상태 확인 또는 취소에 사용합니다.

### 6. Redrive 진행 상태 확인

```powershell
aws sqs list-message-move-tasks `
  --source-arn $dlqArn `
  --max-results 10
```

상태가 `COMPLETED`가 되면 DLQ에서 원본 큐로 메시지 이동이 끝난 것입니다.

### 7. 복구 확인

큐 상태:

```powershell
$queue = "https://sqs.ap-northeast-2.amazonaws.com/740831361032/ticket-confirm-queue"

aws sqs get-queue-attributes `
  --queue-url $queue `
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible

aws sqs get-queue-attributes `
  --queue-url $dlq `
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```

워커 상태:

```powershell
kubectl get deployment ticket-worker-service -n baselink-dev
kubectl logs deployment/ticket-worker-service -n baselink-dev --since=10m
```

CloudWatch Alarm:

```powershell
aws cloudwatch describe-alarms `
  --alarm-names baselink-dev-ticket-confirm-dlq-messages-visible `
  --query "MetricAlarms[0].{State:StateValue,Reason:StateReason}"
```

정상 상태:

```text
DLQ visible messages = 0
CloudWatch Alarm = OK
Slack 복구 알림 도착
ticket-worker-service Ready
```

## Redrive 취소

잘못된 redrive를 시작했거나 장애 원인이 아직 해결되지 않았다고 판단되면 진행 중인 task를 취소할 수 있습니다.

```powershell
aws sqs cancel-message-move-task `
  --task-handle "<TaskHandle>"
```

단, 이미 원본 큐로 이동된 메시지는 취소되지 않습니다.

## 메시지를 삭제해야 하는 경우

메시지 자체가 잘못되어 재처리하면 안 되는 경우에만 삭제합니다.

예시:

- 테스트 메시지
- 필수 필드가 없는 영구 불량 메시지
- 이미 수동 보정이 완료되어 재처리하면 중복 처리가 생기는 메시지

삭제 전에는 메시지 본문과 판단 근거를 Slack 또는 이슈에 기록합니다.

```powershell
aws sqs delete-message `
  --queue-url $dlq `
  --receipt-handle "<ReceiptHandle>"
```

## 발표 포인트

- SQS로 예매 확정 처리를 비동기화했습니다.
- 워커 실패 메시지는 DLQ로 격리해 정상 메시지 처리를 막지 않도록 했습니다.
- DLQ 메시지 발생 시 CloudWatch Alarm, SNS, Amazon Q Developer를 통해 Slack으로 알림을 보냅니다.
- 장애 원인을 수정한 뒤 DLQ 메시지를 원본 큐로 redrive하여 재처리할 수 있습니다.
- 단순 감지가 아니라 장애 격리, 알림, 복구 절차까지 운영 흐름을 구성했습니다.

## 참고

- AWS CLI `start-message-move-task`: https://docs.aws.amazon.com/cli/latest/reference/sqs/start-message-move-task.html
- AWS CLI `list-message-move-tasks`: https://docs.aws.amazon.com/cli/latest/reference/sqs/list-message-move-tasks.html
- AWS SQS DLQ Redrive: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-configure-dead-letter-queue-redrive.html
