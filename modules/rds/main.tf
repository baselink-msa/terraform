resource "aws_db_instance" "this" {
  identifier        = var.identifier
  engine            = "postgres"
  engine_version    = var.engine_version
  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage

  db_name  = var.db_name
  username = var.username

  password                    = var.manage_master_user_password ? null : var.password
  manage_master_user_password = var.manage_master_user_password

  vpc_security_group_ids = var.vpc_security_group_ids
  db_subnet_group_name   = var.db_subnet_group_name

  skip_final_snapshot = var.skip_final_snapshot
  publicly_accessible = var.publicly_accessible

  tags = var.tags
}
