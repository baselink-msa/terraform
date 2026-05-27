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