module "ecr" {
  source = "../../../modules/ecr"

  environment  = var.ecr_environment
  repositories = var.ecr_repositories
}