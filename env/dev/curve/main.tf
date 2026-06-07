# curve-scaler terraform stack
# Day 1: curve DB (module.curve_db), SG
# Day 3: Lambda + EventBridge + VPC wiring
# Day 4: Pod Identity (KEDA CloudWatch trigger)

locals {
  name_prefix = "curve"
  lambda_env = {
    DB_HOST          = module.curve_db.db_instance_address
    DB_PORT          = "5432"
    DB_NAME          = var.curve_db_name
    DB_USER          = var.curve_db_user
    SECRET_ARN       = module.curve_db.master_user_secret_arn
    CEILING_RPS      = tostring(var.ceiling_rps)
    SERVICES         = "order"
    METRIC_NAMESPACE = "Baselink/CurveScaler"
  }
}

# ── 원격 인프라 상태 (VPC / 서브넷 / EKS SG) ──────────────────────
data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = "baselink-tfstate-740831361032"
    key    = "dev/infra/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# ────────────────────────────────────────────────────────────────────
# Day 1: curve DB 보안그룹 + RDS 인스턴스 (subnet group 은 기존 것 참조)
# ────────────────────────────────────────────────────────────────────

resource "aws_security_group" "curve_db" {
  name        = "curve-db"
  description = "PostgreSQL 5432 from EKS cluster SG -- curve-scaler only"
  vpc_id      = data.terraform_remote_state.infra.outputs.vpc_id

  tags = {
    Name    = "curve-db"
    Project = "curve-scaler"
    Owner   = "dmn123"
    Service = "curve-scaler"
  }
}

resource "aws_vpc_security_group_ingress_rule" "curve_db_from_eks" {
  security_group_id            = aws_security_group.curve_db.id
  referenced_security_group_id = data.terraform_remote_state.infra.outputs.eks_cluster_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from EKS cluster security group"
}

resource "aws_vpc_security_group_egress_rule" "curve_db_all" {
  security_group_id = aws_security_group.curve_db.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

module "curve_db" {
  source = "../../../modules/rds"

  identifier             = "agh-curve-db"
  db_name                = var.curve_db_name
  username               = var.curve_db_user
  vpc_security_group_ids = [aws_security_group.curve_db.id]
  db_subnet_group_name   = var.curve_db_subnet_group_name
  publicly_accessible    = false
  multi_az               = false
  skip_final_snapshot    = true

  tags = {
    Project = "curve-scaler"
    Owner   = "dmn123"
    Service = "curve-scaler"
  }
}

# ────────────────────────────────────────────────────────────────────
# Day 3: Lambda 보안그룹 + curve_db SG에 ingress 1개 추가
# ────────────────────────────────────────────────────────────────────

resource "aws_security_group" "lambda" {
  name        = "${local.name_prefix}-lambda"
  description = "curve-scaler Lambda egress to RDS"
  vpc_id      = data.terraform_remote_state.infra.outputs.vpc_id

  tags = {
    Name    = "${local.name_prefix}-lambda"
    Project = "curve-scaler"
  }
}

resource "aws_vpc_security_group_egress_rule" "lambda_all" {
  security_group_id = aws_security_group.lambda.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "curve_db_from_lambda" {
  security_group_id            = aws_security_group.curve_db.id
  referenced_security_group_id = aws_security_group.lambda.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from curve-scaler Lambda"
}

# ── IAM 역할 (Lambda 실행) ──────────────────────────────────────────

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "curve_lambda" {
  name               = "${local.name_prefix}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags = {
    Project = "curve-scaler"
  }
}

resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.curve_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "curve_lambda_inline" {
  name = "${local.name_prefix}-lambda-inline"
  role = aws_iam_role.curve_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PutMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Sid      = "GetSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = module.curve_db.master_user_secret_arn
      },
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
    ]
  })
}

# ── Lambda 패키지 (build/ 디렉토리 기준) ───────────────────────────
# build.sh 실행 후 build/ 에 pg8000 + app.py + db.py 가 설치됨.
# terraform apply 전에 반드시 build.sh 를 먼저 실행할 것.
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../../../../curve-scaler/lambdas/build"
  output_path = "${path.module}/../../../../curve-scaler/lambdas/lambda.zip"
}

# ── Lambda 함수 ─────────────────────────────────────────────────────

resource "aws_lambda_function" "writer" {
  function_name    = "curve-plan-writer"
  description      = "D-1 예매 집계 -> scaling_plan predicted_rps (domain B)"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  role             = aws_iam_role.curve_lambda.arn
  handler          = "app.writer_handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256

  vpc_config {
    subnet_ids         = data.terraform_remote_state.infra.outputs.private_app_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = local.lambda_env
  }

  tags = {
    Project = "curve-scaler"
  }

  depends_on = [aws_cloudwatch_log_group.writer]
}

