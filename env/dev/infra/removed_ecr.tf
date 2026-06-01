removed {
  from = module.ecr.aws_ecr_repository.this

  lifecycle {
    destroy = false
  }
}
