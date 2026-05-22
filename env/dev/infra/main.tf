# --------------------------------------------------------
# SQS 모듈 호출 (파트 B 비동기 예매 확정 큐)
# --------------------------------------------------------
module "sqs_ticket_confirm" {
  source = "../../../modules/sqs"

  # Spring Boot 코드(@SqsListener)에 하드코딩된 큐 이름과 정확히 일치시킵니다.
  queue_name = "ticket-confirm-queue"
}