resource "aws_lambda_function" "emitter" {
  function_name    = "curve-metric-emitter"
  description      = "1분마다 활성 윈도우 RPS -> CloudWatch Baselink/CurveScaler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  role             = aws_iam_role.curve_lambda.arn
  handler          = "app.emitter_handler"
  runtime          = "python3.12"
  timeout          = 15
  memory_size      = 256

  vpc_config {
    subnet_ids         = data.terraform_remote_state.infra.outputs.private_app_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = local.lambda_env
  }

  tags = {
    Project = "curve-scaler"
  }

  depends_on = [aws_cloudwatch_log_group.emitter]
}

# ── CloudWatch Log Groups (retention 명시) ──────────────────────────

resource "aws_cloudwatch_log_group" "writer" {
  name              = "/aws/lambda/curve-plan-writer"
  retention_in_days = 14
  tags              = { Project = "curve-scaler" }
}

resource "aws_cloudwatch_log_group" "emitter" {
  name              = "/aws/lambda/curve-metric-emitter"
  retention_in_days = 14
  tags              = { Project = "curve-scaler" }
}

# ── EventBridge Scheduler: cron(04:00 KST) -> writer ───────────────

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "curve_scheduler" {
  name               = "${local.name_prefix}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
  tags               = { Project = "curve-scaler" }
}

resource "aws_iam_role_policy" "curve_scheduler_invoke" {
  name = "${local.name_prefix}-scheduler-invoke"
  role = aws_iam_role.curve_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "InvokeWriter"
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.writer.arn
    }]
  })
}

resource "aws_scheduler_schedule" "writer_daily" {
  name       = "${local.name_prefix}-writer-daily"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 4 * * ? *)"
  schedule_expression_timezone = "Asia/Seoul"

  target {
    arn      = aws_lambda_function.writer.arn
    role_arn = aws_iam_role.curve_scheduler.arn
    input    = jsonencode({ source = "scheduler" })
  }
}

# ── EventBridge rule: rate(1 minute) -> emitter ─────────────────────

resource "aws_cloudwatch_event_rule" "emitter_1min" {
  name                = "${local.name_prefix}-emitter-1min"
  description         = "Triggers curve-metric-emitter every minute"
  schedule_expression = "rate(1 minute)"
  tags                = { Project = "curve-scaler" }
}

resource "aws_cloudwatch_event_target" "emitter" {
  rule = aws_cloudwatch_event_rule.emitter_1min.name
  arn  = aws_lambda_function.emitter.arn
}

resource "aws_lambda_permission" "emitter_eventbridge" {
  statement_id  = "AllowEventBridgeInvokeEmitter"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.emitter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.emitter_1min.arn
}

# ────────────────────────────────────────────────────────────────────
# Day 4: Pod Identity — EKS addon, KEDA CloudWatch IAM role, association
# ────────────────────────────────────────────────────────────────────

resource "aws_eks_addon" "pod_identity_agent" {
  count        = var.enable_pod_identity_agent_addon ? 1 : 0
  cluster_name = data.terraform_remote_state.infra.outputs.eks_cluster_name
  addon_name   = "eks-pod-identity-agent"

  tags = {
    Project = "curve-scaler"
  }
}

data "aws_iam_policy_document" "keda_cloudwatch_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "keda_cloudwatch" {
  name               = "${local.name_prefix}-keda-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.keda_cloudwatch_assume.json
  tags               = { Project = "curve-scaler" }
}

resource "aws_iam_role_policy" "keda_cloudwatch_inline" {
  name = "${local.name_prefix}-keda-cloudwatch-inline"
  role = aws_iam_role.keda_cloudwatch.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "KEDACloudWatch"
      Effect = "Allow"
      Action = [
        "cloudwatch:GetMetricData",
        "cloudwatch:ListMetrics",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_eks_pod_identity_association" "keda_cloudwatch" {
  cluster_name    = data.terraform_remote_state.infra.outputs.eks_cluster_name
  namespace       = "keda"
  service_account = "keda-operator"
  role_arn        = aws_iam_role.keda_cloudwatch.arn

  tags = {
    Project = "curve-scaler"
  }
}

# ────────────────────────────────────────────────────────────────────
# P6: 워치독 알람 (W4 heartbeat / W1 clamp / Werr Lambda errors) + SNS
# ────────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "curve_alerts" {
  name = "${local.name_prefix}-alerts"
  tags = { Project = "curve-scaler" }
}

