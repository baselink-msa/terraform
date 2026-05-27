resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)

  name                 = "${var.environment}-${each.value}"
  image_tag_mutability = "MUTABLE"
<<<<<<< HEAD
=======
  force_delete         = var.force_delete
>>>>>>> main

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Environment = var.environment
    Service     = each.value
    Project     = "baselink"
  }
}
