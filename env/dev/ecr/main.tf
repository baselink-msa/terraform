module "ecr" {
  source = "../../../modules/ecr"

  environment  = var.ecr_environment
  repositories = var.ecr_repositories
  force_delete = var.ecr_force_delete
}

data "aws_caller_identity" "current" {}

module "ecr_tokyo" {
  source = "../../../modules/ecr"

  providers = {
    aws = aws.tokyo
  }

  environment  = var.ecr_environment
  repositories = var.ecr_replication_enabled ? var.ecr_repositories : []
  force_delete = var.ecr_force_delete
}

resource "aws_ecr_replication_configuration" "tokyo" {
  count = var.ecr_replication_enabled ? 1 : 0

  replication_configuration {
    rule {
      destination {
        region      = var.ecr_replication_region
        registry_id = data.aws_caller_identity.current.account_id
      }

      repository_filter {
        filter      = "${var.ecr_environment}-"
        filter_type = "PREFIX_MATCH"
      }
    }
  }

  depends_on = [module.ecr_tokyo]
}