resource "aws_sns_topic_subscription" "curve_alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.curve_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# W4: heartbeat 소실 (죽은 자는 부고를 못 보낸다 — 침묵=사망 판정)
resource "aws_cloudwatch_metric_alarm" "w4_heartbeat_lost" {
  alarm_name          = "${local.name_prefix}-W4-heartbeat-lost"
  alarm_description   = "emitter 침묵 3분 — Lambda/VPC/DB 장애 가능성"
  namespace           = "Baselink/CurveScaler"
  metric_name         = "heartbeat"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.curve_alerts.arn]
  tags                = { Project = "curve-scaler" }
}

# W1: clamp 발동 (예측값이 ceiling 에 도달)
resource "aws_cloudwatch_metric_alarm" "w1_clamp_engaged" {
  alarm_name        = "${local.name_prefix}-W1-clamp-engaged"
  alarm_description = "predicted_rps ceiling(${var.ceiling_rps}) 도달 — 과대 예측 또는 계획 오염 확인"
  namespace         = "Baselink/CurveScaler"
  metric_name       = "clamp_engaged"
  dimensions = {
    service = "order"
  }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.curve_alerts.arn]
  tags                = { Project = "curve-scaler" }
}

# Werr: Lambda 오류 — writer / emitter 각각 (for_each 2개)
locals {
  _lambda_alarm_fns = {
    writer  = aws_lambda_function.writer.function_name
    emitter = aws_lambda_function.emitter.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "werr_lambda_errors" {
  for_each = local._lambda_alarm_fns

  alarm_name        = "${local.name_prefix}-Werr-${each.key}-errors"
  alarm_description = "${each.value} Lambda 오류 발생 (5분 집계 ≥1)"
  namespace         = "AWS/Lambda"
  metric_name       = "Errors"
  dimensions = {
    FunctionName = each.value
  }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.curve_alerts.arn]
  tags                = { Project = "curve-scaler" }
}

# ────────────────────────────────────────────────────────────────────
# P7: AI Diagnoser Lambda + 진단 전용 SNS topic
# ────────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "curve_diagnosis" {
  name = "${local.name_prefix}-diagnosis"
  tags = { Project = "curve-scaler" }
}

resource "aws_cloudwatch_log_group" "diagnoser" {
  name              = "/aws/lambda/curve-diagnoser"
  retention_in_days = 14
  tags              = { Project = "curve-scaler" }
}

# IAM 인라인 확장 (기존 curve_lambda_inline 무수정, 별도 policy 추가)
resource "aws_iam_role_policy" "curve_lambda_diagnoser" {
  name = "${local.name_prefix}-lambda-diagnoser"
  role = aws_iam_role.curve_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockConverse"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        # cross-region inference profile ARN 은 account 종속이므로 "*" 필요
        Resource = "*"
      },
      {
        Sid    = "FilterLogs"
        Effect = "Allow"
        Action = ["logs:FilterLogEvents"]
        Resource = [
          "${aws_cloudwatch_log_group.emitter.arn}:*",
          "${aws_cloudwatch_log_group.writer.arn}:*",
        ]
      },
      {
        Sid      = "GetMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData"]
        Resource = "*"
      },
      {
        Sid      = "PublishDiagnosis"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.curve_diagnosis.arn
      },
    ]
  })
}

resource "aws_lambda_function" "diagnoser" {
  function_name    = "curve-diagnoser"
  description      = "알람 SNS -> 지표/로그/DB 수집 -> Bedrock 진단 -> 인용 검증 -> JSON"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  role             = aws_iam_role.curve_lambda.arn
  handler          = "app.diagnoser_handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 512

  vpc_config {
    subnet_ids         = data.terraform_remote_state.infra.outputs.private_app_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = merge(local.lambda_env, {
      BEDROCK_MODEL_ID = var.bedrock_model_id
      DIAG_TOPIC_ARN   = aws_sns_topic.curve_diagnosis.arn
      LOG_GROUPS       = "/aws/lambda/curve-metric-emitter,/aws/lambda/curve-plan-writer"
    })
  }

  tags       = { Project = "curve-scaler" }
  depends_on = [aws_cloudwatch_log_group.diagnoser]
}

# curve_alerts -> diagnoser (루프 방지: diagnoser 는 diagnosis topic 에만 publish)
resource "aws_sns_topic_subscription" "curve_alerts_to_diagnoser" {
  topic_arn = aws_sns_topic.curve_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.diagnoser.arn
}

resource "aws_lambda_permission" "diagnoser_sns" {
  statement_id  = "AllowSNSInvokeDiagnoser"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.diagnoser.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.curve_alerts.arn
}
