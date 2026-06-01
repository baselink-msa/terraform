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

  cluster_name      = data.terraform_remote_state.infra.outputs.eks_cluster_name
  aws_region        = var.aws_region
  vpc_id            = data.terraform_remote_state.infra.outputs.vpc_id
  oidc_provider_arn = data.terraform_remote_state.infra.outputs.eks_oidc_provider_arn
  oidc_provider_url = data.terraform_remote_state.infra.outputs.eks_oidc_provider_url
  node_subnet_ids   = data.terraform_remote_state.infra.outputs.private_app_subnet_ids
  node_security_group_ids = [
    data.terraform_remote_state.infra.outputs.eks_cluster_security_group_id
  ]

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
data "aws_secretsmanager_secrets" "rds" {
  filter {
    name   = "name"
    values = ["rds!"]
  }
}

data "aws_secretsmanager_secret_version" "rds" {
  secret_id = tolist(data.aws_secretsmanager_secrets.rds.arns)[0]
}

locals {
  rds_creds = jsondecode(data.aws_secretsmanager_secret_version.rds.secret_string)
}

resource "kubectl_manifest" "backend_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata   = { name = "baselink-dev" }
  })

  depends_on = [module.eks_addons]
}

resource "kubectl_manifest" "backend_secret" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "backend-secret"
      namespace = "baselink-dev"
    }
    type = "Opaque"
    stringData = {
      SPRING_DATASOURCE_USERNAME = local.rds_creds["username"]
      SPRING_DATASOURCE_PASSWORD = local.rds_creds["password"]
      APP_JWT_SECRET             = "baselink-dev-jwt-secret-key-2026-minimum-32-bytes-long"
    }
  })

  depends_on = [kubectl_manifest.backend_namespace]
}