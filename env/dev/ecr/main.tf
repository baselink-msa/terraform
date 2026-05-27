module "ecr" {
  source = "../../../modules/ecr"

  environment  = var.ecr_environment
  repositories = var.ecr_repositories
  force_delete = var.ecr_force_delete
}
