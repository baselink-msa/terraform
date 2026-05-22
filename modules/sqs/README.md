# SQS (Simple Queue Service) 모듈

야구장 예매 시스템의 비동기 처리(예매 확정 등)를 위한 SQS 큐를 생성하는 모듈입니다.

## 🚀 사용 예시

`environments/dev/infra/main.tf` 에서 아래와 같이 호출합니다.

```hcl
module "sqs_ticket_confirm" {
  source = "../../../modules/sqs"

  # 백엔드 코드와 동일하게 이름 설정
  queue_name = "ticket-confirm-queue" 
}