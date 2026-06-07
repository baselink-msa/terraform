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
  description = "PostgreSQL access for agh-curve-db"
  vpc_id      = data.terraform_remote_state.infra.outputs.vpc_id

  tags = {
    Name    = "curve-db"
    Project = "curve-scaler"
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
