module "ticket_event_writer" {
  source = "../../../modules/ticket-event-writer"

  name_prefix      = local.name_prefix
  source_queue_arn = module.sqs_ticket_domain_events.queue_arn

  event_retention_days = 14
  log_retention_days   = 14
  batch_size           = 10

  tags = merge(local.common_tags, {
    Purpose = "ticket-reliability-event-pipeline"
  })
}
