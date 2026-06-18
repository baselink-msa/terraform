###############################################################################
# environments/dev/addon/main.tf
###############################################################################

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Part        = "addon"
  }
}

module "eks_addons" {
  source = "../../../modules/eks-addons"

  cluster_name           = data.terraform_remote_state.infra.outputs.eks_cluster_name
  aws_region             = var.aws_region
  vpc_id                 = data.terraform_remote_state.infra.outputs.vpc_id
  oidc_provider_arn      = data.terraform_remote_state.infra.outputs.eks_oidc_provider_arn
  oidc_provider_url      = data.terraform_remote_state.infra.outputs.eks_oidc_provider_url
  keda_operator_role_arn = "" # operator 는 Pod Identity(keda_cloudwatch)로 자격증명
  node_subnet_ids        = data.terraform_remote_state.infra.outputs.private_app_subnet_ids
  node_security_group_ids = [
    data.terraform_remote_state.infra.outputs.eks_cluster_security_group_id
  ]

  keda_predictive_paused = var.keda_predictive_paused

  tags = local.common_tags
}

module "argocd" {
  source = "../../../modules/argocd"

  cluster_name      = data.terraform_remote_state.infra.outputs.eks_cluster_name
  oidc_provider_arn = data.terraform_remote_state.infra.outputs.eks_oidc_provider_arn
  oidc_provider_url = data.terraform_remote_state.infra.outputs.eks_oidc_provider_url

  namespace           = "argocd"
  server_service_type = "ClusterIP"
  server_insecure     = true

  tags = local.common_tags
}

#==============================================================================
# backend-secret — RDS 비밀번호 + JWT Secret을 K8s Secret으로 생성
# Secrets Manager에서 RDS 비밀번호를 읽어서 자동 생성
#==============================================================================
data "aws_secretsmanager_secret_version" "rds" {
  secret_id = data.terraform_remote_state.infra.outputs.rds_master_user_secret_arn
}

locals {
  rds_creds = jsondecode(data.aws_secretsmanager_secret_version.rds.secret_string)

  keda_postgres_connection = coalesce(
    var.keda_postgres_connection,
    "postgresql://${urlencode(local.rds_creds["username"])}:${urlencode(local.rds_creds["password"])}@${data.terraform_remote_state.infra.outputs.rds_endpoint}/baseball_platform?sslmode=require"
  )
}

resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

resource "kubectl_manifest" "backend_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata   = { name = "baselink-dev" }
  })

  depends_on = [module.eks_addons]
}

resource "kubectl_manifest" "backend_config" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "backend-config"
      namespace = "baselink-dev"
    }
    data = {
      AWS_REGION                                              = var.aws_region
      SPRING_CLOUD_AWS_REGION_STATIC                          = var.aws_region
      SPRING_CLOUD_AWS_SQS_ENDPOINT                           = trimsuffix(data.terraform_remote_state.infra.outputs.ticket_confirm_queue_url, "/ticket-confirm-queue")
      SQS_TICKET_CONFIRM_QUEUE_NAME                           = "ticket-confirm-queue"
      SPRING_DATASOURCE_URL                                   = "jdbc:postgresql://${data.terraform_remote_state.infra.outputs.rds_endpoint}/baseball_platform"
      SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE              = "3"
      SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE                   = "1"
      SPRING_JPA_HIBERNATE_DDL_AUTO                           = "validate"
      SPRING_DATA_REDIS_HOST                                  = data.terraform_remote_state.infra.outputs.redis_primary_endpoint
      SPRING_DATA_REDIS_PORT                                  = "6379"
      WAITING_ROOM_TICKET_SERVICE_NAME                        = "ticket-service"
      WAITING_ROOM_TICKET_SERVICE_CAPACITY_PER_POD_PER_MINUTE = "20"
      WAITING_ROOM_TICKET_SERVICE_FALLBACK_READY_PODS         = "1"
      WAITING_ROOM_KUBERNETES_CAPACITY_ENABLED                = "true"
      WAITING_ROOM_CAPACITY_CACHE_TTL_MS                      = "5000"
      WAITING_ROOM_DB_PRESSURE_ENABLED                        = "true"
      WAITING_ROOM_DB_CONNECTION_BUDGET                       = "60"
      WAITING_ROOM_DB_CAUTION_THRESHOLD                       = "40"
      WAITING_ROOM_DB_WARNING_THRESHOLD                       = "50"
      WAITING_ROOM_DB_CRITICAL_THRESHOLD                      = "55"
      WAITING_ROOM_DB_PRESSURE_CACHE_TTL_MS                   = "5000"
      KNOWLEDGE_BASE_ID                                       = "<bedrock-knowledge-base-id>"
      OTEL_EXPORTER_OTLP_ENDPOINT                               = "http://otel-collector.monitoring:4317"
      OTEL_TRACES_EXPORTER                                      = "otlp"
      OTEL_METRICS_EXPORTER                                     = "none"
      OTEL_LOGS_EXPORTER                                        = "none"
    }
  })

  depends_on = [kubectl_manifest.backend_namespace]
}

