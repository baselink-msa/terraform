resource "aws_secretsmanager_secret" "app_database" {
  name                    = "${local.name_prefix}/database/application"
  description             = "Fixed PostgreSQL credentials used by Baselink application runtime services."
  recovery_window_in_days = 7

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-application-database"
    Purpose = "application-runtime-database"
  })

  lifecycle {
    prevent_destroy = true
  }
}
