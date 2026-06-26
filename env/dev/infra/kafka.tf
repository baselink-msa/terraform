module "kafka_event_streaming" {
  source = "../../../modules/msk-serverless"

  enabled                   = var.enable_kafka_event_streaming
  cluster_name              = "${local.name_prefix}-event-streaming"
  vpc_id                    = module.vpc.vpc_id
  subnet_ids                = module.vpc.private_data_subnet_ids
  client_security_group_ids = [module.eks.cluster_security_group_id]

  tags = merge(local.common_tags, {
    Purpose = "event-streaming-backbone"
  })
}

locals {
  kafka_event_topics = [
    "ticket.domain.events",
    "waiting.operational.events",
    "reservation.lifecycle.events",
    "capacity.signals",
    "infra.audit.events"
  ]

  kafka_topic_arns = var.enable_kafka_event_streaming ? [
    for topic in local.kafka_event_topics :
    "arn:aws:kafka:${var.aws_region}:${data.aws_caller_identity.current.account_id}:topic/${local.name_prefix}-event-streaming/${module.kafka_event_streaming.cluster_uuid}/${topic}"
  ] : []

  kafka_group_arns = var.enable_kafka_event_streaming ? [
    "arn:aws:kafka:${var.aws_region}:${data.aws_caller_identity.current.account_id}:group/${local.name_prefix}-event-streaming/${module.kafka_event_streaming.cluster_uuid}/baselink-*"
  ] : []
}

resource "aws_secretsmanager_secret" "kafka_event_streaming_config" {
  count = var.enable_kafka_event_streaming ? 1 : 0

  name                    = "${local.name_prefix}/kafka/event-streaming"
  description             = "MSK Serverless connection settings for Baselink event streaming producers and consumers."
  recovery_window_in_days = 7

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-kafka-event-streaming"
    Purpose = "event-streaming-runtime-config"
  })
}

resource "aws_secretsmanager_secret_version" "kafka_event_streaming_config" {
  count = var.enable_kafka_event_streaming ? 1 : 0

  secret_id = aws_secretsmanager_secret.kafka_event_streaming_config[0].id
  secret_string = jsonencode({
    clusterArn              = module.kafka_event_streaming.cluster_arn
    bootstrapBrokersSaslIam = module.kafka_event_streaming.bootstrap_brokers_sasl_iam
    topics                  = local.kafka_event_topics
    securityProtocol        = "SASL_SSL"
    saslMechanism           = "AWS_MSK_IAM"
  })
}

resource "aws_iam_role_policy" "backend_runtime_kafka" {
  count = var.enable_kafka_event_streaming ? 1 : 0

  name = "${local.name_prefix}-backend-runtime-kafka"
  role = aws_iam_role.backend_runtime_irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ConnectToKafkaEventStreaming"
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster"
        ]
        Resource = module.kafka_event_streaming.cluster_arn
      },
      {
        Sid    = "ProduceKafkaEvents"
        Effect = "Allow"
        Action = [
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:WriteData"
        ]
        Resource = local.kafka_topic_arns
      },
      {
        Sid    = "BootstrapKafkaTopics"
        Effect = "Allow"
        Action = [
          "kafka-cluster:CreateTopic",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:AlterTopic"
        ]
        Resource = local.kafka_topic_arns
      },
      {
        Sid    = "ConsumeKafkaEvents"
        Effect = "Allow"
        Action = [
          "kafka-cluster:AlterGroup",
          "kafka-cluster:DescribeGroup"
        ]
        Resource = local.kafka_group_arns
      },
      {
        Sid    = "ReadKafkaEvents"
        Effect = "Allow"
        Action = [
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:ReadData"
        ]
        Resource = local.kafka_topic_arns
      },
      {
        Sid    = "ReadKafkaRuntimeConfig"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.kafka_event_streaming_config[0].arn
      }
    ]
  })
}