resource "kubectl_manifest" "backend_secret" {
  sensitive_fields = [
    "stringData.SPRING_DATASOURCE_USERNAME",
    "stringData.SPRING_DATASOURCE_PASSWORD",
    "stringData.APP_JWT_SECRET"
  ]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "backend-secret"
      namespace = "baselink-dev"
      annotations = {
        "baselink.io/db-secret-hash" = sha256("${local.rds_creds["username"]}:${local.rds_creds["password"]}")
      }
    }
    type = "Opaque"
    stringData = {
      SPRING_DATASOURCE_USERNAME = local.rds_creds["username"]
      SPRING_DATASOURCE_PASSWORD = local.rds_creds["password"]
      APP_JWT_SECRET             = random_password.jwt_secret.result
    }
  })

  depends_on = [kubectl_manifest.backend_namespace]
}

resource "kubectl_manifest" "postgres_keda_secret" {
  sensitive_fields = [
    "stringData.connection"
  ]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "postgres-keda-secret"
      namespace = "baselink-dev"
    }
    type = "Opaque"
    stringData = {
      connection = local.keda_postgres_connection
    }
  })

  depends_on = [kubectl_manifest.backend_namespace]
}

#==============================================================================
# YACE CloudWatch Exporter — IRSA Role
# monitoring 네임스페이스의 yace-cloudwatch-exporter SA가 CloudWatch를 읽을 수 있도록
#==============================================================================
locals {
  yace_sa_name  = "yace-cloudwatch-exporter"
  yace_sa_ns    = "monitoring"
  oidc_url_bare = replace(data.terraform_remote_state.infra.outputs.eks_oidc_provider_url, "https://", "")
}

data "aws_iam_policy_document" "yace_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.terraform_remote_state.infra.outputs.eks_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url_bare}:sub"
      values   = ["system:serviceaccount:${local.yace_sa_ns}:${local.yace_sa_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url_bare}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "yace" {
  name               = "baselink-dev-yace-cloudwatch-exporter"
  assume_role_policy = data.aws_iam_policy_document.yace_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "yace_cloudwatch" {
  role       = aws_iam_role.yace.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_iam_role_policy" "yace_tagging" {
  name = "yace-resource-tagging"
  role = aws_iam_role.yace.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TagDiscovery"
        Effect = "Allow"
        Action = [
          "tag:GetResources",
          "tag:GetTagKeys",
          "tag:GetTagValues"
        ]
        Resource = "*"
      },
      {
        Sid      = "AccountAlias"
        Effect   = "Allow"
        Action   = ["iam:ListAccountAliases"]
        Resource = "*"
      }
    ]
  })
}

resource "kubectl_manifest" "baselink_application" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "baselink-app"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/baselink-msa/git-ops.git"
        targetRevision = "main"
        path           = "overlays/dev"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "baselink-dev"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true"
        ]
      }
    }
  })

  depends_on = [
    module.argocd,
    kubectl_manifest.backend_config,
    kubectl_manifest.backend_secret,
    kubectl_manifest.postgres_keda_secret
  ]
}
